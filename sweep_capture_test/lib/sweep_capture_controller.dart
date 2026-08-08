import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:mac_capture/mac_capture.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Standalone test of the sweep-burst capture architecture -- deliberately
/// NOT layered after a main burst the way clearbridge_beta's
/// FrontCaptureController runs it (real data, commit db1a94e 2026-08-06:
/// 1/137 wins, 0/3 cross-zone mosaic wins, 17% of captures permanently
/// stuck at pending/enhancing, averaging 161s ON TOP of the main burst's
/// own time). The working hypothesis this app tests: sweep-burst never got
/// a fair trial because it always shared a Cloud Function request's time
/// budget with the main burst's own AFIS variant loop, and always fired
/// after the user's hand was already fatigued from holding through 8 main-
/// burst shots. Here, the sweep zones ARE the whole capture -- fresh camera
/// session, fresh hand position, and (critically) the ONLY thing populating
/// this request's `frames` field is the center zone's own ambient/flash
/// pair, so the backend's AFIS variant loop has far less competing work
/// than a real front_only_v1 capture, leaving sweep-burst's own zone/fusion
/// scoring a much larger share of the same 300s ceiling.
///
/// Ported from FrontCaptureController._captureSweepBurst (clearbridge_beta)
/// -- same guide-region math (_stillSpaceRegionForShape), same zone timing
/// constants, same real fixes already validated there (EV-compensated
/// flash, per-zone ambient+flash pairs, sequential encode/upload to avoid
/// CPU/bandwidth starvation) -- plus this session's own new
/// _zoneFramingSimilarity real-motion check (2026-08-08), carried over
/// rather than re-derived.
class SweepCaptureController extends ChangeNotifier {
  // ─── Guide geometry (ported from PadSilhouetteShape.defaultShape usage) ──
  static const double _guideN = 2.5;
  // Matches front_capture_controller.dart's _sweepGuideShiftFrac exactly --
  // re-derive by hand only if that project's own guide is re-tuned.
  static const double _sweepGuideShiftFrac = 0.335396;

  // ─── Zone timing (ported from _captureSweepBurst's own constants) ────────
  static const int _calibrationHoldMs = 1500;
  static const int _calibrationTickMs = 700;
  static const int _zoneMoveMs = 3100;
  static const int _zoneSettleMs = 700;
  static const int _burstFlashSettleMs = 70;
  static const int _sweepTimeoutMs = 34000;
  static const int _zoneEncodeTimeoutMs = 20000;
  static const int _zoneUploadTimeoutMs = 18000;
  static const int _zoneJpegQuality = 75;

  // ─── Real-motion check (2026-08-08, this session) ─────────────────────────
  static const double _zoneSimilarityThreshold = 0.90;
  static const int _extraMoveMs = 1800;

  final CameraService _camera = CameraService();
  final HybridCaptureService _hybrid = HybridCaptureService();
  final CaptureAudioService _audio = CaptureAudioService();
  AdaptiveFlashController? _flash;

  int _sensorOrientation = 90;
  Size? _cachedScreenSize;
  Size? _cachedPreviewSize;
  double _focusPeak = 1.0;
  double _focusValue = 0.0;
  bool _disposed = false;

  SweepTestState _state = const SweepTestState();
  SweepTestState get state => _state;
  CameraController? get cameraController => _camera.controller;

