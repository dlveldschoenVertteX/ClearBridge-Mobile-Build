# Scope: ridge-continuity distortion — full optimization pass (2026-07-16)

## Context

After deploying the whole-pad-coverage expansion + coherence flash/ambient fusion
fixes (commit `906c0f8`) and measuring pyfing/pyfingHybrid (confirmed additive but
narrow — see CLAUDE.md), the CTO flagged that **real distortion on ridge
continuity still remains** in the final print and asked for a full scope of
further optimization: deeper multi-camera testing, focus/distance capture meshed
into one superprint, and any other "think outside the box" recommendations, web
research explicitly invited.

This doc reconciles what's already built, what's already scoped-but-unbuilt in
this repo's own prior docs (nothing here duplicates existing work), and what this
session's web research surfaced as genuinely new levers. Everything is prioritized
by cost-to-test vs. expected gain, following this project's standing discipline:
never trust a change until it's measured against real NFIQ2 + real bozorth-vs-ink
(the local harness pattern, `scratchpad/harness.py`, or a real device deploy),
same max-of-variants pattern as every prior addition.

**Two existing docs already cover large parts of this and must not be
duplicated, only extended:**
- `docs/CAPTURE_OPTIMIZATION_SCOPE.md` — camera selection (Lever A, **built**),
  focus/distance/macro (Lever B, **partially built**: only same-distance burst
  stacking, no true distance bracketing or macro lens tested), RAW/AI-off capture
  (Lever C, **not built at all**), IR illumination (Lever D, **built**).
- `docs/MULTI_DISTANCE_MESH_SCOPE.md` — already fully designs the "focus+distance
  meshed into one superprint" idea, including a concrete Phase 0 (capture-only, no
  fusion) before the harder frequency-normalize-then-blend fusion math. **Scoped
  in detail, not yet built at all.**

**One hard precedent governs every "meshing multiple captures" idea below**:
`ml/mac3d_enhance/SMALL_ROLL_SCOPE.md` tested continuous small-baseline
compositing across poses and got a real NO-GO — genuine edge-coherence gains did
not survive because sub-pixel discontinuities at the composite JOINS broke ridge
continuity. Any fusion here must stay restricted to the already-validated pattern
(ECC-align same/near pose → per-pixel sharpness-weighted blend), never naive
geometric stitching across substantially different poses or distances.

## Diagnosis — plausible causes of persistent ridge-continuity distortion

| Hypothesis | Plausibility | Cheap test |
|---|---|---|
| **JPEG 8×8 DCT block artifacts** interfering near-resonantly with `_TARGET_PERIOD=9.0`px | Real risk — JPEG's block grid (8px) sits almost exactly on this project's own ridge-period target (9px) | Capture at max JPEG quality if the `camera` plugin exposes any control; diff ridge continuity / real NFIQ2 |
| Residual **sub-pixel motion blur** past the existing gyro-steadiness gate | Plausible, partially already mitigated | Compare Laplacian sharpness variance within a single burst |
| **Macro-range lens distortion** warping ridge geometry | Plausible, pure-software fix available | OpenCV camera calibration + `cv2.undistort` before masking |
| **Single fixed focal plane vs. pad curvature** | Confirmed motivation already written up in `MULTI_DISTANCE_MESH_SCOPE.md` | Addressed by item 3 below |

## Prioritized recommendations

### 1. Cross-polarization — physical fix for flash specular smudge
Distinct from the existing **software** coherence-fusion band-aid (`fuseMaxc`/
`deepMaxc`, which recovers detail *after* a flash blowout already happened).
Standard macro-photography technique: polarizing film over the flash LED + a
second film over the lens, rotated 90°, blocks specular reflection at the
source. **Testable with ~$2 of film and zero engineering** before any code
change — highest value-per-effort item in this scope.

### 2. Deepen multi-camera testing (BUILT 2026-07-16, not device-tested)
Today: each secondary back camera (IR/night-vision, ultrawide) gets exactly one
torch-lit still, no burst, no per-camera exposure tuning
(`clearbridge_beta/lib/front_capture_controller.dart` ~lines 732–797), scored
independently in `main.py` (~lines 725–757) — never fused with the primary
camera (different sensors rarely share a clean homography at macro range; stay
honest about that limit). Extend to a short burst per secondary camera + per-
camera EV tuning; feed each camera's sharpest-of-burst frame in as its own
candidate (already the pattern, just better raw material).

### 3. Focus/distance capture meshed into one superprint (Phase 0 BUILT 2026-07-16, not device-tested)
Build `docs/MULTI_DISTANCE_MESH_SCOPE.md`'s own **Phase 0 first** (fully
designed, not started): capture at 2 distances, feed each distance's sharpest
frame in as an independent candidate — no fusion math yet.

