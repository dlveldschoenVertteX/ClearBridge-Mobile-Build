import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';

/// Compact always-on distance gauge shown below the capture circle.
///
/// Displays a segmented horizontal bar split into three zones:
///   [← too far] [   perfect   ] [too close →]
/// A sliding indicator dot shows the user's current position within the
/// spectrum. No text — designed to coexist with guidance messages.
///
/// [thumbCoverageRatio] is the normalized hand height (0–1) from MediaPipe.
/// Thresholds match [DistanceGuidanceWidget] and [CaptureAxisController]:
///   > 0.80  → too close
///   0.45–0.80 → perfect
///   0.30–0.45 → approaching (treated as perfect zone visually)
///   < 0.30  → too far
class DistanceZoneBar extends StatelessWidget {
  const DistanceZoneBar({super.key, required this.thumbCoverageRatio});

  final double thumbCoverageRatio;

  static const double _barWidth = 120;
  static const double _barHeight = 5;
  static const double _dotSize = 10;
  static const double _totalHeight = _dotSize + 4;

  // Ratio space: 0.0 = far end, 1.0 = close end
  // Map thumbCoverageRatio → position along bar [0, 1]
  // tooFar = 0.0–0.30 → left segment (0.0–0.33)
  // perfect = 0.30–0.80 → center segment (0.33–0.67)
  // tooClose = 0.80–1.0 → right segment (0.67–1.0)
  static double _toBarPosition(double ratio) {
    const farMax = 0.30;
    const closeMin = 0.80;
    if (ratio <= farMax) {
      return (ratio / farMax) * 0.33;
    } else if (ratio >= closeMin) {
      return 0.67 + ((ratio - closeMin) / (1.0 - closeMin)) * 0.33;
    } else {
      return 0.33 + ((ratio - farMax) / (closeMin - farMax)) * 0.34;
    }
  }

  @override
  Widget build(BuildContext context) {
    final barPos = _toBarPosition(thumbCoverageRatio.clamp(0.0, 1.0));
    final isInPerfect = thumbCoverageRatio >= 0.30 && thumbCoverageRatio <= 0.80;
    final dotColor = isInPerfect ? ClearBridgeColors.success : ClearBridgeColors.warning;

    return SizedBox(
      width: _barWidth,
      height: _totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Segmented bar
          Positioned(
            top: (_totalHeight - _barHeight) / 2,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Row(
                children: [
                  // Too far (left)
                  Expanded(
                    child: Container(
                      height: _barHeight,
                      color: ClearBridgeColors.warning.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(width: 1),
                  // Perfect (center) — wider
                  Expanded(
                    flex: 2,
                    child: Container(
                      height: _barHeight,
                      color: ClearBridgeColors.success.withValues(alpha: 0.60),
                    ),
                  ),
                  const SizedBox(width: 1),
                  // Too close (right)
                  Expanded(
                    child: Container(
                      height: _barHeight,
                      color: ClearBridgeColors.warning.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Sliding indicator dot
          TweenAnimationBuilder<double>(
            tween: Tween(end: barPos),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            builder: (_, pos, __) {
              final leftOffset = pos * (_barWidth - _dotSize);
              return Positioned(
                left: leftOffset,
                top: 0,
                child: Container(
                  width: _dotSize,
                  height: _dotSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    boxShadow: [
                      BoxShadow(
                        color: dotColor.withValues(alpha: 0.55),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          // Zone labels (small, flanking the bar)
          Positioned(
            left: -2,
            top: _totalHeight - 1,
            child: Text(
              '↔',
              style: TextStyle(
                fontSize: 8,
                color: ClearBridgeColors.warning.withValues(alpha: 0.70),
                height: 1,
              ),
            ),
          ),
          Positioned(
            right: -2,
            top: _totalHeight - 1,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.rotationY(math.pi),
              child: Text(
                '↔',
                style: TextStyle(
                  fontSize: 8,
                  color: ClearBridgeColors.warning.withValues(alpha: 0.70),
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
