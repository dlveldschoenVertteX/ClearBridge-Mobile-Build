# Layer 4 — pre-processing / normalization (2026-08-27/28, round 46)

Fourth layer of the step-by-step architecture pass. Focused on ridge-frequency
normalization (`freq_normalize`) since it's the one step in this layer that
gates the whole Gabor bank's working wavelength on every production variant.

## The defect: `_ridge_wavelength` never had a mask

`_ridge_wavelength` (and its diagnostic companion `_ridge_wavelength_robust`)
scan the FULL, un-cropped frame in 32x32 blocks, keeping any block with
`std() >= 8` -- no mask parameter existed before this round. Measured on 24
real recent `front_only_v1` captures (`diag_wavelength_mask_leak.py`, real
Firestore/Storage): the guide occupies only **~3% of frame area**, and
**96% of every block that ever contributes a frequency sample sits OUTSIDE
the guide**. Round 33 already measured, on a real capture, that background
can carry HIGHER local contrast than the pad itself (Laplacian 2282
background vs 1619 pad, same frame) -- so the bare contrast gate has no
reason to prefer pad content, and at this area ratio it structurally can't:
even a pad with every block passing would be outnumbered roughly 30:1 by
background candidates.

This is the same failure MODE round 42 found in the other enhancer's
`_ridge_pass` (measuring frequency/orientation from "the highest-contrast
quadrant of the WHOLE 512x512 scene"), but a different function, in a
different file, on the path every production variant actually runs
(`afis_print.py`'s own Gabor chain, not the NNS enhancer). It is also a
different mechanism from Phase 7-8's already-closed "mask-aware `_normalize`"
experiment (refuted there: `_normalize` is a pure affine map and everything
downstream is affine-invariant). Block SELECTION by std/periodicity is not
affine-invariant in that sense -- which blocks get admitted depends on real
pixel content, not global statistics -- so this is a genuinely separate,
previously-untested lever.

**Real impact on the reported `afisWavelengthPx`**: on 11/23 captures with
real in-mask signal, restricting to the pad moves the reported wavelength by
>=1px (mean |delta| 2.2px, max 9px).

## The fix: additive, backward-compatible, gated

`_ridge_wavelength` gained an optional `mask` parameter -- every existing
call site that doesn't pass it is byte-for-byte unaffected. When a mask IS
passed, the median is taken over in-mask-only samples; falls back to the
full unmasked population when zero in-mask blocks qualify, so it can only
ever narrow toward better-targeted content, never regress a capture that had
no real pad signal to find. Wired into `generate()` behind
`_WAVELENGTH_MASK_RESTRICT` (default `False`), same held-pending-evidence
pattern as round 45's `_UNET_GUIDE_SEED_ENABLED`.

Verified the shipped code, not a reimplementation: `test_wavelength_mask.py`
runs the actual `generate()` with the flag toggled, same real captures, same
`freq_normalize=True` every production variant uses.

## The result: real measurement fix, real NFIQ2 cost

**n=24, real NFIQ2 binary: production mean 69.58, masked mean 68.04, delta
-1.54. Masked better on 0, worse on 3, tied on 21.** The three real deltas
(-14, -6, -17; mean of the non-tied -12.3) are not noise -- they are large
and one-directional.

**Mechanism, read from the numbers.** `_FREQ_SCALE_MIN=0.7` clamps the
resample scale for any native wavelength at or above ~12.9px. The
background-contaminated (unmasked) estimate lands there on the vast majority
of captures (21/24 here) -- background/fabric reads as coarser "ridge"
period than the pad's own finer structure, so the contaminated estimate is
biased toward the floor. The masked (correct) estimate, closer to the pad's
true native period, sometimes escapes the floor (11-12.5px, computing a
milder 0.72-0.82 scale instead of the pinned 0.7) -- and in every one of the
3 captures where that happens, the milder, more-accurate correction scores
WORSE on real NFIQ2.

This is the same shape as two standing findings elsewhere in this project:
round 43's crease-trim (a correct fix that moved NFIQ2 the wrong way because
NFIQ2 was happy to count crease content as ridge area) and round 45's
masking-refinement control (correct-looking mask changes cost real NFIQ2
because NFIQ2 doesn't distinguish "removed useful ridge" from "removed
content NFIQ2 was rewarding for the wrong reason"). It also sits ALONGSIDE,
not against, the 2026-07-19 controlled pipeline test that found LOWERING
`_FREQ_SCALE_MIN` below 0.7 (more aggressive downsampling) hurts real
matchability -- that test never touched the ESTIMATE itself, only how far a
given (contaminated) estimate is allowed to push the scale. Read together:
this pipeline's real quality signals may reward aggressive resampling toward
`_TARGET_PERIOD` fairly broadly, and the contaminated estimate happens to
land in that regime more often than the corrected one does. Whether that
reflects something genuinely useful about heavy resampling, or is itself an
NFIQ2 texture-reward artifact the same way round 43/45 were, is not
resolved by NFIQ2 alone -- it needs the standing blocker, a real >=500dpi
matchability reference, to settle honestly.

## Held, not shipped

`_WAVELENGTH_MASK_RESTRICT` stays `False`. A measurably more accurate
measurement that costs real score on every case it touches is not something
to ship on NFIQ2 evidence -- same discipline as round 45. Production
behaviour is unchanged.

## Secondary finding: the client-side distance-gate calibration is also
contaminated, but its aggregate statistic happens not to move

`_liveWavelengthTooHighPx = 35.0` (`front_capture_controller.dart`, round
17) was derived from real `afisWavelengthPxRaw` stats: mean 23.8, sd 6.4,
mean+2sd=36.6 -> 35.0, framed explicitly as a safety backstop. That field
comes from `_ridge_wavelength_robust`, which has the identical unmasked
defect -- confirmed on the same 24 captures
(`diag_robust_leak_realdata.py`): **individual per-capture values swing
wildly** (28->10.8, 29->9.0, 15->30.0, 9.5->22.5 -- more than half the
population moves by double digits once masked, since this companion is
unclipped and the contamination has full range to distort it).

But the AGGREGATE statistic the threshold was actually derived from barely
moves: unmasked mean=23.3 sd=7.0 mean+2sd=37.4 vs masked mean=21.6 sd=7.6
mean+2sd=36.8 -- both would round to essentially the same ~35 threshold.
Per-capture noise in both directions happens to cancel out at the population
level. **Not recommending a recalibration on this evidence** -- the
threshold this data would justify is barely different from the one already
shipped, and this project's own standing discipline (rounds 11/13/17) is to
recalibrate only from a dedicated real-data pass, not an inferred number.
Recorded so a future round doesn't have to re-derive whether this
contamination threatens that specific threshold -- it measurably doesn't,
even though the underlying field is real noisy.
