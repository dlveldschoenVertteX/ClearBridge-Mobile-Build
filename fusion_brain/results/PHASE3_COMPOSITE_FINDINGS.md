# Stage C — compositing into a real superprint IMAGE: built, run for real, decisive negative

Stage A (point-set level) found that TPS-corrected, *selectively* merged
minutiae can match or modestly beat anchor-alone (top-10/20 on the real
capture, `results/PHASE2_TPS_FINDINGS.md`). Stage C asks the question the
README always said was separate: does turning that same selective, TPS-
registered merge into an actual delivered PICTURE work, or does image
compositing reopen the phase-mismatch failure mode every prior pixel-fusion
attempt in this project hit?

**Built and run for real** (`phase3_composite.py`), not simulated:
rigid-register + TPS-refine every source onto the anchor (identical to
Stage A, no new registration code), run the same validated selective merge
(`fm.fuse(max_added=20)`), then for each source that actually contributed
kept points: warp its PRINT IMAGE (not just its minutiae) into anchor space
via the same rigid transform + `tps.warp_image` (built in Stage A,
exercised on a real image for the first time here), restrict compositing to
a keep-radius disk around each specific kept point (not the source's whole
new-coverage region — the pixel-space analog of Stage A's own selectivity
finding), weight by local ridge coherence (the same signal
`afis_print._fuse_flash_ambient` already uses), and blend with
`sfm_pipeline._multiband_combine` (Laplacian-pyramid seam blending, built
for the cylindrical SfM path, unused elsewhere — its first use outside that
path). Source pixels are masked out of the anchor's own territory entirely
(`1 - anchor_coverage`), matching `fuse_minutiae.py`'s own "keep the
anchor's own minutiae untouched" policy exactly.

## Real result, same capture and references as every prior phase

| candidate | ink_scan | macro_round32 | macro_round35 |
|---|---|---|---|
| anchor alone | 5 | **34** | **29** |
| composite image, hard-edge keep mask | 6 | 34 (ties) | 23 (**−6**) |
| composite image, feathered keep mask (8px) | 9 | 27 (**−7**) | 27 (**−2**) |

Neither variant beats anchor-alone on either informative reference (0/2
both times). The hard-edge version ties on one, loses on the other;
feathering the mask edge — motivated by the real observation that
`_multiband_combine` needs a smoothly-varying weight to do its blending job,
and a hard 0/1 mask hands it a knife-cut seam instead — made the RESULT
worse, not better, on the reference it had been tying.

## Why, confirmed visually, not just from the score

Compared the composite image directly against the clean anchor-alone
render on the same capture (both saved to
`results/cache_fusion_v1/6b43c255-0d4_*`, visually reviewed):

- **Hard-edge variant**: the anchor's own whorl is clean and coherent
  (matches the anchor-alone image exactly, since anchor territory is never
  touched). Around its perimeter, composited patches from each source
  appear as visually DISCONNECTED islands — each internally has real ridge
  texture (they are real warped photographs, not noise), but they do not
  continue the anchor's own ridge flow across the boundary. TPS corrects
  *position* — a kept minutia really does land near where its physical
  counterpart sits — but says nothing about ridge *phase*, i.e. whether the
  specific black/white line crossing that boundary lines up with the line
  it is supposed to extend. It usually does not, because it was never
  fitted to.
- **Feathered variant**: the hard patch edges soften as intended, but in
  the transition zone the Gaussian-blended pixels show visible ghosting —
  faint duplicate/offset ridge lines superimposed on the anchor's real
  ones, most visible near the top and left of the whorl. This is a WORSE
  input for a minutiae matcher than a disconnected-but-locally-clean patch:
  blended out-of-phase lines manufacture exactly the spurious
  bifurcations/endings bozorth3/mindtct punish hardest, right where the
  print reads as ambiguous rather than merely incomplete.

Both failure modes are the SAME mechanism the README's own "why minutiae
space, not pixel space" section predicted from the start, for every prior
pixel-fusion attempt in this project (sweep cross-zone mosaic, field-domain
fusion, `focusZoneSplice`): **compositing pixels across a boundary where
ridge phase was never corrected manufactures spurious minutiae, and a
minutiae matcher punishes that more than it rewards the added coverage.**
What is new and real here is that this is the FIRST time that prediction
has been tested with genuinely correct POSITION (TPS-registered, not
rigid) and genuinely SELECTIVE compositing (gated on the same validated
top-20 policy, not indiscriminate) — and the failure mode still reproduces.
Position correction alone does not fix it; phase was never the thing TPS
(as built here) corrects.

