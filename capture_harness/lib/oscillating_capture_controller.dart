import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image/image.dart' as imglib;
import 'package:mac_capture/mac_capture.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Cropped single-channel (luma) frame ready for JPEG encoding in a
/// background isolate -- see [_encodeGrayJpegIsolate].
class _GrayCrop {
  final Uint8List bytes;
  final int width;
  final int height;
  const _GrayCrop(this.bytes, this.width, this.height);
}

/// Top-level so it can run in a `compute()` isolate -- JPEG encoding is CPU-
/// heavy enough (called up to ~30x/sec during transitions) that doing it
/// synchronously on the UI isolate inside the camera frame callback caused
/// visible preview lag/jank. Only the crop step (a cheap memcpy, done by
/// OscillatingCaptureController._cropFrameGray) stays on the UI isolate;
/// the actual encode moves off it via compute() in _handleTransitionFrame.
Uint8List _encodeGrayJpegIsolate(_GrayCrop crop) {
  final imgObj = imglib.Image.fromBytes(
    width: crop.width,
    height: crop.height,
    bytes: crop.bytes.buffer,
    numChannels: 1,
  );
  return Uint8List.fromList(imglib.encodeJpg(imgObj, quality: 88));
}

/// Decoded-but-not-yet-JPEG-encoded burst still, ready for
/// [_encodeBurstStillIsolate]. See _fireBurst -- the raw ISP JPEG a burst
/// shot decodes to is already downscaled by decodeStillJpegToLuma (from
/// package:mac_capture) by the time this exists, so this buffer is small
/// (~2048px wide luma) even though the source JPEG was 11-29MB.
class _BurstEncodeArgs {
  final Uint8List luma;
  final int width;
  final int height;
  const _BurstEncodeArgs(this.luma, this.width, this.height);
}

/// Top-level so it can run in a compute() isolate -- see _fireBurst for why
/// only the encode (not the decode) is deferred like this.
Uint8List _encodeBurstStillIsolate(_BurstEncodeArgs args) =>
    encodeGrayscaleJpeg(args.luma, args.width, args.height);

/// A single burst shot straight off the ISP, before decode/downscale --
/// held only long enough to get through the shot loop at full cadence, see
/// _fireBurst for why decode/encode happen after the loop instead of inline.
class _RawBurstShot {
  final Uint8List jpeg;
  final int phaseNumber;
  final double angleDeg;
  final DateTime timestamp;
  final bool flashOn;
  final double? laplacianScore;
  const _RawBurstShot({
    required this.jpeg,
    required this.phaseNumber,
    required this.angleDeg,
    required this.timestamp,
    required this.flashOn,
    required this.laplacianScore,
  });
}

/// A burst shot's metadata, captured synchronously at shot time, paired
/// with its still-encoding JPEG bytes future -- see _fireBurst.
class _PendingBurstShot {
  final int phaseNumber;
  final double angleDeg;
  final DateTime timestamp;
  final bool flashOn;
  final double? laplacianScore;
  final Future<Uint8List> encodedBytes;
  const _PendingBurstShot({
    required this.phaseNumber,
    required this.angleDeg,
    required this.timestamp,
    required this.flashOn,
    required this.laplacianScore,
    required this.encodedBytes,
  });
}

/// Which Euler component of [RelativeOrientation] a burst step's targetDeg
/// is measured against. LEFT/RIGHT are a left-right pan (device Y axis =
/// pitch, per DeviceOrientationService's naming); TOP is a nose-up/down tilt
/// (device X axis = roll) -- a physically different motion that was
/// previously (incorrectly) also read off pitch, which is why the TOP hold
/// never felt calibrated: the sensor value driving its dial didn't actually
/// track the "tilt thumb up" motion the user was asked to perform.
enum _AngleAxis { pitch, roll }

/// One of the 8 fixed positions the user holds still at while the ISP fires
/// a burst of real [CameraController.takePicture] stills.
class _BurstStep {
  final double targetDeg;
  final String label;
  final String instruction;
  final _AngleAxis axis;
  const _BurstStep({
    required this.targetDeg,
    required this.label,
    required this.instruction,
    this.axis = _AngleAxis.pitch,
  });
}

/// A slow continuous move between two burst positions, broken into waypoints
/// the user is guided through in order. Frames are extracted from the live
/// preview stream throughout (not real stills — there's no ISP budget for
/// that while the phone is actually moving).
class _TransitionStep {
  final double fromDeg;
  final double toDeg;
  final List<double> waypoints; // in traversal order; last == toDeg
  final String label; // the position being moved toward
  final String instruction;
  const _TransitionStep({
    required this.fromDeg,
    required this.toDeg,
    required this.waypoints,
    required this.label,
    required this.instruction,
  });
}

/// The 8-phase oscillating sequence: front → left → front → right → front →
/// top, alternating burst holds with guided transitions. FRONT/LEFT/RIGHT
/// share a single signed angle (the device's relative pitch — the same axis
/// [ThumbAngleService] uses for the left/right orbit in the 4-angle flow);
/// TOP is measured on roll instead -- see [_AngleAxis].
final List<Object> oscillatingSteps = [
  const _BurstStep(
    targetDeg: 0,
    label: 'FRONT',
    instruction: 'Position thumb at FRONT. Keep steady.',
  ),
  const _TransitionStep(
    fromDeg: 0,
    toDeg: -20,
    waypoints: [-7, -13, -20],
    label: 'LEFT',
    instruction: 'Move SLOWLY to the LEFT.',
  ),
  const _BurstStep(
    targetDeg: -20,
    label: 'LEFT',
    instruction: 'Hold STEADY at LEFT (-20°). Capturing…',
  ),
  const _TransitionStep(
    fromDeg: -20,
    toDeg: 0,
    waypoints: [-13, -7, 0],
    label: 'FRONT',
    instruction: 'Move SLOWLY back to FRONT.',
  ),
  const _TransitionStep(
    fromDeg: 0,
    toDeg: 20,
    waypoints: [7, 13, 20],
    label: 'RIGHT',
    instruction: 'Move SLOWLY to the RIGHT.',
  ),
  const _BurstStep(
    targetDeg: 20,
    label: 'RIGHT',
    instruction: 'Hold STEADY at RIGHT (+20°). Capturing…',
  ),
  const _TransitionStep(
    fromDeg: 20,
    toDeg: 0,
    waypoints: [13, 7, 0],
    label: 'FRONT',
    instruction: 'Move SLOWLY back to FRONT.',
  ),
  const _BurstStep(
    targetDeg: -15,
    label: 'TOP',
    // Positive roll tilts the camera's aim upward (see _AngleAxis) -- to
    // see over the top of the thumb tip the phone needs to tilt DOWN
    // instead, so the target and this instruction are both negative-roll.
    instruction: 'Tilt phone DOWN, looking over the top of your thumb.',
    axis: _AngleAxis.roll,
  ),
];

enum OscillatingPhase { idle, calibrating, running, uploading, complete, error }

