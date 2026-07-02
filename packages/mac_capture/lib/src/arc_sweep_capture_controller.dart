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

class ArcSweepState {
  final ArcSweepPhase phase;
  final double sweepAngleDeg;   // total angle swept so far (gyro-integrated)
  final int binsFilledCount;    // how many 25° bins have a qualifying frame
  final double lightingValue;   // 0.0-1.0 EMA
  final double focusValue;      // 0.0-1.0 EMA
  final bool flashOn;
  final double flashIntensity;
  final double uploadProgress;
  final String? captureId;
  final String? error;

  const ArcSweepState({
    this.phase = ArcSweepPhase.idle,
    this.sweepAngleDeg = 0.0,
    this.binsFilledCount = 0,
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
    double? sweepAngleDeg,
    int? binsFilledCount,
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
        sweepAngleDeg: sweepAngleDeg ?? this.sweepAngleDeg,
        binsFilledCount: binsFilledCount ?? this.binsFilledCount,
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
/// The user holds the phone in portrait and sweeps it around a stationary
/// thumb. The total angular velocity is integrated from the gyroscope to
/// measure how much of the arc has been covered. Frames are binned into 25°
/// windows; the sharpest frame per bin is retained. When 8 bins (200°) are
/// filled the session auto-completes and uploads.
///
/// Unlike MultiAngleCaptureController there is no MediaPipe or per-angle
/// hold-steady gate — the user just sweeps continuously at a comfortable speed.
class ArcSweepCaptureController extends ChangeNotifier {
  ArcSweepCaptureController();

  // ── Constants ─────────────────────────────────────────────────────────────
  static const _binWidth = 25.0;     // degrees per bin
  static const _binCount = 9;        // 9 bins × 25° = 225° max span
  static const _arcTarget = 200.0;   // degrees to declare capture complete
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

  // Sweep angle derived from relative quaternion (degrees from sweep start)
  double _sweepAngleDeg = 0.0;
  DateTime? _lastGyroAt;

  // Frame bins: bin_index → best frame so far
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
    _sweepAngleDeg = 0.0;
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
        // Relative rotation: dq = q_current * q0.conjugate()
        // q0.conj = [q0w, -q0x, -q0y, -q0z]
        final rw =  _qw*_q0w + _qx*_q0x + _qy*_q0y + _qz*_q0z;
        final rx = -_qw*_q0x + _qx*_q0w + _qy*_q0z - _qz*_q0y;
        final ry = -_qw*_q0y - _qx*_q0z + _qy*_q0w + _qz*_q0x;
        final rz = -_qw*_q0z + _qx*_q0y - _qy*_q0x + _qz*_q0w;
        // Total rotation angle (axis-angle magnitude): θ = 2·asin(|sin(θ/2)|)
        final sinHalf = math.sqrt(rx*rx + ry*ry + rz*rz).clamp(0.0, 1.0);
        _sweepAngleDeg = 2.0 * math.asin(sinHalf) * 180.0 / math.pi;
      }
    });

    _set(_state.copyWith(
      phase: ArcSweepPhase.calibrating,
      sweepAngleDeg: 0.0,
      binsFilledCount: 0,
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
    final next = _state.copyWith(
      lightingValue: lighting,
      focusValue: focus,
      flashOn: _flash?.isFlashOn ?? false,
      flashIntensity: _flash?.intensity ?? 0.0,
      sweepAngleDeg: _sweepAngleDeg,
      binsFilledCount: _bestPerBin.length,
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
      sweepAngleDeg: 0.0,
      binsFilledCount: 0,
    ));
  }

  // ── Frame binning ──────────────────────────────────────────────────────────

  void _binFrame(CameraImage image, double sharpness, double brightness) {
    final bin = (_sweepAngleDeg / _binWidth).floor().clamp(0, _binCount - 1);
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
          angleDeg: _sweepAngleDeg,
          timestamp: DateTime.now(),
          flashOn: _flash?.isFlashOn ?? false,
          flashIntensity: _flash?.intensity ?? 0.0,
        );
      }
    }

    if (_bestPerBin.length * _binWidth >= _arcTarget && !_complete) {
      _complete = true;
      unawaited(_finishAndUpload());
    }
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
      final arcAngles = sortedBins.map((e) => e.value.angleDeg).toList();
      final frameMetadata = sortedBins
          .map((e) => <String, dynamic>{
                'arcAngleDeg': e.value.angleDeg,
                'binIndex': e.key,
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
  final double angleDeg;
  final DateTime timestamp;
  final bool flashOn;
  final double flashIntensity;

  const _BinFrame({
    required this.bytes,
    required this.score,
    required this.sharpness,
    required this.angleDeg,
    required this.timestamp,
    required this.flashOn,
    required this.flashIntensity,
  });
}

final arcSweepCaptureControllerProvider =
    ChangeNotifierProvider.autoDispose<ArcSweepCaptureController>(
  (ref) => ArcSweepCaptureController(),
);
