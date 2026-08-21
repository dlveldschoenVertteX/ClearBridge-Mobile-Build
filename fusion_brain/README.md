# fusion_brain — minutiae-space fusion research track

**Status: Phase 0 (premise validation). Nothing here is wired into production.**

## What this is

A research track testing whether combining multiple capture architectures
(front V1 burst, small-offset focus-zone stills, camera-2 macro, sweep
zones) into ONE fused fingerprint template beats simply picking the single
best candidate — which is what production does today.

## Why minutiae space, not pixel space

Every prior fusion attempt in this project operated on IMAGES and lost to a
single un-fused candidate on real matchability:

| attempt | result |
|---|---|
| sweep cross-zone mosaic (pixel blend) | +13.04 sep vs. +28.44 for one un-fused zone |
| field-domain orientation fusion (`fieldfuse`) | -0.60 sep, lost to the pixel mosaic it was meant to beat |
| `focusZoneSplice` (hard region replace, feathered seam) | 0.771 vs. 1.004 native, won 4/10 |
| zone reduction (3-zone, 5-zone configs) | every fused config lost to anchor-only |

**Mechanism**: skin is non-rigid. Between captures the pad deforms, so even
with perfect global registration the local ridge PHASE differs. Wherever two
images are composited, out-of-phase ridges manufacture spurious ridge
endings/bifurcations at the seam. Minutiae matchers (bozorth3, SourceAFIS)
punish spurious minutiae heavily, so image fusion buys coverage and pays
more than it earns.

The literature says the same: minutiae-level merging "can tolerate
non-linear distortions better than image mosaicking" (Ross et al., image vs.
feature mosaicing). Multi-impression template synthesis is reported to
increase coverage, restore missing minutiae, AND remove spurious ones.

So: never composite pixels. Each source stays whole and internally
phase-coherent; fuse the extracted MINUTIAE instead.

## Isolation guarantees (how to pivot back)

- Everything lives under `fusion_brain/`. Nothing outside it was modified.
- Imports from `functions/processEnhanceAndScore/` are READ-ONLY (via
  sys.path) so this scores against the real production pipeline rather than
  a reimplementation. No production file is written to.
- No Firebase writes. Firestore/Storage access is read-only.
- Not referenced by `main.py`, `clearbridge_beta/`, or any CI job.
- **To abandon: `rm -rf fusion_brain/`.** Zero impact on anything else.

## Phases (each gated on the previous)

- **Phase 0 — premise check** (`phase0_premise_check.py`): do the different
  architectures actually contribute DISTINCT, non-spurious minutiae? If each
  source's unique contribution is noise, the whole premise collapses and
  nothing further gets built. Cheapest possible test of the core idea.
- **Phase 1 — classical consensus fusion**: rule-based voting, no ML. Must
  beat single-best-candidate on real SourceAFIS separation to proceed.
- **Phase 2 — learned per-minutia reliability**: only if Phase 1 shows
  signal. Gated on real scanner references for labels (the single ink scan
  cannot separate genuine from impostor and cannot label training data).
- **Phase 3 — learned per-region source weighting.**
