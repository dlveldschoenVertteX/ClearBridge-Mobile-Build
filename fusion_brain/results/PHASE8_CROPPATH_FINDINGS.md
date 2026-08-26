# Phase 7-8 -- the crop-path penalty: real, fixed, and still not enough

Capture `6b43c255`, n=1. Scored against four real references, two of them
the better main-camera ones built in round 40.

## Where this came from

Phase 6 scored its whole 2x2 against a control rendered from a
pad-dominated CROP. Round 40's reference-power work noticed that control
was itself far weaker than the same anchor rendered from the FULL FRAME
-- 27 vs 44 on `main_round32`, from identical pad pixels. If real, every
Phase 6 verdict was measured against a handicapped baseline.

It is real. The two renders differ by 32% of pixels after
phase-correlation alignment, with 40,905 vs 36,675 ink px, despite
identical reported afis params (wavelength 20.0, freqScale 0.7, mask
`guide`) and near-identical print sizes.

## Mechanism: two candidates, one refuted, one real, neither a fix

**REFUTED -- mask-aware `_normalize`.** Drawing the statistics from
inside the pad mask rather than the whole frame produced BYTE-IDENTICAL
output and identical scores on all four references. Recorded so it is not
re-attempted: `_normalize` reduces to `m0 + sqrt(v0)*(x-m)/sqrt(v)`, a
pure AFFINE intensity map, and everything downstream is affine-invariant
-- Sobel orientation depends on gradient RATIOS, periodicity is unchanged
by scaling, and Gabor is linear followed by a relative threshold. A
plausible mechanism killed by its own experiment.

**REAL -- CLAHE tile scale.** `generate()` builds its working image with
`tileGridSize=(8, 8)`, which is relative to the IMAGE. Same pad, 533x400px
tiles full-frame vs 308x320px in the crop, and CLAHE is nonlinear and
local. Confirmed by effect: changing tile size moves minutiae counts, ink
and scores, unlike `_normalize`. But forcing a common physical tile size
made BOTH paths worse and did NOT make them converge:

| arm | minutiae | macro32 | main32 | macro35 | main35 |
|---|---|---|---|---|---|
| full_frame (production 8x8) | 135 | **34** | **44** | 29 | 31 |
| full_frame + tile400 | 131 | 23 | 32 | 24 | 37 |
| crop + tile533 | 133 | 25 | 35 | 26 | 31 |

So: a real sensitivity, not a change worth making. Worth knowing anyway
-- the pad's contrast enhancement scales with framing and camera
resolution rather than with the finger, which is a genuine cross-session
inconsistency source on the axis the prime directive is about.

## The fix that does work: register in crop space, RENDER full-frame

Production crops because whole-frame ECC locks onto the static room, so
REGISTRATION needs the crop; ENHANCEMENT does not. Build the mosaic in
crop space exactly as before, paste it back into the full frame at the
crop's own offset, render once with the original guide.

| arm | minutiae | macro32 | main32 | macro35 | main35 |
|---|---|---|---|---|---|
| **`anchor_fullframe`** | 135 | **34** | **44** | **29** | 31 |
| `anchor_crop` | 135 | 24 | 27 | 27 | **36** |
| `mosaic_crop` (Phase 6's arm) | 91 | 25 | 17 | 20 | 27 |
| **`mosaic_fullframe`** (the fix) | 92 | 29 | 21 | 22 | 21 |

**The fix is real: full-frame render beats crop render on 3/4
references** (29v25, 21v17, 22v20), recovering points for every fusion
arm. **It does not change the verdict: 0/4 against the plain anchor.**

## A bug of mine, recorded rather than quietly fixed

The first version of this pasted the mosaic straight in and reported
`mosaic_fullframe` at 49 minutiae -- a collapse I nearly reported as a
fusion result. It was my own artifact. `_mosaic` returns a coherence-
WEIGHTED AVERAGE, which shifts the region's intensity (mean 124.15 ->
136.77), leaving a hard **20.8-level step** along the crop boundary: a
rectangular discontinuity across the frame that the global CLAHE tiles
and orientation field both then see. Caught by measuring the seam rather
than trusting the number. Fixed by restoring the mosaic's intensity
statistics to the crop region's before pasting (seam step 20.8 -> 7.1,
minutiae 49 -> 92). Per the refuted hypothesis above this is an affine
map, so it cannot alter the ridge structure the mosaic carries.

## Standing conclusion

The crop-path penalty was real and is now fixed, but the gap it explains
(~3-4 points) is an order smaller than the gap to the plain anchor
(44 vs 21 on `main_round32`). Combined with Phase 6, pixel-domain fusion
has now been tested across registration (ECC, ECC+TPS), combine rule
(average, max-coherence), render framing (crop, full-frame) and reference
quality (macro, main-camera), against a correct control every time, and
**`anchor_fullframe` -- the plain single-frame anchor, no fusion at all --
remains the best print this pipeline produces.**
