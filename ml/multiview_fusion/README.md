# Multi-view fusion + flash enhancement — isolated R&D track

## Status: Phase 0 NO-GO (2026-07-22), root cause identified, real next step
proposed below. NOT wired into production. NOT merged into `front_only_v1`.
Lives entirely on `claude/multiview-fusion-blend-experiment`.

## Why this exists

The CTO proposed capturing 4-8 frames while slowly rotating the thumb
(alternating flash/ambient), aligning them with 2D methods, blending into
one sharper composite, then running the existing Gabor/binarization on top.

This project already tried almost exactly this once
(`ml/mac3d_enhance/SMALL_ROLL_SCOPE.md`, tested 2026-07-12) and got a real
"NO-GO": it recovered genuine ridge detail (+45-69% edge coherence, measured)
but blending multiple views of deformable skin introduced sub-pixel ridge
discontinuities at the seams, breaking ridge continuity.

A code-level re-investigation pinned down exactly why: the prior attempt
(`afis_print._front_anchored_mosaic`) used a single GLOBAL homography per
side-frame (`cv2.findTransformECC`, `MOTION_HOMOGRAPHY`) plus a single-scale
coherence-weighted linear blend (`afis_print._block_coherence`) — no
local/piecewise deformation modeling, no seam-optimization, no multi-band
blending anywhere in the codebase. The likely real root cause is geometric
(a single global homography can't capture how non-planar, elastic skin
deforms differently region-to-region between shots), not purely photometric.

Web research found a real, established academic sub-field —
"fingerprint mosaicking for small-area sensors" — that solved a
near-identical problem with techniques never tried here: coarse
ECC/homography alignment -> **local nonlinear deformation correction
(Thin Plate Spline)** -> **seam-routed compositing** (route the blend seam
through low-ridge-content regions, feather only right at the seam).

## Isolation rules (do not violate)

1. Never edit `functions/processEnhanceAndScore/main.py`'s `_afis_variants`
   tuple or `_download_oscillating_frames`.
2. Never edit `clearbridge_beta/lib/front_capture_controller.dart` or
   `front_capture_screen.dart` (the production `front_only_v1` flow).
3. Never run `.github/workflows/deploy-functions.yml` (`workflow_dispatch`)
   from this branch — that is the actual production-deploy trigger.
   Pushing this branch only triggers harmless APK-build/landing-page jobs
   (`build.yml`), confirmed via direct inspection of both workflow files.
