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

## Follow-up #2: softened-content blending — the first real positive result in this whole track

Direct follow-up to both this file's own diagnosis (binarized content may
not have the smooth low-frequency structure `_multiband_combine` needs)
and the CTO's direct instruction to keep trying real fixes. The TRUE
pre-threshold Gabor signal turned out to be unreachable without
reimplementing real production geometry (`_upright_from_tip`,
crease-trim, vignette, final crop-to-bbox all run AFTER binarization,
confirmed by a real captured-shape mismatch: (2240,2986) raw vs. (410,431)
final) — correctly replaying that outside production code would be
exactly the kind of hand-copied-geometry risk this project has been
burned by before. Used a safe, zero-reimplementation-risk proxy instead
(`phase3c_continuous_blend.py`): Gaussian-blur each already-correct,
already-cropped/rotated print (`_AA_SIGMA`'s own antialiasing idea,
repurposed for compositing instead of display) before compositing,
binarize the composite once at the end instead of blending already-binary
content.

**Real result, sweeping `max_added` (the SAME selective-merge cap Stage A
validated, at the pixel-compositing level for the first time) at a fixed
blur_sigma=2.0:**

| max_added | macro_round32 | macro_round35 | beats anchor (2 refs) |
|---|---|---|---|
| anchor alone | 34 | 29 | — |
| 5 | 32 | 24 | 0/2 |
| 10 | 40 | 27 | 1/2 |
| **12** | **40** | **30** | **2/2** |
| **15** | **40** | **30** | **2/2** |
| **17** | **40** | **31** | **2/2** |
| 20 (original hard-edge run) | 34 (tie) | 23 | 0/2 |

