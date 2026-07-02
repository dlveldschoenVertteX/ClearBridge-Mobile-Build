import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';

import 'offline_capture_queue.dart';
import 'capture_audio_service.dart';
import 'capture_axis_controller.dart';
import 'capture_uploader.dart';
import 'multi_angle_capture.dart';
import 'adaptive_flash_controller.dart';
import 'device_orientation_service.dart';
import 'frame_capture_service.dart';
import 'hand_types.dart';
import 'thumb_angle_service.dart';
import 'thumb_landmarker_service.dart';
import 'thumb_orientation_classifier.dart';

const _uuid = Uuid();

/// Capture phases for the thumb-rotation capture flow.
enum CapturePhase {
  idle,
  showingAnimation, // intro animation playing — controls locked
  awaitingStart, // animation done — Start button visible
  calibrating, // ~1.5s: autofocus+lock on the thumb, learn the 0° baseline
  capturing, // live stream + thumb-angle detection active
  angleComplete, // 600ms pause after an angle locked, circle pulses
  uploading,
  complete,
  queued, // no connectivity — frames saved locally for later upload
  error,
}

/// Immutable snapshot of the capture session, rendered by the screen.
class CaptureSessionState {
  final CapturePhase phase;
  final int currentAngleIndex; // 0=front 1=left 2=top 3=right
  final double thumbAngleDegrees; // live from MediaPipe
  final double distanceToTarget; // degrees to current target angle
  final double lightingValue; // 0.0-1.0 (brightness/255), EMA smoothed
  final double focusValue; // 0.0-1.0 normalized Laplacian, EMA smoothed
  final List<bool> anglesComplete; // [front, left, top, right]
  final bool flashOn;
  final double flashIntensity; // 0.0/1.0 — mirrors AdaptiveFlashController
  final bool isNightMode;      // ambient < 80 — torch auto-fires on every burst
  final bool isMarginal;       // ambient 80–100 — manual flash toggle offered
  final bool manualFlashEnabled; // user explicitly armed flash (not auto-night)
  final double uploadProgress;
  final String? captureId;
  final String? error;
  // 0.0 = no hand / hand too small; 1.0 = hand fills frame. Proxy for
  // thumb-to-lens distance: used by DistanceGuidanceWidget.
  final double thumbCoverageRatio;
  // Latest MediaPipe hand landmarks (display/portrait-normalized 0–1), or empty
  // when no hand is in frame. Consumed by SpatialAnchorOverlay (additive layer).
  final List<Landmark> landmarks;
  // Portrait-oriented camera image dimensions the [landmarks] are normalized
  // against. Null until the first frame is processed.
  final Size? cameraImageSize;
  // Plain-text guidance from the 4-axis gate; shown in CaptureGuidanceOverlay.
  final String guidanceMessage;
  // Consecutive frames where all 4 axes are green; drives the progress arc (max 5).
  final int axisGreenFrames;
  // True for 400ms when the final angle sequence starts — all progress circles glow green.
  final bool allCirclesGlow;
  // True for 1s after a failed capture burst — haptic circle shows amber "try again" state.
  final bool isRetrying;
  // Debug-HUD fields (see MacCaptureScreen.showDebugHud) — raw values behind
  // the axis/CV gates, not otherwise surfaced in the UI. Cheap to keep
  // updated even when the HUD is off since they're plain doubles/strings.
  final double gyroMagnitude; // rad/s, smoothed — see CaptureAxisController._gyroMax
  final double? cvConfidence; // last orientation-classifier confidence, 0-1
  final String? cvPredictedAngle; // last orientation-classifier prediction

  const CaptureSessionState({
    this.phase = CapturePhase.idle,
    this.currentAngleIndex = 0,
    this.thumbAngleDegrees = 0.0,
    this.distanceToTarget = 180.0,
    this.lightingValue = 0.0,
    this.focusValue = 0.0,
    this.anglesComplete = const [false, false, false, false],
    this.flashOn = false,
    this.flashIntensity = 0.0,
    this.isNightMode = false,
    this.isMarginal = false,
    this.manualFlashEnabled = false,
    this.uploadProgress = 0.0,
    this.captureId,
    this.error,
    this.thumbCoverageRatio = 0.0,
    this.landmarks = const [],
    this.cameraImageSize,
    this.guidanceMessage = '',
    this.axisGreenFrames = 0,
    this.allCirclesGlow = false,
    this.isRetrying = false,
    this.gyroMagnitude = 0.0,
    this.cvConfidence,
    this.cvPredictedAngle,
  });

  CaptureSessionState copyWith({
    CapturePhase? phase,
    int? currentAngleIndex,
    double? thumbAngleDegrees,
    double? distanceToTarget,
    double? lightingValue,
    double? focusValue,
    List<bool>? anglesComplete,
    bool? flashOn,
    double? flashIntensity,
    bool? isNightMode,
    bool? isMarginal,
    bool? manualFlashEnabled,
    double? uploadProgress,
    String? captureId,
    String? error,
    double? thumbCoverageRatio,
    List<Landmark>? landmarks,
    Size? cameraImageSize,
    String? guidanceMessage,
    int? axisGreenFrames,
    bool? allCirclesGlow,
    bool? isRetrying,
    double? gyroMagnitude,
    double? cvConfidence,
    String? cvPredictedAngle,
  }) {
    return CaptureSessionState(
      phase: phase ?? this.phase,
      currentAngleIndex: currentAngleIndex ?? this.currentAngleIndex,
      thumbAngleDegrees: thumbAngleDegrees ?? this.thumbAngleDegrees,
      distanceToTarget: distanceToTarget ?? this.distanceToTarget,
      lightingValue: lightingValue ?? this.lightingValue,
      focusValue: focusValue ?? this.focusValue,
      anglesComplete: anglesComplete ?? this.anglesComplete,
      flashOn: flashOn ?? this.flashOn,
      flashIntensity: flashIntensity ?? this.flashIntensity,
      isNightMode: isNightMode ?? this.isNightMode,
      isMarginal: isMarginal ?? this.isMarginal,
      manualFlashEnabled: manualFlashEnabled ?? this.manualFlashEnabled,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      captureId: captureId ?? this.captureId,
      error: error ?? this.error,
      thumbCoverageRatio: thumbCoverageRatio ?? this.thumbCoverageRatio,
      landmarks: landmarks ?? this.landmarks,
      cameraImageSize: cameraImageSize ?? this.cameraImageSize,
      guidanceMessage: guidanceMessage ?? this.guidanceMessage,
      axisGreenFrames: axisGreenFrames ?? this.axisGreenFrames,
      allCirclesGlow: allCirclesGlow ?? this.allCirclesGlow,
      isRetrying: isRetrying ?? this.isRetrying,
      gyroMagnitude: gyroMagnitude ?? this.gyroMagnitude,
      cvConfidence: cvConfidence ?? this.cvConfidence,
      cvPredictedAngle: cvPredictedAngle ?? this.cvPredictedAngle,
    );
  }
}

/// Thumb-rotation multi-angle capture controller.
///
/// Replaces the old IMU device-roll engine (constraint #11). It owns the single
/// camera image stream and keeps MediaPipe hand detection running for the whole
/// session (constraint #10). On every frame it derives the thumb rotation
/// angle, drives the haptic guidance + meters, and auto-fires a burst when the
/// thumb holds within 5° of the current target for 300ms.
class MultiAngleCaptureController extends ChangeNotifier {
  MultiAngleCaptureController(this._offlineQueue);
  final OfflineCaptureQueue _offlineQueue;

