# Phase 6 — raw-domain mosaic: registration x combine, against the correct control

Capture `6b43c255` (macro-bearing fusion_v1). Anchor = `front_v1`.
n=1; every number below is one real capture and should be read that way.

## What was tested

A 2x2 over the two candidate causes of Phase 5's minutiae loss:

* **registration** — ECC alone (production's single global homography)
  vs ECC followed by TPS elastic refinement;
* **combine** — coherence-weighted average (production's rule) vs
  per-pixel max-coherence selection (winner-take-all, which can never sum
  two ridge patterns and so cannot interfere destructively).

The CONTROL is `generate()` on the ANCHOR CROP with the same adjusted
guide and no mosaic — the control Phase 5 was missing, whose absence
produced that phase's documented confound.

## Result

| arm | sides | mosaic lap | minutiae | ink | round32 | round35 | beats control |
|---|---|---|---|---|---|---|---|
| control (no mosaic) | — | 20.2 | 135 | 5 | **24** | **27** | — |
| ecc_avg (= Phase 5) | 3/6 | 71.1 | 91 | 5 | **25** | 20 | **1/2** |
| ecc_maxc | 3/6 | 547.3 | 88 | 3 | 15 | 16 | 0/2 |
| tps_avg | 3/6 | 65.2 | 90 | 6 | 16 | 22 | 0/2 |
| tps_maxc | 3/6 | 509.2 | **273** | 6 | 23 | 21 | 0/2 |

**No arm beats the control on both informative references.** `ecc_avg`
remains the best at 1/2, unchanged from Phase 5 — so neither lever
rescues raw-domain fusion.

## Findings

**1. TPS does not help — but the residual it corrects is real.**
Instrumented directly on the ECC-registered crops: 32-51 blocks per
source pass the confidence and plausibility gates (of 380), with median
local misregistration 1.1-11.1 px and p90 up to 29 px, and fitted TPS
max displacement 26-39 px. So sub-ridge-period residual after global
registration genuinely exists (median ~7px on the tilt sources is ~0.8
ridge periods at the 9px target). Correcting it still costs matchability
(`ecc_avg` 25 -> `tps_avg` 16 on round32).

Honest caveat on this arm: `tpsMaxD` pins near the 40px cap on 4 of 6
sources — the same "fitted displacement pins at the tolerance" signature
Stage A already documented as fitting noise rather than skin. Some
fraction of this warp is likely noise, so "TPS is unhelpful here" is
better supported than "elastic correction is unhelpful in principle".

**2. Max-coherence selection is refuted, reversing an earlier reading.**
An interim report during this phase said maxc gave a 10x sharper mosaic
and 160 minutiae vs the control's 135, apparently confirming destructive
interference. That measurement was taken against UNREGISTERED sides (see
the bug below) and does not survive the fix: against properly registered
sides `ecc_maxc` scores 15/16, the worst arm in the matrix. The
`deepMaxc`-beats-`deepFuse` precedent (57 -> 81 real NFIQ2) does not
transfer to this mosaic.

**3. TPS + maxc doubles extracted minutiae and still does not win.**
`tps_maxc` yields 273 minutiae against the control's 135 and recovers
most of what plain `ecc_maxc` lost (15/16 -> 23/21) — so the combination
genuinely extracts far more ridge structure. It still loses. This is
this track's own **template-density penalty** (Stage A) appearing again:
doubling the template bought no matchability.

## Two real bugs in this harness, both mine, recorded rather than quietly fixed

**a. The `ecc` arms did no registration at all.** `_mosaic()` takes
PRE-registered sides; the TPS path warped them but the non-TPS path
cropped each side and passed it straight through. Production performs
ECC inside `_front_anchored_mosaic`, and replacing that function dropped
the registration with it. The mislabelled arm used 2/6 sides where
Phase 5 used 3/6 and scored differently. Fixed by extracting production's
exact ECC step into `_ecc_register()` (small-scale estimate, CLAHE,
`WARP_INVERSE_MAP`, warped ones-mask validity); `ecc_avg` now reproduces
Phase 5 exactly. The avg-vs-maxc contrast measured before this fix was
internally consistent but is superseded by finding 2.

**b. The first TPS arm tested a coordinate bridge, not TPS.** It fitted
the warp on RENDERED-PRINT minutiae and bridged print space to crop space
with a bare per-axis rescale of the rigid translation, then applied the
rotation about the image ORIGIN. The anchor crop is 2563x2464 while its
print is 410x431, and the relationship between them includes
`generate()`'s upright-from-tip rotation and trim, not just a uniform
scale. Measured: the three sources ECC registers well (corr 0.540 /
0.549 / 0.613) were exactly the ones that warp destroyed (0.266 / 0.164 /
-0.008), so every side failed the 0.45 gate and both TPS arms produced
nothing. Replaced with `_elastic_refine()`, which never leaves crop
space: ECC aligns globally, per-block phase correlation measures the
local residual on the registered crops, and those become the TPS control
points. Phase-correlation direction convention was verified empirically
before use.

A third bug, in `tps.py` rather than this harness, was found the same
run: `warp_image()` built its whole per-pixel sampling grid at once, which
OOM-killed the process at raw-crop resolution (~14GB RSS, confirmed via
dmesg). Fixed by row-chunking, verified byte-identical.

## Standing conclusion

Raw-domain fusion has now been tested across registration (ECC,
ECC+TPS) x combine (average, max-coherence) against a correct control,
and no combination beats enhancing the anchor crop alone. This is the
fifth consecutive negative for pixel-domain fusion in this project.

The unresolved confound is the reference itself: `macro_round32` and
`macro_round35` are phone captures, not scanner prints, so this compares
one imperfect print against another and cannot separate "fusion hurt the
print" from "the reference cannot resolve the improvement". The real
>=500-DPI full-pad scanner reference — this track's standing blocker
since 2026-07-16 — is what would settle it.
