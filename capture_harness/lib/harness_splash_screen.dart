import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart';

/// Branded splash shown for a beat on cold start, then hands off straight
/// into the MAC3D capture flow -- no intermediate "Start capture" screen.
class HarnessSplashScreen extends StatefulWidget {
  const HarnessSplashScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<HarnessSplashScreen> createState() => _HarnessSplashScreenState();
}

class _HarnessSplashScreenState extends State<HarnessSplashScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1300), widget.onDone);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = (constraints.maxWidth * 0.45).clamp(120.0, 220.0);
            return Image.asset(
              'assets/images/app_logo.png',
              width: size,
              height: size,
              errorBuilder: (_, __, ___) => const Text(
                'ClearBridge',
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            );
          },
        ),
      ),
    );
  }
}
