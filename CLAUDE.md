# ClearBridge Mobile — persistent context

## Repos & branches
- `origin` (GitHub): `dlveldschoenVertteX/ClearBridge-Mobile-Build` — **now PUBLIC** (flipped
  2026-07-15 specifically to get unlimited free GitHub Actions minutes after both GitHub's
  private-repo minutes and GitLab's free-tier minutes were exhausted). Source is public;
  no secrets live in the repo — CI secrets are GitHub encrypted Secrets / GitLab CI/CD
  variables, injected at build time only.
- `gitlab` (mirror): `clearbridge-project1/ClearBridge-Mobile-Build` — private. `.gitlab-ci.yml`
  builds only `clearbridge_beta` (kept minimal to stay inside the 400 free min/month tier).
  Free tier resets on the calendar month (~the 1st). Not actively used while GitHub Actions
  is unblocked.
- Active development branch: `claude/clearbridge-mobile-github-r8tagm`.

## Standing instruction — CI builds
**Do not automatically trigger or re-trigger a CI build after pushing a fix.** Push code
changes when asked, but wait for an explicit "build it" (or similar) before kicking off or
re-running the GitHub Actions / GitLab CI pipeline. This was an explicit user correction
after burning through CI minutes via automatic rebuild-and-verify loops.

Also note: GitHub Actions' `build.yml` triggers on `on: [push]` unconditionally — pushing
*any* commit (including docs) will auto-start a workflow run as a side effect, even without
me manually invoking it. Flag this to the user before pushing non-trivial commits if it
matters in the moment.

## Three apps in this monorepo
1. **Main app** (`android/`, root) — four-angle + arc-sweep SfM capture flavors.
   **Discontinued 2026-07-15** (see below); the `build` CI job that built it was removed
   from `.github/workflows/build.yml`. App code/flavors left in place, not deleted.
2. **`capture_harness/`** — standalone camera-only test build (mac_capture package only, no
   Firebase/Paystack/MLKit). GitHub Actions job `build-capture-harness`.
3. **`clearbridge_beta/`** — consumer-facing beta app, **front-only single-capture flow**
   (no SfM/oscillation). GitHub Actions job `build-clearbridge-beta`; also mirrored in
   `.gitlab-ci.yml`. This is the active development focus.

## Four-angle / arc-sweep: discontinued (2026-07-15)
User decision: **not moving forward with the four-angle/arc-sweep SfM reconstruction
model.** Same root cause as the beta app's earlier oscillating-capture drop — wider
angular coverage dilutes ridge density in NFIQ's fixed 500×500 model input rather than
adding usable detail. The CI `build` job (built `fourAngle`/`arcSweep` flavors, published
to GitHub Release + Firebase Storage) was removed from `build.yml`; `build-capture-harness`,
`build-clearbridge-beta`, and `deploy-web` remain. App code/flavors were **not** deleted
from the repo — only the CI build step was dropped, in case revisited later.

## Capture pipeline decisions (front-only, current)
- **8-phase oscillating / SfM reconstruction is deliberately dropped for the beta app.**
  Confirmed multiple times (see Notion session logs) that wider angular coverage dilutes
  ridge density in NFIQ's fixed 500×500 model input rather than adding usable detail —
  structurally cannot win. Single front-thumb-pad capture only.
- `FrontCaptureController` (`clearbridge_beta/lib/front_capture_controller.dart`): 1.5s
  hold → 4-shot burst → upload. Burst **alternates ambient/flash** (even index = torch off,
  odd = torch on with EV step -1.0) — an earlier all-flash burst blew out the pad centre
  completely at ~10cm (NFIQ2=9, confirmed via raw burst frame + enhanced_flat.jpg all-white).
- **Secondary-camera (IR/wide-lens) capture ported into front_only_v1, 2026-07-15.** This
  was built + validated on `OscillatingCaptureController` (IR torch shot scored
  competitively with, and on one real device above, the main camera's best frame — see
  `docs/CAPTURE_OPTIMIZATION_SCOPE.md`), and the backend's `secondaryCameras` scoring loop
  in `main.py` is shared/unconditional (not gated to oscillating mode) — but it was never
  wired into `front_capture_controller.dart` since front_only_v1 didn't exist yet when the
  feature was built. Ported directly (best-effort, try/catch per camera, non-blocking):
  after the main burst uploads + Firestore commit, opens each other available back camera,
  fires one torch-lit still, uploads it, records `secondaryCameras` on the doc — all before
  the `processEnhanceAndScore` trigger so the backend's one-time doc read sees it. Not yet
  validated on a real device with this specific app/flow.
- `PadSilhouetteShape.defaultShape` (`packages/mac_capture/lib/src/capture_pad_silhouette_overlay.dart`):
  tapered superellipse guide, shrunk to **top-half of the pad only** per CTO annotation
  (cy=0.37, ry=0.13 — was cy=0.5, ry=0.26). Kept 1:1 with `_scoreRoi` in the controller.
- `guideRegion` is written to Firestore and used **directly as the AFIS mask** on the
  backend (no U-Net segmentation, no fragile ridge-periodicity crop). **Now computed at
  runtime** (`_computeGuideRegion` in `front_capture_controller.dart`), not hardcoded —
  see the BoxFit.cover fix below. If NFIQ looks systematically off-center again, re-derive
  from the actual preview→still transform rather than re-guessing constants.
- **BoxFit.cover guideRegion bug, found + fixed 2026-07-15 (commit `a20e009`) — real
  breakthrough, NFIQ2 jumped from single digits to 72.** The old hardcoded guideRegion
  constants (cx=0.63, cy=0.50, rx=0.13, ry=0.17) were derived by rotating the on-screen
  pad silhouette's raw screen-normalized fraction directly into still-space, silently
  ignoring the `BoxFit.cover` crop+scale that `front_capture_screen.dart`'s
  `_cameraLayer()` applies (`FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge)`
  around a `SizedBox` sized to the swapped preview dimensions) whenever the preview's
  aspect ratio differs from the screen's. Net effect: the backend mask used as the AFIS
  ROI **did not match what the user actually saw on the live capture screen** — it caught
  lower-pad skin creases the on-screen guide never covered. Found only because the user
  sent two annotated screenshots (live on-screen guide vs. a rendered mask overlay with a
  hand-drawn "correct ROI") after explicitly rejecting an incorrect "skin-crease
  contamination" theory floated first — **don't re-derive "why is the print bad" from
  theory when the user says the mask doesn't match what they see; ask for/inspect the
  actual on-screen visual before theorizing.** Fix: `_computeGuideRegion({screenSize,
  previewSize})` now maps the pad silhouette through the same BoxFit.cover math at
  runtime (screen size + preview size both vary by device), then applies the existing
  correct `(u,v) -> (1-v,u)` rotation into still-space. Validated on 3 real post-fix
  captures: 2 of 3 scored real `nfiq2Score` **72** (previous project-wide best was 62;
  previous `front_only_v1` baseline was single digits) — visually confirmed via
  `superprint_afis.png` as a genuinely clean, dense, natural whorl print. Notion session
  log: https://app.notion.com/p/39ea03ed9e7e818bbab5e12207af6570
- NFIQ scores are backend-only, never surfaced to end users (see Notion "NFIQ Visibility
  Policy — Backend Only").
- **NFIQ2 sidecar exists and is live** (`functions/nfiq2_service/`, deployed to Cloud Run
  `nfiq2-service` in `africa-south1`) — the real NIST NFIQ2 binary, called from
  `main.py`/`nfiq2_client.py` as an additive, non-blocking ground-truth check alongside the
  ResNet18 proxy (`nfiqScore`). Written to Firestore as `nfiq2Score` (0-100). `main.py`
  scores whichever image won the internal proxy comparison — either `best_afis_img` (the
  binarized/posterized AFIS superprint) or `best_enhanced` (continuous-tone) — recorded as
  `nfiqSource: "afis"` or `"cylindrical"` on the capture doc.
  - **Do NOT assume the binarized AFIS image is bad input for NFIQ2.** A real production
    oscillating capture scored **70% NFIQ2 via the binarized AFIS template**
    (`nfiqSource: afis`) — proof the binarized rendering is not inherently
    out-of-distribution for NFIQ2, despite NFIQ2 being calibrated on natural scanner
    images. A session on 2026-07-15 incorrectly derived this "binarized = bad" theory from
    first principles after seeing two catastrophic front_only_v1 captures (nfiq2Score 4
    and 6, both `nfiqSource: afis`) and "fixed" `main.py` to always score `best_enhanced` —
    that change was reverted once the 70% counter-example came up. The real cause of those
    two low scores was capture quality (motion blur from AF-lock timing + camera shake +
    a red ambient-light cast in the test environment), not which image type NFIQ2 scored.
    **Before changing anything about which image NFIQ2 scores, pull real Firestore
    `nfiq2Score`/`nfiqSource` history first** — don't re-derive this from theory alone.
  - **NFIQ2 sidecar can't be called directly from this sandbox** — its Cloud Run URL
    (`*.run.app`) is blocked by the sandbox egress policy (only `*.googleapis.com` is
    reachable); same class of restriction as the GHCR/dl.google.com blocks below. Firestore/
    Storage/Cloud Run Admin API (`run.googleapis.com`, to look up the service URL) all work
    fine — it's specifically the deployed service's own generated hostname that's blocked.

## Enhancement model tuning (started 2026-07-15, post-guideRegion-fix)
CTO directive after the guideRegion fix's 72-score breakthrough: tune the AFIS enhancement
pipeline itself (`functions/processEnhanceAndScore/afis_print.py` — Gabor filtering, ridge
frequency normalization, feather blur), which had never been manually tuned. Verify every
change against real `nfiq2Score` (the sidecar), never the ResNet18 proxy alone — same
discipline as everywhere else in this project. The sidecar itself can't be called from this
sandbox (see above) — real validation needs a deploy + real device capture cycle.

**First tuning pass done, committed `abbb7b8`, NOT YET DEPLOYED.** Method: built a local
harness (`nfiq_resnet18.onnx` downloaded once from Storage, run fully offline; scratchpad
`enh_tune/afis_print_tunable.py` + `sweep.py`) that reproduces `main.py`'s exact proxy
scoring closely enough to match its recorded values almost exactly on 5 real captures with
known ground-truth `nfiq2Score`. Used it to sweep Gabor/CLAHE/feather/frequency-clamp
parameters. Findings:
- **Broad correlation across all 24 scored captures**: every capture whose winning variant
  ended with native ridge wavelength ≥15px scored catastrophically on real NFIQ2 (single
  digits), *regardless* of whether/how aggressively frequency-normalization resampling was
  applied. Only 9-11px native wavelength captures scored well (62, 72, 72) — though 9px
  alone wasn't sufficient in one case (`3edf5455`: wl=9, still scored 1, unexplained). This
  points at native capture distance as a bigger lever than post-processing, but the
  enhancement side was still worth tuning within that constraint.
- Changed: `_GABOR_SIGMA_RATIO` 0.56→0.65, `_GABOR_GAMMA` 0.6→0.85 (both broadly positive
  across every real test case, good and bad alike, visually confirmed as finer/more
  continuous ridge lines — no regressions), `_FEATHER_SIGMA` 4.0→2.5 (small, uniformly
  non-negative), `_FREQ_SCALE_MIN` 0.35→0.7 (caps how aggressively the ridge-period resample
  can shrink the image — directly targets the correlation above; improved the local proxy
  +7.2 on the real bad case that had used an 0.5x rescale in production, zero effect on
  captures that didn't need rescaling).
- Final combined check: 4 of 5 real test cases improved or held flat; only the most extreme
  (native wl=20px) dipped slightly — likely beyond what enhancement alone can fix.
- **Not yet confirmed against real NFIQ2** — proxy + visual evidence only so far (except the
  frequency-floor change, which also has real, non-proxy Firestore support). Needs a deploy
  + real device captures to confirm before trusting the gain. Notion session log:
  https://app.notion.com/p/39ea03ed9e7e81ad9beac33f717445b7

## Fidelity/matching axis (added 2026-07-15) — ground-truth minutiae matching sidecar
CTO elevated **fidelity** (does the print structurally/minutiae-match the real finger,
not just score well on NFIQ2) to co-equal status with `nfiq2Score` after comparing our
best real capture (`ccb9c85a`, nfiq2Score 72) against a real inked print and finding ours
visibly noisier despite the good score. Full plan in
`docs/GROUND_TRUTH_MATCHING_SCOPE.md`; CTO decisions: keep capture single-front-pad-only
(NFIQ's fixed 500×500 scoring and real AFIS matching value pull in opposite directions on
capture coverage — don't reopen this), try pretrained enhancement models before collecting
a training dataset from scratch.

**Stream A built and deployed-pending: mindtct/bozorth3 ground-truth matching sidecar.**
Extended `functions/nfiq2_service/` (the existing NFIQ2 Cloud Run service) with `/minutiae`
and `/match` endpoints wrapping NIST NBIS's `mindtct` (minutiae extraction) and `bozorth3`
(minutiae matching, partial-print-capable, no fixed universal pass/fail threshold) — this
is the actual measurement tool for the fidelity axis, separate from and complementary to
NFIQ2's quality axis. New `functions/processEnhanceAndScore/mindtct_client.py` mirrors
`nfiq2_client.py`'s ID-token auth pattern (`extract_minutiae()`, `match_prints()`).

- **NBIS source is vendored into the repo** (`functions/nfiq2_service/vendor/nbis/`, ~9MB,
  see `vendor/nbis/PROVENANCE.md`) rather than fetched from an external URL at Docker build
  time. A first attempt at fetching `lessandro/nbis` (a community mirror — no single
  official NIST-hosted git repo for NBIS exists, unlike NFIQ2's `usnistgov/NFIQ2`; NIST's
  own distribution page 403s automated fetches) directly in the Dockerfile was correctly
  blocked by the session's own safety tooling as an unvetted third-party build dependency.
  Verified the mirror's content is genuine NBIS 5.0.0 (license header, changelog, and every
  file's NIST/ITL project metadata all match NIST's real release) before vendoring, then got
  the user's explicit sign-off on this specific source. Vendored copy trimmed from ~102MB to
  ~9MB (just the packages `mindtct`/`bozorth3` actually link against, traced via their own
  Makefiles) and required one real fix: `-fcommon` added to `CFLAGS` (this 2015-era C89 code
  needs it on GCC 10+, which Ubuntu 22.04 ships — without it, several packages fail to link
  with "multiple definition" errors).
- **Build-verified locally before vendoring** (not yet build-tested in the real Cloud Build/
  Ubuntu-22.04 environment — watch the first real deploy's log, same caveat the Dockerfile
  already carries for the NFIQ2 `.deb` install step): `setup.sh && make config && make it`
  exits 0, produces real `mindtct`/`bozorth3` binaries whose usage output matches NBIS's own
  man pages, and a synthetic end-to-end smoke test (mindtct on a test image → `.xyt` minutiae
  file → bozorth3 on two `.xyt` files → numeric match score) ran without error.
- **Not yet deployed.** Next steps per the approved plan: deploy (separate explicit go-ahead
  needed, same as every backend change), then get a real baseline match score between the
  CTO's ink scan (`ground_truth/cto_thumb_ink_scan_2026-07-15.jpg` in Firebase Storage) and
  the best real captures (`ccb9c85a`, `3e54236a`, `c34911b5`), then the CTO-chosen "try
  pretrained enhancement models first" experiment (FpEnhancer / FingerFlow's CoarseNet-
  FineNet, no training) scored against that real match baseline.

## Known Android/Gradle gotchas (already fixed, keep in mind for new flavors/plugins)
- **Partial-ABI APK / "can't unzip" crash on install**: plugin AARs (camerax, TFLite,
  datastore) bundle prebuilt `.so` for arm64-v8a + armeabi-v7a + x86_64, but
  `--target-platform android-arm64` only compiles `libapp.so`/`libflutter.so` for arm64,
  leaving other ABI dirs partially populated → Android's ABI selector picks a broken one.
  Fix is `packaging.jniLibs.excludes` (strips at final packaging step) — `ndk.abiFilters`
  does **not** work, it only controls JNI compilation, not prebuilt-lib stripping.
- **Debug keystore path mismatch across runners**: the release signing config falls back to
  the built-in "debug" SigningConfig's storeFile when no real release keystore secret is
  configured, and a pre-build step generates that keystore if missing — but the path must be
  read from `android.signingConfigs.getByName("debug").storeFile` directly, **not**
  hardcoded to `~/.android/debug.keystore`. Some runners (confirmed on a GitHub-hosted
  `ubuntu-latest` runner, 2026-07-15) resolve AGP's actual debug keystore location to the XDG
  path `~/.config/.android/debug.keystore` instead, and a hardcoded path silently generates a
  keystore nobody looks up while `validateSigningRelease` still fails "not found".
- **Stable release keystore not yet activated**: `scripts/generate_release_keystore.sh`
  exists to generate a permanent signing cert, but the user hasn't run it / configured
  `KEYSTORE_BASE64` + `KEYSTORE_PASSWORD` + `KEY_ALIAS` + `KEY_PASSWORD` as CI secrets yet.
  Until then, every CI build signs with a freshly-regenerated debug keystore, so upgrading
  over a previous install still requires uninstalling first (cert mismatch). This is a
  one-time setup task still pending.

## CI minutes / build-environment notes
- Building **inside this Claude Code sandbox is not viable** for Android/Flutter: the
  session's egress policy blocks both the GHCR blob-storage CDN
  (`pkg-containers.githubusercontent.com`, needed for `docker pull` of CI images) and
  Google's Android SDK/Maven host (`dl.google.com`, needed for AndroidX/Gradle deps even
  with a natively-installed Flutter SDK). Don't retry this path — it's a deliberate org
  egress restriction, not a fixable config issue.
- A real alternative if GitHub/GitLab CI is ever blocked again: the user has an AWS
  SageMaker account with credit. A SageMaker notebook instance is a normal EC2-backed VM
  with unrestricted internet and a terminal — viable for a manual one-off build (install
  Flutter + Android cmdline-tools, clone, build, download the APK via the Jupyter file
  browser, stop the instance). Not automated; would need to be walked through with the user.
