import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'clearbridge_colors.dart';

class ClearBridgeTypography {
  ClearBridgeTypography._();

  static TextStyle get display => GoogleFonts.manrope(
        fontSize: 36,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.02,
        color: ClearBridgeColors.silverBright,
        height: 1.1,
      );

  static TextStyle get h1 => GoogleFonts.manrope(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.01,
        color: ClearBridgeColors.silverBright,
        height: 1.2,
      );

  // Backward-compat alias — now points to display (not h1)
  static TextStyle get heroText => display;

  static TextStyle get h2 => GoogleFonts.manrope(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.01,
        color: ClearBridgeColors.silverBright,
      );

  static TextStyle get h3 => GoogleFonts.manrope(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: ClearBridgeColors.silverBright,
      );

  static TextStyle get body => GoogleFonts.manrope(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: ClearBridgeColors.silver,
        height: 1.5,
      );

  static TextStyle get caption => GoogleFonts.manrope(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: ClearBridgeColors.silverDim,
        letterSpacing: 0.04,
      );

  static TextStyle get eyebrow => GoogleFonts.manrope(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: ClearBridgeColors.cyan,
        letterSpacing: 0.18,
      );

  static TextStyle get mono {
    try {
      return GoogleFonts.jetBrainsMono(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.02,
        color: ClearBridgeColors.silverDim,
      );
    } catch (_) {
      return GoogleFonts.sourceCodePro(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.02,
        color: ClearBridgeColors.silverDim,
      );
    }
  }

  static TextStyle get label => GoogleFonts.manrope(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.08,
        color: ClearBridgeColors.silverDim,
      );

}
