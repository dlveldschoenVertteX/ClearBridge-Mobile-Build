# Phase 5 — raw-domain fusion: the first result was CONFOUNDED, corrected here

## What was reported, and why it was wrong

The initial phase5 run reported raw-domain fusion losing to anchor-alone
by 9 points on both informative references (25/20 vs 34/29), with a 5.8x
collapse in Laplacian energy (25518 -> 4374) and minutiae dropping
135 -> 91. It was written up as "coherence and matchability are in direct
tension", with averaging-softens-ridges as the mechanism.

**That comparison changed two variables at once.** The mosaic went
through `_front_anchored_mosaic_zones`, which CROPS every source to a
common pad-dominated region (2.6x the guide bounds) and returns an
adjusted guide, then ran `generate()` on that crop. The anchor baseline
ran `generate()` on the FULL raw frame with the original guide. So the
comparison was mosaic-via-crop-path against anchor-via-full-frame-path,
and the difference was attributed entirely to mosaicking.

This is the same error class as phase3d earlier in this track (changed
the merge AND the mask scope, blamed the merge). Recorded rather than
quietly amended.

## The missing control, and the corrected numbers

Running `generate()` on the anchor crop with the SAME adjusted guide and
NO mosaic isolates the crop path:

| candidate | ink_scan | round32 | round35 | lap | minutiae |
|---|---|---|---|---|---|
| anchor, full frame | 5 | **34** | **29** | 25518 | 135 |
| **CONTROL** — anchor crop, no mosaic | 5 | 24 | 27 | 4225 | 135 |
| raw-domain mosaic | 5 | 25 | 20 | 4374 | 91 |

Two things follow immediately:

1. **The Laplacian "collapse" is the crop path, not fusion.** The control
   sits at 4225 without any mosaicking at all — essentially the same as
   the mosaic's 4374. Note the control still yields 135 minutiae, equal
   to the full-frame anchor, so the two prints carry equivalent matchable
   content despite the 6x Laplacian difference; that difference is a
   rendering-scale artifact of the crop path, not lost detail.
2. **Against its own control the mosaic is not a 9-point loss.** It WINS
   on round32 (25 vs 24) and loses on round35 (20 vs 27).

## The mechanism claim was also wrong

Measured directly on the same capture:

    anchor raw crop   lap = 20.2
    raw mosaic        lap = 71.1   (3.5x SHARPER)
    sides used        = 3 of 6, 90.6% of pixels changed

The mosaic is substantially SHARPER than the anchor crop it is built
from. `_MOSAIC_ANCHOR_DOMINANT_T = 1.5` is active and doing exactly what
its own docstring promises — contributing zero at sharpness parity and
ramping up only where a side genuinely resolves better. The
"averaging softens ridges" explanation, borrowed from afis_print.py's own
stacking comment, does not apply to this data.

## What still stands

- The raw-domain print IS visually coherent — one continuous region, no
  disconnected patches. Independently confirmed by the CTO ("the closest
  to my print I have ever seen"). The structural claim behind Phase 5 —
  one orientation field, one Gabor pass, continuity by construction — is
  correct.
- A real residual loss remains on ONE reference (round35, 27 -> 20). That
  is a far narrower problem than "coherence costs matchability", and it
  is the thing worth attacking next.
- 44 minutiae are still lost against the control (135 -> 91) while
  Laplacian is unchanged, so the loss is not softening. Most likely
  candidates, untested: residual local misregistration from ECC's single
  global homography breaking ridge continuity at the sub-ridge scale, or
  destructive interference in the coherence-weighted AVERAGE where two
  sources overlap.

## Next, and why

Both remaining candidates point at the same two levers:

1. **TPS instead of ECC.** Phase 5 used production's ECC homography — one
   global 8-DOF transform. Skin is non-rigid, so local residual
   misregistration is expected, and that is precisely what puts two
   sources' ridges out of phase. TPS corrects locally. Since the mosaic
   already sharpens under ECC, better registration should sharpen it
   further rather than being a speculative bet.
2. **Max-coherence SELECTION instead of weighted averaging.** Selection
   avoids destructive interference entirely — no two out-of-phase ridge
   patterns are ever summed. Direct in-project precedent: `deepMaxc`
   (coherence-max) beat `deepFuse` (flat average) on a real capture,
   57 -> 81 NFIQ2.

Neither is speculative and both are cheap. n=1 capture throughout; the
corrected numbers need replication on the other captures before any of
this is treated as established.