  final _thumbAngle = ThumbAngleService.instance;
  final _hybrid = HybridCaptureService();
  final _axisController = CaptureAxisController();
  final _captureAudio = CaptureAudioService();
  final _orientation = DeviceOrientationService();

  /// Live device orientation relative to the front-pose reference. Step 1
  /// instrumentation: surfaced on the capture HUD to confirm which component
  /// tracks the orbit before it becomes the capture driver.
  RelativeOrientation get deviceOrientation => _orientation.relativeOrientation();

  CameraController? _camera;
  AdaptiveFlashController? _flash;
  CaptureUploader? _upload;
  ThumbLandmarkerService? _plugin;
  ThumbOrientationClassifier? _orientationClassifier;
  String? _userId;
  int _sensorOrientation = 0;

  CaptureSessionState _state = const CaptureSessionState();
  CaptureSessionState get state => _state;

  // Frame bookkeeping.
  final Map<String, List<TaggedFrame>> _angleFramesByName = {};
  final List<TaggedFrame> _allFrames = [];
  final List<int> _angleTimingsMs = [];
  final List<Map<String, dynamic>> _burstStatsList = [];
  final List<Map<String, dynamic>> _axisGateLogs = [];
  DateTime? _angleStart;

  // Live detection state.
  bool _disposed = false;
  bool _busy = false; // a burst is running
  bool _streamRunning = false;
  DateTime? _lastDetectAt;
  DateTime? _lastEmitAt;

  // Gyro (smoothed over a 10-sample rolling window).
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final List<double> _gyroHistory = [];
  double _gyroMagnitude = 0.0;

  // Latest per-frame metrics fed to the axis controller.
  double _latestBrightness = 0.0;
  double _latestFocusNorm = 0.0;

  // Flash bootstrap (brightness collected during calibration).
  double _brightnessSum = 0.0;
  int _brightnessCount = 0;
  // Set when torch is fired during calibration due to extreme darkness (<25 luma).
  bool _pitchDarkActivated = false;

  // Calibration (one-time, before the angle sequence).
  bool _calibrated = false;
  DateTime? _calibStart;
  static const _calibDurationMs = 2500; // safety-fallback; quality gate exits early

  // Focus normalization (relative peak).
  double _focusPeak = 1.0;

  // EV offset applied at calibration — included in frame metadata for backend.
  double _appliedEvOffset = 0.0;

  // Rolling raw-focus history used for quality-gated calibration exit.
  final List<double> _rawFocusHistory = [];
  static const _focusHistoryLen = 5;
  static const _focusStabilityRatio = 0.15; // max spread / max <= 15% → stable
  // Raised from 100 → 130: at close range (10–15cm) sharp skin has higher
  // Laplacian variance — tighter gate rejects frames that are soft from being
  // just outside the focus sweet spot.
  static const _focusMinAbsolute = 130.0;

  // Transition tracking.
  String? _lastCapturedName;
  double _lastCapturedAngleDeg = 0.0;
  bool _transitionCaptured = false;

  // Smooth retry: counts consecutive burst exceptions; escalates to error after 3.
  int _retryCount = 0;

  DateTime? _lastHandDetectedAt;

  // Last known thumb bounding box (normalized 0-1 Rect) for thumb-ROI focus scoring.
  Rect? _lastThumbRoi;

  // Accumulated normalized ROI widths across all detected frames — median at
  // upload time gives the backend a reliable cylinder radius estimate.
  final List<double> _thumbWidthSamples = [];

  // EMA-smoothed thumb angle — dampens per-frame MediaPipe jitter so the
  // distance gate does not reset the green streak on noise spikes.
  double _smoothedAngle = 0.0;
  bool _smoothAngleInitialized = false;

  static const _detectThrottleMs = 90;
  static const _emitThrottleMs = 80;
  static const _handLossGracePeriodMs = 200; // ignore brief hand-loss during flash

  // Quality-only capture path: mirrors CaptureAxisController thresholds.
  // Fires when MediaPipe loses the hand (thumb fills frame at close range) but
  // image quality is excellent for enough consecutive detect frames.
  // Primary-path angle gate. The old 5° fire threshold contradicted the
  // service's own acceptance window (ThumbAngleService.tolerance = 20°) and was
  // unrealistically tight for the noisier MediaPipe geometry at extreme (±90°,
  // 180°) poses. Fire within _lockFireDeg, reset only beyond _lockResetDeg,
  // preserve the green streak in the converging band between.
  static const _lockFireDeg = 12.0;
  static const _lockResetDeg = 18.0;

  // Hybrid CV+IMU gate: when the orientation classifier's top prediction
  // matches the current target angle at or above this confidence, treat the
  // orientation as confirmed regardless of the IMU distance -- CV becomes the
  // primary signal. Below this threshold (or on a different/no prediction),
  // fall back to the IMU distance check exactly as before, so a low-confidence
  // or wrong CV prediction never blocks a capture the IMU alone would allow.
  //
  // Lowered from 0.6: 'top' (roll axis) was firing inconsistently -- the roll
  // target requires an awkward phone tilt to hit on IMU alone, and users were
  // bending their thumb down to find a reachable pose instead of orbiting the
  // phone. The classifier scores confidently (very high scores in practice)
  // when it's actually looking at 'top', so trusting it at a lower bar lets
  // capture fire correctly however the user is holding the phone (up or
  // down), without needing the exact roll angle IMU alone would require.
  static const _cvConfidenceThreshold = 0.45;

  static const _qualityOnlyRequired = 5;
  static const _qualityOnlyGyroMax = 0.10;
  // Raised from 0.45 → 0.58: quality-only path fires at close range where the
  // hand fills the frame; tighter threshold ensures only sharp frames trigger.
  static const _qualityOnlyFocusMin = 0.58;
  static const _qualityOnlyBrightnessMin = 80.0;
  static const _qualityOnlyBrightnessMax = 180.0;
  int _qualityOnlyStreak = 0;

  // ── Phase transitions ──────────────────────────────────────────────────────

  /// Called once the screen is ready: plays the intro animation.
  void startIntro() {
    if (_state.phase != CapturePhase.idle) return;
    _set(_state.copyWith(phase: CapturePhase.showingAnimation));
  }

  /// Called by the intro animation when its 4s sequence finishes.
  void onAnimationComplete() {
    if (_state.phase != CapturePhase.showingAnimation) return;
    _set(_state.copyWith(phase: CapturePhase.awaitingStart));
  }

