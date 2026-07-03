import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as imglib;
import 'package:sensors_plus/sensors_plus.dart';

import 'adaptive_flash_controller.dart';
import 'arc_capture_uploader.dart';
import 'frame_capture_service.dart';
import 'thumb_landmarker_service.dart';

enum ArcSweepPhase {
  idle,
  showingAnimation,
  awaitingStart,
  calibrating,
  sweeping,
  uploading,
  complete,
  error,
}

/// One leg of the sweep path between two checkpoints, in (pitch, roll)
/// device-orientation degrees relative to the front pose. Mirrors
/// [ThumbAngleService.targets] so the sweep traces the exact same physical
/// positions as the 4-angle capture's front/left/top/right checkpoints.
class _LegSpec {
  final double p0, r0, p1, r1;
  final String label;
  final String instruction;
  const _LegSpec({
    required this.p0,
    required this.r0,
    required this.p1,
    required this.r1,
    required this.label,
    required this.instruction,
  });
}

class ArcSweepState {
  final ArcSweepPhase phase;
  final double pathFraction;    // 0.0-1.0 overall progress along front→left→top→right
  final int activeLegIndex;     // 0=front→left, 1=left→top, 2=top→right, -1=idle
  // Degrees from the current phone orientation to the checkpoint at the end
  // of the active leg (LEFT/TOP/RIGHT) — converges to 0 exactly when the
  // phone reaches that checkpoint, mirroring AngleDegreeText's countdown in
  // the 4-angle flow so users have the same "drive it to zero" cue here.
  final double distanceToTargetDeg;
  final int binsFilledCount;    // how many path bins have a qualifying frame
  final int filledBinMask;      // bitmask of which of the 18 path bins are filled
  final bool tooFast;           // phone turning too fast to bin — show "slow down"
  // Thumb-coverage gate (same 0.35–0.85 window as the 4-angle flow). tooFar =
  // thumb too small in frame (move closer); tooClose = filling too much
  // (move back). Both false when coverage is in range or detection is stale.
  final bool tooFar;
  final bool tooClose;
  final double thumbCoverageRatio;
  final bool refocusing;        // per-leg AF re-run in progress — binning paused
  final double lightingValue;   // 0.0-1.0 EMA
  final double focusValue;      // 0.0-1.0 EMA
  final bool flashOn;
  final double flashIntensity;
  final double uploadProgress;
  final String? captureId;
  final String? error;

  const ArcSweepState({
    this.phase = ArcSweepPhase.idle,
    this.pathFraction = 0.0,
    this.activeLegIndex = -1,
    this.distanceToTargetDeg = 0.0,
    this.binsFilledCount = 0,
    this.filledBinMask = 0,
    this.tooFast = false,
    this.tooFar = false,
    this.tooClose = false,
    this.thumbCoverageRatio = 0.0,
    this.refocusing = false,
    this.lightingValue = 0.0,
    this.focusValue = 0.0,
    this.flashOn = false,
    this.flashIntensity = 0.0,
    this.uploadProgress = 0.0,
    this.captureId,
    this.error,
  });

  ArcSweepState copyWith({
    ArcSweepPhase? phase,
    double? pathFraction,
    int? activeLegIndex,
    double? distanceToTargetDeg,
    int? binsFilledCount,
    int? filledBinMask,
    bool? tooFast,
    bool? tooFar,
    bool? tooClose,
    double? thumbCoverageRatio,
    bool? refocusing,
    double? lightingValue,
    double? focusValue,
    bool? flashOn,
    double? flashIntensity,
    double? uploadProgress,
    String? captureId,
    String? error,
  }) =>
      ArcSweepState(
        phase: phase ?? this.phase,
        pathFraction: pathFraction ?? this.pathFraction,
        activeLegIndex: activeLegIndex ?? this.activeLegIndex,
        distanceToTargetDeg: distanceToTargetDeg ?? this.distanceToTargetDeg,
        binsFilledCount: binsFilledCount ?? this.binsFilledCount,
        filledBinMask: filledBinMask ?? this.filledBinMask,
        tooFast: tooFast ?? this.tooFast,
        tooFar: tooFar ?? this.tooFar,
        tooClose: tooClose ?? this.tooClose,
        thumbCoverageRatio: thumbCoverageRatio ?? this.thumbCoverageRatio,
        refocusing: refocusing ?? this.refocusing,
        lightingValue: lightingValue ?? this.lightingValue,
        focusValue: focusValue ?? this.focusValue,
        flashOn: flashOn ?? this.flashOn,
        flashIntensity: flashIntensity ?? this.flashIntensity,
        uploadProgress: uploadProgress ?? this.uploadProgress,
        captureId: captureId ?? this.captureId,
        error: error ?? this.error,
      );
}

/// Arc-sweep capture controller.
///
/// The user holds the thumb still and slowly tilts the phone through the same
/// four checkpoints — and in the same order — as the 4-angle capture:
/// front (0°,0°) → left (pitch −32°) → top (roll −20°) → right (pitch +32°).
/// See [ThumbAngleService.targets]/[ThumbAngleService.order] for the source
/// of truth on those positions; this controller re-derives pitch/roll from
/// the same quaternion construction as [DeviceOrientationService] so the two
/// capture modes agree on what "left"/"top"/"right" mean.
///
/// Rather than four discrete holds, the sweep is captured continuously and
/// densely: the front→left→top→right path is split into 3 legs of 6 bins
/// each (18 bins total). Every frame is projected onto the nearest point of
/// whichever leg it's closest to, and the sharpest frame per bin is kept.
/// The session completes once each leg has at least 4 of its 6 bins filled —
/// i.e. once the user has actually swept through all three legs, not just
/// racked up 18 bins' worth of dithering on one.
///
/// Capture-quality machinery (mirrors the 4-angle flow):
///  * Focus/brightness scoring restricted to a centre ROI so a sharp
///    background can't outscore a slightly-soft thumb.
///  * Thumb-coverage gate via the TFLite hand landmarker (0.35–0.85 window,
///    fail-open when detection is stale so a model failure can't brick capture).
///  * Uploaded frames are centre-cropped from the Y plane with stride handled,
///    then JPEG-encoded (unlike the 4-angle path, which uploads full,
///    uncropped native-resolution raw Y-plane bytes — the backend's raw-
///    buffer decode fallback only matches a handful of hardcoded standard
///    camera resolutions, and a crop's dimensions never land on one of those
///    by chance, so a real encode is what makes the crop decodable at all).
///  * Torch alternation during the sweep retains the best ambient AND best
///    torch-lit frame per bin so the backend has fusion material.
///  * AF re-runs at each leg transition (binning pauses during the hunt).
///  * EV steps down when the thumb ROI approaches blow-out, instead of
///    discarding glared frames after the fact.
///  * A full-resolution still (takePicture) fires as each checkpoint locks,
///    decoded to raw luma client-side so it rides the same upload contract.
class ArcSweepCaptureController extends ChangeNotifier {
  ArcSweepCaptureController();

