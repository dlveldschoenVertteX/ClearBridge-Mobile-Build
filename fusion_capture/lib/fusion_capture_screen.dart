import 'dart:math' as math;

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
          // Curated oscillating-8-phase dial, adapted for tilt's discrete
          // left/tip/right stations (see _TiltRingPainter for why this
          // isn't a literal ported angle reading) -- centred over the
          // guide the same way oscillating_capture_screen.dart centres its
          // own dial, replacing the old text-only instruction for this
          // phase specifically.
          if (s.phase == FusionPhase.tilt)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 70),
                child: _TiltRingPanel(state: s),
              ),
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
          _countdownOverlay(s),
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
    // The tilt ring panel (centred over the guide) already carries this
    // same cue text below its dial -- showing it a second time at the
    // bottom was the "only text" complaint's other half.
    if (s.detailText.isEmpty || s.phase == FusionPhase.tilt) {
      return const SizedBox.shrink();
    }
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

  /// Big pulsing "3…2…1…GO" numeral, on top of everything else. Real
  /// device feedback (2026-08-22): every capture used to fire the instant
  /// positioning finished, with nothing telling the user it was about to
  /// -- this is the visible half of that fix (audio/haptics are the
  /// controller's own `_runCountdown`). `key: ValueKey(v)` is what makes
  /// the pulse restart on every tick -- a fresh widget identity per count
  /// forces TweenAnimationBuilder to re-run its tween from `begin` instead
  /// of animating smoothly from the PREVIOUS count's end state.
  Widget _countdownOverlay(FusionState s) {
    final v = s.countdownValue;
    if (v == null) return const SizedBox.shrink();
    final isGo = v == 0;
    final accent = isGo ? CaptureColors.success : CaptureColors.gold;
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            key: ValueKey(v),
            tween: Tween(begin: 0.55, end: 1.0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              width: 132,
              height: 132,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.6),
                border: Border.all(color: accent, width: 4),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.55),
                    blurRadius: 30,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Text(
                isGo ? 'GO' : '$v',
                style: TextStyle(
                  color: accent,
                  fontSize: isGo ? 38 : 62,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tilt phase's curated dial -- ported from oscillating_capture_screen.dart's
/// `_GuidancePanel`/`_BiometricGuidePainter` (same ring chrome: base ring,
/// 270° track, glowing marker, scan-fill), adapted for what this phase
/// actually has to show. Oscillating's dial plots a CONTINUOUS measured
/// angle because the phone physically orbits a stationary thumb, so the
/// device's own rotation IS the signal. Tilt is the opposite: the phone
/// stays still and the THUMB tilts (see TiltStation's own docstring --
/// "nothing on-device can observe how far the user's finger actually
/// tilted"), so there is no literal angle to plot. What ported instead:
/// discrete station identity/progress (3 fixed markers, not a swept
/// pointer) plus a genuinely live, real signal gyro CAN measure -- whether
/// the PHONE itself is currently steady enough not to blur the shot.
class _TiltRingPanel extends StatelessWidget {
  const _TiltRingPanel({required this.state});
  final FusionState state;

  @override
  Widget build(BuildContext context) {
    final steady = state.gyroSteady;
    final capturing = state.silhouetteState == PadSilhouetteState.capturing;
    final locked = state.silhouetteState == PadSilhouetteState.locked;
    final accent = !steady
        ? CaptureColors.warning
        : capturing
            ? CaptureColors.gold
            : locked
                ? CaptureColors.success
                : CaptureColors.cyan;
    final centreLabel = !steady
        ? 'HOLD'
        : capturing
            ? 'SCAN'
            : '${state.stationsDone}/3';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 196,
          height: 196,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(196, 196),
                painter: _TiltRingPainter(
                  activeIndex: state.stationIndex ?? -1,
                  completedCount: state.stationsDone,
                  silhouetteState: state.silhouetteState,
                  steady: steady,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fingerprint, size: 42, color: accent),
                  const SizedBox(height: 2),
                  Text(
                    centreLabel,
                    style: TextStyle(
                      color: accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          !steady ? 'HOLD PHONE STEADY' : state.detailText,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: !steady ? CaptureColors.warning : Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

class _TiltRingPainter extends CustomPainter {
  const _TiltRingPainter({
    required this.activeIndex,
    required this.completedCount,
    required this.silhouetteState,
    required this.steady,
  });

  final int activeIndex; // -1 before the first station starts
  final int completedCount;
  final PadSilhouetteState silhouetteState;
  final bool steady;

  // Identical track geometry to oscillating's own _BiometricGuidePainter --
  // a 270° arc centred on straight-up, leaving the bottom 90° open.
  static const double _trackStart = -1.25 * math.pi;
  static const double _trackSweep = 1.5 * math.pi;
  // Left -> tip/up -> right, evenly spaced along that same track -- matches
  // the cue order (left, up, right) so the marker sequence visibly travels
  // the direction the instructions imply, even without a continuous
  // measured angle behind it.
  static const List<double> _stationT = [0.0, 0.5, 1.0];

  double _angleForT(double t) => _trackStart + t * _trackSweep;

  Offset _pointAt(Offset c, double r, double t) {
    final a = _angleForT(t);
    return c + Offset(math.cos(a), math.sin(a)) * r;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 14;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final capturing = silhouetteState == PadSilhouetteState.capturing;
    final locked = silhouetteState == PadSilhouetteState.locked;
    final live = !steady
        ? CaptureColors.warning
        : capturing
            ? CaptureColors.gold
            : locked
                ? CaptureColors.success
                : CaptureColors.cyan;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = CaptureColors.steelMuted.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

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

    // Scan-fill: a full ring glow while the shot pair is actually firing --
    // echoes oscillating's own "scan" fill language for the one moment
    // that's genuinely a scan here too.
    if (capturing) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi,
        false,
        Paint()
          ..color = CaptureColors.gold.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }

    for (var i = 0; i < 3; i++) {
      final pt = _pointAt(center, radius, _stationT[i]);
      final done = i < completedCount;
      final active = i == activeIndex && !done;
      final color = done ? CaptureColors.success : (active ? live : CaptureColors.silverDim);
      if (active) {
        canvas.drawCircle(pt, 15, Paint()..color = color.withValues(alpha: 0.25));
      }
      canvas.drawCircle(
        pt,
        active ? 9 : 6,
        Paint()..color = color.withValues(alpha: done || active ? 1.0 : 0.6),
      );
      canvas.drawCircle(
        pt,
        active ? 9 : 6,
        Paint()
          ..color = CaptureColors.void_
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_TiltRingPainter old) =>
      old.activeIndex != activeIndex ||
      old.completedCount != completedCount ||
      old.silhouetteState != silhouetteState ||
      old.steady != steady;
}
