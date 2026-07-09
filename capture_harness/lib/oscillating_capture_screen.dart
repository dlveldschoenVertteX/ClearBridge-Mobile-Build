import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'oscillating_capture_controller.dart';

/// 8-phase oscillating capture screen: front → left → front → right →
/// front → top, alternating real-ISP burst stills with guided transitions.
/// See [OscillatingCaptureController] for the capture state machine — this
/// file is purely presentational.
class OscillatingCaptureScreen extends StatefulWidget {
  const OscillatingCaptureScreen({
    super.key,
    required this.getUserId,
    required this.onRequireLogin,
    required this.onComplete,
    required this.onClose,
  });

  final String? Function() getUserId;
  final VoidCallback onRequireLogin;
  final void Function(String captureId) onComplete;
  final VoidCallback onClose;

  @override
  State<OscillatingCaptureScreen> createState() => _OscillatingCaptureScreenState();
}

class _OscillatingCaptureScreenState extends State<OscillatingCaptureScreen> {
  final CameraService _cameraService = CameraService();
  late final OscillatingCaptureController _ctrl;
  bool _ready = false;
  bool _navigated = false;
  String? _initError;

  CameraController? get _camera => _cameraService.controller;

  @override
  void initState() {
    super.initState();
    _ctrl = OscillatingCaptureController();
    _ctrl.addListener(_onState);
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
    } catch (e) {
      if (mounted) setState(() => _initError = '$e');
    }
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    final s = _ctrl.state;
    if (!_navigated && s.phase == OscillatingPhase.complete && s.captureId != null) {
      _navigated = true;
      widget.onComplete(s.captureId!);
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onState);
    _ctrl.dispose();
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
    await _ctrl.start(camera: cam, userId: userId);
  }

  void _close() => widget.onClose();

  @override
  Widget build(BuildContext context) {
    if (_initError != null) return _errorScaffold(_initError!);
    if (!_ready) {
      return const Scaffold(
        backgroundColor: CaptureColors.void_,
        body: Center(child: CircularProgressIndicator(color: CaptureColors.cyan)),
      );
    }

    final s = _ctrl.state;
    final showDial = s.phase == OscillatingPhase.running;

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Stack(
        children: [
          Positioned.fill(child: RepaintBoundary(child: _cameraLayer())),
          const Positioned.fill(child: RepaintBoundary(child: CaptureVignetteOverlay())),

          // Right: live focus readout — diagnostic only, doesn't gate capture.
          if (showDial)
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: RepaintBoundary(child: FocusMeterWidget(value: _ctrl.focusValue)),
              ),
            ),

          // Centre: angle dial + guidance text.
          if (showDial)
            Center(
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 60),
                  child: _GuidancePanel(state: s),
                ),
              ),
            ),

          // Confirmation banner after a burst.
          if (s.confirmationText != null)
            Positioned(
              top: 110,
              left: 40,
              right: 40,
              child: _ConfirmationBanner(text: s.confirmationText!),
            ),

          // Start button.
          if (s.phase == OscillatingPhase.idle)
            Positioned(
              left: 40,
              right: 40,
              bottom: 100,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Front → Left → Front → Right → Front → Top. '
                    'Hold each position steady; move slowly between them.',
                    textAlign: TextAlign.center,
                    style: CaptureTypography.body.copyWith(
                      fontSize: 13,
                      color: CaptureColors.silverBright,
                    ),
                  ),
                  const SizedBox(height: 18),
                  CaptureButton(
                    label: 'Start Sequence',
                    leadingIcon: Icons.swap_horiz_rounded,
                    onPressed: _onStart,
                  ),
                ],
              ),
            ),

          if (s.phase == OscillatingPhase.calibrating)
            Positioned(
              bottom: 100,
              left: 40,
              right: 40,
              child: Text(
                'Preparing camera…',
                textAlign: TextAlign.center,
                style: CaptureTypography.label.copyWith(
                  fontSize: 13,
                  color: CaptureColors.silverBright,
                ),
              ),
            ),

          if (s.phase == OscillatingPhase.uploading)
            const Positioned.fill(child: _UploadingOverlay()),

          if (s.phase == OscillatingPhase.error)
            Positioned.fill(child: _errorOverlay(s.error ?? 'Capture failed')),

          Positioned(
            top: 48,
            left: 16,
            child: GestureDetector(
              onTap: _close,
              child: const Icon(Icons.arrow_back_ios, color: CaptureColors.silverBright, size: 22),
            ),
          ),

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
                  '8-PHASE OSCILLATING',
                  style: CaptureTypography.label.copyWith(
                    fontSize: 11,
                    color: CaptureColors.cyan,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ),

          if (showDial)
            Positioned(left: 0, right: 0, bottom: 0, child: _StatusPanel(state: s)),
        ],
      ),
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
            Text(message, textAlign: TextAlign.center, style: CaptureTypography.body.copyWith(fontSize: 14)),
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

