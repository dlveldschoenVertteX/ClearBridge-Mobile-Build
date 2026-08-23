import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'sweep_capture_controller.dart';

/// UI for the standalone sweep-burst test app. Deliberately minimal --
/// this app exists to isolate the sweep-burst ARCHITECTURE (see
/// sweep_capture_controller.dart's own doc comment), not to re-build
/// clearbridge_beta's full capture UX. One screen: live preview + the same
/// translating pad guide clearbridge_beta uses, a status/hint banner, and a
/// start button. Result is reviewed on a separate screen once scored.
class SweepCaptureScreen extends StatefulWidget {
  const SweepCaptureScreen({
    super.key,
    required this.getUserId,
    required this.onComplete,
    required this.onRequireLogin,
  });

  final String? Function() getUserId;
  final void Function(String captureId) onComplete;
  final VoidCallback onRequireLogin;

  @override
  State<SweepCaptureScreen> createState() => _SweepCaptureScreenState();
}

class _SweepCaptureScreenState extends State<SweepCaptureScreen> {
  late final SweepCaptureController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = SweepCaptureController();
    _ctrl.addListener(_onState);
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    final s = _ctrl.state;
    if (s.phase == SweepTestPhase.complete && s.captureId != null) {
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
    final size = MediaQuery.of(context).size;
    _ctrl.start(uid, screenSize: size);
  }

  @override
  Widget build(BuildContext context) {
    final s = _ctrl.state;
    final cam = _ctrl.cameraController;

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cam != null && cam.value.isInitialized)
              CameraPreview(cam),

            if (s.activeGuideShape != null)
              Positioned.fill(
                child: CapturePadSilhouetteOverlay(
                  state: _silhouetteState(s.phase, s.zoneCaptureFlash),
                  hint: s.distanceHint.isNotEmpty ? s.distanceHint : null,
                  shape: s.activeGuideShape!,
                  progress: s.sweepProgress,
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

  // zoneCaptureFlash overrides the sweeping-phase color to green/locked for
  // the real duration of each zone's shutter sequence -- the replacement
  // for the removed verbal countdown (2026-08-14): gold means "sweep in
  // progress", green means "capturing this zone right now".
  static PadSilhouetteState _silhouetteState(
          SweepTestPhase p, bool zoneCaptureFlash) =>
      switch (p) {
        SweepTestPhase.sweeping => zoneCaptureFlash
            ? PadSilhouetteState.locked
            : PadSilhouetteState.capturing,
        SweepTestPhase.uploading || SweepTestPhase.complete =>
          PadSilhouetteState.locked,
        SweepTestPhase.error => PadSilhouetteState.warning,
        _ => PadSilhouetteState.aligning,
      };
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.state, required this.onStart});

  final SweepTestState state;
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
            state.phase == SweepTestPhase.idle
                ? 'Sweep-Burst Test (standalone)'
                : (state.message.isNotEmpty ? state.message : 'Ready'),
            style: CaptureTypography.body
                .copyWith(color: CaptureColors.silverBright),
          ),
          const SizedBox(height: 12),

          if (state.phase == SweepTestPhase.uploading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: state.uploadProgress > 0 ? state.uploadProgress : null,
                backgroundColor: CaptureColors.silverDim.withOpacity(0.3),
                color: CaptureColors.cyan,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (state.phase == SweepTestPhase.error && state.error != null) ...[
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

          if (state.phase == SweepTestPhase.idle ||
              state.phase == SweepTestPhase.error)
            CaptureButton(
              label: state.phase == SweepTestPhase.error
                  ? 'Try Again'
                  : 'Start Sweep Capture',
              leadingIcon: Icons.fingerprint,
              onPressed: onStart,
            ),
        ],
      ),
    );
  }

  static String _phaseLabel(SweepTestPhase p) => switch (p) {
        SweepTestPhase.idle => 'SWEEP TEST',
        SweepTestPhase.initializing => 'INITIALIZING',
        SweepTestPhase.calibrating => 'CALIBRATING',
        SweepTestPhase.sweeping => 'SWEEPING',
        SweepTestPhase.uploading => 'UPLOADING',
        SweepTestPhase.complete => 'COMPLETE',
        SweepTestPhase.error => 'ERROR',
      };
}
