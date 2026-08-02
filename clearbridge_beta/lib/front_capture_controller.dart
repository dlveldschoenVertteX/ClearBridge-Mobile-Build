import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback, MethodChannel;
import 'package:mac_capture/mac_capture.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum FrontCapturePhase {
  idle,
  calibrating,
  holding,
  // Guided thumb-sweep capture (2026-07-30, diagnostic-first): two phases
  // inserted between the existing on-target focus-lock (end of `holding`)
  // and the burst actually firing. Replaces "hold still -> fire
  // immediately" with "sweep left-to-right -> fire as qualifying frames
  // pass" -- the burst mechanics themselves (8 shots, Laplacian gate, flash
  // alternation, encode/upload) are unchanged, only the trigger/pacing is
  // new. See FrontCaptureController's _beginSweepPositioning/_beginSweepActive.
  sweepPositioning,
  sweepActive,
  capturing,
  // Primary burst is done and already scored well enough to keep — now
  // grabbing best-effort secondary-camera (IR/ultrawide) and distance-stage-2
  // bonus shots of the SAME thumb placement. Distinct from `uploading` so the
  // UI can tell the user to hold still instead of implying capture is
  // already finished (see the 2026-07-17 "fires blindly" report: the extra
  // torch shots used to fire while the phase already said "Uploading…", so
  // the user had already moved/looked away).
  capturingExtra,
  uploading,
  complete,
  error,
}

class FrontCaptureState {
  const FrontCaptureState({
    this.phase = FrontCapturePhase.idle,
    this.onTarget = false,
    this.holdProgress = 0.0,
    this.isCapturingBurst = false,
    this.burstProgress = 0.0,
    this.extraProgress = 0.0,
    this.uploadProgress = 0.0,
    this.captureId,
    this.error,
    this.confirmationText,
    this.distanceHint,
    this.isSteady = true,
    this.lightingValue = 0.5,
    this.activeGuideShape,
    this.sweepProgress = 0.0,
    this.sweepCentroidX,
    this.sweepFastWarning = false,
    this.sweepPositionOk = false,
    this.sweepDwellProgress = 0.0,
  });

  final FrontCapturePhase phase;
  final bool onTarget;
  final double holdProgress;
  final bool isCapturingBurst;
  // Guided thumb-sweep (sweepPositioning/sweepActive phases): the thumb's
  // last-known intensity-weighted centroid X position, normalized 0.0 (left
  // edge of the guide ROI) to 1.0 (right edge) -- drives both the moving
  // highlight on the horizontal band overlay and the fill of the sweep
  // progress bar (sweepProgress mirrors it 1:1; kept as a separate field so
  // the UI can read "progress" without knowing it's just the raw centroid).
  final double sweepProgress;
  final double? sweepCentroidX;
  // True when the current frame's sharpness is below the fire-gate
  // threshold during sweepActive -- drives the highlight's orange
  // "moving too fast" state (green otherwise).
  final bool sweepFastWarning;
  // True during sweepPositioning once the thumb's centroid is actually
  // inside the left zone (dwelling, about to transition to sweepActive) --
  // real device-test feedback (2026-07-30 round 3): with no visible signal
  // that positioning was even being evaluated, a stuck sweep looked
  // identical to a working-but-slow one ("just static"). Drives a text/
  // colour change in the UI so detection is visibly happening.
  final bool sweepPositionOk;
  // Fraction (0..1) of the left-zone dwell timer elapsed during
  // sweepPositioning -- drives the outer progress ring so it fills (silver,
  // matching the classic burst-progress look) as soon as the thumb reaches
  // the left zone, instead of sitting empty the whole time positioning is
  // in progress.
  final double sweepDwellProgress;
  // Fraction of the main burst fired so far (0..1) -- drives the pad-guide
  // fill animation during FrontCapturePhase.capturing, same "fills up as
  // capture progresses" cue the oscillating dial's scan-fill arc already
  // gives (CTO real-device feedback 2026-07-20: front_only_v1 had no
  // equivalent progress indicator).
  final double burstProgress;
  // Fraction of the "extra capture" work done during FrontCapturePhase.
  // capturingExtra (secondary cameras + the distance-stage-2 attempt) --
  // drives the pad-guide fill during that phase. CTO real-device feedback
  // 2026-07-22: unlike the main burst, secondary cameras (wide lens/IR) had
  // no progress cue at all -- the guide sat static the whole time.
  final double extraProgress;
  final double uploadProgress;
  final String? captureId;
  final String? error;
  final String? confirmationText;
  final String? distanceHint;
  // False while the device is being held too unsteadily (gyroscope-derived)
  // for the hold timer to progress -- surfaced separately from onTarget so
  // the UI can tell the user specifically to hold the phone still, distinct
  // from "align your thumb".
  final bool isSteady;
  // Normalised 0..1 brightness read from the ROI (torch-off samples only),
  // for the lighting meter alongside the focus meter.
  final double lightingValue;
  // Overrides the on-screen guide shape during capturingExtra's secondary-
  // camera turns (see _secondaryCameraGuideShape) -- null means "use
  // PadSilhouetteShape.defaultShape".
  final PadSilhouetteShape? activeGuideShape;

  FrontCaptureState copyWith({
    FrontCapturePhase? phase,
    bool? onTarget,
    double? holdProgress,
    bool? isCapturingBurst,
    double? burstProgress,
    double? extraProgress,
    double? uploadProgress,
    Object? captureId = _sentinel,
    Object? error = _sentinel,
    Object? confirmationText = _sentinel,
    Object? distanceHint = _sentinel,
    bool? isSteady,
    double? lightingValue,
    Object? activeGuideShape = _sentinel,
    double? sweepProgress,
    Object? sweepCentroidX = _sentinel,
    bool? sweepFastWarning,
    bool? sweepPositionOk,
    double? sweepDwellProgress,
  }) =>
      FrontCaptureState(
        phase: phase ?? this.phase,
        onTarget: onTarget ?? this.onTarget,
        holdProgress: holdProgress ?? this.holdProgress,
        isCapturingBurst: isCapturingBurst ?? this.isCapturingBurst,
        burstProgress: burstProgress ?? this.burstProgress,
        extraProgress: extraProgress ?? this.extraProgress,
        uploadProgress: uploadProgress ?? this.uploadProgress,
        captureId: identical(captureId, _sentinel) ? this.captureId : captureId as String?,
        error: identical(error, _sentinel) ? this.error : error as String?,
        confirmationText: identical(confirmationText, _sentinel)
            ? this.confirmationText
            : confirmationText as String?,
        distanceHint:
            identical(distanceHint, _sentinel) ? this.distanceHint : distanceHint as String?,
        isSteady: isSteady ?? this.isSteady,
        lightingValue: lightingValue ?? this.lightingValue,
        activeGuideShape: identical(activeGuideShape, _sentinel)
            ? this.activeGuideShape
            : activeGuideShape as PadSilhouetteShape?,
        sweepProgress: sweepProgress ?? this.sweepProgress,
        sweepCentroidX: identical(sweepCentroidX, _sentinel)
            ? this.sweepCentroidX
            : sweepCentroidX as double?,
        sweepFastWarning: sweepFastWarning ?? this.sweepFastWarning,
        sweepPositionOk: sweepPositionOk ?? this.sweepPositionOk,
        sweepDwellProgress: sweepDwellProgress ?? this.sweepDwellProgress,
      );
}

const _sentinel = Object();

class _BurstEncodeArgs {
  final Uint8List luma;
  final int width;
  final int height;
  const _BurstEncodeArgs(this.luma, this.width, this.height);
}

Uint8List _encodeBurstIsolate(_BurstEncodeArgs args) =>
    encodeGrayscaleJpeg(args.luma, args.width, args.height);

class _RawShot {
  final Uint8List jpeg;
  final bool flashOn;
  final double? laplacianScore;
  final DateTime timestamp;
  // Real per-shot exposure time/ISO read straight out of the JPEG's own
  // EXIF (see JpegExposureExif) -- what the auto-exposure pipeline actually
  // did, not anything the app requested.
  final JpegExposureExif exif;
  const _RawShot({
    required this.jpeg,
    required this.flashOn,
    required this.laplacianScore,
    required this.timestamp,
    this.exif = const JpegExposureExif(),
  });
}

/// Front-only single-burst capture controller.
///
/// Simplified flow: camera opens → calibrate → user seats thumb in guide →
/// auto-fire burst (ambient+flash pairs) → upload → processEnhanceAndScore.
///
/// captureMode='front_only_v1' so the backend's dedicated front-only downloader
/// picks it up (no SfM reconstruction, no oscillation, pure AFIS single-frame
/// + deep-fuse variants).
class FrontCaptureController extends ChangeNotifier {
  // 4 ambient + 4 flash. Bumped from 4 (2+2): a bigger candidate pool raises
  // the odds afis_print's ridge-energy single-frame selection lands on a
  // genuinely sharp shot -- the real-data pattern behind this project's best
  // scores (four-angle/oscillating captures with 12-24 total frames vastly
  // outscored front-only's fixed 4) -- and gives the deepFuse variant (now
  // wired in for front_only_v1) a real multi-frame stack per illumination
  // instead of the bare 2-frame minimum.
  static const int _burstFrameCount = 8;
  static const int _burstShotDelayMs = 0;

  // Burst+video hybrid capture, Phase 0 (2026-08-02, see
  // docs/BURST_VIDEO_HYBRID_SCOPE.md): best-effort video recorded right
  // after the main burst, while the user sweeps their thumb left-to-right,
  // giving the backend oblique-angle candidate frames the static burst/hold
  // can never capture. Fixed duration, not "user confirms sweep complete"
  // (the handoff spec's alternative) -- simplest safe first cut, same
  // reasoning as the disabled guided-sweep feature's own fixed timeout.
  static const int _sweepVideoDurationMs = 6000;
  // Bounds the record-start -> record-stop -> read-bytes sequence only
  // (NOT the upload after it, which has its own legitimate retry/backoff
  // and shouldn't be killed for being slow on a bad connection). 6s
  // recording + generous margin for native start/stop/flush overhead --
  // same proportion as this file's other camera-operation timeouts (e.g.
  // the secondary-camera path's 28s bound against its own, heavier,
  // multi-shot sequence). A hang here is caught by .timeout() rather than
  // blocking the whole capture forever the way an uncaught-hang camera
  // Future would -- try/catch alone does not protect against that.
  static const int _sweepVideoRecordTimeoutMs = 15000;

  // Instant kill-switch for the whole video-sweep step, same pattern as
  // the disabled guided-sweep feature's own _sweepEnabled -- if a real
  // device test finds a problem, flip this to false, commit, push, rebuild.
  // No revert or branch surgery needed to detach this specific feature
  // from everything else on this branch. The backend's own sweepVideoCandidates
  // scoring block (main.py) is already inert whenever no video was
  // uploaded, so this one flag fully controls the feature's real-world
  // effect regardless of what's deployed backend-side.
  static const bool _sweepVideoHybridEnabled = true;
  // decodeStillJpegToLuma's own default (2048) was chosen purely for
  // decode speed/peak-memory safety on budget devices (still_jpeg_
  // downscaler.dart's own docstring), never evaluated as a data-quality
  // tradeoff. The on-screen pad guide only covers ~46%x38% of the frame
  // (capture_pad_silhouette_overlay.dart's defaultShape, rx=0.23/ry=0.19),
  // so at 2048px wide the actual pad region is only ~900-950px across
  // before any further processing -- discarding most of a modern sensor's
  // native detail before the crop even happens. Same principle already
  // proven to matter at a later pipeline stage (two-step downscale before
  // NFIQ's 500x500 resize -- preserving more source resolution before a
  // downsample measurably helps via better anti-aliasing). Bumped to 3200
  // (~2.4x the decode's peak memory, not full native res) as a first,
  // conservative test of the same principle here -- needs a real device
  // capture + NFIQ2/SourceAFIS comparison against the 2048 baseline before
  // trusting it; revert if budget devices show memory/latency regressions.
  static const int _stillDecodeTargetWidth = 3200;
  // Secondary-camera (IR/ultrawide) burst depth. Was a single takePicture()
  // per camera with no sharpness ranking -- a short burst here lets the
  // backend keep the sharpest shot per camera (same Laplacian-variance
  // pattern already used for the main burst), same rationale as the main
  // burst's own frame-count bump above.
  static const int _secondaryBurstCount = 3;
  static const int _burstFlashSettleMs = 70;
  // EV multipliers applied to flashEvStep across the 4 flash shots in the
  // main burst. flashEvStep is negative (reduces exposure to guard against
  // torch blowout), so:
  //   0.5× = lighter reduction = brighter effective flash (catches dark scenes)
  //   1.0× = standard (the adaptive curve's own recommendation)
  //   1.5× = heavier reduction = darker flash (hard blowout guard)
  //   0.75× = intermediate
  // The backend picks the sharpest frame via Laplacian ranking; the bracket
  // gives it 4 real exposure candidates instead of 4 identical ones.
  // Works via setExposureOffset() -- no hardware variable-intensity flash
  // needed, same safe API already proven for the adaptive EV step itself.
  static const List<double> _flashEvBracketMultipliers = [0.5, 1.0, 1.5, 0.75];

  // Guided thumb-sweep capture (2026-07-30, diagnostic-first): replaces the
  // static "hold still -> fire immediately" trigger with two phases inserted
  // between the existing on-target focus-lock and the burst firing --
  // sweepPositioning (wait for the thumb to reach + dwell at the guide's
  // left edge) then sweepActive (fire the same 8 shots as the user sweeps
  // right, gated on sharpness same as before). Burst mechanics themselves
  // (_burstFrameCount, the 0.45 sharpness gate, flash alternation, encode/
  // upload) are UNCHANGED -- only the trigger/pacing of individual shots is
  // new. See _beginSweepPositioning/_handleSweepPositioningFrame/
  // _beginSweepActive/_handleSweepActiveFrame/_fireSweepShot/_completeSweep.
  // Loosened 0.25/0.75 -> 0.32/0.68 (2026-07-30 round 3): a real device test
  // showed the thumb correctly, visibly seated in the shifted guide never
  // registered as "left zone" (positioning stuck indefinitely). The main fix
  // was reverting an unrelated tracking-window widening that had compressed
  // every reading toward 0.5 (see _sweepTrackingRoi's own note) -- this
  // extra margin is a deliberate, honest hedge on top of that fix: the exact
  // raw-buffer-to-screen scale was never independently, precisely calibrated
  // (only reasoned from this project's known 90° rotation convention), so a
  // more forgiving threshold is safer than an exact-but-possibly-still-off
  // one. Worse case if this is now too loose: the sweep resolves a little
  // early -- far better than the confirmed real failure mode of never
  // resolving at all.
  static const double _sweepLeftZoneMax = 0.32;
  static const double _sweepRightZoneMin = 0.68;
  static const int _sweepLeftDwellMs = 400;
  // Hard bound on the whole sweepActive window -- the UX target pace is
  // 2.5-4s (fast enough to feel natural, slow enough that 8 qualifying
  // frames can clear the sharpness gate), so this timeout sits comfortably
  // above that ceiling rather than cutting off a merely-slightly-slow sweep.
  static const int _sweepTimeoutMs = 6000;
  static const int _sweepMinValidShots = 4;
  // Minimum spacing between fired shots -- without this, a frame run that
  // sustains above the sharpness gate would otherwise fire on every single
  // camera frame (15-30/sec). ~300ms spacing against an 8-shot quota targets
  // roughly the 2.5-4s sweep window called out in the UX spec.
  static const int _sweepMinShotIntervalMs = 300;

  // Real device-test feedback (2026-07-30): a static guide oval plus an
  // internal highlight band wasn't enough -- the user reported not seeing
  // their finger inside the mask and being asked to move, and asked for the
  // mask itself to move to the side the UX points it to, so the whole
  // finger stays framed as it sweeps. Fixed by shifting the guide's own
  // centre (cx) left during sweepPositioning and interpolating it left-to-
  // right in sync with sweepProgress during sweepActive -- see
  // _sweepGuideShapeForProgress. Round 2 feedback: "needs more distance...
  // a little further" -- raised 0.10 -> 0.15 (0.5 ± 0.15, still comfortably
  // clear of the guide's own rx=0.1346 half-width from either screen edge).
  // Kept deliberately short of _sweepTrackingRoi's own margin below so the
  // fire-gate's sharpness measurement (still scoped to the narrower,
  // already-proven _scoreRoi, not widened this round) has a real chance of
  // resolving near both extremes, not just the centre.
  static const double _sweepGuideShiftFrac = 0.15;

  // Guided thumb-sweep feature flag. DISABLED as of 2026-07-31 round 5
  // after five real device-test rounds each revealed a different failure
  // mode -- most recently a real, honest finding that the sweep's focus
  // math was applying an unnecessary 90°-rotation inversion that the
  // static hold's own working _beginAutofocus() never applied (the Flutter
  // camera plugin's setFocusPoint takes preview-widget coords, not raw-
  // sensor coords), plus a separate concern that the centroid tracker's
  // ROI mapping is not properly validated against real on-screen thumb
  // position. Rather than ship a sixth speculative fix on top, defaulting
  // BACK to the proven static capture flow (real NFIQ2 72-81 history) --
  // the sweep code stays in the repo behind this flag for a future proper
  // rebuild that can validate coordinate transforms against real captures
  // before shipping, not after.
  static const bool _sweepEnabled = false;

