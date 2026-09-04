# Stack internals: one recommendation of mine refuted, one confirmed

Tests the two follow-ups this round's earlier findings pointed at. Both are
the same shape of defect -- a decision made over the whole frame, where the
guide is a minority of the pixels -- so they were tested together, one
variable at a time, on 12 real production `front_only_v1` captures.

| arm | pool ranking | alignment accept-guard |
|---|---|---|
| `prod` | `_ridge_energy`, centre-half crop (today) | corrcoef over the whole frame (today) |
| `rank` | same DoG probe, guide region | whole frame |
| `guard` | centre-half crop | corrcoef inside the guide |
| `both` | guide region | guide region |

## Ranking: REFUTED, do not re-attempt

| arm | `stack` | vs prod | `focusStack` | vs prod |
|---|---|---|---|---|
| prod | 63.70 | -- | 65.80 | -- |
| **rank** | 58.67 | **-4.67** (1 better / 5 worse) | 63.33 | **-3.89** (2 / 5) |
| guard | 63.33 | +0.00 (1 / 1) | **67.89** | **+0.67 (2 better / 0 worse)** |
| **both** | 57.78 | **-5.56** (1 / 5) | 63.00 | **-4.22** (2 / 5) |

Measuring `_ridge_energy` inside the guide makes stacking WORSE, and drags
the combined arm down with it. This is now the second independent
measurement saying so -- `stack_policy_test.py`'s guide-region arm lost by
1.8-2.4 points, but it changed the region and the metric together and so
could not attribute the loss. This arm holds the metric fixed and changes
only the region, and the loss is larger.

So the 12.5% figure -- the guide's share of the crop `_ridge_energy`
measures -- is a real property that does NOT translate into a defect here.
The plausible reason is that the wider crop is measuring frame-level blur,
which is exactly the right question for "which frames should I average
together", even though it is the wrong question for "which frame has the
best ridges". **My own recommendation to fix this was wrong.**

## Alignment guard: confirmed, and it is a failure-rate fix

| arm | frames accepted | frames rejected | ECC errors | stacks dropped entirely |
|---|---|---|---|---|
| prod | 46 | **20** | 6 | **4** |
| guard | 60 | **6** | 6 | **2** |

`_align_face_on_stack` accepts an aligned frame on `corrcoef > 0.5` measured
over the ENTIRE frame. Restricting that same threshold to the guide cuts
rejections from 20 to 6 and halves the number of captures where the stack is
dropped outright.

The clearest single case is capture `076a1775`: production rejected **all
six** aligned frames and produced nothing at all from either variant; inside
the guide, all six pass.

Honest about the score: **+0.67 mean on focusStack and +0.00 on stack is
inside noise**, and the argument for this change is the failure rate, not
the score. Two captures that previously produced no stack now produce one.
It also never regressed focusStack (2 better / 0 worse).

Counter-case worth recording rather than burying: on `0bd23cc2` production
accepted 2 of 6 frames and scored 67/53, while the guide-restricted guard
accepted all 6 and the render then produced nothing. Accepting more frames
is not automatically better -- a poorly-aligned frame that clears the tighter
region can poison a stack the looser gate happened to exclude.

## Standing caveat

All NFIQ2, n=12, and this whole round has established how readily NFIQ2
rewards texture that is not ridge fidelity. The failure-rate numbers do not
depend on NFIQ2 at all, which is why they carry the recommendation here.
