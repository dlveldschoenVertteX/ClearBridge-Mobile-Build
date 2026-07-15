import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'front_capture_controller.dart';

/// Front-only fingerprint capture screen.
///
/// Simple, single-step flow: seat thumb in the pad silhouette guide → hold
/// steady for 1.5 s → burst auto-fires → uploads to Firebase. No oscillation,
/// no phase dial — just the guide, a focus ring, and a status line.
class FrontCaptureScreen extends StatefulWidget {
  const FrontCaptureScreen({
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
  State<FrontCaptureScreen> createState() => _FrontCaptureScreenState();
}

class _FrontCaptureScreenState extends State<FrontCaptureScreen> {
  final CameraService _cameraService = CameraService();
  late final FrontCaptureController _ctrl;
  bool _ready = false;
  bool _navigated = false;
  String? _initError;

  CameraController? get _camera => _cameraService.controller;

  @override
  void initState() {
    super.initState();
    _ctrl = FrontCaptureController();
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
    if (!_navigated && s.phase == FrontCapturePhase.complete && s.captureId != null) {
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
    await _ctrl.start(
      camera: cam,
      userId: userId,
      screenSize: MediaQuery.sizeOf(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return _errorScaffold('Camera error: $_initError');
    }
    if (!_ready) {
      return const Scaffold(
        backgroundColor: CaptureColors.void_,
        body: Center(child: CircularProgressIndicator(color: CaptureColors.cyan)),
      );
    }

    final s = _ctrl.state;
    final showGuide = s.phase == FrontCapturePhase.idle ||
        s.phase == FrontCapturePhase.calibrating ||
        s.phase == FrontCapturePhase.holding ||
        s.phase == FrontCapturePhase.capturing;

    final silhouetteState = s.isCapturingBurst
        ? PadSilhouetteState.capturing
        : (s.onTarget ? PadSilhouetteState.locked : PadSilhouetteState.aligning);

    final silhouetteHint = s.phase == FrontCapturePhase.idle
        ? 'Seat your thumb pad in the outline'
        : (s.phase == FrontCapturePhase.holding && !s.onTarget
            ? (s.isSteady ? 'Align your thumb and hold still' : null)
            : null);

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Stack(
        children: [
          // Camera preview.
          Positioned.fill(child: RepaintBoundary(child: _cameraLayer())),

          // Pad silhouette guide overlay.
          if (showGuide)
            Positioned.fill(
              child: RepaintBoundary(
                child: CapturePadSilhouetteOverlay(
                  state: silhouetteState,
                  hint: silhouetteHint,
                ),
              ),
            )
          else
            const Positioned.fill(
              child: RepaintBoundary(child: CaptureVignetteOverlay()),
            ),

          // Focus meter (right edge).
          if (showGuide)
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: RepaintBoundary(
                  child: FocusMeterWidget(value: _ctrl.focusValue),
                ),
              ),
            ),

          // Lighting meter (left edge) — mirrors the focus meter so the user
          // sees both quality signals live, not just focus.
          if (showGuide)
            Positioned(
              left: 12,
              top: 0,
              bottom: 0,
              child: Center(
                child: RepaintBoundary(
                  child: LightingMeterWidget(value: s.lightingValue),
                ),
              ),
            ),

          // Hold progress ring around the guide centre.
          if (s.phase == FrontCapturePhase.holding && s.holdProgress > 0)
            Positioned.fill(
              child: _HoldProgressIndicator(progress: s.holdProgress),
            ),

          // Confirmation banner after burst.
          if (s.confirmationText != null)
            Positioned(
              top: 110,
              left: 40,
              right: 40,
              child: _ConfirmationBanner(text: s.confirmationText!),
            ),

          // Distance hint.
          if (s.distanceHint != null && showGuide)
            Positioned(
              bottom: 160,
              left: 40,
              right: 40,
              child: Text(
                s.distanceHint == 'Move closer'
                    ? '↑ Move phone CLOSER to your thumb'
                    : '↓ Move phone BACK a little',
                textAlign: TextAlign.center,
                style: CaptureTypography.label.copyWith(
                  fontSize: 13,
                  color: CaptureColors.warning,
                ),
              ),
            ),

          // Low-light hint.
          if (s.distanceHint == null &&
              s.lightingValue < 0.18 &&
              (s.phase == FrontCapturePhase.calibrating ||
                  s.phase == FrontCapturePhase.holding))
            Positioned(
              bottom: 160,
              left: 40,
              right: 40,
              child: Text(
                '☀ Brighter light = sharper print',
                textAlign: TextAlign.center,
                style: CaptureTypography.label.copyWith(
                  fontSize: 12,
                  color: CaptureColors.gold,
                ),
              ),
            ),

          // Idle: start button.
          if (s.phase == FrontCapturePhase.idle)
            Positioned(
              left: 40,
              right: 40,
              bottom: 100,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Press your thumb pad flat against the camera lens and seat it in the outline.',
                    textAlign: TextAlign.center,
                    style: CaptureTypography.body.copyWith(
                      fontSize: 13,
                      color: CaptureColors.silverBright,
                    ),
                  ),
                  const SizedBox(height: 18),
                  CaptureButton(
                    label: 'Start Capture',
                    leadingIcon: Icons.fingerprint,
                    onPressed: _onStart,
                  ),
                ],
              ),
            ),

          // Calibrating status.
          if (s.phase == FrontCapturePhase.calibrating)
            Positioned(
              bottom: 100,
              left: 40,
              right: 40,
              child: CaptureGuidanceOverlay(
                message: 'Preparing camera…',
                isAllGreen: false,
                greenFraction: 0,
              ),
            ),

          // Holding status.
          if (s.phase == FrontCapturePhase.holding && s.onTarget && s.holdProgress < 1.0)
            Positioned(
              bottom: 100,
              left: 40,
              right: 40,
              child: CaptureGuidanceOverlay(
                message: 'Hold still…',
                isAllGreen: true,
                greenFraction: s.holdProgress,
              ),
            ),

          // Unsteady hint while holding but not yet on target — distinct from
          // the silhouette's "align your thumb" so the user knows WHICH
          // problem to fix.
          if (s.phase == FrontCapturePhase.holding && !s.onTarget && !s.isSteady)
            Positioned(
              bottom: 100,
              left: 40,
              right: 40,
              child: CaptureGuidanceOverlay(
                message: 'Hold the phone steady…',
                isAllGreen: false,
                greenFraction: 0,
              ),
            ),


          // Uploading overlay.
          if (s.phase == FrontCapturePhase.uploading)
            Positioned.fill(child: _UploadingOverlay(progress: s.uploadProgress)),

          // Error overlay.
          if (s.phase == FrontCapturePhase.error)
            Positioned.fill(child: _errorOverlay(s.error ?? 'Capture failed')),

          // Back button.
          Positioned(
            top: 48,
            left: 16,
            child: GestureDetector(
              onTap: widget.onClose,
              child: const Icon(Icons.arrow_back_ios,
                  color: CaptureColors.silverBright, size: 22),
            ),
          ),

          // Mode label.
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
                  'FRONT CAPTURE',
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

  Widget _cameraLayer() {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      return const ColoredBox(color: CaptureColors.void_);
    }
    final preview = cam.value.previewSize;
    final w = preview?.height ?? 1080;
    final h = preview?.width ?? 1920;
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
            CaptureButton(
                label: 'Back',
                variant: CaptureButtonVariant.ghost,
                onPressed: widget.onClose),
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: SafeArea(child: _errorOverlay(message)),
    );
  }
}

// ── Widgets ──────────────────────────────────────────────────────────────────

class _HoldProgressIndicator extends StatelessWidget {
  const _HoldProgressIndicator({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ProgressRingPainter(progress: progress),
      child: const SizedBox.expand(),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  const _ProgressRingPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.5; // align with guide center
    const r = 100.0;
    final paint = Paint()
      ..color = CaptureColors.success.withValues(alpha: 0.85)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      -3.14159 / 2,
      2 * 3.14159 * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter old) => old.progress != progress;
}

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

class _UploadingOverlay extends StatelessWidget {
  const _UploadingOverlay({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CaptureColors.void_.withValues(alpha: 0.92),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 160,
              height: 160,
              child: CaptureIntroAnimation(onComplete: () {}, loop: true),
            ),
            const SizedBox(height: 18),
            Text(
              'Uploading capture…',
              style: CaptureTypography.body.copyWith(
                  color: CaptureColors.silverBright, fontSize: 15),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: CaptureColors.cardBg,
                color: CaptureColors.cyan,
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
