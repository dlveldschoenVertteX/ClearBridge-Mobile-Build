import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Final screen of the beta flow. Lets the tester either capture again or
/// exit the app entirely.
class BetaThankYouScreen extends StatelessWidget {
  const BetaThankYouScreen({super.key, required this.onCaptureAgain});

  final VoidCallback onCaptureAgain;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            children: [
              const Spacer(flex: 3),
              Image.asset(
                'assets/images/app_logo.png',
                width: 96,
                height: 96,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.fingerprint,
                  size: 96,
                  color: ClearBridgeColors.cyan,
                ),
              ),
              const SizedBox(height: 36),
              Text(
                'Thank You',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: ClearBridgeColors.silverBright,
                  letterSpacing: -0.02,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Thank you for taking part in the ClearBridge beta.\n'
                'Your capture helps us build a faster, fairer way\n'
                'to get your police clearance.',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ClearBridgeColors.silver,
                  height: 1.6,
                ),
              ),
              const Spacer(flex: 4),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: onCaptureAgain,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClearBridgeColors.cyan,
                    foregroundColor: ClearBridgeColors.void_,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  label: Text('Capture Again',
                      style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => SystemNavigator.pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ClearBridgeColors.silverBright,
                    side: BorderSide(color: ClearBridgeColors.silverBright.withValues(alpha: 0.24)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.logout_rounded, size: 20),
                  label: Text('Exit',
                      style: GoogleFonts.manrope(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
