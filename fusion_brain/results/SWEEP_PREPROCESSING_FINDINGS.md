# Pre-processing sweep -- three real negatives, and a lead that did not survive

Follow-up to the enhancement-filter sweep, covering the stages UPSTREAM of
it that had never been scored: CLAHE (the first processing step),
`_MASK_COVER_DILATE`, and multi-frame ambient stacking. Same discipline --
one variable at a time from production, real bozorth3 against the round-40
main-camera references, 3 real captures, reported per capture.

## Round 1

| arm | net | wins | note |
|---|---|---|---|
| CLAHE clip=5.0 | **+10** | 2/3 | the lead -- see below |
| CLAHE tiles=16x16 | -2 | 1/3 | neutral |
| mask_dilate=1.15 | -1 | 0/3 | neutral |
| CLAHE clip=2.0 | -1 | 2/3 | |
| CLAHE clip=1.0 | -16 | 2/3 | |
| **mask_dilate=1.0 (shrink only)** | **-21** | 0/3 | |
| CLAHE tiles=32x32 | -27 | 1/3 | |
| CLAHE tiles=4x4 | -30 | 0/3 | |
| **ambient burst STACKED anchor** | **-35** | 1/3 | |
| **CLAHE OFF** | **-46** | 1/3 | |

Three genuinely useful negatives, each answering a question never
previously asked:

* **CLAHE earns its place.** Turning it off costs -46. That control had
  never been run.
* **`_MASK_COVER_DILATE = 1.3` earns its place.** Shrink-only (1.0) costs
  -21. Its value was previously justified only on NFIQ2 (the constant's own
  comment cites 1.6 hurting a capture 79->68); this is the first
  confirmation on real matchability.
* **Ambient burst stacking is negative (-35).** That is the FIFTH
  independent denoise/averaging approach to measure negative in this
  project, after pyfing, nnsHybrid, coherenceDiff and ridgeRestoreHybrid.
  Treat the pattern as settled: extra smoothing ahead of this pipeline's
  own tuned Gabor chain does not help it.

## Round 2 -- the lead was noise, and this is how it was caught

Round 1's `clip=5.0` looked promising precisely because it appeared to sit
on a monotonic dose-response (1.0 -> -16, 2.0 -> -1, 3.0 -> 0, 5.0 -> +10),
which is far more convincing than an isolated point. Round 2 mapped the
curve further, on the stated principle that a trend which only ever rises
is as suspect as a single point.

| clip | net | wins | per-capture |
|---|---|---|---|
| 3.0 (production) | 0 | -- | baseline |
| 4.0 | **-16** | 0/3 | -14, -2, +0 |
| 5.0 | **+10** | 2/3 | -4, +8, +6 |
| 6.0 | **-14** | 1/3 | -13, +8, -9 |
| 8.0 | **-12** | 1/3 | -16, +8, -4 |
| 12.0 | **+6** | 2/3 | -4, +8, +2 |
| 20.0 | **-23** | 2/3 | -32, +8, +1 |

**It does not form a curve at all** -- it oscillates: 0, -16, +10, -14,
-12, +6, -23. The round-1 "trend" was an artifact of sampling only four
points and happening to miss 4.0, which sits 26 points below its immediate
neighbour 5.0. A 25% change in clip limit swinging 26 points
non-monotonically is measurement noise, not an optimum.

The decisive detail is `43378ea7`: its scores are **identical (31/19) at
clip 5, 6, 8, 12 AND 20**. Above ~5 the clip limit stops binding on that
capture, so CLAHE is provably doing the same thing -- yet the NET still
swings by 33 points across those same settings, entirely from the other
two captures. That isolates the swings as noise rather than as any effect
of the parameter.

**Conclusion: no change. Production `clipLimit=3.0` stands.**

## The most useful thing this produced: a noise floor

`43378ea7` saturating gives a rare clean handle on this gate's noise. Net
swings of roughly **+/-15 (about +/-7 per capture-reference pair)** occur
with no underlying change in what the pipeline does.

That retrospectively calibrates every sweep in this track:
* the filter sweep's small deltas (`gabor_gamma=1.00` at -5,
  `circular_vignette=OFF` at -5) were **within noise** -- correctly not
  acted on at the time;
* its large ones (`freq_scale_min=0.50` at -67, `crease_trim=OFF` at -52)
  sit **well outside** it and are real;
* and any future result under ~15 net on 3 captures should be treated as
  unmeasured rather than as a small effect.

Worth applying to this track's own earlier fusion numbers too: several
Phase 6/8 arms differed from their control by less than this, which is a
further reason the scanner reference matters more than any remaining
parameter.
