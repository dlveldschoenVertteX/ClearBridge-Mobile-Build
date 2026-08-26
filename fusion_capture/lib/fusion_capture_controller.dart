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
// Taken transitively via mac_capture (pins ^4.0.2), same as
// clearbridge_beta's own front_capture_controller.dart -- not declared
// directly in this app's own pubspec.yaml, matching that established,
// already-working pattern rather than risking a second, possibly
// conflicting version constraint (exactly what broke this app's first CI
// run, for a different package).
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';

/// Which phase of the fusion session is running.
enum FusionPhase {
  idle,
  initializing,
  frontHold,      // phase 1: hold to lock
  frontBurst,     // phase 1: 8-shot alternating ambient/flash
  tilt,           // phase 2: small-angle left / tip / right
  sweep,          // phase 3: guide translated across zones
  macro,          // phase 4: dedicated close-up shot, camera "2"
  uploading,
  complete,
  error,
}

/// Which Euler component of [RelativeOrientation] a tilt station's
/// targetAngleDeg is measured against. Identical convention to
/// oscillating_capture_controller.dart's `_AngleAxis`: LEFT/RIGHT are a
/// left-right pan (device Y axis = pitch); TIP is a nose-up/down tilt
/// (device X axis = roll) -- a physically different motion, ported as its
/// own axis rather than (as this project has been burned by before) reusing
/// pitch for a motion that isn't actually a pitch.
enum TiltAxis { pitch, roll }

/// One tilt station. `cue` is what the user is asked to do; `key` is the
/// Firestore/Storage tag.
///
/// REAL DEVICE FEEDBACK (2026-08-22): the original design had the THUMB
/// tilt while the phone stayed still, on the reasoning that device sensors
/// "see the phone, not the finger" -- true, but it meant `targetAngleDeg`
/// was pure design intent with no live signal to guide the user to it or to
/// confirm they'd reached it, which is exactly what the feedback flagged
/// ("still a little off... there is a degree measure... before capture is
/// taken"). Ported oscillating_8phase's own real mechanic instead: the
/// PHONE tilts around a stationary thumb, and the device's own fused
/// orientation sensor (`DeviceOrientationService`, already built, already
/// wired into this app's own MainActivity.kt) becomes a genuine live signal
/// -- the same one oscillating already uses in production. targetAngleDeg
/// is now a real, live-trackable target, not just intent. Values kept at
/// this project's own real fusion_brain measurement (~11 degrees -- more
/// tilt is not better, see fusion_brain/results/PHASE0B_TILT_FINDINGS.md),
/// not oscillating's larger 15-20 degree targets -- the "only difference"
/// from the ported mechanic, per direct instruction.
class TiltStation {
  const TiltStation(this.key, this.cue, this.targetAngleDeg,
      {this.axis = TiltAxis.pitch});
  final String key;
  final String cue;
  final double targetAngleDeg;
  final TiltAxis axis;
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
    this.countdownValue,
    this.gyroSteady = true,
    this.stationIndex,
    this.stationsDone = 0,
    this.currentAngleDeg = 0.0,
    this.targetAngleDeg = 0.0,
    this.deltaDeg = 0.0,
    this.angularVelocityDegPerSec = 0.0,
    this.tooFast = false,
    this.lightingValue = 0.5,
    this.focusValue = 0.0,
    this.confirmationText,
    this.zoneCaptureFlash = false,
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
  /// 3, 2, 1, or 0 ("go") during the pre-shutter countdown; null the rest of
  /// the time. Drives the big pulsing numeral overlay -- see _runCountdown.
  final int? countdownValue;
  /// Live gyro-derived phone stability, updated continuously (not just
  /// during a countdown) so the tilt ring can show real, real-time feedback
  /// rather than only reacting at the moment of capture.
  final bool gyroSteady;
  /// Which station (0-based) is currently active during phase 2/3, for the
  /// tilt ring's discrete station markers. Null outside a station phase.
  final int? stationIndex;
  /// How many stations in the CURRENT phase have fully captured their
  /// ambient+flash pair -- drives the ring's completed/green markers.
  final int stationsDone;
  /// Live DeviceOrientationService reading for the ACTIVE tilt station's own
  /// axis (pitch or roll) -- the real, continuously-updated angle the tilt
  /// ring now plots, ported from oscillating_capture_controller.dart's own
  /// currentAngleDeg/targetAngleDeg/deltaDeg. Meaningful only during
  /// FusionPhase.tilt; 0 elsewhere.
  final double currentAngleDeg;
  final double targetAngleDeg;
  final double deltaDeg; // currentAngleDeg - targetAngleDeg, signed
  final double angularVelocityDegPerSec;
  final bool tooFast;
  /// Mean ROI luma, 0..1 -- the SAME underlying signal already driving the
  /// coverage-based distance gate (see `_coverage` on the controller; this
  /// app's fixed-size guide never separately measures "is a thumb actually
  /// in frame" the way front_only_v1's real coverage signal does, so one
  /// mean-luma reading serves both jobs). Surfaced under its own name here
  /// because that is the accurate description of what it measures --
  /// front_only_v1's own BRIGHT meter is this exact same computation.
  final double lightingValue;
  /// Peak-normalised live sharpness -- same definition as front_only_v1's
  /// own FOCUS meter (front_capture_controller.dart's `focusValue` getter).
  final double focusValue;
  /// Front-phase-only confirmation banner text (e.g. '✓ Captured'), ported
  /// from front_only_v1's own `confirmationText` field/pattern -- null the
  /// rest of the time.
  final String? confirmationText;
  /// Sweep phase only: true for the real duration of a zone's shutter
  /// sequence, false while the guide is translating/settling between zones.
  /// Ported from the real sweep architecture's own `zoneCaptureFlash` field
  /// (sweep_capture_test's SweepCaptureController/SweepTestState) -- flips
  /// the guide to its green/locked highlight during capture, gold otherwise,
  /// replacing a verbal countdown per that architecture's own real,
  /// already-validated design (removed the countdown entirely, 2026-08-14,
  /// "allow the camera to pick up if thumb is in mask").
  final bool zoneCaptureFlash;

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
    int? countdownValue,
    bool clearCountdown = false,
    bool? gyroSteady,
    int? stationIndex,
    bool clearStationIndex = false,
    int? stationsDone,
    double? currentAngleDeg,
    double? targetAngleDeg,
    double? deltaDeg,
    double? angularVelocityDegPerSec,
    bool? tooFast,
    double? lightingValue,
    double? focusValue,
    String? confirmationText,
    bool clearConfirmationText = false,
    bool? zoneCaptureFlash,
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
      countdownValue: clearCountdown ? null : (countdownValue ?? this.countdownValue),
      gyroSteady: gyroSteady ?? this.gyroSteady,
      stationIndex: clearStationIndex ? null : (stationIndex ?? this.stationIndex),
      stationsDone: stationsDone ?? this.stationsDone,
      currentAngleDeg: currentAngleDeg ?? this.currentAngleDeg,
      targetAngleDeg: targetAngleDeg ?? this.targetAngleDeg,
      deltaDeg: deltaDeg ?? this.deltaDeg,
      angularVelocityDegPerSec: angularVelocityDegPerSec ?? this.angularVelocityDegPerSec,
      tooFast: tooFast ?? this.tooFast,
      lightingValue: lightingValue ?? this.lightingValue,
      focusValue: focusValue ?? this.focusValue,
      confirmationText: clearConfirmationText
          ? null
          : (confirmationText ?? this.confirmationText),
      zoneCaptureFlash: zoneCaptureFlash ?? this.zoneCaptureFlash,
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
  final CaptureAudioService _audio = CaptureAudioService();
  /// Real device orientation for the tilt phase's angle dial -- same
  /// service oscillating_capture_controller.dart already uses in
  /// production. Reads Android's GAME_ROTATION_VECTOR sensor over the
  /// `clearbridge/orientation` EventChannel, already registered in this
  /// app's own MainActivity.kt (present since this app's own scaffold --
  /// confirmed before relying on it, not assumed).
  final DeviceOrientationService _orientation = DeviceOrientationService();
  Timer? _tiltAnglePoll;
  double _tiltAngularVelocity = 0.0;
  double _tiltLastAngle = 0.0;
  DateTime? _tiltLastAngleAt;

