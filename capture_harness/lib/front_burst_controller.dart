import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image/image.dart' as img;
import 'package:mac_capture/mac_capture.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

// ─── Public state types ───────────────────────────────────────────────────────

enum FrontBurstPhase {
  idle,
  calibrating, // real focus-quality gate (mirrors MultiAngleCaptureController)
  scanning,    // pass 1: 8 torch+ambient pairs, finds the sharpest device pitch
  focusing,    // pass 2: 10 pairs held within ±5° of that pitch
  uploading,
  done,
  error,
}

class FrontBurstState {
  final FrontBurstPhase phase;
  final String message;
  final double progress;           // 0–1 within current phase
  final double focusValue;         // 0–1 normalized Laplacian, EMA smoothed
  final double thumbCoverageRatio; // live, best-effort (ML may be unavailable)
  final bool isFocusLocked;
  final bool isRetrying;           // brief flash when a slot yields no frame
  final int pass1Done;             // 0–8
  final int pass2Done;             // 0–10
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
    this.pass1Done = 0,
    this.pass2Done = 0,
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
    int? pass1Done,
    int? pass2Done,
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
        pass1Done: pass1Done ?? this.pass1Done,
        pass2Done: pass2Done ?? this.pass2Done,
        captureId: captureId ?? this.captureId,
        error: error ?? this.error,
      );
}

// ─── Isolate payload for the final JPEG encode (top-3 frames only) ───────────

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

/// Front-only burst training-data capture.
///
/// Unlike a naive "fire takePicture() on a timer" approach, this reuses the
/// exact same real-time quality pipeline as [MultiAngleCaptureController]:
/// the image stream never stops, [HybridCaptureService] scores every frame's
/// Laplacian sharpness live, and each capture slot opens a short buffered
/// window over that live stream — keeping only frames that clear the quality
/// floor — instead of blindly snapping a JPEG whenever the lens happens to be
/// hunting for focus.
class FrontBurstController extends ChangeNotifier {
  // — Spec constants ———————————————————————————————————————————————————————
  static const int _pass1Count = 8;
  static const int _pass2Count = 10;
  static const double _angleTolDeg = 5.0;  // ±5° pass-2 filter
  static const double _madThreshold = 12.0; // MAD<12 on 16×16 ≈ SSIM>0.95
  static const int _uploadCount = 3;
  // Crop: keep centre 50% × 60% of each frame before upload.
  static const double _cx0 = 0.25, _cx1 = 0.75;
  static const double _cy0 = 0.20, _cy1 = 0.80;
  static const int _angleWaitMs = 3000; // pass-2 per-slot angle-hold wait

  // — Calibration quality gate (mirrors MultiAngleCaptureController) ————————
  static const int _calibDurationMs = 2500; // safety fallback; gate exits early
  static const int _focusHistoryLen = 5;
  static const double _focusStabilityRatio = 0.15; // max spread/max <= 15%
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
  final List<double> _rawFocusHistory = [];
  Completer<void>? _calibCompleter;

  FrontBurstState _state = const FrontBurstState();
  FrontBurstState get state => _state;

  // Exposed so the screen can build a CameraPreview widget.
  CameraController? get cameraController => _camera.controller;

  bool _disposed = false;

