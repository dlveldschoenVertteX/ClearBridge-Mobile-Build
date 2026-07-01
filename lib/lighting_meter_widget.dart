import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.
// value is 0.0-1.0 normalized brightness (see HybridCaptureService.meanLuma).

class LightingMeterWidget extends StatelessWidget {
  const LightingMeterWidget({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    final color = v < 0.3
        ? ClearBridgeColors.warning
        : v > 0.85
            ? ClearBridgeColors.warning
            : ClearBridgeColors.success;
    return SizedBox(
      width: 10,
      height: 120,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          FractionallySizedBox(
            heightFactor: v,
            widthFactor: 1,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
