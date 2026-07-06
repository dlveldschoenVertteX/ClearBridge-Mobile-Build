import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:mac_capture/mac_capture.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

// ─── Public state types ───────────────────────────────────────────────────────

enum FrontBurstPhase {
  idle,
  waitingForCoverage, // stream running — show thumb to camera
  calibrating,        // focus lock + orientation zero
  scanning,           // pass 1: 8 torch+ambient pairs, find sharpest angle
  focusing,           // pass 2: 10 pairs within ±5° of best angle
  processing,         // Laplacian scoring, SSIM dedup, crop
  uploading,
  done,
  error,
}

class FrontBurstState {
  final FrontBurstPhase phase;
  final String message;
  final double progress;           // 0–1 within current phase
  final double thumbCoverageRatio; // live during waitingForCoverage
  final int pass1Done;             // 0–8
  final int pass2Done;             // 0–10
  final String? captureId;
  final String? error;

  const FrontBurstState({
    this.phase = FrontBurstPhase.idle,
    this.message = '',
    this.progress = 0,
    this.thumbCoverageRatio = 0,
    this.pass1Done = 0,
    this.pass2Done = 0,
    this.captureId,
    this.error,
  });

  FrontBurstState copyWith({
    FrontBurstPhase? phase,
    String? message,
    double? progress,
    double? thumbCoverageRatio,
    int? pass1Done,
    int? pass2Done,
    String? captureId,
    String? error,
  }) =>
      FrontBurstState(
        phase: phase ?? this.phase,
        message: message ?? this.message,
        progress: progress ?? this.progress,
        thumbCoverageRatio: thumbCoverageRatio ?? this.thumbCoverageRatio,
        pass1Done: pass1Done ?? this.pass1Done,
        pass2Done: pass2Done ?? this.pass2Done,
        captureId: captureId ?? this.captureId,
        error: error ?? this.error,
      );
}

// ─── Internal frame record ────────────────────────────────────────────────────

class _BurstFrame {
  final Uint8List jpeg;
  final bool torchOn;
  final double devicePitch; // relative to calibration reference, degrees
  final double thumbCoverage;
  final DateTime timestamp;
  double laplacianScore = 0;
  Uint8List? thumbnail; // 16×16 grayscale, used for fast SSIM-proxy dedup

  _BurstFrame({
    required this.jpeg,
    required this.torchOn,
    required this.devicePitch,
    required this.thumbCoverage,
    required this.timestamp,
  });
}

// ─── Isolate payload types ────────────────────────────────────────────────────

// Returned by the score isolate: (laplacian, 16×16 grayscale thumbnail bytes)
typedef _ScoreResult = (double, Uint8List);

typedef _CropInput = Uint8List;
typedef _CropOutput = Uint8List;

// ─── Controller ──────────────────────────────────────────────────────────────

class FrontBurstController extends ChangeNotifier {
  // — Spec constants ———————————————————————————————————————————————————————
  static const int    _pass1Count    = 8;
  static const int    _pass2Count    = 10;
  static const double _nfiqFloor     = 50.0;  // Laplacian proxy; real NFIQ computed server-side
  static const double _coverageMin   = 0.50;
  static const double _coverageMax   = 0.70;
  static const double _angleTolDeg   = 5.0;   // ±5° pass-2 filter
  static const double _madThreshold  = 12.0;  // MAD<12 on 16×16 ≈ SSIM>0.95
  static const int    _uploadCount   = 3;
  // Crop: keep centre 50% × 60% of each frame before upload
  static const double _cx0 = 0.25, _cx1 = 0.75;
  static const double _cy0 = 0.20, _cy1 = 0.80;
  // Torch inter-shot settle
  static const int _torchSettleMs  = 80;
  // Angle-hold wait per slot in pass 2
  static const int _angleWaitMs    = 3000;
  // Coverage must be sustained for this long before calibration fires
  static const int _coverageSustainMs = 800;
  // Coverage wait timeout
  static const int _coverageTimeoutS  = 30;

