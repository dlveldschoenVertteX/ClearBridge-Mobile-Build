import 'package:flutter/material.dart';

import '../services/multi_angle_capture_controller.dart';

// ── Color constants — mirrors splash palette ──────────────────────────────────
const _cyan  = Color(0xFF00BFFF);
const _green = Color(0xFF22C55E);
const _gold  = Color(0xFFC9A84C);

// Trapezoid opacity: ramps in over [0, rampFrac], holds, ramps out over
// [1-rampFrac, 1]. Matches the splash _trapezoid utility.
double _trap(double t, {double ramp = 0.07}) {
  if (t <= 0 || t >= 1) return 0.0;
  if (t < ramp) return t / ramp;
  if (t > 1.0 - ramp) return (1.0 - t) / ramp;
  return 1.0;
}

/// Full-screen FX overlay for the MAC capture screen.
///
/// Layers:
///  1. Scan line — sweeps inside the 200px guide circle during calibrating/capturing
///  2. Ring blast — two expanding rings (cyan + green) fired on each angle capture
///  3. Bloom — green radial glow fired on each angle capture
///  4. Eyebrow — "CAPTURED ✓" / "ALL CLEAR ✓" label above the guide circle
///
/// Positioned.fill + IgnorePointer in the host Stack — never intercepts taps.
class CaptureFxOverlay extends StatefulWidget {
  const CaptureFxOverlay({
    super.key,
    required this.phase,
    required this.completedCount,
    required this.isAllComplete,
  });

  final CapturePhase phase;
  final int completedCount;      // 0–4: number of angles done
  final bool isAllComplete;      // true for the 400ms allCirclesGlow pulse

  @override
  State<CaptureFxOverlay> createState() => _CaptureFxOverlayState();
}

