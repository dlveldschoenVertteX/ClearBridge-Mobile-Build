import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/clearbridge_colors.dart';

/// Centre guidance circle that mirrors the haptic gradient visually: it stays
/// still when far, "vibrates" (sinusoidal x-jitter) faster as the thumb nears
/// the target, snaps to green when locked, and pulses+checkmarks on capture.
///
/// [rotationHint] is the signed degrees remaining to the target angle
/// (-180..+180). Positive = rotate clockwise, negative = counter-clockwise.
/// Pass null to suppress the arrow (e.g. when there is no hand in frame).
class HapticGuidanceCircle extends StatefulWidget {
  const HapticGuidanceCircle({
    super.key,
    required this.distanceToTarget,
    required this.isLocked,
    required this.isPulsing,
    this.isAtCorrectDistance = true,
    this.rotationHint,
    this.isRetrying = false,
  });

  final double distanceToTarget;
  final bool isLocked;
  final bool isPulsing;
  final bool isAtCorrectDistance;
  final double? rotationHint;
  /// When true, the circle border turns amber and the gesture is a quality-retry signal.
  final bool isRetrying;

  @override
  State<HapticGuidanceCircle> createState() => _HapticGuidanceCircleState();
}

class _HapticGuidanceCircleState extends State<HapticGuidanceCircle>
    with TickerProviderStateMixin {
  late final AnimationController _shake;
  late final AnimationController _pulse;
  late final AnimationController _scan;
  late final AnimationController _breath;
  late final Animation<double> _scale;
  late final Animation<double> _flash;
  late final Animation<double> _breathScale;

  static const double _diameter = 200;
  static const Color _amberColor = Color(0xFFFF8C00);

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scan = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 0.95), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeOut));
    _flash = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.15), weight: 1), // ~80ms
      TweenSequenceItem(tween: Tween(begin: 0.15, end: 0.0), weight: 4),
    ]).animate(_pulse);
    _breathScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.05), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut));
  }

  @override
  void didUpdateWidget(covariant HapticGuidanceCircle old) {
    super.didUpdateWidget(old);
    if (widget.isPulsing && !old.isPulsing) {
      _pulse.forward(from: 0);
    }
    // Breathing: fires when the angleComplete moment ends and the next angle starts.
    if (!widget.isPulsing && old.isPulsing && !widget.isLocked) {
      _breath.forward(from: 0);
    }
    _updateShakeScan();
  }

  void _updateShakeScan() {
    final effectiveDistance = (widget.isPulsing || widget.isRetrying)
        ? 0.0
        : (widget.isAtCorrectDistance ? widget.distanceToTarget : 180.0);

    // Run shake only when approaching (freq > 0, i.e. distance ≤ 30°).
    final shouldShake = effectiveDistance > 0 && effectiveDistance <= 30;
    if (shouldShake && !_shake.isAnimating) {
      _shake.repeat();
    } else if (!shouldShake && _shake.isAnimating) {
      _shake.stop();
      _shake.reset();
    }

    // Run scan only while approaching band (5–30°).
    final shouldScan = effectiveDistance > 5 && effectiveDistance <= 30;
    if (shouldScan && !_scan.isAnimating) {
      _scan.repeat(reverse: true);
    } else if (!shouldScan && _scan.isAnimating) {
      _scan.stop();
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    _pulse.dispose();
    _scan.dispose();
    _breath.dispose();
    super.dispose();
  }

  // Rotation direction arrow — fades out as the thumb approaches locked.
  Widget? _rotationArrow(double effectiveDistance) {
    final hint = widget.rotationHint;
    if (hint == null || widget.isLocked || widget.isPulsing) return null;
    final opacity = ((effectiveDistance - 5) / 25).clamp(0.0, 1.0);
    if (opacity <= 0) return null;
    return Center(
      child: AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(milliseconds: 200),
        child: Icon(
          hint > 0 ? Icons.rotate_right_rounded : Icons.rotate_left_rounded,
          color: ClearBridgeColors.cyan.withValues(alpha: 0.75),
          size: 52,
        ),
      ),
    );
  }

  // Horizontal gradient line that sweeps top→bottom while the thumb is
  // approaching (effectiveDistance 5–30°). Hidden when locked or far.
  Widget _scanLineLayer({required bool visible, required double scanValue}) {
    if (!visible) return const SizedBox.shrink();
    final y = 18.0 + scanValue * (_diameter - 36.0);
    return Positioned(
      left: 12,
      right: 12,
      top: y,
      child: Container(
        height: 1.5,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Colors.transparent, ClearBridgeColors.cyan, Colors.transparent],
          ),
          borderRadius: BorderRadius.circular(1),
          boxShadow: [
            BoxShadow(
              color: ClearBridgeColors.cyan.withValues(alpha: 0.50),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }

  // Jitter frequency (Hz) for a given effective distance.
  double _frequencyFor(double d) {
    if (d > 30) return 0;
    if (d > 20) return 0.4;
    if (d > 10) return 1.2;
    if (d > 5) return 3;
    return 6;
  }

  @override
  Widget build(BuildContext context) {
    final completionMode = widget.isPulsing;

    // During completion or retry: suppress all proximity-based animations.
    final effectiveDistance = (completionMode || widget.isRetrying)
        ? 0.0
        : (widget.isAtCorrectDistance ? widget.distanceToTarget : 180.0);

    final approaching = effectiveDistance > 5 && effectiveDistance <= 30;
    final fillFraction =
        approaching ? ((30 - effectiveDistance) / 25).clamp(0.0, 1.0) * 0.5 : 0.0;

    final borderColor = widget.isRetrying
        ? _amberColor
        : (completionMode || widget.isLocked)
            ? ClearBridgeColors.success
            : (widget.isAtCorrectDistance
                ? ClearBridgeColors.cyan
                : ClearBridgeColors.cyan.withValues(alpha: 0.30));

    final fillColor = completionMode
        ? ClearBridgeColors.success.withValues(alpha: 0.20)
        : widget.isRetrying
            ? _amberColor.withValues(alpha: 0.12)
            : (widget.isLocked
                ? ClearBridgeColors.success.withValues(alpha: 0.25)
                : ClearBridgeColors.cyanMuted.withValues(alpha: fillFraction));

    return AnimatedBuilder(
      animation: Listenable.merge([_shake, _pulse, _scan, _breath]),
      builder: (context, _) {
        final freq = _frequencyFor(effectiveDistance);
        final shakeX = (freq == 0 || completionMode || widget.isRetrying)
            ? 0.0
            : math.sin(_shake.value * 2 * math.pi * freq) * 3.0;

        // Pulse takes priority over breathing; they don't overlap.
        final scale = _pulse.isAnimating
            ? _scale.value
            : (_breath.isAnimating ? _breathScale.value : 1.0);
        final flash = _pulse.isAnimating ? _flash.value : 0.0;

        final arrow = _rotationArrow(effectiveDistance);

        return Transform.translate(
          offset: Offset(shakeX, 0),
          child: Transform.scale(
            scale: scale,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _diameter,
              height: _diameter,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fillColor,
                border: Border.all(
                  color: borderColor,
                  width: (completionMode || widget.isLocked) ? 3 : 2,
                ),
              ),
              child: Stack(
                children: [
                  // Scan line — sweeps top→bottom while approaching
                  _scanLineLayer(
                    visible: approaching && !completionMode,
                    scanValue: _scan.value,
                  ),
                  // Rotation direction arrow
                  if (arrow != null) arrow,
                  // Angle-complete checkmark overlay
                  if (completionMode)
                    const Center(
                      child: Icon(
                        Icons.check_circle_outline_rounded,
                        color: ClearBridgeColors.success,
                        size: 64,
                      ),
                    ),
                  // White flash on capture
                  if (flash > 0)
                    Container(
                      color: Colors.white.withValues(alpha: flash),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