  // ── Path geometry ────────────────────────────────────────────────────────
  // Same checkpoint values as ThumbAngleService.targets (left/right on the
  // pitch axis at ±32°, top on the roll axis at −20°), traversed in
  // ThumbAngleService.order: front → left → top → right.
  static const _legs = <_LegSpec>[
    _LegSpec(
      p0: 0, r0: 0, p1: -32, r1: 0,
      label: 'LEFT',
      instruction: 'Tilt phone to the LEFT — capture left edge',
    ),
    _LegSpec(
      p0: -32, r0: 0, p1: 0, r1: -20,
      label: 'TOP',
      instruction: 'Tilt toward THUMB TIP — capture top of thumbprint',
    ),
    _LegSpec(
      p0: 0, r0: -20, p1: 32, r1: 0,
      label: 'RIGHT',
      instruction: 'Tilt phone to the RIGHT — capture right edge',
    ),
  ];
  static const _binsPerLeg = 6;
  static const _totalBins = _binsPerLeg * 3; // 18
  // A leg counts as "covered" once most (not all) of its bins are filled —
  // avoids stalling the whole sweep over one or two marginal frames near a
  // checkpoint's exact endpoint.
  static const _minBinsPerLegToComplete = 4;
  // Frames whose (pitch, roll) land further than this from every leg are
  // considered off the intended path (e.g. a stray yaw/roll combination) and
  // are not binned — a generous sanity gate, not a strict one.
  static const _offPathThresholdDeg = 25.0;

  // Slow-motion gate: frames only bin when the phone is turning slowly enough
  // for a sharp, well-registered view. Also stops testers blasting through the
  // sweep — the whole point of the redesign.
  static const _maxSweepSpeedRadPerSec = 0.7;
  static const _calibDurationMs = 2000;
  static const _emitThrottleMs = 80;
  static const _focusHistoryLen = 5;
  static const _focusStabilityRatio = 0.15;
  static const _focusMinAbsolute = 15.0;

  // ── Quality-capture constants ────────────────────────────────────────────
  // Tight centre ROI for focus/brightness *scoring* — the guidance UI centres
  // the thumb here, so judging sharpness on this window (instead of the whole
  // frame) stops a crisp background from outscoring a soft thumb.
  static const _scoreRoi = Rect.fromLTRB(0.30, 0.30, 0.70, 0.70);
  // Looser ROI for the *upload* crop: generous margin around a centred thumb
  // so the backend's segmentation still has context, while cutting well over
  // half the background pixels (better ridge-resolution per uploaded byte).
  static const _uploadRoi = Rect.fromLTRB(0.18, 0.15, 0.82, 0.85);
  // Same coverage window the 4-angle screen gates on (thumb fills 35–85%).
  static const _coverageMin = 0.35;
  static const _coverageMax = 0.85;
  // Landmark detection cadence (frames) and staleness horizon. Detection is
  // ~tens of ms of CPU; the 4-angle flow runs it far more often, so this is
  // conservative. Past the horizon the gate fails OPEN — a landmarker failure
  // must never brick the arc capture.
  static const _landmarkEveryNFrames = 6;
  static const _coverageStaleMs = 2000;
  // Torch alternation period while sweeping (normal mode only) — yields both
  // ambient and torch-lit frames per bin for backend Mertens-style fusion.
  static const _torchAlternateMs = 600;
  // Glare guard: EV steps down when ambient ROI luma exceeds the high mark,
  // restores when it falls below the low mark. Values chosen against
  // _mapBrightnessScore, which zeroes frames above 220 — prevention > rejection.
  static const _glareHighLuma = 205.0;
  static const _glareLowLuma = 165.0;
  static const _glareEvStep = -0.7;
  // Still capture: fires once per leg when the checkpoint locks (same ≤5°
  // threshold as the 4-angle lock). Decoded at this max width to bound the
  // transient RGBA buffer (~2048×1536×4 ≈ 12.6 MB) on low-end devices.
  static const _stillLockThresholdDeg = 5.0;
  static const _stillDecodeTargetWidth = 2048;

  // ── State ─────────────────────────────────────────────────────────────────
  CameraController? _camera;
  AdaptiveFlashController? _flash;
  ArcCaptureUploader? _upload;
  String? _userId;

  ArcSweepState _state = const ArcSweepState();
  ArcSweepState get state => _state;

  bool _disposed = false;
  bool _streamRunning = false;
  // Set synchronously at the top of startCaptureSequence, before any await.
  // _streamRunning alone isn't set until AFTER startImageStream() succeeds,
  // which left a race window: a rapid double-tap on "Start Sweep" (or any
  // other quick re-invocation) could see _streamRunning still false on both
  // calls and let both race into camera.startImageStream() — the loser hits
  // CameraException("startImageStream was called while a camera was
  // streaming images."), a real observed on-device failure.
  bool _starting = false;
  bool _calibrated = false;
  bool _sweepActive = false;
  bool _complete = false;

  // Gyro
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final Queue<double> _gyroHistory = Queue();
  double _gyroMagnitude = 0.0;

  final _hybrid = HybridCaptureService();

  // Thumb landmarker (coverage gate). Initialized once per controller —
  // ThumbLandmarkerService.initialize() is async and loads a TFLite model.
  final _landmarker = ThumbLandmarkerService();
  bool _landmarkerInitStarted = false;
  int _sensorOrientation = 0;
  int _frameCounter = 0;
  double _lastCoverage = 0.0;
  DateTime? _lastCoverageAt;

