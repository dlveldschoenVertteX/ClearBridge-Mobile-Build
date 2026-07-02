import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'arc_capture_uploader.dart';
import 'arc_sweep_capture_controller.dart';
import 'camera_service.dart';
import 'capture_button.dart';
import 'capture_colors.dart';
import 'capture_intro_animation.dart';
import 'capture_typography.dart';
import 'capture_vignette_overlay.dart';
import 'focus_meter_widget.dart';
import 'lighting_meter_widget.dart';

/// Arc-sweep capture screen.
///
/// The user holds the phone in portrait orientation and sweeps it around a
/// stationary thumb. An arc progress indicator shows how much of the 200°
/// span has been captured. No per-angle hold-steady gate — just sweep slowly.
class ArcSweepCaptureScreen extends ConsumerStatefulWidget {
  const ArcSweepCaptureScreen({
    super.key,
    required this.uploader,
    required this.getUserId,
    required this.onRequireLogin,
    required this.onComplete,
    required this.onClose,
  });

  /// Backend that persists the sweep (Firebase, or anything else).
  final ArcCaptureUploader uploader;

  /// Returns the current authenticated user's ID, or null if signed out.
  final String? Function() getUserId;

  /// Called when [getUserId] returns null as the sweep is about to start.
  final VoidCallback onRequireLogin;

  /// Called once the capture finishes uploading, with the capture ID.
  final void Function(String captureId) onComplete;

  /// Called when the user backs out of the screen.
  final VoidCallback onClose;

  @override
  ConsumerState<ArcSweepCaptureScreen> createState() =>
      _ArcSweepCaptureScreenState();
}

class _ArcSweepCaptureScreenState extends ConsumerState<ArcSweepCaptureScreen> {
  final CameraService _cameraService = CameraService();
  bool _ready = false;
  bool _navigated = false;
  String? _initError;

