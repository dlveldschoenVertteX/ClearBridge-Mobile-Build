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

/// Which way `_waitForDistanceZone` waits for coverage to move --
/// `above` = closer (the old distanceStage2's exact mechanic, reused for
/// ambientClose); `below` = farther (new, for flashFar).
enum _DistanceDirection { above, below }

/// Which illumination `_captureDistanceBurst` fires for its WHOLE burst --
/// never alternates, unlike the primary burst, since decoupling illumination
/// from distance is the entire point of these two stages.
enum _DistanceIllumination { ambientOnly, flashOnly }

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
  });

  final FrontCapturePhase phase;
  final bool onTarget;
  final double holdProgress;
  final bool isCapturingBurst;
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
  // Overrides the on-screen guide shape during capturingExtra's ambientClose/
  // flashFar sub-stages (see docs/MULTI_DISTANCE_MESH_SCOPE.md) -- null means
  // "use PadSilhouetteShape.defaultShape", same as before these stages existed.
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
  const _RawShot({
    required this.jpeg,
    required this.flashOn,
    required this.laplacianScore,
    required this.timestamp,
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
  static const int _burstShotDelayMs = 50;
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
  static const Set<String> _uploadNonRetryableCodes = {
    'unauthorized', 'unauthenticated', 'no-default-bucket',
    'invalid-argument', 'invalid-url', 'object-not-found', 'quota-exceeded',
  };

  // ROI the focus/exposure meters score on — aligned to the pad silhouette
  // bounding box so framing, metering and the superprint crop all agree.
  // Kept 1:1 with PadSilhouetteShape.defaultShape.boundingRect + taper.
  // Updated 2026-07-22 for the second -15% mask shrink (real device test:
  // afisMaskCoverPx on that capture, resolution-adjusted, sits between the
  // established "good" and "too-close" reference clusters -- see
  // defaultShape's own docstring for the full derivation):
  //   cx=0.5, cy=0.37, rx=0.166175*(1+0.20)=0.19941, ry=0.137275
  //   -> [0.30059,0.232725,0.69941,0.507275]
  static const Rect _scoreRoi = Rect.fromLTRB(0.3006, 0.2327, 0.6994, 0.5073);

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
  static const double _glareEvStep = -0.7;
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
  // Endpoints are a first-cut, physically-reasoned curve, NOT fit to real
  // data (n=1 real overexposure case is not enough to calibrate a curve
  // from) — same "needs its own dedicated real-data test" caveat this
  // item carried before being built. Needs a real device round to confirm
  // before tuning further.
  static const double _flashEvMinCut = -0.3; // intensity=1.0 (pitch dark: torch is
                                              // the sole light source, minimal cut needed)
  static const double _flashEvMaxCut = -1.6; // intensity=0.3 (near the bright-mode
                                              // threshold: torch adds on top of
                                              // substantial ambient, needs the most cut)
  double _adaptiveFlashEvStep() {
    final intensity = (_flash?.intensity ?? 0.6).clamp(0.3, 1.0);
    final t = (1.0 - intensity) / 0.7; // 0 at intensity=1.0, 1 at intensity=0.3
    return _flashEvMinCut + (_flashEvMaxCut - _flashEvMinCut) * t;
  }

  static const double _coverageMin = 0.35;
  static const double _coverageMax = 0.85;

  // docs/MULTI_DISTANCE_MESH_SCOPE.md Phase 0, illumination-decoupled variant
  // (2026-07-23): the flash torch's intensity falls off with distance^2, so
  // it overpowers ridge contrast at close range regardless of EV tuning
  // (reproduced again this week: capture 913758cf's ambient frame scored
  // Laplacian 790 vs its flash frame's 81 at the SAME distance) -- while
  // native ridge wavelength (tied to closeness) is this project's own
  // strongest real NFIQ2 predictor, closer is optically richer. Decoupling
  // distance by illumination lets each half get its own best distance
  // instead of compromising on one for both: ambientClose asks the user
  // CLOSER (no torch, so no blowout risk exists regardless of distance);
  // flashFar asks them FARTHER than today's already-tuned default (on top
  // of the existing adaptive-EV step, not instead of it). Per
  // PadSilhouetteShape's own established finding, a BIGGER guide pulls the
  // user closer and a SMALLER one pushes them farther -- factors below are a
  // first cut, NOT fit to real data, same standing caveat as every prior
  // guide resize in this project. Supersedes the old single-distance
  // `distanceStage2` (which asked "get closer" then still fired flash shots
  // at that close range -- exactly the exposure risk this redesign removes).
  static const double _ambientCloseShapeScale = 1.20;
  static const double _flashFarShapeScale = 0.80;
  static final PadSilhouetteShape _ambientCloseShape =
      PadSilhouetteShape.defaultShape.scaled(_ambientCloseShapeScale);
  static final PadSilhouetteShape _flashFarShape =
      PadSilhouetteShape.defaultShape.scaled(_flashFarShapeScale);
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
  // Near-zone threshold reused verbatim from the old distanceStage2 (already
  // real-world-tested, if never yet reached: 0/12 real attempts, see
  // CLAUDE.md). Far-zone threshold is the new, symmetric ask -- below
  // _coverageMin instead of above _coverageMax -- similarly a first cut.
  static const double _ambientCloseCoverageTarget = _coverageMax + 0.05;
  static const double _flashFarCoverageTarget = _coverageMin - 0.10;

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

  double _appliedEvOffset = 0.0;
  bool _evChangeInFlight = false;
  double _lastStableBrightness = 128.0;

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
    _gyroMagnitudeDegPerSec = 0.0;
    _zoomLevel = 1.0;
    _maxZoomLevel = 1.0;
    _underfillStreak = 0;
    _zoomEverApplied = false;
    try {
      _maxZoomLevel = await camera.getMaxZoomLevel();
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

    // Focus tracking: offerFrame returns raw Laplacian variance; normalise by
    // running peak so the meter reads 0→1 relative to the sharpest frame seen.
    try {
      final rawFocus = _hybrid.offerFrame(image, thumbRoi: roi);
      if (rawFocus > _focusPeak) _focusPeak = rawFocus;
      _focusValue = HybridCaptureService.ema(
        _focusValue,
        (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0),
      );
    } catch (_) {}

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

    if (_state.phase != FrontCapturePhase.holding) return;
    if (_burstInFlight) return;

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
        unawaited(_fireBurst());
      }
    } else {
      _holdStart = null;
      _refocusedThisHold = false;
      _apply((s) => s.copyWith(onTarget: false, holdProgress: 0, isSteady: steady));
    }
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

  // Explicit per-camera-turn UI (2026-07-23) -- shared by every camera turn
  // inside capturingExtra (each secondary camera, then ambientClose, then
  // flashFar) so the whole phase reads as one consistent sequence: guide
  // shown -> countdown -> capturing -> explicit stop -> confirmation.
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

  void _maybeAdjustExposure() {
    if (_evChangeInFlight) return;
    final cam = _camera;
    if (cam == null) return;
    if (_lastStableBrightness > _glareHighLuma) {
      final target = _appliedEvOffset + _glareEvStep;
      if ((target - _appliedEvOffset).abs() < 0.05) return;
      _appliedEvOffset = target;
      _evChangeInFlight = true;
      cam.getMinExposureOffset().then((min) async {
        final max = await cam.getMaxExposureOffset();
        await cam.setExposureOffset(_appliedEvOffset.clamp(min, max));
      }).catchError((_) {}).whenComplete(() => _evChangeInFlight = false);
    }
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

  Future<void> _fireBurst() async {
    if (_burstInFlight || _disposed) return;
    _burstInFlight = true;
    // Snapshot device stillness at the moment the burst fires -- diagnostic
    // only (stored alongside laplacianScore below), for tuning
    // _maxSteadyDegPerSec against real capture outcomes.
    final gyroAtCapture = _gyroMagnitudeDegPerSec;
    _apply(
      (s) => s.copyWith(
        isCapturingBurst: true,
        burstProgress: 0.0,
        phase: FrontCapturePhase.capturing,
      ),
      force: true,
    );

    final cam = _camera;
    final torchCapable = _flash?.isNeeded ?? false;
    final flashEvStep = _adaptiveFlashEvStep();
    _flashEvDebug = {
      'evStep': double.parse(flashEvStep.toStringAsFixed(3)),
      'flashIntensity': _flash?.intensity,
      'flashMode': _flash?.modeName,
    };

    double? minEv, maxEv;
    if (torchCapable) {
      try {
        minEv = await cam?.getMinExposureOffset();
        maxEv = await cam?.getMaxExposureOffset();
      } catch (_) {}
    }

    final rawShots = <_RawShot>[];

    try {
      if (cam == null) return;
      await _stopStream();

      // Alternate: even-indexed shots are ambient (torch OFF), odd shots are
      // flash (torch ON with negative EV). At 10cm the torch at full ambient EV
      // blows out the pad centre completely (confirmed on first real capture:
      // NFIQ2=9). Alternating gives the backend both lighting conditions;
      // _download_front_only_frames already splits frames into ambient_frames
      // and flash_frames so AFIS can pick the best-exposed set.
      for (var i = 0; i < _burstFrameCount; i++) {
        final wantFlash = torchCapable && i.isOdd;
        try {
          if (wantFlash) {
            await _flash!.activate();
            if (minEv != null && maxEv != null) {
              final target = _appliedEvOffset + flashEvStep;
              await cam.setExposureOffset(target.clamp(minEv, maxEv));
            }
            await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
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
          rawShots.add(_RawShot(
            jpeg: jpeg,
            flashOn: _flash?.isFlashOn ?? false,
            laplacianScore: _focusValue > 0 ? _focusValue * (_focusPeak + 1e-6) : null,
            timestamp: DateTime.now(),
          ));
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
      final futures = <Future<({Uint8List bytes, bool flashOn, double? lap, DateTime ts})>>[];
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
          return (bytes: encoded, flashOn: raw.flashOn, lap: sharp, ts: raw.timestamp);
        }());
      }

      final results = await Future.wait(futures.map((f) => f.catchError((_) =>
          (bytes: Uint8List(0), flashOn: false, lap: null as double?, ts: DateTime.now()))));

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

      await _finishAndUpload(results, gyroAtCapture);
    } catch (e) {
      _fail('Capture failed: $e');
    } finally {
      _burstInFlight = false;
      if (!_disposed) {
        _apply((s) => s.copyWith(isCapturingBurst: false, confirmationText: null), force: true);
      }
    }
  }

  Future<void> _finishAndUpload(
    List<({Uint8List bytes, bool flashOn, double? lap, DateTime ts})> shots,
    double gyroAtCapture,
  ) async {
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
    _apply(
      (s) => s.copyWith(phase: FrontCapturePhase.capturingExtra, extraProgress: 0.0),
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

      for (final s in shots) {
        if (s.bytes.isEmpty) continue;
        final type = s.flashOn ? 'fl' : 'amb';
        final idx = s.flashOn ? flIdx++ : ambIdx++;
        final path = '$basePath/front_burst_${type}_$idx.jpg';
        uploadTasks.add((s.bytes, path));
        framesMeta.add({
          'path': path,
          'angleDeg': 0.0,
          'flashOn': s.flashOn,
          'type': 'burst',
          if (s.lap != null) 'laplacianScore': double.parse(s.lap!.toStringAsFixed(1)),
          'timestamp': s.ts.toIso8601String(),
        });
      }

      final rawSensorSupport = await _queryRawSensorSupport();
      final noiseReductionOffSupport = await _queryNoiseReductionSupport();
      final cameraLensInfo = await _queryCameraLensInfo();

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
      // Total/completed "extra capture" steps (secondary cameras + the
      // ambientClose/flashFar attempts below) -- drives extraProgress.
      // Defaults to 2 (ambientClose + flashFar only) in case
      // availableCameras() itself throws before the real count is known.
      var extraTotal = 2;
      var extraCompleted = 0;
      try {
        final allCams = await availableCameras();
        final mainName = mainCameraDescription?.name;
        secondaryDebug['allCamsCount'] = allCams.length;
        secondaryDebug['mainCamName'] = mainName;
        final others = allCams.where((c) =>
            c.lensDirection == CameraLensDirection.back && c.name != mainName);
        secondaryDebug['foundBackCams'] =
            others.map((c) => c.name).toList(growable: false);
        // Drives the guide's fill-ring during capturingExtra (see
        // extraProgress on FrontCaptureState) -- CTO real-device feedback
        // 2026-07-20/22: only the main burst had a progress cue; secondary
        // cameras (wide/IR) and the distance stages left the guide static
        // the whole time. +2 accounts for the ambientClose/flashFar attempts
        // below, which always run (best-effort) after this loop.
        extraTotal = others.length + 2;
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
              _camera = active; // resync so ambientClose/flashFar/UI see the current controller
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
            final stageDebug = <String, dynamic>{'stage': 'not_started'};
            final paths = await _captureSecondaryBurst(active, desc, basePath, stageDebug)
                .timeout(const Duration(seconds: 28), onTimeout: () {
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

      // Switch back to the main camera now that the secondary-camera loop is
      // done -- ambientClose/flashFar right below reuse `_camera` and need
      // the main sensor active again (same clean dispose-then-open handoff
      // as each secondary-camera switch above -- by this point the LAST
      // secondary camera has already been explicitly disposed in step 5
      // above, so this is always opening fresh, never racing a still-open
      // session).
      if (svc != null && mainCameraDescription != null &&
          svc.controller?.description.name != mainCameraDescription.name) {
        try {
          await svc
              .initializeCamera(
                lensDirection: CameraLensDirection.back,
                resolution: ResolutionPreset.max,
                cameraDescription: mainCameraDescription,
              )
              .timeout(const Duration(seconds: 8));
          _camera = svc.controller;
          // AdaptiveFlashController binds permanently to the CameraController
          // instance passed at construction (final field, no update method) --
          // the old `_flash` still points at the now-disposed pre-switch main
          // controller. Rebuild it against the fresh one so ambientClose/
          // flashFar's _flash!.activate()/deactivate() calls below don't
          // operate on a disposed controller.
          if (_camera != null) {
            _flash = AdaptiveFlashController(_camera!);
          }
        } catch (e) {
          debugPrint('[front] failed to switch back to main camera: $e');
          // ambientClose/flashFar below check `_camera` is non-null/
          // initialized and just skip themselves (non-fatal) if this didn't
          // work.
        }
      }

      // docs/MULTI_DISTANCE_MESH_SCOPE.md Phase 0, illumination-decoupled
      // (2026-07-23): two best-effort bonus stages, each an independent
      // single-frame candidate (no fusion math yet -- the backend scores
      // each alongside best_afis_img and keeps whichever wins). Supersedes
      // the old single "get closer" distanceStage2, whose bonus burst still
      // fired flash shots at close range -- exactly the exposure risk this
      // redesign removes. Runs AFTER secondary-camera capture, same
      // "can't regress the primary result" discipline as everything else in
      // capturingExtra: best-effort, bounded, any failure just skips silently.
      // Must land in the Firestore payload below before the
      // processEnhanceAndScore trigger so the backend's one-time doc read
      // sees it. Both stages reuse the SAME live main-camera session
      // throughout (no controller swap), so unlike the secondary-camera loop
      // there is no separate camera to dispose in step 5 -- but each still
      // gets the same visible guide/countdown/confirmation sequence for a
      // consistent mental model across the whole capturingExtra phase.
      final ambientCloseFrames = <Map<String, dynamic>>[];
      final ambientCloseDebug = <String, dynamic>{'attempted': false};
      final flashFarFrames = <Map<String, dynamic>>[];
      final flashFarDebug = <String, dynamic>{'attempted': false};
      try {
        final cam2 = _camera;
        if (cam2 != null && !_disposed) {
          // ambientClose: bigger guide pulls the user closer; torch never
          // engages this whole stage, so there is no blowout risk regardless
          // of how close the user actually gets.
          ambientCloseDebug['attempted'] = true;
          // force:true -- without it, _apply's 80ms notification throttle can
          // (and in a real device test, did) silently drop this update, since
          // nothing else touches the UI during _waitForDistanceZone's own
          // wait. Same must-not-drop treatment as the uploading transition
          // below and _fail.
          _apply((s) => s.copyWith(
                distanceHint: 'Move slightly closer for a bonus capture',
                activeGuideShape: _ambientCloseShape,
              ), force: true);
          final nearResult = await _waitForDistanceZone(
            cam2,
            target: _ambientCloseCoverageTarget,
            direction: _DistanceDirection.above,
          );
          ambientCloseDebug['reachedZone'] = nearResult.reached;
          // Diagnostic-first, same discipline the old distanceStage2 shipped
          // with (2026-07-22): real Firestore data showed THAT stage never
          // once succeeded across 12 real attempts, always landing well
          // short of its own threshold (0.444/0.684 vs 0.90) -- record the
          // same signal here so the next real round tells us directly
          // whether this stage's ask is reachable, rather than guessing.
          // direction-appropriate extreme (above wants the max reached).
          ambientCloseDebug['coverageObserved'] =
              double.parse(nearResult.coverageObserved.toStringAsFixed(3));
          if (nearResult.reached) {
            await _refocus();
            await _showCountdown();
            final frames = await _captureDistanceBurst(
              cam2,
              zone: 'ambientClose',
              basePath: basePath,
              count: 3,
              illumination: _DistanceIllumination.ambientOnly,
            );
            ambientCloseFrames.addAll(frames);
          }
        }
        await _showStopConfirmation('ambient-close capture',
            success: ambientCloseFrames.isNotEmpty);
      } catch (e) {
        debugPrint('[front] ambientClose capture skipped (non-fatal): $e');
        ambientCloseDebug['error'] = e.toString();
        await _showStopConfirmation('ambient-close capture', success: false);
      } finally {
        extraCompleted++;
        _apply((s) => s.copyWith(
              distanceHint: null,
              activeGuideShape: null,
              extraProgress: extraCompleted / extraTotal,
            ));
      }

      try {
        final cam3 = _camera;
        if (cam3 != null && !_disposed) {
          // flashFar: smaller guide pushes the user farther than today's
          // already-tuned default, on top of (not instead of) the existing
          // adaptive-EV step, to further cut flash-blowout risk.
          flashFarDebug['attempted'] = true;
          // force:true -- this call runs synchronously right after
          // ambientClose's own cleanup _apply above with no await in
          // between, so without force it always lands inside the 80ms
          // throttle window and gets silently dropped (confirmed via a real
          // device test: the CTO saw this stage's hint text but never the
          // shrunk guide).
          _apply((s) => s.copyWith(
                distanceHint: 'Move slightly back for a bonus capture',
                activeGuideShape: _flashFarShape,
              ), force: true);
          final farResult = await _waitForDistanceZone(
            cam3,
            target: _flashFarCoverageTarget,
            direction: _DistanceDirection.below,
          );
          flashFarDebug['reachedZone'] = farResult.reached;
          // direction-appropriate extreme (below wants the min reached).
          flashFarDebug['coverageObserved'] =
              double.parse(farResult.coverageObserved.toStringAsFixed(3));
          if (farResult.reached) {
            await _refocus();
            await _showCountdown();
            final frames = await _captureDistanceBurst(
              cam3,
              zone: 'flashFar',
              basePath: basePath,
              count: 3,
              illumination: _DistanceIllumination.flashOnly,
            );
            flashFarFrames.addAll(frames);
          }
        }
        await _showStopConfirmation('flash-far capture',
            success: flashFarFrames.isNotEmpty);
      } catch (e) {
        debugPrint('[front] flashFar capture skipped (non-fatal): $e');
        flashFarDebug['error'] = e.toString();
        await _showStopConfirmation('flash-far capture', success: false);
      } finally {
        extraCompleted++;
        _apply((s) => s.copyWith(
              distanceHint: null,
              activeGuideShape: null,
              extraProgress: extraCompleted / extraTotal,
            ));
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
        'zoomDebug': {
          'zoomApplied': _zoomEverApplied,
          'finalZoomLevel': double.parse(_zoomLevel.toStringAsFixed(3)),
          'maxZoomLevel': double.parse(_maxZoomLevel.toStringAsFixed(3)),
        },
        'gyroMagnitudeDegPerSec': double.parse(gyroAtCapture.toStringAsFixed(2)),
        'frames': framesMeta,
        if (rawSensorSupport != null) 'rawSensorSupport': rawSensorSupport,
        if (noiseReductionOffSupport != null)
          'noiseReductionOffSupport': noiseReductionOffSupport,
        if (cameraLensInfo != null) 'cameraLensInfo': cameraLensInfo,
        'secondaryCameraDebug': secondaryDebug,
        if (secondaryMeta.isNotEmpty) 'secondaryCameras': secondaryMeta,
        'ambientCloseDebug': ambientCloseDebug,
        if (ambientCloseFrames.isNotEmpty) 'ambientCloseFrames': ambientCloseFrames,
        'flashFarDebug': flashFarDebug,
        if (flashFarFrames.isNotEmpty) 'flashFarFrames': flashFarFrames,
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
    // Anti-blowout EV step -- the same -1.0 offset already validated for the
    // main camera's flash burst (see the alternating ambient/flash burst
    // above: an earlier all-flash burst blew out the pad centre at ~10cm).
    // setExposureOffset() does not engage the Camera2 interop that
    // setExposureMode() does, so this is safe to call without risking the
    // torch (see CameraService comments on that conflict).
    stageDebug['stage'] = 'exposure_setup';
    try {
      final minEv = await active.getMinExposureOffset();
      final maxEv = await active.getMaxExposureOffset();
      await active.setExposureOffset((-1.0).clamp(minEv, maxEv));
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
    final safeName = desc.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final paths = <String>[];
    for (var i = 0; i < _secondaryBurstCount; i++) {
      stageDebug['stage'] = 'shot_$i';
      final shotStart = DateTime.now();
      final shot = await active.takePicture();
      stageDebug['stage'] = 'shot_${i}_readBytes';
      final bytes = await shot.readAsBytes();
      stageDebug['shot_${i}_captureMs'] =
          DateTime.now().difference(shotStart).inMilliseconds;
      final path = '$basePath/secondary_${safeName}_torch_$i.jpg';
      stageDebug['stage'] = 'shot_${i}_upload';
      // Real-device finding, 2026-07-23: camera "2" times out on upload far
      // more often than "3" -- record real per-shot upload duration so the
      // next real capture's data shows whether this is a consistently slow
      // upload (this field will read high every time) vs. a genuine
      // occasional hang (the timeout fires before this ever gets recorded).
      final uploadStart = DateTime.now();
      await _uploadWithRetry(bytes, path);
      stageDebug['shot_${i}_uploadMs'] =
          DateTime.now().difference(uploadStart).inMilliseconds;
      paths.add(path);
      if (i < _secondaryBurstCount - 1) {
        await Future<void>.delayed(const Duration(milliseconds: _burstShotDelayMs));
      }
    }
    stageDebug['stage'] = 'flash_off';
    await active.setFlashMode(FlashMode.off);
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
  }) async {
    const roi = Rect.fromLTWH(0.3, 0.3, 0.4, 0.4);
    const lockThreshold = 0.45; // same relative threshold as onTarget's gate.
    var peak = 1.0;
    var focusEma = 0.0;
    var streaming = false;
    final start = DateTime.now();
    final completer = Completer<void>();
    void onFrame(CameraImage image) {
      if (completer.isCompleted) return;
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
      } catch (_) {}
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
      stageDebug['focusConvergedMs'] =
          DateTime.now().difference(start).inMilliseconds;
      stageDebug['focusScoreAtFire'] = double.parse(focusEma.toStringAsFixed(3));
    }
  }

  Future<void> _uploadWithRetry(Uint8List bytes, String path) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await FirebaseStorage.instance
            .ref()
            .child(path)
            .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        return;
      } catch (e) {
        final code = e is FirebaseException ? e.code : null;
        final retryable = code == null || !_uploadNonRetryableCodes.contains(code);
        if (!retryable || attempt >= _uploadRetryDelaysMs.length) rethrow;
        await Future.delayed(Duration(milliseconds: _uploadRetryDelaysMs[attempt]));
      }
    }
  }

  /// docs/MULTI_DISTANCE_MESH_SCOPE.md Phase 0, illumination-decoupled
  /// (2026-07-23): best-effort wait for the user to move to a meaningfully
  /// different distance zone than the main capture, using the same coverage
  /// signal _onFrame already computes (`HybridCaptureService.meanLuma` over
  /// `_scoreRoi`) -- just a fresh, short-lived stream since the main stream
  /// is already stopped by the time this runs (inside _finishAndUpload,
  /// after _fireBurst's _stopStream() call). [direction] == above waits for
  /// coverage to RISE past [target] (closer, the old distanceStage2's exact
  /// mechanic); below waits for it to DROP past [target] (farther, new).
  /// No focus/exposure control here -- that happens in _refocus() once this
  /// returns true. Never throws; a bounded timeout (or any stream error)
  /// resolves false so this stage can never hang or block the primary
  /// capture result already sitting in Firestore.
  ///
  /// Returns (reached, coverageObserved) rather than a bare bool -- real
  /// Firestore data showed the old single "closer" stage NEVER once
  /// succeeded across 12 real attempts (2026-07-22/23 analysis), always
  /// landing well short of its own threshold. `coverageObserved` is the
  /// direction-appropriate extreme actually observed during the window --
  /// the highest reached for `above` (ambientClose wants coverage to RISE),
  /// the lowest reached for `below` (flashFar wants coverage to FALL) --
  /// recorded into the caller's debug map regardless of outcome, so the NEXT
  /// real capture tells us whether users are landing well short of the
  /// target (miscalibrated threshold / unclear prompt) or right at its edge
  /// but running out of time (window too short) -- rather than continuing to
  /// guess. Fixed 2026-07-23: this used to always report the MAX regardless
  /// of direction, which for `below` reported the starting coverage, not how
  /// close the user got to the far target -- not a useful number. Diagnostic
  /// only: does not change capture behavior.
  ///
  /// Timeout widened 6s -> 9s (2026-07-23): the real first test of this
  /// stage found the guide-resize cue was silently dropped by _apply's
  /// throttle (see the `force: true` fix at both call sites), so users had
  /// effectively 0s of real visual cue to react to during that whole test --
  /// 6s was never actually exercised as reaction time. Now that the resize
  /// will really render, give real headroom on top of the existing window
  /// rather than replacing it, without touching the coverage thresholds
  /// themselves (measure those separately, one variable at a time).
  Future<({bool reached, double coverageObserved})> _waitForDistanceZone(
    CameraController cam, {
    required double target,
    required _DistanceDirection direction,
  }) async {
    const timeout = Duration(seconds: 9);
    final completer = Completer<bool>();
    var streaming = false;
    var maxCoverage = 0.0;
    var minCoverage = 1.0;
    void onFrame(CameraImage image) {
      if (completer.isCompleted) return;
      try {
        final coverage = HybridCaptureService.meanLuma(image, roi: _scoreRoi) / 255.0;
        if (coverage > maxCoverage) maxCoverage = coverage;
        if (coverage < minCoverage) minCoverage = coverage;
        final steady = _gyroMagnitudeDegPerSec < _maxSteadyDegPerSec;
        final inZone = direction == _DistanceDirection.above
            ? coverage > target
            : coverage < target;
        if (inZone && steady) completer.complete(true);
      } catch (_) {}
    }
    final coverageObserved = () =>
        direction == _DistanceDirection.above ? maxCoverage : minCoverage;
    try {
      await cam.startImageStream(onFrame);
      streaming = true;
      final reached = await completer.future.timeout(timeout, onTimeout: () => false);
      return (reached: reached, coverageObserved: coverageObserved());
    } catch (_) {
      return (reached: false, coverageObserved: coverageObserved());
    } finally {
      if (streaming) {
        try {
          await cam.stopImageStream();
        } catch (_) {}
      }
    }
  }

  /// docs/MULTI_DISTANCE_MESH_SCOPE.md Phase 0, illumination-decoupled
  /// (2026-07-23): fires a small burst at the CURRENT (already-refocused)
  /// distance, using a SINGLE illumination for the whole burst (never
  /// alternating) -- ambientOnly never engages the torch at all (removing
  /// flash-blowout risk regardless of distance); flashOnly uses it for
  /// every shot, still via the existing adaptive-EV step. Uploads each
  /// frame tagged with `distanceZone`. Deliberately NOT a full re-entry into
  /// the main hold/burst state machine (_onFrame/_fireBurst) -- this is a
  /// best-effort bonus stage scored as one more independent candidate by
  /// the backend, not part of the primary deliverable.
  Future<List<Map<String, dynamic>>> _captureDistanceBurst(
    CameraController cam, {
    required String zone,
    required String basePath,
    required int count,
    required _DistanceIllumination illumination,
  }) async {
    final out = <Map<String, dynamic>>[];
    final torchCapable =
        (_flash?.isNeeded ?? false) && illumination == _DistanceIllumination.flashOnly;
    double? minEv, maxEv;
    if (torchCapable) {
      try {
        minEv = await cam.getMinExposureOffset();
        maxEv = await cam.getMaxExposureOffset();
      } catch (_) {}
    }
    for (var i = 0; i < count; i++) {
      final wantFlash = torchCapable;
      try {
        if (wantFlash) {
          await _flash!.activate();
          if (minEv != null && maxEv != null) {
            await cam.setExposureOffset((_appliedEvOffset + _adaptiveFlashEvStep()).clamp(minEv, maxEv));
          }
          await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
        } else {
          await _flash?.deactivate();
          if (minEv != null && maxEv != null) {
            await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
          }
        }
        // Same defensive bound as the secondary-camera burst (see
        // _captureSecondaryBurst's docstring) -- takePicture() is a raw
        // platform-channel await with no bound of its own; a hang here
        // shouldn't be able to block the rest of this best-effort stage.
        final xfile = await cam.takePicture().timeout(const Duration(seconds: 6));
        final jpeg = await xfile.readAsBytes();
        final decoded = await decodeStillJpegToLuma(
          jpeg, _sensorOrientation,
          targetWidth: _stillDecodeTargetWidth,
        );
        if (decoded == null) continue;
        final encoded = await compute(
          _encodeBurstIsolate,
          _BurstEncodeArgs(decoded.luma, decoded.width, decoded.height),
        );
        final path = '$basePath/distance_${zone}_$i.jpg';
        await _uploadWithRetry(encoded, path);
        out.add({'path': path, 'distanceZone': zone, 'flashOn': wantFlash});
      } catch (e) {
        debugPrint('[front] distance burst shot $i ($zone) failed (non-fatal): $e');
      }
      if (i < count - 1) {
        await Future<void>.delayed(const Duration(milliseconds: _burstShotDelayMs));
      }
    }
    try {
      await _flash?.deactivate();
    } catch (_) {}
    return out;
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