  // Quaternion orientation tracker (unit quaternion in device frame)
  double _qw = 1.0, _qx = 0.0, _qy = 0.0, _qz = 0.0;
  // Reference quaternion captured at sweep start
  double _q0w = 1.0, _q0x = 0.0, _q0y = 0.0, _q0z = 0.0;
  bool _q0Captured = false;

  // Signed pitch/roll (degrees) relative to the sweep-start pose, using the
  // same q_rel = q0⁻¹ ⊗ q_current construction and Euler formulas as
  // DeviceOrientationService.relativeOrientation() so both capture modes
  // agree on sign conventions.
  double _sweepPitchDeg = 0.0;
  double _sweepRollDeg = 0.0;
  DateTime? _lastGyroAt;

  // Frame bins, split by illumination so the backend gets fusion material:
  // global bin id (leg * _binsPerLeg + binInLeg) → best frame of that type.
  final Map<int, _BinFrame> _bestAmbientPerBin = {};
  final Map<int, _BinFrame> _bestFlashPerBin = {};

  // Full-resolution checkpoint stills (one per leg, opportunistic).
  final List<_StillFrame> _stills = [];
  final Set<int> _stillCapturedLegs = {};
  bool _takingStill = false;

  // Torch alternation + glare guard.
  DateTime? _lastTorchToggleAt;
  double _lastStableBrightness = 128.0;
  double _appliedEvOffset = 0.0;
  bool _evChangeInFlight = false;

  // Per-leg refocus. Tracks the furthest leg reached (not the current one)
  // so projection flapping at a checkpoint corner can't re-trigger AF.
  int _maxLegReached = -1;
  bool _refocusing = false;

  // Active leg, as a one-way ratchet (see _projectToPath) — never regresses.
  int _currentLegIndex = 0;

  // Calibration
  DateTime? _calibStart;
  final List<double> _brightnessSamples = [];
  final List<double> _rawFocusHistory = [];

  // Focus normalization
  double _focusPeak = 1.0;

  // Emit throttle
  DateTime? _lastEmitAt;

  // ── Phase transitions ──────────────────────────────────────────────────────

  void startIntro() {
    if (_state.phase != ArcSweepPhase.idle) return;
    _set(_state.copyWith(phase: ArcSweepPhase.showingAnimation));
  }

  void onAnimationComplete() {
    if (_state.phase != ArcSweepPhase.showingAnimation) return;
    _set(_state.copyWith(phase: ArcSweepPhase.awaitingStart));
  }

  Future<void> startCaptureSequence({
    required CameraController camera,
    required ArcCaptureUploader uploadService,
    required String userId,
  }) async {
    if (_streamRunning || _starting) return;
    _starting = true;
    _camera = camera;
    _upload = uploadService;
    _userId = userId;
    _flash = AdaptiveFlashController(camera);
    _sensorOrientation = camera.description.sensorOrientation;

    if (!_landmarkerInitStarted) {
      _landmarkerInitStarted = true;
      _landmarker.initialize();
    }

    _bestAmbientPerBin.clear();
    _bestFlashPerBin.clear();
    _stills.clear();
    _stillCapturedLegs.clear();
    _takingStill = false;
    _brightnessSamples.clear();
    _rawFocusHistory.clear();
    _gyroHistory.clear();
    _gyroMagnitude = 0.0;
    _sweepPitchDeg = 0.0;
    _sweepRollDeg = 0.0;
    _lastGyroAt = null;
    _qw = 1.0; _qx = 0.0; _qy = 0.0; _qz = 0.0;
    _q0w = 1.0; _q0x = 0.0; _q0y = 0.0; _q0z = 0.0;
    _q0Captured = false;
    _calibrated = false;
    _sweepActive = false;
    _complete = false;
    _calibStart = null;
    _focusPeak = 1.0;
    _frameCounter = 0;
    _lastCoverage = 0.0;
    _lastCoverageAt = null;
    _lastTorchToggleAt = null;
    _lastStableBrightness = 128.0;
    _appliedEvOffset = 0.0;
    _evChangeInFlight = false;
    _maxLegReached = -1;
    _refocusing = false;
    _currentLegIndex = 0;

    // Neutral EV baseline — the glare guard applies offsets relative to this.
    try {
      await camera.setExposureOffset(0.0);
    } catch (_) {}

    _gyroSub?.cancel();
    _gyroSub = gyroscopeEventStream().listen((e) {
      final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      _gyroHistory.addLast(mag);
      if (_gyroHistory.length > 10) _gyroHistory.removeFirst();
      _gyroMagnitude = _gyroHistory.reduce((a, b) => a + b) / _gyroHistory.length;

      final now = DateTime.now();
      final dt = _lastGyroAt == null
          ? 0.0
          : now.difference(_lastGyroAt!).inMicroseconds / 1e6;
      _lastGyroAt = now;

      if (dt <= 0 || dt > 0.1) return;

      // Quaternion integration — always runs to maintain accurate orientation.
      // First-order update: q += 0.5 * dt * q ⊗ [0, wx, wy, wz], then normalise.
      final h = dt * 0.5;
      final dw = (-_qx * e.x - _qy * e.y - _qz * e.z) * h;
      final dx = ( _qw * e.x + _qy * e.z - _qz * e.y) * h;
      final dy = ( _qw * e.y - _qx * e.z + _qz * e.x) * h;
      final dz = ( _qw * e.z + _qx * e.y - _qy * e.x) * h;
      _qw += dw; _qx += dx; _qy += dy; _qz += dz;
      final norm = math.sqrt(_qw*_qw + _qx*_qx + _qy*_qy + _qz*_qz);
      if (norm > 1e-6) { _qw /= norm; _qx /= norm; _qy /= norm; _qz /= norm; }

      if (_sweepActive) {
        // Capture reference quaternion at the first event after sweep begins.
        if (!_q0Captured) {
          _q0w = _qw; _q0x = _qx; _q0y = _qy; _q0z = _qz;
          _q0Captured = true;
        }
        // Relative rotation q_rel = q0⁻¹ ⊗ q_current — same construction as
        // DeviceOrientationService.relativeOrientation(), so pitch/roll below
        // match the 4-angle path's sign conventions exactly.
        final aw = _q0w, ax = -_q0x, ay = -_q0y, az = -_q0z; // q0 conjugate
        final rw = aw*_qw - ax*_qx - ay*_qy - az*_qz;
        final rx = aw*_qx + ax*_qw + ay*_qz - az*_qy;
        final ry = aw*_qy - ax*_qz + ay*_qw + az*_qx;
        final rz = aw*_qz + ax*_qy - ay*_qx + az*_qw;

        // Roll (about X).
        final sinrCosp = 2.0 * (rw*rx + ry*rz);
        final cosrCosp = 1.0 - 2.0 * (rx*rx + ry*ry);
        _sweepRollDeg = math.atan2(sinrCosp, cosrCosp) * 180.0 / math.pi;

        // Pitch (about Y), clamped at the gimbal poles.
        final sinp = (2.0 * (rw*ry - rz*rx)).clamp(-1.0, 1.0);
        _sweepPitchDeg = math.asin(sinp) * 180.0 / math.pi;
      }
    });

    _set(_state.copyWith(
      phase: ArcSweepPhase.calibrating,
      pathFraction: 0.0,
      activeLegIndex: -1,
      binsFilledCount: 0,
      filledBinMask: 0,
    ));

    try {
      await _beginAutofocus();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // Defensive: this controller talks to the raw CameraController
      // directly rather than through CameraService, so it never got
      // CameraService.startImageStream()'s "already streaming? stop first"
      // guard. Check the controller's own authoritative state (not our
      // _streamRunning flag, which only reflects what THIS controller
      // instance did) in case a prior session left it streaming.
      if (camera.value.isStreamingImages) {
        try {
          await camera.stopImageStream();
        } catch (_) {}
      }
      await camera.startImageStream(_onFrame);
      _streamRunning = true;
    } catch (e) {
      _fail('Could not start camera stream: $e');
    } finally {
      _starting = false;
    }
  }