**max_added in roughly 12–17 beats anchor-alone on BOTH informative
references — the first time any candidate in this entire fusion_brain
track (Phase 1, Stage A's point sets, every earlier Stage C image variant)
has done that.** Not a single lucky point: three separate values (12, 15,
17) all land in the same win band with tightly clustered scores, bracketed
by real losses on both sides (5 and 20) — a genuine, replicated
dose-response curve, the same shape Stage A's own point-set-level
selectivity sweep found, now confirmed to hold at the actual pixel/image
level once the blend target is soft-edged instead of hard-binary.
`blur_sigma` itself saturated quickly (2.0 and 4.0 gave IDENTICAL
re-thresholded scores) — the win is coming from the selectivity range
combined with softened content, not from tuning the blur amount further.

**Honest caveats, same standard this whole track has held throughout,
not relaxed for a positive result**: n=1 real capture, 2 real informative
references (both real cross-session captures of the same finger, not a
lab-grade ground truth), and `max_added≈12-17` was found by sweeping THIS
one capture's own data — a hypothesis worth a real go/no-go decision, not
a tuned production parameter to trust yet. The ink_scan reference (noise
floor, never counted) moved inconsistently across the same sweep (6, 5,
4, 4, 4) — further confirmation that reference is not informative, not a
contradiction of the real result on the two references that are.

**Revises this file's earlier "decisive negative" framing, precisely**:
hard-edge and phase-corrected compositing of already-binarized content
remain real, decisive negatives — that diagnosis holds. What's new is
that giving the blender softened, moderate-magnitude content instead
opens a real, replicated positive window this track had not found before.
Worth a real next step: more real captures to confirm the win band holds
beyond n=1, before this graduates past "promising, not yet validated."

## Second real capture: partial replication, not a clean repeat — and why, confirmed not guessed

CTO took a fresh real `fusion_v1` capture session specifically to test
whether the max_added≈12-17 win band above holds on a second, independent
capture (`43378ea7-9f08-4a44-abe1-8e420bc344d7`). Ran the identical sweep.

| max_added | macro_round32 | macro_round35 | beats (2 refs) |
|---|---|---|---|
| anchor alone | 26 | 18 | — |
| 5 | 34 (BEAT) | 17 (lose) | 1/2 |
| 10 | 31 (BEAT) | 17 (lose) | 1/2 |
| 12 | 31 (BEAT) | 17 (lose) | 1/2 |
| 15 | 29 (BEAT) | 17 (lose) | 1/2 |
| 17 | 29 (BEAT) | 18 (tie) | 1/2 |
| 20 | 25 (lose) | 18 (tie) | 0/2 |

**Real, partial replication — not the clean 2/2 the first capture showed.**
A genuine, consistent win on macro_round32 across a WIDE range (5 through
17, not just a narrow band), but macro_round35 never actually beats
anchor on this capture (best case: ties at max_added=17). One reference
corroborates the mechanism works; the other doesn't move enough to call it
replicated in full.

**Investigated why the contribution pattern looks so different from the
first capture (only `sweep_right` contributes almost anything) rather than
leaving it unexplained** — real, checkable answer, not a guess: on this
capture, ALL THREE tilt sources failed the SAME reliability gate this
track has used since Phase 1 (`fm.gate_sources`, min_inlier_frac=0.20 /
min_inlier_count=15) — real registration inlier counts too low to trust,
a genuine per-capture quality difference (plausibly softer/less-aligned
tilt shots this session), not a bug in anything built for Stage C. Of the
3 sweep sources that DID pass, `sweep_right` alone offered 57
unique-new-coverage candidates (mean quality 46.2) against `sweep_left`'s
5 and `sweep_center`'s 1 — the global quality-sorted cap naturally
concentrates on whichever source actually has real material to contribute
on a given capture, which on THIS capture was overwhelmingly one source
instead of four.

**Honest conclusion**: the mechanism (softened compositing + moderate
selectivity) produces a REAL improvement again, but not uniformly across
both references, and which sources even get a chance to contribute varies
capture-to-capture based on real, already-validated quality gating this
track already trusts. This is consistent with — not a contradiction of —
everything upstream in this track: real capture-to-capture variance in
which sources register well is expected, and n=2 real captures is still
far short of enough to trust `max_added≈12-17` as a tuned setting. It
does further support that this line of work is worth continuing, not that
it is already validated.

## Standing blocker, unchanged

Same as every phase before this one: real judgement of whether ANY of
this recovers or costs real matchability still needs the **real ≥500-DPI
full-pad scanner reference** this project has carried as a standing
blocker since 2026-07-16. The two macro references used here are real
cross-session captures of the same finger, not a lab-grade ground truth,
and the ink scan is a known noise floor (kept for continuity, never
counted toward the verdict). n=1 capture throughout, same caveat as every
other real number in this track.

## Real, important caveat found on visual review: the composite is NOT
## visually a single coherent print, in either version — "scored better"
## and "looks fused" are two different claims, and only the first is true

Direct visual review of both `..._composite_maxadded20.png` (hard-edge)
and `..._composite_softblend.png` (the bozorth3-winning version) for
`6b43c255` shows the SAME structural pattern in both: a clean core print
surrounded by several small, visibly DISCONNECTED patches of ridge
texture scattered around its edge — scalloped/circular in shape, not
blended into the core region at all. Softening the blend changed contrast
and seam smoothness at each patch's own boundary; it did not change the
patch SHAPE or connect them to each other or to the core.

**Root cause, confirmed in code, not a rendering bug**: both
`phase3_composite.py` and `phase3c_continuous_blend.py` call the same
`_keep_mask(kept_pts, a_shape, radius=KEEP_RADIUS_PX=24.0, ...)` —
compositing is restricted to a union of independent 24px-radius circles,
one per individually-kept minutia, not to a smooth contiguous region.
Kept minutiae are sparse and scattered by construction (`fm.fuse`'s own
selective-merge cap picks the globally highest-quality candidates
wherever they happen to fall), so their 24px discs mostly don't touch
each other — hence "small blobs stuck onto the sides," exactly matching
a real, independent visual report of this same pattern
(2026-08-26, CTO screenshot of a fusion_v1 composite).

**This does not contradict the bozorth3 result above** — bozorth3 scores
minutiae correspondence, which the composited patches genuinely add (the
whole reason the score moved). But it does mean the "first real positive
result" recorded above should NOT be read as "produces a coherent single
print" — it currently produces a core print with several small
disconnected ridge patches around it, which is real, matchability-
positive by the one metric tested, and visually nothing like a seamless
scanner-style print. Whether that visual discontinuity itself costs
something a real AFIS matcher would care about beyond what bozorth3
already captured is untested — bozorth3 doesn't penalize disconnected
regions the way a human eye (or possibly a different real matcher) might.

**Not yet fixed. Real, concrete next step, not yet built**: grow/dilate
each kept minutia's disc (or switch to a smooth alpha falloff sized to
merge neighboring discs) so nearby kept points' regions actually join
into one contiguous patch instead of leaving gaps between them — this is
a compositing-shape change, independent of the blend-softening fix
already validated above, and has not been tried.