  CameraController? get _camera => _cameraService.controller;
  CameraService get cameraService => _cameraService;

  AdaptiveFlashController? _flash;

  FusionState _state = const FusionState();
  FusionState get state => _state;

  // ---- phase toggles: flip any off to isolate a phase for A/B ----
  static const bool _frontEnabled = true;
  static const bool _tiltEnabled = true;
  static const bool _sweepEnabled = true;
  static const bool _macroEnabled = true;

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
  // ~10-12 degrees, NOT 15-18 (oscillating's own LEFT/RIGHT targets).
  // Measured on real multi-angle data (fusion_brain Phase 0b): a -11.8 deg
  // frame contributed 107 new edge minutiae vs 87 at -17.0 deg -- more tilt
  // is not better, because added perspective distortion eventually costs
  // more than the extra revealed surface. A face-on CONTROL frame
  // contributed 4, which is what makes the effect geometric rather than
  // frame-to-frame noise. This is the "only difference" from oscillating's
  // own mechanic per direct instruction -- everything else about how a
  // station is reached and confirmed (live angle tracking, hold-to-lock,
  // axis convention) is ported as-is; see TiltStation's own docstring for
  // why the mechanic itself changed this round. tilt_tip's axis/sign
  // matches oscillating's own real, already-validated TOP convention
  // (roll, negative = phone tilts DOWN = camera looks up over the tip)
  // rather than a fresh guess.
  static const List<TiltStation> _tiltStations = [
    TiltStation('tilt_left', 'Tilt phone LEFT', -11.0),
    TiltStation('tilt_tip', 'Tilt phone DOWN, looking over your thumb tip',
        -11.0, axis: TiltAxis.roll),
    TiltStation('tilt_right', 'Tilt phone RIGHT', 11.0),
  ];
  // Reused verbatim from oscillating_capture_controller.dart -- real,
  // already-validated numbers, not re-guessed for this smaller-angle
  // context. Honest caveat: validated at oscillating's own 15-20 degree
  // targets, not yet confirmed at fusion's smaller ~11 degree ones -- a
  // 5 degree tolerance is a bigger fraction of an 11 degree target than of
  // a 20 degree one. Flagged, not tuned blind; the next real device test
  // is what confirms whether this needs its own calibration.
  static const double _tiltHoldToleranceDeg = 5.0;
  static const double _tiltMaxAngularVelocityDegPerSec = 30.0;
  static const int _tiltPhaseTimeoutMs = 60000;
  /// Live angle poll rate. Independent of the camera's own image stream --
  /// DeviceOrientationService reads a separate sensor channel
  /// (GAME_ROTATION_VECTOR), so this does not need a live camera frame to
  /// sample, unlike oscillating's own per-camera-frame sampling.
  static const int _tiltPollMs = 60;

  // ---- phase 3: sweep stations ----
  // Real device feedback (2026-08-22): this phase should look exactly like
  // the real sweep architecture (sweep_capture_test's own
  // SweepCaptureController) -- ported its own real, validated timing
  // constants and mechanic (animated glide + content-driven readiness gate
  // + zoneCaptureFlash, no countdown) rather than the generic snap+settle
  // this phase used before. See _runSweepStations for the full mechanic.
  static const List<SweepStation> _sweepStations = [
    SweepStation('sweep_left', 0.0),
    SweepStation('sweep_center', 0.5),
    SweepStation('sweep_right', 1.0),
  ];
  /// Guide glide duration between zones -- matches the real architecture's
  /// own `_zoneMoveMs`.
  static const int _sweepZoneMoveMs = 1400;
  /// Content-driven per-zone readiness gate bounds -- matches the real
  /// architecture's own `_zoneReadyMinWaitMs`/`_zoneReadyMaxWaitMs`, reusing
  /// this phase's shared `_focusThreshold` (same relative-sharpness signal,
  /// same 0.45 threshold already validated for the front hold).
  static const int _sweepZoneReadyMinWaitMs = 300;
  static const int _sweepZoneReadyMaxWaitMs = 1400;
  static const int _sweepPhaseTimeoutMs = 60000;

  // ---- phase 4: macro (camera "2") close-up ----
  // Ported from clearbridge_beta's own front_capture_controller.dart
  // `_captureMacroShot` -- real, already-validated capture logic (rounds
  // 24-37: real ambient/flash-pair engagement, real focus-target
  // correction, real orientation fix), not a fresh design. Values kept
  // identical to that file's own constants, not re-derived, since they
  // were each calibrated against real device data specific to this exact
  // lens (camera "2"'s own measured pad offset/focus behaviour) that this
  // app has no independent way to re-measure.
  //
  // Real, direct motivation for porting this at all: fusion_brain's own
  // Phase 0/0b findings (tilt contributes real, non-redundant minutiae
  // that a face-on control does not) establish that DIFFERENT capture
  // geometry is what makes a source worth fusing. Macro is a third,
  // qualitatively different geometry -- closer working distance, a
  // physically different lens -- untested by this app until now. Per this
  // track's own standing discipline (fusion_brain/README.md, "why minutiae
  // space, not pixel space"), whether it is WORTH fusing is a premise to
  // measure once real capture data exists, not to assume -- this only
  // ports the CAPTURE, it does not change how fusion_brain treats it.
  static const String _macroCameraName = '2';
  static const double _macroGuideScaleFactor = 1.2;
  static const double _macroFocusTargetCy = 0.34;
  static const int _macroFocusMinMs = 1200;
  static const int _macroFocusMaxMs = 2400;
  static const int _macroCaptureTimeoutMs = 60000;
  // Real convergence-poll constants, identical to clearbridge_beta's own
  // _refocusPollIntervalMs/_refocusStableRatio/_refocusStableStreakRequired/
  // _refocusDriftAcceptRatio/_zoneFocusCallTimeout -- this app has no prior
  // need for a peak-tracking focus-convergence poll (its other phases rely
  // on continuous AF on one already-locked camera), so these did not exist
  // here before this port.
  static const int _macroPollIntervalMs = 150;
  static const double _macroStableRatio = 0.12;
  static const int _macroStableStreakRequired = 2;
  static const double _macroDriftAcceptRatio = 0.6;
  static const Duration _macroFocusCallTimeout = Duration(seconds: 3);

