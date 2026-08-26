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

class _FusionCaptureScreenState extends State<FusionCaptureScreen>
    with TickerProviderStateMixin {
  late final FusionCaptureController _controller;
  bool _started = false;

  // Scan line through the guide during the front-phase burst -- ported
  // directly from front_capture_screen.dart's own `_scanAnim` (real device
  // feedback there: the secondary-camera phase had no visible motion at
  // all, no way to tell the app was doing anything; front_only_v1's front
  // phase already has this cue, so this phase should keep it).
  late final AnimationController _scanAnim;
  bool _wasBursting = false;

  @override
  void initState() {
    super.initState();
    _controller = FusionCaptureController();
    _controller.addListener(_onChanged);
    _scanAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
  }

  void _onChanged() {
    final bursting = _controller.state.phase == FusionPhase.frontBurst;
    if (bursting && !_wasBursting) {
      _scanAnim.repeat(reverse: true);
    } else if (!bursting && _wasBursting) {
      _scanAnim.stop();
      _scanAnim.value = 0;
    }
    _wasBursting = bursting;
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _scanAnim.dispose();
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
      case FusionPhase.macro:
        return 3;
      case FusionPhase.uploading:
      case FusionPhase.complete:
        return 4;
      default:
        return -1;
    }
  }

  bool _isFrontPhase(FusionPhase p) =>
      p == FusionPhase.frontHold || p == FusionPhase.frontBurst;

  @override
  Widget build(BuildContext context) {
    final s = _controller.state;
    final size = MediaQuery.of(context).size;
    final isFrontPhase = _isFrontPhase(s.phase);
    final isBursting = s.phase == FusionPhase.frontBurst;

    // 270x270 ring centred at cy=0.37 -- matches front_only_v1's own ring
    // geometry exactly (PadSilhouetteShape.defaultShape.cy), so a real
    // front_only_v1 user sees the identical layout here.
    const ringD = 270.0;
    const ringR = ringD / 2;
    final ringCx = size.width / 2;
    final ringCy = size.height * 0.37;
    final ringLeft = ringCx - ringR;
    final ringTop = ringCy - ringR;
    const meterW = 40.0;
    const meterH = 180.0;
    const meterGap = 10.0;
    final meterTop = ringCy - meterH / 2;
    final brightLeft = ringLeft - meterGap - meterW;
    final focusLeft = ringLeft + ringD + meterGap;

    // Ring progress/colour -- ported from front_capture_screen.dart's own
    // _ringState.
    final double ringProgress;
    final Color ringColor;
    if (isBursting) {
      ringProgress = s.phaseProgress;
      ringColor = CaptureColors.silverBright;
    } else if (s.phase == FusionPhase.frontHold && s.onTarget) {
      ringProgress = s.holdProgress;
      ringColor = CaptureColors.cyan;
    } else {
      ringProgress = 0.0;
      ringColor = CaptureColors.cyan;
    }

    // Same 30% cutoff front_only_v1's own low-quality warning uses,
    // gated the same way (holding phase only, so it can't misfire before
    // the thumb is even placed).
    final lowQuality = s.phase == FusionPhase.frontHold &&
        (s.lightingValue < 0.30 || s.focusValue < 0.30);
    final brightWarn = lowQuality && s.lightingValue < 0.30;
    final focusWarn = lowQuality && s.focusValue < 0.30;

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
              // Front phase suppresses the overlay's own built-in boundary
              // arc (progress=0) in favour of the external circular ring
              // below -- byte-for-byte the same choice front_only_v1's own
              // screen makes ("the new external ring replaces it").
              progress: isFrontPhase ? 0 : s.phaseProgress,
            ),
          // Front phase: 270x270 external progress ring + BRIGHT/FOCUS
          // vertical meters + burst scan line/counter/dots + confirmation
          // banner -- a direct port of front_only_v1's own capture screen,
          // laid out identically around the same guide geometry.
          if (isFrontPhase) ...[
            Positioned(
              left: ringLeft,
              top: ringTop,
              child: _FusionRing(progress: ringProgress, color: ringColor),
            ),
            Positioned(
              left: brightLeft,
              top: meterTop,
              child: _FusionVerticalMeter(
                value: s.lightingValue,
                color: CaptureColors.gold,
                icon: Icons.wb_sunny_outlined,
                label: 'BRIGHT',
                warning: brightWarn,
              ),
            ),
            Positioned(
              left: focusLeft,
              top: meterTop,
              child: _FusionVerticalMeter(
                value: s.focusValue,
                color: CaptureColors.cyan,
                icon: Icons.center_focus_strong_outlined,
                label: 'FOCUS',
                warning: focusWarn,
              ),
            ),
            if (isBursting)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _scanAnim,
                    builder: (_, __) {
                      final lineY = ringTop + 16 + (ringD - 32) * _scanAnim.value;
                      return Stack(children: [
                        Positioned(
                          top: lineY,
                          left: ringLeft + 20,
                          width: ringD - 40,
                          height: 2,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.transparent,
                                  Color(0x9900BFFF),
                                  Color(0xFF00BFFF),
                                  Color(0x9900BFFF),
                                  Colors.transparent,
                                ],
                                stops: [0.0, 0.2, 0.5, 0.8, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ]);
                    },
                  ),
                ),
              ),
            if (isBursting) ...[
              Positioned(
                top: ringTop + 20,
                left: ringLeft,
                width: ringD,
                child: Text(
                  '${(s.phaseProgress * 8).ceil()} / 8',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: CaptureColors.silverBright,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              Positioned(
                top: ringTop + ringD - 34,
                left: ringLeft,
                width: ringD,
                child: _FusionBurstDots(filled: (s.phaseProgress * 8).ceil(), total: 8),
              ),
            ],
            if (s.confirmationText != null)
              Positioned(
                top: ringTop - 60,
                left: 40,
                right: 40,
                child: _FusionConfirmationBanner(
                  text: s.confirmationText!,
                  lightingValue: s.lightingValue,
                  focusValue: s.focusValue,
                ),
              ),
          ],
          // oscillating-8-phase's own angle dial, ported literally now that
          // the tilt phase tracks a real device angle -- see _TiltRingPanel.
          // Centred over the guide the same way
          // oscillating_capture_screen.dart centres its own dial, replacing
          // the old text-only instruction for this phase specifically.
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
                if (lowQuality)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _FusionWarningRow(
                      text: focusWarn
                          ? 'Hold steadier — image is too soft'
                          : 'Move to better light — image is too dark',
                    ),
                  ),
                if (s.distanceHint != null && _showGuide(s.phase))
                  _distanceBanner(s.distanceHint!),
                // Macro's own confirmation text ('Capturing close-up
                // detail…' / '✓ Close-up captured') has nowhere else to
                // render: the ring-based confirmation banner above is
                // nested inside the front-phase-only block (it's
                // positioned relative to the front ring, which macro
                // doesn't show), and without this the whole phase would
                // give zero visual feedback -- exactly the "silent gap
                // reads as a freeze" failure class this project has been
                // burned by more than once. Reuses the same generic pill
                // widget the distance hint already uses rather than a new
                // one.
                if (s.phase == FusionPhase.macro && s.confirmationText != null)
                  _distanceBanner(s.confirmationText!),
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
      p == FusionPhase.sweep ||
      p == FusionPhase.macro;

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
    const labels = ['Main', 'Edges', 'Texture', 'Detail'];
    final idx = _phaseIndex;
    return Row(
      children: List.generate(4, (i) {
        final done = idx > i;
        final active = idx == i;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < 3 ? 8 : 0),
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
    // bottom was the "only text" complaint's other half. Sweep's own real
    // cue text lives entirely in the distanceHint banner now (see
    // _runSweepStations), matching the real sweep architecture's own
    // single-message design -- showing detailText too would duplicate it.
    if (s.detailText.isEmpty ||
        s.phase == FusionPhase.tilt ||
        s.phase == FusionPhase.sweep) {
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

/// Tilt phase's dial -- ported from oscillating_capture_screen.dart's own
/// `_GuidancePanel`/`_BiometricGuidePainter`, literally this time. The
/// earlier "curated" version (discrete station markers, no continuous
/// angle) was built when the mechanic had the THUMB tilt while the phone
/// stayed still -- no sensor could track that, so a literal angle dial
/// would have been lying. Real device feedback asked for oscillating's
/// actual degree-measure mechanic; FusionCaptureController's tilt phase now
/// has the PHONE tilt around a stationary thumb instead (see TiltStation's
/// own docstring), which makes `state.currentAngleDeg` a real,
/// DeviceOrientationService-measured value -- so this dial can now plot it
/// honestly, the same way oscillating's own does.
///
/// Range is +-20 around each station's OWN target rather than oscillating's
/// fixed +-20/0 window, since fusion's targets are smaller (~11 degrees,
/// not 15-20) -- centring the range on the target keeps the same visual
/// sensitivity oscillating's dial has instead of compressing a smaller real
/// swing into the same 0-20 window.
class _TiltRingPanel extends StatelessWidget {
  const _TiltRingPanel({required this.state});
  final FusionState state;

  static const double _rangeHalfWidth = 20.0;
  static const double _toleranceDeg = 5.0; // matches _tiltHoldToleranceDeg

  @override
  Widget build(BuildContext context) {
    final target = state.targetAngleDeg;
    final rangeMin = target - _rangeHalfWidth;
    final rangeMax = target + _rangeHalfWidth;

    final String deltaText;
    if (state.onTarget) {
      deltaText = 'On target ✓';
    } else {
      // deltaDeg = current - target. The ring maps higher values
      // clockwise/right (_BiometricGuidePainter), so deltaDeg > 0 means the
      // reading is already right of target -- the correction needed is LEFT.
      final dir = state.deltaDeg > 0 ? 'left' : 'right';
      deltaText = '${state.deltaDeg.abs().round()}° more $dir';
    }

    final capturing = state.silhouetteState == PadSilhouetteState.capturing;
    final accent = state.onTarget ? CaptureColors.success : CaptureColors.cyan;
    final String centreLabel;
    if (capturing) {
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
                painter: _TiltRingPainter(
                  currentDeg: state.currentAngleDeg,
                  targetDeg: target,
                  rangeMin: rangeMin,
                  rangeMax: rangeMax,
                  toleranceDeg: _toleranceDeg,
                  onTarget: state.onTarget,
                  progress: state.holdProgress,
                  capturing: capturing,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fingerprint, size: 46, color: accent),
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
        const SizedBox(height: 10),
        Text(
          deltaText,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: state.onTarget ? CaptureColors.success : Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (capturing) ...[
          const SizedBox(height: 4),
          Text(
            'Capturing…',
            style: TextStyle(
              color: CaptureColors.gold,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ] else if (state.onTarget) ...[
          const SizedBox(height: 4),
          const Text(
            'Hold steady…',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          state.tooFast
              ? 'Speed: ⚠ SLOW DOWN'
              : 'Speed: ${state.angularVelocityDegPerSec.round()}°/sec',
          style: TextStyle(
            color: state.tooFast ? CaptureColors.warning : CaptureColors.silverDim,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// Ported verbatim from oscillating_capture_screen.dart's own
/// `_BiometricGuidePainter` -- same track geometry, same lock-zone/scan-fill/
/// marker rendering. Only the constructor's field names changed to match
/// this file's own state shape.
class _TiltRingPainter extends CustomPainter {
  const _TiltRingPainter({
    required this.currentDeg,
    required this.targetDeg,
    required this.rangeMin,
    required this.rangeMax,
    required this.toleranceDeg,
    required this.onTarget,
    required this.progress,
    required this.capturing,
  });

  final double currentDeg;
  final double targetDeg;
  final double rangeMin;
  final double rangeMax;
  final double toleranceDeg;
  final bool onTarget;
  final double progress; // 0..1 scan fill
  final bool capturing;

  // Alignment track spans 270°, centred on straight-up: from 135° left of
  // top to 135° right of top. In canvas radians (0 = 3 o'clock, +CW), that
  // is -225° (=-1.25pi) sweeping +270° (=1.5pi).
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

    final loA = _canvasAngle((targetDeg - toleranceDeg).clamp(rangeMin, rangeMax));
    final hiA = _canvasAngle((targetDeg + toleranceDeg).clamp(rangeMin, rangeMax));
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

    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = capturing ? CaptureColors.gold : lock
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }

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
  bool shouldRepaint(_TiltRingPainter old) =>
      old.currentDeg != currentDeg ||
      old.targetDeg != targetDeg ||
      old.rangeMin != rangeMin ||
      old.rangeMax != rangeMax ||
      old.onTarget != onTarget ||
      old.progress != progress ||
      old.capturing != capturing;
}

// ── Front phase: ported directly from clearbridge_beta's own
// front_capture_screen.dart, per real device feedback that this phase
// should look exactly like front_only_v1, not a stripped-down version of
// it. Same ring geometry, same meter design, same burst counter/dots,
// same confirmation banner shape -- only the field names differ
// (FusionState's lightingValue/focusValue/confirmationText instead of
// FrontCaptureState's). One approximation, disclosed rather than silent:
// front_only_v1 renders its mono counter/percentage text via GoogleFonts'
// JetBrains Mono; this app has no google_fonts dependency (deliberately --
// see this app's own pubspec.yaml note on why a second, possibly
// conflicting package constraint is worth avoiding here), so those spots
// use the platform's plain monospace font family instead. Visually close,
// not byte-identical.

class _FusionRing extends StatelessWidget {
  const _FusionRing({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FusionRingPainter(progress: progress, color: color),
      size: const Size(270, 270),
    );
  }
}

class _FusionRingPainter extends CustomPainter {
  const _FusionRingPainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const strokeW = 14.0;
    final r = cx - strokeW / 2 - 2;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = color.withValues(alpha: 0.12)
        ..strokeWidth = strokeW
        ..style = PaintingStyle.stroke,
    );

    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = color
          ..strokeWidth = strokeW
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_FusionRingPainter old) =>
      old.progress != progress || old.color != color;
}

class _FusionVerticalMeter extends StatelessWidget {
  const _FusionVerticalMeter({
    required this.value,
    required this.color,
    required this.icon,
    required this.label,
    this.warning = false,
  });
  final double value;
  final Color color;
  final IconData icon;
  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    final activeColor = warning ? CaptureColors.warning : color;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 180,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _FusionMeterPainter(value: v, color: activeColor),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: CaptureColors.void_.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: activeColor.withValues(alpha: 0.85), size: 14),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            color: CaptureColors.silverDim,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${(v * 100).round()}%',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: CaptureColors.silver,
          ),
        ),
      ],
    );
  }
}

class _FusionMeterPainter extends CustomPainter {
  const _FusionMeterPainter({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const trackW = 6.0;
    final cx = size.width / 2;
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - trackW / 2, 0, trackW, size.height),
      const Radius.circular(3),
    );
    canvas.drawRRect(track, Paint()..color = CaptureColors.steel);

    final fillH = size.height * value;
    if (fillH > 0) {
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - trackW / 2, size.height - fillH, trackW, fillH),
        const Radius.circular(3),
      );
      canvas.drawRRect(fillRect, Paint()..color = color.withValues(alpha: 0.55));
    }

    final handleY = (size.height - fillH).clamp(8.0, size.height - 8.0);
    final handleCenter = Offset(cx, handleY);
    canvas.drawCircle(handleCenter, 8, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(handleCenter, 5.5, Paint()..color = CaptureColors.silverBright);
    canvas.drawCircle(
      handleCenter,
      5.5,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_FusionMeterPainter old) =>
      old.value != value || old.color != color;
}

class _FusionBurstDots extends StatelessWidget {
  const _FusionBurstDots({required this.filled, required this.total});
  final int filled;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final on = i < filled;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on
                ? CaptureColors.silverBright
                : CaptureColors.silverBright.withValues(alpha: 0.22),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: CaptureColors.silverBright.withValues(alpha: 0.7),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
        );
      }),
    );
  }
}

class _FusionConfirmationBanner extends StatelessWidget {
  const _FusionConfirmationBanner({
    required this.text,
    required this.lightingValue,
    required this.focusValue,
  });
  final String text;
  final double lightingValue;
  final double focusValue;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: CaptureColors.success.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: CaptureColors.success.withValues(alpha: 0.50)),
            ),
            child: Text(
              text,
              style: const TextStyle(
                color: CaptureColors.success,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (text == '✓ Captured') ...[
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'BRIGHT ${(lightingValue.clamp(0.0, 1.0) * 100).round()}%',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: CaptureColors.silverDim,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  'FOCUS ${(focusValue.clamp(0.0, 1.0) * 100).round()}%',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: CaptureColors.silverDim,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FusionWarningRow extends StatelessWidget {
  const _FusionWarningRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    const color = CaptureColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.info_outline, color: color, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
