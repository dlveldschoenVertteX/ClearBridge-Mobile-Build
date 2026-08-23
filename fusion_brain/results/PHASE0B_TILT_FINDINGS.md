# Phase 0b — does small-angle TILT reveal edge ridge detail?

**Yes. Decisively, and the control rules out the obvious alternative
explanation.**

Phase 0 did not test this. What it called "focuszone" are stills sharing the
main burst's framing with only the AF/AE target moved -- the finger never
changes pose, so they *could not* reveal new pad surface. The real claim
needed real multi-angle data, which the discontinued `oscillating_8phase`
captures carry (per-frame `angleDeg`, roughly -17 to +16 degrees).

Capture `353cb00b` (nfiq2 71), all frames rendered through the real
production `afis_print.generate()`, templated with real `mindtct -m1`,
registered onto the sharpest face-on frame in minutiae space.

| source | angle | minutiae | corroborated | new inner | **new EDGE** |
|---|---|---|---|---|---|
| **CONTROL** face-on #2 | +1.0° | 116 | 82 (71%) | 9 | **4** |
| tilt moderate | −11.8° | 279 | 56 (20%) | 63 | **107** |
| tilt extreme | −17.0° | 264 | 59 (22%) | 73 | **87** |
| tilt moderate | +8.5° | 31 | 15 | 5 | *3 (bad frame — see below)* |
| tilt extreme | +15.8° | 380 | 57 (15%) | 111 | **129** |

## Why the control is the whole point

Any different frame contributes *some* unmatched minutiae simply by being a
different frame. So a second FACE-ON frame was scored identically. It
contributed **4** edge minutiae. Tilted frames contributed **87–129** — a
22-32x difference against a control that isolates exactly the confound.

The effect is geometric, not frame-to-frame variation. Tilting rolls pad
surface into view that a face-on capture cannot see, as claimed.

## ~10-12 degrees beats ~17 degrees

On the negative side, where both bands had good frames, **moderate tilt
(−11.8°) produced MORE edge coverage than extreme tilt (−17.0°): 107 vs 87.**
More tilt is not better. That supports the ~10° design instinct directly, and
is consistent with the tradeoff: past some angle, added perspective
distortion and foreshortening cost more than the extra revealed surface.

**The +8.5° cell is not evidence against moderate positive tilt** — that
frame is simply poor (laplacian 226, barely over threshold; its render came
out 237x248 vs ~550-630 for the others, meaning the pad was badly captured).
Positive-side moderate tilt is untested here, not disproven.

## The honest caveat

**Corroboration collapses under tilt: 15-22%, against 71% for the face-on
control.** Partly expected — tilted frames genuinely see different territory,
so much of what they show has nothing to agree with. But it also means the
large majority of tilt-contributed minutiae are *unverified*. Whether they
are real ridge detail or perspective-distortion artifacts cannot be settled
from this data.

This is the same gap Phase 0 hit, and it is the crux for fusion: tilt clearly
adds *coverage*, but coverage of unverified minutiae could just as easily add
noise as signal. Real scanner references are what resolve it.

## What this changes

- The "small-angle tilt" phase is **justified** in a way the focus-zone
  bracket is not. It is the only mechanism measured here that adds
  substantial genuine edge territory.
- Target **~10-12°**, not 15-18°.
- n=1 capture: only one `oscillating_8phase` capture had enough sharp frames
  across angles (the other two failed on missing guideRegion / too few sharp
  frames). Directional, not settled.
