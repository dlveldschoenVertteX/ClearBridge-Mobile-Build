import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge_beta/cb_primary_button.dart';
import 'package:clearbridge_beta/clearbridge_colors.dart';

/// ClearCoin reward screen shown right after a capture completes. Static
/// "+10 ClearCoins" celebration — the balance itself is awarded server-side
/// (Cloud Function, not client-writable) and isn't guaranteed to have landed
/// by the time this screen shows, so it doesn't try to read a live total.
class ClearCoinScreen extends StatefulWidget {
  const ClearCoinScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  State<ClearCoinScreen> createState() => _ClearCoinScreenState();
}

class _ClearCoinScreenState extends State<ClearCoinScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinCtrl;
  late final Animation<double> _spinAnim;
  bool _settled = false;
  bool _showContent = false;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
    _spinAnim = Tween<double>(begin: 2 * math.pi, end: 0.0).animate(
      CurvedAnimation(parent: _spinCtrl, curve: const Cubic(0.15, 0.85, 0.25, 1.0)),
    );
    _spinCtrl.forward().then((_) {
      if (mounted) setState(() => _settled = true);
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showContent = true);
    });
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Text(
                'CLEARCOINS · REWARDS',
                textAlign: TextAlign.center,
                style: GoogleFonts.manrope(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: ClearBridgeColors.gold,
                  letterSpacing: 0.20,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 140,
                child: AnimatedBuilder(
                  animation: _spinCtrl,
                  builder: (_, child) {
                    if (_settled) return child!;
                    return Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.001)
                        ..rotateY(_spinAnim.value),
                      child: child,
                    );
                  },
                  child: const _CoinDisc(),
                ),
              ),
              const SizedBox(height: 20),
              AnimatedOpacity(
                opacity: _showContent ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 550),
                child: Column(
                  children: [
                    Text(
                      '+10 ClearCoins',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.manrope(
                        fontSize: 40,
                        fontWeight: FontWeight.w900,
                        color: ClearBridgeColors.gold,
                        letterSpacing: -0.03,
                        shadows: [
                          Shadow(color: ClearBridgeColors.gold.withValues(alpha: 0.35), blurRadius: 36),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'earned for completing your fingerprint capture',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.manrope(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: ClearBridgeColors.silver,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            ClearBridgeColors.gold.withValues(alpha: 0.12),
                            ClearBridgeColors.gold.withValues(alpha: 0.04),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: ClearBridgeColors.gold.withValues(alpha: 0.28)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: ClearBridgeColors.gold.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: const Icon(Icons.savings_rounded, size: 24, color: ClearBridgeColors.gold),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Get R10 off your next clearance',
                                  style: GoogleFonts.manrope(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: ClearBridgeColors.goldLight,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Applied automatically when ClearBridge launches fully',
                                  style: GoogleFonts.manrope(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: ClearBridgeColors.silver,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(flex: 3),
              AnimatedOpacity(
                opacity: _showContent ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 550),
                child: CbPrimaryButton(
                  label: 'Continue',
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: widget.onContinue,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoinDisc extends StatelessWidget {
  const _CoinDisc();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 132,
        height: 132,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment(-0.7, -0.7),
            end: Alignment(0.7, 0.7),
            stops: [0.0, 0.40, 0.70, 1.0],
            colors: [
              Color(0xFFF5DC6A),
              Color(0xFFC9A84C),
              Color(0xFF9A6E20),
              Color(0xFFE8C96A),
            ],
          ),
          boxShadow: [
            BoxShadow(color: ClearBridgeColors.gold.withValues(alpha: 0.45), blurRadius: 40),
          ],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.30), width: 2),
                ),
              ),
            ),
            Center(
              child: Text(
                '₡',
                style: GoogleFonts.manrope(
                  fontSize: 54,
                  fontWeight: FontWeight.w900,
                  color: Colors.white.withValues(alpha: 0.90),
                  height: 1.0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
