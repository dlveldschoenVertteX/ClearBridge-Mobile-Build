import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image/image.dart' as img;
import 'package:mac_capture/mac_capture.dart';

import 'package:clearbridge_beta/front_burst_uploader.dart';

// ─── Public state types ───────────────────────────────────────────────────────

enum FrontBurstPhase {
  idle,
  calibrating, // real focus-quality gate (mirrors MultiAngleCaptureController)
  capturing,   // single pass: 6 quality-gated shots (3 torch + 3 ambient)
  uploading,
  done,
  error,
}

class FrontBurstState {
  final FrontBurstPhase phase;
  final String message;
  final double progress;
  final double focusValue;         // 0–1 normalized Laplacian, EMA smoothed
  final double thumbCoverageRatio; // live, best-effort (ML may be unavailable)
  final bool isFocusLocked;
  final bool isRetrying;           // brief flash when a slot yields no frame
  final int capturedCount;         // 0..totalShots — drives the burst ring
  final String? captureId;
  final String? error;

  const FrontBurstState({
    this.phase = FrontBurstPhase.idle,
    this.message = '',
    this.progress = 0,
    this.focusValue = 0,
    this.thumbCoverageRatio = 0,
    this.isFocusLocked = false,
    this.isRetrying = false,
    this.capturedCount = 0,
    this.captureId,
    this.error,
  });

  FrontBurstState copyWith({
    FrontBurstPhase? phase,
    String? message,
    double? progress,
    double? focusValue,
    double? thumbCoverageRatio,
    bool? isFocusLocked,
    bool? isRetrying,
    int? capturedCount,
    String? captureId,
    String? error,
  }) =>
      FrontBurstState(
        phase: phase ?? this.phase,
        message: message ?? this.message,
        progress: progress ?? this.progress,
        focusValue: focusValue ?? this.focusValue,
        thumbCoverageRatio: thumbCoverageRatio ?? this.thumbCoverageRatio,
        isFocusLocked: isFocusLocked ?? this.isFocusLocked,
        isRetrying: isRetrying ?? this.isRetrying,
        capturedCount: capturedCount ?? this.capturedCount,
        captureId: captureId ?? this.captureId,
        error: error ?? this.error,
      );
}

// ─── Isolate payload for the final JPEG crop+encode ──────────────────────────

class _CropEncodeInput {
  final Uint8List yPlane;
  final int width;
  final int height;
  final int bytesPerRow;
  const _CropEncodeInput({
    required this.yPlane,
    required this.width,
    required this.height,
    required this.bytesPerRow,
  });
}

// ─── Controller ──────────────────────────────────────────────────────────────

/// Single-pass front-only capture: 6 quality-gated shots (3 torch/ambient
/// pairs) at whatever pose the user is already holding, then the single
/// sharpest frame is uploaded. No angle-anchoring, no second pass — the
/// live focus/quality pipeline (same [HybridCaptureService] the ARC and
/// four-angle flows use) is what keeps every shot in focus, not a timer.
class FrontBurstCaptureController extends ChangeNotifier {
  static const int _totalShots = 6; // 3 torch + 3 ambient pairs
  // Crop: keep centre 50% × 60% of the winning frame before upload.
  static const double _cx0 = 0.25, _cx1 = 0.75;
  static const double _cy0 = 0.20, _cy1 = 0.80;

  // Calibration quality gate (mirrors MultiAngleCaptureController).
  static const int _calibDurationMs = 2500;
  static const int _focusHistoryLen = 5;
  static const double _focusStabilityRatio = 0.15;
  static const double _focusMinAbsolute = 130.0;
  static const int _detectThrottleMs = 90;
  static const int _emitThrottleMs = 80;

  final _camera = CameraService();
  final _orientation = DeviceOrientationService();
  final _landmarker = ThumbLandmarkerService();
  final _hybrid = HybridCaptureService();
  final _audio = CaptureAudioService();