  // ── Stream processing ──────────────────────────────────────────────────────

  void _onFrame(CameraImage image) {
    if (_disposed) return;
    final phase = _state.phase;
    if (phase != ArcSweepPhase.calibrating && phase != ArcSweepPhase.sweeping) return;

    _frameCounter++;

    // Brightness measured on the scoring ROI (not the whole frame) so the
    // meters and quality scores reflect the thumb, not the background.
    final brightness =
        HybridCaptureService.meanLuma(image, roi: _scoreRoi);
    if (!(_flash?.isFlashOn ?? false)) _lastStableBrightness = brightness;
    final lightingNorm = (brightness / 255.0).clamp(0.0, 1.0);
    // Sharpness scored on the same centre ROI.
    final rawFocus = _hybrid.offerFrame(image, thumbRoi: _scoreRoi);
    if (rawFocus > _focusPeak) _focusPeak = rawFocus;
    _focusPeak *= 0.999;
    final focusNorm = (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0);
    final lighting = HybridCaptureService.ema(_state.lightingValue, lightingNorm);
    final focus = HybridCaptureService.ema(_state.focusValue, focusNorm);

    _rawFocusHistory.add(rawFocus);
    if (_rawFocusHistory.length > _focusHistoryLen) _rawFocusHistory.removeAt(0);

    // Thumb-coverage detection at reduced cadence (same model + formula as
    // the 4-angle flow: coverage = |thumbTip.y − wrist.y| in landmark space).
    if (_frameCounter % _landmarkEveryNFrames == 0 && _landmarker.isReady) {
      final hands = _landmarker.detect(image, _sensorOrientation);
      if (hands.isNotEmpty && hands.first.landmarks.length > 4) {
        final lms = hands.first.landmarks;
        _lastCoverage = (lms[4].y - lms[0].y).abs().clamp(0.0, 1.0);
        _lastCoverageAt = DateTime.now();
      }
    }

    final proj = _projectToPath(_sweepPitchDeg, _sweepRollDeg);

    if (phase == ArcSweepPhase.calibrating) {
      _brightnessSamples.add(brightness);
      _runCalibration(rawFocus);
    } else if (_sweepActive && !_complete) {
      _maybeToggleTorch();
      _maybeAdjustExposure();
      _maybeRefocusForLeg(proj.legIndex);
      _maybeCaptureStill(proj.legIndex);
      _binFrame(image, rawFocus, brightness, proj);
    }

    _emitMeters(lighting, focus, proj);
  }

  void _emitMeters(double lighting, double focus,
      ({int legIndex, double t, double distDeg}) proj) {
    final now = DateTime.now();
    // Straight-line distance from the current orientation to the checkpoint
    // at the end of the active leg — this is what AngleDegreeText counts
    // down to 0 with, exactly like the 4-angle flow's distanceToTarget.
    final target = _legs[proj.legIndex];
    final dp = _sweepPitchDeg - target.p1;
    final dr = _sweepRollDeg - target.r1;
    final distanceToTarget = math.sqrt(dp * dp + dr * dr);
    var mask = 0;
    for (var b = 0; b < _totalBins; b++) {
      if (_binFilled(b)) mask |= (1 << b);
    }
    final coverageFresh = _lastCoverageAt != null &&
        now.difference(_lastCoverageAt!).inMilliseconds < _coverageStaleMs;
    final next = _state.copyWith(
      lightingValue: lighting,
      focusValue: focus,
      flashOn: _flash?.isFlashOn ?? false,
      flashIntensity: _flash?.intensity ?? 0.0,
      pathFraction: (proj.legIndex + proj.t) / _legs.length,
      activeLegIndex: proj.legIndex,
      distanceToTargetDeg: distanceToTarget,
      binsFilledCount: _filledBinCount(),
      filledBinMask: mask,
      tooFast: _sweepActive && _gyroMagnitude > _maxSweepSpeedRadPerSec,
      tooFar: _sweepActive && coverageFresh && _lastCoverage < _coverageMin,
      tooClose: _sweepActive && coverageFresh && _lastCoverage > _coverageMax,
      thumbCoverageRatio: _lastCoverage,
      refocusing: _refocusing,
    );
    if (_lastEmitAt == null ||
        now.difference(_lastEmitAt!).inMilliseconds >= _emitThrottleMs) {
      _lastEmitAt = now;
      _set(next, notify: true);
    } else {
      _state = next;
    }
  }