  final _camera      = CameraService();
  final _orientation = DeviceOrientationService();
  final _landmarker  = ThumbLandmarkerService();

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
    _emit(const FrontBurstState()); // reset
    try {
      await _run(userId);
    } catch (e, st) {
      debugPrint('[FrontBurst] fatal: $e\n$st');
      _emit(_state.copyWith(
        phase: FrontBurstPhase.error,
        error: e.toString(),
      ));
    }
  }

  Future<void> _run(String userId) async {
    // ─ 1. Camera + services init ───────────────────────────────────────────
    _emit(const FrontBurstState(
      phase: FrontBurstPhase.waitingForCoverage,
      message: 'Show thumb to camera',
    ));
    _orientation.start();
    _landmarker.initialize();
    await _camera.initializeCamera(
      lensDirection: CameraLensDirection.back,
      resolution: ResolutionPreset.high, // ~1080p; manageable JPEG decode time
    );

    // ─ 2. Coverage gate ────────────────────────────────────────────────────
    final coverage = await _waitForCoverage();

    // ─ 3. Calibrate: focus lock + zero orientation ─────────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.calibrating,
      message: 'Calibrating…',
      thumbCoverageRatio: coverage,
    ));
    await _camera.stopImageStream();
    await _camera.enableCaptureLock();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _orientation.captureReference(); // zero: all pass angles relative to this

    // ─ 4. Pass 1: 8 torch+ambient pairs, no angle filter ──────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.scanning,
      message: 'Pass 1 — scanning…',
      progress: 0,
      pass1Done: 0,
    ));
    final pass1 = await _runPass(
      count: _pass1Count,
      pitchFilter: null,
      coverageSnapshot: coverage,
      onProgress: (i) => _emit(_state.copyWith(
        pass1Done: i,
        progress: i / _pass1Count,
      )),
    );

    // Score pass 1 so we can find the best angle before pass 2
    _emit(_state.copyWith(
      phase: FrontBurstPhase.processing,
      message: 'Scoring pass 1…',
      progress: 0,
    ));
    await _scoreFrames(pass1, onProgress: (p) => _emit(_state.copyWith(progress: p)));
    final bestPitch = _bestPitch(pass1);
    debugPrint('[FrontBurst] best pitch from pass 1: ${bestPitch.toStringAsFixed(1)}°');

    // ─ 5. Pass 2: 10 pairs within ±5° of best pitch ───────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.focusing,
      message: 'Pass 2 — focusing…',
      progress: 0,
      pass2Done: 0,
    ));
    final pass2 = await _runPass(
      count: _pass2Count,
      pitchFilter: bestPitch,
      coverageSnapshot: coverage,
      onProgress: (i) => _emit(_state.copyWith(
        pass2Done: i,
        progress: i / _pass2Count,
      )),
    );

    // Score pass 2
    _emit(_state.copyWith(
      phase: FrontBurstPhase.processing,
      message: 'Scoring pass 2…',
      progress: 0,
    ));
    await _scoreFrames(pass2, onProgress: (p) => _emit(_state.copyWith(progress: p)));

    // ─ 6. Filter → dedup → top-3 ──────────────────────────────────────────
    _emit(_state.copyWith(message: 'Deduplicating…'));
    final all = [...pass1, ...pass2];
    final qualified = all.where((f) =>
        f.laplacianScore >= _nfiqFloor &&
        f.thumbCoverage >= _coverageMin &&
        f.thumbCoverage <= _coverageMax,
    ).toList();

    if (qualified.isEmpty) {
      throw Exception(
        'No qualifying frames (NFIQ floor $_nfiqFloor, coverage $_coverageMin–$_coverageMax). '
        'Try better lighting or adjust thumb distance.',
      );
    }

    final deduped = _deduplicate(qualified);
    deduped.sort((a, b) => b.laplacianScore.compareTo(a.laplacianScore));
    final top = deduped.take(_uploadCount).toList();

    // ─ 7. Crop + upload ────────────────────────────────────────────────────
    _emit(_state.copyWith(
      phase: FrontBurstPhase.uploading,
      message: 'Uploading ${top.length} frames…',
      progress: 0,
    ));
    final captureId = await _upload(
      userId: userId,
      top: top,
      coverage: coverage,
      bestPitch: bestPitch,
      pass1Total: pass1.length,
      pass2Total: pass2.length,
    );

    _emit(_state.copyWith(
      phase: FrontBurstPhase.done,
      captureId: captureId,
      message: 'Complete — $captureId',
      progress: 1,
    ));
  }

  // ─── Coverage wait (stream phase) ────────────────────────────────────────

  Future<double> _waitForCoverage() async {
    final sensorOrientation =
        _camera.selectedCamera?.sensorOrientation ?? 90;
    final completer = Completer<double>();
    DateTime? firstGoodTime;

    await _camera.startImageStream((frame) {
      if (completer.isCompleted) return;

      final hands = _landmarker.detect(frame, sensorOrientation);
      if (hands.isEmpty || hands.first.landmarks.length < 5) {
        firstGoodTime = null;
        _emit(_state.copyWith(
          thumbCoverageRatio: 0,
          message: 'Show thumb to camera',
        ));
        return;
      }

      final wrist    = hands.first.landmarks[0];
      final thumbTip = hands.first.landmarks[4];
      final coverage = (thumbTip.y - wrist.y).abs().clamp(0.0, 1.0);

      _emit(_state.copyWith(
        thumbCoverageRatio: coverage,
        message: coverage < _coverageMin
            ? 'Move closer'
            : coverage > _coverageMax
                ? 'Move further away'
                : 'Hold steady…',
      ));

      if (coverage >= _coverageMin && coverage <= _coverageMax) {
        final now = DateTime.now();
        firstGoodTime ??= now;
        if (now.difference(firstGoodTime!).inMilliseconds >= _coverageSustainMs &&
            !completer.isCompleted) {
          completer.complete(coverage);
        }
      } else {
        firstGoodTime = null;
      }
    });

    return Future.any([
      completer.future,
      Future.delayed(Duration(seconds: _coverageTimeoutS), () {
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Thumb not detected in $_coverageTimeoutS s — check lighting and position.',
            ),
          );
        }
        return _state.thumbCoverageRatio.clamp(_coverageMin, _coverageMax);
      }),
    ]);
  }

  // ─── Burst pass ───────────────────────────────────────────────────────────

  Future<List<_BurstFrame>> _runPass({
    required int count,
    required double? pitchFilter, // null = no filter (pass 1)
    required double coverageSnapshot,
    required void Function(int done) onProgress,
  }) async {
    final frames = <_BurstFrame>[];
    final ctrl = _camera.controller!;

    for (int i = 0; i < count; i++) {
      // Pass 2: wait until device is within ±5° of reference pitch
      if (pitchFilter != null) {
        var waited = 0;
        while (waited < _angleWaitMs) {
          final pitch = _orientation.relativeOrientation().pitch;
          if ((pitch - pitchFilter).abs() <= _angleTolDeg) break;
          await Future<void>.delayed(const Duration(milliseconds: 150));
          waited += 150;
        }
        // Skip slot if still out of tolerance
        final pitch = _orientation.relativeOrientation().pitch;
        if ((pitch - pitchFilter).abs() > _angleTolDeg) {
          debugPrint('[FrontBurst] slot $i skipped — pitch out of tolerance');
          onProgress(i + 1);
          continue;
        }
      }

      final pitchNow = _orientation.relativeOrientation().pitch;

      // Torch frame
      try {
        await ctrl.setFlashMode(FlashMode.torch);
        await Future<void>.delayed(const Duration(milliseconds: _torchSettleMs));
        final tf = await ctrl.takePicture();
        frames.add(_BurstFrame(
          jpeg: await tf.readAsBytes(),
          torchOn: true,
          devicePitch: pitchNow,
          thumbCoverage: coverageSnapshot,
          timestamp: DateTime.now(),
        ));
      } catch (e) {
        debugPrint('[FrontBurst] torch capture $i failed: $e');
      }

      // Ambient frame
      try {
        await ctrl.setFlashMode(FlashMode.off);
        await Future<void>.delayed(const Duration(milliseconds: _torchSettleMs));
        final af = await ctrl.takePicture();
        frames.add(_BurstFrame(
          jpeg: await af.readAsBytes(),
          torchOn: false,
          devicePitch: pitchNow,
          thumbCoverage: coverageSnapshot,
          timestamp: DateTime.now(),
        ));
      } catch (e) {
        debugPrint('[FrontBurst] ambient capture $i failed: $e');
      }

      onProgress(i + 1);
    }

    // Ensure torch is off when done
    try { await ctrl.setFlashMode(FlashMode.off); } catch (_) {}
    return frames;
  }

  // ─── Scoring (isolate per frame) ──────────────────────────────────────────

  Future<void> _scoreFrames(
    List<_BurstFrame> frames, {
    required void Function(double p) onProgress,
  }) async {
    for (int i = 0; i < frames.length; i++) {
      final result = await compute<Uint8List, _ScoreResult>(
        _scoreIsolate,
        frames[i].jpeg,
      );
      frames[i].laplacianScore = result.$1;
      frames[i].thumbnail      = result.$2;
      onProgress((i + 1) / frames.length);
    }
  }

  /// Top-level isolate: decodes JPEG, computes Laplacian variance on the
  /// centre crop, and produces a 16×16 grayscale thumbnail for dedup.
  static _ScoreResult _scoreIsolate(Uint8List jpeg) {
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) return (0.0, Uint8List(256));

    final gray = img.grayscale(decoded);
    final w = gray.width, h = gray.height;

    // Laplacian variance on 25–75% × 20–80% centre crop
    final x0 = (w * 0.25).toInt().clamp(1, w - 2);
    final y0 = (h * 0.20).toInt().clamp(1, h - 2);
    final x1 = (w * 0.75).toInt().clamp(1, w - 2);
    final y1 = (h * 0.80).toInt().clamp(1, h - 2);

    double mean = 0, m2 = 0;
    int n = 0;
    for (int y = y0; y < y1; y += 4) {
      for (int x = x0; x < x1; x += 4) {
        final c   = gray.getPixel(x,     y    ).r.toDouble();
        final lap = 4 * c
            - gray.getPixel(x - 1, y    ).r
            - gray.getPixel(x + 1, y    ).r
            - gray.getPixel(x,     y - 1).r
            - gray.getPixel(x,     y + 1).r;
        n++;
        final d = lap - mean;
        mean += d / n;
        m2   += d * (lap - mean);
      }
    }
    final laplacian = n > 1 ? m2 / (n - 1) : 0.0;

    // 16×16 grayscale thumbnail for fast SSIM-proxy dedup
    final thumb      = img.copyResize(gray, width: 16, height: 16);
    final thumbBytes = Uint8List(256);
    for (int y = 0; y < 16; y++) {
      for (int x = 0; x < 16; x++) {
        thumbBytes[y * 16 + x] = thumb.getPixel(x, y).r.toInt().clamp(0, 255);
      }
    }

    return (laplacian, thumbBytes);
  }

  // ─── Best angle selection ─────────────────────────────────────────────────

  double _bestPitch(List<_BurstFrame> frames) {
    if (frames.isEmpty) return 0.0;
    // Prefer the sharpest torch frame; fall back to any frame
    final torchFrames = frames.where((f) => f.torchOn).toList();
    final source = torchFrames.isNotEmpty ? torchFrames : frames;
    return source.reduce((a, b) =>
        a.laplacianScore > b.laplacianScore ? a : b,
    ).devicePitch;
  }

  // ─── SSIM-proxy dedup (MAD on 16×16 thumbnail) ───────────────────────────

  List<_BurstFrame> _deduplicate(List<_BurstFrame> frames) {
    // Greedy: iterate sharpest-first; add to keep-set if not a near-twin of
    // any already-kept frame. MAD < 12 (of 255) ≈ SSIM > 0.95.
    final sorted = [...frames]
      ..sort((a, b) => b.laplacianScore.compareTo(a.laplacianScore));
    final kept = <_BurstFrame>[];
    for (final f in sorted) {
      final isDup = kept.any((k) => _mad(k.thumbnail, f.thumbnail) < _madThreshold);
      if (!isDup) kept.add(f);
    }
    return kept;
  }

  static double _mad(Uint8List? a, Uint8List? b) {
    if (a == null || b == null || a.length != b.length) return 255.0;
    var sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / a.length;
  }

  // ─── Crop helper (isolate) ────────────────────────────────────────────────

  static _CropOutput _cropIsolate(_CropInput jpeg) {
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) return jpeg;
    final w = decoded.width, h = decoded.height;
    final cropped = img.copyCrop(
      decoded,
      x:      (w * _cx0).round(),
      y:      (h * _cy0).round(),
      width:  (w * (_cx1 - _cx0)).round(),
      height: (h * (_cy1 - _cy0)).round(),
    );
    return Uint8List.fromList(img.encodeJpg(cropped, quality: 92));
  }

  // ─── Upload ───────────────────────────────────────────────────────────────

  Future<String> _upload({
    required String userId,
    required List<_BurstFrame> top,
    required double coverage,
    required double bestPitch,
    required int pass1Total,
    required int pass2Total,
  }) async {
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) throw Exception('No Firebase user — auth failed.');

    final id       = _uuid.v4();
    final basePath = 'captures/$userId/$id';
    final ctrl     = _camera.controller;
    final camDesc  = _camera.selectedCamera;
    final res      = ctrl?.value.previewSize;
    final cameraResolution =
        res != null ? '${res.width.toInt()}x${res.height.toInt()}' : 'unknown';

    final framesMeta = <Map<String, dynamic>>[];

    for (int i = 0; i < top.length; i++) {
      final f    = top[i];
      final type = f.torchOn ? 'torch' : 'ambient';
      final name = 'front_burst_${i + 1}_$type.jpg';

      // Crop to 25–75% × 20–80% before upload
      final cropped = await compute<_CropInput, _CropOutput>(
        _cropIsolate,
        f.jpeg,
      );
      await FirebaseStorage.instance
          .ref()
          .child('$basePath/$name')
          .putData(cropped, SettableMetadata(contentType: 'image/jpeg'));

      framesMeta.add({
        'frameIndex':         i + 1,
        'file':               name,
        'torchOn':            f.torchOn,
        'torchIntensity':     f.torchOn ? 1.0 : 0.0,
        'evOffset':           0.0,         // not exposed by camera plugin
        'focusDistance':      null,         // not exposed by camera plugin
        'devicePitchDeg':     double.parse(f.devicePitch.toStringAsFixed(2)),
        'laplacianScore':     double.parse(f.laplacianScore.toStringAsFixed(1)),
        'nfiqScore':          null,         // computed server-side
        'thumbCoverageRatio': double.parse(f.thumbCoverage.toStringAsFixed(3)),
        'ssimVsDuplicate':    null,         // dedup used MAD; true SSIM server-side
        'timestamp':          f.timestamp.toIso8601String(),
        'cropRegion':         {'x0': _cx0, 'x1': _cx1, 'y0': _cy0, 'y1': _cy1},
      });

      _emit(_state.copyWith(progress: (i + 1) / top.length));
    }

    await FirebaseFirestore.instance.collection('captures').doc(id).set({
      'captureId':         id,
      'userId':            userId,
      'createdAt':         FieldValue.serverTimestamp(),
      'status':            'pending',
      'source':            'capture_harness',
      'captureMode':       'front_burst',
      'captureMethod':     'front_burst_takePicture',
      'forumTrainingData': true,
      // Quality gate params used during this capture
      'nfiqFloor':         _nfiqFloor,
      'coverageGate':      {'min': _coverageMin, 'max': _coverageMax},
      'angleTolDeg':       _angleTolDeg,
      'pass1Count':        _pass1Count,
      'pass2Count':        _pass2Count,
      'pass1Captured':     pass1Total,
      'pass2Captured':     pass2Total,
      'bestDevicePitchDeg':double.parse(bestPitch.toStringAsFixed(2)),
      'thumbCoverageRatio':double.parse(coverage.toStringAsFixed(3)),
      'frameCount':        top.length,
      // Device metadata
      'deviceModel':       camDesc?.name ?? 'unknown',
      'osVersion':         Platform.operatingSystemVersion,
      'cameraModel':       camDesc?.name ?? 'unknown',
      'cameraResolution':  cameraResolution,
      'frames':            framesMeta,
    });

    return id;
  }

  // ─── Cleanup ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _orientation.dispose();
    _camera.disposeCamera();
    super.dispose();
  }
}
