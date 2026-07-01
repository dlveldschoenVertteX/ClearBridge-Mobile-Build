import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.

enum PillVariant { cyan, gold, green, orange, gray }

class CbPill extends StatelessWidget {
  const CbPill({super.key, required this.label, this.variant = PillVariant.cyan});

  final String label;
  final PillVariant variant;

  Color get _color => switch (variant) {
        PillVariant.cyan => ClearBridgeColors.cyan,
        PillVariant.gold => ClearBridgeColors.gold,
        PillVariant.green => ClearBridgeColors.success,
        PillVariant.orange => ClearBridgeColors.warning,
        PillVariant.gray => ClearBridgeColors.silverDim,
      };

  @override
  Widget build(BuildContext context) {
    final c = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: ClearBridgeTypography.label.copyWith(color: c)),
    );
  }
}
