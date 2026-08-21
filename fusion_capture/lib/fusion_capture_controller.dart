import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:mac_capture/mac_capture.dart';
import 'package:uuid/uuid.dart';

/// Which phase of the fusion session is running.
enum FusionPhase {
  idle,
  initializing,
  frontHold,      // phase 1: hold to lock
  frontBurst,     // phase 1: 8-shot alternating ambient/flash
  tilt,           // phase 2: small-angle left / tip / right
  sweep,          // phase 3: guide translated across zones
  uploading,
  complete,
  error,
}

/// One tilt station. `cue` is what the user is asked to do; `key` is the
/// Firestore/Storage tag. Angle is the DESIGN TARGET, not a measurement --
/// nothing on-device can observe how far the user's finger actually tilted
/// (device sensors see the phone, not the finger), so the achieved angle is
/// only recoverable offline by registering the captured frame against the
/// face-on anchor. Recorded here as intent, never asserted as fact.
class TiltStation {
  const TiltStation(this.key, this.cue, this.targetAngleDeg);
  final String key;
  final String cue;
  final double targetAngleDeg;
}

/// One sweep station: the guide translates to `progress` (0=left, 1=right)
/// with an optional vertical offset, and the user follows it.
class SweepStation {
  const SweepStation(this.key, this.progress, {this.dyFrac = 0.0});
  final String key;
  final double progress;
  final double dyFrac;
}

@immutable
class FusionState {
  const FusionState({
    this.phase = FusionPhase.idle,
    this.statusText = '',
    this.detailText = '',
    this.holdProgress = 0.0,
    this.phaseProgress = 0.0,
    this.overallProgress = 0.0,
    this.guideShape,
    this.silhouetteState = PadSilhouetteState.aligning,
    this.onTarget = false,
    this.distanceHint,
    this.errorMessage,
    this.captureId,
  });

  final FusionPhase phase;
  final String statusText;
  final String detailText;
  final double holdProgress;    // 0..1 within the current hold
  final double phaseProgress;   // 0..1 within the current phase
  final double overallProgress; // 0..1 across the whole session
  final PadSilhouetteShape? guideShape;
  final PadSilhouetteState silhouetteState;
  final bool onTarget;
  final String? distanceHint;
  final String? errorMessage;
  final String? captureId;

  FusionState copyWith({
    FusionPhase? phase,
    String? statusText,
    String? detailText,
    double? holdProgress,
    double? phaseProgress,
    double? overallProgress,
    PadSilhouetteShape? guideShape,
    PadSilhouetteState? silhouetteState,
    bool? onTarget,
    String? distanceHint,
    bool clearDistanceHint = false,
    String? errorMessage,
    String? captureId,
  }) {
    return FusionState(
      phase: phase ?? this.phase,
      statusText: statusText ?? this.statusText,
      detailText: detailText ?? this.detailText,
      holdProgress: holdProgress ?? this.holdProgress,
      phaseProgress: phaseProgress ?? this.phaseProgress,
      overallProgress: overallProgress ?? this.overallProgress,
      guideShape: guideShape ?? this.guideShape,
      silhouetteState: silhouetteState ?? this.silhouetteState,
      onTarget: onTarget ?? this.onTarget,
      distanceHint: clearDistanceHint ? null : (distanceHint ?? this.distanceHint),
      errorMessage: errorMessage ?? this.errorMessage,
      captureId: captureId ?? this.captureId,
    );
  }
}

/// Decode width every captured still is downscaled to before upload.
/// Matches clearbridge_beta's own _stillDecodeTargetWidth (3200).
const int _kStillDecodeTargetWidth = 3200;

/// Decode + downscale + grayscale-encode one captured still.
///
/// The decode MUST run on the main isolate -- decodeStillJpegToLuma uses a
/// Flutter-engine API (`instantiateImageCodec`) and cannot run inside
/// `compute()`. Only the encode is offloaded, which is exactly how
/// clearbridge_beta does it.
///
/// Returns the original bytes unchanged on any failure: a decode problem
/// should cost upload size, never the frame itself.
Future<Uint8List> _shrinkForUpload(Uint8List jpeg, int sensorOrientation) async {
  try {
    final decoded = await decodeStillJpegToLuma(
      jpeg,
      sensorOrientation,
      targetWidth: _kStillDecodeTargetWidth,
    );
    if (decoded == null) return jpeg;
    return await compute(
      _encodeIsolate,
      _EncodeArgs(decoded.luma, decoded.width, decoded.height),
    );
  } catch (_) {
    return jpeg;
  }
}