  // ── Calibration ────────────────────────────────────────────────────────────

  void _runCalibration(double rawFocus) {
    _calibStart ??= DateTime.now();
    final now = DateTime.now();

    if (_rawFocusHistory.length == _focusHistoryLen &&
        rawFocus >= _focusMinAbsolute &&
        _isFocusStable()) {
      unawaited(_finalizeCalibration());
      return;
    }

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

    if (_brightnessSamples.isNotEmpty) {
      final avg = _brightnessSamples.reduce((a, b) => a + b) / _brightnessSamples.length;
      await _flash?.calibrate(avg);
    }

    if (_disposed) return;

    // Lock focus so it doesn't hunt as the phone orbits the thumb.
    // AE is intentionally left in auto — exposure needs to adapt as
    // the camera moves from face-on to side-on views of the finger.
    unawaited(_lockFocusOnly());

    // Torch policy: in bright ambient (isNeeded == false) the torch degrades
    // ridge contrast — leave it off. Otherwise start torch-on; the sweep-time
    // alternation in _maybeToggleTorch takes over from here (except pitch
    // dark, where the torch is the only light source and stays on).
    if (_flash?.isNeeded ?? false) {
      _flash?.activate();
    }
    _lastTorchToggleAt = DateTime.now();

    _q0Captured = false; // reference will be captured on first gyro event
    _sweepActive = true;
    _set(_state.copyWith(
      phase: ArcSweepPhase.sweeping,
      pathFraction: 0.0,
      activeLegIndex: 0,
      binsFilledCount: 0,
      filledBinMask: 0,
    ));
  }

  // ── Torch alternation / exposure guard / per-leg refocus ──────────────────

  /// Alternates the torch while sweeping so bins collect both an ambient and
  /// a torch-lit frame — the same fl/amb pairing the 4-angle flow gives the
  /// backend for Mertens fusion. Skipped in pitch dark (torch is the sole
  /// light source; deactivate() is a no-op there anyway) and in bright mode
  /// (torch never activated). Paused while a still is in flight so the
  /// checkpoint still isn't captured mid-lighting-change.
  void _maybeToggleTorch() {
    final flash = _flash;
    if (flash == null || !flash.isNeeded || flash.isPitchDark) return;
    if (_takingStill) return;
    final now = DateTime.now();
    if (_lastTorchToggleAt != null &&
        now.difference(_lastTorchToggleAt!).inMilliseconds < _torchAlternateMs) {
      return;
    }
    _lastTorchToggleAt = now;
    if (flash.isFlashOn) {
      unawaited(flash.deactivate());
    } else {
      unawaited(flash.activate());
    }
  }

  /// Steps EV down when the ambient-measured thumb ROI approaches blow-out
  /// (glare kills ridge contrast and _mapBrightnessScore would zero those
  /// frames anyway) and restores it once the reading falls back. Uses only
  /// torch-off readings so torch light can't trigger a spurious pull-down.
  void _maybeAdjustExposure() {
    if (_evChangeInFlight) return;
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    double? target;
    if (_lastStableBrightness > _glareHighLuma && _appliedEvOffset == 0.0) {
      target = _glareEvStep;
    } else if (_lastStableBrightness < _glareLowLuma && _appliedEvOffset != 0.0) {
      target = 0.0;
    }
    if (target == null) return;
    _evChangeInFlight = true;
    final t = target;
    () async {
      try {
        final minEv = await c.getMinExposureOffset();
        final maxEv = await c.getMaxExposureOffset();
        await c.setExposureOffset(t.clamp(minEv, maxEv));
        _appliedEvOffset = t;
      } catch (_) {
        // Device doesn't support EV offsets — leave the guard disarmed.
        _appliedEvOffset = t; // don't retry every frame
      } finally {
        _evChangeInFlight = false;
      }
    }();
  }

  /// Re-runs autofocus when the sweep first crosses into a new leg. Focus was
  /// locked at the front pose during calibration; users pivot the phone in
  /// place rather than orbiting perfectly, so lens-to-thumb distance drifts
  /// across legs and the locked focus goes soft at the edges. Binning pauses
  /// (via [_refocusing]) while the lens hunts. Only a *forward* leg advance
  /// triggers AF — the projection flaps between adjacent legs right at a
  /// checkpoint corner, and re-triggering there would stall binning.
  void _maybeRefocusForLeg(int legIndex) {
    if (legIndex <= _maxLegReached) return;
    // Defer (don't consume the leg-advance yet) while a still capture has the
    // stream stopped — an AF call racing takePicture()'s stream stop/restart
    // is the same class of concurrent-camera-control hazard the still-capture
    // fix above addresses. Retried next frame; harmless to be a bit late.
    if (_takingStill) return;
    final first = _maxLegReached == -1;
    _maxLegReached = legIndex;
    if (first || _refocusing) return; // initial leg uses the calibration lock
    _refocusing = true;
    () async {
      try {
        await _beginAutofocus();
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _lockFocusOnly();
      } catch (_) {
      } finally {
        _refocusing = false;
      }
    }();
  }

  // ── Checkpoint stills ──────────────────────────────────────────────────────