  /// User tapped Start: bring up flash + the live stream and begin detection.
  Future<void> startCaptureSequence({
    required CameraController camera,
    required CaptureUploader uploadService,
    required String userId,
    required int sensorOrientation,
  }) async {
    if (_state.phase == CapturePhase.capturing || _streamRunning) return;
    _camera = camera;
    _upload = uploadService;
    _userId = userId;
    _sensorOrientation = sensorOrientation;
    _flash = AdaptiveFlashController(camera);

    _angleFramesByName.clear();
    _allFrames.clear();
    _angleTimingsMs.clear();
    _burstStatsList.clear();
    _axisGateLogs.clear();
    _brightnessSum = 0.0;
    _brightnessCount = 0;
    _pitchDarkActivated = false;
    _lastCapturedName = null;
    _transitionCaptured = false;
    _calibrated = false;
    _calibStart = null;
    _angleStart = DateTime.now();
    _lastHandDetectedAt = null;
    _lastThumbRoi = null;
    _thumbWidthSamples.clear();
    _rawFocusHistory.clear();
    _gyroHistory.clear();
    _gyroMagnitude = 0.0;
    _latestBrightness = 0.0;
    _latestFocusNorm = 0.0;
    _axisController.reset();
    _captureAudio.silence();
    _smoothedAngle = 0.0;
    _smoothAngleInitialized = false;
    _retryCount = 0;
    _focusPeak = 1.0;

    unawaited(_captureAudio.init());

    // Begin streaming device orientation; the reference is zeroed at the front
    // pose in _finalizeCalibration.
    _orientation.start();

    _ensurePlugin();
    _gyroSub?.cancel();
    _gyroSub = gyroscopeEventStream().listen((e) {
      final raw = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      _gyroHistory.add(raw);
      if (_gyroHistory.length > 10) _gyroHistory.removeAt(0);
      _gyroMagnitude =
          _gyroHistory.reduce((a, b) => a + b) / _gyroHistory.length;
    });

    // Enter the calibration phase: autofocus on the (now present) thumb and
    // learn the 0° baseline before any angle detection runs.
    _set(_state.copyWith(
      phase: CapturePhase.calibrating,
      currentAngleIndex: 0,
      anglesComplete: const [false, false, false, false],
    ));

    try {
      // Trigger AF on the thumb before opening the analysis stream. A short
      // fixed wait covers initial lens movement; the quality gate in
      // _runCalibration handles the rest of convergence detection.
      await _beginAutofocus();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await camera.startImageStream(_onFrame);
      _streamRunning = true;
    } catch (e) {
      _fail('Could not start camera stream: $e');
    }
  }

  void _ensurePlugin() {
    if (_plugin != null) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    // ThumbLandmarkerService tries its own GPU delegate first, falling back
    // to CPU internally (see thumb_landmarker_service.dart _initAsync). It
    // stays not-ready (detect() returns []) until initialization completes,
    // which _detectAndDrive/_runCalibration already handle as "no hand yet".
    _plugin = ThumbLandmarkerService()..initialize();
    // Same fire-and-forget init pattern; classify() returns null until ready,
    // which cvConfirms already treats as "no CV signal, IMU decides alone".
    _orientationClassifier = ThumbOrientationClassifier()..initialize();
  }

  // ── Stream processing ──────────────────────────────────────────────────────

  void _onFrame(CameraImage image) {
    if (_disposed) return;
    final phase = _state.phase;
    if (phase != CapturePhase.calibrating &&
        phase != CapturePhase.capturing &&
        phase != CapturePhase.angleComplete) {
      return;
    }

    // Record the portrait-oriented image size once. The hand_landmarker plugin
    // rotates the frame by sensorOrientation before detection, so for a 90/270°
    // sensor the upright (display) frame has width/height swapped relative to
    // the raw CameraImage. The spatial-anchor projection needs this orientation
    // to match the landmark normalization. (Exact mapping may need an on-device
    // trim on the A16 — same caveat as the thumb-angle geometry.)
    if (_state.cameraImageSize == null) {
      final swap = _sensorOrientation == 90 || _sensorOrientation == 270;
      final imgSize = swap
          ? Size(image.height.toDouble(), image.width.toDouble())
          : Size(image.width.toDouble(), image.height.toDouble());
      _state = _state.copyWith(cameraImageSize: imgSize);
    }

    // Brightness (lighting meter + flash calibration) and focus (meter + burst).
    final brightness = _meanLuma(image, roi: _lastThumbRoi);
    final lightingNorm = (brightness / 255.0).clamp(0.0, 1.0);
    double rawFocus;
    try {
      rawFocus = _hybrid.offerFrame(image, thumbRoi: _lastThumbRoi);
    } catch (e) {
      debugPrint('BURST_ERR: offerFrame threw $e');
      rawFocus = 0.0;
    }
    if (rawFocus > _focusPeak) _focusPeak = rawFocus;
    _focusPeak *= 0.97; // halves in ~4s so normalizer tracks per-angle quality, not session best
    final focusNorm = (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0);
    final lighting = HybridCaptureService.ema(_state.lightingValue, lightingNorm);
    final focus = HybridCaptureService.ema(_state.focusValue, focusNorm);
    _hybrid.updateFlashState(
      flashOn: _flash?.isFlashOn ?? false,
      intensity: _flash?.intensity ?? 0.0,
    );

    // Rolling raw-focus history (shared by calibration quality gate + axis trend).
    _rawFocusHistory.add(rawFocus);
    if (_rawFocusHistory.length > _focusHistoryLen) _rawFocusHistory.removeAt(0);

    // Cache per-frame metrics for the axis controller (read in _detectAndDrive).
    _latestBrightness = brightness;
    _latestFocusNorm = focusNorm;

    if (phase == CapturePhase.calibrating) {
      _brightnessSum += brightness;
      _brightnessCount++;
      _runCalibration(image, rawFocus);
      _emitMeters(lighting, focus);
      return;
    }

    // capturing / angleComplete: detect (throttled, skipped during a burst).
    final now = DateTime.now();
    if (!_busy &&
        (_lastDetectAt == null ||
            now.difference(_lastDetectAt!).inMilliseconds >= _detectThrottleMs)) {
      _lastDetectAt = now;
      _detectAndDrive(image);
    }
    _emitMeters(lighting, focus);
  }

  void _emitMeters(double lighting, double focus) {
    final now = DateTime.now();
    final f = _flash;
    final next = _state.copyWith(
      lightingValue: lighting,
      focusValue: focus,
      flashOn: f?.isFlashOn ?? false,
      flashIntensity: f?.intensity ?? 0.0,
      isNightMode: f?.isNightMode ?? false,
      isMarginal: f?.isMarginal ?? false,
      manualFlashEnabled: false, // flash gating is fully automatic
    );
    // Throttle notifies to avoid excessive rebuilds; keep the latest values.
    if (_lastEmitAt == null ||
        now.difference(_lastEmitAt!).inMilliseconds >= _emitThrottleMs) {
      _lastEmitAt = now;
      _set(next, notify: true);
    } else {
      _state = next;
    }
  }

  // ── Calibration (one-time, before the angle sequence) ────────────────────────

