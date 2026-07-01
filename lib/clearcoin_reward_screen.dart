import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';

class ClearCoinRewardScreen extends StatefulWidget {
  const ClearCoinRewardScreen({super.key});

  @override
  State<ClearCoinRewardScreen> createState() => _ClearCoinRewardScreenState();
}

class _ClearCoinRewardScreenState extends State<ClearCoinRewardScreen>
    with TickerProviderStateMixin {
  late final AnimationController _spinCtrl;
  late final Animation<double> _spinAnim;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  bool _settled = false;
  bool _showContent = false;
  bool _copied = false;
  String _referralCode = '';

  @override
  void initState() {
    super.initState();

    // 3D coin spin: rotate Y 360° → land flat (1.9s, cubic ease-out)
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
    _spinAnim = Tween<double>(begin: 2 * math.pi, end: 0.0).animate(
      CurvedAnimation(
        parent: _spinCtrl,
        curve: const Cubic(0.15, 0.85, 0.25, 1.0),
      ),
    );
    _spinCtrl.forward().then((_) {
      if (!mounted) return;
      setState(() => _settled = true);
      _pulseCtrl.repeat(reverse: true);
    });

    // Settled pulse glow (scale 1.0→1.06, 2.4s)
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Content fades in after 900ms
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showContent = true);
    });

    _loadReferralCode();
  }

  Future<void> _loadReferralCode() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final code = doc.data()?['referralCode'] as String? ?? '';
      if (mounted && code.isNotEmpty) setState(() => _referralCode = code);
    } catch (_) {}
  }

  void _copyCode() {
    if (_referralCode.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _referralCode));
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header eyebrow
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'CLEARCOINS · REWARDS',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.manrope(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: ClearBridgeColors.gold,
                    letterSpacing: 0.20,
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Coin + ground glow
              SizedBox(
                height: 160,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    // Ground glow — appears after settle
                    if (_settled)
                      Positioned(
                        bottom: 0,
                        child: AnimatedBuilder(
                          animation: _pulseAnim,
                          builder: (_, __) => Opacity(
                            opacity: (_pulseAnim.value - 1.0) * 10 + 0.6,
                            child: Container(
                              width: 110,
                              height: 18,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(100),
                                gradient: RadialGradient(
                                  colors: [
                                    ClearBridgeColors.gold
                                        .withValues(alpha: 0.50),
                                    ClearBridgeColors.gold
                                        .withValues(alpha: 0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // Coin disc
                    Positioned(
                      top: 0,
                      child: AnimatedBuilder(
                        animation:
                            _settled ? _pulseAnim : _spinCtrl,
                        builder: (_, child) {
                          if (_settled) {
                            return Transform.scale(
                              scale: _pulseAnim.value,
                              child: child,
                            );
                          }
                          return Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.identity()
                              ..setEntry(3, 2, 0.001)
                              ..rotateY(_spinAnim.value),
                            child: child,
                          );
                        },
                        child: _CoinDisc(settled: _settled),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // +10 ClearCoins headline
              AnimatedOpacity(
                opacity: _showContent ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 550),
                child: AnimatedSlide(
                  offset:
                      _showContent ? Offset.zero : const Offset(0, 0.08),
                  duration: const Duration(milliseconds: 550),
                  curve: Curves.easeOut,
                  child: Column(
                    children: [
                      Text(
                        '+10 ClearCoins',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.manrope(
                          fontSize: 44,
                          fontWeight: FontWeight.w900,
                          color: ClearBridgeColors.gold,
                          letterSpacing: -0.03,
                          height: 1.0,
                          shadows: [
                            Shadow(
                              color: ClearBridgeColors.gold
                                  .withValues(alpha: 0.35),
                              blurRadius: 40,
                            ),
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
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // R10 cashback card
              AnimatedOpacity(
                opacity: _showContent ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 550),
                child: Container(
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
                    border: Border.all(
                        color: ClearBridgeColors.gold.withValues(alpha: 0.28)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color:
                              ClearBridgeColors.gold.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Icon(Icons.savings_rounded,
                            size: 24, color: ClearBridgeColors.gold),
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
                              'Your ClearCoins are applied automatically at checkout',
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
              ),

              const SizedBox(height: 12),

              // Referral section
              AnimatedOpacity(
                opacity: _showContent ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 550),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: ClearBridgeColors.steel.withValues(alpha: 0.70),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                        color: ClearBridgeColors.silverBright
                            .withValues(alpha: 0.10)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.group_add_rounded,
                              size: 18, color: ClearBridgeColors.cyan),
                          const SizedBox(width: 8),
                          Text(
                            'Refer a friend · earn together',
                            style: GoogleFonts.manrope(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: ClearBridgeColors.silverBright,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text.rich(
                        TextSpan(
                          style: ClearBridgeTypography.caption.copyWith(
                            height: 1.7,
                          ),
                          children: [
                            const TextSpan(
                              text:
                                  'Share your code below. When your referred friend completes their police clearance, ',
                            ),
                            TextSpan(
                              text: 'you both earn +5 ClearCoins',
                              style: ClearBridgeTypography.caption.copyWith(
                                fontWeight: FontWeight.w700,
                                color: ClearBridgeColors.gold,
                              ),
                            ),
                            const TextSpan(
                                text: ' — that\'s R5 off for each of you.'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: ClearBridgeColors.cyan
                                    .withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: ClearBridgeColors.cyan
                                        .withValues(alpha: 0.22)),
                              ),
                              child: Text(
                                _referralCode.isEmpty
                                    ? 'Loading...'
                                    : _referralCode,
                                style: ClearBridgeTypography.mono.copyWith(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: ClearBridgeColors.cyan,
                                  letterSpacing: 0.14,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _copyCode,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: _copied
                                    ? ClearBridgeColors.success
                                        .withValues(alpha: 0.14)
                                    : ClearBridgeColors.cyan
                                        .withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _copied
                                      ? ClearBridgeColors.success
                                          .withValues(alpha: 0.38)
                                      : ClearBridgeColors.cyan
                                          .withValues(alpha: 0.28),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _copied
                                        ? Icons.check
                                        : Icons.content_copy_rounded,
                                    size: 17,
                                    color: _copied
                                        ? ClearBridgeColors.success
                                        : ClearBridgeColors.cyan,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    _copied ? 'Copied!' : 'Copy',
                                    style: GoogleFonts.manrope(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: _copied
                                          ? ClearBridgeColors.success
                                          : ClearBridgeColors.cyan,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // Go to Dashboard CTA
              AnimatedOpacity(
                opacity: _showContent ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 550),
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () =>
                        context.go(AppConstants.dashboardRoute),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ClearBridgeColors.cyan,
                      foregroundColor: ClearBridgeColors.void_,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                    label: Text(
                      'Go to Dashboard',
                      style: GoogleFonts.manrope(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
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
  const _CoinDisc({required this.settled});
  final bool settled;

  @override
  Widget build(BuildContext context) {
    return Container(
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
        boxShadow: settled
            ? [
                BoxShadow(
                  color: ClearBridgeColors.gold.withValues(alpha: 0.12),
                  spreadRadius: 6,
                  blurRadius: 0,
                ),
                BoxShadow(
                  color: ClearBridgeColors.gold.withValues(alpha: 0.45),
                  blurRadius: 40,
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.28),
                  blurRadius: 8,
                  spreadRadius: -2,
                ),
              ]
            : [
                BoxShadow(
                  color: ClearBridgeColors.gold.withValues(alpha: 0.22),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Stack(
        children: [
          // Outer ridge ring
          Positioned.fill(
            child: Container(
              margin: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.30),
                  width: 2,
                ),
              ),
            ),
          ),
          // Inner ridge ring
          Positioned.fill(
            child: Container(
              margin: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                  width: 1,
                ),
              ),
            ),
          ),
          // Shine streak
          Positioned(
            top: 14,
            left: 22,
            child: Transform.rotate(
              angle: -0.314,
              child: Container(
                width: 28,
                height: 58,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x61FFFFFF),
                      Color(0x00FFFFFF),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ₡ Symbol
          Center(
            child: Text(
              '₡',
              style: GoogleFonts.manrope(
                fontSize: 54,
                fontWeight: FontWeight.w900,
                color: Colors.white.withValues(alpha: 0.90),
                letterSpacing: -0.04,
                height: 1.0,
                shadows: const [
                  Shadow(
                    color: Color(0x52000000),
                    blurRadius: 10,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