## Disc-merging fix built + tested (2026-08-26) — real, decisive NEGATIVE

Direct follow-up to the caveat above: built `phase3d_merged_regions.py`,
identical to `phase3c_continuous_blend.py` (same registration, same
`fm.fuse` selective-merge cap, same soften-then-binarize-once policy)
except the keep-mask is now a morphological CLOSE over the union of all
sources' kept-point discs (`_keep_mask_merged`, elliptical kernel,
`CLOSE_RADIUS_PX`), so nearby discs bridge into one contiguous region
instead of staying as separate 24px blobs — the fix proposed to close the
visual-coherence gap.

**Real test, same capture (`6b43c255`) and same `max_added=15` that
previously won 2/2 informative references under the isolated-disc
version**: merging REVERSES the win. `macro_round32` 34→27 (was a win,
now a loss), `macro_round35` 29→22 (same). **0/2 informative references,
down from 2/2.** Confirmed not a tuning-sensitivity fluke: reran at a much
tighter bridging radius (`close_radius=12` vs. `30`) — the resulting image
differs by only 151 of 176,710 pixels (0.09%) and scores identically
(27/22 both times). The loss is structural, not a knob to nudge.

**Visually, the merged composite is also worse, not better** — sent for
direct review: two solid black rectangular blocks appear where the
merged region now spans, plus visible criss-crossing ridge lines, in
place of the previous clean (if disconnected) ridge texture in those same
patches.

**Real mechanism, not just "it got worse"**: the compositing weight for
each non-anchor source already excludes anywhere the anchor itself has
coverage (`inv_a_cov` term) — so the black blocks are NOT anchor/source
disagreement. They appear because merging pulls in the CORRIDOR between
two individually-validated kept points, and that corridor was never
itself checked for phase/orientation agreement — only the two endpoints
were. Where that newly-included corridor is covered by MORE THAN ONE
non-anchor source at once (two different sources' regions, previously
kept apart by the 24px discs, now both spanning the same merged area),
their independently-registered ridge lines disagree at that overlap
(residual non-rigid misalignment TPS didn't fully correct, or genuinely
different local ridge content between two different capture geometries),
and multiband-blending two sets of black ridge lines at conflicting
orientations does not average cleanly — it darkens toward solid black
rather than picking one.

**Conclusion: the isolated-disc "blobs" were not merely cosmetic — they
were incidentally protecting the composite from exactly this
inter-source disagreement**, by keeping each source's contribution
confined to a small, mostly-non-overlapping patch. Naively merging
neighboring regions removes that protection without adding anything to
replace it (no phase/orientation check on the newly-included corridor).
**Not adopting this fix.** A real next step, not yet built, if visual
coherence is revisited: gate the merge itself on real orientation
agreement between whichever sources would end up sharing the merged
region (only bridge two discs if their underlying ridge angle roughly
agrees in the gap between them), rather than a blind geometric distance
threshold — same standing discipline as everywhere else in this track:
measure before trusting a plausible-sounding fix.

## Angle-gated merge built + tested (2026-08-26) — and it first overturned
## phase3d's own conclusion, which was drawn from a conflated test

Built `phase3e_angle_gated_merge.py` to test the fix phase3d proposed
(only bridge two regions where their local ridge ORIENTATION agrees,
using production `afis_print._orientation_field`, read-only). Building it
surfaced a **real flaw in phase3d's own test design that invalidates
phase3d's stated conclusion**, and that is the more important finding of
the two.