**Resolved engineering constraint**: true Camera2 `LENS_FOCUS_DISTANCE` control
needs Camera2 interop, and this codebase already found
(`packages/mac_capture/lib/src/camera_service.dart` ~lines 318–343) that
`setExposureMode()`'s Camera2 interop **persistently blocks `enableTorch()`** —
manual lens-distance control would very likely hit the same conflict, and torch
is core to this pipeline's best variants. **Do not pursue Camera2
`LENS_FOCUS_DISTANCE`.** Instead build the *physical* distance variation
`MULTI_DISTANCE_MESH_SCOPE.md` proposes, reusing
`OscillatingCaptureController`'s hold/transition state machine retargeted to
distance, relying on continuous AF to re-acquire focus naturally. Zero Camera2
risk, zero new native code.

### 4. RAW/DNG capture (Lever C — Phase 0 capability check BUILT 2026-07-16, not device-tested)
No `imageFormatGroup`/quality override exists anywhere in this codebase; the
`camera` plugin's `takePicture()` stills are always compressed JPEG regardless.
True RAW needs Camera2's `RAW_SENSOR` + `DngCreator` directly — a native Android
platform channel, the largest lift in this scope.
- **Phase 0**: extend the existing camera-probe diagnostic screen
  (`docs/CAPTURE_OPTIMIZATION_SCOPE.md` Phase 0) to log
  `CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES` — if no target device
  supports `RAW_SENSOR`, shelve this item.
- **Phase 1** (only if supported): native platform channel, gated behind the
  capability check.
- **Phase 2**: teach the backend to consume a demosaiced-but-unsharpened frame.

### 5. Coherence-enhancing diffusion — new classical enhancement variant (BUILT + MEASURED this session)
Real, established, fingerprint-ridge-continuity-specific technique: anisotropic
diffusion that smooths *along* the local ridge direction (repairing small
discontinuities) while barely touching the across-ridge direction — distinct
from and complementary to Gabor's frequency-selective response. Confirmed via
web research as a real, cited fingerprint-enhancement family (Weickert-style
coherence-enhancing diffusion, oriented diffusion filtering), not previously
tried in this codebase.

Implemented as `_coherence_diffusion()` in `afis_print.py` (an efficient
directional-kernel approximation reusing the same per-orientation-bank
architecture as `_gabor_enhance`, rather than a full iterative PDE solve) and
wired as `enhance='coherenceDiff'`: smooths along ridge direction first, then
re-estimates orientation on the smoothed image and runs the existing tuned
Gabor bank + hard binarization on top — same denoise-then-Gabor pattern as
`pyfingHybrid`. Added to `main.py`'s `_afis_variants` as `('coherenceDiff', ...)`,
max-of-variants, purely additive.

**Measured across all 14 real captures**: mean real NFIQ2 **55.1**, below the
current best (tuned Gabor pipeline, 74.4) on every capture and below
`pyfingHybrid` (61.4), though above pure `pyfingSnfen` (49.4). Bozorth-vs-ink
roughly a wash (4.64 vs. the pipeline's realized 5.3), with one real fidelity
win (`382cc4b2`: 7 vs. the NFIQ2-selected winner's 5). Likely cause: the
smoothing parameters were a first guess, not tuned against real data the way
Gabor's own gamma/sigma/frequency-floor were — a real parameter sweep could
improve this, but isn't prioritized above the untested capture-side items
above (1–4) given current evidence. Full details in CLAUDE.md. Left wired in
as a harmless, additive, max-of-variants candidate.

### 6. Stretch ideas (flagged, not prioritized)
- **Pixel-shift / handheld multi-frame super-resolution** — conceptually close
  to what `stack`/`focusStack` already approximate; true pixel-shift needs OIS
  control this phone class likely doesn't expose via the `camera` plugin.
- **Photometric stereo / multi-light ridge relief** — genuinely interesting
  (ridge relief is a true 3D surface feature) but needs multiple controllable
  light sources or precise tilt-tracked multi-shot capture. Research spike only.
- **GAN/diffusion ridge restoration** — same category as `pyfing`/`pyfingHybrid`,
  already measured (narrow, additive). Not a new direction.

## Files involved
- Item 1: hardware only, no files.
- Item 2: `clearbridge_beta/lib/front_capture_controller.dart` (secondary-camera
  burst + EV), `functions/processEnhanceAndScore/main.py` (~line 725).
- Item 3: `clearbridge_beta/lib/oscillating_capture_controller.dart` (pattern to
  reuse), `clearbridge_beta/lib/front_capture_controller.dart`,
  `functions/processEnhanceAndScore/afis_print.py`.
- Item 4: new native Android platform channel, `front_capture_controller.dart`,
  `afis_print.py`/`main.py`.
- Item 5: `functions/processEnhanceAndScore/afis_print.py`
  (`_coherence_diffusion`), `functions/processEnhanceAndScore/main.py`
  (`_afis_variants`). Done.

## Verification
Software-only items (5, and the undistortion/JPEG-quality tests) — reuse
`scratchpad/harness.py`'s pattern: sweep all 14 real captures, compare real
local NFIQ2 + bozorth-vs-ink against the current best variant. Capture-side
items (2, 3, 4) need a real device build + capture, validated against real
`nfiq2Score`/`afisMask`/`afisEnhance` in the resulting Firestore doc. Item 1 is
validated by the CTO directly (visible specular-smudge reduction, side by side).
