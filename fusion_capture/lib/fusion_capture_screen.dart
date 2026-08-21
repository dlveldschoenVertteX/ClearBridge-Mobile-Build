import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'fusion_capture_controller.dart';

/// Fusion capture UI.
///
/// One continuous session, three phases, ONE persistent guide -- the phase
/// changes what the user is asked to do, never the visual language. Phase
/// identity is carried by a compact stepper plus the instruction line, so a
/// three-phase session still reads as a single coherent capture rather than
/// three separate apps bolted together.
class FusionCaptureScreen extends StatefulWidget {
  const FusionCaptureScreen({super.key});

  @override
  State<FusionCaptureScreen> createState() => _FusionCaptureScreenState();
}

class _FusionCaptureScreenState extends State<FusionCaptureScreen> {
  late final FusionCaptureController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = FusionCaptureController();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_started) return;
    setState(() => _started = true);
    await _controller.start(screenSize: MediaQuery.of(context).size);
  }

  int get _phaseIndex {
    switch (_controller.state.phase) {
      case FusionPhase.frontHold:
      case FusionPhase.frontBurst:
        return 0;
      case FusionPhase.tilt:
        return 1;
      case FusionPhase.sweep:
        return 2;
      case FusionPhase.uploading:
      case FusionPhase.complete:
        return 3;
      default:
        return -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _controller.state;
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _cameraLayer(s),
          if (_showGuide(s.phase))
            CapturePadSilhouetteOverlay(
              state: s.silhouetteState,
              shape: s.guideShape ?? PadSilhouetteShape.defaultShape,
              progress: s.phase == FusionPhase.frontHold
                  ? s.holdProgress
                  : s.phaseProgress,
            ),
          SafeArea(
            child: Column(
              children: [
                _header(s),
                const Spacer(),
                if (s.distanceHint != null && _showGuide(s.phase))
                  _distanceBanner(s.distanceHint!),
                _instruction(s),
                _bottomBar(s),
              ],
            ),
          ),
          if (s.phase == FusionPhase.uploading) _uploadingOverlay(s),
        ],
      ),
    );
  }

  bool _showGuide(FusionPhase p) =>
      p == FusionPhase.frontHold ||
      p == FusionPhase.frontBurst ||
      p == FusionPhase.tilt ||
      p == FusionPhase.sweep;

  Widget _cameraLayer(FusionState s) {
    final cam = _controller.cameraService.controller;
    if (cam == null ||
        !cam.value.isInitialized ||
        s.phase == FusionPhase.uploading ||
        s.phase == FusionPhase.complete) {
      return const ColoredBox(color: CaptureColors.void_);
    }
    final preview = cam.value.previewSize;
    if (preview == null) return CameraPreview(cam);
    // Preview dimensions arrive swapped relative to portrait layout.
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: preview.height,
        height: preview.width,
        child: CameraPreview(cam),
      ),
    );
  }

  Widget _header(FusionState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.statusText.isEmpty ? 'Fusion Capture' : s.statusText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          _stepper(),
        ],
      ),
    );
  }

  /// Three-segment progress bar. Deliberately shows all three phases from
  /// the start so the length of the session is never a surprise mid-capture
  /// -- this flow is materially longer than the single-burst one, and hiding
  /// that reads as a hang rather than as progress.
  Widget _stepper() {
    const labels = ['Main', 'Edges', 'Texture'];
    final idx = _phaseIndex;
    return Row(
      children: List.generate(3, (i) {
        final done = idx > i;
        final active = idx == i;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < 2 ? 8 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: done
                        ? CaptureColors.success
                        : active
                            ? CaptureColors.gold
                            : Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  style: TextStyle(
                    color: (done || active) ? Colors.white : Colors.white38,
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _distanceBanner(String hint) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: CaptureColors.gold, width: 2),
      ),
      child: Text(
        hint.toUpperCase(),
        style: const TextStyle(
          color: CaptureColors.gold,
          fontSize: 16,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _instruction(FusionState s) {
    if (s.detailText.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Text(
        s.detailText,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }

  Widget _bottomBar(FusionState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Column(
        children: [
          if (s.phase == FusionPhase.idle && !_started)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _begin,
                style: FilledButton.styleFrom(
                  backgroundColor: CaptureColors.gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                child: const Text('Start fusion capture',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
          if (s.phase == FusionPhase.error) ...[
            Text(
              s.errorMessage ?? 'Something went wrong',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 15),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  setState(() => _started = false);
                  _begin();
                },
                child: const Text('Try again'),
              ),
            ),
          ],
          if (s.phase == FusionPhase.complete) ...[
            const Icon(Icons.check_circle,
                color: CaptureColors.success, size: 48),
            const SizedBox(height: 10),
            Text(
              s.detailText,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'Capture ${s.captureId?.substring(0, 8) ?? ""}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  setState(() => _started = false);
                  _begin();
                },
                child: const Text('Capture again'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _uploadingOverlay(FusionState s) {
    return ColoredBox(
      color: CaptureColors.void_,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: CaptureColors.gold),
            const SizedBox(height: 20),
            Text(
              s.statusText,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
