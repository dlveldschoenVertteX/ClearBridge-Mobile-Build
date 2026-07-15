# Scope: multi-distance capture + mesh (front-only capture)

## Context

CTO recalled a prior conversation — not fully written down anywhere found in
Notion or this repo's history — about capturing the front thumb pad at
**different working distances** and **meshing them together** into one
denser, more consistently sharp print, rather than the current single-hold,
single-distance capture. The closest documented predecessor is
`CAPTURE_OPTIMIZATION_SCOPE.md`'s "Lever B" (2026-07-12), which proposed
**focus bracketing** but framed it as "capture across a few focus positions,
keep the sharpest" (max-of-N) — not literal fusion. This doc scopes the
fusion version specifically, grounded in what this session's real-data
analysis just found.

**Why this is worth scoping now:** cross-referencing all 24 real scored
captures against their recorded ridge wavelength (see 2026-07-15 tuning
session) showed native ridge wavelength — a direct proxy for working
distance — is the single strongest predictor of real `nfiq2Score` found so
far: every capture ≥15px wavelength scored badly regardless of enhancement
variant; only 9–11px captures scored well. That makes working distance the
highest-leverage remaining variable, and multi-distance capture is a direct
way to attack it from the capture side rather than the enhancement side.

## The core idea

Capture the pad at 2–3 distinct working distances in one session (e.g.
slightly closer, at the current guided distance, slightly farther), then
**mesh** them per-pixel by local sharpness — reusing the same mechanism
already shipped for same-distance burst denoising
(`afis_print._focus_stack_face_on`), rather than just picking one winner.

Two independent reasons this could help beyond "pick the best single shot":
1. **User/device variance in hitting the one right distance.** A fixed
   single target distance depends on the user holding it accurately; multiple
   distances raises the odds at least one lands in the 9–11px sweet spot.
2. **A curved pad isn't at one distance from a flat sensor.** The center and
   the curved edges of a real thumb pad are physically at slightly different
   distances from the lens in any single shot. Different focus/working
   distances may resolve different regions of the SAME pad better — meshing
   could give more uniform sharpness across the whole print than any single
   distance can, not just a better average.

## What already exists to build on

- `afis_print._align_face_on_stack()` — ECC-affine registers a list of
  same-pose frames to a reference, already tolerant of small
  scale/shift/rotation differences (MOTION_AFFINE includes scale), with a
  correlation-based accept/reject (`> 0.5`) per frame.
- `afis_print._focus_stack_face_on()` — takes that aligned stack and does a
  **per-pixel, local-sharpness-weighted blend** (Gaussian-smoothed Laplacian
  energy as the weight), so whichever frame is locally sharpest wins there.
  This is exactly the "mesh" mechanic the CTO described — it just currently
  only runs on same-distance, same-pose burst frames.
- `main.py`'s `_afis_variants` max-of-N pattern — every rendering variant
  (native, freqNorm, stack, fuseAvg, mosaicFreq, deepFuse) is scored
  independently and the highest real proxy score wins, so a new variant can
  only ever raise the final score, never regress a capture that doesn't use
  it. Any multi-distance work should follow this same pattern.

## What's genuinely new and needs care

**Frequency mismatch between distances.** Same-distance stacking today never
needs to worry about ridge period — every frame in the stack shares one
native wavelength. Multi-distance frames will NOT: a "near" shot and a "far"
shot have different native ridge periods by construction. Blending them
directly (today's `_focus_stack_face_on` order: align → blend → normalize
frequency once at the end) would mix mismatched periods in transition
regions between which-frame-won-where — likely producing inconsistent or
smeared ridge spacing, not a cleaner print.

**This session's own finding makes this a real risk, not a hypothetical
one**: aggressive frequency-rescaling (resampling by more than ~30%) already
correlates with catastrophic real NFIQ2 in the current single-image pipeline
(see the 2026-07-15 tuning session). A multi-distance blend that leans on
frequency normalization even more (normalizing every candidate frame, not
just the occasional oversized single image) inherits that same risk and
needs its own validation — it should NOT be assumed to help just because
same-distance stacking helps.

