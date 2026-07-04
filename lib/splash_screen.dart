import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/auth_provider.dart';

/// Animated "biometric scan" splash, ported from the ClearBridge Splash
/// Claude Design file (ClearBridge_Splash.dc.html).
///
/// `cb-base-nofp.png` (medallion ring/tower art) is used for both the static
/// center and the rotating ring, via the same two radial-gradient masks the
/// CSS used (replicated here with [ShaderMask] + [RadialGradient] — Flutter's
/// direct equivalent of `mask-image: radial-gradient(...)`). `cb-fp-masked.png`
/// (the fingerprint revealed by the scan) is layered on top and clipped
/// top-to-bottom in sync with the scan line. Both are the real design assets.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  bool _hasNavigated = false;
  Timer? _fallbackTimer;

  // Curves ported 1:1 from the CSS cubic-bezier() functions.
  static const _easeOutSoft = Cubic(0.2, 0.8, 0.2, 1.0);
  static const _easeInOutSharp = Cubic(0.37, 0.0, 0.63, 1.0);
  static const _ringDecelerate = Cubic(0.22, 0.0, 0.36, 1.0);

  static const _cyan = Color(0xFF00BFFF);
  static const _green = Color(0xFF22C55E);
  static const _flashGreen = Color(0xFF5FC873);
  static const _gold = Color(0xFFC9A84C);
  static const _textDim = Color(0xFFA7AFB9);
  static const _textMid = Color(0xFFB5BCC4);
  static const _textBright = Color(0xFFC6CDD6);
  static const _badgeText = Color(0xFFDFF1FF);
  static const _tapDim = Color(0xFF7A8089);
  static const _digitalBlue = Color(0xFF2E9FE0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (mounted) setState(() => _elapsed = elapsed);
    })..start();

    // Full intro settles by ~5.75s; give it a generous safety-net window
    // before force-navigating in case the user doesn't tap.
    _fallbackTimer = Timer(const Duration(seconds: 14), _navigateToNextScreen);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fallbackTimer?.cancel();
    super.dispose();
  }

  double get _t => _elapsed.inMilliseconds / 1000.0;

  void _navigateToNextScreen() {
    if (_hasNavigated) return;
    if (kIsWeb) {
      final path = Uri.base.path;
      if (path.startsWith('/admin')) return;
    }
    _hasNavigated = true;
    final authState = ref.read(authProvider);
    final user = authState.valueOrNull;
    if (user == null) {
      context.go(AppConstants.loginRoute);
    } else {
      context.go(AppConstants.dashboardRoute);
    }
  }

  // ── Animation-timeline helpers (ported from the CSS @keyframes) ──────────

  double _progress(double delay, double dur, [Curve curve = Curves.linear]) {
    if (dur <= 0) return _t >= delay ? 1.0 : 0.0;
    final raw = ((_t - delay) / dur).clamp(0.0, 1.0);
    return curve.transform(raw);
  }

  /// cb-rise: fades/slides in over 0.6s, then holds (CSS `both` fill mode).
  double _riseOpacity(double delay) => _progress(delay, 0.6, _easeOutSoft);
  double _riseDy(double delay) => 14 * (1 - _riseOpacity(delay));

  /// cb-flashText: fades in (14%), holds, fades out (last 18%). Used for the
  /// eyebrow status text that cycles through phases.
  ({double opacity, double dy}) _flashText(double delay, double dur) {
    if (_t < delay) return (opacity: 0, dy: 6);
    if (_t > delay + dur) return (opacity: 0, dy: -4);
    final local = (_t - delay) / dur;
    if (local < 0.14) {
      final p = _easeOutSoft.transform(local / 0.14);
      return (opacity: p, dy: 6 * (1 - p));
    } else if (local < 0.82) {
      return (opacity: 1, dy: 0);
    } else {
      final p = (local - 0.82) / 0.18;
      return (opacity: 1 - p, dy: -4 * p);
    }
  }

  /// cb-pctFade: fades in (14%), holds, fades out (last 14%).
  double _pctFadeOpacity(double delay, double dur) {
    if (_t < delay || _t > delay + dur) return 0;
    final local = (_t - delay) / dur;
    if (local < 0.14) return _easeOutSoft.transform(local / 0.14);
    if (local < 0.86) return 1;
    return 1 - (local - 0.86) / 0.14;
  }

  /// cb-greenFlash: quick punch-in (26%), long fade-out.
  double _greenFlashOpacity(double delay, double dur) {
    if (_t < delay || _t > delay + dur) return 0;
    final local = (_t - delay) / dur;
    if (local < 0.26) return 0.85 * (local / 0.26);
    return 0.85 * (1 - (local - 0.26) / 0.74);
  }

  /// cb-ringLockGlow: fades in (30%), settles to a dim hold.
  double _ringLockGlowOpacity(double delay, double dur) {
    if (_t < delay) return 0;
    final local = ((_t - delay) / dur).clamp(0.0, 1.0);
    if (local < 0.3) return local / 0.3;
    return 1 - 0.7 * ((local - 0.3) / 0.7);
  }

  /// cb-ambient-style ping-pong oscillation: 0 at phase 0/1, 1 at phase 0.5.
  double _oscillate(double period, {double startAt = 0}) {
    final active = math.max(0.0, _t - startAt);
    final x = (active % period) / period;
    return (1 - math.cos(2 * math.pi * x)) / 2;
  }

  /// A repeating (non-ping-pong) ramp, e.g. the expanding fingerprint ring.
  double _ramp(double period, {double startAt = 0}) {
    final active = math.max(0.0, _t - startAt);
    return (active % period) / period;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      body: GestureDetector(
        onTap: _navigateToNextScreen,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.56),
              radius: 1.1,
              colors: [Color(0xFF142346), Color(0xFF0D1426), Color(0xFF0B0F1A)],
              stops: [0.0, 0.48, 1.0],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _ambientGlows(),
              _statusEyebrow(),
              _logoMedallion(),
              _scanPercentage(),
              _underLogoCluster(),
              _bottomStatus(),
              _tapToContinue(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ambientGlows() {
    final cyanPhase = _oscillate(4.5);
    final goldPhase = _oscillate(6.0);
    return Stack(
      children: [
        Align(
          alignment: const Alignment(0, -0.16),
          child: IgnorePointer(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: Opacity(
                opacity: 0.5 + 0.4 * cyanPhase,
                child: Transform.scale(
                  scale: 0.92 + 0.14 * cyanPhase,
                  child: Container(
                    width: 420,
                    height: 420,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          _cyan.withValues(alpha: 0.26),
                          _cyan.withValues(alpha: 0.08),
                          _cyan.withValues(alpha: 0),
                        ],
                        stops: const [0.0, 0.42, 0.70],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.14),
          child: IgnorePointer(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Opacity(
                opacity: 0.5 + 0.4 * goldPhase,
                child: Transform.scale(
                  scale: 0.92 + 0.14 * goldPhase,
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [_gold.withValues(alpha: 0.15), _gold.withValues(alpha: 0)],
                        stops: const [0.0, 0.64],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _monoLabel(String text, {required Color color, double size = 11}) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: FontWeight.w700,
        letterSpacing: size * 0.32,
        color: color,
      ),
    );
  }

  Widget _statusEyebrow() {
    final identity = _flashText(0.5, 1.4);
    final scanning = _flashText(1.7, 2.15);
    final verifiedOpacity = _riseOpacity(3.85);
    final verifiedDy = _riseDy(3.85);

    return Positioned(
      top: 172,
      left: 0,
      right: 0,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: identity.opacity,
            child: Transform.translate(
              offset: Offset(0, identity.dy),
              child: _monoLabel('BIOMETRIC IDENTITY', color: _cyan),
            ),
          ),
          Opacity(
            opacity: scanning.opacity,
            child: Transform.translate(
              offset: Offset(0, scanning.dy),
              child: _monoLabel('SCANNING FINGERPRINT', color: _cyan),
            ),
          ),
          Opacity(
            opacity: verifiedOpacity,
            child: Transform.translate(
              offset: Offset(0, verifiedDy),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.verified_user, color: _green, size: 15),
                  const SizedBox(width: 7),
                  _monoLabel('IDENTITY VERIFIED', color: _green),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logoMedallion() {
    const size = 240.0;

    // cb-logoRise: the whole medallion fades/rises/un-blurs in.
    final riseP = _progress(0.35, 1.2, _easeOutSoft);
    final riseOpacity = riseP;
    final riseDy = 16 * (1 - riseP);
    final riseScale = 0.84 + 0.16 * riseP;
    final riseBlur = 7 * (1 - riseP);

    // cb-logoFloat: gentle infinite bob, starts once the rise is done.
    final floatDy = -5 * _oscillate(6.0, startAt: 1.7);

    // cb-ringSpinStop: 720deg, decelerating to a dead stop (locked).
    final ringTurns = _progress(0.5, 3.2, _ringDecelerate) * 2; // 720deg = 2 turns

    // cb-fpReveal + cb-scanMove: synced top-down reveal & scan line.
    final revealP = _progress(1.7, 2.0, _easeInOutSharp);
    final scanDy = 240 * _progress(1.7, 2.0, _easeInOutSharp);
    double scanOpacity;
    {
      final local = ((_t - 1.7) / 2.0).clamp(0.0, 1.0);
      if (_t < 1.7 || _t > 3.7) {
        scanOpacity = 0;
      } else if (local < 0.07) {
        scanOpacity = local / 0.07;
      } else if (local < 0.93) {
        scanOpacity = 1;
      } else {
        scanOpacity = 1 - (local - 0.93) / 0.07;
      }
    }

    final greenFlash = _greenFlashOpacity(3.62, 0.7);
    final ringLockGlow = _ringLockGlowOpacity(3.65, 1.2);

    return Align(
      alignment: const Alignment(0, -0.16),
      child: Opacity(
        opacity: riseOpacity,
        child: Transform.translate(
          offset: Offset(0, riseDy + floatDy),
          child: Transform.scale(
            scale: riseScale,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: riseBlur, sigmaY: riseBlur),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: _cyan.withValues(alpha: 0.34),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Static inner medallion — masked to the inner ~83% radius.
                      ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (rect) => const RadialGradient(
                          colors: [Colors.black, Colors.black, Colors.transparent],
                          stops: [0.0, 0.83, 0.86],
                        ).createShader(rect),
                        child: Image.asset('assets/images/cb-base-nofp.png', fit: BoxFit.contain),
                      ),
                      // Rotating chrome ring — masked to a thin outer band only.
                      Transform.rotate(
                        angle: ringTurns * 2 * math.pi,
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (rect) => const RadialGradient(
                            colors: [
                              Colors.transparent,
                              Colors.black,
                              Colors.black,
                              Colors.transparent,
                            ],
                            stops: [0.82, 0.85, 0.98, 1.0],
                          ).createShader(rect),
                          child: Image.asset('assets/images/cb-base-nofp.png', fit: BoxFit.contain),
                        ),
                      ),
                      // Cyan glow as the ring locks into place.
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                Colors.transparent,
                                _cyan.withValues(alpha: 0.6 * ringLockGlow),
                                _cyan.withValues(alpha: 0.2 * ringLockGlow),
                                Colors.transparent,
                              ],
                              stops: const [0.79, 0.84, 0.92, 0.96],
                            ),
                          ),
                        ),
                      ),
                      // Fingerprint, revealed top-to-bottom by the scan.
                      ClipRect(
                        clipper: _TopDownClipper(revealP),
                        child: Image.asset('assets/images/cb-fp-masked.png', fit: BoxFit.contain),
                      ),
                      // Green capture-confirmation flash.
                      IgnorePointer(
                        child: Opacity(
                          opacity: greenFlash,
                          child: Container(
                            width: 200,
                            height: 200,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  _flashGreen.withValues(alpha: 0.9),
                                  _flashGreen.withValues(alpha: 0),
                                ],
                                stops: const [0.0, 0.68],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Scan line + trailing gradient.
                      if (scanOpacity > 0)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: Opacity(
                              opacity: scanOpacity,
                              child: Transform.translate(
                                offset: Offset(0, scanDy),
                                child: Column(
                                  children: [
                                    Container(height: 3, color: _cyan, margin: const EdgeInsets.symmetric(horizontal: size * 0.07)),
                                    Container(
                                      height: 54,
                                      margin: EdgeInsets.symmetric(horizontal: size * 0.08),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [_cyan.withValues(alpha: 0.22), _cyan.withValues(alpha: 0)],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _scanPercentage() {
    final opacity = _pctFadeOpacity(1.6, 2.3);
    final pct = (_progress(1.7, 2.0).clamp(0.0, 1.0) * 100).round();
    return Positioned(
      top: 490,
      left: 0,
      right: 0,
      child: Opacity(
        opacity: opacity,
        child: Text(
          '$pct%',
          textAlign: TextAlign.center,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.3,
            color: _cyan,
            shadows: [Shadow(color: _cyan.withValues(alpha: 0.6), blurRadius: 16)],
          ),
        ),
      ),
    );
  }

  Widget _fadeRiseLine(double delay, Widget child) {
    return Opacity(
      opacity: _riseOpacity(delay),
      child: Transform.translate(offset: Offset(0, _riseDy(delay)), child: child),
    );
  }

  Widget _underLogoCluster() {
    final dotOpacity = 0.35 + 0.65 * _oscillate(1.4);

    return Align(
      alignment: const Alignment(0, 0.24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fadeRiseLine(
            4.05,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 30, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, _textMid.withValues(alpha: 0.5)]))),
                const SizedBox(width: 12),
                Text('FOR THE WORKER', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 4, color: _textDim)),
                const SizedBox(width: 12),
                Container(width: 30, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [_textMid.withValues(alpha: 0.5), Colors.transparent]))),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _fadeRiseLine(
            4.25,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: _cyan.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(color: _cyan.withValues(alpha: 0.45)),
                    boxShadow: [BoxShadow(color: _cyan.withValues(alpha: 0.22), blurRadius: 14)],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: dotOpacity,
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: _cyan, boxShadow: [BoxShadow(color: _cyan.withValues(alpha: 0.9), blurRadius: 6)]),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text('BETA', style: GoogleFonts.manrope(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: _badgeText)),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('FAST', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.7, color: _textMid)),
                    const SizedBox(width: 14),
                    Container(width: 1, height: 12, color: _textMid.withValues(alpha: 0.28)),
                    const SizedBox(width: 14),
                    Text('SECURE', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.7, color: _textMid)),
                    const SizedBox(width: 14),
                    Container(width: 1, height: 12, color: _textMid.withValues(alpha: 0.28)),
                    const SizedBox(width: 14),
                    Text('DIGITAL', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.7, color: _digitalBlue)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _fadeRiseLine(
            4.45,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 46, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, _textMid.withValues(alpha: 0.45)]))),
                const SizedBox(width: 14),
                Text('POLICE CLEARANCE REIMAGINED', style: GoogleFonts.manrope(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 2.2, color: _textBright)),
                const SizedBox(width: 14),
                Container(width: 46, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [_textMid.withValues(alpha: 0.45), Colors.transparent]))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomStatus() {
    final fpScale = 1 + 0.16 * _oscillate(1.8);
    final ringLocal = _ramp(1.8);
    final ringScale = 0.7 + 1.0 * ringLocal;
    final ringOpacity = 0.55 * (1 - ringLocal);

    return Positioned(
      bottom: 62,
      left: 0,
      right: 0,
      child: _fadeRiseLine(
        4.75,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: ringOpacity,
                    child: Transform.scale(
                      scale: ringScale,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: _cyan.withValues(alpha: 0.6))),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: fpScale,
                    child: Icon(Icons.fingerprint, size: 20, color: _cyan, shadows: [Shadow(color: _cyan.withValues(alpha: 0.45), blurRadius: 7)]),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 9),
            Text('Ready for secure capture', style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: _textMid)),
          ],
        ),
      ),
    );
  }

  Widget _tapToContinue() {
    final pulseOpacity = _t >= 5.7 ? (0.3 + 0.55 * _oscillate(2.2, startAt: 5.7)) : 0.85;
    return Positioned(
      bottom: 32,
      left: 0,
      right: 0,
      child: _fadeRiseLine(
        5.15,
        Center(
          child: Opacity(
            opacity: pulseOpacity,
            child: Text(
              'TAP TO CONTINUE',
              style: GoogleFonts.manrope(fontSize: 10.5, fontWeight: FontWeight.w500, letterSpacing: 1.5, color: _tapDim),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopDownClipper extends CustomClipper<Rect> {
  _TopDownClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, size.height * fraction);

  @override
  bool shouldReclip(_TopDownClipper oldClipper) => oldClipper.fraction != fraction;
}
