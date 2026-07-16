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
- **Deployed 2026-07-15 to `nfiq2-service` (Cloud Run, africa-south1), revision
  `nfiq2-service-00002-kxl`.** Built via Cloud Build directly from Python (`google-cloud-
  build`/`google-cloud-run`/`google-cloud-storage` client libs) since this sandbox has no
  `gcloud` CLI — source tarball staged through the existing `clearbridge-dc699-nfiq2-build-
  src` GCS bucket, then `ServicesClient.update_service()` to roll the new image out.
  Deploying required a service-account key upload (same pattern as the earlier Firebase
  deploy this session) since no ADC/credentials are configured in this sandbox by default.
- **First real Cloud Build run found and fixed a genuine bug the local test missed**:
  `mindtct`/`bozorth3` compiled fine, but the build-time sanity check (`RUN mindtct ... ||
  true`) reported "not found" — NBIS's top-level Makefile has `it` and `install` as
  *separate* targets (`all: config it install catalog`), so `make it` alone never puts the
  binaries on `PATH`. Chaining `make install` was rejected too: its hardcoded
  `RUNTIME_DATA_PACKAGES := an2k nfiq pcasys` list would `cp` runtime data from `nfiq`/
  `pcasys`, which aren't vendored, and hard-fail. Fix (commit `da4ae5b`): copy the two
  compiled binaries directly to `/usr/local/bin` instead of running `make install` at all.
  Rebuilt, confirmed via the real build log that both binaries now respond with correct
  usage text, then deployed. **Lesson for future NBIS-adjacent work**: `make it` builds
  only; never assume it installs without checking the actual Makefile.
- **Not yet HTTP-smoke-tested** — same known sandbox limitation as the NFIQ2 sidecar itself
  (this sandbox's egress reaches `*.googleapis.com` but not the deployed service's own
  `*.run.app` hostname). Real validation happens the same way NFIQ2 itself gets validated:
  through `processEnhanceAndScore` calling it during an actual capture, not from here.
- **First real baseline match test run, 2026-07-15** (in-sandbox, using the vendored
  `mindtct`/`bozorth3` binaries directly — not via the live HTTP endpoint, which this
  sandbox can't reach). Probe = `3e54236a` (nfiq2Score 72; picked over the other two 72-
  scorers `ccb9c85a`/`c34911b5` by visual ridge-continuity check — `c34911b5` has visibly
  messier/broken ridges lower-right; `3e54236a` and `ccb9c85a` both clean, `3e54236a`
  slightly smoother/less "hairy" at the edges). Gallery = the CTO's ink scan.
  - **Raw score: 3** (essentially a non-match by bozorth3's usual scale). Investigating
    *why* before treating that as a verdict (same discipline as everywhere else):
    measured actual ridge wavelength in each image and found a real ~2.75x scale mismatch
    (mindtct assumes ~500 DPI; nothing was correcting for it). Correcting raised the score
    to 14 with a quick single-ROI estimate — real evidence scale matters, but that quick
    estimate itself turned out unreliable (see below).
  - **CTO directly observed the prints are mirrored** (loop on the wrong side). Checked
    `packages/mac_capture`'s still-image decode path (`decodeStillJpegToLuma`) for an
    app-level mirroring bug — found none, it only rotates for sensor orientation, never
    flips. Swept all 8 rotate/mirror combinations of the (scale-corrected) pair: scores
    only spread 10-18, too narrow/noisy to trust any single orientation as "the" correct
    one (genuine matches typically score far higher). No code-traceable bug found, so the
    mirroring's root cause is still open — the fix that shipped works around the
    ambiguity rather than resolving it (see below).
- **Built real DPI normalization + mirror handling into `mindtct_client.py`**
  (commit `7d359c0`), not a one-off script:
  - `_estimate_ridge_wavelength_px()`: FFT-based ridge-period estimate. The quick manual
    estimate used above wasn't actually reliable — sweeping ROI size on the ink scan gave
    wildly inconsistent results (61px to 163px) because a real photo's lighting/shading
    gradient can dominate the low frequencies a small `min_r` cutoff doesn't exclude.
    Shipped defaults (`roi_frac=0.6`, `min_r=15`) were chosen because they're the ones
    that **converge to a stable answer across a wide range of nearby parameter values on
    both real images** (~11.7px digital capture, ~21.6px ink scan) — convergence, not a
    single lucky number, is what makes an estimate trustworthy on a noisy real photo.
  - `_normalize_dpi()`: rescales toward this project's existing ~9px calibration target
    (same one `afis_print.py` already uses).
  - `match_prints()` now tries the probe both as normalized and mirrored, keeps the
    higher bozorth3 score, and returns a dict (`matchScore`, `mirrorApplied`,
    `rawScoreOriginal`, `rawScoreMirrored`, `probeDpiScale`, `galleryDpiScale`) instead of
    a bare int — full transparency, since nothing else calls this yet.
  - **Honest result with the more rigorous estimate: score 6, mirror did NOT help (5 <
    6)** — actually lower than the quick pass's 14. Real, not tuned to look good: it means
    the quick pass's number was closer by chance, and scale/orientation alone isn't the
    dominant gap for this specific pair. Remaining real candidates, not yet corrected for:
    the ink scan shows the whole thumb while the digital capture's `guideRegion` only
    frames the pad's top portion (a coverage mismatch — not fixable by scale/orientation
    correction alone), and the ink scan photo itself has real quality issues (blur, low
    contrast — the CTO's own words: "the best I could get"). **Do not treat this single
    pair's score as a verdict on fidelity either way** — same "need more real data before
    concluding" discipline as the rest of this project. All test artifacts (probe/gallery
    images at every processing stage) are in this session's scratchpad, not committed.