  int _sensorOrientation = 90;
  Rect? _lastThumbRoi;
  double _liveCoverage = 0.0;
  double _focusPeak = 1.0;
  bool _flashOn = false;
  double _flashIntensity = 0.0;
  DateTime? _lastDetectAt;
  DateTime? _lastEmitAt;
  DateTime? _calibStart;
  bool _calibrated = false;
  bool _disposed = false;
  final List<double> _rawFocusHistory = [];
  Completer<void>? _calibCompleter;

  FrontBurstState _state = const FrontBurstState();
  FrontBurstState get state => _state;

  // Exposed so the screen can build a CameraPreview widget.
  CameraController? get cameraController => _camera.controller;

  void _emit(FrontBurstState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  // ─── Entry point ─────────────────────────────────────────────────────────

  Future<void> start(String userId, {required FrontBurstUploader uploader}) async {
    if (_state.phase != FrontBurstPhase.idle &&
        _state.phase != FrontBurstPhase.error &&
        _state.phase != FrontBurstPhase.done) return;
    _emit(const FrontBurstState());
    try {
      await _run(userId, uploader);
    } catch (e, st) {
      debugPrint('[FrontBurst] fatal: $e\n$st');
      _emit(_state.copyWith(phase: FrontBurstPhase.error, error: e.toString()));
    }
  }

  Future<void> _run(String userId, FrontBurstUploader uploader) async {
    await _audio.init();
    _orientation.start();
    _landmarker.initialize();
    await _camera.initializeCamera(
      lensDirection: CameraLensDirection.back,
      // Max sensor resolution per spec — more source detail for the single
      // winning frame that gets uploaded.
      resolution: ResolutionPreset.max,
    );
    _sensorOrientation = _camera.selectedCamera?.sensorOrientation ?? 90;

    // ─ Calibration: real focus-quality gate ───────────────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.calibrating,
      message: 'Hold thumb steady…',
    ));
    _calibStart = DateTime.now();
    _calibrated = false;
    _calibCompleter = Completer<void>();
    final camera = _camera.controller!;
    await camera.setFocusMode(FocusMode.auto);
    await _camera.startImageStream(_onFrame);
    await _calibCompleter!.future;

    await _camera.enableCaptureLock();
    _orientation.captureReference();
    HapticFeedback.mediumImpact();
    _emit(_state.copyWith(isFocusLocked: true));

