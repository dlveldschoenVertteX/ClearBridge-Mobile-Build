# Masking fix -- built, verified, and re-run against the whole track

Real gap fixed: `_render()`, the shared helper every phase script in this
track calls, never passed `ambient_burst`/`flash_burst` to `generate()`, so
`_flash_diff_mask` could never engage across Phase 3 through Phase 8. Fixed
by adding `_flash_pair_for(doc, source)` (looks up a real same-source
ambient+flash pair from the capture's own Firestore doc) and an optional
`flash_pair` argument to `_render()`, threaded through automatically when
supplied. Backward compatible -- every existing 3-arg call keeps its old
(bare-guide) behaviour untouched.

## Verified working, then re-run against the exact capture behind every
## number in Phase 6/7/8

`6b43c255` (the capture behind the whole Phase 6/7/8 comparison, including
the "fusion loses to the anchor" verdict and the crop-path fix): tested
`_flash_diff_mask` directly against the real ambient/flash pair for every
one of the capture's 6 sources.

| source | flash diff | result |
|---|---|---|
| front_v1 (the ANCHOR) | rejected | flash Laplacian 26.1 < the existing 50.0 blowout guard |
| tilt_right | **engaged** | 192,185 px |
| sweep_left | **engaged** | 447,612 px |
| sweep_center | rejected | flash Laplacian 40.8 |
| sweep_right | rejected | flash Laplacian 49.2 |
| tilt_left, tilt_tip | no pair uploaded | -- |

**The mechanism works** (2 of 6 sources engage on real data), but the
ANCHOR -- the render every fusion arm is being compared against -- does not,
because its own flash frame is too soft. Re-rendered it with the fix
applied and confirmed **byte-identical output** to every pre-fix render in
this track (40,905 ink px both times). The U-Net fallback still returns a
region with zero overlap with the guide on this capture (round 40's own
still-unexplained finding) -- so on THIS capture, no masking option was
ever available, fix or no fix.

**Conclusion for this capture: the fusion-vs-anchor verdict from Phase 6/7/8
is unaffected by the masking fix.** Not because masking doesn't matter --
because this specific capture never had usable flash content for it to act
on, with or without the bug.

## Where flash-diff DOES engage: mixed, not a clean win

Checked all 4 real captures used across this track for a viable front_v1
flash pair. Only `43378ea7` has one (flash Laplacian 425.6). Rendered it
both ways on identical input:

| reference | guide+unet (pre-fix path) | guide+flashdiff (fixed) | delta |
|---|---|---|---|
| ink_scan | 8 | 4 | -4 |
| macro_round32 | 26 | 26 | 0 |
| macro_round35 | 18 | 15 | -3 |
| main_round32 | 26 | 29 | +3 |
| main_round35 | 16 | 13 | -3 |

Mixed and small -- one reference up, three flat-to-down. Consistent with
this project's own already-documented 2026-08-20 finding (round 21,
production codebase): a controlled test of `guide+unet` vs `guide+flashdiff`
found no reliable advantage either direction on real data, and this track's
own numbers now replicate that on an independent capture.

## Standing conclusion

The bug was real and is fixed -- worth keeping regardless, since it's the
correct behaviour and will matter on captures with usable flash content.
But it does not change any verdict already reported in this track: the
anchor-vs-fusion comparison is unaffected (no usable masking source existed
on that capture either way), and where masking DOES change, it moves scores
in both directions by a small, noise-level amount matching an existing
finding elsewhere in this project. Not re-running the full 8-arm comparison
grid on the strength of this -- there is nothing in this result that would
change any of it.
