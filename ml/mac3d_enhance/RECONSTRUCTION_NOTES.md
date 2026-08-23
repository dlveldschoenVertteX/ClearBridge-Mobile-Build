# Whole-print reconstruction vs NFIQ — the decisive finding

**TL;DR:** whole-print (wrap-around) reconstruction cannot raise NFIQ, *by the
metric's own construction*, no matter how perfect the reconstruction is. The
reconstruction that DOES help (front-pad edge-fill from minimal-yaw neighbours)
is already shipped. Pursue whole-print reconstruction only if the goal changes
from the NFIQ score to real AFIS matching.

## Why — measured, not asserted

NFIQ resizes every print to a fixed **500×500** before scoring. So the front
pad's share of that 500×500 is what sets the effective ridge resolution the
model sees. Padding the *same* clean front print into a larger canvas (i.e.
simulating a wider reconstructed print where the front pad is just one region)
drops the score hard:

| front pad fills | indoor NFIQ | sunlight NFIQ |
|-----------------|-------------|---------------|
| 100% (tight)    | 68.5        | 60.9          |
| 75%             | 58.1        | 49.5          |
| 50% (whole-print)| 47.4       | 41.9          |

A perfect whole-print reconstruction lands near the 50% row — ~20 points below
the tight front pad. This matches every empirical result to date:
cylindrical unwrap ≈ 36, multi-view fusion −17, wide-yaw mosaic ≤ single frame.
It was never a reconstruction-quality problem; it's the fixed-resolution metric.

## The corollary: NFIQ and real match value DIVERGE on coverage

A real AFIS matcher rewards **more minutiae area** — a genuine whole/rolled
print matches better than a single pad. NFIQ, scoring a fixed 500×500, rewards
the opposite (dense ridges in a small frame). So:

- **Goal = NFIQ 80** → maximise front-pad clarity; do NOT add coverage.
  Levers: flash+ambient fusion (shipped, +12), deep-burst denoise (shipped),
  two-step downscale (shipped), learned restoration (scaffolded). Reconstruction
  is counterproductive here.
- **Goal = real matching / rolled-equivalent** → coverage matters; whole-print
  reconstruction is worth perfecting, but measure it with a **matcher (minutiae
  count / match score)**, not NFIQ.

Decide which target is the product's north star before investing more in
reconstruction. Chasing NFIQ 80 and a full rolled print at once is
self-contradictory on a fixed-resolution quality metric.

## If/when whole-print reconstruction IS the goal: the only geometry the optics allow

SfM fails on these captures (COLMAP: periodic ridges + small baseline → no
registration). Wide-baseline oblique views foreshorten and won't seam. The one
protocol that could work is **small-baseline mosaic chaining**:

- Capture a **continuous slow roll** of the pad (not 8 discrete holds), ~30–60
  fps, so *adjacent* frames differ by **<2°** — where ridge foreshortening is
  ~0.06% and neighbours genuinely align.
- Chain pairwise homographies neighbour-to-neighbour outward from the front,
  with a light global constraint (bundle-adjustment-lite) to bound drift.
- Blend in the pad's own tangent plane per segment; unwrap.

This needs a **capture-flow change** (continuous-roll mode + higher preview fps
+ per-frame IMU) before it's testable — it can't be prototyped on the current
8-hold captures. Scope it as its own project, gated on the coverage-vs-NFIQ
decision above.
