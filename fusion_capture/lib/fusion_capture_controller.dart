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

class _Shot {
  _Shot({
    required this.jpeg,
    required this.tag,
    required this.flashOn,
    this.exif,
  });
  final Uint8List jpeg;
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

  static const Duration _callTimeout = Duration(seconds: 3);

  final List<_Shot> _shots = [];
  final Map<String, dynamic> _debug = {};
  final Map<String, Map<String, double>> _guideRegions = {};

  String? _captureId;
  Size? _screenSize;
  Size? _previewSize;
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
      _flash = AdaptiveFlashController(cam);
      final mainRegion = _guideRegionFor(PadSilhouetteShape.defaultShape);
      if (mainRegion != null) _guideRegions['main'] = mainRegion;

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
      await _awaitHold().timeout(
          const Duration(milliseconds: _frontPhaseTimeoutMs));
      await _fireFrontBurst();
    } on TimeoutException {
      // Non-fatal: a hold that never completes should not lose the session.
      // Whatever was captured still uploads, and the phase is marked so the
      // offline analysis knows this capture is incomplete rather than
      // silently treating it as a clean three-phase session.
      _debug['frontPhaseTimedOut'] = true;
    } finally {
      await _stopStream();
    }
  }

  Future<void> _awaitHold() async {
    final completer = Completer<void>();
    Timer? poll;
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_disposed) {
        poll?.cancel();
        if (!completer.isCompleted) completer.complete();
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
      if (p >= 1.0) {
        poll?.cancel();
        if (!completer.isCompleted) completer.complete();
      }
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
    } on TimeoutException {
      _debug['tiltPhaseTimedOut'] = true;
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
    } on TimeoutException {
      _debug['sweepPhaseTimedOut'] = true;
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

    final uid = FirebaseAuth.instance.currentUser?.uid ??
        (await FirebaseAuth.instance.signInAnonymously()).user?.uid;
    if (uid == null) {
      _fail('Sign-in failed');
      return;
    }
    final captureId = _captureId!;
    final basePath = 'captures/$uid/$captureId';

    final frames = <Map<String, dynamic>>[];
    final tiltShots = <Map<String, dynamic>>[];
    final sweepShots = <Map<String, dynamic>>[];

    for (final shot in _shots) {
      final path = '$basePath/${shot.tag}.jpg';
      try {
        await _storage.ref(path).putData(
              shot.jpeg,
              SettableMetadata(contentType: 'image/jpeg'),
            );
      } catch (e) {
        debugPrint('[fusion] upload failed ${shot.tag}: $e');
        continue;
      }
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
      }, SetOptions(merge: true));

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
