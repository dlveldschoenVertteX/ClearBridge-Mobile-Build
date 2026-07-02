import 'package:flutter/material.dart';

import 'capture_colors.dart';
import 'capture_typography.dart';

enum CaptureButtonVariant { primary, ghost }

/// Minimal package-local button — a trimmed copy of the host app's CbButton
/// covering only the variants the capture flow actually uses.
class CaptureButton extends StatelessWidget {
  const CaptureButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = CaptureButtonVariant.primary,
    this.leadingIcon,
  });

  final String label;
  final VoidCallback? onPressed;
  final CaptureButtonVariant variant;
  final IconData? leadingIcon;

  @override
  Widget build(BuildContext context) {
    final isPrimary = variant == CaptureButtonVariant.primary;
    final enabled = onPressed != null;

    Color fg;
    Gradient? gradient;
    Color? bg;
    BoxBorder? border;
    List<BoxShadow>? shadow;

    if (isPrimary) {
      gradient = enabled ? CaptureColors.gradPrimary : null;
      bg = enabled ? null : CaptureColors.cardBorder;
      fg = enabled ? Colors.white : CaptureColors.silverDim;
      shadow = enabled
          ? [
              BoxShadow(
                color: CaptureColors.cyan.withValues(alpha: 0.25),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ]
          : null;
    } else {
      bg = Colors.white.withValues(alpha: 0.04);
      fg = CaptureColors.silverBright;
      border = Border.all(color: Colors.white.withValues(alpha: 0.08));
    }

    return Opacity(
      opacity: enabled || !isPrimary ? 1 : 0.55,
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
              boxShadow: shadow,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (leadingIcon != null) ...[
                  Icon(leadingIcon, size: 18, color: fg),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: CaptureTypography.h3
                        .copyWith(color: fg, fontSize: 15, letterSpacing: 0.1),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