  void _runCalibration(CameraImage image, double rawFocus) {
    _calibStart ??= DateTime.now();
    final plugin = _plugin;
    final now = DateTime.now();
    if (plugin != null &&
        (_lastDetectAt == null ||
            now.difference(_lastDetectAt!).inMilliseconds >= _detectThrottleMs)) {
      _lastDetectAt = now;
      try {
        final hands = plugin.detect(image, _sensorOrientation);
        if (hands.isNotEmpty && hands.first.landmarks.length >= 18) {
          _lastThumbRoi = _computeThumbRoi(
            hands.first.landmarks,
            image.width.toDouble(),
            image.height.toDouble(),
          );
        }
      } catch (_) {}
    }

    // Pitch-dark detection: if the scene is completely dark after 400ms and
    // MediaPipe still hasn't found the thumb, fire the torch immediately so
    // detection can converge. The calibration brightness samples collected so
    // far are discarded — _finalizeCalibration overrides avgBrightness with 5.0
    // (signalling torch-only illumination to the flash controller).
    if (!_pitchDarkActivated &&
        _calibStart != null &&
        now.difference(_calibStart!).inMilliseconds >= 400 &&
        _brightnessCount > 0 &&
        (_brightnessSum / _brightnessCount) < 25.0 &&
        _lastThumbRoi == null) {
      _pitchDarkActivated = true;
      unawaited(_flash?.activate());
    }

    // Quality gate: exit calibration early once focus has converged.
    // History is maintained by _onFrame; just read the latest window here.
    if (_rawFocusHistory.length == _focusHistoryLen &&
        rawFocus >= _focusMinAbsolute &&
        _isFocusStable()) {
      unawaited(_finalizeCalibration());
      return;
    }

    // Safety fallback: always exit after the hard timeout.
    if (now.difference(_calibStart!).inMilliseconds >= _calibDurationMs) {
      unawaited(_finalizeCalibration());
    }
  }

  bool _isFocusStable() {
    if (_rawFocusHistory.length < _focusHistoryLen) return false;
    var min = _rawFocusHistory[0];
    var max = _rawFocusHistory[0];
    for (final v in _rawFocusHistory) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    if (max == 0) return false;
    return (max - min) / max <= _focusStabilityRatio;
  }

  Future<void> _finalizeCalibration() async {
    if (_calibrated) return;
    _calibrated = true;

    // Calibrate flash from measured ambient. Torch stays off after calibration;
    // it activates only around each burst window in _fireAngleCapture.
    double? avgBrightness;
    if (_pitchDarkActivated) {
      // Torch was fired during calibration; brightness samples are a mix of
      // dark + torch-lit frames. Report 5.0 (true pre-torch ambient) so the
      // flash controller enters pitch-dark mode (torch stays on) and EV is
      // set to −0.3 (correct for torch-only close-range illumination).
      avgBrightness = 5.0;
    } else if (_brightnessCount > 0) {
      avgBrightness = _brightnessSum / _brightnessCount;
    }
    if (avgBrightness != null) {
      await _flash?.calibrate(avgBrightness);
      debugPrint('FLASH_MODE: ${_flash?.modeName} ambient=${avgBrightness.toStringAsFixed(1)}');
      // Set EV offset before locking AE so the offset is baked into all four
      // angle bursts at the same exposure level.
      await _setAdaptiveExposureOffset(avgBrightness);
    }

    // Zero the device-orientation reference to the user's natural front pose so
    // every subsequent orbit angle is measured relative to it (no flat-start).
    _orientation.captureReference();

    if (_disposed) return;

    // Steer the AF metering point to the thumb centre but leave AF in
    // continuous-auto mode. The lock is deferred to just before each angle
    // burst so the lens re-converges at whatever distance the user has moved
    // to — critical for close-range (10–15cm) sharpness.
    unawaited(_steerFocusToThumb());
    _angleStart = DateTime.now();
    _lastDetectAt = null;
    _set(_state.copyWith(
      phase: CapturePhase.capturing,
      isNightMode: _flash?.isNightMode ?? false,
      isMarginal: _flash?.isMarginal ?? false,
    ));
  }