  void _emit(FrontBurstState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  // ─── Entry point ─────────────────────────────────────────────────────────

  Future<void> start(String userId) async {
    if (_state.phase != FrontBurstPhase.idle &&
        _state.phase != FrontBurstPhase.error &&
        _state.phase != FrontBurstPhase.done) return;
    _emit(const FrontBurstState());
    try {
      await _run(userId);
    } catch (e, st) {
      debugPrint('[FrontBurst] fatal: $e\n$st');
      _emit(_state.copyWith(phase: FrontBurstPhase.error, error: e.toString()));
    }
  }

  Future<void> _run(String userId) async {
    // ─ 1. Camera + services init ───────────────────────────────────────────
    await _audio.init();
    _orientation.start();
    _landmarker.initialize();
    await _camera.initializeCamera(
      lensDirection: CameraLensDirection.back,
      resolution: ResolutionPreset.high,
    );
    _sensorOrientation = _camera.selectedCamera?.sensorOrientation ?? 90;

    // ─ 2. Calibration: real focus-quality gate, not a blocking ML wait ────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.calibrating,
      message: 'Hold thumb steady…',
    ));
    _calibStart = DateTime.now();
    _calibrated = false;
    _calibCompleter = Completer<void>();
    await _camera.controller!.setFocusMode(FocusMode.auto);
    await _camera.startImageStream(_onFrame);
    await _calibCompleter!.future;

    await _camera.enableCaptureLock();
    _orientation.captureReference(); // zero: all pass angles relative to this
    HapticFeedback.mediumImpact();
    _emit(_state.copyWith(isFocusLocked: true));