  CameraController? get _camera => _cameraService.controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _cameraService.initializeCamera(
        lensDirection: CameraLensDirection.back,
        resolution: ResolutionPreset.max,
      );
      if (!mounted) return;
      setState(() => _ready = true);
      // No intro animation is rendered on this screen, so advance straight
      // through showingAnimation to awaitingStart — without this the phase
      // machine stalls and the Start button never appears.
      ref.read(arcSweepCaptureControllerProvider)
        ..startIntro()
        ..onAnimationComplete();
    } catch (e) {
      if (mounted) setState(() => _initError = '$e');
    }
  }

  @override
  void dispose() {
    _cameraService.disposeCamera();
    super.dispose();
  }

  Future<void> _onStart() async {
    final userId = widget.getUserId();
    if (userId == null) {
      widget.onRequireLogin();
      return;
    }
    final cam = _camera;
    if (cam == null) return;
    await ref.read(arcSweepCaptureControllerProvider).startCaptureSequence(
          camera: cam,
          uploadService: widget.uploader,
          userId: userId,
        );
  }

  void _close() => widget.onClose();

  void _onStateChanged(ArcSweepState s) {
    if (_navigated) return;
    if (s.phase == ArcSweepPhase.complete && s.captureId != null) {
      _navigated = true;
      widget.onComplete(s.captureId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ArcSweepCaptureController>(
      arcSweepCaptureControllerProvider,
      (_, next) => _onStateChanged(next.state),
    );

    if (_initError != null) return _errorScaffold(_initError!);
    if (!_ready) {
      return const Scaffold(
        backgroundColor: CaptureColors.void_,
        body: Center(child: CircularProgressIndicator(color: CaptureColors.cyan)),
      );
    }

    final phase = ref.watch(
      arcSweepCaptureControllerProvider.select((c) => c.state.phase),
    );

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Stack(
        children: [
          // Camera preview
          Positioned.fill(
            child: RepaintBoundary(child: _cameraLayer()),
          ),

          // Vignette: fades background to black so only the centred thumb is
          // prominent — same framing cue as the 4-angle capture screen.
          const Positioned.fill(
            child: RepaintBoundary(child: CaptureVignetteOverlay()),
          ),

          // Left: lighting meter
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: RepaintBoundary(
                child: Consumer(
                  builder: (_, ref, __) {
                    final v = ref.watch(arcSweepCaptureControllerProvider
                        .select((c) => c.state.lightingValue));
                    return LightingMeterWidget(value: v);
                  },
                ),
              ),
            ),
          ),

          // Right: focus meter
          Positioned(
            right: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: RepaintBoundary(
                child: Consumer(
                  builder: (_, ref, __) {
                    final v = ref.watch(arcSweepCaptureControllerProvider
                        .select((c) => c.state.focusValue));
                    return FocusMeterWidget(value: v);
                  },
                ),
              ),
            ),
          ),

          // Center: arc progress indicator (sweeping and calibrating phases)
          if (phase == ArcSweepPhase.sweeping ||
              phase == ArcSweepPhase.calibrating ||
              phase == ArcSweepPhase.awaitingStart)
            Center(
              child: RepaintBoundary(
                child: Consumer(
                  builder: (_, ref, __) {
                    final s = ref.watch(arcSweepCaptureControllerProvider).state;
                    return _ArcProgressWidget(
                      sweepAngleDeg: s.sweepAngleDeg,
                      binsFilledCount: s.binsFilledCount,
                      phase: s.phase,
                    );
                  },
                ),
              ),
            ),

          // Calibrating overlay
          if (phase == ArcSweepPhase.calibrating)
            Positioned(
              bottom: 80,
              left: 40,
              right: 40,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Preparing camera…',
                    textAlign: TextAlign.center,
                    style: CaptureTypography.label.copyWith(
                      fontSize: 13,
                      color: CaptureColors.silverBright,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(
                    backgroundColor: CaptureColors.steelMuted,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(CaptureColors.cyan),
                  ),
                ],
              ),
            ),

          // Start button
          if (phase == ArcSweepPhase.awaitingStart)
            Positioned(
              left: 40,
              right: 40,
              bottom: 100,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Hold thumb still. Sweep camera slowly around it.',
                    textAlign: TextAlign.center,
                    style: CaptureTypography.body.copyWith(
                      fontSize: 14,
                      color: CaptureColors.silverBright,
                    ),
                  ),
                  const SizedBox(height: 20),
                  CaptureButton(
                    label: 'Start Sweep',
                    leadingIcon: Icons.rotate_right_rounded,
                    onPressed: _onStart,
                  ),
                ],
              ),
            ),

          // Sweeping guidance
          if (phase == ArcSweepPhase.sweeping)
            Positioned(
              bottom: 60,
              left: 40,
              right: 40,
              child: Consumer(
                builder: (_, ref, __) {
                  final s = ref.watch(arcSweepCaptureControllerProvider).state;
                  final pct = (s.binsFilledCount * 25.0 / _arcTarget * 100).round().clamp(0, 100);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$pct% covered — keep sweeping',
                        textAlign: TextAlign.center,
                        style: CaptureTypography.label.copyWith(
                          fontSize: 13,
                          color: CaptureColors.silverBright,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

          // Uploading overlay
          if (phase == ArcSweepPhase.uploading)
            Positioned.fill(child: const _UploadingOverlay()),

          // Flash indicator
          if (phase == ArcSweepPhase.sweeping || phase == ArcSweepPhase.calibrating)
            Positioned(
              top: 52,
              right: 50,
              child: Consumer(
                builder: (_, ref, __) {
                  final s = ref.watch(arcSweepCaptureControllerProvider).state;
                  return _buildFlashIndicator(s.flashOn, s.flashIntensity);
                },
              ),
            ),

          // Error overlay
          if (phase == ArcSweepPhase.error)
            Positioned.fill(
              child: Consumer(
                builder: (_, ref, __) {
                  final err = ref.watch(arcSweepCaptureControllerProvider
                      .select((c) => c.state.error));
                  return _errorOverlay(err ?? 'Capture failed');
                },
              ),
            ),

          // Back arrow
          Positioned(
            top: 48,
            left: 16,
            child: GestureDetector(
              onTap: _close,
              child: const Icon(Icons.arrow_back_ios,
                  color: CaptureColors.silverBright, size: 22),
            ),
          ),

          // Mode label
          Positioned(
            top: 48,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: CaptureColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: CaptureColors.cyanBorder),
                ),
                child: Text(
                  'ARC SWEEP',
                  style: CaptureTypography.label.copyWith(
                    fontSize: 11,
                    color: CaptureColors.cyan,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlashIndicator(bool flashOn, double flashIntensity) {
    if (flashIntensity == 0.0) {
      return const Opacity(
        opacity: 0.3,
        child: Icon(Icons.flash_off, color: CaptureColors.silverDim, size: 16),
      );
    }
    return Icon(
      Icons.flash_on,
      color: flashOn ? CaptureColors.gold : CaptureColors.silverDim,
      size: 16,
    );
  }

  Widget _cameraLayer() {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      return const ColoredBox(color: CaptureColors.void_);
    }
    final preview = cam.value.previewSize;
    final w = preview?.height ?? cam.value.previewSize?.width ?? 1080;
    final h = preview?.width ?? cam.value.previewSize?.height ?? 1920;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: w, height: h, child: CameraPreview(cam)),
    );
  }

  Widget _errorOverlay(String message) {
    return Container(
      color: CaptureColors.void_.withValues(alpha: 0.92),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: CaptureColors.error, size: 44),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: CaptureTypography.body.copyWith(fontSize: 14)),
            const SizedBox(height: 22),
            CaptureButton(label: 'Back', variant: CaptureButtonVariant.ghost, onPressed: _close),
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: SafeArea(child: _errorOverlay('Camera error: $message')),
    );
  }
}

