import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Branded splash shown for a beat on cold start, then hands off into the
/// user-details/POPIA screen. Tap anywhere to skip.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onDone, this.onDiagnostics});

  final VoidCallback onDone;

  /// Hidden entry point: long-press the logo to open the device camera probe
  /// (Phase-0 diagnostic; see docs/CAPTURE_OPTIMIZATION_SCOPE.md). Optional so
  /// production builds can leave it unset.
  final VoidCallback? onDiagnostics;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1600), _go);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _go() {
    if (_done) return;
    _done = true;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: GestureDetector(
        onTap: _go,
        onLongPress: widget.onDiagnostics == null
            ? null
            : () {
                // Cancel auto-advance so the splash doesn't navigate away from
                // under the probe; leave _done false so a tap still continues
                // into the normal flow after the probe is popped.
                _timer?.cancel();
                widget.onDiagnostics!();
              },
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = (constraints.maxWidth * 0.4).clamp(100.0, 180.0);
                  return Image.asset(
                    'assets/images/app_logo.png',
                    width: size,
                    height: size,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.fingerprint,
                      size: size,
                      color: ClearBridgeColors.cyan,
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              Text(
                'ClearBridge Beta',
                style: GoogleFonts.manrope(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: ClearBridgeColors.silverBright,
                  letterSpacing: -0.02,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Police clearance reimagined',
                style: GoogleFonts.manrope(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ClearBridgeColors.silverDim,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
