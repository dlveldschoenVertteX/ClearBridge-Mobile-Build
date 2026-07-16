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

enum FrontCapturePhase { idle, calibrating, holding, capturing, uploading, complete, error }

class FrontCaptureState {
  const FrontCaptureState({
    this.phase = FrontCapturePhase.idle,
    this.onTarget = false,
    this.holdProgress = 0.0,
    this.isCapturingBurst = false,
    this.uploadProgress = 0.0,
    this.captureId,
    this.error,
    this.confirmationText,
    this.distanceHint,
    this.isSteady = true,
    this.lightingValue = 0.5,
  });

  final FrontCapturePhase phase;
  final bool onTarget;
  final double holdProgress;
  final bool isCapturingBurst;
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

  FrontCaptureState copyWith({
    FrontCapturePhase? phase,
    bool? onTarget,
    double? holdProgress,
    bool? isCapturingBurst,
    double? uploadProgress,
    Object? captureId = _sentinel,
    Object? error = _sentinel,
    Object? confirmationText = _sentinel,
    Object? distanceHint = _sentinel,
    bool? isSteady,
    double? lightingValue,
  }) =>
      FrontCaptureState(
        phase: phase ?? this.phase,
        onTarget: onTarget ?? this.onTarget,
        holdProgress: holdProgress ?? this.holdProgress,
        isCapturingBurst: isCapturingBurst ?? this.isCapturingBurst,
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
  static const Set<String> _uploadNonRetryableCodes = {
    'unauthorized', 'unauthenticated', 'no-default-bucket',
    'invalid-argument', 'invalid-url', 'object-not-found', 'quota-exceeded',
  };

  // ROI the focus/exposure meters score on — aligned to the pad silhouette
  // bounding box so framing, metering and the superprint crop all agree.
  // Kept 1:1 with PadSilhouetteShape.defaultShape.boundingRect + taper:
  //   cx=0.5, cy=0.37, rx=0.23*(1+0.20)=0.276, ry=0.19 → [0.224,0.18,0.776,0.56]
  static const Rect _scoreRoi = Rect.fromLTRB(0.224, 0.18, 0.776, 0.56);

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
  // Extra EV reduction applied when the torch fires at close range (~10 cm).
  // Flash overexposure killed NFIQ on the first real capture — the pad centre
  // blew out completely. -1.0 EV at close range keeps ridges in the histogram.
  static const double _flashEvStep = -1.0;
  static const double _coverageMin = 0.35;
  static const double _coverageMax = 0.85;

  // Device must be this still (gyroscope magnitude, deg/s) before the hold
  // timer counts and the burst can fire. Real captures showed motion-blur
  // streaking in BOTH ambient and flash frames of the same burst — camera
  // shake at macro (thumb-pad-filling) distance, independent of focus
  // distance or exposure. First-cut threshold; tune from real telemetry
  // (gyroMagnitudeDegPerSec is stored per-frame below).
  static const double _maxSteadyDegPerSec = 6.0;

  CameraController? _camera;
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
  }) async {
    if (_starting || _streamRunning) return;
    _starting = true;
    _disposed = false;
    _camera = camera;
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

    _flash = AdaptiveFlashController(camera);

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
    final hint = tooFar
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
        phase: FrontCapturePhase.capturing,
      ),
      force: true,
    );

    final cam = _camera;
    final torchCapable = _flash?.isNeeded ?? false;

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
              final target = _appliedEvOffset + _flashEvStep;
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

      // Decode + re-encode off the UI isolate.
      final futures = <Future<({Uint8List bytes, bool flashOn, double? lap, DateTime ts})>>[];
      for (final raw in rawShots) {
        futures.add(() async {
          final decoded = await decodeStillJpegToLuma(raw.jpeg, _sensorOrientation);
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
    _apply((s) => s.copyWith(phase: FrontCapturePhase.uploading, uploadProgress: 0), force: true);

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
        'gyroMagnitudeDegPerSec': double.parse(gyroAtCapture.toStringAsFixed(2)),
        'frames': framesMeta,
        if (rawSensorSupport != null) 'rawSensorSupport': rawSensorSupport,
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

      // Best-effort secondary-camera capture: try any OTHER back cameras this
      // device exposes (e.g. IR/night-vision + ultrawide sensors) for one
      // extra torch-lit still each, purely additive to the main flow above.
      // Ported from OscillatingCaptureController (built + validated there,
      // proven server-side: the IR camera's torch shot alone scored
      // competitively with -- and on one device, above -- the main camera's
      // best single frame; see docs/CAPTURE_OPTIMIZATION_SCOPE.md). Was never
      // wired into front_only_v1 before now since that flow didn't exist yet
      // when this was built. Runs AFTER the main frames + Firestore doc are
      // already committed, so there is nothing left for a failure here to
      // jeopardise, and BEFORE the processEnhanceAndScore trigger below so
      // the backend's one-time doc read sees secondaryCameras already
      // present. Many devices can only hold one camera session open at a
      // time -- opening a second physical camera here may simply fail, which
      // is caught and skipped silently per-camera.
      // Diagnostic trail written unconditionally (unlike secondaryMeta below,
      // which only ever reflects successes) -- added after a real device
      // test on the Doogee S118 (previously confirmed to expose separate
      // IR/ultrawide camera IDs) silently produced zero secondaryCameras
      // with no way to tell whether that meant "no other camera found" or
      // "every attempt failed". Written even on total failure so the next
      // real capture actually explains itself instead of staying silent.
      final secondaryDebug = <String, dynamic>{'foundBackCams': <String>[]};
      final secondaryMeta = <Map<String, dynamic>>[];
      try {
        final allCams = await availableCameras();
        final mainName = _camera?.description.name;
        secondaryDebug['allCamsCount'] = allCams.length;
        secondaryDebug['mainCamName'] = mainName;
        final others = allCams.where((c) =>
            c.lensDirection == CameraLensDirection.back && c.name != mainName);
        secondaryDebug['foundBackCams'] =
            others.map((c) => c.name).toList(growable: false);
        for (final desc in others) {
          CameraController? tmp;
          try {
            tmp = CameraController(desc, ResolutionPreset.max, enableAudio: false);
            await tmp.initialize().timeout(const Duration(seconds: 8));
            await tmp.setFlashMode(FlashMode.torch);
            // Anti-blowout EV step -- the same -1.0 offset already validated
            // for the main camera's flash burst (see the alternating
            // ambient/flash burst above: an earlier all-flash burst blew out
            // the pad centre at ~10cm). setExposureOffset() does not engage
            // the Camera2 interop that setExposureMode() does, so this is
            // safe to call without risking the torch (see CameraService
            // comments on that conflict).
            try {
              final minEv = await tmp.getMinExposureOffset();
              final maxEv = await tmp.getMaxExposureOffset();
              await tmp.setExposureOffset((-1.0).clamp(minEv, maxEv));
            } catch (_) {
              // Some secondary sensors may not support exposure offset --
              // non-fatal, the burst still fires at default exposure.
            }
            await Future<void>.delayed(const Duration(milliseconds: 600));
            final safeName = desc.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
            final paths = <String>[];
            for (var i = 0; i < _secondaryBurstCount; i++) {
              final shot = await tmp.takePicture();
              final bytes = await shot.readAsBytes();
              final path = '$basePath/secondary_${safeName}_torch_$i.jpg';
              await _uploadWithRetry(bytes, path);
              paths.add(path);
              if (i < _secondaryBurstCount - 1) {
                await Future<void>.delayed(
                    const Duration(milliseconds: _burstShotDelayMs));
              }
            }
            await tmp.setFlashMode(FlashMode.off);
            secondaryMeta.add({'name': desc.name, 'paths': paths});
            secondaryDebug['${desc.name}_ok'] = true;
          } catch (e) {
            debugPrint('[front] secondary camera ${desc.name} skipped: $e');
            secondaryDebug['${desc.name}_error'] = e.toString();
          } finally {
            try {
              await tmp?.dispose();
            } catch (_) {}
          }
        }
      } catch (e) {
        debugPrint('[front] secondary camera capture skipped entirely: $e');
        secondaryDebug['fatalError'] = e.toString();
      }
      try {
        final update = <String, dynamic>{'secondaryCameraDebug': secondaryDebug};
        if (secondaryMeta.isNotEmpty) update['secondaryCameras'] = secondaryMeta;
        await FirebaseFirestore.instance.collection('captures').doc(id).update(update);
      } catch (_) {}

      // docs/MULTI_DISTANCE_MESH_SCOPE.md Phase 0: capture a second,
      // meaningfully-closer distance zone as ONE MORE independent
      // single-frame candidate (no fusion math yet -- the backend just
      // scores it alongside best_afis_img and keeps whichever wins). Runs
      // AFTER the main upload + secondary-camera capture, same "can't
      // regress the primary result" discipline: best-effort, bounded by a
      // timeout, any failure just skips this stage silently. Must land
      // before the processEnhanceAndScore trigger below so the backend's
      // one-time doc read sees it.
      final distanceStage2 = <Map<String, dynamic>>[];
      final distanceDebug = <String, dynamic>{'attempted': false};
      try {
        final cam2 = _camera;
        if (cam2 != null && !_disposed) {
          distanceDebug['attempted'] = true;
          _apply((s) => s.copyWith(distanceHint: 'Move slightly closer for a bonus capture'));
          final reachedNear = await _waitForNearDistanceZone(cam2);
          distanceDebug['reachedNearZone'] = reachedNear;
          if (reachedNear) {
            await _refocus();
            final frames = await _captureDistanceBurst(
              cam2,
              zone: 'near',
              basePath: basePath,
              count: 3,
            );
            distanceStage2.addAll(frames);
          }
        }
      } catch (e) {
        debugPrint('[front] distance-stage-2 capture skipped (non-fatal): $e');
        distanceDebug['error'] = e.toString();
      } finally {
        _apply((s) => s.copyWith(distanceHint: null));
      }
      try {
        final update = <String, dynamic>{'distanceStage2Debug': distanceDebug};
        if (distanceStage2.isNotEmpty) update['distanceStage2'] = distanceStage2;
        await FirebaseFirestore.instance.collection('captures').doc(id).update(update);
      } catch (_) {}

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

  /// docs/MULTI_DISTANCE_MESH_SCOPE.md Phase 0: best-effort wait for the
  /// user to move to a meaningfully CLOSER distance zone than the main
  /// capture, using the same coverage signal _onFrame already computes
  /// (`HybridCaptureService.meanLuma` over `_scoreRoi`) -- just a fresh,
  /// short-lived stream since the main stream is already stopped by the
  /// time this runs (inside _finishAndUpload, after _fireBurst's
  /// _stopStream() call). No focus/exposure control here -- that happens
  /// in _refocus() once this returns true. Never throws; a bounded timeout
  /// (or any stream error) resolves false so this stage can never hang or
  /// block the primary capture result already sitting in Firestore.
  Future<bool> _waitForNearDistanceZone(CameraController cam) async {
    const timeout = Duration(seconds: 6);
    const nearThreshold = _coverageMax + 0.05;
    final completer = Completer<bool>();
    var streaming = false;
    void onFrame(CameraImage image) {
      if (completer.isCompleted) return;
      try {
        final coverage = HybridCaptureService.meanLuma(image, roi: _scoreRoi) / 255.0;
        final steady = _gyroMagnitudeDegPerSec < _maxSteadyDegPerSec;
        if (coverage > nearThreshold && steady) completer.complete(true);
      } catch (_) {}
    }
    try {
      await cam.startImageStream(onFrame);
      streaming = true;
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      if (streaming) {
        try {
          await cam.stopImageStream();
        } catch (_) {}
      }
    }
  }

  /// docs/MULTI_DISTANCE_MESH_SCOPE.md Phase 0: fires a small alternating
  /// ambient/flash burst at the CURRENT (already-refocused) distance and
  /// uploads each frame tagged with `distanceZone`. Deliberately NOT a full
  /// re-entry into the main hold/burst state machine (_onFrame/_fireBurst)
  /// -- this is a best-effort bonus stage scored as one more independent
  /// candidate by the backend, not part of the primary deliverable, so it
  /// mirrors _fireBurst's alternating-EV pattern directly rather than
  /// coupling to the primary phase/state-machine fields.
  Future<List<Map<String, dynamic>>> _captureDistanceBurst(
    CameraController cam, {
    required String zone,
    required String basePath,
    required int count,
  }) async {
    final out = <Map<String, dynamic>>[];
    final torchCapable = _flash?.isNeeded ?? false;
    double? minEv, maxEv;
    if (torchCapable) {
      try {
        minEv = await cam.getMinExposureOffset();
        maxEv = await cam.getMaxExposureOffset();
      } catch (_) {}
    }
    for (var i = 0; i < count; i++) {
      final wantFlash = torchCapable && i.isOdd;
      try {
        if (wantFlash) {
          await _flash!.activate();
          if (minEv != null && maxEv != null) {
            await cam.setExposureOffset((_appliedEvOffset + _flashEvStep).clamp(minEv, maxEv));
          }
          await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
        } else {
          await _flash?.deactivate();
          if (minEv != null && maxEv != null) {
            await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
          }
        }
        final xfile = await cam.takePicture();
        final jpeg = await xfile.readAsBytes();
        final decoded = await decodeStillJpegToLuma(jpeg, _sensorOrientation);
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
