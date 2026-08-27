# Layer 2 — guide geometry (2026-08-27, round 44)

Second layer of the step-by-step architecture pass. This is the layer with the
worst bug history in this project (BoxFit.cover mis-mapping, mirrored prints,
macro-camera offset, the `_isolate_thumb_lobe` frame-centre seed) and every one
of those was caught only after it had already corrupted something two layers
downstream. So it was audited for coordinate-space correctness specifically,
not for tuning.

## Checked and CORRECT — recorded so a later round doesn't re-litigate

- **The BoxFit.cover + rotation transform.** `_computeGuideRegion` maps screen
  `rx=0.134604` to still `ry=0.08298`, a ratio of 0.6164, which is exactly the
  crop factor for the real preview/screen aspect pair (0.4615/0.75). Correct.
- **`_scoreRoi` and `_focusPointScreenSpace`** both derive from
  `_guideCx/_guideCy/_guideRx/_guideRy` at runtime now (rounds 14/16 fixes).
  No live copy left to drift.

## FIXED 1 — fusion sweep stations had literally zero overlap

`fusion_capture`'s sweep guide swept `cx = 0.2 + 0.6 * progress`. Measured
across the real station set: **0.0% overlap on all three adjacent pairs** —
coverage 3.00x the single-guide area, perfectly disjoint. Production's own
sweep geometry gets 35.9%. Mosaicking needs 30–50% adjacent overlap; with zero
there is no shared content for any registration to lock onto, which is a
structural reason the sweep sources have never registered well rather than a
tuning one.

Changed to a half-span of 0.15 about the guide's own centre. Coverage drops
3.00x -> 2.28x, which is the deliberate trade: rounds 37–41 established that
coverage a matcher cannot register is not merely wasted but actively harmful,
because the template-density penalty charges for every added minutia whether or
not it carries signal.

## FIXED 2 — `_sec_guide` constants were left in a coordinate space round 36 removed

`main.py` synthesises a guide for each secondary camera. For camera "2" it used
`cx=0.50, cy=0.34, rx=0.11, ry=0.13`. Those were real measurements — rounds 31
and 33 took them off real frames — but off frames in a convention round 36 then
changed and never came back to re-derive them against.

**Confirmed rather than assumed.** Both real cached camera-"2" macro frames
(`f4cb3ba5`, round 32; `b615f37b`, round 35 — the exact captures rounds 31/33/35
measured on) decode via plain `cv2.imdecode`, the same call this backend makes,
to **2448x3264 — portrait**. Every other frame in the same request is 4266x3200,
landscape. That mismatch *is* the sideways bug round 36 diagnosed, and its fix
(`_normalizeMacroFrame`) now routes this frame through `decodeStillJpegToLuma`
like every other path, which rotates it 90 deg CW into landscape. Round 36's own
note records it was never device-tested, so no real capture has ever surfaced
the leftover.

The rotation was read off `decodeStillJpegToLuma`'s own indexing
(`rotated[y*dstW+x] = luma[(h-1-x)*w + y]`), not its docstring: `(u,v) -> (1-v,u)`,
with the radii swapping axes. So:

    cam "2"  portrait (0.500, 0.340) -> landscape (0.660, 0.500)
             portrait rx 0.11 / ry 0.13 -> landscape rx 0.13 / ry 0.11

**Independent corroboration.** The MAIN guide's own real still-space position,
measured off a real capture in round 16, is `cx=0.63 / cy=0.50`. The macro
measurement rotates to `(0.66, 0.50)` — 0.03 away on both axes — exactly what it
should be, since the user aims at the same on-screen guide for both shots and the
macro guide is only scaled 1.2x. Two numbers from completely different real data
landing on the same spot is much stronger than either alone.

### Measured on real data, not argued

`test_sec_guide_rotation.py` applies that exact client rotation to reconstruct
what the backend will actually receive, then renders the real production
candidate both ways and scores with the real NFIQ2 binary.

| frame the backend receives | guide constants | f4cb3ba5 | b615f37b |
|---|---|---|---|
| portrait (pre-round-36) | OLD | 62 | 59 |
| landscape (post-round-36) | **OLD — what ships today** | 58 | 57 |
| landscape (post-round-36) | **NEW — rotated** | **67** | **72** |

**+9 and +15** on the frames the pipeline will actually receive. On `b615f37b`
the mask also moved from bare `guide` to `guide+unet` — the content-aware
refinement now finds a real pad to refine, which it could not on the OLD crop.
That is a mechanistic corroboration independent of the score: the U-Net accept
gate passes on NEW and fails on OLD.

**Honest limit on the top row.** It is *not* a faithful reproduction of history —
`b615f37b` scored a real production 75 via `afisMask: guide+flashdiff`, and this
harness feeds a single frame so flash-diff can never engage. Absolute numbers
here are therefore not comparable to production, and no claim is made that this
beats what production historically delivered. What is valid is the *within-harness*
comparison: identical inputs, only the constants and the frame orientation vary.
That comparison is unambiguous.

### Camera "3" fixed too, though currently unreachable

Its `cy=0.37` was never measured at all — it was copied from
`PadSilhouetteShape.cy`, a SCREEN-space constant, and used as a still-space `cy`.
Round 27's audit listed "`defaultShape.cy` 0.37 == `main.py`'s `_sec_cy`" under
constants that AGREE; they agree numerically while living in different spaces,
which is the actual defect. Correct still-space value is the same rotation of the
same screen shape the main guide already gets: `(0.5, 0.37) -> (0.63, 0.50)`.

This branch is dead today — `_captureSecondaryBurst` was removed client-side on
2026-08-03, so only camera "2" is captured. Fixed anyway because round 40 named
camera "3" the better-evidenced diversity candidate if secondary cameras are
revived, and a wrong constant waiting for that is a landmine.

## Not device-tested

Same standing discipline as every capture-side change. The backend change needs
its own deploy go-ahead; the sweep-geometry change needs a real fusion capture to
confirm the stations now share content.
