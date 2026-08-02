# Scope: locked shutter speed (native Camera2 lift)

## Context

CTO handoff doc asked for `HybridCaptureService`/`FrontCaptureController` to
pin shutter speed to a constant (`targetShutterSpeedUs = 6667`, 1/150s) for
every burst frame, with auto-ISO compensating for brightness, so NFIQ2/ridge-
wavelength variation reflects real geometric/lighting differences rather than
the camera's own auto-exposure decisions from shot to shot.

Reviewed against the real codebase before building anything (2026-08-02) —
three things in the handoff doc don't hold up:

1. **Named integration points don't exist.** `HybridCaptureService`
   (`packages/mac_capture/lib/src/frame_capture_service.dart`) is a pure
   frame-scoring helper — it never touches a `CameraController` and has no
   `initializeCamera()`. The real owner is `CameraService.initializeCamera()`.
   `FrontCaptureController._captureMainBurst()` doesn't exist either — the
   real burst method is `_fireBurst()`.
2. **The plugin has no API for `setExposureTime()`.** `camera: ^0.11.4`
   (this project's pinned version, via `mac_capture/pubspec.yaml`) has never
   shipped a public manual-sensor-control API — confirmed directly against
   the live `camera_android_camerax` changelog: only `setExposureOffset`,
   `setExposureMode`, `setExposurePoint` (EV bias + metering point, not raw
   sensor control) have ever been added; Camera2Interop usage inside the
   plugin is marked `@OptIn` (internal-only). `CameraService` itself already
   documents *why* it deliberately never calls even the much smaller
   `setExposureMode()`: on this CameraX backend, engaging Camera2 interop on
   the live session **blocks the torch from firing** for the rest of that
   session — the exact mechanism this app's flash/burst logic depends on.
3. **"Shutter locked, ISO auto" isn't a mode Camera2 offers at any layer.**
   `CONTROL_AE_MODE` is binary: `ON` (hardware auto-controls exposure time
   *and* sensitivity together, can't pin one and float the other) or `OFF`
   (app must set **both** `SENSOR_EXPOSURE_TIME` and `SENSOR_SENSITIVITY`
   manually — there's no auto-ISO callback). Even with full native Camera2
   access, "auto-ISO compensates for brightness" means the app has to
   implement its own metering loop (read a brightness signal each frame,
   compute and set `SENSITIVITY` itself) — a real control-loop feature, not
   a flag.

**What's already real and shipped**: the capability probe from an earlier
this-session round (`getManualExposureSupport`/`manualExposureSupportByCameraId`
in `MainActivity.kt`, `manualExposureSupport` written to Firestore) already
answers "does this device's sensor even support manual exposure control at
all" — no new work needed there.

**Stage 1 diagnostic, built this round** (`packages/mac_capture/lib/src/
jpeg_exif_exposure.dart`, wired into `front_capture_controller.dart`'s
`_fireBurst`): reads the real `ExposureTime`/`ISOSpeedRatings` EXIF tags the
camera HAL already writes into every burst JPEG — zero plugin change, zero
native code, just bytes already in hand after `takePicture()`. Written into
each burst frame's existing `frames[]` Firestore entry as `shutterSpeedUs`/
`shutterSpeedReadable`/`isoValue`/`isLockedShutter: false`. This gives real
per-shot auto-exposure variance data from the *next* real capture, before
committing to the native lift below.

This doc scopes that native lift specifically — the part Stage 1 can't
deliver (actual control, not just visibility).

## The core idea

Add a way to fix `SENSOR_EXPOSURE_TIME` for the 8-shot burst while a
software loop keeps `SENSOR_SENSITIVITY` tracking scene brightness — the
literal goal from the handoff doc, minus the mistaken assumption that
Camera2 does the ISO half automatically.

## Two viable architectures

### Option A — Camera2Interop pass-through on the existing CameraX session

Patch (fork) `camera_android_camerax` to add a small platform-channel method
(e.g. `setManualExposure(exposureTimeNs, sensitivity)`) that applies
`Camera2CameraControl.addCaptureRequestOptions` with `CONTROL_AE_MODE=OFF` +
explicit `SENSOR_EXPOSURE_TIME`/`SENSOR_SENSITIVITY` onto the **same live
session** the preview and burst already use — no new session, no teardown.

- **Pro**: avoids camera-session churn entirely — the app keeps one
  continuously-open session, same as today.
- **Con / open risk, unconfirmed**: `setExposureMode()` already engages
  Camera2 interop on this exact backend and that alone blocks the torch —
  `addCaptureRequestOptions` with `AE_MODE_OFF` is a deeper interop
  engagement on the same session, so it may hit the identical torch
  conflict, or worse. This is the single biggest unknown and should be
  tested cheaply (see Phase 0 below) before any real build effort.
- **Con**: means pinning a local fork of the plugin (git dependency, not
  pub.dev) — a real ongoing maintenance cost every time the plugin cuts a
  new release.

### Option B — standalone parallel Camera2 session for the burst only

New native MethodChannel that briefly closes the CameraX-owned session,
opens a raw `CameraDevice`/`CameraCaptureSession` directly, fires the 8
manual-exposure stills (with the app's own software auto-ISO loop), closes
that session, and hands control back to CameraX for the live preview.

- **Pro**: doesn't depend on patching/forking the pub.dev plugin; fully
  owned by this app's own native code.
- **Con — this is the same risk category this project has already declined
  twice.** The RAW/DNG platform-channel effort and the noise-reduction
  Camera2-override research spike (`CLAUDE.md`, 2026-07-23) were both
  shelved specifically because they'd add "yet another native camera-
  session open/close cycle... the exact category of risk this session's
  own ANR investigation just traced to camera-session churn." Option B is
  structurally the same shape of change.

## Recommended phased plan (de-risk before committing to either)

**Phase 0 — cheapest possible real-device test, no capture-flow change.**
Extend the existing read-only `clearbridge/cameraCapabilities` MethodChannel
with a one-off diagnostic: on a device that already reports
`supportsManualExposure`, briefly apply `AE_MODE_OFF` + a fixed
`SENSOR_EXPOSURE_TIME`/`SENSOR_SENSITIVITY` via Camera2Interop on the live
CameraX session (Option A's core mechanism) purely to observe whether
`enableTorch()` still works afterward, then immediately revert to
`AE_MODE_ON`. Logs the result (`torchSurvivedManualExposure: bool`) to
Firestore alongside the existing capability fields. This answers Option A's
one real open question directly, on real hardware, before writing any of
the actual burst-integration code — same "measure before you build"
discipline as every other capture-side decision this project has made.

**Phase 1 — only if Phase 0 confirms the torch survives.** Build Option A
for real: the platform-channel method, the software auto-ISO loop (seeded
from the existing `_lastStableBrightness` signal already computed every
frame for the brightness meter — no new metering path needed, just a new
consumer of data already flowing), wired into `_fireBurst` behind a
`useLockedShutter` flag exactly as the handoff doc proposed, defaulting to
`false` so it can only ever be opted into, never regress the current path.

**If Phase 0 shows the torch does NOT survive**, do not build Option A —
fall back to evaluating Option B on its own merits (an explicit go/no-go
given its ANR-risk history), or stop here and rely on Stage 1's diagnostic
data alone to decide whether the noise this whole effort targets is even
large enough to be worth either native path.

## Open questions / risks to carry into implementation

1. Phase 0's own result is unknown — this is the load-bearing question the
   whole plan branches on, not a formality.
2. The software auto-ISO loop's own convergence speed/stability is
   unproven — same "focus convergence may behave differently" caveat the
   handoff doc itself flagged, but for sensitivity instead of focus.
3. Neither this sandbox nor the plugin's own test suite can validate any of
   this without a real device — same standing limitation as every other
   capture-side change this project makes.
4. Stage 1's EXIF diagnostic depends on the device's camera HAL actually
   populating `ExposureTime`/`ISOSpeedRatings` tags in the JPEG — not
   guaranteed on every device; a capture with all-null exposure fields in
   `frames[]` means the tag wasn't written, not that parsing failed.