  /// Adjusts EV offset based on measured ambient brightness so capture bursts
  /// are well-exposed. The offset accounts for whether the torch will fire:
  ///   ambient <30:    −0.3  (pitch dark + torch: prevent overexposure)
  ///   ambient 30–80:   0.0  (dim + torch: neutral, torch is primary source)
  ///   ambient 80–150: −0.3  (normal indoor + torch: compensate for fill light)
  ///   ambient 150–184:−0.5  (bright indoor + torch: strong compensation)
  ///   ambient ≥185:    0.0  (very bright, torch skipped: let camera expose normally)
  Future<void> _setAdaptiveExposureOffset(double brightness) async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    final target = brightness < 30  ? -0.3
                 : brightness < 80  ?  0.0
                 : brightness < 150 ? -0.3
                 : brightness < 185 ? -0.5
                 :                    0.0; // torch skipped — neutral EV
    _appliedEvOffset = target;
    try {
      final minEv = await c.getMinExposureOffset();
      final maxEv = await c.getMaxExposureOffset();
      await c.setExposureOffset(target.clamp(minEv, maxEv));
    } catch (_) {}
  }

  // Flash is fully automatic — no manual toggle.

  Future<void> _beginAutofocus() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFocusMode(FocusMode.auto);
    } catch (_) {}
    // Focus point is steered to the thumb in _steerFocusToThumb at calibration
    // end, then re-locked per burst in _refocusForBurst.
  }

  /// Steers the AF metering point to the thumb and locks focus.
  /// Called at calibration end. Continuous-auto is intentionally NOT left open:
  /// at 10–14cm the thumb's matte skin loses the contrast fight against the
  /// background and AF hunts away between bursts. Locking here eliminates that.
  /// Each burst re-locks via _refocusForBurst().
  Future<void> _steerFocusToThumb() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    final roi = _lastThumbRoi;
    final point = roi != null
        ? Offset((roi.left + roi.right) / 2.0, (roi.top + roi.bottom) / 2.0)
        : const Offset(0.5, 0.5);
    try {
      await c.setFocusMode(FocusMode.auto);
      await c.setFocusPoint(point);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_disposed) return;
      await c.setFocusMode(FocusMode.locked);
    } catch (_) {}
  }

  /// Per-burst refocus: re-aims AF at the current thumb position, waits for
  /// convergence, then locks focus for the burst window.
  ///
  /// This is the close-range sharpness fix: the thumb may be at a different
  /// distance from the lens than it was at calibration. Re-locking per burst
  /// ensures the lens is focused at the actual capture distance each time.
  /// Focus lock does not conflict with torch (only AE lock does — see
  /// _lockFocus comment below).
  Future<void> _refocusForBurst() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    final roi = _lastThumbRoi;
    final point = roi != null
        ? Offset((roi.left + roi.right) / 2.0, (roi.top + roi.bottom) / 2.0)
        : const Offset(0.5, 0.5);
    try {
      await c.setFocusMode(FocusMode.auto);
      await c.setFocusPoint(point);
      // 500ms: at 10–14cm the lens travels further in diopters than at portrait
      // distance — 250ms wasn't enough to fully converge before locking.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_disposed) return;
      // Focus lock only — AE is deliberately NOT locked. On the CameraX backend
      // setExposureMode() routes through Camera2 interop (CONTROL_AE_LOCK) which
      // conflicts with enableTorch() and prevents the LED from firing. Focus lock
      // (a native CameraControl op) is safe; exposure is held via the EV offset
      // set at calibration (_setAdaptiveExposureOffset → setExposureCompensationIndex).
      await c.setFocusMode(FocusMode.locked);
    } catch (_) {}
  }

  double _wrap180(double d) {
    var x = d % 360.0;
    if (x > 180.0) x -= 360.0;
    if (x < -180.0) x += 360.0;
    return x;
  }

  // Angle-aware EMA: interpolates along the shortest arc so the ±180 wrap
  // boundary never causes the smoothed value to spin the long way around.
  // Compares the first-half mean vs second-half mean of the raw Laplacian
  // history to decide whether focus is improving, degrading, or stable.
  static LaplacianTrend _focusTrend(List<double> history) {
    if (history.length < 2) return LaplacianTrend.stable;
    final mid = history.length ~/ 2;
    final early = history.sublist(0, mid).reduce((a, b) => a + b) / mid;
    final late = history.sublist(mid).reduce((a, b) => a + b) / (history.length - mid);
    const threshold = 0.03;
    if (late - early > threshold) return LaplacianTrend.sharpening;
    if (early - late > threshold) return LaplacianTrend.blurring;
    return LaplacianTrend.stable;
  }

  double _angleEma(double smoothed, double raw, {double alpha = 0.4}) {
    var diff = raw - smoothed;
    while (diff > 180) { diff -= 360; }
    while (diff < -180) { diff += 360; }
    return _wrap180(smoothed + alpha * diff);
  }

  double _orbitAngle(RelativeOrientation o, String axis) {
    switch (axis) {
      case 'pitch': return o.pitch;
      case 'roll': return o.roll;
      default: return o.magnitude;
    }
  }

  void _detectAndDrive(CameraImage image) {
    final plugin = _plugin;
    if (plugin == null) return;

    List<Hand> hands;
    try {
      hands = plugin.detect(image, _sensorOrientation);
    } catch (_) {
      return;
    }
    if (hands.isEmpty || hands.first.landmarks.length < 18) {
      // Flash pulses can cause MediaPipe to briefly drop the hand. Only act
      // when the hand has been absent longer than the grace period.
      final withinGrace = _lastHandDetectedAt != null &&
          DateTime.now().difference(_lastHandDetectedAt!).inMilliseconds <
              _handLossGracePeriodMs;
      if (!withinGrace) {
        // Clear landmarks so the spatial-anchor overlay hides when the hand
        // is truly gone (empty list is a real value, unlike the copyWith null).
        _state = _state.copyWith(
          distanceToTarget: 180.0,
          landmarks: const <Landmark>[],
        );
        _captureAudio.updateGuidanceTone(null);
        // Quality-only fallback: thumb may be too close for MediaPipe to see
        // the full hand. Fire on image quality alone when thumb fills the frame.
        _checkQualityOnlyCapture(image);
      }
      return;
    }

    // Hand confirmed — reset quality-only streak and update detection state.
    _qualityOnlyStreak = 0;
    _lastHandDetectedAt = DateTime.now();
    _lastThumbRoi = _computeThumbRoi(
      hands.first.landmarks,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    // Only sample during active capture — transitions show oblique thumb poses
    // that make the ROI appear narrower, biasing the SfM radius estimate.
    if (_lastThumbRoi != null && _state.phase == CapturePhase.capturing) {
      _thumbWidthSamples.add(_lastThumbRoi!.width);
    }

    final name = ThumbAngleService.order[_state.currentAngleIndex];
    final target = ThumbAngleService.targets[name]!;

    // Orbit angle: device orientation relative to the zeroed front pose.
    // Axis chosen per capture position (pitch for left/right, roll for top,
    // magnitude for front). MediaPipe stays for quality/coverage/framing only.
    final orient = _orientation.relativeOrientation();
    final orbitRaw = _orbitAngle(orient, ThumbAngleService.axis[name]!);
    if (!_smoothAngleInitialized) {
      _smoothedAngle = orbitRaw;
      _smoothAngleInitialized = true;
    } else {
      _smoothedAngle = _angleEma(_smoothedAngle, orbitRaw);
    }
    final distance = _thumbAngle.distanceToTarget(_smoothedAngle, target);

    // Hybrid CV+IMU gate: a confident, correct CV prediction overrides the
    // IMU distance to "locked" (0°) so orientation lock is CV-primary when
    // the model is sure, and IMU-only (unchanged) otherwise. cvConfirms can
    // only ever bring the thumb closer to firing, never block a capture the
    // IMU alone would already have allowed -- see _cvConfidenceThreshold.
    final cvPrediction = _orientationClassifier?.classify(image, _sensorOrientation);
    final cvConfirms = cvPrediction != null &&
        cvPrediction.angleName == name &&
        cvPrediction.confidence >= _cvConfidenceThreshold;
    final effectiveDistance = cvConfirms ? 0.0 : distance;

    // Hand height in frame (wrist→middle fingertip) as a distance proxy:
    // smaller value = farther away, larger value = too close.
    final wrist    = hands.first.landmarks[0];
    final thumbTip = hands.first.landmarks[4]; // thumb tip — guard requires ≥18
    final coverage = (thumbTip.y - wrist.y).abs().clamp(0.0, 1.0);

    // Evaluate 4-axis quality gate and propagate guidance to UI.
    // Use _flash?.isFlashOn directly — _state.flashOn lags by up to
    // _emitThrottleMs (80ms), causing the brightness gate to see a flash-bright
    // frame while flashOn is still false and incorrectly reset the streak.
    final axisResult = _axisController.evaluate(
      normalisedFocus: _latestFocusNorm,
      trend: _focusTrend(_rawFocusHistory),
      brightness: _latestBrightness,
      thumbCoverageRatio: coverage,
      gyroMagnitude: _gyroMagnitude,
      flashOn: _flash?.isFlashOn ?? false,
    );

    // Show rotation direction+magnitude while the thumb hasn't reached the fire
    // threshold. Quality-gate messages only matter once the angle is close enough
    // to capture — showing them while far just confuses the user about why nothing fires.
    final guidanceMsg = effectiveDistance > _lockFireDeg
        ? _rotationMessage(name, effectiveDistance)
        : axisResult.message;

    _state = _state.copyWith(
      thumbAngleDegrees: _smoothedAngle,
      distanceToTarget: effectiveDistance,
      thumbCoverageRatio: coverage,
      landmarks: hands.first.landmarks,
      guidanceMessage: guidanceMsg,
      axisGreenFrames: axisResult.consecutiveGreenFrames,
      gyroMagnitude: _gyroMagnitude,
      cvConfidence: cvPrediction?.confidence,
      cvPredictedAngle: cvPrediction?.angleName,
    );
    _captureAudio.updateGuidanceTone(effectiveDistance);

    // Transition detection is about genuine physical movement away from the
    // last captured angle -- always IMU-driven (raw distance), independent
    // of whether CV currently confirms the *new* target.
    _checkTransition(_smoothedAngle, distance);
    _checkLock(effectiveDistance, axisResult);
  }

  // ── Lock + transition logic ─────────────────────────────────────────────────

  void _checkLock(double distance, AxisEvaluationResult axisResult) {
    if (_busy) return;
    // Only wipe the streak when the thumb is clearly away from the target.
    // A hard reset right at the fire threshold means any jitter spike zeroes
    // the counter, making 5 consecutive green frames impossible. Reset only
    // beyond _lockResetDeg, preserve the streak in the converging band, and
    // fire within _lockFireDeg.
    if (distance > _lockResetDeg) {
      _axisController.reset();
      return;
    }
    if (distance > _lockFireDeg) return; // converging — streak preserved
    if (axisResult.readyToCapture) {
      unawaited(_fireAngleCapture());
    }
  }

  // Fires capture when MediaPipe cannot see the full hand (thumb fills the
  // frame at close range). Orbit angle is gated via a live IMU reading so the
  // user must physically orbit to each position — using _smoothedAngle here
  // caused all 4 angles to fire without rotation because:
  //   (a) _smoothedAngle retains the OLD axis value after an index advance
  //       (left=pitch−20° → top=roll−20°: stale pitch matches roll target → 0°)
  //   (b) the 30° window was wide enough to fire on natural device tilt alone.
  void _checkQualityOnlyCapture(CameraImage image) {
    if (_busy) return;

    // Gate on the live orbit reading for the current angle's axis. This is the
    // same IMU source _detectAndDrive uses, so thresholds match exactly.
    final name   = ThumbAngleService.order[_state.currentAngleIndex];
    final target = ThumbAngleService.targets[name]!;
    final orient = _orientation.relativeOrientation();
    final orbitLive     = _orbitAngle(orient, ThumbAngleService.axis[name]!);
    final orbitDistance = _thumbAngle.distanceToTarget(orbitLive, target);

    // Hybrid CV+IMU gate, same rationale as _detectAndDrive: this path only
    // runs when MediaPipe can't see a full hand (thumb too close), which is
    // exactly the range the orientation classifier was trained for and the
    // hand-landmark angle extraction can't handle. Without this, quality-only
    // captures were purely IMU-driven with zero visual orientation check.
    final cvPrediction = _orientationClassifier?.classify(image, _sensorOrientation);
    final cvConfirms = cvPrediction != null &&
        cvPrediction.angleName == name &&
        cvPrediction.confidence >= _cvConfidenceThreshold;
    final effectiveOrbitDistance = cvConfirms ? 0.0 : orbitDistance;

    if (effectiveOrbitDistance > _lockFireDeg) {
      _state = _state.copyWith(
        guidanceMessage: _rotationMessage(name, effectiveOrbitDistance),
        gyroMagnitude: _gyroMagnitude,
        cvConfidence: cvPrediction?.confidence,
        cvPredictedAngle: cvPrediction?.angleName,
      );
      _captureAudio.updateGuidanceTone(effectiveOrbitDistance);
      _qualityOnlyStreak = 0;
      return;
    }
    _captureAudio.updateGuidanceTone(effectiveOrbitDistance);

    final flashOn = _state.flashOn;
    final qualityOk = _gyroMagnitude <= _qualityOnlyGyroMax &&
        _latestFocusNorm >= _qualityOnlyFocusMin &&
        _latestBrightness >= _qualityOnlyBrightnessMin &&
        (flashOn || _latestBrightness <= _qualityOnlyBrightnessMax);

    if (!qualityOk) {
      _qualityOnlyStreak = 0;
      return;
    }

    _qualityOnlyStreak++;
    // Mirror the axis green-frame UI so the haptic circle and progress arc
    // give the user real-time feedback during quality-only accumulation.
    _state = _state.copyWith(
      guidanceMessage: _qualityOnlyStreak >= _qualityOnlyRequired
          ? 'Capturing...'
          : 'Perfect — hold still',
      axisGreenFrames: _qualityOnlyStreak,
    );

    if (_qualityOnlyStreak >= _qualityOnlyRequired) {
      _qualityOnlyStreak = 0;
      unawaited(_fireAngleCapture());
    }
  }

  /// Returns a live rotation direction+magnitude hint for the given angle name.
  /// Shows while the thumb is still outside the fire threshold so the user
  /// knows which way to rotate and how many degrees remain.
  String _rotationMessage(String angleName, double distance) {
    final deg = distance.round();
    switch (ThumbAngleService.axis[angleName]) {
      case 'pitch':
        final target = ThumbAngleService.targets[angleName]!;
        return target < 0 ? 'Orbit phone left  ~$deg°' : 'Orbit phone right  ~$deg°';
      case 'roll':
        return 'Tilt phone forward  ~$deg°';
      default:
        return ''; // 'magnitude' — front angle, user is already here
    }
  }

  void _checkTransition(double angle, double distance) {
    if (_busy || _transitionCaptured || _lastCapturedName == null) return;
    final movedFromLast =
        _thumbAngle.distanceToTarget(angle, _lastCapturedAngleDeg);
    if (movedFromLast > 15.0 && distance > 20.0) {
      _transitionCaptured = true;
      final nextName = ThumbAngleService.order[_state.currentAngleIndex];
      unawaited(_fireTransitionCapture(_lastCapturedName!, nextName));
    }
  }

  Future<void> _fireTransitionCapture(String prev, String next) async {
    if (_busy) return;
    _busy = true;
    try {
      final frames = await _hybrid.captureTransitionBurst(
        zoneId: 'transition_${prev}_$next',
        thumbAngleDegrees: _state.thumbAngleDegrees,
        thumbCoverageRatio: _state.thumbCoverageRatio,
      );
      _allFrames.addAll(frames);
    } catch (_) {
      // Transition frames are supplementary; never fail the session on them.
    } finally {
      _busy = false;
    }
  }

  Future<void> _fireAngleCapture() async {
    if (_busy) return;
    _busy = true;
    _captureAudio.silence();
    final index = _state.currentAngleIndex;
    final name = ThumbAngleService.order[index];
    debugPrint('AXIS_GATE[$name]: focus=${_latestFocusNorm.toStringAsFixed(2)} '
        'brightness=${_latestBrightness.toStringAsFixed(1)} '
        'gyro=${_gyroMagnitude.toStringAsFixed(3)} '
        'greenFrames=${_state.axisGreenFrames}');
    _axisGateLogs.add({
      'angle':            name,
      'focusNorm':        double.parse(_latestFocusNorm.toStringAsFixed(3)),
      'brightness':       double.parse(_latestBrightness.toStringAsFixed(1)),
      'gyroMagnitude':    double.parse(_gyroMagnitude.toStringAsFixed(4)),
      'greenFrames':      _state.axisGreenFrames,
      // CV confirmation snapshot at the fire moment — data for retuning
      // _cvConfidenceThreshold / ThumbAngleService's per-angle targets once
      // enough beta sessions have logged real confidence distributions.
      'cvConfidence':     _state.cvConfidence == null
          ? null
          : double.parse(_state.cvConfidence!.toStringAsFixed(3)),
      'cvPredictedAngle': _state.cvPredictedAngle,
    });
    try {
      // 0. Refocus at current thumb distance before the burst window.
      //    Torch is off here — re-locking focus after torch activation would
      //    conflict with enableTorch() on the CameraX backend.
      await _refocusForBurst();
      if (_disposed) { _busy = false; return; }

      // 1. Ambient burst — deactivate torch first (no-op in pitch dark mode
      //    where it stays on). Tag frames with the actual torch state so the
      //    upload service names them correctly (amb vs fl) and the backend's
      //    Mertens fusion path receives correctly labelled inputs.
      await _flash?.deactivate();
      final ambFlashOn = _flash?.isFlashOn ?? false;
      _hybrid.updateFlashState(
        flashOn: ambFlashOn,
        intensity: ambFlashOn ? (_flash?.intensity ?? 0.0) : 0.0,
      );
      final ambientFrames = await _hybrid.captureAngleBurst(
        zoneId: 'angle_$name',
        thumbAngleDegrees: _state.thumbAngleDegrees,
        targetAngleDegrees: ThumbAngleService.targets[name]!,
        thumbCoverageRatio: _state.thumbCoverageRatio,
      );
      final ambStats = Map<String, dynamic>.from(_hybrid.lastBurstStats ?? {});

      // 2. Flash burst — fires when isNeeded (skipped in bright mode ≥185 luma).
      //    Server-side Mertens fusion combines ambient + flash frames for shadow
      //    fill. The torch is driven via setFlashMode(FlashMode.torch) →
      //    CameraControl.enableTorch(). We do NOT touch setExposureMode here:
      //    on the CameraX backend it routes through Camera2 interop
      //    (Camera2CameraControl), and once engaged it conflicts with
      //    enableTorch(), preventing the LED from firing. Exposure is held by
      //    the EV offset set at calibration.
      List<TaggedFrame> flashFrames = const [];
      Map<String, dynamic> flStats = {};
      if (_flash?.isNeeded ?? false) {
        await _flash!.activate();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        _hybrid.updateFlashState(flashOn: true, intensity: _flash!.intensity);
        flashFrames = await _hybrid.captureAngleBurst(
          zoneId: 'angle_${name}_fl',
          thumbAngleDegrees: _state.thumbAngleDegrees,
          targetAngleDegrees: ThumbAngleService.targets[name]!,
          thumbCoverageRatio: _state.thumbCoverageRatio,
        );
        flStats = Map<String, dynamic>.from(_hybrid.lastBurstStats ?? {});
        await _flash!.deactivate();
        final postFlashOn = _flash!.isFlashOn;
        _hybrid.updateFlashState(
          flashOn: postFlashOn,
          intensity: postFlashOn ? _flash!.intensity : 0.0,
        );
      }

      final frames = [...ambientFrames, ...flashFrames];
      debugPrint('BURST[$name]: ${ambientFrames.length} amb + ${flashFrames.length} fl frames');
      final angleStats = <String, dynamic>{
        'angle':              name,
        'ambientCandidates':  ambStats['candidateCount'] ?? 0,
        'ambientMinScore':    ambStats['minScore'] ?? 0.0,
        'ambientMaxScore':    ambStats['maxScore'] ?? 0.0,
        'ambientEarlyExit':   ambStats['earlyExit'] ?? false,
        if (flStats.isNotEmpty) 'flashCandidates': flStats['candidateCount'] ?? 0,
        if (flStats.isNotEmpty) 'flashMaxScore':   flStats['maxScore'] ?? 0.0,
      };
      _burstStatsList.add(angleStats);
      debugPrint('BURST_STATS[$name]: candidates=${angleStats['ambientCandidates']} '
          'min=${angleStats['ambientMinScore']} max=${angleStats['ambientMaxScore']} '
          'earlyExit=${angleStats['ambientEarlyExit']}');
      if (frames.isEmpty) {
        _axisController.reset();
        _busy = false;
        return; // nothing usable — let the user re-hold
      }

      _angleFramesByName[name] = frames;
      _allFrames.addAll(frames);
      _angleTimingsMs.add(
        DateTime.now().difference(_angleStart ?? DateTime.now()).inMilliseconds,
      );

      final completed = List<bool>.from(_state.anglesComplete)..[index] = true;
      _lastCapturedName = name;
      _lastCapturedAngleDeg = ThumbAngleService.targets[name]!;
      _transitionCaptured = false;

      HapticFeedback.heavyImpact();
      // Double pulse for the intermediate angle that precedes the final angle,
      // signalling the approaching finish without over-celebrating mid-sequence.
      if (index == 2) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        HapticFeedback.heavyImpact();
      }
      unawaited(_captureAudio.playAngleSuccess(
        isFinal: index == ThumbAngleService.order.length - 1,
      ));
      _retryCount = 0;

      _set(_state.copyWith(
        phase: CapturePhase.angleComplete,
        anglesComplete: completed,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_disposed) {
        _busy = false;
        return;
      }

      if (index < ThumbAngleService.order.length - 1) {
        _angleStart = DateTime.now();
        _axisController.reset();
        _smoothAngleInitialized = false; // re-seed EMA on the new axis
        // A stale peak from the just-completed angle (different distance/
        // lighting) otherwise carries into the next angle's focus scoring
        // until it decays, making early frames of the new angle read as
        // falsely soft. See startCaptureSequence for the matching reset.
        _focusPeak = 1.0;
        final advancingToFinal = index == 2;
        _set(_state.copyWith(
          phase: CapturePhase.capturing,
          currentAngleIndex: index + 1,
          guidanceMessage: '',
          axisGreenFrames: 0,
          allCirclesGlow: advancingToFinal,
        ));
        if (advancingToFinal) {
          Future<void>.delayed(const Duration(milliseconds: 400)).then((_) {
            if (!_disposed && _state.allCirclesGlow) {
              _state = _state.copyWith(allCirclesGlow: false);
              notifyListeners();
            }
          });
        }
        _busy = false;
      } else {
        _busy = false;
        await _finishAndUpload();
      }
    } catch (e) {
      _busy = false;
      if (_retryCount < 3) {
        _retryCount++;
        _set(_state.copyWith(
          phase: CapturePhase.capturing,
          guidanceMessage: 'Quality low — try again',
          isRetrying: true,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        if (!_disposed) {
          _set(_state.copyWith(guidanceMessage: '', isRetrying: false));
        }
      } else {
        _retryCount = 0;
        _fail('Capture failed at $name: $e');
      }
    }
  }

  // ── Upload ───────────────────────────────────────────────────────────────────

  Future<void> _finishAndUpload() async {
    final upload = _upload;
    final userId = _userId;
    if (upload == null || userId == null) return;

    _set(_state.copyWith(phase: CapturePhase.uploading, uploadProgress: 0.0));
    await _flash?.deactivate();
    await _stopStream();

    // Re-pack into the existing 4-angle storage order (front, right, top, left).
    // Flash flags are tracked per-frame so the upload service names ambient and
    // torch-lit files differently, enabling server-side Mertens fusion.
    final orderedFrames = <List<Uint8List>>[];
    final orderedFlashFlags = <List<bool>>[];
    for (final key in CaptureAngles.keyList) {
      final List<TaggedFrame> keyFrames = _angleFramesByName[key] ?? const [];
      orderedFrames.add([for (final f in keyFrames) f.bytes]);
      orderedFlashFlags.add([for (final f in keyFrames) f.flashOn]);
    }

    // Median normalized ROI width across all detected frames.
    // Sent to the backend so SfM can use a reliable cylinder radius without
    // depending on its own Otsu-threshold silhouette detection on compressed frames.
    double? thumbWidthFraction;
    if (_thumbWidthSamples.isNotEmpty) {
      final sorted = List<double>.from(_thumbWidthSamples)..sort();
      thumbWidthFraction = sorted[sorted.length ~/ 2];
    }

    final capture = MultiAngleCapture(
      capturedFrames: orderedFrames,
      isFlashFrame: orderedFlashFlags,
      metadata: {
        'source': 'flutter_thumb_rotation',
        'captureMethod': 'thumb_rotation_mediapipe',
        'timestamp': DateTime.now().toIso8601String(),
        'angleOrder': ThumbAngleService.order,
        'transitionFrames':
            _allFrames.where((f) => f.zoneId.startsWith('transition')).length,
      },
      angleTimingsMs: _angleTimingsMs,
    );

    final frameMetadata = [
      for (final f in _allFrames)
        {
          // zoneHint: app-assigned label for analytics — not used by pipeline.
          'zoneHint': f.zoneId,

          // Device orbit tilt (pitch/roll from sensor zero) — analytics only.
          // NOT a cylindrical camera position; backend uses fixed 0/90/180/270.
          'deviceOrbitDegrees': f.thumbAngleDegrees,
          'targetAngleDegrees': f.targetAngleDegrees, // null for transitions
          'angularError': f.angularError,             // null for transitions
          'thumbCoverageRatio': f.thumbCoverageRatio,

          // Quality context.
          'laplacianScore': f.laplacianScore,
          'flashOn': f.flashOn,
          'flashIntensity': f.flashIntensity,
          // Ambient brightness at calibration (not torch-lit) — for NFIQ audit.
          'ambientBrightnessLuma': _brightnessCount > 0
              ? (_brightnessSum / _brightnessCount).roundToDouble()
              : null,
          // EV offset baked in at calibration — lets backend normalize exposure.
          'evOffsetApplied': _appliedEvOffset,
          // Flash mode set at calibration: pitch_dark | normal | bright.
          'flashMode': _flash?.modeName,
          // Thumb bounding box at capture time — lets backend crop without re-detection.
          if (f.thumbRoi != null) 'thumbRoi': {
            'left':   f.thumbRoi!.left,
            'top':    f.thumbRoi!.top,
            'right':  f.thumbRoi!.right,
            'bottom': f.thumbRoi!.bottom,
          },
          'timestamp': f.timestamp.toIso8601String(),
          // Raw Y-plane geometry. Backend decodes as:
          //   np.frombuffer(data, uint8).reshape((imageHeight, bytesPerRow))[:, :imageWidth]
          'imageWidth':   f.imageWidth,
          'imageHeight':  f.imageHeight,
          'bytesPerRow':  f.bytesPerRow,
        },
    ];

    // Generate the captureId here so the same ID is used whether the upload
    // succeeds immediately or is saved to the offline queue.
    final captureId = _uuid.v4();

    try {
      // Build per-angle orbit map for backend SfM seeding — eliminates a
      // second Firestore read in processEnhanceAndScore.
      final orbitAngles = <String, double>{};
      for (final name in ThumbAngleService.order) {
        final frames = _angleFramesByName[name];
        if (frames != null && frames.isNotEmpty) {
          orbitAngles[name] = frames.first.thumbAngleDegrees;
        }
      }

      await upload.uploadAndProcess(
        capture,
        userId: userId,
        captureId: captureId,
        frameMetadata: frameMetadata,
        thumbWidthFraction: thumbWidthFraction,
        burstStats: List.unmodifiable(_burstStatsList),
        axisGateAtCapture: List.unmodifiable(_axisGateLogs),
        orbitAngles: orbitAngles,
        onProgress: (p) =>
            _set(_state.copyWith(uploadProgress: p), notify: true),
      );

      _set(_state.copyWith(
        phase: CapturePhase.complete,
        captureId: captureId,
        uploadProgress: 1.0,
      ));
    } catch (e) {
      if (_isNetworkError(e)) {
        try {
          await _offlineQueue.enqueue(
            capture,
            userId,
            captureId,
            frameMetadata: frameMetadata,
          );
          _set(_state.copyWith(
            phase: CapturePhase.queued,
            captureId: captureId,
            uploadProgress: 0.0,
          ));
        } catch (queueErr) {
          _fail('Upload failed and could not save offline: $e');
        }
      } else {
        _fail('Upload failed: $e');
      }
    }
  }

  bool _isNetworkError(Object e) {
    // CaptureUploader implementations should throw CaptureNetworkException
    // for retryable network failures (e.g. wrapping backend-specific error
    // codes this package has no knowledge of). The string heuristic below is
    // a fallback for uploaders that don't.
    if (e is CaptureNetworkException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('network') ||
        msg.contains('socketexception') ||
        msg.contains('connection refused') ||
        msg.contains('no internet');
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  double _meanLuma(CameraImage image, {Rect? roi}) {
    if (image.planes.isEmpty) return 0.0;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    if (w < 8 || h < 8) return 0.0;
    final stride = h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;
    var sum = 0;
    var n = 0;
    if (roi != null) {
      final x0 = (roi.left * w).clamp(0, w - 1).toInt();
      final y0 = (roi.top * h).clamp(0, h - 1).toInt();
      final x1 = (roi.right * w).clamp(0, w - 1).toInt();
      final y1 = (roi.bottom * h).clamp(0, h - 1).toInt();
      if (x1 > x0 + 1 && y1 > y0 + 1) {
        for (var y = y0; y < y1; y += 8) {
          final row = y * stride;
          for (var x = x0; x < x1; x += 8) {
            sum += bytes[row + x];
            n++;
          }
        }
        return n > 0 ? sum / n : 0.0;
      }
    }
    for (var y = 0; y < h; y += 8) {
      final row = y * stride;
      for (var x = 0; x < w; x += 8) {
        sum += bytes[row + x];
        n++;
      }
    }
    return n > 0 ? sum / n : 0.0;
  }

  Future<void> _stopStream() async {
    if (!_streamRunning) return;
    _streamRunning = false;
    try {
      await _camera?.stopImageStream();
    } catch (_) {}
  }

  void _fail(String message) {
    unawaited(_flash?.deactivate());
    unawaited(_stopStream());
    _set(_state.copyWith(phase: CapturePhase.error, error: message));
  }

  void _set(CaptureSessionState next, {bool notify = true}) {
    _state = next;
    if (notify && !_disposed) notifyListeners();
  }

  /// Returns a normalized [Rect] (0–1) bounding the thumb (landmarks 1–4)
  /// with 10% padding, or null if the ROI is too small (<40px on device).
  Rect? _computeThumbRoi(List<Landmark> landmarks, double imgW, double imgH) {
    if (landmarks.length < 5) return null;
    try {
      final tip = landmarks[4]; // thumb tip
      final base = landmarks[1]; // CMC
      final minX = tip.x < base.x ? tip.x : base.x;
      final maxX = tip.x > base.x ? tip.x : base.x;
      final minY = tip.y < base.y ? tip.y : base.y;
      final maxY = tip.y > base.y ? tip.y : base.y;
      final padX = (maxX - minX) * 0.10;
      final padY = (maxY - minY) * 0.10;
      if ((maxX - minX + 2 * padX) * imgW < 40) return null;
      if ((maxY - minY + 2 * padY) * imgH < 40) return null;
      return Rect.fromLTRB(
        (minX - padX).clamp(0.0, 1.0),
        (minY - padY).clamp(0.0, 1.0),
        (maxX + padX).clamp(0.0, 1.0),
        (maxY + padY).clamp(0.0, 1.0),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_flash?.deactivate());
    _gyroSub?.cancel();
    unawaited(_stopStream());
    _hybrid.reset();
    _plugin?.dispose();
    _orientationClassifier?.dispose();
    _captureAudio.dispose();
    _orientation.dispose();
    super.dispose();
  }
}

/// autoDispose so each entry into the capture screen gets a fresh controller
/// (a lingering `complete` phase must not auto-navigate on re-entry).
final multiAngleCaptureControllerProvider =
    ChangeNotifierProvider.autoDispose<MultiAngleCaptureController>(
  (ref) => MultiAngleCaptureController(ref.read(offlineCaptureQueueProvider)),
);
