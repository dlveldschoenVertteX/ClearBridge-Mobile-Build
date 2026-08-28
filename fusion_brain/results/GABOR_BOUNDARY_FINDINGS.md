# Layer 5 — enhancement (2026-08-28, round 47)

Fifth layer of the architecture pass. Two parts: an architecture-level
question (why do two enhancement models exist, and does the answer still
hold), and a new correctness hypothesis in the AFIS Gabor path specifically
(the one every production variant routes through).

## Architecture question: why two enhancement paths, and is that still earned

`main.py` selects the delivered print from whichever of two independent
pipelines scores higher real NFIQ2 -- the AFIS binarized Gabor print
(`afis_print.py`, `nfiqSource: afis`) or the NNS continuous-tone print
(`enhancement_pipeline.py`, `nfiqSource: cylindrical`). Checked with real
data rather than assumed: across 120 real `front_only_v1` captures,
**AFIS wins 119/120 (99%)**; NNS wins exactly 1, by a real +10.4 margin
(34.0 vs 44.4) when it does. Same split holds on captures since 2026-08-01
(76/77, 99%).

This is a legitimate "rare but real" fallback, not dead weight -- the same
max-of-variants philosophy the whole pipeline runs on (a candidate that
wins 1% of the time and by a real double-digit margin when it does is worth
keeping, same as any of the low-win-rate AFIS variants in round 29's own
win-rate table). Not recommending removing the NNS path. Recorded here so a
future round has the real number instead of re-deriving it.

## New hypothesis: does the default Gabor path leak background into real pad content?

The default `enhance='gabor'` branch (every production variant that has
ever won selection routes through this) computes:

    norm = _normalize(g8)                # FULL FRAME, g8 unmasked
    orient = _orientation_field(norm)     # boxFilter(_BLOCK=16) + Gaussian(_ORIENT_SMOOTH=15)
    enh = _gabor_enhance(norm, orient, wl)  # kernel radius ~18-39px at wl 9-20

`binimg[mask==0]=255` only runs AFTER this, discarding background OUTPUT --
it cannot undo a boundary-adjacent PAD pixel's orientation/Gabor response
having been computed partly from background content within kernel reach.
`_FADE_INSET_PX=25` (the band that keeps some Gabor output near the edge,
applied further downstream) overlaps this same reach, so real delivered
ridge content near the pad edge could plausibly be background-influenced,
not just wasted computation on discarded pixels.

This is a different intervention from the already-refuted Phase 7-8
"mask-aware `_normalize`" experiment (byte-identical there, because
`_normalize` reduces to a pure global affine map). Block/kernel-level
orientation and Gabor filtering are not affine-invariant the same way --
they respond to local gradient/contrast content directly.

**Fix candidate**: replace background with the in-mask mean, feathered at
the boundary (`_GABOR_BOUNDARY_FEATHER_SIGMA=8`, a much narrower feather
than `_FADE_INSET_PX=25` -- deliberately, since the goal is suppressing
background close to the boundary, not softening a wide band of it) so this
cannot manufacture the "ridge terminating on one curve" artifact
`_FADE_INSET_PX` itself exists to avoid. Gated behind
`_GABOR_BOUNDARY_FEATHER` (default `False`), wired only into the default
gabor branch -- every other `enhance=` path is untouched.

## Result: real, consistent, negative

**n=24, real NFIQ2 binary, same production `freq_normalize=True` path:
feathered mean 66.79 vs production 69.58 (delta -2.79). Feathered better on
8, worse on 16, tied on 0.**

Trend was stable throughout the run -- never crossed into net-positive at
any checkpoint (n=4: -2.75; n=8: -3.13; n=14: -3.64; n=20: consistent). Not
a late-sample artifact.

Same shape as rounds 43/45/46: a change that removes real background
influence from where the pad is actually being reconstructed, and NFIQ2
scores it worse more often than not. The mechanism most consistent with
this project's own established prime-directive thesis: NFIQ2 rewards
dense, high-frequency, ridge-*like* texture, and background content bleeding
into near-boundary orientation/Gabor response is itself exactly that kind
of texture -- suppressing it can read as "less print-like" to NFIQ2 even
when it makes the reconstruction more faithful to the real pad.

## Held, not shipped

`_GABOR_BOUNDARY_FEATHER` stays `False`. Production is unchanged. Same
standing caveat as every "correctness cost NFIQ2" finding in this project:
this needs the real >=500dpi matchability reference to settle whether the
feathered version is actually a better print despite scoring worse, or
whether it's genuinely worse (e.g. the narrow 8px feather itself introduces
a soft-edge artifact of its own). NFIQ2 alone cannot distinguish those.