  void _emit(SweepTestState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  // ─── Entry point ───────────────────────────────────────────────────────

  Future<void> start(String userId, {required Size screenSize}) async {
    if (_state.phase != SweepTestPhase.idle) return;
    _cachedScreenSize = screenSize;
    _emit(const SweepTestState(phase: SweepTestPhase.initializing));
    try {
      await _run(userId);
    } catch (e, st) {
      debugPrint('[SweepTest] fatal: $e\n$st');
      _emit(_state.copyWith(phase: SweepTestPhase.error, error: e.toString()));
    }
  }

  Future<void> _run(String userId) async {
    await _audio.init();
    await _camera.initializeCamera(
      lensDirection: CameraLensDirection.back,
      resolution: ResolutionPreset.veryHigh,
    );
    final cam = _camera.controller;
    if (cam == null) throw Exception('Camera failed to initialize');
    _sensorOrientation = _camera.selectedCamera?.sensorOrientation ?? 90;
    _cachedPreviewSize = cam.value.previewSize;
    _flash = AdaptiveFlashController(cam);

    // Brief real calibration: sample live focus + brightness for a bounded
    // window (same discipline as every other capture in this project --
    // measure, don't assume) before committing to the sweep. Deliberately
    // simpler than clearbridge_beta's own multi-second hold-gate -- this
    // app's whole purpose is isolating the sweep architecture itself, not
    // re-testing the pre-capture readiness gate.
    _emit(_state.copyWith(phase: SweepTestPhase.calibrating, message: 'Reading light + focus…'));
    final calib = await _calibrate(cam);
    await _flash!.calibrate(calib.brightness);

    // ─ Sweep zones: the WHOLE capture ────────────────────────────────────
    final basePath = 'captures/$userId/${_uuid.v4()}';
    final zones = <MapEntry<String, double>>[
      const MapEntry('left', 0.0),
      const MapEntry('center', 0.5),
      const MapEntry('right', 1.0),
    ];
    final rawShots = <String, Uint8List>{};
    final guideRegions = <String, Map<String, dynamic>>{};
    final zoneDebug = <String, dynamic>{};
    final stopwatch = Stopwatch()..start();

    _emit(_state.copyWith(
      phase: SweepTestPhase.sweeping,
      distanceHint: 'Place your thumb at the start position',
      sweepProgress: 0.0,
      activeGuideShape: _sweepGuideShapeForProgress(0.0),
    ));
    unawaited(HapticFeedback.lightImpact());
    await Future<void>.delayed(const Duration(milliseconds: _calibrationHoldMs));

    try {
      await (() async {
        final torchCapable = _flash!.isNeeded;
        final flashEvStep = torchCapable ? -0.6 : 0.0; // fixed EV step -- see README
        double? minEv, maxEv;
        if (torchCapable) {
          try {
            minEv = await cam.getMinExposureOffset();
            maxEv = await cam.getMaxExposureOffset();
          } catch (_) {}
        }
        zoneDebug['torchCapable'] = torchCapable;
        unawaited(HapticFeedback.mediumImpact());

        var wasFlashLastShot = false;
        Uint8List? prevZoneFlash;
        var extraMoveMs = 0;

        for (var i = 0; i < zones.length; i++) {
          final zone = zones[i].key;
          final target = zones[i].value;
          if (_disposed) break;

          if (i == 0) {
            _emit(_state.copyWith(
              sweepProgress: target,
              activeGuideShape: _sweepGuideShapeForProgress(target),
            ));
          } else {
            final fromProgress = zones[i - 1].value;
            final moveMs = _zoneMoveMs + extraMoveMs;
            final grantedExtra = extraMoveMs > 0;
            if (grantedExtra) {
              zoneDebug['${zone}_extraMoveMsGranted'] = extraMoveMs;
              extraMoveMs = 0;
            }
            _emit(_state.copyWith(
              distanceHint: grantedExtra
                  ? 'Move further this time'
                  : (zone == 'right' ? 'Slowly move right' : 'Slowly move to the middle'),
            ));
            final moveStart = DateTime.now();
            while (true) {
              final elapsedMs = DateTime.now().difference(moveStart).inMilliseconds;
              final t = (elapsedMs / moveMs).clamp(0.0, 1.0);
              final progress = fromProgress + (target - fromProgress) * t;
              _emit(_state.copyWith(
                sweepProgress: progress,
                activeGuideShape: _sweepGuideShapeForProgress(progress),
              ));
              if (t >= 1.0) break;
              await Future<void>.delayed(const Duration(milliseconds: 60));
            }
          }

          if (i == 0) {
            unawaited(HapticFeedback.lightImpact());
            _emit(_state.copyWith(distanceHint: 'Hold still — capturing $zone'));
            await Future<void>.delayed(const Duration(milliseconds: _zoneSettleMs));
          } else {
            for (final n in const ['Hold still…', '2…', '1…']) {
              if (_disposed) break;
              _emit(_state.copyWith(distanceHint: n));
              unawaited(HapticFeedback.lightImpact());
              await Future<void>.delayed(const Duration(milliseconds: _calibrationTickMs));
            }
          }
          if (_disposed) break;

          // Ambient shot.
          try {
            await _flash!.deactivate();
            if (minEv != null && maxEv != null) {
              await cam.setExposureOffset((0.0).clamp(minEv, maxEv));
            }
            if (wasFlashLastShot) {
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            }
          } catch (_) {}
          wasFlashLastShot = false;
          try {
            final xfile = await cam.takePicture();
            rawShots['${zone}_amb'] = await xfile.readAsBytes();
          } catch (e) {
            zoneDebug['${zone}_amb_error'] = e.toString();
          }

          // Flash shot.
          if (torchCapable) {
            try {
              await _flash!.activate();
              if (minEv != null && maxEv != null) {
                await cam.setExposureOffset(flashEvStep.clamp(minEv, maxEv));
              }
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            } catch (_) {}
          }
          wasFlashLastShot = torchCapable;
          try {
            final xfile = await cam.takePicture();
            rawShots['${zone}_fl'] = await xfile.readAsBytes();
          } catch (e) {
            zoneDebug['${zone}_fl_error'] = e.toString();
          }

          final region = _guideRegionForSweepZone(target);
          if (region != null) guideRegions[zone] = region;

          // Real-motion check against the PREVIOUS zone's flash shot --
          // ported from clearbridge_beta's front_capture_controller.dart
          // (2026-08-08 fix). Deliberately does NOT reopen the live camera
          // stream (this project hit a real ANR from repeatedly restarting
          // startImageStream mid-sweep, 2026-07-30) -- compares already-
          // captured JPEGs via decodeStillJpegToLuma, a pure dart:ui decode
          // with no camera-session involvement.
          final thisFlash = rawShots['${zone}_fl'];
          if (thisFlash != null && prevZoneFlash != null) {
            final sim = await _zoneFramingSimilarity(prevZoneFlash, thisFlash);
            if (sim != null) {
              zoneDebug['${zone}_framingSimilarityToPrev'] = double.parse(sim.toStringAsFixed(3));
              if (sim >= _zoneSimilarityThreshold) extraMoveMs = _extraMoveMs;
            }
          }
          if (thisFlash != null) prevZoneFlash = thisFlash;
        }

        try {
          await _flash?.deactivate();
        } catch (_) {}
      }()).timeout(const Duration(milliseconds: _sweepTimeoutMs));
    } catch (e) {
      zoneDebug['sweepError'] = e.toString();
    }
    stopwatch.stop();

    if (rawShots.isEmpty) {
      throw Exception('No zone shots captured');
    }

    _emit(_state.copyWith(phase: SweepTestPhase.uploading, message: 'Uploading…', uploadProgress: 0));
    await _camera.disposeCamera();

    await _uploadAndScore(
      userId: userId,
      basePath: basePath,
      rawShots: rawShots,
      guideRegions: guideRegions,
      zoneDebug: zoneDebug,
      durationMs: stopwatch.elapsedMilliseconds,
    );
  }

  Future<({double brightness, double focus})> _calibrate(CameraController cam) async {
    final completer = Completer<void>();
    double brightness = 128.0;
    var samples = 0;
    void onFrame(CameraImage image) {
      if (_disposed || completer.isCompleted) return;
      try {
        final focus = _hybrid.offerFrame(image, thumbRoi: null);
        if (focus > _focusPeak) _focusPeak = focus;
        _focusValue = (focus / (_focusPeak + 1e-6)).clamp(0.0, 1.0);
        // Cheap mean-luma sample from the Y plane's own bytes, matching the
        // AdaptiveFlashController's own documented brightness convention.
        final plane = image.planes.first.bytes;
        if (plane.isNotEmpty) {
          var sum = 0;
          const stride = 97; // sparse sample, not every pixel
          var n = 0;
          for (var i = 0; i < plane.length; i += stride) {
            sum += plane[i];
            n++;
          }
          if (n > 0) brightness = sum / n;
        }
      } catch (_) {}
      samples++;
      if (samples >= 15 && !completer.isCompleted) completer.complete();
    }

    await cam.setFocusMode(FocusMode.auto);
    await _camera.startImageStream(onFrame);
    await completer.future.timeout(const Duration(milliseconds: 2500), onTimeout: () {});
    await _camera.stopImageStream();
    return (brightness: brightness, focus: _focusValue);
  }

  // ─── Guide geometry (ported verbatim from front_capture_controller.dart) ─

  PadSilhouetteShape _sweepGuideShapeForProgress(double progress) {
    const base = PadSilhouetteShape.defaultShape;
    final cx = (0.5 - _sweepGuideShiftFrac) + (2 * _sweepGuideShiftFrac) * progress.clamp(0.0, 1.0);
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

  ({double cx, double cy, double rx, double ry})? _stillSpaceRegionForShape(
    PadSilhouetteShape shape,
  ) {
    final screenSize = _cachedScreenSize;
    final previewSize = _cachedPreviewSize;
    if (screenSize == null || previewSize == null) return null;
    final wp = previewSize.height;
    final hp = previewSize.width;
    final ws = screenSize.width;
    final hs = screenSize.height;
    if (wp <= 0 || hp <= 0 || ws <= 0 || hs <= 0) return null;
    final scale = math.max(ws / wp, hs / hp);
    final offX = (wp * scale - ws) / 2;
    final offY = (hp * scale - hs) / 2;

    Offset toStill(double su, double sv) {
      final previewU = ((su * ws) + offX) / scale / wp;
      final previewV = ((sv * hs) + offY) / scale / hp;
      return Offset(1.0 - previewV, previewU);
    }

    final center = toStill(shape.cx, shape.cy);
    final top = toStill(shape.cx, shape.cy - shape.ry);
    final bottom = toStill(shape.cx, shape.cy + shape.ry);
    final left = toStill(shape.cx - shape.rx, shape.cy);
    final right = toStill(shape.cx + shape.rx, shape.cy);
    final xs = [top.dx, bottom.dx, left.dx, right.dx];
    final ys = [top.dy, bottom.dy, left.dy, right.dy];
    return (
      cx: center.dx,
      cy: center.dy,
      rx: (xs.reduce(math.max) - xs.reduce(math.min)) / 2,
      ry: (ys.reduce(math.max) - ys.reduce(math.min)) / 2,
    );
  }

  Map<String, dynamic>? _guideRegionForSweepZone(double progress) {
    final region = _stillSpaceRegionForShape(_sweepGuideShapeForProgress(progress));
    if (region == null) return null;
    return {
      'cx': region.cx,
      'cy': region.cy,
      'rx': region.rx,
      'ry': region.ry,
      'n': _guideN,
      'tipAngleDeg': (_sensorOrientation == 90 || _sensorOrientation == 270) ? 0.0 : 90.0,
    };
  }

  /// See front_capture_controller.dart's _zoneFramingSimilarity (2026-08-08)
  /// for the full real-bug writeup this targets. Ported verbatim.
  Future<double?> _zoneFramingSimilarity(Uint8List a, Uint8List b) async {
    try {
      final da = await decodeStillJpegToLuma(a, _sensorOrientation, targetWidth: 80);
      final db = await decodeStillJpegToLuma(b, _sensorOrientation, targetWidth: 80);
      if (da == null || db == null) return null;
      if (da.width != db.width || da.height != db.height) return null;
      final n = da.luma.length;
      if (n == 0) return null;
      double sumA = 0, sumB = 0;
      for (var i = 0; i < n; i++) {
        sumA += da.luma[i];
        sumB += db.luma[i];
      }
      final meanA = sumA / n, meanB = sumB / n;
      double cov = 0, varA = 0, varB = 0;
      for (var i = 0; i < n; i++) {
        final da_ = da.luma[i] - meanA;
        final db_ = db.luma[i] - meanB;
        cov += da_ * db_;
        varA += da_ * da_;
        varB += db_ * db_;
      }
      final denom = math.sqrt(varA * varB);
      if (denom < 1e-6) return null;
      return (cov / denom).clamp(-1.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  // ─── Upload + trigger ──────────────────────────────────────────────────

  Future<void> _uploadAndScore({
    required String userId,
    required String basePath,
    required Map<String, Uint8List> rawShots,
    required Map<String, Map<String, dynamic>> guideRegions,
    required Map<String, dynamic> zoneDebug,
    required int durationMs,
  }) async {
    // Decode + re-encode every shot at reduced quality, SEQUENTIALLY --
    // real bug already found and fixed in clearbridge_beta (concurrent
    // compute() isolates starve each other on a mobile CPU).
    final encoded = <String, Uint8List>{};
    for (final entry in rawShots.entries) {
      try {
        final decoded = await decodeStillJpegToLuma(
          entry.value, _sensorOrientation, targetWidth: 2048,
        ).timeout(const Duration(milliseconds: _zoneEncodeTimeoutMs));
        if (decoded != null) {
          final jpeg = await compute(_encodeIsolate,
              _EncodeArgs(decoded.luma, decoded.width, decoded.height));
          encoded[entry.key] = jpeg;
        }
      } catch (e) {
        zoneDebug['${entry.key}_encodeError'] = e.toString();
      }
    }

    // Upload sequentially (real bug already found in clearbridge_beta:
    // concurrent uploads split one constrained mobile pipe and starve
    // each other).
    var completed = 0;
    for (final entry in encoded.entries) {
      try {
        final task = FirebaseStorage.instance
            .ref()
            .child('$basePath/sweep_burst_${entry.key}.jpg')
            .putData(entry.value, SettableMetadata(contentType: 'image/jpeg'));
        await task.timeout(const Duration(milliseconds: _zoneUploadTimeoutMs), onTimeout: () {
          unawaited(task.cancel().catchError((_) => false));
          throw TimeoutException('zone upload timed out');
        });
      } catch (e) {
        zoneDebug['${entry.key}_uploadError'] = e.toString();
      }
      completed++;
      _emit(_state.copyWith(uploadProgress: completed / encoded.length));
    }

    // Repurpose the CENTER zone's own ambient+flash pair as this request's
    // `frames` field -- _download_front_only_frames (main.py) requires a
    // non-empty `frames` array to run at all, and center is the zone
    // closest to the standard (non-swept) guide position, so it's the
    // most representative single "main burst" stand-in available without
    // capturing a genuinely separate burst (which would reintroduce the
    // exact "layered after" problem this app exists to remove).
    final framesMeta = <Map<String, dynamic>>[];
    if (encoded.containsKey('center_amb')) {
      framesMeta.add({
        'path': '$basePath/sweep_burst_center_amb.jpg',
        'angleDeg': 0.0,
        'flashOn': false,
        'type': 'burst',
      });
    }
    if (encoded.containsKey('center_fl')) {
      framesMeta.add({
        'path': '$basePath/sweep_burst_center_fl.jpg',
        'angleDeg': 0.0,
        'flashOn': true,
        'type': 'burst',
      });
    }
    if (framesMeta.isEmpty) {
      throw Exception('Center zone never captured -- nothing to score');
    }

    // sweepBurstDebug in the SAME schema main.py already reads (2026-08-05
    // ambient+flash-pair format) -- no backend change needed for this app
    // to be scored by the existing, already-deployed sweep-burst pipeline.
    final paths = <String, String>{};
    for (final key in encoded.keys) {
      paths[key] = '$basePath/sweep_burst_$key.jpg';
    }
    final sweepBurstDebug = {
      'attempted': true,
      'uploaded': true,
      'durationMs': durationMs,
      'paths': paths,
      'guideRegions': guideRegions,
      'zones': zoneDebug,
    };

    final centerGuide = guideRegions['center'] ??
        {'cx': 0.63, 'cy': 0.5, 'rx': 0.1112, 'ry': 0.083, 'n': _guideN, 'tipAngleDeg': 0.0};

    final id = Uri.parse(basePath).pathSegments.last;
    await FirebaseFirestore.instance.collection('captures').doc(id).set({
      'captureId': id,
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
      'status': 'pending',
      'source': 'sweep_capture_test',
      'captureMode': 'front_only_v1',
      'captureMethod': 'sweep_burst_standalone',
      'guideRegion': centerGuide,
      'frames': framesMeta,
      'sweepBurstDebug': sweepBurstDebug,
    }, SetOptions(merge: true));

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
      debugPrint('[SweepTest] processEnhanceAndScore trigger failed: $e');
    }

    await _audio.playAngleSuccess(isFinal: true);
    _emit(_state.copyWith(phase: SweepTestPhase.complete, captureId: id, uploadProgress: 1.0));
  }

  @override
  void dispose() {
    _disposed = true;
    _audio.dispose();
    _camera.disposeCamera();
    super.dispose();
  }
}

class _EncodeArgs {
  final Uint8List luma;
  final int width;
  final int height;
  const _EncodeArgs(this.luma, this.width, this.height);
}

Uint8List _encodeIsolate(_EncodeArgs args) {
  return encodeGrayscaleJpeg(
    args.luma, args.width, args.height,
    quality: SweepCaptureController._zoneJpegQuality,
  );
}

enum SweepTestPhase { idle, initializing, calibrating, sweeping, uploading, complete, error }

class SweepTestState {
  final SweepTestPhase phase;
  final String message;
  final String distanceHint;
  final double sweepProgress;
  final PadSilhouetteShape? activeGuideShape;
  final double uploadProgress;
  final String? captureId;
  final String? error;

  const SweepTestState({
    this.phase = SweepTestPhase.idle,
    this.message = '',
    this.distanceHint = '',
    this.sweepProgress = 0.0,
    this.activeGuideShape,
    this.uploadProgress = 0.0,
    this.captureId,
    this.error,
  });

  SweepTestState copyWith({
    SweepTestPhase? phase,
    String? message,
    String? distanceHint,
    double? sweepProgress,
    PadSilhouetteShape? activeGuideShape,
    double? uploadProgress,
    String? captureId,
    String? error,
  }) =>
      SweepTestState(
        phase: phase ?? this.phase,
        message: message ?? this.message,
        distanceHint: distanceHint ?? this.distanceHint,
        sweepProgress: sweepProgress ?? this.sweepProgress,
        activeGuideShape: activeGuideShape ?? this.activeGuideShape,
        uploadProgress: uploadProgress ?? this.uploadProgress,
        captureId: captureId ?? this.captureId,
        error: error ?? this.error,
      );
}
