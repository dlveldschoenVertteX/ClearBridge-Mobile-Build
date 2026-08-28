# Layer 3 — masking & segmentation (2026-08-27, round 45)

Third layer of the step-by-step architecture pass. Audited on the real
production population with real Firestore/Storage access, not on cached
fragments.

## Population

132 real `front_only_v1` captures carry a recorded `afisMask`:

| mask | n | share |
|---|---|---|
| `guide+flashdiff` | 44 | 37% |
| `guide` (bare, refinement rejected or unavailable) | 41 | 34% |
| `guide+unet` | 33 | 28% |
| `unet` (unguided path) | 2 | 2% |

So a third of production already ships with no content-aware refinement at
all. That is the fact the rest of this layer turns on.

## Two hypotheses of mine, both refuted before shipping

**(a) "The U-Net over-segments and the area-only accept gate mislabels the
result as `guide+<det>` when the mask actually used is just the dilated
guide."** False. On the 24 real recent captures every accepted mask cuts
36–78% of the bound (median 48%); *zero* cases below a 10% cut. The label is
honest. My earlier local numbers (55–62% of frame) were my own error: that set
included `front_focuszone_*` stills, which are diagnostic frames the mask path
never runs on.

**(b) "Guide-seeded component selection fixes the U-Net."** As a straight swap
it is a wash — 9/13 either way. It recovers `474b4d6a` and loses `774f2252`,
where the guide-centre pixel lands in a small neighbouring component that
fails the ≥3% area floor.

## What is real: the two detectors are not equally reliable

| detector | used on | failed to locate the pad |
|---|---|---|
| `_flash_diff_mask` | 11/24 (46%) | **0** |
| `_unet_mask` | 13/24 (54%) | **4 (31%)** |

Every U-Net failure is **mis-location**, never over- or under-segmentation: a
real blob exists, it just does not overlap the guide (survivors of the bound
intersection: 0%, 3%, 10%, 13%).

**Traceable cause.** `ml/thumb_seg/build_dataset.py` generates this model's
pseudo-labels by calling `_segment_via_flash_diff(amb, fl, _KSIZE)` **with no
seed** — i.e. with the pre-round-16 frame-centre seed, the exact 555px error
round 16 found and fixed in production but never regenerated labels for. The
model was distilled from a detector aimed at the wrong point, so it learned
"the near-camera blob near the frame centre" rather than "the guided pad". The
measured failure shape is precisely what that predicts.

**Harness representativeness, checked rather than assumed**: the harness feeds
a single ambient/flash pair where production feeds the full burst. Flash-diff
availability came out at 46% either way — an exact match to the real
population — so the simplification is validated. The U-Net/bare split differs
slightly (38/17 vs production's 29/25), in the conservative direction: the
harness credits the U-Net *more* than production does, so the 31% miss rate
understates rather than overstates the problem.

## The control that changes the recommendation

Every masking round so far compared detectors against **each other** —
`guide+flashdiff` vs `guide+unet` (round 20), forced-unet on matched captures
(round 21), seed fixes (round 16). None ran the control the whole layer rests
on: **refinement ON vs refinement OFF**, same capture, same everything else.

**Result, n=24 real recent captures, real NFIQ2 binary, identical inputs with
only the masking decision varied:**

| arm | mean NFIQ2 |
|---|---|
| production refinement | 69.58 |
| **bare guide, refinement disabled** | **72.50** |

**delta -2.92; refinement worse on 13, better on 7, tied on 4.** Split by
detector it is the same both ways -- `guide+flashdiff` -3.5 (n=11),
`guide+unet` -3.6 (n=9) -- so *which* detector runs is not the variable.
Content-aware refinement itself is what costs NFIQ2 here.

### The area confound, tested rather than waved at

Refinement changes mask area (measured 0.53-1.08x the bare guide, mean 0.83x),
and NFIQ2 partly rewards valid ridge area, so a size effect had to be ruled
out before reading this as a shape/content result.

`diag_area_confound.py`, n=20 captures where refinement actually changed the
mask: **correlation(area ratio, dNFIQ2) r = +0.317**, i.e. area explains only
about 10% of the variance. The two most informative points run against the
area story outright: the single biggest shrink (`1cc301a8`, 0.37x area) scored
the **best** delta at +8, while an essentially area-neutral mask (`5363a49b`,
0.96x) scored **-9**.

So this is not refinement making the mask smaller. It is refinement making the
mask a different SHAPE -- and that shape scores worse.

### Third arm: the dilated guide alone, no detector at all

If refinement's cost were really about area, the DILATED guide (the same
outer bound refinement is clipped to, ~1.69x the tight guide's area, no
content-aware selection whatsoever) should sit somewhere between bare and
refined, or beat both if bigger is simply better.

    refined (production)     69.71
    bare guide (tight)       72.50
    dilated guide (no det.)  60.67

**The dilated guide is the WORST of the three arms**, by a wide margin --
worse than refined, worse than bare. This rules out "more area helps" outright
in either direction: a mask that is purely bigger, with no detector narrowing
it back down, is worse than either the tight guide or the detector-refined
result. NFIQ2 does not reward area for its own sake here; it penalizes
non-pad content, and the dilated guide includes the most of it.

(Note: this run predates gating `_UNET_GUIDE_SEED_ENABLED` off, so its
`refined` column used the seeded U-Net on the captures where that changes the
mask -- e.g. `474b4d6a` reads 76 here vs 73 in the primary control. The `bare`
and `dilated` arms both disable the detector entirely and are unaffected; the
three-way ranking above is unchanged by that discrepancy.)

### Caveats that must travel with that number

1. **NFIQ2 is a floor, not the target** — this project's own prime directive.
   It has been demonstrated foolable here before (a visually-garbage capture
   scored 77), and round 43's crease work is the direct precedent: a *correct*
   mask fix moved NFIQ2 the wrong way because NFIQ2 was happy to count crease
   content as ridge area.
2. **Refinement systematically changes mask AREA** (measured 0.53–1.08× the
   bare guide), and NFIQ2 partly rewards valid ridge area. A negative delta is
   therefore consistent with two opposite stories — refinement removing useful
   ridge area, or refinement correctly removing non-pad content NFIQ2 was
   counting. `diag_area_confound.py` correlates the per-capture delta against
   the per-capture area ratio to separate them, and a third arm
   (`test_mask_arm3_dilated.py` — the bare guide grown to the same outer bound,
   no detector at all) settles it: if the plain dilated guide matches the
   refined arm, the detector contributes nothing and the whole delta is area.
3. **This renders one candidate, not production's 16-variant pool.** A mask
   worse for `native` could still let another variant win. Same limitation
   every masking test in this project has had, stated rather than buried.

## Held, not shipped

The additive guide-seeded fix is implemented in `_unet_mask` (prefer the
component under the guide centre, fall back to `argmax(area)` when that pick is
unusable — 10/13 vs 9/13, verified in the shipped code path, +3 NFIQ2 on the
one capture it changes, four others byte-identical).

It is **deliberately not being shipped on that number alone.** If refinement is
net-negative, then making the U-Net succeed more often makes a harmful
mechanism fire more often — the +3 on `474b4d6a` would be a coin flip that
happened to land well. The refinement control decides it, not the seed test.

The same logic settles the bigger question: **retraining the U-Net against
correctly-seeded labels is not justified** until refinement itself is shown to
be worth having. That is a real saving — it was the obvious next move and the
data says not yet.
