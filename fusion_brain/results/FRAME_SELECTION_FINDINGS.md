# Frame selection: production picks the best burst frame 2 times in 18

Answers a direct CTO instruction (2026-08-27): *"fix the frame selection ...
also look into how we can get the ambient frames resolve better ridge
content, because stacking ambient frames on noise explains why the stacking
function performed so badly."*

Method: for 18 real production `front_only_v1` captures, render **every**
burst frame as `generate()`'s primary and score each with the real NIST
NFIQ2 binary, holding `ambient_burst`/`flash_burst` -- and therefore every
masking decision -- identical across arms. The only variable is `frames[0]`.
That makes the best possible choice known rather than assumed, and turns
policy comparison into an offline question over recorded numbers
(`eval_selection_guards.py`), so any rule can be tested without re-rendering.

Deliberately the **production** population, not `fusion_v1`. Earlier this
same session a backend change looked behaviour-neutral on three captures
that were all `fusion_v1`, and would have broken 57% of production.

## Result

| policy | mean NFIQ2 | vs prod | worst case | picks best frame |
|---|---|---|---|---|
| **prod** -- sharpest ambient, client laplacianScore | 62.22 | -- | -- | **2/18** |
| swap: flash only, guide-region Laplacian | 65.50 | +3.28 | **-16** | 6/18 |
| swap: flash unless >5% / >15% of pad clipped | 65.50 | +3.28 | -16 | 6/18 |
| swap: flash unless ambient 2x/4x sharper in guide | 64.61 | +2.39 | -16 | 6/18 |
| **additive: prod + best-flash candidate** (shipped) | **68.83** | **+6.61** | **0** | 8/18 |
| additive: prod + best-flash + best-ambient | 69.89 | +7.67 | 0 | 9/18 |
| ORACLE -- best frame, unknowable live | 74.78 | +12.56 | -- | -- |

Both clipping guards are inert: they never fire, because median pad
clipping on this population is 0.

## Why the current rule loses, measured

Two independent confounds, neither of them a tuning problem.

**ISO.** Across 63 production captures with exposure metadata:

| | shutter median | ISO median | client Laplacian median |
|---|---|---|---|
| ambient | 29,999 us (1/33 s) | **291** | 157.8 |
| flash | 29,999 us (1/33 s) | **140** | 70.1 |

The torch does not shorten the exposure -- 79% of ambient and 71% of flash
frames sit at the same 30 ms AE ceiling -- it lets the sensor drop ISO.
Laplacian variance rewards the broadband sensor noise the ambient frames
carry twice as much of. Measured per frame inside the guide:

| metric | ambient | flash | flash / ambient |
|---|---|---|---|
| client laplacianScore | 144.0 | 57.5 | 0.40 |
| guide-region Laplacian | 124.3 | 36.0 | 0.29 |
| ridge-band energy | 0.350 | 0.466 | **1.33** |
| ridge fraction (illumination-normalised) | 0.263 | 0.319 | **1.21** |
| orientation coherence | 0.220 | 0.369 | **1.68** |

Laplacian says ambient is 3.4x sharper. Every ridge-specific measure says
flash is better, coherence most strongly of all -- and coherence is the one
that most directly means "there are real oriented ridges here". This is the
quantitative form of the CTO's own visual report that the ambient frames
looked blurry while scoring highest.

**Framing.** `generate()`'s internal `_ridge_energy` ranks frames on a
centre-half crop of the frame. Measured on six real production captures, the
guide occupies **12.5%** of that crop -- so 87.5% of what the ranking
measures is background. This ranking also orders the `stack`/`focusStack`
pool, so the same defect reaches those variants.

## Why additive, not a swap

`main.py` already carries a note that a 2026-07-24 experiment preferring
flash was refuted, and says not to re-attempt it. That test **replaced** the
primary and ranked with the client's whole-preview proxy. The swap rows
above reproduce its failure mode from a different direction: up to **-16**
on individual captures, because the flash frame is not always better.

Keeping both and letting the existing max-of-variants NFIQ2 selection decide
is non-regressive by construction -- the same "can only add a candidate"
discipline every other addition to this pipeline follows -- and beats every
swap on the mean as well.

## Against real production, with a confound removed

`compare_vs_production.py` compares against the `nfiq2Score` production
actually delivered rather than a single-variant proxy. Run unfiltered it
reported +18.50, but five captures carrying almost all of that (+64, +57,
+56, +53, +41) were taken 2026-07-24 to 2026-08-05 and delivered 5-10 via
`secondary_3`/`minutiae_left`/`detailZoom` -- selection paths since changed
outright. That delta is three weeks of pipeline fixes, not frame selection.

Restricted to captures from 2026-08-17 onward (n=6): **+3.33 mean, improves
2 of 6, regresses 0, max single gain +14.** Smaller than the within-harness
+6.61, as expected -- production already runs sixteen variants on the
ambient primary and recovers part of the gap on its own. This is the number
that describes what shipping the change actually buys.

## Measured and deliberately not shipped

Adding the best AMBIENT frame by the same guide-region ranking buys a
further +1.06 (68.83 -> 69.89) for another render pair. The variant loop
already truncates on real captures (round 14's own Cloud Logging trace), so
that trade is recorded here rather than spent. Revisit if the per-variant
budget ever gets cheaper.

## On OIS, since it is about to be bought

Estimated motion smear from the recorded gyro rate at the 30 ms exposure is
**3.2 px median / 4.7 px p90**, against a 9-15 px ridge period. Across 52
scored captures, shutter, ISO and gyro all correlate with real NFIQ2 at
|r| < 0.17 -- noise. Captures with >=75% of frames pinned at the AE ceiling
average 60.7 against 64.0 for those below 25%, a gap inside this project's
own established noise floor.

OIS should help, and a sensor that can hold a shorter exposure would help
more. But this data does not support stabilisation as the dominant term --
the ISO penalty on ambient frames is larger, and it is fixable in software,
which is what the change above does.
