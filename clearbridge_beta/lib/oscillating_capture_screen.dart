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
    // Spotlight reticle: shown while framing/capturing so the user fills the
    // thumb-pad oval (which is exactly the focus/exposure/scoring ROI). Hidden
    // once uploading/complete/error.
    final showReticle = s.phase == OscillatingPhase.idle ||
        s.phase == OscillatingPhase.calibrating ||
        s.phase == OscillatingPhase.running;
    final reticleState = s.isCapturingBurst
        ? ReticleState.capturing
        : (s.onTarget ? ReticleState.locked : ReticleState.aligning);
    final reticleHint = s.phase == OscillatingPhase.idle
        ? 'Fill the oval with your thumb pad'
        : null;

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Stack(
        children: [
          Positioned.fill(child: RepaintBoundary(child: _cameraLayer())),
          if (showReticle)
            Positioned.fill(
              child: RepaintBoundary(
                child: CaptureReticleOverlay(
                  state: reticleState,
                  hint: reticleHint,
                ),
              ),
            )
          else
            const Positioned.fill(
                child: RepaintBoundary(child: CaptureVignetteOverlay())),

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

  Widget _errorOverlay(String message, {VoidCallback? onRetry}) {
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
            if (onRetry != null) ...[
              CaptureButton(label: 'Retry', onPressed: onRetry),
              const SizedBox(height: 10),
            ],
            CaptureButton(label: 'Back', variant: CaptureButtonVariant.ghost, onPressed: _close),
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: SafeArea(
        child: _errorOverlay(
          'Camera error: $message',
          // Camera init failures are frequently transient (cold HAL warm-up,
          // capability negotiation on budget hardware) -- let the user retry
          // in place rather than forcing a full navigation restart.
          onRetry: () {
            setState(() => _initError = null);
            _init();
          },
        ),
      ),
    );
  }
}

// ── Guidance panel (dial + text) ──────────────────────────────────────────

class _GuidancePanel extends StatelessWidget {
  const _GuidancePanel({required this.state});
  final OscillatingCaptureState state;

  // Phase 8 (index 7) is the only step with a different dial range — see
  // the plan's axis-decision note in oscillating_capture_controller.dart.
  static const _defaultRange = (min: -20.0, max: 20.0);
  static const _topRange = (min: -20.0, max: 0.0);

