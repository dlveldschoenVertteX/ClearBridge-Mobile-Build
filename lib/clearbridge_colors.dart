import 'package:flutter/material.dart';

class ClearBridgeColors {
  ClearBridgeColors._();

  // Surfaces
  static const Color void_ = Color(0xFF0B0F1A);
  static const Color navy = Color(0xFF111827);
  static const Color steel = Color(0xFF172340);
  static const Color rim = Color(0xFF1E2D45);
  static const Color midBlue = Color(0xFF0F2044);  // section headers, capture overlay panels

  // Brand — Cyan
  static const Color cyan = Color(0xFF00BFFF);
  static const Color cyanMuted = Color(0x2600BFFF);
  static const Color cyanBorder = Color(0x4500BFFF);

  // Brand — Gold
  static const Color gold = Color(0xFFC9A84C);
  static const Color goldLight = Color(0xFFE8C96A);
  static const Color goldDark = Color(0xFF9A6E20);
  static const Color goldMuted = Color(0x26C9A84C);
  static const Color goldBorder = Color(0x45C9A84C);

  // Brand — Blue
  static const Color blueDark = Color(0xFF1E88E5);
  static const Color blueDeep = Color(0xFF1565C0);
  static const Color blueDeep2 = Color(0xFF0D47A1);
  static const Color blueBright = Color(0xFF4A9FE6);
  static const Color blueMuted = Color(0x1A1565C0);

  // Text
  static const Color silverBright = Color(0xFFE2E8F0);
  static const Color silver = Color(0xFFB5BCC4);       // --cb-silver
  static const Color silverDim = Color(0xFF7A8089);
  static const Color silverDimAlt = Color(0xFF7A8089); // alias, kept for compat

  // Steel text (on light surfaces)
  static const Color steelText = Color(0xFFB5BCC4);
  static const Color steelBorder = Color(0x45B5BCC4);
  static const Color steelMuted = Color(0x26B5BCC4);

  // Card surfaces
  static const Color cardBg = Color(0x99172340);       // rgba(23,35,64,0.6)
  static const Color cardBorder = Color(0x1EB5BCC4);   // rgba(181,188,196,0.12)

  // Semantic
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF97316);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF00BFFF);

  // MAC 3D capture — Unity lock-green for angle-meter lock + progress dots.
  static const Color captureLock = Color(0xFF00FF88);

  // Gradients
  static const LinearGradient gradPrimary = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00BFFF), Color(0xFF1E88E5)],
  );

  static const LinearGradient gradSuccess = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF16A34A), Color(0xFF22C55E)],
  );

  static const LinearGradient gradWarning = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF97316), Color(0xFFFB923C)],
  );

  static const LinearGradient gradGold = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE6CB8A), Color(0xFFC9A55A)],
  );
}
