# ClearBridge Mobile — persistent context

## Camera-2 macro capture, first real device test: two real bugs found and fixed (2026-08-20, round 24)
Direct follow-up to round 23's brand-new `_captureMacroShot()`. First real
device test (screenshot) showed the guide + "Capturing close-up detail…"
banner rendering correctly, but the camera feed underneath was solid
black, and the CTO reported "camera 2 had no live stream." Pulled the
matching real Firestore doc rather than trust the screenshot alone.

**Bug 1, confirmed and fixed: no rebuild after the camera swap.**
`_cameraLayer()` reads `_cameraService.controller` fresh only on
`build()`, and rebuilds only fire via this controller's own
`notifyListeners()` (`_apply`). The only `_apply` call in
`_captureMacroShot` ran BEFORE `initializeCamera()` even started
swapping to camera "2" — so the screen's one rebuild for this whole step
happened while the controller was still mid-swap (old camera disposed,
new one not yet ready), and `_cameraLayer()`'s own null/uninitialized
fallback rendered a flat black `ColoredBox`. With no further rebuild ever
fired, nothing ever replaced it — exactly what the screenshot showed.
Fixed with a second, forced `_apply` call right after the swap completes.

**Bug 2, found via the real Firestore data, likely the more consequential
one: no overall timeout on the sequence.** The same real capture from
this test (`c27d0004`) landed with `secondaryCameras: null` — meaning
`_captureMacroShot` didn't just have a rendering problem, it failed to
produce ANY result on this run (self-skipping already caught whatever
happened, so the main capture wasn't affected). Re-read this file's own
already-established discipline for exactly this class of risk:
`_sweepBurstTimeoutMs`'s own docs state plainly that try/catch alone
cannot protect against a hang, since `takePicture()` is a raw platform-
channel await with no timeout of its own — and camera "2" has a long,
real history in this project of being the slowest camera to open/upload
(multiple earlier rounds hit this exact failure mode on this exact
camera). `_captureMacroShot` never got the same outer-timeout treatment
every other per-camera-turn sequence in this file already has. Fixed:
wrapped the whole open+focus+capture+upload sequence in one real 45s
bound (`_macroCaptureTimeoutMs` — real camera-open retry structure alone
can take up to ~32s worst case per `CameraService`'s own internal 12s+20s
retry, plus margin for focus/shutter/one real upload attempt).

**Not fully confirmed yet** — both fixes are real, well-evidenced, and
directly explain the observed symptom, but neither has been re-tested on
a real device. The next real capture with these fixes is what confirms
whether the feed renders correctly AND whether `secondaryCameras`
actually lands non-null.

## Focus-lever audit: camera-2 macro wired as a dedicated final capture; focus-zone-splice audited on real matchability (not NFIQ) and found to be a real, additional negative (2026-08-20, round 23)
Direct follow-up to the earlier "audit focus levers" request. Two real
findings, one implemented, one closes out a standing open question with a
decisive answer.

**Camera "2" (macro) wired as a dedicated final capture.** New
`_captureMacroShot()` (`front_capture_controller.dart`) fires after the
main 8-frame burst (and the currently-disabled sweep burst) but before
the upload screen -- a real, separate camera "2" session, never
interleaved into the main burst. Guide grown 20%
(`PadSilhouetteShape.scaled(1.2)`) per explicit CTO direction, to pull
the thumb physically closer to this lens. Focus convergence reuses the
existing `_retargetAndConverge` poll loop (measured, not a blind delay --
this project's own hard-learned lesson from the original secondary-
camera focus fix, round 5) via a dedicated local sharpness listener, not
`_onFrame` (which carries main-camera-specific state that doesn't apply
to this lens). Uploads under the existing `secondaryCameras` field/path
convention `main.py`'s own secondary-camera scoring loop already
consumes -- no backend consumption changes needed, since that loop
already derives camera "2"'s real sensor-corrected crop region from
`cameraLensInfo` (fixed 2026-07-29).

**Real, proactively-caught conflict, fixed alongside it**: pulling the
thumb closer will raise this camera's own measured native wavelength,
and the existing secondary-camera selection gate
(`_SECONDARY_MAX_WAVELENGTH_PX = 19.5`, non-IR) would very likely have
silently blocked this feature's own output from ever winning selection --
shipping a "get closer" feature that then gets vetoed by a "too close"
gate. New `_SECONDARY_MAX_WAVELENGTH_PX_MACRO = 35.0`, scoped to camera
"2" only (camera "3"'s own IR ceiling untouched), matching round 17's own
real matchability finding and exact number for the identical reason.
Flagged as provisional pending real device data, same as every other
threshold in this pipeline. Not yet device-tested.

**Focus-zone-splice: real matchability audit (SourceAFIS vs. the ink
scan, not NFIQ2), decisive negative.** Direct answer to "does it improve
ridge continuity, not just NFIQ" -- reproduced the ACTUAL production
`focusZoneSplice` candidate (`main.py`'s own `afis_print.generate(enhance
='focusZoneSplice', ...)` call, byte-for-byte) for all 10 real captures
with `focusZoneShots` data, compared against the plain `native` full-
frame candidate on the same real SourceAFIS-vs-ink-scan gate used
throughout this session.

**First pass was contaminated by a real harness bug, caught before
trusting the result**: 6/10 captures showed byte-identical native/splice
output. Root cause was in MY test script, not production --
`_focus_zone_splice`'s own shape-equality safety check
(`_focus_zone_splice`'s docstring: "the client's own decode pipeline uses
the identical... center-square crop for the zone shots as the main
burst, specifically so these stay pixel-aligned") silently no-ops when
shapes don't match, and my harness downloaded the main ambient/flash
frames RAW/rectangular instead of replicating
`_download_front_only_frames`'s own center-square crop -- a real
methodological gap in the test, not a production defect. Fixed the
harness to match production's `_load()` exactly and re-ran; all 10
captures then showed genuine engagement (real, differing scores).

**Corrected result: native mean 1.004, splice mean 0.771, splice wins
4/10 (40%, worse than a coin flip).** Splicing the per-zone dedicated-
focus stills into the delivered print does not improve real matchability
-- it trends measurably WORSE on average. This is a second, independent,
additional negative on top of what was already known: `focusZoneSplice`
has also never once won real production selection on NFIQ2 (needs to
beat `native` by a 5.0 margin, never observed to in the last 15+ real
captures checked). Combined with the same round's earlier finding that
the whole focus-zone-bracket costs ~12-16s of real device time per
capture (unchanged since round 8), this closes the loop the CTO's
original question was pointing at: the feature is real, expensive, and
now shown on the metric that actually matters (not just NFIQ) to not be
helping. **Recommending this be disabled** (`_focusZoneBracketEnabled =
false`) to reclaim the real per-capture time cost, though this is a
product call, not actioned unilaterally without explicit direction.

**Also confirmed, not new this round**: the lens-probe diagnostic
(`capture_harness`'s `LensProbeScreen`, round 15) is fully on-device with
zero Firestore/Storage upload by design -- I have no way to see its
captured stills or its `getCameraExtensionSupport` result from this
session. The real, already-established evidence (camera "2": 2.37mm
focal length, 3.92x2.94mm sensor, smallest/shortest of all four cameras)
still points at it being a real macro-ish sensor; the definitive answer
needs the CTO's own visual comparison against a stock-Macro-mode
reference photo.

## First real device test of the round-17 wavelength-gate raise (16->35): confirmed working, strong score, one new unexplained wrinkle flagged (2026-08-20, round 22)
CTO ran a real capture (`d0ec5195`) on the just-built/deployed APK, the
first real device test of round 17's `_liveWavelengthTooHighPx` raise
(16.0 -> 35.0 -- the explicit CTO call that real matchability favors
closer capture, not farther). Pulled the real Firestore doc rather than
assume anything from "test done" alone.

**Real, positive confirmation.** `liveWavelengthDebug.wavelengthGateThresholdPx:
35.0` -- the raised gate is live in production on this real capture, not
just committed. `sampleCount: 186` (healthy, nowhere near the historical
`sampleCount:0` problem), `wavelengthGateExpired: false` (the hold
resolved on its own, never needed the 6s escape hatch). The real backend
measurement, `afisWavelengthPxRaw: 28.0` -- squarely inside the 16-35px
band the OLD gate would have blocked and the new one now allows -- and the
capture scored a real, strong **NFIQ2 74** (`afisMask: guide+unet`,
`henryClass: AW`). Direct, real evidence the CTO's product call is working
as intended: a closer capture that the pre-round-17 gate would have
rejected now gets through and scores well.

**One new, real, unexplained discrepancy -- flagged honestly, not acted
on (n=1).** This same capture's LIVE-domain wavelength estimate
(`liveWavelengthStillPx: 12.19`) is ~2.3x smaller than the real backend
measurement of the actual captured frame (`afisWavelengthPxRaw: 28.0`).
This directly contradicts the round-13 calibration (`_wavelengthScaleToStill`
returns a flat `1.0`, justified at the time by 5 real data points averaging
close to a 1:1 live-vs-backend ratio) -- this capture's ratio is ~0.44, well
outside that established range. Per round 13's own stated caveat ("if a
future `_stillDecodeTargetWidth` or preview-resolution change shows real
drift again, re-validate... rather than assuming 1.0 holds forever"), this
is exactly the kind of fresh data point that question would need -- but
one real capture isn't enough to act on by itself, same "don't tune blind
off a single data point" discipline as everywhere else in this project.
Not investigated further this round; worth checking again once a few more
real captures on this same build land, to see whether this is a real,
reproducible drift or a one-off (e.g. this specific capture's hold took an
unusually long time to resolve gate-wise, `wavelengthNullAttempts: 25` out
of `sharpnessSampleCount: 1733` -- not obviously anomalous by itself, but
noted in case a pattern emerges).

No code changes this round -- this is real-device confirmation of an
already-shipped, already-deployed change, plus one flagged (not actioned)
observation for the future.

## Mask-preference reorder (guide+unet over guide+flashdiff) tested and REJECTED — the earlier aggregate comparison was confounded, controlled test shows no real advantage (2026-08-20, round 21)
Direct follow-up to round 20's own closing suggestion ("worth considering
whether `guide+unet` should be preferred more aggressively over
`guide+flashdiff` in the mask-selection order"). Before implementing that
reorder in `afis_print.py` (currently `_flash_diff_mask` is tried first,
`_unet_mask` only as a fallback when it returns `None`), ran the real
controlled test the suggestion itself hadn't had yet: forced `_unet_mask`
on the exact same 12 real captures that currently resolve to
`guide+flashdiff` under the fixed seed (round 20), same burst content, same
guide region, only the detector swapped (`_flash_diff_mask` monkeypatched
to return `None`, isolating exactly the choice this reorder would make).

**Real result: no advantage, and the earlier evidence for the reorder was
confounded.** flashdiff mean 0.650, forced-unet mean 0.667 — a wash. Unet
wins only 4/12 (33%, worse than a coin flip). On 5 of 12, `_unet_mask`'s
own coverage accept-gate REJECTED the detected mask outright and fell back
to bare `guide` — it isn't even reliably producing a usable pad mask on
these specific captures, let alone a better one.

This directly explains why round 20's own aggregate numbers
(`guide+unet` mean 3.872 vs `guide+flashdiff` mean 1.351,
`mask_correlation.json`, n=21 vs n=19) looked so lopsided: those are
DIFFERENT real captures that happened to route to different mask paths in
production, not the same captures scored under both masks. Flash-diff and
unet plausibly engage on systematically different kinds of captures to
begin with (e.g. flash-diff needs a usable ambient/flash pair at all;
unet is the fallback when it doesn't), so the aggregate group means
reflect whatever real quality differences already existed between those
two capture populations, not a clean causal effect of the mask choice
itself. Same confound class already caught once before in this project
(the pad-gate "more fusion = better" reversal, 2026-08-13) — an aggregate
comparison across non-matched groups looked like a real effect until a
same-item controlled test said otherwise.

**Not implementing the reorder.** The real, controlled, causal test — not
the aggregate one — is the one that should decide this, and it argues
against the change. `_flash_diff_mask`-first stays as-is. No code change
made this round; this closes out round 20's own open suggestion with a
real negative, rather than leaving it as an unverified TODO or acting on
it blind.

## Flash-diff mask seed fix, real follow-up test: does NOT close the matchability gap toward guide+unet — a visually-correct fix that didn't move the real score (2026-08-20, round 20)
Direct follow-up to round 16's flash-diff mask fix (`339a1e2`, committed,
NOT deployed): that round found and fixed a real bug (`_isolate_thumb_lobe`
seeded at the bare frame centre instead of the true `guide_region` centre,
a 555px real offset) and visually confirmed the fix correctly re-centres
the mask on ONE real capture (`14674391`). That entry's own final line
flagged the real next step, not yet done: "re-run this same session's
mask-vs-matchability sweep (63 real captures) to confirm `guide+flashdiff`'s
real mean score closes the gap toward (or past) `guide+unet`'s 3.87, not
just that one capture's mask looks visually correct now." Ran that test
this round, on the CURRENT (fixed) code, against all 19 real captures
whose PRODUCTION mask had resolved to `guide+flashdiff` (the original
`mask_correlation.json` sweep — same real SourceAFIS-vs-ink-scan harness
used throughout this session).

**Real result: it does not close the gap.** Mean score barely moved:
**1.351 (old, buggy seed) -> 1.362 (new, fixed seed)** — nowhere near
`guide+unet`'s established 3.872 mean. Win rate 9/19 (47%), a coin flip.

**Broke this down further, and the more precise picture is less
flattering than the flat mean alone suggests.** Of the 19 captures, the
fixed code still resolves 12 to `guide+flashdiff` (the fix changed the
seed, not whether flash-diff's own accept-gate takes the result), 6 now
fall back to `guide+unet` (the seed fix apparently makes the flash-diff
candidate fail its own area/coverage accept-gate more often than before),
and 1 falls back to bare `guide`.

- **Among the 12 that stayed `guide+flashdiff`**: mean delta is
  **NEGATIVE, -0.88** (sum -10.6/12) — on the captures where the seed fix
  is actually doing what it was built to do (a correctly-centred
  flash-diff mask, same mechanism, just fixed geometry), real matchability
  trended slightly WORSE, not better, on this sample.
- **Among the 6 that fell back to `guide+unet`**: mean delta is
  **positive, +1.94** — but this is dominated by one outlier
  (`3f8fd075`, +9.04) that also carries this project's own
  already-documented `nfiq2Score: 586` data-integrity bug (a known sidecar
  parsing defect unrelated to masking) — a single anomalous capture, not a
  reliable signal. Excluding it, the remaining 5 average +0.52 — a mild,
  not decisive, lean positive, and this "win" isn't really the seed fix
  working — it's the seed fix incidentally making flash-diff fail its
  accept-gate more often, letting the ALREADY-established stronger
  `guide+unet` mask take over instead.
- **The exact capture visually confirmed in round 16 (`14674391`)** scored
  **0.0 in BOTH the old and new run** — the mask is visibly, unambiguously
  better-centred now (round 16's own overlay proved this), but the real
  SourceAFIS-vs-ink-scan score didn't move at all on this specific
  capture. A direct, humbling confirmation that a visually-correct mask
  fix does not automatically show up in this particular metric.

**Honest interpretation, not spin either direction.** This isn't strong
evidence the fix is WRONG — it's still a real, independently-verified bug
fix (the mask objectively covers the correct anatomical region now,
confirmed by direct pixel-space calculation and visual overlay in round
16, unrelated to whatever this score says). But it IS strong evidence
against the specific hope that fixing this one seeding bug would, on its
own, meaningfully close `guide+flashdiff`'s matchability gap toward
`guide+unet`. The same standing noise-floor caveat this project has
already established for the single-ink-scan SourceAFIS gate applies here
too (absolute scores 0-10 on a matcher whose practical match threshold is
~40) — a modest real improvement could in principle be hiding under this
gate's own known insensitivity. But there is no evidence of one in this
data, and the flashdiff-retained subset trending negative argues against
assuming one exists.

**Not recommending further optimization effort on `_flash_diff_mask`
specifically on the strength of this round's result** — the seed bug was
real and worth fixing regardless (it was producing masks centred on
knuckle/crease content some of the time, a correctness bug independent of
this score), but this data doesn't support treating the flash-diff path
as a promising lever for closing the real matchability gap toward
`guide+unet`. `guide+unet` remains the stronger mask by a wide, consistent
margin (3.872 vs. 1.362) — worth considering whether `guide+unet` should
be preferred more aggressively over `guide+flashdiff` in the mask-
selection order, though that's a real product/pipeline decision, not
actioned here without explicit direction. Fix stays committed (`339a1e2`,
still not deployed) since it's still the objectively correct mask-geometry
behavior; this round's finding is about its downstream matchability
effect, not about whether to keep the fix.

## Learned scale-normalizer: mixed MAC3D+SD302 checkpoint validated against the real SourceAFIS gate — no clear win, real mechanistic reason found (2026-08-20, round 19)
Direct follow-up to the CTO's "move to NIST SD302" instruction: retrained the
mixed-corpus checkpoint (113 real MAC3D superprints + 300 sampled NIST SD302
contact prints, cosine LR schedule) with checkpoint saving added to
`train.py` (previously never saved a checkpoint — every prior local run's
weights were unrecoverable once the process exited), then ran it through
this project's own established real-data validation gates rather than
trusting the training-loss curve alone, per this pipeline's standing
discipline (see `pyfingHybrid`/`nnsHybrid`/`coherenceDiff`/`deform_correct`
v1-v3 — every one of those was measured against real matchability before
any adoption decision, several came back negative despite a healthy loss
curve).

**Circularity check run first, not skipped.** The self-supervised training
scheme treats every real source image (all 63 cached MAC3D superprints
included) as canonically-scaled (log_scale=0) by construction — it only
ever learns to detect a distortion applied ON TOP of those images, never
their own pre-existing native scale offset. Since those same 63 real
captures are literally in the training source pool, there was a real risk
the network would just tautologically predict ~0 on all of them regardless
of true wavelength. Checked directly: correlation between the model's raw
prediction on each of the 63 real (unperturbed) captures and that
capture's already-established classical ridge-wavelength estimate
(`wl_raw`, from this session's earlier `sweep_results.json`) came back
**r=+0.527** — a real, moderate positive correlation, not zero, so the
network did retain some transferable scale-sensitive signal rather than
pure memorized identity. But the model's own predicted range is far
narrower than reality (std=0.080 log-scale vs. classical's std=0.220) —
it's a much more conservative/muted corrector than the classical estimate,
consistent with partial (not total) anchor-memorization pulling
predictions toward 0.

**Real SourceAFIS gate vs. the CTO's ink scan (n=63, same harness as
`run_sweep.py`, only the probe DPI estimate swapped — classical
`wl_raw`-based vs. model-predicted):**

| condition | mean best score | wins | losses | ties |
|---|---|---|---|---|
| classical (wl_raw-based DPI) | 2.618 | — | — | — |
| model-predicted DPI | 3.109 | 34/63 | 28/63 | 1/63 |

A 54% win rate at these absolute score magnitudes is not a real
differentiator — both conditions sit deep in the noise-floor territory
this exact gate was already established to occupy earlier this session (a
single low-quality ink scan can't reliably separate genuine from impostor
at this quality level; genuine and impostor captures alike score
single-digit-to-low-teens against it). Some individual deltas are large in
both directions (e.g. `69a2d180` +27.8, `5363a49b` -14.0) but with no
consistent pattern tying big wins/losses to anything measurable (not
concentrated in the CTO's own genuine captures) — reads as gate noise, not
signal.

**Real, mechanistic explanation for why the model doesn't clearly win**:
the muted prediction range found in the circularity check directly
predicts this outcome. Captures that most need aggressive correction
(high native `wl_raw`, e.g. 16-17px, where classical DPI reaches
850-950) get pulled by the model to a much narrower 500-600 DPI band —
under-correcting exactly the captures where correction should matter most.
This is the same class of finding as `ridgeRestoreHybrid` v2's real
regression from small-volume real-data mixing, though the failure
mechanism here is different (under-correction from anchor-conservatism,
not signal dilution from a mismatched second corpus).

**Genuine-vs-impostor cross-capture gate (the more decisive test per this
project's own established preference for it over the single-ink-scan
comparison) could NOT be run this round**: only 1 genuine pair exists
among the 63 currently-cached local superprints (the cache was built from
a top-NFIQ2 selection, not full per-user coverage — most of this
project's 10 real multi-capture users have only 0-1 of their repeat
captures cached locally). Attempted to download the 16 missing captures
directly from Storage to fill this out properly; blocked by
`DefaultCredentialsError` — this fresh sandbox has no GCP service-account
credentials configured (the temporary key used earlier this session did
not persist). **Flagged honestly, not silently skipped**: the ink-scan
gate result above is the best real evidence available this round, and it
does not show a clear win. The cross-capture gate remains the real next
check once credentials are available again, and per this project's own
standing discipline, is what should actually decide viability, not this
weaker proxy.

**Conclusion, stated plainly**: the mixed MAC3D+SD302 checkpoint does not
currently demonstrate a real matchability improvement over the
already-existing classical ridge-wavelength DPI estimate already used in
production (`estimate_dpi.py`/`_ridge_wavelength_robust`, the same
mechanism `mindtct_client._normalize_dpi` and this session's SourceAFIS
sweep both already rely on). The clean, monotonic training-loss curves
from every run this session (63-image, 113-image, 113-image scheduled,
mixed 331-image scheduled) were real and never in question — the gap is
between "trains cleanly on its own synthetic task" and "the trained
correction helps the real downstream matcher," and this round's real data
says it doesn't yet, for a real, identified reason (anchor-conservatism
muting the correction exactly where it's needed most). **Not recommending
further scale-normalizer iteration (bigger SD302 volume, more epochs,
SageMaker) without first addressing the circularity in the training setup
itself** — e.g. holding a fraction of real captures OUT of the source pool
entirely and only ever using them as scale-unknown eval targets, never as
distortion-anchor material, so the network is forced to learn transferable
scale features rather than exploit its own anchors. That's a real,
buildable next step, not a dead end — but a different fix than "more of
the same data," which this round's evidence argues against by itself.
`train.py`'s new checkpoint-saving capability (real, added this round —
previously no run's weights were ever recoverable) is committed and
useful regardless of this checkpoint's own result.

## Scale-normalizer data plan: NIST SD302 approved as a second source, explicitly sequenced behind MAC3D stability (2026-08-19, round 18 cont.)
CTO direction, real and well-reasoned: since training operates on
BINARIZED prints (not continuous-tone), a real digital scanner print is
equally valid source material for the same self-supervised synthetic-
scale-distortion task -- meaning the much larger, cleaner NIST SD302
corpus (SD302a/b/d contact prints, already used successfully once before
in this project for `ml/deform_correct`'s own synthetic-distortion
training) is a legitimate second data source, not just this session's 63
MAC3D superprints. Same "apply a known distortion, inflate px scale,
supervise against the known ground truth" pattern already built.

**Explicit sequencing, CTO's own call**: do NOT mix in SD302 until the
MAC3D-only track shows a genuinely stable progression on its own. This
directly avoids a real, already-documented failure mode in this exact
project: `ridgeRestoreHybrid` v2 (2026-08-08) mixed 59 real captures into
an SD302-trained checkpoint at exactly this small a volume and
REGRESSED (mean -3.1, win rate 54%->31%) versus the SD302-only v1 --
"the 59 real crops... diluted the model's clean ridge-restoration signal
without teaching it anything that transfers, at this small a mixing
volume." Same risk class here, same avoidance strategy. NIST SD302
integration is approved in principle, gated on MAC3D-only training
demonstrating real stability first (more epochs/data, and critically,
validated against the real SourceAFIS matchability sweep, not just a
smoothly-decreasing loss curve).

## Learned scale-normalizer, first local CPU smoke test: real, clean positive trend (2026-08-19, round 18)
Per the CTO's direction ("I believe that the normalization training will be
more successful... let's move forward with a local CPU test, if it goes
well for the first 15 epochs we will see a trend"), built the scale-only
learned normalizer proposed as the C2CL-inspired alternative to hand-tuned
`_FREQ_SCALE_MIN`.

**Built** (`ml/scale_normalize/`): `ScaleRegressorNet` (small CNN, 5 conv
blocks + global-average-pool + 2-layer head, ~198K params, GroupNorm not
BatchNorm2d per this project's own already-learned lesson), trained
self-supervised on synthetic scale distortion applied to real source
material — 63 real `superprint_afis.png` renders already downloaded this
session's SourceAFIS matchability sweep, same "apply a KNOWN distortion to
real clean material, train the net to invert it" pattern that trained
cleanly for `ml/deform_correct` (unlike the earlier SD302f real-pair
approach, which never converged). Deliberately narrower than
`deform_correct`'s full per-pixel deformation field: predicts a single
scalar log-scale correction factor, a much more constrained/tractable
target, per this round's own plan.

**First local CPU run, 15 epochs, ~50s wall time, real and clean — no
mean-collapse, no divergence, no NaN**:

| | train_loss | val_loss | val_scale_mae |
|---|---|---|---|
| epoch 1 | 0.163 | 0.050 | 0.254 |
| epoch 15 | 0.014 | 0.007 | 0.090 |

val_loss mean dropped 43% from the first half of training to the second
half. By epoch 15 the network's predicted scale factor is off by ~0.09 on
average (real units) against a true synthetic range spanning ~0.3x-3.5x —
a real, fast improvement, not noise.

**Honest caveat, stated plainly**: validation is only 12 distinct source
images (63 real captures split 51 train/12 val) — real project-domain
data, not synthetic filler, but small enough that some of this
improvement could be partial memorization of those 12 images' own content
rather than a fully general scale-invariant feature. The clean,
non-collapsing curve is a genuinely good sign the architecture/training
setup are sound — it is NOT yet proof this generalizes, and is NOT yet
validated against real matchability (the only metric that actually
matters per this project's prime directive) or wired into
`afis_print.generate()` in any way.

**Real next step, not yet built**: apply the trained network's predicted
correction to a real capture and run it through the SAME real SourceAFIS-
vs-ground-truth sweep already built this session, compared against the
current `freq_normalize`/`_FREQ_SCALE_MIN=0.7` baseline (which that same
sweep just confirmed is already near-optimal on this small sample) — that
comparison, not the training loss curve, is what decides whether this is
worth pursuing further (a bigger real corpus, more epochs, eventually
SageMaker) or a dead end, same standing discipline as every other ML
candidate in this pipeline.

## Distance-gate reversed on explicit CTO product call: real matchability wants closer, not farther (2026-08-19, round 17)
Direct follow-up to the mask-vs-matchability sweep: the real winners all sit
at wlRaw 28-30, squarely inside what `_liveWavelengthTooHighPx=16.0` was
built to block. CTO's explicit call, stated plainly: "we need ridge
continuity more than we need NFIQ at this point." Raised
`_liveWavelengthTooHighPx` 16.0 → **35.0** — grounded in the same 63-capture
sweep's real backend `afisWavelengthPxRaw` stats (n=44: mean 23.8, sd 6.4,
max 30.0, mean+2sd=36.6), and lands independently on the exact same number
sweep's own analogous threshold was already recalibrated to on 2026-08-14
for the identical reason ("reframed from an optimization target to a pure
safety backstop"). No longer an optimization target — a backstop against a
genuinely pathological outlier only.

**Real, unresolved follow-on flagged, not silently changed**: the
`_DistanceBanner`/`distanceHint` copy ("Push Print Backward") and the
wave-cue's own anchor points (`_liveWavelengthTargetPx=11.5`,
`_liveWavelengthCueCeilingPx=26.0`) are ALL still built around the old
NFIQ2-driven "closer is bad" framing — now directly inconsistent with this
gate change (the cue would read "maxed out, too close" at wl 26 while the
gate no longer blocks until 35, and the banner would still tell a user
moving into the real-matchability-favorable 28-30 range to back away).
Deliberately NOT touched this round — changing what the app tells the user
to physically DO is a bigger UX decision than the backstop threshold itself,
flagged for explicit direction before acting.

Not yet device-tested. Client-only change (no backend), needs only a push
to reach a real build.

## Real root cause of the guide+flashdiff matchability deficit, found + fixed + visually confirmed: the lobe search was seeded at the wrong point (2026-08-19, round 16)
Direct follow-up to the mask-vs-matchability sweep (round 15's own predecessor
finding): `guide+flashdiff`-masked captures scored ~1/3 the real matchability
of `guide+unet`-masked ones despite near-identical NFIQ2 (76.1 vs 79.3),
pointing at a real defect in flash-diff's own mask boundary rather than a
capture-quality difference. Investigated directly rather than guess.

**Reproduced a real `guide+flashdiff` capture's exact mask locally**
(`14674391`, score 0.00 in the sweep) — downloaded its raw ambient/flash
burst pair, ran the real `sfm_pipeline._segment_via_flash_diff` used in
production, and overlaid the resulting contour on the raw frame. **The mask
was centered on a knuckle/flexion-crease region, not the fingertip pad at
all** — visually unambiguous (multiple horizontal crease grooves inside the
boundary, no whorl pattern anywhere near it).

**Real, precise root cause, confirmed by direct calculation before touching
any code**: `_isolate_thumb_lobe`'s seed point is hardcoded to the frame's
bare geometric centre (`w_img/2, h_img/2`) — correct only if the guided pad
sits at cx=0.5. front_only_v1's real `guide_region` is cx=0.63 (confirmed
via `_superellipse_mask`'s own docstring: its region is already in the same
coordinate space `generate()`'s raw frame uses, no rotation adjustment
needed here) — a real, non-trivial **555px offset** on a 4266px-wide raw
frame (13% of width). The mis-centred lobe search in the reproduced capture
landed at (2149.5, 1437.5) — almost exactly on the WRONG assumed centre
(2133, 1600), nowhere near the true guide centre (2687.6, 1600) — direct,
numeric confirmation this is the actual mechanism, not a coincidence.

Same bug CLASS already diagnosed and fixed once before in this exact
codebase, just in a different code path: the 2026-08-14 `_scoreRoi` fix's
own real evidence item 3 states "cropping a real capture by the OLD
[uncorrected] rect yields knuckle skin plus background with essentially no
pad ridges at all" — the identical failure signature, now found in
`_flash_diff_mask`'s call into `_isolate_thumb_lobe`, which never got that
fix applied to it.

**Fixed**: `_segment_via_flash_diff` (`sfm_pipeline.py`) gained optional
`seed_cx`/`seed_cy` params (pixel space), defaulting to the old frame-centre
behaviour when omitted — every other caller (arc_sweep/oscillating) is
byte-for-byte unaffected. `afis_print._flash_diff_mask` now threads its
already-in-scope `guide_region` through, computing the real seed as
`guide_region['cx']*w, guide_region['cy']*h` instead of assuming centre.

**Re-ran the exact same real capture through the fixed code and visually
confirmed the mask now correctly wraps the actual fingertip pad**,
whorl/ridge pattern included, no crease content — a completely different
(correct) region from the pre-fix contour. Real, decisive, non-speculative
before/after comparison — not inferred from a plausible-sounding theory.

**Committed, NOT deployed** — needs its own explicit deploy go-ahead like
every other backend change. Real next step once deployed: re-run this same
session's mask-vs-matchability sweep (63 real captures against the ground-
truth ink scan) to confirm `guide+flashdiff`'s real mean score closes the
gap toward (or past) `guide+unet`'s 3.87, not just that one capture's mask
looks visually correct now.

## Lens-probe diagnostic built to answer "is my phone's stock Macro mode a real lens we could use?" (2026-08-19, round 15)
CTO sent screenshots of their stock camera app: "Macro" appears as its own
mode tile under "More" (alongside Pro/Portrait/Bokeh/Mono), not a toggle
inside regular Photo mode — real evidence favoring "genuinely separate
hardware lens" over "software crop heuristic". Cross-referenced against
real `cameraLensInfo` data this project already collected: camera "2" has
the shortest focal length (2.37mm vs. main's 4.15mm) and by far the
smallest sensor (3.92×2.94mm vs. main's 5.98×4.49mm) of the four cameras —
the classic signature of a budget quad-camera phone's dedicated macro
sensor. Camera "2" has been used as a secondary/bonus capture camera all
project, just never explicitly recognized as "the macro lens" specifically
— front_only_v1's primary capture has always used camera "0" (main).

**Built a standalone, `capture_harness`-only diagnostic** (per this
project's own standing "no one-off diagnostic tooling in the production
clearbridge_beta app" precedent, commit `4a832c0`) to settle this on a
real device, two independent ways:
1. **`getCameraExtensionSupport`** (new native method,
   `capture_harness/android/.../MainActivity.kt`): queries Android's formal
   Camera2 Extensions API (`CameraExtensionCharacteristics`, API 31+) per
   camera id for `EXTENSION_MACRO` support — if this device implements
   Macro as a vendor extension layered on a base camera (mostly a flagship
   feature), this settles the question directly with zero visual
   comparison needed. Real expectation stated plainly in the code: unlikely
   on this rugged/budget device, but free to check and definitive if
   positive. Gated on `Build.VERSION.SDK_INT`, wrapped per-id in try/catch
   — can only ever report false/empty on an unsupported device, never
   crash.
2. **`LensProbeScreen`** (`capture_harness/lib/lens_probe_screen.dart`, new
   "Lens Probe (diagnostic)" entry on the harness's mode-chooser screen):
   cycles through every back camera id in turn (reusing `CameraService`,
   the same hardened open/dispose API `front_capture_controller.dart`'s
   secondary-camera capture already relies on), fires one still from each,
   labels it with the real `getCameraLensInfo` characteristics (focal
   length/sensor size/flash — copied verbatim from clearbridge_beta's own
   `MainActivity.kt`), and shows a review grid of all captured stills so
   the CTO can directly compare each against a reference photo taken with
   the stock app's own Macro mode — whichever matches field-of-view/
   close-focus behaviour is the real answer.

**Real bug found and fixed before shipping**: the first draft derived
"all cameras done" purely from `_captured.length >= _backCameras.length`
— skipping (not capturing) the LAST camera in the list would then never
satisfy that condition, permanently stranding the screen on a disposed
camera controller with no button to proceed (the capture-step view's own
loading branch has no escape once `_service.isInitialized` is false and
nothing reopens it). Fixed with an explicit `_finished` flag set on
stepping past the last camera via EITHER path (capture or skip), not
derived from the capture count.

Not yet run on a real device — needs the next harness APK build + a real
walkthrough to actually answer the question this was built for.

## Real root cause of a reported ridge-continuity complaint, found via Cloud Logging, not guessed: one stuck fuse-pair call starves the whole variant loop, letting the weakest candidate win by default (2026-08-19, round 14)
CTO pushed back directly on my own read of a fresh capture (`1cc301a8`,
NFIQ2 59): I'd called the print's density/detail a sign of quality; CTO
correctly identified it as fragmented ridge continuity instead, pointing at
a real prior high-scorer (`1c019820`, NFIQ2 79) as the comparison for what
genuine continuity looks like. Visual re-check confirmed the CTO's read,
not mine — `1c019820`'s ridge strokes run long and continuous around a
clear whorl; `1cc301a8`'s are short, choppy, and frequently break rather
than flow.

**Found the real mechanism, not a guess.** `1cc301a8`'s
`superprintParams` was missing the `afisFreqScale` field entirely — the
tell that its winning candidate was the plain `native` variant
(`_afis_variants = (('native', dict()), ...)`, the only entry that never
passes `freq_normalize`). Checked this across 25 real recent captures:
**23 of 25 won via a `freq_normalize=True` variant; only 2 won via bare
`native`**, and neither of those 2 is among the session's higher scorers.
One of the 23 freqNorm-winners (`628d7803`, NFIQ2 78) has nearly the exact
same wavelength profile as `1cc301a8` (wl=15.0/wlRaw=11.0 vs 15.0/11.0) —
almost a controlled pair, and it scored 19 points higher with the resample
applied. Strong, real evidence `native` losing out to a freqNorm-family
variant is the anomaly, not the norm.

**Pulled the actual Cloud Run logs for this request (not inferred) to see
why `native` won anyway:**
```
17:04:59  AFIS variant native nfiq=59.0
17:05:12  AFIS variant freqNorm nfiq=59.0
17:05:12  freqNorm suppressed by freqNorm false-match guard (needed >= native(59.0)+3.0, got 59.0)
17:05:30  AFIS variant stack nfiq=59.0
17:05:47  AFIS variant focusStack nfiq=59.0
17:06:27  _call_with_hard_deadline: generate did not complete within 40.0s
17:06:27  AFIS variant loop: time budget exceeded, skipping remaining variants from fuseMaxc onward
```
A single flash-pair candidate inside `fuseMaxc` ran the FULL 40-second
per-pair hard-cap (`_FUSE_PAIR_HARD_TIMEOUT_SEC`) before
`_call_with_hard_deadline` gave up on it — and that alone blew past the
loop's overall 70s `_variants_deadline`, skipping every variant after it:
`deepFuse`, `deepMaxc`, `mosaicFreq`, `pyfingHybridFreqNorm`,
`deepAmbBestFl`, and more — several of which are this project's own
historically strongest real scorers. `native` didn't win this capture on
merit; it won because it was the only thing that finished before the
clock ran out. `freqNorm` DID run and tied `native` exactly (59.0 both)
but was correctly withheld by its own real, already-justified false-match
margin (needs +3.0 over native, a deliberate 2026-08-07 guard, not
touched here) — so even the one cheaper freqNorm-family candidate that
did get a chance couldn't win on a tie.

**This is a recurrence of an already-diagnosed failure class, just not
fully closed the first time.** The 40s per-pair cap was added 2026-08-08
specifically to stop one earlier, worse version of this same bug (a
single stuck pair blocking ~144s, threatening the request's own harder
300s Cloud Run ceiling and leaving captures stuck at `status: enhancing`
forever). That fix protects the REQUEST from hanging, but never protected
the other VARIANTS in the same request from being starved — 40s is more
than half of the entire 70s variant-loop budget, so even a single
capped-out pair can crowd out most of the tuple after it.

**Fixed**: `_FUSE_PAIR_HARD_TIMEOUT_SEC` lowered 40.0 → 20.0. Per this
constant's own already-documented real evidence ("every real per-pair
time this session's own logs have shown for a WORKING alignment" is
"single-digit to low-double-digit seconds"), 20s is still a comfortable
2-4x margin above the normal case — it only changes how fast a pair
that's ALREADY struggling gets abandoned, freeing real budget for the
stronger, later candidates in the tuple. Purely a timing change, no
scoring/selection logic touched — can only let MORE variants compete
within the same 70s budget, never fewer.

**Committed, NOT deployed** — this is a `functions/` change and needs its
own explicit deploy go-ahead like every other backend change this
project. Not yet re-confirmed against a real capture that hits the same
stuck-pair condition; the next one that does is what shows whether 20s
actually recovers the lost variants or whether the loop still runs out
before reaching the historically-strongest candidates.

## Follow-on to the scale fix, same round: the wave-cue ceiling was calibrated on the same inflated data, recalibrated off the (bug-immune) real backend numbers instead (2026-08-19, round 13 cont.)
Direct consequence of the `_wavelengthScaleToStill` fix immediately below,
caught before pushing rather than after: `_liveWavelengthCueCeilingPx`
(50.0) was calibrated 2026-08-18 from 3 real `liveWavelengthStillPx`
reads — but that's exactly the live-domain field the scale bug was
inflating 1.25x-2.2x, and 2026-08-18 postdates the 2026-08-14 refactor that
caused it. So 50.0 was very likely calibrated against already-inflated
numbers. Left in place after the scale fix, it would badly
under-differentiate the real, corrected 16-28px range users actually see —
a milder recurrence of the exact "flat plateau" problem this constant was
built to solve in round 11.

Re-derived from the real backend `afisWavelengthPxRaw` measurements instead
(server-side, immune to the live-domain bug): the same 6 recent captures
pulled for the scale fix read 28.0, 15.0, 28.0, 28.0, 26.0, 28.0 (max 28.0).
Applied the same "ceiling sits just under the real observed max" convention
the original 50.0 used (50/54.8 ≈ 0.91x) to this new max: 28.0×0.91 ≈ 25.5,
rounded to **26.0**. Honest caveat, same as round 11's own: n=6, and
backend-domain data is a proxy for what the corrected live domain *should*
now read, not itself a direct live-domain sample — revisit once several
fresh real captures on the scale-fixed build post genuinely reliable
`liveWavelengthStillPx` reads to calibrate against directly. Not yet
device-tested.

## Round-12's own fixes confirmed working on real data — and that check surfaced a bigger, real bug: a 2026-08-14 refactor silently broke the live wavelength estimator's still-domain calibration (2026-08-19, round 13)
Round-12's two fixes (stale `liveWavelengthDebug` snapshot, widened focus-zone
restore-to-centre bound) shipped without a device test. First real capture on
that build (`774f2252`, NFIQ2 63) confirms both are working exactly as
designed: the diagnostic snapshot's `liveAbsSharpness` (27.017) now EXACTLY
matches `focusZoneDebug.restoreCenter.sharpness` (27.017) — direct proof the
re-snapshot fires after the bracket, not before it — and the gap between the
last focus-zone shot and the first main-burst frame shrank from the previous
capture's 21s down to ~2s. This capture's own overall softness (main-burst
Laplacian 11.2-21.4) traces to something else, not a repeat of the round-12
bug: `refocusDebug.maxSharpnessObserved` was already only 28.88 at the very
first hold-lock, before the zone bracket ever ran — this specific attempt had
a poor initial AF lock, a different failure mode than the one round-12 fixed.

**Pulling on that same real capture surfaced a second, more consequential
real bug, unrelated to round-12's own fixes.** Cross-checking the freshly-
accurate post-bracket snapshot against the backend's own real measurement of
the actually-captured frame (`afisWavelengthPxRaw`) found `liveWavelengthStillPx:
60.02` vs. the real backend value **28.0** — a 2.14x inflation, even with the
staleness bug now fixed. Checked whether this was a one-off: pulled every
real front_only_v1 capture with both fields present (6 total, 2026-08-17
through 2026-08-19). 5 of 6 show the same pattern, `liveWavelengthStillPx`
inflated 1.25x-2.2x over the real backend value (774f2252 2.14x, `e50047c7`
2.17x, `4508786f` 1.71x, `1c019820` 1.96x, `f0968af4` 1.25x — one older
capture, `286f1f0a`, predates this session's other fixes and doesn't fit).
**The raw, UN-scaled `liveWavelengthPx` tracks the real backend value far
better on those same 5 captures** (ratios 1.07, 1.09, 0.86, 0.98, 0.90 — mean
0.98, essentially 1:1) — the scaling step itself, not the underlying
estimate, is what's wrong.

**Real, mechanistic root cause, not a guess**: `_wavelengthScaleToStill()`
used to derive a genuine still-vs-preview correction from the ratio between
`_scoreRoi.width` and `_guideRx`, back when those were two INDEPENDENTLY
derived approximations of the guide region (the function's own prior comment
said so explicitly). But the 2026-08-14 fix ("`_scoreRoi` never got the
runtime BoxFit.cover correction") redefined `_scoreRoi` as a getter equal to
`2*_guideRx` by construction — which makes `_guideRx` cancel out of this
OTHER function's formula algebraically: `roiWidthPx = _scoreRoi.width *
image.width = 2*_guideRx*image.width`, so
`(2*_guideRx*_stillDecodeTargetWidth)/roiWidthPx` collapses to a bare
`_stillDecodeTargetWidth/image.width` resolution ratio with zero real
geometric correction left in it — silently, since nobody touched THIS
function when `_scoreRoi` was refactored. This lines up exactly with a real,
already-documented calibration from 2026-08-06 (above `_liveWavelengthTooHighPx`):
back then, the corrected live estimate tracked the real backend value to
within ~1px (21.2 live vs. 20.0/22.0 backend) — a genuinely validated ~1:1
relationship that this silent collapse broke sometime after 2026-08-14
without anyone changing that threshold or re-checking the calibration.
**Very likely a real, direct contributor to "wavelength estimator not
intuitive"/"takes a while to lock" persisting even after the round-12
staleness fix**: an inflated `liveWavelengthStillPx` reads as falsely
too-close, triggering unnecessary `wavelengthTooHigh` gate blocks and a
wave-cue that never visibly settles, regardless of where the thumb actually
is.

**Fixed**: `_wavelengthScaleToStill()` now returns a flat `1.0` instead of
the collapsed resolution-ratio math — per the real data above, the raw
preview-domain estimate is already a good proxy for the backend's
still-domain measurement post the 2026-08-14 refactor, so no further scaling
is warranted. **Honest caveat, stated plainly**: this is an empirical
correction grounded in 5 consistent real data points, not a from-first-
principles re-derivation of the true preview-vs-still relationship — if a
future `_stillDecodeTargetWidth` or preview-resolution change shows real
drift again, re-validate against fresh `afisWavelengthPxRaw` pairs the same
way rather than assuming 1.0 holds forever. `scaleToStill`/`liveWavelengthPx`
stay in `liveWavelengthDebug` specifically so the next real captures keep
this checkable. Not yet device-tested — needs a fresh real capture to
confirm `liveWavelengthStillPx` now tracks `afisWavelengthPxRaw` to within
~1-2px again, the same bar the 2026-08-06 calibration originally set.

## Two real bugs found from a real device-test round: wavelength-diagnostic staleness explains "backward said, forward worked"; focus-zone bracket's own restore-to-center was the softness culprit (2026-08-18, round 12)
CTO reported two issues on the build carrying the recalibrated wave-cue:
"Wavelength estimator is still not intuitive... text said go backwards but
when I brought thumb forward it only locked" and "Focus still has an
issue, the captures were soft." Pulled the real capture (`e50047c7`) and
its full `captureTelemetry` trace for both rather than guess.

**Wavelength "backward said, forward worked": real root cause is a stale
diagnostic snapshot, not a wrong direction or a broken estimator.** Real
timeline: `holdComplete` at 18.3s, but the first real `shotFired` didn't
happen until 39.4s — a 21-second gap (the focus-zone-bracket's own real
cost, see round 8's finding, now confirmed even larger). Critically, the
wavelength estimator kept sampling the WHOLE time during that gap — 110 of
123 real attempts succeeded — but `liveWavelengthDebug` is snapshotted at
`_fireBurst()` ENTRY (hold-complete time), before the bracket runs, so the
value written to Firestore reflects an 21-second-STALE moment, not the
state when the real scored frames actually get captured. This capture's
own numbers prove it: the stale snapshot read `liveWavelengthStillPx:
32.57` (still over the 16.0 gate) with `wavelengthGateExpired: true`, yet
the REAL backend measurement of the actually-captured frame
(`afisWavelengthPxRaw`) came back a healthy **15.0** — i.e. the true
distance was fine by the time the shutter fired, the diagnostic just never
saw it. The most likely real explanation for the CTO's own experience:
the hold finally completing was the 6-second escape hatch's timer expiring
(not a genuine gate-clear), which can land right after ANY movement --
creating a false "that's what fixed it" impression regardless of which
direction was actually corrective.

**Fixed the observability gap**: `snapshotWavelengthDebug()` (extracted
from the existing snapshot code, unchanged) is now called a SECOND time
right after the focus-zone-bracket completes, overwriting the stale
hold-complete-time snapshot with the state that's actually current when
the real burst fires. Diagnostic-only — doesn't change any gate/hold
behavior, just stops misleading the next review of a real capture's data.

**Focus softness: real, distinct bug found in the SAME 21-second window.**
This capture's real Laplacian scores (main burst 36.5-111.1,
`refocusDebug.finalSharpness` 44.2) were measurably below this session's
other captures (90-220+ range) — a real, quantitative match for "the
captures were soft," not just a subjective read. Root cause: after the
focus-zone-bracket retargets AF to 4 different zone points, the final
"restore focus to centre" call — the ACTUAL focus state the real scored
ambient/flash frames get captured at, since it's the last thing that runs
before `_stopStream()` and the main burst — used the SAME short
`_focusZoneMinMs`/`_focusZoneMaxMs` (250-700ms) bound as each individual
zone shot. That bound's own justification ("the lens is already converged
at centre from the hold's own `_refocus()` moments earlier, so retargeting
nearby is a small delta") doesn't hold for the RESTORE call: by then the
lens has moved to 4 different zone targets over 10+ real seconds, so
returning to centre is a real, larger readjustment. It was also never
verified or logged at all.

**Fixed**: widened the restore-to-centre call to the same bound the
original hold-lock's own `_refocus()` uses (`_refocusMinMs`/
`_refocusMaxMs`, 600-1200ms) — the one convergence in the whole bracket
that actually matters for the delivered print, so it deserves at least the
same rigor as the first lock, not the shortest bound in the sequence.
Logged into `focusZoneDebug['restoreCenter']` (previously unobserved) so
the next real capture's data confirms whether this recovers real sharpness.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project; both fixes are diagnosed from real data
but need the next real capture to confirm.

## Distance-wave cue recalibrated off 3 real reliable reads: it was clamping "too close" to a flat plateau, hiding real progress (2026-08-18, round 11)
CTO reported the wavelength gate "takes long to lock even when I follow
instructions" on a real device screenshot showing the new top-of-screen
banner correctly reading "PUSH PRINT BACKWARD" — asked to review, then
took a second capture session specifically so this could be calibrated off
real data rather than guessed.

**Real root cause, confirmed across 3 real captures the same session**:
`liveWavelengthStillPx` posted RELIABLE final reads of **15.18, 47.92, and
54.80px** — real users (well, the one real tester) routinely sitting FAR
beyond the gate threshold (16.0px) for extended periods, not just grazing
it. The wave-cue's own formula clamped `(liveWavelengthStillPx - 11.5) /
(16.0 - 11.5)` to `[0,1]` — meaning 20px and 54.8px rendered IDENTICALLY
(rings maximally "too close" either way). A user genuinely moving in the
right direction while still outside range got zero visual confirmation of
progress until crossing the last few px before the threshold — a direct,
concrete explanation for "feels stuck" even while doing the right thing.

**Fixed by decoupling the cue's visual ceiling from the real gate
threshold** — `_liveWavelengthTooHighPx` (16.0, the value that actually
blocks the hold) is untouched. New `_liveWavelengthCueCeilingPx = 50.0`,
used only as the wave-cue's own scaling denominator, calibrated against
the real observed max (54.8) so the worst real case still reads as ~maxed
while the whole real 16-50px range in between now gets actual
differentiation instead of a flat plateau.

**Honest caveat, same as every other real-data-driven number in this
project**: n=3 real reliable samples (the estimator only started producing
reliable reads reliably enough to calibrate against after this same
round's quadratic-detrend/stripCount=7 fixes) — revisit 50.0 once more
real reliable reads accumulate. Not yet device-tested.

## Focus-zone data now actually incorporated into the delivered superprint — new focusZoneSplice candidate, diagnostic-first (2026-08-17, round 10)
Direct follow-up to the CTO's question "how do we incorporate the
focusZone data into the final superprint since it catches details that
specifically are eroded in the final superprint." Answered first, then
built what was described: NOT cross-zone pixel fusion (already measured
destructive multiple times this project — matchability mosaic, field-
domain fusion, `zone_reduction_test`: a single un-fused zone beat every
fused configuration by 2x+ real bozorth3 separation every time) — a
**hard region-replace with a narrow feathered seam**, justified by a real
structural difference from what already failed: the focus-zone-bracket
shots share the exact same framing as the main frame (only the AF/AE
target moved, the camera never did), so there is no cross-position
registration step and no interpolation-error risk, unlike sweep's own
zones which needed real ECC alignment between genuinely different poses.

**Built (`afis_print.py`)**: `_focus_zone_splice(g8, mask, focus_zones)` —
for each zone with a dedicated still, rasterizes that zone's own sub-guide
region (`_superellipse_mask`, same coordinate convention as
`guide_region`), intersects with the pad's own mask, feathers the
boundary via the same distance-transform technique the module already
uses for the pad/background edge (`_FOCUS_ZONE_FEATHER_PX = 18.0`,
narrower than `_FADE_INSET_PX=25` since this seam sits inside real pad
content on both sides, not at a background boundary), and hard-replaces
that sub-region's pixels — never an average/blend of the whole region.
Runs BEFORE `_normalize`/`_orientation_field`/`_gabor_enhance`, so ridge
orientation is computed once over the whole composite and stays locally
coherent across each seam, instead of gluing together already-binarized
crops (closer to the mosaic's own failure mode). New `enhance=
'focusZoneSplice'` dispatch branch and `focus_zone_frames` parameter on
`generate()`.

**Wired in (`main.py`)** as a new standalone candidate block, run once
after the main variant loop (same point `_focus_zone_frames` is already
downloaded) — not part of the static `_afis_variants` tuple, since it
needs the per-request downloaded zone stills + sub-guide regions that
aren't available until after that tuple is built. Sub-guide formulas
(0.35 offset / 0.70 radius) duplicated from the minutiae-patch block's
own — same accepted "each side keeps its own copy" pattern already used
elsewhere in this pipeline.

**Real, deliberate guard, matching precedent**: genuinely new and
UNVALIDATED against real bozorth3, so it requires beating `native` by
`_FOCUS_ZONE_SPLICE_MARGIN = 5.0` NFIQ2 before it can win production
selection — same precautionary-margin discipline already applied to
`pyfingHybridFreqNorm`/`nnsHybrid` before either had its own real
matchability numbers. Purely additive: can only ever replace
`best_afis_img` with something that scored higher AND cleared the margin,
never regress a capture that doesn't trigger it.

**Not yet deployed, not yet device-tested.** The real next step once
enough real captures with focus-zone data + this candidate exist: a
proper bozorth3 (not NFIQ2 proxy) genuine-vs-impostor gate on
`focusZoneSplice` specifically, the same standard every other candidate
in this pipeline has ultimately been held to — that's what should decide
whether the margin comes down, goes up, or this gets shelved like the
cross-zone fusion techniques before it.

## Distance hint moved to a bold, pulsing top-of-screen banner; real device review of a ridge-continuity print, and its limits (2026-08-17, round 9)
CTO real-device feedback: "the wavelength signal text needs to be displayed
on top of the screen in bold and it needs to pulse, can't see it at the
bottom. just direct text 'Bring Print Closer'... 'Push Print Backward'" —
plus asked to see the latest superprint to judge whether the round-7/8
ridge-continuity work (quadratic detrend, focus-zone bracket) actually
improved it.

**UI fix, direct implementation of the ask.** The `distanceHint`-driven text
("Move phone CLOSER"/"Move phone BACK") used to render as a small row at
the very bottom of the screen, alongside the CTA button — same class of
"easy to miss while looking at the guide" problem the brightness warning
pill was already built to fix on 2026-08-06, just never applied to this
signal. Split it out of the bottom `_WarningRow` (which now only ever shows
the lighting/focus low-quality case) into a new top-of-screen
`_DistanceBanner`: bold (`FontWeight.w900`, 20px, uppercase), gold-bordered
pill, positioned just below the header row so it's the first thing in the
user's eyeline. Pulses via its own dedicated `AnimationController`
(`_distancePulseCtrl`, 700ms opacity tween 1.0->0.35, same pattern already
proven for the brightness pill's `_blinkCtrl` but kept independent since
brightness and distance warnings can in principle both be true
simultaneously and need independent pulse phases). Copy is exactly the
CTO's own wording: `distanceHint == 'Move closer' ? 'Bring Print Closer' :
'Push Print Backward'` — the only two non-null values `rawOnTarget` ever
produces (coverage-driven "too far" vs. either coverage- or
wavelength-gate-driven "too close", which already share one string).
Committed, not device-tested.

**Superprint review: honest read, with the real limiting caveat stated
plainly rather than oversold either way.** Pulled the latest real capture
(`286f1f0a`, NFIQ2 63) and sent the superprint for direct visual review.
It reads coarser/more fragmented than some earlier prints this session —
but this is very likely a **direct, expected consequence of physical
distance, not a ridge-continuity regression**: this is the exact capture
the round-8 wavelength escape hatch rescued, raw wavelength **26px**, well
above the established 9-14px sweet spot. Cross-checked against `80a994ca`
(also raw wavelength 28px, different finger, NFIQ2 74) which visually
reads notably cleaner despite an almost identical raw wavelength number —
underscoring that a single cross-subject visual comparison like this isn't
a controlled test; different real fingers look different regardless of
pipeline quality, the same "don't over-index on one comparison" discipline
this project applies everywhere else.

**The more important, structural finding: no capture so far COULD show the
focus-zone fix's real effect, by design.** `minutiaeDebug` confirms the
dedicated tip/base/left/right stills are captured and scored correctly
(`source: focusZone`) — but per the existing 2026-08-17-earlier-round
policy, minutiae patches (focus-zone-sourced or not) stay strictly
diagnostic-only and can never win production selection over the full-print
candidate, specifically to prevent a partial-pad crop from silently
replacing the real print (the exact real bug fixed earlier this session).
So every superprint delivered today, including this one, is still built
the same way it always was — the plain single best full frame — regardless
of whether the focus-zone bracket ran. The mechanism works; it just isn't
connected to the real output yet. **Real next step, not yet built**: a
proper bozorth3 (not NFIQ2 proxy) matchability test on the focus-zone data
now that it exists in real Firestore docs, to decide whether/how it should
ever be allowed to influence the delivered print — the same "verify with
real matchability before touching production selection" discipline as
every other candidate-selection decision in this pipeline.

## Real device confirmation the wavelength/focus-zone fixes work — and two real, distinct causes of "sweeps forever" found + fixed (2026-08-17, round 8)
CTO ran the build carrying the quadratic-detrend/stripCount=7/focus-zone-
bracket changes: "struggled with the wavelength estimator for awhile, it
seems I only have one shot to get correct distance or it sweeps forever...
but I managed 1 capture where it was working as proposed." Pulled the real
capture (`80a994ca`, real NFIQ2 74) and its full `captureTelemetry` trace
rather than guess at what "sweeps forever" meant.

**Good news first, confirmed with real numbers: both of the previous
round's mechanism fixes are real and working.** `stripsCleared` read 7/7 on
every single one of 69 real throttled attempts (was 5/5 before the
stripCount bump). `stripsWithPeak` regularly reached 4-6 (not just barely
scraping the required 2) — the quadratic detrend is genuinely finding more
peaks per strip, not just marginally clearing the bar. **11 of 69 attempts
(16%) succeeded** — a real, large jump from the historical near-zero
qualify rate. The focus-zone-bracket also worked end-to-end for the first
time ever: `focusZoneShots` has all 4 zones, and `minutiaeDebug` confirms
the backend correctly sourced tip/base/left/right from the dedicated
focus-zone stills (`"source": "focusZone"`) instead of the center-focused
crop.

**But the real telemetry timeline exposed two distinct, real problems, not
one — both now fixed:**

**Problem 1: the wavelengthTooHigh gate has no bounded escape.** Real
timeline: `refocusLocked` at 12.8s, `holdComplete` at 14.3s — meaning it
took ~14 real seconds of struggle before every gate (focus, coverage,
wavelength, steady) was satisfied simultaneously long enough to complete
the hold. Read `rawOnTarget`'s own code to confirm why: unlike
`tooFar`/`tooClose` (which have an obvious physical correction via the
on-screen guide's size, and which the reset logic already treats as a
genuine "thumb left"), a hold blocked SOLELY by `wavelengthTooHigh` had NO
bounded fallback at all — it just stayed blocked indefinitely until the
user happened to land within `_liveWavelengthTooHighPx` by feel, with only
a text hint and the wave rings to go on. This was low-risk to ship
2026-08-14 because the estimator rarely had enough real samples to ever
actually assert `wavelengthTooHigh=true` (the long-documented
`sampleCount:0` problem) — now that this SAME round's quadratic-detrend/
stripCount fixes made it genuinely reliable, this latent gap became
reachable in practice for the first time, and this real capture is direct
evidence of it.

**Fixed**: new bounded escape hatch (`_wavelengthOnlyBlockedSince`,
`_wavelengthOnlyBlockMaxMs = 6000`) — tracks how long the hold has been
blocked solely by `wavelengthTooHigh` (every other gate already
satisfied); once sustained past 6s, the hold is allowed to proceed anyway
rather than trapping the user. Same principle sweep's own live-wavelength
gate already uses (2026-08-13/14, bounded 3s there) — 6s chosen more
generously here since front's hold has no separate "waiting room"
sub-phase telegraphing the wait the way sweep's calibration step does.
Whether this escape hatch fires is now written to `liveWavelengthDebug`
(`wavelengthGateExpired`) so the next real capture shows if 6s is well-
calibrated, too short, or rarely even needed now that the underlying
estimator works better.

**Problem 2, independently real and very possibly the bigger contributor
to "sweeps forever": the focus-zone-bracket's true cost is much higher
than documented, with zero UI feedback during it.** Real telemetry: hold
completed at 14.3s, but the first main-burst `shotFired` didn't happen
until 32.1s — an 18-SECOND gap. `focusZoneDebug`'s own `convergedMs`
values (1980/1274/1382/4304ms, summing to ~8.9s across 4 zones) confirm
why: the "250-700ms per zone" cost documented when this feature shipped
only ever described the intended POLL bound inside `_retargetAndConverge`
— it never accounted for the real camera API round-trip latency
(`setFocusMode`/`setFocusPoint`/`setExposurePoint`, each individually
allowed up to 3s via `_zoneFocusCallTimeout`), which this real data shows
dominates the actual cost. Add 4 real shutter presses on top of that and
the true per-capture cost of this feature is ~15-18s, not the "meaningfully
lengthening capture time" the original ship note undersold it as. Worse:
`_fireBurst()` sets `phase: capturing, burstProgress: 0` at entry and
never updates either during the focus-zone-bracket loop (which runs BEFORE
the main burst) — so for that whole 15-18s window the UI showed a frozen
progress state with no confirmation text at all, reading exactly like a
hang regardless of what the wavelength gate was doing.

**Fixed**: `_captureFocusZoneShots()` now sets `confirmationText:
'Capturing extra detail…'` before starting the zone loop — same "silent
gap reads as a freeze" fix already proven once elsewhere in this file
(2026-07-23, the burst-end decode/encode lag), applied to a new location.
Deliberately did NOT touch `burstProgress` during this phase (would need
to interact with the main burst's own progress calc afterward in a way
that risks looking like it jumps backward) — the text banner alone is the
low-risk fix for "looks stuck."

**Honest, undecided real product question, not resolved this round**: is
an 18-second real cost (on top of whatever time the hold itself takes)
worth the focus-zone-bracket's real per-zone matchability gain that
motivated building it? Not re-litigated here — the CTO explicitly
authorized turning it on for its first real test, and it worked correctly.
Worth an explicit product call once more real captures confirm whether the
`minutiaeDebug` proxy-score gains from `source: focusZone` translate to
real bozorth3 matchability gains (the actual thing this whole feature was
built to chase), weighed against 15-18s of added real capture time.

## Wavelength estimator: quadratic detrend (real debug fix, not another parameter nudge); focus-zone bracket extended to left/right and turned ON (2026-08-17, round 7)
CTO reviewed the `eacb0b2c` superprint (sent for review) and gave two direct
instructions: build the focus-zone-bracket extension to left/right and turn
it on (per the earlier recommendation), and — separately, more pointedly —
"debug 2. because the wavelength estimator is not working as it should",
pushing back on treating the `stripCount` bump alone as sufficient.

**Focus-zone bracket: extended + enabled.** `_focusZoneBracketZones` now
`['tip', 'base', 'left', 'right']`, `_focusZoneBracketEnabled = true`.
`_focusPointForZone` gained `left`/`right` cases (`cx -/+ rx*0.35`, same
0.35 offset convention already used for tip/base and already matching
`main.py`'s own minutiae sub-guide formulas). Corrected an assumption in
the original (still-present) comment block above the flag: it argued
left/right don't need dedicated focus since they "sit at the same vertical
distance as centre" — but the real bozorth3 per-zone comparison this whole
feature is built from actually found 'right' as one of the two STRONGEST
real gains from a dedicated zone shot (core +40%, right +34%), not a zone
that could skip it. Backend needed zero changes — `main.py`'s minutiae-
patch loop already checks `_focus_zone_frames.get(_pname)` generically for
every patch name, so `left`/`right` zone stills are picked up automatically.
**Real, deliberate cost, stated plainly**: this now fires 4 extra dedicated
stills (up from 2) before the main burst — each a retarget+converge
(250-700ms) + a real shutter press — meaningfully lengthening capture time.
Turned on before its own first device test, on explicit CTO instruction —
a deliberate exception to this project's usual "ship off, validate one
device round before enabling" sequencing, not a change to that discipline
generally.

**Wavelength estimator: real debug pass, found a genuine mechanism gap, not
just another number to guess.** Re-read `estimateRidgeWavelengthPx` end to
end looking for an actual bug rather than another threshold tweak. Real
candidate found in the detrending step: the code mean-centers each strip's
signal then removes only a LINEAR trend before autocorrelating, explicitly
to "suppress torch-gradient trends" (the function's own comment) — but the
torch is a near-point source, so its brightness falloff across a strip is
genuinely closer to quadratic (radial, centred wherever the torch's own
falloff peaks) than linear. A linear fit only removes the strip's AVERAGE
slope and leaves the residual curvature in place — worst for strips that
sit off to one side of the ROI, which is consistent with the real telemetry
pattern already found (`stripsWithPeak` landing at 1 of the 2 needed on
strips that had already cleared the contrast bar, meaning real periodic
content was present but the peak search still came up short).

**Fixed, not just re-diagnosed**: upgraded to a proper quadratic (least-
squares, 3x3 normal-equations solve via Cramer's rule) detrend. Strictly
generalises the existing linear detrend (a linear trend is just the
degenerate c=0 case), so it can only detrend at least as well as before on
strips that were already fine — it cannot regress a strip that already
found its peak. **Verified the closed-form solve numerically before
trusting it in a live-camera code path**: reproduced the exact same Cramer's-
rule arithmetic in Python against 5 random synthetic quadratic+noise
signals and compared to `numpy.polyfit` — matched to within floating-point
precision (~1e-12) on every trial, not just eyeballed.

**Honest framing, same as the stripCount change**: this is a real,
physically-motivated mechanism fix, not a guessed magic number — but it's
still unconfirmed against real device data. The next real capture's
`stripsWithPeak` distribution (now on top of the also-real stripCount=7
change from the previous round) is what actually shows whether this closes
the gap, same "let the next capture answer it" discipline as every other
change in this thread.

## First real capture with `stripsWithPeak` data: the wavelength estimator genuinely works, it's borderline-short by exactly one strip (2026-08-17, round 6)
First real capture on the build carrying the `stripsWithPeak` diagnostic
(`eacb0b2c`, confirmed via the field's presence in telemetry — the previous
sunlight capture predates it). This is the real answer the diagnostic was
built to give.

**Real, decisive finding: strips ARE finding peaks — this is not the
structural live-preview-domain dead end it could have been.** Across 8
throttled attempts: `stripsWithPeak` read 0 (x2), 1 (x5), 2 (x2) — and the
two attempts that hit 2 are exactly the two that succeeded
(`success: true`, `liveWavelengthDebug.sampleCount` reached 1 by the end of
the hold). The estimator's own >=2-strips-must-agree bar
(`lags.length < 2 -> null` in `estimateRidgeWavelengthPx`) is being missed
by exactly one strip on the majority of attempts — a genuinely borderline
shortfall, not a "zero signal at all" wall. Also got the first real
`scaleToStill` value from an actual successful live sample (2.0), confirming
the live-preview-to-still-domain scale relationship is real and computable,
not just theoretical.

**Fixed with a sample-density change, not a threshold guess.** Raised the
live call's `stripCount` 5 -> 7 (`front_capture_controller.dart`, shared
function's default stays 5 for other callers, same override pattern already
used for `minStripStd`). Deliberately NOT a guess at `minLagPx`/
`maxLagRawPx`/lowering the 2-strip agreement bar itself — those would each
either weaken the actual robustness check or require picking a new number
with no real basis. Sampling more independent strip positions per attempt
raises the odds of hitting the SAME unweakened bar without touching what
"reliable" means. Structurally low-risk even off n=1: worst case is a
modest extra per-attempt CPU cost (still bounded, still throttled), it
cannot make an already-working attempt fail.

**Honest caveat, stated plainly**: this is one real capture with the new
diagnostic. The stripCount bump is justified by the shape of the evidence
(consistently short by exactly one, never by more), not by enough real
samples to prove 7 is the right number — the next real capture's
`stripsWithPeak` distribution is what actually confirms this moved the
needle, same "let the next capture answer it" discipline as the diagnostic
itself.

**Also confirmed on this second real capture**: crease-trim fired again
(`afisCreaseTrimPx: 39159`), `refocusDebug` converged cleanly with no drift
retry needed (real NFIQ2 66, `afisMask: guide+unet` — the content-aware
mask engaged this time, unlike the previous sunlight capture which fell
back to bare `guide`).

## Real sunlight device test: no repeat of the transillumination failure, crease-trim confirmed live, and a genuinely new wavelength-estimator lead (2026-08-17, round 5)
CTO ran one real capture deliberately in sunlight to stress-test the already-
deployed crease-trim/vignette work. Pulled the real capture (`181e8cd8`,
single-capture session) directly rather than assume anything from "it was
done in sunlight" alone.

**Good news: no repeat of the earlier sunlight failure.** Real NFIQ2 **70**.
Frames show ISO 50-53, shutter 1/821-1/1642 (genuinely bright scene, HAL
compensating hard) but none of the near-zero-contrast red-transillumination
signature from the earlier catastrophic sunlight capture (NFIQ2 6-8). Also
the first real device confirmation the deployed crease-trim fired on a real
capture: `superprintParams.afisCreaseTrimPx: 17190`.

**Caveat stated plainly**: this capture predates the wavelength-reset-
debounce / focus-drift-retry / permission-race fixes pushed+deployed earlier
this same round — those need a fresh APK build+install before they can be
judged from real data. `refocusDebug` on this capture looked healthy on its
own terms (converged, no drift retry needed), but that doesn't confirm or
refute the drift-retry logic specifically since it never had cause to fire.

**Real, newly-precise finding on the wavelength estimator, from the
telemetry system built specifically for this.** All 8 live attempts on this
capture show **5/5 strips clearing the contrast bar** (`stripsCleared: 5`,
`maxStripStd` 34-47 vs. the live `minStripStd=3.0` floor) yet every attempt
still failed (`success: false`). Checked two older non-sunlight captures
(`5363a49b`, `4ae6d13c`) and found the identical signature — so this is very
likely the GENERAL bottleneck behind the long-standing sampleCount:0
problem, not something sunlight-specific. Read `estimateRidgeWavelengthPx`'s
own code to find exactly where: it needs >=2 strips to each find a real
autocorrelation local maximum (`peakLags` non-empty) before it will return a
result (`lags.length < 2 -> null`) — a strip can clear the CONTRAST bar and
still contribute nothing if its autocorrelation never produces a clean local
max within the search window. The existing diagnostics (`stripsAttempted`/
`stripsClearedStd`/`maxStripStd`) couldn't distinguish "0 strips found any
peak at all" (a structural live-preview-domain limit no threshold tuning
would fix) from "exactly 1 strip found a peak, needed 2" (a genuinely
threshold-adjacent case) — both looked identical from outside.

**Fixed the visibility gap, not the number** — per this project's own
standing discipline, did not guess at `minLagPx`/`maxLagRawPx` values
without evidence to justify a specific new number (checked whether the true
live-preview ridge period was suspiciously close to `minLagPx=2` via
`_wavelengthScaleToStill`'s own scale math, but couldn't derive a confident
raw-px estimate without a real device's actual live preview resolution to
hand). New `RidgeWavelengthAttemptDebug.stripsWithPeak`
(`frame_capture_service.dart`) — incremented exactly when a strip's
autocorrelation search succeeds, so it equals `lags.length` at the point the
function returns. Wired into the `wavelengthAttempt` telemetry event
(`front_capture_controller.dart`) as `stripsWithPeak`. The next real capture
will show, for the first time, whether strips are finding zero peaks (points
at a live-preview resolution/ISP-denoising ceiling — no code fix available)
or one (points at `minLagPx`/`maxLagRawPx` being the real lever) — turning
the next round into a real, evidence-based fix instead of another guess.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project; this is a pure diagnostic addition with
zero behavior change, so it's safe to ship regardless, but the actual
answer it's built to reveal needs a real capture on the built APK.

## Per-zone focus-bracket capture built: the real lever the zone comparison pointed at, front_only_v1-only, feature-flagged off (2026-08-17, round 4)
Direct follow-up to the per-zone matchability comparison below. CTO asked how
the "per-zone refocus/re-shoot" lever I proposed as the actionable takeaway
would actually work for front_only_v1, then said "Yes build B, but keep A in
memory, I would actually like a hybrid of the 2 options... let's start with
B" — B being "focus-bracket the shot: fire one extra dedicated still per
weak zone, retarget AF to that zone specifically, then let the BACKEND select
per-region instead of trusting one center-focused frame for everything", vs.
A ("just nudge the existing single AF point off-center toward the weak
zones"). **What actually got built is honestly already the hybrid, not pure
B** — worth stating plainly since I never answered the "what would a hybrid
look like" question directly before building: this codebase has no manual
lens-distance control exposed (`setFocusPoint`/`setFocusMode` only, confirmed
via `camera_service.dart` — Camera2Interop manual `LENS_FOCUS_DISTANCE` was
never built, per the standing `docs/LOCKED_SHUTTER_SPEED_SCOPE.md` finding
that only manual EXPOSURE has ever been probed), so "bracket focus distance"
is only achievable in practice by retargeting the AF POINT (mechanism A) and
letting the platform's own AF algorithm re-converge at whatever distance that
region needs — then treating each resulting frame as its own independently-
selectable per-region candidate (philosophy B, never fused/averaged across
positions, per this project's own hard-won zone-fusion-destroys-matchability
finding). One mechanism, both ideas' benefits: A's buildability + B's
backend-selection safety.

**Client (`front_capture_controller.dart`)**: new `_focusZoneBracketEnabled`
flag (`false`), `_focusZoneBracketZones = ['tip', 'base']` — chosen because
those are exactly the two zones `main.py`'s minutiae-patch block already
crops as sub-guides of the single center-focused main frame but has never
had its own dedicated focus for (core/left/right already get reasonable
coverage from the center focus point; tip/base sit at the guide's own
vertical extremes, farthest from center). When on, `_fireBurst()` calls the
new `_captureFocusZoneShots()` right before `_stopStream()` (round 1 only —
can't double up with the also-off `_secondBurstEnabled`), which for each
zone: retargets `setFocusPoint`/`setExposurePoint` to that zone's own
position within `PadSilhouetteShape.defaultShape` (`_focusPointForZone`),
polls the same self-relative peak/streak convergence signal `_refocus()`
already uses (`_retargetAndConverge`, bounded 250-700ms), fires a real
`takePicture()` tagged with a new `_RawShot.focusZone` field, then restores
AF to the guide's own centre before the main alternating ambient/flash burst
proceeds exactly as before. `_finishAndUpload()` splits these tagged shots
out of the main burst BEFORE the existing ambient/flash decode loop (so they
can never get miscounted into `front_burst_${type}_$idx` numbering), uploads
each under its own `front_focuszone_$zone.jpg` path, and writes a separate
`focusZoneShots`/`focusZoneDebug` Firestore field — same additive, own-field
pattern `_secondBurstEnabled`'s `frames2` already established. Also checks
`secondBurstShots` for the same tag (covers the combination where both flags
are on, even though neither is by default).

**Backend (`main.py`)**: new `_download_front_only_focus_zone_frames()`
(self-skips to `{}` when `focusZoneShots` is absent, i.e. every capture
today), downloaded once per request alongside the existing burst2 download.
The minutiae-patch loop's `tip`/`base` candidates now check
`_focus_zone_frames.get(_pname)` first: if a dedicated zone still exists,
that sub-guide crops from the ZONE-FOCUSED frame instead of the single
center-focused main frame every other patch still uses (guide coordinates
stay valid unchanged — the camera never moved/zoomed, only the AF target
did). Purely additive to an already-diagnostic-only block (minutiae patches
were fixed 2026-08-17 earlier this session to never win the real superprint
outright — see below) — this can only change what the tip/base diagnostic
candidates' OWN score is, never let a partial-pad patch back into
production selection.

**Not yet device-tested, both flags stay off** — same standing discipline
as every other capture-side change this project. The real next check once a
device test lands: does `focusZoneDebug`'s `convergedMs`/`sharpness` per
zone show the AF point actually re-converging distinctly for tip vs. base
(not just re-locking on the same spot), and does `minutiaeDebug.tip/base`'s
`proxyScore` improve with `source: 'focusZone'` vs. the historical
center-focused-crop baseline on the same real captures.

## Per-zone, per-architecture real matchability comparison: sweep's dedicated zone shots beat front's sub-crops on core/right, tied on left (2026-08-17)
CTO sent a real print with green (strong, well-defined core/whorl) vs.
yellow (distorted above/below) hand-annotated, and asked which capture
architecture produces the best ridge quality per anatomical segment —
explicitly correcting the approach up front: use real matchability
(bozorth3), not NFIQ2, since NFIQ2 only estimates "looks print-like",
not whether it's coherent with the real underlying finger.

**Built a real, purely diagnostic comparison — no fusion, per this
project's own hard-won lesson that combining zones destroys matchability
(see the "zone reduction + field-domain fusion" and "matchability mosaic"
entries).** Found 9 real users in Firestore with >=2 real captures that
each carry real `sweepBurstDebug` zone data (22 captures, 17 genuine
pairs total). For each capture: rendered FRONT-architecture zones (core/
tip/base/left/right) as sub-crops of the capture's own single main-burst
frame, using the exact same sub-guide formulas `main.py`'s minutiae-patch
candidates already use; rendered SWEEP-architecture zones from each
zone's own dedicated captured still + dedicated guide region (no
sub-cropping — a real, separate shot per zone). Scored every genuine
(same-user, cross-capture) pair, same-zone-same-architecture, via real
`mindtct -m1` + `bozorth3` — never NFIQ2.

**Real result (17 genuine pairs, `scratchpad/zone_arch_compare`):**

| zone | front mean (n) | sweep mean (n) |
|---|---|---|
| core | 16.76 (17) | **23.53** (17) |
| tip | 17.82 (17) | 21.00 (3 -- thin) |
| base | 17.94 (17) | 20.50 (4 -- thin) |
| left | 19.47 (17) | 19.82 (17) — tied |
| right | 19.00 (17) | **25.53** (17) |

Sweep's dedicated zone shots beat front's own sub-crops on core (+40%
relative) and right (+34%), tied on left, and showed the same direction
on tip/base but those two only had 2 of 9 users with real 5-zone data
(n=3-4, not trustworthy on their own). Medians moved the same direction
as means throughout, so this isn't an outlier-driven artifact.

**Real, honest interpretation, not just "sweep wins": the likely mechanism
is a fresh shot beats a crop, not sweep's multi-position protocol
specifically.** Visually confirmed (sent to CTO) on one real pair: sweep's
`right` zone is a genuinely different capture geometry (its own framing/
angle), not just the same content cropped tighter, and shows visibly
cleaner ridge continuity than front's simple rectangular sub-crop of the
same fixed frame. This is the plausible real driver — a dedicated,
independently-focused/exposed capture of a specific region beats a
sub-crop of one general-purpose frame — which is a genuinely different,
more actionable finding than "switch to sweep": it points at *per-zone
re-focus/re-shoot within a single architecture* as the real lever, not
sweep's discontinued multi-position capture flow specifically (matches
the CTO's own scope decision to keep front_only_v1 as the sole active
architecture).

**Not acted on yet — diagnostic only**, per the explicit ask. Real next
step this points at, not built: test whether front_only_v1's own already-
built redundant-second-burst mechanism (currently feature-flagged off),
or a new per-zone refocus pass within a single front_only_v1 capture,
recovers some of this real gap without reintroducing the fusion/mosaic
failure mode already closed out.

## Three real bugs found from a real device-test round: wavelength-reset over-firing, focus-drift-onto-background, first-launch camera permission race (2026-08-17)
CTO ran 2 real capture sessions plus hit a real error on the very first app
open, reporting three things: focus locked onto the background and came out
soft in session 1; the wavelength estimator still never locks no matter
where the thumb is placed; and a `CameraException(CameraPermissionsRequestOngoing,
...)` error on first launch, before either capture.

**Wavelength estimator: real root cause found via the telemetry system
built specifically for this.** Pulled the real `wavelengthAttempt` events
for both sessions -- and the per-attempt fix from earlier today IS working
(one real hold had 9 CONSECUTIVE successful attempts; 30/156 succeeded
overall on the second capture) -- but the session's final `sampleCount`
still landed at 0 both times. Root cause: the per-hold reset
(`front_capture_controller.dart`, the "thumb genuinely left" trigger) fired
on the very FIRST single frame where coverage blipped past tooFar/tooClose
-- ordinary hand tremor during a multi-second hold does this routinely --
wiping the accumulated sample count before it ever reached
`_liveWavelengthMinSamples`, over and over, even though individual
attempts were succeeding fine. **Fixed**: debounced the reset with a
`_wavelengthOutOfRangeSince` timestamp -- only treated as a genuine "thumb
left" once out-of-range has been sustained for 500ms, not a single noisy
frame. `_refocusedThisHold`'s own reset is deliberately NOT debounced the
same way (already real-device-tuned for AF-hunting risk, 2026-08-14 --
not this fix's job to touch).

**Focus locking onto the background: real, self-relative fix, not a fixed
threshold.** Real Firestore data across 18 recent captures confirmed the
reported capture's `refocusDebug.finalSharpness` (29.85) was the lowest of
the set by a real margin, and its own `nfiq2Score` (52) was also the
lowest -- but the same data also showed a genuinely GOOD capture
(nfiq2=81) with a similarly low finalSharpness (35.5), ruling out a fixed
absolute floor (this live, uncalibrated Laplacian signal varies too much
with distance/lighting for one global number to be trustworthy across
different captures). `_refocus()`'s convergence check only ever asked "has
the reading stopped changing" -- a lens settled on the background behind
the thumb converges (stops changing) just as confidently as one settled on
the thumb itself. **Fixed, self-relative instead**: track the PEAK
sharpness seen during the poll; if the value it converges to is well below
that peak (< 60%), that's evidence the lens swept past a genuinely better
focus point before drifting onto something worse, and it gets exactly ONE
extra `_beginAutofocus()` retry (bounded -- can't loop indefinitely, the
second attempt's result is always accepted regardless). New diagnostics
(`maxSharpnessObserved`, `driftRetried`) on `refocusDebug` and the
`refocusLocked` telemetry event so the next real capture shows whether
this actually fires and helps.

**First-launch camera permission crash: real re-entrancy bug in
`CameraService`, fixed at the shared choke point.** `CameraService`
already tracked a `_pendingInitialization` field but never actually
checked it on entry to `initializeCamera()` -- a second concurrent call on
the same instance would silently overwrite the field and start its own
independent `CameraController(...).initialize()`, racing the first call's
own Android runtime permission request (`CameraPermissionsRequestOngoing`
is exactly what that race throws). Can only ever matter on the very first
launch, before permission is granted -- once granted, `initialize()` never
needs to prompt again, matching "only happened the first time I opened the
app." Root-caused which SPECIFIC second call was responsible was not
achievable from static code review alone (no device logs with a full stack
trace available) -- fixed at the correct choke point regardless: a second
concurrent `initializeCamera()` call on the same `CameraService` instance
now awaits the first call's own in-flight result instead of starting an
independent one, closing the race no matter which caller fires second.

**Not yet re-tested on a real device** -- same standing discipline as
every other capture-side change this project; all three fixes are
diagnosed from real data (Firestore + the new telemetry system) but need
the next real capture round to confirm.

## Crease trim recalibrated against direct CTO ground truth; circular scanner-style vignette added (2026-08-17, round 3)
CTO sent back a real generated print (the one from the previous entry) with
the residual crease band hand-marked yellow: "remove the yellow highlighted
section as well, it is clearly crease" -- plus a second, separate ask: "have
the feathing be circular so it mimics real fingerprint scanner prints."

**Crease trim recalibrated using the CTO's own annotation as ground
truth, not another guess.** Measured the real row-wise circular-variance
profile of the exact flagged print (`scratchpad/ps/deltacheck`): the true
tail crease (frac 0.82-1.0 of the mask's span) turned out to be separated
from the genuine core peak (frac ~0.50-0.55) by only a shallow dip then a
SECOND, narrower high-variance bump (frac 0.73-0.80) -- the original
threshold (0.30, raw per-row) read that second bump as real ridge
structure and left it untouched, which is exactly the residual band the
CTO marked. Fixed two ways together: (1) smoothed the per-row circular-
variance profile (21px box window) before thresholding, so a narrow bump
can't hide real crease just past it; (2) raised the threshold 0.30 -> 0.40
on that smoothed profile, which crosses the dip BEFORE the second bump
instead of after it -- confirmed via a full offline sweep
(threshold x smoothing-window x run-length) against the real cached
binarized print, not picked blind. Real, deliberate trade-off, stated
plainly in the code: more aggressive, costs more real area, accepted
because a visible crease is the worse failure mode per direct instruction.

**Circular/elliptical vignette added** (`_circular_vignette`, new
`circular_vignette: bool = True` param on `generate()`): fits an ellipse
to the (crease-trimmed) mask's own centroid + extent, then fades the print
to white with a smooth radial falloff, on top of the existing organic
mask-shaped feather rather than replacing it. Direct, real side benefit:
this also fixed the "known cosmetic gap" flagged in the previous round
(the crease-trim boundary was a hard cut, unlike the print's other,
naturally-feathered edges) -- the vignette smooths over it for free.

**Re-validated on the same 2 real cached captures, real numbers improved,
not just held steady**: real NFIQ2 `01662ffb` 70 (original) -> 66 (round-2
trim) -> **77** (this round); `474b4d6a` 77 -> 75 -> **79**. Both now score
*above* their original untrimmed baseline, not just "acceptably lower" --
removing the genuinely messy crease content plus softening the edges via
the vignette reads as cleaner, more consistent ridge structure to NFIQ2,
not just a smaller print. Visually confirmed (sent to CTO) the residual
band from the annotated screenshot is gone on the same real capture.

**Not yet deployed** — needs its own explicit deploy go-ahead like every
other backend change, same as the round-2 crease-trim commit it amends.

## Backend-side crease exclusion built: real ridge-curvature mask trim, found and fixed a real axis bug along the way (2026-08-17)
Direct follow-up to the CTO's "pad isolation needs to be a backend
configuration" direction (previous entry). Built `_trim_base_crease()`
(`afis_print.py`): trims print area toward the guide's BASE half only
wherever local ridge orientation is too uniform across a row to plausibly
be real pad structure — a flexion crease is characteristically near-
straight parallel lines, while true whorl/loop/arch ridge flow has real
local curvature. Measures this via row-wise CIRCULAR variance of
`_orientation_field`'s own ridge-direction estimate (1 - resultant-vector-
length of the doubled angles), scanning from the mask's own vertical centre
toward its base for the first sufficiently-long run of low-variance rows.
Wired into `generate()` as `crease_trim: bool = True` — applies universally
to every guide-region-based candidate (front burst, minutiae patches, sweep
zones, secondary cameras), matching the "backend config, not capture
geometry" framing directly.

**Real, non-trivial bug found and fixed during validation, not shipped
blind.** First implementation trimmed based on `guide_region`'s own
`cy`/`ry` keys, applied BEFORE the pipeline's upright rotation — reasoned
to be correct, but a visual overlay of the actual mask boundary directly on
a real raw capture (`scratchpad/ps/deltacheck/raw_with_trim_overlay_zoom.png`)
showed the trim cutting a vertical strip on one SIDE of the final image,
not a horizontal band at the bottom. Root cause: `_stillSpaceRegionForShape`'s
own `(u,v)->(1-v,u)` rotation means `guide_region`'s `cy`/`ry` keys do NOT
correspond to the pre-rotation image's row axis — they're already rotated
90° from the on-screen shape's own tip/base axis. Fixed by moving the trim
to run AFTER `_upright_from_tip`/`_upright_rotate` instead, on the
already-rotated `binimg`/`mask` — the one point in this pipeline with a
*guaranteed* row-axis contract ("larger row = base"), sidestepping the
whole class of pre-rotation axis confusion rather than re-deriving it by
hand. Same rotation-bug class already documented multiple times elsewhere
in this project (`_scoreRoi`, `_focusPointScreenSpace`, the original
BoxFit.cover guideRegion bug) — this file's own standing lesson held again.

**Validated locally against 2 real cached front_only_v1 captures**
(`01662ffb`, `474b4d6a` — raw bursts + guide_region pulled from Storage/
Firestore, full `generate()` run, real calibrated NFIQ2 binary):
- Visually confirmed (post-fix) the trim removes a horizontal band from
  the BOTTOM of the upright print, not a side strip — matches the CTO's
  own photo (crease is below the pad, not beside it).
- `01662ffb` (full, un-shrunk guide): trimmed 28,908px off the base;
  real NFIQ2 70 -> 66 (-4).
- `474b4d6a` (captured on the now-reverted shrunk guide, so less crease
  was present to begin with): trimmed only 4,630px; real NFIQ2 77 -> 75
  (-2).
- Both real, small NFIQ2 *decreases* — expected and consistent with this
  project's own established finding that NFIQ2 and real matchability are
  different axes: removing non-ridge crease content costs a little
  quality-proxy score (less total area) while the content removed was
  never real fingerprint signal, so it should be a net real-matchability
  positive, not something the NFIQ2 dip alone should be read as a
  regression.

**Known, accepted cosmetic gap, not fixed this round**: the new trim
boundary is a hard cut (matches the mask exactly), unlike the print's
other edges, which fade via the existing `_FADE_INSET_PX`/`_FEATHER_SIGMA`
distance-transform feather. Visually minor in the validated samples: a
real follow-up if it looks wrong on a real device capture, not blocking
this shipping.

**Not yet deployed** — needs its own explicit deploy go-ahead like every
other backend change. `crease_trim` defaults `True` (so it's live the
moment this deploys, on every guide-region-based candidate, without a
`main.py` change) but is a real, named, easily-disabled parameter if it
needs to be turned off without a revert.

## Guide-shape crease cut REVERTED — CTO wants pad/crease isolation solved as a backend config problem, not client geometry (2026-08-17)
CTO tested the crease-cut build (previous entry below) and gave direct
feedback: liked the on-screen guide shape as it was before that change, and
explicitly directed that fingerprint-pad isolation should be solved as a
**backend configuration** problem, not by changing the client-side capture
geometry. `PadSilhouetteShape.defaultShape` reverted to its pre-cut values
(`cy: 0.37, ry: 0.111195`), and the companion `main.py` secondary-camera-3
`_sec_cy` copy reverted to `0.37` alongside it, so the two stay in sync.

**Why a backend fix is a genuinely different, harder problem than the
existing content-aware masking already solves.** `afis_print.py`'s existing
`_flash_diff_mask`/U-Net refinement (guide+flashdiff / guide+unet) separates
finger SKIN from non-finger BACKGROUND (desk, wall) using near-camera torch
falloff -- but the flexion crease is still finger skin, illuminated the same
way as the true pad, so that mechanism has no signal to tell pad and crease
apart. A real pad/crease isolation fix needs a different cue: the crease's
own texture is characteristically straighter/more parallel and lower-
curvature than the pad's whorled ridge flow (visible directly in the CTO's
own annotated photo). This project already has the building block for
exactly that measurement (`_ridge_confidence`, orientation coherence gated
by in-band ridge energy, and the Poincare-index core/curvature search used
elsewhere for reticle placement) -- next real step is applying that as an
additional mask-refinement stage inside the guide bound, not a guide-size
change. Not yet built -- flagged for the next session/round.

## Guide shape cut to exclude the DIP flexion crease, per a real annotated CTO photo (2026-08-17) — SUPERSEDED, see entry above
CTO sent a real photo of their own thumb, hand-marked green (true pad/ridge
area) vs. yellow (the joint flexion-crease band below it, visibly different
ridge character) and said the yellow area must never appear in the
superprint — plus floated, as a separate thought, that once the guide only
captures real ridge area, there may be room to move the working distance
closer for more detail on the fixed-size AFIS/NFIQ2 canvas.

**Fixed** (`capture_pad_silhouette_overlay.dart`, `PadSilhouetteShape.defaultShape`):
the crease boundary in the photo sits at roughly 64% of the way down the old
guide's own vertical span — i.e. the bottom ~35% of every capture to date
was crease, not pad. Cut asymmetrically (top edge held at its old position,
only the bottom edge moves up) since the CTO's photo only flagged the
BOTTOM boundary as wrong: `cy` 0.37 -> 0.3311, `ry` 0.111195 -> 0.0723,
`rx` untouched (width wasn't flagged). Since `guideRegion` is written
verbatim from this shape and used directly as the backend's AFIS crop mask,
this one client-side change is sufficient to affect everything downstream
(on-screen guide, `_scoreRoi`, `_focusPointScreenSpace`, the real backend
mask) — same "single source of truth" design this file already documents.
Also fixed a real, now-stale hand-copied constant this change would
otherwise have silently drifted from (`main.py`'s secondary-camera-3 guide
synthesis hardcoded `cy=0.37` "matching the main guide's own" -- updated to
0.3311, same drift-risk class already documented elsewhere in this project
for `_scoreRoi`/`_focusPointScreenSpace`).

**Real, flagged residual risk, not yet resolved**: `_MASK_COVER_DILATE=1.3`
(`afis_print.py`) still lets the backend's content-aware flash-diff/U-Net
mask reach up to 1.3x beyond whatever `guideRegion` this shape produces --
a real risk given the crease has its own periodic, ridge-like texture that
could fool that same content-aware detector into treating it as pad. This
cut was sized so the new dilated bound (0.425) sits comfortably above the
OLD guide's own un-dilated bottom edge (0.481), which should leave real
margin, but if the crease still shows up in a real superprint after this
ships, `_MASK_COVER_DILATE` — not another guide-size cut — is the next real
lever to check, per its own already-existing real-data-calibration history
(round 11: 1.6 measurably hurt a well-placed capture; not re-tuning it blind
here).

**The "move closer once the canvas is pad-only" idea — real, plausible,
deliberately NOT acted on yet.** Correct mechanism as stated: a fixed-size
AFIS/NFIQ2 canvas wastes resolution on non-ridge content, and removing the
crease should let a closer capture spend that recovered canvas budget on
real ridge detail instead of overflowing into skin that was always going to
be masked out. But this project's own standing discipline is one variable
at a time — the crease cut itself needs a real device test first (does the
new guide actually look right against a real live thumb, does the crease
actually disappear from real superprints) before compounding it with a
second, independent distance change on top. Flagged as the natural next
real experiment once this cut is confirmed, not built now.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project. My own vertical-boundary estimate came
from visually reading the CTO's photo, not an exact pixel measurement —
worth a direct on-screen sanity check against a real thumb before trusting
the exact numbers.

## Real production bug found + fixed: minutiae patches could win as the FINAL superprint (partial-pad crops, not diagnostic-only as originally intended); live wavelength estimator retuned off real telemetry (2026-08-17)
CTO reviewed the first real telemetry capture (`01662ffb`, nfiq2Score 86) and
flagged two things: the live wavelength estimator/UX wave cue is "definitely
not working," and asked to see the real superprint for that capture directly,
saying "I'm not sure AFIS would allow a partial print" once told its
`afisSource` was `minutiae_deltaLeft`.

**Real production bug, confirmed and fixed.** Pulled `01662ffb`'s real
`minutiaeDebug` — `deltaLeft` (a 0.62x-radius crop of the guide, ALSO shifted
off-centre: `cx - 0.38*rx`, `cy + 0.25*ry`, so ~38% of the full pad's area,
not concentric with it) had won outright and become the actual production
`superprintPath`/`nfiq2Score`. Checked every one of the 8 minutiae-patch
sub-guides in `main.py`: none of them is the full pad — they range 0.55x
(coreTight) to 0.70x (core/left/right/tip/base) radius, with deltaLeft/
deltaRight also off-centre. Re-derived both the real full-guide candidate and
the real winning deltaLeft crop from `01662ffb`'s own raw burst
(`afis_print.generate()`, same real code) and ran real `mindtct -m1` on both
to sanity-check: full-guide native 100 minutiae, freqNorm 275, the deltaLeft
crop 132 — minutiae COUNT alone doesn't settle this (this project's own prime
directive already established mindtct/Gabor-synthesized minutiae counts are
foolable, not a trustworthy stand-in for real bozorth3 matchability), but the
structural finding stands regardless of count: a smaller, off-centre crop
representing less of the physical pad was silently allowed to REPLACE the
full print in production, contradicting this feature's own originally-stated
intent (2026-08-03 history: "written to Firestore as `minutiaeDebug` for
per-capture validation of whether any patch ever wins selection" — i.e. meant
to be *observed*, not acted on). The 2026-08-12 comment in `main.py` even
already documents this happening twice before (`minutiae_left` won two real
captures, 77 and 83) without ever being flagged as a policy question until
now. Root cause: NFIQ2 measures local block quality, not print completeness
— a tight, evenly-focused sub-crop can score BETTER than the full pad while
covering meaningfully less real ridge/minutiae area, the same NFIQ2-vs-real-
matchability divergence this project's whole prime directive is about, just
never previously checked for THIS candidate family specifically.

**Fixed** (`main.py`): minutiae patches still compute and log their real
NFIQ2 score (`minutiaeDebug`, field renamed `wonSelection` ->
`wouldWinSelection` to make the new semantics explicit) but can no longer
promote themselves to `best_afis_img`/`afis_params`/the real `superprintPath`
— restores the original diagnostic-only intent. Real, deliberate cost: any
capture that was relying on a minutiae patch to rescue a weak full-guide
result (this session's own two prior real wins) will now score whatever the
full-guide candidates alone produce instead — likely lower NFIQ2 on some
captures, but a full-pad print instead of an undisclosed partial one, which
is the trade the CTO's own question was actually asking for. **Committed,
NOT deployed** — needs its own explicit deploy go-ahead like every other
backend change.

**Live wavelength estimator: real root cause narrowed from the new
telemetry, not fully solved, retuned.** `01662ffb`'s telemetry showed 129
in-coverage frames, 21 real throttled attempts, only 1 success
(`sampleCount: 1`) — consistent with the long-standing historical
`sampleCount:0` pattern (71% of captures, 2026-08-14). Traced two real,
additive contributors: (1) refocus lock alone took 3.68s of the ~7.5s
pre-burst window, so most of the 21 throttled attempts were spent on frames
still actively AF-hunting (genuinely blurred) rather than the ~1.5s of
actually-in-focus hold time — now gated on `!_refocusing` so attempts
concentrate on the post-lock window instead; (2) the `minStripStd=6.0`
per-strip contrast bar was validated (2026-08-14) against cached, full-
quality STILL JPEGs, never against the live YUV preview stream this actually
runs on, which is lower-resolution and plausibly more ISP-denoised — relaxed
to `3.0` for the live call specifically (shared function's default
unchanged, so nothing else that calls it is affected). Also lowered
`_liveWavelengthMinSamples` 3 -> 2: even a fully-fixed per-attempt success
rate still has to clear 3 independent samples inside a typically-short
post-lock hold window (~6 possible throttled attempts at 250ms in 1.5s) —
2 is still a real check (the existing outlier-rejection guard already
protects against trusting a single bad sample), just a more realistic bar
for how much post-lock time a hold actually provides.

**New diagnostics added, not just a guess-and-hope fix.** `estimateRidgeWavelengthPx`
gained an optional `RidgeWavelengthAttemptDebug` sink (`stripsAttempted`,
`stripsClearedStd`, `maxStripStd`, `axis`) filled in on EVERY attempt,
success or failure — closes the exact gap that made this untraceable before
(every past failure looked identical from the outside). Logged to the new
`captureTelemetry` stream as a `wavelengthAttempt` event per throttled
attempt. The next real capture's telemetry will show, for the first time,
the actual observed per-strip contrast distribution — confirming whether
3.0 is enough, needs to go lower, or whether the real bottleneck is
something else entirely (e.g. `axis` picking the wrong strip orientation
near a whorl core). **Not yet device-tested** — same standing discipline as
every other capture-side change this project.

## Real device retest confirms ANR fix; ClearCoin root-caused to identity churn, not a code bug; full-pipeline diagnostic telemetry added (2026-08-17)
CTO ran two more real captures on the sequential-encode-fix build. Both
completed cleanly (`a262d2b3` nfiq2=78, `e33d618e` nfiq2=82) — **first real
confirmation the ANR fix from the previous round is holding**, no repeat of
the "isn't responding" dialog.

**ClearCoin "+10 shows every time" — investigated with real data, root
cause is NOT the code.** `clearcoin_screen.dart` already does exactly what
was asked: reads a live, per-user Firestore `clearCoinBalance` field, shows
"+10 earned" only while under 50, switches to showing just the total once
at/above it. Confirmed this is genuinely live and correct: the CTO's real
account balance read **20** after their 2 real captures this session
(exactly 2x10). The real reason the cap has never visibly kicked in:
queried all real captures project-wide and found **99 distinct userIds
across only 238 total captures** (~2.4 captures per identity) — Firebase
anonymous auth persists across app restarts but not across a reinstall,
and every current test build is still signed with a freshly-regenerated
debug keystore (the still-open release-keystore item), which forces an
uninstall between builds and wipes that identity. The CTO has likely never
gotten 5 real captures on one persistent identity before the next test
build reset it. **Not a code change** — this should resolve itself once
the permanent release keystore lands and updates happen in-place instead
of via reinstall.

**Full-pipeline diagnostic telemetry added**, per explicit CTO ask ("add a
diagnostic function for everything on capture pipeline so we can start
debugging and optimizing from a point of knowledge rather than guessing").
Directly targets a real, previously-invisible gap found in this same
review: `refocusDebug.finalSharpness` (measured once, at the moment focus
locks) didn't line up with the eventual captured stills' `laplacianScore`
on either of the two real captures reviewed (`e33d618e`: 176 at lock vs.
~87 on the actual best still) — with nothing recorded in between, there
was no way to tell whether sharpness genuinely degrades during the hold
window, during the burst itself, or whether the two numbers just aren't
directly comparable (different measurement pipelines -- live preview vs.
full JPEG).

Built as a throttled (150ms), non-blocking trajectory logger
(`_logTelemetry`) sampling `focusValue`/`liveAbsSharpness`/`coverage`/gyro
continuously through the whole session, plus explicit checkpoints at every
real transition: `refocusLocked` (right after focus lock, matching
`refocusDebug`'s own moment), `holdComplete` (right as the hold timer
finishes, immediately before the image stream stops for the burst — the
real checkpoint closing the gap above, directly comparable against
`refocusLocked` since both are live-domain), and `shotFired` per burst
shot (timing-only — the image stream is already stopped by then for
`takePicture()`, so there is genuinely no live focus signal available
during the actual burst; documented plainly rather than faking a per-shot
reading). Written once, fire-and-forget, to `captureTelemetry/{captureId}`
-- an existing Firestore collection/security-rule pair already in this
project (built for the discontinued oscillating flow, never wired up for
front_only_v1 before now) deliberately separate from the `captures` doc so
a slow/failed telemetry write can never affect the real capture. No new
Firestore rules needed — the existing `captureTelemetry` rule (`create` if
`userId == auth.uid`) already covers this write exactly.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project. CTO plans several more real test
captures next; this telemetry is what turns those into real answers about
focus-drift instead of another single-data-point guess.

## Redundant second-burst capture built: real hypothesis test, feature-flagged off, needs real device testing (2026-08-16)
CTO asked to build and test the "capture a second redundant hold+burst,
keep whichever scores better, never fuse" idea floated earlier in this
session as a fresh, unproven hypothesis (distinct from anything sweep
already validated). Unlike the fusion-variant work above, this genuinely
**cannot** be measured against the cached local capture library the way
those were -- it's a question about real session-to-session physical/pose
variability during a live capture, which a static-JPEG harness can't
honestly simulate. Built as a real, working, OFF-by-default feature
instead, matching this project's own established discipline for exactly
this class of change (same pattern as `_sweepEnabled`/
`_sweepBurstHybridEnabled`).

**Client (`front_capture_controller.dart`)**: new
`_secondBurstEnabled` flag (`false`). When on, `_fireBurst()` doesn't call
`_finishAndUpload` after the first burst completes -- it stashes the
captured shots (`_burst1Shots`), resets the exact same hold-gate fields
`start()` already resets (`_refocusedThisHold`, the wavelength-estimate
state, `_holdStart`), and returns to the `holding` phase with a "Hold
still again — bonus capture" banner. The SAME `_onFrame`/`rawOnTarget`
machinery that fired the first burst naturally fires `_fireBurst()` again
for round 2 -- no parallel hold implementation, reusing 100% of the
already-proven gate logic. Round 2 then uploads BOTH bursts: round 1 under
the existing `front_burst_*` paths / `frames` Firestore field (byte-for-
byte unchanged), round 2 under new `front_burst2_*` paths / a separate
`frames2` field -- deliberately never merged into one array, so nothing
about the existing single-burst path changes when the flag is off (the
only state today).

**Backend (`main.py`)**: new `_download_front_only_frames_burst2()`
(reads `frames2` if present, returns `None` otherwise -- self-skipping,
same contract as every other optional candidate source in this pipeline).
A new candidate block runs right after the main `_afis_variants` loop:
scores burst2's own native + freqNorm renderings via real NFIQ2
(`_score_ground_truth`, the same ground-truth sidecar every other
candidate uses) and keeps it ONLY if it beats round 1's own best score --
deliberately SELECT, never fuse. Averaging pixels across two genuinely
different real holds is exactly the risk this project's own zone-fusion
findings already showed is harmful (`zone_reduction_test.py`: a single
un-fused anchor zone beat every fused multi-zone configuration by 2x+) --
this avoids that failure mode by construction, comparing two independent
renderings rather than blending their raw frames.

**Real, deliberate costs, stated plainly**: roughly doubles capture time
(a second full hold-to-lock + 8-shot burst) and roughly doubles the
backend's per-capture compute cost for the added candidate (2 more
`afis_print.generate()` + NFIQ2 sidecar calls). Both costs are the direct,
unavoidable price of testing whether real capture-to-capture redundancy
actually helps matchability -- not incidental waste.

**Not yet device-tested, and cannot be pre-validated the way the fusion
variants were** -- this needs a real capture with the flag flipped on to
produce even the first data point. Recommend testing this in isolation
(flag on, nothing else changed) before drawing any conclusion, same "one
variable at a time" discipline as every other capture-side change this
project.

## New deepAmbBestFl fusion variant built + wired in; completed the pending "does front's fusion win NFIQ2 but lose matchability" investigation (2026-08-16)
CTO asked (a) whether averaging the ambient burst but fusing with only the
single best flash frame (instead of averaging the whole flash burst, like
`deepMaxc` already does) would help matchability, and (b) to run any other
tests that could improve it -- which included finally completing the
investigation flagged as pending in the "Sweep put on ice" entry above:
does front's own production fusion pool win NFIQ2 selection while actually
losing real matchability, the same pattern already confirmed for sweep's
mosaic.

**Built `deepAmbBestFl`** (`afis_print.py`): reuses `deep*`'s existing
ambient-side `_stack_face_on` averaging unchanged, but the flash side now
picks the single sharpest flash frame (new `_best_frame_by_sharpness`
helper, plain Laplacian-variance argmax) instead of averaging the whole
flash burst -- flash frames are this project's own long-documented
recurring source of blown-out/inconsistent exposure, so averaging all of
them risks diluting one genuinely good frame with several bad ones. Not
`static const`-able caching concerns applied here since this reuses the
existing request-scoped `stack_cache` dict, with its own cache key
(`df_bestfl`) so it can't collide with `deep*`'s flat-averaged flash cache
slot.

**Real bozorth3/INCITS-378 gate, 22 real local front_only_v1 captures
(mindtct -m1 templating, same users.json genuine/impostor grouping used
throughout this project, `scratchpad/ps/fusion_matchability_gate.py`,
not committed -- scratch-only):**

| variant | genuine | impostor | sep | iMax | beat/15 (or /9) |
|---|---|---|---|---|---|
| native (single best frame, no fusion) | 4.93 | 3.84 | 1.09 | 8.0 | 1/15 |
| **deepFuse** (flat avg combine) | 22.60 | 15.69 | **6.91** | 42.0 | **2/15** |
| deepMaxc (coherence combine) | 13.93 | 11.79 | 2.14 | 39.0 | 0/15 |
| **deepAmbBestFl** (new) | 13.40 | 10.86 | 2.54 | 25.0 | 0/15 |
| stack | 4.27 | 4.61 | -0.34 | 21.0 | 0/15 |
| focusStack | 4.60 | 4.11 | 0.49 | 10.0 | 0/15 |
| fuseAvg (single-pair) | 6.11 | 4.37 | 1.74 | 15.0 | 0/9 |
| fuseMaxc (single-pair) | 5.33 | 4.16 | 1.17 | 15.0 | 0/9 |
| fuseSoft (single-pair) | 5.33 | 4.36 | 0.97 | 10.0 | 0/9 |

(fuseAvg/fuseMaxc/fuseSoft ran on a smaller real sample -- 17/22 templated,
9 genuine pairs -- some captures' best-single ambient/flash pair didn't
register; not investigated further since the deep*-family sample is the
one that matters more for this question, being the actual production
default for front_only_v1's real bursts.)

**Two real findings, not one.** (1) `deepAmbBestFl` is a genuine,
measurable improvement over `deepMaxc` specifically -- its closest sibling,
same architecture, only the flash-handling differs -- on both separation
(2.54 vs 2.14) and worst-case impostor risk (iMax 25.0 vs 39.0, i.e.
meaningfully less confusable with a random stranger). Wired into
`main.py`'s `_afis_variants` as one more additive max-of-variants
candidate on the strength of this. (2) **The pending investigation's
answer, and a real surprise**: plain `deepFuse` (flat-average combine, the
mode NOT preferred in production) has the single best beat-count of every
variant tested -- better than the coherence-based `deepMaxc`/`deepSoft`
modes production actually favors, which were chosen specifically because
they win on NFIQ2 and visually fix flash specular smudging (see the
`deepMaxc` real-capture writeup elsewhere in this file: "3e54236a maxc:
real NFIQ2 57->81"). This is a real, if small-sample (9-15 real pairs,
10 real users), signal that NFIQ2-driven variant PREFERENCE inside
`main.py`'s max-of-variants selection may be systematically passing over a
better-matchability candidate (`deepFuse`) in favor of a worse one
(`deepMaxc`) purely because the worse one looks better under NFIQ2 --
consistent with this project's own prime-directive thesis (NFIQ2 and real
matchability pull in different directions) but not yet strong enough
evidence (single-digit beat-count differences on this sample size) to
justify reordering or removing anything from the existing variant pool.
**Flagged, not acted on** -- worth a larger real sample before touching
`deepMaxc`'s standing in production.

**Not yet deployed** -- needs its own explicit go-ahead, same as every
other backend change this project.

## Real device test of the debug-signed build: app-not-responding on upload, real root cause found + fixed (2026-08-16)
CTO ran a real capture on the debug-signed build (the same commit with the
AF-hunting/wave-cue/`_scoreRoi`/Crashlytics/POPIA fixes) and hit an Android
"ClearBridge Beta isn't responding" dialog during/around the upload step.

**Pulled the real Firestore doc before guessing anything.** The capture
(`628d7803`) actually completed successfully server-side: all 8 burst
frames uploaded with healthy Laplacian scores (237-1857), the Firestore
write landed, and `processingStartedAt` confirms `processEnhanceAndScore`
was triggered and running normally (checked elapsed time against the
project's own established 130-180s typical window before treating
`status: enhancing` as anything other than in-progress). So the ANR wasn't
a functional upload failure — the real question was what could block the
UI badly enough to trip Android's ANR watchdog around that window.

**Real root cause, found by reading the code, not guessing: the main
burst's decode+encode step already had this exact bug fixed once, just in
the wrong file.** `_captureSweepBurst`'s own encode loop carries a detailed
comment from an earlier round: running 6 simultaneous `compute()` isolates
on a mobile CPU made them starve each other so badly that a single
zone's encode blew 18-22s instead of an expected 3-4s — fixed there by
making those encodes run sequentially. `_finishAndUpload` — the MAIN burst
path every real front_only_v1 capture goes through, unlike the
rarely-exercised sweep path — had never gotten the same fix: its own
decode+encode step used `Future.wait(rawShots.map(...))`, firing all
**8** shots' `decodeStillJpegToLuma` + `compute()` calls concurrently.
8 concurrent isolates is worse than the 6 already proven to cause severe
contention, and a strong, well-evidenced candidate for a main-isolate-
adjacent stall long enough to trigger the observed ANR — this is exactly
the kind of "already found and fixed once, never ported to the sibling
code path" bug this file's own history keeps surfacing (see `_scoreRoi`/
`_focusPointScreenSpace`).

**Fixed**: converted the `Future.wait` block to a plain sequential
`for`-loop over `rawShots`, matching `_captureSweepBurst`'s already-proven
pattern exactly — each isolate gets the full CPU to itself, one at a time.
Total wall-time is roughly unchanged (still N x single-encode-time), just
without the 8-way contention spike. Downstream code (`framesMeta`
construction, `uploadTasks`) was already keyed off the same record shape
(`bytes`/`flashOn`/`lap`/`ts`/`exif`/`gyro`), so this needed zero changes
beyond the loop itself. **Not yet re-tested on a real device** — same
standing discipline as every other capture-side change this project; the
next real capture on this fix will be the first real confirmation the ANR
is actually resolved, not just a plausible theory.

## STANDING TODO: release keystore setup still not done — needs a desktop browser (2026-08-16)
Two consecutive real attempts to set the 4 release-signing GitHub secrets from
mobile web both failed with the identical real error
(`KeytoolException: ... "Not the correct tag"` at `:app:packageRelease`,
confirmed via real job logs both times, not assumed) — first with an
RSA-4096 keystore (5,809-char base64), then again with a shorter RSA-2048
one (3,589 chars) generated specifically to reduce mobile-paste risk. Since
the SAME symptom recurred even after shrinking the value and switching to
"Select All" instead of manual drag-select, the likely culprit is GitHub's
mobile web secrets form itself mishandling a long paste into that one
Value field, not the copy technique. CTO's call: stop fighting mobile web,
defer this until a desktop browser is available, and revert to debug
signing in the meantime so the app is testable again right now.

**Reverted to debug signing**: CTO is deleting all 4 GitHub secrets
(`KEYSTORE_BASE64`/`KEYSTORE_PASSWORD`/`KEY_ALIAS`/`KEY_PASSWORD`). The
workflow (`build.yml`) already has a clean fallback for this -- the "Decode
keystore" step's `if: env.KEYSTORE_BASE64 != ''` skips itself when the
secret is unset, and `build.gradle.kts`'s own signing-config logic falls
back to a freshly-generated debug keystore when `/tmp/release.keystore`
doesn't exist -- the same path that already builds `build-capture-harness`/
`build-sweep-test` successfully. No workflow changes needed to revert;
purely a matter of the secrets being absent.

**Next time this is picked up**: do NOT reuse any of the previously-
generated keystore files -- both were deleted from the sandbox immediately
after sending (standard practice this project), and their real values were
never printed into this chat transcript either (deliberately, to avoid
leaking secret material) — so they cannot be recovered. Generate a fresh
keystore from scratch, and have the CTO set all 4 secrets from an actual
desktop browser this time before trying mobile again.

## Real CI confirmation of the push: 3/4 jobs green, release keystore corrupted in transit, real cause found + shorter replacement issued (2026-08-16)
Pushed the 4 held commits + confirmed the run via the real GitHub Actions API
(not assumed). `deploy-web`, `build-capture-harness`, `build-sweep-test` all
passed clean. `build-clearbridge-beta` failed, but not at signing setup —
pulled the real job log rather than guess: `Decode keystore` step reported
success (it's just `base64 -d`, which can't validate content), but the
actual Gradle build failed at `:app:packageRelease` with
`KeytoolException: Failed to read key from store "/tmp/release.keystore":
Not the correct tag` -- a definitive signal the decoded bytes aren't a real
keystore at all, not a wrong password/alias. Root cause: the
`KEYSTORE_BASE64` secret (5,809 characters) almost certainly got corrupted
pasting into GitHub's mobile web UI -- consistent with the two earlier
mobile-UI failures hit setting these same secrets (a generic "Failed to add
secret" and a "name field can't contain spaces" error from pasting the
whole name=value block into one field).

**Fixed by removing the risk factor, not by asking for a more careful
paste.** Regenerated the keystore at RSA 2048 instead of 4096 (still
Android's own recommended default for app signing, not a security
downgrade) specifically to roughly halve the base64 length (5,809 -> 3,589
chars) and reduce the odds of another mobile-paste corruption. **Verified
the replacement round-trips correctly BEFORE sending it** (encoded to
base64, decoded back, re-opened with `keytool -list` using the real
password/alias, confirmed readable) -- catching any corruption in my own
generation step, not just trusting the encode succeeded. Delivered via
SendUserFile, never pasted into chat; local copy deleted after send. User
needs to REPLACE (not add) all 4 existing GitHub secrets with the new
values. `main` branch keystore never signed a real distributed build, so
swapping it now costs nothing (no existing install would need
uninstalling).

## Full code-review pass on front_capture_controller.dart/front_capture_screen.dart: two real (currently-dormant) bugs found + fixed (2026-08-16)
Per the CTO's ask for a code-review pass (no new device data, just a careful
read) before the next beta build. Dispatched a thorough review focused on
the same bug CLASS this file has hit twice already this session (hand-copied
geometry constants silently drifting from their real source of truth) plus
resource-leak/lifecycle/null-safety sweeps. Verified every finding against
the actual code before trusting it (one candidate finding turned out to rest
on a wrong assumption about Dart const-expression rules — see below).

**Real bug #1, fixed: `_focusPointScreenSpace` had already drifted, just
inertly.** This was a second hand-copied `static const Rect`
(0.3385, 0.2588, 0.6615, 0.4812), kept deliberately separate from `_scoreRoi`
since `setFocusPoint`/`setExposurePoint` take preview-space coordinates, not
`_scoreRoi`'s still-space ones — a real, correct reason to keep them as two
named quantities. But its implied half-width (0.1615) had already gone stale
against `PadSilhouetteShape.defaultShape`'s real current `rx` (0.134604,
after a later guide-shrink round only touched the shape's own default, never
this copy) — the exact same bug class as the already-fixed `_scoreRoi`
drift. Purely inert today only because `_beginAutofocus` has only ever read
the rect's CENTRE, never its extent — the centre (0.5, 0.37) happened to
still match. Fixed the same way `_scoreRoi` was: converted to a getter
deriving straight from `PadSilhouetteShape.defaultShape.cx/cy`, eliminating
the second copy entirely (returns an `Offset` now, not a `Rect`, since only
the centre was ever meaningful). **Real Dart constraint that changed the fix
shape**: this can't be `static const` — `PadSilhouetteShape.defaultShape.cx`
is not a valid constant expression, confirmed by an ALREADY-DOCUMENTED real
build failure elsewhere in this same file (`_sweepGuideShapeForProgress`'s
own note on trying the identical pattern for `.rx`) — caught this via
checking prior art in the file itself before shipping a fix that would have
failed to compile, not by trusting Dart's general const-field-access rules
in the abstract. A plain (non-const) getter sidesteps it with zero real
cost, since this is read once per autofocus trigger, never per-frame.

**Real bug #2, fixed (currently dormant, session-lifecycle version of the
already-fixed per-hold bug): `start()` never resets the live-wavelength-
estimate state.** The 2026-08-15 fix taught the per-hold "thumb genuinely
left" reset trigger (inside `_onFrame`) to zero out
`_wavelengthSampleCount`/`_liveWavelengthPx`/`_liveWavelengthStillPx`/
`_wavelengthAxis`/`_wavelengthOutlierStreak` — but `start()` itself, which
resets a long list of other per-session accumulator fields for a fresh
capture attempt, never got the same treatment. Confirmed currently
unreachable: `front_capture_screen.dart` always constructs a brand-new
`FrontCaptureController` in `initState()` and never calls `start()` twice on
one instance, and `start()`'s own `_starting || _streamRunning` guard would
additionally block same-instance re-entry while streaming. Fixed anyway,
belt-and-suspenders, directly adjacent to `_refocusedThisHold = false` in
`start()` (the same trigger point the per-hold fix uses) — zero real cost,
and closes the same stale-lifetime-counter failure mode at the session
boundary too, in case a future retake-without-rebuilding flow ever changes
the current one-controller-per-attempt lifecycle.

**Everything else checked clean**: Timer/StreamSubscription/
AnimationController disposal (the only `StreamSubscription`, `_gyroSub`, is
cancelled on both `_fail()` and `dispose()`; all `AnimationController`s in
the screen file are disposed in their owning `State.dispose()`; the legacy
secondary-camera session code this project's own history documents as its
prior source of exactly this bug class has actually been removed from this
file entirely), `mounted` checks before post-await `setState`/context use,
phase consistency on every early-return/error path (all route through
`_fail()`, which always lands in `FrontCapturePhase.error`), and the
`distanceWaveCue` computation's edge cases (no division-by-zero risk, fixed
positive denominator; clamp/anchor directions internally consistent). Noted
but not audited further: `_sweepEnabled`/`_sweepBurstHybridEnabled` are both
`static const bool = false`, so the ~900 lines of sweep-positioning/
sweep-burst code in this file are currently unreachable — not a gap in this
review, just out of scope since it can't execute in the current build.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project; both fixes are logic-preserving on every
real capture path exercised so far (confirmed by tracing that both were
inert before this fix), so no behavior change is expected on the next real
capture, just removed drift risk.

## Pre-beta pass: backend deploy caught up, real release keystore issued, POPIA compliance gaps found + two fixed (2026-08-16)
CTO asked for four things: deploy whatever backend work was still pending,
solve the release-signing-keystore gap, audit the POPIA consent flow for
beta readiness, and refocus all remaining tweaks on front_only_v1 only.

**Backend deploy.** The two commits sitting undeployed since 2026-08-13
(`30b7dc4` reverting sweep's matchability mosaic to plain freqNorm,
`b1f7191` removing the destructive `pad_mask_override`) were deployed via
`firebase deploy --only functions:python-pipeline --project clearbridge-dc699`.
Confirmed live via the real Cloud Functions v2 API: `updateTime` advanced to
`2026-08-16T10:52:38Z`, `state: ACTIVE` — same drift-check discipline as the
2026-07-24 14-commit deploy-gap incident.

**Release keystore, real and permanent, not a placeholder.** Generated a real
4096-bit RSA keystore (100-year validity, alias `clearbridge-release`) via
`keytool`, non-interactively (random password via `openssl rand`, never
echoed to the session transcript) — same parameters
`scripts/generate_release_keystore.sh` already specified, just run
programmatically instead of by hand. Delivered the keystore + the 4 secret
values (`KEYSTORE_BASE64`/`KEYSTORE_PASSWORD`/`KEY_ALIAS`/`KEY_PASSWORD`) to
the CTO directly as files, never pasted into chat. `.github/workflows/build.yml`'s
`build-clearbridge-beta` job already reads all 4 as GitHub Actions secrets
and decodes/signs with them — confirmed by reading the workflow, no workflow
change needed. **The one step this session genuinely cannot do**: setting
GitHub repo secrets requires the GitHub API's secret-encryption flow, which
isn't among the tools available here — the CTO has to paste the 4 values in
themselves (repo Settings → Secrets and variables → Actions). Local keystore
working files deleted from the sandbox immediately after delivery.
`scripts/generate_release_keystore.sh`'s own instructions were also stale
(said "GitLab CI/CD variables" — GitLab isn't the active CI per this file's
own "Repos & branches" section) — corrected to reference GitHub Actions repo
secrets, matching what `build.yml` actually reads.

**POPIA compliance audit — one real bug found + fixed on the spot, three
real gaps needing a CTO call, all three now resolved.** Read
`user_details_popia_screen.dart` plus the live Firestore ruleset (fetched
directly via the Firebase Rules API, not assumed from a local file — this
project has never had a local `firestore.rules`, confirmed again here).
- **Real bug**: `_save()` wrote the `consents` map as hardcoded `true` for
  all four required checkboxes regardless of their actual bound state.
  Harmless in practice today (the Continue button is disabled unless
  `_allRequired` — all four true — so the written value always matched the
  real state anyway), but a latent landmine if any of the four ever becomes
  optional later. Fixed: writes `_captureConsent`/`_superprintConsent`/
  `_reuseConsent`/`_durationConsent` directly.
- **Age gate raised 16 -> 18.** POPIA defines a "child" as under 18 and
  generally requires a parent/guardian's ("competent person's") consent to
  process a child's personal information — compounded here since fingerprints
  are "special personal information" under POPIA, and this app's single-user
  anonymous-auth flow has no mechanism to collect a guardian's consent at
  all. CTO's explicit call: raise the floor rather than build a consent-by-
  proxy flow. `_detailsValid` now requires `_age! >= 18`.
- **Deletion right made real, not just promised.** The consent screen has
  always said "I understand... I can request permanent deletion at any
  time" — but no mechanism existed anywhere: no in-app action, no support
  contact, and the live Firestore rules blanket-deny all client-side
  update/delete on `captures` (`allow update, delete: if false`), so only an
  admin with direct console/Admin-SDK access could ever have fulfilled that
  promise, and nothing in the app or its docs told a user how to reach one.
  Fixed with a genuinely new capability, not a doc change: a
  `deletionRequests/{userId}` Firestore collection (rule added via the
  Rules API — confirmed via diff against the previously-fetched live rules
  that this was the ONLY change, nothing else in the ruleset touched — user
  can create/refresh their own pending request, cannot set or clear its own
  `status`, admin has full read/write, same "user creates, status is
  server/admin-only" pattern already used for `applications`). Wired into
  `BetaThankYouScreen` (chosen deliberately over the POPIA screen itself,
  since that screen is a one-time first-launch gate — `popia_completed`
  means a returning user never sees it again, so it's the ONLY screen a user
  could ever reach this from) as a small "Request my data be deleted" link
  below Capture Again/Exit, confirms via a dialog, writes the request, shows
  a snackbar. Does **not** auto-delete anything — deliberately a request
  queue for manual admin review, consistent with how every other admin-
  gated write in this ruleset already works.
- **Responsible-party/Information Officer disclosure**: flagged as a real
  POPIA Section 18 gap (no company/address/Information Officer contact
  anywhere in the consent flow) — CTO said they'd provide the real details;
  **still open, waiting on that real information** (deliberately not
  fabricated). Whoever picks this up next: add it to the POPIA consent
  screen once the CTO supplies the actual company/contact details, not
  before.
- **Not a substitute for real legal review** — flagged explicitly to the
  CTO as a code/product audit, not a legal opinion, given the real
  regulatory stakes (biometric data + POPIA). The age-gate and deletion-flow
  fixes reduce obvious exposure but don't constitute compliance sign-off.

**Scope going forward, per explicit CTO instruction: front_only_v1 only.**
No further sweep/mosaic/multi-zone work unless explicitly revived — matches
the 2026-08-14 shelving decision already documented below. Remaining
beta-readiness tweaks scoped to front_only_v1 specifically.

## Crashlytics fully wired: com.clearbridge.beta had never been registered in Firebase at all (2026-08-15)
CTO asked to complete the Crashlytics setup properly rather than leave the
native half undone, plus asked what else is outstanding before beta.

**Real gap found, not just a missing file.** Fetched `google-services.json`
for the app ID already in `firebase_options.dart`
(`...:android:ad3f79916c25252848acca`, real access via the existing Admin
SDK service-account credentials against the Firebase Management API) and
found it registers `com.clearbridge.app` / `com.clearbridge.bridge` --
**neither matches this app's real `applicationId`, `com.clearbridge.beta`.**
Listed every Android app in the project directly to confirm rather than
assume: only those same two exist. `com.clearbridge.beta` had never been
registered at all -- `firebase_options.dart` had been borrowing the
`com.clearbridge.app` registration's `appId` the whole time. That's fine
for Auth/Firestore/Storage/Functions (none of them enforce package-name
matching against `FirebaseOptions`, which is exactly why this went
unnoticed through months of real production use) but Crashlytics's native
Android SDK needs the app's own genuine registration to attach to, and
the `google-services` Gradle plugin hard-fails at configuration time on
a package-name mismatch.

**Fixed at the root, not worked around**: registered a real new Android
app for `com.clearbridge.beta` via the Management API (`POST
.../androidApps`, real service-account credentials -- additive only,
does not touch the two existing registrations), fetched its real
`google-services.json`, placed it at `android/app/google-services.json`,
and updated `firebase_options.dart`'s `appId` to the new, correctly-
registered value (`apiKey` unchanged -- confirmed identical across all
three apps, one shared project-level key). Applied both Gradle plugins
(`com.google.gms.google-services`, `com.google.firebase.crashlytics`) in
`settings.gradle.kts`/`android/app/build.gradle.kts`.

**One real, flagged unknown**: `dl.google.com` and `search.maven.org` are
both blocked by this sandbox's own egress policy (confirmed via the proxy
status endpoint), so the two plugin versions pinned (google-services
4.4.2, firebase-crashlytics-gradle 3.0.3) could not be verified against
the live Maven registry -- real, well-established published versions,
but the first thing to check if CI fails specifically on plugin
resolution.

**Real, deliberate risk taken**: changing `firebase_options.dart`'s
`appId` touches the Dart-side `Firebase.initializeApp(options:)` call
every SDK in this app depends on, not just Crashlytics -- unlike the new
app registration and the JSON file (purely additive), this modifies
something that's worked in production for months. Judged safe because
Firestore/Storage security rules key off `request.auth.uid`, never
`appId`, and nothing else in this codebase's own established logic
references it either -- but it's real production-config surgery,
**not device-tested**, and is the one part of this change most worth
watching closely on the next real build.

## Real device test of the AF-hunting fix: one real stuck-at-pending capture (crash suspected, no logs to confirm), distance-wave rings found frozen due to a lifetime-not-per-hold sample counter, Crashlytics added (2026-08-15)
CTO ran a real capture session: 3 of 4 captures scored cleanly (70/78/81),
1 (`bbaebb07`) is genuinely stuck at `status: pending` -- app reportedly
crashed during upload. Also reported the new distance-wave rings never
shrink even moving the phone all the way back (screenshot).

**Crash: real, but not diagnosable from Firestore data alone.** `bbaebb07`
has every field the app writes -- all 8 burst frames uploaded (real paths,
healthy Laplacian 882-1168), full guide/refocus/wavelength/camera-lens
diagnostics, a completed refocus convergence. So the upload loop and the
Firestore write both finished; it's stuck specifically because
`processEnhanceAndScore` never ran. That trigger call is wrapped in its
own `try`/`catch` and is fire-and-forget (never awaited), so a network
failure there can't crash the app or hang the UI -- ruling it out as the
direct cause. More likely candidates: the real 8-file *concurrent* upload
(`_uploadConcurrency = 8`, pre-existing, not touched this session) is a
genuine memory-pressure point, or the OS killed the app for an unrelated
reason during that window. **This app had zero crash reporting** -- no
Crashlytics, nothing -- so this is inference from data, not a confirmed
cause.

**Real bug found: distance-wave cue frozen because its reliability gate
uses a LIFETIME counter, not a per-hold one.** `_wavelengthSampleCount`
is only ever incremented (`grep` confirms exactly one `= 0`, at its field
declaration) -- across the CTO's "a few capture sessions" today, once it
happened to accumulate to >=3 from several earlier attempts (each
individually gathering only 0-1 samples, per the still-open `_scoreRoi`
qualify-rate question), `wlReliable`/`distanceWaveCue` permanently
stopped being null and started rendering off whatever `_liveWavelengthPx`
was last cached -- which, since fresh samples are rare, barely moves,
reading as a frozen, unresponsive cue exactly matching the screenshot.
**Fixed**: reset the whole wavelength-estimate state
(`_wavelengthSampleCount`, `_wavelengthOutlierStreak`, `_liveWavelengthPx`,
`_liveWavelengthStillPx`, `_wavelengthAxis`) at the same real "thumb
genuinely left coverage range" trigger `_refocusedThisHold` already uses,
so reliability reflects fresh sampling on the CURRENT attempt, never
stale accumulation from an earlier one. **Not yet device-tested.**

**Crashlytics added, Dart-side only.** `firebase_crashlytics` +
`runZonedGuarded`/`FlutterError.onError`/`PlatformDispatcher.instance.
onError` wired into `main.dart`, matching the standard Flutter+Crashlytics
pattern. **Deliberately incomplete**: this app has no
`android/app/google-services.json` and no `google-services`/
`firebase-crashlytics` Gradle plugins -- every other Firebase SDK here
(auth/firestore/storage/functions) works purely off the Dart-side
`FirebaseOptions` in `firebase_options.dart`, but Crashlytics genuinely
needs the native file + both Gradle plugins to register crashes, and
applying either plugin without that real file present fails the build at
configuration time -- breaking every future CI run, not just this one.
Did not fabricate or guess at the file. Real remaining step, needs the
CTO: download `google-services.json` from Firebase Console -> Project
Settings -> the Android app -> add it at `android/app/google-services.json`
-> then the two Gradle plugin lines can be added safely. Until that
lands, the Dart-side calls are safe no-ops.

## Real device test of the `_scoreRoi` fix: "live feed looked blurry" traced to a real bug in the wavelength-gate change itself, fixed (2026-08-14)
CTO tested the `_scoreRoi` runtime-correction build and reported the live
camera feed looked blurry / struggled to focus. Pulled the two real
captures from this test before touching anything: both landed fine —
`b31f6d8e` scored real NFIQ2 **81** (a strong result), ambient-frame
client Laplacian scores 687-740 (healthy), no errors. So the FINAL
captured images were not degraded — ruled out via real data rather than
assumed. `_scoreRoi`'s own consumers were also checked and cleared: the
camera's actual autofocus target point (`_beginAutofocus`) reads from
`_focusPointScreenSpace`, a completely separate, untouched constant --
`_scoreRoi` only affects the app's own sharpness/coverage/wavelength
*measurements*, never where the lens physically focuses.

CTO clarified: the LIVE PREVIEW itself looked blurry/hunting, not the
final photos. That pointed at real repeated autofocus re-triggering, and
a real bug was found, distinct from the `_scoreRoi` fix (which stays --
this is a separate defect in the same wavelength-gate change from
earlier today). The hold's refocus-reset condition
(`_refocusedThisHold = false`, which forces a fresh `_refocus()` call
the next time on-target recovers) had `wavelengthTooHigh` added to it
alongside `tooFar`/`tooClose` when the wavelength check became a gate --
but unlike coverage (a smooth, continuously-sampled mean-luma value),
`wavelengthTooHigh` depends on a low-sample-count, EMA'd autocorrelation
estimate already known to be noisy (the whole reason the outlier-
rejection streak logic exists). The reset condition's OWN comment states
the design principle this violated: transient signal dips shouldn't
force a refocus, since that "multiplies unnecessary waits" -- every time
the noisy wavelength estimate flickered across the 16.0px threshold and
back, this fired a real, visible AF re-acquisition cycle.

**Fixed**: removed `wavelengthTooHigh` from the refocus-reset condition
only. It stays in `rawOnTarget`'s own gate (the actual intended fix from
earlier today — the hold still correctly can't complete while genuinely
reading too-close); it just no longer also forces the lens to re-hunt
every time the noisy estimate blips. The coverage-based signals
(`tooFar`/`tooClose`) already capture genuine distance changes reliably
enough to re-trigger AF on their own, same as before this whole
wavelength-gate line of work started. **Not yet device-tested.**

## Real root cause of the 71% wavelength-gate inertness found: `_scoreRoi` never got the runtime BoxFit.cover correction `guideRegion` already has (2026-08-14)
Follow-up to the resolution hypothesis being refuted -- dug into the
remaining candidate flagged at the time: whether `_scoreRoi` (the live
ROI feeding `meanLuma`/`estimateRidgeWavelengthPx`/focus tracking) has
the same class of bug as the already-documented, already-fixed-once
"BoxFit.cover guideRegion bug".

**Confirmed, from the code's own math, not a guess.** `_scoreRoi` IS a
real, previously-fixed value -- the 2026-08-06 fix corrected a genuine
rotation-axis bug, proven three independent ways at the time (arithmetic,
real Firestore data, a visual crop comparison), and that fix is not being
undone here. But that fix only corrected the ROTATION mapping. It never
gave `_scoreRoi` the SEPARATE runtime BoxFit.cover crop/scale correction
`_computeGuideRegion` already applies to `_guideCx`/`_guideCy`/
`_guideRx`/`_guideRy` (the fields `guideRegion` itself is built from) --
`_scoreRoi` stayed a hand-derived `static const`, frozen at whatever crop
was assumed when it was written, never updated per real device.

**Smoking gun**: `_scoreRoi`'s own hardcoded bounds imply a center of
exactly (cx=0.6300, cy=0.5000) -- which is EXACTLY `_guideCx`/`_guideCy`'s
hardcoded DEFAULT value (the value that exists ONLY before
`_computeGuideRegion` ever runs its real per-device correction). Not
independent confirmation of anything -- the same uncorrected number,
copied into two places by hand.

**Fixed**: `_scoreRoi` converted from a `static const Rect` to a getter
deriving directly from `_guideCx`/`_guideCy`/`_guideRx`/`_guideRy` --
the same already-validated, already-runtime-corrected fields
`guideRegion` uses, instead of maintaining a second, independently-
drifting copy of the same geometry. Cannot regress: before
`_computeGuideRegion` ever runs, those fields sit at hardcoded defaults
already close to (and, for the center, identical to) the old constant, so
the fallback is no worse than before; on every real device (where
`_computeGuideRegion` always runs before the live stream starts) it now
gets the real per-device-corrected region instead.

**This is the leading real explanation for the 71% `sampleCount: 0`
finding** (see the entry below) -- a systematically-offset ROI would
explain the estimator failing to find qualifying ridge content on most
real captures despite its own math being proven robust down to 320px
resolution. **Not yet device-tested** -- the two diagnostic counters
added the same session (`inCoverageFrameCount`/`wavelengthNullAttempts`)
will show directly on the next real capture whether this actually moves
`sampleCount` off zero, which is the real confirmation this needs before
trusting it.

## Real device test of the wavelength-gate build: gate confirmed inert on 71% of real captures; resolution hypothesis tested and refuted; new distance-wave UI cue built (2026-08-14)
CTO tested the wavelength-gate build. Capture `9e7606b9` (new user,
front_only_v1, real nfiq2Score 80, no hang/error) looked clean on the
surface, but its `liveWavelengthDebug` showed `sampleCount: 0` despite
128 general sharpness samples during the hold -- the live estimator never
produced a single qualifying reading, so `wavelengthTooHigh` was `false`
the whole hold by construction and the new gate never actually got a
chance to block anything.

**Checked whether this was a one-off — it isn't.** Pulled
`liveWavelengthDebug` across the last 34 real front_only_v1 captures
(back to early August, well before today's change): **24/34 (71%) show
`sampleCount: 0`.** This is a longstanding, pre-existing reliability gap
in the live estimator itself, not something today's change caused or
revealed for the first time on this one capture — it just means the
gate, however correctly wired into `rawOnTarget`, is near-inert in
practice for most real users until this is fixed.

**Resolution-mismatch hypothesis tested with real data, and refuted.**
`estimateRidgeWavelengthPx` requires >=2 of 5 sampled strips to clear a
`minStripStd=6.0` contrast bar before it returns anything; the working
theory was that the live CameraImage preview's much lower resolution
(vs. the ~3200px-decode still the backend measures) fails that bar even
when the eventual still succeeds easily (this exact capture's backend
measurement found `afisWavelengthPxRawBlocks: 419` -- plenty of reliable
blocks). Reproduced the real strip-std qualification algorithm in Python
against the 10 real front_only_v1 captures with locally cached raw
bursts, at 7 simulated widths from native (~4266px) down to 320px: **100%
of captures qualified (>=2/5 strips) at every single resolution tested,
including 320px.** The estimator's own math is robust across resolution;
that's not the bottleneck.

**Real root cause still open — the likelier remaining candidate is
`_scoreRoi` itself.** It's a hardcoded normalized `Rect`, never derived
at runtime through the same BoxFit.cover-correcting transform
`guideRegion` uses -- structurally the same class of risk as the
already-documented real "BoxFit.cover guideRegion bug" this project hit
once before (a hardcoded region constant that silently didn't match what
the transform actually produced on real devices). Can't fully confirm
this without a live raw CameraImage frame, which isn't available from
this sandbox -- so instead of guessing at a fix blind, added two cheap,
purely-diagnostic counters (`inCoverageFrameCount`,
`wavelengthNullAttempts`) that will directly show on the NEXT real
capture whether the estimator is rarely INVOKED (inCoverageRange rarely
true) versus invoked often but rarely qualifying once it runs -- the one
distinction the current data can't make.

**New: distance-wave UI cue, replacing the text-only hint.** CTO
feedback: the "Move back slightly" text hint isn't blatant enough to
register mid-hold, and proposed a visual instead -- rings streaming
outward from the guide's own edge, shrinking as the user reaches the
right distance. Built as a genuine continuous analog of the SAME signal
that now gates the hold (`FrontCaptureState.distanceWaveCue`, 0..1,
anchored to the real 11.5px sweet-spot midpoint at 0 and the 16.0px gate
threshold at 1 -- both already-established real numbers, not new ones),
rendered in `CapturePadSilhouetteOverlay` as concentric rings traced
along the pad's own boundary path (reusing the shape's existing
`toPath(inflate:)`, the same technique the scrim-fade layers already
use) via a new one-directional ticker (needed `TickerProviderStateMixin`
instead of `Single*`, since the existing breathing-pulse ticker already
claimed the one slot `Single*` allows). Ring travel distance, opacity,
and visibility all shrink toward zero as the cue approaches 0 and grow
toward their max approaching 1, so "the waves getting smaller" reads
directly as "getting closer to right" -- and draws nothing at all when
no reliable estimate exists yet, same discipline as everywhere else this
signal is used. **Inherits the same inertness problem documented above**
until the sampleCount gap is fixed -- the rings will rarely appear in
practice on the same ~71% of real captures, for the same reason the gate
rarely fires. Not yet device-tested.

## Sweep put on ice, focus returned to front_only_v1: fusion is real-negative on real data (mosaic AND field-domain), front's own live-wavelength check upgraded from hint to gate (2026-08-14)
CTO decision after the mosaic/field-fusion tests below: sweep's core
mosaic concept measures negative regardless of technique (pixel blend,
field-domain consensus, or zone-reduced variants all lost badly to a
single un-fused zone — see the two entries below), so sweep is shelved
for now and effort returns to `front_only_v1`, "since it does exactly
the same thing with less effort." Pushed back on the "exactly the same
thing" part with the real data before proceeding: front_only_v1 is the
one architecture in this whole project that measured **negative** real
SourceAFIS separation (-0.42, beat 0/45) against sweep's +10.57 — and
that gap traces to the guide PROTOCOL (session-to-session scale/pose
consistency), not to fusion. Sweep's fusion step is confirmed bad; its
capture protocol was never the thing that failed. CTO agreed to proceed
on front_only_v1 anyway (product-scope decision, not a data disagreement)
and asked for real matchability optimizations there.

**Fix #1, built: front's own live-wavelength check upgraded from an
advisory hint to a real gate.** `front_capture_controller.dart` already
has a real, scale-corrected live ridge-wavelength estimator (2026-08-06,
validated to track the backend's own `afisWavelengthPx` to within ~1px)
— but `wavelengthTooHigh` only ever changed the displayed `distanceHint`
text ("Move back slightly"); it was never included in `rawOnTarget`, the
actual condition gating whether the hold can complete. A user could see
the hint and have the hold finish right through it anyway. This is the
exact, already-diagnosed reason front_only_v1 still shows real cross-
session scale mismatch despite the estimator existing — sweep got the
real fix for this exact gap on 2026-08-13/14 (ported as an actual bounded
wait), but it was explicitly scoped away from front at the time per the
CTO's own instruction then. Now that front is the focus, folded
`wavelengthTooHigh` directly into `rawOnTarget` (`!wavelengthTooHigh`,
same as the existing `!tooClose`) and into the refocus-reset condition —
no new bounded-wait mechanism needed, since the hold's own continuous
re-check loop already behaves exactly like sweep's bounded wait, just
indefinitely, the same way it already does for `tooFar`/`tooClose` today.
Threshold left at the existing `_liveWavelengthTooHighPx = 16.0` —
unlike sweep's copy-pasted version of this same number (which was wrong
for a different pipeline domain and got recalibrated to 35.0), front's
16.0 is grounded in front's OWN real NFIQ2 correlation data (native
wavelength >=15px -> catastrophic, 9-14px sweet spot), not a
cross-architecture guess, so no reason to change the number itself here
— only to make it actually load-bearing. Diagnostic field renamed
`wavelengthHintThresholdPx` -> `wavelengthGateThresholdPx` to match.
**Not yet device-tested** — same standing discipline as every capture-
side change this project.

**Investigation #2, running: do front's own fusion variants win NFIQ2
selection while losing real matchability, the same pattern just found
for sweep's mosaic?** `main.py`'s `_afis_variants` pool includes several
pixel-averaging fusion variants (`fuseAvg`/`fuseMaxc`/`fuseSoft`,
`deepFuse`/`deepMaxc`, `stack`/`focusStack`) guarded only by a proxy/
NFIQ2-driven sharpness-ratio heuristic (`_FUSION_VARIANT_NAMES`) — never
validated against real SourceAFIS matchability the way
`pyfingHybridFreqNorm` eventually was. Given the newly-confirmed finding
that plain pixel averaging at real registration accuracy destroys ridge
energy (see the mosaic/field-fusion entries below), this is a directly
motivated, previously-unchecked gap in front's own production variant
pool. Testing all 9 reachable variants (no pyfing sidecar from this
sandbox) against the same real NIST SD302 impostor gate, using the 10
real front_only_v1 captures with locally cached raw bursts (3 real
genuine pairs). Result pending.

## Sweep zone reduction + field-domain fusion tested: fusion of ANY kind, on ANY zone subset, loses badly to a single un-fused zone (2026-08-14)
Follow-up to the CTO's two direct questions: "why keep left/right if they
contribute nothing" (proposing a tip-center-delta-only capture), and
whether a light/shadow-consensus mechanism could work alongside the
mosaic to bring out more ridge detail (correcting the premise first:
photometric stereo didn't fail for lack of shadow — the torch is
on-axis with the lens, so it fills the valley micro-shadows PS needs,
confirmed via direct counterfactual — but a genuinely different
mechanism, fusing ridge ORIENTATION instead of pixels, was worth a real
test since orientation varies slowly in space and should be far more
tolerant of the sub-ridge-period registration error that was already
shown to destroy pixel-domain fusion).

**Field-domain fusion (`fieldfuse`): real, clean negative.** Built a
coherence-weighted multi-zone consensus ridge-orientation field (fused in
double-angle space, sanity-checked to reproduce the plain single-zone
field exactly when given no sides — max angular error 2.4e-7 rad), then
ran the existing Gabor synthesis on the ANCHOR's own untouched pixels
using that field, so anchor ridge detail is never averaged. Real
SourceAFIS test (13 captures, 10 genuine pairs, same NIST impostor gate
used all session), with the missing control this project had never run
before -- a true no-fusion single-zone baseline:

| arm | separation | beat impostor max |
|---|---|---|
| mosaic (current production pixel blend) | +13.04 | 3/10 |
| **anchor_only (centre zone, no fusion at all)** | **+28.44** | **7/10** |
| fieldfuse (orientation-consensus) | -0.60 | 0/10 |

fieldfuse lost even to the pixel mosaic, likely because side-zone
orientation contributed wherever ITS OWN coherence was high with no gate
on whether the anchor's own local field was already reliable there --
misregistered side content could overwrite good anchor signal instead of
only filling genuine gaps. Not pursued further without a materially
different gating mechanism. The bigger finding is `anchor_only` beating
BOTH fusion arms by 2x+ -- no prior mosaic test in this project had ever
included a true zero-fusion control.

**Zone reduction (`zone_reduction_test.py`): independently confirms the
same finding on a different real sample.** The 6 real 5-zone captures
(delta/tip zones are only ~2 days old, all one finger, all 15 cross pairs
genuine by this project's own established single-tester convention):

| configuration | separation | beat impostor max | pad coverage vs. centre |
|---|---|---|---|
| **anchor only** | **+26.12** | **8/15** | 1.0x |
| tip-centre-delta (CTO's proposal) | +12.55 | 3/15 | 1.74x |
| left-centre-right | +8.82 | 2/15 | 2.28x |
| all 5 zones fused | +4.92 | 3/15 | 2.88x |

Two things settled: among fusion configs, fewer/more-overlapping zones
lose less (tip-centre-delta > left-centre-right > all-5), consistent with
"more averaging = more destruction" -- the CTO's own zone-reduction
instinct was directionally right within that constraint. But no fusion
configuration, on either real sample, comes close to no fusion at all.
More pad coverage did not buy better matchability anywhere in this data
-- the averaging cost dominated every time.

**Conclusion, and the reason sweep was set aside (see the entry above)**:
this isn't a technique problem (tried pixel-domain and field-domain, both
failed) and it isn't a zone-count problem (failed at 3 zones and at 5) --
cross-zone fusion itself appears to be the wrong lever for this
pipeline's real matchability, regardless of form. The real, still-untested
next step this pointed at (capture multiple zones for redundancy, SELECT
the single best one via real NFIQ2 the same way `main.py` already selects
every other variant, never average) was proposed but not built before the
CTO redirected effort to front_only_v1 instead.

## Real device test of the readiness-gate build; phone-vs-thumb movement tested (inconclusive, n=1); left zone's real root cause found + fixed (2026-08-14)
CTO tested the countdown-removal build (`711abe9`) with a deliberate twist:
braced the thumb against a fixed surface and moved the PHONE instead of the
thumb through the sweep zones, per their own observation that repositioning
the thumb feels physically uncomfortable, then asked to debug why 'left'
keeps underperforming.

**Readiness-gate build confirmed working on real hardware.** Capture
`971c304d` (2026-08-14, new user, 48s total): every zone shows
`readyDetected: true`, resolving in 303-364ms — all near the 300ms floor,
nowhere close to the 1400ms bound — confirming the concurrent
stream+`takePicture()` condition flagged as unverified is safe on this
device, and that the fixed 2100ms countdown really was pure dead time. Gyro
readings (1.4-2.5°/s) were in the same range as prior thumb-moved captures,
no sign phone-movement adds meaningfully more shake at the moment of
capture.

**Phone-vs-thumb registration: genuinely inconclusive on n=1, not a win.**
Real per-zone correlation against center on this capture: left 0.406
(fails the 0.45 gate), right **0.822** (best right seen all session), delta
0.686 (worse than every prior thumb-moved delta, which ran 0.85-0.94), tip
0.797. Mixed, not a clean signal either direction — right/tip look
slightly better, delta looks worse, on a single real capture. Told the CTO
plainly this needs 2-3 more phone-moved captures (plus a real matchability
comparison against existing thumb-moved captures) before concluding
anything — comfort is a real, independent reason to prefer it regardless
of what the numbers eventually say, but it isn't yet demonstrated to help
or hurt matchability.

**Left zone's real root cause found, distinct from the 2026-08-12 AF-timing
fix — and NOT related to phone-vs-thumb.** Left underperformed on BOTH the
new phone-moved capture (0.406) and every prior thumb-moved capture
(0.169-0.620 across 4 real captures, pass rate 2/4) — same weakness in
both builds, ruling out the countdown/readiness-gate change or the
movement-actor question as the cause. Re-examined the code path rather
than re-tuning AF timing again (already fixed once, 2026-08-12, and real
data shows it's still failing): **no guide is ever shown on screen during
calibration, and the pre-loop hold snapped the guide directly to the LEFT
position with zero animation** — left is the only zone in the whole
5-zone sequence the user has to find COLD, with a static target and no
motion path to follow, while every other zone gets a continuous 1400ms
animated tween from wherever it just successfully was. That's a real,
structural asymmetry independent of AF convergence, and it survived the
AF-timing fix because it was never the thing that fix addressed.

**Fixed**: the guide now appears at CENTRE from the start of calibration
(a free side benefit — the wavelength/focus sampling ROI already assumes
centre content, so this also gives calibration itself a real target for
the first time) and stays there through the pre-roll hold. The zone loop's
first iteration now animates left FROM centre using the exact same tween
every other zone already uses, instead of snapping there instantly. The
parallel `_redirectZoneFocus(cam, 0.0)` head-start call is unchanged and
still races AF to the left target during the hold — so by the time the
animated move arrives, focus is very likely already converged, meaning
this fix adds real motion guidance without giving up the existing
AF-timing fix's benefit.

**Real, deliberate cost**: zone 0 now pays the same ~1400ms move-animation
time every other zone already pays, which it previously didn't (it went
straight into the readiness gate). Given the ask was specifically to fix a
real registration failure, not preserve every last millisecond of the
countdown-removal savings, this trade was made deliberately — worth
knowing when reviewing the next real capture's total duration.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project. Committed, not pushed (per standing
process rule) — awaiting explicit go-ahead.

## Sweep timing: countdown removed for a content-driven readiness gate; zone-geometry vertical-shift idea checked and set aside as confounded (2026-08-14)
CTO, prepping for beta with a real 30-subject ground-truth+sweep paired
dataset coming, asked whether sweep's capture time could be trimmed without
sacrificing quality, then two follow-ups: remove the verbal countdown
entirely in favor of camera-driven readiness detection plus a visual
capture cue, and whether delta zone's strong real registration (see the
guide-gated pad test above) means lowering all zones vertically might help.

**Countdown removed, replaced with a real content-driven gate.**
`sweep_capture_controller.dart`'s per-zone flow used to pay a fixed cost
every zone: a 700ms settle (zone 0) or a 3-tick verbal countdown at 700ms
each (every other zone, 2100ms total) — stacked ON TOP of the two
mechanisms that actually do measured work (`_redirectZoneFocus`'s own
900ms focus/exposure settle, the gyro motion-blur gate). Neither the flat
settle nor the countdown was ever backed by a measurement. Replaced both
with one gate reusing `_focusValue` — the same peak-normalized relative-
sharpness signal already validated for `front_capture_controller.dart`'s
own primary hold-phase gate (0.45 threshold) and for this file's own
`_calibrate()` — applied per zone instead of only once at the start:
resolves in as little as 300ms once real content is in focus, never
blocks past 1400ms. `_focusPeak` resets per zone so an earlier, sharper
zone can't suppress the current zone's relative signal.

**This required a real architecture change, not just a constant tweak**:
`_focusValue` only updates while the image stream is open, and the stream
was being closed at the end of `_calibrate()` — before the zone loop even
starts. Moved the single `stopImageStream()` call to fire once after the
whole zone loop instead, so the same stream `_calibrate()` already opens
stays live through every zone. **This is a genuinely new, unverified
condition**: every real device test this project has run so far only ever
called `takePicture()` after the stream was stopped; this makes
`takePicture()` run while the stream is still active. Different failure
surface than the 2026-07-30 ANR (which was from REOPENING a stream
mid-sweep — this one never closes and reopens, it just stays open) but
still needs real-device confirmation before trusting it, same as every
other capture-side change this project.

**Visual capture cue added in place of the countdown**, reusing
infrastructure that already existed rather than building new UI: the
shared `CapturePadSilhouetteOverlay` already renders gold for
`PadSilhouetteState.capturing` and green for `.locked` — the guide now
flips to green for the real duration of each zone's shutter sequence (not
a fixed cosmetic timer) via a new `zoneCaptureFlash` field on
`SweepTestState`, read by `sweep_capture_screen.dart`'s `_silhouetteState`.
Gold reads as "sweep in progress", green as "capturing this zone right
now".

**Real budget change**: worst case per zone drops slightly (900+1400=2300ms
max vs. the old fixed 2100ms already being paid regardless), but the real
saving is in the common case — resolving in ~300-600ms once focus is
already converged (likely for most zones, since the move+settle already
ran) instead of always paying the full fixed cost. Estimated ~4-7s off the
whole sweep in the typical case; not yet measured on a real device.

**Zone-geometry vertical-shift idea: checked, real confound found, not
implemented.** CTO's hypothesis (delta scores best in the small real
registration sample above, so maybe all zones benefit from a similar
vertical shift) was checked against the guide geometry directly rather
than assumed. Computed real overlap area between each zone's guide mask
and center's, using the actual shipped shape parameters:

| zone | offset | overlap with center |
|---|---|---|
| left/right | cx shifted +/-0.15 (~90% of rx) | **47.5%** |
| delta/tip | cy shifted +/-0.07 (~51% of ry) | **69.9%** |

Delta/tip were deliberately built with roughly half the guide's own radius
of displacement "so both still overlap the centre zone across most of
their area" (the zone's own existing code comment) — left/right shift by
nearly a full radius instead. This fully explains delta's stronger real
registration correlation without needing a vertical-vs-horizontal
explanation at all: delta/tip simply move less, so of course they overlap
center more and register more easily. The n=3-4 real sample can't
distinguish "vertical positioning is better" from "smaller displacement
registers better" — this is the same confound class already caught once
this session (the pad-gate "more fusion = better" reversal). **Not
changing zone geometry on this signal** — if displacement magnitude is
the real driver, shifting all zones vertically would only help to the
extent it also shrinks their displacement, not because vertical is
inherently favored, and either way the sample is too thin to act on
without a real controlled test.

## Sweep matchability mosaic: real production defect found + fixed (pad_mask_override collapsed matchability 12x), five other mosaic-tuning ideas tested and refuted (2026-08-13)
Follow-up to the sweep-vs-front-only decision below, working through the
prioritized matchability-optimization list against the real SourceAFIS-vs-
NIST-SD302-impostor gate built for that test. All tests use the same 13 real
sweep captures (10 confirmed genuine pairs, same-user real repeat captures)
and the same 15 real NIST SD302 impostor scans established there.

**Fixed and shipped (locally, not yet pushed): the mosaic's enhancement
config.** Production's real matchability-mosaic render used
`enhance='pyfingHybrid', freq_normalize=True, pyfing_blend=0.7`. Real test on
this exact artifact (3 real sweep captures): pyfingHybridFreqNorm scored
separation **-0.13** (noise floor, same failure signature as front_only_v1's
matchability collapse). Plain freqNorm on the SAME mosaic content, same
fusion geometry, only this one config line different: **+8.69**, later
confirmed at **+13.04** (beat 3/10) across the full 13-capture/10-genuine-pair
set. `pyfing_blend`/`pyfing_hybrid` was validated on a different population
(22 front_only_v1-era captures) and never re-checked against real sweep
mosaic content specifically — it doesn't transfer. `main.py`'s matchability
render now uses plain `freq_normalize=True, freq_scale_min=0.9`, no pyfing.
Committed `30b7dc4`, **pushed**.

**Five follow-up optimization ideas tested against this same real gate, all
negative — the 0.45 whole-crop ECC accept-gate is confirmed correctly
calibrated, not a hidden lever:**
- **Local optical-flow residual refinement** on top of ECC registration:
  per-side correlation improved, but real matchability WORSENED (+8.69
  baseline -> +1.15 with flow-refine).
- **Masked ECC** (registering only within the pad, not the whole crop):
  frequently fails to converge; no real improvement where it does.
- **Pad-only correlation as the accept-gate** (instead of whole-crop, at
  0.45 and 0.30 thresholds): both worse than the shipped whole-crop gate
  (separation 13.04 -> 4.21 or 0.56, fusion rate dropped 25/33 -> 12-18/33).
- **Loosening the whole-crop gate** (0.45 -> 0.30 -> 0.20 -> none): monotonic
  NEGATIVE trend on a controlled equal sample (13.04 -> 8.59 -> 7.87 ->
  7.55). This refuted an earlier, confounded read of the pad-gate test that
  had looked like "more fusion = better" — that apparent trend was an
  artifact of captures dropping out of the comparison entirely as the gate
  tightened, not a real fusion-count effect.
- **Tightening the whole-crop gate** (0.45 -> 0.55 -> 0.65 -> 0.75): 0.55
  showed marginally higher separation (+13.57) but on a shrunken sample
  (11/8 vs 13/10 genuine) — discounted as a sample-size confound, not a real
  win; 0.65 and 0.75 collapsed the sample further with no genuine pairs left
  to compare at 0.75. **Conclusion: 0.45 is the correct operating point in
  both directions** — diagnostically it measures the wrong thing (background
  dominates a 2.6x-margin crop, ~91% of it), but it happens to be more
  permissive toward genuinely complementary zone content than any
  pad-restricted alternative, which matters given sweep's zones are
  *designed* to show different pad regions.

**Real production defect found + fixed: `pad_mask_override` was quietly
destroying the freqNorm fix's own validated gain.** CTO directly observed
background sometimes present in final superprints and connected it to
matchability. Investigation found the mosaic render call
(`main.py`, ~line 1841) was still passing `pad_mask_override=_pad_mask` — a
U-Net-derived pad refinement mask, meant to trim the guide's mild real
overshoot into background more precisely than the guide alone. **The U-Net
mask is broken on mosaic crop input**: visually confirmed (contour overlay,
`3f5b9cd6`) as a 4.3%-of-crop sliver down the thumb's LEFT EDGE, nowhere
near the actual pad — not a subtle bug. Real matchability test isolating just
this one variable (`none` vs `unet_gated`, same 13-capture/10-genuine set,
same freqNorm config otherwise): separation collapsed from **+13.04 to
+1.05** (beat 3/10 -> 1/10), a ~12x loss — meaning the already-pushed
freqNorm fix has **not actually been delivering its validated benefit in
production**, this second, independent defect was still live underneath it
the whole time.

**Candidate fix tried and also refuted before committing to the final
one.** Since the U-Net mask itself is broken, tried gating the same
`_pad_within_finger` refinement by the GUIDE superellipse instead (a real,
stable bound, unlike the broken U-Net output) — mask-stability diagnostics
looked genuinely promising (guide-gated: 0.37-0.63x guide area, consistently
shrinking, 1.7x spread; U-Net-gated: 0.29-3.23x guide area, mostly
*expanding* past the guide, 11x spread). **Did not rescue matchability
either**: separation +1.87, beat **0/10** — actually worse on the metric
that matters most than the broken U-Net-gated version's 1/10, despite the
mask itself being far saner. This means the failure isn't "which detector
gates the pad refinement" — any extra content-aware restriction layered on
top of the guide is destructive to this pipeline's real matchability, the
same lesson as every other denoise/masking pre-pass tried against it this
whole project (pyfing, coherenceDiff, NNS, masked ECC, pad-only correlation
gate above). The guide's own mild real overshoot into background — genuinely
real, and what the CTO spotted — costs far less than every attempted fix
for it has cost so far.

**Fix shipped**: removed `pad_mask_override`/the U-Net pad-refinement block
entirely from the mosaic render call — it now renders with plain guide-only
masking (freqNorm's already-validated +13.04 configuration, restored to
what it should have been the whole time). Committed locally (message:
"Remove destructive pad_mask_override from sweep matchability mosaic —
guide-only masking restores the validated +13.04 freqNorm separation"),
**not yet pushed** (standing process rule — awaiting explicit go-ahead,
same as the freqNorm fix's own deploy). Not device-tested; same standing
discipline as every other backend change this project — needs its own
explicit deploy go-ahead before this reaches production regardless of push
timing.

## Sweep chosen over front_only_v1 for beta (real matchability test), live-wavelength distance GATE ported to sweep (2026-08-13)
CTO asked directly: between sweep and front_only_v1, which architecture is
superior and which should beta ship with. This had never actually been
tested on the metric that matters — every prior comparison used NFIQ2 (both
score 70s-80s, a wash) or capture speed/complexity (favors front_only_v1).
Ran the real test instead: real SourceAFIS genuine-vs-impostor separation,
using a real external impostor population.

**Real, decisive result — reverses the NFIQ2-based read.** Genuine pairs =
the CTO's own real captures across sessions (CTO confirmed they are the
only tester, so every same-userId pair, and per capture-mode, every
different-userId pair too, since Firebase anonymous auth mints a fresh
userId per session — this is all one real finger). Impostor pairs = the
CTO's own captures vs 15 real, distinct NIST SD302 subjects (right thumb,
rolled scans, downloaded from the project's existing S3 training bucket,
`sd302/extracted/SD302a/...`) — a genuine, unambiguous external population.

| | genuine mean | impostor mean | impostor max | separation | beat impostor max |
|---|---|---|---|---|---|
| **sweep** (`superprintPath`, n=16) | 13.65 | 3.08 | 26.97 | **+10.57** | **18/120 (15%)** |
| **front_only_v1** (`superprintPath`, n=10) | 1.06 | 1.48 | 14.94 | **-0.42** | **0/45 (0%)** |

Front_only_v1 shows the finger matching itself *worse*, on average, than a
real stranger's thumb — essentially zero real matchable signal, despite
scoring fine on NFIQ2. Visually confirmed why: two of the CTO's own
front_only_v1 captures were at visibly different physical scales (one
tight complete whorl, one much coarser with no visible core) despite each
individually reading well on NFIQ2 — a matcher can't correspond ridges
across a scale mismatch. Sweep's fixed per-zone guide geometry is very
likely winning specifically because it's more consistent session-to-
session; front_only_v1 has nothing enforcing that.

**Verdict: push sweep forward for beta, not front_only_v1** — directly
validates this project's own prime directive (matchability over NFIQ2):
front_only_v1 ties or beats sweep on NFIQ2 but has no real matchable
signal on this test; sweep is the only one of the two that actually works
as a fingerprint matcher. Caveat stated plainly: n=1 real subject, not a
population-level guarantee — but the separation is categorical (positive
vs. negative), not a close call.

**Root cause of front_only_v1's failure — fixed, scoped to sweep only.**
`front_capture_controller.dart` already has a real, scale-corrected live
ridge-wavelength estimator (2026-08-06, validated to track the backend's
own `afisWavelengthPx` to within ~1px) — but it's advisory-only, a text
hint ("Move back slightly") the hold can complete right past. That's
exactly why front_only_v1 still shows the scale-mismatch failure despite
the estimator existing. `sweep_capture_controller.dart` had ZERO
equivalent — `distanceHint` there was pure status text, never derived from
anything measured.

Fixed, scoped strictly to sweep per the CTO's explicit ask (front_only_v1
untouched): ported `HybridCaptureService.estimateRidgeWavelengthPx` (shared
package code, not duplicated) into `_calibrate()`, reusing front's own
real-data-validated threshold (`_liveWavelengthTooHighPx = 16.0`) and
EMA/outlier-rejection logic verbatim. Unlike front, this runs as an actual
bounded GATE, not just a hint: if the estimate is reliable and reads
too-close after the initial calibration window, the sweep shows "Move back
slightly" and waits up to 3s more (polling every 300ms) before the first
zone ever fires — real margin to reposition, capped short so a
correctly-positioned user (the common case) never pays for it.

Deliberately does NOT open a second camera stream — this file already hit
a real ANR from reopening `startImageStream` mid-sweep (2026-07-30);
sampling happens on the SAME already-open stream `_calibrate()` already
uses for focus/brightness. Base ROI reused directly from front's own
`_scoreRoi` constant (valid because sweep's `center` zone resolves to
exactly `PadSilhouetteShape.defaultShape`, the same shape front's ROI was
derived from); still-decode-width corrected to sweep's own 2048 (not
front's 3200 — using the wrong one would silently mis-scale every
estimate). Full diagnostics (`liveWavelengthPx`, `liveWavelengthStillPx`,
`sampleCount`, `gateResolvedInTime`) written to
`sweepBurstDebug.zones.liveWavelengthDebug` for the next real capture.

**Threshold recalibrated 2026-08-14 — the original 16.0 was wrong, not just
unverified.** It was copied verbatim from front's own value, which encodes
front_only_v1's NFIQ2 finding (native wavelength >=15px on a single plain
frame is catastrophic). That doesn't transfer: real backend
`afisWavelengthPxRaw` across the 16 real sweep captures used for the
architecture test above (same 2048-decode-width domain the live estimate is
already scaled into, so directly comparable) clusters at 15-30px, mean 26.7,
sd 4.3 — the old 16.0 sat almost at the very BOTTOM of sweep's own normal
range, so as shipped it would have fired on ~15/16 real captures and spent
its whole 3s window unresolved on nearly every capture, adding latency while
gating essentially nothing. Checked whether real matchability actually
supports a "closer is better" push for sweep the way it does for front — it
does not: across the 10 real genuine pairs in this same set, per-pair scale
MISMATCH (not absolute wavelength) is what correlates with score (r=-0.27;
well-matched pairs mean 17.9 vs mismatched 10.4), and the two single
strongest real genuine matches measured all session (41.5, 42.6) both came
from captures at wlRaw~=29 — the high end, not the low end. Sweep's fixed
per-zone guide geometry already produces that session-to-session consistency
for free (the real reason it already beats front_only_v1 above) — no
evidence a live "get farther back" push adds anything on top of it.
Recalibrated `_liveWavelengthTooHighPx` 16.0 -> **35.0**: reframed from an
optimization target to a pure safety backstop, set comfortably above the
whole observed real range (mean + ~2sd) so it only fires on a genuine,
far-outside-normal outlier rather than routinely on ordinary captures.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project. Committed, not pushed (per standing
process rule) — awaiting explicit go-ahead.

## Real device oscillating_8phase test: third independent confirmation, thread closed for good (2026-08-13)
CTO ran one real oscillating_8phase capture (`353cb00b`) as a genuine last
try, per their own framing, and asked for a full review/debug/optimization
pass — the actual thing the two prior investigations (gap-fill fix,
scale-crop check) had been building toward but never had fresh real device
data to test against.

**Real result: nfiq2Score 71 — but that number has nothing to do with the
SfM reconstruction.** `superprintParams.afisSource` shows `frameIndex: 4,
angleDeg: 1.2, afisStackMode: mean, afisStacked: 3` — the winner is a
plain 3-frame mean-stack of near-face-on burst-anchored frames, the exact
same mechanism front_only_v1/sweep already use. Visually confirmed: a
clean, dense, well-formed whorl (`superprint_afis.png`) — a real, good
print, but one that would have looked identical from a front_only_v1
capture. The oscillating-specific multi-angle geometry contributed
nothing to this number.

**The actual cylindrical/SfM path scored real NFIQ2 37-39 — not the 0.0
production recorded.** `nfiqCylindrical: 0.0` in Firestore is ambiguous by
main.py's own documented contract (`_score_ground_truth` fails closed to
0.0 on any sidecar error — "NOT that the print genuinely scored zero").
Reproduced the exact pipeline locally (`main._download_oscillating_frames`
+ `sfm_pipeline.reconstruct_and_unwrap` + `enhancement_pipeline.enhance`,
same technique as the two prior investigations): real local NFIQ2 scored
**37 (composited) / 39 (uncomposited)** — a real, working number, meaning
the recorded 0.0 was almost certainly a **sidecar call failure on this
specific capture, not a genuine score**. Flagging as a separate, real
data-integrity bug (past `nfiqCylindrical` values may understate true
reconstruction quality in some fraction of captures) — not itself a
reason to revive anything, and not fixed this pass since it doesn't change
the verdict either way.

**Visually confirmed the 37-39 is a fair score, not an unlucky
sidecar.** The composited cylindrical unwrap (`enhanced_composited.png`)
shows a blocky, discontinuous tonal smear with visible per-bin seam
banding — no coherent ridge structure at all, next to nothing like the
clean AFIS-path whorl that actually won. Root causes visible in the real
diagnostics: `cylR: 198.5px` (well below the 274-540px range seen on the
6 captures in the earlier redemption test — this capture's pad silhouette
was detected notably smaller), mixed per-frame segmentation methods across
the 9 angle bins (`flash_diff`/`otsu`/`center_lobe` — inconsistent
per-frame quality feeding the stitch), and a coarse measured wavelength
(21.5px) consistent with the already-confirmed structural finding that
this texture's ridge scale is not a fixable resize artifact.

**Final verdict, third independent real-data test in agreement**: the
7-day-earlier batch test (6 captures, gap-fill fix, ceiling 21-44), the
scale-collapse check (clean negative, no crop-before-enhance benefit), and
now this fresh real device capture (37-39 cylindrical vs 71 from a
near-face-on frame the reconstruction didn't need) all point the same
direction. The gap between reconstruction quality and simple single-frame
capture isn't closing — if anything this capture's margin (71 vs 37-39,
over 30 points) is worse than the batch test's own historical range.
**Not recommending any further SfM/oscillating optimization work.** Every
mechanism from the Notion redemption plan has now been tested with real
data; closing this thread for good rather than re-opening it on the next
"one more idea." A genuinely different reconstruction strategy (true
multi-view depth estimation instead of cylindrical single-axis unwrap)
might fare differently, but that's a from-scratch rebuild, not an
optimization of what exists — and three losses this size don't justify
that investment right now.

## SfM redemption thread closed out: real bug found+fixed+deployed, but the fix alone doesn't justify reviving SfM (documented 2026-08-13, work done 2026-08-07)
CTO asked to revisit "the way we found to revive SfM" from memory/Notion.
This was investigated and tested earlier in this same project (Notion:
"Next Session Work Plan — Bozorth3 Re-Gate, SfM Redemption, Fusion Sweep",
Track 2) but the result was never written up here — closing that gap now.

**Real mechanism found, same defect class as two already-fixed NNS bugs.**
`sfm_pipeline.reconstruct_and_unwrap()` computes a `valid` weight-mask
(which texels of the stitched cylindrical texture have real camera
coverage vs. gap-filled/synthesized periphery) but threw it away — never
returned, never composited out before enhancement, for the *successful*
multi-frame reconstruction path. The single-frame fallback path already
did this compositing correctly; the working path never got the same
treatment. This is the identical hard-edge-into-ridge-filter defect
already found and fixed twice this project for NNS (pre-mask ringing,
512-resize scale collapse) — a third occurrence nobody had checked.

**Fixed, committed, and already deployed**: `eff736a` (2026-08-07) threads
the `valid` mask through and composites it out AFTER enhancement using the
same feathered-mask pattern already proven twice elsewhere. Predates the
last confirmed backend deploy timestamp, so it's live in production.

**Real test result on 6 real SfM/oscillating captures (2 local runs,
scoring OLD vs NEW via real local NFIQ2): mean delta +3.0 to +3.5, mostly
positive (4-5 of 6 improved per run) — but the ceiling after fixing it is
only 21-44**, on captures that previously scored 1-9. Nowhere near
front_only_v1/sweep's typical 60-86 range. The fix is real and worth
keeping (no reason to revert a genuine bug fix), but it does **not**
redeem SfM to competitiveness — exactly the caveat the original Notion
plan flagged going in: fixing the gap-fill confound doesn't touch the
independent, real reason SfM was discontinued (wide angular coverage
dilutes ridge density in NFIQ's fixed 500×500 input). That problem is
still fully present and still dominates the result.

**The remaining lever was checked too (2026-08-13, same session as this
writeup) — clean negative, not the same bug as NNS.** Verified, not
assumed, per the plan's own instruction: measured real ridge wavelength
via `_ridge_wavelength_robust` (the exact diagnostic that caught the NNS
512-resize bug) on all 6 real captures at three points — native full
2048×2048 canvas, native canvas cropped to the `valid`-mask bounding box,
and each of those resized to the 512×512 `enhance()` actually sees.

**No collapse signature found — the opposite of the NNS case.** NNS's bug
was a genuine collapse: ground truth 15.0px native → 29.0px after resizing
a full ~3200px CAMERA frame where the pad occupied a small fraction of the
canvas; cropping to the pad first fixed it (16.5px). Here, `bbox_frac`
(pad-bearing region as a fraction of the full canvas) already ran 49.7%
-92.0% — never a small dot in a big frame — and native full-canvas
wavelength was ALREADY 14-28px before any resize, not a resize artifact.
Cropping to the valid-mask bbox before the resize didn't fix anything:
3 of 6 captures got WORSE (2927b6bd 21.5→28.0px, 7f53940f 15.0→28.0px,
3edf5455 24.0→27.5px), 2 were unchanged, 1 moved negligibly (+1px). **Not
implemented — a real, tested negative**, not a guess. The 14-28px native
wavelength is a genuine property of the reconstructed cylindrical texture,
not a fixable input-plumbing bug — direct, first-hand confirmation that
the wide-angular-coverage dilution problem is structural, not an artifact
stack sitting on top of a fixable bug.

**Both candidate mechanisms from the Notion "SfM redemption" plan are now
closed, one shipped-positive (modest) and one tested-negative. Not
recommending reviving SfM/arc_sweep/oscillating_8phase capture modes** —
the gap-fill fix stands on its own merits (deployed, harmless, correct)
but was never sufficient alone, and the one other lever that might have
explained the remaining gap doesn't. No code changed this pass beyond the
already-shipped `eff736a` — this was verification only, scoped to the
oscillating/arc SfM path, nothing touched in front_only_v1, sweep, or any
shared `enhancement_pipeline.enhance()`/`afis_print.py` code other paths
depend on.

## Sweep-burst field test round: adaptive-EV/gyro-gate confirmed live, first real mosaic NFIQ2 win, per-zone flat-fielding/flash-cue retest closes the PS thread (2026-08-13, round 23)
CTO ran 3 real sweep captures back to back under deliberately different
lighting (indoor skylight+natural sun, indoor artificial light, outdoor
direct sun) to stress-test the adaptive-EV/gyro-gate port (`fcca7d6`,
pushed+built this round) and re-probe the light/shadow hypothesis from the
previous round with harsher real data than was available then.

**Ported fixes confirmed working on-device, not just compiling.** All 3
captures show `flashEvStep: -0.714` (the new adaptive curve) instead of the
old flat `-0.6`, and every zone now carries a real `_gyroDegPerSec` reading
(1.0-2.5°/s indoors, one 4.72°/s outlier — see below) — all comfortably
under the 6.0°/s gate, so it never blocked capture, but it's genuinely
measuring real device motion now, not a stub.

**Real scores: 86 / 78 / 86 — no catastrophic sunlight failure this round**,
unlike the 2026-07-18 transillumination case (NFIQ2 6-8 on that one). n=1
per condition, not a settled result, but a real positive data point that
the accumulated fixes (torch threshold, adaptive EV, corrected zone
geometry, mosaic, distal crop) have made the pipeline meaningfully more
robust to hard outdoor light than it used to be.

**First real NFIQ2-selection win for the cross-zone mosaic.** Session 1
(indoor skylight+sun): `afisSource: sweepFusion`, 4/4 sides registered,
fusion proxy 86 = the capture's final `nfiq2Score` — the anchor-dominant
blending fix (round 22-era work) finally won outright selection, not just a
retained-sharpness metric. Visually confirmed clean: wide, dense,
continuous whorl, no seam artifacts.

**Outdoor sun partially broke mosaic registration.** Session 3: only 3/4
sides registered, fusion scored 51 — the round's worst result, well below
the single-zone `left` winner (85). Visually confirmed degraded (fragmented
ridges on the left half). The `left` zone also carried the round's one
elevated gyro reading (4.72°/s vs 1.0-2.5°/s everywhere else) — passed the
6.0°/s gate but plausibly still soft enough to fail the mosaic's own
correlation guard. A real, plausible cost of real motion, not a new bug.

**New real photometric finding, not the one being searched for.** Indoor
(both sessions), flash is consistently *softer* than ambient (Laplacian
ratio 0.52-0.71x per zone, same direction/magnitude as everything measured
all project). Outdoor sun *reverses* it: flash sharper than ambient in
every zone (ratio 1.08-1.28x). Root cause isn't the torch — ambient frames
show real highlight clipping outdoors (0.28-1.66% of pixels vs ~0% on
flash), because the `-0.714` EV pulldown built for indoor torch-intensity
scaling incidentally also protects the flash exposure from outdoor sun
clipping. An emergent benefit of the port, not something it was built for.

**"Hold farther back" experiment: inconclusive, CTO held back only ~5%.**
`afisWavelengthPx` still reads exactly `20.0` (the estimator's hard clamp)
in all 3 captures — identical to every capture before this test, no sign
the held distance moved the needle. CTO confirmed only a ~5% pullback was
tried and flagged wanting to go farther next round. Scores are strong
anyway (78-86) despite sitting at the wavelength ceiling that used to be
catastrophic on the old single-frame front-only pipeline — real evidence
the mosaic+pyfingHybrid+distal-crop stack has made the pipeline much less
wavelength-sensitive than the original front_only_v1-era correlation, not
proof distance no longer matters.

### Flat-fielding + flash/no-flash cue re-tested PER ZONE — clean negative, closes the thread
Every prior PS/flat-field test this project ran on the CROSS-ZONE mosaic
(ECC-registered to stitch side zones onto center), and both "gains" measured
there were traced, on visual inspection, to registration-seam artifacts
fooling the ridge-contrast proxy — not genuine signal. Re-ran both
techniques on this round's fresh captures **strictly per zone** instead:
a single zone's `amb`/`fl` pair is captured with the guide held at one fixed
position (gyro-gated), so there is no registration hop and no seam possible
— the first time either technique has been tested in a domain that
structurally cannot produce that specific confound.

Two candidates, both scored through the real production `afis_print`
pipeline + real local NFIQ2, across all 5 zones × all 3 sessions (15 zone
comparisons):
- **flat-field** (divide by a heavily-blurred version of the same single
  frame, removing large-scale illumination gradient): **0/15 wins, mean
  delta -9.80.**
- **flash-cue** (`fl / (amb+eps)` ratio image — the closest thing to real
  photometric stereo available given only 2 distinct illuminants per zone,
  never true normal-disambiguating multi-light PS): **1/15 "wins", mean
  delta -8.93.**

**The one apparent flash-cue win doesn't hold up under visual check**
(`d6fef37f/right`, flash-cue 76 vs plain-ambient 68): the plain-ambient
side lost because ITS OWN mask came out malformed (a jagged, notched crop —
a segmentation instability on that specific frame), not because flash-cue
extracted better ridge detail. The flat-field losses are genuine ridge
fragmentation on visual check (`3f5b9cd6/delta`: clean dense whorl at 75 →
irregular, top-corner-fragmented print at 49). **Net: 0/15 real wins for
either technique**, and unlike the two previous rounds this is not an
"our test was confounded" result — this is a clean, non-confounded test
with the same clean negative. Consistent with every other denoise-pre-pass/
illumination-correction technique tried this whole project (pyfing, NNS,
coherenceDiff, curriculum-blur restoration) — an extra photometric
processing stage ahead of this pipeline's own tuned Gabor+binarize chain is
not automatically additive, and light/shadow-based correction specifically
has now failed 4 real tests across 2 fundamentally different confound
regimes (cross-zone-registered and per-zone-clean). **Not re-attempting
flat-fielding or a 2-illuminant photometric cue again without a genuinely
different mechanism** (e.g. a real 3rd non-coplanar light source, which
this rig's fixed-position torch cannot provide) — this specific thread is
closed, not just paused.

No code shipped this round beyond the already-pushed `fcca7d6` (analysis +
documentation only).

## Two new ML lines tried, both real negatives: mosaic registration net + curriculum-blur ridge restoration (2026-08-08, round 22)
CTO proposed two training ideas in the same session: (1) a puzzle-piece
registration net for stitching multi-angle captures into a mosaic, and (2) a
curriculum-training scheme using the real NIST SD302 dataset — feed a
ridge-restoration model increasingly-blurred/degraded prints in stages and
train it to reconstruct clean ridges, on the theory this would improve
`pyfingHybrid`'s matchability without sacrificing `freqNorm`'s continuity.
Built and real-GPU-trained both. **Both are real, honest negatives — neither
is wired into production, and per the CTO's explicit call, none of this
session's commits were pushed.**

**`ml/mosaic_register/`** — `TwoCropRegistrationNet` (global-avg-pool ->
regress rigid-transform params (cos,sin,tx,ty) between a reference crop and a
side crop). Two real bugs found and fixed along the way (a units mismatch in
synthetic training-pair generation; a BatchNorm2d NaN-gradient failure on
near-zero-variance batches, fixed via GroupNorm — though the deeper root
cause turned out to be the orientation-loss sqrt-epsilon bug below, found
right after). **Real 200-epoch SageMaker run: val loss frozen at
0.1728-0.1730 across every single epoch — zero learning on the real diverse
dataset.** Root cause diagnosed architecturally, not a tuning problem:
global-average-pooling discards all spatial correspondence between the two
crops before the network ever compares them — it has no mechanism to learn
"where do these overlap." Would need a correlation/cost-volume layer to be
viable at all; not rebuilt this session. Real SageMaker cost: ~$0.03-0.10.

**`ml/ridge_restore_curriculum/`** — `RidgeRestoreUNet` (copied from
`ml/mac3d_enhance/model.py`, GroupNorm not BatchNorm2d, applied preemptively
this time) trained via `degrade.py`'s synthetic pipeline (blur, specular
blowout, low contrast, uneven illumination, noise) ramped in severity over a
curriculum schedule, loss = L1 + SSIM + orientation-field similarity. **Real
bug found via `torch.autograd.set_detect_anomaly`**: the orientation loss's
`norm = sqrt(cs**2+sn**2) + 1e-6` protects the forward value but not the
backward gradient at exactly-zero input — routine on binarized/uniform-region
images (unlike deform_correct's original continuous-tone photo domain, which
never tripped this). Fixed by moving epsilon inside the sqrt (0/150 seeds
NaN afterward, was ~25-40% before). Wired into `afis_print.py` as
`enhance='ridgeRestoreHybrid'` (denoise-pre-pass pattern, same shape as
`pyfingHybrid`/`nnsHybrid`) — **present but NOT added to `main.py`'s
production `_afis_variants`**, same "measured, not shipped" treatment as
`gaborVarFreq`/`fidelity`.

Trained two checkpoints, both measured honestly against real local NFIQ2 on
the same 13-real-capture sample used elsewhere this session (production-
accurate: real `guideRegion` + full ambient/flash burst through
`afis_print.generate()`, scored via the real local NFIQ2 binary):

| variant | mean NFIQ2 (n=13) | wins vs freqNorm |
|---|---|---|
| **native** (plain single frame, no fusion/denoise) | **64.9** | — |
| freqNorm | 54.2 | — |
| ridgeRestoreHybrid **v1** (SD302d only, 300 prints) | 55.7 | 7/13 (54%) |
| ridgeRestoreHybrid **v2** (v1 + 59 real project captures mixed in) | 52.6 | 4/13 (31%) |

v1 barely edges freqNorm — statistically indistinguishable from a coin flip
at this sample size, not a real effect. **v2, the "mix in real capture data
to close the domain gap" iteration, is a clear regression from v1** (mean
-3.1, win rate 54%->31%) despite looking visually better on the single
capture spot-checked before the broader test — plausible cause: the 59 real
crops (looser `guideRegion`-based framing vs SD302's clean scanner captures)
diluted the model's clean ridge-restoration signal without teaching it
anything that transfers, at this small a mixing volume. **Neither checkpoint
comes within 9 points of plain `native`** — consistent with every other
denoise-pre-pass variant tried this project (`pyfingHybrid`, `nnsHybrid`,
`coherenceDiff`): an extra restoration/smoothing stage ahead of this
pipeline's own tuned Gabor+binarize chain is not automatically additive, and
none of the four tried so far have beaten a plain single frame on this
pipeline's real captures.

**Not pushed, per explicit CTO direction**: "do not push if it was a net
negative." Both modules stay local-only (3 commits: mosaic_register,
ridge_restore_curriculum, the unwired `ridgeRestoreHybrid` branch in
`afis_print.py`) — not merged to the remote branch, not deployed.

**CTO's own conclusion, and the real state of this project's fidelity axis
after tonight**: parameter/architecture tuning on synthetic data has hit a
real ceiling — four independent denoise-pre-pass techniques (pyfing, NNS,
coherence-diffusion, now curriculum-blur restoration) and one registration
architecture have all measured negative or noise-level this project. The
missing unlock is not more synthetic-data cleverness; it's **a real ≥500-DPI
ground-truth scanner reference and a beta cohort test group** — matches the
prime directive's own standing diagnosis (no reliable numeric fidelity
target exists yet without better ground truth) and is a CTO-side blocker,
not something further solo ML iteration can substitute for. Do not re-attempt
either mosaic registration (global-pool architecture) or ridge-restoration
curriculum training (this exact data mix) expecting a different result
without changing one of those two root inputs first.

## Sweep-video replaced with sweep-burst stills; minutiae-patch sub-guide candidates added (2026-08-03/2026-08-05, round 21)
CTO asked whether the burst+video hybrid sweep ("prime directive" fusion
architecture) actually works, and — once shown the real Phase 0 data said no
— proposed the direct fix: fire real stills at the start/middle/right sweep
positions instead of extracting frames from a recorded video.

**Real data behind the "does it work" answer**: two of the most recent real
captures with sweep data (`9408bb2a` nfiq2=73, `1febdba7` nfiq2=7) both
showed sweep-video zone frames scoring Laplacian 23-59, vs 311-327 for plain
main-burst ambient stills on the SAME captures — a ~5-6x sharpness gap. Root
cause is structural, not tunable: 30fps video gives each frame only ~33ms
exposure (vs a still's proper exposure time), and H.264 compression further
softens detail relative to an uncompressed JPEG. Zero sweep-video zone
candidates had ever won selection (`wonSelection: true`) across any real
capture checked — mechanically the extraction/scoring loop worked correctly,
it just never had competitive material to work with.

**Fixed by replacing the capture mechanism, not the extraction logic**:
`_captureSweepVideo` (recorded a fixed-duration video while the guide
translated left-to-right, backend seeked to 5 candidate timestamps per zone
and picked the sharpest via Laplacian) is now `_captureSweepBurst` — the
guide still translates through the same left/centre/right positions with
the same real-time-to-react pacing (per-hop `_sweepZoneMoveMs` animation +
`_sweepZoneSettleMs` dwell before each shutter), but a real `takePicture()`
JPEG still fires at each of the 3 stops instead of a video ever being
recorded. Same discipline as every other bounded camera sequence in this
file: the whole 3-zone sequence is wrapped in one `.timeout()`
(`_sweepBurstTimeoutMs`, 18s) since `takePicture()` is an unbounded
platform-channel await, and each zone's shot is ALSO individually
try/caught so one failed zone only costs that one candidate, never aborts
the other two.

**Per-zone guide region, not just per-zone stills**: since the on-screen
guide visibly translates for each zone, the still-space AFIS mask must
translate with it too, or the backend would crop e.g. the left zone's frame
using the centre zone's guide bounds. Rather than hand-derive a second,
easily-drifting copy of the existing BoxFit.cover + 90°-rotation transform
(`_computeGuideRegion`), that transform was factored out into
`_stillSpaceRegionForShape()` and reused by a new
`_guideRegionForSweepZone()` — guaranteed to stay in sync with the main
guide's own derivation since there's only one implementation of the math.
Requires caching `screenSize`/`previewSize` from `start()` (new
`_cachedScreenSize`/`_cachedPreviewSize` fields) since the sweep-burst
capture runs later in `_finishAndUpload`, well after `start()`'s original
call site for this geometry.

Backend (`main.py`): the old `_extract_video_zone_candidates` function and
`_SWEEP_VIDEO_ZONE_TIMESTAMPS_MS` constant (video-seek-and-decode) are
removed outright — no longer reachable now that the client never uploads a
video. The replacement block downloads the 3 real zone stills directly from
`sweepBurstDebug.paths`, scores each through `afis_print.generate()` using
that zone's own `sweepBurstDebug.guideRegions[zone]` (falling back to the
main capture's `guideRegion` if the client couldn't compute one), and
competes via the same `if _zs > afis_nfiq` max-of-variants gate as every
other candidate source in this loop. Firestore fields renamed to match:
client writes `sweepBurstDebug`, backend writes `sweepBurstCandidates`
(was `sweepVideoDebug`/`sweepVideoCandidates`).

**Also same-session**: added minutiae-patch sub-guide candidates (`core`/
`left`/`right`, each a tighter crop of the same already-downloaded main
burst frames — 70% rx/ry centred, and cx-shifted ±35% of rx for the two
delta regions) to `main.py`'s AFIS variant scoring, per the CTO's idea to
use tighter crops of the existing high-res burst to sharpen matchability-
relevant sub-regions without any new capture. Purely additive (same
max-of-variants gate), reuses `_stack_cache` from the main variant loop.
Written to Firestore as `minutiaeDebug` for per-capture validation of
whether any patch ever wins selection.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project: needs a real APK build + real capture to
confirm the sweep-burst stills actually score competitively against the
main burst (the whole point of the fix) and that the per-zone guide regions
crop correctly. Backend changes need their own explicit deploy go-ahead.

## Deep-dive on why the re-verified capture scored lower + adaptive flash EV curve softened (2026-07-24, round 20)
CTO asked why the manually re-verified `3f8fd075` capture (real NFIQ2 64)
scored lower than recent captures like `dadd4ef9` (81) or `03b91b6f` (72),
wanted the full picture (all real sources, not just the winning number),
and asked to keep iterating.

**Root-caused, not assumed.** Real flash-frame pixel stats:
`min=0, max=78, mean=28.3, std=14.1` — a badly UNDERexposed frame (max
brightness only 78/255), not the blown-out-white failure this project's
`_FLASH_DIFF_MIN_FLASH_LAPLACIAN` blowout guard (round 9) was built to
catch. **Confirmed via direct counterfactual**: disabling that guard
entirely and re-running `afis_print.generate()` on this exact real capture
produced the IDENTICAL result (64, still `guide+unet`) — proving the mask
fallback isn't over-cautious here; flash-diff's own accept-gate rejects it
independently, because there's genuinely no usable brightness differential
in near-black flash frames. The lower score is a real content limitation
of this specific capture, not a backend regression from anything shipped
this session.

**Full real layout for this capture** (all sources, not just the winner):
main-camera variants ranged 26-64 (native 64 winning; freqNorm 62; fuseSoft
61; fuseAvg 55; deepMaxc 45; stack 47; deepFuse 41; focusStack 38; fuseMaxc
26). Secondary camera "3" (the "IR" cam): real NFIQ2 39 — worse than main,
did not win. Secondary camera "2": **self-rejected** (`mask covers 67% of
frame — segmentation failed`) — genuinely new information, since this is
the FIRST real content camera "2" has ever produced (see round 18). Its
exposure is fine (mean=84, std=58, healthy dynamic range) — the failure is
framing/segmentation, consistent with the already-documented, never-fixed
gap that camera "2"'s guide was never calibrated to its own (much wider,
2.37mm focal length) field of view.

**Real capture-side fix**: the underexposed flash frame here (evStep
-1.043 applied at intensity=0.6) plus round-16's independent paired
IR-camera finding (main-camera flash frames underexposed at median 30-43
in both real samples checked there) are now TWO real data points showing
the adaptive flash EV curve (`_flashEvMinCut`/`_flashEvMaxCut`, built
2026-07-22 off a single real overexposure case, `cb684c57`) may be
over-correcting toward underexposure. Scaled both endpoints down ~30%
(`_flashEvMinCut` -0.3->-0.2, `_flashEvMaxCut` -1.6->-1.1) — at
intensity=0.6 this now yields evStep ~-0.71 instead of -1.043. **Honest
open risk, stated plainly**: `cb684c57` is the exact real capture that
justified the AGGRESSIVE end of the original curve (Laplacian 15-19 flash
vs 343-395 ambient — real blowout) — softening the curve could reopen
that failure mode on a similarly bright-ambient capture. Needs a real
device test to confirm this doesn't regress, same "one variable at a
time" discipline as every other capture-side change this project.

## Manual post-deploy verification: real capture re-run through the current backend confirms the fix (2026-07-24, round 19 cont.)
Per the CTO's explicit ask to verify the deploy manually rather than wait
for a new physical capture: attempted the strongest possible check first —
minting a real Firebase ID token for `3f8fd075`'s own owner (via Admin SDK
`create_custom_token` + `signInWithCustomToken`) and calling the deployed
`processEnhanceAndScore` callable function directly over HTTPS, exactly as
the app itself would. Blocked by this sandbox's standing egress policy —
`*.cloudfunctions.net` is unreachable, same class of restriction already
documented for the NFIQ2 sidecar's `*.run.app` host (only `*.googleapis.com`
is allowlisted).

**Fell back to the established, session-long verification method**:
downloaded `3f8fd075`'s real raw burst + `guideRegion` from Storage/
Firestore and ran the exact current (now-deployed) `afis_print.generate()`
across the real `_afis_variants` set, scored by the real local NFIQ2
binary — same harness pattern used for every other validation this
session.

**Real result: best variant (native) scored 64 — a legitimate, in-range
NFIQ2 value.** Full spread: native 64, freqNorm 62, fuseSoft 61, fuseAvg
55, deepMaxc 45, stack 47, deepFuse 41, focusStack 38, fuseMaxc 26. Compare
to what the PRE-deploy code actually wrote to this same real capture's
Firestore doc: the impossible `nfiq2Score: 586` that should have been
caught and discarded by the exact fix (`cbc10fe`) that just went live.
This is direct, real confirmation — not just a deploy-timestamp check —
that the deployed pipeline now produces valid, trustworthy scores on real
data instead of garbage.

## Real deployment-gap bug found + fixed: `processEnhanceAndScore` hadn't been redeployed since 2026-07-16 — 14 real backend commits went live at once (2026-07-24, round 19)
Investigating the round-18 capture's impossible `nfiq2Score: 586` (the
same class of bug as the already-fixed `898` case) led to a much bigger
finding: the fix for THAT exact bug (commit `cbc10fe`, 2026-07-17T11:54
UTC) was already correct and already committed — it just had never been
deployed. Confirmed directly via the Cloud Functions v2 API (not
assumed): `processEnhanceAndScore`'s real `updateTime` was
`2026-07-16T21:10:31Z` — matching the stack_cache/70s-budget/300s-timeout
production-hang fix from that day, and predating every backend commit
since. `git log --since` against that exact timestamp showed **14 real
backend commits** sitting undeployed: the nfiq2Score range-validation fix
itself, the segmentation hole-fill fix, the `enhanced_flat.jpg` crop fix,
the stack/focusStack revival, the fuse-pair fallback, the fusion-selection
sharpness guard, and more — essentially this entire session's backend
optimization track. Every real device test since 2026-07-16 evening had
been scored by the OLD backend; the client-side (APK) fixes tested
alongside them were real and live, but none of the backend half was.

**Deployed** (`firebase deploy --only functions:python-pipeline --project
clearbridge-dc699`, CTO's explicit go-ahead) — confirmed via the same
Cloud Functions API that `updateTime` is now `2026-07-24T05:32:38Z`, well
after every pending commit. All 14 backend fixes are live in production
as of this timestamp. **Not yet confirmed against a fresh real capture**
— the next real test will be the first one actually scored by this
session's backend work, including things like the segmentation hole-fill
and stack/focusStack fixes that were previously only validated locally
against the offline harness, never in the real production path.

**Process lesson**: this project's standing discipline has always been
"commit, hold `git push`/deploy until explicit go-ahead" — that worked
correctly for git pushes (confirmed via `git log`/`git status` at every
step), but there was no equivalent real-data check for the BACKEND deploy
side specifically, and it silently drifted 14 commits / 8 days out of
sync without anyone noticing until a real capture's impossible score
forced the investigation. Worth periodically cross-checking
`processEnhanceAndScore`'s real `updateTime` against `git log` when in
doubt, rather than assuming a "Deployed" note in this file's history is
still current.

## Camera "2" completes its full burst for the first time ever; camera "3" confirmed NOT a true IR/mono sensor (2026-07-24, round 18)
Real device test of the round-17 build (commit `020e813`, sweep timeout
28s->34s + the round-16 color-filter-arrangement/flash diagnostics).
Capture `3f8fd075` (2026-07-24T05:09 UTC).

**Camera "2" fully completed its burst for the first time in this
project's entire real-device history.** `secondaryCameraDebug` shows
`2_ok: true` alongside `3_ok: true` — no timeout, no stuck stage. Real
per-shot data confirms both round-15/17 fixes are working together as
intended: `shot_0_focusConvergedMs: 292`, `shot_1_focusConvergedMs: 342`
(fast, genuine reconvergence, same as the previous test), and total
elapsed time for the sweep landed around ~23.7s — comfortably inside the
34s budget where it would have blown the old flat 28s bound purely on
upload time alone. Every prior real test (rounds 3 through 17) had camera
"2" fail at some upload step; this is the first real, clean, complete
success.

**The camera-3 "IR" question from round 16 is now definitively settled,
and the answer is not what the CTO's naming assumed.** Real
`SENSOR_INFO_COLOR_FILTER_ARRANGEMENT` data for all 4 cameras:

| camera | colorFilterArrangement | hasOwnFlash |
|---|---|---|
| "0" (main) | GBRG | true |
| "1" (front) | RGGB | false |
| "2" | GBRG | true |
| "3" ("IR") | BGGR | **false** |

**Camera "3" is a standard Bayer RGB sensor (BGGR), not a true
near-infrared/mono sensor** — same class as every other camera on this
device. The CTO's observed "less flash bleed" is therefore real but NOT a
spectral/NIR effect; it's consistent with the other already-established
explanation (largest sensor of the four, 6.64x4.97mm, more dynamic range,
clips less easily under torch). Going forward this camera should be
thought of as "the big-sensor camera," not "the IR camera" — the naming
was a reasonable guess from the live-preview look, but the real Camera2
data doesn't support it.

**One more real, unexplained-but-benign wrinkle**: camera "3" reports
`hasOwnFlash: false`, yet every real capture shows it clearly torch-lit
(median brightness 117-128/255 in round-16's paired comparison). This
device's torch is evidently a system-level LED control not gated by the
specific active camera's own reported flash capability — not an app bug,
since the illumination demonstrably works in every real capture; just a
device quirk worth knowing if a future diagnostic ever trusts
`hasOwnFlash` as the sole signal for whether a camera can be torch-lit.

Real NFIQ2 score for this capture not yet available at time of writing
(status was still `enhancing`, consistent with this pipeline's own
established 130-180s typical processing time, not a stall) — will follow
up once scored.

## Real device test of the round-15 focus-recheck fix: confirmed working, but exposed camera-2's real upload-time bottleneck — timeout widened for the sweep path (2026-07-24, round 17)
CTO tested the build from round 15 (commit `bf10fa2`, the camera-2 sweep
focus-recheck fix). Real capture `f4a05838` (2026-07-24T04:32 UTC) landed
`status: scored`, `nfiq2Score: 9` (main-camera ambient frame won selection;
flash frames again scored Laplacian ~15 vs ambient's ~237-249, the
recurring torch-blowout pattern; `afisWavelengthPx` pegged at the 20px
measurement ceiling, consistent with the established "held too close"
correlation — not a new finding, no action taken on this axis this round).

**The round-15 fix itself is confirmed real and working**:
`secondaryCameraDebug['2_stageDebug']` shows `shot_0_focusConvergedMs: 304`
and `shot_1_focusConvergedMs: 334` — both real, fast, genuine
reconvergence after each sweep reposition, both comfortably inside the
150-900ms bound. Not the bottleneck.

**But camera "2" still failed** — this time at `shot_1_upload`
(`2_timeout: true`, `2_stuckAt: "shot_1_upload"`), not focus. Real
per-step accounting: pre-loop focus wait (592ms) + shot0 reposition
(1600ms) + shot0 refocus recheck (304ms) + shot0 capture (904ms) +
**shot0 upload (10,936ms)** + shot1 reposition (1600ms) + shot1 refocus
(334ms) + shot1 capture (569ms) = **16,839ms elapsed before shot1's
upload even starts**, leaving only ~11.2s of the flat 28s per-camera
timeout for an upload that, going by shot0's own real number, plausibly
needs ~11s+. Camera "3" uploaded its 3 shots in 6.4-6.8s each on this
same capture — camera "2"'s chronically slow upload (established since
round 3) is the real, dominant cost here, not anything newly broken. The
sweep's own legitimate extra work (2 reposition delays + 2 refocus
checks, ~3.8-5s combined) — all real, deliberate, and each individually
justified — left almost no margin against it.

**Fixed**: widened the per-camera timeout specifically for the sweep path
(camera "2" only) from 28s to 34s — a real, evidence-based number (28s +
the sweep's own added ~5s worst case), not a guess. Every other camera
(including camera "2" on any future non-sweep path, and camera "3") keeps
the original 28s bound untouched, so the ANR-prevention rationale that
bound exists for isn't diluted anywhere it doesn't need to be.

## Camera "3" ("IR") sensor-type diagnostic added — is it real NIR or just a bigger RGB sensor? (2026-07-24, round 16)
CTO observed less flash bleed/specular glare on camera "3" in the live
preview than the main camera. Checked the real, already-established data
first: camera "3" has the largest sensor of all 4 cameras (6.64x4.97mm)
and is already the best-performing, most-reliable secondary camera
(nfiq2Score 72 real win, round 5) — but nothing in the app has ever
queried whether it's a genuine near-infrared-sensitive sensor (weak/no
IR-cut filter, common on rugged-phone "night vision" cameras) vs. just a
bigger, better-tuned RGB sensor that happens to clip less. These two
explanations point at very different follow-up optimizations, so this
needed a real answer, not a guess.

Pulled real paired images (main-camera flash frame + camera-3 torch frame,
same capture) for the two real captures where camera "3" has ever
succeeded (`03b91b6f`, `70d69867`) and ran real pixel stats. Inconclusive
on the "bleed" question specifically: in BOTH real samples, the MAIN
camera's flash frame was actually underexposed (median 30-43/255, zero
clipped pixels) rather than blown out — so there was no real specular-
clipping case in either sample to compare camera "3" against. What IS real:
camera "3" came out meaningfully better-exposed and higher-contrast in
both (median 117-128/255, std 38-59 vs main's std 11-22) — consistent with
either a real sensor advantage (bigger chip, more dynamic range) or a
spectral one (true NIR), not distinguishable from exposure stats alone.

**Fixed the actual gap**: added `SENSOR_INFO_COLOR_FILTER_ARRANGEMENT` (the
one Camera2 field that definitively answers RGB-Bayer vs. MONO/NIR sensor
type) and `FLASH_INFO_AVAILABLE` (whether camera "3" has its own flash
unit, a second real candidate explanation — a different illuminant, not
just a different sensor) to the existing read-only `cameraLensInfoByCameraId()`
query in `MainActivity.kt` — same safe, non-invasive pattern as the two
diagnostics already there (focal length/sensor size/facing), no live
session touched, flows straight through to the capture doc's existing
`cameraLensInfo` field with zero Dart-side changes needed (that map is
already generically deserialized). The next real capture with a working
camera "3" will show definitively whether it's a true NIR sensor (the
bigger, physically-real lever this session's backend specular-suppression
work — both median and trimmed-mean combine swaps — failed to find) or
just a bigger RGB chip.

## Fifth real bug found + fixed: camera-2 distance-sweep shots never re-verify focus after repositioning (2026-07-24, round 15)
With the specular-suppression line closed out (both combine-swap variants
measured negative, see below), switched back to targeted code review rather
than more blind parameter tuning, this time auditing the round-7 camera-2
distance-sweep feature's backend + capture-side wiring — not yet reviewed
since it was built.

Backend side (`main.py`'s `secondaryDistanceScale` lookup) checked out
correctly: the `_torch_(\d+)\.jpg$` filename regex matches the client's
`secondary_${safeName}_torch_$i.jpg` naming, and `shot_{n}_guideScale`
lookup keys line up with what `_captureSecondaryBurst` actually writes — no
bug there.

**Real bug found in `_captureSecondaryBurst`
(`front_capture_controller.dart`)**: `_waitForSecondaryFocusLock` — the
real, measured focus-convergence wait built in round 4 specifically because
this device's secondary cameras are documented to focus slowly/unreliably —
is only ever called **once, before the sweep loop starts**, verifying
convergence at whatever distance the user happened to be at when the burst
began. But the camera-2 sweep then resizes the guide and asks the user to
move to a NEW distance (closer for shot 0, farther for shot 1) before each
shot fires — and that repositioning got only a flat 1600ms delay
(`_camera2SweepMoveDelayMs`) with zero re-verification that focus actually
reconverged at the new distance. Every other focus-dependent step in this
file gets a real measured check; this one relied purely on presumed
continuous autofocus (`FocusMode.auto`) reconverging in time, unconfirmed —
structurally the same class of gap as the round-12 flash-settle-delay bug
(an existing, already-proven wait mechanism applied only at the first state
transition of a sequence that has more than one).

**Fixed**: added an optional `keyPrefix` param to
`_waitForSecondaryFocusLock` (defaults to `''`, so the existing pre-loop
call is unaffected) so its `focusConvergedMs`/`focusScoreAtFire` diagnostic
fields can be written per-shot instead of being overwritten on each call.
Each sweep shot now gets its own bounded re-check
(`minWaitMs: 150, maxWaitMs: 900, keyPrefix: 'shot_${i}_'`) right after the
reposition delay, before the shutter fires — real, measured confirmation
that focus reconverged at the NEW distance, not just a longer blind delay.
Bounded short (900ms max) since the 1600ms move delay already provides real
settle time; this only adds verification on top of it, never replaces or
shortens the existing move delay. Non-sweep secondary-camera cameras (the
`distanceSweepScales == null` path — every camera except "2") are
completely untouched.

**Real, deliberate cost**: up to +900ms per sweep shot (2 shots) if focus
is slow to reconverge — modest against this camera's already-heavier
per-shot budget (1600ms reposition delay already, vs 50ms for other
cameras' fixed-position shots). Cannot regress: if focus reconverges fast
(likely, since continuous AF already had 1600ms), the wait resolves almost
immediately and costs nothing extra in practice.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project; needs a real APK build + real capture on
a device where camera "2" actually completes its burst (still an open,
separate reliability problem — see round 6) to confirm the new
`shot_0_focusConvergedMs`/`shot_1_focusConvergedMs` diagnostics show real
convergence data.

## Specular-suppression idea 1 — median instead of mean stacking: tested, real net negative, NOT shipped (2026-07-24, round 14)
Per the CTO's direct ask ("are there some specular suppression optimizations
we can implement right now?"), first confirmed the backend never receives
color data at all — the client uploads **luma-only**
(`decodeStillJpegToLuma`/`DecodedStillLuma`,
`packages/mac_capture/lib/src/still_jpeg_downscaler.dart`) — ruling out any
classic chromaticity/dichromatic-reflection-model specular removal without a
capture-side change. Two grayscale-domain candidates remained: (1) swap
`_stack_face_on`'s final combine from mean to median (a per-pixel outlier-
rejecting combine — a genuine flash specular highlight should be an
above-baseline outlier at that pixel across the aligned stack), (2) an
explicit specular-highlight detector (bright + locally-smooth pixels
blanked, not inpainted).

**Tested idea 1 first** (monkey-patched `_median_stack_face_on`, same
`_align_face_on_stack` alignment, only the final `np.mean`→`np.median` swap,
run through the `deep`/`deepMaxc`/`deepSoft` variant family across all 17
real captures with usable bursts — same harness pattern as every other
validation this session):

| capture | mean | median | delta |
|---|---|---|---|
| 382cc4b2 | 53 | 50 | -3 |
| 3e54236a | 83 | 72 | -11 |
| 5aa18155 | 69 | 56 | -13 |
| 722ae3b0 | 63 | 79 | +16 |
| 7d7d0162 | 66 | 66 | 0 |
| 913758cf | 60 | 49 | -11 |
| 9bdc9f85 | 66 | 68 | +2 |
| afe5b02c | 58 | 60 | +2 |
| c34911b5 | 73 | 57 | -16 |
| cb684c57 | 51 | 49 | -2 |
| ccb9c85a | 62 | 46 | -16 |
| dadd4ef9 | 51 | 51 | 0 |
| e5cb52fc | 50 | 50 | 0 |
| f2fa606b | 76 | 69 | -7 |
| f382a03a | 64 | 64 | 0 |
| fc619fe8 | 67 | 67 | 0 |
| fcfa2e93 | 75 | 73 | -2 |

**Real net negative: mean delta -3.59, 9/17 regressed vs 3/17 improved, 5
ties.** Not shipped — `_stack_face_on` stays mean-combine, no code change.
**Why, mechanistically**: median across a small stack (n=2-4 same-pose
frames, this pipeline's real burst depth) is a much weaker noise-averaging
combine than mean — it only wins on a capture with a genuine per-frame
specular outlier, and loses the broader noise-reduction benefit mean
provides on every capture that DOESN'T have one. Most of this project's
real bursts apparently don't have a strong enough specular outlier for the
trade to pay off net.

**Tried a softer compromise — trimmed mean** (drop only the single highest
per-pixel value, then mean the rest; falls back to plain mean for n<3),
reasoning it should keep most of mean's noise-averaging benefit while still
rejecting one genuine specular spike. Same 17-capture harness:

| capture | mean | trimmed | delta |
|---|---|---|---|
| 382cc4b2 | 53 | 46 | -7 |
| 3e54236a | 83 | 70 | -13 |
| 5aa18155 | 69 | 71 | +2 |
| 722ae3b0 | 63 | 68 | +5 |
| 7d7d0162 | 66 | 66 | 0 |
| 913758cf | 60 | 35 | -25 |
| 9bdc9f85 | 66 | 68 | +2 |
| afe5b02c | 58 | 64 | +6 |
| c34911b5 | 73 | 70 | -3 |
| cb684c57 | 51 | 54 | +3 |
| ccb9c85a | 62 | 58 | -4 |
| dadd4ef9 | 51 | 51 | 0 |
| e5cb52fc | 50 | 50 | 0 |
| f2fa606b | 76 | 77 | +1 |
| f382a03a | 64 | 64 | 0 |
| fc619fe8 | 67 | 67 | 0 |
| fcfa2e93 | 75 | 72 | -3 |

**Also net negative (mean delta -2.12), though far more balanced (6/17
improved, 6/17 regressed, 5 ties) than pure median.** Almost the entire
negative average is one outlier: `913758cf` (-25) — the exact capture
already flagged elsewhere in this project's history as a fusion-selection
trap (blown-out flash burst, unstable registration; see "Real bug found +
fixed: stack/focusStack..."). Excluding that one capture, the remaining 16
net to roughly a wash (sum -11, mean ≈ -0.7) — trimming still isn't a clean
win even there, just no longer clearly harmful. Not shipped — same
`_stack_face_on` stays mean-combine, no code change.

**Conclusion on the combine-swap approach overall (median + trimmed mean,
both tested)**: neither is a viable specular-suppression lever at this
pipeline's real burst depth (2-4 same-pose frames). Any per-pixel outlier-
rejecting combine trades away too much of mean's noise-reduction benefit
on the majority of captures that don't have a strong specular artifact, and
the one recurring capture that's genuinely hard (`913758cf`, already a
known fusion trap) gets WORSE under both variants, not better — its
problem is unstable registration/alignment, not a specular outlier a
combine-level fix can address. Not pursuing an explicit specular-highlight
detector (candidate idea 2, bright+locally-smooth pixel blanking) further
right now either — it would face the same fundamental small-n problem
(rejecting a frame's contribution at a pixel still costs noise-averaging
benefit there) plus real tuning risk on this project's own already-
documented "don't tune blind on a handful of noisy captures" lesson. The
capture-side flash-transition settle-delay fix (round 12, attacks specular
risk at its root by giving the sensor time to re-converge exposure) remains
the higher-value real lever for this problem, not a backend combine change.

## _STACK_MAX sweep (4 vs 8): tested, no real gain, left as-is (2026-07-24, round 13 cont.)
Quick follow-up to the `stack`/`focusStack` revival: those variants cap at
`_STACK_MAX=4` same-pose frames even when the burst-fallback can supply up
to 8. Tested raising the cap to 8 across all 18 real library captures
(real production single-frame selection + burst fallback, matching the
revival fix's own validation setup). **Net negative**: mean delta (max8 -
max4) = -1.33; 5 captures regressed, 3 improved, 10 unaffected (bursts
with <=4 usable frames don't reach the cap either way). Left
`_STACK_MAX` at 4 — no change made. Fourth "plausible-sounding tuning
idea, measured, refuted" result this session (after the ambient-vs-flash
frame-priority swap, the deepFocus fusion variant, and now this) — a real,
consistent signal that backend NFIQ2-side tuning has hit diminishing
returns for now, distinct from the four real structural bugs fixed
earlier this same round.

## deepFocus* variant (focus-stacked deep fusion): built, measured, NOT wired into production (2026-07-24, round 13)
CTO asked whether same-pose fusion (the biggest existing NFIQ lever —
`deepFuse`/`deepMaxc`/`deepSoft`) could be optimized further. Found one
real, previously-untried combination: `deep*` always flat-averages each
illumination's burst (`_stack_face_on`) before fusing ambient+flash,
never the sharpness-weighted `_focus_stack_face_on` (already proven
separately — see the earlier `stack`/`focusStack` revival — to recover
detail a flat average smooths over). Built `deepFocusAvg`/`deepFocusMaxc`/
`deepFocusSoft` in `afis_print.py`: identical to `deep`/`deepMaxc`/
`deepSoft` except the per-illumination stack uses focus-stacking instead
of flat averaging (own separate `stack_cache` key, since it needs a
different intermediate result).

**Measured honestly on all 17 real library captures — net NEGATIVE, not
a win.** `deep*` mean best = 63.9, `deepFocus*` mean best = 62.2; 11/17
captures regressed, only 6 improved (a few real individual wins:
`382cc4b2` +20, `c34911b5` +5, but the average moved the wrong way).
Same lesson as `nnsHybrid`/`coherenceDiff` underperforming despite each
combining independently-proven pieces — two good techniques don't
automatically compose.

**Deliberately NOT wired into `main.py`'s production `_afis_variants`**,
for two independent reasons: the negative average result, and a real
compute-cost concern -- `deepFocus*` needs its own separate ECC-alignment
stacking pass (can't share the `deep*` family's cache, since it needs the
sharpness-weighted intermediate, not the flat-averaged one), which would
roughly double the exact expensive step that once caused a real production
outage (a capture stuck at `status: enhancing` forever, fixed 2026-07-16 by
caching `_stack_face_on` across the `deep*` family specifically to avoid
redoing it 3x). Code stays in `afis_print.py`, self-contained and unused
unless explicitly called — same "measured, kept as an available scaffold,
not shipped" treatment as `gaborVarFreq`/`fidelity`/`gaborPyfingField`.

## Capture-side: asymmetric flash-transition settle delay (2026-07-24, round 12)
CTO asked whether there were more iterations to make on the capture side
specifically (app, not backend). Line-by-line review of `_fireBurst`
(`front_capture_controller.dart`) — the main 8-shot alternating burst,
not deeply audited this session even though several nearby pieces were
touched — found a real timing asymmetry: the flash-ON transition
(`_flash!.activate()` + raising the EV offset) gets an explicit
`_burstFlashSettleMs` (70ms) delay before its shot fires, but the
flash-OFF transition (`_flash?.deactivate()` + EV dropping back to base)
went straight into `takePicture()` with zero settle time. In **normal
mode** (the common case — `AdaptiveFlashController`'s docstring confirms
pitch-dark keeps the torch on continuously with `deactivate()` a no-op,
and bright mode skips the torch entirely, so this only matters for the
in-between "normal" ambient luma range most real captures fall into), the
torch genuinely toggles on/off every other shot across the whole burst —
if the sensor needs real settle time to re-converge exposure after either
direction of that change (which is exactly why the activate side already
waits), every other "ambient" shot in the burst could be captured while
still influenced by the prior flash frame's EV state.

**Fixed**: same `_burstFlashSettleMs` delay now applies on the way back
down too — but only when the immediately preceding shot in the loop
actually fired the flash (`wasFlashLastShot`), not just "this slot is
nominally ambient". Needed care here: a naive `i > 0` gate would have
added the delay to EVERY shot in bright/torch-incapable mode (where flash
never activates at all, so there's nothing to settle from) — tracked the
real previous-shot state explicitly instead. Real, deliberate cost: ~3
extra 70ms delays per 8-shot burst in normal mode (~210ms total).

**Not device-tested** — this is a live-camera-hardware timing question
(does the sensor genuinely need settle time on the flash-off transition,
and does 70ms cover it), which can't be validated against static
downloaded JPEGs the way the backend fixes this session were — needs a
real APK build + real capture to confirm, same standing discipline as
every other capture-side change this project.

## Fourth real bug found + fixed: `enhanced_flat.jpg` unnecessarily cropped 75% on every front_only_v1 capture (2026-07-24, round 11 cont.)
Dispatched an Explore agent for a fresh code-review pass (my own manual
review had already covered `afis_print.py` heavily this round) over
`sfm_pipeline.py`'s flash-diff segmentation and `main.py`'s proxy-scoring
path, looking for the same class of bug as the three above. It surfaced
3 candidates; checked each against whether it's actually reachable by
front_only_v1 (this project's only active capture mode) before spending
any validation effort:

- **`sfm_pipeline._segment_via_flash_diff` never got the blown-out-flash
  guard I added to `afis_print.py`'s copy of this check** — real bug, but
  confirmed via direct trace (`main.py:470-520`) that front_only_v1
  explicitly raises `CaptureQualityError` before `reconstruct_and_unwrap`
  (and its failure-fallback's own `_segment_and_locate` call) is ever
  reached — both call sites are structurally unreachable from the active
  capture mode. Real, worth porting if arc_sweep/oscillating_8phase are
  ever revived (both currently discontinued/dropped per this project's own
  standing decisions) — not actioned now, no real captures from those
  modes locally to validate against.
- A related `NORM_MINMAX`-stretch gap inside the same function — same
  unreachability, same disposition (documented, not actioned).
- **`_score_nfiq`'s coverage-aware crop (`main.py:1845`,
  `crop_frac = max(0.75, sfm_coverage**0.5 + 0.05)`) fires unconditionally
  on every front_only_v1 capture** — confirmed real and reachable: this
  project's own front_only_v1 code passes a HARDCODED sentinel
  `sfm_coverage = 0.35` ("non-zero so downstream quality gates pass" —
  never a real coverage measurement, since front_only_v1 skips SfM
  reconstruction entirely), which always lands below the crop function's
  0.75 floor. The crop's own stated purpose — stripping gap-filled KDTree
  periphery noise from a real SfM reconstruction — cannot apply to
  front_only_v1 at all, since `enhanced` there is just a plain center-crop
  of the raw frame with zero gap-filling. Net effect: `enhanced_flat.jpg`
  (a real saved artifact) and the Henry-classification input were losing
  ~44% of their area on every single front_only_v1 capture, for a reason
  that never applied to this capture mode.

**Fixed at the one real call site** (`main.py`, the "4. NFIQ Scoring"
stage): pass `sfm_coverage=1.0` for `is_front_only` instead of the
misleading 0.35 sentinel — matching how every AFIS-path `_score_nfiq` call
already passes 1.0. **Not numerically re-validated locally**: real NFIQ2
rejects raw/unenhanced frames outright ("Fingerprint area is too small" —
confirmed directly, tried scoring a raw center-square frame), so testing
this would require reproducing the full NNS enhancement pipeline first,
which isn't worth the effort for a fix to a SECONDARY artifact (AFIS
already wins the primary `nfiqScore`/`nfiqPass` decision on effectively
every real front_only_v1 capture seen this whole project — this fix can't
change that). Shipped on the strength of the logical argument instead: the
crop's own stated premise is provably inapplicable here, so this can only
recover real content that was being needlessly discarded, never truncate
something that should stay cropped.

## Tested and REJECTED: ambient-vs-flash frame priority in `_download_front_only_frames` (2026-07-24, round 11 cont.)
Same round's code review turned up a third candidate: `_download_front_only_frames`
always prefers the sharpest AMBIENT frame over any flash frame whenever
one exists, never actually comparing their client `laplacianScore`s. This
looked like the same class of bug as the two fixes above (an unconditional
priority silently discarding better raw material). Checked real Firestore
per-frame `laplacianScore` data across the library: **5 of 18 real
captures would have their selection flipped** by comparing scores directly
instead of defaulting to ambient (`7d7d0162`, `9bdc9f85`, `f382a03a`,
`fc619fe8`, `fcfa2e93`).

**Built the fix, then measured it on those exact 5 captures before
trusting it — and the real data refuted it**: only 1/5 improved (`7d7d0162`:
+18 real NFIQ2), the other 4 REGRESSED (`9bdc9f85`: -2, `f382a03a`: -12,
`fc619fe8`: -13, `fcfa2e93`: -4). Net negative. Consistent with this
project's own already-documented finding that the CLIENT laplacianScore is
an unreliable whole-preview-frame proxy (`afis_print.py`'s own
`_ridge_energy` comment: "observed identical across a burst... can't
distinguish the sharp still from a soft one") — reading numerically higher
for flash on these captures didn't mean the flash frame was genuinely
better material. **Reverted** — ambient-preferred stays the correct
default, left a comment documenting the real numbers so this exact swap
isn't re-attempted blind by a future session. This is the discipline this
whole project runs on: a plausible-sounding fix still needs a real-data
check before it ships, and this round is the case where that check said no.

## Second real bug found + fixed same round: `fuseAvg`/`fuseMaxc`/`fuseSoft` can also go fully dead on a single failed pair (2026-07-24, round 11 cont.)
Same root cause as `stack`/`focusStack` above, different symptom: for
front_only_v1, `ambient_frames`/`flash_frames` are each length 1 (the one
client-laplacian-selected pair), so when THAT one pair fails to register/
fuse (`_fuse_flash_ambient`'s ECC step failing, or the correlation guard
rejecting it), `fuseAvg`/`fuseMaxc`/`fuseSoft` have no other pair to try
and return `None` entirely — confirmed on 2 real captures this round
(`847fa2d3`, `5aa18155`, both showed all three fuse variants as `None`
under real production single-pair selection).

**Fixed the same way, additive-only**: the ORIGINAL single pair is still
tried FIRST, exactly as before — only if it fails does the code now try
additional same-pose pairs built from the raw preserved burst
(`ambient_burst`/`flash_burst`, already downloaded, ranked by ridge
energy). Since the primary pair always wins when it works, this can only
ever recover an already-guaranteed-`None` result, never change a
currently-succeeding one.

**Validated on 12/18 real library captures** (another container restart
cut it short, not needed — already unambiguous): of the 10 with a known
pre-fix baseline, **9/10 match their old value exactly (zero regressions
confirmed)**, and **1/10 (`5aa18155`) went from `None`/`None`/`None` to
real 58/59/72** — `fuseSoft`'s 72 is the best real score seen for that
specific capture across every test this session. The other 2 fresh
captures checked: `cb684c57` got real values (50/64/48), `ccb9c85a`
correctly stayed `None` (no pair registers at all — a genuine content
limitation on that capture, not a bug).

Committed alongside the stack/focusStack fix, not yet pushed (standing
process rule).

## Real bug found + fixed: `stack`/`focusStack` were structurally dead for front_only_v1, this project's own active capture mode (2026-07-24, round 11)
Per the CTO's ask to keep hunting for backend bugs/optimizations using the
real capture library, code-reviewed `afis_print.py`/`main.py`'s frame-
selection path (not blind parameter tuning) and found a real, previously
unnoticed bug: `_download_front_only_frames` (`main.py`) collapses the
whole 8-frame burst down to exactly ONE pre-selected ambient + ONE
pre-selected flash frame (by client-reported `laplacianScore`, always
preferring ambient) **before** `afis_print.generate()` ever runs. But
`main.py`'s own `_afis_variants` list runs `stack`/`focusStack` on every
single front_only_v1 request — and both require >=2 same-pose frames to
do anything (`generate()`'s stacking logic operates on `frames`, which is
always length 1 here). **Both variants were guaranteed to return `None`
on literally every real front_only_v1 capture this project has ever
scored** — two of eleven production variants, silently burning request
time for zero benefit, every time.

Confirmed via a real sweep of the full local capture library (before vs.
after, real local NFIQ2 — same calibrated binary used throughout this
session): a naive fix (feed the FULL burst into every variant, replacing
the single pre-selected frame everywhere) was NOT a clean win — 4 real
gains, several ties, but a real -4 regression on `913758cf` (the exact
capture already flagged in this project's history for a fusion-selection
trap: fuseMaxc/fuseSoft's registration genuinely degrades with different
candidate framing on that specific bad-flash capture). Reverted the naive
version.

**Fixed narrowly instead**: only `stack`/`focusStack`'s own frame source
now falls back to the raw preserved same-pose burst (`ambient_burst`/
`flash_burst` — already downloaded for every front_only_v1 request to
feed `deepFuse`, so no new download needed) when the primary single-frame
list can't supply the >=2 frames needed. `native`/`freqNorm`/`fuseAvg`/
`fuseMaxc`/`fuseSoft`/`deepFuse`/`deepMaxc` are completely untouched — so
this can only ever promote an already-guaranteed-`None` result to a real
one, never regress a capture the old code already handled correctly (same
"can only add a candidate" discipline as every other addition to this
max-of-variants pipeline).

**Validated on 17 of 18 real library captures** (container restart cut
the 18th short, not needed — the result is already unambiguous):
**17/17 now produce real, non-None `stack`/`focusStack` output** (was
0/17 before this fix — a 100% dead-code confirmation). In 11 of 17, the
newly-unlocked variant beats plain `native` outright, several by a wide
margin (`5aa18155`: native 22 -> 69, +47; `722ae3b0`: 35 -> 59, +24;
`847fa2d3`: +15; `7d7d0162`: +14; `dadd4ef9`: +13; `c34911b5`: +12).
Since this only adds candidates to the existing max-of-variants pool, it
cannot lower any capture's result — the captures where stack/focusStack
scored below native simply mean native (or another untouched variant)
still wins there, exactly as before.

Committed, not yet pushed (standing process rule). Not yet deployed or
device-tested — same discipline as every other backend change this
project makes.

## Local rebuild of `dadd4ef9` with the segmentation fix: real trade-off found, not a clean win (2026-07-23, round 10)
Per the CTO's ask ("rebuild the 81% print but even better"), pulled
`dadd4ef9`'s full real raw burst (8 main-camera frames + all 3 secondary
camera-3 frames) and re-ran it locally through the just-fixed
`afis_print.generate()` across every available variant, scored by the
real local NFIQ2 binary (calibrated to match production).

**Honest result: could not reach 81 locally, and the reason is fully
explained, not a mystery.** Best achievable with the segmentation fix
applied is **71** (`native`, guide-only mask — no content-aware refinement
engaged at all, since this capture's flash burst was too blown out for
flash-diff and the U-Net fallback scored lower). Production's real 81 came
via `afisMask: "guide+flashdiff"` — the exact buggy, holed mask fixed last
round. Root cause of the gap: that buggy mask's real shape happened to crop
down to `afisWavelengthPx=13.0` (inside this project's own established
9-14px NFIQ2 sweet spot), while EVERY correctly-functioning mask option on
this same raw capture (guide-only, U-Net-refined) lands at `wl=16.0`
instead — a real property of how this particular capture was framed, not
an artifact of which mask option is chosen. The bug's own hole/jagged crop
was accidentally cropping into the higher-wavelength periphery in a way
that (per NFIQ2's own well-documented foolability) scored better without
being a more faithful print. The flash burst itself was unrecoverable —
all 4 flash frames scored Laplacian 17-20 (fully blown out), so no
fuse/deepFuse variant had usable flash content to work with, and the 3
real secondary camera-3 frames all self-rejected (U-Net segmentation
covered 82-96% of frame — no usable pad boundary found in a plain, no-
guide-region crop of those specific frames).

**Guide-only (71) beat the U-Net-refined result (69, `coherenceDiff`) on
this specific capture** — worth noting since it means the "unet" fallback
isn't automatically better than no refinement at all when a capture's
flash-diff signal is unusable; not changed as a global default off one
real data point, same discipline as everywhere else, but worth watching
on future similarly-blown-out captures.

**Sent the CTO the guide-only/native rebuild (71, clean smooth boundary,
no hole, no jagged edges — visually matching the reference image's clean
look)** rather than chase the higher-but-defective number. This is the
honest trade-off of the round-9 fix: it can't invent ridge detail a
capture's own raw material doesn't have, and a correct mask sometimes
scores lower than a broken one on NFIQ2 specifically because NFIQ2 doesn't
penalize the defects a correct mask avoids — consistent with this
project's own long-standing "NFIQ2 is foolable, don't optimize it blind"
finding. No code changed this round (analysis only, scratchpad-side).

## Real segmentation bug found + fixed: blown-out flash frame corrupts the flash-diff mask, punches a real hole in the print (2026-07-23, round 9)
CTO flagged a visible segmentation defect in the `dadd4ef9` (nfiq2Score 81)
superprint sent last round — a jagged, "toothed" boundary plus a real
squarish hole/notch bitten out of the ridge area — and separately said
ridge continuity looked worse than usual, attaching a comparison image
with a smooth boundary and no such defect. Investigated by pulling
`dadd4ef9`'s real Firestore doc rather than guessing.

**Root cause, confirmed from the doc's own data**: `superprintParams.afisMask
= "guide+flashdiff"` — this capture's mask came from `_flash_diff_mask()`
(flash-minus-ambient differencing, `afis_print.py`), intersected with a
1.3x-dilated guide bound. But `dadd4ef9`'s ENTIRE flash burst was severely
blown out — Laplacian 17.2-19.8 across all 4 flash frames vs 232-245 on the
matching ambient frames, the same recurring torch-blowout pattern documented
repeatedly throughout this project. `_flash_diff_mask` always used the
first ambient/flash pair with zero exposure check. A saturated/clipped
flash frame has almost no local brightness gradient left in the near-camera
region — exactly the cue the torch-falloff differencing depends on — so it
produced a noisy, patchy diff mask instead of a clean pad-shaped blob. That
noise passed straight through the existing accept-gate (which only checks
overall AREA, 0.35-0.92 of bound, never smoothness/holes) and became a
literal, permanent hole in the final print: `afis_print.py` hard-masks
everything outside the mask to white (`binimg[mask == 0] = 255`), so a false
"not pad" region isn't just a boundary artifact — it's real ridge-bearing
pad area that got thrown away entirely. **This is very likely the same root
cause as the "ridge continuity looks worse" complaint, not a separate
issue** — a hole punched straight through real ridge structure, plus the
jagged boundary breaking ridge strokes wherever it crosses them, reads
exactly like a continuity problem even though the underlying ridges
themselves were probably fine.

**Fixed, two layers** (`afis_print.py`):
1. **Blowout guard in `_flash_diff_mask`**: computes the flash frame's own
   Laplacian variance before trusting it for differencing; skips any pair
   below `_FLASH_DIFF_MIN_FLASH_LAPLACIAN = 50.0` (comfortably above every
   confirmed-blown-out real flash score this project has seen — 17-90 range
   — and comfortably below legitimately sharp captures, hundreds+), trying
   the next burst pair if any. If every pair is blown out (as in
   `dadd4ef9`), returns `None` and falls through to the U-Net mask (or bare
   guide) — both smooth, both already-safe existing paths.
2. **`_fill_mask_holes()`**: a new belt-and-suspenders helper, applied to
   `pad_mask` right after it's obtained (both the flashdiff and U-Net
   paths) — flood-fills from a corner to find true background, then fills
   anything NOT reached (real foreground OR an enclosed hole) back in. Can
   only recover area already inside the detected pad shape, never grow past
   it or remove real foreground — can't regress an already-clean mask,
   catches the same failure mode even from a non-blowout noise source.

Verified the hole-fill logic standalone (synthetic mask with a punched
rectangle: 4584px -> 5025px after fill, hole recovered). Not yet re-run
against a real capture — same standing discipline as everywhere else in
this pipeline, needs a real device test with a similarly blown-out burst to
confirm. The already-scored `dadd4ef9` doc itself can't be retroactively
fixed by this change; the benefit is on the next real capture that hits the
same blowout condition.

**TAR on the `dadd4ef9` print, asked directly**: no honest TAR percentage
exists for this print, or for anything in this project's real history (the
round-7 handoff audit already confirmed zero "TAR%" figure appears anywhere
in CLAUDE.md/docs). TAR is a population-level metric requiring many real
genuine AND impostor comparisons at a fixed decision threshold — it cannot
be computed from one print. What IS real: ran the actual SourceAFIS
matcher (the project's own established fidelity gate) between `dadd4ef9`'s
superprint and the CTO's ink scan directly (`scratchpad/sourceafis`,
locally built, `.m2` cached) — **score 0.00** (mirrored orientation: 0.00
one direction, 2.19 the other) — far below SourceAFIS's own practical
match threshold (~40). Contextualized against the same ink scan's
established noise floor: the CTO's own previously-confirmed genuine
captures (`3e54236a`/`c34911b5`/`382cc4b2`/`722ae3b0`) score 0.00-10.60
against this same scan, and unrelated impostor captures score in a
similar 0-10.6 range — this single low-quality ink scan has never been able
to separate genuine from impostor (the project's own long-standing
"noise floor" finding, unrelated to this specific print). **A 0.00 score
here does not mean this print doesn't match the real finger** — it means
the whole measurement is underpowered given the current ground truth, same
caveat as every other real match number in this project's history. A real
TAR needs a proper paired dataset (RidgeBase) or a real ≥500-DPI reference
scan — both still-standing, CTO-side blockers, not something computable
from what exists today. Separately, the segmentation hole found above is a
plausible real contributor to this specific 0.00 (real minutiae structure
was destroyed in that hole region) — but the noise-floor caveat likely
dominates regardless.

Committed, not yet pushed (standing process rule).

## Splash duration extended 6.5s → 9.0s (2026-07-23, round 8)
CTO real-device feedback: "it's too fast right now." Rescaled every beat
timestamp in `splash_screen.dart` by the same uniform factor (9.0/6.5 =
18/13) used to build the 6.5s version from the original 13.0s JSX
reference in the first place — not a re-tuned guess, so relative
proportions between beats stay exactly what the reference intended, just
stretched to a slower, more readable pace. Also caught and fixed 4
continuous (sin/modulo-driven) animations — the badge-dot pulse, the ring
pulse, its fingerprint-icon breathing scale, and the "tap to continue"
opacity pulse — that convert the file's own compressed `t` back to the
JSX reference's 13.0s timeline via a hardcoded `t*2` (correct only for the
old 6.5s duration, since 13/6.5=2); replaced with a named
`_refTimeScale = 13.0/_totalS` constant so these stay correct
automatically if the duration is ever rescaled again. Not yet
device-tested.

## Handoff audit + camera "2" distance-sweep feature (2026-07-23, round 7)
CTO sent an external "5-day sprint" handoff doc and asked it be audited
against the real codebase before any implementation. Dispatched 3 parallel
Explore agents to verify every specific technical claim rather than trust
or blindly implement it. **Result: several factual premises did not match
the real codebase, though the underlying mechanisms it pointed at do exist
under different names:**
- `augmentedCircleService.dart` does not exist — real file is
  `packages/mac_capture/lib/src/capture_pad_silhouette_overlay.dart`,
  class `PadSilhouetteShape` (`defaultShape`: cx=0.5, cy=0.37,
  rx=0.166175, ry=0.137275, taper=0.20 — already tuned twice, 2026-07-18
  and 2026-07-20/22). `_scoreRoi` in `front_capture_controller.dart:296`
  is a **manually-kept-in-sync copy**, not computed at runtime — any future
  guide re-tuning must update both or they'll silently drift apart.
- `ContinuousCaptureProvider` does not exist — real class is
  `FrontCaptureController`. The `0.45` focus threshold exists in **two**
  places: the primary hold-phase gate (`front_capture_controller.dart:647`)
  and the just-built secondary-camera `_waitForSecondaryFocusLock`
  (`:1498`) — two independent thresholds, not one.
- `CameraService.initializeCamera()` has **no exposure logic at all** —
  adding EV there would be new work, not an extension. The real, already-
  validated adaptive-EV mechanism is `_adaptiveFlashEvStep()` in
  `front_capture_controller.dart`, using `setExposureOffset()` (safe),
  interpolating -0.3 to -1.6 by torch intensity (shipped as an unvalidated
  "first-cut curve"). Also surfaced a real discrepancy worth a future look:
  `setExposureMode()` (the documented torch-blocking Camera2-interop
  landmine) **is** called once, in `oscillating_capture_controller.dart:611`
  — contradicting CLAUDE.md's prior "never called" note, though that path
  isn't part of the active front-only flow.
- Current burst is **8 frames (4 ambient + 4 flash, alternating)**, not the
  handoff's "5-frame (current)" claim (`_burstFrameCount = 8`,
  `front_capture_controller.dart:169`).
  Any future burst-count experiment must also account for this project's
  own ANR history: bumping the secondary-camera burst 1→3 shots previously
  caused real timeout/ANR failures until the per-camera timeout was widened
  12s→28s — a burst-count increase is not free.
- No "50% TAR on 26-capture set" baseline figure exists anywhere in this
  project's real documented history (grepped CLAUDE.md + all 4 docs/*_SCOPE
  files — zero matches). Every real 26-capture result uses mean-score /
  "X of 4 genuine beat impostor max" framing instead — any future TAR
  re-measurement should be framed the same way to be comparable to history.
- No manual, ruler-measured, fixed-physical-distance testing protocol
  exists anywhere in project history — every prior "capture distance"
  effort was the in-app live-guide feature (`distanceStage2` →
  `ambientClose`/`flashFar`, the one just retired this session at 0/18
  all-time real reach rate).

**CTO's actual ask, once the audit surfaced this**: narrower than the full
handoff — build a distance-varying guide for **camera "2" only** ("use the
mask opening to gauge user distance so it can go from closer to further
away"), not the whole 5-day sprint. Built exactly that, not the handoff's
generic multi-distance feature: `_camera2DistanceSweepScales = [1.15,
0.85]` (bigger guide first = closer, per this project's own established
"bigger guide pulls user closer" finding; smaller guide second = farther),
threaded into `_captureSecondaryBurst` via a new optional
`distanceSweepScales` param — only camera "2" (`desc.name == '2'`) passes
it; every other camera's behavior is byte-for-byte unchanged. Reuses
`PadSilhouetteShape.scaled(factor)` (already existed, survived the round-6
ambientClose/flashFar removal since it's a general-purpose shape helper,
not feature-specific) and the `force: true` fix already proven necessary
this session for guide-resize visibility (`_apply`'s 80ms throttle
otherwise silently drops a resize mid-burst). Each sweep shot gets a real
1600ms move-delay (`_camera2SweepMoveDelayMs`) with a haptic pulse and a
`distanceHint` banner ("Move closer" / "Move back slightly") — genuine
time to reposition, unlike the other cameras' 50ms inter-shot gap, which
is tuned for a static thumb.

**Deliberate, real side benefit**: dropped camera "2"'s burst from 3 shots
to exactly 2 (one per sweep position) — camera "2" has died at shot index
2 (the 3rd shot's upload) in every real test to date (round 3-6 notes), so
this also sidesteps that exact failure point, directly addressing the
round-6 pending "cut camera 2's burst 3→1 to raise completion odds"
suggestion, just landing at 2 instead of 1 so the sweep still has two real
distance points to compare.

**Backend diagnostic added** (`main.py`, secondary-camera scoring loop):
when a camera-2 sweep frame wins that camera's own internal Laplacian
comparison, the winning shot's filename (`secondary_2_torch_N.jpg`) is
matched back to `secondaryCameraDebug['2_stageDebug']['shot_N_guideScale']`
already on the capture doc, and recorded as `secondaryDistanceScale` in
`afis_params` — so once camera "2" actually completes a real capture, the
next real Firestore doc will show which distance (closer vs. farther) the
sharpest secondary frame was captured at, giving the CTO's "wide catches
more edge ridge" hypothesis its first real per-distance data point instead
of none.

**Not yet device-tested** — same standing discipline as every other
capture-side change this project. The rest of the original handoff (input-
resolution validation, general guide re-tuning, EV sweep, focus-threshold
sweep, general burst-count sweep, end-of-week TAR re-measurement) was
**not** built — the CTO's actual ask this round was scoped specifically to
the camera-2 distance-sweep feature above, not the full 5-day sprint.

## ambientClose/flashFar retired; camera "2"/"3" real physical-spec comparison (2026-07-23, round 6)
CTO decision: retire ambientClose/flashFar outright (0/18 all-time real
reach rate — see round 5). Removed cleanly from both sides: app-side the
two bonus-stage blocks, the dead "switch back to main camera" handoff that
only existed to serve them, `_waitForDistanceZone`/`_captureDistanceBurst`,
the direction/illumination enums, and the shape/target constants;
backend-side the corresponding `ambientCloseFrames`/`flashFarFrames`
scoring loop in `main.py` (dead weight once the client stops writing those
fields). Secondary-camera capture and the main burst are untouched.
Committed (`0cbfdb1`), not yet pushed.

**CTO hypothesis on camera "2" ("Wide Cam," believed possibly the best
camera for ClearBridge) checked against real data, not accepted at face
value.** Camera "2" does have the shortest focal length of all four
cameras (2.37mm vs main's 4.15mm) — consistent with being a wider-FOV lens,
which fits the CTO's read. But it ALSO has by far the smallest sensor
(3.92×2.94mm vs main's 5.98×4.49mm) — consistent with a lower-spec
auxiliary/macro sensor, not a premium wide lens. More importantly: camera
"2" has **never once completed a successful capture** across all 4 recent
real tests — always stalls at the exact same step (`shot_2_upload`) — so
there is currently **zero real captured/scored print data** to evaluate its
actual quality. The CTO's "looks like more quality" read is from the live
preview feed, not a completed capture; recommended not trusting that over
real captured data until camera "2" can actually finish a burst.

**Camera "3" (functionally the CTO's "IR," since they attribute "wide" to
"2") has the largest sensor of all four cameras (6.64×4.97mm, bigger than
main) and just delivered the first real, non-proxy-fooled secondary-camera
win this whole project (round 5, nfiq2Score 72, visually confirmed clean
print)** — no reason to retire it; it's the strongest secondary-camera
result to date.

**Optimization suggestions given, not yet built (pending CTO go-ahead):**
reduce camera "2"'s burst count 3→1 (it always dies on shot 2's upload
specifically; fewer shots raises its odds of actually completing and would
finally produce real print data to test the "wide catches more edge ridge"
hypothesis empirically); now that ambientClose/flashFar are retired,
there's freed time budget in `capturingExtra` that could absorb this
without net-lengthening the whole flow; flagged that this test's main-
camera burst was itself unusually weak (Laplacian 19-24) and camera "3"
saved the capture — real, quantifiable evidence the multi-camera safety net
has genuine value, an argument for investing further in camera "2"'s
reliability rather than dropping it.

## Real device test of the focus-convergence build: first genuine secondary-camera win (nfiq2Score 72), stageDebug-merge bug found + fixed (2026-07-23, round 5)
CTO tested the build with the focus-convergence fix (`6b6b606`). Real
capture `03b91b6f` (2026-07-23T18:03 UTC) scored **nfiq2Score 72** via
`afisSource: "secondary_3"` — the **first real, non-proxy-fooled win for a
secondary camera** in this project's history (the one prior secondary-
camera win, `70d69867`, was a proxy-fooled false positive with real
nfiq2Score 6). Downloaded and visually confirmed both the raw secondary
frame (thumb well-centered, in focus) and the resulting `superprint_afis.png`
(clean, dense whorl) — a real, legitimate result, not an artifact.

**Why this matters**: the main camera's own burst was unusually soft this
capture (ambient Laplacian only 19-24, flash 31-36 — both far below typical
good captures, and for once flash wasn't even worse than ambient). The
secondary camera saved the capture. This is the first real demonstration of
the CTO's original multi-camera vision actually working: when one camera's
capture is weak, another camera's data can still win.

**New `cameraLensInfo` diagnostic (shipped last round) paid off immediately**:
camera "2" (the one that times out almost every capture) has a much smaller
sensor (3.92×2.94mm) and shorter focal length (2.37mm) than the main camera
(5.98×4.49mm, 4.15mm) — consistent with being a lower-spec auxiliary/macro
sensor, plausibly explaining its consistently slower encode/upload pipeline.
Camera "3" (the consistently reliable one, and this test's winner) has the
**largest** sensor of all four cameras (6.64×4.97mm, even bigger than main).
Camera "2" **still timed out at the exact same step** (`shot_2_upload`) for
the 4th real capture in a row — now a very strong, reproducible signal
pointing at that specific weak sensor's own upload/encode speed, not
intermittent flakiness.

**Real bug found + fixed**: the per-camera `stageDebug` map (carrying the
last two rounds' new diagnostics — `focusConvergedMs`/`focusScoreAtFire`,
per-shot `captureMs`/`uploadMs`) was only ever read for its single `'stage'`
key on timeout; every other field was silently discarded regardless of
outcome, so none of those new diagnostics actually reached this test's
Firestore doc. Fixed: the whole map is now preserved under
`'<camera>_stageDebug'` unconditionally, so the *next* real capture's data
will actually show focus-convergence timing and per-shot upload duration.

**ambientClose/flashFar: now 0/6 fresh real attempts** (3 tests × 2 stages)
with the guide-resize visibility bug already fixed — coverage stayed in the
0.49-0.73 range across every attempt, nowhere near either target (>0.90 /
<0.25). Combined with the predecessor design's 0/12, this is **0/18
all-time**. Recommendation stands: relax the thresholds substantially or
retire the feature rather than continuing to tune blind — awaiting CTO
direction.

Committed (`4daacc6`), not yet pushed (standing process rule) or further
device-tested.

## Secondary-camera focus now actually measured, not guessed; ridge-continuity/TAR status recap (2026-07-23, round 4)
CTO tested the round-3 build (audio fix + camera diagnostics + splash
rebuild, run `30027872912`, confirmed successful) and raised two points:
"ridge continuity is a big issue, it will have a really low TAR" despite
visually impressive prints, and "some cameras do not focus on fingerprint
immediately, it's blurry captures."

**Focus fix, real root cause.** `_captureSecondaryBurst` fired its burst
after a **blind fixed 1400ms delay** with zero verification that AF had
actually converged — unlike the PRIMARY camera's own burst, which only
fires once a real measured sharpness signal (`_focusValue`, peak-
normalized/EMA-smoothed Laplacian variance via `_hybrid.offerFrame`) clears
a 0.45 relative threshold during the hold. The secondary-camera path had no
equivalent at all. Added `_waitForSecondaryFocusLock()`, reusing that exact
same signal on the secondary camera's own image stream: resolves as soon as
the smoothed, peak-normalized sharpness exceeds the same 0.45 threshold
(portable across lenses with very different absolute sharpness ranges,
same as the primary path), bounded 500ms min / 2600ms max (never fires on
a lucky first frame, never hangs longer than a modest margin over the old
delay even on a sensor that never converges). Records
`focusConvergedMs`/`focusScoreAtFire` per camera into `secondaryCameraDebug`
so the next real test's data shows whether convergence is actually
happening now and how long it really takes.

**Ridge-continuity/TAR: recapped the real status, did not write new
enhancement code blind.** This is the project's own standing Prime
Directive, already the subject of massive prior investigation this whole
project (SourceAFIS gate, `ml/deform_correct` v1-v3, `ml/multiview_fusion`
Phase 0/1, pyfing/pyfingHybrid/coherenceDiff/nnsHybrid) — every one of
those either measured negative or only narrowly, inconsistently positive.
The two real structural blockers are unchanged: no real ≥500-DPI reference
scan of the CTO's own finger exists (the one ink scan can't distinguish
genuine from impostor — noise floor), and RidgeBase/a public paired dataset
was never actually acquired despite being flagged since 2026-07-17. The one
real, free, still-untried lever is cross-polarization (physical film over
flash+lens, kills specular reflection at the source) — flagged as the
highest value-per-effort item in `docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md`
since 2026-07-16/17 and still never tried. Recommended against another
speculative enhancement-code pass given the track record above; the real
unlocks here are CTO-side (reference scan, paired dataset) or free
(cross-polarization), not new capture-pipeline code.

Committed (`730e66c`), not yet pushed (standing process rule) or
device-tested.

## Audio silently never worked (missing init()), camera-2 diagnostics added, full-fidelity splash rebuild (2026-07-23, round 3)
CTO reported no audio/haptics anywhere in the capture flow, said the splash
screen was missing most of the reference zip's content and wanted the whole
thing translated as-is (duration is the only allowed change), and asked to
scope everything from the prior optimizations report before pushing.
Investigated via two Explore agents (audio wiring, splash reference diff)
plus direct code checks; scoped in Plan Mode, approved, then built.

**Audio root-caused: `front_capture_controller.dart` never calls
`CaptureAudioService.init()`.** `init()` is the only place that loads the
WAV assets into the `just_audio` players (`setAsset`) — every
`playAngleSuccess()` call since (main-burst chime, per-camera
`capturingExtra` chime) played a source-less player, silently swallowed by
that method's own `catch`. The sibling `oscillating_capture_controller.dart`
already calls `init()` in its own setup — a copy-paste gap from when the
chime call sites were retrofitted into this controller. Fixed with one
`unawaited(_audio.init())` call in `start()`. Considered also adding
explicit Android `AudioAttributes`/`audio_session` config for robustness,
but skipped it — it would need a new pub dependency this sandbox has no way
to verify resolves (no Flutter toolchain, no cached pub registry), and
unlike the `init()` call it isn't the actual bug. Haptics themselves look
correctly wired (`HapticFeedback.lightImpact`/`heavyImpact` at the right
call sites, `VIBRATE` permission declared) — if still silent after this
fix, it's most likely the device's own "Touch vibration" system setting,
which gates `HapticFeedback.*` with no way for the app to detect it.

**Camera "2" timeout pattern — added diagnostics, not a guess-fix.** Real
data: camera "2" timed out on upload in 3 of the last 4 real captures with
secondary-camera data (different `shot_N_upload` step each time), while
camera "3" succeeds consistently — but nothing in the app has ever
distinguished which physical lens each opaque camera-id actually is.
Extended the existing read-only `cameraCapabilities` MethodChannel
(`MainActivity.kt`) with `getCameraLensInfo` (focal length, sensor size,
lens facing per camera id — same read-only, no-capture pattern as the
existing `rawSensorSupport`/`noiseReductionOffSupport` queries), attached to
the capture doc as `cameraLensInfo`. Added per-shot upload-duration
timestamps (`shot_N_captureMs`/`shot_N_uploadMs`) to `_captureSecondaryBurst`'s
`stageDebug` so the next real capture shows whether camera "2" is
consistently slow to upload vs. genuinely hanging.

**Also corrected an item from the prior optimizations report**: the "live
too-close hint during the primary hold" I'd proposed as a gap already
exists — `_onFrame` already sets `distanceHint = 'Move back slightly'`
whenever coverage exceeds `_coverageMax` during the hold, rendered as "↓
Move phone BACK a little". No work needed there; flagged so it isn't
mistakenly re-built later.

**Splash screen: full-fidelity rebuild, 13.0s reference scaled to 6.5s.**
Read the actual `ClearBridgeReveal.jsx` reference beat-by-beat (not prior
session notes, which contained at least one wrong quote — the reference's
real tagline is "POLICE CLEARANCE REIMAGINED", not "Police clearance in
2-5 hours"). The 2026-07-20/22 pass condensed this to 4.7s and dropped the
entire under-logo marketing stack (5 rows) plus several smaller beats,
believing only the scan/reveal mechanic mattered — the CTO wanted
everything back, shorter duration only. Rebuilt scaling every one of the
reference's own timestamps by exactly 0.5 (preserves true proportions,
including its own settled tail, rather than re-tuning by feel). Restored:
the second (gold) ambient halo + blur on both, a separate medallion
under-glow, the capture "pop" scale bump, a green drop-shadow glow that
follows the fingerprint's own revealed silhouette (blurred `srcIn`-tinted
copy under the crisp one, not a bounding-box glow), the scan line's soft
trailing gradient band, the verification rings' outer glow, the
radial-gradient stage background, the full-screen vignette, JetBrains Mono
(was Roboto Mono) on eyebrow/percentage text, and the full 5-row marketing
stack (FOR THE WORKER / BETA+FAST+SECURE+DIGITAL badge row / POLICE
CLEARANCE REIMAGINED / Ready for secure capture / Tap to continue). Reused
the blur/badge/dash-line/pulsing-icon widget *techniques* already proven in
the unrelated legacy root `lib/splash_screen.dart`, but every beat's actual
timing/content came from the JSX, not that file. One accepted
approximation: the reference's `mixBlendMode: screen` capture flash has no
direct Flutter sibling-blend-mode widget without a custom `CustomPainter`
— left as plain alpha compositing (minor visual difference against a
near-black background).

Committed (`e2a6ffa`, `7171aeb`), not yet pushed (standing process rule) or
device-tested.

## Real-device test of the per-camera-state-machine build: nfiq2Score 81 (ties all-time best), guide-resize notification bug found + fixed, camera-during-upload fixed (2026-07-23)
CTO tested the APK built from the per-camera state-machine commit (`0a11728`)
and reported three things via 5 screenshots: the ambientClose/flashFar guide
never visibly resized, the live camera kept running behind the "Uploading…"
screen, and asked how the resulting real captures scored. Investigated via
an Explore agent (exact code) plus a fresh Firestore/Storage pull of the
exact test capture.

**Real result: `dadd4ef9` scored `nfiq2Score: 81`** (createdAt
2026-07-23T14:15:56Z, matches the screenshots), tying this project's
all-time-best (previously `fc619fe8`'s deepFuse, also 81) — won via the
plain "native" ambient frame (frameIndex 0, `afisEnhance: gabor`). Visually
confirmed clean, dense whorl print via `superprint_afis.png`. Flash frames
again scored terrible sharpness (Laplacian 17-20 vs ambient 232-245, the
same recurring torch-blowout pattern) but self-corrected via selection.
Secondary camera "3" succeeded (3 frames); reviewed one visually — thumb
in-frame but loosely centered, consistent with the known camera-parallax
finding. Secondary camera "2" **still timed out** at the 28s bound
(`2_stuckAt: shot_2_upload`) — not blocking, flagged as still-unresolved.
`ambientCloseDebug`/`flashFarDebug` both show `attempted: true, reachedZone:
false` — neither bonus stage fired a burst this test (root-caused below).

**Real bug found + fixed: the guide-resize cue could be silently dropped.**
`activeGuideShape` WAS being set correctly before both waits (ambientClose
→ enlarged shape, flashFar → shrunk shape) — but the `_apply()` call
carrying it didn't pass `force: true`, and `_apply` throttles
`notifyListeners()` to at most once per 80ms. For flashFar this was a
**guaranteed** miss: its `_apply` call runs synchronously right after
ambientClose's own cleanup `_apply`, with no `await` in between, always
landing inside the 80ms window. The CTO's screenshot showed the "Move
slightly back for a bonus capture" hint text (which did eventually flush on
a later call) but never the shrunk guide — exactly consistent with this
mechanism, not a "too subtle to notice" issue. **Fixed**: added `force:
true` to both `_apply` calls, matching the existing pattern already used
for the uploading-phase transition and `_fail`.

**Real diagnostic bug found + fixed alongside it**: `_waitForDistanceZone`
always tracked the MAX coverage regardless of `direction`. For flashFar's
`below` direction (wants coverage to DROP), the informative number is the
MINIMUM reached, not the max — the old `maxCoverageObserved: 0.613` field
didn't actually say how close the CTO got to the 0.25 target. Now tracks
both extremes and reports whichever matches direction under a renamed
`coverageObserved` field, so the next real test's data is interpretable.
Also widened the wait window 6s→9s: the resize cue effectively never
rendered during this test (per the bug above), so 6s was never actually
exercised as real reaction time — did NOT touch the coverage thresholds
themselves, per this project's "measure one variable at a time" discipline.
Real reach-rate is now 0/2 for this design (continuing the old
`distanceStage2`'s 0/12) — worth watching whether it improves now that the
visual cue will actually work, before considering a bigger redesign.

**Camera-during-upload, fixed**: confirmed the live `CameraPreview` was the
unconditional base layer of the screen's `Stack` in every phase, and the
uploading scrim was only 92%-opaque (`CaptureColors.void_` alpha 0.92),
letting 8% of the live feed bleed through — exactly the dim texture visible
behind the icon in the screenshots. Nothing after `uploading` needs the
camera again (`uploading` only ever transitions to `complete`/`error`).
Fixed: the controller now disposes the camera before flipping to
`uploading`, the screen skips the camera layer entirely during that phase
(belt-and-suspenders), and the uploading overlay is now fully opaque with
the actual ClearBridge logo (`app_logo.png`, already asset-registered, used
elsewhere in `beta_thank_you_screen.dart`) plus a real `CircularProgressIndicator`
spinner, replacing the generic pulsing `Icons.fingerprint` placeholder
(`CaptureIntroAnimation` — left untouched since it's still used by the
retired multi-angle flow).

Committed, not yet pushed (standing process rule: batch, push only on
explicit go-ahead) or device-tested.

## Explicit per-camera capture state machine + secondary-camera framing guidance (2026-07-23)
CTO reported two real problems using the app, both inside `capturingExtra`
(secondary cameras "2"/"3", then `ambientClose`/`flashFar`): no deliberate
stop between cameras (the loop just moved straight to the next one), and
"Uploading…" appearing while a camera could still be capturing in the
background. Root-caused in code: the secondary-camera loop never explicitly
disposed a camera controller after its own turn — it relied entirely on the
SIDE EFFECT of the NEXT camera's `svc.initializeCamera()` internally calling
`CameraService.disposeCamera()` first. Combined with the per-camera 28s
timeout (which can't cancel the underlying native call — the established ANR
hypothesis), this meant a timeout could fire and the loop would race on to
the next camera while the previous one's native work was still running, with
no `await`ed "this camera has fully stopped" checkpoint anywhere.

**Fix**: every camera turn inside `capturingExtra` (each secondary camera,
then `ambientClose`, then `flashFar`) now goes through the same explicit
5-step sequence: (1) switch in + generic centered guide shown on that
camera's own live feed (already displayed automatically —
`_cameraLayer()` reads the live `CameraService` controller — just never had
a guide overlay before), (2) `"3…"`/`"2…"`/`"1…"` countdown with haptic
pulses (~700ms apart, real time to use the guide before the shutter fires),
(3) capturing, (4) an explicit, **awaited** `svc.disposeCamera()` before the
turn is allowed to end (secondary cameras only — `ambientClose`/`flashFar`
reuse the same live main-camera session throughout, so there's nothing to
dispose there, but they get the same visible sequence for consistency), (5)
a real `"✓ $friendly captured"` / `"$friendly skipped"` confirmation banner
+ chime. Two new shared helpers (`_showCountdown`, `_showStopConfirmation`)
reused across all 4 turns instead of duplicating this logic. New generic
`_secondaryCameraGuideShape` (reuses `PadSilhouetteShape.defaultShape` —
deliberately NOT calibrated to each lens's real FOV offset yet, since no
measured offset data exists; this is the first cut that gives the user SOME
framing target instead of none, following directly from this session's
camera-comparison finding that secondary cameras have real, sometimes-
excellent ridge detail but fire completely blind today).

**Real, deliberate cost**: adds ~3.5-4s per camera turn × 4 turns ≈ 14-16s to
`capturingExtra`'s total length — the direct, unavoidable price of a
countdown + confirmation on every camera, not a surprise. Committed, not yet
pushed (standing process rule: batch, push only on explicit go-ahead) or
device-tested.

## Post-device-test optimization round: fusion-selection guard, illumination-decoupled distance capture, noise-reduction research spike (2026-07-23)
Following the ANR/prime-directive audit above, scoped and built the next
round in Plan Mode (approved), with a new standing process rule: commit
locally per item but hold `git push` (which is what actually triggers
`build.yml`) until the CTO explicitly says to push/build, rather than
pushing after every individual fix as in prior rounds.

**Illumination-decoupled distance capture, Phase 0 — the CTO's own idea
this round.** The flash torch's intensity falls off with distance², so it
overpowers ridge contrast at close range regardless of EV tuning (real,
reproduced pattern: `913758cf`'s ambient frame scored Laplacian 790 vs its
flash frame's 81 at the SAME distance) — while native ridge wavelength
(tied to closeness) is this project's strongest real NFIQ2 predictor, and
closer is optically richer. Decoupling distance by illumination lets each
half get its own best distance instead of compromising on one for both.
Replaced the old single-distance `distanceStage2` (which asked "get closer"
then still fired flash shots at that close range — exactly the exposure
risk this removes) with two best-effort bonus stages in `capturingExtra`:
**`ambientClose`** (guide enlarges — per `PadSilhouetteShape`'s own
established finding, a bigger guide pulls the user closer — torch never
engages this whole stage, so blowout risk is removed regardless of
distance) and **`flashFar`** (guide shrinks, pushing the user farther than
today's already-tuned default, on top of the existing adaptive-EV flash).
Both feed the backend's existing max-of-variants selection as independent
single-frame candidates — no fusion math yet (Phase 1, gated on this
showing real gain, per `docs/MULTI_DISTANCE_MESH_SCOPE.md`). Both ship with
`maxCoverageObserved` diagnostic logging from day one, same discipline the
old `distanceStage2` shipped with after its own 12/12 real-world failure
record (now known more precisely: 0.444/0.684 vs a 0.90 threshold — landing
well short, not grazing it). Added `PadSilhouetteShape.scaled(factor)` as a
reusable helper. Not yet device-tested.

**Fusion-selection sharpness guard, backend-only.** Directly targets the
real miss found in the same audit: `913758cf` had a plain ambient frame at
Laplacian 790.4 (sharpest of 15 real captures audited) but the variant loop
picked a flash+ambient fusion anyway, and the internal proxy overestimated
it badly (65.37 predicted vs 32 real). Added a guard in `main.py`'s variant
loop: when the ambient frame is drastically sharper than the flash frame
feeding a fusion variant (Laplacian ratio ≥ 4x), that fusion variant must
beat the plain `native` variant's own proxy score by a real margin (+3 NFIQ)
to win, rather than merely edging it out. Purely a guard on an existing
max-of-variants loop — can only withhold a variant from winning, never
produce a worse result than what earlier variants already found. **Offline
validation** (17 real captures — the original 14 plus `afe5b02c`/
`913758cf`/`cb684c57` newly downloaded for this test, harness-style sweep
reproducing `main.py`'s proxy-driven selection, not committed): changed
selection on 2/17 captures (`c34911b5`: fuseAvg 77→freqNorm 76, -1;
`f2fa606b`: fuseAvg 43→freqNorm 64, +21) and was inert on the rest — net
+20 across the two it touched, never observed to regress a capture that
didn't trigger it. **Honest caveat**: the offline harness does not exactly
reproduce `main.py`'s real per-variant input wiring (confirmed: on
`913758cf` itself, the harness's proxy-driven baseline already picked
`native` even without the guard, whereas real production picked `fuseSoft`
— a plumbing difference between the standalone script and the real
pipeline, not evidence the guard is wrong, but a reason this still needs
real-device confirmation, same as always). Not yet deployed.

**Research spike: native noise-reduction override (Item C) — do not pursue
right now.** `noiseReductionOffSupport` came back `true` on all 4 cameras
this device (a real, positive Phase-0 result, unlike RAW/DNG), but
researching the actual `camera_android_camerax` v0.11.4 plugin source
(confirmed via `pubspec.lock`) found the real Camera2 interop machinery
(`Camera2CameraControlProxyApi`/`CaptureRequestOptionsProxyApi`) exists only
as an INTERNAL implementation detail — the public `CameraController` Dart
API (confirmed via the package's own published docs) exposes no method that
reaches Camera2 capture-request options, noise reduction, or edge mode at
all. Reaching it would require either forking the plugin or opening a fully
separate, independent native Camera2 session bypassing CameraX entirely (two
sessions can't normally hold one physical camera at once) — a native lift
comparable in size to the RAW/DNG path already declined, not a small
interop tweak as originally scoped. Given this would add yet another native
camera-session open/close cycle during `capturingExtra` — the exact
category of risk this session's own ANR investigation just traced to
camera-session churn in that same window — **recommending against pursuing
this further right now.** No code shipped for this item.

## Third real-device test (zoom/adaptive-flash-EV/noise-reduction-probe build): ANR root-caused + fixed, first-ever good score on a "too close" capture, and a real fusion-selection miss (2026-07-23)
CTO tested the APK built from the zoom-to-fill/adaptive-flash-EV/noise-
reduction-probe round and hit a real Android ANR ("ClearBridge Beta isn't
responding") during the `capturingExtra` phase, plus asked two direct
questions: (1) can the backend reconcile "get closer for more ridge detail"
with the established "large px = bad NFIQ2" finding, and (2) audit real
Firestore captures toward the prime directive. Pulled the 15 most recent
real capture docs directly (not assumed) to ground all three answers.

**ANR root-caused via a real regression signal, not guessed at.**
`secondaryCameraDebug` across the last 3 real captures (`cb684c57` 07-22
through today's two) shows **both** secondary cameras (`2`,`3`) timing out
on **every** attempt, always stuck at `shot_0_upload`/`shot_1_upload` --
whereas every real capture before that (`2a85bb36`, `9b0fb988`, `b1c50ca2`,
etc., all the way back) shows clean `'2_ok'/'3_ok': true`. The dividing line
lines up exactly with the Item 3 change that took `_secondaryBurstCount`
1->3 shots and added exposure/focus setup + a 1400ms settle delay per
camera -- the 12s per-camera timeout guarding that whole sequence was
calibrated for the OLD single-shot flow and was never widened for the new,
much longer one, so it now fires routinely. Since `Future.timeout()` cannot
cancel the underlying native `takePicture()`/upload call, a timeout here
very likely leaves that camera's session still active in the background
while the loop immediately opens the NEXT camera's session -- real
overlapping camera-session contention, the same failure category this
codebase has already documented elsewhere, and the most likely real trigger
for the ANR. **Fix**: widened the timeout 12s -> 28s
(`front_capture_controller.dart`) so it's far less likely to ever fire under
normal conditions, removing the overlap at its source rather than papering
over the symptom. Not yet confirmed on a real device.

**Also found and fixed a real, unrelated UI bug while auditing the
screenshot**: the CTO's screenshot showed a nonsensical "↓ Move phone BACK a
little" banner rendered simultaneously with the correct "Capturing with
secondary camera…" banner. Root cause: `front_capture_screen.dart`'s
distance-hint widget mapped ANY non-null `distanceHint` that wasn't
literally `'Move closer'` to that one fixed string -- during
`capturingExtra`, `distanceHint` legitimately carries status text instead
(`'Capturing with $friendly…'`), which this widget mangled. Fixed by scoping
that widget's condition to exclude `capturingExtra` (which already has its
own correct banner one widget down). Both fixes committed `08c06ad`, pushed.

**The "closer for detail vs. large-px NFIQ2 penalty" question: no clean
backend knob reconciles them, but today's data is the first real
counter-example that the two aren't always in conflict.** Backend
resampling was already tested directly for exactly this (2026-07-19 freq-
floor relaxation, `_FREQ_SCALE_MIN` 0.7->0.15) and made real matchability
**worse**, not better -- confirming this isn't a pixel-scale artifact a
backend knob can fix; resampling changes pixel *spacing*, not optical
*resolution*, so it can't invent ridge detail a too-close/badly-lit capture
never recorded. **But today's `afe5b02c` is a genuine, real outlier**:
`afisWavelengthPx` 18.5 (deep in the historically "catastrophic" >=15px
zone -- every other real capture at wl>=17 scored single digits except one
borderline wl=15 case) yet scored a real **nfiq2Score 74**, the best score
this project has ever recorded at this wavelength. Its `zoomDebug` shows
zoom-to-fill actually engaged (`finalZoomLevel: 1.3`, `zoomApplied: true`)
and its `flashEvDebug` shows the adaptive EV step active (`evStep: -1.043`).
Plausible mechanism: the "too close is catastrophic" pattern was never
purely about wavelength/pixel-scale -- it's that getting closer usually ALSO
risks flash blowout and framing overshoot, and this capture is the first
real evidence that if those two specific risks are independently controlled
(adaptive flash EV, zoom-assisted framing), a close/high-wavelength capture
CAN still score well. **n=1, not proof, needs replication** -- but this is a
genuinely new, positive data point worth watching on the next several real
captures rather than the settled negative result it looked like before this
round's fixes shipped.

**Real fusion-selection miss found on `913758cf` (nfiq2Score 32, the round's
worse capture)**: its plain ambient frame scored Laplacian **790.4** (the
sharpest single frame across all 15 captures audited), while its flash frame
scored only 81.3 -- a large contrast-collapse-from-overexposure gap,
the same recurring "torch blows out an already-decently-lit pad" pattern
documented earlier this project. Despite that, the winning variant was
`afisFused: 'soft'` (a flash+ambient blend), and the internal proxy score
(`nfiqAfis` 65.37) badly overestimated the real result (`nfiq2Score` 32) --
another real instance of the already-established "the internal proxy is
foolable, only real NFIQ2 is trustworthy" finding, this time plausibly
costing a capture that had an excellent plain-ambient frame available. Not
actioned this round (n=1, consistent with existing selection-heuristic
limitations already documented, not a new bug) -- worth watching whether
this recurs before considering whether variant selection should weight raw
frame sharpness more directly.

**Prime-directive audit, real Firestore data, no proactive backend changes
made:**
- **`noiseReductionOffSupport` now confirmed `true` for `noiseReductionOff`
  AND `edgeModeOff` on all 4 cameras on this real device** (Item C's Phase-0
  probe, shipped last round). Unlike RAW/DNG (dead on arrival --
  `rawSensorSupport` false on every camera), this device DOES advertise the
  capability the harder native `CaptureRequest.NOISE_REDUCTION_MODE`/
  `EDGE_MODE=OFF` override would need -- Item C is worth pursuing now, not
  shelved.
- **`distanceStage2` is still 0-for-11 real attempts**, but the diagnostic
  logging shipped specifically to answer this (`maxCoverageObserved`) now has
  real numbers: today's two attempts topped out at **0.444** and **0.684**
  against the required **0.90** threshold -- both meaningfully short, one by
  more than half. This is real evidence favoring the "design tension"
  hypothesis over "almost there, just needs more time": users aren't
  grazing the threshold and running out of clock, they're landing well
  short of it, consistent with the mask already having been shrunk twice to
  push users FARTHER away for the wavelength sweet spot, leaving nowhere
  comfortable to go closer.
- `rawSensorSupport` still `false` on all 4 cameras, consistent with the
  standing closed-out finding -- not revisited.

## deform_correct v3 (SD302f domain-matched + real MAC3D source): MIXED result, not a clean win over v2 (2026-07-22)
Per the CTO's redirected idea — after multiview-fusion's phase-demodulation
rebuild became this branch's sixth negative result on the front/side
registration task, use the NIST SD302 corpus (confirmed live in S3, not
Firestore as first framed) for the ALREADY-partially-working
`ml/deform_correct` synthetic-distortion line instead, using the subset
"closest to MAC3D domain" — trained a new checkpoint (v3) on 953 clean
source prints: 912 SD302f crops (the only PHOTOGRAPHED, not scanned, part
of SD302 — real contactless skin, quality-gated via a new self-contained
`sd302f_crop.py` three-gate cropper, 72.7% raw pass rate before a further
median-cutoff tightening) + all 41 real MAC3D `enhancedImagePath` prints
pulled straight from Firestore (the literal target domain, not a proxy).
Deliberately did NOT re-include SD302a/b/d volume — that was v2, already
found NOT to beat v1 on this same real gate.

**Real bugs found and fixed along the way** (all committed): the S3
downloader needed retry-with-backoff (a transient `ProxyConnectionError`
killed the first sampling attempt at 8/2000); the SageMaker launcher had
the same `framework_version` 2.4-vs-2.3 SDK mismatch already fixed on the
multiview-fusion branch, plus an unbounded `torch`/`numpy` pin in
requirements.txt that risked the same DataLoader ABI crash found there;
the manifest channel's in-container path was hardcoded to `manifest.json`
while the actual uploaded object was named differently, causing a real
`FileNotFoundError` on the first submission (fixed by deriving the path
from the manifest's own basename); the first spot-instance submission hit
the same `InsufficientCapacity` stall seen on earlier SageMaker jobs this
project has run, resolved the same way (stop + resubmit on-demand, cost
difference negligible: ~$0.74 spot estimate vs. the job's actual real
on-demand cost, well under budget).

**Training itself was healthy**: val loss descended cleanly 0.176 -> 0.123
over 100 epochs (job `deform-synth-v3-mac3d-sd302f-od2`, `ml.g4dn.xlarge`,
~41 min), no mean-collapse, consistent with this line's established
"synthetic self-distortion has a real learnable signal" pattern (unlike
every front/side pairwise-registration attempt on the other branch).

**The real gate — same scale-normalized SourceAFIS methodology as v1/v2,
same 26-capture real MAC3D library, same ink-scan/cross-session groups —
gives a genuinely MIXED result, not a win:**

| condition | genuine-vs-ink mean | impostor max | beat max | cross-session mean |
|---|---|---|---|---|
| scale-normalized, uncorrected | 2.56 | 5.86 | 1/4 | 22.62 |
| scale-normalized, v2-corrected (a+b+d volume) | 3.16 | 7.51 | 0/4 | 4.85 |
| **scale-normalized, v3-corrected (SD302f+MAC3D domain)** | **3.01** | **14.43** | **0/4** | **9.13** |

v3 roughly doubles v2's cross-session same-finger matching (4.85 -> 9.13,
a real improvement on genuine-pair matching) but also roughly doubles v2's
worst-case impostor false-match risk (7.51 -> 14.43) and doesn't change the
headline failure (still 0/4 genuine pairs beat the impostor max, same as
v2). The single impostor capture driving the blowup (`e5cb52fc`) scored
14.43 alone; every other impostor stayed in the 0-6.2 range, the same
"one noisy real capture's correction gets misread as false-match-like
signal" pattern already documented for v1's full-library test (there it
was the sunlight-transillumination capture; here it's a different real
capture, same underlying failure mode: correcting an already-noisy print
can manufacture spurious minutiae-like structure rather than real ridge
detail).

**Conclusion**: domain-matching the synthetic-distortion source data
(photographed contactless skin + the literal real target domain, instead
of clean contact-scanner volume) measurably changes what the model learns
in a real, non-random way — but doesn't fix the underlying problem this
whole `ml/deform_correct` line has never solved: correcting an
already-noisy real capture can still manufacture false-match-adjacent
noise as easily as it can help. **Not recommending wiring v3 into
production over v2 or v1** without further work — if any of these
checkpoints are ever wired in, it must be as one more max-of-variants
candidate gated by existing quality selection (same standing discipline as
every other addition to this pipeline), never a blind replacement, and
this real noise-amplification behavior is exactly why. Checkpoint: S3
`deform-correct/deform-synth-v3-mac3d-sd302f-od2/checkpoints/best.pt`.

## Prime-directive roadmap delivered + distanceStage2 diagnostic instrumentation (2026-07-22)
CTO asked directly for a prioritized roadmap toward the prime directive
(real matchability, not NFIQ2). Delivered one grounded in real project
history + two facts verified fresh this session rather than assumed:

- **RidgeBase dataset**: confirmed via a full CLAUDE.md/docs re-read — the
  CTO said they'd acquire this 2026-07-17, `ml/fidelity_benchmark/ingest.py`
  is built and self-tested specifically to consume it, but it has never
  actually landed. Still the single biggest standing blocker on the whole
  fidelity axis, alongside the CTO's own ink scan being too weak to
  discriminate genuine from impostor (bozorth3-vs-ink sits at noise-floor
  4-7 for everyone, not just the CTO's own finger).
- **RAW/DNG capture: CLOSED OUT.** Queried Firestore directly across all 26
  real `front_only_v1` captures — `rawSensorSupport` has never once come
  back `true` for any camera on any real device. Per this item's own stated
  gate ("if not, dead on arrival"), this closes the question: no device in
  the fleet supports it, don't pursue the native RAW/DNG platform-channel
  effort.
- **`distanceStage2` ("move closer for a bonus capture") has NEVER
  succeeded**: queried Firestore directly — 9/9 real attempts show
  `reachedNearZone: false`. Not a fluke. Real hypothesis found on re-read
  (not just "threshold is wrong"): `nearThreshold = _coverageMax + 0.05 =
  0.90` asks users to get CLOSER than an already-successful primary hold
  (which already requires coverage in [0.35, 0.85]) — but this feature was
  built 2026-07-16, BEFORE the project's own strongest real finding (native
  ridge wavelength predicts NFIQ2; the guide mask has since been shrunk
  TWICE specifically to push users FARTHER away to hit the 9-14px sweet
  spot). distanceStage2's "closer = more detail" premise may now directly
  contradict the primary flow's own calibration — the 9/9 failure could be
  the system correctly resisting a request that would make the capture
  worse, not a bug.

**CTO chose this as the next concrete step.** Rather than guess and loosen
the threshold blind, added diagnostic-only instrumentation:
`_waitForNearDistanceZone` now returns `(reached, maxCoverage)` instead of
a bare bool, and `distanceDebug` gains `maxCoverageObserved` — the highest
coverage actually reached during the real 6s window, recorded regardless
of outcome. The next real capture will show whether users land well short
of 0.90 (miscalibrated ask / unclear prompt) or right at its edge but run
out of time (window too short) — turning the next test into real evidence
instead of another guess. No capture behavior changed, no threshold
touched yet, per this project's own "measure before tuning" discipline.

## Second real-device test of the hang-fix build: fix confirmed working, mask shrunk again (real data, not just feel), secondary cameras still can't focus (2026-07-22)
CTO tested the APK built from the previous round's 4 fixes (commit `9b51781`).
Real capture `cb684c57` (uid `3P9IKtAB8dM3T5HGNEVLSSrDl1y1`, 2026-07-22 13:57
UTC) reached `status: scored`, real `nfiq2Score: 46` — a real, decent score,
and **the hang-fix is confirmed working**: `secondaryCameraDebug` shows
`2_timeout`/`3_timeout: true` instead of the app hanging forever the way it
did before the 12s-timeout fix — the CTO's "IR cam struggled to focus"
report is exactly what a clean timeout on an AF-convergence failure looks
like, not a regression from the fix itself.

**Mask-size complaint independently confirmed by measurement, not just
feel** (`superprintParams.afisMaskCoverPx: 607615`). That number was
measured under the 2026-07-20 2048->3200px decode-width bump, which inflates
pixel COUNT ~2.44x at the same physical/relative size vs. the historical
2048px-pipeline reference clusters this project's own wavelength/coverage
correlation was built on. Resolution-adjusted (607615/2.44 ≈ 249000px), it
lands between the established "good/far" cluster (~167000px, the real
72-scorers) and the "too-close/bad" cluster (~262000px) — much closer to the
bad end. **Action**: shrunk `PadSilhouetteShape.defaultShape` a further -15%
(rx 0.1955->0.166175, ry 0.1615->0.137275; `_scoreRoi` recomputed to match)
— same lever, same magnitude as the 2026-07-20 cut, not the full ~18% the
area ratio would imply (n=1 real data point isn't enough to trust an exact
target, per this project's own discipline).

**Real, currently self-correcting finding, not actioned**: this capture's
flash-lit burst frames scored Laplacian 15-19 vs. 343-395 on ambient frames
from the SAME hold (gyro only 1.22°/s, ruling out motion blur) — contrast
collapse from overexposure, the same "torch blows out an already-decently-
lit pad" failure mode documented earlier this project, just triggered by
moderate ambient light rather than close range this time. Self-corrected
this round (`afisSource` shows `frameIndex: 0`, an ambient frame, won
selection) so the final print wasn't hurt, but the flash half of this
capture's burst was dead weight. Not fixed yet — a real next candidate is
scaling the flash EV step to calibrated ambient brightness instead of a
fixed `-1.0`, but needs its own dedicated real-data test before changing,
same standing discipline as everywhere else.

**Secondary-camera AF convergence remains a real, unresolved problem.**
Added stage-diagnostic instrumentation (`_captureSecondaryBurst` now takes a
`stageDebug` map, written synchronously before each major await —
`flash_on`/`exposure_setup`/`focus_setup`/`settle_delay`/`shot_N`/etc. —
survives even though `.timeout()` doesn't cancel the underlying Future) so
the NEXT test's `secondaryDebug['<cam>_stuckAt']` will show exactly which
step the IR/wide camera stalled on, rather than just "timed out" — this
capture predates that instrumentation, so it's unknown yet whether AF itself
never converges or a specific `takePicture()` call hangs.

## CTO device-test round: burst-end lag, no progress cue on secondary cameras, wide-cam capture hang, splash mismatch (2026-07-22)
Four real-device findings from testing the previous round's APK, all addressed:

1. **Small lag right at the end of the main burst.** The pad-guide fill ring
   reached 100% on the last shutter click, then the app went visually silent
   during the decode+sharpness+re-encode `Future.wait` over all 8 burst
   frames before "✓ Captured" appeared — read as a freeze. Real, not
   imagined: this work got measurably heavier after the
   `_stillDecodeTargetWidth` 2048->3200px bump (2026-07-20, ~2.4x more decode
   pixels across all 8 frames), plausibly what made an always-present pause
   newly noticeable. Fix: show an explicit `confirmationText: 'Processing…'`
   banner for this window (`front_capture_controller.dart`, `_fireBurst`)
   instead of a silent gap — it naturally gets replaced by the existing
   `'✓ Captured'` text once decode/encode finishes.
2. **Wide cam / IR had no progressive fill cue.** `silhouetteProgress` only
   ever read `burstProgress` (main burst) or `holdProgress` (frozen from
   before the burst fired) — during `FrontCapturePhase.capturingExtra`
   (secondary cameras + distance-stage-2), the guide sat static the whole
   time. Added `FrontCaptureState.extraProgress`, incremented per secondary-
   camera attempt (success, failure, or timeout all count) and per the
   distance-stage-2 attempt, wired into `front_capture_screen.dart`'s
   `silhouetteProgress` when `phase == capturingExtra`. Also made
   `silhouetteState` read `capturing` (gold fill) rather than whatever
   `onTarget` was frozen at during this phase, since it's still actively
   working, not settled.
3. **Wide cam capture got permanently stuck, never progressed** (real device
   test, photo not received but description was unambiguous). Root cause,
   found by re-reading the secondary-camera loop line by line:
   `svc.initializeCamera(...)` already had an 8s timeout, but NOTHING after
   it did — `setFlashMode`/exposure/focus calls and, critically,
   `takePicture()` itself were raw awaits with no bound. If a secondary
   sensor's native capture session hangs (plausible on a wide-angle lens
   with different AF/AE convergence behavior than the already-exercised IR
   sensor, especially given this project's own extensive prior history of
   camera-session contention on this exact code path), the await never
   resolves — and since this whole block runs BEFORE the real Firestore
   write/upload, a hang here blocks the ENTIRE capture forever, not just
   that one camera's data. Fix: extracted the per-camera exposure/focus/
   burst sequence into `_captureSecondaryBurst()` and wrapped the whole call
   in a single `.timeout(12s)` that returns an empty path list on expiry
   (logged as `secondaryDebug['<cam>_timeout']`) — the loop then moves on
   instead of hanging. Added the same defensive `.timeout(6s)` to
   `_captureDistanceBurst`'s `takePicture()` call for the same risk
   category. Not yet confirmed on the real device that previously got stuck.
4. **Splash screen didn't resemble the actual reference animation.** The
   prior pass (2026-07-20) built a plain 900ms fade+scale — a real
   simplification gap, not a bug: the CTO's reference
   (`Logo_background_refinement.zip` -> `ClearBridgeReveal.jsx`) is a genuine
   13s scan-reveal animation (logo entry -> a cyan scan-line sweeps down the
   medallion revealing a green fingerprint layer top-to-bottom in sync with
   a 0-100% counter -> a capture-confirm flash + two expanding verification
   rings -> eyebrow label swaps BIOMETRIC IDENTITY -> SCANNING FINGERPRINT ->
   IDENTITY VERIFIED -> tagline), never actually built. Rebuilt
   `splash_screen.dart` as a faithful port of that mechanic, condensed
   proportionally to ~4.7s (still an app-launch splash, not a 13s block, and
   the reference's later marketing-copy rows — FOR THE WORKER / BADGE row /
   etc — trimmed to one tagline line since the feedback was about the
   *animation*, not the extra copy). New assets `cb-base-nofp.png` (base
   medallion, no fingerprint) + `cb-fp-masked.png` (green fingerprint reveal
   layer, revealed via a `CustomClipper` that grows top-to-bottom in sync
   with the scan line — the Flutter equivalent of the reference's `clipPath:
   inset(...)` reveal), resized to 640x640 to match the existing
   `app_logo.png` convention, added to `assets/images/`.

All four fixes are client-side only (`clearbridge_beta/lib/`), no backend
changes. Not yet device-tested — same standing discipline as every other
capture-side change this project: needs a real APK build + real device
confirmation, especially item 3 (the actual reported hang).

## Real device test of the resolution-bump build: pipeline healthy, secondary-camera fix confirmed working, mask still too big (2026-07-20)
CTO tested the APK built from the 2048->3200px still-decode resolution bump
(commit `8f1bb6f`). Real capture `2a85bb36` (uid `K7LNUP7leQO3q2E3rGMufMZx19q2`,
2026-07-20 15:04 UTC) landed `status: scored`, real `nfiq2Score: 72` — matches
the historical best (same as `c34911b5`/`3e54236a` under the OLD 2048px
pipeline), confirming the bigger decode didn't break anything. **Bonus
confirmation**: `secondaryCameraDebug` shows `2_ok`/`3_ok: true` with real
`secondaryCameras` paths present — the 2026-07-16 Firestore-rules fix for this
data is definitively working in production now, on a fresh real capture.

**Honest caveat on "did the resolution bump help":** no controlled comparison
exists (different real user/subject than the CTO's own ink-scan-referenced
finger, no paired before/after of the identical physical capture). What IS
observable: this capture's `afisWavelengthPx` read 15.0 vs. two historical
72-scorers' 9.0/11.0 under the old 2048px pipeline — expected, since more
decode pixels naturally read a higher raw pixel-wavelength for the same
physical ridge spacing (freq_normalize compensates downstream). Not proof the
change helped, but proof it's at least neutral — same top-tier score,
pipeline handled the new resolution regime gracefully.

**Real, actionable finding from this same test round**: wl=15 sits right at
the edge of this project's own established >=15px "catastrophic" correlation
— and the CTO independently reported "thumb still too close" on this exact
test. Directly corroborates each other. **Action taken**: shrunk the guide
-15% (see below) rather than treating the resolution bump and the mask-size
complaint as unrelated.

## CTO device-test round: mask -15%, secondary-camera audio, capture-progress fill ring, refined splash logo (2026-07-20)
Four real-device findings from testing the resolution-bump APK, all
addressed same-session:

1. **Guide mask still too big, thumb still too close.** Shrunk `PadSilhouetteShape.defaultShape` -15% (rx 0.23->0.1955, ry 0.19->0.1615;
   `_scoreRoi` in `front_capture_controller.dart` recomputed to match — kept
   1:1 per the shape's own docstring contract). Same lever, same direction as
   the 2026-07-18 revert, taken further — corroborated by this same test
   round's real wl=15 data point (see above).
2. **No audio confirmation on secondary-camera (IR/wide) captures.** The main
   burst already played a success chime via the existing
   `CaptureAudioService` (`just_audio`-backed, pre-generated WAV assets,
   already wired for the oscillating flow) — but each secondary camera's own
   capture in `front_capture_controller.dart` had zero audio feedback. Added
   `_audio.playAngleSuccess(isFinal: false)` right after each secondary
   camera's burst completes.
3. **No capture-progress indicator on the guide, unlike the oscillating dial's
   scan-fill arc.** `CapturePadSilhouetteOverlay`/`_PadSilhouettePainter`
   gained a `progress` parameter that traces a partial arc along the pad's
   OWN boundary path (`Path.computeMetrics()`/`extractPath()`, gold while
   capturing, green once the hold locks) rather than a separate circular
   ring — visually consistent with the pad shape itself. Driven by a new
   `FrontCaptureState.burstProgress` (per-shot fraction during the burst),
   falling back to the existing `holdProgress` before the burst fires —
   same two-phase pattern the oscillating dial already uses.
4. **Splash screen replaced with the refined brand assets** (CTO-provided
   zip, `Logo_background_refinement.zip`): confirmed the new
   `clearbridge-logo-circular.png` is the same badge design as the existing
   `app_logo.png`, just a higher-fidelity render (crisper metal/fingerprint
   texture) — replaced in place (resized 640x640, ~620KB) since both the
   splash and the thank-you screen share this one asset file. Gave the
   splash a brief fade/scale-in reveal + "BIOMETRIC IDENTITY" tagline beat
   matching the provided animated-reveal concept's key beats, condensed to
   ~2.2s total — the source asset was a ~13s marketing animation (logo ->
   scanning-fingerprint sweep with a percentage counter -> "Police clearance
   in 2-5 hours" tagline), deliberately NOT reproduced verbatim since that
   far exceeds what an app-launch splash should ever block a cold start for.

All four changes are UI/client-side only, no backend changes, committed
together (`551beee`). Not yet device-tested.

## Frequency-floor relaxation hypothesis TESTED on the real production pipeline and REFUTED — keep `_FREQ_SCALE_MIN=0.7` as-is (2026-07-19)
Per the CTO's "validate it, act as CTO" ask, followed up on the scale-
normalization finding above with a properly controlled test: real raw
`front_only_v1` burst frames + `guideRegion` for the 14 key MAC3D captures
were pulled fresh from Firestore/Storage and run through the ACTUAL
production `afis_print.generate(freq_normalize=True)` — not a standalone
reimplementation — once at the current floor (`_FREQ_SCALE_MIN=0.7`) and
once relaxed to `0.15`. Confirmed via real diagnostics that every one of
these captures has native wavelength 16.5-20px, so the current floor clamps
ALL of them to scale=0.7 (proper correction would need 0.45-0.55) — exactly
the under-correction the hypothesis predicted.

**Result: relaxing the floor made real matchability WORSE, not better.**

| condition | genuine-vs-ink mean | beat impostor max | cross-session mean |
|---|---|---|---|
| **current (floor=0.7)** | 5.01 | **2/4** | **37.99** |
| relaxed (floor=0.15) | 1.52 | 0/4 | 27.00 |

The standout cross-session pair (`9bdc9f85` vs `fcfa2e93`) scored a huge
**163.38** at the current floor and *dropped* to 116.76 when relaxed. 2/4
genuine captures beating the impostor max at the current floor is the best
real-matchability result measured all session (previous best was 1/4).

**Why this contradicts the earlier post-hoc scale-normalization finding**:
that test resampled the ALREADY-binarized final AFIS print (a crude,
lossy operation on hard black/white pixels) as a bolt-on AFTER the real
pipeline ran. This test varies the floor INSIDE the real pipeline, resampling
the continuous-tone image BEFORE Gabor enhancement — the actual mechanism.
The post-hoc test was a real methodological artifact, not a production
insight. **Conclusion: the earlier decision to raise `_FREQ_SCALE_MIN` from
0.35 to 0.7 (documented above, based on a real 24-capture NFIQ2 correlation)
was correct on the matchability axis too, not just NFIQ2 quality — do not
lower it.** This is a case of a hypothesis being taken seriously, tested
rigorously against the real system, and refuted — the discipline this
project has run on all session. No code change made.

## Bigger recalibrated deform-correct model (v2, DPI-fixed dataset) DOES NOT beat the smaller one on the real gate — but exposed a genuinely new, cheaper lever (2026-07-18)
Per the CTO's "find the best way to train the model... think out the box" ask,
fixed a real DPI-inconsistency bug in the scaled-up training data (SD302a+b+d
consolidated, 3810 prints vs the earlier 930-print SD302d-only run) and
retrained from scratch on real SageMaker GPU. Training itself was healthy and
confirms the fix worked: val loss descended cleanly 0.42 -> 0.2836 over 100
epochs (job `deform-synth-v2-1784399333`, `ml.g4dn.xlarge`, ~3h), never
plateauing the way the pre-fix run did. **But the real gate — SourceAFIS
matchability on the full 26-capture real MAC3D library — tells a more
complicated, honestly negative story.**

**First pass (naive resize, same eval code as every prior MAC3D test this
session): v2 is WORSE than the smaller v1 checkpoint, and worse than not
correcting at all.** Genuine-vs-ink mean dropped 5.45 -> **1.80** (v1 had
raised it to 7.48); impostor max rose 10.08 -> **14.43** (worse, same
noise-amplification direction as the earlier full-library finding). 0/4
genuine beat impostor max in both cases.

**Investigated why before accepting that verdict** (per this project's own
standing discipline): confirmed real MAC3D captures have **zero DPI metadata
and range from 289px to 2904px native resolution** (a 10x spread) — the eval
script's naive resize-to-256 was applying a wildly different, arbitrary ridge
scale per capture. v2 was specifically trained to expect a consistent
physical ridge-scale convention (the whole point of the DPI fix), so this is
a real train/eval domain mismatch, not just an old-vs-new noise difference.

**Re-ran with the eval-side preprocessing matched to training** (same
content-based ridge-wavelength estimate -> resample to the 9px target ->
center-crop/pad used in `dataset.py`, applied to both the probe and the ink
gallery). Measured native wavelengths spread 8.5-22px across captures (ink
scan itself at 17px) — confirming the scale mismatch was real and large.
Three-way comparison, same 26 captures:

| condition | genuine-vs-ink mean | impostor max | beat max | cross-session mean |
|---|---|---|---|---|
| naive resize, uncorrected | 5.45 | 10.08 | 0/4 | 9.49 |
| naive resize, v2-corrected | 1.80 | 14.43 | 0/4 | 12.50 |
| **scale-normalized, uncorrected** | 2.56 | 5.86 | **1/4** | **22.62** |
| scale-normalized, v2-corrected | 3.16 | 7.51 | 0/4 | 4.85 |

**The real finding: properly matching ridge SCALE alone — with no learned
deformation model at all — is a bigger, cleaner lever than the deform-correct
network itself.** Scale-normalization alone beat every other condition on
cross-session matching (22.62 vs 9.49-12.50) and was the ONLY condition where
a genuine pair ever beat the impostor max. Sanity-checked the standout case
(`9bdc9f85` vs `fcfa2e93`, two independent real captures of the same finger:
confirmed distinct files via MD5, not a duplicate-image bug) — scale-norm
alone scored a strong genuine match (**83.23**), but running the SAME
scale-matched pair through the v2 deform-correct model on top actually **cut
it to 16.94** — the learned warp made an already-good match worse. This
strongly suggests most of the earlier v1 checkpoint's apparent "gain" on this
exact pair (17.78 -> ~44) was likely riding on an incidental scale-matching
side effect of the model's own fixed-size input resize, not the actual
learned geometric correction doing real work.

**Honest conclusion**: neither deform-correct checkpoint (v1 small-dataset or
v2 bigger-DPI-fixed-dataset) shows a clean, reliable real-matchability win
once evaluated fairly — this is now THREE real-data rounds (small-sample v1,
full-library v1, full-library v2) without a uniform positive result, each
with a different failure mode (regressions on already-good pairs, noise
amplification on garbage captures, and now a demonstrated net-negative on a
properly scale-matched pair). **Not recommending wiring either deform-correct
checkpoint into production.** The scale-normalization idea, however, is a
new, real, and much CHEAPER candidate worth testing directly in the
production AFIS pipeline (no GPU model, no inference cost) — `afis_print.py`
already has its own DPI/wavelength-based resampling logic (`_TARGET_PERIOD`,
`_FREQ_SCALE_MIN`) that could plausibly be extended/tuned toward this same
effect, separately from the deform_correct line of work. Worth a dedicated
follow-up measurement before further deform-model GPU spend.

## Full-library MAC3D re-test: the earlier gain holds but is NOT uniform — real regressions + a noise-amplification risk found (2026-07-18)
Per the CTO's ask to use the full library, pulled ALL 26 real scored MAC3D
superprints from Firestore/Storage (not just the 14 cached locally) and
re-ran the deform-correct gate. Two honest findings temper the earlier
positive result:

**1. Bigger impostor pool (22, was 10) exposed a noise-amplification risk.**
Genuine-vs-ink mean still improved (5.45->7.47, same as before), but impostor
max jumped 10.08->**27.08** after correction — traced to `ca93829d`, the
**sunlight-transillumination capture** (nfiq2=7, catastrophic quality,
documented earlier this session). Correcting an already noisy/low-signal
print can manufacture a spurious false-match artifact rather than real ridge
structure — the model amplifies whatever weak minutiae-like noise exists,
good OR bad. Still 0/4 genuine beat the impostor max either way, but the
margin is now clearly worse-case than the small-sample result suggested.

**2. NEW signal (no ink needed): 5 real same-user cross-session pairs**
(two independent real captures of presumably the same finger, different
sessions) — tests whether correcting BOTH images makes them match EACH OTHER
better. Genuinely mixed: **3/5 improved** (one substantially — `9bdc9f85` vs
`fcfa2e93` roughly tripled, ~17.8 -> ~44 avg), but **2/5 regressed**,
including `ccb9c85a` vs `f2fa606b` dropping from an already-good ~17.85 down
to ~0.2 — a real regression on a pair that was already working.

**Conclusion, revised from the earlier single-cluster result**: the
correction has real, sometimes dramatic positive potential, but is **NOT a
uniform win** — it can hurt already-good matches and can turn noise into a
false positive on garbage input. This rules out ever blind-replacing the
existing pipeline output. It reinforces the project's own standing
discipline: wire in as ONE more max-of-variants candidate (never force-
replace), so per-capture NFIQ2/matchability-based selection picks whichever
variant actually wins, and existing quality gating keeps catastrophic inputs
(like sunlight captures) from being trusted on a spurious score.

## Synth-trained model tested on REAL MAC3D captures vs the ink scan — biggest real gain of the session (2026-07-18)
Per the CTO's ask, applied the synth-trained checkpoint (930 SD302d prints,
val 0.345->0.249) to the actual deployment domain: all 14 real MAC3D captures
in `scratchpad/safis_imgs/`, SourceAFIS-matched against the CTO's real ink
scan (not a SD302 proxy). 4 of the 14 are the CTO's own same finger (uid
`Sgsk0mvnECac`: `3e54236a`/`c34911b5`/`382cc4b2`/`722ae3b0`), the other 10 are
real impostors.

**Uncorrected baseline**: genuine mean 5.45, impostor mean 4.39 (max 10.08) —
already mildly positive separation (+1.06), but 0/4 genuine beat the impostor
max; `c34911b5` scored a flat **0** (SourceAFIS found zero matching minutiae).

**After the deform correction**: genuine mean **7.48** (+2.03), impostor mean
**2.74** (-1.65, impostor max dropped to 8.31) — separation **+4.74**, a 4.5x
improvement, moving in BOTH directions at once (genuine up, impostor down).
**`382cc4b2` scored 13.67, beating the corrected impostor max of 8.31 — the
first real case all session where a genuine pair would actually be
distinguishable from every impostor.** `c34911b5` went from a flat 0 to 3.01 —
real matchability where there was previously none. Caveat stated plainly: n=4
genuine examples is small, not a statistically overwhelming result, but it's
real, measured on the actual deployment domain, and the clearest positive
signal the prime directive has produced this session — stronger than the
cross-domain SD302f test (where correction helped but 0/42 ever beat the
impostor max). Consistent explanation: MAC3D's own captures vs the CTO's own
ink scan is a cleaner single-subject domain than 21-subject SD302f-vs-SD302abd,
so there was more real signal for the correction to unlock.

## Synthetic-distortion deform training WORKS + first real matchability gain (2026-07-18)
Per the CTO's dataset question, pivoted `ml/deform_correct/` from the dead-end
SD302f contactless-probe pairing to **self-supervised synthetic distortion**:
take clean SD302d contact prints, apply a known physically-grounded
contactless distortion (cylinder foreshortening + elastic, `synth_distort.py`,
physics visually verified), train the net to invert it. Perfect ground truth,
consistent distortion family, clean abundant source. Trained on real GPU (930
prints, 120 epochs, af-south-1). **Unlike SD302f (frozen val, no learning),
this DESCENDED cleanly: val 0.345 -> 0.249, generalizing to held-out prints.**
The machinery was never broken — SD302f just had no learnable shared signal.

**First real-transfer win (the actual gate):** applied the synth-trained model
to REAL SD302f contactless probes and re-ran SourceAFIS vs the SD302a/b/d
contact galleries (`scratchpad/sd302/eval_synth_real.py`). Genuine same-finger
mean **0.120 -> 0.315** (2.6x), and genuine-minus-impostor separation flipped
from **-0.229 (worse than random) to +0.059 (positive)**. This is the FIRST
deformation approach all session to move real contactless->contact matchability
in the right direction. **Honest caveat:** absolute scores still tiny (~0.3 vs
the ~40 SourceAFIS needs; 0/42 genuine beat the impostor max), consistent with
SD302f's near-zero baseline signal — the correction amplifies what little exists
but can't manufacture matchability from near-signal-free data. Real usable
matches need (a) real MAC3D paired data to tune the synthetic distortion to
actual capture geometry, (b) a refined distortion model. But the APPROACH is
now validated as a genuine lever — the synthetic-self-supervision route is the
one to build on, not SD302f pairs. Checkpoint: S3
`deform-correct/deform-synth-sd302d-1784372557/checkpoints/best.pt`.

## Direct sunlight KILLS captures via finger transillumination (2026-07-18) — real root cause of a whole low-scoring test round
Round-3 APK test (capture `ca93829d` + siblings `9b0fb988`/`b1c50ca2`) all
scored catastrophic real NFIQ2 (6-8). Pulled the raw frame: the entire thumb
pad glows **deep monochromatic red** with sharp-but-contrast-free ridges
(laplacian ~30 across ALL 8 burst frames vs ~3000 on good captures; NOT a
frame-selection bug — every frame was equally soft). CTO confirmed these were
shot in **pure direct sunlight**. Root cause is **transillumination**: with the
thumb held behind the phone (pad facing the rear camera), sun hits the nail
side and passes THROUGH the translucent fingertip; tissue/hemoglobin absorb
blue-green and pass red/NIR, so the pad lights up red *from within*, and that
diffuse subsurface glow floods over the SURFACE ridge/valley shadows the camera
needs. Result: ridges are in focus but have almost no contrast → NFIQ2 floor.
Also secondary: held moderately far (`afisWavelengthPx` 17-20 vs the 14 of the
72-scorer; native distance, per the standing wavelength≥15px→catastrophic
finding). **Fix: capture indoors / in diffuse light so the white TORCH becomes
the dominant light and lights the pad by surface reflection (which carries
ridge contrast) instead of sun transillumination — the regime the pipeline was
tuned in. Get the thumb closer so the torch overpowers ambient AND ridges image
finer.** This is a recurrence of the earlier "red ambient-light cast" note but
now with the real cause pinned (sunlight, not a red bulb). Possible future
code-side aid (offered, not built): a capture-time red-cast/low-contrast
detector that warns "move out of direct sun" before firing the burst.

**On the freq-normalizer question (the CTO asked why the 9px px-changer doesn't
rescue a 20px capture):** `afisWavelengthPx` is the NATIVE pre-resample
wavelength (`afis_print.py:1554`, measured before the resample at :1556). The
resample is deliberately capped at `_FREQ_SCALE_MIN=0.7` (raised from 0.35
after the real 24-capture Firestore correlation showed aggressive shrinking
HURTS), so a 20px native only comes down to ~14px, never 9px. And more
fundamentally, resampling changes pixel *spacing*, not optical *resolution* —
downsampling a coarse/soft capture can't invent the crisp ridge definition a
natively-close, well-lit capture records. NFIQ2 measures real ridge clarity,
fixed at capture time. So the normalizer is a mild correction by design, never
a rescue for a far or badly-lit capture.

## deform_correct on SD302f: trained on real GPU, DEFINITIVE NEGATIVE — the data has no generalizable contactless→contact deformation to learn (2026-07-18)
Ran `ml/deform_correct/` end-to-end on real SageMaker GPU (af-south-1
`ml.g4dn.xlarge`, ~$2.81 total across the whole debugging chain, all under
budget) against the 181 real cropped/aligned SD302 pairs. **Conclusion: a
shared deformation network cannot learn a generalizable contactless→contact
correction from this data.** This is a data finding, not a code failure —
every bug found along the way was real and is fixed/committed, but the trained
model converges to ~identity (does nothing) and would not help MAC3D.

**The debugging chain (each layer only visible after fixing the one before,
all committed):**
1. **Training plateau (loss stuck ~0.75).** Root cause: pairs were fed to the
   net at random rotation/scale relative to their galleries, and the net's
   ±12% local-displacement budget physically can't undo a gross global
   misalignment. A brute-force alignment diagnostic proved real signal exists
   (orientation-field loss 1.21 identity → 0.45 under global rotation+scale).
   Fixed with the standard C2CL order: global pre-registration offline
   (`scratchpad/sd302/align_pairs.py`, research-only) + augmentation narrowed
   from rot90 to small rotations (`dataset.py`).
2. **NaN cascade (three distinct real bugs).** (a) SSIM local variance
   `E[x^2]-mu^2` going slightly negative from fp32 round-off → clamp_min(0).
   (b) A single non-finite-loss batch permanently corrupting weights (grad
   clip turns Inf→NaN via inf*0) → skip the optimizer step on any non-finite
   loss. (c) The orientation loss backpropping through `atan2`, whose gradient
   diverges on the uniform white borders that alignment/augmentation create →
   rewrote the doubled-angle field as `(vy/r, vx/r)` (atan2-free, bounded
   gradient; uniform-patch grad 4990→0.28). Plus a GPU-only cuDNN NaN that
   never reproduced on CPU → `nan_to_num` guards on the field + flow, smaller
   orientation-smoothing kernel (91×91→31×31), and a ridge-masked loss.
3. **Frozen val (the real verdict).** Once numerically stable, val loss froze
   at the identity-warp value across lr=1e-4, 1e-3, and 3e-3. **Decisive
   diagnostic: a shared net overfits a FIXED set of 1 or 8 pairs cleanly
   (orient 0.48→0.13), but full 164-pair minibatch training stays flat.**
   That exact pattern = contradictory per-pair targets: each minibatch of 8
   pulls the shared weights a different direction, they average to ~0 flow,
   and the net correctly learns "no consistent correction exists here." The
   residual after global alignment is per-pair crop/alignment NOISE, not a
   shared physical distortion.

**Consistent with the whole session's evidence** — the SD302f→contact
SourceAFIS baseline separation is already near-zero at the raw-data level
(genuine 0.28 vs impostor 0.16); there was never much matchable signal for a
deformation net to amplify. **SD302f is not a productive training source for a
deformation model that helps MAC3D.** The real unlock remains a better paired
reference (real ≥500dpi contact scans of the SAME fingers MAC3D captures, or a
cleaner paired dataset), not more tuning on SD302f. **All the code fixes are
genuine hardening of `ml/deform_correct/` for whenever such data exists** —
the pipeline now trains stably on real GPU end-to-end; it just needs data with
a learnable shared signal. Do NOT re-run SD302f deform training expecting a
different result without first changing the data.

## CTO capture-geometry explanation: thumb-twist mirroring (2026-07-17) — real physical cause, root of the "mirrored print" mystery
CTO explained the actual physical mechanism behind a mystery this project
flagged earlier but never resolved (session note: "CTO directly observed the
prints are mirrored... No code-traceable bug found, so the mirroring's root
cause is still open"): **this capture flow requires the user to twist their
thumb behind the phone to present the pad to the rear-facing lens.** That
twist is physically equivalent to viewing the pad from the opposite side
compared to a direct scan or ink impression (finger pressed straight down,
never twisted) — a REAL geometric mirror baked into the capture ergonomics
itself, not a software bug in the decode/rotation path (consistent with the
earlier finding that decode/rotation code has no traceable flip anywhere).
**Applies to every MAC3D/ClearBridge capture, not just one session's test.**

- **Reticle fix, done**: a Poincaré-index core measurement on a real capture
  (`9b0fb988`) found the true ridge core to the right of the guide centre —
  matching an earlier, independently-derived finding from a different real
  capture (see "BoxFit.cover guideRegion bug" section below: "the whorl core
  sits to the right"). Both measurements were taken from the raw CAPTURED
  (already twist-mirrored) image, so "right" there is actually "left" in how
  the pipeline renders live to the user — which is exactly what the CTO
  directly confirmed seeing. `PadSilhouetteShape.coreTargetDxFrac` set to
  **-0.20** (left) per the CTO's direct, physically-reasoned report, not the
  raw-image measurement — the reticle guides LIVE placement in the
  already-mirrored capture domain, so it needs to match what the user
  actually perceives, not the ink/scanner convention.
- **Enhancement/matching implication, tested, honestly inconclusive**: if our
  captures are systematically mirrored relative to "proper" scan/ink
  convention, every fidelity/AFIS-matching comparison against the CTO's ink
  scan this whole session could have been comparing a mirrored probe against
  a non-mirrored gallery — a real, previously-unexamined candidate root cause
  for the whole prime-directive matchability wall. **Tested directly**: ran
  SourceAFIS (the trustworthy gate this project established) on all 14 real
  captures, normal vs. mirrored, against the ink scan
  (`scratchpad/safis_imgs/`, mirrored versions already existed from an
  earlier bozorth3-based sweep, never previously re-tested with SourceAFIS).
  **Result: mirroring did NOT help on average** — mean score dropped 1.53 →
  0.92, normal orientation won 9/14 captures vs. mirrored winning 5/14. This
  does NOT mean the CTO's physical explanation is wrong (the twist-geometry
  reasoning is sound) — most likely the ink scan's own already-documented
  weaknesses (blur, low contrast, whole-thumb vs. guideRegion coverage
  mismatch, "best I could get") swamp any real mirror signal at this
  reference quality, same "no reliable numeric target yet" limitation
  flagged throughout `docs/FIDELITY_WALL_SCOPE.md`. **Do not apply a
  blanket pipeline-wide mirror to AFIS template generation based on this one
  inconclusive test** — re-test properly once a better reference exists (a
  real ≥500dpi scan, or eventually real SD 302 pairs via `ml/deform_correct/`),
  with rotation and mirror handled together and verified independently, not
  layered on an already-uncertain base image set of unknown prep history.

## Real-device test round fixes (2026-07-17) — after testing the recenter-guide-experiment APK
CTO tested that APK and reported two real problems, both now fixed and merged
into the main dev branch (`claude/recenter-guide-experiment` merged in,
commit `89c4970`):
- **Core-target reticle was invisible.** The original marker (thin 10/18px
  double-ring, 1.5-2px stroke, using the same shifting `accent` colour as the
  guide outline) was real but effectively unnoticeable over a live camera
  feed. Redrawn as a bold, FIXED-gold crosshair reticle (14/26px rings,
  3-3.5px stroke, 4 crosshair ticks, blurred halo) — unmistakable, visually
  distinct from the guide outline's own colour.
- **Secondary-camera/distance-stage-2 shots fired "blindly."** Root cause:
  `_finishAndUpload` flipped the UI to "Uploading…" at the very top of the
  function, BEFORE the secondary-camera/distance-stage-2 capture blocks ran
  (which fire their own torch shots of the same thumb placement) — so the
  user saw "done, uploading" and moved/looked away before those extra shots
  actually fired. Fixed with a new `FrontCapturePhase.capturingExtra`
  (explicit "Hold still — capturing extra detail…" banner, guide + camera
  preview kept visible) shown for that whole window; `uploading` now only
  triggers right before the real Firestore write + main upload begin. Side
  effect: also fixed `distanceHint` text never displaying (was gated on
  `showGuide`, which excluded the phase it was actually set during).
- **Real backend bug found via live Firestore data**: capture `a6bd9f81`
  (2026-07-17) got `nfiq2Score: 898` written — impossible, NFIQ2 is 0-100.
  Root cause: `nfiq2_service/app.py`'s `/score` route called `nfiq2 -i <path>`
  WITHOUT `-F` (the flag that forces NFIQ2's documented CSV format this
  project's own local build was calibrated against), so the generic
  permissive parser (shared with `/match`, which has no fixed range) picked
  up the wrong field. Fixed: always pass `-F`; added a stricter
  `_parse_nfiq2_score()` for `/score` only that prefers the documented CSV
  column and hard-validates the result is in [0,100], returning None (existing
  502 path) rather than ever writing an impossible value again. Added the same
  range check as a second gate in `nfiq2_client.py` (last stop before
  Firestore). **Confirmed the secondaryCameras Firestore-rules fix (`c13f45a`)
  IS working in production** — both real captures from this test round have
  real `secondaryCameras` data with real paths, `secondaryCameraDebug` showing
  `2_ok`/`3_ok: true`. `distanceStage2` stayed empty both times
  (`reachedNearZone: false`) — working as designed (best-effort, 6s timeout),
  not a bug.
- **Observation, not yet actioned**: both real captures from this round had
  `afisWavelengthPx` 14.0 and 20.0 — well above the pipeline's `_TARGET_PERIOD
  =9.0` target. Per this project's own established finding (native ridge
  wavelength ≥15px correlates with catastrophic real NFIQ2; 9-11px scores
  well), this suggests the thumb was held at the wrong distance during this
  test round — a capture-technique point worth flagging to the CTO directly,
  not a code fix. **DIRECTION CORRECTED 2026-07-18 (this note originally said
  "too far" — that is BACKWARDS):** higher wavelength = held too CLOSE. Real
  Firestore evidence across ~10 captures: wl>=17 (nfiq2 5-9) had mean
  `afisMaskCoverPx` ~262k (big pad in frame = close), wl<=14 (nfiq2 72) had
  ~167k (small pad = farther); the wl 9/11/14 captures all scored 72. This is
  just optics — closer thumb = more magnified = more px per physical ridge =
  higher px wavelength. So the fix is to hold the thumb FARTHER (pad smaller
  in the guide) so wavelength drops to the 9-14 sweet spot. Corollary: the
  on-screen guide SIZE controls capture distance — a bigger guide makes users
  hold closer (worse). The +5% mask enlargement (done to stop clipping) likely
  pushes wavelength UP into the bad zone; holding farther fixes BOTH clipping
  and wavelength, so the guide arguably wants to be smaller, not bigger.
- **None of this is deployed/built yet** — backend fix needs the standard
  explicit deploy go-ahead; app fixes need a new APK build + real-device
  confirmation, same as every other capture-side change this project.

## PRIME DIRECTIVE (CTO, 2026-07-16) — matchability, not NFIQ2
NFIQ2 is already ~70% consistently even without the MAC3D dataset. The real
problem is **ridge continuity / true AFIS matchability**: a high NFIQ2 is
worthless if the print doesn't actually match the same finger in an AFIS
database. Optimize matchability by any means (web research, downloading
models/datasets allowed); exhaust everything doable solo before Beta. See
**`docs/FIDELITY_WALL_SCOPE.md`** for the full plan.

**Session finding (2026-07-16, three independent tools agree — this is a firm
wall, not a theory):** stood up **SourceAFIS 3.18** locally (Java+Maven,
`scratchpad/sourceafis/`, a much stronger matcher than bozorth3) and re-scored
all 14 real captures. It STILL can't separate genuine from impostor: genuine
cross-capture mean 2.8 vs impostor 1.2, **0/10** genuine pairs beat the
impostor max (SourceAFIS needs ~40 for a real match). ORB+RANSAC (matcher-
independent) confirms it: `3e54236a` vs `c34911b5` — SAME finger, BOTH NFIQ2
**72** — share **0** geometrically-consistent features / 0 homography inliers.
So the high NFIQ2 measures ridge-like *texture*, not fingerprint *identity*;
the binarized AFIS template is largely Gabor-*synthesized* plausible ridges,
not a repeatable transcription of true minutiae. Tested `render=`
binary/continuous/raw as a possible lever — none separated genuine/impostor,
and binary yields the most mindtct minutiae, so binary is confirmed correct;
the `render=` experiment was **reverted** (production stays binary-only).
**Root cause per the literature (C2CL, Grosz/Jain TIFS 2021):** our pipeline
has no cross-domain geometry-correction stage — no perspective rectification,
no TPS/RTPS elastic-deformation correction toward contact-print geometry —
which is exactly the part that makes contactless prints AFIS-matchable.
**Measurement blocker:** the single low-quality CTO ink scan can't tell a
match from a non-match, so there is no reliable numeric fidelity target yet —
the top priority is a better ≥500-DPI reference and/or a public paired dataset
(RidgeBase/PolyU/ISPFD/NIST SD 302, all CTO-side: license forms + NIST hosts
are egress-blocked here). **Use SourceAFIS, not bozorth3, as the fidelity gate
from now on; select on cross-domain match score, never NFIQ2, for fidelity.**

### Prime-directive scaffolds built 2026-07-17 (all committed; all GATED on the paired dataset)
Everything below is built, self-tested where possible, and **waiting on a real
paired dataset** to validate/tune — nothing here is proven to move real match
scores yet, and none is wired into production selection.
- **`ml/fidelity_benchmark/`** (committed, self-tested, no data needed yet):
  `ingest.py` indexes RidgeBase / NIST SD 302 / generic layouts into
  (subject, finger, modality) records + genuine/impostor cross-modality pairs;
  `benchmark.py` has the verification metric core (EER, TAR@FAR, d′) + the
  `select_variant` matcher-based selection comparing `nfiq2`/`minutiae`/`oracle`
  strategies. This produces the first real genuine/impostor ROC the moment data
  lands. **Run `python3 ingest.py --selftest` / `benchmark.py --selftest`.**
- **`functions/processEnhanceAndScore/geom_correct.py`** — C2CL-style geometry
  correction: `cylindrical_rectify()` (single-image cylinder-foreshortening
  undo, fully implemented) + `elastic_flatten()` (parametric RTPS placeholder).
  Wired as `afis_print.generate(geom='cyl'|'cylElastic')`, default OFF,
  self-skipping, NOT in `main.py`'s variant list.
- **Fidelity-oriented enhance modes in `afis_print.py`**: `enhance='gaborVarFreq'`
  (per-region local ridge-frequency Gabor) and `enhance='fidelity'` (local-freq
  Gabor + a ridge-CONFIDENCE gate that blanks hallucinated ridges). Also default
  OFF, NOT in the production variant list. **Measured negative on 5 fingers**:
  both cut impostor false-matches (the right direction) but over-prune genuine
  signal at first-guess thresholds — the recurring lesson that **fidelity-
  oriented enhancement cannot be tuned on 5 noisy fingers without overfitting.**
  The Gabor bank SYNTHESISES ridges everywhere → aggressive synthesis buys NFIQ2
  not matchability; fidelity needs the opposite instinct (less hallucination).
- **`enhance='gaborPyfingField'`** (2026-07-17): swaps pyfing's neural
  Snfoe/Snffe orientation/frequency estimators in for this module's own
  classical ones, feeding the SAME Gabor bank as `gaborVarFreq` (isolates the
  field-estimate question). **Measured: real NFIQ2 win (mean 62.9 vs
  gaborVarFreq's 52.9, beats it 10/14) but real matchability LOSS (SourceAFIS
  genuine mean 9.3 ≈ impostor mean 9.4 — worse than gaborVarFreq and
  production).** The clearest single demonstration this session of the prime
  directive's thesis: NFIQ2-quality and matchability pulled in opposite
  directions. Not adopted — quality win doesn't matter if matchability loses.
- **External impostor check** (`github.com/Chenhao03/DATASET`, 55 public-domain
  contactless fingerphotos, one per subject = a real impostor population):
  SourceAFIS almost never false-matches (impostor mean 0.07, max 5.6, 0 pairs
  ≥20) — confirming it's a trustworthy gate — while our genuine same-finger sits
  faintly above (mean 5.6, max 14.2). A faint real identity signal exists to
  amplify; SourceAFIS is confirmed the right gate.
- **Capture-side:** `claude/recenter-guide-experiment` branch adds a ridge-core
  target cue to the capture guide (UI-only, no mask change) — device-testable
  A/B for whether guiding the user to seat the whorl core in the guide lands
  more matchable minutiae. The `camera` plugin has no JPEG-quality knob, so the
  only real raw-quality lever left is RAW/DNG (native, gated on the
  `rawSensorSupport` Phase-0 check that needs a device to report).

## Deformation-correction training pipeline (`ml/deform_correct/`, 2026-07-17)
Built the learned piece `geom_correct.py`'s `elastic_flatten()` has been stubbing
as an identity placeholder for — a network trained on real paired NIST SD 302
data (contactless probe → contact gallery) to correct cross-domain geometry,
per the prime-directive research (C2CL/Grosz-Jain TIFS 2021). `model.py`
(`DeformFieldUNet` + differentiable `SpatialTransformer` warp, single-image
input only — no paired gallery exists live in production), `dataset.py`
(subject-disjoint splits by finger key), `train.py` (loss is primarily ridge-
**orientation** similarity — a differentiable torch reimplementation of
`afis_print._orientation_field`'s own math, chosen over raw pixel similarity
since probe/gallery are different sensor modalities that don't share pixel
statistics — plus small-weight SSIM and flow-smoothness), `build_manifest.py`
(relative paths, so the manifest works inside a SageMaker container),
`sagemaker_launch.py` (dry-run by default, `--go` required to spend, managed
spot, hard runtime cap, prints cost estimate first). Smoke-tested end-to-end
on synthetic placeholder data in-sandbox (full loop: load → forward → warp →
loss → backward → checkpoint → ONNX export → ONNX Runtime inference, all
verified). **Not yet run on real data.** The real validation gate is the
SourceAFIS genuine-vs-impostor ROC (`ml/fidelity_benchmark/benchmark.py`) on
the exported ONNX model, never the training loss itself or NFIQ2 — same
standing discipline as everywhere else in this project.

## AWS SageMaker + S3 — real credentials live, infra confirmed (2026-07-17)
CTO provided real AWS credentials (root-level — explicitly overrode the
recommendation to use a scoped IAM user after being shown the blast-radius
tradeoff) to train `ml/deform_correct/` on real SD 302 data. **No secrets are
recorded in this file or anywhere in the repo** — credentials live only in
each sandbox's local `~/.aws` config (profile `clearbridge`), session-scoped,
never committed. CTO set a $20 AWS Budgets alert as an independent safety net.
- **Confirmed live** against account `085068687041` ("ClearBridge") via a
  read-only `sts:GetCallerIdentity` call before doing anything else.
- **The existing NNS-training infrastructure is directly reusable, no new
  setup needed**: S3 bucket `clearbridge-fingerprint-training-085068687041-af-
  south-1-an` and IAM role `ClearBridgeSageMakerRole` (region `af-south-1`,
  same region as the Cloud Run functions).
- **Real finding, checked before assuming**: not every AWS region offers
  SageMaker GPU *Training* jobs (some only offer GPU for *Studio* notebooks).
  Verified via the AWS Pricing API that `ml.g4dn.xlarge` Training **is**
  available in `af-south-1` — real on-demand price **$0.977/hr** (~$0.34/hr
  spot). A 4h-capped job worst-cases at ~$3.90 on-demand / ~$1.37 spot, well
  inside the $20 budget — no region change needed.
- **This sandbox still cannot reach `nigos.nist.gov` directly** (403,
  consistent with the earlier-documented egress block) — the CTO downloads
  SD 302 via **AWS CloudShell** instead (runs on AWS's own network, not
  subject to this sandbox's restriction), streaming each file straight into
  S3 via `curl | aws s3 cp -` (never touches CloudShell's own small disk),
  inside a `tmux` session so it survives the browser tab losing focus.
  Verified real transfer content directly via S3 byte-level reads (not just
  trusting terminal output) before trusting the larger transfers — the two
  small files came through as real CSV/text content, not an HTML error page,
  confirming the tokenized NIST links authenticate correctly.
- **In progress as of this session**: `SD302a.zip` (2.05GB) confirmed
  complete; `SD302b/d/f` were transferring. `SD302f` (~66GB, the contactless
  part) is the long pole. A recurring background check (this session only,
  polls S3 directly) was set up to report progress without the CTO needing to
  babysit CloudShell.
- **Next once the dataset lands**: sanity-check the real NIST folder/filename
  convention against `ml/fidelity_benchmark/ingest.py`'s `_sd302_record()`
  classifier (built from NIST's documented part descriptions, never validated
  against the real archive layout) before trusting `build_manifest.py`'s
  output, then a local CPU smoke pass on real data, then a SageMaker dry-run
  cost estimate for review before any `--go`.

## SD302 baseline calibration: contactless-vs-contact structural gap confirmed on real NIST data (2026-07-17)
With the full SD302 dataset landed in S3 (a/b/d contact scanner parts + f
contactless N2N-rig part), ran the real "critical missing measurement" the
prime directive flagged: SourceAFIS genuine-vs-impostor separation between
SD302f (contactless) probes and SD302a/b/d (contact scanner, real ≥500dpi)
galleries — the same measurement previously only possible against the CTO's
one noisy ink scan.

**Building a working automatic fingertip cropper for SD302f's raw rig photos
took three real, visually-disproven failed attempts before landing on
something trustworthy** (same "verify visually before trusting" discipline
as the guideRegion/mask work): broad HSV skin-tone thresholding grabbed
almost the whole frame; a center-crop heuristic included too much smooth
finger-shaft skin; a "tall narrow blob" HSV+aspect heuristic confidently
cropped background fabric texture on the same test image. Switching to
`afis_print._ridge_confidence` (orientation coherence gated by in-band ridge
energy, already proven this session for reticle placement) looked promising
on a single spot check but **a wider visual check found it was ALSO
regularly fooled** — the rig's own metal support rail has coherent,
energetic oriented texture indistinguishable from ridges to that metric
alone, and a Poincaré-index core search across the full frame got fooled
even worse, by circular/facial content in the loose photos scattered around
the rig as background clutter (a deliberately adversarial-looking scene:
real people's faces on paper, similar in color and local texture to skin).
**Final working approach** (`scratchpad/sd302/crop_and_manifest.py`, not
committed — research-only): (1) restrict the search to an empirically-
observed ROI sub-region (confirmed by eye across 28 real samples that the
rig's finger-insertion slot always lands in roughly the same part of the
frame regardless of which of the rig's 15 cameras took the shot); (2) within
that ROI, gate ridge-confidence by a local orientation-CURVATURE score (near
0 for a straight edge like the rail, near 1 near a real fingertip's
loop/whorl core) — the rail is coherent but never curves, only a real
fingertip does; (3) a post-hoc whole-crop quality re-check (mean
confidence×curvature over the WHOLE crop, not just the seed patch that
picked its center) as a final accept/reject gate, since a good seed patch
can still sit at the edge of an otherwise-bad crop. Net result on the real
40-sample calibration set: 21/40 passed all three gates and were visually
confirmed (grid spot check) to be genuinely centered on real finger ridge
detail, not rig/background clutter — the other 19 were correctly
self-rejected rather than silently contaminating the measurement.

**DPI normalization also needed a real fix mid-flight**: naively reusing
`afis_print._ridge_wavelength` (which clips to [5,20]px, correct for its own
production use case) under-corrected scale on these much-larger raw crops,
where the true native wavelength was often >20px (confirmed: a crop whose
clipped estimate read 20.0 still measured 20.0 after resampling by 9/20,
consistent with the true unclipped wavelength being ~44px). Fixed with an
uncapped variant (`_ridge_wavelength_uncapped`, clip raised to [5,60]) used
only for this calibration's scale correction.

**Result** (SourceAFIS, `scratchpad/sourceafis/`, same tool as every fidelity
measurement this session): genuine (n=42, 21 real cross-domain pairs, cross-
subject SD302f-vs-SD302a/b/d) mean **0.28**, impostor (n=840) mean **0.16** —
genuine trends slightly higher but **0/42 genuine pairs beat the impostor
max (5.31)**, and most genuine scores are literal zero (SourceAFIS found no
matching minutiae at all). **This is the same "no reliable separation"
result already found against the CTO's one noisy ink scan — but now backed
by a real, clean, ≥500dpi reference dataset with 21 independent subjects
instead of 1, and a validated (not just assumed) real-finger crop.** This
substantially raises confidence that the gap is a genuine structural
domain-transfer problem (per the prime directive's standing C2CL/Grosz-Jain
citation), not primarily an artifact of the ink scan's own known quality
issues or of MAC3D's specific capture pipeline. **Directly validates
proceeding with `ml/deform_correct/`'s geometry-correction network** as the
right next lever, rather than continued raw-matching parameter tuning.

**Caveat, stated plainly**: the DPI-normalization wavelength estimate on
these crops was often still landing in the 17-30px range after resampling
(should converge near `_TARGET_PERIOD=9.0`), meaning scale correction on
this quick calibration pass was itself imperfect on noisy real photos, same
category of estimator-convergence issue already documented for
`mindtct_client._estimate_ridge_wavelength_px`. Some fraction of this gap
could still be residual scale mismatch rather than pure geometric/domain
distortion — worth keeping in mind, not a reason to distrust the
directionally-clear zero-separation result.

**First real-data smoke test of `ml/deform_correct/train.py`** (previously
only smoke-tested on synthetic placeholder data): ran against these same 21
real cropped/DPI-normalized SD302 pairs (`scratchpad/sd302/
deform_manifest_smoke.json`, data_root = the cropped-image folder), CPU,
small size/epoch count, purely to confirm the full real-data loop (load →
augment → forward → warp → orientation-similarity loss → backward →
checkpoint) runs end-to-end without a shape/dtype/path error before ever
considering a paid SageMaker run.

## Sidecar service URLs — deploy-only config, NOT in the repo (2026-08-13)
`processEnhanceAndScore` reaches its two Cloud Run sidecars purely through
environment variables, and **neither the variables nor their values exist
anywhere in this repository**:

- **`NFIQ2_SERVICE_URL`** -> the `nfiq2-service` Cloud Run service
  (`africa-south1`). Read by `nfiq2_client.py` and `mindtct_client.py`.
- **`PYFING_SERVICE_URL`** -> the `pyfing-service` Cloud Run service
  (`africa-south1`). Read by `pyfing_client.py`.

**Why this matters more than it looks.** Both clients are written to fail
SILENTLY and non-blockingly by design: if the variable is unset they log an
info line and return `None`, and the pipeline carries on. So losing
`NFIQ2_SERVICE_URL` does not throw — it just means every capture quietly
stops getting a real NFIQ2 score, which is exactly the class of invisible
regression this project already lost three weeks to once (the fabricated-
score bug, see that section). Losing `PYFING_SERVICE_URL` silently drops
the matchability mosaic back to the plain Gabor chain while still writing
the artifact, so it looks like it worked.

**Where they actually live**: set directly on the deployed function's
`serviceConfig.environmentVariables`. They survived every `firebase deploy`
observed so far, but that is deploy-tool behaviour, not a guarantee, and
they are in no config file under version control. A local
`functions/processEnhanceAndScore/.env` (Firebase Functions v2 reads it at
deploy time) makes deploys from a given machine deterministic -- but
`.gitignore`'s "# Secrets - never commit" block covers `.env` and `.env.*`,
so that file is deliberately NOT committed and must be recreated in any new
environment that deploys this function.

**Recovering the values** (deliberately not pasted here -- this repo is
public, and the URLs are live authenticated endpoints): read them off Cloud
Run directly, e.g. `run_v2.ServicesClient().get_service(name=
'projects/clearbridge-dc699/locations/africa-south1/services/<svc>').uri`
for `nfiq2-service` / `pyfing-service`. Confirm what the function currently
has via the Cloud Functions v2 API's
`serviceConfig.environmentVariables`.

**Also required, and separately easy to lose**: the function's runtime
service account needs `roles/run.invoker` on each sidecar, or the calls
return 403 and the same silent degradation follows. Granted for
`pyfing-service` on 2026-08-13.

## Repos & branches
- `origin` (GitHub): `dlveldschoenVertteX/ClearBridge-Mobile-Build` — **now PUBLIC** (flipped
  2026-07-15 specifically to get unlimited free GitHub Actions minutes after both GitHub's
  private-repo minutes and GitLab's free-tier minutes were exhausted). Source is public;
  no secrets live in the repo — CI secrets are GitHub encrypted Secrets / GitLab CI/CD
  variables, injected at build time only.
- `gitlab` (mirror): `clearbridge-project1/ClearBridge-Mobile-Build` — private. `.gitlab-ci.yml`
  builds only `clearbridge_beta` (kept minimal to stay inside the 400 free min/month tier).
  Free tier resets on the calendar month (~the 1st). Not actively used while GitHub Actions
  is unblocked.
- Active development branch: `claude/clearbridge-mobile-github-r8tagm`.

## Standing instruction — CI builds
**Do not automatically trigger or re-trigger a CI build after pushing a fix.** Push code
changes when asked, but wait for an explicit "build it" (or similar) before kicking off or
re-running the GitHub Actions / GitLab CI pipeline. This was an explicit user correction
after burning through CI minutes via automatic rebuild-and-verify loops.

Also note: GitHub Actions' `build.yml` triggers on `on: [push]` unconditionally — pushing
*any* commit (including docs) will auto-start a workflow run as a side effect, even without
me manually invoking it. Flag this to the user before pushing non-trivial commits if it
matters in the moment.

## Three apps in this monorepo
1. **Main app** (`android/`, root) — four-angle + arc-sweep SfM capture flavors.
   **Discontinued 2026-07-15** (see below); the `build` CI job that built it was removed
   from `.github/workflows/build.yml`. App code/flavors left in place, not deleted.
2. **`capture_harness/`** — standalone camera-only test build (mac_capture package only, no
   Firebase/Paystack/MLKit). GitHub Actions job `build-capture-harness`.
3. **`clearbridge_beta/`** — consumer-facing beta app, **front-only single-capture flow**
   (no SfM/oscillation). GitHub Actions job `build-clearbridge-beta`; also mirrored in
   `.gitlab-ci.yml`. This is the active development focus.

## Four-angle / arc-sweep: discontinued (2026-07-15)
User decision: **not moving forward with the four-angle/arc-sweep SfM reconstruction
model.** Same root cause as the beta app's earlier oscillating-capture drop — wider
angular coverage dilutes ridge density in NFIQ's fixed 500×500 model input rather than
adding usable detail. The CI `build` job (built `fourAngle`/`arcSweep` flavors, published
to GitHub Release + Firebase Storage) was removed from `build.yml`; `build-capture-harness`,
`build-clearbridge-beta`, and `deploy-web` remain. App code/flavors were **not** deleted
from the repo — only the CI build step was dropped, in case revisited later.

## Capture pipeline decisions (front-only, current)
- **8-phase oscillating / SfM reconstruction is deliberately dropped for the beta app.**
  Confirmed multiple times (see Notion session logs) that wider angular coverage dilutes
  ridge density in NFIQ's fixed 500×500 model input rather than adding usable detail —
  structurally cannot win. Single front-thumb-pad capture only.
- `FrontCaptureController` (`clearbridge_beta/lib/front_capture_controller.dart`): 1.5s
  hold → 4-shot burst → upload. Burst **alternates ambient/flash** (even index = torch off,
  odd = torch on with EV step -1.0) — an earlier all-flash burst blew out the pad centre
  completely at ~10cm (NFIQ2=9, confirmed via raw burst frame + enhanced_flat.jpg all-white).
- **Secondary-camera (IR/wide-lens) capture ported into front_only_v1, 2026-07-15.** This
  was built + validated on `OscillatingCaptureController` (IR torch shot scored
  competitively with, and on one real device above, the main camera's best frame — see
  `docs/CAPTURE_OPTIMIZATION_SCOPE.md`), and the backend's `secondaryCameras` scoring loop
  in `main.py` is shared/unconditional (not gated to oscillating mode) — but it was never
  wired into `front_capture_controller.dart` since front_only_v1 didn't exist yet when the
  feature was built. Ported directly (best-effort, try/catch per camera, non-blocking):
  after the main burst uploads + Firestore commit, opens each other available back camera,
  fires one torch-lit still, uploads it, records `secondaryCameras` on the doc — all before
  the `processEnhanceAndScore` trigger so the backend's one-time doc read sees it. Not yet
  validated on a real device with this specific app/flow.
- `PadSilhouetteShape.defaultShape` (`packages/mac_capture/lib/src/capture_pad_silhouette_overlay.dart`):
  tapered superellipse guide, shrunk to **top-half of the pad only** per CTO annotation
  (cy=0.37, ry=0.13 — was cy=0.5, ry=0.26). Kept 1:1 with `_scoreRoi` in the controller.
- `guideRegion` is written to Firestore and used **directly as the AFIS mask** on the
  backend (no U-Net segmentation, no fragile ridge-periodicity crop). **Now computed at
  runtime** (`_computeGuideRegion` in `front_capture_controller.dart`), not hardcoded —
  see the BoxFit.cover fix below. If NFIQ looks systematically off-center again, re-derive
  from the actual preview→still transform rather than re-guessing constants.
- **BoxFit.cover guideRegion bug, found + fixed 2026-07-15 (commit `a20e009`) — real
  breakthrough, NFIQ2 jumped from single digits to 72.** The old hardcoded guideRegion
  constants (cx=0.63, cy=0.50, rx=0.13, ry=0.17) were derived by rotating the on-screen
  pad silhouette's raw screen-normalized fraction directly into still-space, silently
  ignoring the `BoxFit.cover` crop+scale that `front_capture_screen.dart`'s
  `_cameraLayer()` applies (`FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge)`
  around a `SizedBox` sized to the swapped preview dimensions) whenever the preview's
  aspect ratio differs from the screen's. Net effect: the backend mask used as the AFIS
  ROI **did not match what the user actually saw on the live capture screen** — it caught
  lower-pad skin creases the on-screen guide never covered. Found only because the user
  sent two annotated screenshots (live on-screen guide vs. a rendered mask overlay with a
  hand-drawn "correct ROI") after explicitly rejecting an incorrect "skin-crease
  contamination" theory floated first — **don't re-derive "why is the print bad" from
  theory when the user says the mask doesn't match what they see; ask for/inspect the
  actual on-screen visual before theorizing.** Fix: `_computeGuideRegion({screenSize,
  previewSize})` now maps the pad silhouette through the same BoxFit.cover math at
  runtime (screen size + preview size both vary by device), then applies the existing
  correct `(u,v) -> (1-v,u)` rotation into still-space. Validated on 3 real post-fix
  captures: 2 of 3 scored real `nfiq2Score` **72** (previous project-wide best was 62;
  previous `front_only_v1` baseline was single digits) — visually confirmed via
  `superprint_afis.png` as a genuinely clean, dense, natural whorl print. Notion session
  log: https://app.notion.com/p/39ea03ed9e7e818bbab5e12207af6570
- NFIQ scores are backend-only, never surfaced to end users (see Notion "NFIQ Visibility
  Policy — Backend Only").
- **NFIQ2 sidecar exists and is live** (`functions/nfiq2_service/`, deployed to Cloud Run
  `nfiq2-service` in `africa-south1`) — the real NIST NFIQ2 binary, called from
  `main.py`/`nfiq2_client.py` as an additive, non-blocking ground-truth check alongside the
  ResNet18 proxy (`nfiqScore`). Written to Firestore as `nfiq2Score` (0-100). `main.py`
  scores whichever image won the internal proxy comparison — either `best_afis_img` (the
  binarized/posterized AFIS superprint) or `best_enhanced` (continuous-tone) — recorded as
  `nfiqSource: "afis"` or `"cylindrical"` on the capture doc.
  - **Do NOT assume the binarized AFIS image is bad input for NFIQ2.** A real production
    oscillating capture scored **70% NFIQ2 via the binarized AFIS template**
    (`nfiqSource: afis`) — proof the binarized rendering is not inherently
    out-of-distribution for NFIQ2, despite NFIQ2 being calibrated on natural scanner
    images. A session on 2026-07-15 incorrectly derived this "binarized = bad" theory from
    first principles after seeing two catastrophic front_only_v1 captures (nfiq2Score 4
    and 6, both `nfiqSource: afis`) and "fixed" `main.py` to always score `best_enhanced` —
    that change was reverted once the 70% counter-example came up. The real cause of those
    two low scores was capture quality (motion blur from AF-lock timing + camera shake +
    a red ambient-light cast in the test environment), not which image type NFIQ2 scored.
    **Before changing anything about which image NFIQ2 scores, pull real Firestore
    `nfiq2Score`/`nfiqSource` history first** — don't re-derive this from theory alone.
  - **NFIQ2 sidecar can't be called directly from this sandbox** — its Cloud Run URL
    (`*.run.app`) is blocked by the sandbox egress policy (only `*.googleapis.com` is
    reachable); same class of restriction as the GHCR/dl.google.com blocks below. Firestore/
    Storage/Cloud Run Admin API (`run.googleapis.com`, to look up the service URL) all work
    fine — it's specifically the deployed service's own generated hostname that's blocked.

## Enhancement model tuning (started 2026-07-15, post-guideRegion-fix)
CTO directive after the guideRegion fix's 72-score breakthrough: tune the AFIS enhancement
pipeline itself (`functions/processEnhanceAndScore/afis_print.py` — Gabor filtering, ridge
frequency normalization, feather blur), which had never been manually tuned. Verify every
change against real `nfiq2Score` (the sidecar), never the ResNet18 proxy alone — same
discipline as everywhere else in this project. The sidecar itself can't be called from this
sandbox (see above) — real validation needs a deploy + real device capture cycle.

**First tuning pass done, committed `abbb7b8`, NOT YET DEPLOYED.** Method: built a local
harness (`nfiq_resnet18.onnx` downloaded once from Storage, run fully offline; scratchpad
`enh_tune/afis_print_tunable.py` + `sweep.py`) that reproduces `main.py`'s exact proxy
scoring closely enough to match its recorded values almost exactly on 5 real captures with
known ground-truth `nfiq2Score`. Used it to sweep Gabor/CLAHE/feather/frequency-clamp
parameters. Findings:
- **Broad correlation across all 24 scored captures**: every capture whose winning variant
  ended with native ridge wavelength ≥15px scored catastrophically on real NFIQ2 (single
  digits), *regardless* of whether/how aggressively frequency-normalization resampling was
  applied. Only 9-11px native wavelength captures scored well (62, 72, 72) — though 9px
  alone wasn't sufficient in one case (`3edf5455`: wl=9, still scored 1, unexplained). This
  points at native capture distance as a bigger lever than post-processing, but the
  enhancement side was still worth tuning within that constraint.
- Changed: `_GABOR_SIGMA_RATIO` 0.56→0.65, `_GABOR_GAMMA` 0.6→0.85 (both broadly positive
  across every real test case, good and bad alike, visually confirmed as finer/more
  continuous ridge lines — no regressions), `_FEATHER_SIGMA` 4.0→2.5 (small, uniformly
  non-negative), `_FREQ_SCALE_MIN` 0.35→0.7 (caps how aggressively the ridge-period resample
  can shrink the image — directly targets the correlation above; improved the local proxy
  +7.2 on the real bad case that had used an 0.5x rescale in production, zero effect on
  captures that didn't need rescaling).
- Final combined check: 4 of 5 real test cases improved or held flat; only the most extreme
  (native wl=20px) dipped slightly — likely beyond what enhancement alone can fix.
- **Not yet confirmed against real NFIQ2** — proxy + visual evidence only so far (except the
  frequency-floor change, which also has real, non-proxy Firestore support). Needs a deploy
  + real device captures to confirm before trusting the gain. Notion session log:
  https://app.notion.com/p/39ea03ed9e7e81ad9beac33f717445b7

## Fidelity/matching axis (added 2026-07-15) — ground-truth minutiae matching sidecar
CTO elevated **fidelity** (does the print structurally/minutiae-match the real finger,
not just score well on NFIQ2) to co-equal status with `nfiq2Score` after comparing our
best real capture (`ccb9c85a`, nfiq2Score 72) against a real inked print and finding ours
visibly noisier despite the good score. Full plan in
`docs/GROUND_TRUTH_MATCHING_SCOPE.md`; CTO decisions: keep capture single-front-pad-only
(NFIQ's fixed 500×500 scoring and real AFIS matching value pull in opposite directions on
capture coverage — don't reopen this), try pretrained enhancement models before collecting
a training dataset from scratch.

**Stream A built and deployed-pending: mindtct/bozorth3 ground-truth matching sidecar.**
Extended `functions/nfiq2_service/` (the existing NFIQ2 Cloud Run service) with `/minutiae`
and `/match` endpoints wrapping NIST NBIS's `mindtct` (minutiae extraction) and `bozorth3`
(minutiae matching, partial-print-capable, no fixed universal pass/fail threshold) — this
is the actual measurement tool for the fidelity axis, separate from and complementary to
NFIQ2's quality axis. New `functions/processEnhanceAndScore/mindtct_client.py` mirrors
`nfiq2_client.py`'s ID-token auth pattern (`extract_minutiae()`, `match_prints()`).

- **NBIS source is vendored into the repo** (`functions/nfiq2_service/vendor/nbis/`, ~9MB,
  see `vendor/nbis/PROVENANCE.md`) rather than fetched from an external URL at Docker build
  time. A first attempt at fetching `lessandro/nbis` (a community mirror — no single
  official NIST-hosted git repo for NBIS exists, unlike NFIQ2's `usnistgov/NFIQ2`; NIST's
  own distribution page 403s automated fetches) directly in the Dockerfile was correctly
  blocked by the session's own safety tooling as an unvetted third-party build dependency.
  Verified the mirror's content is genuine NBIS 5.0.0 (license header, changelog, and every
  file's NIST/ITL project metadata all match NIST's real release) before vendoring, then got
  the user's explicit sign-off on this specific source. Vendored copy trimmed from ~102MB to
  ~9MB (just the packages `mindtct`/`bozorth3` actually link against, traced via their own
  Makefiles) and required one real fix: `-fcommon` added to `CFLAGS` (this 2015-era C89 code
  needs it on GCC 10+, which Ubuntu 22.04 ships — without it, several packages fail to link
  with "multiple definition" errors).
- **Deployed 2026-07-15 to `nfiq2-service` (Cloud Run, africa-south1), revision
  `nfiq2-service-00002-kxl`.** Built via Cloud Build directly from Python (`google-cloud-
  build`/`google-cloud-run`/`google-cloud-storage` client libs) since this sandbox has no
  `gcloud` CLI — source tarball staged through the existing `clearbridge-dc699-nfiq2-build-
  src` GCS bucket, then `ServicesClient.update_service()` to roll the new image out.
  Deploying required a service-account key upload (same pattern as the earlier Firebase
  deploy this session) since no ADC/credentials are configured in this sandbox by default.
- **First real Cloud Build run found and fixed a genuine bug the local test missed**:
  `mindtct`/`bozorth3` compiled fine, but the build-time sanity check (`RUN mindtct ... ||
  true`) reported "not found" — NBIS's top-level Makefile has `it` and `install` as
  *separate* targets (`all: config it install catalog`), so `make it` alone never puts the
  binaries on `PATH`. Chaining `make install` was rejected too: its hardcoded
  `RUNTIME_DATA_PACKAGES := an2k nfiq pcasys` list would `cp` runtime data from `nfiq`/
  `pcasys`, which aren't vendored, and hard-fail. Fix (commit `da4ae5b`): copy the two
  compiled binaries directly to `/usr/local/bin` instead of running `make install` at all.
  Rebuilt, confirmed via the real build log that both binaries now respond with correct
  usage text, then deployed. **Lesson for future NBIS-adjacent work**: `make it` builds
  only; never assume it installs without checking the actual Makefile.
- **Not yet HTTP-smoke-tested** — same known sandbox limitation as the NFIQ2 sidecar itself
  (this sandbox's egress reaches `*.googleapis.com` but not the deployed service's own
  `*.run.app` hostname). Real validation happens the same way NFIQ2 itself gets validated:
  through `processEnhanceAndScore` calling it during an actual capture, not from here.
- **First real baseline match test run, 2026-07-15** (in-sandbox, using the vendored
  `mindtct`/`bozorth3` binaries directly — not via the live HTTP endpoint, which this
  sandbox can't reach). Probe = `3e54236a` (nfiq2Score 72; picked over the other two 72-
  scorers `ccb9c85a`/`c34911b5` by visual ridge-continuity check — `c34911b5` has visibly
  messier/broken ridges lower-right; `3e54236a` and `ccb9c85a` both clean, `3e54236a`
  slightly smoother/less "hairy" at the edges). Gallery = the CTO's ink scan.
  - **Raw score: 3** (essentially a non-match by bozorth3's usual scale). Investigating
    *why* before treating that as a verdict (same discipline as everywhere else):
    measured actual ridge wavelength in each image and found a real ~2.75x scale mismatch
    (mindtct assumes ~500 DPI; nothing was correcting for it). Correcting raised the score
    to 14 with a quick single-ROI estimate — real evidence scale matters, but that quick
    estimate itself turned out unreliable (see below).
  - **CTO directly observed the prints are mirrored** (loop on the wrong side). Checked
    `packages/mac_capture`'s still-image decode path (`decodeStillJpegToLuma`) for an
    app-level mirroring bug — found none, it only rotates for sensor orientation, never
    flips. Swept all 8 rotate/mirror combinations of the (scale-corrected) pair: scores
    only spread 10-18, too narrow/noisy to trust any single orientation as "the" correct
    one (genuine matches typically score far higher). No code-traceable bug found, so the
    mirroring's root cause is still open — the fix that shipped works around the
    ambiguity rather than resolving it (see below).
- **Built real DPI normalization + mirror handling into `mindtct_client.py`**
  (commit `7d359c0`), not a one-off script:
  - `_estimate_ridge_wavelength_px()`: FFT-based ridge-period estimate. The quick manual
    estimate used above wasn't actually reliable — sweeping ROI size on the ink scan gave
    wildly inconsistent results (61px to 163px) because a real photo's lighting/shading
    gradient can dominate the low frequencies a small `min_r` cutoff doesn't exclude.
    Shipped defaults (`roi_frac=0.6`, `min_r=15`) were chosen because they're the ones
    that **converge to a stable answer across a wide range of nearby parameter values on
    both real images** (~11.7px digital capture, ~21.6px ink scan) — convergence, not a
    single lucky number, is what makes an estimate trustworthy on a noisy real photo.
  - `_normalize_dpi()`: rescales toward this project's existing ~9px calibration target
    (same one `afis_print.py` already uses).
  - `match_prints()` now tries the probe both as normalized and mirrored, keeps the
    higher bozorth3 score, and returns a dict (`matchScore`, `mirrorApplied`,
    `rawScoreOriginal`, `rawScoreMirrored`, `probeDpiScale`, `galleryDpiScale`) instead of
    a bare int — full transparency, since nothing else calls this yet.
  - **Honest result with the more rigorous estimate: score 6, mirror did NOT help (5 <
    6)** — actually lower than the quick pass's 14. Real, not tuned to look good: it means
    the quick pass's number was closer by chance, and scale/orientation alone isn't the
    dominant gap for this specific pair. Remaining real candidates, not yet corrected for:
    the ink scan shows the whole thumb while the digital capture's `guideRegion` only
    frames the pad's top portion (a coverage mismatch — not fixable by scale/orientation
    correction alone), and the ink scan photo itself has real quality issues (blur, low
    contrast — the CTO's own words: "the best I could get"). **Do not treat this single
    pair's score as a verdict on fidelity either way** — same "need more real data before
    concluding" discipline as the rest of this project. All test artifacts (probe/gallery
    images at every processing stage) are in this session's scratchpad, not committed.
- **Next real steps**: (1) get more paired ink-scan/digital-capture samples before
  generalizing from one pair; (2) the CTO-chosen "try pretrained enhancement models
  first" experiment — see the new section below for where that stands.

## Pretrained fingerphoto-enhancement models (2026-07-15) — pyfing sidecar built
Per the CTO's "try pretrained first" decision (§ Fidelity/matching axis above), evaluated
existing pretrained models before any from-scratch training. Learned from the NBIS
vendoring experience this same session: pulling in external pretrained weights is the same
class of supply-chain decision as vendoring external source, so applied the same diligence
(verify the source is real/legitimate/maintained, check license compatibility with shipping
in a commercial product, confirm it actually does image enhancement and not just minutiae
extraction) before integrating anything.

**Two originally-identified candidates both ruled out on closer inspection**:
- **FpEnhancer** (github.com/XiongjunGuan/FpEnhancer) — real repo, MIT license, legitimate
  academic author, but trained on ~800 rolled/scanner-quality prints with synthetic noise
  augmentation; its own README warns it struggles on "highly blurry/incomplete images or
  complex backgrounds" — exactly the failure mode a raw fingerphoto presents. Weights only
  distributed via an unverified external Google Drive link.
- **FingerFlow** (`pip install fingerflow`) — real package, MIT license, but
  `extract_minutiae()` only returns minutiae coordinates — **no enhanced image output at
  all**, disqualifying for this use case regardless of quality. Also shows signs of light
  abandonment (last release ~2022).

**New candidate found and adopted: `pyfing`** (github.com/raffaele-cappelli/pyfing,
`pip install pyfing`). Verified clean — MIT license (commercial use/redistribution
explicitly fine), maintainer Raffaele Cappelli is an associate professor at the University
of Bologna and FVC (Fingerprint Verification Competition) co-organizer, author of the
widely-used SFinGe synthetic-fingerprint generator. Pretrained weights ship **inside the
MIT-licensed PyPI package itself** (confirmed via source read — model classes build weight
paths from `os.path.dirname(__file__)`, no external download calls anywhere; the wheel is
~85MB, consistent with bundled `.h5` weights) — no separate third-party host to vet at all,
cleaner than even the NBIS situation. Real peer-reviewed backing: SNFOE/SNFFE (IEEE Access
2024, same author), LEADER (arXiv:2602.15493, claims cross-domain generalization to latent
impressions — the closest published claim to our fingerphoto use case of any candidate
found).

**Built `functions/pyfing_service/`** (Dockerfile + Flask `app.py` running pyfing's
segmentation→orientation→frequency→enhancement pipeline, `SNFEN`/`GBFEN` method choice) as
a **separate Cloud Run sidecar** — CTO's explicit choice over embedding directly in
`processEnhanceAndScore`, since pyfing needs Keras/TensorFlow alongside that function's
existing PyTorch stack; isolating it keeps the shared function's footprint unchanged and
makes it trivial to fully remove if the experiment doesn't pan out. New
`functions/processEnhanceAndScore/pyfing_client.py` mirrors `nfiq2_client.py`'s ID-token
auth pattern (`enhance_fingerprint()`).

**First real test, in-sandbox** (installed `pyfing`+`keras`+`tensorflow-cpu` directly,
ran the Flask app via its test client — no deploy needed to validate the code path): took
a real raw burst frame from `3e54236a` (`front_burst_fl_0.jpg`, red-tinted, needed an
autocontrast stretch first), a crude manual crop (no real `guideRegion` alignment, no
multi-frame fusion — everything the production pipeline already does that this quick test
skipped), and ran both methods:
- **SNFEN (neural): bozorth3 match score 7** against the CTO's ink scan (via the newly-
  built `mindtct_client.match_prints()` normalization) — edges out the production
  pipeline's own tuned output on this exact capture (6), with zero training/tuning and a
  worse (cruder) input crop.
- **GBFEN (classical, non-neural): score 4** — worse than both SNFEN and the current
  pipeline.
- Visually, SNFEN's enhanced output shows a genuinely clean, continuous whorl in the real
  pad region — output saved to session scratchpad, not committed.

**Not yet wired into `main.py`'s `_afis_variants`** — the honest next test is running
SNFEN on the pipeline's own properly `guideRegion`-cropped/aligned image (not a manual
crop) before deciding whether to integrate as a real `('pyfing', ...)` max-of-variants
candidate. `pyfing_service` itself is committed but **not deployed** — needs its own
explicit go-ahead like every other backend change.

### pyfing wired in + measured on all 14 real captures — does NOT currently beat the tuned Gabor pipeline
Wired `enhance='pyfing'` into `afis_print.generate()` (`_pyfing_enhance()`: crops to the
mask bbox, grey-fills outside it, routes through pyfing's SNFEN) and added
`('pyfingSnfen', dict(enhance='pyfing'))` to `main.py`'s `_afis_variants` — same
max-of-variants pattern as every other addition, so it can only ever help, never regress.

**Real bug found in the `pyfing` library itself, not our code**: its `Snfen.run()`
enhancement stage, when called with `dpi != 500`, resizes `image`/`mask`/`orientation`
to a scaled size but resizes `ridge_periods` to the *original* unscaled size — a numpy
`dstack` shape mismatch every time (reproduced standalone: a 465px crop at `dpi=300`
crashes with "index 0 has size 800 and index 3 has size 465"). Their own examples always
call it at `dpi=500`, so this path is presumably untested upstream. **Fix**: pre-rescale
our own crop to the ~500dpi-equivalent domain first (same convention as
`mindtct_client._normalize_dpi` — resample toward `_TARGET_PERIOD`), then always call
pyfing with `dpi=500`, sidestepping the buggy internal rescale entirely instead of
working around a third-party bug with try/except.

**Honest measured result, harness run across all 14 real captures (local pyfing, in-
process, no HTTP sidecar needed for this test)**: `pyfingSnfen` **never won a single
capture** by real NFIQ2 — it ran successfully every time (no failures/fallbacks) but
scored lower than the current tuned-Gabor best variant on all 14, by margins from ~4 to
~31 points (e.g. `3e54236a`: pyfing 53 vs. winner 81; `847fa2d3`: pyfing 24 vs. winner 55).
On the fidelity axis (bozorth-vs-ink), pyfing alone averages ~4.8 vs. the full pipeline's
realized ~5.2 — roughly a wash, with one real exception: `7d7d0162` scored bozorth **8**
via pyfing vs. **5** for the variant that actually won on NFIQ2 that capture — a genuine
fidelity edge NFIQ2-only selection missed on that one capture, but not a broad pattern.

**Conclusion**: a generic pretrained SNFEN, with zero fine-tuning on this project's own
data, does not beat a pipeline that's already been through several real-data-driven
tuning passes (Gabor gamma/sigma, frequency-scale floor, orientation smoothing, mask
coverage, coherence fusion) specifically calibrated against these exact captures. This
tracks — pyfing was trained on its own dataset domain, not fingerphoto captures like
ours. The variant stays wired in (harmless, additive, and a no-op in production today
since `pyfing_service` isn't deployed) in case future pyfing versions or fine-tuning
change this, but **do not expect it to move real scores right now** without either (a)
fine-tuning pyfing on this project's own captures, or (b) a materially different crop/
input than what's already been tried here.

### pyfing-then-Gabor hybrid (`enhance='pyfingHybrid'`) — CTO's convention-mismatch hypothesis CONFIRMED, real gain
CTO observation, unprompted and correct: pyfing's own output convention is continuous-
tone with ridges bright on a dark background (near its own internal binary-ish scale),
while this project's entire Gabor pipeline (and every real NFIQ2/bozorth result it's
been tuned against) uses **hard-binarized** black ridges on a white background, gray
only at the feathered mask edge. The pure-`pyfingSnfen` variant's `_pyfing_enhance` was
just doing `255 - enhanced` — a plain intensity invert, not the same transformation as
this pipeline's own binarization. CTO's proposed fix: use pyfing purely to *find ridge
continuity* (its actual trained job — denoise a noisy photo into cleaner ridge
structure), then run that through this project's own tuned Gabor+binarize chain for the
final black/white conversion, rather than inverting pyfing's output directly.

**Built exactly that.** Refactored `_pyfing_enhance` into `_pyfing_denoise()` (returns
pyfing's raw continuous-tone output, still in pyfing's own convention) + a thin invert
wrapper for the existing pure-pyfing path, and added `enhance='pyfingHybrid'`: runs
`_pyfing_denoise()`, then feeds that image through `_normalize` → `_orientation_field`
→ `_gabor_enhance` → the same hard-binarization line every other variant uses. Wired
into `main.py`'s `_afis_variants` as `pyfingHybrid`, max-of-variants alongside
`pyfingSnfen` and everything else.

**Measured on all 14 real captures, hypothesis confirmed real (not just theoretical)**:
- **Hybrid vs. pure pyfing: mean real NFIQ2 jumped 49.4 -> 61.4 (+12)** purely from
  fixing the convention handling — the CTO's observation was pointing at a genuine,
  measurable gap, not a cosmetic one.
- **Hybrid vs. the current best (tuned-Gabor) pipeline**: still trails on 13 of 14
  captures by 10-25 points (e.g. `9bdc9f85`: hybrid 66 vs. winner 83) — the classical
  pipeline's several real-data tuning passes still win on raw quality score. But **it
  now wins outright on one real capture** (`382cc4b2`: 76 vs. the previous winner's 74)
  — a small, real, additive gain now live via max-of-variants.
- **One real fidelity win**: `ccb9c85a` scores bozorth **8** via the hybrid vs. **5**
  for whichever variant wins there on NFIQ2 — a genuine structural-match edge that
  pure-NFIQ2 selection misses, the same pattern seen with plain pyfing on a different
  capture (`7d7d0162`). Reinforces the existing finding that NFIQ2-only selection can
  leave real fidelity gains on the table on specific captures.

**Conclusion**: the convention-mismatch theory was right and fixing it recovered real
score, but doesn't (yet) make pyfing-based enhancement beat this project's own tuned
Gabor chain overall — it's now a genuine, if narrow, additive candidate rather than a
categorically-losing one. Committed (`e3007ff`), not deployed.

## Coherence-enhancing diffusion variant (`enhance='coherenceDiff'`, 2026-07-16) — measured, underperforms as first implemented
Per the CTO's request for a full ridge-continuity optimization scope
(`docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md`), added a classical (no sidecar
dependency) alternative to pyfing: `_coherence_diffusion()` in `afis_print.py`
smooths lengthwise along the local ridge direction (an efficient directional-
kernel approximation of Weickert-style coherence-enhancing diffusion, reusing
`_gabor_enhance`'s own per-orientation-bank architecture rather than a full
iterative PDE solve), then re-estimates orientation on the smoothed image and
runs the existing tuned Gabor bank + binarization on top — same denoise-then-
Gabor pattern as `pyfingHybrid`. Wired into `main.py`'s `_afis_variants` as
`coherenceDiff`, max-of-variants.

**Measured on all 14 real captures**: mean real NFIQ2 **55.1** — worse than the
tuned Gabor pipeline (74.4) on every single capture (never won selection), and
also worse than `pyfingHybrid` (61.4), though better than pure `pyfingSnfen`
(49.4). Bozorth-vs-ink mean 4.64, roughly a wash vs. baseline, with one notable
exception: `382cc4b2` scored bozorth **7** via coherenceDiff vs. **5** for the
capture's actual NFIQ2-selected winner — another real instance of NFIQ2-only
selection missing a fidelity gain on a specific capture (same pattern as the
`pyfingHybrid`/`ccb9c85a` case and the earlier plain-`pyfing`/`7d7d0162` case).

**Likely why it underperforms as shipped**: the smoothing parameters
(`_COH_DIFF_SIGMA=1.2`, `_COH_DIFF_ORIENT_RATIO=2.5`) were a first guess, not
run through the same real-data tuning sweep the Gabor gamma/sigma/frequency-
floor parameters went through earlier this session (see "First tuning pass").
An extra smoothing pass ahead of Gabor plausibly costs high-frequency ridge
energy that NFIQ2 rewards (consistent with this project's own "NFIQ2 rewards
high-frequency ridge-like texture" finding) unless the along-ridge elongation
is tuned much more conservatively. Left wired in as-is (harmless, additive, a
real fidelity win on one real capture) but **not tuned further without a real
reason to prioritize it over the higher-value untested items in the scope
doc** (cross-polarization, multi-camera burst, RAW capture, physical distance
meshing) — a parameter sweep here would cost real iteration time for a
technique that's currently the weakest of the three denoise-pre-pass variants
tried this session (Gabor-only > pyfingHybrid > coherenceDiff > pyfingSnfen on
mean NFIQ2). Committed (`25b6b44`), not deployed.

## NNS-then-Gabor hybrid variant (`enhance='nnsHybrid'`, 2026-07-16) — CTO's own "combine both pipelines" idea, measured underperforms
CTO request: after seeing this project's OTHER, older enhancement model side
by side with the AFIS template on the same real capture (`382cc4b2`:
`enhancement_pipeline.enhance()`'s NNS output scored real NFIQ2 39, visibly
smoother/more continuous ridge-wise than the AFIS binarized template's 76),
asked for a hybrid combining the NNS pipeline's ridge smoothness/continuity
with the AFIS template's NFIQ2 quality — the same denoise-then-Gabor pattern
already used for `pyfingHybrid`/`coherenceDiff`, applied to this project's own
second enhancement model instead of an external one.

**Built exactly that.** `_nns_denoise()` in `afis_print.py` crops to the mask
bbox, grey-fills outside it, and runs `enhancement_pipeline.enhance()` (CLAHE
+ multi-scale Gabor + trained `FingerprintUNet`) as a denoise pre-pass, then
feeds the result through this module's own `_normalize` → `_orientation_field`
→ `_gabor_enhance` → hard-binarization chain — same pattern as the other two
hybrids. Unlike pyfing, NNS's own output convention already matches this
project's (ridges dark, background light — confirmed via
`enhancement_pipeline.ink_scanner_style`'s docstring and `_postprocess`'s
contrast-stretch), so no invert was needed. Wired into `main.py`'s
`_afis_variants` as `nnsHybrid`, max-of-variants. Committed (`3a8b3f4`).

**Measured on all 14 real captures**: mean real NFIQ2 **50.1** — never won
selection on any capture (one near-tie: `847fa2d3` at 55 vs. the winner's own
55), worse than `coherenceDiff` (55.1) and `pyfingHybrid` (61.4), roughly on
par with pure `pyfingSnfen` (49.4) — the worst-performing of the three
denoise-pre-pass hybrids tried this session (Gabor-only > pyfingHybrid >
coherenceDiff > nnsHybrid ≈ pyfingSnfen on mean NFIQ2). Bozorth-vs-ink mean
4.57, a wash vs. baseline, no standout fidelity win this time (best deltas
were only +1: `ccb9c85a` 6 vs. 5, `382cc4b2` 6 vs. 5).

**Conclusion**: the NNS pipeline's smoother continuous-tone output does NOT
translate into a better post-Gabor-binarized result — likely because its own
enhancement stages (CLAHE + multi-scale Gabor + `FingerprintUNet`, tuned
against a completely different objective — the ResNet18 proxy's continuous-
tone scoring, not real NFIQ2 on a binarized template) already discard or
reshape ridge information in a way that doesn't compose well with a SECOND
independent Gabor pass on top. This is the same lesson as `coherenceDiff`: an
extra denoise/smoothing stage ahead of this project's own tuned Gabor bank
is not automatically additive just because the pre-pass looks visually
smoother — it has to be measured, not assumed. Left wired in as a harmless,
additive, max-of-variants candidate; not prioritized for further tuning over
the untested capture-side items in `docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md`.

## Background contamination in AFIS masking — real fix, 2026-07-15
CTO flagged real background contamination degrading scoring, and named the exact prior
solution: a trained fingerprint segmentation model + flash captures as the finger-vs-
background signal. Investigation confirmed both **already exist and are already validated**
in this codebase — `sfm_pipeline._segment_via_flash_diff` (flash-minus-ambient
differencing; the torch falls off with distance², so it isolates near-camera surfaces
almost regardless of background brightness/texture) and the trained U-Net
(`_get_thumb_seg_session`/`thumb_seg_unet.onnx`, ~1.94M params, trained on flash-diff
pseudo-labels) — but **both were completely bypassed for `front_only_v1`**: `guide_mask`
(the static, purely-geometric `guideRegion` silhouette) short-circuited straight past any
content-aware check whenever present (`afis_print.py`'s old `if guide_mask is not None:
mask = guide_mask` — zero per-capture awareness of what's actually in the frame).

**Fix (commit `84ea9c6`)**: `afis_print.py`'s `generate()` now intersects the guide mask
with a flash-diff mask (primary — `ambient_burst`/`flash_burst` frames are already
downloaded for `front_only_v1` via `_download_front_burst`, confirmed reaching every
variant in `main.py`'s `_afis_variants` loop, not just the `deepFuse` one) or falls back to
the U-Net mask (when no usable ambient/flash pair exists). New `afisMask` values:
`'guide+flashdiff'` / `'guide+unet'`, alongside the existing `'guide'` when neither
refinement is available. **Can only ever shrink the mask toward the guide's own bounds**
(intersection — never introduces new background outside the guide) **and falls back to the
guide mask alone if a refinement wipes out >65% of it** (likely a failed/misfiring
segmentation, not evidence the guide itself is wrong) — cannot regress a previously-good
capture, same discipline as every other change in this pipeline.

**Verified against a real capture (`3e54236a`)**: the guide mask was already well-aligned to
the visible pad on this specific capture — refinement kept 96% of its area, trimming only
thin slivers at the top/bottom edges where the guide oval slightly overshoots the
ridge-bearing pad (confirmed via a visual overlay: red = old guide boundary, green =
refined boundary, both sitting on real finger skin, no background in either). **The severe
background contamination visible in this session's earlier pyfing test images was from my
own crude manual crop for that experiment, not the production pipeline's real masking** —
worth being precise about, since they look superficially similar but have different causes.
Re-ran the pyfing SNFEN test on the properly guide+flashdiff-masked crop (clean, no
background at all): **bozorth3 match score unchanged at 7** — the fix didn't move this
specific test's number (mindtct's own minutiae extraction apparently already discounted the
plain wall texture in the cruder crop), but it's still the right, principled fix per the
CTO's ask, and matters more for captures with textured/patterned backgrounds (wood-plank
desks, patterned wallpaper — the exact cases `_segment_via_flash_diff`'s own docstring
already documents defeating brightness-only thresholding).

**Not yet deployed** — needs its own explicit go-ahead like every other backend change.

## Thumb orientation in diagnostic images — display-only, no pipeline bug
CTO noted raw thumb images shown in-session were sideways and asked for upright framing
going forward (explicitly cosmetic, not a quality-metric concern). Checked: the actual
production AFIS output (`superprint_afis.png`) is **already rotated upright** correctly via
`afis_print.py`'s `_upright_from_tip` (uses `guideRegion.tipAngleDeg` — the app knows
exactly which way the tip points on the portrait screen — deterministic, not a PCA guess).
The sideways images were specifically **raw burst frames** (e.g. `front_burst_fl_0.jpg`)
downloaded and displayed directly for the pyfing experiment, which are unrotated sensor-
orientation JPEGs never passed through the pipeline's own upright-rotation step. No pipeline
change needed or made — going forward, rotate raw/diagnostic frames upright before display
whenever showing them for review.

## Real NFIQ2 + bozorth3 now run LOCALLY in-sandbox (2026-07-16) — major unlock
Previously all real-NFIQ2 validation needed a deploy + on-device capture (the Cloud Run
sidecar's `*.run.app` host is unreachable from the sandbox). Both ground-truth tools now
build and run locally:
- **Real NIST NFIQ2 2.3.0** built from source: `git clone --recursive
  https://github.com/usnistgov/NFIQ2` (github.com clone works; only release-asset
  downloads 403), then the CMake superbuild — needed `apt-get install libdb-dev
  libdb++-dev libsqlite3-dev libssl-dev libjpeg-dev libpng-dev libtiff-dev
  libopenjp2-7-dev libhwloc-dev` for its `libbiomeval` dependency (Berkeley DB + OpenJPEG
  were the two blockers). Binary at `/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2`,
  model at `.../share/nist_plain_tir-ink.txt`. CLI: `nfiq2 -m MODEL -i IMG.png -F` prints
  the bare score. **Calibrated**: resize to 500×500 LANCZOS first (exactly as
  `nfiq2_client` does) → exact match to production's recorded `nfiq2Score=72` on `3e54236a`.
- **NBIS mindtct/bozorth3**: already vendored (`functions/nfiq2_service/vendor/nbis/`),
  build copy in scratchpad.
- The proxy ONNX (`nfiq_resnet18.onnx`) and `thumb_seg_unet.onnx` are both pullable from
  Storage `models/` (googleapis reachable) → the U-Net mask path and the exact production
  proxy scorer also run locally.
- Harness (`scratchpad/harness.py`, not committed): runs the real `afis_print.generate()`
  variants on all 14 real front captures, scores each with real NFIQ2 + bozorth-vs-ink.

### CRITICAL measurement finding — do NOT optimize blindly to NFIQ2
- **Real NFIQ2 is FOOLABLE on our prints.** A visually-garbage front capture (`5aa18155`,
  broken/choppy discontinuous ridges, vertical crease artifacts, no coherent whorl) scored
  real NFIQ2 **77**. NFIQ2 rewards high-frequency ridge-*like* texture regardless of whether
  it's a faithful print. So NFIQ2 is a **floor/sanity check, NOT the optimization target** —
  selecting the "best" variant purely by NFIQ2 will happily pick a high-scoring garbage
  render. (This also explains the proxy's total unreliability — proxy 76 → real NFIQ2 9 in
  production history.)
- **The single ink scan is too weak to be a fidelity target.** bozorth3-vs-ink is only
  valid on the CTO's OWN captures (same finger: uid `Sgsk0mvnECac` = `3e54236a`,
  `c34911b5`, `382cc4b2`, `722ae3b0`). On those it sits at **4–5** — and *different* people's
  captures score bozorth 4–7 against the same ink scan too. So at this quality level bozorth
  cannot distinguish same-finger from different-finger; absolute values 4–7 are noise floor.
  The ink scan's own low quality ("best I could get" — blur, low contrast) is the limiter.
- **Consequence: there is no reliable *numeric* fidelity target yet.** "Optimize until the
  match score is high" is not honestly achievable with current ground truth. What IS
  reliable: **visual ridge continuity/coverage**, plus the tools as floors. To unlock real
  fidelity optimization we need a **better ground-truth reference** — a proper ≥500-DPI
  scanner/ink-card capture of the CTO's finger (ideally a few fingers), which is exactly the
  `ml/mac3d_enhance/DATA_SPEC.md` gap.
- **Root-cause finding (most important):** on the CTO's own captures the static `guideRegion`
  oval is sometimes **MIS-CENTERED off the ridge-dense pad** — on `3e54236a` the whorl core
  sits to the *right*, largely outside the guide, while the guide covers the fainter left
  pad (confirmed via a red=guide/green=detected-pad overlay). This mis-alignment — not just
  coverage size — is a likely real reason match quality on the CTO's own finger is mediocre.
  Content-aware pad detection (flash-diff/U-Net) re-centers onto the actual dense-ridge
  region; longer-term the on-screen capture guide placement itself should be improved so the
  pad's ridge core lands inside the guide.

### Two CTO-reported print defects fixed (commit `906c0f8`, NOT deployed)
- **Whole-pad coverage** (`_MASK_COVER_DILATE=1.3` in `afis_print.py`): the mask now expands
  from the detected real pad (flash-diff/U-Net) toward the pad tip the tight guide oval cut
  off, clipped to a dilated guide so it can't grab background/hand. Set to 1.3 not higher —
  a 1.6 sweep measurably hurt a well-placed capture (`c34911b5` local NFIQ2 79→68) by
  reaching into poor-contact periphery. Note: the "choppy top" seen on some expanded prints
  is real poor-contact ridge signal at the pad top (a *capture* issue), not a masking bug.
- **Flash specular smudge** (coherence-fusion variants `fuseMaxc`/`fuseSoft`/`deepMaxc` added
  to `main.py`'s `_afis_variants`): `deepFuse` hardcoded flat `avg` fusion, which keeps a
  blown-out flash centre half-bright and washes out the ridges there. The coherence modes
  (already in `_fuse_flash_ambient`, never wired as variants) per-region take whichever
  exposure resolves ridges best, winning the specular centre back from the ambient exposure.
  Confirmed on `3e54236a`: maxc superprint is a clean, fully-covered whorl with the centre
  smudge gone (real NFIQ2 57→81, visually verified). Coherence-fusion variants win on 6 of
  14 captures; max-of-variants, so purely additive. **This is the more solid of the two
  fixes** (verified visually + wins as a real variant), vs. coverage which the noisy metrics
  can't confirm.

## CRITICAL: production capture pipeline was hanging forever — found + fixed (2026-07-16)
First real device test of the new APK (capture `9efb7d1e`, 18:51 UTC) got stuck at
`status: "enhancing"` and never completed — confirmed via Cloud Run logs still
running 2+ hours later. Root cause: `processenhanceandscore`'s Cloud Run service has
a **2-minute request timeout** (`run_v2.ServicesClient` config check), but the real
log trace showed the gap between adjacent `_afis_variants` entries `deepFuse`
(18:54:48) and `deepMaxc` (19:10:08) was **15 minutes 20 seconds** — `deepFuse`/
`deepMaxc`/`deepSoft` each independently redid the expensive ambient/flash burst ECC
alignment (`_stack_face_on`) from scratch, even though all three share identical
inputs and differ only in the final (cheap) fusion mode. This capture's flash frames
scored unusually low sharpness (Laplacian ~60-73 vs. ambient ~3100-3345, a 40-50x
gap) — ECC likely struggled to converge, and that cost got paid 3x instead of once.
This is pre-existing architecture from an earlier session's commit (`906c0f8`), not
something introduced by this session's pyfing/coherence/nns additions — but this was
apparently the first real capture to actually exercise `deepMaxc` in production,
exposing it. **This was a full outage**: every real capture reaching the fuse family
(nearly all of them, since ambient+flash bursts are always preserved) would hang
forever and never reach `status: "scored"`.

**Fixed**: `afis_print.generate()` gained a `stack_cache` parameter (request-scoped
dict, never a module-level/global cache to avoid stale reuse across different
requests on a warm Cloud Run instance) — `main.py`'s variant loop creates one fresh
`{}` per request and passes it to every `generate()` call, so `_stack_face_on(ab)`/
`_stack_face_on(fb)` compute once and get reused across `deepFuse`/`deepMaxc`/
`deepSoft` instead of 3x. Also added a 70s wall-clock budget on the whole
`_afis_variants` loop as an independent safety net (stops trying further variants
once exceeded, scores with whatever's already been produced — same as a variant
self-skipping, can't make the result worse). **Verified locally**: `deepMaxc` on a
real capture dropped from 15.9s to 4.7s reusing the cache (same real NFIQ2 score,
81); full 14-capture regression sweep afterward matched the pre-fix baseline exactly
(mean 74.4, same winning variant per capture) — zero regression.

**Also raised the Cloud Run request timeout** 120s → 300s (`main.py`'s
`@https_fn.on_call(timeout_sec=...)` — the actual source of truth `firebase deploy`
applies each time, not a raw Cloud Run API edit which would be silently reverted on
the next deploy) as a safety margin — 120s left almost no headroom even for a normal
capture once cold model downloads (~15-55s per real logs) are counted, and the 70s
variant budget already bounds runaway work internally so the higher ceiling costs
nothing by itself. **Deployed** (both fixes together, `firebase deploy --only
functions:python-pipeline`).

**Still needed, not yet done**: get a real device to re-test and confirm a capture
now reaches `status: "scored"` — this fix is deployed but not yet confirmed against
a real capture. The `secondaryCameras`/`distanceStage2` missing-fields mystery
mentioned here has since been root-caused and fixed — see the section below.

## Root cause found + fixed: secondaryCameras/distanceStage2 fields silently never wrote (2026-07-16)
Following up on a real device test where the CTO saw the flash fire again during
the "uploading" screen (after the CTO believed capture was already done) — the
secondary-camera and distance-stage-2 code WAS running (that's the extra flash),
but its results kept coming up completely absent from Firestore, not just empty.

**Root cause, confirmed via the live Firestore ruleset** (fetched directly from
`firebaserules.googleapis.com`, active release `fb550ede-382d-4c36-b501-137c3b459579`,
deployed 2026-07-02 — there's no local `firestore.rules` file in this repo, rules
are managed purely via Firebase console/deploy): the `captures` collection's
security rules are

```
allow create: if request.auth != null
  && request.resource.data.userId == request.auth.uid
  && request.resource.data.get('status', 'pending') == 'pending'
  && request.resource.data.get('nfiqScore', 0) == 0
  && request.resource.data.get('nfiqPass', false) == false
  && !('scoredAt' in request.resource.data)
  && !('processingStartedAt' in request.resource.data)
  && !('lastCaptureCallAt' in request.resource.data);
allow update, delete: if false;
```

A document's first write is evaluated against `allow create`; every subsequent
write to that same doc is evaluated against `allow update` instead — which this
ruleset blanket-denies for non-admin clients. `front_capture_controller.dart`'s
`_finishAndUpload` wrote the initial capture doc via `.set(..., merge: true)`
(allowed, since the doc didn't exist yet), then tried to record
`secondaryCameraDebug`/`secondaryCameras`/`distanceStage2Debug`/`distanceStage2`
via two later `.update()` calls — both **silently rejected** every single time
(wrapped in `try { ... } catch (_) {}`, so the failure was invisible client-side
too). This was true from the moment the secondary-camera feature was first built
in an earlier session — never a regression, just never actually working. It also
meant `main.py`'s secondary-camera/distanceStage2 scoring loops (already deployed)
had never had real data to act on either.

**Fix, per the CTO's explicit choice of restructuring the app over loosening the
rules** (`front_capture_controller.dart`'s `_finishAndUpload`): moved the entire
secondary-camera capture block and the entire distance-stage-2 capture block to
run **before** the Firestore document write instead of after, and folded their
resulting `secondaryDebug`/`secondaryMeta`/`distanceDebug`/`distanceStage2` data
directly into that one `.set(..., merge: true)` call. Both blocks only ever
touched Cloud Storage for their own image uploads (via `_uploadWithRetry`), which
has no such create/update distinction, so nothing about their own logic needed to
change — only the ordering, so everything lands in the single `create`-evaluated
write instead of two always-rejected `update`-evaluated ones. The two `.update()`
calls were deleted outright rather than kept as dead code. Deliberately did NOT
touch the production security rules themselves, per the CTO's explicit "go with
option 1" (app-side restructuring) over the alternative (loosening `allow update`
for these specific fields).

**Not yet device-tested** — same discipline as every other capture-side change
this session: this compiles/reviews clean (manual brace-balance check; no Dart
toolchain in this sandbox) but needs a real APK build + real capture to confirm
`secondaryCameras`/`distanceStage2` actually populate in a real Firestore doc now.

## Capture-side scope items 2-4 built, NOT YET DEVICE-TESTED (2026-07-16)
Per `docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md` + the CTO's "let's go according
to your recommendations": items #1 (validate the `906c0f8` deploy on a real
device) and #2 (cross-polarization test) both need the CTO to physically act, so
built the three remaining engineering items in parallel, all **unverified beyond
`py_compile`/manual brace-balance checks — no Dart/Kotlin toolchain in this
sandbox, no real device.** Do not treat any of these as working until an APK build
+ real capture confirms them.

- **Secondary-camera burst + EV tuning** (`front_capture_controller.dart`
  ~lines 765-812): each IR/ultrawide secondary camera now fires a 3-shot burst
  (`_secondaryBurstCount`) instead of one still, with `setExposureOffset(-1.0)`
  applied first (the same anti-blowout EV step already validated for the main
  flash burst — confirmed safe: only `setExposureMode()`, never called here,
  triggers the Camera2-interop/torch conflict). `secondaryCameras` docs now
  carry a `paths: [...]` list (was a single `path`). `main.py`'s secondary-camera
  loop (~line 751) picks the sharpest via the same Laplacian-variance pattern as
  `_best_frame_from_paths`, backward-compatible with the old single-`path` schema.
- **Physical distance-guided capture, Phase 0** (`front_capture_controller.dart`:
  new `_waitForNearDistanceZone()`/`_captureDistanceBurst()` methods, called
  after the secondary-camera block and before the `processEnhanceAndScore`
  trigger): reuses the existing `_scoreRoi` coverage signal and `_coverageMax`
  threshold to detect a meaningfully closer distance zone (6s bounded timeout,
  never blocks the primary result if the user doesn't move), re-focuses, fires
  a 3-shot alternating ambient/flash burst tagged `distanceZone: 'near'`. This
  is a self-contained bonus stage, NOT a re-entry into the main hold/burst state
  machine — deliberately avoids touching the already-tuned primary capture-
  quality logic. `main.py` scores the sharpest stage-2 frame as one more
  independent single-frame candidate (`afisSource: 'distanceStage2'`) — no
  fusion math, per `docs/MULTI_DISTANCE_MESH_SCOPE.md`'s own Phase 0 design.
- **RAW/DNG capability check, Phase 0** (`MainActivity.kt`: new
  `MethodChannel('clearbridge/cameraCapabilities')` reading each camera's
  `CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES` for `RAW_SENSOR`
  support — a read-only query, no capture): result cached and attached to the
  capture's own Firestore doc as `rawSensorSupport`. **Deliberately NOT a
  revived diagnostic screen** — the prior one was explicitly removed (commit
  `4a832c0`) as "test-only tooling with no place in the current build"; this is
  silent, no new UI. Purely informational for now — answers "does any real
  device support RAW_SENSOR" before committing to the much bigger native
  RAW-capture platform-channel lift.

**All three need a real APK build + real device capture before trusting them.**
Watch for: the distance-stage-2 timeout actually resolving (not hanging the
upload flow), the secondary-camera burst not exceeding per-camera session
limits on real hardware, and whether `rawSensorSupport` ever comes back true on
any device in the fleet (if not, the RAW/DNG item is dead on arrival, per the
scope doc's own Phase 0 gate).

## Known Android/Gradle gotchas (already fixed, keep in mind for new flavors/plugins)
- **Partial-ABI APK / "can't unzip" crash on install**: plugin AARs (camerax, TFLite,
  datastore) bundle prebuilt `.so` for arm64-v8a + armeabi-v7a + x86_64, but
  `--target-platform android-arm64` only compiles `libapp.so`/`libflutter.so` for arm64,
  leaving other ABI dirs partially populated → Android's ABI selector picks a broken one.
  Fix is `packaging.jniLibs.excludes` (strips at final packaging step) — `ndk.abiFilters`
  does **not** work, it only controls JNI compilation, not prebuilt-lib stripping.
- **Debug keystore path mismatch across runners**: the release signing config falls back to
  the built-in "debug" SigningConfig's storeFile when no real release keystore secret is
  configured, and a pre-build step generates that keystore if missing — but the path must be
  read from `android.signingConfigs.getByName("debug").storeFile` directly, **not**
  hardcoded to `~/.android/debug.keystore`. Some runners (confirmed on a GitHub-hosted
  `ubuntu-latest` runner, 2026-07-15) resolve AGP's actual debug keystore location to the XDG
  path `~/.config/.android/debug.keystore` instead, and a hardcoded path silently generates a
  keystore nobody looks up while `validateSigningRelease` still fails "not found".
- **Stable release keystore not yet activated**: `scripts/generate_release_keystore.sh`
  exists to generate a permanent signing cert, but the user hasn't run it / configured
  `KEYSTORE_BASE64` + `KEYSTORE_PASSWORD` + `KEY_ALIAS` + `KEY_PASSWORD` as CI secrets yet.
  Until then, every CI build signs with a freshly-regenerated debug keystore, so upgrading
  over a previous install still requires uninstalling first (cert mismatch). This is a
  one-time setup task still pending.

## CI minutes / build-environment notes
- Building **inside this Claude Code sandbox is not viable** for Android/Flutter: the
  session's egress policy blocks both the GHCR blob-storage CDN
  (`pkg-containers.githubusercontent.com`, needed for `docker pull` of CI images) and
  Google's Android SDK/Maven host (`dl.google.com`, needed for AndroidX/Gradle deps even
  with a natively-installed Flutter SDK). Don't retry this path — it's a deliberate org
  egress restriction, not a fixable config issue.
- A real alternative if GitHub/GitLab CI is ever blocked again: the user has an AWS
  SageMaker account with credit. A SageMaker notebook instance is a normal EC2-backed VM
  with unrestricted internet and a terminal — viable for a manual one-off build (install
  Flutter + Android cmdline-tools, clone, build, download the APK via the Jupyter file
  browser, stop the instance). Not automated; would need to be walked through with the user.
- **GitHub Actions artifact downloads are ALSO blocked from this sandbox** (confirmed
  2026-07-16): the GitHub API's artifact download endpoint redirects to a signed Azure
  Blob Storage URL (`*.blob.core.windows.net`), which isn't allowlisted by this session's
  egress policy — `curl` gets a 403 at the CONNECT step (`/root/.ccr/README.md`: "policy
  denial... do not retry or route around it"). Same class of restriction as the GHCR/
  dl.google.com blocks above. Even when a CI build succeeds and produces an APK artifact
  (confirmed working: `build.yml` on `push` builds `clearbridge-beta-apk` +
  `capture-harness-apk` successfully), **the artifact itself cannot be fetched into this
  sandbox to relay to the user** — the user must download it directly from the GitHub
  Actions run page in their own browser (Actions tab → the run → Artifacts section at the
  bottom), which isn't subject to this sandbox's egress policy.
