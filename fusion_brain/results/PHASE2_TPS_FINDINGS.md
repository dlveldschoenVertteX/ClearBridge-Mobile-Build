# Stage A — TPS elastic fusion: the rigid-slop diagnosis was mostly WRONG, and the real mechanism is now measured

Stage A set out to test one hypothesis: Phase 1's fusion lost because it
registered sources with a **rigid** transform, leaving real non-rigid skin
deformation uncorrected, so merged minutiae landed slightly off. The fix was
TPS elastic warping using the matched minutiae as control points (Ross &
Jain; Bazen & Gerez; the learned successor is Cui/Feng et al.,
arXiv:2004.05972).

**The hypothesis is largely refuted, and the controls found the real
mechanism instead.** That is a better outcome than a small win would have
been.

## What TPS actually bought

`tps.py` is built and numerically self-tested (affine reproduced to 1e-12,
held-out non-rigid recovery 0.046px, extrapolation guard confirmed
engaging, Jacobian angle update accurate to 0.01°). It fitted cleanly on
all 6 real sources. Result:

| candidate | macro_round32 | macro_round35 |
|---|---|---|
| anchor alone (production today) | **34** | **29** |
| rigid fusion (Phase 1) | 28 | 25 |
| TPS elastic fusion (Stage A) | 29 | 25 |

28 → 29 on one reference, unchanged on the other. Real, but nowhere near
closing a 34 → 28 deficit. **Registration model was not the main problem.**

One diagnostic worth recording: every source's fitted `maxDisplacement`
pinned at ~12px, which is exactly `dist_tol`. The deformation TPS can even
*see* is bounded by the correspondence radius that accepted the control
points in the first place — any true deformation larger than the tolerance
never produced a correspondence to fit. So TPS here corrects sub-tolerance
residual only, which is a real structural ceiling on this approach as
currently wired, not a tuning issue.

## The controls that found the real mechanism

### B. Random-point control — the decisive one

Adding **85 pure-noise minutiae** (uniform over the anchor's own print area,
random orientation, 3 seeds) versus adding the 85 **real fused** minutiae:

| reference | anchor | real fusion | random noise (mean) |
|---|---|---|---|
| macro_round32 | 34 | 28 (**−6**) | 29.3 (**−4.7**) |
| macro_round35 | 29 | 25 (**−4**) | 23.3 (**−5.7**) |

**Real added minutiae cost about the same as pure noise of the same
count.** So a large part of the "fusion loses" result is a *template-density
penalty* that is substantially independent of whether the added points carry
real signal. The original comparison could not distinguish "these minutiae
are bad" from "adding this many minutiae to this template hurts this score"
— and the control says it is materially the latter.

### C. Reference-coverage check — the test was structurally underpowered

Only **10/85** and **17/85** of the added minutiae fall inside the
reference print's own extent. ~80–88% of what fusion contributes is in
territory the reference does not cover, so it *cannot* raise those scores by
construction — it can only add competing evidence. Measuring a
wider-coverage superprint against a narrower-coverage reference is the wrong
instrument for this question, and that has to be stated plainly rather than
read as "fusion fails".

### A. Per-source ablation — the premise still has real support

Anchor + exactly one source at a time:

| config | n | macro_round32 | macro_round35 |
|---|---|---|---|
| anchor alone | 135 | 34 | 29 |
| + tilt_left | 180 | **35** | 29 |
| + tilt_right | 237 | **37** | 26 |
| + sweep_left | 167 | **35** | 27 |
| + tilt_tip | 187 | 29 | 28 |
| + sweep_right | 213 | 31 | 25 |
| + sweep_center | 135 | 34 | 29 (gate correctly added 0) |

**Individual sources do beat the anchor** — `tilt_right` reaches 37 vs 34
(+3), `tilt_left` and `sweep_left` reach 35. The added coverage carries real
matchable signal. It is the indiscriminate *all-sources* merge that dilutes
it below baseline, exactly as the density-penalty control predicts.

## Selectivity sweep — a real, consistent dose-response

Adding only the top-K highest-quality new minutiae (mindtct's own
reliability), everything else identical:

| config | n | macro_round32 | macro_round35 |
|---|---|---|---|
| anchor alone | 135 | 34 | 29 |
| + top-10 | 145 | 34 | **32** |
| + top-20 | 155 | 34 | **32** |
| + top-30 | 165 | 34 | 28 |
| + top-40 | 175 | 29 | 25 |
| + top-60 | 195 | 28 | 25 |
| + top-85 | 220 | 28 | 25 |

Monotonic degradation past ~top-30, consistent across both references. The
**shape** of this curve is the robust finding: more indiscriminate merging
is monotonically worse. Top-10/top-20 matching on one reference and beating
by +3 on the other is the *promising* part, but it is chosen post-hoc on
n=1 capture with 2 references, so it is a hypothesis to validate, **not a
tuned parameter to trust.** Implemented as `fuse(max_added=...)`, default
`None` (unchanged Phase 1 behaviour) so nothing is silently tuned to this
one capture.

## Honest status

- The fusion premise (sources contribute real, matchable new coverage)
  survives — strengthened, if anything, by the per-source ablation.
- The **merge policy** is the thing that was wrong, not the registration
  model. Selectivity, not warp sophistication, is the live lever.
- The **measurement instrument** is a real bottleneck: 80%+ of added
  coverage lies outside the available references, and a density penalty of
  comparable size to the real effect sits on top of it. Judging a
  full-coverage superprint needs a full-coverage reference — which is
  exactly the standing "real ≥500-DPI scanner reference" blocker this
  project has carried since 2026-07-16.

## What this changes about Stage B (the NNS)

**Do not start Stage B training yet.** Stage B was scoped as a learned dense
registration network (retargeting `ml/deform_correct`'s existing
`DeformFieldUNet`) supervised by Stage A's TPS field. Stage A has now shown
that better registration is worth ~1 point against a ~6 point deficit — so a
network that learns to do registration *better* is optimising the wrong
term. Training it now would repeat this project's own documented pattern of
building a model before the metric it is supposed to move was understood
(`ml/mosaic_register`, `ridgeRestoreHybrid` v2).

The reframed Stage B, if it happens, is a **learned per-minutia reliability
model** — predict which candidate minutiae are worth merging, which is what
the selectivity result says actually matters. That is the original Phase 2
from the README, and it remains gated on real scanner references for
labels.