// ── Arc target constant (matches controller) ───────────────────────────────────
const _arcTarget = 200.0;

/// Circular arc progress indicator for the arc sweep capture.
class _ArcProgressWidget extends StatelessWidget {
  const _ArcProgressWidget({
    required this.sweepAngleDeg,
    required this.binsFilledCount,
    required this.phase,
  });

  final double sweepAngleDeg;
  final int binsFilledCount;
  final ArcSweepPhase phase;

  @override
  Widget build(BuildContext context) {
    final coverageFraction = (binsFilledCount * 25.0 / _arcTarget).clamp(0.0, 1.0);
    final isActive = phase == ArcSweepPhase.sweeping;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 180,
          height: 180,
          child: CustomPaint(
            painter: _ArcPainter(
              fraction: coverageFraction,
              isActive: isActive,
              binsFilledCount: binsFilledCount,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          isActive
              ? '${binsFilledCount * 25}° / ${_arcTarget.toInt()}° covered'
              : 'Position thumb in centre',
          style: CaptureTypography.label.copyWith(
            fontSize: 13,
            color: CaptureColors.silverBright,
          ),
        ),
      ],
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter({
    required this.fraction,
    required this.isActive,
    required this.binsFilledCount,
  });

  final double fraction;
  final bool isActive;
  final int binsFilledCount;

  // The arc spans 200° centered on the bottom of the circle, sweeping from
  // left to right. Start angle in Flutter convention (0° = 3 o'clock):
  static const _spanDeg = _arcTarget;
  static const _startDeg = 90.0 + (_spanDeg / 2);  // 190° → starts at ~7 o'clock

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final startRad = _startDeg * math.pi / 180;
    final spanRad = _spanDeg * math.pi / 180;

    // Background track
    final trackPaint = Paint()
      ..color = CaptureColors.steelMuted.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startRad, spanRad, false, trackPaint);

    // Filled progress
    if (fraction > 0.0) {
      final fillPaint = Paint()
        ..color = isActive ? CaptureColors.cyan : CaptureColors.success
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, startRad, spanRad * fraction, false, fillPaint);
    }

    // Bin tick marks (every 25°)
    const binCount = 8; // _spanDeg (200°) / 25°
    for (var i = 0; i <= binCount; i++) {
      final tickAngle = startRad + (i / binCount) * spanRad;
      final outerR = radius + 5;
      final innerR = radius - (i < binsFilledCount ? 8 : 4);
      final dx = math.cos(tickAngle);
      final dy = math.sin(tickAngle);
      final tickPaint = Paint()
        ..color = i < binsFilledCount
            ? CaptureColors.cyan
            : CaptureColors.steelMuted
        ..strokeWidth = i < binsFilledCount ? 2.5 : 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(center.dx + dx * innerR, center.dy + dy * innerR),
        Offset(center.dx + dx * outerR, center.dy + dy * outerR),
        tickPaint,
      );
    }

    // Center circle
    final centerPaint = Paint()
      ..color = isActive
          ? CaptureColors.cyan.withValues(alpha: 0.15)
          : CaptureColors.steelMuted.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 18, centerPaint);

    // Center icon (fingerprint — concentric arc set)
    final iconPaint = Paint()
      ..color = isActive ? CaptureColors.cyan : CaptureColors.silverDim
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (var r = 12.0; r <= 30.0; r += 6) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        math.pi * 0.7,
        math.pi * 1.6,
        false,
        iconPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.fraction != fraction ||
      old.isActive != isActive ||
      old.binsFilledCount != binsFilledCount;
}

// ── Upload overlay ─────────────────────────────────────────────────────────────

class _UploadingOverlay extends StatelessWidget {
  const _UploadingOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CaptureColors.void_,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 240,
            height: 240,
            child: CaptureIntroAnimation(
              onComplete: () {},
              loop: true,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Loading...',
            style: CaptureTypography.body.copyWith(
              color: CaptureColors.silverBright,
              fontSize: 15,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
