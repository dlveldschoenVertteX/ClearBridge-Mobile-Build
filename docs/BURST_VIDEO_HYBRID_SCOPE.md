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

### Phase 4 (fusion/stitching) — architecture scoped 2026-08-03, not built

The spec's region-stitching step (copy pixels 0-175 from the left frame,
125-375 from center, 325-500 from right, into one composite) assumes the
three source frames are already in the same aligned coordinate space. They
are not — they're photographs of the pad from genuinely different viewing
angles (that's the entire point of sampling different sweep zones), which
means real perspective/foreshortening differences, not just a translation.
Splicing un-registered regions by raw pixel-coordinate copy would very
likely produce a visibly discontinuous composite (ridge lines breaking at
the seams), not a cleaner print.

**Gate, unchanged**: do not start building this until Phase 0 shows real
evidence — `sweepVideoCandidates.<zone>.wonSelection: true` on a real
fraction of captures. Everything below is the architecture to build *if*
that evidence lands, written now (per direct request) so it's ready rather
than re-derived later.

#### The honest starting point: this project already tried multi-angle warping and it lost

`sfm_pipeline.reconstruct_and_unwrap()` — the existing cylindrical-unwrap
pipeline for the oscillating/arc-sweep capture modes — already projects
multiple angled views onto a shared surface model and blends them. Per
CLAUDE.md's own established finding, the resulting unwrap scores
**14-24 NFIQ points lower** than simply keeping the single sharpest
face-on frame, and `_fuse_flash_ambient`'s own docstring states the reason
plainly: "multi-angle reconstruction... warps oblique views and hurts
NFIQ." Any new fusion design has to explain concretely why it avoids that
outcome, not just assert that it will. Two real differences justify a
second attempt, not blind optimism:

1. **Baseline size.** The cylindrical unwrap spans up to a ~270° device
   orbit — a genuine full 3D reconstruction problem. A hand sweep across
   the burst+video hybrid's left/center/right zones covers maybe 20-40° of
   real angular change. At that baseline, a *local* patch of the pad's
   surface is a much better planar approximation than the whole pad is —
   this is the standard justification for local-homography mosaicking over
   global 3D reconstruction in wide-baseline stitching problems generally,
   not something specific to this pipeline.
2. **Scope of the claim.** The cylindrical unwrap tries to reconstruct the
   *entire* pad from partial views — a mandatory, all-or-nothing geometric
   model. This design only wants to *optionally* recover detail in a
   narrow edge band the center view already shows (just less sharply),
   gated at every step so a failed or low-confidence region simply falls
   back to the center frame's own content — closer in spirit to
   `_fuse_flash_ambient`'s "same pose, no geometric distortion" framing
   than to full reconstruction.

#### Architecture: local-patch registration + confidence-weighted multi-band blend

**Do not build a new pipeline from scratch.** Every step below is either a
direct reuse of existing, already-proven code in this file, or a small,
clearly-scoped extension of one. Work happens on raw/CLAHE-normalized
grayscale, matching how `_stack_face_on`/`_focus_stack_face_on`/
`_fuse_flash_ambient` already operate — **never on already-binarized AFIS
output** (the spec's original framing). Binarized black/white ridge images
have thrown away the continuous-tone signal both registration and
multi-band blending need; fuse first, binarize once, at the end, through
the existing single-pass Gabor/normalize chain every other candidate
already goes through.

1. **Per-candidate frequency normalization, before anything else.**
   Independently resample each zone-winner toward `_TARGET_PERIOD` via the
   existing `_ridge_wavelength`-based resample already used for
   `freq_normalize=True`. Must happen before registration — a scale
   mismatch between zones (different working distance at different sweep
   positions) would otherwise get folded into the estimated warp as
   spurious scale correction, exactly the failure
   `docs/MULTI_DISTANCE_MESH_SCOPE.md` already flagged for its own sibling
   distance-fusion case.

2. **Coarse pre-alignment via phase correlation — a genuinely new piece.**
   Unlike same-pose burst frames (near-identical framing, valid for
   `_align_face_on_stack`'s direct ECC call), a sweep zone's frame shows
   the thumb at a real, unknown, potentially large pixel offset from the
   center frame. ECC has a limited convergence basin and will not find a
   large unknown translation on its own. Use `cv2.phaseCorrelate` (stdlib
   OpenCV, FFT cross-correlation, no new dependency) between the two
   frames' CLAHE-normalized grayscale to get a coarse translation estimate
   first, then seed ECC with it. Backend-only — no client-side position
   tracking needed (deliberately kept off the client; the disabled guided-
   sweep feature's whole 5-round saga was almost entirely coordinate-space
   bugs in exactly this kind of live position tracking, see
   `docs/GUIDED_SWEEP_ARCHITECTURE.md`).

3. **Local, bounded registration — extend `_align_face_on_stack`, don't
   replace it.** Restrict the ECC estimation window to the overlap band
   near the seam (e.g. the outer ~40% of the oblique frame, not the whole
   image) rather than the whole frame — this is what actually captures
   "local patch of a curved surface ≈ planar," not a global assumption
   over the entire pad. Use `cv2.MOTION_HOMOGRAPHY` (not `MOTION_AFFINE`)
   for the oblique-to-center registration specifically, since a real
   viewing-angle change is a perspective transform, not just
   rotation/scale/shear — `_align_face_on_stack`'s existing `MOTION_AFFINE`
   stays correct and untouched for its own same-pose use case; this is a
   parallel function, not a modification of the existing one.

4. **Per-region confidence, not a single accept/reject scalar.**
   `_align_face_on_stack` already gates on one whole-frame correlation
   number (`> 0.5`). For a local, partially-overlapping patch this needs
   to be a spatial map: after warping, compute local correlation in a
   sliding window across the overlap band, so a sub-region where the
   planarity assumption genuinely breaks down (e.g. near a crease) is
   excluded from blending even when the rest of the same frame aligned
   fine. Direct generalization of the existing scalar gate, not new
   invention.

5. **Blend weight = measured ridge coherence, not fixed pixel columns.**
   Reuse `_fuse_flash_ambient`'s own `_coh()` helper (currently a local
   closure inside that function — pull it to module scope so both call
   sites can use it) to compute a structure-tensor coherence map on both
   the center frame and the warped oblique frame in the overlap band.
   Blend toward the oblique frame only where its *measured* coherence
   exceeds center's at that location, gated by step 4's confidence map —
   the same "maxc"/"soft" idea `_fuse_flash_ambient` already uses for
   flash/ambient pairs, applied across genuinely different views instead
   of the same view under different illumination. This avoids the spec's
   real failure mode: pulling in oblique edge content just because it's
   spatially near the edge, even when it's actually blurrier or more
   foreshortened than what center already has there.

6. **Seam blending: reuse `sfm_pipeline._multiband_combine()` — it
   already exists and is already correct for this exact problem.** This
   Laplacian-pyramid (Burt-Adelson) blend is currently built, tested, and
   sitting unused ("Prototype / diagnostic only — not wired into the
   default `reconstruct_and_unwrap()` path"). Its own docstring describes
   precisely the two seam artifacts this design needs to avoid: ridge-line
   ghosting from imperfect alignment (fixed by blending high frequencies
   only right at the seam) and visible brightness steps between differently-
   lit source frames (fixed by blending low frequencies over a wide
   region). Feed it `(warped_candidate_texture, confidence_weight)` pairs
   for center + whichever oblique zones pass step 4's gate, instead of its
   current per-orbit-angle cylindrical inputs — the function itself is
   already shape-agnostic (any list of same-size texture/weight arrays).

7. **One fused composite → the existing Gabor/binarize/frequency-normalize
   chain, once.** The blended raw grayscale is masked with the existing
   `_guide_region`/segmentation machinery exactly as any other candidate,
   then flows through `afis_print.generate()`'s normal single enhancement
   pass — no new enhancement code needed here at all.

8. **Output as one more max-of-candidates entry — no override band.**
   Competes for `best_afis_img` via the exact same `if score > afis_nfiq`
   gate every other candidate source in this file already uses. Deliberately
   **not** the spec's Phase 5 tolerance rule ("submit superprint if its
   score is within 1.0 of the top candidate") — that can submit a *worse*
   result than the plain best candidate. Strict max, matching this
   pipeline's one consistent rule everywhere else: a new candidate can only
   raise the final score, never be allowed to lower it by a tolerance band.

#### Before writing any of the above: a standalone registration-convergence probe

Same "measure before you build" discipline as every other investment this
project has made (the EXIF diagnostic before the locked-shutter native
lift, Phase 0 candidate-scoring before this fusion work itself). Once real
captures with populated `sweepVideoCandidates` exist, build a small
offline script (same pattern as `scratchpad/harness.py` elsewhere this
project has used) that runs *only* steps 1-4 above — frequency-normalize,
phase-correlate, local ECC-homography, per-region confidence — against
real zone-winner pairs and reports the real confidence-map coverage and
residuals. If registration itself doesn't converge with usable confidence
on real pad content, steps 5-8 (the blend) are premature regardless of how
good the raw candidate images are — this is the cheapest possible way to
find that out before investing in the rest.

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
