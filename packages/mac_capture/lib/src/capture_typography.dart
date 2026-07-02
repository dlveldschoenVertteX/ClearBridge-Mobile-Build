import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'capture_colors.dart';

/// Package-local text styles for the capture UI — see [CaptureColors] for
/// why this is a standalone copy rather than an import of the host app's
/// design system.
class CaptureTypography {
  CaptureTypography._();

  static TextStyle get h2 => GoogleFonts.manrope(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.01,
        color: CaptureColors.silverBright,
      );

  static TextStyle get h3 => GoogleFonts.manrope(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: CaptureColors.silverBright,
      );

  static TextStyle get body => GoogleFonts.manrope(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: CaptureColors.silver,
        height: 1.5,
      );

  static TextStyle get label => GoogleFonts.manrope(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.08,
        color: CaptureColors.silverDim,
      );
}
