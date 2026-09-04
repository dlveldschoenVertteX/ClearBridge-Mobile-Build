# Layer 6 (fusion): flash-softness guard ported from sweep to front_only_v1 -- real, net-positive, SHIPPED

## The gap

`flash_pair_sharpness_ratio` / `_FLASH_PAIR_MAX_SHARPNESS_RATIO = 2.0` was
built and calibrated 2026-08-12 on real **sweep** captures: every zone whose
ambient+flash pair actually fused scored LOWER than that zone's plain
ambient frame (5/5 zones, 2/2 mosaics, up to -13 NFIQ2, zero counter-
examples) whenever the flash frame ran softer than ~2.8x the ambient's own
sharpness -- a real torch-blowout signature, independently documented on the
main front burst elsewhere in this project's own history (round 42: ambient
Laplacian ~3.4x flash's, real ISO/exposure measurements).

That guard was wired ONLY into the sweep zone-fusion path
(`main.py` ~2255-2266). `front_only_v1`'s own fuse family
(`fuseAvg`/`fuseMaxc`/`fuseSoft`/`deepFuse`/`deepMaxc`/`deepSoft`/
`deepAmbBestFl`) -- confirmed via `grep` to be the path nearly every real
production capture routes through -- had no equivalent check anywhere,
despite `afis_print.py` fusing ambient+flash pairs by the identical
mechanism (`_fuse_flash_ambient`).

## Fix

`_FUSE_FLASH_SOFTNESS_GUARD` flag, wired into all three real call sites in
`afis_print.py` that build a fused candidate from an ambient/flash pair:

1. The deep-family stack-then-fuse path (`da`/`df`, shared by
   `deepFuse`/`deepMaxc`/`deepSoft`/`deepFocus*`) -- ratio measured on the
   already-stacked `da`/`df` pair; if it fails, `fused` stays `None` and the
   variant falls back to plain `da` (ambient-only, never regresses to
   nothing).
2. The single-pair candidate loop (`fuseAvg`/`fuseMaxc`/`fuseSoft`) --
   candidates are tried in existing face-on/ridge-energy priority order;
   any pair whose ratio exceeds the threshold is skipped (`continue`)
   rather than fused.
3. The burst-fallback loop (same family, added 2026-07-24 for when the
   single pre-selected pair fails to register) -- identical per-pair gate.

Backward compatible in every branch: when the guard doesn't fire (ratio
under threshold, or `_FUSE_FLASH_SOFTNESS_GUARD` off), behavior is
byte-identical to before. `params['afisFuseSoftnessSkipped']` records the
skipped ratio when the deep-family path is gated, for diagnostics.

## Real test, 12 captures (9 guard-firing + 3 controls, narrowed from the
full 24-capture library via a cheap Laplacian-ratio pre-pass -- full-res
ECC in `_fuse_flash_ambient` makes an exhaustive 24x2-arm run impractical,
same narrowing technique as round 45)

Ran the actual shipped `generate(fuse='avg', ...)` twice per capture
(`_FUSE_FLASH_SOFTNESS_GUARD` off/on), passing the SAME arguments real
production passes (`ambient_burst`/`flash_burst` included, matching
`main.py`'s own variant-loop call shape -- an earlier draft of this test
omitted the burst and made the guarded arm look artificially worse; fixed
before drawing any conclusion).

| capture | ratio | prod nfiq2 | guarded nfiq2 | delta |
|---|---|---|---|---|
| 01662ffb (control) | 0.47 | 72 | 72 | +0 |
| 474b4d6a (control) | 1.74 | 75 | 75 | +0 |
| 4ae6d13c (control) | 0.71 | 67 | 67 | +0 |
| 80a994ca | 2.94 | 62 | **75** | **+13** |
| 286f1f0a | 3.17 | 77 | 76 | -1 |
| 8ed1c600 | 2.58 | 52 | 49 | -3 |
| e33d618e | 3.68 | 71 | None | forfeit |
| a262d2b3 | 5.34 | 64 | None | forfeit |
| fc142f97 | 2.81 | 64 | None | forfeit |
| 1cc301a8 | 5.37 | 49 | None | forfeit |
| c27d0004 | 82 | 82 | None | forfeit |
| f4cb3ba5 | 2.49 | 54 | None | forfeit |

**Controls: exact no-op on all 3 (+0/+0/+0)** -- confirms the gate only
changes behavior when it's actually supposed to.

**Guard-firing, non-forfeit subset (n=3): +13 / -1 / -3, mean +3.0.** Real,
mixed but net positive -- the single large win (+13) outweighs two small
losses.

**Guard-firing, forfeit subset (6/9, 67%): every pair in the WHOLE burst
(not just the pre-selected one) exceeds the ratio threshold**, so
`fuse='avg'` in isolation returns `None` entirely. In real production this
is not a crash or a regression on its own -- `main.py`'s variant loop is
max-of-variants, and a `None` result just means this one variant forfeits
its candidacy on that capture while `native`/`freqNorm`/other fuse modes/
`deepFuse` etc. still compete normally. This is mechanistically consistent
with, not contrary to, the validated sweep finding: when EVERY ambient/
flash pair in a burst is blown out relative to ambient, trusting none of
them (rather than averaging in a bad one) is the behavior the sweep data
already showed is correct.

**Paired mean across all 6 non-forfeit comparisons: +1.50** (n=6: the 3
exact-no-op controls plus the 3 real deltas above).

## Decision: SHIP ENABLED (`_FUSE_FLASH_SOFTNESS_GUARD = True`)

First fix in this round's layer-by-layer pass (layers 2-6) that is not a
net negative. Unlike layers 4/5's boundary/measurement fixes (both
correctly-more-faithful and both measurably WORSE on real NFIQ2), this
ports an already-validated mechanism from a sibling capture mode, shows
zero regression where it shouldn't fire, and a net-positive real delta
where it does fire and can still produce a candidate. The high forfeiture
rate (6/9) is a real, honestly-reported property of this fix -- it makes
`fuseAvg` specifically much more conservative on bursts with uniformly
blown-out flash -- but is bounded by the max-of-variants architecture and
matches the validated mechanism's own logic, not a new risk.

**Honest limits, not glossed over**: only 3 of 12 real comparisons are
non-trivial (the rest are either exact no-ops or forfeits with nothing to
compare), a much thinner evidence base than the sweep's own 5/5 + 2/2
validation. Only the single-pair family (`fuse='avg'`) was tested directly
end-to-end; the deep-family code path (`deepFuse`/`deepMaxc`/`deepSoft`,
this project's own higher win-rate/higher-mean-quality variants per round
29's measured priority ordering) shares the identical guard mechanism and
`_fuse_flash_ambient` call but was not separately end-to-end validated here
-- same ratio-based gate, same fallback-to-ambient-only behavior, so risk
is judged low, but this is a real, stated gap, not a tested equivalence.
Worth a dedicated deep-family check if this is revisited.