  static const int _holdDurationMs = 1500;
  static const int _calibDurationMs = 500;
  static const int _confirmationDisplayMs = 700;
  static const int _emitThrottleMs = 80;
  static const int _uploadConcurrency = 8;
  static const List<int> _uploadRetryDelaysMs = [500, 1500, 4000];

  // docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md item 4, Phase 0: a silent,
  // read-only query (native MethodChannel -> Camera2 CameraCharacteristics)
  // for whether any camera on this device advertises RAW_SENSOR capability
  // -- no capture, no new screen/UI (the prior diagnostic screen was
  // explicitly removed, commit 4a832c0). Queried once per app session
  // (cached statically) and attached to each capture's own Firestore doc,
  // purely so a future RAW/DNG capture path can be scoped against real
  // device data instead of a guess.
  static const _cameraCapabilitiesChannel = MethodChannel('clearbridge/cameraCapabilities');
  static Map<String, bool>? _rawSensorSupportCache;
  static bool _rawSensorSupportQueried = false;

  static Future<Map<String, bool>?> _queryRawSensorSupport() async {
    if (_rawSensorSupportQueried) return _rawSensorSupportCache;
    _rawSensorSupportQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getRawSensorSupport');
      if (result != null) {
        _rawSensorSupportCache = result.map((k, v) => MapEntry(k, v as bool));
      }
    } catch (e) {
      debugPrint('[front] RAW sensor capability query failed (non-fatal): $e');
    }
    return _rawSensorSupportCache;
  }

  // docs/CAPTURE_OPTIMIZATION_SCOPE.md Lever C.1, Phase 0: same read-only,
  // no-capture, no-UI, once-per-session-cached pattern as
  // _queryRawSensorSupport() above -- answers whether real devices even
  // ADVERTISE support for disabling noise-reduction/edge smoothing before
  // any harder live-session Camera2-interop override work is attempted.
  static Map<String, Map<String, bool>>? _noiseReductionSupportCache;
  static bool _noiseReductionSupportQueried = false;

  static Future<Map<String, Map<String, bool>>?> _queryNoiseReductionSupport() async {
    if (_noiseReductionSupportQueried) return _noiseReductionSupportCache;
    _noiseReductionSupportQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getNoiseReductionOffSupport');
      if (result != null) {
        _noiseReductionSupportCache = result.map((k, v) => MapEntry(
              k,
              (v as Map).map((k2, v2) => MapEntry(k2 as String, v2 as bool)),
            ));
      }
    } catch (e) {
      debugPrint('[front] noise-reduction capability query failed (non-fatal): $e');
    }
    return _noiseReductionSupportCache;
  }

  // Real-device finding, 2026-07-23: secondary camera "2" times out on
  // upload far more often than "3" across several real captures (always
  // stuck mid-upload, at a different shot each time), but nothing in the
  // app has ever distinguished WHICH physical lens each raw camera-id
  // string actually is. Same read-only, no-capture, once-per-session-cached
  // pattern as the two queries above -- lets the next real capture's
  // secondaryCameraDebug be cross-referenced against real focal-length/
  // sensor-size data instead of an opaque id.
  static Map<String, Map<String, dynamic>>? _cameraLensInfoCache;
  static bool _cameraLensInfoQueried = false;

  static Future<Map<String, Map<String, dynamic>>?> _queryCameraLensInfo() async {
    if (_cameraLensInfoQueried) return _cameraLensInfoCache;
    _cameraLensInfoQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getCameraLensInfo');
      if (result != null) {
        _cameraLensInfoCache = result.map((k, v) => MapEntry(
              k,
              (v as Map).map((k2, v2) => MapEntry(k2 as String, v2)),
            ));
      }
    } catch (e) {
      debugPrint('[front] camera lens-info query failed (non-fatal): $e');
    }
    return _cameraLensInfoCache;
  }

  // Locked-shutter-speed handoff doc, Phase 0 (2026-07-31): same read-only,
  // no-capture, once-per-session-cached pattern as the three queries above
  // -- answers whether any real device even advertises MANUAL_SENSOR +
  // a real exposure-time range before any native Camera2Interop work
  // (which this app has none of today) is considered for a real locked-
  // shutter capture mode. A positive result here does NOT by itself mean
  // "locked shutter + auto ISO" is available for free -- Camera2 has no
  // such combined AE mode; AE_MODE_OFF requires driving ISO manually too.
  // See MainActivity.kt's manualExposureSupportByCameraId() for the full
  // caveat. Same discipline as rawSensorSupport: this is what would have
  // closed out RAW/DNG immediately instead of after real capture work,
  // had it existed sooner.
  static Map<String, Map<String, dynamic>>? _manualExposureSupportCache;
  static bool _manualExposureSupportQueried = false;

  static Future<Map<String, Map<String, dynamic>>?> _queryManualExposureSupport() async {
    if (_manualExposureSupportQueried) return _manualExposureSupportCache;
    _manualExposureSupportQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getManualExposureSupport');
      if (result != null) {
        _manualExposureSupportCache = result.map((k, v) => MapEntry(
              k,
              (v as Map).map((k2, v2) => MapEntry(k2 as String, v2)),
            ));
      }
    } catch (e) {
      debugPrint('[front] manual-exposure capability query failed (non-fatal): $e');
    }
    return _manualExposureSupportCache;
  }

  // docs/LOCKED_SHUTTER_SPEED_SCOPE.md, Phase 0 (2026-08-02): unlike the
  // four capability queries above (plain CameraCharacteristics reads, safe
  // to run anytime, including while the live CameraX session is open), this
  // one briefly opens its OWN throwaway Camera2 session natively
  // (TorchExposureProbe.kt) to test whether the torch survives
  // CONTROL_AE_MODE_OFF on this device's HAL. Android does not allow two
  // concurrent CameraDevice handles on the same physical camera, so this
  // MUST be awaited to completion BEFORE CameraService.initializeCamera()
  // ever runs -- callers (FrontCaptureScreen._init()) must call this first,
  // never from inside an already-active capture. Public (not `_`-prefixed)
  // specifically so the screen can call it ahead of camera init; every
  // other probe in this file is queried lazily on _finishAndUpload instead,
  // which this one architecturally cannot do.
  static Map<String, dynamic>? torchExposureProbeCache;
  static bool _torchExposureProbeQueried = false;

  static Future<Map<String, dynamic>?> probeTorchExposureCompat() async {
    if (_torchExposureProbeQueried) return torchExposureProbeCache;
    _torchExposureProbeQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('probeTorchWithManualExposure')
          // Belt-and-suspenders on top of the native 6s bound -- if the
          // platform channel call itself somehow never returns, this must
          // still not block the real camera init that follows.
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (result != null) torchExposureProbeCache = result;
    } catch (e) {
      debugPrint('[front] torch-exposure probe failed (non-fatal): $e');
    }
    return torchExposureProbeCache;
  }

  static const Set<String> _uploadNonRetryableCodes = {
    'unauthorized', 'unauthenticated', 'no-default-bucket',
    'invalid-argument', 'invalid-url', 'object-not-found', 'quota-exceeded',
  };

  // ROI the focus/exposure meters score on — aligned to the pad silhouette
  // bounding box so framing, metering and the superprint crop all agree.
  // Kept 1:1 with PadSilhouetteShape.defaultShape.boundingRect + taper.
  // Updated 2026-07-25 for the third -10% mask shrink (CTO audit after two
  // afisWavelengthPx=20 captures on the cam-3-only build -- see
  // defaultShape's own docstring for the full derivation, including the
  // real _MASK_COVER_DILATE finding on why the scored mask reads bigger
  // than this on-screen shape implies):
  //   cx=0.5, cy=0.37, rx=0.134604*(1+0.20)=0.161525, ry=0.111195
  //   -> [0.338475,0.258805,0.661525,0.481195]
  static const Rect _scoreRoi = Rect.fromLTRB(0.3385, 0.2588, 0.6615, 0.4812);

  // Row-axis (maps to on-screen X, see _sweepScreenXFraction) tracking
  // window used by the guided sweep's own CENTROID tracking only. Named
  // separately from _scoreRoi (which stays completely untouched, still
  // feeding the static hold's focus/brightness/coverage signal) purely for
  // clarity about which code depends on it.
  //
  // REAL MATH ERROR, found + reverted 2026-07-30 round 3: an earlier
  // version of this widened the row span 1.8x, reasoning the tracker
  // "needed more room" to follow the thumb across the wider guide-shift
  // range (_sweepGuideShiftFrac). That reasoning was backwards -- the
  // centroid fraction is normalized by DIVIDING by this window's own
  // height, so a WIDER window makes the SAME physical thumb displacement
  // produce a LESS extreme (closer to 0.5) normalized value, making the
  // 0.25/0.75 zone thresholds HARDER to reach, not easier. A real device
  // test (round 3) confirmed the symptom this predicts: focus locked on
  // the thumb correctly (validating the underlying rotation/axis math is
  // right), but sweepPositioning never progressed past "place thumb at the
  // left edge" even with the thumb visibly, correctly seated in the
  // shifted guide -- consistent with the widened window compressing every
  // real reading toward the middle, below the zone threshold. Reverted to
  // exactly _scoreRoi's own span (a value already implicitly proven
  // reasonably well-scaled by months of real static-hold captures, even
  // though it was never explicitly validated for lateral tracking) rather
  // than guessing a new width without real data.
  //
  // REAL REGRESSION, found + fixed round 4: this same constant used to
  // ALSO drive the focus re-aim point (_refocusForSweepPositioning /
  // _beginSweepActive), which is a SEPARATE concern from centroid zone
  // detection -- reverting the width here for the (correct) centroid-math
  // fix silently moved the focus target too, undoing round 2's real-
  // device-confirmed focus fix (that fix shipped and was validated together
  // with the WIDE window, never with this narrow one). A real device test
  // confirmed exactly this: "focus... catching the background instead of
  // the foreground" returned. Split into two independent constants below --
  // _sweepFocusRoi (kept at the wide, validated-for-focus span) for the
  // two focus call sites, _sweepTrackingRoi (narrow, _scoreRoi) for
  // centroid/zone detection only. Never let one constant silently serve two
  // independently-tuned purposes again.
  static const Rect _sweepTrackingRoi = _scoreRoi;

  // Wide row-axis window used ONLY for the sweep's focus re-aim point
  // (_refocusForSweepPositioning / _beginSweepActive) -- this exact span is
  // what round 2's real device test confirmed fixes "focus locked on
  // background, not thumb". Kept deliberately separate from
  // _sweepTrackingRoi (see its docs above) so a future centroid-math tweak
  // can never again silently regress this independently-validated value.
  static const Rect _sweepFocusRoi = Rect.fromLTRB(0.3385, 0.17, 0.6615, 0.57);

  // Guide region in landscape-still coords (the space afis_print.generate()
  // receives after decodeStillJpegToLuma's 90°-CW rotation). Computed at
  // runtime in start() from the actual screen size + camera preview size --
  // NOT a fixed constant. The on-screen silhouette is drawn in
  // screen-normalized coords, but _cameraLayer() displays the preview via
  // BoxFit.cover, which CROPS part of the preview frame whenever the
  // preview's aspect ratio differs from the screen's. A hardcoded rotation-
  // only formula (the previous approach) ignores that crop entirely, so the
  // backend mask silently drifts from what the on-screen guide actually
  // shows on any device where the crop is non-trivial -- confirmed via a
  // real device screenshot showing the live guide sitting higher/tighter on
  // the pad than the backend's masked region. See _computeGuideRegion.
  double _guideCx = 0.63;
  double _guideCy = 0.50;
  double _guideRx = 0.13;
  double _guideRy = 0.17;
  static const double _guideN = 2.5;

  static const double _glareHighLuma = 205.0;
  // Hysteresis gap below _glareHighLuma before walking the EV offset back
  // toward 0 -- a real gap (not right at 205) so a scene sitting near the
  // trigger threshold can't oscillate step-down/step-up every other frame.
  static const double _glareLowLuma = 150.0;
  static const double _glareEvStep = -0.7;
  // Minimum time between successive glare EV steps. Every other exposure/
  // focus-changing mechanism in this file (flash-transition settle, refocus
  // settle, secondary-camera focus-lock wait) has a real settle delay because
  // this project's own history repeatedly found the sensor needs time to
  // converge before the next reading can be trusted -- this one previously
  // had none, so several -0.7 steps could ratchet through in well under a
  // second on a bright scene, before _lastStableBrightness had a chance to
  // reflect the prior correction.
  static const int _glareEvSettleMs = 500;
  // Adaptive flash EV step (2026-07-22): the fixed -1.0 this replaces was
  // sized off the FIRST real overexposure capture, then never revisited —
  // but a later real capture (cb684c57) showed the opposite failure at a
  // DIFFERENT ambient level: flash frames scored Laplacian 15-19 vs 343-395
  // on ambient frames from the SAME hold (gyro only 1.22°/s, ruling out
  // motion blur) — contrast collapse from the torch adding on top of
  // already-decent ambient light, the fixed -1.0 wasn't enough headroom at
  // that brightness. A single constant can't be right for both a
  // near-pitch-dark hold (torch is the ONLY light — a big EV cut there
  // needlessly darkens the one useful frame) and a bright-normal hold
  // (torch competes with substantial existing light — under-cutting risks
  // exactly cb684c57's blowout). Scale off AdaptiveFlashController's own
  // already-calibrated `intensity` (the fraction of exposure the torch
  // itself contributes, derived from the session's one-time ambient
  // calibration) instead of guessing a second fixed constant.
  //
  // Endpoints were a first-cut, physically-reasoned curve, calibrated
  // against n=1 real overexposure case (cb684c57) — the caveat this item
  // carried from the start ("needs its own dedicated real-data test").
  // 2026-07-24 (round 19/20): two independent real captures since then
  // (03b91b6f/70d69867's paired IR-camera comparison, and 3f8fd075 — real
  // flash-frame pixel stats: mean=28.3/255, max=78/255, at evStep=-1.043,
  // intensity=0.6) now show the OPPOSITE failure mode — the main camera's
  // flash frame coming out badly UNDERexposed, not blown out. A single
  // overexposure data point drove the original curve; the accumulated
  // real evidence now points the other way. Scaled both endpoints down by
  // the same ~30% the CTO asked for (-1.0 -> -0.7 equivalent at a typical
  // mid-intensity torch): at intensity=0.6 this curve now yields evStep
  // ~-0.71 instead of -1.043. Still a real device test needed to confirm
  // this doesn't reopen the original cb684c57-style blowout risk — same
  // "one variable at a time" discipline as the rest of this file.
  static const double _flashEvMinCut = -0.2; // intensity=1.0 (pitch dark: torch is
                                              // the sole light source, minimal cut needed)
  static const double _flashEvMaxCut = -1.1; // intensity=0.3 (near the bright-mode
                                              // threshold: torch adds on top of
                                              // substantial ambient, needs the most cut)
  // When ambient mean luma is below this threshold the torch is already the
  // ONLY meaningful light source.  Dimming it with a negative EV offset is
  // counterproductive — the EV curve was calibrated on the overexposure
  // case (bright ambient + flash on top), not on a pitch-dark room.
  static const double _flashEvDarkRoomThreshold = 30.0; // /255

  double _adaptiveFlashEvStep() {
    // Skip the correction entirely in a dark room: ambient mean < ~12%
    // brightness means the torch is already the sole light source and any
    // negative EV step only makes an already-underexposed frame worse.
    if (_lastStableBrightness < _flashEvDarkRoomThreshold) return 0.0;
    final intensity = (_flash?.intensity ?? 0.6).clamp(0.3, 1.0);
    final t = (1.0 - intensity) / 0.7; // 0 at intensity=1.0, 1 at intensity=0.3
    return _flashEvMinCut + (_flashEvMaxCut - _flashEvMinCut) * t;
  }

  static const double _coverageMin = 0.35;
  static const double _coverageMax = 0.85;

  // Generic centered guide shown during each secondary camera's (IR/wide)
  // own live feed (2026-07-23) -- NOT calibrated to that lens's real FOV
  // offset from the main camera (no measured data exists yet; the
  // camera-comparison investigation this session found the thumb is
  // completely absent from the secondary lens's frame in ~3/8 real
  // captures, and off-center/uncontrolled in the rest). Reusing the
  // default shape is a deliberate first cut -- it gives the user SOME
  // framing target instead of none, and the countdown below gives them
  // real time to use it, before ever investing in precise per-lens
  // calibration.
  static const PadSilhouetteShape _secondaryCameraGuideShape =
      PadSilhouetteShape.defaultShape;

  // Device must be this still (gyroscope magnitude, deg/s) before the hold
  // timer counts and the burst can fire. Real captures showed motion-blur
  // streaking in BOTH ambient and flash frames of the same burst — camera
  // shake at macro (thumb-pad-filling) distance, independent of focus
  // distance or exposure. First-cut threshold; tune from real telemetry
  // (gyroMagnitudeDegPerSec is stored per-frame below).
  static const double _maxSteadyDegPerSec = 6.0;

  // Diagnostic snapshot of _adaptiveFlashEvStep()'s inputs/output for the
  // burst just fired -- written to the capture doc so the next real device
  // round gives concrete evidence on whether this first-cut curve is sane,
  // same "measure before tuning further" discipline as every other capture
  // parameter in this file.
  Map<String, dynamic> _flashEvDebug = {};

  CameraController? _camera;
  CameraService? _cameraService;
  String? _userId;
  AdaptiveFlashController? _flash;
  int _sensorOrientation = 0;

  bool _disposed = false;
  bool _starting = false;
  bool _streamRunning = false;
  bool _burstInFlight = false;

  bool _focusLocked = false;
  bool _refocusing = false;
  // True once a fresh auto->lock cycle has run for the CURRENT hold attempt.
  // Mirrors OscillatingCaptureController's _refocusedThisStep: focus is
  // deliberately NOT locked at session start (before the thumb is anywhere
  // near the lens, which was locking onto empty background) -- it's
  // re-acquired fresh the moment the thumb is first confirmed on-target.
  bool _refocusedThisHold = false;
  // Tracks whether the thumb was in coverage range on the previous frame so
  // we can detect the entry transition and immediately point AF at the thumb.
  bool _wasInCoverageRange = false;

  double _appliedEvOffset = 0.0;
  bool _evChangeInFlight = false;
  double _lastStableBrightness = 128.0;
  DateTime? _lastGlareEvAdjustAt;

  // Zoom-to-fill (2026-07-22): compensates for the pad under-filling the
  // guide at the ALREADY-correct working distance, WITHOUT asking the user
  // to physically move closer -- physically moving closer is exactly what
  // this project's own real data (native ridge wavelength -> NFIQ2/
  // matchability) says to avoid; the guide has been shrunk twice specifically
  // to push users FARTHER back. Zoom-in-only is deliberate: it recovers
  // framing without paying the wavelength cost a "move closer" fix would.
  // Never zooms OUT to fix over-fill -- backing away physically is the
  // correct (and free) fix there, per the same reasoning in reverse.
  double _zoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  bool _zoomChangeInFlight = false;
  int _underfillStreak = 0;
  bool _zoomEverApplied = false;
  static const int _underfillStreakThreshold = 8; // ~consecutive frames, not
      // a single noisy reading -- same hysteresis rationale as
      // _maxSteadyDegPerSec's gyro smoothing.
  static const double _zoomStep = 0.15;
  // Cap digital zoom at 1.3x: afe5b02c (round 3) scored nfiq2=74 at 1.3x,
  // and native wavelength ~9.75px × 1.3 = ~12.7px stays in the 9-14px sweet
  // spot.  Beyond 1.3x the pixel wavelength hits the 20px ceiling and NFIQ2
  // collapses (real captures: nfiq2=10, nfiq2=6 at 2.05x).
  static const double _maxZoomFill = 1.3;

  // Two-tier adaptive zoom burst (2026-07-30, Phase 0 -- diagnostic-only on
  // the backend side). After the main 8-shot burst is safely captured and
  // encoded, fires a short SECOND burst at a fixed higher zoom targeting the
  // pad's CENTER -- the whorl core, typically the highest-topology and
  // hardest-to-reconstruct region of the superprint. Deliberately different
  // from zoom-to-fill above: that only ever compensates for under-framing at
  // the SAME working distance; this trades FOV for pixel density on the
  // assumption the main burst already secured the full-pad context shot, so
  // a failure or user movement during this second burst can only ever cost
  // these extra frames, never the already-encoded main burst. CameraX has no
  // pan control, so this always targets frame CENTER, not a specific weak
  // spot -- see the spec's Phase 2 for why an off-center sweep needs a
  // native Camera2 SCALER_CROP_REGION lift instead.
  static const double _detailZoomLevel = 2.0;
  static const int _detailZoomSettleMs = 400;
  // ambient, flash, ambient -- same alternation convention as the main
  // burst, just 3 shots since this is a supplementary detail pass, not a
  // replacement candidate set.
  static const int _detailBurstCount = 3;
  final List<Uint8List> _detailFrames = [];
  final List<bool> _detailFramesFlash = [];
  bool _detailBurstFired = false;
  double? _detailZoomAppliedLevel;

  // Live ridge-wavelength estimate (2026-07-26, Phase 0 -- diagnostic-only,
  // does NOT drive distanceHint yet). Reconciling "closer for detail" with
  // "far enough for good pixel wavelength" (see _maxZoomFill's own comment
  // above) has so far relied entirely on the brightness/fill proxy
  // (coverage) below -- this measures the thing that actually matters
  // (native ridge wavelength) directly from the live preview, so the next
  // several real captures can confirm it tracks the backend's own
  // afisWavelengthPx before it's ever trusted to change user-facing text.
  double? _liveWavelengthPx;
  double? _liveWavelengthStillPx;
  int _wavelengthSampleCount = 0;
  String? _wavelengthAxis;
  DateTime? _lastWavelengthEstimateAt;
  static const int _wavelengthEstimateIntervalMs = 250;
  Map<String, dynamic> _wavelengthDebug = {};

  // Guided thumb-sweep state (see the constants block above for the
  // phase-timing constants). _sweepRawShots/_sweepCentroids are parallel
  // lists built in fire order -- index i of one corresponds to index i of
  // the other, which _finishAndUpload relies on to attach centroidX to the
  // right frame's metadata.
  bool _sweepActivating = false;
  bool _sweepShotInFlight = false;
  DateTime? _lastSweepShotAt;
  int _sweepFlashShotIndex = 0;
  bool _sweepWasFlashLastShot = false;
  final List<_RawShot> _sweepRawShots = [];
  final List<double?> _sweepCentroids = [];
  DateTime? _sweepActiveStart;
  DateTime? _sweepLeftDwellStart;
  double? _lastCentroidX;
  bool _sweepTorchCapable = false;
  double _sweepFlashEvStep = 0.0;
  double? _sweepMinEv;
  double? _sweepMaxEv;
  Map<String, dynamic> _sweepDebug = {};

  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gyroMagnitudeDegPerSec = 0.0;

  DateTime? _calibStart;
  bool _calibDone = false;
  final List<double> _brightnessSamples = [];

  double _focusValue = 0;
  double _focusPeak = 1.0;
  double get focusValue => _focusValue;

  DateTime? _holdStart;
  DateTime? _lastEmitAt;

  final _hybrid = HybridCaptureService();
  final _audio = CaptureAudioService();

  FrontCaptureState _state = const FrontCaptureState();
  FrontCaptureState get state => _state;

  CameraController? get cameraController => _camera;

  Future<void> start({
    required CameraController camera,
    required String userId,
    required Size screenSize,
    CameraService? cameraService,
  }) async {
    if (_starting || _streamRunning) return;
    _starting = true;
    _disposed = false;
    _camera = camera;
    _cameraService = cameraService;
    _userId = userId;
    _sensorOrientation = camera.description.sensorOrientation;

    _computeGuideRegion(screenSize: screenSize, previewSize: camera.value.previewSize);

    _holdStart = null;
    _calibDone = false;
    _brightnessSamples.clear();
    _focusValue = 0;
    _focusPeak = 1.0;
    _appliedEvOffset = 0.0;
    _refocusedThisHold = false;
    _wasInCoverageRange = false;
    _gyroMagnitudeDegPerSec = 0.0;
    _zoomLevel = 1.0;
    _maxZoomLevel = 1.0;
    _underfillStreak = 0;
    _zoomEverApplied = false;
    _detailFrames.clear();
    _detailFramesFlash.clear();
    _detailBurstFired = false;
    _detailZoomAppliedLevel = null;
    _sweepActivating = false;
    _sweepShotInFlight = false;
    _lastSweepShotAt = null;
    _sweepFlashShotIndex = 0;
    _sweepWasFlashLastShot = false;
    _sweepRawShots.clear();
    _sweepCentroids.clear();
    _sweepActiveStart = null;
    _sweepLeftDwellStart = null;
    _lastCentroidX = null;
    _sweepDebug = {};
    try {
      _maxZoomLevel = (await camera.getMaxZoomLevel()).clamp(1.0, _maxZoomFill);
    } catch (_) {}

    _flash = AdaptiveFlashController(camera);

    // Loads the chime WAV assets into the players -- without this call,
    // every later playAngleSuccess() plays a source-less player, which
    // just_audio silently no-ops on (swallowed by that method's own
    // catch), so no chime is ever audible even though every call site looks
    // correctly wired. Real device test, 2026-07-23: confirmed missing here
    // (the sibling oscillating_capture_controller.dart already calls this
    // in its own setup; this call was never copied over when the chime call
    // sites were retrofitted into this controller).
    unawaited(_audio.init());

    _apply((s) => s.copyWith(phase: FrontCapturePhase.calibrating), force: true);

    // Enable continuous autofocus tracking the ROI right away, but DO NOT
    // lock yet -- locking here (before the thumb is anywhere near the lens)
    // freezes the AF distance on whatever's in frame at cold-open (empty
    // background) and it never re-adjusts once locked, which was the root
    // cause of inconsistent blur: the on-screen "on target" gate is a
    // software Laplacian score normalised against its own running peak, so
    // it can read as "locked" even though the underlying AF never actually
    // pointed at the pad. The real re-acquire+lock now happens in
    // _onFrame/_refocus, once the thumb is confirmed on-target.
    try {
      await _beginAutofocus();
    } catch (_) {}

    _gyroSub ??= gyroscopeEventStream().listen((event) {
      final degPerSec = math.sqrt(
            event.x * event.x + event.y * event.y + event.z * event.z,
          ) *
          (180.0 / math.pi);
      _gyroMagnitudeDegPerSec = HybridCaptureService.ema(
        _gyroMagnitudeDegPerSec,
        degPerSec,
        alpha: 0.35,
      );
    });

    _calibStart = DateTime.now();
    _brightnessSamples.clear();

    try {
      await camera.startImageStream(_onFrame);
      _streamRunning = true;
    } catch (e) {
      _fail('Camera stream failed: $e');
      return;
    } finally {
      _starting = false;
    }
  }

  /// Maps the on-screen pad silhouette (screen-normalized coords) into
  /// landscape-still-normalized guideRegion coords, accounting for the
  /// BoxFit.cover crop _cameraLayer() applies (the previous fixed-constant
  /// approach only rotated the raw on-screen fraction, silently ignoring
  /// that crop -- confirmed wrong via a real device screenshot comparing
  /// the live guide against the actual masked backend region).
  void _computeGuideRegion({required Size screenSize, Size? previewSize}) {
    if (previewSize == null || screenSize.width <= 0 || screenSize.height <= 0) {
      return; // keep the existing (last-good or default) values
    }
    // _cameraLayer() swaps previewSize's width/height to get the portrait
    // display aspect ratio before handing it to FittedBox(fit: BoxFit.cover).
    final wp = previewSize.height;
    final hp = previewSize.width;
    final ws = screenSize.width;
    final hs = screenSize.height;
    final scale = math.max(ws / wp, hs / hp);
    final offX = (wp * scale - ws) / 2;
    final offY = (hp * scale - hs) / 2;

    // Screen-normalized point -> landscape-still-normalized point: undo the
    // BoxFit.cover crop/scale to recover the true preview-frame fraction,
    // then apply the same 90°-CW rotation decodeStillJpegToLuma performs
    // ((u,v) in portrait-preview -> (1-v,u) in landscape-still).
    Offset toStill(double su, double sv) {
      final previewU = ((su * ws) + offX) / scale / wp;
      final previewV = ((sv * hs) + offY) / scale / hp;
      return Offset(1.0 - previewV, previewU);
    }

    const shape = PadSilhouetteShape.defaultShape;
    final center = toStill(shape.cx, shape.cy);
    final top = toStill(shape.cx, shape.cy - shape.ry);
    final bottom = toStill(shape.cx, shape.cy + shape.ry);
    final left = toStill(shape.cx - shape.rx, shape.cy);
    final right = toStill(shape.cx + shape.rx, shape.cy);

    final xs = [top.dx, bottom.dx, left.dx, right.dx];
    final ys = [top.dy, bottom.dy, left.dy, right.dy];
    _guideCx = center.dx;
    _guideCy = center.dy;
    _guideRx = (xs.reduce(math.max) - xs.reduce(math.min)) / 2;
    _guideRy = (ys.reduce(math.max) - ys.reduce(math.min)) / 2;
  }

  /// Converts a raw-live-preview-pixel wavelength estimate into the same
  /// still-space pixel units the backend's own `afisWavelengthPx` uses
  /// (measured directly on the still decoded to _stillDecodeTargetWidth,
  /// no further resize before _ridge_wavelength runs).
  ///
  /// `_guideRx` is the guide's half-width already in still-normalized,
  /// crop-and-rotation-corrected coordinates (_computeGuideRegion above);
  /// `_scoreRoi` is the same ROI already feeding meanLuma/the wavelength
  /// estimator, in raw-CameraImage-normalized coordinates. These are two
  /// INDEPENDENTLY derived approximations of "the same" guide region
  /// (_scoreRoi's own comment says it's only "kept 1:1" with the guide
  /// shape, not identical to the crop-corrected _guideRx) -- fine for a
  /// coarse scale factor, but exactly why liveWavelengthStillPx must be
  /// checked against real backend afisWavelengthPx data (not trusted
  /// because it looks reasonable) before this ever drives distanceHint.
  double? _wavelengthScaleToStill(CameraImage image) {
    final roiWidthPx = _scoreRoi.width * image.width;
    if (roiWidthPx <= 0 || _guideRx <= 0) return null;
    return (2 * _guideRx * _stillDecodeTargetWidth) / roiWidthPx;
  }

  void _onFrame(CameraImage image) {
    if (_disposed) return;

    final roi = _scoreRoi;

    // Coverage hint (distance from camera).
    double? coverage;
    try {
      coverage = HybridCaptureService.meanLuma(image, roi: roi) / 255.0;
    } catch (_) {}
    final tooFar = coverage != null && coverage < _coverageMin;
    final tooClose = coverage != null && coverage > _coverageMax;
    // Hoisted here (was previously computed further down, just before the
    // focus-tracking block) so the live wavelength estimator below can also
    // gate on it -- no point running autocorrelation on a background frame
    // before the thumb is plausibly present.
    final inCoverageRange = coverage != null && !tooFar && !tooClose;
    // Try zoom-to-fill before ever telling the user to physically move
    // closer -- zooming preserves the guided working distance (and the
    // native ridge wavelength it was tuned for); physically moving closer
    // does not. Only fall back to the "Move closer" hint once zoom is
    // already maxed out and genuinely can't help further.
    final zoomMaxedOut = _maybeAdjustZoom(tooFar);
    final hint = (tooFar && zoomMaxedOut)
        ? 'Move closer'
        : tooClose
            ? 'Move back slightly'
            : null;
    if (hint != _state.distanceHint) {
      _apply((s) => s.copyWith(distanceHint: hint));
    }

    // Live ridge-wavelength estimate (Phase 0, diagnostic-only -- see the
    // field docs above _gyroSub). Throttled to a wall-clock interval (mirrors
    // this file's one existing throttling convention, _emitThrottleMs/
    // _calibDurationMs) and gated on inCoverageRange, since the autocorrelation
    // pass is real work and there's no point running it on a background
    // frame. Wrapped in try/catch -- must never be able to break the hold.
    if (inCoverageRange) {
      final now = DateTime.now();
      if (_lastWavelengthEstimateAt == null ||
          now.difference(_lastWavelengthEstimateAt!).inMilliseconds >=
              _wavelengthEstimateIntervalMs) {
        _lastWavelengthEstimateAt = now;
        try {
          final est =
              HybridCaptureService.estimateRidgeWavelengthPx(image, roi: roi);
          if (est != null) {
            _liveWavelengthPx = HybridCaptureService.ema(
              _liveWavelengthPx ?? est.medianLagPx,
              est.medianLagPx,
            );
            final scale = _wavelengthScaleToStill(image);
            _liveWavelengthStillPx =
                scale != null ? _liveWavelengthPx! * scale : null;
            _wavelengthAxis = est.axis;
            _wavelengthSampleCount++;
          }
        } catch (_) {}
      }
    }

    // Focus tracking: offerFrame returns raw Laplacian variance; normalise by
    // running peak so the meter reads 0→1 relative to the sharpest frame seen.
    //
    // Peak is only updated when the thumb is in coverage range. Without this
    // gate, sharp background frames before the thumb arrives set _focusPeak
    // far above anything the (initially blurry) thumb can achieve, preventing
    // the focus meter from ever clearing the 0.45 on-target threshold.
    //
    // On thumb ENTRY we immediately point AF at the thumb ROI and reset the
    // peak to the current (low) raw value, giving focus tracking a fresh
    // baseline calibrated to the thumb — not leftover background sharpness.
    try {
      final rawFocus = _hybrid.offerFrame(image, thumbRoi: roi);
      if (inCoverageRange && !_wasInCoverageRange) {
        // Thumb just entered range: reset peak and immediately direct AF.
        // Skip if a full refocus cycle is already running — it will redirect
        // AF itself and calling _beginAutofocus() concurrently would race
        // with its 600ms settle timer.
        _focusPeak = rawFocus + 1e-6;
        _focusValue = 0;
        if (!_refocusing) unawaited(_beginAutofocus());
      } else if (inCoverageRange && rawFocus > _focusPeak) {
        _focusPeak = rawFocus;
      }
      _focusValue = HybridCaptureService.ema(
        _focusValue,
        (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0),
      );
    } catch (_) {}
    _wasInCoverageRange = inCoverageRange;

    // Brightness tracking for exposure.
    if (!(_flash?.isFlashOn ?? false)) {
      try {
        _lastStableBrightness = HybridCaptureService.meanLuma(image, roi: roi);
        _apply((s) => s.copyWith(
              lightingValue: (_lastStableBrightness / 255.0).clamp(0.0, 1.0),
            ));
      } catch (_) {}
    }
    if (!_refocusing) _maybeAdjustExposure();

    // Calibration: sample brightness for AdaptiveFlash.
    if (!_calibDone) {
      try {
        _brightnessSamples.add(HybridCaptureService.meanLuma(image, roi: roi));
      } catch (_) {}
      final start = _calibStart;
      if (start != null &&
          DateTime.now().difference(start).inMilliseconds >= _calibDurationMs) {
        unawaited(_finalizeCalibration());
      }
      return;
    }

    if (_burstInFlight) return;

    // Guided thumb-sweep phases -- inserted between the existing on-target
    // focus-lock (below) and the burst firing. Each has its own per-frame
    // handler; both return early so the holding-phase logic below never
    // runs concurrently with the sweep.
    if (_state.phase == FrontCapturePhase.sweepPositioning) {
      _handleSweepPositioningFrame(image);
      return;
    }
    if (_state.phase == FrontCapturePhase.sweepActive) {
      _handleSweepActiveFrame(image);
      return;
    }

    if (_state.phase != FrontCapturePhase.holding) return;

    // On-target: focus score crosses threshold, distance is right, AND the
    // device is objectively still (gyroscope-derived). Real captures showed
    // motion-blur streaking even when the software focus score read "on
    // target" -- a fixed hold timer alone doesn't catch handshake at macro
    // distance.
    final steady = _gyroMagnitudeDegPerSec < _maxSteadyDegPerSec;
    final rawOnTarget = _focusValue > 0.45 && !tooFar && !tooClose && steady;

    if (rawOnTarget) {
      // Re-acquire focus FRESH the first time this hold reaches on-target,
      // instead of trusting whatever the lens converged to before the thumb
      // arrived. Mirrors OscillatingCaptureController's per-pose re-lock
      // (the fix for "RIGHT angle always blurs").
      if (!_refocusedThisHold) {
        _refocusedThisHold = true;
        _holdStart = null;
        unawaited(_refocus());
        _apply((s) => s.copyWith(onTarget: true, holdProgress: 0, isSteady: steady));
        return;
      }
      if (_refocusing) {
        // Hold the user steady while the lens converges; don't start the
        // hold timer or fire on a mid-hunt frame.
        _apply((s) => s.copyWith(onTarget: true, holdProgress: 0, isSteady: steady));
        return;
      }
      _holdStart ??= DateTime.now();
      final heldMs = DateTime.now().difference(_holdStart!).inMilliseconds;
      final progress = (heldMs / _holdDurationMs).clamp(0.0, 1.0);
      _apply((s) => s.copyWith(onTarget: true, holdProgress: progress, isSteady: steady));
      if (heldMs >= _holdDurationMs) {
        _holdStart = null;
        // Sweep behind a disabled flag (see _sweepEnabled's own docs) --
        // routes back to the proven static burst path _fireBurst() by
        // default, which is _fireBurst's original pre-sweep behaviour when
        // called with no preCollectedShots argument.
        unawaited(_sweepEnabled ? _beginSweepPositioning() : _fireBurst());
      }
    } else {
      _holdStart = null;
      // Only restart the focus-acquire cycle when the thumb genuinely leaves
      // coverage range (real distance change — AF may need to re-acquire at a
      // new distance). Gyro spikes and transient focus dips while the thumb
      // stays in frame don't stale the locked focus; resetting here would
      // trigger a fresh 600ms refocus wait the moment the score recovers,
      // multiplying unnecessary waits when the user is just slightly unsteady.
      if (tooFar || tooClose || coverage == null) {
        _refocusedThisHold = false;
      }
      _apply((s) => s.copyWith(onTarget: false, holdProgress: 0, isSteady: steady));
    }
  }

  // ── Guided thumb-sweep capture ──────────────────────────────────────────
  //
  // Phase 1 (sweepPositioning): wait for the thumb's centroid to reach the
  // guide's left zone and dwell there briefly, so the sweep always starts
  // from a known, consistent position rather than wherever the thumb
  // happened to be when the hold-still timer completed.
  //
  // Phase 2 (sweepActive): fire the same 8-shot alternating-flash burst as
  // before, but gated per-frame on sharpness as the user sweeps right,
  // instead of firing all 8 back-to-back the instant a static hold
  // completes. Ends on quota (8 shots), an early right-zone exit once the
  // minimum valid-shot count is already met, or a hard timeout.

  /// The on-screen guide shape for a given sweep progress (0.0 = fully
  /// left-shifted, 1.0 = fully right-shifted) -- interpolates `cx` linearly,
  /// everything else copied from `PadSilhouetteShape.defaultShape`. This IS
  /// "the mask" the 2026-07-30 device-test feedback asked to move: rather
  /// than a static guide the user's thumb sweeps across (with a separate,
  /// easy-to-miss highlight band), the guide itself translates across the
  /// screen so the whole finger stays inside it throughout the sweep.
  PadSilhouetteShape _sweepGuideShapeForProgress(double progress) {
    const base = PadSilhouetteShape.defaultShape;
    final cx = (0.5 - _sweepGuideShiftFrac) +
        (2 * _sweepGuideShiftFrac) * progress.clamp(0.0, 1.0);
    return PadSilhouetteShape(
      cx: cx,
      cy: base.cy,
      rx: base.rx,
      ry: base.ry,
      n: base.n,
      taper: base.taper,
      coreTargetDyFrac: base.coreTargetDyFrac,
      coreTargetDxFrac: base.coreTargetDxFrac,
    );
  }

  Future<void> _beginSweepPositioning() async {
    _sweepActivating = false;
    _sweepShotInFlight = false;
    _lastSweepShotAt = null;
    _sweepFlashShotIndex = 0;
    _sweepWasFlashLastShot = false;
    _sweepRawShots.clear();
    _sweepCentroids.clear();
    _sweepLeftDwellStart = null;
    _lastCentroidX = null;
    _apply(
      (s) => s.copyWith(
        phase: FrontCapturePhase.sweepPositioning,
        sweepProgress: 0.0,
        sweepCentroidX: null,
        sweepFastWarning: false,
        sweepPositionOk: false,
        sweepDwellProgress: 0.0,
        // Guide shifted fully left -- this IS the "place thumb at the left
        // edge" target now, not a separate highlight overlay on a static
        // guide (see _sweepGuideShapeForProgress).
        activeGuideShape: _sweepGuideShapeForProgress(0.0),
      ),
      force: true,
    );
    // Real device-test finding (2026-07-30 round 2): "focus is not locked
    // on the thumb but rather on the background". Root cause: focus was
    // locked (FocusMode.locked) at the ORIGINAL static hold's centred point
    // (set once by the hold phase's own _refocus(), before this sweep flow
    // even existed) and nothing here ever re-aimed it -- so once the guide
    // shifted left and the user actually moved their thumb to match, the
    // lens stayed pointed at whatever background was now exposed at the
    // OLD centred spot. This very likely also explains "capture never
    // initiates": with the lens focused on the wall, the thumb itself reads
    // soft in _scoreRoi, so _focusValue's Laplacian score can't clear the
    // 0.45 fire-gate threshold no matter how well the user positions their
    // thumb. Fix: continuous (not locked) autofocus re-aimed at the
    // shifted guide's actual position for the whole positioning phase, so
    // the lens is already converging on the right spot before the user's
    // thumb gets there -- _beginSweepActive's existing settle+lock cycle
    // then takes over once positioning resolves.
    unawaited(_refocusForSweepPositioning());
  }

  /// Converts a SCREEN-space left(0)-right(1) fraction into the raw
  /// CameraImage buffer point setFocusPoint/setExposurePoint expect, via
  /// _sweepFocusRoi -- the ONE constant every sweep focus-targeting call
  /// site must share (see _sweepFocusRoi's own docs for why this was split
  /// out from _sweepTrackingRoi after a real round-4 regression). Column
  /// axis fixed at the ROI's own centre ("centre Y fixed" per the sweep
  /// spec); row axis inverted per this project's confirmed 90°CW
  /// raw-buffer-to-screen rotation (see _sweepScreenXFraction).
  Offset _sweepFocusPointFor(double targetScreenX) {
    final rawBufferX = (_sweepFocusRoi.left + _sweepFocusRoi.right) / 2;
    final rawBufferY = (_sweepFocusRoi.top +
            (1.0 - targetScreenX) * _sweepFocusRoi.height)
        .clamp(0.0, 1.0);
    return Offset(rawBufferX, rawBufferY);
  }

  /// Re-aims CONTINUOUS autofocus (not locked) at the sweep-positioning
  /// guide's actual on-screen position -- see the real-bug note in
  /// _beginSweepPositioning above. Evaluated at progress=0.0 (the guide's
  /// fully-left-shifted cx) since the guide doesn't move further during
  /// positioning itself.
  Future<void> _refocusForSweepPositioning() async {
    final cam = _camera;
    if (cam == null) return;
    final pt = _sweepFocusPointFor(_sweepGuideShapeForProgress(0.0).cx);
    try {
      await cam.setFocusMode(FocusMode.auto);
      await cam.setFocusPoint(pt);
      await cam.setExposurePoint(pt);
    } catch (_) {}
  }

  /// Maps the raw CameraImage buffer's own axes into an on-screen
  /// left(0.0)-to-right(1.0) fraction, for the guided thumb-sweep. Given
  /// this project's real, already-confirmed `sensorOrientation=90`
  /// convention (see `_computeGuideRegion`'s "90°-CW rotation" derivation --
  /// the same class of screen-vs-buffer coordinate fix that took NFIQ2 from
  /// single digits to 72 for the guideRegion mask), a 90°CW rotation from
  /// raw sensor space to upright portrait maps the raw buffer's ROW axis to
  /// the upright image's HORIZONTAL axis, inverted (screen-left = a large
  /// raw-row fraction, screen-right = a small one) -- NOT the buffer's
  /// column axis.
  ///
  /// Real bug found via a real device test (2026-07-30): the sweep asked
  /// the user to move their thumb toward an on-screen "left zone"/"sweep
  /// right" cue, but the original centroid tracking measured the buffer's
  /// COLUMN axis -- which this rotation actually maps to on-screen VERTICAL
  /// position, not horizontal. The positioning/sweep gates could never
  /// reliably resolve against real left-right thumb motion, matching the
  /// report ("did not see my finger in mask", capture never firing). Same
  /// standing discipline as everywhere else in this file: reasoned from
  /// this project's own already-confirmed rotation convention, not device-
  /// tested yet -- the next real capture's `sweepDebug.centroids` trend
  /// (now recorded in already-correct screen-space fractions) is the actual
  /// go/no-go check.
  ///
  /// Uses `_sweepTrackingRoi` (wider than `_scoreRoi`, row axis only --
  /// see its own docs) so the tracker has real room to follow the thumb
  /// across the sweep's widened guide-shift range.
  double? _sweepScreenXFraction(CameraImage image) {
    final rowFrac = HybridCaptureService.estimateThumbCentroidX(
      image, roi: _sweepTrackingRoi, alongRows: true,
    );
    if (rowFrac == null) return null;
    return (1.0 - rowFrac).clamp(0.0, 1.0);
  }

  void _handleSweepPositioningFrame(CameraImage image) {
    // Already transitioning to sweepActive (re-aiming focus, an async
    // sequence spanning several frames) -- avoid re-triggering it on every
    // subsequent frame while that's in flight.
    if (_sweepActivating) return;

    double? centroid;
    try {
      centroid = _sweepScreenXFraction(image);
    } catch (_) {}
    _lastCentroidX = centroid ?? _lastCentroidX;

    final inLeftZone = centroid != null && centroid <= _sweepLeftZoneMax;
    var dwellProgress = 0.0;
    if (inLeftZone) {
      _sweepLeftDwellStart ??= DateTime.now();
      final dwelledMs = DateTime.now().difference(_sweepLeftDwellStart!).inMilliseconds;
      dwellProgress = (dwelledMs / _sweepLeftDwellMs).clamp(0.0, 1.0);
      if (dwelledMs >= _sweepLeftDwellMs) {
        _sweepActivating = true;
        unawaited(_beginSweepActive(centroid!));
        return;
      }
    } else {
      _sweepLeftDwellStart = null;
    }
    _apply((s) => s.copyWith(
          sweepCentroidX: centroid,
          sweepProgress: 0.0,
          sweepPositionOk: inLeftZone,
          sweepDwellProgress: dwellProgress,
        ));
  }

  /// Re-aims focus to the guide's own left-shifted position (centre Y
  /// fixed) -- the same point _refocusForSweepPositioning has already been
  /// continuously converging on -- waits for it to settle, locks it, then
  /// transitions to sweepActive. Deliberately does this ONCE at sweep
  /// start, not continuously during the sweep itself -- focus-chase latency
  /// mid-sweep would introduce exactly the motion blur the sharpness gate
  /// is trying to avoid.
  Future<void> _beginSweepActive(double startCentroidX) async {
    final cam = _camera;
    if (cam == null) {
      _sweepActivating = false;
      return;
    }

    // Deliberately NOT derived from startCentroidX (which is a live
    // _sweepTrackingRoi-relative reading) -- REAL REGRESSION, round 4: an
    // earlier version of this reused startCentroidX through this same
    // inverse transform, which silently mixed _sweepTrackingRoi's (narrow,
    // centroid-tuned) calibration into a focus target, undoing round 2's
    // validated focus fix. _refocusForSweepPositioning has already been
    // continuously re-aiming at the guide's own fixed left-shifted position
    // throughout positioning, and reaching sweepActive only happens once
    // the dwell condition confirms the thumb is actually there -- so
    // re-aiming at that SAME already-validated point (not a fresh,
    // differently-calibrated one) is both simpler and correct.
    final pt = _sweepFocusPointFor(_sweepGuideShapeForProgress(0.0).cx);
    try {
      await cam.setFocusMode(FocusMode.auto);
      await cam.setFocusPoint(pt);
      await cam.setExposurePoint(pt);
      // Same 600ms auto->settle->lock convention as _refocus() -- this
      // device's proven AF convergence timing elsewhere in this file.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await cam.setFocusMode(FocusMode.locked);
    } catch (_) {}

    if (_disposed || _state.phase != FrontCapturePhase.sweepPositioning) {
      _sweepActivating = false;
      return;
    }

    _sweepTorchCapable = _flash?.isNeeded ?? false;
    _sweepFlashEvStep = _adaptiveFlashEvStep();
    _sweepMinEv = null;
    _sweepMaxEv = null;
    if (_sweepTorchCapable) {
      try {
        _sweepMinEv = await cam.getMinExposureOffset();
        _sweepMaxEv = await cam.getMaxExposureOffset();
      } catch (_) {}
    }
    _sweepActiveStart = DateTime.now();
    _sweepActivating = false;
    _apply(
      (s) => s.copyWith(
        phase: FrontCapturePhase.sweepActive,
        // Continuous with sweepPositioning's own progress/guide position
        // (both 0.0, left-shifted) rather than jumping to startCentroidX --
        // _handleSweepActiveFrame takes over from here on every live frame.
        sweepProgress: 0.0,
        sweepCentroidX: startCentroidX,
        sweepFastWarning: false,
        activeGuideShape: _sweepGuideShapeForProgress(0.0),
      ),
      force: true,
    );
  }

  void _handleSweepActiveFrame(CameraImage image) {
    double? centroid;
    try {
      centroid = _sweepScreenXFraction(image);
    } catch (_) {}
    if (centroid != null) _lastCentroidX = centroid;
    final effectiveCentroid = centroid ?? _lastCentroidX;

    // Same 0.45 threshold as the existing on-target gate above -- reused,
    // not a second independent value, per "must not change the existing
    // Laplacian gate threshold".
    final sharpnessOk = _focusValue > 0.45;
    final progress = (effectiveCentroid ?? _state.sweepProgress).clamp(0.0, 1.0);
    _apply((s) => s.copyWith(
          sweepCentroidX: effectiveCentroid,
          sweepProgress: progress,
          sweepFastWarning: !sharpnessOk,
          // The guide itself tracks the sweep (see _sweepGuideShapeForProgress)
          // so the whole finger stays framed as it moves, instead of a
          // static oval the thumb sweeps across.
          activeGuideShape: _sweepGuideShapeForProgress(progress),
        ));

    final capturedCount = _sweepRawShots.length;
    final elapsedMs = _sweepActiveStart == null
        ? 0
        : DateTime.now().difference(_sweepActiveStart!).inMilliseconds;

    // Completion checks run before the fire gate so a frame that both
    // qualifies to fire AND crosses a completion boundary doesn't squeeze
    // in one extra shot past where the sweep should already have ended.
    if (capturedCount >= _burstFrameCount) {
      unawaited(_completeSweep(success: true));
      return;
    }
    if (effectiveCentroid != null &&
        effectiveCentroid >= _sweepRightZoneMin &&
        capturedCount >= _sweepMinValidShots) {
      unawaited(_completeSweep(success: true));
      return;
    }
    if (elapsedMs >= _sweepTimeoutMs) {
      unawaited(_completeSweep(success: capturedCount >= _sweepMinValidShots));
      return;
    }

    // Fire gate: only capture when sharp, not already mid-shot, and enough
    // time has passed since the last shot -- natural pacing across the
    // sweep window rather than pile-firing every frame once sharp.
    if (!_sweepShotInFlight) {
      final now = DateTime.now();
      final sinceLastShot = _lastSweepShotAt == null
          ? _sweepMinShotIntervalMs
          : now.difference(_lastSweepShotAt!).inMilliseconds;
      if (sharpnessOk && sinceLastShot >= _sweepMinShotIntervalMs) {
        unawaited(_fireSweepShot(effectiveCentroid));
      }
    }
  }

  /// Captures one sweep shot. Stops the image stream before the still
  /// capture and restarts it immediately after, matching the SAME pattern
  /// every other still-capture path in this file already uses (the static
  /// burst, secondary cameras, the detail-zoom burst) -- unlike an earlier
  /// version of this method, which kept `startImageStream` running
  /// continuously across every sweep shot so centroid/sharpness tracking
  /// wouldn't have to pause. That was a real, explicitly-flagged unverified
  /// assumption (concurrent ImageAnalysis + ImageCapture use), and a real
  /// device test (2026-07-30) hit an Android ANR ("app isn't responding:
  /// Close/Wait") consistent with it not being safe on this hardware/plugin
  /// combination -- this project's own history has repeatedly traced ANRs
  /// to exactly this class of camera-session contention. Restarting per
  /// shot costs real, bounded latency (a stream stop/start cycle, up to
  /// _sweepMinShotIntervalMs's worth of tracking gap) but removes the ANR
  /// risk category entirely, at the cost of a NEW, also-unverified
  /// assumption -- that 8 rapid stop/restart cycles are themselves safe on
  /// real hardware. Flagged for the next real device test same as
  /// everywhere else in this file; if THIS turns out to be a problem too,
  /// the next lever is spacing shots further apart, not going back to a
  /// continuously-running stream.
  Future<void> _fireSweepShot(double? centroidAtFire) async {
    final cam = _camera;
    if (cam == null || _sweepShotInFlight) return;
    _sweepShotInFlight = true;
    _lastSweepShotAt = DateTime.now();
    try {
      await _stopStream();

      final i = _sweepRawShots.length;
      // Same alternation convention as the static burst: even index =
      // ambient (torch off), odd = flash (torch on with negative EV).
      final wantFlash = _sweepTorchCapable && i.isOdd;
      try {
        if (wantFlash) {
          await _flash!.activate();
          if (_sweepMinEv != null && _sweepMaxEv != null) {
            final multiplier = _flashEvBracketMultipliers[
                _sweepFlashShotIndex % _flashEvBracketMultipliers.length];
            final target = _appliedEvOffset + _sweepFlashEvStep * multiplier;
            await cam.setExposureOffset(target.clamp(_sweepMinEv!, _sweepMaxEv!));
          }
          await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
        } else {
          await _flash?.deactivate();
          if (_sweepMinEv != null && _sweepMaxEv != null) {
            await cam.setExposureOffset(_appliedEvOffset.clamp(_sweepMinEv!, _sweepMaxEv!));
          }
          // Same flash-off settle delay as the static burst -- only applied
          // when the immediately preceding shot actually fired the flash.
          if (_sweepWasFlashLastShot) {
            await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
          }
        }
      } catch (_) {}
      if (wantFlash) _sweepFlashShotIndex++;
      _sweepWasFlashLastShot = wantFlash;

      final xfile = await cam.takePicture();
      final jpeg = await xfile.readAsBytes();
      _sweepRawShots.add(_RawShot(
        jpeg: jpeg,
        flashOn: _flash?.isFlashOn ?? false,
        laplacianScore: _focusValue > 0 ? _focusValue * (_focusPeak + 1e-6) : null,
        timestamp: DateTime.now(),
      ));
      _sweepCentroids.add(centroidAtFire);
      // Immediate per-shot feedback -- real device-test feedback (2026-07-30
      // round 2): "I can't hear or see anything fire". The static burst only
      // confirms once at the very end (all 8 shots); the sweep's shots are
      // spread over several seconds of active user motion, so a light tick
      // per shot (distinct from the final heavyImpact success pattern in
      // _fireBurst) gives real-time confirmation instead of total silence
      // until the whole sweep resolves.
      unawaited(HapticFeedback.selectionClick());
    } catch (e) {
      debugPrint('[front] sweep shot failed (non-fatal): $e');
    } finally {
      if (!_disposed && !_streamRunning) {
        try {
          await cam.startImageStream(_onFrame);
          _streamRunning = true;
        } catch (e) {
          debugPrint('[front] sweep stream restart failed (non-fatal): $e');
        }
      }
      _sweepShotInFlight = false;
    }
  }

  Future<void> _completeSweep({required bool success}) async {
    // Guard against double-invocation -- _handleSweepActiveFrame can fire
    // again on the next camera frame before the phase transition below
    // actually lands (async gap between the completion check and here).
    if (_state.phase != FrontCapturePhase.sweepActive) return;
    // Immediately move off sweepActive so a concurrent frame callback can't
    // re-enter this same completion path a second time. Also resets the
    // guide back to centered/default -- the rest of the flow (detail-zoom,
    // secondary cameras) expects the same centered guide the static burst
    // always used, not wherever the sweep's moving guide last landed.
    _apply(
      (s) => s.copyWith(phase: FrontCapturePhase.capturing, activeGuideShape: null),
      force: true,
    );

    final capturedCount = _sweepRawShots.length;
    final elapsedMs = _sweepActiveStart == null
        ? 0
        : DateTime.now().difference(_sweepActiveStart!).inMilliseconds;

    try {
      await _flash?.deactivate();
    } catch (_) {}

    _sweepDebug = {
      'centroids': List<double?>.from(_sweepCentroids),
      'capturedCount': capturedCount,
      'sweepDurationMs': elapsedMs,
      'timedOut': elapsedMs >= _sweepTimeoutMs,
      'leftDwellMs': _sweepLeftDwellMs,
    };

    if (!success) {
      HapticFeedback.mediumImpact(); // distinct from the success heavyImpact below
      _apply(
        (s) => s.copyWith(
          phase: FrontCapturePhase.sweepPositioning,
          confirmationText: 'Try again — sweep a little slower',
          sweepProgress: 0.0,
        ),
        force: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: _confirmationDisplayMs));
      if (_disposed) return;
      _apply((s) => s.copyWith(confirmationText: null), force: true);
      unawaited(_beginSweepPositioning());
      return;
    }

    final rawShots = List<_RawShot>.from(_sweepRawShots);
    final centroids = List<double?>.from(_sweepCentroids);
    final gyroAtCapture = _gyroMagnitudeDegPerSec;
    unawaited(_fireBurst(
      preCollectedShots: rawShots,
      preCollectedCentroids: centroids,
      gyroAtCapture: gyroAtCapture,
    ));
  }

  Future<void> _finalizeCalibration() async {
    if (_calibDone || _disposed) return;
    _calibDone = true;
    if (_brightnessSamples.isNotEmpty) {
      final avg = _brightnessSamples.reduce((a, b) => a + b) / _brightnessSamples.length;
      try {
        await _flash?.calibrate(avg);
      } catch (_) {}
    }
    _apply((s) => s.copyWith(phase: FrontCapturePhase.holding), force: true);
  }

  Future<void> _beginAutofocus() async {
    final cam = _camera;
    if (cam == null) return;
    _focusLocked = false;
    final cx = (_scoreRoi.left + _scoreRoi.right) / 2;
    final cy = (_scoreRoi.top + _scoreRoi.bottom) / 2;
    final pt = Offset(cx, cy);
    try {
      await cam.setFocusMode(FocusMode.auto);
    } catch (_) {}
    try {
      await cam.setFocusPoint(pt);
    } catch (_) {}
    try {
      await cam.setExposurePoint(pt);
    } catch (_) {}
  }

  Future<void> _lockFocusOnly() async {
    final cam = _camera;
    if (cam == null) return;
    try {
      await cam.setFocusMode(FocusMode.locked);
      _focusLocked = true;
    } catch (_) {}
  }

  /// Re-acquire then re-lock focus at the pad's actual current distance,
  /// instead of trusting whatever the lens converged to before the thumb was
  /// in frame. Same 600ms auto->settle->lock cycle already proven for the
  /// oscillating flow's RIGHT-angle blur fix (350ms was re-locking mid-hunt).
  Future<void> _refocus() async {
    if (_refocusing) return;
    _refocusing = true;
    try {
      await _beginAutofocus();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _lockFocusOnly();
    } catch (e) {
      debugPrint('[front] refocus failed (non-fatal): $e');
    } finally {
      _refocusing = false;
    }
  }

  // Explicit per-camera-turn UI (2026-07-23) -- shared by every secondary-
  // camera turn inside capturingExtra so the whole phase reads as one
  // consistent sequence: guide shown -> countdown -> capturing -> explicit
  // stop -> confirmation.
  // Directly answers the CTO's real-device report that cameras fired with
  // no dead stop between them and no warning before the shutter.

  /// "3…" -> "2…" -> "1…", ~700ms apart with a light haptic pulse each, then
  /// hands off to "Capturing…". Real time for the user to react to
  /// whatever guide is currently shown, not just a label change.
  Future<void> _showCountdown() async {
    for (final n in const ['3…', '2…', '1…']) {
      if (_disposed) return;
      _apply((s) => s.copyWith(distanceHint: n));
      HapticFeedback.lightImpact();
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    if (_disposed) return;
    _apply((s) => s.copyWith(distanceHint: 'Capturing…'));
  }

  /// Real, visible confirmation that a camera turn has ended -- shown only
  /// AFTER the caller has already awaited that camera's explicit stop (e.g.
  /// `svc.disposeCamera()`), so "this camera stopped" is a fact by the time
  /// this banner appears, not an assumption. Clears the guide shape so the
  /// next turn (or the real uploading transition) starts from a clean slate.
  Future<void> _showStopConfirmation(String friendly, {required bool success}) async {
    if (_disposed) return;
    _apply((s) => s.copyWith(
          distanceHint: success ? '✓ $friendly captured' : '$friendly skipped',
          activeGuideShape: null,
        ));
    if (success) {
      unawaited(_audio.playAngleSuccess(isFinal: false));
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  // Real bug found + fixed 2026-07-29: this previously had no settle delay
  // (could ratchet several -0.7 steps within under a second on a bright
  // scene, well before _lastStableBrightness reflected the prior
  // correction) and never reversed (_appliedEvOffset was only ever
  // decremented, so a brief glint during calibration permanently depressed
  // the exposure baseline -- including the main burst's ambient/flash EV,
  // which both use _appliedEvOffset as their base -- for the rest of that
  // capture session even if brightness later returned to normal). The old
  // "already converged" check also compared target against _appliedEvOffset
  // itself (always exactly _glareEvStep apart, so it could never actually
  // trip) instead of against the real hardware-clamped value, letting the
  // internal accounting value run away past what the camera actually
  // applied. Now: settled by _glareEvSettleMs, reconciled against the real
  // hardware min/max every adjustment (so _appliedEvOffset can't diverge
  // from what the sensor actually has), and walks back toward 0 with a
  // hysteresis gap (_glareLowLuma) once the glare clears.
  void _maybeAdjustExposure() {
    if (_evChangeInFlight) return;
    final cam = _camera;
    if (cam == null) return;
    final now = DateTime.now();
    if (_lastGlareEvAdjustAt != null &&
        now.difference(_lastGlareEvAdjustAt!).inMilliseconds < _glareEvSettleMs) {
      return;
    }
    final wantsDarker = _lastStableBrightness > _glareHighLuma;
    final wantsBrighter =
        _lastStableBrightness < _glareLowLuma && _appliedEvOffset < 0.0;
    if (!wantsDarker && !wantsBrighter) return;
    final step = wantsDarker ? _glareEvStep : -_glareEvStep;
    _evChangeInFlight = true;
    _lastGlareEvAdjustAt = now;
    cam.getMinExposureOffset().then((min) async {
      final max = await cam.getMaxExposureOffset();
      final target = (_appliedEvOffset + step).clamp(min, max);
      if ((target - _appliedEvOffset).abs() < 0.05) return;
      _appliedEvOffset = target;
      await cam.setExposureOffset(_appliedEvOffset);
    }).catchError((_) {}).whenComplete(() => _evChangeInFlight = false);
  }

  /// Zoom-to-fill: called every frame with the current under-fill reading.
  /// Only ever zooms IN, only after a sustained (not single-frame) under-fill
  /// streak, and only up to the device's own max zoom -- see the field
  /// comments above `_zoomLevel` for why this never zooms back out. Returns
  /// true once zoom is maxed out and can no longer help (the caller falls
  /// back to the existing "Move closer" hint at that point).
  bool _maybeAdjustZoom(bool tooFar) {
    if (!tooFar) {
      _underfillStreak = 0;
      return false;
    }
    final atMax = _zoomLevel >= _maxZoomLevel - 0.01;
    if (atMax) return true;
    _underfillStreak++;
    if (_underfillStreak < _underfillStreakThreshold) return false;
    _underfillStreak = 0;
    if (_zoomChangeInFlight) return false;
    final cam = _camera;
    if (cam == null) return false;
    final target = (_zoomLevel + _zoomStep).clamp(1.0, _maxZoomLevel);
    if ((target - _zoomLevel).abs() < 0.01) return false;
    _zoomChangeInFlight = true;
    cam.setZoomLevel(target).then((_) {
      _zoomLevel = target;
      _zoomEverApplied = true;
    }).catchError((_) {}).whenComplete(() => _zoomChangeInFlight = false);
    return false;
  }

  /// Supplementary detail burst fired AFTER the main 8-shot burst is already
  /// safely captured and encoded (see the call site in _fireBurst) -- zooms
  /// in on frame CENTER (CameraX has no pan control) at a fixed higher zoom
  /// level to trade FOV for pixel density on the pad's most topologically
  /// complex region, the whorl core. Best-effort throughout: any failure
  /// here (zoom rejected, a shot fails, decode fails) only ever costs these
  /// extra frames -- `_detailFrames` may end up shorter than
  /// `_detailBurstCount` or even empty, which the backend treats as "no
  /// detail candidate available" rather than an error.
  ///
  /// Reuses the main burst's own flash/EV plumbing (`_flash`, the same
  /// `flashEvStep` computed once per burst in `_fireBurst`) rather than
  /// re-deriving it, so the detail shots get the same adaptive exposure
  /// correction the main burst's flash frames already do.
  Future<void> _fireDetailBurst(
    CameraController cam, {
    required bool torchCapable,
    required double flashEvStep,
    double? minEv,
    double? maxEv,
  }) async {
    _detailFrames.clear();
    _detailFramesFlash.clear();
    _detailZoomAppliedLevel = null;

    // Device max zoom may be below the nominal _detailZoomLevel -- query the
    // TRUE hardware ceiling here rather than reusing _maxZoomLevel, which is
    // deliberately capped at _maxZoomFill (1.3x) for the unrelated zoom-to-
    // fill feature above and would otherwise prevent ever reaching 2x.
    var target = _detailZoomLevel;
    try {
      final deviceMax = await cam.getMaxZoomLevel();
      target = _detailZoomLevel.clamp(1.0, deviceMax);
    } catch (_) {}

    try {
      await cam.setZoomLevel(target).timeout(const Duration(seconds: 3));
      _detailZoomAppliedLevel = target;
    } catch (e) {
      debugPrint('[front] detail-zoom setZoomLevel failed (non-fatal): $e');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: _detailZoomSettleMs));

    _apply(
      (s) => s.copyWith(confirmationText: 'Hold still — capturing detail…'),
      force: true,
    );

    try {
      for (var i = 0; i < _detailBurstCount; i++) {
        final wantFlash = torchCapable && i.isOdd; // ambient, flash, ambient
        try {
          if (wantFlash) {
            await _flash!.activate();
            if (minEv != null && maxEv != null) {
              await cam.setExposureOffset(
                  (_appliedEvOffset + flashEvStep).clamp(minEv, maxEv));
            }
            await Future<void>.delayed(
                const Duration(milliseconds: _burstFlashSettleMs));
          } else {
            await _flash?.deactivate();
            if (minEv != null && maxEv != null) {
              await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
            }
          }
        } catch (_) {}
        try {
          final xfile = await cam.takePicture();
          final jpeg = await xfile.readAsBytes();
          final decoded = await decodeStillJpegToLuma(
            jpeg, _sensorOrientation,
            targetWidth: _stillDecodeTargetWidth,
          );
          if (decoded != null) {
            final encoded = await compute(
              _encodeBurstIsolate,
              _BurstEncodeArgs(decoded.luma, decoded.width, decoded.height),
            );
            _detailFrames.add(encoded);
            _detailFramesFlash.add(wantFlash);
          }
        } catch (e) {
          debugPrint('[front] detail-zoom shot $i failed (non-fatal): $e');
        }
      }
    } finally {
      try {
        await _flash?.deactivate();
        if (minEv != null && maxEv != null) {
          await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
        }
      } catch (_) {}
      // Always reset zoom regardless of how many shots succeeded -- secondary
      // cameras and the rest of the flow assume 1x.
      try {
        await cam.setZoomLevel(1.0).timeout(const Duration(seconds: 3));
      } catch (_) {}
      _detailBurstFired = true;
      _apply((s) => s.copyWith(confirmationText: null), force: true);
    }
  }

  static double _lumaSharpness(Uint8List luma, int w, int h) {
    if (w < 8 || h < 8 || luma.length < w * h) return 0.0;
    final x0 = w ~/ 4, x1 = 3 * w ~/ 4;
    final y0 = h ~/ 4, y1 = 3 * h ~/ 4;
    const stepPx = 3;
    double sum = 0.0, sumSq = 0.0;
    int n = 0;
    for (var y = y0 + 1; y < y1 - 1; y += stepPx) {
      final row = y * w;
      for (var x = x0 + 1; x < x1 - 1; x += stepPx) {
        final c = luma[row + x];
        final lap = (4 * c -
                luma[row + x - 1] -
                luma[row + x + 1] -
                luma[row - w + x] -
                luma[row + w + x])
            .toDouble();
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 0.0;
    final mean = sum / n;
    return sumSq / n - mean * mean;
  }

  /// Fires (or finishes processing) the main 8-shot burst. When
  /// [preCollectedShots] is supplied (the guided-sweep path -- see
  /// _completeSweep), the shots are already captured; this skips straight to
  /// the shared post-collection work (torch-off restore, decode/encode,
  /// detail-zoom burst, success feedback, upload). When null, falls back to
  /// the original static collection loop (stream stopped, all 8 shots fired
  /// back-to-back) -- kept for structural completeness, though the only
  /// active caller is now _completeSweep.
  Future<void> _fireBurst({
    List<_RawShot>? preCollectedShots,
    List<double?>? preCollectedCentroids,
    double? gyroAtCapture,
  }) async {
    if (_burstInFlight || _disposed) return;
    _burstInFlight = true;
    // Snapshot device stillness at the moment the burst fires -- diagnostic
    // only (stored alongside laplacianScore below), for tuning
    // _maxSteadyDegPerSec against real capture outcomes.
    final gyro = gyroAtCapture ?? _gyroMagnitudeDegPerSec;
    _apply(
      (s) => s.copyWith(
        isCapturingBurst: true,
        burstProgress: preCollectedShots != null ? 1.0 : 0.0,
        phase: FrontCapturePhase.capturing,
      ),
      force: true,
    );

    final cam = _camera;
    final torchCapable =
        preCollectedShots != null ? _sweepTorchCapable : (_flash?.isNeeded ?? false);
    final flashEvStep =
        preCollectedShots != null ? _sweepFlashEvStep : _adaptiveFlashEvStep();
    _flashEvDebug = {
      'evStep': double.parse(flashEvStep.toStringAsFixed(3)),
      'evBracket': _flashEvBracketMultipliers
          .map((m) => double.parse((flashEvStep * m).toStringAsFixed(3)))
          .toList(),
      'flashIntensity': _flash?.intensity,
      'flashMode': _flash?.modeName,
    };
    // Snapshot the running live-wavelength estimate at the moment the burst
    // actually fires (same convention as _flashEvDebug above), not at
    // doc-write time -- the hold could end slightly before upload.
    _wavelengthDebug = {
      'liveWavelengthPx': _liveWavelengthPx,
      'liveWavelengthStillPx': _liveWavelengthStillPx,
      'scaleToStill': _liveWavelengthPx != null && _liveWavelengthPx! > 0
          ? (_liveWavelengthStillPx ?? 0) / _liveWavelengthPx!
          : null,
      'sampleCount': _wavelengthSampleCount,
      'axis': _wavelengthAxis,
    };

    double? minEv, maxEv;
    if (preCollectedShots != null) {
      minEv = _sweepMinEv;
      maxEv = _sweepMaxEv;
    } else if (torchCapable) {
      try {
        minEv = await cam?.getMinExposureOffset();
        maxEv = await cam?.getMaxExposureOffset();
      } catch (_) {}
    }

    final rawShots = <_RawShot>[];

    try {
      if (cam == null) return;

      if (preCollectedShots != null) {
        rawShots.addAll(preCollectedShots);
      } else {
        await _stopStream();

        // Alternate: even-indexed shots are ambient (torch OFF), odd shots are
        // flash (torch ON with negative EV). At 10cm the torch at full ambient EV
        // blows out the pad centre completely (confirmed on first real capture:
        // NFIQ2=9). Alternating gives the backend both lighting conditions;
        // _download_front_only_frames already splits frames into ambient_frames
        // and flash_frames so AFIS can pick the best-exposed set.
        var wasFlashLastShot = false;
        var flashShotIndex = 0;
        for (var i = 0; i < _burstFrameCount; i++) {
          final wantFlash = torchCapable && i.isOdd;
          try {
            if (wantFlash) {
              await _flash!.activate();
              if (minEv != null && maxEv != null) {
                final multiplier = _flashEvBracketMultipliers[
                    flashShotIndex % _flashEvBracketMultipliers.length];
                final target = _appliedEvOffset + flashEvStep * multiplier;
                await cam.setExposureOffset(target.clamp(minEv, maxEv));
              }
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            } else {
              await _flash?.deactivate();
              if (minEv != null && maxEv != null) {
                await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
              }
              // Real asymmetry found 2026-07-24: the flash-ON transition above
              // gets an explicit settle delay before its shot fires, but the
              // flash-OFF transition (torch physically switching off AND the EV
              // offset dropping back from flashEvStep to base) went straight
              // into takePicture() with zero settle time -- only when this shot
              // actually FOLLOWS a real flash shot (`wasFlashLastShot`, not
              // just "this is an ambient slot" -- torch-incapable/bright-mode
              // bursts never fire flash at all, so they must NOT pick up this
              // delay on every single shot). If the sensor needs real time to
              // re-converge exposure after either change -- which is exactly
              // why the activate() side already waits -- every other "ambient"
              // shot in a normal-mode burst could be captured mid-transition,
              // still influenced by the prior flash frame's EV state.
              // Symmetric fix: same settle window on the way back down. Not
              // yet device-tested -- same standing discipline as every other
              // capture-side change this project.
              if (wasFlashLastShot) {
                await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
              }
            }
          } catch (_) {}
          if (wantFlash) flashShotIndex++;
          wasFlashLastShot = wantFlash;
          try {
            final xfile = await cam.takePicture();
            final jpeg = await xfile.readAsBytes();
            // Locked-shutter-speed investigation, Stage 1 (2026-08-02): the
            // `camera` plugin has no public API for manual SENSOR_EXPOSURE_
            // TIME/SENSITIVITY control (confirmed against the plugin's own
            // changelog), so real shutter-speed locking would need a native
            // Camera2Interop lift. Before spending that, read what the HAL's
            // own auto-exposure actually did for THIS shot straight out of
            // the JPEG's EXIF -- zero plugin/native change, just bytes we
            // already have.
            final exif = parseJpegExposureExif(jpeg);
            rawShots.add(_RawShot(
              jpeg: jpeg,
              flashOn: _flash?.isFlashOn ?? false,
              laplacianScore: _focusValue > 0 ? _focusValue * (_focusPeak + 1e-6) : null,
              timestamp: DateTime.now(),
              exif: exif,
            ));
            // MAC3D capture-UX-polish mockup dev-handoff note: "fire a light
            // haptic tick on each burst frame, stronger buzz on capture
            // completion" -- the completion buzz already existed
            // (HapticFeedback.heavyImpact() below); this adds the per-frame
            // tick, same call already used elsewhere in this file for
            // real-time "something just happened" confirmation.
            unawaited(HapticFeedback.selectionClick());
          } catch (e) {
            debugPrint('[front] burst shot $i failed (non-fatal): $e');
          }
          _apply(
            (s) => s.copyWith(burstProgress: (i + 1) / _burstFrameCount),
            force: true,
          );
          if (i < _burstFrameCount - 1) {
            await Future<void>.delayed(const Duration(milliseconds: _burstShotDelayMs));
          }
        }
      }
      // Always restore torch-off and base EV when done.
      try {
        await _flash?.deactivate();
        if (minEv != null && maxEv != null) {
          await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
        }
      } catch (_) {}

      // Real device test (2026-07-22): a noticeable silent pause right at
      // the end of the main burst -- the guide's fill ring hits 100% (last
      // shutter click) then nothing visibly happens until "✓ Captured"
      // appears. Root cause: the decode+sharpness+re-encode work below runs
      // AFTER the ring already reads full, with no UI change during it, so
      // it reads as a freeze rather than the app doing something. This work
      // got real slower after the _stillDecodeTargetWidth 2048->3200 bump
      // (2026-07-20, ~2.4x more decode pixels per frame across all 8 burst
      // shots) — plausibly what made an always-present pause newly
      // noticeable. Show an explicit "Processing…" banner for this window
      // instead of a silent gap.
      _apply((s) => s.copyWith(confirmationText: 'Processing…'), force: true);

      // Decode + re-encode off the UI isolate.
      final futures = <Future<({Uint8List bytes, bool flashOn, double? lap, DateTime ts, JpegExposureExif exif})>>[];
      for (final raw in rawShots) {
        futures.add(() async {
          final decoded = await decodeStillJpegToLuma(
            raw.jpeg, _sensorOrientation,
            targetWidth: _stillDecodeTargetWidth,
          );
          if (decoded == null) throw StateError('decode failed');
          final sharp = _lumaSharpness(decoded.luma, decoded.width, decoded.height);
          final encoded = await compute(
            _encodeBurstIsolate,
            _BurstEncodeArgs(decoded.luma, decoded.width, decoded.height),
          );
          return (bytes: encoded, flashOn: raw.flashOn, lap: sharp, ts: raw.timestamp, exif: raw.exif);
        }());
      }

      final results = await Future.wait(futures.map((f) => f.catchError((_) => (
            bytes: Uint8List(0),
            flashOn: false,
            lap: null as double?,
            ts: DateTime.now(),
            exif: const JpegExposureExif(),
          ))));

      // Each sweep shot (_fireSweepShot) already stops/restarts the stream
      // around its own takePicture() call, so by now it's running again --
      // stop it here before any further still captures (the detail-zoom
      // burst below), matching the invariant the static path already
      // established via _stopStream() above.
      if (preCollectedShots != null) {
        await _stopStream();
      }

      // Two-tier adaptive zoom (Phase 0, diagnostic-only backend-side): the
      // main burst above is now safely captured and encoded, so a
      // supplementary higher-zoom detail pass on the pad center can only
      // ever add a candidate, never jeopardise what's already secured.
      try {
        await _fireDetailBurst(
          cam,
          torchCapable: torchCapable,
          flashEvStep: flashEvStep,
          minEv: minEv,
          maxEv: maxEv,
        );
      } catch (e) {
        debugPrint('[front] detail-zoom burst failed entirely (non-fatal): $e');
      }

      HapticFeedback.heavyImpact();
      unawaited(_audio.playAngleSuccess(isFinal: true));
      _apply(
        (s) => s.copyWith(
          isCapturingBurst: false,
          confirmationText: '✓ Captured',
        ),
        force: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: _confirmationDisplayMs));

      await _finishAndUpload(
        results,
        gyro,
        sweepCentroids: preCollectedCentroids,
        sweepDebugData: preCollectedShots != null ? _sweepDebug : null,
      );
    } catch (e) {
      _fail('Capture failed: $e');
    } finally {
      _burstInFlight = false;
      if (!_disposed) {
        _apply((s) => s.copyWith(isCapturingBurst: false, confirmationText: null), force: true);
      }
    }
  }

  /// Best-effort video capture, Phase 0 of the burst+video hybrid spec
  /// (docs/BURST_VIDEO_HYBRID_SCOPE.md) -- records ~6s of video on the SAME
  /// main CameraController the burst just used (no second session, unlike
  /// the secondary-camera loop right after this: that one switches to a
  /// DIFFERENT physical camera and has its own real, already-documented
  /// session-contention history; this stays on the one already-open
  /// session, the lower-risk case). Uploads the raw file -- the backend
  /// decides what candidate frames to pull from it; nothing here decodes or
  /// interprets the video.
  ///
  /// Deliberately does NOT attempt the full spec's multi-region fusion --
  /// see the scope doc for why (unregistered oblique-angle stitching is a
  /// real, unproven research question, not a formality). This only gets a
  /// video onto the capture doc so the backend's Phase 0 (score each
  /// candidate frame independently, no fusion) has real data to work with.
  ///
  /// Never throws past its own try/catch -- a failure here can't jeopardise
  /// the main burst, which is already safely uploaded via the caller's own
  /// separate path regardless of this method's outcome.
  Future<Map<String, dynamic>> _captureSweepVideo(String basePath) async {
    final debug = <String, dynamic>{'attempted': true};
    final svc = _cameraService;
    if (svc == null) {
      debug['error'] = 'no camera service';
      return debug;
    }
    final stopwatch = Stopwatch()..start();
    var recording = false;
    try {
      await _stopStream();
      // The actual record-start -> record-stop -> read-bytes sequence is
      // wrapped in its own timeout, separate from the upload below -- a
      // hang anywhere in native video recording must not block the whole
      // capture forever (try/catch alone doesn't catch a Future that never
      // resolves).
      final bytes = await (() async {
        await svc.startVideoRecording();
        recording = true;
        // Reuses the same distanceHint-driven banner capturingExtra
        // already renders (front_capture_screen.dart) -- no screen-side
        // change needed. Explicit "sweep" instruction, distinct from this
        // phase's own default "hold still" framing (the rest of
        // capturingExtra -- secondary cameras, distance-stage-2 --
        // genuinely wants the thumb held still; this step is the one
        // exception that wants motion).
        _apply((s) => s.copyWith(distanceHint: 'Slowly sweep your thumb left to right'));
        await Future<void>.delayed(const Duration(milliseconds: _sweepVideoDurationMs));

        final xfile = await svc.stopVideoRecording();
        recording = false;
        return xfile.readAsBytes();
      }()).timeout(const Duration(milliseconds: _sweepVideoRecordTimeoutMs));
      stopwatch.stop();
      debug['durationMs'] = stopwatch.elapsedMilliseconds;

      debug['fileSizeBytes'] = bytes.length;
      if (bytes.isEmpty) {
        debug['error'] = 'empty video file';
        return debug;
      }
      final path = '$basePath/sweep_video.mp4';
      await _uploadWithRetry(bytes, path, contentType: 'video/mp4');
      debug['path'] = path;
      debug['uploaded'] = true;
    } catch (e) {
      debug['error'] = e.toString();
      debugPrint('[front] sweep video capture failed (non-fatal): $e');
      if (recording) {
        try {
          await svc.stopVideoRecording();
        } catch (_) {}
      }
    } finally {
      _apply((s) => s.copyWith(distanceHint: null));
    }
    return debug;
  }

  Future<void> _finishAndUpload(
    List<({Uint8List bytes, bool flashOn, double? lap, DateTime ts, JpegExposureExif exif})> shots,
    double gyroAtCapture, {
    List<double?>? sweepCentroids,
    Map<String, dynamic>? sweepDebugData,
  }) async {
    _audio.silence();
    // NOT `uploading` yet -- the secondary-camera + distance-stage-2 blocks
    // below still need the thumb held in place (same physical placement, a
    // different lens/distance). Telling the user "Uploading…" here was the
    // root cause of the 2026-07-17 "fires blindly" report: they saw that
    // text, assumed capture was over, and had already moved by the time the
    // extra torch shots actually fired. `capturingExtra` keeps the guide +
    // camera preview up with an explicit "hold still" message instead; the
    // real `uploading` transition happens below, right before the actual
    // Firestore write + upload begin.
    // Explicitly clear confirmationText when transitioning INTO
    // capturingExtra -- real device-test feedback (2026-08-01): "IR cam
    // did not give me any progress guidance or anything like the main
    // cam". Root cause: _fireBurst sets confirmationText='✓ Captured' just
    // before calling us, and clears it only in its own finally block
    // AFTER we've fully returned. front_capture_screen.dart's headline
    // block is gated on `s.confirmationText == null`, so every countdown
    // ('3…', '2…', '1…'), status ('Now using $friendly'), and per-camera
    // '✓ IR captured' string _showCountdown/_showStopConfirmation write
    // via distanceHint was being rendered but then never actually shown
    // -- the leftover main-burst banner was covering the display slot for
    // the entire secondary-camera flow. Cleared here so those status
    // updates can finally render.
    _apply(
      (s) => s.copyWith(
        phase: FrontCapturePhase.capturingExtra,
        extraProgress: 0.0,
        confirmationText: null,
      ),
      force: true,
    );

    final userId = _userId;
    if (userId == null) {
      _fail('No user ID');
      return;
    }

    try {
      final id = _uuid.v4();
      final basePath = 'captures/$userId/$id';

      final tipAngleDeg =
          (_sensorOrientation == 90 || _sensorOrientation == 270) ? 0.0 : 90.0;

      // Build upload tasks and Firestore frames metadata.
      final uploadTasks = <(Uint8List, String)>[];
      final framesMeta = <Map<String, dynamic>>[];
      var ambIdx = 0, flIdx = 0;

      for (var frameIdx = 0; frameIdx < shots.length; frameIdx++) {
        final s = shots[frameIdx];
        if (s.bytes.isEmpty) continue;
        final type = s.flashOn ? 'fl' : 'amb';
        final idx = s.flashOn ? flIdx++ : ambIdx++;
        final path = '$basePath/front_burst_${type}_$idx.jpg';
        uploadTasks.add((s.bytes, path));
        // centroidX (diagnostic-only, guided-sweep capture): the thumb's
        // intensity-weighted centroid X position at the moment THIS frame
        // fired, normalized 0.0-1.0 within the guide width. sweepCentroids is
        // parallel (by index) to the raw-shot list _fireBurst built `shots`
        // from -- null/absent for the non-sweep static-burst path.
        final centroidX = (sweepCentroids != null && frameIdx < sweepCentroids.length)
            ? sweepCentroids[frameIdx]
            : null;
        framesMeta.add({
          'path': path,
          'angleDeg': 0.0,
          'flashOn': s.flashOn,
          'type': 'burst',
          if (s.lap != null) 'laplacianScore': double.parse(s.lap!.toStringAsFixed(1)),
          'timestamp': s.ts.toIso8601String(),
          if (centroidX != null) 'centroidX': double.parse(centroidX.toStringAsFixed(3)),
          // Locked-shutter-speed investigation, Stage 1: real auto-exposure
          // values the HAL actually used for this shot, read from the JPEG's
          // own EXIF -- not app-controlled (this plugin has no manual
          // exposure API), hence isLockedShutter: false always at this
          // stage. Null fields mean the device/HAL didn't populate that EXIF
          // tag, not a parse failure being silently swallowed.
          if (s.exif.exposureTimeUs != null) 'shutterSpeedUs': s.exif.exposureTimeUs,
          if (s.exif.exposureTimeReadable != null)
            'shutterSpeedReadable': s.exif.exposureTimeReadable,
          if (s.exif.isoValue != null) 'isoValue': s.exif.isoValue,
          'isLockedShutter': false,
        });
      }

      // Detail-zoom frames upload alongside the main burst -- same
      // concurrency batching below, just tagged with their own filename
      // convention so the backend can distinguish them from the main burst.
      final detailPaths = <String>[];
      for (var i = 0; i < _detailFrames.length; i++) {
        final path = '$basePath/detail_zoom_$i.jpg';
        uploadTasks.add((_detailFrames[i], path));
        detailPaths.add(path);
      }

      final rawSensorSupport = await _queryRawSensorSupport();
      final noiseReductionOffSupport = await _queryNoiseReductionSupport();
      final cameraLensInfo = await _queryCameraLensInfo();
      final manualExposureSupport = await _queryManualExposureSupport();
      // Already ran (and was awaited to completion) before the camera even
      // opened, in FrontCaptureScreen._init() -- this just reads the cached
      // result, does not re-trigger the native probe.
      final torchExposureProbe = await probeTorchExposureCompat();

      // Runs BEFORE the secondary-camera loop below (which switches to a
      // different physical camera) so this step's "same main camera,
      // already-open session" assumption holds -- see _captureSweepVideo's
      // own doc comment. Gated on _sweepVideoHybridEnabled -- flip that one
      // flag to detach this feature instantly if a real device test finds
      // a problem, without touching anything else in this file.
      final sweepVideoDebug = _sweepVideoHybridEnabled
          ? await _captureSweepVideo(basePath)
          : <String, dynamic>{'attempted': false, 'reason': 'feature disabled'};

      // Secondary-camera capture and distance-stage-2 capture both run here,
      // BEFORE the single Firestore document write below, and their results
      // are folded directly into that one write. Firestore security rules
      // evaluate a brand-new document's first write against `allow create`
      // (which this project's rules permit for clients), but ANY subsequent
      // `.update()` on that same doc is evaluated against `allow update`,
      // which this project's rules blanket-deny for non-admin clients
      // (`allow update, delete: if false;`). The two blocks below used to
      // run AFTER the initial `.set()` and record their results via a
      // separate `.update()` call each -- both silently rejected by the
      // rules engine every single time, which is why secondaryCameras/
      // distanceStage2 have never actually landed in a real capture doc.
      // Both blocks only touch Cloud Storage (via _uploadWithRetry) for
      // their own image uploads, which has no such restriction, so nothing
      // here depends on the Firestore doc already existing.

      // Best-effort secondary-camera capture: try any OTHER back cameras this
      // device exposes (e.g. IR/night-vision + ultrawide sensors) for one
      // extra torch-lit still each, purely additive to the main flow above.
      // Ported from OscillatingCaptureController (built + validated there,
      // proven server-side: the IR camera's torch shot alone scored
      // competitively with -- and on one device, above -- the main camera's
      // best single frame; see docs/CAPTURE_OPTIMIZATION_SCOPE.md). Was never
      // wired into front_only_v1 before now since that flow didn't exist yet
      // when this was built. Runs BEFORE the single Firestore write below
      // (see the note above) and BEFORE the processEnhanceAndScore trigger,
      // so the backend's one-time doc read sees secondaryCameras already
      // present. A failure here can't jeopardise the main burst, which is
      // uploaded separately below regardless of this block's outcome. Many
      // devices can only hold one camera session open at a time -- opening
      // a second physical camera here may simply fail, which is caught and
      // skipped silently per-camera.
      // Diagnostic trail written unconditionally (unlike secondaryMeta below,
      // which only ever reflects successes) -- added after a real device
      // test on the Doogee S118 (previously confirmed to expose separate
      // IR/ultrawide camera IDs) silently produced zero secondaryCameras
      // with no way to tell whether that meant "no other camera found" or
      // "every attempt failed". Written even on total failure so the next
      // real capture actually explains itself instead of staying silent.
      // Real device test (2026-07-17) found the live preview lags/freezes
      // hard through this whole block, with no visible sign of the other
      // cameras firing -- root cause: the main camera's CameraController
      // stayed fully active (its texture still bound to the on-screen
      // CameraPreview) for the ENTIRE secondary-camera loop while a SECOND,
      // completely separate CameraController was opened and driven at the
      // same time. The `camera` plugin shares a native rendering/platform-
      // channel thread across controllers, so two simultaneously-live
      // sessions contend and stall Flutter's texture updates -- not (only) a
      // sensor-hardware limit, a plugin-level threading one, which is why
      // this reproduced even though secondaryCameras data landed fine in
      // Storage (the DATA path was never broken, only the live view). A
      // first fix (pausePreview()/resumePreview() on the main controller)
      // was NOT sufficient on real hardware -- pausing stops Flutter from
      // requesting new frames but doesn't release the underlying camera
      // session, so the second controller still contended for it.
      //
      // Real fix: route secondary-camera capture through the SAME
      // CameraService the screen's CameraPreview already reads its
      // controller from (a live getter, not a cached reference) via
      // `initializeCamera(cameraDescription: ...)`, which internally
      // disposes the current controller before opening the next one -- a
      // full, clean handoff, not two sessions open at once. Side benefit
      // this also directly satisfies "so I can see the captures firing live
      // for all cameras before upload": since the screen's preview always
      // shows whatever CameraService.controller currently is, switching to
      // each secondary camera this way makes ITS live feed appear on screen
      // while it's active, instead of a frozen/paused main-camera frame.
      final secondaryDebug = <String, dynamic>{'foundBackCams': <String>[]};
      final secondaryMeta = <Map<String, dynamic>>[];
      final mainCameraDescription = _camera?.description;
      final svc = _cameraService;
      // Total/completed "extra capture" steps (secondary cameras) -- drives
      // extraProgress. Defaults to 0 in case availableCameras() itself
      // throws before the real count is known.
      var extraTotal = 0;
      var extraCompleted = 0;
      try {
        final allCams = await availableCameras();
        final mainName = mainCameraDescription?.name;
        secondaryDebug['allCamsCount'] = allCams.length;
        secondaryDebug['mainCamName'] = mainName;
        final allBack = allCams.where((c) =>
            c.lensDirection == CameraLensDirection.back && c.name != mainName);
        // Sensor-size quality gate: skip auxiliary cameras (macro, depth)
        // whose physical sensor area is less than 50% of the main camera's.
        // They add upload cost without improving quality. Exception: always
        // include MONO/NIR cameras regardless of size -- they offer a unique
        // spectral channel no RGB sensor can replicate, which is exactly what
        // makes them useful for beta-device discovery (if a user has a real
        // IR sensor we want to know and test it, even on a small chip).
        final lensInfo = await _queryCameraLensInfo();
        final mainInfo = lensInfo?[mainName];
        final mainArea = mainInfo != null
            ? ((mainInfo['sensorWidthMm'] as double? ?? 0) *
               (mainInfo['sensorHeightMm'] as double? ?? 0))
            : 0.0;
        final others = allBack.where((c) {
          final info = lensInfo?[c.name];
          if (info == null || mainArea == 0) return true; // no data → include
          if (info['colorFilterArrangement'] == 'MONO') return true; // true NIR → always include
          final area = ((info['sensorWidthMm'] as double? ?? 0) *
                        (info['sensorHeightMm'] as double? ?? 0));
          return area == 0 || area >= mainArea * 0.5;
        }).toList(growable: false);
        secondaryDebug['foundBackCams'] =
            allBack.map((c) => c.name).toList(growable: false);
        secondaryDebug['qualifiedBackCams'] =
            others.map((c) => c.name).toList(growable: false);
        // Drives the guide's fill-ring during capturingExtra (see
        // extraProgress on FrontCaptureState) -- CTO real-device feedback
        // 2026-07-20/22: only the main burst had a progress cue; secondary
        // cameras (wide/IR) left the guide static the whole time.
        extraTotal = others.length;
        for (final desc in others) {
          final labelName = desc.name.toLowerCase();
          final friendly = labelName.contains('ir') || labelName.contains('night')
              ? 'IR camera'
              : labelName.contains('wide')
                  ? 'wide lens'
                  : 'secondary camera';
          var succeeded = false;
          try {
            CameraController active;
            if (svc != null) {
              await svc
                  .initializeCamera(
                    lensDirection: CameraLensDirection.back,
                    resolution: ResolutionPreset.max,
                    cameraDescription: desc,
                  )
                  .timeout(const Duration(seconds: 8));
              active = svc.controller!;
              _camera = active; // resync so the UI's live preview sees the current controller
            } else {
              // Defensive fallback if no CameraService was supplied (should
              // not happen via the real screen, which always passes one) --
              // same isolated-controller behavior as before this fix, so
              // this path still works, just without the live-preview fix.
              active = CameraController(desc, ResolutionPreset.max, enableAudio: false);
              await active.initialize().timeout(const Duration(seconds: 8));
            }

            // Explicit per-camera-turn sequence (2026-07-23), per the CTO's
            // real-device report: "no dead stop for any camera... it goes
            // ahead to the next camera" and "Uploading... but camera is
            // still live in the background". Step 1+2: switch in, show a
            // generic centered guide on THIS camera's own live feed (already
            // shown automatically -- _cameraLayer() reads the live
            // CameraService controller). Not precisely calibrated per-lens
            // yet (real per-lens FOV-offset data doesn't exist) -- a
            // deliberate first cut, per the camera-comparison investigation
            // this same session: secondary cameras have real, sometimes-
            // excellent ridge detail but fire blind with no framing cue at
            // all today.
            _apply((s) => s.copyWith(
                  distanceHint: 'Now using $friendly — center your thumb pad',
                  activeGuideShape: _secondaryCameraGuideShape,
                  extraProgress: extraCompleted / extraTotal,
                ));
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            // Step 3: countdown -- real time to use the guide above before
            // the shutter fires, not just a label change.
            await _showCountdown();

            // Step 4: capture. Real device test (2026-07-22): capture got
            // permanently stuck on the wide-angle camera, never progressing
            // past this phase -- root cause: initializeCamera above already
            // has an 8s timeout, but NOTHING after it did. takePicture()
            // itself is a raw await with no bound, so a hung native capture
            // session stalled the whole rest of the flow with zero
            // user-visible progress. Bound the ENTIRE per-camera
            // exposure/focus/burst sequence in one timeout so a hang here
            // can only ever cost this one camera's data.
            //
            // Widened 12s -> 28s (2026-07-23): real Firestore data across 3
            // captures after the burst upgrade (1->3 shots) showed BOTH
            // secondary cameras timing out on every one, always mid-upload
            // -- 12s was calibrated for the old single-shot flow.
            //
            // Widened 28s -> 38s (2026-07-26): 3/4 consecutive real captures
            // showed cam-3 timing out at flash_off with shot_2 upload still
            // running. Real burst timeline: ~4-8s setup+capture, then 3
            // parallel uploads each taking ~9-20s (bandwidth contention).
            // shot_2 consistently arrives last, taking ~20s from upload start.
            // Worst-case 8s init + 25s shot_2 upload = 33s; 38s gives real margin.
            final stageDebug = <String, dynamic>{'stage': 'not_started'};
            final paths = await _captureSecondaryBurst(
              active,
              desc,
              basePath,
              stageDebug,
            ).timeout(const Duration(seconds: 38), onTimeout: () {
              debugPrint(
                  '[front] secondary camera ${desc.name} timed out mid-capture '
                  '(stuck at: ${stageDebug['stage']}) -- skipping');
              secondaryDebug['${desc.name}_timeout'] = true;
              // Last stage entered before the timeout fired -- e.g.
              // 'settle_delay'/'focus_setup' points at AF convergence never
              // completing, 'shot_N' points at takePicture() itself hanging.
              secondaryDebug['${desc.name}_stuckAt'] = stageDebug['stage'];
              return <String>[];
            });
            // Real bug found 2026-07-23: the per-camera stageDebug map (now
            // carrying focusConvergedMs/focusScoreAtFire and per-shot
            // capture/upload timings) was only ever read for its 'stage'
            // key on timeout -- every other field silently never reached
            // Firestore, regardless of outcome. Preserve the whole map here,
            // unconditionally, so the next real capture's data actually
            // shows the new diagnostics.
            secondaryDebug['${desc.name}_stageDebug'] =
                Map<String, dynamic>.from(stageDebug);

            // Step 5: explicit, AWAITED stop -- regardless of success or
            // timeout -- before this iteration ends. Previously this loop
            // relied entirely on the NEXT camera's own initializeCamera()
            // call to dispose this one as a side effect (internally,
            // CameraService._initializeCameraAttempt calls disposeCamera()
            // first) -- meaning there was never an await'd "this camera has
            // fully stopped" checkpoint owned by the turn that just
            // finished. A timeout firing meant the loop raced on to open
            // the NEXT camera while the timed-out camera's takePicture()/
            // upload call was very likely STILL running in the background
            // (.timeout() cannot cancel the underlying native Future) --
            // the leading real ANR ("ClearBridge Beta isn't responding")
            // hypothesis this session. Disposing HERE, awaited, closes that
            // gap at its source: the native session is actively torn down
            // (which should fail any still-pending call against it) before
            // we ever consider this turn done.
            if (svc != null) {
              await svc.disposeCamera();
            } else {
              try {
                await active.dispose();
              } catch (_) {}
            }
            // Real gap found 2026-07-29: a timeout above means
            // _captureSecondaryBurst's underlying Future is very likely
            // still running in the background (.timeout() doesn't cancel
            // it -- e.g. still inside takePicture()/an upload call against
            // the controller just disposed). Android's native camera
            // teardown is itself asynchronous at the HAL level, so this
            // awaited dispose() resolving doesn't guarantee the native
            // session has fully closed before the NEXT camera's
            // initializeCamera() opens below -- the same "two native camera
            // sessions contending" hazard this project's own ANR history
            // already root-caused once (see the 28s->38s/12s->28s timeout
            // widening notes above). Only pay this on the timeout path (not
            // every successful turn, which has no orphaned Future to wait
            // out) -- real, deliberate cost only where there's real risk.
            if (secondaryDebug['${desc.name}_timeout'] == true) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }

            if (paths.isNotEmpty) {
              secondaryMeta.add({'name': desc.name, 'paths': paths});
              secondaryDebug['${desc.name}_ok'] = true;
              succeeded = true;
            }
            await _showStopConfirmation(friendly, success: succeeded);
            extraCompleted++;
            _apply((s) => s.copyWith(
                  distanceHint: null,
                  extraProgress: extraCompleted / extraTotal,
                ));
          } catch (e) {
            debugPrint('[front] secondary camera ${desc.name} skipped: $e');
            secondaryDebug['${desc.name}_error'] = e.toString();
            await _showStopConfirmation(friendly, success: false);
            extraCompleted++;
            _apply((s) => s.copyWith(
                  distanceHint: null,
                  extraProgress: extraCompleted / extraTotal,
                ));
          }
        }
      } catch (e) {
        debugPrint('[front] secondary camera capture skipped entirely: $e');
        secondaryDebug['fatalError'] = e.toString();
      } finally {
        _apply((s) => s.copyWith(distanceHint: null, activeGuideShape: null));
      }

      // Real upload begins here -- the actual Firestore write + main burst
      // upload below, not the best-effort extra-camera work above. This is
      // the honest point to switch the UI to "Uploading…". Stop the camera
      // FIRST (real device test, 2026-07-23: the live preview kept running
      // visibly behind the uploading screen -- nothing here needs the
      // camera again; `uploading` only ever transitions to `complete`/
      // `error`), so by the time the UI actually shows "Uploading…" the
      // camera has genuinely stopped, not just been painted over.
      try {
        await _cameraService?.disposeCamera();
      } catch (_) {}
      _apply((s) => s.copyWith(phase: FrontCapturePhase.uploading, uploadProgress: 0), force: true);

      // Single Firestore write for the whole capture -- evaluated by the
      // security rules as `create` (the doc doesn't exist yet), which is
      // the only client-writable path. Everything gathered above (main
      // burst frames, rawSensorSupport, secondary-camera results, distance-
      // stage-2 results) goes into this one call; there is no later
      // `.update()` on this doc from the client.
      final firestoreFuture = FirebaseFirestore.instance.collection('captures').doc(id).set({
        'captureId': id,
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'pending',
        'source': 'clearbridge_beta',
        'captureMode': 'front_only_v1',
        'captureMethod': 'front_only_v1',
        'guideRegion': {
          'cx': _guideCx,
          'cy': _guideCy,
          'rx': _guideRx,
          'ry': _guideRy,
          'n': _guideN,
          'tipAngleDeg': tipAngleDeg,
        },
        'burstFrameCount': shots.where((s) => s.bytes.isNotEmpty).length,
        'flashEvDebug': _flashEvDebug,
        'liveWavelengthDebug': _wavelengthDebug,
        if (sweepDebugData != null) 'sweepDebug': sweepDebugData,
        'zoomDebug': {
          'zoomApplied': _zoomEverApplied,
          'finalZoomLevel': double.parse(_zoomLevel.toStringAsFixed(3)),
          'maxZoomLevel': double.parse(_maxZoomLevel.toStringAsFixed(3)),
        },
        'detailZoomCapture': {
          'paths': detailPaths,
          'zoomLevel': _detailZoomAppliedLevel,
          'shotCount': _detailFrames.length,
          'fired': _detailBurstFired,
          'flashFlags': _detailFramesFlash,
        },
        'gyroMagnitudeDegPerSec': double.parse(gyroAtCapture.toStringAsFixed(2)),
        'frames': framesMeta,
        if (rawSensorSupport != null) 'rawSensorSupport': rawSensorSupport,
        if (noiseReductionOffSupport != null)
          'noiseReductionOffSupport': noiseReductionOffSupport,
        if (cameraLensInfo != null) 'cameraLensInfo': cameraLensInfo,
        if (manualExposureSupport != null)
          'manualExposureSupport': manualExposureSupport,
        if (torchExposureProbe != null) 'torchExposureProbe': torchExposureProbe,
        'sweepVideoDebug': sweepVideoDebug,
        'secondaryCameraDebug': secondaryDebug,
        if (secondaryMeta.isNotEmpty) 'secondaryCameras': secondaryMeta,
      }, SetOptions(merge: true));

      var completed = 0;
      final total = math.max(uploadTasks.length, 1);
      for (var i = 0; i < uploadTasks.length; i += _uploadConcurrency) {
        final end = math.min(i + _uploadConcurrency, uploadTasks.length);
        await Future.wait([
          for (var j = i; j < end; j++)
            _uploadWithRetry(uploadTasks[j].$1, uploadTasks[j].$2).then((_) {
              completed++;
              _apply((s) => s.copyWith(uploadProgress: completed / total));
            }),
        ]);
      }
      await firestoreFuture;

      () async {
        try {
          await FirebaseFunctions.instanceFor(region: 'africa-south1')
              .httpsCallable('processEnhanceAndScore')
              .call({
            'captureId': id,
            'userId': userId,
            'basePath': basePath,
            'captureMode': 'front_only_v1',
          });
        } catch (e) {
          debugPrint('[front] processEnhanceAndScore trigger failed (non-blocking): $e');
        }
      }();

      _apply(
        (s) => s.copyWith(
          phase: FrontCapturePhase.complete,
          captureId: id,
          uploadProgress: 1.0,
        ),
        force: true,
      );
    } catch (e) {
      _fail('Upload failed: $e');
    }
  }

  /// Exposure/focus setup + torch burst for ONE secondary (IR/wide) camera.
  /// Extracted so the whole sequence can be wrapped in a single `.timeout()`
  /// by the caller -- see the 2026-07-22 real-device "stuck on Wide cam"
  /// report: `takePicture()` (and, in principle, any of the setup calls
  /// below) is a raw platform-channel await with no bound of its own, so a
  /// hang on a secondary sensor's native capture session previously stalled
  /// the entire remaining capture forever, not just this one camera.
  /// `stageDebug` is mutated SYNCHRONOUSLY right before each major await --
  /// real device test 2026-07-22: both secondary cameras timed out with no
  /// way to tell whether they stalled on AF convergence, exposure setup, or
  /// a specific shot's takePicture() call (the CTO separately reported "IR
  /// cam struggled to focus", consistent with an AF-convergence stall, but
  /// the raw timeout alone couldn't confirm that). Since `.timeout()` on
  /// the caller's side doesn't cancel this function -- it just stops
  /// waiting for it -- a synchronous write immediately before the await
  /// that ends up hanging is what survives into secondaryDebug even though
  /// the overall Future never completes in time.
  Future<List<String>> _captureSecondaryBurst(
    CameraController active,
    CameraDescription desc,
    String basePath,
    Map<String, dynamic> stageDebug,
  ) async {
    stageDebug['stage'] = 'flash_on';
    await active.setFlashMode(FlashMode.torch);
    // Adaptive EV step -- same curve as the main burst (_adaptiveFlashEvStep),
    // so the secondary camera's flash exposure responds to ambient brightness
    // the same way the main burst does. Ambient luma reading is scene-level
    // (doesn't change by active camera), so the value is valid here.
    // setExposureOffset() is safe; setExposureMode() is the Camera2-interop
    // landmine, never called here.
    stageDebug['stage'] = 'exposure_setup';
    try {
      final minEv = await active.getMinExposureOffset();
      final maxEv = await active.getMaxExposureOffset();
      await active.setExposureOffset(_adaptiveFlashEvStep().clamp(minEv, maxEv));
    } catch (_) {
      // Some secondary sensors may not support exposure offset -- non-fatal,
      // the burst still fires at default exposure.
    }
    // AUTOFOCUS on the near thumb before firing. Without this the secondary
    // sensor stays at its resting focus (usually far), so a ~10cm thumb
    // comes back badly out of focus -- real device test 2026-07-18: the
    // wide lens returned laplacian ~18 (vs ~1900 on the focused main camera)
    // and never converged. Point AF at the frame centre (where the thumb
    // sits) and give it time to converge before the burst; guard each call
    // since some secondary sensors are fixed-focus and will throw.
    stageDebug['stage'] = 'focus_setup';
    try {
      await active.setFocusPoint(const Offset(0.5, 0.5));
      await active.setFocusMode(FocusMode.auto);
    } catch (_) {
      // fixed-focus secondary sensor -- nothing to converge, fall through to
      // the settle delay and shoot at native focus.
    }
    // Real device report, 2026-07-23: some secondary cameras don't focus
    // immediately, producing blurry captures. This used to be a blind fixed
    // 1400ms delay with zero verification that AF actually converged --
    // unlike the primary camera's own burst, which only fires once a real
    // measured sharpness signal (_focusValue) clears a threshold. Replaced
    // with an equivalent measured wait on the secondary camera's own stream.
    stageDebug['stage'] = 'settle_delay';
    await _waitForSecondaryFocusLock(active, stageDebug);
    // Lock focus at the converged position so AF can't drift between shots.
    // Same as the primary camera's _lockFocusOnly() before its own burst.
    stageDebug['stage'] = 'focus_lock';
    try {
      await active.setFocusMode(FocusMode.locked);
    } catch (_) {}
    final safeName = desc.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final secondarySensorOrientation = desc.sensorOrientation;
    // Capture RAW shots only while the user holds still, then decode/encode/
    // upload ALL of them afterward -- mirrors the main burst's own
    // _finishAndUpload pattern. Real device regression found 2026-07-25:
    // doing the grayscale decode+encode INLINE per shot (as first shipped)
    // pushed captureMs from ~600ms to ~7100-7800ms per shot on a real
    // device -- moving the expensive work back into the "hold still" phase
    // it was built to avoid, and blowing the 28s per-camera timeout
    // (secondaryCameraDebug showed '3_timeout: true', stuck at
    // 'flash_off'). Capture stays fast; the expensive work now happens
    // after, in parallel, same as the upload step already does.
    // Real bug found + fixed 2026-07-29: unlike the main burst's own per-shot
    // loop (_fireBurst), which wraps each takePicture() in its own try/catch
    // so one bad shot just yields fewer frames, this loop had no per-shot
    // guard at all -- any single transient CameraException on shot 1 of 3
    // threw out of the whole function, discarding shots 0 (and any after)
    // even if they'd already succeeded. The outer per-camera catch in
    // _finishAndUpload still keeps this from crashing the capture, but it
    // meant an avoidable total loss of that camera's already-good data on a
    // transient glitch. Now: each shot is individually guarded; a failure
    // stops the burst early (rather than leaving a gap mid-sequence, which
    // the encode/upload loops below assume don't exist) but keeps whatever
    // was already captured.
    final rawShots = <Uint8List>[];
    for (var i = 0; i < _secondaryBurstCount; i++) {
      stageDebug['stage'] = 'shot_$i';
      final shotStart = DateTime.now();
      try {
        final shot = await active.takePicture();
        stageDebug['stage'] = 'shot_${i}_readBytes';
        rawShots.add(await shot.readAsBytes());
        stageDebug['shot_${i}_captureMs'] =
            DateTime.now().difference(shotStart).inMilliseconds;
      } catch (e) {
        stageDebug['shot_${i}_error'] = e.toString();
        debugPrint('[front] secondary camera shot $i failed (non-blocking): $e');
        break;
      }
    }
    stageDebug['stage'] = 'flash_off';
    await active.setFlashMode(FlashMode.off);
    if (rawShots.isEmpty) return const <String>[];
    final shotCount = rawShots.length;

    // Downscale + convert to grayscale before upload -- same convention the
    // main burst already uses (decodeStillJpegToLuma/encodeGrayscaleJpeg).
    // takePicture() on a secondary sensor returns a full native-ISP-
    // resolution COLOR JPEG; without this, uploads were 12-20s per shot
    // even in parallel. Falls back to the raw JPEG on any decode/encode
    // failure so this can never block a capture. Run via Future.wait (not
    // a sequential loop) so the underlying platform decoder can overlap
    // work across shots, same as the main burst's own decode/encode block.
    final encoded = await Future.wait(List.generate(shotCount, (i) async {
      final encodeStart = DateTime.now();
      var bytes = rawShots[i];
      try {
        final decoded = await decodeStillJpegToLuma(
          rawShots[i], secondarySensorOrientation,
          targetWidth: _stillDecodeTargetWidth,
        );
        if (decoded != null) {
          bytes = await compute(
            _encodeBurstIsolate,
            _BurstEncodeArgs(decoded.luma, decoded.width, decoded.height),
          );
        }
      } catch (_) {}
      stageDebug['shot_${i}_encodeMs'] =
          DateTime.now().difference(encodeStart).inMilliseconds;
      stageDebug['shot_${i}_encodedBytes'] = bytes.length;
      return bytes;
    }));

    // Upload all shots in parallel now that the user no longer needs to hold.
    final paths = List<String>.filled(shotCount, '');
    await Future.wait(
      List.generate(shotCount, (i) async {
        final path = '$basePath/secondary_${safeName}_torch_$i.jpg';
        stageDebug['shot_${i}_uploadStage'] = 'uploading';
        final uploadStart = DateTime.now();
        await _uploadWithRetry(encoded[i], path);
        stageDebug['shot_${i}_uploadMs'] =
            DateTime.now().difference(uploadStart).inMilliseconds;
        paths[i] = path;
      }),
    );
    stageDebug['stage'] = 'done';
    return paths;
  }

  /// Waits for the secondary camera's own autofocus to actually converge,
  /// measured via the same peak-normalized, EMA-smoothed Laplacian sharpness
  /// signal already used for the primary camera's own `_focusValue`/`onTarget`
  /// gating (`_onFrame`, `_hybrid.offerFrame`) -- reused here rather than
  /// reinvented, since it's already proven portable (peak-relative, not an
  /// absolute threshold, so it doesn't need re-tuning per lens). Replaces a
  /// blind fixed delay that fired the burst regardless of whether AF had
  /// actually locked (real device report, 2026-07-23: blurry secondary-camera
  /// captures on some lenses).
  ///
  /// Bounded both ways: [minWaitMs] stops a lucky first frame from firing
  /// before the lens has genuinely started moving; [maxWaitMs] guarantees
  /// this can never hang longer than a modest safety margin over the old
  /// fixed delay, even on a sensor whose focus never converges (e.g. a
  /// genuinely fixed-focus secondary camera) -- same best-effort discipline
  /// as every other secondary-camera step. Records `focusConvergedMs`/
  /// `focusScoreAtFire` into the caller's stageDebug so the next real capture
  /// shows whether convergence is actually happening now, and how long it
  /// really takes per camera, instead of guessing.
  Future<void> _waitForSecondaryFocusLock(
    CameraController active,
    Map<String, dynamic> stageDebug, {
    int minWaitMs = 500,
    int maxWaitMs = 2600,
    String keyPrefix = '',
  }) async {
    const roi = Rect.fromLTWH(0.3, 0.3, 0.4, 0.4);
    const lockThreshold = 0.45; // same relative threshold as onTarget's gate.
    var peak = 1.0;
    var focusEma = 0.0;
    var streaming = false;
    var processingFrame = false; // re-entrancy guard: offerFrame can take
        // >33ms, so at 30fps the event queue backs up and starves the UI
        // thread → ANR.  Skip any frame that arrives while one is in flight.
    final start = DateTime.now();
    final completer = Completer<void>();
    void onFrame(CameraImage image) {
      if (completer.isCompleted || processingFrame) return;
      processingFrame = true;
      try {
        final raw = _hybrid.offerFrame(image, thumbRoi: roi);
        if (raw > peak) peak = raw;
        focusEma = HybridCaptureService.ema(
          focusEma,
          (raw / (peak + 1e-6)).clamp(0.0, 1.0),
        );
        final elapsedMs = DateTime.now().difference(start).inMilliseconds;
        if (elapsedMs >= minWaitMs && focusEma > lockThreshold) {
          completer.complete();
        }
      } catch (_) {} finally {
        processingFrame = false;
      }
    }
    try {
      await active.startImageStream(onFrame);
      streaming = true;
      await completer.future.timeout(
        Duration(milliseconds: maxWaitMs),
        onTimeout: () {},
      );
    } catch (_) {
    } finally {
      if (streaming) {
        try {
          await active.stopImageStream();
        } catch (_) {}
      }
      stageDebug['${keyPrefix}focusConvergedMs'] =
          DateTime.now().difference(start).inMilliseconds;
      stageDebug['${keyPrefix}focusScoreAtFire'] =
          double.parse(focusEma.toStringAsFixed(3));
      // true = AF never actually converged; burst fired at the maxWaitMs
      // bound. Distinguishes "fast lock" from "gave up and fired anyway".
      stageDebug['${keyPrefix}focusTimedOut'] = !completer.isCompleted;
    }
  }

  Future<void> _uploadWithRetry(
    Uint8List bytes,
    String path, {
    String contentType = 'image/jpeg',
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await FirebaseStorage.instance
            .ref()
            .child(path)
            .putData(bytes, SettableMetadata(contentType: contentType));
        return;
      } catch (e) {
        final code = e is FirebaseException ? e.code : null;
        final retryable = code == null || !_uploadNonRetryableCodes.contains(code);
        if (!retryable || attempt >= _uploadRetryDelaysMs.length) rethrow;
        await Future.delayed(Duration(milliseconds: _uploadRetryDelaysMs[attempt]));
      }
    }
  }

  Future<void> _stopStream() async {
    if (!_streamRunning) return;
    _streamRunning = false;
    try {
      await _camera?.stopImageStream();
    } catch (_) {}
  }

  void _fail(String message) {
    _audio.silence();
    unawaited(_flash?.deactivate());
    unawaited(_stopStream());
    unawaited(_gyroSub?.cancel());
    _gyroSub = null;
    _apply((s) => s.copyWith(phase: FrontCapturePhase.error, error: message), force: true);
  }

  void _apply(FrontCaptureState Function(FrontCaptureState) update, {bool force = false}) {
    _state = update(_state);
    if (_disposed) return;
    final now = DateTime.now();
    if (force ||
        _lastEmitAt == null ||
        now.difference(_lastEmitAt!).inMilliseconds >= _emitThrottleMs) {
      _lastEmitAt = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_flash?.deactivate());
    unawaited(_stopStream());
    unawaited(_gyroSub?.cancel());
    _gyroSub = null;
    _audio.dispose();
    super.dispose();
  }
}
