import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_primary_button.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.

class ErrorDialog {
  ErrorDialog._();

  static Future<void> show({
    required BuildContext context,
    required String title,
    required String message,
    String buttonText = 'OK',
    VoidCallback? onPressed,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: ClearBridgeColors.navy,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ClearBridgeTypography.h2),
              const SizedBox(height: 12),
              Text(message, style: ClearBridgeTypography.body),
              const SizedBox(height: 24),
              CbPrimaryButton(
                label: buttonText,
                onPressed: () {
                  Navigator.of(context).pop();
                  onPressed?.call();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
