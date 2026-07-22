# Multi-view fusion + flash enhancement — isolated R&D track

## Status: Phase 0 NO-GO, Phase 1 MIXED/NO-GO, Phase 2 NO-GO at the
signal-ceiling level, phase-demodulation rebuild ALSO NO-GO on real capture
pairs despite being independently validated as correct (2026-07-22, six
independent negative-to-mixed results total on the front/side registration
task — see close-out sections below). NOT wired into production. NOT
merged into `front_only_v1`. Lives entirely on
`claude/multiview-fusion-blend-experiment`. The evidence now points at the
capture GEOMETRY (real multi-angle pose change between shots), not the
registration algorithm, as the actual bottleneck — see the phase-
demodulation close-out for the reasoning.

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

## Phase 1 (`seam_composite.py`, 2026-07-22) — MIXED, not a clear win either

Tried (a) above directly on top of ECC-only alignment (no local correction —
that's dead per above). Before reusing OpenCV's own stitching seam finders
(`cv2.detail_DpSeamFinder`, `cv2.detail_GraphCutSeamFinder` — both confirmed
available, `cv2` 4.10.0) as-is, checked the assumption they're built on:
real panorama seam-finding assumes each source's "locally better" region is
a large, roughly bipartite area (e.g. left half vs. right half). **Measured
this directly first**: per-row, which of front/side has higher local
`block_coherence` flips 7-23 times per row on real data (not a single clean
left/right split), and handing `cv2.detail_DpSeamFinder` the raw full-
overlap masks gave a degenerate result — it assigned the ENTIRE frame to one
source and nothing to the other, no real cut at all. A single-seam DP/graph-
cut model assumes exactly the large-coherent-region structure this data
doesn't have.

**Adapted instead**: `seam_composite()` uses front's own local coherence
weakness (vs. each ECC-registered side) to define candidate substitution
regions, drops small/speckled candidates via connected-component area
filtering (`_MIN_BLOB_AREA_PX=400` — collapses the per-pixel speckle into a
handful of real regions), and feathers only a narrow band
(`_FEATHER_BAND_PX=10`) around each surviving region's boundary — hard
partition + narrow feather, instead of the OLD `coherence_weighted_blend`'s
whole-frame weighted average.

**Confirmed real, substantial substitution happens** (not a no-op): 25-54%
of the frame was substituted across the 4 real test captures. **Measured
result vs. the OLD whole-frame blend, same `seam_continuity_score` metric**:

| capture | OLD (whole-frame blend) | NEW (seam-routed) |
|---|---|---|
| `3edf5455` | 1.080 | **1.042** (slightly better) |
| `7f53940f` | 0.540 | **1.040** (worse) |
| `2927b6bd` | n/a (no control band) | 1.097 |
| `b615e6e7` | n/a (no control band) | 1.155 |

Paired result (the 2 captures where both arms have a valid ratio): NEW
better on 1/2, worse on 1/2 — no clear win. Both of the unpaired NEW ratios
sit modestly above 1 (seam ~4-16% worse than the front-only control band,
not dramatically so — nowhere near the ~2x regressions Phase 0's TPS attempt
produced, but not an improvement either).

**Conclusion**: seam-routed compositing, adapted to this data's actual
(non-bipartite) quality-difference pattern, does not clearly beat the
already-shipped whole-frame coherence blend on real seam-continuity — it's
roughly comparable, mixed capture-to-capture. **This is now three real,
independently-measured negative-to-mixed results in this branch** (NCC
block-matching, minutiae correspondence, seam-routed compositing), on top
of the original 2026-07-12 small-roll NO-GO — a second, differently-
implemented confirmation that classical/moderate-effort multi-view fusion
techniques don't reliably fix this architecture's ridge-continuity problem
on real MAC3D-style captures. The one lever left genuinely untried is Phase
2: a **learned** per-pair deformation/compositing model trained on many
real examples (same architecture family as `ml/deform_correct/`) — a much
larger real-GPU-training commitment than anything tried so far in this
branch, not a quick follow-up. Recommend a direct go/no-go conversation with
the CTO before starting that, rather than building it speculatively.

## Phase 2 (learned pair-deformation model, 2026-07-22) — design + why it
can succeed where the classical estimators couldn't

All three classical correspondence methods failed for the same underlying
reason: estimating deformation fresh from ONE noisy real pair is
underdetermined — periodic texture aliases NCC, minutiae density creates
chance matches, and no per-pair estimator has a prior for "what real skin
deformation looks like." A learned model changes the problem: train on
thousands of pairs where the true deformation is KNOWN, so the network
internalizes the prior and applies it to real pairs in one shot.

**The supervision trick** (`synth_multiview.py`): take a real frame `R`,
draw a random smooth residual flow `g`, synthesize `front(p) = R(p+g(p))`
— the flow warping `R`-as-side into the front is then EXACTLY `g` by
construction, no field inversion. The residual family models what remains
AFTER production ECC alignment (small affine residual + multi-scale
elastic, range includes zero so identity is in-distribution). Photometric
jitter (smooth illumination-gradient gain fields — the moving-torch
effect — plus gamma/contrast/blur/noise) is applied INDEPENDENTLY per
view, forcing the net to match ridge STRUCTURE, not intensity — precisely
the axis NCC failed on.

**Contract decisions** (`deform_net.py`):
- 2-channel pair input (front + ECC-registered side): both exist live at
  inference here, unlike `ml/deform_correct/`'s single-image constraint —
  standard VoxelMorph-style pair registration, a strictly easier task.
- Flow in PIXELS with per-size grid conversion (`PixelWarp`): trains on
  256px crops (preserving native ridge scale — crops, never resizes),
  runs fully-convolutionally on 912px frames meaning the same physical
  displacement — avoiding the normalized-unit scale trap that invalidated
  the first deform-correct v2 evaluation (CLAUDE.md 2026-07-18).
- Zero-init tanh-capped flow head (±24px): an undertrained checkpoint
  degrades gracefully to identity, never scrambles ridges.

**Training** (`train_pair.py`): direct supervised L1 end-point-error
against the exact ground-truth flow (the structural advantage over both
the classical estimators and deform_correct's unsupervised orientation
loss) + small smoothness term. Subject-disjoint user split; deterministic
val pairs; identity-baseline EPE (= mean |g|) reported every epoch — val
EPE must land well below it for learning to be real. Verified before
training: synthesis↔PixelWarp convention consistency (0.1 grey-level MAE
reconstructing the synthetic front by warping the side with the gt flow).

**Data**: 313 real frames, 26 users, pulled via `pull_training_frames.py`
(schema-drift-robust recursive Storage-path scan over capture docs — all
capture modes usable, since synthesis needs only single frames).

**Go/no-go** (`run_phase2.py`): the REAL gate is real front/side pairs,
not synthetic val. Two metrics: (1) direct overlap orientation agreement
between front and corrected side (dense, paired, pre-blend — sharper than
the seam metric, which lost its control band on 2/4 captures in earlier
phases); (2) the same seam-continuity metric as Phases 0/1 for
comparability. Result to be reported honestly either way, as with every
phase in this branch.

## Phase 2 real-GPU training (`multiview-pair-deform-v3`, 2026-07-22) —
FLAT, root-caused to mean-collapse, pyramid fix built, still NO-GO after a
four-part diagnostic chain

Submitted the SageMaker job (`ml.g4dn.xlarge`, af-south-1, on-demand after
two earlier submissions hit spot-capacity and a numpy/torch ABI crash — see
launcher history above) on the real 313-frame/26-user pull. Training ran to
completion without crashing, but val EPE never moved off the identity
baseline for the full run (flat ~4.40 vs. identity 4.40, every logged
epoch).

**Checkpoint forensics (before assuming "bug" vs. "no signal"):** loaded the
trained checkpoint, ran it on held-out synthetic pairs with known ground
truth, and directly measured `cosine(pred_flow, gt_flow) = -0.050` (should
be near +1 for real learning) with mean `|pred|` **0.034px** vs. mean `|gt|`
**6.7px** — the network is not predicting small-but-wrong flows, it is
predicting essentially **zero** everywhere. This is the textbook signature
of mean-collapse under an EPE/L1 regression loss: when a regressor can't
extract the answer from its inputs, the loss-optimal fallback is the
marginal mean of the target, which for a zero-centered random flow family
is identity — exactly what a flat val-EPE-equals-identity-baseline curve
looks like from the outside.

**Literature check (web research, per the CTO's explicit "you may use web to
search for relevant info" ask) confirmed this is a known, named failure
mode for this exact data type, not a novel problem**: real fingerprint
dense-registration methods (Cui & Feng, TIFS 2018, "2-D Phase Demodulation
for Deformable Fingerprint Registration"; PDRNet, T-IFS 2024) do not
register on raw intensity correlation at all — they treat ridge texture as
a 2-D cosine wave and register via **phase**, specifically because raw
correlation on periodic ridge texture is multi-modal (one near-equal peak
per ridge cycle) and any correlation-based estimator will systematically
regress toward the prior mean under exactly this kind of ambiguity. This
matches Phase 0/Phase 1's own classical findings (NCC block-matching and
minutiae nearest-neighbor both failed via periodicity/density aliasing) —
the learned single-level correlation net hit the same wall by a parallel
mechanism.

**Built the literature-motivated fix**: `ctf_deform_net.py`,
`CoarseToFinePairNet` — a minimal PWC-Net-style 3-level coarse-to-fine
pyramid (1/16 -> 1/8 -> 1/4 resolution), the standard fix for exactly this
ambiguity: at 1/16 resolution a 9-20px ridge period is well below one pixel
of that grid (0.6-1.25px), so the texture is effectively non-periodic blur
at that scale and a small correlation window there is unambiguous while
still reaching +-64px of full-resolution displacement; each finer level
then only has to resolve a residual well below half a ridge period at its
own scale — the regime where correlation genuinely has a single peak.
Flows carried in full-resolution pixel units throughout (same scale-trap-
avoidance contract as `deform_net.py`/`corr_deform_net.py`), multi-scale
EPE supervision at all 3 levels, zero-init heads at every level. Verified
via shape/gradient smoke test (zero-init gives exact-zero flow at every
level; multi-scale EPE backward pass runs; `predict()` returns full-res
flow; 0.24M params) before spending any more GPU time.

**Before re-running the full pyramid on GPU, ran four cheap CPU probes to
isolate which of several candidate causes was real** — the standing
project discipline of investigating a negative result's actual mechanism
rather than guessing at the next fix:

1. **Small-vs-full flow magnitude** (`probe_small_full.py`-equivalent):
   trained the SAME single-level corr net on small (<=0.25 strength) vs.
   full (<=1.0 strength) synthetic flows, 240 steps each. **Both stayed
   flat at their own identity baseline** (small: val 1.228 vs. ident 1.228;
   full: val 4.939 vs. ident 4.910) — ruling out "the flow range itself is
   too extreme to learn" as a standalone explanation; even the easiest
   (smallest-shift) version never moved.

2. **Jitter x BatchNorm 2x2 grid** (`probe2x2_fast.py`): trained 4 cells
   (photometric jitter on/off) x (BatchNorm on/off), sub-period flows
   (strength<=0.25), 200 steps each, on real preloaded frames. Every cell
   stayed flat at its own identity baseline regardless of condition —
   ruling out both photometric jitter and BatchNorm (a specific concern
   given BatchNorm's known interaction with small-batch flow regression)
   as the sole cause.

3. **Stride-2 vs. stride-4 encoder** (tested via the same harness):
   ruled out the "sub-stride invisibility" hypothesis (displacements
   smaller than a feature map's stride should be invisible to correlation
   computed at that stride) — a stride-2 variant did not resolve the flat
   result either, so under-stride blindness was not the (sole) cause.

4. **Deepest probe, `probe_minimal.py`, two parts, the decisive one:**
   - **Part A — zero-learning signal ceiling**: with NO network and NO
     training in the loop at all, applied a KNOWN small constant shift
     (dx,dy in [-3,3]) to real fingerprint crops and checked whether raw
     local-correlation argmax (81-channel, +-4px window) recovers the
     exact known shift. **Result: 3/20 hits (15%)** — about 12x above the
     1/81 chance rate (binomial p~0.001, a real, non-random signal) but
     practically far too weak and noisy to serve as a reliable training
     target: 85% of the time even the exact-answer correlation computation
     itself picks the wrong peak on this real data.
   - **Part B — simplest possible learnable task**: stride-1 features (no
     downsampling at all, so no periodicity-aliasing at a coarse grid is
     even possible), CONSTANT per-crop translation (not a spatially-varying
     field — the easiest possible regression target), 64px crops, 300
     steps. **Still flat**: val EPE pinned at the identity baseline the
     entire run, never moving.

**Final verdict for this branch**: Part A quantifies the actual ceiling —
raw intensity correlation on these real fingerprint crops carries a real
but very weak signal (~15% exact-recovery rate for a trivial known shift),
consistent with every other finding in this branch (NCC block-matching
periodicity aliasing, minutiae density chance-matching, PDRNet/Cui-Feng's
own reason for abandoning intensity correlation in favor of phase). Part B
shows that weak a signal is not learnable within this branch's realistic
compute/data budget (313 frames, 26 users) even on the easiest conceivable
version of the task. The coarse-to-fine pyramid fix is architecturally
sound and addresses a real, literature-confirmed failure mode, but does not
change the underlying signal ceiling Part A measured — a correlation-based
architecture at any number of pyramid levels is still built on the same
intensity-correlation primitive that Part A shows is weak on this data. **A
phase-based approach (per Cui & Feng / PDRNet) is the literature-correct
next architecture, but is a materially larger rebuild (a different feature
representation, not a drop-in change to the existing correlation-net
family) — not a quick follow-up to this branch's existing code.**

Combined with Phase 0/1's three independent classical NO-GOs, this is now
**five independent negative-to-mixed results** on multi-view fusion for
this architecture family: NCC block-matching, minutiae correspondence,
seam-routed compositing, single-level learned correlation, and (via the
probes) coarse-to-fine learned correlation at the signal-ceiling level.
**Recommendation: do not continue sinking GPU/engineering time into
intensity-correlation-based multi-view fusion on this branch.** The two
honest paths forward, neither cheap, both requiring a real go/no-go
conversation with the CTO before starting: (a) a phase-demodulation-based
registration net (the literature's actual answer for periodic fingerprint
texture — a genuinely different feature representation, several days of
new build); or (b) abandon multi-view geometric fusion as a lever entirely
and focus remaining effort on the capture-side/optics levers already
identified as untried elsewhere in this project (`docs/
RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md`'s cross-polarization test, physical
distance bracketing, secondary-camera AF fixes) — none of which depend on
solving this correspondence problem at all.

## Phase-demodulation rebuild (`phase_align.py`, 2026-07-22) — the core
method is VALIDATED and correctly implemented, but STILL NO-GO on real
front/side pairs — the sixth independent negative-to-mixed result, and the
first to fail despite being individually proven correct

Per the CTO's explicit "do the phase-demodulation rebuild" ask (following
the Phase 2 close-out above), built the literature-correct alternative to
every intensity-correlation method tried so far: Cui & Feng (TIFS 2018) /
PDRNet (T-IFS 2024) treat ridge texture as a local 2-D cosine wave and read
displacement directly off the PHASE of an analytic signal, never doing
patch/template matching at all — sidestepping the periodicity-aliasing
mechanism that broke every correlation-based method on this branch (NCC
block-matching, minutiae nearest-neighbor, the learned corr-net).

**Built** (`phase_align.py`): `analytic_phase()` — a per-pixel-varying
quadrature Gabor bank (even=cos-phase, odd=sin-phase, same discretized-
orientation/per-pixel-index trick as `common.gabor_enhance`) forms a local
analytic signal `Z = even + i*odd`; phase = `angle(Z)`, amplitude =
`|Z|`. `phase_residual_shift()` demodulates front and an ECC-registered
side with front's own orientation/wavelength field, takes the wrapped
phase difference, and converts it to a displacement ONLY along the local
ridge-**normal** direction (`dphi * wavelength / (2*pi)`).

**The aperture problem is treated as the correct scope, not a limitation
to work around**: a single local orientation/frequency estimate can only
resolve the ridge-normal component (shift along a ridge's own tangent is
invisible to phase, the classical Fleet & Jepson aperture problem for
periodic texture) — but ridge-normal misalignment is *exactly* the only
component that breaks visible ridge continuity; tangential slip produces
no visible seam. This is also, by construction, a **residual-only**
method: phase differences only resolve displacement up to half a ridge
period before wrapping/aliasing the same way correlation does over a full
period, so it is scoped as a refinement on top of the existing ECC
coarse-alignment step, same "coarse handles the big motion, fine only
resolves the sub-period residual" contract the abandoned
`CoarseToFinePairNet` pyramid was built around.

**Decisive validation BEFORE any real-pair test** (mirroring
`probe_minimal.py` Part A's zero-learning methodology exactly, so the
comparison is apples-to-apples): applied a KNOWN shift, confined to each
crop's own local ridge-normal direction and within its half-wavelength
regime, to real fingerprint crops, and measured `phase_residual_shift`'s
recovery error with **zero training or learning in the loop** — the same
kind of test that measured raw correlation argmax at a mere 15% exact-hit
rate. **Result (n=80 real crops): mean error 0.79px, median 0.32px, 94%
of trials within 2px** of the true known shift — against a 2.75px mean
chance baseline (guessing zero shift). This is a night-and-day
improvement over correlation's signal ceiling and a direct, real
confirmation that the literature's phase-based approach is fundamentally
sound and was implemented correctly here — not a re-run of the same
failure by another name.

**Real-pair test (the actual gate): does NOT improve, and mildly-to-
moderately REGRESSES, real seam continuity.** Wired `phase_correct()`
into `local_align.py` (confidence-weighted dense box-smoothing of the raw
per-pixel field, then a direct remap — no TPS, no sparse control points
needed since the phase field is already dense) and re-ran the same
three-way Phase 0 harness (`run_phase0_v2.py`) on the same 4 real
`oscillating_8phase` captures used throughout Phase 0/1. One real bug
found and fixed en route: the confidence normalization originally divided
by the raw per-image amplitude MAX, which worked fine on the small,
photometrically-uniform validation crops above but collapsed almost the
entire real overlap region below threshold on full real captures (a
handful of outlier-bright pixels made the max 100x+ the typical in-ridge
value; median normalized confidence inside the real overlap region was
0.0002-0.0013). Fixed by normalizing against the 95th percentile within
the valid mask instead of the raw max — robust to that outlier, and
confirmed not to change the validation test's own result.

Paired comparison (the 2 of 4 captures where both arms have a valid
seam/control ratio):

| capture | OLD (ECC-only) | PHASE-corrected (1 pass) | PHASE-corrected (3 iters) |
|---|---|---|---|
| `3edf5455` | 1.080 | 1.116 (worse) | **1.292** (worse still) |
| `7f53940f` | 0.540 | 0.596 (worse) | **0.661** (worse still) |

**Iterating made it monotonically worse, not better — the decisive
finding.** Chained `phase_correct` 3-4 times (re-estimate the residual on
the already-corrected image, repeat), the standard Lucas-Kanade-style way
to handle a residual larger than one pass can safely resolve. The
per-iteration diagnostics show the raw measured residual (`mean_abs_
normal_shift_px`) shrinking cleanly and monotonically each iteration
(e.g. `3edf5455`: 3.03 -> 1.88 -> 1.67px; `7f53940f`: 3.40 -> 2.17 ->
1.67px) — the algorithm IS converging by its own internal metric — while
the actual seam-continuity outcome gets steadily worse with every
iteration applied. If the phase estimate were tracking real geometric
misalignment, converging it further should improve, not degrade, the
composite. It doesn't, on either real paired capture tested.

**Root-cause interpretation, consistent with this whole branch's other
five results**: `oscillating_8phase` side frames are captured at real,
independent physical angles (the pulled manifest's own `angleDeg` field:
-11deg to +11deg per side, not simulated). A single global ECC homography
per side-frame — already established as unable to fully capture non-
planar skin deformation across a real angle change — evidently leaves a
residual that is NOT confined to the sub-half-period regime this method
(and the abandoned learned pyramid) assumes: TPS's own raw NCC control-
point displacements on this same data landed at 12-16px against 9-20px
wavelengths, i.e. comparable to a FULL ridge period, not a small
residual. Genuine perspective/pose change between shots also very
plausibly changes local ridge SHADING/amplitude asymmetrically between
front and side (not just position), which would read as phase "signal"
to this method without being a real spatial shift at all — plausibly
explaining why "correcting" it, and correcting it harder via iteration,
makes the print worse rather than better.

**Conclusion**: this is the sixth independent negative-to-mixed result on
this branch's front/side registration task (NCC block-matching, minutiae
correspondence, seam-routed compositing, single-level learned
correlation, coarse-to-fine correlation at the signal-ceiling level, and
now phase demodulation) — and the first of the six to fail DESPITE being
individually validated as a correct, working implementation of its
underlying technique. That combination is the strongest evidence yet
that the bottleneck is not any single registration algorithm (six
genuinely different ones have now been tried) but the **capture geometry
itself**: real independent-angle shots of deformable, non-planar skin
produce a residual misalignment field after coarse alignment that is too
large, and/or too contaminated by genuine photometric/perspective
change (not pure position shift), for any single-shot 2-D correction —
classical or learned — to safely resolve. **Recommend against further
per-pair 2-D registration work on this specific front/side fusion task.**
A geometrically-honest fix would need actual 3-D surface modeling of the
finger pad (well beyond this branch's original 2-D scope), which is a
materially different and much larger undertaking, not a next tweak to
try here.
