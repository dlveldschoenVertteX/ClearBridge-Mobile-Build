import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Branded splash shown for a beat on cold start, then hands off into the
/// user-details/POPIA screen. Tap anywhere to skip.
///
/// Logo + reveal beats (fade/scale-in badge, "BIOMETRIC IDENTITY" tagline)
/// match the refined brand assets provided 2026-07-20 (`app_logo.png`
/// replaced with the higher-fidelity circular badge render). The source
/// reference was a ~13s animated marketing reveal (logo -> scanning-
/// fingerprint sweep with a percentage counter -> "Police clearance in
/// 2-5 hours" tagline) -- deliberately NOT reproduced verbatim here, since
/// that runs far longer than an app-launch splash should ever block a cold
/// start. This keeps the same visual beats (badge reveal, tagline, brand
/// wordmark) condensed into a couple of seconds instead.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  Timer? _timer;
  bool _done = false;
  late final AnimationController _anim;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _taglineOpacity;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _logoScale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutBack),
    );
    _logoOpacity = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    );
    _taglineOpacity = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.45, 1.0, curve: Curves.easeOut),
    );
    _anim.forward();
    _timer = Timer(const Duration(milliseconds: 2200), _go);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _anim.dispose();
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
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, child) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Opacity(
                    opacity: _taglineOpacity.value,
                    child: Text(
                      'BIOMETRIC IDENTITY',
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: ClearBridgeColors.cyan,
                        letterSpacing: 3.0,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Opacity(
                    opacity: _logoOpacity.value,
                    child: Transform.scale(
                      scale: _logoScale.value,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size =
                              (constraints.maxWidth * 0.4).clamp(100.0, 180.0);
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
                    ),
                  ),
                  const SizedBox(height: 24),
                  Opacity(
                    opacity: _taglineOpacity.value,
                    child: Text(
                      'ClearBridge Beta',
                      style: GoogleFonts.manrope(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: ClearBridgeColors.silverBright,
                        letterSpacing: -0.02,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Opacity(
                    opacity: _taglineOpacity.value,
                    child: Text(
                      'Police clearance reimagined',
                      style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ClearBridgeColors.silverDim,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
