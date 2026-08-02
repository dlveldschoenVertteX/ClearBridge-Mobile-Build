# Guided thumb-sweep capture — architecture reference (disabled)

## Status

**Disabled as of 2026-07-31 (round 5).** Gated behind one flag in
`clearbridge_beta/lib/front_capture_controller.dart`:

```dart
static const bool _sweepEnabled = false;   // ~line 329
```

At the hold-timer completion point (`_onFrame`, ~line 1139):

```dart
unawaited(_sweepEnabled ? _beginSweepPositioning() : _fireBurst());
```

Flip the flag to `true` to re-enable — nothing else needs to change to turn
it back on. The screen side (`front_capture_screen.dart`) already has all
the sweep UI wired up (ring color/progress, `TRACKING` status pill,
`_SweepProgressBar`, headline text) and is state-driven off
`FrontCapturePhase.sweepPositioning`/`sweepActive`, so it starts rendering
again automatically once the flag flips.

This doc exists because five real-device rounds of fixes are scattered
across inline comments in `front_capture_controller.dart` — this is the
consolidated reference for picking the feature back up.

## The two-phase design

**Phase 1 — `sweepPositioning`**: wait for the thumb to reach a "start"
zone at the guide's left edge and dwell there briefly, so every sweep
starts from a known position instead of wherever the hold happened to end.

**Phase 2 — `sweepActive`**: the same 8-shot alternating ambient/flash
burst as the static path, but fired incrementally as the user sweeps their
thumb rightward — each shot gated on sharpness instead of all 8 firing
back-to-back.

## Phase 1 — `sweepPositioning`

- `_beginSweepPositioning()`: resets sweep state, sets `activeGuideShape`
  to the guide shifted fully left (`_sweepGuideShapeForProgress(0.0)`), and
  kicks off continuous (not locked) autofocus re-aimed at that shifted
  position (`_refocusForSweepPositioning()`).
