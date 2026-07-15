# Scope: mindtct + bozorth3 ground-truth minutiae matching

## Context

CTO provided a real inked ground-truth print of their own thumb (photographed,
then uploaded to Firebase Storage at `ground_truth/cto_thumb_ink_scan_2026-07-15.jpg`,
`clearbridge-dc699.firebasestorage.app`) specifically to validate the AFIS
pipeline against, rather than continuing to optimize blind against NFIQ2/proxy
scores alone.

**Why this is a different question from everything else in this project's
NFIQ2 work:** NFIQ2 and the ResNet18 proxy both measure image *quality* — does
this look like a scannable, well-formed print. Neither measures *fidelity* —
does the pipeline's output actually preserve the true ridge/minutiae pattern
of the real finger, or does it produce something quality-scanner-friendly but
structurally wrong (merged ridges, fabricated detail, misplaced core). A real
ground-truth image is the only way to check fidelity, and a proper minutiae
match is the only way to check it rigorously rather than by eye.

## The tools

NIST's classic NBIS (NIST Biometric Image Software) suite — a *different*,
older NIST project from NFIQ2 (which this codebase already integrates) —
includes the standard tools for exactly this:
- **`mindtct`** — minutiae detector. Takes a fingerprint image, extracts
  minutiae (ridge endings, bifurcations) as x/y/angle/quality, writes a `.xyt`
  file (plus quality/orientation/low-contrast maps as side artifacts).
- **`bozorth3`** — minutiae matcher. Takes two `.xyt` files (probe + gallery)
  and produces a match score. Rotation/translation invariant — no manual
  image alignment needed, which matters here since the ink print and the
  app's digital capture are at different scale, rotation, and framing.

## Honest uncertainty up front (verify before committing to this plan)

This project's own `functions/nfiq2_service/Dockerfile` already documents a
lesson worth repeating here: **its NFIQ2 `.deb` download URL was never
build-tested end-to-end from this sandbox** (network egress here can't reach
external hosts), and `app.py`'s own docstring admits the CLI invocation syntax
was "best-effort, not confirmed." Do the same honest check for NBIS before
assuming this is a clean drop-in:
1. **Confirm a real, current NBIS source is still obtainable.** NBIS classic
   is older and distributed differently from NFIQ2 (which has its own active
   `usnistgov/NFIQ2` GitHub with release binaries) — verify the actual current
   download path (NIST's own site historically, possibly a maintained mirror)
   before writing Dockerfile steps around an assumed URL.
2. **NBIS is a source build, not a package install.** Unlike NFIQ2's `apt
   install <deb>`, NBIS ships as C source with its own `setup.sh` /
   `make config` / `make it` build flow — more moving parts, no guarantee it
   builds cleanly on a modern Ubuntu base without patching. Budget real
   engineering time for this, not a quick add.
3. **`bozorth3` match scores have no single universal "same finger"
   threshold.** Score interpretation is typically calibrated per deployment
   (a common rule-of-thumb cutoff exists in NBIS demos/literature, but it is
   not a rigorously fixed constant) — don't hardcode an assumed pass/fail
   number without checking NBIS's own documentation and ideally validating
   against a few known-same and known-different print pairs first.

## Proposed architecture — extend the existing NFIQ2 sidecar, don't duplicate it

`functions/nfiq2_service/` already exists as exactly the right kind of
service for this: a Cloud Run sidecar wrapping a NIST CLI binary behind Flask,
used because Firebase's buildpack-based Functions deploy has no Dockerfile
hook of its own. Rather than standing up a second Cloud Run service (more
infra, more auth wiring, more cost), **extend this same service and
Dockerfile** to also build NBIS and expose two more endpoints:

- `POST /minutiae` — wraps `mindtct`. Accepts an image, returns the extracted
  minutiae (as the raw `.xyt` content or parsed JSON).
- `POST /match` — wraps `bozorth3`. Accepts two minutiae sets (or two images,
  running `mindtct` internally on each first), returns the match score.

Follow the exact pattern already established in `app.py`'s `/score` endpoint:
temp-file the input, subprocess out to the CLI, parse permissively, never
crash the endpoint, log raw output for the first real run so invocation
syntax can be corrected if this sandbox's assumptions about NBIS's CLI turn
out wrong (same honesty `/score` already models).

**Client side**: a new `mindtct_client.py` alongside the existing
`nfiq2_client.py` in `functions/processEnhanceAndScore/`, same ID-token
service-to-service auth pattern already proven there.

## Workflow for this specific validation (one-off R&D, not production pipeline)

1. Preprocess the ground-truth ink scan: it's a phone photo of paper, not a
   proper flatbed scan — deskew, denoise, and contrast-normalize before
   feeding it to `mindtct` (mindtct is tuned for scanner-like grayscale
   fingerprint images at ~500 DPI; raw paper-photo noise/lighting will hurt
   minutiae quality same as it would for any scanner-calibrated tool).
2. Run `mindtct` on the cleaned-up ground truth -> ground-truth `.xyt`.
3. Run `mindtct` on the pipeline's own output. Try BOTH representations —
   the binarized `superprint_afis.png` and the continuous-tone
   `enhanced_flat.jpg` — since it's not yet known which one `mindtct` (built
   for natural scanner images) extracts cleaner minutiae from. This is the
   same "don't assume, check both" discipline this project already learned
   the hard way with NFIQ2 and the binarized-vs-continuous-tone question.
4. Run `bozorth3` between the ground-truth minutiae and the pipeline output's
   minutiae -> a real match score.
5. **Expected to be a partial match, not a full one.** The app's on-screen
   guide deliberately frames only the top portion of the pad (shrunk earlier
   to avoid the DIP crease — see CLAUDE.md), while the ink scan shows the
   whole pad tip-to-base. `bozorth3` is explicitly designed to handle
   partial-print matching (this is normal in real AFIS use), so this isn't a
   blocker — but don't expect or chase a "full" match score, and don't treat
   a partial-but-positive match as a failure.
6. This also finally answers a standing open question from the mask-size
   discussion: does the app's narrow top-half guide window reliably capture
   the same core region visible in the full ink print, or does it risk
   framing just to the side of it? A real minutiae match against ground
   truth is a much better way to answer that than eyeballing two images.

## What this is NOT (scope boundaries)

- Not a production feature. This is an R&D validation tool for this specific
  ground-truth comparison, run manually against a handful of real captures —
  not wired into `main.py`'s per-capture scoring flow.
- Not a replacement for NFIQ2. Quality (NFIQ2) and fidelity (minutiae match)
  are answering different questions; keep both.
- Not started yet. No code written, no Dockerfile changes made — scope only,
  per request. The ground-truth image itself IS already saved (Firebase
  Storage, see Context above) so it's ready whenever this is built.

## Recommended first step if this gets picked up

Verify NBIS's current real source/download path and confirm it still builds
on a modern Ubuntu base in isolation (a throwaway local Docker build, same
kind of build-time sanity check the existing Dockerfile already does with
`RUN nfiq2 --version || nfiq2 -v || true`) before writing the full sidecar
integration — cheaper to discover a build problem early than after wiring up
the Flask endpoints and client code around it.
