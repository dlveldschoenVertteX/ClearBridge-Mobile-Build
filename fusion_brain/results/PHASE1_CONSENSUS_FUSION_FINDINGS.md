# Phase 1 — classical consensus fusion: real result is NEGATIVE on the first real capture

**Does not pass its own gate yet.** README's Phase 1 charter: "Must beat
single-best-candidate on real SourceAFIS separation to proceed." On the one
real `fusion_v1` capture available (`6b43c255`), it does not.

## What was built

`fuse_minutiae.py`: a purely classical (no ML) fusion rule.
1. **Per-source reliability gate**, motivated directly by Phase 0c's
   `sweep_center` finding: a source is excluded entirely from fusion unless
   its registration explains at least 20% of its own detected minutiae
   (and at least 15 raw inliers). Confirmed working exactly as designed —
   `sweep_center` (14%, the real bad frame documented in
   `PHASE0C_REAL_CAPTURE_FINDINGS.md`) is the only source this gate
   rejected; all 5 genuinely-good sources passed.
2. **Per-minutia classification**, reusing Phase 0's own already-validated
   corroborated / unique_in_overlap / unique_new_coverage logic verbatim.
3. **Fusion rule**: keep the anchor's own minutiae untouched, add only
   `unique_new_coverage` points from sources that passed the gate. Drop
   `unique_in_overlap` (likely spurious) and non-anchor `corroborated`
   (already represented via whichever source corroborated it).

## Real result, this one capture

| candidate | minutiae | vs ink scan (bozorth3) | vs macro round-32 | vs macro round-35 |
|---|---|---|---|---|
| anchor alone (= today's production) | 135 | 5 | **34** | **29** |
| fused (+85 from 5 reliable sources) | 220 | 5 | 28 | 25 |

The ink-scan comparison ties (5 vs 5) — consistent with this project's own
long-standing finding that the single ink scan sits at a noise floor and
rarely discriminates anything at these magnitudes, so a tie there is not
informative either way. The two macro-camera cross-session comparisons
(the CTO's own real finger, a different real capture each time — the more
decisive test per this project's own established preference for it over
the ink scan) are informative, and both say the same thing: **fused loses
to the anchor alone**, by a real margin (34→28, 29→25).

## Honest read

The premise (non-anchor sources carry real, non-spurious minutiae) held —
Phase 0/0b/0c all agree, and the reliability gate correctly excluded the
one genuinely bad source this round. But passing the premise check does not
automatically mean naive gate-and-merge fusion helps real matching, and on
this capture it does not. Plausible mechanism, not yet confirmed: even
"reliable" sources still carry real registration slop (`dist_tol=12px`,
`angle_tol=25°` — the same tolerances Phase 0 validated, not loosened here),
and merging 85 more points (+63% over the anchor's own 135) gives a real
matcher like bozorth3 more surface area for near-miss/competing
correspondences, which can cost more than the added genuine coverage buys —
the same class of tradeoff already seen repeatedly in this project's
image-space fusion attempts, just showing up in minutiae space instead of
pixel space this time.

**n=1 real capture.** Not a verdict on the whole track, but a real,
specific negative that should not be waved past. Two honest paths forward,
neither of which is "ship this":
- Gather more real `fusion_capture` sessions before concluding anything —
  one capture's fusion result is exactly as thin evidence as one capture's
  premise check would have been.
- Or refine the fusion rule itself before re-testing: a per-source gate
  alone may be too coarse — a per-MINUTIA confidence filter (not just
  per-source) on the added points, or a tighter correspondence tolerance
  for what counts as "new coverage," are both real, unbuilt levers that
  might recover the loss without abandoning the classical (Phase 1, no ML)
  approach.

**Not recommending this be wired into anything** on the strength of one
negative result — same standing discipline as every other real-data-gated
decision in this project.
