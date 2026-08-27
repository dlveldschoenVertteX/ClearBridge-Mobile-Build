# Processing-lever sweep -- production is already at the optimum

CTO ask (2026-08-27): find optimum settings across the enhancement
filters. One variable at a time from the production baseline, scored with
real bozorth3 against the round-40 main-camera references, on 3 real
captures, reported per capture.

## Result: no lever improves on aggregate

| arm | net delta | wins | mean minutiae vs base |
|---|---|---|---|
| **BASELINE (production)** | -- | -- | -- |
| gabor_gamma=1.00 | -5 | 1/3 | +8 |
| circular_vignette=OFF | -5 | 2/3 | +32 |
| gabor_sigma_ratio=0.50 | -14 | 1/3 | +0 |
| gabor_gamma=0.70 | -28 | 0/3 | -7 |
| gabor_sigma_ratio=0.80 | -40 | 0/3 | -4 |
| freq_scale_min=0.90 | -51 | 0/3 | +92 |
| crease_trim=OFF | -52 | 0/3 | +162 |
| freq_scale_min=0.50 | -67 | 1/3 | -63 |

`freq_scale_min` moved in EITHER direction hurts (-67 at 0.50, -51 at
0.90) -- the signature of a real optimum rather than an arbitrary default.
This independently confirms the 2026-07-15 tuning pass and round 19's own
finding that relaxing the frequency floor costs real matchability, now
using a better instrument (main-camera refs) and real bozorth3 rather
than NFIQ2.

The two nearest arms (-5 each) are within this gate's noise; neither is a
candidate change.

## The load-bearing finding: template density, again

**Correlation between minutiae count and bozorth3 score across all 27
renders: r = -0.246.** More minutiae is mildly WORSE.

`crease_trim=OFF` is the cleanest illustration -- it adds **+162 minutiae
on average** (135 -> 268 on one capture) and loses on all 3 captures.
`freq_scale_min=0.90` does the same: +92 minutiae, 0/3.

This is Stage A's template-density penalty appearing in a completely
independent context -- filter tuning rather than fusion -- and it is the
same mechanism that made `tps_maxc` lose while carrying 273 minutiae
against the anchor's 135. Across this project it now reproduces in three
separate settings, and is best treated as a settled property of this
pipeline: **anything that inflates the template costs matchability.**

Practical consequence: minutiae count is not a proxy for print quality
here, and any future change that "finds more minutiae" should be regarded
with suspicion until scored.

## Recommendation

Stop tuning these filters -- there is no headroom on real data. Combined
with the separate finding that 8.4% of pad pixels are hard-saturated at
CAPTURE (unrecoverable by any backend setting, verified unchanged across
every CLAHE clip limit), the remaining levers are capture-side: pad
exposure, and guide geometry.
