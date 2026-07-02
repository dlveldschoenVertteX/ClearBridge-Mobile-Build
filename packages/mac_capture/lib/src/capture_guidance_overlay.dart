import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'capture_colors.dart';
import 'capture_typography.dart';

/// Plain-text guidance overlay shown below the capture circle during capture.
/// Shows the current axis guidance message with a 150ms crossfade.
class CaptureGuidanceOverlay extends StatelessWidget {
  const CaptureGuidanceOverlay({
    super.key,
    required this.message,
    required this.isAllGreen,
    required this.greenFraction,
  });

  final String message;
  final bool isAllGreen;
  final double greenFraction; // 0.0–1.0 (consecutiveGreenFrames / 5)

  @override
  Widget build(BuildContext context) {
    final textColor = isAllGreen
        ? CaptureColors.success
        : CaptureColors.silverBright;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: Text(
        message,
        key: ValueKey(message),
        textAlign: TextAlign.center,
        style: CaptureTypography.body.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
      ),
    );
  }
}

/// Two-phase progress arc around the HapticGuidanceCircle.
///
/// Phase A (distanceToTarget > 5°): cyan arc fills as the thumb approaches the
///   target (30° → 5°), giving the user a live closing-in signal.
/// Phase B (distanceToTarget ≤ 5°, angle locked): arc transitions to green and
///   fills as consecutive quality frames accumulate (0 → 5), confirming the hold.
///
/// The handoff between phases is seamless — the arc stays on screen and only
/// the colour and fill source change.
class RotationProgressArc extends StatelessWidget {
  const RotationProgressArc({
    super.key,
    required this.distanceToTarget,
    required this.axisGreenFrames,
  });

  final double distanceToTarget;
  final int axisGreenFrames;

  static const double _size = 218;
  static const double _strokeWidth = 3;

  @override
  Widget build(BuildContext context) {
    final locked = distanceToTarget <= 5;
    final double fraction;
    final Color arcColor;
    if (locked) {
      fraction = (axisGreenFrames / 5.0).clamp(0.0, 1.0);
      arcColor = CaptureColors.success;
    } else {
      fraction = ((30.0 - distanceToTarget) / 25.0).clamp(0.0, 1.0);
      arcColor = CaptureColors.cyan;
    }
    if (fraction <= 0) return const SizedBox.shrink();
    return SizedBox(
      width: _size,
      height: _size,
      child: CustomPaint(painter: _RotationArcPainter(fraction, arcColor)),
    );
  }
}

class _RotationArcPainter extends CustomPainter {
  _RotationArcPainter(this.fraction, this.color);
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = RotationProgressArc._strokeWidth
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(
      RotationProgressArc._strokeWidth / 2,
      RotationProgressArc._strokeWidth / 2,
      size.width - RotationProgressArc._strokeWidth,
      size.height - RotationProgressArc._strokeWidth,
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0.0, 1.0),
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RotationArcPainter old) =>
      old.fraction != fraction || old.color != color;
}
