import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'package:clearbridge_beta/capture_burst_ring.dart';
import 'package:clearbridge_beta/cb_primary_button.dart';
import 'package:clearbridge_beta/clearbridge_colors.dart';
import 'package:clearbridge_beta/clearbridge_typography.dart';
import 'package:clearbridge_beta/front_burst_capture_controller.dart';
import 'package:clearbridge_beta/front_burst_uploader.dart';

class FrontBurstCaptureScreen extends StatefulWidget {
  const FrontBurstCaptureScreen({
    super.key,
    required this.getUserId,
    required this.onComplete,
    required this.onClose,
  });

  final String? Function() getUserId;
  final void Function(String captureId) onComplete;
  final VoidCallback onClose;

  @override
  State<FrontBurstCaptureScreen> createState() =>
      _FrontBurstCaptureScreenState();
}

class _FrontBurstCaptureScreenState extends State<FrontBurstCaptureScreen> {
  late final FrontBurstCaptureController _ctrl;
  static const _uploader = FrontBurstUploader();

  @override
  void initState() {
    super.initState();
    _ctrl = FrontBurstCaptureController();
    _ctrl.addListener(_onState);
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    final s = _ctrl.state;
    if (s.phase == FrontBurstPhase.done && s.captureId != null) {
      widget.onComplete(s.captureId!);
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onState);
    _ctrl.dispose();
    super.dispose();
  }

  void _start() {
    final uid = widget.getUserId();
    if (uid == null) return;
    _ctrl.start(uid, uploader: _uploader);
  }

  @override
  Widget build(BuildContext context) {
    final s = _ctrl.state;
    final showGuidance = s.phase == FrontBurstPhase.calibrating ||
        s.phase == FrontBurstPhase.capturing;
    final CameraController? camera = _ctrl.cameraController;

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (camera != null && camera.value.isInitialized)
              Positioned.fill(child: RepaintBoundary(child: _cameraLayer(camera))),

            if (showGuidance)
              Positioned(
                right: 12,
                top: 0,
                bottom: 160,
                child: RepaintBoundary(
                  child: Center(child: FocusMeterWidget(value: s.focusValue)),
                ),
              ),

            // Reticle: arc-fill burst ring, always visible so the user has
            // an explicit target to line their thumb up with.
            Center(
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 160),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CaptureBurstRing(total: 6, completed: s.capturedCount),
                      if (showGuidance) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            s.message,
                            textAlign: TextAlign.center,
                            style: ClearBridgeTypography.body.copyWith(
                              color: s.isFocusLocked
                                  ? ClearBridgeColors.success
                                  : ClearBridgeColors.silverBright,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                color: ClearBridgeColors.silverBright,
                onPressed: widget.onClose,
              ),
            ),

            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _StatusPanel(state: s, onStart: _start),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-bleed camera preview, scaled/cropped (not stretched) to fill the
/// screen. `previewSize` is reported in sensor (landscape) orientation, so
/// width/height are swapped for the portrait cover fit — mirrors
/// mac_capture_screen.dart's `_cameraLayer`. Without this, embedding
/// [CameraPreview] directly in a `Stack(fit: StackFit.expand)` gives it tight
/// full-screen constraints that defeat its internal `AspectRatio`, stretching
/// the live image.
Widget _cameraLayer(CameraController cam) {
  final preview = cam.value.previewSize;
  final w = preview?.height ?? 1080;
  final h = preview?.width ?? 1920;
  return FittedBox(
    fit: BoxFit.cover,
    clipBehavior: Clip.hardEdge,
    child: SizedBox(
      width: w,
      height: h,
      child: CameraPreview(cam),
    ),
  );
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.state, required this.onStart});

  final FrontBurstState state;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_phaseLabel(state.phase), style: ClearBridgeTypography.eyebrow),
          const SizedBox(height: 4),
          Text(
            state.phase == FrontBurstPhase.idle
                ? 'Front Burst Capture'
                : (state.message.isNotEmpty ? state.message : 'Ready'),
            style: ClearBridgeTypography.body
                .copyWith(color: ClearBridgeColors.silverBright),
          ),
          const SizedBox(height: 12),

          if (state.phase == FrontBurstPhase.uploading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: state.progress > 0 ? state.progress : null,
                backgroundColor: ClearBridgeColors.silverDim.withValues(alpha: 0.3),
                color: ClearBridgeColors.cyan,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (state.phase == FrontBurstPhase.error && state.error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ClearBridgeColors.error.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                state.error!,
                style: ClearBridgeTypography.caption.copyWith(
                  color: ClearBridgeColors.error,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (state.phase == FrontBurstPhase.idle ||
              state.phase == FrontBurstPhase.error)
            CbPrimaryButton(
              label: state.phase == FrontBurstPhase.error
                  ? 'Try Again'
                  : 'Start Capture',
              icon: const Icon(Icons.fingerprint),
              onPressed: onStart,
            ),

          if (state.phase == FrontBurstPhase.done)
            CbPrimaryButton.ghost(
              label: 'Capture Again',
              icon: const Icon(Icons.refresh),
              onPressed: onStart,
            ),
        ],
      ),
    );
  }

  static String _phaseLabel(FrontBurstPhase p) => switch (p) {
        FrontBurstPhase.idle => 'FRONT BURST',
        FrontBurstPhase.calibrating => 'CALIBRATING',
        FrontBurstPhase.capturing => 'CAPTURING',
        FrontBurstPhase.uploading => 'UPLOADING',
        FrontBurstPhase.done => 'COMPLETE',
        FrontBurstPhase.error => 'ERROR',
      };
}