class _EncodeArgs {
  const _EncodeArgs(this.luma, this.width, this.height);
  final Uint8List luma;
  final int width;
  final int height;
}

Uint8List _encodeIsolate(_EncodeArgs a) =>
    encodeGrayscaleJpeg(a.luma, a.width, a.height);

class _Shot {
  _Shot({
    required this.jpeg,
    required this.tag,
    required this.flashOn,
    this.exif,
  });
  Uint8List jpeg;          // replaced in-place by _shrinkCaptured()
  bool shrunk = false;
  final String tag;        // storage/Firestore key, e.g. 'tilt_left_fl'
  final bool flashOn;
  final JpegExposureExif? exif;
}

/// Three-phase fusion capture.
///
/// ARCHITECTURAL CONTRACT, and the reason this app exists separately:
/// every phase produces INDEPENDENT, COMPLETE candidate frames. Nothing is
/// blended, spliced, or averaged into a shared image on-device. That is
/// deliberate -- four separate image-space fusion attempts in this project
/// (sweep cross-zone mosaic, field-domain orientation fusion,
/// focusZoneSplice, zone reduction) all lost to a single un-fused candidate
/// on real matchability, because compositing frames of non-rigid skin
/// manufactures spurious minutiae at every seam and minutiae matchers punish
/// those hard. Fusion, if it happens at all, happens LATER and in MINUTIAE
/// space (see fusion_brain/). This app's only job is to capture the raw
/// material cleanly and label it precisely.
class FusionCaptureController extends ChangeNotifier {
  FusionCaptureController({
    CameraService? cameraService,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _cameraService = cameraService ?? CameraService(),
        _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final CameraService _cameraService;
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;
  final HybridCaptureService _hybrid = HybridCaptureService();

  CameraController? get _camera => _cameraService.controller;
  CameraService get cameraService => _cameraService;

  AdaptiveFlashController? _flash;

  FusionState _state = const FusionState();
  FusionState get state => _state;

  // ---- phase toggles: flip any off to isolate a phase for A/B ----
  static const bool _frontEnabled = true;
  static const bool _tiltEnabled = true;
  static const bool _sweepEnabled = true;

  /// Whether to invoke the deployed production Cloud Function on this
  /// capture. OFF on purpose.
  ///
  /// With `captureMode: 'fusion_v1'`, `main.py` does NOT take its
  /// front_only_v1 path -- it falls through to `_download_best_frames`,
  /// which lists every blob under basePath and would mix phase-1, tilt and
  /// sweep frames into one undifferentiated set. That is not a meaningful
  /// result, and making it meaningful would require a backend change, which
  /// is precisely what an isolated experiment must not need.
  ///
  /// Baselines are computed OFFLINE instead, in fusion_brain/, which already
  /// runs the real production `afis_print.generate()` against these frames --
  /// so nothing is lost by leaving production untouched. Flip this on only
  /// with a deliberate decision about how the backend should treat
  /// fusion_v1.
  static const bool _triggerProductionBackend = false;

  // ---- phase 1: front hold + burst (values proven in front_only_v1) ----
  static const int _burstFrameCount = 8;
  static const int _burstFlashSettleMs = 70;
  static const double _focusThreshold = 0.45;
  static const double _coverageMin = 0.35;
  static const double _coverageMax = 0.85;
  static const int _holdDurationMs = 1500;
  static const int _frontPhaseTimeoutMs = 75000;
  /// Bound on the 8-shot burst itself. Derived the same way
  /// clearbridge_beta derived its own _burstCaptureTimeoutMs: 8 real
  /// shutter presses plus torch settles, with better than 2x margin.
  static const int _burstTimeoutMs = 45000;

  // ---- phase 2: tilt stations ----
  // ~10-12 degrees, NOT 15-18. Measured on real multi-angle data
  // (fusion_brain Phase 0b): a -11.8 deg frame contributed 107 new edge
  // minutiae vs 87 at -17.0 deg -- more tilt is not better, because added
  // perspective distortion eventually costs more than the extra revealed
  // surface. A face-on CONTROL frame contributed 4, which is what makes the
  // effect geometric rather than frame-to-frame noise.
  static const List<TiltStation> _tiltStations = [
    TiltStation('tilt_left', 'Roll thumb slightly LEFT', -11.0),
    TiltStation('tilt_tip', 'Roll thumb slightly UP (toward tip)', 11.0),
    TiltStation('tilt_right', 'Roll thumb slightly RIGHT', 11.0),
  ];
  static const int _tiltSettleMs = 1400;   // real time to reposition
  static const int _tiltPhaseTimeoutMs = 60000;

  // ---- phase 3: sweep stations ----
  static const List<SweepStation> _sweepStations = [
    SweepStation('sweep_left', 0.0),
    SweepStation('sweep_center', 0.5),
    SweepStation('sweep_right', 1.0),
  ];
  static const int _sweepSettleMs = 1200;
  static const int _sweepPhaseTimeoutMs = 60000;

  /// See [_kStillDecodeTargetWidth] -- the single definition of this value.
  ///
  /// REAL BUG this fixes (first device test, 2026-08-21): this app uploaded
  /// raw `takePicture()` bytes with no decode step, so every frame went up
  /// at FULL sensor resolution in colour -- measured 20-29 MB each, ~420 MB
  /// for a 20-shot session, at 20-30s per upload. The app sat on
  /// "Uploading..." for 6+ minutes and looked hung because it effectively
  /// was. Production never did this: it decodes to single-channel luma at
  /// this width and re-encodes before upload, which is why its frames are a
  /// fraction of the size. Same treatment here.
  // (constant lives at file scope as _kStillDecodeTargetWidth so the
  // top-level helper and the controller cannot drift apart -- this project
  // has been burned more than once by one value living in two places.)

  /// Hard bound on a single upload. `putData` is an unbounded await, and an
  /// upload that stalls with no bound is indistinguishable from a hang --
  /// the exact failure class this project has hit repeatedly on raw awaits.
  static const Duration _uploadTimeout = Duration(seconds: 45);

  /// Bound for the non-upload network calls (auth, the Firestore write).
  /// Both are unbounded awaits by default and both sit AFTER every frame is
  /// captured, so a stall in either loses the entire session.
  static const Duration _networkTimeout = Duration(seconds: 30);

  final List<_Shot> _shots = [];
  final Map<String, dynamic> _debug = {};
  final Map<String, Map<String, double>> _guideRegions = {};

  String? _captureId;
  Size? _screenSize;
  Size? _previewSize;
  int _sensorOrientation = 90;
  /// Set when a phase's outer timeout fires. `.timeout()` stops the caller
  /// WAITING but does not cancel the work behind the future -- without this
  /// an abandoned station loop keeps driving takePicture() while the NEXT
  /// phase is already using the camera. Overlapping camera sessions are a
  /// documented ANR source in this project, so every capture loop checks
  /// this and bails within one iteration.
  bool _abortPhase = false;
  bool _disposed = false;

  // live signals from the preview stream
  double _focusValue = 0.0;
  double _focusPeak = 0.0;
  double? _liveAbsSharpness;
  double _coverage = 0.0;
  DateTime? _holdStart;

  void _apply(FusionState Function(FusionState) f) {
    if (_disposed) return;
    _state = f(_state);
    notifyListeners();
  }

  void _fail(String message) {
    _apply((s) => s.copyWith(phase: FusionPhase.error, errorMessage: message));
  }

  // ------------------------------------------------------------------
  // session
  // ------------------------------------------------------------------

  Future<void> start({required Size screenSize}) async {
    if (_state.phase != FusionPhase.idle &&
        _state.phase != FusionPhase.error &&
        _state.phase != FusionPhase.complete) {
      return;
    }
    _screenSize = screenSize;
    _shots.clear();
    _debug.clear();
    _guideRegions.clear();
    _captureId = const Uuid().v4();
    _apply((s) => const FusionState().copyWith(
          phase: FusionPhase.initializing,
          statusText: 'Starting camera…',
          guideShape: PadSilhouetteShape.defaultShape,
          captureId: _captureId,
        ));

    try {
      await _cameraService.initializeCamera();
      final cam = _camera;
      if (cam == null) {
        _fail('Camera unavailable');
        return;
      }
      final pv = cam.value.previewSize;
      if (pv != null) _previewSize = Size(pv.width, pv.height);
      _sensorOrientation = cam.description.sensorOrientation;
      _flash = AdaptiveFlashController(cam);
      final mainRegion = _guideRegionFor(PadSilhouetteShape.defaultShape);
      if (mainRegion != null) {
        _guideRegions['main'] = mainRegion;
      } else {
        // Every offline candidate is cropped by this region, so a capture
        // without one is not analysable. Record it rather than shipping a
        // silently unusable capture.
        _debug['guideRegionUnavailable'] = true;
        debugPrint('[fusion] WARNING: no guideRegion (previewSize missing)');
      }

      if (_frontEnabled) {
        await _runFrontPhase();
      }
      if (_state.phase == FusionPhase.error) return;
      if (_tiltEnabled) {
        await _runTiltPhase();
      }
      if (_state.phase == FusionPhase.error) return;
      if (_sweepEnabled) {
        await _runSweepPhase();
      }
      if (_state.phase == FusionPhase.error) return;
      await _finishAndUpload();
    } catch (e) {
      _fail('Capture failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // phase 1 -- front hold + burst (the proven V1 flow)
  // ------------------------------------------------------------------

  Future<void> _runFrontPhase() async {
    _apply((s) => s.copyWith(
          phase: FusionPhase.frontHold,
          statusText: 'Phase 1 of 3 — Main capture',
          detailText: 'Place thumb in the guide and hold still',
          guideShape: PadSilhouetteShape.defaultShape,
          overallProgress: 0.0,
        ));
    try {
      await _startStream();
      final held = await _awaitHold(
          const Duration(milliseconds: _frontPhaseTimeoutMs));
      if (!held) _debug['frontHoldTimedOut'] = true;
      // The BURST needs its own bound too. Previously only the hold was
      // wrapped, leaving 8 raw takePicture() calls completely unprotected --
      // and this file's sibling in clearbridge_beta documents exactly why
      // that is not safe: takePicture() is a raw platform-channel await with
      // no timeout of its own, so try/catch alone cannot save a stalled
      // shutter. A hang there would strand the session before any upload,
      // losing the whole capture.
      await _fireFrontBurst()
          .timeout(const Duration(milliseconds: _burstTimeoutMs));
      await _shrinkCaptured();
    } on TimeoutException {
      // Non-fatal: whatever was captured still uploads, and the phase is
      // marked so offline analysis knows this capture is incomplete rather
      // than treating it as a clean three-phase session.
      _debug['frontPhaseTimedOut'] = true;
      _abortPhase = true;
    } finally {
      _abortPhase = false;
      await _stopStream();
    }
  }

  /// Waits for a satisfied hold, or gives up after [limit]. Returns true if
  /// the hold completed.
  ///
  /// Owns its OWN deadline rather than relying on the caller's
  /// `.timeout()`. A caller-side timeout stops the caller WAITING but does
  /// nothing to the work behind the future -- the periodic poll would keep
  /// running forever, calling _apply() every 100ms and fighting the UI of
  /// every later phase. Every exit path here cancels both timers.
  Future<bool> _awaitHold(Duration limit) async {
    final completer = Completer<bool>();
    Timer? poll;
    Timer? deadline;
    void finish(bool ok) {
      poll?.cancel();
      deadline?.cancel();
      if (!completer.isCompleted) completer.complete(ok);
    }
    deadline = Timer(limit, () => finish(false));
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_disposed) {
        finish(false);
        return;
      }
      final onTarget = _focusValue >= _focusThreshold &&
          _coverage >= _coverageMin &&
          _coverage <= _coverageMax;
      if (!onTarget) {
        _holdStart = null;
        _apply((s) => s.copyWith(
              onTarget: false,
              holdProgress: 0.0,
              silhouetteState: PadSilhouetteState.aligning,
              distanceHint: _coverage > _coverageMax
                  ? 'Move phone BACK a little'
                  : (_coverage < _coverageMin ? 'Move closer' : null),
              clearDistanceHint: _coverage >= _coverageMin &&
                  _coverage <= _coverageMax,
            ));
        return;
      }
      _holdStart ??= DateTime.now();
      final held = DateTime.now().difference(_holdStart!).inMilliseconds;
      final p = (held / _holdDurationMs).clamp(0.0, 1.0);
      _apply((s) => s.copyWith(
            onTarget: true,
            holdProgress: p,
            silhouetteState: PadSilhouetteState.locked,
            clearDistanceHint: true,
          ));
      if (p >= 1.0) finish(true);
    });
    return completer.future;
  }

  Future<void> _fireFrontBurst() async {
    final cam = _camera;
    if (cam == null) return;
    _apply((s) => s.copyWith(
          phase: FusionPhase.frontBurst,
          detailText: 'Hold still — capturing',
          silhouetteState: PadSilhouetteState.capturing,
        ));
    await _stopStream();
    var wasFlashLastShot = false;
    for (var i = 0; i < _burstFrameCount; i++) {
      if (_abortPhase || _disposed) break;
      final wantFlash = i.isOdd;
      try {
        if (wantFlash) {
          await _flash?.activate();
          await Future<void>.delayed(
              const Duration(milliseconds: _burstFlashSettleMs));
        } else {
          await _flash?.deactivate();
          // Symmetric settle: the sensor needs time to re-converge coming
          // DOWN off the torch too, not just going up. Only pay it when the
          // previous shot actually fired the flash.
          if (wasFlashLastShot) {
            await Future<void>.delayed(
                const Duration(milliseconds: _burstFlashSettleMs));
          }
        }
        final x = await cam.takePicture();
        final bytes = await x.readAsBytes();
        _shots.add(_Shot(
          jpeg: bytes,
          tag: 'front_${wantFlash ? "fl" : "amb"}_$i',
          flashOn: wantFlash,
          exif: parseJpegExposureExif(bytes),
        ));
        wasFlashLastShot = wantFlash;
      } catch (e) {
        debugPrint('[fusion] front shot $i failed (non-fatal): $e');
      }
      _apply((s) => s.copyWith(
            phaseProgress: (i + 1) / _burstFrameCount,
            overallProgress: 0.33 * ((i + 1) / _burstFrameCount),
          ));
    }
    await _flash?.deactivate();
  }

  // ------------------------------------------------------------------
  // phase 2 -- small-angle tilt
  // ------------------------------------------------------------------

  Future<void> _runTiltPhase() async {
    _apply((s) => s.copyWith(
          phase: FusionPhase.tilt,
          statusText: 'Phase 2 of 3 — Edge detail',
          detailText: 'Small tilts reveal the sides of your print',
          silhouetteState: PadSilhouetteState.capturing,
          phaseProgress: 0.0,
        ));
    try {
      await _runStations(
        count: _tiltStations.length,
        settleMs: _tiltSettleMs,
        phaseBase: 0.33,
        cueFor: (i) => _tiltStations[i].cue,
        keyFor: (i) => _tiltStations[i].key,
        guideFor: (i) => PadSilhouetteShape.defaultShape,
        onStation: (i) {
          _debug['${_tiltStations[i].key}_targetAngleDeg'] =
              _tiltStations[i].targetAngleDeg;
        },
      ).timeout(const Duration(milliseconds: _tiltPhaseTimeoutMs));
      await _shrinkCaptured();
    } on TimeoutException {
      _debug['tiltPhaseTimedOut'] = true;
      _abortPhase = true;
    } finally {
      _abortPhase = false;
    }
  }

  // ------------------------------------------------------------------
  // phase 3 -- sweep with light
  // ------------------------------------------------------------------

  Future<void> _runSweepPhase() async {
    _apply((s) => s.copyWith(
          phase: FusionPhase.sweep,
          statusText: 'Phase 3 of 3 — Texture',
          detailText: 'Follow the guide',
          phaseProgress: 0.0,
        ));
    try {
      await _runStations(
        count: _sweepStations.length,
        settleMs: _sweepSettleMs,
        phaseBase: 0.66,
        cueFor: (i) => 'Follow the guide',
        keyFor: (i) => _sweepStations[i].key,
        guideFor: (i) => _sweepGuideFor(_sweepStations[i]),
        onStation: (i) {
          final zr = _guideRegionFor(_sweepGuideFor(_sweepStations[i]));
          if (zr != null) _guideRegions[_sweepStations[i].key] = zr;
        },
      ).timeout(const Duration(milliseconds: _sweepPhaseTimeoutMs));
      await _shrinkCaptured();
    } on TimeoutException {
      _debug['sweepPhaseTimedOut'] = true;
      _abortPhase = true;
    } finally {
      _abortPhase = false;
    }
  }

  /// Shared station loop for phases 2 and 3: cue -> settle -> ambient+flash
  /// pair. Both phases capture a real PAIR at each station, because
  /// flash-minus-ambient is what lets the backend separate near-camera skin
  /// from background (torch falloff ~ distance^2) -- without a pair, a
  /// candidate can only ever be scored against the bare geometric guide.
  Future<void> _runStations({
    required int count,
    required int settleMs,
    required double phaseBase,
    required String Function(int) cueFor,
    required String Function(int) keyFor,
    required PadSilhouetteShape Function(int) guideFor,
    void Function(int)? onStation,
  }) async {
    final cam = _camera;
    if (cam == null) return;
    for (var i = 0; i < count; i++) {
      if (_abortPhase || _disposed) break;
      final key = keyFor(i);
      onStation?.call(i);
      _apply((s) => s.copyWith(
            detailText: cueFor(i),
            guideShape: guideFor(i),
            silhouetteState: PadSilhouetteState.aligning,
          ));
      unawaited(HapticFeedback.lightImpact());
      await Future<void>.delayed(Duration(milliseconds: settleMs));

      _apply((s) => s.copyWith(silhouetteState: PadSilhouetteState.capturing));
      // Ambient first, then flash -- flash last so the torch is off again
      // before the next station's cue is shown.
      for (final wantFlash in [false, true]) {
        if (_abortPhase || _disposed) break;
        try {
          if (wantFlash) {
            await _flash?.activate();
            await Future<void>.delayed(
                const Duration(milliseconds: _burstFlashSettleMs));
          }
          final x = await cam.takePicture();
          final bytes = await x.readAsBytes();
          _shots.add(_Shot(
            jpeg: bytes,
            tag: '${key}_${wantFlash ? "fl" : "amb"}',
            flashOn: wantFlash,
            exif: parseJpegExposureExif(bytes),
          ));
        } catch (e) {
          debugPrint('[fusion] station $key flash=$wantFlash failed: $e');
        } finally {
          if (wantFlash) await _flash?.deactivate();
        }
      }
      unawaited(HapticFeedback.heavyImpact());
      _apply((s) => s.copyWith(
            phaseProgress: (i + 1) / count,
            overallProgress: phaseBase + 0.33 * ((i + 1) / count),
            silhouetteState: PadSilhouetteState.locked,
          ));
    }
  }

  PadSilhouetteShape _sweepGuideFor(SweepStation z) {
    const base = PadSilhouetteShape.defaultShape;
    // Translate across the middle 60% of the screen so the guide never
    // clips off-edge at the extremes.
    final cx = 0.2 + 0.6 * z.progress;
    return PadSilhouetteShape(
      cx: cx,
      cy: base.cy + z.dyFrac,
      rx: base.rx,
      ry: base.ry,
      taper: base.taper,
    );
  }

  /// Downscale everything captured so far that has not been shrunk yet, and
  /// release the raw bytes.
  ///
  /// Called at the END of each phase rather than after each shot on purpose.
  /// Doing it inline during the 8-shot burst would insert a decode between
  /// shots and stretch a ~2s burst to ~10s, letting the finger drift -- which
  /// defeats the same-pose stacking the burst exists for. Deferring to the
  /// phase boundary keeps peak memory at ~8 raw frames (the level
  /// clearbridge_beta already runs at in production) instead of all 20
  /// (~400 MB at the measured 20-29 MB per frame), which is a real OOM risk
  /// on a device that is also holding camera buffers.
  Future<void> _shrinkCaptured() async {
    for (final shot in _shots) {
      if (shot.shrunk) continue;
      shot.jpeg = await _shrinkForUpload(shot.jpeg, _sensorOrientation);
      shot.shrunk = true;
    }
  }

  // ------------------------------------------------------------------
  // live preview stream
  // ------------------------------------------------------------------

  Future<void> _startStream() async {
    final cam = _camera;
    if (cam == null) return;
    _focusPeak = 0.0;
    try {
      await _cameraService.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('[fusion] stream start failed: $e');
    }
  }

  Future<void> _stopStream() async {
    try {
      await _cameraService.stopImageStream();
    } catch (_) {}
  }

  void _onFrame(CameraImage image) {
    if (_disposed) return;
    try {
      final roi = _scoreRoi;
      final raw = _hybrid.offerFrame(image, thumbRoi: roi);
      _liveAbsSharpness =
          HybridCaptureService.ema(_liveAbsSharpness ?? raw, raw);
      final abs = _liveAbsSharpness ?? 0.0;
      if (abs > _focusPeak) _focusPeak = abs;
      // Peak-normalised, exactly as front_only_v1 does: absolute Laplacian
      // varies far too much across devices/lighting for a fixed threshold.
      _focusValue = _focusPeak > 0 ? (abs / _focusPeak).clamp(0.0, 1.0) : 0.0;
      _coverage = HybridCaptureService.meanLuma(image, roi: roi) / 255.0;
    } catch (_) {}
  }

  /// Live scoring ROI, derived from the guide rather than hardcoded.
  /// front_only_v1 was burned twice by hand-copied geometry constants
  /// drifting from PadSilhouetteShape -- deriving it keeps one source of
  /// truth.
  Rect get _scoreRoi {
    const g = PadSilhouetteShape.defaultShape;
    return Rect.fromCenter(
      center: Offset(g.cx, g.cy),
      width: g.rx * 2,
      height: g.ry * 2,
    );
  }

  /// Screen-space guide shape -> still-space AFIS mask region.
  ///
  /// Ported verbatim from front_only_v1's `_stillSpaceRegionForShape`, and
  /// deliberately NOT re-derived. A naive "rotate (u,v) -> (1-v,u)" version
  /// silently ignores the BoxFit.cover crop/scale that `_cameraLayer`
  /// applies whenever preview aspect != screen aspect -- which is exactly
  /// the bug that made this project's real captures score single digits
  /// until it was found and fixed (commit a20e009: NFIQ2 jumped to 72). The
  /// mask the backend crops by must match what the user actually saw, so
  /// this undoes the cover transform first, THEN rotates.
  ///
  /// Returns null before the camera reports a preview size; callers fall
  /// back to omitting the region rather than writing a wrong one.
  Map<String, double>? _guideRegionFor(PadSilhouetteShape shape) {
    final screenSize = _screenSize;
    final previewSize = _previewSize;
    if (screenSize == null || previewSize == null) return null;
    // _cameraLayer() swaps preview width/height for the portrait display
    // aspect before handing it to BoxFit.cover, so undo it the same way.
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
    return {
      'cx': center.dx,
      'cy': center.dy,
      'rx': (xs.reduce(math.max) - xs.reduce(math.min)) / 2,
      'ry': (ys.reduce(math.max) - ys.reduce(math.min)) / 2,
      'n': shape.n,
      'tipAngleDeg': 0.0,
    };
  }

  // ------------------------------------------------------------------
  // upload
  // ------------------------------------------------------------------

  Future<void> _finishAndUpload() async {
    _apply((s) => s.copyWith(
          phase: FusionPhase.uploading,
          statusText: 'Uploading…',
          detailText: '',
          overallProgress: 1.0,
        ));
    try {
      await _cameraService.disposeCamera();
    } catch (_) {}

    // Bounded: an unbounded sign-in is a network call that can hang, and a
    // hang here strands the session on "Uploading..." with everything
    // already captured -- the worst possible place to lose a capture.
    String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      try {
        final cred = await FirebaseAuth.instance
            .signInAnonymously()
            .timeout(_networkTimeout);
        uid = cred.user?.uid;
      } catch (e) {
        _fail('Sign-in failed: $e');
        return;
      }
    }
    if (uid == null) {
      _fail('Sign-in failed');
      return;
    }
    final captureId = _captureId!;
    final basePath = 'captures/$uid/$captureId';

    final frames = <Map<String, dynamic>>[];
    final tiltShots = <Map<String, dynamic>>[];
    final sweepShots = <Map<String, dynamic>>[];

    final sensorOrientation = _sensorOrientation;
    var done = 0;
    for (final shot in _shots) {
      final path = '$basePath/${shot.tag}.jpg';
      // Real progress, not a static banner. A 20-shot session is genuinely
      // slow even downscaled, and "Uploading..." with no counter is
      // indistinguishable from a hang -- which is exactly how the first
      // device test read.
      _apply((s) => s.copyWith(
            statusText: 'Uploading ${done + 1} of ${_shots.length}…',
          ));
      // Normally already shrunk at its phase boundary; this only does real
      // work if a phase timed out before its shrink pass ran.
      if (!shot.shrunk) {
        shot.jpeg = await _shrinkForUpload(shot.jpeg, sensorOrientation);
        shot.shrunk = true;
      }
      // Retry once. Without it a single transient network blip permanently
      // drops that frame from a 20-frame session -- and with 20 independent
      // uploads the odds of at least one blip are not small. Production
      // uses _uploadWithRetry for the same reason.
      var uploaded = false;
      for (var attempt = 1; attempt <= 2 && !uploaded; attempt++) {
        try {
          await _storage
              .ref(path)
              .putData(shot.jpeg, SettableMetadata(contentType: 'image/jpeg'))
              .timeout(_uploadTimeout);
          uploaded = true;
        } catch (e) {
          debugPrint('[fusion] upload attempt $attempt failed ${shot.tag}: $e');
          if (attempt == 2) {
            _debug['uploadFailed_${shot.tag}'] = e.toString();
          }
        }
      }
      if (!uploaded) continue;
      done++;
      final meta = <String, dynamic>{
        'path': path,
        'tag': shot.tag,
        'flashOn': shot.flashOn,
        if (shot.exif?.exposureTimeUs != null)
          'exposureTimeUs': shot.exif!.exposureTimeUs,
        if (shot.exif?.isoValue != null) 'iso': shot.exif!.isoValue,
      };
      if (shot.tag.startsWith('front_')) {
        frames.add(meta);
      } else if (shot.tag.startsWith('tilt_')) {
        tiltShots.add(meta);
      } else {
        sweepShots.add(meta);
      }
    }

    try {
      await _firestore.collection('captures').doc(captureId).set({
        'userId': uid,
        'captureId': captureId,
        'basePath': basePath,
        // DATA ISOLATION -- deliberately NOT 'front_only_v1'.
        //
        // An earlier draft used front_only_v1 so the deployed backend would
        // score phase 1 for free. That is a real contamination hazard: this
        // project makes decisions from historical capture stats (the
        // 116-capture variant win-rate study, the mask-vs-matchability
        // sweeps), and every one of those filters on
        // captureMode == 'front_only_v1'. Experimental captures landing in
        // that population would silently skew the very numbers used to judge
        // production -- corrupting the baseline this experiment is supposed
        // to be measured AGAINST.
        //
        // 'fusion_v1' can never be mistaken for a production capture by any
        // existing query, and isExperiment makes the intent explicit for
        // anything written later that does not know about fusion at all.
        'captureMode': 'fusion_v1',
        'fusionVersion': 'fusion_v1',
        'isExperiment': true,
        'fusionPhases': {
          'front': _frontEnabled,
          'tilt': _tiltEnabled,
          'sweep': _sweepEnabled,
        },
        'status': 'pending',
        'nfiqScore': 0,
        'nfiqPass': false,
        'createdAt': FieldValue.serverTimestamp(),
        'guideRegion': _guideRegions['main'],
        'frames': frames,
        if (tiltShots.isNotEmpty) 'tiltShots': tiltShots,
        if (sweepShots.isNotEmpty) 'sweepShots': sweepShots,
        'fusionGuideRegions': _guideRegions,
        'fusionDebug': _debug,
      }, SetOptions(merge: true)).timeout(_networkTimeout);

      // Backend trigger is OFF by default -- see _triggerProductionBackend.
      if (_triggerProductionBackend) {
        unawaited(FirebaseFunctions.instanceFor(region: 'africa-south1')
            .httpsCallable('processEnhanceAndScore')
            .call({
              'captureId': captureId,
              'userId': uid,
              'basePath': basePath,
            })
            .catchError((Object e) {
              debugPrint('[fusion] trigger failed (non-fatal): $e');
              return null as dynamic;
            }));
      }

      _apply((s) => s.copyWith(
            phase: FusionPhase.complete,
            statusText: 'Capture complete',
            detailText:
                '${frames.length} main · ${tiltShots.length} tilt · '
                '${sweepShots.length} sweep',
          ));
    } catch (e) {
      _fail('Upload failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_cameraService.disposeCamera());
    super.dispose();
  }
}
