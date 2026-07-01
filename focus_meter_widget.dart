import 'package:flutter/material.dart';

import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';

/// Right-edge vertical meter for focus sharpness. [value] is the normalized
/// Laplacian (0–1, EMA smoothed); the fill fraction is mapped so a blurry frame
/// reads near-empty and an AFIS-sharp frame reads near-full.
class FocusMeterWidget extends StatelessWidget {
  const FocusMeterWidget({super.key, required this.value});

  final double value;

  double get _fillFraction {
    final v = value.clamp(0.0, 1.0);
    if (v < 0.30) return _map(v, 0.0, 0.30, 0.0, 0.1);
    if (v < 0.50) return _map(v, 0.30, 0.50, 0.1, 0.5);
    if (v < 0.65) return _map(v, 0.50, 0.65, 0.5, 0.85);
    return _map(v, 0.65, 1.0, 0.85, 1.0);
  }

  double _map(double v, double inMin, double inMax, double outMin, double outMax) {
    final t = ((v - inMin) / (inMax - inMin)).clamp(0.0, 1.0);
    return outMin + (outMax - outMin) * t;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 120,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Icon(Icons.remove_red_eye_outlined,
              color: ClearBridgeColors.silverBright, size: 18),
          SizedBox(
            width: 10,
            height: 80,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: _fillFraction),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              builder: (context, fill, _) {
                return Container(
                  decoration: BoxDecoration(
                    color: ClearBridgeColors.steelMuted,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: fill.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              ClearBridgeColors.silver,
                              ClearBridgeColors.silverBright,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Text('Focus',
              style: ClearBridgeTypography.label.copyWith(
                fontSize: 10,
                color: ClearBridgeColors.silverDim,
              )),
        ],
      ),
    );
  }
}