  /// Fires a full-resolution still capture the first time each leg's
  /// checkpoint locks (≤5° — same threshold as the 4-angle angle lock).
  /// Stills come from the ISP's still pipeline (multi-frame NR, proper
  /// sharpening, full sensor resolution) rather than the preview stream, and
  /// are decoded to raw luma client-side so they ride the exact same
  /// raw-Y-plane upload contract as stream frames. Failures are swallowed:
  /// stills are opportunistic bonus material, never a capture dependency.
  void _maybeCaptureStill(int legIndex) {
    // _refocusing check: don't fire a still capture (which stops/restarts the
    // stream) while an AF call from _maybeRefocusForLeg is in flight — same
    // concurrent-camera-control hazard, guarded from the other direction.
    if (_takingStill || _refocusing || _stillCapturedLegs.contains(legIndex)) {
      return;
    }
    final target = _legs[legIndex];
    final dp = _sweepPitchDeg - target.p1;
    final dr = _sweepRollDeg - target.r1;
    if (math.sqrt(dp * dp + dr * dr) > _stillLockThresholdDeg) return;
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;

    _takingStill = true;
    _stillCapturedLegs.add(legIndex);
    final pitchAtCapture = _sweepPitchDeg;
    final rollAtCapture = _sweepRollDeg;
    () async {
      // takePicture() while an image stream is active is unreliable on
      // Android — some vendor camera HALs never resolve the still-capture
      // request when a repeating preview/stream request is also attached,
      // hanging the Future indefinitely. Stopping the stream first and
      // restarting it after is the plugin-sanctioned way to interleave a
      // still capture with streaming.
      final wasStreaming = _streamRunning;
      try {
        if (wasStreaming) await _stopStream();
        final xfile = await c.takePicture();
        final jpeg = await xfile.readAsBytes();
        final luma = await _decodeJpegToBufferLuma(jpeg);
        if (luma != null && !_disposed) {
          _stills.add(_StillFrame(
            bytes: luma.bytes,
            width: luma.width,
            height: luma.height,
            pitchDeg: pitchAtCapture,
            rollDeg: rollAtCapture,
            legIndex: legIndex,
            timestamp: DateTime.now(),
            flashOn: _flash?.isFlashOn ?? false,
            flashIntensity: _flash?.intensity ?? 0.0,
          ));
          HapticFeedback.lightImpact();
        }
      } catch (e) {
        debugPrint('[arc] checkpoint still failed (non-blocking): $e');
      } finally {
        _takingStill = false;
        if (wasStreaming && !_disposed && _sweepActive) {
          try {
            await c.startImageStream(_onFrame);
            _streamRunning = true;
          } catch (e) {
            debugPrint('[arc] failed to resume image stream after still: $e');
          }
        }
      }
    }();
  }