    // ─ 3. Pass 1: 8 torch+ambient pairs, no angle filter ──────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.scanning,
      message: 'Pass 1 — scanning…',
      progress: 0,
      pass1Done: 0,
    ));
    final pass1 = <TaggedFrame>[];
    for (int i = 0; i < _pass1Count; i++) {
      pass1.addAll(await _captureSlotPair(zonePrefix: 'front1_$i'));
      _emit(_state.copyWith(pass1Done: i + 1, progress: (i + 1) / _pass1Count));
    }
    await _audio.playAngleSuccess(isFinal: false);
    HapticFeedback.heavyImpact();

    final bestPitch = _bestPitch(pass1);
    debugPrint('[FrontBurst] best pitch from pass 1: ${bestPitch.toStringAsFixed(1)}°');

    // ─ 4. Pass 2: 10 pairs within ±5° of best pitch ───────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.focusing,
      message: 'Pass 2 — focusing…',
      progress: 0,
      pass2Done: 0,
    ));
    final pass2 = <TaggedFrame>[];
    for (int i = 0; i < _pass2Count; i++) {
      final held = await _waitForPitch(bestPitch);
      if (held) {
        pass2.addAll(await _captureSlotPair(
          zonePrefix: 'front2_$i',
          targetPitch: bestPitch,
        ));
      } else {
        debugPrint('[FrontBurst] slot $i skipped — pitch out of tolerance');
      }
      _emit(_state.copyWith(pass2Done: i + 1, progress: (i + 1) / _pass2Count));
    }
    await _audio.playAngleSuccess(isFinal: false);
    HapticFeedback.heavyImpact();
    await _camera.stopImageStream();

    // ─ 5. Dedup → top-3 ────────────────────────────────────────────────────
    _emit(_state.copyWith(message: 'Selecting best frames…'));
    final all = [...pass1, ...pass2];
    if (all.isEmpty) {
      throw Exception(
        'No qualifying frames captured — try better lighting or hold steadier.',
      );
    }
    final deduped = _deduplicate(all);
    deduped.sort((a, b) => b.laplacianScore.compareTo(a.laplacianScore));
    final top = deduped.take(_uploadCount).toList();

    // ─ 6. Crop + upload ────────────────────────────────────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.uploading,
      message: 'Uploading ${top.length} frames…',
      progress: 0,
    ));
    final captureId = await _upload(
      userId: userId,
      top: top,
      bestPitch: bestPitch,
      pass1Total: pass1.length,
      pass2Total: pass2.length,
    );
    await _audio.playAngleSuccess(isFinal: true);

    _emit(_state.copyWith(
      phase: FrontBurstPhase.done,
      captureId: captureId,
      message: 'Complete — $captureId',
      progress: 1,
    ));
  }

  // ─── Live stream callback — never stops until pass 2 ends ─────────────────

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
      // Proximity tone only while still settling — silenced once locked/firing.
      if (!_calibrated) {
        _audio.updateGuidanceTone(45.0 * (1.0 - focusNorm));
      }
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
      _audio.silence();
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

  // ─── Capture a torch+ambient pair via the live quality-gated window ─────

  Future<List<TaggedFrame>> _captureSlotPair({
    required String zonePrefix,
    double? targetPitch,
  }) async {
    final out = <TaggedFrame>[];
    for (final torchOn in [true, false]) {
      final frames = await _captureOne(
        zoneId: '${zonePrefix}_${torchOn ? 'torch' : 'ambient'}',
        torchOn: torchOn,
        targetPitch: targetPitch ?? 0.0,
      );
      if (frames.isEmpty) {
        _emit(_state.copyWith(isRetrying: true));
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          if (!_disposed) _emit(_state.copyWith(isRetrying: false));
        });
      } else {
        out.add(frames.first);
        HapticFeedback.lightImpact();
      }
    }
    return out;
  }

  Future<List<TaggedFrame>> _captureOne({
    required String zoneId,
    required bool torchOn,
    required double targetPitch,
  }) async {
    final ctrl = _camera.controller!;
    try {
      await ctrl.setFlashMode(torchOn ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
    _flashOn = torchOn;
    _flashIntensity = torchOn ? 1.0 : 0.0;
    await Future<void>.delayed(const Duration(milliseconds: 180)); // exposure settle

    final pitchNow = _orientation.relativeOrientation().pitch;
    final frames = await _hybrid.captureAngleBurst(
      zoneId: zoneId,
      thumbAngleDegrees: pitchNow,
      targetAngleDegrees: targetPitch,
      thumbCoverageRatio: _liveCoverage,
    );

    if (torchOn) {
      try { await ctrl.setFlashMode(FlashMode.off); } catch (_) {}
      _flashOn = false;
      _flashIntensity = 0.0;
    }
    return frames;
  }

  Future<bool> _waitForPitch(double targetPitch) async {
    var waited = 0;
    while (waited < _angleWaitMs) {
      final pitch = _orientation.relativeOrientation().pitch;
      if ((pitch - targetPitch).abs() <= _angleTolDeg) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      waited += 150;
    }
    final pitch = _orientation.relativeOrientation().pitch;
    return (pitch - targetPitch).abs() <= _angleTolDeg;
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

  // ─── Best angle selection ─────────────────────────────────────────────────

  double _bestPitch(List<TaggedFrame> frames) {
    if (frames.isEmpty) return 0.0;
    final torchFrames = frames.where((f) => f.flashOn).toList();
    final source = torchFrames.isNotEmpty ? torchFrames : frames;
    return source
        .reduce((a, b) => a.laplacianScore > b.laplacianScore ? a : b)
        .thumbAngleDegrees;
  }

  // ─── SSIM-proxy dedup (MAD on 16×16 thumbnail sampled from the Y-plane) ──

  List<TaggedFrame> _deduplicate(List<TaggedFrame> frames) {
    final sorted = [...frames]
      ..sort((a, b) => b.laplacianScore.compareTo(a.laplacianScore));
    final thumbs = {for (final f in sorted) f: _thumbnailFromYPlane(f)};
    final kept = <TaggedFrame>[];
    for (final f in sorted) {
      final isDup = kept.any((k) => _mad(thumbs[k]!, thumbs[f]!) < _madThreshold);
      if (!isDup) kept.add(f);
    }
    return kept;
  }

  static Uint8List _thumbnailFromYPlane(TaggedFrame f) {
    final out = Uint8List(256);
    final bytes = f.bytes;
    final w = f.imageWidth, h = f.imageHeight, stride = f.bytesPerRow;
    if (w < 16 || h < 16 || bytes.length < stride * h) return out;
    for (int ty = 0; ty < 16; ty++) {
      final sy = (ty * h) ~/ 16;
      final row = sy * stride;
      for (int tx = 0; tx < 16; tx++) {
        final sx = (tx * w) ~/ 16;
        final idx = row + sx;
        out[ty * 16 + tx] = idx < bytes.length ? bytes[idx] : 0;
      }
    }
    return out;
  }

  static double _mad(Uint8List a, Uint8List b) {
    var sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / a.length;
  }

  // ─── Crop + JPEG encode (isolate, only the 3 uploaded frames) ────────────

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

  // ─── Upload ───────────────────────────────────────────────────────────────

  Future<String> _upload({
    required String userId,
    required List<TaggedFrame> top,
    required double bestPitch,
    required int pass1Total,
    required int pass2Total,
  }) async {
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) throw Exception('No Firebase user — auth failed.');

    final id = _uuid.v4();
    final basePath = 'captures/$userId/$id';
    final camDesc = _camera.selectedCamera;
    final ctrl = _camera.controller;
    final res = ctrl?.value.previewSize;
    final cameraResolution =
        res != null ? '${res.width.toInt()}x${res.height.toInt()}' : 'unknown';

    final framesMeta = <Map<String, dynamic>>[];

    for (int i = 0; i < top.length; i++) {
      final f = top[i];
      final type = f.flashOn ? 'torch' : 'ambient';
      final name = 'front_burst_${i + 1}_$type.jpg';

      final jpeg = await compute<_CropEncodeInput, Uint8List>(
        _cropEncodeIsolate,
        _CropEncodeInput(
          yPlane: f.bytes,
          width: f.imageWidth,
          height: f.imageHeight,
          bytesPerRow: f.bytesPerRow,
        ),
      );
      await FirebaseStorage.instance
          .ref()
          .child('$basePath/$name')
          .putData(jpeg, SettableMetadata(contentType: 'image/jpeg'));

      framesMeta.add({
        'frameIndex': i + 1,
        'file': name,
        'torchOn': f.flashOn,
        'torchIntensity': f.flashIntensity,
        'evOffset': 0.0, // not exposed by camera plugin
        'focusDistance': null, // not exposed by camera plugin
        'devicePitchDeg': double.parse(f.thumbAngleDegrees.toStringAsFixed(2)),
        'laplacianScore': double.parse(f.laplacianScore.toStringAsFixed(1)),
        'nfiqScore': null, // computed server-side
        'thumbCoverageRatio': double.parse(f.thumbCoverageRatio.toStringAsFixed(3)),
        'ssimVsDuplicate': null, // dedup used MAD; true SSIM server-side
        'timestamp': f.timestamp.toIso8601String(),
        'cropRegion': {'x0': _cx0, 'x1': _cx1, 'y0': _cy0, 'y1': _cy1},
        if (f.thumbRoi != null)
          'thumbRoi': {
            'left': f.thumbRoi!.left,
            'top': f.thumbRoi!.top,
            'right': f.thumbRoi!.right,
            'bottom': f.thumbRoi!.bottom,
          },
      });

      _emit(_state.copyWith(progress: (i + 1) / top.length));
    }

    await FirebaseFirestore.instance.collection('captures').doc(id).set({
      'captureId': id,
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
      'status': 'pending',
      'source': 'capture_harness',
      'captureMode': 'front_burst',
      'captureMethod': 'front_burst_hybrid_capture',
      'forumTrainingData': true,
      'nfiqFloor': 50.0, // HybridCaptureService's built-in quality floor
      'angleTolDeg': _angleTolDeg,
      'pass1Count': _pass1Count,
      'pass2Count': _pass2Count,
      'pass1Captured': pass1Total,
      'pass2Captured': pass2Total,
      'bestDevicePitchDeg': double.parse(bestPitch.toStringAsFixed(2)),
      'frameCount': top.length,
      'deviceModel': camDesc?.name ?? 'unknown',
      'osVersion': Platform.operatingSystemVersion,
      'cameraModel': camDesc?.name ?? 'unknown',
      'cameraResolution': cameraResolution,
      'frames': framesMeta,
    });

    return id;
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