  // ---- pre-shutter countdown (real device feedback, 2026-08-22): every
  // station/burst previously fired the instant positioning finished, with
  // no final beat for the user to settle -- "it just fires without me
  // being ready". 700ms/tick matches this project's own already-validated
  // countdown cadence (front_capture_controller.dart's per-camera capture
  // sequence, "3…"/"2…"/"1… ~700ms apart"), not a fresh guess. ----
  static const int _countdownTickMs = 700;
  static const int _countdownGoHoldMs = 250;

  /// Same steadiness bound front_capture_controller.dart already validates
  /// (_maxSteadyDegPerSec) -- reused verbatim rather than re-guessed, since
  /// this is the identical question (is the PHONE moving enough to blur the
  /// shot right now), just asked continuously here instead of gating a hold.
  static const double _maxSteadyDegPerSec = 6.0;

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

  // live phone-motion signal, independent of the preview stream (device
  // sensor, not camera frames) -- see _maxSteadyDegPerSec.
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gyroMagnitudeDegPerSec = 0.0;
  bool _gyroSteadyLast = true;

  // Throttle for high-frequency callers (the per-frame lighting/focus meter
  // push from _onFrame) -- same "force param, else throttle" pattern
  // front_capture_controller.dart's own _apply already uses, ported rather
  // than reinvented. Every other call site in this file (hold/tilt/station
  // polls, phase transitions) already fires at a naturally bounded rate, so
  // they pass force: true and are unaffected.
  DateTime? _lastEmitAt;
  static const int _emitThrottleMs = 120;