**phase3d moved TWO variables at once, not one.** `phase3c` built the
keep mask PER SOURCE (`[m for m in fused if m.source == name]`) — each
source only ever contributed pixels near ITS OWN kept points. phase3d
replaced that with ONE GLOBAL mask over every source's kept points,
applied to every source — so each source additionally contributed
wherever its coverage happened to overlap some OTHER source's points.
That is a far larger change than "merge nearby discs," and it manufactures
exactly the multi-source overlap phase3d then blamed the regression on.
**phase3d's conclusion ("the isolated discs were protecting the composite
from cross-source disagreement") is therefore not established by that
test, and its solid-black-block artifact is substantially an artifact of
the conflation, not of merging.** Recorded here rather than quietly
corrected: the earlier entry stands as written, this supersedes it.

**Control run (per-source masking restored, merging only, no angle
gate)** on the same capture/settings phase3d failed at:

| variant | macro_round32 (anchor 34) | macro_round35 (anchor 29) | beats |
|---|---|---|---|
| phase3d (conflated global mask) | 27 | 22 | **0/2** |
| phase3e control (per-source, merged) | 31 | **31** | **1/2** |

Visually confirmed too: the control image has **no solid black blocks and
no crossing artifacts** — it is a single, substantially contiguous shape,
by far the most visually coherent composite this track has produced.

**The angle gate itself is inert.** Real measured diagnostics (the
instrumentation added precisely because phase3d's mechanism was inferred
rather than measured): multi-source overlap is only **1,055px of 23,870px
(4.4%)** on capture 1 and **268px of 14,590px (1.8%)** on capture 2. The
gate suppressed 499px and changed the output by **57 of 176,710 pixels
(0.03%)**, with **identical scores**. So cross-source ridge disagreement
is not a meaningful mechanism here at all — phase3d's diagnosis was wrong
about the cause as well as the magnitude.

## The real trade-off merging buys, measured across both captures

Sweeping `max_added` on the (correct) per-source merged variant, against
`phase3c`'s isolated-disc numbers on the same captures:

**Capture `6b43c255`** (anchor 34 / 29):

| max_added | isolated discs (phase3c) | merged (phase3e) |
|---|---|---|
| 10 | — | 34 tie / **31 win** → 1/2 |
| 12 | **40 win / 30 win → 2/2** | 31 / **31 win** → 1/2 |
| 15 | **40 win / 30 win → 2/2** | 31 / **31 win** → 1/2 |
| 17 | **40 win / 31 win → 2/2** | 32 / **30 win** → 1/2 |
| 20 | — | 32 / **30 win** → 1/2 |

**Capture `43378ea7`** (anchor 26 / 18), `max_added=15`: isolated discs
29 / 17 → 1/2; merged **20 / 17 → 0/2**.

**Consistent, reproducible finding across both real captures and five
settings: merging into contiguous regions costs real matchability on the
stronger reference** (capture 1: 40 → 31-32; capture 2: 29 → 20), while
holding or slightly improving the weaker one. The visual-coherence gain is
real and the matchability cost is real; they pull in opposite directions.

## Honest conclusion

The specific fix asked for (angle-gated merging) **does nothing measurable
here** — the mechanism it targets accounts for under 5% of composited
area. What the exercise actually produced is (a) a correction to phase3d's
own erroneous conclusion, and (b) a clean, quantified statement of the
genuine trade-off: **the blobby isolated-disc composite scores better; the
merged composite looks better.** Both are real; there is no setting tested
that gets both.

That is a product decision, not a tuning problem, and it should be made
explicitly rather than by picking whichever number looks best: if the
delivered artifact is judged by a matcher, isolated discs win; if it is
ever shown to a human or judged by eye, merged wins. Nothing here changes
the standing recommendation that Stage C's trustworthy deliverable remains
the minutiae TEMPLATE (Stage A/B), not the picture — and that production's
superprint image should stay the single best full-frame render it delivers
today. n=2 captures throughout, same standing caveat as every number in
this track.

## Validated-bridge merging (2026-08-26) — the CTO's hypothesis was right,
## is now quantified, and yields the first merge that costs nothing

CTO's read of the phase3e trade-off: *"if the blob beats the merge, that
means it more meaningfully reconstructs the ridges in the places it should
be. there needs to be a merged where ridges are reconstructed better and
according to the data given."* Tested directly. **Confirmed, with a
number.**