class OscillatingCaptureState {
  final OscillatingPhase phase;
  final int stepIndex; // 0..7, meaningful once phase == running
  final bool isBurstStep;
  final String phaseLabel;
  final String instruction;
  final double currentAngleDeg;
  final double targetAngleDeg;
  final double deltaDeg; // currentAngleDeg - targetAngleDeg, signed
  final bool onTarget;
  final double holdProgress; // 0..1, burst steps only
  final int waypointIndex; // 0-based, transition steps only
  final int waypointTotal;
  final double angularVelocityDegPerSec;
  final bool tooFast;
  final int distanceHint; // -1 too far (move closer), +1 too close (back off), 0 ok
  final bool isCapturingBurst;
  final int burstShotIndex; // shots fired so far this burst, for the UI countdown
  final int burstShotTotal;
  final String? confirmationText; // "✓ FRONT captured" banner, ~700ms
  final int totalFramesCaptured;
  final double uploadProgress;
  final String? captureId;
  final String? error;

  const OscillatingCaptureState({
    this.phase = OscillatingPhase.idle,
    this.stepIndex = 0,
    this.isBurstStep = true,
    this.phaseLabel = '',
    this.instruction = '',
    this.currentAngleDeg = 0,
    this.targetAngleDeg = 0,
    this.deltaDeg = 0,
    this.onTarget = false,
    this.holdProgress = 0,
    this.waypointIndex = 0,
    this.waypointTotal = 3,
    this.angularVelocityDegPerSec = 0,
    this.tooFast = false,
    this.distanceHint = 0,
    this.isCapturingBurst = false,
    this.burstShotIndex = 0,
    this.burstShotTotal = 0,
    this.confirmationText,
    this.totalFramesCaptured = 0,
    this.uploadProgress = 0,
    this.captureId,
    this.error,
  });

  OscillatingCaptureState copyWith({
    OscillatingPhase? phase,
    int? stepIndex,
    bool? isBurstStep,
    String? phaseLabel,
    String? instruction,
    double? currentAngleDeg,
    double? targetAngleDeg,
    double? deltaDeg,
    bool? onTarget,
    double? holdProgress,
    int? waypointIndex,
    int? waypointTotal,
    double? angularVelocityDegPerSec,
    bool? tooFast,
    int? distanceHint,
    bool? isCapturingBurst,
    int? burstShotIndex,
    int? burstShotTotal,
    Object? confirmationText = _sentinel,
    int? totalFramesCaptured,
    double? uploadProgress,
    String? captureId,
    Object? error = _sentinel,
  }) =>
      OscillatingCaptureState(
        phase: phase ?? this.phase,
        stepIndex: stepIndex ?? this.stepIndex,
        isBurstStep: isBurstStep ?? this.isBurstStep,
        phaseLabel: phaseLabel ?? this.phaseLabel,
        instruction: instruction ?? this.instruction,
        currentAngleDeg: currentAngleDeg ?? this.currentAngleDeg,
        targetAngleDeg: targetAngleDeg ?? this.targetAngleDeg,
        deltaDeg: deltaDeg ?? this.deltaDeg,
        onTarget: onTarget ?? this.onTarget,
        holdProgress: holdProgress ?? this.holdProgress,
        waypointIndex: waypointIndex ?? this.waypointIndex,
        waypointTotal: waypointTotal ?? this.waypointTotal,
        angularVelocityDegPerSec:
            angularVelocityDegPerSec ?? this.angularVelocityDegPerSec,
        tooFast: tooFast ?? this.tooFast,
        distanceHint: distanceHint ?? this.distanceHint,
        isCapturingBurst: isCapturingBurst ?? this.isCapturingBurst,
        burstShotIndex: burstShotIndex ?? this.burstShotIndex,
        burstShotTotal: burstShotTotal ?? this.burstShotTotal,
        confirmationText: identical(confirmationText, _sentinel)
            ? this.confirmationText
            : confirmationText as String?,
        totalFramesCaptured: totalFramesCaptured ?? this.totalFramesCaptured,
        uploadProgress: uploadProgress ?? this.uploadProgress,
        captureId: captureId ?? this.captureId,
        error: identical(error, _sentinel) ? this.error : error as String?,
      );
}

// Sentinel so copyWith can distinguish "leave unchanged" from "set to null"
// for the two nullable fields (confirmationText, error).
const _sentinel = Object();

class _CapturedFrame {
  final Uint8List bytes;
  final int phaseNumber; // 1-8
  final double angleDeg;
  final double velocityDegPerSec; // 0 for burst stills
  final DateTime timestamp;
  final bool isBurst;
  final bool flashOn;
  // Raw (unsmoothed) Laplacian sharpness at capture time — for transition
  // frames this is the exact per-frame value from HybridCaptureService; for
  // burst stills it's the live preview-stream reading from immediately
  // before the burst started (the actual full-res ISP still can't be
  // cheaply scored without decoding it, and burst frames are already
  // preferred server-side by type, not by score — this is a documented
  // approximation, not an exact per-shot measurement).
  final double? laplacianScore;
  const _CapturedFrame({
    required this.bytes,
    required this.phaseNumber,
    required this.angleDeg,
    required this.velocityDegPerSec,
    required this.timestamp,
    required this.isBurst,
    required this.flashOn,
    this.laplacianScore,
  });
}

/// 8-phase oscillating capture: front → left → front → right → front → top,
/// alternating real-ISP burst stills at each hold position with guided
/// video-frame-extraction transitions between them.
///
/// Feeds the same backend SfM reconstruction pipeline the other capture
/// modes use (`processEnhanceAndScore`, `captureMode: 'oscillating_8phase'`)
/// — see the backend's `_download_oscillating_frames` for how the dense
/// frame stream this controller produces gets binned down into a
/// cylindrical-projection input. To reconstruct well it tracks, per frame:
/// the exact device angle (pitch axis for FRONT/LEFT/RIGHT, roll axis for
/// TOP -- see [_AngleAxis] -- via [DeviceOrientationService]),
/// raw Laplacian sharpness (so the backend can pick the best frame per
/// angle bin), and ambient/torch pairing (so flash-diff segmentation — the
/// most reliable segmentation tier on every other capture mode — has real
/// pairs to work with, not just single ambient frames).
///
/// Brightness-only calibration instead of a focus-stability tracker (unlike
/// the package's other controllers) — this mode is otherwise purely
/// angle-and-timing driven per its spec, and staying minimal keeps it fast
/// to retune while the geometry itself is still being worked out. It does
/// use the same hybrid CV+IMU gate as [MultiAngleCaptureController] though
/// (see [_cvClassifier]) — the trained thumb-orientation model directly
/// supports this mode's four burst positions (front/left/right/top), so
/// there was no reason to leave this mode IMU-only.
class OscillatingCaptureController extends ChangeNotifier {
  static const double _holdToleranceDeg = 5.0;
  static const double _waypointToleranceDeg = 5.0;
  static const int _holdDurationMs = 1500;
  static const int _burstFrameCount = 3; // reduced from 5 per field-test feedback on burst duration
  static const int _burstShotDelayMs = 50;
  static const int _burstFlashSettleMs = 70; // AE settle after toggling torch mid-burst
  static const double _maxAngularVelocityDegPerSec = 30.0;
  // ~12fps: still comfortably oversampled for the backend's 5deg angle bins
  // (41deg-ish sweep / 5deg ~= 8-9 bins) but roughly a third of the frame
  // count -- and upload requests -- that ~30fps produced, which was the
  // main driver of "upload takes extremely long" (each frame is its own
  // Storage upload; see _uploadConcurrency below).
  static const int _videoFrameMinIntervalMs = 80;
  static const int _maxVideoFramesPerTransition = 150; // safety cap
  static const int _emitThrottleMs = 80;
  static const int _confirmationDisplayMs = 700;
  static const int _calibDurationMs = 500; // brightness sampling for AdaptiveFlashController
  static const int _torchAlternateMs = 500; // transition-phase torch toggle cadence
  static const int _uploadConcurrency = 16; // was 6 -- see _videoFrameMinIntervalMs
  // Hybrid CV+IMU gate, same threshold as MultiAngleCaptureController: a
  // confident, correct CV prediction can bring the effective distance to 0
  // (locked) even if the raw IMU angle hasn't quite settled there -- it
  // never blocks a capture the IMU alone would already allow.
  static const double _cvConfidenceThreshold = 0.45;
  static const int _cvClassifyMinIntervalMs = 150; // ~6-7Hz cap, not full frame-rate