// ── Guidance panel (dial + text) ──────────────────────────────────────────

class _GuidancePanel extends StatelessWidget {
  const _GuidancePanel({required this.state});
  final OscillatingCaptureState state;

  // Phase 8 (index 7) is the only step with a different dial range — see
  // the plan's axis-decision note in oscillating_capture_controller.dart.
  static const _defaultRange = (min: -41.0, max: 41.0);
  static const _topRange = (min: 0.0, max: 40.0);

  @override
  Widget build(BuildContext context) {
    final isTopPhase = state.stepIndex == 7;
    final range = isTopPhase ? _topRange : _defaultRange;

    final String deltaText;
    if (state.onTarget) {
      deltaText = state.isBurstStep ? 'On target' : 'On target ✓';
    } else {
      final dir = state.deltaDeg > 0 ? 'right' : 'left';
      // Phase 8 has no left/right meaning — just show the raw delta.
      deltaText = isTopPhase
          ? '${state.deltaDeg.abs().round()}° to go'
          : '${state.deltaDeg.abs().round()}° more $dir';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 220,
          height: 150,
          child: CustomPaint(
            painter: _AngleDialPainter(
              currentDeg: state.currentAngleDeg,
              targetDeg: state.targetAngleDeg,
              rangeMin: range.min,
              rangeMax: range.max,
              onTarget: state.onTarget,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          deltaText,
          style: CaptureTypography.h3.copyWith(
            fontSize: 20,
            color: state.onTarget ? CaptureColors.success : CaptureColors.silverBright,
          ),
        ),
        if (state.isBurstStep && state.holdProgress > 0) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: state.holdProgress,
                minHeight: 5,
                backgroundColor: CaptureColors.silverDim.withValues(alpha: 0.25),
                color: state.isCapturingBurst ? CaptureColors.gold : CaptureColors.success,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            state.isCapturingBurst ? 'Capturing…' : 'Holding steady…',
            style: CaptureTypography.label.copyWith(fontSize: 11),
          ),
        ],
        if (!state.isBurstStep) ...[
          const SizedBox(height: 4),
          Text(
            'Waypoint ${state.waypointIndex + 1}/${state.waypointTotal}',
            style: CaptureTypography.label.copyWith(fontSize: 11),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          state.tooFast ? 'Speed: ⚠ SLOW DOWN' : 'Speed: ${state.angularVelocityDegPerSec.round()}°/sec',
          style: CaptureTypography.label.copyWith(
            fontSize: 11,
            color: state.tooFast ? CaptureColors.warning : CaptureColors.silverDim,
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: CaptureGuidanceOverlay(
            message: 'Phase ${state.stepIndex + 1}/8 — ${state.instruction}',
            isAllGreen: state.onTarget,
            greenFraction: state.onTarget ? 1.0 : 0.0,
          ),
        ),
      ],
    );
  }
}

/// Half-circle gauge: 9 o'clock → 12 o'clock → 3 o'clock, mapping
/// [rangeMin, rangeMax] linearly onto that sweep. `0`/mid points straight
/// up; positive angles sweep toward 3 o'clock.
///
/// Canvas angle convention: for physical angle φ, the on-screen unit vector
/// is (dx, dy) = (sin(a), -cos(a)) where a = (φ-mid)/halfRange * (π/2) — a
/// standard "clock hand" parametrisation (a=0 → straight up). The equivalent
/// `Canvas.drawArc` angle is θ(φ) = a − π/2, which increases continuously
/// from −π (φ=min) through −π/2 (φ=mid, straight up) to 0 (φ=max) — verified
/// algebraically so the background arc and needle never disagree about
/// which side of the dial is which.
class _AngleDialPainter extends CustomPainter {
  const _AngleDialPainter({
    required this.currentDeg,
    required this.targetDeg,
    required this.rangeMin,
    required this.rangeMax,
    required this.onTarget,
  });

