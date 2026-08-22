# Phase 0c — does the premise hold on REAL fusion_capture output?

**Yes, on 5 of 6 non-anchor sources — and the 6th outlier is explained, not
hand-waved away.**

Phase 0/0b tested the premise against OTHER architectures' real captures
(front_only_v1, oscillating_8phase) as a proxy, since fusion_capture itself
had produced no real data yet. This is the first run of the identical
registration/classification pipeline against an actual `fusion_v1` capture
(`6b43c255`, real device test, front+tilt+sweep all landed real content).

| source | minutiae | inliers/total | corroborated | uniq/overlap | **uniq/new** |
|---|---|---|---|---|---|
| front_v1 (anchor) | 135 | — | 112 | 19 | 4 |
| tilt_left | 105 | 32/105 (30%) | 73 | 20 | **12** |
| tilt_tip | 148 | 44/148 (30%) | 97 | 48 | 3 |
| tilt_right | 197 | 42/197 (21%) | 100 | 64 | **33** |
| sweep_left | 84 | 24/84 (29%) | 45 | 28 | **11** |
| sweep_center | 258 | **37/258 (14%)** | 106 | 92 | 60* |
| sweep_right | 168 | 41/168 (24%) | 100 | 42 | **26** |

*sweep_center's 60 "unique_new_coverage" is not trustworthy — see below.

All 6 non-anchor sources registered successfully (100%, up from Phase 0's
partial rate on other architectures). All 6 land within `unique_in_overlap
< corroborated + unique_new_coverage` — the kill criterion never triggers.

## sweep_center is a real, explained outlier, not a counterexample

Visual check (this project's own standing discipline — never trust a
number that looks off without looking at the actual content) found
`sweep_center`'s rendered print visibly incoherent: no clear whorl core,
choppy near-parallel texture unlike every other source's clean whorl.
Pulling the RAW frame (`sweep_center_amb.jpg`) explains it directly: the
thumb is out of frame, blurred, angled — the shot fired while the finger
was still moving into position. Its own numbers corroborate the visual:
lowest inlier fraction of any source (14%, next-lowest is 21%) and the only
non-near-zero registered rotation (39°, everything else is within 6°).

This is not a mark against the sweep architecture (`sweep_left` and
`sweep_right`, same station type, both look genuinely clean and both
registered well) — it is a capture-quality miss on this one station, on
this one real session, from the exact failure mode already root-caused and
fixed the same day this capture was taken: `fusion_capture`'s pre-fix build
fired every station's shutter the instant its settle delay elapsed, with no
countdown and no steadiness check (see round "fusion_capture: defer all
processing to end, curated tilt ring UI, pre-shutter countdown"). This
capture predates that fix. A real, live signal for exactly this case
(`state.gyroSteady`) is now wired into that same build; this is the kind of
frame it exists to catch.

## Direct implication for Phase 1

A source-level reliability gate before fusion is not optional — it is
exactly what would have caught this. `sweep_center`'s 14% inlier fraction
is a real, measurable, classical (no ML needed) signal that a source is
contributing more noise than corroborated coverage, and Phase 1's fusion
rule gates on it.
