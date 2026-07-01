import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';

// ---------------------------------------------------------------------------
// Placeholder reconstruction — this file was not present in the uploaded
// source tree (see missing-files list). Rebuilt to match the API every call
// site in this repo already expects (label/icon/onPressed/isLoading, plus
// .ghost() and .danger() variants). Replace with the original design-system
// component when available.
// ---------------------------------------------------------------------------

enum _CbPrimaryButtonVariant { primary, ghost, danger }

class CbPrimaryButton extends StatelessWidget {
  const CbPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.isLoading = false,
  }) : _variant = _CbPrimaryButtonVariant.primary;

  const CbPrimaryButton.ghost({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.isLoading = false,
  }) : _variant = _CbPrimaryButtonVariant.ghost;

  const CbPrimaryButton.danger({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.isLoading = false,
  }) : _variant = _CbPrimaryButtonVariant.danger;

  final String label;
  final Widget? icon;
  final VoidCallback? onPressed;
  final bool isLoading;
  final _CbPrimaryButtonVariant _variant;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading;

    Color fg;
    Gradient? gradient;
    Color? bg;
    BoxBorder? border;

    switch (_variant) {
      case _CbPrimaryButtonVariant.primary:
        gradient = enabled ? ClearBridgeColors.gradPrimary : null;
        bg = enabled ? null : ClearBridgeColors.cardBorder;
        fg = enabled ? Colors.white : ClearBridgeColors.silverDim;
        break;
      case _CbPrimaryButtonVariant.ghost:
        bg = Colors.white.withValues(alpha: 0.04);
        fg = ClearBridgeColors.silverBright;
        border = Border.all(color: Colors.white.withValues(alpha: 0.08));
        break;
      case _CbPrimaryButtonVariant.danger:
        bg = ClearBridgeColors.error.withValues(alpha: 0.08);
        fg = ClearBridgeColors.error;
        border = Border.all(color: ClearBridgeColors.error.withValues(alpha: 0.5), width: 1.5);
        break;
    }

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onPressed : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            decoration: BoxDecoration(
              gradient: gradient,
              color: bg,
              borderRadius: BorderRadius.circular(16),
              border: border,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isLoading)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                else ...[
                  if (icon != null) ...[
                    IconTheme(data: IconThemeData(size: 18, color: fg), child: icon!),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: ClearBridgeTypography.h3.copyWith(
                          color: fg, fontSize: 15, letterSpacing: 0.1),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