class _CaptureFxOverlayState extends State<CaptureFxOverlay>
    with TickerProviderStateMixin {
  // Scan line: continuous 2000ms repeat during calibrating + capturing
  late final AnimationController _scanCtrl;

  // Ring blast: 1150ms one-shot on each angle capture
  late final AnimationController _ring1Ctrl;
  late final AnimationController _ring2Ctrl; // 200ms staggered

  // Bloom: 700ms one-shot on each angle capture
  late final AnimationController _bloomCtrl;

  // Eyebrow: 1000ms one-shot (300ms in + 400ms hold + 300ms out)
  late final AnimationController _eyebrowCtrl;

  int _lastCompletedCount = 0;
  bool _allComplete = false;

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat();

    _ring1Ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1150));
    _ring2Ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1150));
    _bloomCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    _eyebrowCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000));

    _lastCompletedCount = widget.completedCount;
    _allComplete = widget.isAllComplete;
  }

  @override
  void didUpdateWidget(covariant CaptureFxOverlay old) {
    super.didUpdateWidget(old);

    // Detect a new angle completion
    if (widget.completedCount > _lastCompletedCount) {
      _lastCompletedCount = widget.completedCount;
      _allComplete = widget.isAllComplete || widget.completedCount == 4;
      _triggerBlast();
    }

    // Resume scan when re-entering capturing from another phase
    final isActive = widget.phase == CapturePhase.calibrating ||
        widget.phase == CapturePhase.capturing;
    if (isActive && !_scanCtrl.isAnimating) {
      _scanCtrl.repeat();
    } else if (!isActive && _scanCtrl.isAnimating) {
      _scanCtrl.stop();
    }
  }

  void _triggerBlast() {
    _ring1Ctrl.forward(from: 0);
    // Ring 2 starts 200ms after ring 1
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _ring2Ctrl.forward(from: 0);
    });
    _bloomCtrl.forward(from: 0);
    _eyebrowCtrl.forward(from: 0);
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _ring1Ctrl.dispose();
    _ring2Ctrl.dispose();
    _bloomCtrl.dispose();
    _eyebrowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.phase == CapturePhase.calibrating ||
        widget.phase == CapturePhase.capturing;

    return LayoutBuilder(
      builder: (_, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final cx = w / 2;
        final cy = h / 2;

        return AnimatedBuilder(
          animation: Listenable.merge(
              [_scanCtrl, _ring1Ctrl, _ring2Ctrl, _bloomCtrl, _eyebrowCtrl]),
          builder: (_, __) {
            return Stack(
              children: [
                // ── 1. Scan line — clipped to 200px guide circle ──────────────
                if (isActive) _buildScanLine(cx, cy),

                // ── 2. Ring blasts ────────────────────────────────────────────
                if (_ring1Ctrl.value > 0)
                  _buildRing(cx, cy, _ring1Ctrl.value, _cyan),
                if (_ring2Ctrl.value > 0)
                  _buildRing(cx, cy, _ring2Ctrl.value, _green),

                // ── 3. Bloom ──────────────────────────────────────────────────
                if (_bloomCtrl.value > 0) _buildBloom(cx, cy),

                // ── 4. Eyebrow ────────────────────────────────────────────────
                if (_eyebrowCtrl.value > 0)
                  _buildEyebrow(cx, cy),
              ],
            );
          },
        );
      },
    );
  }

  // ── Scan line ──────────────────────────────────────────────────────────────

  Widget _buildScanLine(double cx, double cy) {
    const r = 100.0; // circle radius = diameter 200 / 2
    final t = _scanCtrl.value;
    // Vertical travel: top of circle to bottom (−r → +r), mapped 0→1
    final dy = -r + t * (r * 2.0);
    final opacity = _trap(t, ramp: 0.07);
    if (opacity <= 0) return const SizedBox.shrink();

    return Positioned(
      left: cx - r,
      top: cy - r,
      width: r * 2,
      height: r * 2,
      child: Opacity(
        opacity: opacity,
        child: ClipOval(
          child: Stack(
            children: [
              // Trail gradient below the line
              Positioned(
                top: dy + r + 1,
                left: 0,
                right: 0,
                height: 48,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x38003FFF), Colors.transparent],
                    ),
                  ),
                ),
              ),
              // Scan line
              Positioned(
                top: dy + r - 1.5,
                left: r * 0.05,
                right: r * 0.05,
                height: 3,
                child: Container(
                  decoration: BoxDecoration(
                    color: _cyan,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0xCC00BFFF),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Ring blast ─────────────────────────────────────────────────────────────

  Widget _buildRing(double cx, double cy, double raw, Color color) {
    final progress = raw; // 0→1
    final scale = 0.62 + progress * (1.55 - 0.62);
    final opacity = progress < 0.18
        ? (progress / 0.18) * 0.80
        : 0.80 * (1.0 - progress) / 0.82;

    const base = 240.0;
    final size = base * scale;

    return Positioned(
      left: cx - size / 2,
      top: cy - size / 2,
      width: size,
      height: size,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.70), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.45),
                blurRadius: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Bloom ──────────────────────────────────────────────────────────────────

  Widget _buildBloom(double cx, double cy) {
    final t = _bloomCtrl.value;
    final opacity = t < 0.26 ? (t / 0.26) * 0.85 : 0.85 * (1.0 - t) / 0.74;
    const size = 200.0;

    return Positioned(
      left: cx - size / 2,
      top: cy - size / 2,
      width: size,
      height: size,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                _green.withValues(alpha: 0.85),
                Colors.transparent,
              ],
              stops: const [0.0, 0.68],
            ),
          ),
        ),
      ),
    );
  }

  // ── Eyebrow ────────────────────────────────────────────────────────────────

  Widget _buildEyebrow(double cx, double cy) {
    final t = _eyebrowCtrl.value;
    // 300ms in, 400ms hold, 300ms out
    final opacity = t < 0.30
        ? t / 0.30
        : t > 0.70
            ? (1.0 - t) / 0.30
            : 1.0;

    final isAll = _allComplete;
    final label = isAll ? 'ALL CLEAR' : 'CAPTURED';
    final color = isAll ? _gold : _green;

    return Positioned(
      left: 0,
      right: 0,
      top: cy - 100 - 48, // 100px = circle radius, 48px above circle edge
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_user_rounded, color: color, size: 15),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 3.2,
                color: color,
                shadows: [
                  Shadow(
                    color: color.withValues(alpha: 0.60),
                    blurRadius: 14,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