  /// Decodes a JPEG still to a JPEG-re-encoded luma buffer in the SAME
  /// orientation as the preview-stream Y planes, so the backend sees a
  /// consistent set of frames.
  ///
  /// The stream buffer is in sensor (landscape) orientation; takePicture JPEGs
  /// decode EXIF-upright (portrait on a 90°/270° sensor). For those sensors
  /// the upright image is rotated 90° CW back into buffer orientation —
  /// the inverse of ThumbLandmarkerService's buffer→upright CCW rotation.
  ///
  /// Re-encoded as JPEG rather than left as a raw buffer for the same reason
  /// as [_extractRoiBytes]: the backend's decoder only reliably handles
  /// either a real image decode or a byte count matching one of a handful of
  /// hardcoded standard camera resolutions, and this decoded-then-rotated
  /// still's dimensions won't reliably match either by chance.
  Future<({Uint8List bytes, int width, int height})?> _decodeJpegToBufferLuma(
      Uint8List jpeg) async {
    final codec = await ui.instantiateImageCodec(
      jpeg,
      targetWidth: _stillDecodeTargetWidth,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    try {
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;
      final rgba = byteData.buffer.asUint8List();
      final w = image.width;
      final h = image.height;

      // RGBA → luma (BT.601 integer approximation).
      final luma = Uint8List(w * h);
      for (var i = 0, p = 0; i < luma.length; i++, p += 4) {
        luma[i] =
            (77 * rgba[p] + 150 * rgba[p + 1] + 29 * rgba[p + 2]) >> 8;
      }

      if (_sensorOrientation == 90 || _sensorOrientation == 270) {
        // Rotate 90° CW: dst is h wide × w tall; dst(x,y) = src(y, h-1-x).
        final rotated = Uint8List(w * h);
        final dstW = h;
        final dstH = w;
        for (var y = 0; y < dstH; y++) {
          final srcCol = y;
          for (var x = 0; x < dstW; x++) {
            rotated[y * dstW + x] = luma[(h - 1 - x) * w + srcCol];
          }
        }
        return (
          bytes: _encodeGrayscaleJpeg(rotated, dstW, dstH),
          width: dstW,
          height: dstH,
        );
      }
      return (bytes: _encodeGrayscaleJpeg(luma, w, h), width: w, height: h);
    } finally {
      image.dispose();
    }
  }

  // ── Path projection ─────────────────────────────────────────────────────────

  /// Returns the phone's position relative to the ACTIVE leg of the
  /// front→left→top→right path: the leg index, position along it (0..1),
  /// and perpendicular distance in degrees.
  ///
  /// The active leg is a one-way ratchet (advances once the phone gets within
  /// [_stillLockThresholdDeg] of the current leg's checkpoint; never
  /// regresses) rather than a fresh "nearest of all 3 legs" search every
  /// frame. The naive nearest-leg approach breaks under overshoot: once the
  /// phone passes a checkpoint (e.g. pitch beyond LEFT's −32°), both the leg
  /// just finished and the leg that should start next clamp their projection
  /// to the SAME corner point and report the SAME distance — the tie always
  /// resolves to the earlier leg, so continued motion just grows the "distance
  /// to LEFT" reading instead of ever being recognised as progress toward
  /// TOP. That is what produced the frozen "tilt toward LEFT" / stalled
  /// coverage bug: the user visibly reached the tip while the projection
  /// stayed pinned on leg 0. The ratchet can't get confused this way — an
  /// overshoot just makes the countdown climb again until the user corrects
  /// back onto the checkpoint they're actually meant to be closing in on.
  ({int legIndex, double t, double distDeg}) _projectToPath(
      double pitch, double roll) {
    while (_currentLegIndex < _legs.length - 1) {
      final leg = _legs[_currentLegIndex];
      final dp = pitch - leg.p1;
      final dr = roll - leg.r1;
      if (math.sqrt(dp * dp + dr * dr) <= _stillLockThresholdDeg) {
        _currentLegIndex++;
      } else {
        break;
      }
    }
    final leg = _legs[_currentLegIndex];
    final dx = leg.p1 - leg.p0;
    final dy = leg.r1 - leg.r0;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0
        ? 0.0
        : (((pitch - leg.p0) * dx + (roll - leg.r0) * dy) / len2);
    t = t.clamp(0.0, 1.0);
    final projP = leg.p0 + t * dx;
    final projR = leg.r0 + t * dy;
    final dp = pitch - projP;
    final dr = roll - projR;
    final dist = math.sqrt(dp * dp + dr * dr);
    return (legIndex: _currentLegIndex, t: t, distDeg: dist);
  }

  // ── Frame binning ──────────────────────────────────────────────────────────

  bool _binFilled(int bin) =>
      _bestAmbientPerBin.containsKey(bin) || _bestFlashPerBin.containsKey(bin);

  int _filledBinCount() {
    var n = 0;
    for (var b = 0; b < _totalBins; b++) {
      if (_binFilled(b)) n++;
    }
    return n;
  }

  void _binFrame(CameraImage image, double sharpness, double brightness,
      ({int legIndex, double t, double distDeg}) proj) {
    // Slow-motion gate: only accept frames while the phone is turning gently.
    // A fast turn is both motion-blurred and poorly registered, and lets a
    // tester rush the sweep — rejecting those frames is what enforces the
    // deliberate pace the arc is supposed to have.
    if (_gyroMagnitude > _maxSweepSpeedRadPerSec) return;

    // No binning while the lens is hunting between legs.
    if (_refocusing) return;

    // Thumb-coverage gate (fail-open on stale/absent detection): frames where
    // the thumb is too small or overflowing the frame don't count, same
    // 0.35–0.85 window the 4-angle screen enforces.
    final covAt = _lastCoverageAt;
    if (covAt != null &&
        DateTime.now().difference(covAt).inMilliseconds < _coverageStaleMs &&
        (_lastCoverage < _coverageMin || _lastCoverage > _coverageMax)) {
      return;
    }

    if (proj.distDeg > _offPathThresholdDeg) return;

    final binInLeg = (proj.t * _binsPerLeg).floor().clamp(0, _binsPerLeg - 1);
    final bin = proj.legIndex * _binsPerLeg + binInLeg;

    // Score with the stable (torch-off) brightness during torch-lit frames so
    // torch light can't inflate a frame's score — same trick as the 4-angle
    // burst path (_lastStableBrightness).
    final flashOn = _flash?.isFlashOn ?? false;
    final scoredBrightness = flashOn ? _lastStableBrightness : brightness;
    final brightnessScore = _mapBrightnessScore(scoredBrightness);
    final score = sharpness * 0.6 + brightnessScore * 0.4;
    if (score < 0.05) return; // discard near-black / severely-blurred frames

    final bins = flashOn ? _bestFlashPerBin : _bestAmbientPerBin;
    final existing = bins[bin];
    if (existing == null || score > existing.score) {
      final crop = _extractRoiBytes(image);
      if (crop != null) {
        bins[bin] = _BinFrame(
          bytes: crop.bytes,
          width: crop.width,
          height: crop.height,
          score: score,
          sharpness: sharpness,
          pitchDeg: _sweepPitchDeg,
          rollDeg: _sweepRollDeg,
          timestamp: DateTime.now(),
          flashOn: flashOn,
          flashIntensity: _flash?.intensity ?? 0.0,
        );
      }
    }

    if (!_complete && _allLegsCovered()) {
      _complete = true;
      unawaited(_finishAndUpload());
    }
  }

  bool _allLegsCovered() {
    for (var leg = 0; leg < _legs.length; leg++) {
      var count = 0;
      final base = leg * _binsPerLeg;
      for (var b = base; b < base + _binsPerLeg; b++) {
        if (_binFilled(b)) count++;
      }
      if (count < _minBinsPerLegToComplete) return false;
    }
    return true;
  }

  // ── Upload ─────────────────────────────────────────────────────────────────

  Future<void> _finishAndUpload() async {
    _sweepActive = false;
    _flash?.deactivate();
    // Restore neutral EV for whatever uses the camera next.
    final cam = _camera;
    if (cam != null && cam.value.isInitialized && _appliedEvOffset != 0.0) {
      try {
        await cam.setExposureOffset(0.0);
      } catch (_) {}
    }
    _set(_state.copyWith(phase: ArcSweepPhase.uploading, uploadProgress: 0.0));
    await _stopStream();

    final upload = _upload;
    final userId = _userId;
    if (upload == null || userId == null) return;

    try {
      // Assemble: per-bin frames (ambient first, then torch-lit) in bin
      // order, then the checkpoint stills. Stills are tagged onto their
      // leg's final bin so filenames stay within the frame_{N}_arc_{bin}
      // contract; 'still': true in metadata distinguishes them.
      final frameBytes = <Uint8List>[];
      final arcAngles = <double>[];
      final frameMetadata = <Map<String, dynamic>>[];

      void addEntry({
        required Uint8List bytes,
        required int width,
        required int height,
        required int bin,
        required double pitch,
        required double roll,
        required bool flashOn,
        required double flashIntensity,
        required DateTime timestamp,
        double? laplacianScore,
        bool still = false,
      }) {
        frameBytes.add(bytes);
        arcAngles.add(pitch);
        frameMetadata.add(<String, dynamic>{
          'pitchDeg': pitch,
          'rollDeg': roll,
          'binIndex': bin,
          'legIndex': bin ~/ _binsPerLeg,
          if (laplacianScore != null) 'laplacianScore': laplacianScore,
          'flashOn': flashOn,
          'flashIntensity': flashIntensity,
          'still': still,
          'thumbCoverageRatio':
              double.parse(_lastCoverage.toStringAsFixed(3)),
          'evOffsetApplied': _appliedEvOffset,
          'timestamp': timestamp.toIso8601String(),
          // `bytes` is a real JPEG (see _encodeGrayscaleJpeg /
          // _decodeJpegToBufferLuma) — decodes directly server-side, no raw-
          // buffer reshape needed. Dimensions are carried here only for
          // diagnostics/logging, not as a decode instruction.
          'imageWidth': width,
          'imageHeight': height,
        });
      }

      for (var bin = 0; bin < _totalBins; bin++) {
        for (final bins in [_bestAmbientPerBin, _bestFlashPerBin]) {
          final f = bins[bin];
          if (f == null) continue;
          addEntry(
            bytes: f.bytes,
            width: f.width,
            height: f.height,
            bin: bin,
            pitch: f.pitchDeg,
            roll: f.rollDeg,
            flashOn: f.flashOn,
            flashIntensity: f.flashIntensity,
            timestamp: f.timestamp,
            laplacianScore: f.sharpness,
          );
        }
      }
      for (final s in _stills) {
        addEntry(
          bytes: s.bytes,
          width: s.width,
          height: s.height,
          bin: s.legIndex * _binsPerLeg + _binsPerLeg - 1,
          pitch: s.pitchDeg,
          roll: s.rollDeg,
          flashOn: s.flashOn,
          flashIntensity: s.flashIntensity,
          timestamp: s.timestamp,
          still: true,
        );
      }

      HapticFeedback.heavyImpact();

      final captureId = await upload.uploadArcAndProcess(
        frameBytes,
        arcAngles: arcAngles,
        userId: userId,
        frameMetadata: frameMetadata,
        onProgress: (p) => _set(_state.copyWith(uploadProgress: p), notify: true),
      );

      _set(_state.copyWith(
        phase: ArcSweepPhase.complete,
        captureId: captureId,
        uploadProgress: 1.0,
      ));
    } catch (e) {
      _fail('Upload failed: $e');
    }
  }

  // ── Camera helpers ─────────────────────────────────────────────────────────

  Future<void> _beginAutofocus() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFocusMode(FocusMode.auto);
    } catch (_) {}
    try {
      await c.setFocusPoint(const Offset(0.5, 0.5));
    } catch (_) {}
  }

  Future<void> _lockFocusOnly() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFocusMode(FocusMode.locked);
    } catch (_) {}
  }

  Future<void> _stopStream() async {
    if (!_streamRunning) return;
    _streamRunning = false;
    try {
      await _camera?.stopImageStream();
    } catch (_) {}
  }

  void _fail(String message) {
    _flash?.deactivate();
    unawaited(_stopStream());
    _set(_state.copyWith(phase: ArcSweepPhase.error, error: message));
  }

  void _set(ArcSweepState next, {bool notify = true}) {
    _state = next;
    if (notify && !_disposed) notifyListeners();
  }

  // ── Image helpers ──────────────────────────────────────────────────────────

  static double _mapBrightnessScore(double brightness) {
    if (brightness < 60 || brightness > 220) return 0.0;
    if (brightness < 120) return (brightness - 60) / 60;
    if (brightness <= 180) return 1.0;
    return 1.0 - ((brightness - 180) / 40).clamp(0.0, 1.0);
  }

  /// Copies the [_uploadRoi] centre crop out of the Y plane, row by row with
  /// the device stride handled, then JPEG-encodes it. Cropping cuts over half
  /// the background pixels (better ridge resolution per uploaded byte, less
  /// for backend segmentation to strip) — but JPEG-encoding (rather than
  /// uploading the raw crop bytes) is what actually makes that crop
  /// *decodable* server-side: the backend's decoder tries a real image
  /// decode first and only falls back to matching the byte count against a
  /// short hardcoded list of standard full-frame camera resolutions. A
  /// crop's dimensions are an arbitrary fraction of the native resolution
  /// and essentially never land on one of those by chance — raw cropped
  /// bytes would silently fail to decode for every single frame. A real
  /// JPEG decodes directly regardless of its dimensions.
  ({Uint8List bytes, int width, int height})? _extractRoiBytes(
      CameraImage image) {
    if (image.planes.isEmpty) return null;
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final w = image.width;
      final h = image.height;
      if (w < 8 || h < 8) return null;
      // Same defensive stride cap as HybridCaptureService: some devices
      // report bytesPerRow > width but deliver a width×height buffer.
      final stride =
          h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;

      final x0 = (_uploadRoi.left * w).floor().clamp(0, w - 2);
      final x1 = (_uploadRoi.right * w).ceil().clamp(x0 + 1, w);
      final y0 = (_uploadRoi.top * h).floor().clamp(0, h - 2);
      final y1 = (_uploadRoi.bottom * h).ceil().clamp(y0 + 1, h);
      final cw = x1 - x0;
      final ch = y1 - y0;

      final out = Uint8List(cw * ch);
      for (var y = 0; y < ch; y++) {
        final srcStart = (y0 + y) * stride + x0;
        out.setRange(y * cw, (y + 1) * cw, bytes, srcStart);
      }
      final jpeg = _encodeGrayscaleJpeg(out, cw, ch);
      return (bytes: jpeg, width: cw, height: ch);
    } on RangeError {
      return null;
    } catch (e) {
      // JPEG encode failed for some other reason (OOM, corrupt buffer) —
      // drop this one frame rather than crash the sweep over it.
      debugPrint('[arc] JPEG encode failed for cropped frame: $e');
      return null;
    }
  }

  /// Encodes a dense (bytesPerRow == width) 8-bit grayscale buffer as JPEG.
  static Uint8List _encodeGrayscaleJpeg(Uint8List gray, int w, int h) {
    final image = imglib.Image.fromBytes(
      width: w,
      height: h,
      bytes: gray.buffer,
      numChannels: 1,
    );
    return Uint8List.fromList(imglib.encodeJpg(image, quality: 90));
  }

  @override
  void dispose() {
    _disposed = true;
    _flash?.deactivate();
    _gyroSub?.cancel();
    _landmarker.dispose();
    unawaited(_stopStream());
    super.dispose();
  }
}

class _BinFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final double score;
  final double sharpness;
  final double pitchDeg;
  final double rollDeg;
  final DateTime timestamp;
  final bool flashOn;
  final double flashIntensity;

  const _BinFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.score,
    required this.sharpness,
    required this.pitchDeg,
    required this.rollDeg,
    required this.timestamp,
    required this.flashOn,
    required this.flashIntensity,
  });
}

class _StillFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final double pitchDeg;
  final double rollDeg;
  final int legIndex;
  final DateTime timestamp;
  final bool flashOn;
  final double flashIntensity;

  const _StillFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.pitchDeg,
    required this.rollDeg,
    required this.legIndex,
    required this.timestamp,
    required this.flashOn,
    required this.flashIntensity,
  });
}

final arcSweepCaptureControllerProvider =
    ChangeNotifierProvider.autoDispose<ArcSweepCaptureController>(
  (ref) => ArcSweepCaptureController(),
);
