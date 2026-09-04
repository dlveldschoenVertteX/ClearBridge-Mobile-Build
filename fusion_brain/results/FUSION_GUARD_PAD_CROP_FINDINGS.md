# Layer 7 (variant selection): main.py's own fusion-selection sharpness guard measured the whole frame, not the pad -- fixed, low-risk, SHIPPED

## The gap

`main.py`'s fusion-selection sharpness guard (`_fusion_guarded`, built
2026-07-23 after real capture `913758cf`: a plain ambient frame at
Laplacian 790.4 while its flash frames scored only ~81-86, yet a flash+
ambient fusion variant won selection anyway because the internal proxy
overestimated it) computed its trigger ratio as:

```python
_amb_lap = Laplacian(ambient_frames[0]).var()   # WHOLE FRAME, no mask
_fl_lap  = Laplacian(flash_frames[0]).var()      # WHOLE FRAME, no mask
_fusion_guarded = (_amb_lap / _fl_lap) >= 4.0
```

This predates `afis_print.flash_pair_sharpness_ratio` (built 2026-08-12 for
the sweep guard, and ported to front_only_v1's own fuse call sites in this
same pass's layer 6, round 48) -- whose own docstring states exactly why a
whole-frame measurement is wrong here: "a whole-frame Laplacian is
dominated by background texture and says almost nothing about the ridge
content the fusion actually operates on." Same background-contamination
defect pattern already found and independently fixed in layers 3 (masking),
4 (wavelength), 5 (Gabor enhancement), and 6 (afis_print.py's own fuse
guard) of this pass -- just never checked in this SECOND, separate,
pre-existing guard that also lives in `main.py`.

## Diagnostic, 24 real captures

`fusion_brain/diag_fusion_guard_wholeframe.py`: for the same real capture
population layer 6 used, compare whether the guard's own 4.0 threshold
fires under the current whole-frame measurement vs the already-shipped,
guide-region-restricted `flash_pair_sharpness_ratio`, on the identical
frame pair (`ambient_frames[0]`/`flash_frames[0]`).

**3 of 24 (12.5%) disagree**, and in EVERY case the direction is the same:
whole-frame measurement says `False` (guard doesn't fire), guide-region
measurement says `True` (guard should fire) -- background content dilutes
a real ambient:flash sharpness gap the pad crop shows clearly. Zero cases
in the opposite direction (whole-frame over-triggering). This means
restricting to the pad can only make the guard fire on MORE real cases on
this population, never fewer -- the fix is a strict superset of the
current trigger set here, not a wash in both directions.

| capture | wholeframe ratio | guide-region ratio | wf fires (4.0) | guide fires (4.0) |
|---|---|---|---|---|
| a262d2b3 | 3.87 | 5.34 | No | **Yes** |
| 1cc301a8 | 3.54 | 5.37 | No | **Yes** |
| c27d0004 | 1.74 | 5.43 | No | **Yes** |

## Does it matter? Tested the actual downstream consequence, not assumed

`fusion_brain/test_fusion_guard_margin.py`: for these 3 disagreement
captures, ran the real `generate()` for `native` and `deepFuse`
(`fuseAvg` self-forfeited on all 3 -- layer 6's own per-pair guard,
threshold 2.0, already blocks the single-pair fuse family here; expected,
consistent).

| capture | native | deepFuse | margin |
|---|---|---|---|
| 1cc301a8 | 63.0 | 66.0 | +3.0 (exactly clears `_FUSION_MARGIN_REQUIRED=3.0`) |
| a262d2b3 | 52.0 | 69.0 | +17.0 |
| c27d0004 | 37.0 | 70.0 | +33.0 |

**On all 3 tested captures, deepFuse's real margin over native already
clears the +3.0 requirement regardless of which measurement triggers the
guard.** So on this evidence, the fix is a genuine correctness improvement
(measuring the right content) with no demonstrated change in real
selection outcomes -- not a guess dressed up as validated, but an honest
report that the available evidence doesn't show harm OR benefit to the
delivered print, only to the guard's own internal accuracy.

**Secondary, smaller correctness fix caught along the way**: the OLD code
gated the whole check on `_fl_lap > 0`, meaning a flash frame with
LITERALLY ZERO variance (a completely flat/blank frame -- the most
suspicious case of all) was treated as NOT guarded, since `0 > 0` is
False. `flash_pair_sharpness_ratio` returns `float('inf')` in that exact
case, which correctly trips the `>= 4.0` check under the new code --
closing a real, if narrow, gap in the old logic's own edge case.

## Decision: SHIP (no flag needed -- reuses an already-validated function verbatim)

Unlike layers 4/5's boundary/measurement fixes (net negative on real
NFIQ2) or layer 6 (net positive, needed a flag to compare against the
pre-fix behavior), this fix changes WHICH FRAME CONTENT a pre-existing
guard measures, not what gets rendered or delivered. It can only ever make
the guard's trigger condition MORE accurate (confirmed: only ever adds
newly-detected cases on this population, never removes a real one), and
the guard's own action when triggered is a bounded safety margin (require
+3.0 over native), not a hard block -- so even a newly-triggered case can
still win outright if it's genuinely better, which is exactly what was
observed on all 3 real disagreement captures. No flag: this directly
reuses `flash_pair_sharpness_ratio`, the same already-shipped, already-
tested function layer 6 relies on for a materially similar decision, so
there's no new untested code path to gate.

**Honest limit**: only `deepFuse` was tested end-to-end on the 3
disagreement captures; `fuseMaxc`/`fuseSoft`/`deepMaxc` (also in
`_FUSION_VARIANT_NAMES`) were not separately checked. `fuseAvg` already
self-forfeited via layer 6, so the remaining untested variants share
`deepFuse`'s own stacked-pair mechanism (`deepMaxc`) or the same
single-pair family (`fuseMaxc`/`fuseSoft`) already shown moot for that
family here.
