import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Branded splash shown for a beat on cold start, then hands off into the
/// user-details/POPIA screen. Tap anywhere to skip.
///
/// Ported from the CTO's actual reference reveal (`ClearBridgeReveal.jsx`,
/// `Logo_background_refinement.zip`, 2026-07-22): logo entry -> a cyan
/// scan-line sweeps down the medallion revealing a green fingerprint layer
/// top-to-bottom in sync with a 0-100% counter -> a capture-confirm flash +
/// two expanding "verification" rings -> eyebrow label swaps
/// (BIOMETRIC IDENTITY -> SCANNING FINGERPRINT -> IDENTITY VERIFIED) ->
/// brief tagline. The reference plays this over 13s as a marketing/hero
/// animation; condensed here to ~4.7s (still noticeably longer/richer than
/// the first pass's plain 900ms fade+scale, which the CTO reported didn't
/// resemble the reference at all) since an app cold-start splash shouldn't
/// block that long, and the reference's later marketing copy rows (FOR THE
/// WORKER / BADGE row / etc.) are trimmed to a single tagline line -- the
/// actual animation MECHANIC (scan/reveal/percentage/rings) is what the
/// feedback was about, not the extra marketing text.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Total visual sequence length (seconds) -- scaled down from the
  // reference's 13s timeline, proportions preserved for the key beats.
  static const double _totalS = 4.7;
  // Extra hold after the sequence visually settles, before auto-continuing.
  static const double _holdS = 0.5;

  static const double _logoEntryStart = 0.15;
  static const double _logoEntryDur = 0.65;
  static const double _breatheStart = 0.85;

  static const double _scanStart = 0.95;
  static const double _scanEnd = 2.75;

  static const double _flashCenter = 2.82;
  static const double _flashHalfWidth = 0.22;
  static const double _ring1Start = 2.9;
  static const double _ring2Start = 3.12;
  static const double _ringDur = 0.85;

  static const double _eyebrow1In = 0.0, _eyebrow1Out = 1.05;
  static const double _eyebrow2In = 0.95, _eyebrow2Out = 2.85;
  static const double _eyebrow3In = 2.75;

  static const double _taglineIn = 3.25;

  Timer? _timer;
  bool _done = false;
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_totalS * 1000).round()),
    );
    _anim.forward();
    _timer = Timer(
      Duration(milliseconds: ((_totalS + _holdS) * 1000).round()),
      _go,
    );
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

  static double _alphaIO(double t, double inS, double? outS,
      {double fadeIn = 0.35, double fadeOut = 0.35}) {
    if (t < inS) return 0;
    if (t < inS + fadeIn) {
      return Curves.easeOut.transform(((t - inS) / fadeIn).clamp(0.0, 1.0));
    }
    if (outS != null && t > outS) {
      return (1 - (t - outS) / fadeOut).clamp(0.0, 1.0);
    }
    return 1;
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
            final t = _anim.value * _totalS;
            return _buildScene(t);
          },
        ),
      ),
    );
  }

  Widget _buildScene(double t) {
    // Logo entry: easeOutBack scale-in + fade, then a subtle idle breathe.
    final entryP = ((t - _logoEntryStart) / _logoEntryDur).clamp(0.0, 1.0);
    final entryS = Curves.easeOutBack.transform(entryP);
    final opacity = ((t - _logoEntryStart) / 0.5).clamp(0.0, 1.0);
    final breathe =
        t > _breatheStart ? 0.012 * math.sin((t - _breatheStart) * 1.1) : 0.0;
    final scale = 0.74 + 0.26 * entryS + breathe;

    // Scan-line fingerprint reveal (top-to-bottom, matching the reference's
    // clipPath inset).
    final scanP = ((t - _scanStart) / (_scanEnd - _scanStart)).clamp(0.0, 1.0);
    final reveal = Curves.easeInOutSine.transform(scanP);
    final scanActive = t > _scanStart - 0.05 && t < _scanEnd + 0.3;
    final showPct = t > _scanStart + 0.05 && t < _scanEnd + 0.25;

    // Capture-confirm flash + verification rings.
    final flash =
        (1 - ((t - _flashCenter).abs() / _flashHalfWidth)).clamp(0.0, 1.0) *
            0.65;
    final verifyGlow = ((t - _flashCenter) / 1.2).clamp(0.0, 1.0);

    const logoSize = 176.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Ambient glow behind the medallion, intensifying once "verified".
        Center(
          child: Container(
            width: logoSize * 2.6,
            height: logoSize * 2.6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  ClearBridgeColors.cyan
                      .withValues(alpha: 0.09 + 0.16 * verifyGlow),
                  ClearBridgeColors.cyan.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Eyebrow label stack -- only one is ever actually visible at a
            // time (their fade windows are sequential, not overlapping).
            SizedBox(
              height: 20,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _eyebrow(t, _eyebrow1In, _eyebrow1Out, 'BIOMETRIC IDENTITY',
                      ClearBridgeColors.cyan),
                  _eyebrow(t, _eyebrow2In, _eyebrow2Out,
                      'SCANNING FINGERPRINT', ClearBridgeColors.cyan),
                  _eyebrow(t, _eyebrow3In, null, 'IDENTITY VERIFIED',
                      const Color(0xFF22C55E)),
                ],
              ),
            ),
            const SizedBox(height: 22),

            // Medallion: base -> fingerprint reveal -> scan line -> flash ->
            // verification rings, all layered in the logo's own box so they
            // scale/fade together.
            Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: SizedBox(
                  width: logoSize,
                  height: logoSize,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      Image.asset(
                        'assets/images/cb-base-nofp.png',
                        width: logoSize,
                        height: logoSize,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.fingerprint,
                          size: logoSize,
                          color: ClearBridgeColors.cyan,
                        ),
                      ),
                      ClipRect(
                        clipper: _TopRevealClipper(reveal),
                        child: Image.asset(
                          'assets/images/cb-fp-masked.png',
                          width: logoSize,
                          height: logoSize,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                      if (scanActive)
                        Positioned(
                          top: (reveal * logoSize - 1.5).clamp(0.0, logoSize),
                          left: logoSize * 0.08,
                          right: logoSize * 0.08,
                          child: Container(
                            height: 3,
                            decoration: BoxDecoration(
                              color: ClearBridgeColors.cyan,
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: [
                                BoxShadow(
                                  color: ClearBridgeColors.cyan
                                      .withValues(alpha: 0.85),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (flash > 0)
                        Container(
                          width: logoSize * 0.84,
                          height: logoSize * 0.84,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                const Color(0xFF5FC873)
                                    .withValues(alpha: flash),
                                const Color(0xFF5FC873).withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      _verificationRing(t, _ring1Start, logoSize),
                      _verificationRing(t, _ring2Start, logoSize),
                    ],
                  ),
                ),
              ),
            ),

            if (showPct) ...[
              const SizedBox(height: 14),
              Text(
                '${(reveal * 100).round()}%',
                style: GoogleFonts.robotoMono(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: ClearBridgeColors.cyan,
                  letterSpacing: 2.0,
                ),
              ),
            ] else
              const SizedBox(height: 14 + 22 * 1.2),

            const SizedBox(height: 20),
            Opacity(
              opacity: _alphaIO(t, _taglineIn, null, fadeIn: 0.5),
              child: Transform.translate(
                offset: Offset(
                    0, (1 - _alphaIO(t, _taglineIn, null, fadeIn: 0.5)) * 12),
                child: Column(
                  children: [
                    Text(
                      'ClearBridge Beta',
                      style: GoogleFonts.manrope(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: ClearBridgeColors.silverBright,
                        letterSpacing: -0.02,
                      ),
                    ),
                    const SizedBox(height: 6),
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
          ],
        ),
      ],
    );
  }

  Widget _eyebrow(double t, double inS, double? outS, String text, Color color) {
    final a = _alphaIO(t, inS, outS);
    if (a <= 0) return const SizedBox.shrink();
    return Opacity(
      opacity: a,
      child: Transform.translate(
        offset: Offset(0, (1 - a) * 6),
        child: Text(
          text,
          style: GoogleFonts.robotoMono(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: 3.2,
          ),
        ),
      ),
    );
  }

  Widget _verificationRing(double t, double start, double logoSize) {
    final p = ((t - start) / _ringDur).clamp(0.0, 1.0);
    if (p <= 0 || p >= 1) return const SizedBox.shrink();
    final size = logoSize * (0.62 + 0.7 * p);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ClearBridgeColors.cyan.withValues(alpha: 0.7 * (1 - p)),
          width: 2,
        ),
      ),
    );
  }
}

/// Clips its child from the top down to `fraction` of its height -- the
/// Flutter equivalent of the reference's `clipPath: inset(0 0 (1-p)*100% 0)`
/// top-to-bottom reveal.
class _TopRevealClipper extends CustomClipper<Rect> {
  const _TopRevealClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width, size.height * fraction.clamp(0.0, 1.0));

  @override
  bool shouldReclip(_TopRevealClipper oldClipper) =>
      oldClipper.fraction != fraction;
}