4. Per this project's own established convention (see `ml/deform_correct/
   dataset.py`'s own docstring), this module does NOT import
   `functions/processEnhanceAndScore/afis_print.py` directly — it ports the
   specific techniques it needs (`_block_coherence`, `_orientation_field`,
   the ECC/homography coarse-alignment step) as self-contained functions in
   `common.py`, dependency-light, so this experiment can never accidentally
   couple to or destabilize the production file.

## Files

- `common.py` — self-contained ports of `_block_coherence`,
  `_orientation_field`, and the ECC/homography coarse-alignment step
  `_front_anchored_mosaic` already uses (that part never failed — reused
  as-is, not reinvented).
- `local_align.py` — **Phase 0**: adds a dense local correspondence step
  (block-matching, gated by ridge coherence) on top of the coarse ECC
  alignment, then fits `cv2.createThinPlateSplineShapeTransformer` to warp
  the side frame through the local correction before blending. Isolates ONE
  variable: does local geometric correction fix the seam even with the OLD
  blend left unchanged?
- `continuity_metric.py` — the previously-missing direct measurement of the
  actual failure mode (seam ridge-continuity), instead of only inferring it
  from a whole-print NFIQ2/SourceAFIS drop as the 2026-07-12 test did:
  orientation-field discontinuity across the seam band, plus a minutiae-
  density-anomaly check via NBIS `mindtct`.
- `pull_real_captures.py` — pulls the real `oscillating_8phase` capture
  library (front + side frames) from Firestore/Storage, adapting
  `scripts/backfill_nfiq2.py`'s credential pattern.
- `seam_composite.py` — **Phase 1** (not started): seam-routed compositing,
  only built if Phase 0's go/no-go passes.
- `deform_net.py` / `synth_multiview.py` — **Phase 2** (not started): a
  learned per-pair deformation net, only built if Phase 1 passes AND the
  classical correspondence step is visibly the bottleneck.

## Go/no-go discipline

Every phase is measured against the SAME real captures three ways: the old
`mosaicFreq` (`_front_anchored_mosaic`) result, the current single-frame
`front_only_v1` production baseline (same finger), and the new fusion
result — real NFIQ2, SourceAFIS genuine/impostor separation, and the new
continuity metric. A phase must clear the continuity bar AND at minimum
match the single-frame baseline before the next phase starts. Report the
honest result either way, same discipline as every other experiment in this
project (`ml/deform_correct/README.md`, `CLAUDE.md`).

## Phase 0 result (2026-07-22): NO-GO — root cause is NCC block-matching
itself, not a tuning problem

Ran `run_phase0.py` against 4 real `oscillating_8phase` captures pulled via
`pull_real_captures.py` (`2927b6bd`, `3edf5455`, `7f53940f`, `b615e6e7`; 2-3
side frames each after ECC's own `corrcoef<0.45` gate dropped a few). Compared
seam-continuity `ratio` (seam orientation-discontinuity / front-only control
band; >1 = seam is measurably worse than baseline noise) for OLD (ECC-only)
vs. NEW (TPS-corrected on top of ECC), same unchanged blend for both.

**Direct paired result** (the only 2 captures where both conditions produced
a valid ratio — the other 2 had `control_discontinuity: null`, meaning ECC-
only's own contributor mask left too little front-only area for a control
band):

| capture | OLD (ECC-only) | NEW (TPS-corrected) |
|---|---|---|
| `3edf5455` | 1.080 | **1.152** (worse) |
| `7f53940f` | 0.540 | **1.033** (worse) |

TPS correction made the seam measurably *worse* in both real paired
comparisons, not better.

**Investigated why before accepting that verdict** (same discipline as
every other finding in this project). First pass: `tps_diagnostics` showed
`max_disp_px` identically `19.799px` (`= sqrt(2) * _SEARCH_RADIUS`, i.e. the
exact corner of the ±14px search window) in *all 10* side-frame fits across
all 4 captures — not a coincidence. A direct point-level check found 22-33%
of raw "control points" landing within 2px of the search window's boundary,
clustered at its diagonal corners: a matchTemplate boundary artifact, not
real correspondences. Added edge-clamp rejection + a neighbor-consistency
outlier filter and widened the search radius 14->20px (see `local_align.py`,
`_reject_neighbor_outliers`) — this did NOT fix the underlying problem, it
just thinned the point count (112->26, 231->43 on one test pair) while the
survivors still clustered at 15-20px displacement instead of near zero.

**Decisive follow-up experiment**: re-ran the raw block match at 4 different
search radii (R=6/10/14/20) on the same real pair. Median "best match"
displacement scaled almost linearly with window size (7.8 / 12.2 / 16.6 /
22.8px) while mean NCC confidence stayed flat (~0.57-0.60) at every radius,
and the fraction of matches landing within 3px of the already-good
ECC-predicted position never exceeded ~2% at ANY radius tested. **This is
the classic signature of NCC template-matching failing on periodic texture**:
fingerprint ridges (measured elsewhere in this project at 9-20+px native
wavelength) give the correlation surface many near-equal peaks, one per
ridge cycle, so the reported "global best" match is essentially unconstrained
by the window rather than anchored to true local structure — the window size
itself, not genuine correspondence, determines how far away the "match" ends
up. Feeding these into a TPS solve fits a spurious high-order warp to
noise, which directly explains the paired-comparison regression above.

**Conclusion**: this rules out **naive NCC block-matching** as a correspondence
method for this data, but does NOT rule out the underlying hypothesis that
local nonlinear geometric correction between views could still help — the
academic literature this plan cites never proposed plain block-matching in
the first place; periodic-texture correspondence needs to be either
minutiae-based (sparse, discrete points immune to periodicity aliasing — NBIS
`mindtct` is already vendored in this repo, `functions/nfiq2_service/vendor/
nbis/`, and this project already has a working Python client,
`mindtct_client.py`) or phase-correlation-based with an explicit ridge-period
consistency check. **Proposed next step, not yet started, needs a go-ahead
before more implementation time is spent**: swap `local_align.py`'s
correspondence step from raw NCC block-matching to minutiae-pair matching
(extract minutiae via `mindtct` on both the front anchor and each ECC-aligned
side frame, correspond by nearest-neighbor-in-position-and-orientation within
a small radius, fit TPS to the surviving minutiae pairs instead of a dense
grid) — a genuinely different, not-yet-tried correspondence method, before
concluding the whole local-correction direction is a dead end.

## Minutiae-based correspondence (`minutiae_align.py`, 2026-07-22) — ALSO
NO-GO, same failure signature via a genuinely different method

Built exactly the proposed next step: `common.gabor_binarize()` (a port of
`afis_print.generate()`'s default Gabor+binarize chain — confirmed necessary
first, since mindtct detects **zero** minutiae on a raw fingerphoto and 406
on the same capture after this chain) feeds `mindtct -m1` on both the front
anchor and each ECC-registered side frame, correspondence by greedy nearest-
neighbor gated on BOTH position (`_MATCH_RADIUS_PX`) and ridge-angle
agreement (`_MATCH_ANGLE_DEG`) — a genuinely different method from dense NCC
block-matching, since minutiae are sparse discrete points, not generic image
patches, and shouldn't be fooled by ridge periodicity the same way.

**Measured the same failure signature, via a different mechanism.** Re-ran
the radius-scaling diagnostic (same test as Phase 0's decisive experiment,
now on minutiae): median match displacement again scaled almost linearly
with the match radius (R=10/15/20/30/45 -> median disp 8.1/10.3/12.9/20.2/
28.4px) instead of converging to a stable small value. Root cause here is
different from the NCC case but equally real: real minutiae density on
these captures (~400 over a ~900x900px pad) gives an *expected* ~1.4 chance
candidates within a 30px radius purely from density, regardless of whether
any of them is the true corresponding point — a greedy nearest-neighbor
match with no global consistency constraint can't tell a real correspondence
from a nearby chance one at this density.

**Added the standard remedy and it still failed**: fit `cv2.estimateAffine
Partial2D(..., method=cv2.RANSAC)` on top of the raw greedy matches to keep
only a geometrically-CONSISTENT subset (real correspondences from the same
finger should share one locally-affine transform; chance matches should not).
On the same real pair, RANSAC found only **8 inliers out of 121** raw
matches even at a generous 5px reprojection threshold — i.e. no strong
consensus exists among these matches at all, and the few "inliers" RANSAC
did accept still spanned 6-32px displacement, not a tight cluster.

**Conclusion**: three independent correspondence methods now fail the same
way on this real data — dense NCC block-matching (periodicity aliasing),
minutiae nearest-neighbor (density-driven chance matching), and RANSAC-
filtered minutiae (no geometric consensus to filter toward). This is no
longer plausibly a single implementation bug; it's evidence that **classical,
per-pair point correspondence cannot reliably recover local elastic
deformation from these front/side view pairs** — likely because the true
residual misalignment after ECC is either small and swamped by minutiae-
detection noise between two different photos of deformable skin under
different lighting/angle, or genuinely large and non-smooth in a way a
sparse point-correspondence estimate (with no learned prior) can't safely
disambiguate from noise on this little real data per pair.

**This rules out any classical local-TPS-correction approach for this
architecture, not just the two correspondence methods tried.** The two
remaining honest options, neither yet started: (a) skip local geometric
correction entirely and go straight to **seam-routed compositing** (Phase 1's
technique) on top of the existing ECC-only alignment — since routing the
blend seam through low-disagreement regions doesn't require solving
correspondence at all, it might still reduce visible discontinuity even
without a working local correction step; or (b) a **learned** per-pair
deformation model (Phase 2, `ml/deform_correct/`'s own architecture family)
trained on many real examples, since a network can learn to disambiguate
true correspondence from noise in a way a fresh per-pair classical estimate
cannot. Recommend (a) next, since it's far cheaper to test and doesn't
depend on ever solving the correspondence problem this section just spent
two rounds failing to solve.
