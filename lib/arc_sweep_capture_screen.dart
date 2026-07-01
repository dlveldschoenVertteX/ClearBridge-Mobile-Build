import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_ui.dart';
import 'package:clearbridge/arc_sweep_capture_controller.dart';
import 'package:clearbridge/camera_service.dart';
import 'package:clearbridge/fingerprint_frame_upload_service.dart';
import 'package:clearbridge/capture_intro_animation.dart';
import 'package:clearbridge/focus_meter_widget.dart';
import 'package:clearbridge/lighting_meter_widget.dart';

/// Arc-sweep capture screen.
///
/// The user holds the phone in portrait orientation and sweeps it around a
/// stationary thumb. An arc progress indicator shows how much of the 200°
/// span has been captured. No per-angle hold-steady gate — just sweep slowly.
class ArcSweepCaptureScreen extends ConsumerStatefulWidget {
  const ArcSweepCaptureScreen({super.key});

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
      ref.read(arcSweepCaptureControllerProvider).startIntro();
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Session expired — please log in again.'),
          backgroundColor: ClearBridgeColors.error,
        ));
        context.go(AppConstants.loginRoute);
      }
      return;
    }
    final cam = _camera;
    if (cam == null) return;
    await ref.read(arcSweepCaptureControllerProvider).startCaptureSequence(
          camera: cam,
          uploadService: ref.read(fingerprintFrameUploadServiceProvider),
          userId: user.uid,
        );
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppConstants.dashboardRoute);
    }
  }

  void _onStateChanged(ArcSweepState s) {
    if (_navigated) return;
    if (s.phase == ArcSweepPhase.complete && s.captureId != null) {
      _navigated = true;
      context.go('/capture/result', extra: s.captureId);
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
        backgroundColor: ClearBridgeColors.void_,
        body: Center(child: CircularProgressIndicator(color: ClearBridgeColors.cyan)),
      );
    }

    final phase = ref.watch(
      arcSweepCaptureControllerProvider.select((c) => c.state.phase),
    );

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: Stack(
        children: [
          // Camera preview
          Positioned.fill(
            child: RepaintBoundary(child: _cameraLayer()),
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
                    style: ClearBridgeTypography.label.copyWith(
                      fontSize: 13,
                      color: ClearBridgeColors.silverBright,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(
                    backgroundColor: ClearBridgeColors.steelMuted,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(ClearBridgeColors.cyan),
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
                    style: ClearBridgeTypography.body.copyWith(
                      fontSize: 14,
                      color: ClearBridgeColors.silverBright,
                    ),
                  ),
                  const SizedBox(height: 20),
                  CbButton(
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
                        style: ClearBridgeTypography.label.copyWith(
                          fontSize: 13,
                          color: ClearBridgeColors.silverBright,
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
                  color: ClearBridgeColors.silverBright, size: 22),
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
                  color: ClearBridgeColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: ClearBridgeColors.cyanBorder),
                ),
                child: Text(
                  'ARC SWEEP',
                  style: ClearBridgeTypography.label.copyWith(
                    fontSize: 11,
                    color: ClearBridgeColors.cyan,
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
        child: Icon(Icons.flash_off, color: ClearBridgeColors.silverDim, size: 16),
      );
    }
    return Icon(
      Icons.flash_on,
      color: flashOn ? ClearBridgeColors.gold : ClearBridgeColors.silverDim,
      size: 16,
    );
  }

  Widget _cameraLayer() {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      return const ColoredBox(color: ClearBridgeColors.void_);
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
      color: ClearBridgeColors.void_.withValues(alpha: 0.92),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: ClearBridgeColors.error, size: 44),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: ClearBridgeTypography.body.copyWith(fontSize: 14)),
            const SizedBox(height: 22),
            CbButton(label: 'Back', variant: CbButtonVariant.ghost, onPressed: _close),
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
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
          style: ClearBridgeTypography.label.copyWith(
            fontSize: 13,
            color: ClearBridgeColors.silverBright,
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
      ..color = ClearBridgeColors.steelMuted.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startRad, spanRad, false, trackPaint);

    // Filled progress
    if (fraction > 0.0) {
      final fillPaint = Paint()
        ..color = isActive ? ClearBridgeColors.cyan : ClearBridgeColors.success
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
            ? ClearBridgeColors.cyan
            : ClearBridgeColors.steelMuted
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
          ? ClearBridgeColors.cyan.withValues(alpha: 0.15)
          : ClearBridgeColors.steelMuted.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 18, centerPaint);

    // Center icon (fingerprint — concentric arc set)
    final iconPaint = Paint()
      ..color = isActive ? ClearBridgeColors.cyan : ClearBridgeColors.silverDim
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
      color: ClearBridgeColors.void_,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            AppConstants.logoPath,
            width: 120,
            height: 120,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 48),
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
            style: ClearBridgeTypography.body.copyWith(
              color: ClearBridgeColors.silverBright,
              fontSize: 15,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