  // Loose centre crop for transition frames — cuts background while leaving
  // margin for a wandering thumb during the move (unlike a burst hold, the
  // thumb position isn't locked down during a transition).
  static const Rect _videoRoi = Rect.fromLTRB(0.15, 0.12, 0.85, 0.88);

  // Centre ROI the focus meter, brightness meter and exposure guard all score
  // on — the thumb sits here, so a crisp/bright background can't outscore a
  // soft/dark thumb (the exact failure that left production captures a blurry
  // back-focused lozenge). Same window ArcSweepCaptureController scores on.
  static const Rect _scoreRoi = Rect.fromLTRB(0.30, 0.30, 0.70, 0.70);

  // Exposure guard bands, measured on the ambient thumb ROI (torch-off frames
  // only). Field captures came back at ~38/255 luma — badly underexposed, so
  // ridge contrast was buried in sensor noise. Push EV up when the thumb is
  // dark, pull back down toward neutral once it recovers, and clamp glare at
  // the top so a torch hotspot can't blow out ridges either.
  static const double _darkLowLuma  = 95.0;   // below this → brighten
  static const double _darkOkLuma   = 120.0;  // above this → stop brightening
  static const double _glareHighLuma = 205.0; // above this → darken
  static const double _brightenEvStep = 1.5;  // +EV applied when underexposed
  static const double _glareEvStep    = -0.7; // −EV applied on glare
  // Burst sharpness gate: a hold whose thumb-ROI focus is below this fraction
  // of the running focus peak is treated as out-of-focus — the burst is held
  // off and a refocus is kicked instead of banking a blurry set of stills.
  static const double _burstFocusGateFrac = 0.55;

  // On-device thumb detection (MediaPipe hand landmarker) drives a DYNAMIC
  // ROI: focus/exposure/sharpness all target the actual thumb pixels instead
  // of the fixed centre box, so an off-centre thumb is still metered
  // correctly. Run at reduced cadence (same as ArcSweepCaptureController) —
  // the model is too heavy for every frame but a few detections a second is
  // plenty to keep the ROI tracking a slowly-orbiting thumb.
  static const int _landmarkEveryNFrames = 6;
  static const int _thumbRoiStaleMs = 1500; // fall back to centre if detection lapses
  // Thumb bbox (MediaPipe landmarks 1–4) is padded by this fraction of its
  // size so focus/metering include the ridge field around the tip, not just
  // the skeleton line.
  static const double _thumbRoiPad = 0.18;
  // Coverage = normalised thumb-tip↔wrist span; same 0.35–0.85 "not too far /
  // not too close" window the 4-angle and arc-sweep flows gate on.
  static const double _coverageMin = 0.35;
  static const double _coverageMax = 0.85;

  CameraController? _camera;
  String? _userId;
  AdaptiveFlashController? _flash;
  ThumbOrientationClassifier? _cvClassifier;
  int _sensorOrientation = 0;
  DateTime? _lastCvClassifyAt;
  OrientationPrediction? _lastCvPrediction;
  bool _encodeInFlight = false;
  _AngleAxis? _lastAxis;

  // Focus/exposure control state (ported from ArcSweepCaptureController).
  bool _focusLocked = false;     // true once AF has been acquired and locked
  bool _refocusing = false;      // an auto→settle→lock cycle is in flight
  int _burstRefocusAttempts = 0; // sharpness-gate retries at the current hold
  double _appliedEvOffset = 0.0; // current EV offset applied to the camera
  bool _evChangeInFlight = false;
  double _lastStableBrightness = 128.0; // ambient thumb-ROI luma (torch-off)

  // Dynamic thumb ROI from the on-device landmarker (null → use centre box).
  final _landmarker = ThumbLandmarkerService();
  bool _landmarkerInitStarted = false;
  int _frameCounter = 0;
  Rect? _thumbRoi;
  DateTime? _thumbRoiAt;
  double _lastCoverage = 0.0;
  DateTime? _lastCoverageAt;

  OscillatingCaptureState _state = const OscillatingCaptureState();
  OscillatingCaptureState get state => _state;

  final _orientation = DeviceOrientationService();
  final _hybrid = HybridCaptureService(); // live focus meter + per-frame sharpness tag
  final _audio = CaptureAudioService(); // success chime + proximity tone

  bool _disposed = false;
  bool _starting = false;
  bool _streamRunning = false;
  bool _burstInFlight = false;

  double _lastAngle = 0;
  DateTime? _lastAngleAt;
  double _angularVelocity = 0;

  DateTime? _holdStart;
  int _currentWaypointIndex = 0;
  bool _waypointFired = false;
  DateTime? _lastVideoFrameAt;
  DateTime? _lastEmitAt;
  DateTime? _lastTorchToggleAt;

  DateTime? _calibStart;
  bool _calibDone = false;
  final List<double> _brightnessSamples = [];

  double _focusValue = 0;
  double _focusPeak = 1.0;
  double get focusValue => _focusValue;

  final List<_CapturedFrame> _capturedFrames = [];

  CameraController? get cameraController => _camera;

  // ── Entry point ────────────────────────────────────────────────────────

