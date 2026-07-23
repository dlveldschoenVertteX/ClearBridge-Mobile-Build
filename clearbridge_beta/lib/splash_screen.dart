import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Branded splash shown for a beat on cold start, then hands off into the
/// user-details/POPIA screen. Tap anywhere to skip.
///
/// Full-fidelity port of the CTO's reference reveal (`ClearBridgeReveal.jsx`,
/// `Logo_background_refinement.zip`) -- every beat in the 13.0s reference is
/// reproduced here, uniformly scaled by exactly 0.5 (6.5s total instead of
/// 13.0s -- the CTO's one explicitly-approved change, "shorter duration,
/// that's the only change"), so relative proportions -- including the
/// reference's own long settled hold near the end -- are preserved exactly
/// rather than rushed into an arbitrary shorter budget.
///
/// A prior pass condensed this to 4.7s and dropped the entire under-logo
/// marketing stack (5 rows: "FOR THE WORKER", the BETA/FAST/SECURE/DIGITAL
/// badge row, "POLICE CLEARANCE REIMAGINED", "Ready for secure capture",
/// "Tap to continue") -- this pass restores all of it, plus several smaller
/// beats: the second (gold) ambient halo, both halos' blur, a separate
/// medallion under-glow, the capture "pop" scale bump, the green drop-shadow
/// glow that follows the fingerprint's own revealed silhouette (not a
/// bounding box), the scan line's soft trailing gradient band, the
/// verification rings' outer glow, the radial-gradient stage background, and
/// the full-screen vignette. Reuses the exact blur/badge/dash-line/pulsing-
/// icon Flutter *techniques* already proven working in the older, unrelated
/// root-level `lib/splash_screen.dart` (a different app target entirely) --
/// that file's own timings/copy are NOT the source of truth here, only its
/// widget technique; every beat's actual content/timing below is derived
/// directly from the JSX reference.
///
/// One approximation, noted rather than silently skipped: the reference's
/// capture-confirm flash uses CSS `mixBlendMode: screen`, which has no
/// direct sibling-blend-mode widget in Flutter without a custom
/// `CustomPainter`; plain alpha compositing is used instead (the visual
/// difference against this near-black background is minor).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Every timestamp below is the JSX reference's own value * (_totalS/13.0)
  // -- an exact uniform scale, not a re-tuned guess, so the relative
  // proportions between beats always match the reference precisely,
  // whatever _totalS is set to. Originally 6.5s (0.5x); extended to 9.0s
  // (CTO feedback 2026-07-23: "it's too fast right now") by rescaling every
  // beat below by 9.0/6.5, not by padding/re-tuning individual beats.
  static const double _totalS = 9.0;
  static const double _holdS = 0.554;
  // Converts this file's compressed-timeline `t` back to the original JSX
  // reference's own 13.0s timeline -- used by the few continuous (sin-
  // driven) animations below that are evaluated directly against the
  // reference's own formulas rather than as discrete in/out beats. Stays
  // correct automatically if _totalS is ever rescaled again.
  static const double _refTimeScale = 13.0 / _totalS;

  static const Color _digitalBlue = Color(0xFF2E9FE0);

  static const double _logoEntryStart = 0.485;
  static const double _logoEntryDur = 0.762;
  static const double _logoAppearDur = 0.381;
  static const double _breatheStart = 1.385;
  static const double _popStart = 3.358;
  static const double _popEnd = 3.842;

  static const double _scanStart = 1.904;
  static const double _scanEnd = 3.462;

  static const double _flashCenter = 3.545;
  static const double _flashHalfWidth = 0.291;
  static const double _ring1Start = 3.704;
  static const double _ring2Start = 3.925;
  static const double _ringDur = 0.727;

  static const double _eyebrow1In = 0.277, _eyebrow1Out = 1.765;
  static const double _eyebrow2In = 1.973, _eyebrow2Out = 3.496;
  static const double _eyebrow3In = 3.808, _eyebrow3Out = 5.885;

  static const double _pctIn = 1.973, _pctOut = 3.635;

  static const double _row1In = 4.085; // FOR THE WORKER
  static const double _row2In = 4.258; // BETA / FAST / SECURE / DIGITAL
  static const double _row3In = 4.465; // POLICE CLEARANCE REIMAGINED
  static const double _row4In = 4.708; // Ready for secure capture
  static const double _row5In = 5.019; // Tap to continue
  static const double _rowFadeIn = 0.346;

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
        child: Container(
          // Stage radial-gradient background (reference: circle at 50% 36%,
          // #16264d -> #0B0F1A at 72%) -- the prior pass used a flat color.
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.28),
              radius: 1.1,
              colors: [Color(0xFF16264D), ClearBridgeColors.void_],
              stops: [0.0, 0.72],
            ),
          ),
          child: AnimatedBuilder(
            animation: _anim,
            builder: (context, child) {
              final t = _anim.value * _totalS;
              return _buildScene(t, context);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildScene(double t, BuildContext context) {
    // Logo entry: easeOutBack scale-in + fade, idle breathe, and the
    // capture-moment "pop" -- all three additive terms exist in the
    // reference; the prior pass only had entry+breathe.
    final entryP = ((t - _logoEntryStart) / _logoEntryDur).clamp(0.0, 1.0);
    final entryS = Curves.easeOutBack.transform(entryP);
    final opacity = ((t - _logoEntryStart) / _logoAppearDur).clamp(0.0, 1.0);
    final breathe =
        t > _breatheStart ? 0.012 * math.sin((t - _breatheStart) * 2.2) : 0.0;
    final pop = (t > _popStart && t < _popEnd)
        ? math.sin((t - _popStart) / (_popEnd - _popStart) * math.pi) * 0.03
        : 0.0;
    final scale = 0.74 + 0.26 * entryS + breathe + pop;

    // Scan-line fingerprint reveal (top-to-bottom, matching the reference's
    // clipPath inset).
    final scanP = ((t - _scanStart) / (_scanEnd - _scanStart)).clamp(0.0, 1.0);
    final reveal = Curves.easeInOutSine.transform(scanP);
    final scanActive = t > _scanStart - 0.025 && t < _scanEnd + 0.175;
    final showPct = t > _pctIn && t < _pctOut;

    // Capture-confirm flash + verification rings + the glow that ramps in
    // once "verified" (drives both ambient halos and the medallion
    // under-glow, per the reference).
    final flash =
        (1 - ((t - _flashCenter).abs() / _flashHalfWidth)).clamp(0.0, 1.0) *
            0.6;
    final verifyGlow = ((t - _flashCenter) / 0.6).clamp(0.0, 1.0);

    const logoSize = 176.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Two ambient halos (cyan + gold), blurred, screen-relative --
        // distinct from the medallion under-glow below. The prior pass had
        // only one, unblurred halo tied to the medallion.
        _ambientHalo(
          color: ClearBridgeColors.cyan,
          size: logoSize * 1.92,
          opacity: 0.09 + 0.07 * verifyGlow,
          blurSigma: 10,
        ),
        _ambientHalo(
          color: ClearBridgeColors.gold,
          size: logoSize * 1.37,
          opacity: 0.10,
          blurSigma: 10,
        ),

        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Biases the whole stack toward the top of the screen (the
              // reference's logo box sits at ~39% down, not dead-center),
              // while staying scroll-safe on short screens now that the
              // marketing stack below adds real height.
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.08),

              // Eyebrow label stack -- only one is ever actually visible at
              // a time (their fade windows are sequential, not
              // overlapping).
              SizedBox(
                height: 20,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    _eyebrow(t, _eyebrow1In, _eyebrow1Out, 'BIOMETRIC IDENTITY',
                        ClearBridgeColors.cyan),
                    _eyebrow(t, _eyebrow2In, _eyebrow2Out,
                        'SCANNING FINGERPRINT', ClearBridgeColors.cyan),
                    _eyebrow(t, _eyebrow3In, _eyebrow3Out, 'IDENTITY VERIFIED',
                        ClearBridgeColors.success),
                  ],
                ),
              ),
              const SizedBox(height: 22),

              // Medallion: under-glow -> base -> fingerprint drop-shadow
              // glow -> fingerprint reveal -> scan line + trailing band ->
              // flash -> verification rings, all layered in the logo's own
              // box so they scale/fade together.
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
                        // Under-glow behind the medallion, intensifying once
                        // "verified" -- distinct from the two screen-level
                        // ambient halos above (reference: separate element,
                        // smaller radius, larger verifyGlow amplitude).
                        IgnorePointer(
                          child: ImageFiltered(
                            imageFilter: ImageFilter.blur(sigmaX: 6.5, sigmaY: 6.5),
                            child: Container(
                              width: logoSize * 1.4,
                              height: logoSize * 1.4,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    ClearBridgeColors.cyan
                                        .withValues(alpha: 0.08 + 0.30 * verifyGlow),
                                    ClearBridgeColors.cyan.withValues(alpha: 0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
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
                        // Green drop-shadow glow that follows the
                        // fingerprint's own revealed silhouette (CSS
                        // `filter: drop-shadow`, not a bounding-box glow) --
                        // a blurred copy tinted solid green via srcIn (which
                        // replaces color but keeps the source's own alpha
                        // shape), sitting under the crisp copy, same
                        // reveal-clip sync.
                        ClipRect(
                          clipper: _TopRevealClipper(reveal),
                          child: ImageFiltered(
                            imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                            child: ColorFiltered(
                              colorFilter: ColorFilter.mode(
                                ClearBridgeColors.success.withValues(alpha: 0.65),
                                BlendMode.srcIn,
                              ),
                              child: Image.asset(
                                'assets/images/cb-fp-masked.png',
                                width: logoSize,
                                height: logoSize,
                                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                              ),
                            ),
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
                        if (scanActive) ...[
                          // Soft trailing gradient band behind the hard
                          // scan line -- the prior pass only had the line.
                          Positioned(
                            top: (reveal * logoSize - 46).clamp(0.0, logoSize),
                            left: logoSize * 0.08,
                            right: logoSize * 0.08,
                            child: Container(
                              height: 46,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    ClearBridgeColors.cyan.withValues(alpha: 0),
                                    ClearBridgeColors.cyan.withValues(alpha: 0.20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: (reveal * logoSize - 1.5).clamp(0.0, logoSize),
                            left: logoSize * 0.07,
                            right: logoSize * 0.07,
                            child: Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color: ClearBridgeColors.cyan,
                                borderRadius: BorderRadius.circular(2),
                                boxShadow: [
                                  BoxShadow(
                                    color: ClearBridgeColors.cyan.withValues(alpha: 0.85),
                                    blurRadius: 10,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        // Capture-confirm flash. Approximates the
                        // reference's `mixBlendMode: screen` with plain
                        // alpha compositing (see class doc).
                        if (flash > 0)
                          Container(
                            width: logoSize * 0.84,
                            height: logoSize * 0.84,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xFF5FC873).withValues(alpha: flash),
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
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: ClearBridgeColors.cyan,
                    letterSpacing: 2.0,
                  ),
                ),
              ] else
                const SizedBox(height: 14 + 22 * 1.2),

              // Full under-logo marketing stack -- five rows, entirely
              // missing from the prior condensed pass (which only had a
              // plain two-line tagline). Content/order/copy taken directly
              // from the reference; widget technique reused from the
              // legacy root splash file.
              const SizedBox(height: 26),
              _marketingRow(t, _row1In, _forTheWorkerRow()),
              const SizedBox(height: 16),
              _marketingRow(t, _row2In, _badgeRow(t)),
              const SizedBox(height: 16),
              _marketingRow(t, _row3In, _reimaginedRow()),
              const SizedBox(height: 20),
              _marketingRow(t, _row4In, _readyRow(t)),
              const SizedBox(height: 14),
              _marketingRow(t, _row5In, _tapRow(t)),
            ],
          ),
        ),

        // Vignette -- drawn last, on top of everything, darkening the
        // edges. Entirely missing from the prior pass.
        IgnorePointer(
          child: Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.1),
                radius: 1.0,
                colors: [Colors.transparent, Color(0x73000000)],
                stops: [0.52, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _ambientHalo({
    required Color color,
    required double size,
    required double opacity,
    required double blurSigma,
  }) {
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: opacity),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
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
          style: GoogleFonts.jetBrainsMono(
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
    final alpha = 0.7 * (1 - p);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ClearBridgeColors.cyan.withValues(alpha: alpha),
          width: 2,
        ),
        // Outer glow -- missing from the prior pass, which only drew the
        // bordered circle.
        boxShadow: [
          BoxShadow(
            color: ClearBridgeColors.cyan.withValues(alpha: (alpha / 0.7) * 0.5),
            blurRadius: 28,
          ),
        ],
      ),
    );
  }

  Widget _marketingRow(double t, double inS, Widget child) {
    final a = _alphaIO(t, inS, null, fadeIn: _rowFadeIn);
    if (a <= 0) return const SizedBox.shrink();
    return Opacity(
      opacity: a,
      child: Transform.translate(
        offset: Offset(0, (1 - a) * 16),
        child: child,
      ),
    );
  }

  Widget _dashLine({required bool leading}) => Container(
        width: 30,
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: leading
                ? [Colors.transparent, ClearBridgeColors.silver.withValues(alpha: 0.5)]
                : [ClearBridgeColors.silver.withValues(alpha: 0.5), Colors.transparent],
          ),
        ),
      );

  Widget _forTheWorkerRow() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dashLine(leading: true),
          const SizedBox(width: 12),
          Text(
            'FOR THE WORKER',
            style: GoogleFonts.manrope(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              color: ClearBridgeColors.silverDim,
            ),
          ),
          const SizedBox(width: 12),
          _dashLine(leading: false),
        ],
      );

  Widget _badgeRow(double t) {
    // Pulsing badge dot: reference dot = 0.35+0.65*sin(t_ref*4.4);
    // t_ref = t*_refTimeScale (converts back to the JSX reference's own
    // 13.0s timeline, whatever this file's current _totalS is).
    final dotOpacity =
        (0.35 + 0.65 * math.sin(t * 4.4 * _refTimeScale)).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: ClearBridgeColors.cyan.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.45)),
            boxShadow: [
              BoxShadow(color: ClearBridgeColors.cyan.withValues(alpha: 0.22), blurRadius: 14),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: dotOpacity,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ClearBridgeColors.cyan,
                    boxShadow: [
                      BoxShadow(color: ClearBridgeColors.cyan.withValues(alpha: 0.9), blurRadius: 6),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text('BETA',
                  style: GoogleFonts.manrope(
                      fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: const Color(0xFFDFF1FF))),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Text('FAST',
            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.7, color: ClearBridgeColors.silver)),
        const SizedBox(width: 14),
        Container(width: 1, height: 12, color: ClearBridgeColors.silver.withValues(alpha: 0.28)),
        const SizedBox(width: 14),
        Text('SECURE',
            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.7, color: ClearBridgeColors.silver)),
        const SizedBox(width: 14),
        Container(width: 1, height: 12, color: ClearBridgeColors.silver.withValues(alpha: 0.28)),
        const SizedBox(width: 14),
        // Its own distinct blue, not the dim gray of FAST/SECURE (reference).
        Text('DIGITAL',
            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.7, color: _digitalBlue)),
      ],
    );
  }

  Widget _reimaginedRow() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.transparent, ClearBridgeColors.silver.withValues(alpha: 0.45)]),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            'POLICE CLEARANCE REIMAGINED',
            style: GoogleFonts.manrope(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 2.2, color: ClearBridgeColors.silverBright),
          ),
          const SizedBox(width: 14),
          Container(
            width: 46,
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [ClearBridgeColors.silver.withValues(alpha: 0.45), Colors.transparent]),
            ),
          ),
        ],
      );

  Widget _readyRow(double t) {
    // ringP = (t_ref % 1.8)/1.8, t_ref = t*_refTimeScale.
    final ringP = (t * _refTimeScale) % 1.8 / 1.8;
    final ringScale = 0.7 + 1.0 * ringP;
    final ringOpacity = (0.55 * (1 - ringP)).clamp(0.0, 1.0);
    // fpScale sin arg: t_ref*3.6 = t*3.6*_refTimeScale.
    final fpScale = 1 + 0.13 * math.sin(t * 3.6 * _refTimeScale);
    return Row(
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
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.6)),
                    ),
                  ),
                ),
              ),
              Transform.scale(
                scale: fpScale,
                child: Icon(
                  Icons.fingerprint,
                  size: 20,
                  color: ClearBridgeColors.cyan,
                  shadows: [Shadow(color: ClearBridgeColors.cyan.withValues(alpha: 0.45), blurRadius: 7)],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 9),
        Text('Ready for secure capture',
            style: GoogleFonts.manrope(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: ClearBridgeColors.silver)),
      ],
    );
  }

  Widget _tapRow(double t) {
    // tap = 0.3+0.55*sin(t_ref*3.0), t_ref = t*_refTimeScale.
    final tapOsc =
        (0.3 + 0.55 * math.sin(t * 3.0 * _refTimeScale)).clamp(0.0, 1.0);
    return Opacity(
      opacity: tapOsc,
      child: Text(
        'TAP TO CONTINUE',
        style: GoogleFonts.manrope(fontSize: 10.5, fontWeight: FontWeight.w500, letterSpacing: 1.5, color: ClearBridgeColors.silverDim),
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