  final double currentDeg;
  final double targetDeg;
  final double rangeMin;
  final double rangeMax;
  final bool onTarget;

  static const double _toleranceDeg = 5.0;

  double _canvasAngle(double phi) {
    final mid = (rangeMin + rangeMax) / 2;
    final halfRange = (rangeMax - rangeMin) / 2;
    final a = (phi - mid) / halfRange * (math.pi / 2);
    return a - math.pi / 2;
  }

  Offset _pointAt(Offset center, double radius, double phi) {
    final theta = _canvasAngle(phi);
    return center + Offset(math.cos(theta), math.sin(theta)) * radius;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 8);
    final radius = math.min(size.width / 2, size.height) - 16;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Background track.
    canvas.drawArc(
      rect,
      -math.pi,
      math.pi,
      false,
      Paint()
        ..color = CaptureColors.steelMuted.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );

    // Tolerance wedge, filled pie-slice from centre.
    final loTheta = _canvasAngle((targetDeg - _toleranceDeg).clamp(rangeMin, rangeMax));
    final hiTheta = _canvasAngle((targetDeg + _toleranceDeg).clamp(rangeMin, rangeMax));
    canvas.drawArc(
      rect,
      loTheta,
      hiTheta - loTheta,
      true,
      Paint()
        ..color = CaptureColors.success.withValues(alpha: 0.16)
        ..style = PaintingStyle.fill,
    );

    // Reference ticks at quarter points.
    final tickPaint = Paint()
      ..color = CaptureColors.silverDim.withValues(alpha: 0.5)
      ..strokeWidth = 2;
    for (final f in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final phi = rangeMin + f * (rangeMax - rangeMin);
      final p0 = _pointAt(center, radius - 6, phi);
      final p1 = _pointAt(center, radius + 6, phi);
      canvas.drawLine(p0, p1, tickPaint);
    }

    // Target tick — emphasised.
    canvas.drawLine(
      _pointAt(center, radius - 10, targetDeg),
      _pointAt(center, radius + 10, targetDeg),
      Paint()
        ..color = CaptureColors.success
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );

    // Needle — clamp the display angle a little past the range so an
    // overshoot doesn't send it swinging around to the opposite side.
    final overshoot = (rangeMax - rangeMin) * 0.2;
    final needleDeg = currentDeg.clamp(rangeMin - overshoot, rangeMax + overshoot);
    final needleTip = _pointAt(center, radius - 4, needleDeg);
    canvas.drawLine(
      center,
      needleTip,
      Paint()
        ..color = onTarget ? CaptureColors.success : Colors.white
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(center, 6, Paint()..color = onTarget ? CaptureColors.success : Colors.white);
  }

  @override
  bool shouldRepaint(_AngleDialPainter old) =>
      old.currentDeg != currentDeg ||
      old.targetDeg != targetDeg ||
      old.rangeMin != rangeMin ||
      old.rangeMax != rangeMax ||
      old.onTarget != onTarget;
}

// ── Confirmation banner ────────────────────────────────────────────────────

class _ConfirmationBanner extends StatelessWidget {
  const _ConfirmationBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: CaptureColors.success.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: CaptureColors.success.withValues(alpha: 0.5)),
        ),
        child: Text(
          text,
          style: CaptureTypography.h3.copyWith(color: CaptureColors.success, fontSize: 15),
        ),
      ),
    );
  }
}

// ── Bottom status panel ────────────────────────────────────────────────────

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.state});
  final OscillatingCaptureState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < oscillatingSteps.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < state.stepIndex
                          ? CaptureColors.success
                          : i == state.stepIndex
                              ? CaptureColors.cyan
                              : CaptureColors.silverDim.withValues(alpha: 0.3),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Phase ${state.stepIndex + 1}/8 · ${state.totalFramesCaptured} frames captured',
            style: CaptureTypography.label.copyWith(fontSize: 11, color: CaptureColors.silverDim),
          ),
        ],
      ),
    );
  }
}

// ── Upload overlay ─────────────────────────────────────────────────────────

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
            child: CaptureIntroAnimation(onComplete: () {}, loop: true),
          ),
          const SizedBox(height: 32),
          Text(
            'Uploading…',
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
