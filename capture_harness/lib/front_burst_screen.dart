import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'front_burst_controller.dart';

class FrontBurstScreen extends StatefulWidget {
  const FrontBurstScreen({
    super.key,
    required this.getUserId,
    required this.onComplete,
    required this.onClose,
    required this.onRequireLogin,
  });

  final String? Function() getUserId;
  final void Function(String captureId) onComplete;
  final VoidCallback onClose;
  final VoidCallback onRequireLogin;

  @override
  State<FrontBurstScreen> createState() => _FrontBurstScreenState();
}

class _FrontBurstScreenState extends State<FrontBurstScreen> {
  late final FrontBurstController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = FrontBurstController();
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
    if (uid == null) {
      widget.onRequireLogin();
      return;
    }
    _ctrl.start(uid);
  }

  @override
  Widget build(BuildContext context) {
    final s = _ctrl.state;
    final showGuidance = s.phase == FrontBurstPhase.calibrating ||
        s.phase == FrontBurstPhase.scanning ||
        s.phase == FrontBurstPhase.focusing;

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview
            if (_ctrl.cameraController != null &&
                _ctrl.cameraController!.value.isInitialized)
              CameraPreview(_ctrl.cameraController!),

            // Focus meter — right edge, matches ARC/four-angle layout.
            if (showGuidance)
              Positioned(
                right: 12,
                top: 0,
                bottom: 140,
                child: RepaintBoundary(
                  child: Center(child: FocusMeterWidget(value: s.focusValue)),
                ),
              ),

            // Reticle + guidance text — centred, visible from idle onward so
            // the user always knows exactly where to line up their thumb.
            Center(
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 140),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HapticGuidanceCircle(
                        distanceToTarget: 0.0,
                        isLocked: s.isFocusLocked,
                        isPulsing: false,
                        isAtCorrectDistance: s.thumbCoverageRatio == 0 ||
                            (s.thumbCoverageRatio >= 0.35 &&
                                s.thumbCoverageRatio <= 0.85),
                        isRetrying: s.isRetrying,
                      ),
                      if (showGuidance) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: CaptureGuidanceOverlay(
                            message: s.message,
                            isAllGreen: s.isFocusLocked,
                            greenFraction: s.isFocusLocked ? 1.0 : 0.0,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            // Top: back button
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                color: CaptureColors.silverBright,
                onPressed: widget.onClose,
              ),
            ),

            // Bottom status panel
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

// ─── Status panel ─────────────────────────────────────────────────────────────

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.state, required this.onStart});

  final FrontBurstState state;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.72),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _phaseLabel(state.phase),
            style: CaptureTypography.label
                .copyWith(color: CaptureColors.cyan, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            state.phase == FrontBurstPhase.idle
                ? 'Front Burst (training)'
                : (state.message.isNotEmpty ? state.message : 'Ready'),
            style: CaptureTypography.body
                .copyWith(color: CaptureColors.silverBright),
          ),
          const SizedBox(height: 12),

          if (state.phase == FrontBurstPhase.scanning || state.pass1Done > 0) ...[
            _DotRow(label: 'Pass 1', done: state.pass1Done, total: 8),
            const SizedBox(height: 6),
          ],
          if (state.phase == FrontBurstPhase.focusing || state.pass2Done > 0) ...[
            _DotRow(label: 'Pass 2', done: state.pass2Done, total: 10),
            const SizedBox(height: 6),
          ],

          if (state.phase == FrontBurstPhase.uploading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: state.progress > 0 ? state.progress : null,
                backgroundColor: CaptureColors.silverDim.withOpacity(0.3),
                color: CaptureColors.cyan,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (state.phase == FrontBurstPhase.error && state.error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                state.error!,
                style: CaptureTypography.body.copyWith(
                  color: Colors.redAccent,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (state.phase == FrontBurstPhase.idle ||
              state.phase == FrontBurstPhase.error)
            CaptureButton(
              label: state.phase == FrontBurstPhase.error
                  ? 'Try Again'
                  : 'Start Burst Capture',
              leadingIcon: Icons.fingerprint,
              onPressed: onStart,
            ),

          if (state.phase == FrontBurstPhase.done)
            CaptureButton(
              label: 'Capture Again',
              leadingIcon: Icons.refresh,
              variant: CaptureButtonVariant.ghost,
              onPressed: onStart,
            ),
        ],
      ),
    );
  }

  static String _phaseLabel(FrontBurstPhase p) => switch (p) {
        FrontBurstPhase.idle => 'FRONT BURST',
        FrontBurstPhase.calibrating => 'CALIBRATING',
        FrontBurstPhase.scanning => 'PASS 1 / 2',
        FrontBurstPhase.focusing => 'PASS 2 / 2',
        FrontBurstPhase.uploading => 'UPLOADING',
        FrontBurstPhase.done => 'COMPLETE',
        FrontBurstPhase.error => 'ERROR',
      };
}

// ─── Pass dot row ─────────────────────────────────────────────────────────────

class _DotRow extends StatelessWidget {
  const _DotRow({required this.label, required this.done, required this.total});
  final String label;
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label ',
            style: CaptureTypography.label
                .copyWith(color: CaptureColors.silverDim, fontSize: 11)),
        ...List.generate(total, (i) {
          final filled = i < done;
          return Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled
                  ? CaptureColors.cyan
                  : CaptureColors.silverDim.withOpacity(0.3),
            ),
          );
        }),
      ],
    );
  }
}