## Honest conclusion

**Stage C's photometric compositing approach, as currently built, is a
real, decisive negative** — not inconclusive, not "needs more tuning."
Tried the direct, well-motivated follow-up (feathering, to give the
blender a smooth weight to work with) and it made things worse, which
rules out "the seam just needs softening" as the fix. The actual gap is
ridge-phase alignment, which neither rigid nor TPS registration (fit to
minutiae *positions*, never to local ridge *phase*) provides.

**Consistent with the README's own standing framing**: minutiae-space
fusion (Stage A/B) remains the live, validated approach — it never needed
pixel-level phase agreement, which is exactly why it survived where every
pixel-space attempt in this project's history has failed, including this
one. **Do not pursue further pixel-compositing tuning on this mechanism**
(more feathering, different keep radii, different blend weightings) — the
mechanism itself is the problem, and no amount of blend-parameter tuning
corrects a phase mismatch that was never modelled. A real fix would need
either (a) a phase-aware registration step (estimate and correct local
ridge phase offset, not just position, before compositing — a genuinely
different and harder problem than anything built so far in this track), or
(b) accepting that Stage C's real deliverable is the minutiae TEMPLATE
(Stage A/B's own output), not a picture, and that production's real
superprint image should stay the single best full-frame render it already
delivers today, with fusion operating only at the matching-template level
production doesn't currently expose. Either is a real product/architecture
decision, not something to guess at here.

## Follow-up: local phase-correlation correction — tested, also negative, and it sharpens the diagnosis

Direct follow-up on this file's own closing recommendation ("a real fix
would need a phase-aware registration step"). Built the cheapest classical
version before considering anything learned (`phase3b_phase_correct.py`):
every contributing source's TPS-warped image genuinely OVERLAPS the
anchor's own real coverage in substantial real territory (10,900–21,400px
per source on this capture) — territory `phase3_composite.py`'s own
`1 - anchor_coverage` gate throws away before compositing, never otherwise
used. Both images show the same real physical ridges there, so any
sub-pixel translational disagreement between them, measured directly via
Fourier phase correlation (`cv2.phaseCorrelate`), IS the local phase
residual TPS left uncorrected — if the "phase gap hides inside dist_tol"
hypothesis is right, this should find it.

**Real result: the measured shifts are tiny — under 0.6px for all four
sources** (tilt_left −0.04/−0.04, tilt_right −0.24/0.16, sweep_left
0.59/0.09, sweep_right 0.05/−0.17 — against a ~9px ridge period). Applying
them anyway did not help; macro_round32 got measurably WORSE (34 → 24, a
bigger loss than the un-corrected hard-edge version's tie). Visually the
corrected composite is near-identical to the uncorrected one — expected,
given the corrections found were sub-pixel.

**This is informative, not just another negative.** It rules out "a
constant per-source translational phase offset, small enough to hide
inside the minutiae correspondence tolerance" as the mechanism — that was
the specific, well-motivated hypothesis this test existed to check, and
the real overlap data says it isn't there. TPS + rigid registration were
already correctly aligned in POSITION at these overlap points; the visible
disconnected-island artifact survives despite that.

**Real, untested candidate mechanism this points at instead**: every
image composited so far is already hard-binarized (pure black/white ridge
map), not continuous-tone. `_multiband_combine` was built and validated for
smooth continuous-tone photographic content (the cylindrical SfM texture
path) — Laplacian-pyramid blending's whole mechanism (hide seams by
blending broad LOW-frequency content, which for a photo means smooth
brightness/gradient information) may not have an equivalent to lean on in
a binary image, where the "low-frequency" component is just local average
darkness, not real structure. Blending two already-binarized ridge maps
may be closer to blending two square waves than two photographs. Not
tested this round — the real next cheap experiment, if this thread is
picked up again, is compositing the CONTINUOUS-TONE enhanced render
(before the final binarization step) and thresholding once at the end,
rather than blending already-binary content.

## Standing blocker, unchanged

Same as every phase before this one: real judgement of whether ANY of
this recovers or costs real matchability still needs the **real ≥500-DPI
full-pad scanner reference** this project has carried as a standing
blocker since 2026-07-16. The two macro references used here are real
cross-session captures of the same finger, not a lab-grade ground truth,
and the ink scan is a known noise floor (kept for continuity, never
counted toward the verdict). n=1 capture throughout, same caveat as every
other real number in this track.
