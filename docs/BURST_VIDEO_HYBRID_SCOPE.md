# Scope: burst + video hybrid capture

## Context

CTO handoff spec proposed a 5-phase pipeline: burst (2 reference stills) +
6s video sweep (180 frames) → extract 17 candidate frames → score all 17
through the full AFIS pipeline → fuse the best left/center/right regions
into a stitched "superprint" → submit whichever of {superprint, top single
frame, burst fallback} scores best.

Reviewed against the real codebase and this project's own incident history
before building (2026-08-02) — the core idea (more viewing angles = more
recoverable ridge detail) is sound and consistent with what
`docs/MULTI_DISTANCE_MESH_SCOPE.md` already scoped for the sibling
distance-fusion case, but several parts of the spec don't hold up, and one
part (Phase 3's per-candidate compute cost) would very likely reproduce a
real production outage this project already suffered once.

### What's real and was buildable as specced

- **Client-side video bitrate/fps control is a genuine, supported plugin
  API** — confirmed live against the `camera` package's own changelog:
  "Adds support to control video fps and bitrate. See `CameraController`
  constructor" (v0.10.6+), with `fps`/`videoBitrate` as real constructor
  params. Unlike the manual-exposure investigation
  (`docs/LOCKED_SHUTTER_SPEED_SCOPE.md`), this is NOT a Camera2Interop gap.
- **`CameraService` already has `startVideoRecording()`/
  `stopVideoRecording()`** (`packages/mac_capture/lib/src/camera_service.dart`)
  — built at some point, never actually called anywhere in the app until
  now. No new capability needed, just wiring.
- **The backend already has OpenCV** (`opencv-contrib-python-headless` in
  `functions/processEnhanceAndScore/requirements.txt`) — the standard PyPI
  wheel bundles FFmpeg for `cv2.VideoCapture` file-based decode, so video
  decoding needs no new native dependency. (Not verified in this sandbox —
  no way to run `cv2.VideoCapture` against a real device-encoded clip here;
  this is standard OpenCV-wheel behavior, not confirmed against this
  project's actual traffic.)

### What's not real / needs correcting

- **`HybridCaptureService.takeBurst()`/`.recordVideo()` don't exist** as
  integration points — same class of mismatch as the locked-shutter-speed
  handoff doc. `HybridCaptureService` is a pure frame-scoring helper with
  no `CameraController` reference. The real owner is `FrontCaptureController`
  (burst logic already lives there) + `CameraService` (video recording).
- **Codec selection (H.265 vs H.264) is NOT controllable** through the
  `camera` plugin — confirmed against the same changelog: no entry ever
  added codec/HEVC selection. The platform picks whatever its
  `MediaRecorder`/CameraX `Recorder` defaults to; the app can only read
  back what it got afterward, never request H.265.
- **"Constant bitrate (not adaptive)" isn't guaranteed** — `videoBitrate`
  sets a target the platform encoder aims for, not a hard CBR mode. Same
  category of gap as manual exposure control, smaller in degree.
- **`gs://clearbridge-captures/...`** doesn't match this project's real
  bucket (`clearbridge-dc699.firebasestorage.app`) — used the existing
  `basePath` upload convention instead (`{basePath}/sweep_video.mp4`,
  alongside `front_burst_*.jpg`).
- **The "50% baseline / 70-80% target" TAR figures aren't measurable with
  this project's current infrastructure.** Per this project's own Prime
  Directive findings, no real paired-genuine/impostor dataset or ≥500-DPI
  reference exists yet, and no TAR baseline figure appears anywhere in this
  project's real documented history (confirmed by an earlier full-history
  grep, see the 2026-07-23 handoff audit). Treat the spec's numeric targets
  as aspirational, not as something a build can be checked against today.

### The one real production-outage risk: Phase 3's per-candidate compute cost

The existing `_afis_variants` loop (`main.py`) already runs ~15 enhancement
variants against a **70-second internal wall-clock budget**, inside Cloud
Run's 300s request timeout. That budget exists *because* of a real 2026-
07-16 incident: on one real capture, three variants (`deepFuse`/`deepMaxc`/
`deepSoft`) each independently redid an expensive alignment step, took 15+
minutes combined, and left the capture stuck at `status: enhancing`
forever until fixed (shared caching + the 70s budget).

The spec's Phase 3 asks for the **full** `afis_print.generate()` pipeline
(masking, orientation field, Gabor enhancement, frequency normalization,
proxy scoring) run **independently on all 17 candidates**, then again on
the fused superprint. Unlike today's 15 variants — which mostly share
cached alignment/stacking work on 1-2 underlying source frames — 17 video/
burst candidates are 17 genuinely different images with no shared cache
opportunity. This is not a marginal increase over an already-tight budget;
it's the same failure shape that caused the 2026-07-16 outage, at a larger
multiplier.

**Not built as specced.** Built instead, following the same "cheap
pre-select, expensive-score only the survivors" shape every other
candidate source in this pipeline already uses (secondary cameras,
detail-zoom):

1. Extract 5 raw candidate frames per zone by **direct-seeking** the video
   (`cv2.VideoCapture.set(CAP_PROP_POS_MSEC, ...)`), never decoding and
   holding all ~180 frames the spec describes.
2. Rank each zone's 5 candidates by **cheap real Laplacian variance** —
   no AFIS pipeline involved yet.
3. Run the full, expensive `afis_print.generate()` pipeline exactly **3
   times** (once per zone's single winner), not 17 — a bounded, small
   addition to the existing budget, not a multiplier on it.
4. Score each via the existing internal proxy (`_score_nfiq`, never the
   real NFIQ2 sidecar per-candidate — that stays a single post-hoc call on
   the eventual overall winner, per this project's own standing
   discipline) and let it compete for `best_afis_img` via the exact same
   `if score > afis_nfiq` max-of-candidates gate secondary cameras and
   detail-zoom already use.

This can only ever raise the final score (additive candidate, same
discipline as everywhere else in this pipeline) and adds at most 3 extra
`afis_print.generate()` calls per capture, not 17.

### Phase 4 (fusion/stitching) — not built, real methodological gap

The spec's region-stitching step (copy pixels 0-175 from the left frame,
125-375 from center, 325-500 from right, into one composite) assumes the
three source frames are already in the same aligned coordinate space. They
are not — they're photographs of the pad from genuinely different viewing
angles (that's the entire point of sampling different sweep zones), which
means real perspective/foreshortening differences, not just a translation.
Splicing un-registered regions by raw pixel-coordinate copy would very
likely produce a visibly discontinuous composite (ridge lines breaking at
the seams), not a cleaner print.

This project has already done real work on exactly this class of problem
and found it hard: `ml/deform_correct`'s cylindrical/elastic correction
line has mixed, sometimes-negative results even with a trained model (see
CLAUDE.md's extensive `deform_correct` history), and
`docs/MULTI_DISTANCE_MESH_SCOPE.md` — the sibling distance-based fusion
idea — explicitly phases around this same risk: normalize and *align*
(ECC-affine, via the already-existing `_align_face_on_stack`) each
candidate to a common reference **before** blending, never a naive
fixed-region splice.

**Recommendation, mirroring that doc's own precedent exactly**: Phase 4
should not be attempted until Phase 0 (built here) shows real evidence a
video-sourced candidate is independently competitive —
`sweepVideoCandidates.<zone>.wonSelection: true` on a real fraction of
captures. If that evidence appears, the next step is alignment-then-blend
via the existing `_align_face_on_stack`/`_focus_stack_face_on` machinery,
not pixel-region splicing.

## What's built (Phase 0)

- **Client** (`front_capture_controller.dart`): `_captureSweepVideo()` —
  records ~6s of video on the same main `CameraController` right after the
  main burst (before the secondary-camera loop, which switches to a
  different physical camera and has its own real session-contention
  history — video stays on the one already-open session, the lower-risk
  case). Uploads to `{basePath}/sweep_video.mp4`. Reuses the existing
  `capturingExtra`-phase `distanceHint` banner mechanism for the "sweep
  left to right" prompt — no screen-side UI change needed.
  `CameraService.initializeCamera()` gained optional `fps`/`videoBitrate`
  params (real plugin API), passed as `30`/`2500000` from
  `FrontCaptureScreen._init()`.
- **Backend** (`main.py`): `_extract_video_zone_candidates()` (direct-seek,
  cheap-rank) + a new candidate-scoring block modeled directly on the
  existing detail-zoom block, writing `sweepVideoCandidates` diagnostics to
  Firestore.

## Open questions / risks to carry forward

1. **Not device-tested** — same standing discipline as every other
   capture-side change this project makes; needs a real APK build + real
   video-capable device to confirm recording/upload actually works.
2. **Video-file decode compatibility unverified in this sandbox** — whether
   `cv2.VideoCapture` cleanly opens whatever container/codec this specific
   device fleet's `camera` plugin actually produces is a real open
   question, not assumed to just work.
3. **`CameraController` shares one resolution preset between photo and
   video** — this build does NOT force 1920×1080 for video (would require
   disposing/reinitializing the controller with a different preset, a real
   camera-session-churn risk this project has repeatedly traced ANRs to).
   Video records at whatever `ResolutionPreset.max` yields on the device;
   `afis_print.generate()` downsizes to 500×500 for scoring regardless, so
   this is unlikely to matter for final quality, but it's a deliberate
   deviation from the spec worth knowing about.
4. Real per-zone win rate is unknown until real captures exist —
   `sweepVideoCandidates` is the diagnostic that will answer it.