**Proposed order of operations (differs from today's single-image pipeline):**
1. Per distance-zone: pick the sharpest frame, estimate its native
   `_ridge_wavelength` (already exists).
2. Normalize each candidate to `_TARGET_PERIOD` **individually, before
   alignment** — not once at the end on a single fused image, which is the
   opposite order from every existing variant.
3. Align the now-common-period frames via `_align_face_on_stack`.
4. Add a **post-alignment scale sanity check**: reject a frame if its
   recovered affine scale factor sits far outside ~0.8–1.25 (today's stack
   only gates on `_STACK_ANGLE_DEG`/correlation, with no equivalent for a
   genuine scale mismatch — a new failure mode this introduces).
5. Blend via the existing `_focus_stack_face_on` sharpness-weighted combine.

## Capture-side change (`clearbridge_beta/lib/front_capture_controller.dart`)

Today: single 1.5s hold → one 8-shot burst (4 ambient + 4 flash) at one
distance. Proposed: extend to a **2–3 stage guided sequence** — hold → brief
"move slightly closer" cue → second hold+burst → optional "move back" cue →
third hold+burst.

- **Reuse, don't reinvent**: `OscillatingCaptureController` already has a
  proven hold/transition/hold state machine (steadiness gate, burst
  mechanics, guided cue timing) for angle-based multi-position capture —
  retarget the same pattern to distance instead of angle rather than writing
  a new one.
- **Distance-zone detection**: the existing `_scoreRoi` mean-luma coverage
  check (already used for the "move closer"/"move back" hints) can detect
  when the user has moved to a meaningfully different distance zone — no new
  sensor/hardware capability needed.
- **Schema**: tag each burst's `frames[]` entries with a `distanceZone`
  field (`'near'|'mid'|'far'`), parallel to the existing `flashOn` tagging —
  additive, no redesign.
- **Real cost to weigh**: this roughly doubles-to-triples the capture
  window (extra holds + transition guidance) in an app whose current
  strength is a fast single-hold capture. This is a genuine product
  trade-off, not just an engineering detail — worth a explicit go/no-go
  before building, not just after.

## Recommended phased plan (de-risk before committing to the harder fusion work)

**Phase 0 — capture-only, cheapest possible test.** Capture at 2 distances
instead of 1, but do NOT build the fusion math yet. Feed each distance's
sharpest frame into the pipeline as its own independent single-frame
candidate in the existing max-of-N variant list (the same way secondary-camera
shots already work). This alone answers "does capturing a second distance
ever produce a better single frame than the guided one" — the foundational
question — without touching the harder, unproven frequency-normalize-before-
blend fusion math at all.

**Phase 1 — only if Phase 0 shows real gain.** Build the actual
`multiDistance` fusion variant described above (normalize-then-align-then-
blend), wired into `main.py`'s `_afis_variants` as one more additive,
non-regressing entry.

This mirrors the discipline already established elsewhere in this project
(camera selection, deepFuse, mosaic were all proven as independent levers
before being combined) — don't build the compound version before the
simple version is shown to help.

## Open questions / risks to carry into implementation

1. Whether ECC-affine registration actually converges reliably across a real
   near/far distance gap — untested. If it fails often, the variant
   self-skips per the existing `None`-return contract (costs nothing, but
   also gains nothing on those captures).
2. The frequency-normalize-per-frame-before-blend step is new territory this
   project hasn't tested — needs its own real-device NFIQ2 validation, not
   an assumption it inherits same-distance stacking's proven benefit.
3. Capture-time UX cost vs. the beta app's current single-hold speed.
4. Same standing constraint as all other NFIQ2 work this project: the
   sidecar can't be reached from this dev sandbox — any validation needs a
   real deploy + real device captures, never trust the local proxy alone.
