# The crease detector was reading the enhancer's own output

Direct CTO report (2026-08-27), with an annotated print: "the blue circle
surrounding the print should be the only thing that survives ... it seems to
be enhancing everything past the crease at the bottom as well", asking
whether it was one image or the pipeline.

## It is the pipeline, on about one capture in five

Across 24 real production `front_only_v1` captures since crease trim
shipped, `afisCreaseTrimPx` is present on 19 (removing a median 27% of the
print) and **absent on 5** -- those ship with the below-crease region
intact.

## Root cause: a circularity in the detector

`_trim_base_crease` asks "is this row a crease?" by measuring the circular
variance of ridge orientation across the row -- a crease being
characteristically near-parallel, a real pad having genuine curvature. It
measured that on the **binarized** image, chosen deliberately because clean
black/white gives a stronger edge signal than the noisier grayscale.

That reasoning is right about edge strength and wrong about what is being
asked. By then the Gabor bank has run, and this project has already
documented that the bank "will impose ridge-like structure on any input with
enough local contrast". The crease therefore arrives at the detector already
wearing plausible, varied ridge flow -- **the detector is reading data the
enhancer has made fingerprint-shaped.**

Measured on `b615f37b`, one of the five failures:

| base-half circular variance | post-Gabor (old) | pre-Gabor (new) |
|---|---|---|
| median | 0.506 | **0.181** |
| longest run below threshold | 27px | **162px** |
| fires (needs >= 29px) | no | **yes** |

The Gabor pass raises the measured variance in the crease region from 0.181
to 0.506 -- straight through the 0.40 threshold.

## The fix, and what it actually does

`generate()` keeps the pre-Gabor normalized grayscale, rotates it through
`_upright_from_tip` with the same pre-rotation mask, and passes it to
`_trim_base_crease` as `orient_src`. Falls back to the old behaviour when
absent; wired only on the default gabor/freqNorm branch, which is the path
every production variant that has ever won selection goes through.

| capture | trim old | trim new | NFIQ2 |
|---|---|---|---|
| **b615f37b** (the failure) | **0.0%** | **24.0%** | **59 -> 76** |
| e33d618e | 49.8% | 49.8% | 75 -> 75 |
| 03b91b6f | 38.5% | 37.4% | 58 -> 62 |
| 076a1775 | 33.6% | 30.0% | 44 -> 47 |
| 0bd23cc2 | 17.1% | 15.0% | 58 -> 56 |
| a262d2b3 | 49.6% | 34.0% | 52 -> 49 |
| 474b4d6a | 12.5% | 10.4% | 80 -> 75 |
| 01662ffb | 42.3% | 40.4% | 83 -> 76 |

Mean NFIQ2 delta **+0.88** (3 up / 4 down / 1 same) -- neutral, with the one
large move being the capture the change is for. Visually confirmed on
`b615f37b`: the second, below-crease arch region present in the untrimmed
render is gone, and on `01662ffb` the trimmed print is a clean pad with no
crease left behind.

## Honest limits

**On captures where the trim already worked, the new measure trims slightly
LESS** (typically 1-4 points, once 15.6). More conservative is arguably the
safer error -- less real pad removed -- but it is a real behaviour change on
the majority of captures, not a no-op, and it is not obviously an
improvement there. `a262d2b3`'s 49.6% -> 34.0% is the largest such move, on
a capture whose print is fragmented and low-scoring either way.

NFIQ2 is reported here, not used as the gate. Crease trim is already known
to cost NFIQ2 when it works, because NFIQ2 rewards ridge-like texture
wherever it appears -- which is exactly the property that lets a crease
score well. The gate is the CTO's stated requirement that below-crease
content must not survive, plus visual confirmation.

n=8, and the no-fire population is n=1 of those. The remaining four
production captures that recorded no trim did fire when reproduced here,
which means production's "no trim" on those came from a different winning
variant rather than from the capture -- worth knowing, and not yet chased.
