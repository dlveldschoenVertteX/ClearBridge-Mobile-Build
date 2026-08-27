# The NNS enhancer's streaking: a global single-orientation filter locking onto background

Direct CTO ask: "Have we ever tried to optimize the legacy NNS enhancer?
There may be some levers to pull on" -- following an earlier report that a
real enhanced print showed diagonal streaking through it.

## Two real, distinct bugs in the same function, not one

`enhancement_pipeline.enhance()`'s Stage-3 path (`_ridge_pass` -- confirmed
active on every real production capture via `enhancementParams.nnsStage: 3`
on real Firestore docs) derives both a ridge FREQUENCY and a single dominant
ORIENTATION from `_sharpest_roi` -- the highest-Laplacian-variance quadrant
of the WHOLE 512x512 scene -- then stamps one Gabor kernel at that one
frequency/orientation across the entire image, pad and background alike.

1. **Frequency is pinned at its own clamp on every capture.** The radial FFT
   spectrum of the ROI falls monotonically from bin 1 (measured:
   97530, 63237, 28752, 19763, ...) -- that is the image's 1/f illumination
   falloff, not ridge structure, and `np.argmax` always lands on bin 1 ->
   period 128px -> clamped to 50px. Confirmed pinned at 50.0px on every one
   of 10 real captures tested (`test_nns_guidecrop.py`), cropped or not.
2. **Orientation locks onto whatever the highest-contrast quadrant contains,
   which is usually background.** Isolated by rendering with `unet_weight=0`
   (pure `_ridge_pass`, no UNet) vs `unet_weight=1` (pure UNet, no
   `_ridge_pass`) on a real streaked capture: the filter-only render
   reproduces the CTO-reported diagonal streaking almost exactly; the
   UNet-only render does not. This is the dominant, confirmed mechanism for
   the visual artifact, not the frequency clamp -- the frequency bug alone
   (full-scene input, corrected frequency only) moved NFIQ2 only marginally
   (+0.50 mean, 5 better / 5 worse -- noise), because Stage 3 weights the
   filter at only 0.35 against the UNet's 0.65 and a wrong wavelength on the
   right orientation is a much smaller error than a wrong orientation.

## The guide-crop lever alone: refuted

First tested feeding `enhance()` the guide-region crop as its whole input,
on the theory that raising the pad's share of the frame would fix both
problems by construction. Real result on 10 captures: **-4.00 mean, 4
better / 5 worse.** Cropping removes the surrounding context CLAHE and the
UNet were trained/tuned against, and that cost outweighed the framing gain.
This was the finding that led to isolating frequency and orientation as
separate questions rather than accepting "crop it" as the answer.

## The real fix: measure the pad, filter the whole frame

`enhance()` gained an optional `roi_box` (512-space) restricting ONLY where
`_estimate_ridge_frequency` and `_ridge_pass`'s orientation estimate are
measured. CLAHE, the UNet, and the final filter still run on the whole
frame exactly as before -- only the measurement narrows. `main.py` computes
`roi_box` from the same `guideRegion` AFIS already uses, scoped to
`front_only_v1` (the space the guide's normalized coordinates are defined
in), 1.15x padded to match `_MASK_COVER_DILATE`'s existing margin
convention elsewhere in this pipeline.

**Result, 12 real production captures (`test_nns_orientation_fix.py`):**

| | prod | fixed | delta |
|---|---|---|---|
| NFIQ2 mean | 21.17 | 23.67 | **+2.50** (8 better / 3 worse / 1 same) |
| background streak coherence (ring around the guide) | 0.609 | 0.593 | -0.016 |

The background-coherence measure moved in the right direction but by less
than expected -- plausibly because it is measured in a fixed ring next to
the guide's own feathered boundary, which is itself partly shaped by the
mask rather than pure background texture. NFIQ2 is the more informative
number here and it improved.

**Visually confirmed on the two real captures that motivated this work**:
on `b615f37b`, `prod` renders the pad as a near-featureless grey oval;
`fixed` shows real curved ridge flow across the same pad, and the
background pattern is no longer forced into the deck's diagonal. On
`1d186afc` the improvement is marginal and NFIQ2 dropped (16 -> 11) -- this
capture's raw pad content is independently soft (already flagged this
session under the frame-selection work), and no orientation fix can recover
detail the optics never recorded. Recorded honestly rather than only
showing the capture that worked.

## Deployed status

Wired into `main.py` for `front_only_v1` only. `enhancementParams` now
records `nnsRoiRestricted` so a real capture shows whether the fix engaged.
Committed, not yet pushed pending final review of this write-up.

## Standing caveat

n=12, NFIQ2 only. This project has repeatedly found that NFIQ2 rewards
ridge-like texture regardless of whether it is faithful to the real finger
-- the same caveat that applies to every NFIQ2-gated finding this session.
The visual check on `b615f37b` is the stronger piece of evidence: it shows
the fix producing plausible ridge STRUCTURE, not just a higher score.