  void _apply(FusionState Function(FusionState) f, {bool force = false}) {
    if (_disposed) return;
    _state = f(_state);
    final now = DateTime.now();
    if (force ||
        _lastEmitAt == null ||
        now.difference(_lastEmitAt!).inMilliseconds >= _emitThrottleMs) {
      _lastEmitAt = now;
      notifyListeners();
    }
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

    unawaited(_audio.init());
    _orientation.start();
    _gyroSteadyLast = true;
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
      final steady = _gyroMagnitudeDegPerSec < _maxSteadyDegPerSec;
      // Only push a state update when the STEADY/UNSTEADY verdict actually
      // flips, not on every raw sample -- gyro events arrive far faster
      // than any UI needs to redraw, and rebuilding on every sample would
      // just be wasted churn for a value the ring only shows as a colour.
      if (steady != _gyroSteadyLast) {
        _gyroSteadyLast = steady;
        _apply((s) => s.copyWith(gyroSteady: steady));
      }
    });

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
      if (_macroEnabled) {
        await _runMacroPhase();
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
      // Zero the tilt phase's orientation reference to whatever pose the
      // phone is actually in right now -- the same timing
      // oscillating_capture_controller.dart uses (captureReference() at its
      // own FRONT calibration). This is the user's natural hold, so every
      // later tilt target is measured relative to how THEY actually hold
      // the phone, not an arbitrary app-launch orientation.
      _orientation.captureReference();
      // The BURST needs its own bound too. Previously only the hold was
      // wrapped, leaving 8 raw takePicture() calls completely unprotected --
      // and this file's sibling in clearbridge_beta documents exactly why
      // that is not safe: takePicture() is a raw platform-channel await with
      // no timeout of its own, so try/catch alone cannot save a stalled
      // shutter. A hang there would strand the session before any upload,
      // losing the whole capture.
      await _fireFrontBurst()
          .timeout(const Duration(milliseconds: _burstTimeoutMs));
      // Decode/encode is deferred to _finishAndUpload now (see that
      // method's own docs) -- no shrink pass here.
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

  /// "3…2…1" pre-shutter beat: bold pulsing numeral (screen overlay, see
  /// fusion_capture_screen.dart), a tick + light haptic per count, then a
  /// distinct "go" tone/haptic right as the shutter is about to fire.
  ///
  /// Real device feedback (2026-08-22): every station previously fired the
  /// instant its settle delay elapsed, with nothing telling the user the
  /// shutter was about to go -- "it just fires without me being ready".
  /// This is the fix, shared by the front burst and every tilt/sweep
  /// station so the whole session has one consistent pre-capture beat, not
  /// three different conventions.
  ///
  /// Deliberately timing-only, not a gyro GATE -- it does not delay or
  /// re-run itself if the phone is currently unsteady. `state.gyroSteady`
  /// is already live throughout the whole session (see the gyro listener
  /// in `start()`) and the ring/banner reflect it in real time regardless
  /// of the countdown, so the user already has that signal without this
  /// needing to block on it. Blocking here would reintroduce exactly the
  /// kind of unpredictable extra delay item 1 (defer processing to the
  /// end) was about removing.
  Future<void> _runCountdown() async {
    for (final n in [3, 2, 1]) {
      if (_abortPhase || _disposed) return;
      _apply((s) => s.copyWith(countdownValue: n));
      unawaited(HapticFeedback.lightImpact());
      unawaited(_audio.playCountdownTick());
      await Future<void>.delayed(const Duration(milliseconds: _countdownTickMs));
    }
    if (_abortPhase || _disposed) return;
    _apply((s) => s.copyWith(countdownValue: 0));
    unawaited(HapticFeedback.mediumImpact());
    unawaited(_audio.playCountdownGo());
    await Future<void>.delayed(const Duration(milliseconds: _countdownGoHoldMs));
    _apply((s) => s.copyWith(clearCountdown: true));
  }

  Future<void> _fireFrontBurst() async {
    final cam = _camera;
    if (cam == null) return;
    await _runCountdown();
    if (_abortPhase || _disposed) return;
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
    // Front-only-v1's own visual confirmation the instant the burst
    // finishes ('✓ Captured' + a BRIGHT/FOCUS readout of the conditions it
    // was shot under) -- ported directly rather than leaving this phase's
    // completion silent. Dwells briefly so it's actually seen before the
    // tilt phase's own cue replaces it (cleared explicitly there).
    unawaited(HapticFeedback.mediumImpact());
    _apply((s) => s.copyWith(
          confirmationText: '✓ Captured',
          silhouetteState: PadSilhouetteState.locked,
        ), force: true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  // ------------------------------------------------------------------
  // phase 2 -- small-angle tilt
  // ------------------------------------------------------------------

  /// Ported from oscillating_capture_controller.dart's own running-phase
  /// mechanic (`_handleBurstFrame` + its `_BurstStep` model), not the
  /// discrete-station design this phase shipped with earlier this session.
  /// Real device feedback: the earlier UI showed WHICH station was active
  /// but nothing tracked whether the user had actually reached it -- "there
  /// is a degree measure when you tilt... before capture is taken" in
  /// oscillating, and this phase had no equivalent. `_orientation` (real
  /// device sensor, zeroed at the front hold -- see _runFrontPhase) now
  /// makes that literally true here too: each station is a real hold-until-
  /// locked at a live-tracked target angle, exactly like an oscillating
  /// burst step, just at this project's own smaller ~11 degree targets
  /// (fusion_brain Phase 0b) instead of oscillating's 15-20.
  ///
  /// Deliberately NOT ported: oscillating's CV-classifier confirmation and
  /// per-pose refocus-on-arrival. Neither exists in this app yet (no
  /// trained angle classifier, no wired AF refocus call) and neither was
  /// asked for -- the ask was the degree measure and hold-to-lock mechanic,
  /// which this delivers with the same live sensor oscillating itself uses.
  Future<void> _runTiltPhase() async {
    _apply((s) => s.copyWith(
          phase: FusionPhase.tilt,
          statusText: 'Phase 2 of 3 — Edge detail',
          detailText: 'Small tilts reveal the sides of your print',
          silhouetteState: PadSilhouetteState.aligning,
          guideShape: PadSilhouetteShape.defaultShape,
          phaseProgress: 0.0,
          stationsDone: 0,
          clearStationIndex: true,
          clearConfirmationText: true,
        ));
    final cam = _camera;
    if (cam == null) return;
    _tiltAngularVelocity = 0.0;
    _tiltLastAngleAt = null;
    try {
      for (var i = 0; i < _tiltStations.length; i++) {
        if (_abortPhase || _disposed) break;
        final station = _tiltStations[i];
        _debug['${station.key}_targetAngleDeg'] = station.targetAngleDeg;
        _tiltLastAngleAt = null; // crossing stations can change axis -- see
        // oscillating's own _lastAxis handling; drop the stale sample so it
        // can't register as a bogus angular-velocity spike.
        _apply((s) => s.copyWith(
              detailText: station.cue,
              silhouetteState: PadSilhouetteState.aligning,
              stationIndex: i,
              targetAngleDeg: station.targetAngleDeg,
            ));
        final held = await _awaitTiltAngleHold(station)
            .timeout(const Duration(milliseconds: _tiltPhaseTimeoutMs));
        if (!held) {
          _debug['${station.key}_holdTimedOut'] = true;
          continue; // best-effort -- move on to the next station rather
          // than losing the whole phase over one unreached angle.
        }
        if (_abortPhase || _disposed) break;

        await _runCountdown();
        if (_abortPhase || _disposed) break;

        _apply((s) => s.copyWith(silhouetteState: PadSilhouetteState.capturing));
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
              tag: '${station.key}_${wantFlash ? "fl" : "amb"}',
              flashOn: wantFlash,
              exif: parseJpegExposureExif(bytes),
            ));
          } catch (e) {
            debugPrint('[fusion] tilt station ${station.key} flash=$wantFlash failed: $e');
          } finally {
            if (wantFlash) await _flash?.deactivate();
          }
        }
        unawaited(HapticFeedback.heavyImpact());
        _apply((s) => s.copyWith(
              phaseProgress: (i + 1) / _tiltStations.length,
              overallProgress: 0.33 + 0.33 * ((i + 1) / _tiltStations.length),
              silhouetteState: PadSilhouetteState.locked,
              stationsDone: i + 1,
            ));
      }
      // Decode/encode is deferred to _finishAndUpload now.
    } on TimeoutException {
      _debug['tiltPhaseTimedOut'] = true;
      _abortPhase = true;
    } finally {
      _tiltAnglePoll?.cancel();
      _tiltAnglePoll = null;
      _abortPhase = false;
    }
  }

  /// Polls the real device angle on [station]'s own axis until it has sat
  /// within [_tiltHoldToleranceDeg] of the target for [_holdDurationMs],
  /// mirroring oscillating_capture_controller.dart's `_handleBurstFrame`.
  /// Owns its own Completer/Timer the same way `_awaitHold` does, so a
  /// caller-side `.timeout()` can stop WAITING without leaving the poll
  /// loop running in the background fighting the next station's UI.
  Future<bool> _awaitTiltAngleHold(TiltStation station) {
    final completer = Completer<bool>();
    DateTime? holdStart;
    _tiltAnglePoll?.cancel();
    void finish(bool ok) {
      _tiltAnglePoll?.cancel();
      _tiltAnglePoll = null;
      if (!completer.isCompleted) completer.complete(ok);
    }

    _tiltAnglePoll = Timer.periodic(const Duration(milliseconds: _tiltPollMs), (_) {
      if (_disposed || _abortPhase) {
        finish(false);
        return;
      }
      final orient = _orientation.relativeOrientation();
      final angle = station.axis == TiltAxis.roll ? orient.roll : orient.pitch;

      final now = DateTime.now();
      if (_tiltLastAngleAt != null) {
        final dt = now.difference(_tiltLastAngleAt!).inMicroseconds / 1e6;
        if (dt > 0.001) {
          final raw = (angle - _tiltLastAngle).abs() / dt;
          _tiltAngularVelocity = HybridCaptureService.ema(_tiltAngularVelocity, raw, alpha: 0.35);
        }
      }
      _tiltLastAngle = angle;
      _tiltLastAngleAt = now;

      final dist = (angle - station.targetAngleDeg).abs();
      final tooFast = _tiltAngularVelocity > _tiltMaxAngularVelocityDegPerSec;

      if (dist <= _tiltHoldToleranceDeg && !tooFast) {
        holdStart ??= DateTime.now();
        final heldMs = DateTime.now().difference(holdStart!).inMilliseconds;
        final progress = (heldMs / _holdDurationMs).clamp(0.0, 1.0);
        _apply((s) => s.copyWith(
              currentAngleDeg: angle,
              deltaDeg: angle - station.targetAngleDeg,
              onTarget: true,
              holdProgress: progress,
              angularVelocityDegPerSec: _tiltAngularVelocity,
              tooFast: false,
            ));
        if (heldMs >= _holdDurationMs) finish(true);
      } else {
        holdStart = null;
        _apply((s) => s.copyWith(
              currentAngleDeg: angle,
              deltaDeg: angle - station.targetAngleDeg,
              onTarget: false,
              holdProgress: 0.0,
              angularVelocityDegPerSec: _tiltAngularVelocity,
              tooFast: tooFast,
            ));
      }
    });
    return completer.future;
  }

  // ------------------------------------------------------------------
  // phase 3 -- sweep with light
  // ------------------------------------------------------------------

  Future<void> _runSweepPhase() async {
    _apply((s) => s.copyWith(
          phase: FusionPhase.sweep,
          statusText: 'Phase 3 of 3 — Texture',
          // Sweep's own real cue text lives entirely in distanceHint (see
          // _runSweepStations) -- detailText is left at whatever the tilt
          // phase last set, harmlessly, since the screen suppresses the
          // bottom instruction text for this phase (matching how it
          // already suppresses it for tilt, for the same "one banner, not
          // two" reason).
          phaseProgress: 0.0,
          stationsDone: 0,
          clearStationIndex: true,
          zoneCaptureFlash: false,
          guideShape: _sweepGuideFor(_sweepStations[0]),
        ));
    // Real sweep architecture keeps the preview stream open for the WHOLE
    // zone loop so its content-driven readiness gate has a live signal --
    // see _runSweepStations. This is a fresh open on top of an
    // already-initialised camera controller (front phase already opened
    // and cleanly closed its own stream on this exact controller earlier
    // in the same session), not a reopen of a still-active session -- the
    // documented real ANR this project hit (2026-07-30) was from
    // reopening an image stream MID-sweep, which this is not.
    await _startStream();
    try {
      await _runSweepStations()
          .timeout(const Duration(milliseconds: _sweepPhaseTimeoutMs));
      // Decode/encode is deferred to _finishAndUpload now.
    } on TimeoutException {
      _debug['sweepPhaseTimedOut'] = true;
      _abortPhase = true;
    } finally {
      _abortPhase = false;
      await _stopStream();
    }
  }

  /// Real sweep-architecture hint text per zone, matching
  /// sweep_capture_test's own SweepCaptureController phrasing verbatim --
  /// the actual "sweep architecture we built" this phase is meant to look
  /// like.
  String _sweepHintFor(SweepStation z) {
    switch (z.key) {
      case 'sweep_left':
        return 'Slowly move left';
      case 'sweep_right':
        return 'Slowly move right';
      default:
        return 'Slowly move to the middle';
    }
  }

  /// Sweep-phase zone loop, ported from the real sweep architecture's own
  /// zone loop (sweep_capture_test/lib/sweep_capture_controller.dart)
  /// rather than the generic snap-to-position + fixed-settle-and-countdown
  /// this phase used before. Real device feedback asked for this phase to
  /// "look exactly like the sweep architecture we built" -- and that
  /// architecture's visual identity IS this loop: the guide glides
  /// continuously between zones (never snaps), a content-driven readiness
  /// gate replaces any fixed wait, and the guide flips to its green
  /// "locked" highlight (zoneCaptureFlash) only for the real duration of a
  /// zone's own shutter sequence -- not a verbal countdown, which that
  /// architecture's own real history explicitly REMOVED (2026-08-14,
  /// "allow the camera to pick up if thumb is in mask").
  ///
  /// Deliberately narrower than the full real controller: no torch EV
  /// curve, no gyro motion gate, no live wavelength distance gate, no
  /// second ambient stacking shot -- those are capture-QUALITY mechanics
  /// this phase's existing flash handling and the shared phase timeouts
  /// already cover reasonably, and porting them is a materially bigger
  /// lift than what was asked (visual/UX parity with the real
  /// architecture). If real device data ever shows this phase needs them,
  /// port from the same source file.
  Future<void> _runSweepStations() async {
    final cam = _camera;
    if (cam == null) return;
    for (var i = 0; i < _sweepStations.length; i++) {
      if (_abortPhase || _disposed) break;
      final station = _sweepStations[i];
      final zr = _guideRegionFor(_sweepGuideFor(station));
      if (zr != null) _guideRegions[station.key] = zr;

      // Animated glide from wherever the guide last was to this zone --
      // the real architecture's own tween (_zoneMoveMs), replacing the old
      // instant snap.
      final from = i == 0 ? _sweepStations[0] : _sweepStations[i - 1];
      final moveStart = DateTime.now();
      while (true) {
        if (_abortPhase || _disposed) break;
        final elapsed = DateTime.now().difference(moveStart).inMilliseconds;
        final t = (elapsed / _sweepZoneMoveMs).clamp(0.0, 1.0);
        final progress = from.progress + (station.progress - from.progress) * t;
        final dyFrac = from.dyFrac + (station.dyFrac - from.dyFrac) * t;
        // Real sweep architecture drives its whole hint banner off ONE
        // field (distanceHint), sequentially overwritten as the zone
        // progresses through glide -> ready -> capture -- matched here
        // rather than splitting glide-direction text into detailText,
        // which would leave a stale "Hold still" message on screen
        // through the NEXT zone's glide if not separately cleared.
        _apply((s) => s.copyWith(
              distanceHint: _sweepHintFor(station),
              guideShape:
                  _sweepGuideFor(SweepStation(station.key, progress, dyFrac: dyFrac)),
              stationIndex: i,
              silhouetteState: PadSilhouetteState.capturing,
            ), force: true);
        if (t >= 1.0) break;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      if (_abortPhase || _disposed) break;

      // Content-driven readiness gate -- same real signal/threshold as the
      // primary front hold (_focusValue >= _focusThreshold), applied per
      // zone instead of once, matching the real sweep architecture's own
      // _zoneReadyFocusThreshold gate. Fresh peak per zone so an earlier,
      // sharper zone's peak can't starve this zone's own relative signal
      // toward the max-wait fallback.
      _focusPeak = 0.0;
      final zoneLabel = station.key.replaceFirst('sweep_', '');
      _apply((s) => s.copyWith(distanceHint: 'Hold still — capturing $zoneLabel'),
          force: true);
      final readyStart = DateTime.now();
      var readyDetected = false;
      while (DateTime.now().difference(readyStart).inMilliseconds <
          _sweepZoneReadyMaxWaitMs) {
        if (_abortPhase || _disposed) break;
        final elapsed = DateTime.now().difference(readyStart).inMilliseconds;
        if (elapsed >= _sweepZoneReadyMinWaitMs && _focusValue >= _focusThreshold) {
          readyDetected = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      _debug['${station.key}_readyDetected'] = readyDetected;
      if (_abortPhase || _disposed) break;

      // Visual "capturing now" cue -- flips the guide to green/locked for
      // the real duration of the shutter sequence, replacing the removed
      // verbal countdown.
      unawaited(HapticFeedback.mediumImpact());
      _apply((s) => s.copyWith(
            zoneCaptureFlash: true,
            silhouetteState: PadSilhouetteState.locked,
          ), force: true);

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
            tag: '${station.key}_${wantFlash ? "fl" : "amb"}',
            flashOn: wantFlash,
            exif: parseJpegExposureExif(bytes),
          ));
        } catch (e) {
          debugPrint('[fusion] sweep station ${station.key} flash=$wantFlash failed: $e');
        } finally {
          if (wantFlash) await _flash?.deactivate();
        }
      }
      unawaited(HapticFeedback.heavyImpact());
      _apply((s) => s.copyWith(
            phaseProgress: (i + 1) / _sweepStations.length,
            overallProgress: 0.66 + 0.33 * ((i + 1) / _sweepStations.length),
            zoneCaptureFlash: false,
            stationsDone: i + 1,
          ), force: true);
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
  // ------------------------------------------------------------------
  // phase 4 -- macro (camera "2") close-up
  // ------------------------------------------------------------------

  /// Real, measured focus convergence for a camera this app has not
  /// previously needed to retarget mid-session (every other phase runs on
  /// one already-locked camera with continuous AF). Ported verbatim from
  /// clearbridge_beta's `_retargetAndConverge` -- peak-tracking with one
  /// drift retry, not a blind delay, per this project's own hard-learned
  /// lesson (front_capture_controller.dart's own history: "secondary-camera
  /// focus now actually measured, not guessed"). Polls the SAME
  /// `_liveAbsSharpness` field `_onFrame` writes for the other phases; safe
  /// to share since this only ever runs after the front/tilt/sweep image
  /// stream has already been stopped (`_runMacroPhase` starts its own,
  /// separate listener below), so there is no concurrent writer to race.
  Future<double?> _retargetAndConvergeMacro(CameraController cam, Offset pt,
      {int minMs = _macroFocusMinMs,
      int maxMs = _macroFocusMaxMs,
      Map<String, dynamic>? debugOut}) async {
    double? lastSample;
    var maxSample = 0.0;
    var driftRetried = false;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await cam.setFocusMode(FocusMode.auto).timeout(_macroFocusCallTimeout);
        await cam.setFocusPoint(pt).timeout(_macroFocusCallTimeout);
        await cam.setExposurePoint(pt).timeout(_macroFocusCallTimeout);
      } catch (_) {}
      lastSample = _liveAbsSharpness;
      var stableStreak = 0;
      final pollSw = Stopwatch()..start();
      while (pollSw.elapsedMilliseconds < maxMs) {
        await Future<void>.delayed(const Duration(milliseconds: _macroPollIntervalMs));
        if (_disposed) break;
        final sample = _liveAbsSharpness;
        if (sample != null && sample > 0) {
          if (sample > maxSample) maxSample = sample;
          if (lastSample != null && lastSample! > 0) {
            final change = (sample - lastSample!).abs() / lastSample!;
            stableStreak = change < _macroStableRatio ? stableStreak + 1 : 0;
          }
          lastSample = sample;
        }
        if (pollSw.elapsedMilliseconds >= minMs &&
            stableStreak >= _macroStableStreakRequired) {
          break;
        }
      }
      final driftedLow = attempt == 1 &&
          maxSample > 0 &&
          lastSample != null &&
          lastSample! < maxSample * _macroDriftAcceptRatio &&
          !_disposed;
      if (!driftedLow) break;
      driftRetried = true;
    }
    try {
      await cam.setFocusMode(FocusMode.locked).timeout(_macroFocusCallTimeout);
    } catch (_) {}
    if (debugOut != null) {
      debugOut['sharpness'] = lastSample;
      debugOut['maxSample'] = maxSample;
      debugOut['driftRetried'] = driftRetried;
    }
    return lastSample;
  }

  /// Dedicated final capture on camera "2" (the macro/close-up lens),
  /// ported from clearbridge_beta's own `_captureMacroShot`
  /// (front_capture_controller.dart) -- real, already-validated capture
  /// logic, not new design. Guide grown `_macroGuideScaleFactor` (20%)
  /// larger than the standard shape, same explicit direction as the
  /// source: pull the thumb physically closer to this lens.
  ///
  /// Self-skipping at every step (missing camera id, failed open, failed
  /// capture, failed upload) -- can only ever ADD a fourth candidate
  /// source, never block or regress the front/tilt/sweep phases that
  /// already ran. Real, deliberate cost: one more camera open/close cycle,
  /// one focus convergence, two shutter presses (ambient + flash) on top
  /// of the three phases before it.
  Future<void> _runMacroPhase() async {
    _apply((s) => s.copyWith(
          phase: FusionPhase.macro,
          statusText: 'Phase 4 of 4 — Close-up detail',
          phaseProgress: 0.0,
          clearStationIndex: true,
          zoneCaptureFlash: false,
        ));
    try {
      await (() async {
        final cams = await _cameraService.getAvailableCameras();
        CameraDescription? macroDesc;
        for (final c in cams) {
          if (c.lensDirection == CameraLensDirection.back &&
              c.name == _macroCameraName) {
            macroDesc = c;
            break;
          }
        }
        if (macroDesc == null) {
          debugPrint('[fusion] macro camera ($_macroCameraName) not present, skipping');
          _debug['macroCameraAbsent'] = true;
          return;
        }

        _apply(
          (s) => s.copyWith(
            confirmationText: 'Capturing close-up detail…',
            guideShape: PadSilhouetteShape.defaultShape.scaled(_macroGuideScaleFactor),
          ),
          force: true,
        );
        unawaited(HapticFeedback.lightImpact());

        await _cameraService.initializeCamera(cameraDescription: macroDesc);
        final macroCam = _camera;
        if (macroCam == null) return;
        // Same real bug/fix as clearbridge_beta: the screen's camera layer
        // only rebuilds on this controller's own notifyListeners(), and the
        // one _apply call above ran BEFORE initializeCamera() finished
        // swapping -- force a fresh emit now that the new controller is
        // actually ready, or the preview can render solid black.
        _apply((s) => s, force: true);

        _liveAbsSharpness = null;
        // Real measured pad offset for this lens (_macroFocusTargetCy),
        // not frame-centre -- see clearbridge_beta's own round-33 finding
        // this is ported from: camera "2"'s pad sits at cy~0.34, and
        // autofocus/sharpness-ROI aimed at 0.5 was measurably tracking
        // background/crease content instead.
        const macroRoi = Rect.fromLTWH(0.25, 0.15, 0.5, 0.4);
        void macroFrameListener(CameraImage image) {
          try {
            final raw = _hybrid.offerFrame(image, thumbRoi: macroRoi);
            _liveAbsSharpness = HybridCaptureService.ema(_liveAbsSharpness ?? raw, raw);
          } catch (_) {}
        }
        await macroCam.startImageStream(macroFrameListener);
        final focusDebug = <String, dynamic>{};
        final focusSw = Stopwatch()..start();
        try {
          await _retargetAndConvergeMacro(
              macroCam, const Offset(0.5, _macroFocusTargetCy),
              debugOut: focusDebug);
        } finally {
          try {
            await macroCam.stopImageStream();
          } catch (_) {}
        }
        focusDebug['convergedMs'] = focusSw.elapsedMilliseconds;
        _debug['macroDebug'] = focusDebug;

        // Ambient+flash pair (not a single shot) so the backend's real
        // flash-diff segmentation can engage for this candidate -- same
        // real fix/reasoning as clearbridge_beta round 34: a single macro
        // frame has never had any content-aware masking available to it.
        Uint8List? flashJpeg;
        try {
          try {
            final minEv = await macroCam.getMinExposureOffset().timeout(_macroFocusCallTimeout);
            final maxEv = await macroCam.getMaxExposureOffset().timeout(_macroFocusCallTimeout);
            await macroCam
                .setExposureOffset((-1.0).clamp(minEv, maxEv))
                .timeout(_macroFocusCallTimeout);
          } catch (_) {}
          await macroCam.setFlashMode(FlashMode.torch).timeout(_macroFocusCallTimeout);
          await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
          final flXfile = await macroCam.takePicture();
          flashJpeg = await flXfile.readAsBytes();
        } catch (e) {
          debugPrint('[fusion] macro flash shot failed (non-fatal, ambient-only): $e');
        } finally {
          try {
            await macroCam.setFlashMode(FlashMode.off).timeout(_macroFocusCallTimeout);
          } catch (_) {}
          try {
            await macroCam.setExposureOffset(0.0).timeout(_macroFocusCallTimeout);
          } catch (_) {}
        }

        final xfile = await macroCam.takePicture();
        final ambJpeg = await xfile.readAsBytes();
        final ambExif = parseJpegExposureExif(ambJpeg);
        // Tagged with the MACRO camera's own sensorOrientation, not the
        // cached main-camera _sensorOrientation -- a different physical
        // lens module could in principle be mounted at a different
        // rotation. _shrinkCaptured() (called later, for every OTHER shot)
        // always uses _sensorOrientation, so these two macro shots are
        // shrunk here instead, immediately, with the correct orientation,
        // and marked already-shrunk so the shared pass skips them.
        final ambShot = _Shot(
          jpeg: await _shrinkForUpload(ambJpeg, macroDesc.sensorOrientation),
          tag: 'macro_amb_0',
          flashOn: false,
          exif: ambExif,
        )..shrunk = true;
        _shots.add(ambShot);

        if (flashJpeg != null) {
          final flExif = parseJpegExposureExif(flashJpeg);
          final flShot = _Shot(
            jpeg: await _shrinkForUpload(flashJpeg, macroDesc.sensorOrientation),
            tag: 'macro_fl_0',
            flashOn: true,
            exif: flExif,
          )..shrunk = true;
          _shots.add(flShot);
        }

        _apply((s) => s.copyWith(confirmationText: '✓ Close-up captured'), force: true);
      }())
          .timeout(const Duration(milliseconds: _macroCaptureTimeoutMs));
    } catch (e) {
      debugPrint('[fusion] macro phase failed (non-fatal): $e');
      _debug['macroPhaseFailed'] = e.toString();
    }
  }

  /// Called ONCE, from `_finishAndUpload`, after all three phases are done
  /// -- not per-phase. It used to run at each phase boundary specifically
  /// to bound peak memory (~8 raw frames instead of ~20), but real device
  /// feedback was that the felt pause it caused between phases read as
  /// resistance mid-session. Still per-shot (never inline during the
  /// 8-shot burst itself) for the original, still-valid reason: a decode
  /// between shots would stretch a ~2s burst to ~10s and let the finger
  /// drift, defeating the same-pose stacking the burst exists for.
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
      // Live-push to FusionState (throttled, see _apply) so the front-phase
      // BRIGHT/FOCUS meters read live -- front_only_v1's own meters read
      // straight off the controller's live value every rebuild; this app's
      // state is immutable/notify-driven, so the value has to be pushed
      // instead of polled. The hold-poll timer already refreshes the UI at
      // 10Hz while a hold is active, but this covers the window before a
      // hold starts and keeps the meters live even when on-target (where
      // the hold poll's own _apply calls stop varying).
      _apply((s) => s.copyWith(
            lightingValue: _coverage,
            focusValue: _focusValue,
          ));
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
          statusText: 'Processing captured images…',
          detailText: '',
          overallProgress: 1.0,
        ));
    try {
      await _cameraService.disposeCamera();
    } catch (_) {}

    // REAL DEVICE FEEDBACK (2026-08-22): decode/encode used to run at the
    // end of EACH phase (see the phase methods' own "Decode/encode is
    // deferred" comments) so peak memory stayed bounded to one phase's raw
    // frames at a time -- but that meant a real, felt pause dropped in
    // between every phase, mid-session, reading as resistance ("as if
    // images are processing immediately"). All of it now happens here
    // instead, in ONE pass, after the user's part of the session is
    // completely over -- the only place a processing pause is expected
    // rather than a surprise. Real, deliberate trade: peak memory is now
    // every raw shot from all three phases at once (front+tilt+sweep, up
    // to 20 frames) instead of one phase's worth -- accepted because the
    // pre-shrink build already held a full 20-shot raw session in memory
    // end-to-end without an OOM (its real failure was upload TIME at full
    // resolution, never a crash) -- real precedent this is safe on the
    // device this was tested on, not just an assumption.
    await _shrinkCaptured();

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
    final macroShots = <Map<String, dynamic>>[];

    final sensorOrientation = _sensorOrientation;

    // REAL DEVICE BUG (2026-08-22, capture ffb1682f): the front burst -- the
    // one anchor this whole experiment cannot function without -- uploaded
    // 0/8 frames, EVERY one hitting the full 45s timeout on BOTH retry
    // attempts (a contiguous ~12-minute dead stretch: 8 shots x 2 attempts x
    // 45s), while every later tilt/sweep shot on the SAME capture uploaded
    // cleanly once the loop reached them. Root cause of the old shape: retry
    // was PER-SHOT (try, wait up to 45s, retry, wait up to 45s again, THEN
    // move to the next shot) -- so a transient connectivity gap at the START
    // of the loop burns the entire retry budget of every shot unlucky enough
    // to be first, one at a time, before the loop ever reaches a shot that
    // would have succeeded once the network recovered. Restructured into two
    // passes ACROSS all shots instead: pass 1 tries every shot once with a
    // short timeout, so a bad stretch is discovered quickly rather than paid
    // for per-shot; pass 2 retries only what failed, after a short backoff,
    // with the full timeout. A transient outage now costs one fast pass
    // through the whole batch, not 90s+ multiplied by however many shots
    // happen to go first -- and specifically protects the front anchor from
    // being wiped out by bad luck in upload order.
    const firstPassTimeout = Duration(seconds: 20);
    const retryBackoff = Duration(seconds: 3);

    // REAL DATA-LOSS BUG (found 2026-08-26 by auditing capture ffb1682f's
    // own bytes in Storage, not from the client's own logs -- which were
    // the thing that turned out to be wrong).
    //
    // That capture recorded `frames: []` with an `uploadFailed_front_*`
    // TimeoutException for all 8 front frames. Storage told a different
    // story:
    //
    //   front_amb_0.jpg  2,097,152 bytes (exactly 2 MiB), NO JPEG EOI
    //                    marker -> genuinely truncated at a buffer boundary
    //   the other 7      valid EOI marker -> complete, perfectly usable
    //
    // So SEVEN uploads actually completed and were thrown away, because
    // `putData(...).timeout(...)` only abandons the DART future -- it does
    // not cancel the native upload, which carries on and finishes. The
    // client sees a TimeoutException, records the frame as failed, and
    // omits it from `frames`. Result: a capture 7/8 intact in Storage but
    // entirely invisible to everything that reads the document, the
    // production backend included. The two-pass restructure above reduces
    // how OFTEN a timeout fires; it cannot help once one has, because the
    // verdict itself is wrong.
    //
    // The eighth frame is the mirror-image failure: a partial object left
    // behind by an abandoned upload, sitting in Storage looking like a real
    // file. Nothing downstream checks -- cv2 decodes a truncated JPEG
    // happily (it only warns), and the garbage in the missing region
    // actually INFLATES sharpness metrics, so a corrupt frame can score as
    // the SHARPEST and be picked as the fusion anchor. That is not
    // hypothetical: it happened while analysing this exact capture.
    //
    // Both halves need the same missing mechanism -- ask Storage what
    // actually landed instead of trusting (or distrusting) the timeout.
    // Byte length is the check, since it catches both the abandoned-but-
    // complete case and the truncated case, and needs no image decode.
    Future<bool> storedObjectIsComplete(String path, int expectedBytes) async {
      try {
        final md = await _storage
            .ref(path)
            .getMetadata()
            .timeout(const Duration(seconds: 10));
        return md.size == expectedBytes;
      } catch (_) {
        // Object absent, or metadata unreachable -- either way we cannot
        // claim it landed. Deliberately conservative: a false "incomplete"
        // costs one retry, a false "complete" silently ships a corrupt
        // frame into the pipeline.
        return false;
      }
    }

    Future<void> deletePartialObject(String path, String tag) async {
      try {
        await _storage.ref(path).delete().timeout(const Duration(seconds: 10));
        _debug['deletedPartial_$tag'] = true;
      } catch (_) {
        // Nothing there to delete, or the delete failed -- not worth
        // failing the capture over. Recorded rather than silently dropped
        // so a partial object that survives is at least traceable.
        _debug['deletePartialFailed_$tag'] = true;
      }
    }

    Future<bool> attemptUpload(_Shot shot, Duration timeout) async {
      // Normally already shrunk at its phase boundary; this only does real
      // work if a phase timed out before its shrink pass ran.
      if (!shot.shrunk) {
        shot.jpeg = await _shrinkForUpload(shot.jpeg, sensorOrientation);
        shot.shrunk = true;
      }
      final path = '$basePath/${shot.tag}.jpg';
      final expected = shot.jpeg.length;
      try {
        await _storage
            .ref(path)
            .putData(shot.jpeg, SettableMetadata(contentType: 'image/jpeg'))
            .timeout(timeout);
      } catch (e) {
        debugPrint('[fusion] upload threw ${shot.tag}: $e');
        // The upload may well have finished anyway (see above). Ask.
        if (await storedObjectIsComplete(path, expected)) {
          debugPrint('[fusion] ${shot.tag} landed complete despite $e');
          _debug['uploadRecovered_${shot.tag}'] = e.toString();
          return true;
        }
        _debug['uploadFailed_${shot.tag}'] = e.toString();
        // Whatever partial bytes are up there must not masquerade as a
        // real frame on a later pass, or to the backend.
        await deletePartialObject(path, shot.tag);
        return false;
      }
      // putData returning normally is not proof the stored object is whole
      // -- verify the same way, so a truncated upload can never be reported
      // as success.
      if (await storedObjectIsComplete(path, expected)) {
        return true;
      }
      debugPrint('[fusion] upload incomplete ${shot.tag} (expected $expected)');
      _debug['uploadIncomplete_${shot.tag}'] = expected;
      await deletePartialObject(path, shot.tag);
      return false;
    }

    final uploadedTags = <String>{};
    var done = 0;
    final total = _shots.length;

    // Pass 1: one fast attempt per shot, in order.
    final failedFirstPass = <_Shot>[];
    for (final shot in _shots) {
      _apply((s) => s.copyWith(
            statusText: 'Uploading ${done + 1} of $total…',
          ));
      final ok = await attemptUpload(shot, firstPassTimeout);
      if (ok) {
        uploadedTags.add(shot.tag);
        done++;
        _debug.remove('uploadFailed_${shot.tag}');
      } else {
        failedFirstPass.add(shot);
      }
    }

    // Pass 2: retry only failures, after a short backoff -- by now whatever
    // transient condition caused pass 1's failures has had real time to
    // clear -- with the full, longer timeout for genuinely slow links.
    if (failedFirstPass.isNotEmpty) {
      await Future.delayed(retryBackoff);
      for (final shot in failedFirstPass) {
        _apply((s) => s.copyWith(
              statusText: 'Retrying upload ${done + 1} of $total…',
            ));
        final ok = await attemptUpload(shot, _uploadTimeout);
        if (ok) {
          uploadedTags.add(shot.tag);
          done++;
          _debug.remove('uploadFailed_${shot.tag}');
        }
      }
    }

    for (final shot in _shots) {
      if (!uploadedTags.contains(shot.tag)) continue;
      final path = '$basePath/${shot.tag}.jpg';
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
      } else if (shot.tag.startsWith('macro_')) {
        // Real bug caught before it shipped: this bucketing used to be a
        // bare `else -> sweepShots`, which would have silently swallowed
        // every macro_* tag into sweepShots the moment this phase's shots
        // started landing in `_shots` -- corrupting sweepShots with frames
        // from a completely different camera/geometry, invisibly, since
        // nothing about the shape of a Map<String,dynamic> would reveal
        // the mistake. Macro gets its own explicit branch and its own
        // Firestore field for the same reason tilt/sweep each already do.
        macroShots.add(meta);
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
          'macro': _macroEnabled,
        },
        'status': 'pending',
        'nfiqScore': 0,
        'nfiqPass': false,
        'createdAt': FieldValue.serverTimestamp(),
        'guideRegion': _guideRegions['main'],
        'frames': frames,
        if (tiltShots.isNotEmpty) 'tiltShots': tiltShots,
        if (sweepShots.isNotEmpty) 'sweepShots': sweepShots,
        if (macroShots.isNotEmpty) 'macroShots': macroShots,
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
    unawaited(_gyroSub?.cancel());
    _gyroSub = null;
    _tiltAnglePoll?.cancel();
    _tiltAnglePoll = null;
    _orientation.dispose();
    _audio.dispose();
    unawaited(_cameraService.disposeCamera());
    super.dispose();
  }
}
