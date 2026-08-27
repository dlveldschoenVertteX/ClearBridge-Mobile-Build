# Why the thumb pad is not reliably given the ROI -- diagnosis

CTO report (2026-08-27): "the real thumbprint is not always being given the
ROI ... the thumbprint needs to occupy all the enhancement budget, no
background at all, even when there is not flash diff. I need to be able to
lock the thumbpad print with confidence and ignore background."

Investigated on 3 real fusion captures. Several real defects found, two
fixed. **The headline ask -- lock the pad with confidence from content --
is NOT solved, and the measurements below say why.**

## 1. The flash-diff gate was measuring the wrong property (FIXED)

`_flash_diff_mask` admitted a pair only if the flash frame's whole-frame
Laplacian variance cleared 50.0. The stated intent was to reject BLOWN-OUT
frames. Laplacian variance does not measure that -- it is equally low for a
merely SOFT frame, and softness is irrelevant here because torch-falloff
differencing reads a LOW-FREQUENCY brightness difference, not detail.

| capture | flashLap | old gate | clipped | torch delta in/out | reality |
|---|---|---|---|---|---|
| 6b43c255 | 26.1 | **REJECT** | **1.1%** | **+15 / -13** | works, 52% of guide |
| 43378ea7 | 425.6 | pass | 0.0% | +55 / -41 | works, 86% of guide |
| 5181d451 | 10.0 | REJECT | 0.0% | **-9 / +1** | genuinely unusable |

`6b43c255` -- the anchor behind this whole track's fusion comparison -- was
having a perfectly good pair thrown away: 1.1% clipped, textbook torch
signature. It fell through to the BARE guide oval, no content awareness at
all. `5181d451` (sunlight) is the converse: sun overwhelms the torch so the
differential is INVERTED, which a sharpness test cannot see and which is the
only thing that actually disqualifies a pair.

**Fixed**: replaced with the two physically-correct tests -- saturated-pixel
fraction (`_FLASH_DIFF_MAX_CLIP_FRAC`) and near-field torch differential
(`_FLASH_DIFF_MIN_TORCH_DELTA`). The differential test is a precondition of
the mechanism, not a tuned parameter.

## 2. Content-aware refinement can over-trim REAL pad (FIXED)

Enabling flash-diff on `6b43c255` made things much worse, not better:
135 minutiae -> 61, and bozorth3 44 -> 17 on `main_round32`.

Root cause found visually, not guessed: the mask cuts a **horizontal line
across the thumb**, keeping the lower half and discarding the upper half --
because a specular highlight there is saturated in BOTH exposures and so
carries no torch differential. The detector answers its own question
correctly ("no falloff cue here") while being wrong about the one that
matters ("is this pad").

**Fixed**: `_MASK_MIN_GUIDE_RETENTION` raised 0.35 -> 0.70. A refinement
should REFINE the guide, not overrule it; the user physically aligned the
pad to that guide, so a detector discarding half of it is far more likely
failing than right.

**Net effect of 1+2 together: behaviour-neutral on all 3 real captures.**
Every one lands on the same mask it does today (6b43c255 `guide`,
43378ea7 `guide+flashdiff`, 5181d451 `guide+unet`), with identical scores.
These are correctness fixes with no measured gain yet -- stated plainly
rather than dressed up.

## 3. Why "lock the pad from content" is NOT solved

Every available cue was measured on the same 3 captures. **None is robust,
and they fail on different captures**:

| cue | 6b43c255 | 43378ea7 | 5181d451 |
|---|---|---|---|
| torch differential | +15 works | +55 works | **-9 fails** |
| brightness vs surround | 189 v 123 works | **160 v 170 fails** | 187 v 109 works |
| ridge texture | **0.87x fails** | **0.81x fails** | 1.13x marginal |

The ridge-texture row is the most important and the most counter-intuitive:
**the guide interior is LESS ridge-like than the surrounding background on
2 of 3 captures**, and 45-72% of the guide scores no more ridge-like than
known background. This is not a bug in the metric -- it independently
reproduces this project's own round-33 measurement (pad Laplacian 1619 vs
adjacent background 2282) and `_pad_within_finger`'s own docstring warning
that unguided ridge energy "latches onto wood grain and fabric".

So the physically-obvious approach -- "keep the parts that look like
fingerprint" -- **cannot work as a primary cue in this domain**, because
fabric and creases genuinely out-score a real pad.

## 4. The deeper reason: the pad is overexposed

Measured per-frame inside the guide on `6b43c255`:

| frame | pad Laplacian | pad ridge score | pad mean brightness | clipped |
|---|---|---|---|---|
| front_amb_2 | 8.0 | 0.28 | 180.2 | 14.4% |
| front_amb_6 | 33.3 | 0.60 | 167.5 | 11.2% |
| front_fl_3 | 15.1 | 0.52 | 201.5 | 14.9% |

**11-15% of the pad is clipped at/above 250** on every frame. Ridges are
destroyed by saturation before any masking decision is made. No mask can
recover ridge detail that was never captured -- which is why the ridge cue
finds nothing inside the guide, and why the pad reads featureless.

**This reframes the ask: the primary lever is capture-side exposure, not
backend masking.**

## 5. Separate real bug: fusion_capture never records laplacianScore

`collect_sources` picks the anchor with
`max(amb, key=lambda f: f.get('laplacianScore') or 0)`. `fusion_capture`
writes no `laplacianScore` at all (production `clearbridge_beta` does --
it hit this exact bug on 2026-08-03 and fixed it via
`_encodeBurstWithSharpnessIsolate`; the fix was never ported). With all
values 0, `max()` returns the FIRST ambient frame, so anchor selection is
arbitrary rather than sharpest.

Honest measurement, which REFUTES the obvious conclusion: on `6b43c255` the
arbitrarily-picked frame (`front_amb_2`, pad Laplacian 8.0 -- the *worst*)
scored **best** (44 on `main_round32`) while the sharpest (`front_amb_6`,
33.3) scored 26. Sharpness does not predict matchability here, consistent
with this project's standing finding. The bug is real and worth fixing for
determinism, but fixing it would not have improved this capture.

## Recommendation

Not shipping a content-based pad lock on this evidence -- the measurements
say no available cue supports one, and this project has a long record of
content-aware refinements measuring negative when pushed past the guide.

The two fixes above are worth keeping (they correct real defects and cost
nothing), but the real lever for "no background, all budget on the pad" is
upstream:

1. **Fix pad exposure first.** 11-15% clipping is destroying the ridge
   signal every other mechanism depends on. An EV pulldown targeted at the
   pad region, or exposure bracketing, attacks the actual cause.
2. **Tighten the guide to the pad** rather than detect the pad inside a
   loose guide. The guide visibly overhangs the thumb tip into background;
   that overhang is the bleed, and it is a fixed geometric quantity that
   can be corrected once rather than re-detected per capture.
3. Re-test content-aware refinement only after (1), when there is real
   ridge signal for it to find.