  Future<void> start({
    required CameraController camera,
    required String userId,
  }) async {
    if (_starting || _streamRunning) return;
    _starting = true;
    _disposed = false;
    _camera = camera;
    _userId = userId;
    _sensorOrientation = camera.description.sensorOrientation;
    // Lazy-init, same pattern as MultiAngleCaptureController._ensurePlugin --
    // loading the tflite model takes real time, so it's created once and
    // reused across repeated start()/"capture again" calls, not per-session.
    _cvClassifier ??= ThumbOrientationClassifier()..initialize();

    _capturedFrames.clear();
    _holdStart = null;
    _currentWaypointIndex = 0;
    _waypointFired = false;
    _lastAngle = 0;
    _lastAngleAt = null;
    _angularVelocity = 0;
    _lastVideoFrameAt = null;
    _lastTorchToggleAt = null;
    _lastCvClassifyAt = null;
    _lastCvPrediction = null;
    _encodeInFlight = false;
    _lastAxis = null;
    _focusLocked = false;
    _refocusing = false;
    _appliedEvOffset = 0.0;
    _evChangeInFlight = false;
    _lastStableBrightness = 128.0;
    _frameCounter = 0;
    _thumbRoi = null;
    _thumbRoiAt = null;
    _lastCoverage = 0.0;
    _lastCoverageAt = null;
    if (!_landmarkerInitStarted) {
      _landmarkerInitStarted = true;
      _landmarker.initialize();
    }
    _focusPeak = 1.0;
    _hybrid.reset();
    _flash = AdaptiveFlashController(camera);
    _brightnessSamples.clear();
    _calibDone = false;
    unawaited(_audio.init());

    _state = const OscillatingCaptureState(phase: OscillatingPhase.calibrating);
    notifyListeners();

    // Acquire autofocus on the thumb (centre point). It's LOCKED once
    // calibration finishes (_finalizeCalibration) so the lens can't hunt back
    // onto the background as the phone orbits — the root cause of the
    // back-focused, blurry-thumb captures field testing produced.
    await _beginAutofocus();
    // Expose for the thumb ROI, not the whole (mostly dark) scene.
    try {
      await camera.setExposureMode(ExposureMode.auto);
      await camera.setExposurePoint(const Offset(0.5, 0.5));
    } catch (_) {}

    _orientation.start();
    // 500ms settle before zeroing the reference, matching
    // MultiAngleCaptureController's proven calibration delay -- the previous
    // 50ms was too short for the orientation sensor to settle after the
    // phone is first raised into position, biasing the whole session's "0°
    // = FRONT" zero point by several degrees (symptom: the dial insists
    // FRONT isn't reached even when the thumb is visibly dead-centre).
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_disposed) return;
    _orientation.captureReference();

    _calibStart = DateTime.now();
    try {
      if (camera.value.isStreamingImages) {
        try {
          await camera.stopImageStream();
        } catch (_) {}
      }
      // Calibration proceeds through _onFrame's `calibrating`-phase branch
      // (brightness sampling to feed AdaptiveFlashController) — one
      // continuous stream, no stop/restart between calibrating and running.
      await camera.startImageStream(_onFrame);
      _streamRunning = true;
    } catch (e) {
      _fail('Could not start camera stream: $e');
      _starting = false;
      return;
    }

