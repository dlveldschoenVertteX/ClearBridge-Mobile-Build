# Phase 0 findings — does the fusion premise hold?

Measured on 4 real captures (2 with focus-zone + camera-2 macro, 2 with real
sweep-zone data), every source rendered through the real production
`afis_print.generate()` and templated with real `mindtct -m1`.

| source family | n | minutiae | corroborated | unmatched-in-overlap | NEW coverage |
|---|---|---|---|---|---|
| front_v1 (anchor) | 4 | 440 | **84.3%** | 12.0% | 3.6% |
| focuszone | 8 | 1591 | 64.1% | 26.1% | 9.7% |
| macro (cam 2) | 2 | 310 | 62.9% | **32.3%** | 4.8% |
| sweep | 10 | 875 | 59.9% | 23.5% | **16.6%** |

## Verdict: premise SURVIVES, unevenly

**1. Minutiae-space registration works across genuinely different
architectures.** This is the single most important result. Every source --
including a different physical lens (macro) and different guide positions
(sweep zones) -- registered onto the front-V1 anchor. On the strongest
capture (nfiq2 86) `sweep_center` reached 78/112 inliers and front_v1
corroboration hit 91%. Pixel-space registration is what failed in this
project before (`ml/mosaic_register`: val loss frozen across a 200-epoch real
GPU run, zero learning). Point-set registration succeeds where that failed.

**2. front_v1 is the correct anchor.** Highest corroboration (84.3%) and
lowest unmatched rate (12.0%) of any family -- the cleanest, most
self-consistent source.

**3. Sweep is the real coverage contributor** -- 16.6% of its minutiae sit in
territory NO other source covers (145 minutiae; per-zone median 10, max 41).
This directly supports "sweep sees ridge detail the others can't."

**4. Focus-zone stills add little new territory** (median 6 per zone) -- as
expected and by design: they share framing with the main burst, only the AF
target moves. Their value would be better local focus, not new coverage.

**5. Macro (camera 2) is the weakest fusion contributor** -- lowest new
coverage (4.8%) AND the highest unmatched-in-overlap rate (32.3%). Worth
stating plainly because it cuts against expectation: this is the camera that
just won two production captures outright on NFIQ2. It is a strong
SELECTION candidate and a weak FUSION contributor. Those are different jobs,
and this is real evidence to keep it in the first role, not force it into the
second.

## The unresolved question, stated honestly

`unmatched-in-overlap` (12-32% across families) is genuinely ambiguous. A
minutia one source sees, sitting where other sources have coverage but do
NOT see it, is either:
  - spurious (detector noise) -> fusion must reject it, or
  - real but only resolvable in the sharpest source -> fusion should keep it.

**Nothing in the current data can distinguish these**, because there is no
trustworthy ground truth: the single ink scan cannot separate genuine from
impostor (both sit at the 0-10 noise floor). This is precisely the gap the
50 Phase-1B scanner references would close, and it is the difference between
fusion adding real matchable structure and fusion adding noise.

## Recommendation

Proceed to Phase 1 (classical consensus fusion, no ML), with priorities set
by the measurements above rather than by assumption:
  - anchor on front_v1
  - treat SWEEP as the coverage-adding architecture worth the capture cost
  - do NOT expect focus-zone or macro to contribute much new territory
  - gate everything on real SourceAFIS separation vs. single-best-candidate

Phase 2 (learned per-minutia reliability) stays blocked on real scanner
references. Without labels there is no way to resolve the ambiguity above,
and this project has already lost five ML attempts that trained against
proxies instead of the real target.