    // ─ Single pass: 6 quality-gated shots ──────────────────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.capturing,
      message: 'Capturing…',
      progress: 0,
      capturedCount: 0,
    ));
    final shots = <TaggedFrame>[];
    for (int i = 0; i < _totalShots; i++) {
      final torchOn = i.isEven; // alternate torch/ambient
      final frame = await _captureOne(torchOn: torchOn, zoneId: 'front_$i');
      if (frame != null) {
        shots.add(frame);
        HapticFeedback.lightImpact();
      } else {
        _emit(_state.copyWith(isRetrying: true));
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          if (!_disposed) _emit(_state.copyWith(isRetrying: false));
        });
      }
      _emit(_state.copyWith(
        capturedCount: i + 1,
        progress: (i + 1) / _totalShots,
      ));
    }
    await _camera.stopImageStream();
    HapticFeedback.heavyImpact();
    await _audio.playAngleSuccess(isFinal: true);

    if (shots.isEmpty) {
      throw Exception(
        'No qualifying frames captured — try better lighting or hold steadier.',
      );
    }

    // ─ Pick the single sharpest frame ──────────────────────────────────────
    final best = shots.reduce(
      (a, b) => a.laplacianScore > b.laplacianScore ? a : b,
    );

    // ─ Crop + upload ────────────────────────────────────────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.uploading,
      message: 'Uploading…',
      progress: 0.3,
    ));
    final jpeg = await compute<_CropEncodeInput, Uint8List>(
      _cropEncodeIsolate,
      _CropEncodeInput(
        yPlane: best.bytes,
        width: best.imageWidth,
        height: best.imageHeight,
        bytesPerRow: best.bytesPerRow,
      ),
    );

    final captureId = await uploader.uploadAndProcess(
      jpeg,
      userId: userId,
      frameMetadata: {
        'frameIndex': 1,
        'torchOn': best.flashOn,
        'torchIntensity': best.flashIntensity,
        'laplacianScore': double.parse(best.laplacianScore.toStringAsFixed(1)),
        'thumbCoverageRatio': double.parse(best.thumbCoverageRatio.toStringAsFixed(3)),
        'devicePitchDeg': double.parse(best.thumbAngleDegrees.toStringAsFixed(2)),
        'timestamp': best.timestamp.toIso8601String(),
        'cropRegion': {'x0': _cx0, 'x1': _cx1, 'y0': _cy0, 'y1': _cy1},
        'shotsAttempted': _totalShots,
        'shotsQualified': shots.length,
        if (best.thumbRoi != null)
          'thumbRoi': {
            'left': best.thumbRoi!.left,
            'top': best.thumbRoi!.top,
            'right': best.thumbRoi!.right,
            'bottom': best.thumbRoi!.bottom,
          },
      },
    );

    _emit(_state.copyWith(
      phase: FrontBurstPhase.done,
      captureId: captureId,
      message: 'Complete — $captureId',
      progress: 1,
    ));
  }

  // ─── Live stream callback ──────────────────────────────────────────────────

  void _onFrame(CameraImage image) {
    if (_disposed) return;

    final now = DateTime.now();
    if (_lastDetectAt == null ||
        now.difference(_lastDetectAt!).inMilliseconds >= _detectThrottleMs) {
      _lastDetectAt = now;
      try {
        final hands = _landmarker.detect(image, _sensorOrientation);
        if (hands.isNotEmpty && hands.first.landmarks.length >= 5) {
          final wrist = hands.first.landmarks[0];
          final tip = hands.first.landmarks[4];
          _liveCoverage = (tip.y - wrist.y).abs().clamp(0.0, 1.0);
          _lastThumbRoi = _computeThumbRoi(
            hands.first.landmarks,
            image.width.toDouble(),
            image.height.toDouble(),
          );
        } else {
          _liveCoverage = 0.0;
          _lastThumbRoi = null;
        }
      } catch (_) {}
    }

    _hybrid.updateFlashState(flashOn: _flashOn, intensity: _flashIntensity);
    double rawFocus;
    try {
      rawFocus = _hybrid.offerFrame(image, thumbRoi: _lastThumbRoi);
    } catch (e) {
      debugPrint('[FrontBurst] offerFrame threw $e');
      rawFocus = 0.0;
    }
    if (rawFocus > _focusPeak) _focusPeak = rawFocus;
    _focusPeak *= 0.97;
    final focusNorm = (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0);
    final focus = HybridCaptureService.ema(_state.focusValue, focusNorm);

    if (!_calibrated) {
      _rawFocusHistory.add(rawFocus);
      if (_rawFocusHistory.length > _focusHistoryLen) _rawFocusHistory.removeAt(0);
      _maybeFinalizeCalibration(rawFocus, now);
    }

    if (_lastEmitAt == null ||
        now.difference(_lastEmitAt!).inMilliseconds >= _emitThrottleMs) {
      _lastEmitAt = now;
      _emit(_state.copyWith(
        focusValue: focus,
        thumbCoverageRatio: _liveCoverage,
        message: _guidanceMessage(),
      ));
    } else {
      _state = _state.copyWith(focusValue: focus, thumbCoverageRatio: _liveCoverage);
    }
  }

  String _guidanceMessage() {
    if (_calibrated) return _state.message;
    if (_liveCoverage > 0 && _liveCoverage < 0.35) return 'Move closer';
    if (_liveCoverage > 0.85) return 'Move further away';
    return 'Hold thumb steady…';
  }

  void _maybeFinalizeCalibration(double rawFocus, DateTime now) {
    if (_calibrated) return;
    final stable = _rawFocusHistory.length == _focusHistoryLen &&
        rawFocus >= _focusMinAbsolute &&
        _isFocusStable();
    final timedOut = _calibStart != null &&
        now.difference(_calibStart!).inMilliseconds >= _calibDurationMs;
    if (stable || timedOut) {
      _calibrated = true;
      final c = _calibCompleter;
      if (c != null && !c.isCompleted) c.complete();
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

  // ─── One quality-gated shot, with bounded in-place retries ───────────────

  // A single 700ms window can legitimately come back empty (hand tremor,
  // AE still settling, a transient focus hunt) without the thumb actually
  // being out of range — retrying the same slot a couple of times before
  // giving up on it recovers most of those instead of silently burning
  // through all 6 slots and ending up with too few usable frames.
  static const int _maxAttemptsPerShot = 3;

  Future<TaggedFrame?> _captureOne({
    required bool torchOn,
    required String zoneId,
  }) async {
    for (int attempt = 0; attempt < _maxAttemptsPerShot; attempt++) {
      final frame = await _captureWindow(torchOn: torchOn, zoneId: '${zoneId}_a$attempt');
      if (frame != null) return frame;
      if (attempt < _maxAttemptsPerShot - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return null;
  }

  Future<TaggedFrame?> _captureWindow({
    required bool torchOn,
    required String zoneId,
  }) async {
    final camera = _camera.controller!;
    try {
      await camera.setFlashMode(torchOn ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
    _flashOn = torchOn;
    _flashIntensity = torchOn ? 1.0 : 0.0;

    // Steer AF to the thumb ROI centre before each quality window so the
    // camera re-runs a one-shot focus scan at exactly the right spot instead
    // of using whatever locked position it had from calibration.
    if (_lastThumbRoi != null) {
      try {
        await camera.setFocusPoint(Offset(
          (_lastThumbRoi!.left + _lastThumbRoi!.right) / 2,
          (_lastThumbRoi!.top + _lastThumbRoi!.bottom) / 2,
        ));
      } catch (_) {}
    }
    try {
      await camera.setFocusMode(FocusMode.auto);
    } catch (_) {}
    // Allow AE + AF to converge after torch switch and focus scan.
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final pitchNow = _orientation.relativeOrientation().pitch;
    final frames = await _hybrid.captureAngleBurst(
      zoneId: zoneId,
      thumbAngleDegrees: pitchNow,
      targetAngleDegrees: 0.0,
      thumbCoverageRatio: _liveCoverage,
    );

    if (torchOn) {
      try { await camera.setFlashMode(FlashMode.off); } catch (_) {}
      _flashOn = false;
      _flashIntensity = 0.0;
    }
    return frames.isNotEmpty ? frames.first : null;
  }

  Rect? _computeThumbRoi(List<Landmark> landmarks, double imgW, double imgH) {
    if (landmarks.length < 5) return null;
    try {
      final tip = landmarks[4];
      final base = landmarks[1];
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

  // ─── Crop + JPEG encode (isolate) ────────────────────────────────────────

  static Uint8List _cropEncodeIsolate(_CropEncodeInput input) {
    final bytes = input.yPlane;
    final w = input.width, h = input.height, stride = input.bytesPerRow;
    final x0 = (w * _cx0).round().clamp(0, w - 1);
    final y0 = (h * _cy0).round().clamp(0, h - 1);
    final x1 = (w * _cx1).round().clamp(x0 + 1, w);
    final y1 = (h * _cy1).round().clamp(y0 + 1, h);
    final cropW = x1 - x0, cropH = y1 - y0;

    final out = img.Image(width: cropW, height: cropH);
    for (int y = 0; y < cropH; y++) {
      final row = (y0 + y) * stride;
      for (int x = 0; x < cropW; x++) {
        final idx = row + x0 + x;
        final l = idx < bytes.length ? bytes[idx] : 0;
        out.setPixelRgb(x, y, l, l, l);
      }
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 92));
  }

  // ─── Cleanup ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _audio.dispose();
    _orientation.dispose();
    _landmarker.dispose();
    _hybrid.reset();
    _camera.disposeCamera();
    super.dispose();
  }
}