**The mechanism, measured.** Counting extracted minutiae on the two saved
composites (`6b43c255`, max_added=15): blobs 171 minutiae / 56,582 ink px;
naive merge 209 / 72,946. The selective merge validated exactly **15**
added minutiae — merging introduced **38 extra**, sitting in corridor
pixels no gate in this track ever checked (not `fm.gate_sources`, not
`fm.fuse`'s quality cap, not the coherence weight, which is a soft
multiplier rather than a veto). Stage A's own random-noise control already
established that template DENSITY alone carries a penalty comparable to
real added minutiae. So the naive merge pays for 38 unvetted points to
gain 15 vetted ones. That is exactly why it looks better and scores worse.

**Real bug found in the first fix attempt, worth recording.** The obvious
remedy — attenuate the compositing weight around unvalidated minutiae —
**cannot work**, and the reason is structural: `_multiband_combine`
normalizes by total weight, so wherever a single source covers a pixel the
weight cancels out entirely and the pixel survives at full value no matter
how small the weight. Measured: the suppression changed **1 pixel of
176,710** and left scores identical. Weight is not a veto; only a hard
zero removes content. Recorded because this invalidates any future "just
down-weight it" fix on this blender.

**What actually works — `phase3f_validated_merge.py`.** Rather than
filling corridors and then trying to remove what's bad (which also punches
holes, manufacturing the ridge terminations this whole exercise is trying
to avoid), never grow through unsupported territory in the first place:
draw the same validated discs, then join a PAIR of validated points with a
capsule **only if the corridor between them contains no unvalidated
minutia** (point-to-segment distance ≤ clearance). Contiguity grows only
along paths the data endorses; no interior holes, no unvetted fill.

**Real result, all three real captures, `max_added=15`:**

| capture | anchor | blobs (phase3c) | validated bridges | bridges drawn |
|---|---|---|---|---|
| `6b43c255` | 34 / 29 | **40 / 30 → 2/2** | **40 / 30 → 2/2** | 3 |
| `43378ea7` | 26 / 18 | 29 / 17 → 1/2 | 29 / 17 → 1/2 | 1 |
| `5181d451` (sunlight, new) | 16 / 21 | 21 / 19 → 1/2 | 21 / 19 → 1/2 | 12 |

**Matchability-neutral on every capture — it matches the best-known blob
score exactly while drawing real bridges**, unlike the naive merge which
cost 40→31 and 29→20. Composite minutiae counts are unchanged too (171 vs
171 on capture 1), confirming the bridges add no spurious features.

**Dose-response confirms the mechanism is the gate, not luck**
(`6b43c255`, varying corridor clearance):

| clearance | bridges let through | composite minutiae | round32 (34) | round35 (29) | beats |
|---|---|---|---|---|---|
| 24 (strict) | 6 rejected | 171 | **40** | **30** | **2/2** |
| 12 | 0 rejected | 174 | 34 tie | 26 | 0/2 |
| 6 | 0 rejected | 174 | 34 tie | 26 | 0/2 |
| no gate (phase3e) | all | 209 | 31 | 31 | 1/2 |

Relaxing the gate one step admits 6 more bridges, adds only **3** extra
minutiae — and costs **6 points** on one reference and **4** on the other.
Unvetted corridor content is expensive out of all proportion to its
volume. The strict gate is the correct operating point.

**The honest limitation, stated plainly.** The gate is strict enough that
it barely changes the picture: covered area moves by only +202px
(sunlight) and −641px (capture 1) versus the blob version. The reason is
itself the finding — sources present **119–134 unvalidated minutiae**
inside their contributing coverage against only **15 validated** ones, so
almost every candidate corridor is genuinely blocked. **The blobs are not
an arbitrary shape: they are very nearly the entire region where this
data is trustworthy.** A visually seamless merged print is not reachable
by better compositing policy alone, because the supporting data mostly is
not there — which is the same standing conclusion this track keeps
arriving at from new directions.

**Sunlight capture note**: `5181d451` (the new capture, deliberately shot
in sunlight) processed cleanly with no sunlight-specific failure —
registration, gating and compositing all behaved normally, and fusion
still beat anchor on one reference (16→21). Its anchor scores are lower
across the board (16/21 vs capture 1's 34/29), consistent with this
project's long-documented sunlight capture-quality problems, but that is a
capture-side effect, not a fusion one.
