# Phase 4 — hierarchical (per-architecture-bracket) fusion: premise SUPPORTED, architecture REFUTED

CTO's proposal (2026-08-26): "make a superprint out of each architecture
bracket, Front only, Angle tilt (oscillation architecture), sweep. then
find points that match and look like they can be bridged then fuse them."

Built and tested end to end on all three real `fusion_v1` captures. The
premise holds and is measurably real; the architecture built on it does
not beat the flat merge it was meant to improve. Both halves are recorded
here because the premise being true is exactly what makes the negative
result informative rather than a dead end.

## 1. Premise check (`phase4a_bracket_premise.py`) — SUPPORTED, margin ~4%

126 real registrations (every ordered source pair on all 3 real captures),
grouped intra- vs cross-bracket, scored against `fuse_minutiae.gate_sources`'s
own production thresholds (`min_inlier_frac=0.20`, `min_inlier_count=15`):

| | pairs | mean inliers | median | mean frac | gate pass |
|---|---|---|---|---|---|
| **intra**-bracket | 36 | **42.47** | 42.0 | **0.3122** | **36/36 (100%)** |
| **cross**-bracket | 90 | 40.69 | 40.0 | 0.2904 | 87/90 (96.7%) |

Per bracket: tilt 44.94 mean inliers (18/18 pass), sweep 40.00 (18/18 pass).

**Within a pose family registration IS tighter, and every intra-bracket
pair clears the gate where cross-bracket pairs sometimes fail.** The
CTO's intuition is confirmed. But the margin is ~4%, not the large gap
that would transform downstream results — and that number turns out to
explain the whole rest of this phase.

## 2. Image-level hierarchy (`phase4b_bracket_fusion.py`) — 0/2, mechanism found

Stage 1 fused each bracket into a superprint IMAGE; Stage 2 fused those
onto `front_v1`. Result on `6b43c255`: 30/23 against anchor 34/29 — worse
than the flat validated-bridge merge's 40/30.

| bracket | anchor -> superprint | validated | **UNVETTED** |
|---|---|---|---|
| tilt | 148 -> 209 (+61) | 25 | **36** |
| sweep | 258 -> 305 (+47) | 25 | **22** |

**Compositing an image always yields more extracted minutiae than the
merge validated** — real warped fingerprint texture carries its own real
ridge endings, and pasting it brings them along whether or not any gate
endorsed them (phase3f measured the same ratio on the flat merge:
135 -> 171 for 15 validated). So a two-stage IMAGE hierarchy *compounds*
the template-density penalty Stage A documented: Stage 1 pollutes each
bracket superprint, Stage 2 then treats that polluted superprint as a
trusted source and pollutes again on top. Stage 2 saw 40 unvalidated
points in `tilt_sp` alone, and `sweep_sp` contributed nothing.

## 3. Template-level hierarchy (`phase4c_template_hierarchy.py`) — 1/2

Same bracket architecture, intermediate changed from picture to TEMPLATE
(merged minutiae + union coverage, zero pixels composited, therefore zero
unvetted additions). Stage 1 now yields 148 -> 173, **all 25 validated**.

Result: 35/28 -> **1/2**. Removing the intermediate picture recovers most
of the image hierarchy's loss, exactly as the mechanism predicted — but
still trails the flat merge.

## 4. Stage 1 budget sweep — the pre-filtering hypothesis, REFUTED

The obvious remaining explanation was pre-filtering: Stage 2 can only
choose from Stage 1's survivors, so a point flat merging would have picked
may be lost. Tested directly by raising the Stage 1 cap with Stage 2 held
at 15 (capture `6b43c255`, anchor 34/29):

| Stage 1 budget | tilt template | sweep template | Stage 2 took | round32 | round35 | beats |
|---|---|---|---|---|---|---|
| 25 | 173 | 283 | tilt_sp: 15 | **35** | 28 | 1/2 |
| 50 | 198 | 308 | tilt_sp: 15 | 34 tie | 25 | 0/2 |
| 100 | 230 | 313 | tilt_sp: 15 | 34 tie | **30** | 1/2 |
| 999 (unlimited) | 230 | 313 | tilt_sp: 15 | 34 tie | **30** | 1/2 |
| **flat merge** | — | — | — | **40** | **30** | **2/2** |

Three things settle it:

1. **The budget saturates** — 999 is byte-identical to 100 (all available
   candidates exhausted at 82 tilt / 55 sweep), so this tested the real
   ceiling, not a partial range.
2. **Stage 2 takes exactly 15 from `tilt_sp` and 0 from `sweep_sp` at
   every budget**, final template 150 minutiae in all four runs.
   Enriching the bracket templates only changes WHICH tilt points win --
   it never lets more through and never lets sweep in. Stage 1's cap was
   never the binding constraint.
3. **The hierarchy never reaches the flat merge.** Best case 34/30 vs
   flat's 40/30; the 6-point deficit on `macro_round32` is persistent
   across every budget tested.

## Mechanism, and why a true premise still yields a losing architecture

Hierarchy points take an EXTRA REGISTRATION HOP: member -> bracket anchor
-> front, versus flat's single source -> front. Every transform adds
positional error, and TPS is fitted to minutiae positions. A ~4%
pose-family registration advantage does not pay for a whole additional
transform. That is precisely why the premise can be genuinely supported
(§1) and the architecture built on it still lose (§4) — the two facts are
consistent, not contradictory.

## Honest conclusion

**Flat selection across all sources at once is already near-optimal for
this data.** `fm.fuse` picking the global top-N over all six raw sources
beats any two-stage arrangement tested, because it gives every candidate
one transform to the anchor and full freedom of choice.

**Not recommending the bracket hierarchy.** It is a well-motivated idea
resting on a premise that is genuinely true, and it was worth the test --
but three real captures, four Stage 1 budgets, and two intermediate
representations all point the same way. The one durable gain from this
phase is diagnostic: intra-bracket registration quality (100% gate pass
vs 96.7%) is now measured, and the extra-hop cost is now quantified.

**Real bug fixed along the way**: Stage 1's fused minutiae kept their
original member tags (`tilt_left`, ...), and `fm.fuse` recounts per source
by `m.source`, so Stage 2 reported `contributed=0` for both brackets while
genuinely merging 15 points. Selection was always correct; only the
accounting read zero. Re-tagging each point with its bracket fixed it, and
re-running confirmed scores were unchanged (35/28 both times).

## Standing caveat

n=3 real captures, and judging any of this still needs the ≥500-DPI
full-pad scanner reference this project has carried as a blocker since
2026-07-16. Same caveat as every number in this track.
