import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.

class CbProgressDots extends StatelessWidget {
  const CbProgressDots({super.key, required this.total, required this.current});

  final int total;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final active = i == current;
        final done = i < current;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: active ? 20 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: active || done
                  ? ClearBridgeColors.cyan
                  : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      }),
    );
  }
}
