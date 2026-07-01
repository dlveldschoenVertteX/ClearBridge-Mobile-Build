import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'clearbridge_colors.dart';
import 'clearbridge_typography.dart';

class AppTheme {
  static ThemeData get darkTheme {
    final manropeFamily = GoogleFonts.manrope().fontFamily;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ClearBridgeColors.void_,
      fontFamily: manropeFamily,
      colorScheme: const ColorScheme.dark(
        primary: ClearBridgeColors.cyan,
        secondary: ClearBridgeColors.gold,
        surface: ClearBridgeColors.navy,
        error: ClearBridgeColors.error,
        onPrimary: Colors.white,
        onSurface: ClearBridgeColors.silverBright,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: ClearBridgeColors.silverBright),
        titleTextStyle: ClearBridgeTypography.h2,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0x0AFFFFFF), // rgba(255,255,255,0.04)
        floatingLabelBehavior: FloatingLabelBehavior.always,
        floatingLabelStyle: ClearBridgeTypography.label.copyWith(
          fontSize: 10,
          color: ClearBridgeColors.silverDim,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.05,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Color(0x14FFFFFF),
            width: 1.5,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Color(0x14FFFFFF),
            width: 1.5,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: ClearBridgeColors.cyan,
            width: 1.5,
          ),
        ),
        hintStyle: ClearBridgeTypography.body.copyWith(
          color: ClearBridgeColors.silverDim,
        ),
        contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ClearBridgeColors.cyan,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: ClearBridgeTypography.h3.copyWith(color: Colors.white),
        ),
      ),
      dividerColor: ClearBridgeColors.rim,
      cardColor: ClearBridgeColors.cardBg,
      cardTheme: CardThemeData(
        color: ClearBridgeColors.cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: ClearBridgeColors.cardBorder),
        ),
        elevation: 0,
      ),
      textTheme: TextTheme(
        headlineLarge: ClearBridgeTypography.display,
        headlineMedium: ClearBridgeTypography.h2,
        headlineSmall: ClearBridgeTypography.h3,
        bodyLarge: ClearBridgeTypography.body,
        bodyMedium: ClearBridgeTypography.body,
        bodySmall: ClearBridgeTypography.caption,
        labelLarge: ClearBridgeTypography.label,
        labelSmall: ClearBridgeTypography.label,
      ),
    );
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: ClearBridgeColors.cyan,
        brightness: Brightness.light,
      ),
    );
  }

  // Legacy aliases retained for widgets not yet migrated to design-system v2
  static const Color backgroundColor = ClearBridgeColors.void_;
  static const Color primaryBackground = ClearBridgeColors.void_;
  static const Color surfaceColor = ClearBridgeColors.navy;
  static const Color primaryColor = ClearBridgeColors.cyan;
  static const Color accentColor = ClearBridgeColors.cyan;
  static const Color tealGradientStart = ClearBridgeColors.cyan;
  static const Color successColor = ClearBridgeColors.success;
  static const Color errorColor = ClearBridgeColors.error;
  static const Color textSecondaryColor = ClearBridgeColors.silverDim;
  static const Color borderColor = ClearBridgeColors.cardBorder;
  static const LinearGradient surfaceGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ClearBridgeColors.void_, ClearBridgeColors.navy],
  );
  static const LinearGradient tealGradient = ClearBridgeColors.gradPrimary;
}
