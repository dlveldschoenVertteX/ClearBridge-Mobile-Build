import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image/image.dart' as imglib;
import 'package:mac_capture/mac_capture.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// One of the 8 fixed positions the user holds still at while the ISP fires
/// a burst of real [CameraController.takePicture] stills.
class _BurstStep {
  final double targetDeg;
  final String label;
  final String instruction;
  const _BurstStep({
    required this.targetDeg,
    required this.label,
    required this.instruction,
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
/// top, alternating burst holds with guided transitions. All 8 phases are
/// driven off a single signed angle (the device's relative pitch — the same
/// axis [ThumbAngleService] uses for the left/right orbit in the 4-angle
/// flow), so phase 8's "+30°" target sits on that same scale rather than
/// introducing a second physical axis.
final List<Object> oscillatingSteps = [
  const _BurstStep(
    targetDeg: 0,
    label: 'FRONT',
    instruction: 'Position thumb at FRONT. Keep steady.',
  ),
  const _TransitionStep(
    fromDeg: 0,
    toDeg: -45,
    waypoints: [-15, -30, -45],
    label: 'LEFT',
    instruction: 'Move SLOWLY to the LEFT.',
  ),
  const _BurstStep(
    targetDeg: -45,
    label: 'LEFT',
    instruction: 'Hold STEADY at LEFT (-45°). Capturing…',
  ),
  const _TransitionStep(
    fromDeg: -45,
    toDeg: 0,
    waypoints: [-30, -15, 0],
    label: 'FRONT',
    instruction: 'Move SLOWLY back to FRONT.',
  ),
  const _TransitionStep(
    fromDeg: 0,
    toDeg: 45,
    waypoints: [15, 30, 45],
    label: 'RIGHT',
    instruction: 'Move SLOWLY to the RIGHT.',
  ),
  const _BurstStep(
    targetDeg: 45,
    label: 'RIGHT',
    instruction: 'Hold STEADY at RIGHT (+45°). Capturing…',
  ),
  const _TransitionStep(
    fromDeg: 45,
    toDeg: 0,
    waypoints: [30, 15, 0],
    label: 'FRONT',
    instruction: 'Move SLOWLY back to FRONT.',
  ),
  const _BurstStep(
    targetDeg: 30,
    label: 'TOP',
    instruction: 'Tilt thumb UP slightly. Keep thumb centered.',
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
  final bool isCapturingBurst;
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
    this.isCapturingBurst = false,
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
    bool? isCapturingBurst,
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
        isCapturingBurst: isCapturingBurst ?? this.isCapturingBurst,
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
  const _CapturedFrame({
    required this.bytes,
    required this.phaseNumber,
    required this.angleDeg,
    required this.velocityDegPerSec,
    required this.timestamp,
    required this.isBurst,
  });
}

/// 8-phase oscillating capture: front → left → front → right → front → top,
/// alternating real-ISP burst stills at each hold position with guided
/// video-frame-extraction transitions between them.
///
/// Deliberately lean compared to the package's other capture controllers
/// (no ML thumb-coverage gate, no torch/flash logic, a fixed-delay
/// calibration instead of a focus-stability tracker) — this mode is purely
/// angle-and-timing driven per its spec, and staying minimal keeps it fast
/// to retune while the geometry itself is still being worked out.
class OscillatingCaptureController extends ChangeNotifier {
  static const double _holdToleranceDeg = 5.0;
  static const double _waypointToleranceDeg = 5.0;
  static const int _holdDurationMs = 1500;
  static const int _burstFrameCount = 6; // spec range: 5-8
  static const int _burstShotDelayMs = 90;
  static const double _maxAngularVelocityDegPerSec = 30.0;
  static const int _videoFrameMinIntervalMs = 33; // caps extraction at ~30fps
  static const int _maxVideoFramesPerTransition = 150; // safety cap
  static const int _emitThrottleMs = 80;
  static const int _confirmationDisplayMs = 700;

  // Loose centre crop for transition frames — cuts background while leaving
  // margin for a wandering thumb during the move (unlike a burst hold, the
  // thumb position isn't locked down during a transition).
  static const Rect _videoRoi = Rect.fromLTRB(0.15, 0.12, 0.85, 0.88);

  CameraController? _camera;
  String? _userId;

  OscillatingCaptureState _state = const OscillatingCaptureState();
  OscillatingCaptureState get state => _state;

  final _orientation = DeviceOrientationService();
  final _hybrid = HybridCaptureService(); // live focus meter only — no gating

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

    _capturedFrames.clear();
    _holdStart = null;
    _currentWaypointIndex = 0;
    _waypointFired = false;
    _lastAngle = 0;
    _lastAngleAt = null;
    _angularVelocity = 0;
    _lastVideoFrameAt = null;
    _focusPeak = 1.0;
    _hybrid.reset();

    _state = const OscillatingCaptureState(phase: OscillatingPhase.calibrating);
    notifyListeners();

    try {
      await camera.setFocusMode(FocusMode.auto);
      await camera.setFocusPoint(const Offset(0.5, 0.5));
    } catch (_) {}
    // Fixed settle delay rather than a focus-stability tracker: every burst
    // frame is a real takePicture() still (the ISP re-focuses/re-meters each
    // shot), so this only needs to get the lens roughly pointed before the
    // stream starts — not lock in a perfect calibration.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_disposed) return;

    _orientation.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (_disposed) return;
    _orientation.captureReference();

    try {
      if (camera.value.isStreamingImages) {
        try {
          await camera.stopImageStream();
        } catch (_) {}
      }
      await camera.startImageStream(_onFrame);
      _streamRunning = true;
    } catch (e) {
      _fail('Could not start camera stream: $e');
      _starting = false;
      return;
    }

    _starting = false;
    HapticFeedback.mediumImpact();
    _enterStep(0, force: true);
  }

  void _enterStep(int index, {bool force = false}) {
    _holdStart = null;
    _currentWaypointIndex = 0;
    _waypointFired = false;
    _lastVideoFrameAt = null;

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
    if (_disposed || _state.phase != OscillatingPhase.running) return;
    if (_burstInFlight) return; // stream is stopped during a burst anyway

    // Live sharpness readout — diagnostic only, never gates capture.
    try {
      final raw = _hybrid.offerFrame(image);
      if (raw > _focusPeak) _focusPeak = raw;
      _focusPeak *= 0.995;
      _focusValue = HybridCaptureService.ema(
        _focusValue,
        (raw / (_focusPeak + 1e-6)).clamp(0.0, 1.0),
      );
    } catch (_) {}

    final angle = _orientation.relativeOrientation().pitch;
    final now = DateTime.now();
    if (_lastAngleAt != null) {
      final dt = now.difference(_lastAngleAt!).inMicroseconds / 1e6;
      if (dt > 0.001) {
        final raw = (angle - _lastAngle).abs() / dt;
        _angularVelocity = HybridCaptureService.ema(_angularVelocity, raw, alpha: 0.35);
      }
    }
    _lastAngle = angle;
    _lastAngleAt = now;

    final step = oscillatingSteps[_state.stepIndex];
    if (step is _BurstStep) {
      _handleBurstFrame(angle, step);
    } else if (step is _TransitionStep) {
      _handleTransitionFrame(image, angle, step);
    }
  }

  void _handleBurstFrame(double angle, _BurstStep step) {
    final dist = (angle - step.targetDeg).abs();
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
        _holdStart = null;
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

  void _handleTransitionFrame(CameraImage image, double angle, _TransitionStep step) {
    // Video-frame extraction, throttled to ~30fps and capped defensively.
    final now = DateTime.now();
    if ((_lastVideoFrameAt == null ||
            now.difference(_lastVideoFrameAt!).inMilliseconds >= _videoFrameMinIntervalMs) &&
        _capturedFrames.length < _maxVideoFramesPerTransition * 4) {
      final transitionFrameCount = _capturedFrames
          .where((f) => !f.isBurst && f.phaseNumber == _state.stepIndex + 1)
          .length;
      if (transitionFrameCount < _maxVideoFramesPerTransition) {
        final jpeg = _extractFrameJpeg(image);
        if (jpeg != null) {
          _capturedFrames.add(_CapturedFrame(
            bytes: jpeg,
            phaseNumber: _state.stepIndex + 1,
            angleDeg: angle,
            velocityDegPerSec: _angularVelocity,
            timestamp: now,
            isBurst: false,
          ));
          _lastVideoFrameAt = now;
        }
      }
    }

    final target = step.waypoints[_currentWaypointIndex];
    final dist = (angle - target).abs();
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
    _apply((s) => s.copyWith(isCapturingBurst: true), force: true);

    final cam = _camera;
    final wasStreaming = _streamRunning;

    try {
      if (cam == null) return;
      if (wasStreaming) await _stopStream();

      for (var i = 0; i < _burstFrameCount; i++) {
        try {
          final xfile = await cam.takePicture();
          final bytes = await xfile.readAsBytes();
          // DeviceOrientationService reads a native EventChannel independent
          // of the camera image stream, so it keeps updating even while the
          // stream is stopped for takePicture() — read fresh per shot rather
          // than reusing the pre-burst angle.
          _capturedFrames.add(_CapturedFrame(
            bytes: bytes,
            phaseNumber: _state.stepIndex + 1,
            angleDeg: _orientation.relativeOrientation().pitch,
            velocityDegPerSec: 0,
            timestamp: DateTime.now(),
            isBurst: true,
          ));
        } catch (e) {
          debugPrint('[osc] burst shot $i failed (non-fatal): $e');
        }
        if (i < _burstFrameCount - 1) {
          await Future<void>.delayed(const Duration(milliseconds: _burstShotDelayMs));
        }
      }

      HapticFeedback.heavyImpact();
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

  Uint8List? _extractFrameJpeg(CameraImage image) {
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
      final imgObj = imglib.Image.fromBytes(
        width: cw,
        height: ch,
        bytes: out.buffer,
        numChannels: 1,
      );
      return Uint8List.fromList(imglib.encodeJpg(imgObj, quality: 88));
    } on RangeError {
      return null;
    } catch (e) {
      debugPrint('[osc] video-frame encode failed (non-fatal): $e');
      return null;
    }
  }

  // ── Upload ─────────────────────────────────────────────────────────────
  //
  // No backend pipeline understands this frame layout yet (8 phases mixing
  // real-ISP burst stills with stream-extracted transition frames is a new
  // schema), so this uploads raw frames + rich per-frame metadata to
  // Storage/Firestore for inspection and pipeline development, and does NOT
  // trigger processEnhanceAndScore.

  Future<void> _finishAndUpload() async {
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
          if (!f.isBurst)
            'angularVelocityDegPerSec': double.parse(f.velocityDegPerSec.toStringAsFixed(1)),
          'timestamp': f.timestamp.toIso8601String(),
        });
      }

      final firestoreFuture = FirebaseFirestore.instance.collection('captures').doc(id).set({
        'captureId': id,
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'captured_unprocessed',
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
      for (var i = 0; i < uploadTasks.length; i += 6) {
        final end = math.min(i + 6, uploadTasks.length);
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
    _orientation.dispose();
    unawaited(_stopStream());
    super.dispose();
  }
}