- **Next real steps**: (1) get more paired ink-scan/digital-capture samples before
  generalizing from one pair; (2) the CTO-chosen "try pretrained enhancement models
  first" experiment — see the new section below for where that stands.

## Pretrained fingerphoto-enhancement models (2026-07-15) — pyfing sidecar built
Per the CTO's "try pretrained first" decision (§ Fidelity/matching axis above), evaluated
existing pretrained models before any from-scratch training. Learned from the NBIS
vendoring experience this same session: pulling in external pretrained weights is the same
class of supply-chain decision as vendoring external source, so applied the same diligence
(verify the source is real/legitimate/maintained, check license compatibility with shipping
in a commercial product, confirm it actually does image enhancement and not just minutiae
extraction) before integrating anything.

**Two originally-identified candidates both ruled out on closer inspection**:
- **FpEnhancer** (github.com/XiongjunGuan/FpEnhancer) — real repo, MIT license, legitimate
  academic author, but trained on ~800 rolled/scanner-quality prints with synthetic noise
  augmentation; its own README warns it struggles on "highly blurry/incomplete images or
  complex backgrounds" — exactly the failure mode a raw fingerphoto presents. Weights only
  distributed via an unverified external Google Drive link.
- **FingerFlow** (`pip install fingerflow`) — real package, MIT license, but
  `extract_minutiae()` only returns minutiae coordinates — **no enhanced image output at
  all**, disqualifying for this use case regardless of quality. Also shows signs of light
  abandonment (last release ~2022).

**New candidate found and adopted: `pyfing`** (github.com/raffaele-cappelli/pyfing,
`pip install pyfing`). Verified clean — MIT license (commercial use/redistribution
explicitly fine), maintainer Raffaele Cappelli is an associate professor at the University
of Bologna and FVC (Fingerprint Verification Competition) co-organizer, author of the
widely-used SFinGe synthetic-fingerprint generator. Pretrained weights ship **inside the
MIT-licensed PyPI package itself** (confirmed via source read — model classes build weight
paths from `os.path.dirname(__file__)`, no external download calls anywhere; the wheel is
~85MB, consistent with bundled `.h5` weights) — no separate third-party host to vet at all,
cleaner than even the NBIS situation. Real peer-reviewed backing: SNFOE/SNFFE (IEEE Access
2024, same author), LEADER (arXiv:2602.15493, claims cross-domain generalization to latent
impressions — the closest published claim to our fingerphoto use case of any candidate
found).

**Built `functions/pyfing_service/`** (Dockerfile + Flask `app.py` running pyfing's
segmentation→orientation→frequency→enhancement pipeline, `SNFEN`/`GBFEN` method choice) as
a **separate Cloud Run sidecar** — CTO's explicit choice over embedding directly in
`processEnhanceAndScore`, since pyfing needs Keras/TensorFlow alongside that function's
existing PyTorch stack; isolating it keeps the shared function's footprint unchanged and
makes it trivial to fully remove if the experiment doesn't pan out. New
`functions/processEnhanceAndScore/pyfing_client.py` mirrors `nfiq2_client.py`'s ID-token
auth pattern (`enhance_fingerprint()`).

**First real test, in-sandbox** (installed `pyfing`+`keras`+`tensorflow-cpu` directly,
ran the Flask app via its test client — no deploy needed to validate the code path): took
a real raw burst frame from `3e54236a` (`front_burst_fl_0.jpg`, red-tinted, needed an
autocontrast stretch first), a crude manual crop (no real `guideRegion` alignment, no
multi-frame fusion — everything the production pipeline already does that this quick test
skipped), and ran both methods:
- **SNFEN (neural): bozorth3 match score 7** against the CTO's ink scan (via the newly-
  built `mindtct_client.match_prints()` normalization) — edges out the production
  pipeline's own tuned output on this exact capture (6), with zero training/tuning and a
  worse (cruder) input crop.
- **GBFEN (classical, non-neural): score 4** — worse than both SNFEN and the current
  pipeline.
