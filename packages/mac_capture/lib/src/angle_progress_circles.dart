import 'package:flutter/material.dart';

import 'capture_colors.dart';

/// Row of four small circles tracking capture progress through the angles
/// (front → left → top → right). The active circle fills as the thumb nears its
/// target; completed circles show a checkmark.
class AngleProgressCircles extends StatelessWidget {
  const AngleProgressCircles({
    super.key,
    required this.currentAngleIndex,
    required this.currentFillFraction, // 0.0–1.0 for the active circle
    required this.anglesComplete,
    this.glowAll = false,
  });

  final int currentAngleIndex;
  final double currentFillFraction;
  final List<bool> anglesComplete;
  /// When true, all circles briefly glow green (fired when the final angle starts).
  final bool glowAll;

  static const double _size = 18;
  static const _names = ['FRONT', 'LEFT', 'TOP', 'RIGHT'];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var i = 0; i < anglesComplete.length; i++) _circle(i),
      ],
    );
  }

  Widget _circle(int i) {
    final complete = anglesComplete[i];
    final active = i == currentAngleIndex && !complete;
    final labelColor = (active || complete || glowAll)
        ? CaptureColors.cyan
        : CaptureColors.silverDim;

    final dot = (complete || glowAll)
        ? AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: glowAll && !complete
                  ? CaptureColors.success
                  : CaptureColors.cyan,
            ),
            child: const Icon(
              Icons.check,
              color: Colors.white,
              size: 10,
            ),
          )
        : TweenAnimationBuilder<double>(
            tween: Tween(
                begin: 0, end: active ? currentFillFraction.clamp(0.0, 1.0) : 0.0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            builder: (context, f, _) {
              return Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: CaptureColors.cyan.withValues(alpha: f),
                  border: Border.all(
                    color: active
                        ? CaptureColors.cyan
                        : CaptureColors.steelBorder,
                    width: 1.5,
                  ),
                ),
              );
            },
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(height: 4),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: labelColor,
            letterSpacing: 0.5,
          ),
          child: Text(_names[i]),
        ),
      ],
    );
  }
}