- `_handleSweepPositioningFrame(image)` (called from `_onFrame` every
  camera frame while in this phase): computes the thumb's screen-space X
  centroid via `_sweepScreenXFraction(image)`. If it's `<=
  _sweepLeftZoneMax` (0.32), starts/continues a dwell timer; once dwelled
  `>= _sweepLeftDwellMs` (400ms), transitions to `_beginSweepActive()`.
- `sweepPositionOk`/`sweepDwellProgress` state fields drive the UI
  (headline "Hold there…" vs "Place thumb…", the ring fill).

## Phase 2 — `sweepActive`

- `_beginSweepActive(startCentroidX)`: re-aims focus at the SAME point
  positioning was already converging on (deliberately — see "Round 4
  regression" below), waits 600ms to settle, locks focus (`FocusMode.
  locked`), captures torch/EV state, then transitions the phase.
- `_handleSweepActiveFrame(image)` (every frame): recomputes centroid,
  drives `sweepProgress` (the guide's shift + progress bar) directly off
  centroid position, checks three completion conditions in order — quota
  (8 shots), early-exit (centroid past `_sweepRightZoneMin` **and**
  `>= _sweepMinValidShots` already captured), or hard timeout
  (`_sweepTimeoutMs` = 6000ms) — then, if not completing, checks the fire
  gate: sharp enough (`_focusValue > 0.45`, the same threshold as the
  static hold) **and** `>= _sweepMinShotIntervalMs` (300ms) since the last
  shot.
- `_fireSweepShot()`: stops the image stream, fires one alternating
  ambient/flash shot (identical convention to the static burst), restarts
  the stream, haptic tick per shot.
- `_completeSweep({success})`: on success, hands the collected
  `_sweepRawShots`/`_sweepCentroids` into the **existing**
  `_fireBurst(preCollectedShots: ..., preCollectedCentroids: ...)` — this
  is why the sweep didn't need its own upload/scoring path; `_fireBurst`
  already branches on whether shots were pre-collected. On failure (didn't
  hit `_sweepMinValidShots` before timeout), shows "Try again — sweep a
  little slower" and loops back to `_beginSweepPositioning()`.

## Key constants (all near line 285 of `front_capture_controller.dart`)

| Constant | Value | What it controls |
|---|---|---|
| `_sweepLeftZoneMax` | 0.32 | positioning: centroid must be ≤ this to count as "at the left edge" |
| `_sweepRightZoneMin` | 0.68 | active: centroid must reach this to allow early completion |
| `_sweepLeftDwellMs` | 400 | positioning: how long the thumb must dwell in the left zone |
| `_sweepTimeoutMs` | 6000 | active: hard cap on the whole sweep window |
| `_sweepMinValidShots` | 4 | active: minimum shots needed for early-exit or timeout-success |
| `_sweepMinShotIntervalMs` | 300 | active: minimum gap between fired shots |
| `_sweepGuideShiftFrac` | 0.15 | how far left/right of center the guide translates |

## The two ROI constants — the part most worth understanding before tweaking

```dart
static const Rect _sweepTrackingRoi = _scoreRoi;                              // narrow — centroid/zone math
static const Rect _sweepFocusRoi = Rect.fromLTRB(0.3385, 0.17, 0.6615, 0.57); // wide — focus targeting only
```

These used to be one shared constant, and that was the round-4 bug:
widening it helped focus-targeting but made the centroid math worse (a
wider ROI compresses every reading toward 0.5, making the 0.32/0.68 zone
thresholds harder to reach); narrowing it back to fix centroid math
silently broke focus again, since both purposes shared the same value. If
you're tuning positioning/zone-reach behavior, touch `_sweepTrackingRoi`.
If you're tuning focus targeting, touch `_sweepFocusRoi`. **Don't merge
them back into one constant.**

## Coordinate rotation — the other thing that bit this feature

`_sweepScreenXFraction()` and `_sweepFocusPointFor()` both encode a 90°CW
raw-sensor-to-screen rotation: the raw buffer's **row** axis maps to
on-screen **horizontal**, inverted. This project's confirmed convention
(same one that fixed the `guideRegion` mask bug elsewhere). If the sweep
ever appears to track vertical motion instead of horizontal, this is the
first place to check — an earlier version tracked the buffer's column
axis, and that was exactly the round-3 bug.

## The 5 real-device rounds

1. **Round 1** (original build): shipped without device testing.
2. **Round 2**: focus locked on background, not thumb — root cause was
   focus staying anchored at the static hold's original point, never
   re-aimed for the shifted guide. Fixed with
   `_refocusForSweepPositioning`.
3. **Round 3**: centroid tracked the wrong axis (column instead of row) —
   the rotation bug above.
4. **Round 4**: fixing round 3's ROI width broke focus again (the
   shared-ROI bug above) — split into `_sweepTrackingRoi`/
   `_sweepFocusRoi`.
5. **Round 5**: still blurry + still no capture firing after all of the
   above. At that point the pattern of "fix one thing, break or fail to
   fix another" was itself the signal to stop and disable rather than keep
   guessing — that's the state it's in now.

Round 5 never got a root cause — it's the actual open question if this
feature is picked back up. Given rounds 2-4 all trace to focus/
coordinate-space issues, the recommended next step is adding real
diagnostic logging (`sweepDebug.centroids` trend, actual focus-convergence
values at fire time) on a re-enabled build **before** changing any logic
blind — same discipline as everywhere else in this project.

## Also present, not sweep-specific but adjacent

- `_lastCentroidX`: a fallback used by both `_handleSweepPositioningFrame`
  and `_handleSweepActiveFrame` when a given frame's centroid estimate
  comes back null (keeps the guide from jumping to center on a single bad
  frame).
- `HybridCaptureService.estimateThumbCentroidX()`
  (`packages/mac_capture/lib/src/frame_capture_service.dart`) is the
  underlying intensity-weighted centroid primitive both sweep ROI constants
  feed into — shared, not sweep-owned, so changes there affect nothing else
  currently (no other caller in the codebase), but worth knowing it's not
  local to the controller.
- `sweepDebug` (written to Firestore only when a sweep actually completes
  a capture): `centroids`, `capturedCount`, `sweepDurationMs`, `timedOut`,
  `leftDwellMs` — the diagnostic trail for whichever real device test comes
  next.
