import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/capture_intro_animation.dart';

/// In-app port of the MAC3D Capture Guide HTML document.
///
/// Accessible from the profile settings sheet (Capture Guide) and from the
/// capture screen's help button. Uses the same orbit animation widget as the
/// pre-capture intro — in looping mode so it plays continuously.
class CaptureGuideScreen extends StatefulWidget {
  const CaptureGuideScreen({super.key});

  @override
  State<CaptureGuideScreen> createState() => _CaptureGuideScreenState();
}

class _CaptureGuideScreenState extends State<CaptureGuideScreen>
    with SingleTickerProviderStateMixin {
  // Drives all three quality-lock animated fill bars (each offset by 0–1.2 s).
  late final AnimationController _fill;

  @override
  void initState() {
    super.initState();
    _fill = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  // Bar width fraction: 0.34 (34%) → 0.92 (92%) → 0.34, sine-shaped.
  // [phase] 0–1 shifts the peak, mirroring the CSS animation delay.
  double _barFraction(double t, double phase) {
    final v = (t + phase) % 1.0;
    return 0.34 + 0.58 * math.sin(v * math.pi);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: CustomScrollView(
        slivers: [
          // ── Sticky header ─────────────────────────────────────────
          SliverAppBar(
            pinned: true,
            backgroundColor: ClearBridgeColors.void_.withValues(alpha: 0.9),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              color: ClearBridgeColors.silverBright,
              onPressed: () => context.pop(),
            ),
            title: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ClearBridgeColors.cyanMuted,
                    border: Border.all(
                      color: ClearBridgeColors.cyan.withValues(alpha: 0.25),
                    ),
                  ),
                  child: const Icon(
                    Icons.fingerprint,
                    size: 18,
                    color: ClearBridgeColors.cyan,
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MAC 3D',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: ClearBridgeColors.cyan,
                        letterSpacing: 0.16,
                      ),
                    ),
                    const Text(
                      'Fingerprint Capture Guide',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: ClearBridgeColors.silverBright,
                        letterSpacing: -0.01,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            titleSpacing: 0,
            actions: [
              _PulsingBadge(),
              const SizedBox(width: 16),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(
                height: 1,
                color: ClearBridgeColors.steelBorder,
              ),
            ),
          ),

          // ── Body content ─────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.only(bottom: 56),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── Core rule ──────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                  child: _InfoCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline, size: 26, color: ClearBridgeColors.cyan),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Your thumb stays still. The scanner moves.',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: ClearBridgeColors.silverBright,
                                  letterSpacing: -0.01,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Rest your thumb on any flat surface. Hold the phone flat over it, then tilt left, up, and right to capture each edge. The app auto-captures when it locks.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ClearBridgeColors.silver,
                                  height: 1.55,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Live scanner demo ────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                  child: CaptureIntroAnimation(
                    onComplete: () {},
                    loop: true,
                  ),
                ),

                // ── Four captures ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionLabel('The Four Angles'),
                      const SizedBox(height: 16),
                      _StepCard(
                        number: '01',
                        icon: Icons.filter_center_focus,
                        title: 'CENTER · FLAT',
                        body: 'Keep your thumb still on the surface. Hold the scanner flat and square over it so the camera reads the centre of your print.',
                        hint: 'full pad visible, phone level',
                      ),
                      const SizedBox(height: 12),
                      _StepCard(
                        number: '02',
                        icon: Icons.rotate_left,
                        title: 'LEFT EDGE',
                        body: 'Keep your thumb planted. Slowly tilt the scanner to the LEFT so it reads the left edge of your print. Move the phone — not your thumb.',
                        hint: 'ridge curve wrapping left',
                      ),
                      const SizedBox(height: 12),
                      _StepCard(
                        number: '03',
                        icon: Icons.expand_less,
                        title: 'TOP EDGE',
                        body: 'Now tilt the scanner UP and over the fingertip to read the top edge. Thumb stays planted — only the phone moves.',
                        hint: 'tip of thumb, nail visible',
                      ),
                      const SizedBox(height: 12),
                      _StepCard(
                        number: '04',
                        icon: Icons.rotate_right,
                        title: 'RIGHT EDGE',
                        body: 'Finally, tilt the scanner to the RIGHT for the right edge. Move slowly and keep contact light. Return flat when done.',
                        hint: 'right ridge curve, mirror of step 2',
                      ),
                    ],
                  ),
                ),

                // ── Before You Start ───────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionLabel('Before You Start'),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _SetupCard(
                              icon: Icons.table_restaurant,
                              title: 'Any surface works',
                              body: 'Capture anywhere — a desk, counter, your leg, even mid-air. A dark matte surface gives the best ridge contrast, but it\'s not required.',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SetupCard(
                              icon: Icons.wb_incandescent,
                              title: 'Even Light',
                              body: 'Natural daylight or a room light behind you. Avoid bright windows in front — glare washes out the ridges.',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _SetupCard(
                              icon: Icons.clean_hands,
                              title: 'Clean & Dry',
                              body: 'Wipe your thumb dry. Sweat or lotion blurs the ridge detail and will prevent the lock from engaging.',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SetupCard(
                              icon: Icons.straighten,
                              title: '15–20 cm',
                              body: 'Keep the phone about a hand-span above your thumb. Too close blurs; too far loses ridge detail.',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // ── Quality locks ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionLabel('What Makes It Lock'),
                      const SizedBox(height: 4),
                      Text(
                        'The app locks automatically when all three pass.',
                        style: TextStyle(
                          fontSize: 13,
                          color: ClearBridgeColors.silverDim,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 16),
                      AnimatedBuilder(
                        animation: _fill,
                        builder: (_, __) {
                          return Column(
                            children: [
                              _QualityCard(
                                icon: Icons.center_focus_strong,
                                title: 'Focus',
                                badge: 'RIDGES SHARP',
                                body: 'Fill the viewfinder with your thumb. The camera must see individual ridges, not just a blur. If the circle stays grey, move slightly closer or hold steadier.',
                                barFraction: _barFraction(_fill.value, 0),
                                okTag: 'Thumb fills frame',
                                badTag: 'Table edge visible',
                              ),
                              const SizedBox(height: 12),
                              _QualityCard(
                                icon: Icons.wb_sunny,
                                title: 'Lighting',
                                badge: 'NO GLARE',
                                body: 'Bright and even is ideal. Avoid windows directly in front of you. If you see a white hotspot on your thumb, shift position until the skin tone looks consistent.',
                                barFraction: _barFraction(_fill.value, 0.1875),
                                okTag: 'Even room light',
                                badTag: 'Direct sun or glare',
                              ),
                              const SizedBox(height: 12),
                              _QualityCard(
                                icon: Icons.pan_tool,
                                title: 'Steadiness',
                                badge: 'HOLD STILL',
                                body: 'At each angle, pause for half a second before moving on. The app detects micro-jitter and won\'t lock while the image is moving. Let it settle — you\'ll feel it click.',
                                barFraction: _barFraction(_fill.value, 0.375),
                                okTag: 'Pause at each angle',
                                badTag: 'Rushing the orbit',
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),

                // ── Common Mistakes ────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionLabel('Common Mistakes'),
                      const SizedBox(height: 16),
                      _MistakeRow(
                        title: 'Moving your thumb',
                        body: 'Your thumb must stay flat and completely still. Only the phone moves. Even a small shift resets position tracking.',
                      ),
                      const SizedBox(height: 8),
                      _MistakeRow(
                        title: 'Wet or oily skin',
                        body: 'Moisture fills the ridge valleys and flattens the pattern. Dry your thumb and wait a moment before capturing.',
                      ),
                      const SizedBox(height: 8),
                      _MistakeRow(
                        title: 'Phone too close (<12 cm)',
                        body: "The camera can't focus at very short range. The circle will stay yellow. Pull back to 15–20 cm and the lock engages quickly.",
                      ),
                      const SizedBox(height: 8),
                      _MistakeRow(
                        title: 'Glare from a bright window',
                        body: 'A hotspot on the thumb pad overexposes the image and washes ridges out. Face away from windows or close a blind.',
                      ),
                    ],
                  ),
                ),

                // ── Quick Reference ────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionLabel('Quick Reference'),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: const [
                          _RefChip(icon: Icons.straighten, label: '15–20 cm above thumb'),
                          _RefChip(icon: Icons.touch_app, label: 'No shutter — auto-captures'),
                          _RefChip(icon: Icons.timer, label: '≈ 14 seconds total'),
                          _RefChip(icon: Icons.circle_outlined, label: 'Green ring = captured'),
                          _RefChip(icon: Icons.replay, label: 'Blur won\'t lock — reposition'),
                          _RefChip(
                              icon: Icons.table_restaurant,
                              label: 'Any surface · dark = best contrast'),
                        ],
                      ),
                    ],
                  ),
                ),

                // ── Ready CTA ─────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0x14002BFF), Color(0x80172340)],
                      ),
                      border: Border.all(
                        color: ClearBridgeColors.cyan.withValues(alpha: 0.22),
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: ClearBridgeColors.cyanMuted,
                            border: Border.all(
                              color: ClearBridgeColors.cyan.withValues(alpha: 0.3),
                            ),
                          ),
                          child: const Icon(
                            Icons.fingerprint,
                            size: 28,
                            color: ClearBridgeColors.cyan,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Ready to capture',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: ClearBridgeColors.silverBright,
                            letterSpacing: -0.01,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Four tilt angles, one clean print, ≈14 seconds. The ring turns green when each angle locks.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: ClearBridgeColors.silver,
                            height: 1.55,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () =>
                                context.go(AppConstants.continuousCaptureRoute),
                            style: FilledButton.styleFrom(
                              backgroundColor: ClearBridgeColors.cyan,
                              foregroundColor: ClearBridgeColors.void_,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: const StadiumBorder(),
                            ),
                            icon: const Icon(Icons.camera_alt, size: 18),
                            label: const Text(
                              'Start Capture',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.01,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.verified_user,
                                size: 13, color: ClearBridgeColors.success),
                            const SizedBox(width: 6),
                            Text(
                              'POPIA-compliant · Secured on-device',
                              style: TextStyle(
                                fontSize: 11,
                                color: ClearBridgeColors.silverDim,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Supporting widgets ────────────────────────────────────────────────────────

class _PulsingBadge extends StatefulWidget {
  @override
  State<_PulsingBadge> createState() => _PulsingBadgeState();
}

class _PulsingBadgeState extends State<_PulsingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: ClearBridgeColors.cyanMuted,
        border: Border.all(
          color: ClearBridgeColors.cyan.withValues(alpha: 0.25),
        ),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Opacity(
              opacity: 0.4 + 0.6 * _ctrl.value,
              child: Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: ClearBridgeColors.cyan,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '≈ 14s',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: ClearBridgeColors.cyan,
              letterSpacing: 0.10,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: ClearBridgeColors.cyan,
        letterSpacing: 0.18,
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ClearBridgeColors.cyan.withValues(alpha: 0.06),
        border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.20)),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: child,
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.icon,
    required this.title,
    required this.body,
    required this.hint,
  });
  final String number;
  final IconData icon;
  final String title;
  final String body;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        border: Border.all(color: ClearBridgeColors.cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: ClearBridgeColors.cyanMuted,
              border: Border.all(
                color: ClearBridgeColors.cyan.withValues(alpha: 0.22),
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 22, color: ClearBridgeColors.cyan),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      number,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: ClearBridgeColors.cyan,
                        letterSpacing: 0.12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: ClearBridgeColors.silverBright,
                        letterSpacing: -0.01,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ClearBridgeColors.cyan.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 13,
                    color: ClearBridgeColors.silver,
                    height: 1.55,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility,
                        size: 14,
                        color: ClearBridgeColors.success,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'You should see: $hint',
                          style: const TextStyle(
                            fontSize: 11,
                            color: ClearBridgeColors.silverDim,
                            fontWeight: FontWeight.w500,
                          ),
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
    );
  }
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        border: Border.all(color: ClearBridgeColors.cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: ClearBridgeColors.cyanMuted,
              border: Border.all(
                color: ClearBridgeColors.cyan.withValues(alpha: 0.20),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: ClearBridgeColors.cyan),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: ClearBridgeColors.silverBright,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(
              fontSize: 12,
              color: ClearBridgeColors.silver,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _QualityCard extends StatelessWidget {
  const _QualityCard({
    required this.icon,
    required this.title,
    required this.badge,
    required this.body,
    required this.barFraction,
    required this.okTag,
    required this.badTag,
  });
  final IconData icon;
  final String title;
  final String badge;
  final String body;
  final double barFraction;
  final String okTag;
  final String badTag;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        border: Border.all(color: ClearBridgeColors.cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: ClearBridgeColors.cyan),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: ClearBridgeColors.silverBright,
                ),
              ),
              const Spacer(),
              Text(
                badge,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: ClearBridgeColors.cyan,
                  letterSpacing: 0.08,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Animated fill bar
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Container(
              height: 5,
              color: Colors.white.withValues(alpha: 0.06),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: barFraction.clamp(0.0, 1.0),
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [ClearBridgeColors.cyan, Color(0xFF2E9FE0)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: const TextStyle(
              fontSize: 12,
              color: ClearBridgeColors.silver,
              height: 1.55,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _StatusTag(
                label: okTag,
                icon: Icons.check,
                color: ClearBridgeColors.success,
              ),
              _StatusTag(
                label: badTag,
                icon: Icons.close,
                color: ClearBridgeColors.error,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.label, required this.icon, required this.color});
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.20)),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _MistakeRow extends StatelessWidget {
  const _MistakeRow({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: ClearBridgeColors.error.withValues(alpha: 0.05),
        border: Border.all(color: ClearBridgeColors.error.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.warning_amber_rounded,
                size: 18, color: ClearBridgeColors.error),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: ClearBridgeColors.silverBright,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 12,
                    color: ClearBridgeColors.silverDim,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RefChip extends StatelessWidget {
  const _RefChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        border: Border.all(color: ClearBridgeColors.cardBorder),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: ClearBridgeColors.success),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: ClearBridgeColors.silver,
            ),
          ),
        ],
      ),
    );
  }
}
