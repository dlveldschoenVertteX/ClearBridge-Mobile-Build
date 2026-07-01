import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.

class CbInputField extends StatelessWidget {
  const CbInputField({
    super.key,
    required this.label,
    this.placeholder,
    this.controller,
    this.keyboardType,
    this.maxLength,
  });

  final String label;
  final String? placeholder;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ClearBridgeTypography.label),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLength: maxLength,
          style: ClearBridgeTypography.body.copyWith(color: ClearBridgeColors.silverBright),
          decoration: InputDecoration(
            hintText: placeholder,
            hintStyle: ClearBridgeTypography.body.copyWith(color: ClearBridgeColors.silverDim),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.04),
            counterText: '',
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: ClearBridgeColors.cyan, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