  @override
  Widget build(BuildContext context) {
    final isTopPhase = state.stepIndex == 7;
    final range = isTopPhase ? _topRange : _defaultRange;

    final String deltaText;
    if (state.onTarget) {
      deltaText = state.isBurstStep ? 'On target' : 'On target ✓';
    } else {
      // deltaDeg = currentAngleDeg - targetAngleDeg. The ring maps higher
      // angle values clockwise/right (_BiometricGuidePainter), so deltaDeg > 0
      // means the current reading is already to the right of the target — the
      // correction needed is therefore LEFT, not right.
      final dir = state.deltaDeg > 0 ? 'left' : 'right';
      // Phase 8 has no left/right meaning — just show the raw delta.
      deltaText = isTopPhase
          ? '${state.deltaDeg.abs().round()}° to go'
          : '${state.deltaDeg.abs().round()}° more $dir';
    }

    // Scan-fill fraction: burst shot progress while capturing, else hold time.
    final progress = state.isCapturingBurst
        ? (state.burstShotTotal > 0
            ? state.burstShotIndex / state.burstShotTotal
            : 0.0)
        : (state.isBurstStep ? state.holdProgress : 0.0);
    final accent = state.onTarget ? CaptureColors.success : CaptureColors.cyan;
    final String centreLabel;
    if (state.isCapturingBurst) {
      centreLabel = 'SCAN';
    } else if (state.onTarget) {
      centreLabel = 'LOCKED';
    } else {
      centreLabel = '${state.deltaDeg.abs().round()}°';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 208,
          height: 208,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(208, 208),
                painter: _BiometricGuidePainter(
                  currentDeg: state.currentAngleDeg,
                  targetDeg: state.targetAngleDeg,
                  rangeMin: range.min,
                  rangeMax: range.max,
                  onTarget: state.onTarget,
                  progress: progress,
                  capturing: state.isCapturingBurst,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fingerprint, size: 46, color: accent),
                  const SizedBox(height: 2),
                  Text(
                    centreLabel,
                    style: CaptureTypography.label.copyWith(
                      fontSize: 13,
                      color: accent,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          deltaText,
          style: CaptureTypography.h3.copyWith(
            fontSize: 20,
            color: state.onTarget ? CaptureColors.success : CaptureColors.silverBright,
          ),
        ),
        if (state.isCapturingBurst) ...[
          const SizedBox(height: 4),
          Text(
            'Capturing ${state.burstShotIndex}/${state.burstShotTotal}',
            style: CaptureTypography.label.copyWith(
              fontSize: 11,
              color: CaptureColors.gold,
            ),
          ),
        ] else if (state.isBurstStep && state.onTarget) ...[
          const SizedBox(height: 4),
          Text(
            'Hold steady…',
            style: CaptureTypography.label.copyWith(fontSize: 11),
          ),
        ] else if (!state.isBurstStep) ...[
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
        if (state.distanceHint != 0) ...[
          const SizedBox(height: 6),
          Text(
            state.distanceHint < 0
                ? '↑ Move phone CLOSER to the thumb'
                : '↓ Move phone BACK a little',
            style: CaptureTypography.label.copyWith(
              fontSize: 12,
              color: CaptureColors.warning,
            ),
          ),
        ],
        if (state.lowLight) ...[
          const SizedBox(height: 6),
          Text(
            '☀ Brighter light = sharper print',
            style: CaptureTypography.label.copyWith(
              fontSize: 12,
              color: CaptureColors.gold,
            ),
          ),
        ],
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

/// Biometric alignment ring — a full circular scanner rather than an
/// automotive gauge. The upper 270° arc is the "alignment track": the
/// physical range [rangeMin, rangeMax] maps onto it, a cyan-muted lock zone
/// marks the target ±tolerance, and a glowing marker rides the track at the
/// current angle (cyan → green on lock). The remaining sweep is a scan-fill
/// ring that fills green with [progress] while holding / capturing, giving the
/// "fingerprint scan" feel. All colours are ClearBridge brand tokens.
class _BiometricGuidePainter extends CustomPainter {
  const _BiometricGuidePainter({
    required this.currentDeg,
    required this.targetDeg,
    required this.rangeMin,
    required this.rangeMax,
    required this.onTarget,
    required this.progress,
    required this.capturing,
  });

  final double currentDeg;
  final double targetDeg;
  final double rangeMin;
  final double rangeMax;
  final bool onTarget;
  final double progress; // 0..1 scan fill
  final bool capturing;

  static const double _toleranceDeg = 5.0;
  // Alignment track spans 270° centred on straight-up: from 135° left of top
  // to 135° right of top. In canvas radians (0 = 3 o'clock, +CW), that is
  // −225° (=−1.25π) sweeping +270° (=1.5π).
  static const double _trackStart = -1.25 * math.pi;
  static const double _trackSweep = 1.5 * math.pi;

  double _canvasAngle(double phi) {
    final t = ((phi - rangeMin) / (rangeMax - rangeMin)).clamp(0.0, 1.0);
    return _trackStart + t * _trackSweep;
  }

  Offset _pointAt(Offset c, double r, double phi) {
    final a = _canvasAngle(phi);
    return c + Offset(math.cos(a), math.sin(a)) * r;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 14;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final lock = CaptureColors.success;
    final live = onTarget ? lock : CaptureColors.cyan;

    // Full faint base ring.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = CaptureColors.steelMuted.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    // Alignment track (the 270° arc the angle maps onto).
    canvas.drawArc(
      rect,
      _trackStart,
      _trackSweep,
      false,
      Paint()
        ..color = CaptureColors.silverDim.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );

    // Target lock zone: a thick cyan-muted arc segment around target±tol.
    final loA = _canvasAngle((targetDeg - _toleranceDeg).clamp(rangeMin, rangeMax));
    final hiA = _canvasAngle((targetDeg + _toleranceDeg).clamp(rangeMin, rangeMax));
    canvas.drawArc(
      rect,
      loA,
      hiA - loA,
      false,
      Paint()
        ..color = live.withValues(alpha: onTarget ? 0.9 : 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round,
    );

    // Scan-fill: green arc growing from the top as the hold/burst progresses.
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = (capturing ? CaptureColors.gold : lock)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }

    // Current-angle marker riding the track (glow + core), clamped just past
    // the range so an overshoot parks at the edge instead of wrapping.
    final overshoot = (rangeMax - rangeMin) * 0.15;
    final markDeg = currentDeg.clamp(rangeMin - overshoot, rangeMax + overshoot);
    final markPt = _pointAt(center, radius, markDeg);
    canvas.drawCircle(markPt, 11, Paint()..color = live.withValues(alpha: 0.28));
    canvas.drawCircle(markPt, 6, Paint()..color = live);
    canvas.drawCircle(
      markPt,
      6,
      Paint()
        ..color = CaptureColors.void_
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_BiometricGuidePainter old) =>
      old.currentDeg != currentDeg ||
      old.targetDeg != targetDeg ||
      old.rangeMin != rangeMin ||
      old.rangeMax != rangeMax ||
      old.onTarget != onTarget ||
      old.progress != progress ||
      old.capturing != capturing;
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
      color: CaptureColors.void_.withValues(alpha: 0.82),
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
