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
          // Phase label + message
          Text(
            _phaseLabel(state.phase),
            style: CaptureTypography.label
                .copyWith(color: CaptureColors.cyan, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            state.message.isNotEmpty ? state.message : 'Ready',
            style: CaptureTypography.body
                .copyWith(color: CaptureColors.silverBright),
          ),
          const SizedBox(height: 12),

          // Coverage bar (only during waitingForCoverage)
          if (state.phase == FrontBurstPhase.waitingForCoverage) ...[
            _CoverageBar(ratio: state.thumbCoverageRatio),
            const SizedBox(height: 12),
          ],

          // Pass 1 dots
          if (state.phase == FrontBurstPhase.scanning ||
              state.pass1Done > 0) ...[
            _DotRow(label: 'Pass 1', done: state.pass1Done, total: 8),
            const SizedBox(height: 6),
          ],

          // Pass 2 dots
          if (state.phase == FrontBurstPhase.focusing ||
              state.pass2Done > 0) ...[
            _DotRow(label: 'Pass 2', done: state.pass2Done, total: 10),
            const SizedBox(height: 6),
          ],

          // Generic progress bar (processing / uploading)
          if (state.phase == FrontBurstPhase.processing ||
              state.phase == FrontBurstPhase.uploading ||
              state.phase == FrontBurstPhase.calibrating) ...[
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

          // Error message
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

          // CTA button
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
        FrontBurstPhase.idle             => 'FRONT BURST',
        FrontBurstPhase.waitingForCoverage => 'COVERAGE GATE',
        FrontBurstPhase.calibrating      => 'CALIBRATING',
        FrontBurstPhase.scanning         => 'PASS 1 / 2',
        FrontBurstPhase.focusing         => 'PASS 2 / 2',
        FrontBurstPhase.processing       => 'PROCESSING',
        FrontBurstPhase.uploading        => 'UPLOADING',
        FrontBurstPhase.done             => 'COMPLETE',
        FrontBurstPhase.error            => 'ERROR',
      };
}

// ─── Coverage bar ─────────────────────────────────────────────────────────────

class _CoverageBar extends StatelessWidget {
  const _CoverageBar({required this.ratio});
  final double ratio;

  @override
  Widget build(BuildContext context) {
    final inZone = ratio >= 0.50 && ratio <= 0.70;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Thumb coverage',
                style: CaptureTypography.label
                    .copyWith(color: CaptureColors.silverDim, fontSize: 11)),
            Text('${(ratio * 100).toStringAsFixed(0)}%',
                style: CaptureTypography.label.copyWith(
                  color: inZone ? CaptureColors.cyan : Colors.orange,
                  fontSize: 11,
                )),
          ],
        ),
        const SizedBox(height: 4),
        Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio.clamp(0.0, 1.0),
                backgroundColor: CaptureColors.silverDim.withOpacity(0.3),
                color: inZone ? CaptureColors.cyan : Colors.orange,
                minHeight: 8,
              ),
            ),
            // Target zone markers at 50% and 70%
            Positioned.fill(
              child: LayoutBuilder(builder: (_, constraints) {
                final w = constraints.maxWidth;
                return Stack(children: [
                  Positioned(
                    left: w * 0.50 - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(
                        width: 2,
                        color: Colors.white.withOpacity(0.6)),
                  ),
                  Positioned(
                    left: w * 0.70 - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(
                        width: 2,
                        color: Colors.white.withOpacity(0.6)),
                  ),
                ]);
              }),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Pass dot row ─────────────────────────────────────────────────────────────

class _DotRow extends StatelessWidget {
  const _DotRow(
      {required this.label, required this.done, required this.total});
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