- Visually, SNFEN's enhanced output shows a genuinely clean, continuous whorl in the real
  pad region — output saved to session scratchpad, not committed.

**Not yet wired into `main.py`'s `_afis_variants`** — the honest next test is running
SNFEN on the pipeline's own properly `guideRegion`-cropped/aligned image (not a manual
crop) before deciding whether to integrate as a real `('pyfing', ...)` max-of-variants
candidate. `pyfing_service` itself is committed but **not deployed** — needs its own
explicit go-ahead like every other backend change.

### pyfing wired in + measured on all 14 real captures — does NOT currently beat the tuned Gabor pipeline
Wired `enhance='pyfing'` into `afis_print.generate()` (`_pyfing_enhance()`: crops to the
mask bbox, grey-fills outside it, routes through pyfing's SNFEN) and added
`('pyfingSnfen', dict(enhance='pyfing'))` to `main.py`'s `_afis_variants` — same
max-of-variants pattern as every other addition, so it can only ever help, never regress.

**Real bug found in the `pyfing` library itself, not our code**: its `Snfen.run()`
enhancement stage, when called with `dpi != 500`, resizes `image`/`mask`/`orientation`
to a scaled size but resizes `ridge_periods` to the *original* unscaled size — a numpy
`dstack` shape mismatch every time (reproduced standalone: a 465px crop at `dpi=300`
crashes with "index 0 has size 800 and index 3 has size 465"). Their own examples always
call it at `dpi=500`, so this path is presumably untested upstream. **Fix**: pre-rescale
our own crop to the ~500dpi-equivalent domain first (same convention as
`mindtct_client._normalize_dpi` — resample toward `_TARGET_PERIOD`), then always call
pyfing with `dpi=500`, sidestepping the buggy internal rescale entirely instead of
working around a third-party bug with try/except.

**Honest measured result, harness run across all 14 real captures (local pyfing, in-
process, no HTTP sidecar needed for this test)**: `pyfingSnfen` **never won a single
capture** by real NFIQ2 — it ran successfully every time (no failures/fallbacks) but
scored lower than the current tuned-Gabor best variant on all 14, by margins from ~4 to
~31 points (e.g. `3e54236a`: pyfing 53 vs. winner 81; `847fa2d3`: pyfing 24 vs. winner 55).
On the fidelity axis (bozorth-vs-ink), pyfing alone averages ~4.8 vs. the full pipeline's
realized ~5.2 — roughly a wash, with one real exception: `7d7d0162` scored bozorth **8**
via pyfing vs. **5** for the variant that actually won on NFIQ2 that capture — a genuine
fidelity edge NFIQ2-only selection missed on that one capture, but not a broad pattern.

**Conclusion**: a generic pretrained SNFEN, with zero fine-tuning on this project's own
data, does not beat a pipeline that's already been through several real-data-driven
tuning passes (Gabor gamma/sigma, frequency-scale floor, orientation smoothing, mask
coverage, coherence fusion) specifically calibrated against these exact captures. This
tracks — pyfing was trained on its own dataset domain, not fingerphoto captures like
ours. The variant stays wired in (harmless, additive, and a no-op in production today
since `pyfing_service` isn't deployed) in case future pyfing versions or fine-tuning
change this, but **do not expect it to move real scores right now** without either (a)
fine-tuning pyfing on this project's own captures, or (b) a materially different crop/
input than what's already been tried here.

### pyfing-then-Gabor hybrid (`enhance='pyfingHybrid'`) — CTO's convention-mismatch hypothesis CONFIRMED, real gain
CTO observation, unprompted and correct: pyfing's own output convention is continuous-
tone with ridges bright on a dark background (near its own internal binary-ish scale),
while this project's entire Gabor pipeline (and every real NFIQ2/bozorth result it's
been tuned against) uses **hard-binarized** black ridges on a white background, gray
only at the feathered mask edge. The pure-`pyfingSnfen` variant's `_pyfing_enhance` was
just doing `255 - enhanced` — a plain intensity invert, not the same transformation as
this pipeline's own binarization. CTO's proposed fix: use pyfing purely to *find ridge
continuity* (its actual trained job — denoise a noisy photo into cleaner ridge
structure), then run that through this project's own tuned Gabor+binarize chain for the
final black/white conversion, rather than inverting pyfing's output directly.

**Built exactly that.** Refactored `_pyfing_enhance` into `_pyfing_denoise()` (returns
pyfing's raw continuous-tone output, still in pyfing's own convention) + a thin invert
wrapper for the existing pure-pyfing path, and added `enhance='pyfingHybrid'`: runs
`_pyfing_denoise()`, then feeds that image through `_normalize` → `_orientation_field`
→ `_gabor_enhance` → the same hard-binarization line every other variant uses. Wired
into `main.py`'s `_afis_variants` as `pyfingHybrid`, max-of-variants alongside
`pyfingSnfen` and everything else.

**Measured on all 14 real captures, hypothesis confirmed real (not just theoretical)**:
- **Hybrid vs. pure pyfing: mean real NFIQ2 jumped 49.4 -> 61.4 (+12)** purely from
  fixing the convention handling — the CTO's observation was pointing at a genuine,
  measurable gap, not a cosmetic one.
- **Hybrid vs. the current best (tuned-Gabor) pipeline**: still trails on 13 of 14
  captures by 10-25 points (e.g. `9bdc9f85`: hybrid 66 vs. winner 83) — the classical
  pipeline's several real-data tuning passes still win on raw quality score. But **it
  now wins outright on one real capture** (`382cc4b2`: 76 vs. the previous winner's 74)
  — a small, real, additive gain now live via max-of-variants.
- **One real fidelity win**: `ccb9c85a` scores bozorth **8** via the hybrid vs. **5**
  for whichever variant wins there on NFIQ2 — a genuine structural-match edge that
  pure-NFIQ2 selection misses, the same pattern seen with plain pyfing on a different
  capture (`7d7d0162`). Reinforces the existing finding that NFIQ2-only selection can
  leave real fidelity gains on the table on specific captures.

**Conclusion**: the convention-mismatch theory was right and fixing it recovered real
score, but doesn't (yet) make pyfing-based enhancement beat this project's own tuned
Gabor chain overall — it's now a genuine, if narrow, additive candidate rather than a
categorically-losing one. Committed (`e3007ff`), not deployed.

## Coherence-enhancing diffusion variant (`enhance='coherenceDiff'`, 2026-07-16) — measured, underperforms as first implemented
Per the CTO's request for a full ridge-continuity optimization scope
(`docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md`), added a classical (no sidecar
dependency) alternative to pyfing: `_coherence_diffusion()` in `afis_print.py`
smooths lengthwise along the local ridge direction (an efficient directional-
kernel approximation of Weickert-style coherence-enhancing diffusion, reusing
`_gabor_enhance`'s own per-orientation-bank architecture rather than a full
iterative PDE solve), then re-estimates orientation on the smoothed image and
runs the existing tuned Gabor bank + binarization on top — same denoise-then-
Gabor pattern as `pyfingHybrid`. Wired into `main.py`'s `_afis_variants` as
`coherenceDiff`, max-of-variants.

**Measured on all 14 real captures**: mean real NFIQ2 **55.1** — worse than the
tuned Gabor pipeline (74.4) on every single capture (never won selection), and
also worse than `pyfingHybrid` (61.4), though better than pure `pyfingSnfen`
(49.4). Bozorth-vs-ink mean 4.64, roughly a wash vs. baseline, with one notable
exception: `382cc4b2` scored bozorth **7** via coherenceDiff vs. **5** for the
capture's actual NFIQ2-selected winner — another real instance of NFIQ2-only
selection missing a fidelity gain on a specific capture (same pattern as the
`pyfingHybrid`/`ccb9c85a` case and the earlier plain-`pyfing`/`7d7d0162` case).

**Likely why it underperforms as shipped**: the smoothing parameters
(`_COH_DIFF_SIGMA=1.2`, `_COH_DIFF_ORIENT_RATIO=2.5`) were a first guess, not
run through the same real-data tuning sweep the Gabor gamma/sigma/frequency-
floor parameters went through earlier this session (see "First tuning pass").
An extra smoothing pass ahead of Gabor plausibly costs high-frequency ridge
energy that NFIQ2 rewards (consistent with this project's own "NFIQ2 rewards
high-frequency ridge-like texture" finding) unless the along-ridge elongation
is tuned much more conservatively. Left wired in as-is (harmless, additive, a
real fidelity win on one real capture) but **not tuned further without a real
reason to prioritize it over the higher-value untested items in the scope
doc** (cross-polarization, multi-camera burst, RAW capture, physical distance
meshing) — a parameter sweep here would cost real iteration time for a
technique that's currently the weakest of the three denoise-pre-pass variants
tried this session (Gabor-only > pyfingHybrid > coherenceDiff > pyfingSnfen on
mean NFIQ2). Committed (`25b6b44`), not deployed.

## NNS-then-Gabor hybrid variant (`enhance='nnsHybrid'`, 2026-07-16) — CTO's own "combine both pipelines" idea, measured underperforms
CTO request: after seeing this project's OTHER, older enhancement model side
by side with the AFIS template on the same real capture (`382cc4b2`:
`enhancement_pipeline.enhance()`'s NNS output scored real NFIQ2 39, visibly
smoother/more continuous ridge-wise than the AFIS binarized template's 76),
asked for a hybrid combining the NNS pipeline's ridge smoothness/continuity
with the AFIS template's NFIQ2 quality — the same denoise-then-Gabor pattern
already used for `pyfingHybrid`/`coherenceDiff`, applied to this project's own
second enhancement model instead of an external one.

**Built exactly that.** `_nns_denoise()` in `afis_print.py` crops to the mask
bbox, grey-fills outside it, and runs `enhancement_pipeline.enhance()` (CLAHE
+ multi-scale Gabor + trained `FingerprintUNet`) as a denoise pre-pass, then
feeds the result through this module's own `_normalize` → `_orientation_field`
→ `_gabor_enhance` → hard-binarization chain — same pattern as the other two
hybrids. Unlike pyfing, NNS's own output convention already matches this
project's (ridges dark, background light — confirmed via
`enhancement_pipeline.ink_scanner_style`'s docstring and `_postprocess`'s
contrast-stretch), so no invert was needed. Wired into `main.py`'s
`_afis_variants` as `nnsHybrid`, max-of-variants. Committed (`3a8b3f4`).

**Measured on all 14 real captures**: mean real NFIQ2 **50.1** — never won
selection on any capture (one near-tie: `847fa2d3` at 55 vs. the winner's own
55), worse than `coherenceDiff` (55.1) and `pyfingHybrid` (61.4), roughly on
par with pure `pyfingSnfen` (49.4) — the worst-performing of the three
denoise-pre-pass hybrids tried this session (Gabor-only > pyfingHybrid >
coherenceDiff > nnsHybrid ≈ pyfingSnfen on mean NFIQ2). Bozorth-vs-ink mean
4.57, a wash vs. baseline, no standout fidelity win this time (best deltas
were only +1: `ccb9c85a` 6 vs. 5, `382cc4b2` 6 vs. 5).

**Conclusion**: the NNS pipeline's smoother continuous-tone output does NOT
translate into a better post-Gabor-binarized result — likely because its own
enhancement stages (CLAHE + multi-scale Gabor + `FingerprintUNet`, tuned
against a completely different objective — the ResNet18 proxy's continuous-
tone scoring, not real NFIQ2 on a binarized template) already discard or
reshape ridge information in a way that doesn't compose well with a SECOND
independent Gabor pass on top. This is the same lesson as `coherenceDiff`: an
extra denoise/smoothing stage ahead of this project's own tuned Gabor bank
is not automatically additive just because the pre-pass looks visually
smoother — it has to be measured, not assumed. Left wired in as a harmless,
additive, max-of-variants candidate; not prioritized for further tuning over
the untested capture-side items in `docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md`.

## Background contamination in AFIS masking — real fix, 2026-07-15
CTO flagged real background contamination degrading scoring, and named the exact prior
solution: a trained fingerprint segmentation model + flash captures as the finger-vs-
background signal. Investigation confirmed both **already exist and are already validated**
in this codebase — `sfm_pipeline._segment_via_flash_diff` (flash-minus-ambient
differencing; the torch falls off with distance², so it isolates near-camera surfaces
almost regardless of background brightness/texture) and the trained U-Net
(`_get_thumb_seg_session`/`thumb_seg_unet.onnx`, ~1.94M params, trained on flash-diff
pseudo-labels) — but **both were completely bypassed for `front_only_v1`**: `guide_mask`
(the static, purely-geometric `guideRegion` silhouette) short-circuited straight past any
content-aware check whenever present (`afis_print.py`'s old `if guide_mask is not None:
mask = guide_mask` — zero per-capture awareness of what's actually in the frame).

**Fix (commit `84ea9c6`)**: `afis_print.py`'s `generate()` now intersects the guide mask
with a flash-diff mask (primary — `ambient_burst`/`flash_burst` frames are already
downloaded for `front_only_v1` via `_download_front_burst`, confirmed reaching every
variant in `main.py`'s `_afis_variants` loop, not just the `deepFuse` one) or falls back to
the U-Net mask (when no usable ambient/flash pair exists). New `afisMask` values:
`'guide+flashdiff'` / `'guide+unet'`, alongside the existing `'guide'` when neither
refinement is available. **Can only ever shrink the mask toward the guide's own bounds**
(intersection — never introduces new background outside the guide) **and falls back to the
guide mask alone if a refinement wipes out >65% of it** (likely a failed/misfiring
segmentation, not evidence the guide itself is wrong) — cannot regress a previously-good
capture, same discipline as every other change in this pipeline.

**Verified against a real capture (`3e54236a`)**: the guide mask was already well-aligned to
the visible pad on this specific capture — refinement kept 96% of its area, trimming only
thin slivers at the top/bottom edges where the guide oval slightly overshoots the
ridge-bearing pad (confirmed via a visual overlay: red = old guide boundary, green =
refined boundary, both sitting on real finger skin, no background in either). **The severe
background contamination visible in this session's earlier pyfing test images was from my
own crude manual crop for that experiment, not the production pipeline's real masking** —
worth being precise about, since they look superficially similar but have different causes.
Re-ran the pyfing SNFEN test on the properly guide+flashdiff-masked crop (clean, no
background at all): **bozorth3 match score unchanged at 7** — the fix didn't move this
specific test's number (mindtct's own minutiae extraction apparently already discounted the
plain wall texture in the cruder crop), but it's still the right, principled fix per the
CTO's ask, and matters more for captures with textured/patterned backgrounds (wood-plank
desks, patterned wallpaper — the exact cases `_segment_via_flash_diff`'s own docstring
already documents defeating brightness-only thresholding).

**Not yet deployed** — needs its own explicit go-ahead like every other backend change.

## Thumb orientation in diagnostic images — display-only, no pipeline bug
CTO noted raw thumb images shown in-session were sideways and asked for upright framing
going forward (explicitly cosmetic, not a quality-metric concern). Checked: the actual
production AFIS output (`superprint_afis.png`) is **already rotated upright** correctly via
`afis_print.py`'s `_upright_from_tip` (uses `guideRegion.tipAngleDeg` — the app knows
exactly which way the tip points on the portrait screen — deterministic, not a PCA guess).
The sideways images were specifically **raw burst frames** (e.g. `front_burst_fl_0.jpg`)
downloaded and displayed directly for the pyfing experiment, which are unrotated sensor-
orientation JPEGs never passed through the pipeline's own upright-rotation step. No pipeline
change needed or made — going forward, rotate raw/diagnostic frames upright before display
whenever showing them for review.

## Real NFIQ2 + bozorth3 now run LOCALLY in-sandbox (2026-07-16) — major unlock
Previously all real-NFIQ2 validation needed a deploy + on-device capture (the Cloud Run
sidecar's `*.run.app` host is unreachable from the sandbox). Both ground-truth tools now
build and run locally:
- **Real NIST NFIQ2 2.3.0** built from source: `git clone --recursive
  https://github.com/usnistgov/NFIQ2` (github.com clone works; only release-asset
  downloads 403), then the CMake superbuild — needed `apt-get install libdb-dev
  libdb++-dev libsqlite3-dev libssl-dev libjpeg-dev libpng-dev libtiff-dev
  libopenjp2-7-dev libhwloc-dev` for its `libbiomeval` dependency (Berkeley DB + OpenJPEG
  were the two blockers). Binary at `/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2`,
  model at `.../share/nist_plain_tir-ink.txt`. CLI: `nfiq2 -m MODEL -i IMG.png -F` prints
  the bare score. **Calibrated**: resize to 500×500 LANCZOS first (exactly as
  `nfiq2_client` does) → exact match to production's recorded `nfiq2Score=72` on `3e54236a`.
- **NBIS mindtct/bozorth3**: already vendored (`functions/nfiq2_service/vendor/nbis/`),
  build copy in scratchpad.
- The proxy ONNX (`nfiq_resnet18.onnx`) and `thumb_seg_unet.onnx` are both pullable from
  Storage `models/` (googleapis reachable) → the U-Net mask path and the exact production
  proxy scorer also run locally.
- Harness (`scratchpad/harness.py`, not committed): runs the real `afis_print.generate()`
  variants on all 14 real front captures, scores each with real NFIQ2 + bozorth-vs-ink.

### CRITICAL measurement finding — do NOT optimize blindly to NFIQ2
- **Real NFIQ2 is FOOLABLE on our prints.** A visually-garbage front capture (`5aa18155`,
  broken/choppy discontinuous ridges, vertical crease artifacts, no coherent whorl) scored
  real NFIQ2 **77**. NFIQ2 rewards high-frequency ridge-*like* texture regardless of whether
  it's a faithful print. So NFIQ2 is a **floor/sanity check, NOT the optimization target** —
  selecting the "best" variant purely by NFIQ2 will happily pick a high-scoring garbage
  render. (This also explains the proxy's total unreliability — proxy 76 → real NFIQ2 9 in
  production history.)
- **The single ink scan is too weak to be a fidelity target.** bozorth3-vs-ink is only
  valid on the CTO's OWN captures (same finger: uid `Sgsk0mvnECac` = `3e54236a`,
  `c34911b5`, `382cc4b2`, `722ae3b0`). On those it sits at **4–5** — and *different* people's
  captures score bozorth 4–7 against the same ink scan too. So at this quality level bozorth
  cannot distinguish same-finger from different-finger; absolute values 4–7 are noise floor.
  The ink scan's own low quality ("best I could get" — blur, low contrast) is the limiter.
- **Consequence: there is no reliable *numeric* fidelity target yet.** "Optimize until the
  match score is high" is not honestly achievable with current ground truth. What IS
  reliable: **visual ridge continuity/coverage**, plus the tools as floors. To unlock real
  fidelity optimization we need a **better ground-truth reference** — a proper ≥500-DPI
  scanner/ink-card capture of the CTO's finger (ideally a few fingers), which is exactly the
  `ml/mac3d_enhance/DATA_SPEC.md` gap.
- **Root-cause finding (most important):** on the CTO's own captures the static `guideRegion`
  oval is sometimes **MIS-CENTERED off the ridge-dense pad** — on `3e54236a` the whorl core
  sits to the *right*, largely outside the guide, while the guide covers the fainter left
  pad (confirmed via a red=guide/green=detected-pad overlay). This mis-alignment — not just
  coverage size — is a likely real reason match quality on the CTO's own finger is mediocre.
  Content-aware pad detection (flash-diff/U-Net) re-centers onto the actual dense-ridge
  region; longer-term the on-screen capture guide placement itself should be improved so the
  pad's ridge core lands inside the guide.

### Two CTO-reported print defects fixed (commit `906c0f8`, NOT deployed)
- **Whole-pad coverage** (`_MASK_COVER_DILATE=1.3` in `afis_print.py`): the mask now expands
  from the detected real pad (flash-diff/U-Net) toward the pad tip the tight guide oval cut
  off, clipped to a dilated guide so it can't grab background/hand. Set to 1.3 not higher —
  a 1.6 sweep measurably hurt a well-placed capture (`c34911b5` local NFIQ2 79→68) by
  reaching into poor-contact periphery. Note: the "choppy top" seen on some expanded prints
  is real poor-contact ridge signal at the pad top (a *capture* issue), not a masking bug.
- **Flash specular smudge** (coherence-fusion variants `fuseMaxc`/`fuseSoft`/`deepMaxc` added
  to `main.py`'s `_afis_variants`): `deepFuse` hardcoded flat `avg` fusion, which keeps a
  blown-out flash centre half-bright and washes out the ridges there. The coherence modes
  (already in `_fuse_flash_ambient`, never wired as variants) per-region take whichever
  exposure resolves ridges best, winning the specular centre back from the ambient exposure.
  Confirmed on `3e54236a`: maxc superprint is a clean, fully-covered whorl with the centre
  smudge gone (real NFIQ2 57→81, visually verified). Coherence-fusion variants win on 6 of
  14 captures; max-of-variants, so purely additive. **This is the more solid of the two
  fixes** (verified visually + wins as a real variant), vs. coverage which the noisy metrics
  can't confirm.

## CRITICAL: production capture pipeline was hanging forever — found + fixed (2026-07-16)
First real device test of the new APK (capture `9efb7d1e`, 18:51 UTC) got stuck at
`status: "enhancing"` and never completed — confirmed via Cloud Run logs still
running 2+ hours later. Root cause: `processenhanceandscore`'s Cloud Run service has
a **2-minute request timeout** (`run_v2.ServicesClient` config check), but the real
log trace showed the gap between adjacent `_afis_variants` entries `deepFuse`
(18:54:48) and `deepMaxc` (19:10:08) was **15 minutes 20 seconds** — `deepFuse`/
`deepMaxc`/`deepSoft` each independently redid the expensive ambient/flash burst ECC
alignment (`_stack_face_on`) from scratch, even though all three share identical
inputs and differ only in the final (cheap) fusion mode. This capture's flash frames
scored unusually low sharpness (Laplacian ~60-73 vs. ambient ~3100-3345, a 40-50x
gap) — ECC likely struggled to converge, and that cost got paid 3x instead of once.
This is pre-existing architecture from an earlier session's commit (`906c0f8`), not
something introduced by this session's pyfing/coherence/nns additions — but this was
apparently the first real capture to actually exercise `deepMaxc` in production,
exposing it. **This was a full outage**: every real capture reaching the fuse family
(nearly all of them, since ambient+flash bursts are always preserved) would hang
forever and never reach `status: "scored"`.

**Fixed**: `afis_print.generate()` gained a `stack_cache` parameter (request-scoped
dict, never a module-level/global cache to avoid stale reuse across different
requests on a warm Cloud Run instance) — `main.py`'s variant loop creates one fresh
`{}` per request and passes it to every `generate()` call, so `_stack_face_on(ab)`/
`_stack_face_on(fb)` compute once and get reused across `deepFuse`/`deepMaxc`/
`deepSoft` instead of 3x. Also added a 70s wall-clock budget on the whole
`_afis_variants` loop as an independent safety net (stops trying further variants
once exceeded, scores with whatever's already been produced — same as a variant
self-skipping, can't make the result worse). **Verified locally**: `deepMaxc` on a
real capture dropped from 15.9s to 4.7s reusing the cache (same real NFIQ2 score,
81); full 14-capture regression sweep afterward matched the pre-fix baseline exactly
(mean 74.4, same winning variant per capture) — zero regression.

**Also raised the Cloud Run request timeout** 120s → 300s (`main.py`'s
`@https_fn.on_call(timeout_sec=...)` — the actual source of truth `firebase deploy`
applies each time, not a raw Cloud Run API edit which would be silently reverted on
the next deploy) as a safety margin — 120s left almost no headroom even for a normal
capture once cold model downloads (~15-55s per real logs) are counted, and the 70s
variant budget already bounds runaway work internally so the higher ceiling costs
nothing by itself. **Deployed** (both fixes together, `firebase deploy --only
functions:python-pipeline`).

**Still needed, not yet done**: get a real device to re-test and confirm a capture
now reaches `status: "scored"` — this fix is deployed but not yet confirmed against
a real capture. Also unresolved: this same capture's `secondaryCameras`/
`distanceStage2` debug fields were completely absent (not just empty) despite the
Dart code being structurally correct and the backend trigger firing — root cause not
pinned down without device-side logs; asked the CTO whether an error banner appeared
on screen during/after that capture.

## Capture-side scope items 2-4 built, NOT YET DEVICE-TESTED (2026-07-16)
Per `docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md` + the CTO's "let's go according
to your recommendations": items #1 (validate the `906c0f8` deploy on a real
device) and #2 (cross-polarization test) both need the CTO to physically act, so
built the three remaining engineering items in parallel, all **unverified beyond
`py_compile`/manual brace-balance checks — no Dart/Kotlin toolchain in this
sandbox, no real device.** Do not treat any of these as working until an APK build
+ real capture confirms them.

- **Secondary-camera burst + EV tuning** (`front_capture_controller.dart`
  ~lines 765-812): each IR/ultrawide secondary camera now fires a 3-shot burst
  (`_secondaryBurstCount`) instead of one still, with `setExposureOffset(-1.0)`
  applied first (the same anti-blowout EV step already validated for the main
  flash burst — confirmed safe: only `setExposureMode()`, never called here,
  triggers the Camera2-interop/torch conflict). `secondaryCameras` docs now
  carry a `paths: [...]` list (was a single `path`). `main.py`'s secondary-camera
  loop (~line 751) picks the sharpest via the same Laplacian-variance pattern as
  `_best_frame_from_paths`, backward-compatible with the old single-`path` schema.
- **Physical distance-guided capture, Phase 0** (`front_capture_controller.dart`:
  new `_waitForNearDistanceZone()`/`_captureDistanceBurst()` methods, called
  after the secondary-camera block and before the `processEnhanceAndScore`
  trigger): reuses the existing `_scoreRoi` coverage signal and `_coverageMax`
  threshold to detect a meaningfully closer distance zone (6s bounded timeout,
  never blocks the primary result if the user doesn't move), re-focuses, fires
  a 3-shot alternating ambient/flash burst tagged `distanceZone: 'near'`. This
  is a self-contained bonus stage, NOT a re-entry into the main hold/burst state
  machine — deliberately avoids touching the already-tuned primary capture-
  quality logic. `main.py` scores the sharpest stage-2 frame as one more
  independent single-frame candidate (`afisSource: 'distanceStage2'`) — no
  fusion math, per `docs/MULTI_DISTANCE_MESH_SCOPE.md`'s own Phase 0 design.
- **RAW/DNG capability check, Phase 0** (`MainActivity.kt`: new
  `MethodChannel('clearbridge/cameraCapabilities')` reading each camera's
  `CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES` for `RAW_SENSOR`
  support — a read-only query, no capture): result cached and attached to the
  capture's own Firestore doc as `rawSensorSupport`. **Deliberately NOT a
  revived diagnostic screen** — the prior one was explicitly removed (commit
  `4a832c0`) as "test-only tooling with no place in the current build"; this is
  silent, no new UI. Purely informational for now — answers "does any real
  device support RAW_SENSOR" before committing to the much bigger native
  RAW-capture platform-channel lift.

**All three need a real APK build + real device capture before trusting them.**
Watch for: the distance-stage-2 timeout actually resolving (not hanging the
upload flow), the secondary-camera burst not exceeding per-camera session
limits on real hardware, and whether `rawSensorSupport` ever comes back true on
any device in the fleet (if not, the RAW/DNG item is dead on arrival, per the
scope doc's own Phase 0 gate).

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
- **GitHub Actions artifact downloads are ALSO blocked from this sandbox** (confirmed
  2026-07-16): the GitHub API's artifact download endpoint redirects to a signed Azure
  Blob Storage URL (`*.blob.core.windows.net`), which isn't allowlisted by this session's
  egress policy — `curl` gets a 403 at the CONNECT step (`/root/.ccr/README.md`: "policy
  denial... do not retry or route around it"). Same class of restriction as the GHCR/
  dl.google.com blocks above. Even when a CI build succeeds and produces an APK artifact
  (confirmed working: `build.yml` on `push` builds `clearbridge-beta-apk` +
  `capture-harness-apk` successfully), **the artifact itself cannot be fetched into this
  sandbox to relay to the user** — the user must download it directly from the GitHub
  Actions run page in their own browser (Actions tab → the run → Artifacts section at the
  bottom), which isn't subject to this sandbox's egress policy.
