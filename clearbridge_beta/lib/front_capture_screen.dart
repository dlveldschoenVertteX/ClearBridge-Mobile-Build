import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

import 'front_capture_controller.dart';

/// Front-only fingerprint capture screen — MAC3D UX polish.
///
/// Layout: three-column while the guide is active (brightness meter |
/// 270×270 progress ring + oval guide | focus meter), with a status pill
/// in the header and guidance text below the ring.
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

class _FrontCaptureScreenState extends State<FrontCaptureScreen>
    with TickerProviderStateMixin {
  final CameraService _cameraService = CameraService();
  late final FrontCaptureController _ctrl;
  late final AnimationController _scanAnim;
  bool _ready = false;
  bool _navigated = false;
  String? _initError;

  // Locked at the moment the main burst begins so the focus meter stays
  // stable during shot-taking (flash alternation causes the peak-normalised
  // _focusValue to oscillate during the burst itself — cosmetically confusing
  // since the burst already started because focus was good). Cleared once
  // isCapturingBurst goes false.
  double? _lockedFocusValue;

  CameraController? get _camera => _cameraService.controller;

  @override
  void initState() {
    super.initState();
    _ctrl = FrontCaptureController();
    _ctrl.addListener(_onState);
    // Not started here — driven by _onState so it only runs during active
    // shot-taking (not during the Processing… decode window, which is where
    // the 8× concurrent decodes happen and CPU headroom matters most).
    _scanAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
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
    final s = _ctrl.state;

    // Scan animation: run only while shots are actively being taken.
    // Stops before the Processing… decode phase so the 8× concurrent
    // ui.instantiateImageCodec calls don't compete with 60 fps repaints.
    final shouldScan = s.isCapturingBurst && s.confirmationText == null;
    if (shouldScan && !_scanAnim.isAnimating) {
      _scanAnim.repeat(reverse: true);
    } else if (!shouldScan && _scanAnim.isAnimating) {
      _scanAnim.stop();
      _scanAnim.value = 0;
    }

    // Focus meter: lock at burst-start value to avoid the
    // peak-normalisation oscillation that flash-vs-ambient alternation causes.
    if (s.isCapturingBurst && _lockedFocusValue == null) {
      _lockedFocusValue = _ctrl.focusValue;
    } else if (!s.isCapturingBurst && _lockedFocusValue != null) {
      _lockedFocusValue = null;
    }

    setState(() {});

    if (!_navigated &&
        s.phase == FrontCapturePhase.complete &&
        s.captureId != null) {
      _navigated = true;
      widget.onComplete(s.captureId!);
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onState);
    _ctrl.dispose();
    _cameraService.disposeCamera();
    _scanAnim.dispose();
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
      cameraService: _cameraService,
    );
  }

  // Returns (progress 0-1, fillColor) for the outer progress ring.
  (double, Color) _ringState(FrontCaptureState s) {
    if (s.isCapturingBurst) return (s.burstProgress, CaptureColors.silverBright);
    if (s.phase == FrontCapturePhase.capturingExtra) {
      return (s.extraProgress, CaptureColors.gold);
    }
    if (s.phase == FrontCapturePhase.sweepActive) {
      // Orange while too blurry to fire (mirrors the tracking highlight
      // below), green once the current frame clears the sharpness gate.
      return (
        s.sweepProgress,
        s.sweepFastWarning ? CaptureColors.warning : CaptureColors.success,
      );
    }
    if (s.phase == FrontCapturePhase.complete) return (1.0, CaptureColors.success);
    if (s.phase == FrontCapturePhase.holding && s.onTarget) {
      return (s.holdProgress, CaptureColors.cyan);
    }
    return (0.0, CaptureColors.cyan);
  }

  String? _headlineText(FrontCaptureState s) {
    if (s.phase == FrontCapturePhase.idle) return 'Place thumb in the guide';
    if (s.phase == FrontCapturePhase.calibrating) return 'Preparing camera…';
    if (s.phase == FrontCapturePhase.holding) {
      if (s.onTarget) return 'Hold still…';
      if (!s.isSteady) return 'Hold the phone steady…';
      return 'Align your thumb';
    }
    if (s.phase == FrontCapturePhase.sweepPositioning) {
      return 'Place thumb at the left edge of the guide';
    }
    if (s.phase == FrontCapturePhase.sweepActive) {
      return s.sweepFastWarning ? 'Slow down a little…' : 'Slowly sweep right →';
    }
    if (s.phase == FrontCapturePhase.capturing) return 'Scanning fingerprint…';
    if (s.phase == FrontCapturePhase.capturingExtra) {
      return s.distanceHint ?? 'Capturing extra detail…';
    }
    return null;
  }

  Color _headlineColor(FrontCaptureState s) {
    if (s.phase == FrontCapturePhase.holding && s.onTarget) {
      return CaptureColors.success;
    }
    if (s.phase == FrontCapturePhase.sweepActive) {
      return s.sweepFastWarning ? CaptureColors.warning : CaptureColors.success;
    }
    if (s.phase == FrontCapturePhase.sweepPositioning) {
      return CaptureColors.cyan;
    }
    return CaptureColors.silverBright;
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) return _errorScaffold('Camera error: $_initError');
    if (!_ready) {
      return const Scaffold(
        backgroundColor: CaptureColors.void_,
        body: Center(child: CircularProgressIndicator(color: CaptureColors.cyan)),
      );
    }

    final s = _ctrl.state;
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final topPad = mq.padding.top;
    final bottomPad = mq.padding.bottom;

    final showGuide = s.phase == FrontCapturePhase.idle ||
        s.phase == FrontCapturePhase.calibrating ||
        s.phase == FrontCapturePhase.holding ||
        s.phase == FrontCapturePhase.sweepPositioning ||
        s.phase == FrontCapturePhase.sweepActive ||
        s.phase == FrontCapturePhase.capturing ||
        s.phase == FrontCapturePhase.capturingExtra;

    final silhouetteState = (s.isCapturingBurst ||
            s.phase == FrontCapturePhase.capturingExtra ||
            s.phase == FrontCapturePhase.sweepActive)
        ? PadSilhouetteState.capturing
        : (s.onTarget || s.phase == FrontCapturePhase.sweepPositioning
            ? PadSilhouetteState.locked
            : PadSilhouetteState.aligning);

    final (ringProgress, ringColor) = _ringState(s);

    // 270×270 ring centred at cy=0.37 — matches PadSilhouetteShape.cy.
    const ringD = 270.0;
    const ringR = ringD / 2;
    final ringCx = size.width / 2;
    final ringCy = size.height * 0.37;
    final ringLeft = ringCx - ringR;
    final ringTop = ringCy - ringR;

    // Vertical meters: 40×180, flanking the ring with a 10 px gap.
    const meterW = 40.0;
    const meterH = 180.0;
    const meterGap = 10.0;
    final meterTop = ringCy - meterH / 2;
    final brightLeft = ringLeft - meterGap - meterW;
    final focusLeft = ringLeft + ringD + meterGap;

    // Warning / hint row — distance or lighting.
    String? warningText;
    Color warningColor = CaptureColors.warning;
    if (showGuide &&
        s.distanceHint != null &&
        s.phase != FrontCapturePhase.capturingExtra) {
      warningText = s.distanceHint == 'Move closer'
          ? '↑ Move phone CLOSER to your thumb'
          : '↓ Move phone BACK a little';
    } else if (showGuide &&
        s.distanceHint == null &&
        s.lightingValue < 0.18 &&
        (s.phase == FrontCapturePhase.calibrating ||
            s.phase == FrontCapturePhase.holding)) {
      warningText = '☀  Brighter light = sharper print';
      warningColor = CaptureColors.gold;
    }

    final headline = _headlineText(s);

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Stack(
        children: [
          // Camera preview — stopped before upload phase to prevent bleed-
          // through behind the upload scrim (real device test, 2026-07-23).
          if (s.phase != FrontCapturePhase.uploading)
            Positioned.fill(child: RepaintBoundary(child: _cameraLayer())),

          // Pad guide overlay: dark scrim + oval cutout + core reticle.
          // progress=0 suppresses the old boundary arc — the new external
          // ring replaces it. hint=null: guidance now lives in the bottom
          // section, not drawn inside the overlay.
          if (showGuide)
            Positioned.fill(
              child: RepaintBoundary(
                child: CapturePadSilhouetteOverlay(
                  state: silhouetteState,
                  hint: null,
                  progress: 0,
                  shape: s.activeGuideShape ?? PadSilhouetteShape.defaultShape,
                ),
              ),
            )
          else
            const Positioned.fill(
              child: RepaintBoundary(child: CaptureVignetteOverlay()),
            ),

          // 270×270 capture progress ring centred on the oval.
          if (showGuide)
            Positioned(
              left: ringLeft,
              top: ringTop,
              child: _CaptureProgressRing(progress: ringProgress, color: ringColor),
            ),

          // Sweep Step 1 (positioning) needs no separate highlight overlay --
          // the guide silhouette itself shifts left via activeGuideShape
          // (see FrontCaptureController._sweepGuideShapeForProgress), a real
          // fix from 2026-07-30 device-test feedback that a static guide +
          // internal highlight band left the user unable to tell where
          // their thumb actually needed to be.

          // Sweep Step 2: horizontal progress bar + moving centroid-tracking
          // highlight beneath the guide. Replaces the need for mid-sweep text
          // instruction — the user watches this fill left-to-right instead.
          if (s.phase == FrontCapturePhase.sweepActive)
            Positioned(
              left: ringLeft,
              top: ringTop + ringD + 10,
              width: ringD,
              child: _SweepProgressBar(
                progress: s.sweepProgress,
                fastWarning: s.sweepFastWarning,
              ),
            ),

          // Brightness meter — left of ring.
          if (showGuide)
            Positioned(
              left: brightLeft,
              top: meterTop,
              child: _VerticalMeter(
                value: s.lightingValue,
                color: CaptureColors.gold,
                icon: Icons.wb_sunny_outlined,
              ),
            ),

          // Focus meter — right of ring. Uses the value locked at burst-start
          // while shooting so flash/ambient alternation doesn't make it flicker.
          if (showGuide)
            Positioned(
              left: focusLeft,
              top: meterTop,
              child: _VerticalMeter(
                value: _lockedFocusValue ?? _ctrl.focusValue,
                color: CaptureColors.cyan,
                icon: Icons.center_focus_strong_outlined,
              ),
            ),

          // Scan line sweeping through the oval during burst.
          if (s.isCapturingBurst)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _scanAnim,
                  builder: (_, __) {
                    final lineY = ringTop + 16 + (ringD - 32) * _scanAnim.value;
                    return Stack(
                      children: [
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
                      ],
                    );
                  },
                ),
              ),
            ),

          // Frame counter X/8 shown under the ring during burst.
          if (s.isCapturingBurst)
            Positioned(
              top: ringTop + ringD + 6,
              left: ringLeft,
              width: ringD,
              child: Text(
                '${(s.burstProgress * 8).ceil()} / 8',
                textAlign: TextAlign.center,
                style: CaptureTypography.label.copyWith(
                  fontSize: 11,
                  color: CaptureColors.silver,
                ),
              ),
            ),

          // Per-camera confirmation banners (e.g. "✓ IR captured"), and the
          // sweep-retry prompt ("Try again — sweep a little slower") shown
          // via the same mechanism while briefly back in sweepPositioning.
          if (s.confirmationText != null)
            Positioned(
              top: topPad + 64,
              left: 40,
              right: 40,
              child: _ConfirmationBanner(
                text: s.confirmationText!,
                isWarning: s.phase == FrontCapturePhase.sweepPositioning,
              ),
            ),

          // Header: back | "FRONT CAPTURE" | status pill.
          Positioned(
            top: topPad + 10,
            left: 0,
            right: 0,
            child: _buildHeader(s),
          ),

          // Headline + idle caption, anchored just below the ring.
          // Suppressed when the confirmationText banner is active so the two
          // don't render simultaneously (e.g. "Processing…" pill + "Scanning
          // fingerprint…" text both visible during the post-burst decode phase).
          if (headline != null &&
              s.confirmationText == null &&
              s.phase != FrontCapturePhase.uploading)
            Positioned(
              left: 24,
              right: 24,
              top: ringTop + ringD + (s.isCapturingBurst ? 24 : 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    headline,
                    textAlign: TextAlign.center,
                    style: CaptureTypography.h3.copyWith(
                      fontSize: 16,
                      color: _headlineColor(s),
                    ),
                  ),
                  if (s.phase == FrontCapturePhase.idle) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Press your thumb pad flat against the camera lens and seat it in the outline.',
                      textAlign: TextAlign.center,
                      style: CaptureTypography.body.copyWith(
                        fontSize: 12,
                        color: CaptureColors.silver,
                      ),
                    ),
                  ],
                ],
              ),
            ),

          // Warning + CTA anchored to the bottom.
          if (s.phase != FrontCapturePhase.uploading &&
              s.phase != FrontCapturePhase.complete &&
              s.phase != FrontCapturePhase.error)
            Positioned(
              bottom: bottomPad + 16,
              left: 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (warningText != null) ...[
                    _WarningRow(text: warningText, color: warningColor),
                    const SizedBox(height: 10),
                  ],
                  _buildCta(s),
                ],
              ),
            ),

          // Upload overlay — camera already disposed before this phase.
          if (s.phase == FrontCapturePhase.uploading)
            Positioned.fill(child: _UploadingOverlay(progress: s.uploadProgress)),

          // Error overlay.
          if (s.phase == FrontCapturePhase.error)
            Positioned.fill(child: _errorOverlay(s.error ?? 'Capture failed')),
        ],
      ),
    );
  }

  Widget _buildHeader(FrontCaptureState s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: widget.onClose,
            child: const Icon(Icons.arrow_back_ios,
                color: CaptureColors.silverBright, size: 22),
          ),
          Container(
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
          _StatusPill(phase: s.phase, onTarget: s.onTarget),
        ],
      ),
    );
  }

  // Bottom CTA row: only the idle and error phases show an action button.
  Widget _buildCta(FrontCaptureState s) {
    if (s.phase == FrontCapturePhase.idle) {
      return CaptureButton(
        label: 'Start Capture',
        leadingIcon: Icons.fingerprint,
        onPressed: _onStart,
      );
    }
    // Active phases: small, non-interactive status line so the area
    // isn't blank while the user is in the flow.
    final note = s.phase == FrontCapturePhase.calibrating
        ? 'Preparing camera…'
        : (s.phase == FrontCapturePhase.holding && !s.onTarget && s.isSteady)
            ? 'Align your thumb'
            : null;
    if (note == null) return const SizedBox.shrink();
    return Text(
      note,
      textAlign: TextAlign.center,
      style: CaptureTypography.label
          .copyWith(fontSize: 13, color: CaptureColors.silver),
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
            const Icon(Icons.error_outline,
                color: CaptureColors.error, size: 44),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: CaptureTypography.body.copyWith(fontSize: 14)),
            const SizedBox(height: 22),
            CaptureButton(
              label: 'Back',
              variant: CaptureButtonVariant.ghost,
              onPressed: widget.onClose,
            ),
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

// ── Status pill ───────────────────────────────────────────────────────────────

class _StatusPill extends StatefulWidget {
  const _StatusPill({required this.phase, required this.onTarget});
  final FrontCapturePhase phase;
  final bool onTarget;

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dot;

  @override
  void initState() {
    super.initState();
    _dot = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _dot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isRec = widget.phase == FrontCapturePhase.capturing ||
        widget.phase == FrontCapturePhase.capturingExtra;
    final isCaptured = widget.phase == FrontCapturePhase.complete;

    final Color pillBg;
    final Color textColor;
    final String label;
    final Widget? leading;

    if (isCaptured) {
      pillBg = CaptureColors.success.withValues(alpha: 0.18);
      textColor = CaptureColors.success;
      label = 'Captured';
      leading = const Icon(Icons.check, color: CaptureColors.success, size: 11);
    } else if (isRec) {
      pillBg = CaptureColors.warning.withValues(alpha: 0.18);
      textColor = CaptureColors.warning;
      label = 'REC';
      leading = AnimatedBuilder(
        animation: _dot,
        builder: (_, __) => Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: CaptureColors.warning.withValues(alpha: 0.35 + 0.65 * _dot.value),
            shape: BoxShape.circle,
          ),
        ),
      );
    } else {
      pillBg = CaptureColors.cyan.withValues(alpha: 0.12);
      textColor = CaptureColors.cyan;
      label = 'READY';
      leading = null;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: pillBg,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: textColor.withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 4)],
          Text(
            label,
            style: CaptureTypography.label.copyWith(
              fontSize: 10,
              color: textColor,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Vertical meter ────────────────────────────────────────────────────────────

class _VerticalMeter extends StatelessWidget {
  const _VerticalMeter({
    required this.value,
    required this.color,
    required this.icon,
  });

  final double value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 180,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CustomPaint(
          painter: _MeterPainter(value: value.clamp(0.0, 1.0), color: color),
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Icon(icon, color: color.withValues(alpha: 0.65), size: 14),
            ),
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  const _MeterPainter({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = Radius.circular(10);
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, radius);

    // Track background.
    canvas.drawRRect(rrect, Paint()..color = CaptureColors.cardBg);

    // Filled portion grows from the bottom.
    final fillH = size.height * value;
    if (fillH > 0) {
      final fillRect =
          Rect.fromLTWH(0, size.height - fillH, size.width, fillH);
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, radius),
        Paint()..color = color.withValues(alpha: 0.28),
      );
    }

    // Thumb line at the top of the fill.
    final thumbY = size.height - fillH;
    canvas.drawLine(
      Offset(8, thumbY),
      Offset(size.width - 8, thumbY),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.value != value || old.color != color;
}

// ── Capture progress ring ─────────────────────────────────────────────────────

class _CaptureProgressRing extends StatelessWidget {
  const _CaptureProgressRing({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _RingPainter(progress: progress, color: color),
      size: const Size(270, 270),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = cx - 6; // inset so stroke doesn't clip at the widget edge
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    // Ring track — always visible, at low opacity.
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = color.withValues(alpha: 0.12)
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke,
    );

    // Progress arc — starts at 12 o'clock (-π/2), fills clockwise.
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = color
          ..strokeWidth = 5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

// ── Warning row ───────────────────────────────────────────────────────────────

class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
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
          Icon(Icons.info_outline, color: color, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: CaptureTypography.label
                  .copyWith(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Confirmation banner ───────────────────────────────────────────────────────

class _ConfirmationBanner extends StatelessWidget {
  const _ConfirmationBanner({required this.text, this.isWarning = false});
  final String text;
  // True for the sweep-retry prompt ("Try again — sweep a little slower")
  // -- same banner shape/mechanism as the success confirmations, but a
  // warning tone rather than green so a failed sweep doesn't read as success.
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final color = isWarning ? CaptureColors.warning : CaptureColors.success;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: color.withValues(alpha: 0.50)),
        ),
        child: Text(
          text,
          style: CaptureTypography.h3.copyWith(color: color, fontSize: 15),
        ),
      ),
    );
  }
}

// ── Sweep progress bar ────────────────────────────────────────────────────────

/// Horizontal left-to-right fill bar shown during sweepActive, beneath the
/// guide. Replaces the need for mid-sweep text instruction (per the UX
/// spec) — the user watches this fill instead of reading copy. Green while
/// the current frame is sharp enough to fire, orange while moving too fast.
class _SweepProgressBar extends StatelessWidget {
  const _SweepProgressBar({required this.progress, required this.fastWarning});
  final double progress;
  final bool fastWarning;

  @override
  Widget build(BuildContext context) {
    final color = fastWarning ? CaptureColors.warning : CaptureColors.success;
    return SizedBox(
      height: 10,
      child: CustomPaint(
        painter: _SweepBarPainter(progress: progress.clamp(0.0, 1.0), color: color),
      ),
    );
  }
}

class _SweepBarPainter extends CustomPainter {
  const _SweepBarPainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(track, Paint()..color = CaptureColors.cardBg);

    final fillW = size.width * progress;
    if (fillW > 0) {
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, fillW, size.height),
        Radius.circular(size.height / 2),
      );
      canvas.drawRRect(fillRect, Paint()..color = color.withValues(alpha: 0.55));
    }

    // Marker dot at the current leading edge -- the moving "tracking" cue
    // the UX spec calls for, distinct from the fill itself.
    final markerX = fillW.clamp(size.height / 2, size.width - size.height / 2);
    canvas.drawCircle(
      Offset(markerX, size.height / 2),
      size.height / 2 + 2,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SweepBarPainter old) =>
      old.progress != progress || old.color != color;
}

// ── Upload overlay ────────────────────────────────────────────────────────────

class _UploadingOverlay extends StatelessWidget {
  const _UploadingOverlay({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    // Fully opaque (camera already stopped before this phase). ClearBridge
    // logo + spinner + linear progress — replaces the generic fingerprint
    // icon placeholder per CTO device-test feedback 2026-07-23.
    return Container(
      color: CaptureColors.void_,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 132,
              height: 132,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const SizedBox(
                    width: 132,
                    height: 132,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: CaptureColors.cyan,
                    ),
                  ),
                  ClipOval(
                    child: Image.asset(
                      'assets/images/app_logo.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.fingerprint,
                        size: 96,
                        color: CaptureColors.cyan,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Uploading capture…',
              style: CaptureTypography.body
                  .copyWith(color: CaptureColors.silverBright, fontSize: 15),
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
