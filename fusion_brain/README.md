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
  **DONE — PASSED.** See `results/PHASE0_FINDINGS.md`.
- **Phase 0b — does small-angle TILT reveal edge detail?** (`phase0b_tilt_check.py`)
  **DONE — PASSED**, 22-32x a face-on control. `results/PHASE0B_TILT_FINDINGS.md`.
- **Phase 0c — does the premise hold on REAL fusion_capture output?**
  (`phase0c_real_fusion_capture.py`) **DONE — PASSED** on 5/6 sources, 6th
  explained. `results/PHASE0C_REAL_CAPTURE_FINDINGS.md`.
- **Phase 1 — classical consensus fusion** (`fuse_minutiae.py`,
  `phase1_consensus_fusion.py`): rule-based, no ML. Must beat
  single-best-candidate on real matchability to proceed.
  **DONE — FAILED.** Ties on the (noise-floor) ink scan, LOSES on both
  cross-session references (34→28, 29→25). `results/PHASE1_CONSENSUS_FUSION_FINDINGS.md`.

## Why Phase 1 failed, and what replaces it

Phase 1 registered each source onto the anchor with a **rigid similarity
transform** (rotate + scale + translate) and merged the minutiae that landed
in new territory. Rigid registration is the wrong model for skin: between
two captures the pad genuinely deforms non-rigidly, so a rigid fit leaves
real residual displacement everywhere except near wherever it happened to
lock. Merged points therefore land slightly *off* where the same physical
minutia actually sits, and a matcher reads near-miss correspondences as
competing evidence rather than support. That is the most likely mechanism
behind losing 34→28 while adding 63% more points.

**The fix is the technique this project has flagged as an unbuilt gap since
2026-07-17** (see `functions/processEnhanceAndScore/geom_correct.py`, whose
`elastic_flatten()` is still an identity placeholder, and CLAUDE.md's own
prime-directive entry: "no TPS/RTPS elastic-deformation correction"):
**use the matched minutiae as CONTROL POINTS for a thin-plate-spline (TPS)
elastic warp**, not merely as evidence for one global rigid fit.

This is the classical fingerprint-mosaicking method (Ross & Jain,
"Fingerprint Mosaicking Using Thin Plate Splines"; Bazen & Gerez, "Elastic
minutiae matching by means of thin plate spline models"), and the modern
learned version is Cui/Feng et al., *Dense Registration and Mosaicking of
Fingerprints by Training an End-to-End Network* (IEEE TIFS,
arXiv:2004.05972) — a Siamese embedding + encoder-decoder regressing a
per-pixel displacement field, trained on synthesised ground-truth
deformations, used for both registration AND mosaicking.

## Roadmap (current plan — Stage A in progress)

- **Stage A — classical TPS elastic registration** (`tps.py`,
  `phase2_tps_fusion.py`, `phase2b_ablation.py`). **DONE — hypothesis
  largely REFUTED, and the controls found the real mechanism.** TPS is
  built and numerically self-tested, fits cleanly on all real sources, but
  bought only 28→29 against a 34→28 deficit. The controls then showed why:
  a random-noise control of the same COUNT cost about as much as the real
  added minutiae (template-density penalty, largely independent of point
  quality), only ~10-20% of added minutiae even fall inside the reference's
  extent (underpowered instrument), and a selectivity sweep found a real
  monotonic dose-response — top-10/20 matches or beats anchor, top-85
  loses. **Registration model was not the problem; merge policy is.**
  Full detail: `results/PHASE2_TPS_FINDINGS.md`.
- **Stage B — REFRAMED, not started.** Originally scoped as a learned dense
  registration network (retargeting `ml/deform_correct`'s existing
  `DeformFieldUNet`, supervised by Stage A's TPS field). Stage A's result
  says better registration is worth ~1 point against a ~6 point deficit, so
  that network would optimise the wrong term — and building a model before
  understanding the metric is this project's own documented failure pattern
  (`ml/mosaic_register`, `ridgeRestoreHybrid` v2). The live version is a
  **learned per-minutia reliability model**: predict which candidate
  minutiae are worth merging, which is what the selectivity result says
  actually matters. Still gated on real scanner references for labels.
- **Stage C — compositing into a real superprint image.** `tps.warp_image`
  + `sfm_pipeline._multiband_combine()`, gated by the same coherence-
  confidence check `_fuse_flash_ambient` uses, restricted to the same
  selectively-kept minutiae Stage A validated (`phase3_composite.py`).
  Hard-edge and phase-correlation-corrected compositing of already-
  binarized content are both real, decisive negatives (0/2 informative
  references, TPS position was already correct at the real measured
  overlap — see `results/PHASE3_COMPOSITE_FINDINGS.md`). **Follow-up
  found the first real positive result in this track's history**
  (`phase3c_continuous_blend.py`): compositing SOFTENED (not hard-binary)
  content, binarizing once at the end, at a moderate selective-merge cap
  (`max_added` in roughly 12-17) beats anchor-alone on BOTH informative
  references on the first capture, partially replicated (1/2 references)
  on a second. **Promising, not yet validated** — n=2 captures, same
  standing caveat as everything else here; needs more real captures
  before this becomes a trusted parameter rather than a hypothesis.
  **Important caveat found on direct visual review, 2026-08-26**: the
  composite is NOT a visually coherent single print in either version —
  it's a clean core print with several small, disconnected circular
  patches of ridge texture stuck around its edge (root cause:
  `_keep_mask`'s 24px-radius discs, one per kept minutia, mostly don't
  touch each other). The bozorth3 score genuinely improves (it scores
  minutiae correspondence, which the patches do add), but "scores
  better" and "looks fused" are two separate claims — only the first is
  currently true. The proposed fix (merge/dilate neighboring discs into
  contiguous regions) was then built and tested twice
  (`phase3d_merged_regions.py`, superseded; `phase3e_angle_gated_merge.py`,
  correct): merging DOES produce a visually coherent single shape, but
  consistently COSTS real matchability on the stronger reference across
  both real captures and five settings (40→31 and 29→20). The
  orientation-gated refinement is measurably inert (targets <5% of
  composited area; changes 0.03% of pixels, identical scores). Net: the
  blobby version scores better, the merged version looks better, and no
  tested setting gets both — a product call, not a tuning problem. Full
  detail, including a correction to phase3d's own erroneous conclusion
  (drawn from a conflated test): `results/PHASE3_COMPOSITE_FINDINGS.md`.

## The real blocker, stated plainly

Stage A's controls surfaced a measurement problem, not just a method
problem: **80-88% of what fusion adds lies outside the available
references' own coverage**, and a template-density penalty of comparable
magnitude to the real effect sits on top of that. A wider-coverage
superprint cannot be fairly judged against a narrower-coverage reference.
Decisively measuring this needs the **real ≥500-DPI full-pad scanner
reference** this project has carried as a standing blocker since
2026-07-16 — the same blocker `docs/FIDELITY_WALL_SCOPE.md` and the
Notion "Multi-Frame Fusion Strategy" page both identify as the unlock.

Validation is unchanged throughout: real bozorth3/SourceAFIS against real
references, gated on beating single-best-candidate. That standard is what
correctly killed Phase 1.