    _starting = false;
  }

  Future<void> _finalizeCalibration() async {
    if (_calibDone) return;
    _calibDone = true;
    final avg = _brightnessSamples.isEmpty
        ? 128.0
        : _brightnessSamples.reduce((a, b) => a + b) / _brightnessSamples.length;
    await _flash?.calibrate(avg);
    if (_disposed) return;
    // Lock focus so it holds the thumb through the whole orbit instead of
    // hunting to the background. AE stays in auto (exposure must adapt as the
    // view goes face-on → side-on), guarded by _maybeAdjustExposure below.
    await _lockFocusOnly();
    HapticFeedback.mediumImpact();
    _enterStep(0, force: true);
  }

  // ── Thumb ROI (on-device landmarker) ──────────────────────────────────────

  /// The ROI focus/exposure/sharpness should target: the live thumb bbox when
  /// a fresh detection exists, else the fixed centre box.
  Rect get _activeRoi {
    final roi = _thumbRoi;
    final at = _thumbRoiAt;
    if (roi != null &&
        at != null &&
        DateTime.now().difference(at).inMilliseconds < _thumbRoiStaleMs) {
      return roi;
    }
    return _scoreRoi;
  }

  /// Runs the hand landmarker (reduced cadence) and updates the thumb bbox +
  /// coverage. Landmarks 1–4 are the thumb (CMC→tip); their padded bounds make
  /// the ROI. Coverage = |tip.y − wrist.y| feeds the too-far/too-close hint.
  void _updateThumbRoi(CameraImage image) {
    if (!_landmarker.isReady) return;
    if (_frameCounter % _landmarkEveryNFrames != 0) return;
    final hands = _landmarker.detect(image, _sensorOrientation);
    if (hands.isEmpty || hands.first.landmarks.length <= 4) return;
    final lms = hands.first.landmarks;
    double minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0;
    for (var i = 1; i <= 4; i++) {
      final p = lms[i];
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    final padX = (maxX - minX) * _thumbRoiPad;
    final padY = (maxY - minY) * _thumbRoiPad;
    final l = (minX - padX).clamp(0.0, 1.0);
    final t = (minY - padY).clamp(0.0, 1.0);
    final r = (maxX + padX).clamp(0.0, 1.0);
    final b = (maxY + padY).clamp(0.0, 1.0);
    if (r - l < 0.08 || b - t < 0.08) return; // implausibly small — ignore
    _thumbRoi = Rect.fromLTRB(l, t, r, b);
    _thumbRoiAt = DateTime.now();
    _lastCoverage = (lms[4].y - lms[0].y).abs().clamp(0.0, 1.0);
    _lastCoverageAt = DateTime.now();
  }

  /// Distance hint from the latest coverage reading: -1 = too far (move
  /// closer), +1 = too close (move back), 0 = in range or detection stale.
  int get _distanceHint {
    final at = _lastCoverageAt;
    if (at == null ||
        DateTime.now().difference(at).inMilliseconds > _thumbRoiStaleMs) {
      return 0;
    }
    if (_lastCoverage < _coverageMin) return -1;
    if (_lastCoverage > _coverageMax) return 1;
    return 0;
  }

  // ── Focus / exposure control (ported from ArcSweepCaptureController) ───────

  /// Centre of the active ROI — where focus/exposure should be aimed.
  Offset get _roiCentre {
    final r = _activeRoi;
    return Offset(
      ((r.left + r.right) / 2).clamp(0.0, 1.0),
      ((r.top + r.bottom) / 2).clamp(0.0, 1.0),
    );
  }

  /// Puts the lens into continuous AF aimed at the thumb (ROI centre).
  Future<void> _beginAutofocus() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    _focusLocked = false;
    final pt = _roiCentre;
    try {
      await c.setFocusMode(FocusMode.auto);
    } catch (_) {}
    try {
      await c.setFocusPoint(pt);
    } catch (_) {}
    try {
      await c.setExposurePoint(pt);
    } catch (_) {}
  }

  /// Freezes focus at its current distance so orbiting can't make it hunt.
  Future<void> _lockFocusOnly() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFocusMode(FocusMode.locked);
      _focusLocked = true;
    } catch (_) {}
  }

  /// Re-acquire then re-lock focus. Kicked when a burst hold arrives soft
  /// (sharpness gate) so the thumb is crisp before the stills fire.
  void _refocus() {
    if (_refocusing) return;
    _refocusing = true;
    () async {
      try {
        await _beginAutofocus();
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _lockFocusOnly();
      } catch (_) {
      } finally {
        _refocusing = false;
      }
    }();
  }

  /// Nudges EV to keep the thumb ROI properly exposed: brighten when it's dark
  /// (the underexposure that buried ridge contrast in noise), pull back toward
  /// neutral once it recovers, and clamp glare at the top. Uses only torch-off
  /// readings so torch light can't trigger a spurious change.
  void _maybeAdjustExposure() {
    if (_evChangeInFlight) return;
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    double? target;
    if (_lastStableBrightness < _darkLowLuma && _appliedEvOffset < _brightenEvStep) {
      target = _brightenEvStep;
    } else if (_lastStableBrightness > _glareHighLuma && _appliedEvOffset >= 0.0) {
      target = _glareEvStep;
    } else if (_appliedEvOffset > 0.0 && _lastStableBrightness > _darkOkLuma) {
      target = 0.0; // recovered from dark — relax back to neutral
    } else if (_appliedEvOffset < 0.0 && _lastStableBrightness < _glareHighLuma - 20) {
      target = 0.0; // glare gone — relax back to neutral
    }
    if (target == null) return;
    _evChangeInFlight = true;
    final t = target;
    () async {
      try {
        final minEv = await c.getMinExposureOffset();
        final maxEv = await c.getMaxExposureOffset();
        await c.setExposureOffset(t.clamp(minEv, maxEv));
        _appliedEvOffset = t;
      } catch (_) {
        _appliedEvOffset = t; // unsupported — don't retry every frame
      } finally {
        _evChangeInFlight = false;
      }
    }();
  }

  void _enterStep(int index, {bool force = false}) {
    _holdStart = null;
    _currentWaypointIndex = 0;
    _waypointFired = false;
    _lastVideoFrameAt = null;
    _burstRefocusAttempts = 0;

    final step = oscillatingSteps[index];
    if (step is _BurstStep) {
      _apply(
        (s) => s.copyWith(
          phase: OscillatingPhase.running,
          stepIndex: index,
          isBurstStep: true,
          phaseLabel: step.label,
          instruction: step.instruction,
          targetAngleDeg: step.targetDeg,
          holdProgress: 0,
          onTarget: false,
        ),
        force: force,
      );
    } else if (step is _TransitionStep) {
      _apply(
        (s) => s.copyWith(
          phase: OscillatingPhase.running,
          stepIndex: index,
          isBurstStep: false,
          phaseLabel: step.label,
          instruction: step.instruction,
          targetAngleDeg: step.waypoints.first,
          waypointIndex: 0,
          waypointTotal: step.waypoints.length,
          onTarget: false,
        ),
        force: force,
      );
    }
  }

  void _advanceStep() {
    if (_disposed) return;
    final next = _state.stepIndex + 1;
    if (next >= oscillatingSteps.length) {
      unawaited(_finishAndUpload());
      return;
    }
    HapticFeedback.mediumImpact();
    _enterStep(next, force: true);
  }

  // ── Stream processing ─────────────────────────────────────────────────

  void _onFrame(CameraImage image) {
    if (_disposed) return;
    if (_burstInFlight) return; // stream is stopped during a burst anyway

    // Track the thumb bbox (reduced cadence) in every live phase so the ROI
    // is warm before the first hold and keeps following the thumb as it
    // orbits. Cheap when it's not the Nth frame (early return inside).
    _frameCounter++;
    _updateThumbRoi(image);

    if (_state.phase == OscillatingPhase.calibrating) {
      _runCalibrationSample(image);
      return;
    }
    if (_state.phase != OscillatingPhase.running) return;

    final roi = _activeRoi;

    // Sharpness — feeds both the live meter (smoothed) and, for transition
    // frames, the exact per-frame tag the backend uses to pick the best
    // frame in each angle bin (see _download_oscillating_frames).
    double rawFocus = 0;
    try {
      // Score sharpness on the live thumb ROI, not the whole frame, so a
      // crisp background can't outscore a soft thumb.
      rawFocus = _hybrid.offerFrame(image, thumbRoi: roi);
      if (rawFocus > _focusPeak) _focusPeak = rawFocus;
      _focusPeak *= 0.995;
      _focusValue = HybridCaptureService.ema(
        _focusValue,
        (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0),
      );
    } catch (_) {}

    // Track ambient thumb-ROI brightness (torch-off frames only) and keep the
    // thumb correctly exposed — this is what fixes the underexposed, dark
    // captures that buried ridge contrast in noise.
    if (!(_flash?.isFlashOn ?? false)) {
      _lastStableBrightness = HybridCaptureService.meanLuma(image, roi: roi);
    }
    if (!_refocusing) _maybeAdjustExposure();

    // Surface the macro-distance hint (too far / too close) so the user frames
    // the thumb large enough to resolve ridges but still within the lens's
    // focus range. Only emit on a change to avoid extra rebuilds.
    final hint = _distanceHint;
    if (hint != _state.distanceHint) {
      _apply((s) => s.copyWith(distanceHint: hint));
    }

    final step = oscillatingSteps[_state.stepIndex];
    // TOP is the only step measured on roll rather than pitch -- see
    // _AngleAxis. All transitions and every other burst stay on pitch.
    final axis = step is _BurstStep ? step.axis : _AngleAxis.pitch;
    final orient = _orientation.relativeOrientation();
    final angle = axis == _AngleAxis.roll ? orient.roll : orient.pitch;

    final now = DateTime.now();
    if (_lastAxis != axis) {
      // Crossing from a pitch-driven step to the roll-driven TOP step (or
      // back) is a discontinuity in the underlying signal, not real device
      // motion -- drop the stale sample so it can't register as a bogus
      // angular-velocity spike and falsely trip the "too fast" guard.
      _lastAngleAt = null;
    }
    _lastAxis = axis;
    if (_lastAngleAt != null) {
      final dt = now.difference(_lastAngleAt!).inMicroseconds / 1e6;
      if (dt > 0.001) {
        final raw = (angle - _lastAngle).abs() / dt;
        _angularVelocity = HybridCaptureService.ema(_angularVelocity, raw, alpha: 0.35);
      }
    }
    _lastAngle = angle;
    _lastAngleAt = now;

    // Hybrid CV+IMU gate infrastructure, shared by burst holds and (for the
    // final/destination waypoint only, see _handleTransitionFrame)
    // transitions. Throttled to ~6-7Hz rather than full camera frame-rate --
    // see _handleBurstFrame's original comment: the hold window is 1.5s, so
    // a few classifications a second is plenty, and running tflite
    // inference every frame risked reintroducing preview lag.
    final classifyNow = DateTime.now();
    if (_lastCvClassifyAt == null ||
        classifyNow.difference(_lastCvClassifyAt!).inMilliseconds >= _cvClassifyMinIntervalMs) {
      _lastCvClassifyAt = classifyNow;
      _lastCvPrediction = _cvClassifier?.classify(image, _sensorOrientation);
    }

    if (step is _BurstStep) {
      _handleBurstFrame(angle, step);
    } else if (step is _TransitionStep) {
      _maybeToggleTorchForTransition();
      _handleTransitionFrame(image, angle, rawFocus, step);
    }
  }

  void _runCalibrationSample(CameraImage image) {
    _brightnessSamples.add(HybridCaptureService.meanLuma(image, roi: _activeRoi));
    final start = _calibStart;
    if (start != null &&
        DateTime.now().difference(start).inMilliseconds >= _calibDurationMs) {
      unawaited(_finalizeCalibration());
    }
  }

  /// Alternates the torch during transition steps so both an ambient and a
  /// torch-lit frame get extracted across the sweep — the same real
  /// ambient/flash pairing the burst loop produces at each hold, needed for
  /// flash-diff segmentation server-side (see _segment_via_flash_diff).
  /// Skipped when torch isn't needed (bright ambient) or stays on
  /// permanently (pitch dark) — mirrors ArcSweepCaptureController's policy.
  void _maybeToggleTorchForTransition() {
    final flash = _flash;
    if (flash == null || !flash.isNeeded || flash.isPitchDark) return;
    final now = DateTime.now();
    if (_lastTorchToggleAt != null &&
        now.difference(_lastTorchToggleAt!).inMilliseconds < _torchAlternateMs) {
      return;
    }
    _lastTorchToggleAt = now;
    if (flash.isFlashOn) {
      unawaited(flash.deactivate());
    } else {
      unawaited(flash.activate());
    }
  }

  void _handleBurstFrame(double angle, _BurstStep step) {
    // CV classify-and-cache now happens once per frame in _onFrame (shared
    // with transition arrival checks) -- just read the cached prediction.
    final cvPrediction = _lastCvPrediction;
    final cvConfirms = cvPrediction != null &&
        cvPrediction.angleName == step.label.toLowerCase() &&
        cvPrediction.confidence >= _cvConfidenceThreshold;

    final rawDist = (angle - step.targetDeg).abs();
    final dist = cvConfirms ? 0.0 : rawDist;
    final tooFast = _angularVelocity > _maxAngularVelocityDegPerSec;

    if (dist <= _holdToleranceDeg && !tooFast) {
      _holdStart ??= DateTime.now();
      final heldMs = DateTime.now().difference(_holdStart!).inMilliseconds;
      final progress = (heldMs / _holdDurationMs).clamp(0.0, 1.0);
      _apply((s) => s.copyWith(
            currentAngleDeg: angle,
            deltaDeg: angle - step.targetDeg,
            onTarget: true,
            holdProgress: progress,
            angularVelocityDegPerSec: _angularVelocity,
            tooFast: false,
          ));
      if (heldMs >= _holdDurationMs) {
        // Sharpness gate: don't bank a burst of soft stills. If the thumb ROI
        // is out of focus, kick one refocus and keep holding; only after the
        // refocus (or a couple of attempts) do we fire, so we never stall
        // forever if the lens simply can't do better at this distance.
        final soft = _focusLocked && _focusValue < _burstFocusGateFrac;
        if (soft && !_refocusing && _burstRefocusAttempts < 2) {
          _burstRefocusAttempts++;
          _holdStart = DateTime.now(); // re-accumulate the hold during refocus
          _refocus();
          _apply((s) => s.copyWith(
                currentAngleDeg: angle,
                deltaDeg: angle - step.targetDeg,
                onTarget: true,
                holdProgress: 0,
                angularVelocityDegPerSec: _angularVelocity,
                tooFast: false,
              ));
          return;
        }
        _holdStart = null;
        _burstRefocusAttempts = 0;
        unawaited(_fireBurst(step));
      }
    } else {
      _holdStart = null;
      _apply((s) => s.copyWith(
            currentAngleDeg: angle,
            deltaDeg: angle - step.targetDeg,
            onTarget: false,
            holdProgress: 0,
            angularVelocityDegPerSec: _angularVelocity,
            tooFast: tooFast,
          ));
    }
  }

  void _handleTransitionFrame(
    CameraImage image,
    double angle,
    double rawFocus,
    _TransitionStep step,
  ) {
    // Video-frame extraction, throttled to ~30fps and capped defensively.
    // The crop (cheap memcpy) stays synchronous; the JPEG encode -- CPU-heavy
    // enough at this rate to have caused visible preview lag when it ran
    // synchronously on the UI isolate -- moves to a compute() isolate.
    // _encodeInFlight provides natural backpressure: if an encode is still
    // running when the next eligible frame arrives, that frame is skipped
    // rather than piling up more isolates than the device can keep up with.
    final now = DateTime.now();
    if ((_lastVideoFrameAt == null ||
            now.difference(_lastVideoFrameAt!).inMilliseconds >= _videoFrameMinIntervalMs) &&
        _capturedFrames.length < _maxVideoFramesPerTransition * 4 &&
        !_encodeInFlight) {
      final transitionFrameCount = _capturedFrames
          .where((f) => !f.isBurst && f.phaseNumber == _state.stepIndex + 1)
          .length;
      if (transitionFrameCount < _maxVideoFramesPerTransition) {
        final crop = _cropFrameGray(image);
        if (crop != null) {
          _encodeInFlight = true;
          _lastVideoFrameAt = now;
          final phaseNumber = _state.stepIndex + 1;
          final flashOn = _flash?.isFlashOn ?? false;
          compute(_encodeGrayJpegIsolate, crop).then((jpeg) {
            _encodeInFlight = false;
            if (_disposed) return;
            _capturedFrames.add(_CapturedFrame(
              bytes: jpeg,
              phaseNumber: phaseNumber,
              angleDeg: angle,
              velocityDegPerSec: _angularVelocity,
              timestamp: now,
              isBurst: false,
              flashOn: flashOn,
              laplacianScore: rawFocus,
            ));
          }).catchError((Object e) {
            _encodeInFlight = false;
            debugPrint('[osc] video-frame encode failed (non-fatal): $e');
          });
        }
      }
    }

    final target = step.waypoints[_currentWaypointIndex];
    final rawDist = (angle - target).abs();
    // CV assist only applies to the final waypoint -- the actual named
    // destination (step.label), which is the only point along a transition
    // the trained classifier can meaningfully recognize (it only knows the
    // 4 discrete positions, not intermediate waypoint angles). This is what
    // fixes "moving from RIGHT to FRONT doesn't register" -- IMU-only
    // arrival detection had no fallback if pitch had drifted by then,
    // unlike burst holds which already had this hybrid gate.
    var dist = rawDist;
    if (_currentWaypointIndex == step.waypoints.length - 1) {
      final cvPrediction = _lastCvPrediction;
      final cvConfirms = cvPrediction != null &&
          cvPrediction.angleName == step.label.toLowerCase() &&
          cvPrediction.confidence >= _cvConfidenceThreshold;
      if (cvConfirms) dist = 0.0;
    }
    final tooFast = _angularVelocity > _maxAngularVelocityDegPerSec;

    _apply((s) => s.copyWith(
          currentAngleDeg: angle,
          targetAngleDeg: target,
          deltaDeg: angle - target,
          onTarget: dist <= _waypointToleranceDeg,
          waypointIndex: _currentWaypointIndex,
          angularVelocityDegPerSec: _angularVelocity,
          tooFast: tooFast,
          totalFramesCaptured: _capturedFrames.length,
        ));

    if (dist <= _waypointToleranceDeg && !_waypointFired) {
      _waypointFired = true;
      HapticFeedback.mediumImpact();
      if (_currentWaypointIndex >= step.waypoints.length - 1) {
        _advanceStep();
      } else {
        _currentWaypointIndex++;
        _waypointFired = false;
      }
    }
  }

  // ── Burst capture (real ISP stills) ───────────────────────────────────

  Future<void> _fireBurst(_BurstStep step) async {
    if (_burstInFlight) return;
    _burstInFlight = true;
    _apply(
      (s) => s.copyWith(
        isCapturingBurst: true,
        burstShotIndex: 0,
        burstShotTotal: _burstFrameCount,
      ),
      force: true,
    );

    final cam = _camera;
    final wasStreaming = _streamRunning;
    final preburstFocus = _focusValue > 0 ? _focusValue * (_focusPeak + 1e-6) : null;
    final torchCapable = _flash?.isNeeded ?? false;

    // EV offset range, queried once (not per-shot) -- torch-lit shots dial
    // exposure down so full-power torch doesn't blow out ridge detail on
    // close-up skin; ambient shots stay neutral. Same -0.4 EV middle ground
    // as MultiAngleCaptureController._setAdaptiveExposureOffset's "normal/
    // bright indoor + torch" bands, just applied per-shot here since this
    // mode alternates torch within a single burst rather than fixing it for
    // a whole session.
    double? minEv;
    double? maxEv;
    if (torchCapable) {
      try {
        minEv = await cam?.getMinExposureOffset();
        maxEv = await cam?.getMaxExposureOffset();
      } catch (_) {}
    }

    // Raw ISP stills at ResolutionPreset.max are 11-29MB each -- verified
    // against a real capture in Storage. Every shot gets downscaled to
    // ~2048px-wide grayscale before it ever reaches _capturedFrames, via the
    // same decodeStillJpegToLuma/encodeGrayscaleJpeg pair
    // ArcSweepCaptureController already ships for its own checkpoint
    // stills (see packages/mac_capture/lib/src/still_jpeg_downscaler.dart)
    // -- 2048px is ~4x the 500x500 the backend's NFIQ scoring normalizes to
    // anyway, so this is well above the pipeline's actual quality floor.
    //
    // Decode+encode happen entirely AFTER the shot loop below, not inline
    // per-shot -- a real-device test showed the burst taking noticeably too
    // long with inline decode. Capturing all raw JPEGs first restores the
    // original fast shot-to-shot cadence (just takePicture() + delays);
    // the decode/encode cost moves into the post-burst pause, which already
    // has cover (haptic + confirmation banner + _confirmationDisplayMs).
    final rawShots = <_RawBurstShot>[];

    try {
      if (cam == null) return;
      if (wasStreaming) await _stopStream();

      for (var i = 0; i < _burstFrameCount; i++) {
        // Alternate ambient/torch across the burst so this hold position
        // also yields a real ambient/flash pair for segmentation, same as
        // every other frame in the session — not just single ambient shots.
        // Pitch-dark mode leaves torch on for every shot (deactivate() is a
        // documented no-op there), which is the correct behaviour: there's
        // no usable "ambient" variant when the torch is the only light.
        final wantTorch = torchCapable && i.isOdd;
        if (torchCapable) {
          try {
            if (wantTorch) {
              await _flash!.activate();
            } else {
              await _flash!.deactivate();
            }
            if (minEv != null && maxEv != null) {
              // Baseline on the live guard's current offset (which brightens a
              // dark thumb / tames glare) rather than forcing 0. Only trim a
              // little extra for a torch shot when the scene is already bright
              // enough that the torch would blow out ridges; in a dim scene
              // (where the guard has pushed EV up) keep that brightening so
              // torch-lit stills aren't left darker than the ambient ones.
              final extra = (wantTorch && _lastStableBrightness > _darkOkLuma)
                  ? -0.4
                  : 0.0;
              final target = _appliedEvOffset + extra;
              await cam.setExposureOffset(target.clamp(minEv, maxEv));
            }
            await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
          } catch (_) {}
        }
        try {
          final xfile = await cam.takePicture();
          final jpeg = await xfile.readAsBytes();
          // DeviceOrientationService reads a native EventChannel independent
          // of the camera image stream, so it keeps updating even while the
          // stream is stopped for takePicture() — read fresh per shot rather
          // than reusing the pre-burst angle. Must read the same axis this
          // step is gated on (see _AngleAxis) -- TOP frames tagged with
          // pitch instead of roll would carry a near-zero angleDeg that
          // doesn't reflect the actual tilt, corrupting the backend's
          // per-frame geometry for that phase.
          final freshOrient = _orientation.relativeOrientation();
          rawShots.add(_RawBurstShot(
            jpeg: jpeg,
            phaseNumber: _state.stepIndex + 1,
            angleDeg: step.axis == _AngleAxis.roll ? freshOrient.roll : freshOrient.pitch,
            timestamp: DateTime.now(),
            flashOn: _flash?.isFlashOn ?? false,
            laplacianScore: preburstFocus,
          ));
        } catch (e) {
          debugPrint('[osc] burst shot $i failed (non-fatal): $e');
        }
        _apply((s) => s.copyWith(burstShotIndex: i + 1), force: true);
        if (i < _burstFrameCount - 1) {
          await Future<void>.delayed(const Duration(milliseconds: _burstShotDelayMs));
        }
      }
      if (torchCapable) {
        try {
          await _flash!.deactivate();
          if (minEv != null && maxEv != null) {
            // Restore the live guard's offset (not a hard 0) so the stream
            // resumes at the exposure the thumb ROI actually needs.
            await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
          }
        } catch (_) {}
      }

      // dart:ui decode must stay on this isolate (Flutter-engine API,
      // unavailable inside compute()) -- but it's a hardware-accelerated
      // decode-at-reduced-size done once per shot here, not the continuous
      // 30fps loop that made transition-frame *encoding* worth
      // backgrounding. Only the CPU-bound JPEG re-encode is deferred to
      // compute(), collected via Future.wait below.
      final pendingShots = <_PendingBurstShot>[];
      for (final raw in rawShots) {
        try {
          final decoded = await decodeStillJpegToLuma(raw.jpeg, _sensorOrientation);
          if (decoded == null) continue;
          pendingShots.add(_PendingBurstShot(
            phaseNumber: raw.phaseNumber,
            angleDeg: raw.angleDeg,
            timestamp: raw.timestamp,
            flashOn: raw.flashOn,
            laplacianScore: raw.laplacianScore,
            encodedBytes: compute(
              _encodeBurstStillIsolate,
              _BurstEncodeArgs(decoded.luma, decoded.width, decoded.height),
            ),
          ));
        } catch (e) {
          debugPrint('[osc] burst shot decode failed (non-fatal): $e');
        }
      }
      if (pendingShots.isNotEmpty) {
        final encoded = await Future.wait(pendingShots.map((p) => p.encodedBytes));
        for (var i = 0; i < pendingShots.length; i++) {
          final p = pendingShots[i];
          _capturedFrames.add(_CapturedFrame(
            bytes: encoded[i],
            phaseNumber: p.phaseNumber,
            angleDeg: p.angleDeg,
            velocityDegPerSec: 0,
            timestamp: p.timestamp,
            isBurst: true,
            flashOn: p.flashOn,
            laplacianScore: p.laplacianScore,
          ));
        }
      }

      HapticFeedback.heavyImpact();
      unawaited(_audio.playAngleSuccess(
        isFinal: _state.stepIndex == oscillatingSteps.length - 1,
      ));
      _apply(
        (s) => s.copyWith(
          confirmationText: '✓ ${step.label} captured',
          totalFramesCaptured: _capturedFrames.length,
        ),
        force: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: _confirmationDisplayMs));
    } finally {
      _burstInFlight = false;
      if (!_disposed) {
        _apply(
          (s) => s.copyWith(isCapturingBurst: false, confirmationText: null),
          force: true,
        );
      }
      if (wasStreaming && !_disposed && cam != null) {
        try {
          await cam.startImageStream(_onFrame);
          _streamRunning = true;
        } catch (e) {
          debugPrint('[osc] failed to resume stream after burst: $e');
        }
      }
      _advanceStep();
    }
  }

  // ── Video-frame extraction ────────────────────────────────────────────
  //
  // Split into a synchronous crop (cheap memcpy, must run on the UI isolate
  // since CameraImage's native buffer isn't valid once _onFrame returns) and
  // an isolate-run encode (see _encodeGrayJpegIsolate below) -- see the
  // compute() call in _handleTransitionFrame for why.

  _GrayCrop? _cropFrameGray(CameraImage image) {
    if (image.planes.isEmpty) return null;
    try {
      final plane = image.planes[0];
      final bytes = plane.bytes;
      final w = image.width;
      final h = image.height;
      if (w < 8 || h < 8) return null;
      final stride =
          h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;

      final x0 = (_videoRoi.left * w).floor().clamp(0, w - 2);
      final x1 = (_videoRoi.right * w).ceil().clamp(x0 + 1, w);
      final y0 = (_videoRoi.top * h).floor().clamp(0, h - 2);
      final y1 = (_videoRoi.bottom * h).ceil().clamp(y0 + 1, h);
      final cw = x1 - x0;
      final ch = y1 - y0;

      final out = Uint8List(cw * ch);
      for (var y = 0; y < ch; y++) {
        final srcStart = (y0 + y) * stride + x0;
        out.setRange(y * cw, (y + 1) * cw, bytes, srcStart);
      }
      return _GrayCrop(out, cw, ch);
    } on RangeError {
      return null;
    } catch (e) {
      debugPrint('[osc] video-frame crop failed (non-fatal): $e');
      return null;
    }
  }

  // ── Upload ─────────────────────────────────────────────────────────────
  //
  // Uploads frames + rich per-frame metadata to Storage/Firestore, then
  // triggers processEnhanceAndScore with captureMode: 'oscillating_8phase'
  // so the backend's _download_oscillating_frames path picks it up — see
  // that function for how the dense frame stream gets binned down into a
  // cylindrical-projection input.

  Future<void> _finishAndUpload() async {
    _audio.silence();
    _apply((s) => s.copyWith(phase: OscillatingPhase.uploading, uploadProgress: 0), force: true);
    await _stopStream();
    _orientation.dispose();

    final userId = _userId;
    if (userId == null) {
      _fail('No user ID — cannot upload');
      return;
    }

    try {
      final id = _uuid.v4();
      final basePath = 'captures/$userId/$id';

      final uploadTasks = <(Uint8List, String)>[];
      final framesMeta = <Map<String, dynamic>>[];
      final burstCounters = <int, int>{};
      final transCounters = <int, int>{};

      for (final f in _capturedFrames) {
        final String path;
        if (f.isBurst) {
          final idx = burstCounters.update(f.phaseNumber, (v) => v + 1, ifAbsent: () => 0);
          path = '$basePath/phase_${f.phaseNumber}_burst_$idx.jpg';
        } else {
          final idx = transCounters.update(f.phaseNumber, (v) => v + 1, ifAbsent: () => 0);
          path = '$basePath/phase_${f.phaseNumber}_transition_'
              '${idx.toString().padLeft(3, '0')}.jpg';
        }
        uploadTasks.add((f.bytes, path));
        framesMeta.add({
          'path': path,
          'phaseNumber': f.phaseNumber,
          'type': f.isBurst ? 'burst' : 'transition',
          'angleDeg': double.parse(f.angleDeg.toStringAsFixed(2)),
          'flashOn': f.flashOn,
          if (f.laplacianScore != null)
            'laplacianScore': double.parse(f.laplacianScore!.toStringAsFixed(1)),
          if (!f.isBurst)
            'angularVelocityDegPerSec': double.parse(f.velocityDegPerSec.toStringAsFixed(1)),
          'timestamp': f.timestamp.toIso8601String(),
        });
      }

      final firestoreFuture = FirebaseFirestore.instance.collection('captures').doc(id).set({
        'captureId': id,
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'pending',
        'source': 'capture_harness',
        'captureMode': 'oscillating_8phase',
        'captureMethod': 'oscillating_8phase_v1',
        'frameCount': _capturedFrames.length,
        'burstFrameCount': _capturedFrames.where((f) => f.isBurst).length,
        'transitionFrameCount': _capturedFrames.where((f) => !f.isBurst).length,
        'phases': [
          for (var i = 0; i < oscillatingSteps.length; i++)
            {
              'phaseNumber': i + 1,
              'label': oscillatingSteps[i] is _BurstStep
                  ? (oscillatingSteps[i] as _BurstStep).label
                  : (oscillatingSteps[i] as _TransitionStep).label,
              'type': oscillatingSteps[i] is _BurstStep ? 'burst' : 'transition',
            },
        ],
        'frames': framesMeta,
      }, SetOptions(merge: true));

      var completed = 0;
      final total = uploadTasks.isEmpty ? 1 : uploadTasks.length;
      for (var i = 0; i < uploadTasks.length; i += _uploadConcurrency) {
        final end = math.min(i + _uploadConcurrency, uploadTasks.length);
        await Future.wait([
          for (var j = i; j < end; j++)
            FirebaseStorage.instance
                .ref()
                .child(uploadTasks[j].$2)
                .putData(uploadTasks[j].$1, SettableMetadata(contentType: 'image/jpeg'))
                .then((_) {
              completed++;
              _apply((s) => s.copyWith(uploadProgress: completed / total));
            }),
        ]);
      }
      await firestoreFuture;

      // Fire-and-forget, matching every other capture mode's uploader
      // (BackendCaptureUploader.uploadAndProcess /
      // ArcCaptureUploader.uploadArcAndProcess) — the callable's own
      // Firestore writes (status: enhancing -> scored/failed) are the
      // durable record of processing outcome, not this call's return value.
      () async {
        try {
          await FirebaseFunctions.instanceFor(region: 'africa-south1')
              .httpsCallable('processEnhanceAndScore')
              .call({
            'captureId': id,
            'userId': userId,
            'basePath': basePath,
            'captureMode': 'oscillating_8phase',
          });
        } catch (e) {
          debugPrint('[osc] processEnhanceAndScore trigger failed (non-blocking): $e');
        }
      }();

      _apply(
        (s) => s.copyWith(
          phase: OscillatingPhase.complete,
          captureId: id,
          uploadProgress: 1.0,
        ),
        force: true,
      );
    } catch (e) {
      _fail('Upload failed: $e');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

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
    _apply((s) => s.copyWith(phase: OscillatingPhase.error, error: message), force: true);
  }

  void _apply(OscillatingCaptureState Function(OscillatingCaptureState) update, {bool force = false}) {
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
    _orientation.dispose();
    unawaited(_stopStream());
    _cvClassifier?.dispose();
    _landmarker.dispose();
    _audio.dispose();
    super.dispose();
  }
}
