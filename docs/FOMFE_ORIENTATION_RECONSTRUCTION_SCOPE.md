# Scope: FOMFE global orientation-field reconstruction (2026-08-04)

## Context

CTO observation, after the mask-boundary taper fix: "I have a feeling we can
reconstruct ridges way better, especially since we have points that can be
connected at certain points that clearly supposed to go together but
segmentation error or something else is distorting flow" — plus an explicit
ask to search for real published techniques rather than guess.

Web research surfaced **FOMFE** (Fingerprint Orientation Model based on 2D
Fourier Expansion — Wang, Hu, Phillips, IEEE TPAMI 2007) as a real, well-cited,
previously-untried lever for this pipeline: a **global** low-order
trigonometric-polynomial fit to the orientation field, as opposed to a local
one. This is a different axis of change than every denoise-then-Gabor hybrid
already in `afis_print.py` (`pyfingHybrid`/`coherenceDiff`/`nnsHybrid`), all of
which clean the *image* and then re-run the existing *local* orientation
estimator on the cleaned result. FOMFE instead replaces only how the
orientation field itself is estimated, which is a more direct answer to "local
segmentation noise is distorting flow that should otherwise connect."

Sources:
- [A Fingerprint Orientation Model Based on 2D Fourier Expansion (FOMFE)](https://ieeexplore.ieee.org/document/4107562/)
- [Weighted 2D Fourier expansion model for low-quality orientation estimation](https://www.academia.edu/21280652/Estimation_of_fingerprint_orientation_field_by_weighted_2D_fourier_expansion_model)
- [Orientation field reconstruction via orthogonal polynomials](https://www.sciencedirect.com/science/article/abs/pii/S0031320314001320)

## What was built

`afis_print.py`:
- `_fomfe_orientation_field(img, mask, bsize, order, blend)` — fits
  `cos(2θ)`/`sin(2θ)` independently via weighted least squares (weight = local
  gradient-coherence energy) against a small tensor-product cos/sin basis over
  normalized image coordinates (order 4 → ~97 real basis functions), then
  evaluates the fitted model densely over the whole image.
- Wired as a new `enhance='fomfe'` variant alongside the existing hybrid
  modes — same non-blocking, self-skip-on-failure contract as everything else
  in this module.
- **CTO's own refinement, round 2**: the pure-global version measurably hurt
  real matchability at whorl cores/deltas (a low-order global model can't
  represent genuinely tight local curvature there, so it overwrites real
  structure, not just noise). Fixed by **confidence-weighted blending**
  (`blend=True`, the default) with the existing local field
  (`_orientation_field`) instead of a full replacement: trust local where
  local gradient-coherence is genuinely strong, fall back toward the global
  fit only where it's weak. Weight is percentile-normalized per capture
  (`_FOMFE_BLEND_PERCENTILE`, default 90 — conservative) so it adapts to each
  capture's own contrast/pressure range rather than a fixed cutoff.

All of this is self-contained, unused-by-default scaffold code — **not**
referenced anywhere in `main.py`'s production `_afis_variants` list.

## Results

### Round 1 — small sample (8 real captures, 1 genuine-pair user / 6 pairs)
- Real NFIQ2 (locally built NIST binary): pure-global beat the tuned `gabor`
  baseline on 7/8 captures, mean **+3.6** — the first denoise/orientation
  hybrid this whole project has tried with a clean net NFIQ2 gain.
- Real SourceAFIS matchability (CTO's own 4 genuine cross-session captures, 6
  pairs): mean **74.2 → 58.1**, a real loss, concentrated in 3 pairs all
  involving one capture (`382cc4b2`).
- Swept model order (1–8): none recovered the baseline on that capture's
  pairs.
- Confidence-weighted blend (round 2) measurably closed the gap: mean
  **58.1 → 66.1** (percentile=70) **→ 69.1** (percentile=90). Real NFIQ2 held
  (mean +4.0). At percentile=90, 3 of 6 pairs beat baseline outright — only
  the 3 pairs involving `382cc4b2` stayed below it, which read at the time
  like a capture-specific issue.

### Round 2 — broad validation (22 real captures, 10 independent genuine-pair
users / 15 pairs), per the CTO's explicit ask not to trust the round-1 sample
- Real NFIQ2: mean **+2.36** (was +4.0) — still net positive, but a
  meaningfully smaller effect once tested broadly. 13/22 improved, 3 flat,
  6/22 regressed (was 1/8).
- Real SourceAFIS matchability: mean **55.65 → 50.03**, a real ~10% loss.
  8/15 pairs improved, 7/15 regressed — essentially a coin flip, not a clean
  win.
- **The `382cc4b2`-specific theory did not hold up.** A different pair, not
  involving that capture at all (`367fb854` vs `de540624`), produced the
  single biggest regression in the whole set (91.0 → 27.5) — bigger than
  anything `382cc4b2` produced. This looks like a real, broader property of
  the technique: it helps some real captures a lot (+19.5, +13.5, +10.9) and
  hurts others a lot (-63.5, -32.3, -16.3), fairly unpredictably, netting
  slightly negative on average — not a bug isolated to one capture's
  calibration.

## Conclusion

**Not wired into production**, and not recommended even as an *additive*
max-of-variants candidate. The instinct that "additive can only help" doesn't
apply cleanly here: `main.py`'s variant selection picks the winner by NFIQ2
score, and this technique can win that internal quality race on exactly the
captures where it's real-matchability-negative — the same "the proxy is
foolable" failure mode already documented elsewhere in this project (see
`gaborPyfingField` in `CLAUDE.md`), just for a new variant.

This is a genuine, honestly-negative research result on the axis that
actually matters (real matchability), arrived at through the project's
standing discipline — measure before shipping, on real data, at a scale big
enough not to be fooled by a lucky/unlucky small sample. Kept as documented,
available scaffold code (same treatment as `gaborVarFreq`/`fidelity`/
`gaborPyfingField`/`deepFocus*`) in case a future session wants to revisit it
with a different angle.

## Possible future directions (not started)

- **Understand the swing, not just its sign.** Characterize what
  distinguishes the captures FOMFE helps a lot from the ones it hurts a lot —
  if there's a detectable per-capture signal (e.g. overall coherence
  variance, mask size, native wavelength), the blend could be gated per-
  capture instead of applied uniformly.
- **A genuinely regional blend** (closer to the CTO's original "outer edges
  only" framing, revisited with position AND confidence both informing the
  weight) rather than confidence alone.
- **A held-out validation split** — all tuning here (percentile 70 vs 90) was
  chosen by looking at the same 6-pair set used to report the result; a
  cleaner methodology would tune on one subset and confirm on another before
  trusting a specific parameter value.
- Not pursued further this round given the fusion-of-sweep-architecture work
  is next in line and untested end-to-end on a real capture (see CLAUDE.md /
  `docs/BURST_VIDEO_HYBRID_SCOPE.md` Phase 4) — the CTO flagged that as
  potentially higher-leverage and is capturing fresh real data for it soon.
