# ClearBridge Mobile — persistent context

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
