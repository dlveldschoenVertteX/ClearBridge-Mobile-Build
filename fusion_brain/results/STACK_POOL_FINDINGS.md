# The stacking hypothesis: right symptom, wrong mechanism

CTO hypothesis (2026-08-27): *"stacking ambient frames on noise explains why
the stacking function performed so badly (just a guess)."*

The symptom is real. The mechanism is not the pool -- and testing it turned
up a bigger reason that also explains why the pool never mattered.

## What production actually stacks

`generate()` does not stack ambient frames. It pools `ambient_burst` AND
`flash_burst` together, ranks the pool by its own nested `_ridge_energy`,
and flat-averages the top `_STACK_MAX` (4). So the pool is
illumination-MIXED by construction, and the ranking is a centre-half crop of
the frame -- on real captures the guide occupies only 12.5% of that crop.

That gave two candidate defects worth separating, so the test has four arms
on 12 real production `front_only_v1` captures, with masking inputs held
identical across all of them:

| arm | pool | ranked by |
|---|---|---|
| `prod` | every frame | `_ridge_energy`, copied byte-for-byte (what runs today) |
| `mixed` | every frame | guide-region ridge score |
| `ambient` | ambient only | guide-region ridge score |
| `flash` | flash only | guide-region ridge score |

`prod` vs `mixed` isolates the RANKING; `mixed` vs the single-illumination
arms isolates the MIX. Stacking is done with production's own
`_stack_face_on`/`_focus_stack_face_on` and the result handed to
`generate()` as the primary frame, because `generate()`'s pool builder is a
closure and cannot be varied from outside without also perturbing masking.

## Result: no pool policy beats what is already there

| arm | `stack` mean | vs prod | | `focusStack` mean | vs prod |
|---|---|---|---|---|---|
| **prod** (today) | **63.70** | -- | | **65.80** | -- |
| mixed | 61.30 | -2.40 (4 better / 5 worse) | | 65.44 | -1.78 (3/6) |
| ambient | 60.78 | -2.56 (2 better / 6 worse) | | 63.22 | **-4.00 (1/7)** |
| flash | 63.22 | -2.33 (4 better / 4 worse) | | 65.25 | -3.62 (1/6) |

**Ambient-only is the worst arm of the four** -- so the hypothesis is
refuted in the most direct way available: deliberately doing the thing it
warns against is what performs worst. Restricting to flash-only loses too.
The illumination mix is not the problem, and neither is the ranking, despite
the ranking genuinely being unstable (its top-4 ranged from 4 ambient to 4
flash across captures, disagreeing with the guide-region ranking on most).

An earlier draft of this test was itself wrong and is recorded rather than
quietly fixed: its "mixed" arm ranked by the guide-region score, so it never
reproduced production's actual pool at all. The `prod` arm above exists
because of that.

## The real reason stacking underperforms

Comparing the same captures against the per-frame renders from
`frame_selection_test.json`:

| | mean NFIQ2 (n=10) |
|---|---|
| **best single frame in the burst** | **74.5** |
| focusStack (production pool) | 65.8 |
| stack (production pool) | 63.7 |
| production's own single primary frame | 61.7 |

Stacking beats production's *chosen* frame on 5-6 of 10 captures -- which is
why it wins variants today -- but beats the burst's *best* frame on only
**2 of 10**, losing by ~9-11 points on average.

So stacking's apparent value is largely a symptom of a bad primary-frame
choice, not a gain of its own. Averaging four frames costs more ridge detail
than the noise reduction recovers, and the single best frame wins. With the
flash-primary candidate now added to selection (see
`FRAME_SELECTION_FINDINGS.md`), the ground stacking was making up should
shrink further.

**Also measured: 21% of stack arms (20 of 96) failed outright** -- ECC
alignment returning nothing -- concentrated on 4 of 12 captures, one of
which failed on every arm. That fragility is a more consequential property
of these variants than which frames go into them.

## Not actioned

This is an argument for eventually reclaiming the two variants' place in a
70s budget that already truncates on real captures, not for deleting them
now: they are additive candidates and they do still win 2 of 10 outright.
The right time to revisit is after the flash-primary candidate has real
production data, and on real matchability rather than NFIQ2 -- everything
above is an NFIQ2 measurement, on n=10-12, with the standing caveat that
NFIQ2 rewards ridge-like texture rather than fidelity.
