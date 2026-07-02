import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'adaptive_flash_controller.dart';
import 'arc_capture_uploader.dart';
import 'frame_capture_service.dart';

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
  final int binsFilledCount;    // how many path bins have a qualifying frame
  final int filledBinMask;      // bitmask of which of the 18 path bins are filled
  final bool tooFast;           // phone turning too fast to bin — show "slow down"
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
    this.binsFilledCount = 0,
    this.filledBinMask = 0,
    this.tooFast = false,
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
    int? binsFilledCount,
    int? filledBinMask,
    bool? tooFast,
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
        binsFilledCount: binsFilledCount ?? this.binsFilledCount,
        filledBinMask: filledBinMask ?? this.filledBinMask,
        tooFast: tooFast ?? this.tooFast,
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
/// Frames only bin while the phone is turning slowly (a gyro speed gate) — a
/// fast, blurry, poorly-registered sweep fills nothing, which is what stops
/// testers blasting straight through instead of sweeping deliberately.
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

  // ── State ─────────────────────────────────────────────────────────────────
  CameraController? _camera;
  AdaptiveFlashController? _flash;
  ArcCaptureUploader? _upload;
  String? _userId;

  ArcSweepState _state = const ArcSweepState();
  ArcSweepState get state => _state;

  bool _disposed = false;
  bool _streamRunning = false;
  bool _calibrated = false;
  bool _sweepActive = false;
  bool _complete = false;

  // Gyro
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final Queue<double> _gyroHistory = Queue();
  double _gyroMagnitude = 0.0;

  final _hybrid = HybridCaptureService();

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

  // Frame bins: global bin id (leg * _binsPerLeg + binInLeg) → best frame so far
  final Map<int, _BinFrame> _bestPerBin = {};

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
    if (_streamRunning) return;
    _camera = camera;
    _upload = uploadService;
    _userId = userId;
    _flash = AdaptiveFlashController(camera);

    _bestPerBin.clear();
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
      await camera.startImageStream(_onFrame);
      _streamRunning = true;
    } catch (e) {
      _fail('Could not start camera stream: $e');
    }
  }

  // ── Stream processing ──────────────────────────────────────────────────────

  void _onFrame(CameraImage image) {
    if (_disposed) return;
    final phase = _state.phase;
    if (phase != ArcSweepPhase.calibrating && phase != ArcSweepPhase.sweeping) return;

    final brightness = HybridCaptureService.meanLuma(image);
    final lightingNorm = (brightness / 255.0).clamp(0.0, 1.0);
    final rawFocus = _hybrid.offerFrame(image);
    if (rawFocus > _focusPeak) _focusPeak = rawFocus;
    _focusPeak *= 0.999;
    final focusNorm = (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0);
    final lighting = HybridCaptureService.ema(_state.lightingValue, lightingNorm);
    final focus = HybridCaptureService.ema(_state.focusValue, focusNorm);

    _rawFocusHistory.add(rawFocus);
    if (_rawFocusHistory.length > _focusHistoryLen) _rawFocusHistory.removeAt(0);

    if (phase == ArcSweepPhase.calibrating) {
      _brightnessSamples.add(brightness);
      _runCalibration(rawFocus);
    } else if (_sweepActive && !_complete) {
      _binFrame(image, rawFocus, brightness);
    }

    _emitMeters(lighting, focus);
  }

  void _emitMeters(double lighting, double focus) {
    final now = DateTime.now();
    final proj = _projectToPath(_sweepPitchDeg, _sweepRollDeg);
    var mask = 0;
    for (final k in _bestPerBin.keys) {
      if (k >= 0 && k < _totalBins) mask |= (1 << k);
    }
    final next = _state.copyWith(
      lightingValue: lighting,
      focusValue: focus,
      flashOn: _flash?.isFlashOn ?? false,
      flashIntensity: _flash?.intensity ?? 0.0,
      pathFraction: (proj.legIndex + proj.t) / _legs.length,
      activeLegIndex: proj.legIndex,
      binsFilledCount: _bestPerBin.length,
      filledBinMask: mask,
      tooFast: _sweepActive && _gyroMagnitude > _maxSweepSpeedRadPerSec,
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

    // Torch on for the entire sweep if the scene is dark.
    _flash?.activate();

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

  // ── Path projection ─────────────────────────────────────────────────────────

  /// Projects a (pitch, roll) sample onto the nearest point of the nearest
  /// leg of the front→left→top→right path. Returns the leg index, the
  /// position along that leg (0..1), and the perpendicular distance in
  /// degrees (used as an off-path sanity gate).
  ({int legIndex, double t, double distDeg}) _projectToPath(
      double pitch, double roll) {
    var bestLeg = 0;
    var bestT = 0.0;
    var bestDist = double.infinity;
    for (var i = 0; i < _legs.length; i++) {
      final leg = _legs[i];
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
      if (dist < bestDist) {
        bestDist = dist;
        bestLeg = i;
        bestT = t;
      }
    }
    return (legIndex: bestLeg, t: bestT, distDeg: bestDist);
  }

  // ── Frame binning ──────────────────────────────────────────────────────────

  void _binFrame(CameraImage image, double sharpness, double brightness) {
    // Slow-motion gate: only accept frames while the phone is turning gently.
    // A fast turn is both motion-blurred and poorly registered, and lets a
    // tester rush the sweep — rejecting those frames is what enforces the
    // deliberate pace the arc is supposed to have.
    if (_gyroMagnitude > _maxSweepSpeedRadPerSec) return;

    final proj = _projectToPath(_sweepPitchDeg, _sweepRollDeg);
    if (proj.distDeg > _offPathThresholdDeg) return;

    final binInLeg = (proj.t * _binsPerLeg).floor().clamp(0, _binsPerLeg - 1);
    final bin = proj.legIndex * _binsPerLeg + binInLeg;

    final brightnessScore = _mapBrightnessScore(brightness);
    final score = sharpness * 0.6 + brightnessScore * 0.4;
    if (score < 0.05) return; // discard near-black / severely-blurred frames

    final existing = _bestPerBin[bin];
    if (existing == null || score > existing.score) {
      final bytes = _extractBytes(image);
      if (bytes != null) {
        _bestPerBin[bin] = _BinFrame(
          bytes: bytes,
          score: score,
          sharpness: sharpness,
          pitchDeg: _sweepPitchDeg,
          rollDeg: _sweepRollDeg,
          timestamp: DateTime.now(),
          flashOn: _flash?.isFlashOn ?? false,
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
        if (_bestPerBin.containsKey(b)) count++;
      }
      if (count < _minBinsPerLegToComplete) return false;
    }
    return true;
  }

  // ── Upload ─────────────────────────────────────────────────────────────────

  Future<void> _finishAndUpload() async {
    _sweepActive = false;
    _flash?.deactivate();
    _set(_state.copyWith(phase: ArcSweepPhase.uploading, uploadProgress: 0.0));
    await _stopStream();

    final upload = _upload;
    final userId = _userId;
    if (upload == null || userId == null) return;

    try {
      final sortedBins = _bestPerBin.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));

      final frameBytes = sortedBins.map((e) => e.value.bytes).toList();
      // arcAngles carries pitch — the dominant axis for legs 0/2 and the
      // continuation point for leg 1 — for backend compatibility with the
      // existing single-angle-per-frame contract. Full pitch+roll travels in
      // frameMetadata for anything that wants the true 2-axis position.
      final arcAngles = sortedBins.map((e) => e.value.pitchDeg).toList();
      final frameMetadata = sortedBins
          .map((e) => <String, dynamic>{
                'pitchDeg': e.value.pitchDeg,
                'rollDeg': e.value.rollDeg,
                'binIndex': e.key,
                'legIndex': e.key ~/ _binsPerLeg,
                'laplacianScore': e.value.sharpness,
                'flashOn': e.value.flashOn,
                'flashIntensity': e.value.flashIntensity,
                'timestamp': e.value.timestamp.toIso8601String(),
              })
          .toList();

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

  Uint8List? _extractBytes(CameraImage image) {
    if (image.planes.isEmpty) return null;
    try {
      return Uint8List.fromList(image.planes[0].bytes);
    } on RangeError {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _flash?.deactivate();
    _gyroSub?.cancel();
    unawaited(_stopStream());
    super.dispose();
  }
}

class _BinFrame {
  final Uint8List bytes;
  final double score;
  final double sharpness;
  final double pitchDeg;
  final double rollDeg;
  final DateTime timestamp;
  final bool flashOn;
  final double flashIntensity;

  const _BinFrame({
    required this.bytes,
    required this.score,
    required this.sharpness,
    required this.pitchDeg,
    required this.rollDeg,
    required this.timestamp,
    required this.flashOn,
    required this.flashIntensity,
  });
}

final arcSweepCaptureControllerProvider =
    ChangeNotifierProvider.autoDispose<ArcSweepCaptureController>(
  (ref) => ArcSweepCaptureController(),
);
