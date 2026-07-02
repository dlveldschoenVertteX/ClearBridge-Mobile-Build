import 'package:flutter/material.dart';

/// Package-local color palette for the capture UI. Mirrors the host app's
/// brand colors at the time this package was extracted — kept as its own
/// copy (rather than importing the app's design system) so this package has
/// zero dependency on any specific host app and can be tweaked independently.
class CaptureColors {
  CaptureColors._();

  // Surfaces
  static const Color void_ = Color(0xFF0B0F1A);
  static const Color steel = Color(0xFF172340);

  // Brand — Cyan
  static const Color cyan = Color(0xFF00BFFF);
  static const Color cyanMuted = Color(0x2600BFFF);
  static const Color cyanBorder = Color(0x4500BFFF);

  // Brand — Gold
  static const Color gold = Color(0xFFC9A84C);

  // Brand gradient (primary button)
  static const LinearGradient gradPrimary = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00BFFF), Color(0xFF1E88E5)],
  );

  // Text
  static const Color silverBright = Color(0xFFE2E8F0);
  static const Color silver = Color(0xFFB5BCC4);
  static const Color silverDim = Color(0xFF7A8089);

  // Card / panel surfaces
  static const Color cardBg = Color(0x99172340);
  static const Color cardBorder = Color(0x1EB5BCC4);
  static const Color steelBorder = Color(0x45B5BCC4);
  static const Color steelMuted = Color(0x26B5BCC4);

  // Semantic
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF97316);
  static const Color error = Color(0xFFEF4444);
}
