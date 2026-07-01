import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../../../core/widgets/cb_ui.dart' show ClearCoinCoin;
import '../../application/providers/clearance_provider.dart';
import '../../auth/providers/auth_provider.dart';
import '../../auth/providers/user_profile_provider.dart';


/// Dashboard — Flutter port of the prototype `DashboardScreen`: greeting,
/// ClearCoin card, beta banner, Get-Clearance (coming soon) + Save-Print
/// (active) tiles, stats, referral card, quick actions, recent activity, and
/// the capture-guide bottom sheet. Wired to the real providers.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entryCtrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    _fade = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    super.dispose();
  }

  void _startCapture() => context.push(AppConstants.fingerprintRoute);

  void _openHelp() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _CaptureGuideSheet(onStart: () {
        Navigator.of(context).pop();
        _startCapture();
      }),
    );
  }

  void _openNotifications() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _NotificationsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clearances = ref.watch(userClearancesProvider).valueOrNull ?? [];

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: SafeArea(
          child: Stack(
            children: [
              const Positioned.fill(
                child: IgnorePointer(child: _SilverAmbientBg()),
              ),
              Positioned.fill(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _GreetingRow(onNotifications: _openNotifications),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _SetupJourneyTracker(),
                            const SizedBox(height: 16),
                            _ActionTiles(onSavePrint: _startCapture),
                            const SizedBox(height: 14),
                            const _ReferralCard(),
                            const SizedBox(height: 14),
                            const _SectionLabel('Quick Actions'),
                            const SizedBox(height: 10),
                            _QuickActions(onHelp: _openHelp),
                            const SizedBox(height: 14),
                            const _SectionLabel('Recent Activity'),
                            const SizedBox(height: 10),
                            _RecentActivity(count: clearances.length),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Greeting ─────────────────────────────────────────────────────────────────
class _GreetingRow extends ConsumerWidget {
  const _GreetingRow({this.onNotifications});
  final VoidCallback? onNotifications;

  String _timeOfDay() {
    final h = DateTime.now().hour;
    if (h < 12) return 'GOOD MORNING';
    if (h < 17) return 'GOOD AFTERNOON';
    return 'GOOD EVENING';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final user = ref.watch(authProvider).valueOrNull;
    final firstName = profile?.firstName.isNotEmpty == true
        ? profile!.firstName
        : (user?.displayName?.split(' ').first ?? 'there');
    final initials = _initials(profile?.firstName, profile?.surname, user);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_timeOfDay(),
                    style: ClearBridgeTypography.eyebrow
                        .copyWith(letterSpacing: 0.16)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(
                      child: Text(firstName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              ClearBridgeTypography.h2.copyWith(fontSize: 20)),
                    ),
                    const SizedBox(width: 8),
                    const _GoldBetaBadge(),
                  ],
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onNotifications,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_rounded,
                    color: ClearBridgeColors.cyan, size: 24),
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: ClearBridgeColors.error,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: ClearBridgeColors.void_, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => context.push('/profile'),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [ClearBridgeColors.cyan, ClearBridgeColors.blueDeep2],
                ),
                border: Border.all(color: ClearBridgeColors.cyanBorder, width: 2),
              ),
              alignment: Alignment.center,
              child: Text(initials,
                  style: GoogleFonts.manrope(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  String _initials(String? first, String? last, User? user) {
    final f = first?.isNotEmpty == true ? first![0] : null;
    final l = last?.isNotEmpty == true ? last![0] : null;
    if (f != null && l != null) return '${f.toUpperCase()}${l.toUpperCase()}';
    if (f != null) return f.toUpperCase();
    final d = user?.displayName;
    if (d != null && d.isNotEmpty) return d[0].toUpperCase();
    return 'CB';
  }
}

class _GoldBetaBadge extends StatelessWidget {
  const _GoldBetaBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ClearBridgeColors.gold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: ClearBridgeColors.gold.withValues(alpha: 0.4)),
      ),
      child: Text('BETA',
          style: ClearBridgeTypography.label.copyWith(
              color: ClearBridgeColors.gold,
              fontWeight: FontWeight.w800,
              fontSize: 9,
              letterSpacing: 0.14)),
    );
  }
}

// ── Action tiles ────────────────────────────────────────────────────────────
class _ActionTiles extends StatelessWidget {
  const _ActionTiles({required this.onSavePrint});
  final VoidCallback onSavePrint;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CapturePulseButton(onTap: onSavePrint),
        const SizedBox(height: 10),
        const _GetClearanceCard(),
      ],
    );
  }
}

// ── Referral card ─────────────────────────────────────────────────────────────
class _ReferralCard extends ConsumerWidget {
  const _ReferralCard();

  String _codeFor(User? user) {
    if (user == null) return 'CB-GUEST';
    final raw = user.uid.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    return raw.length >= 8 ? raw.substring(0, 8) : raw;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).valueOrNull;
    final code = _codeFor(user);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: [0.0, 0.7, 1.0],
          colors: [Color(0x1AE2E8F0), Color(0x0D94A3B8), Color(0x00000000)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x4DE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1FE2E8F0),
            blurRadius: 24,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: ClearBridgeColors.silverBright.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                  color: ClearBridgeColors.silverBright.withValues(alpha: 0.30)),
            ),
            child: const Icon(Icons.share,
                size: 20, color: ClearBridgeColors.silverBright),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('REFERRAL CODE',
                    style: ClearBridgeTypography.eyebrow
                        .copyWith(color: ClearBridgeColors.silverDim)),
                const SizedBox(height: 2),
                Text(code,
                    style: ClearBridgeTypography.mono.copyWith(
                        color: ClearBridgeColors.silverBright,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.08)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    const ClearCoinCoin(size: 12),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          text: '+10 ClearCoins',
                          style: ClearBridgeTypography.label.copyWith(
                              color: ClearBridgeColors.cyan,
                              fontWeight: FontWeight.w700,
                              fontSize: 11),
                          children: [
                            TextSpan(
                              text: ' when they buy a clearance',
                              style: ClearBridgeTypography.label.copyWith(
                                  color: ClearBridgeColors.silverDim,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 11),
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
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => Share.share(
              'Use my ClearBridge referral code $code to get your police clearance fast.',
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x2E00BFFF), Color(0x1A1E88E5)],
                ),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.45)),
                boxShadow: [
                  BoxShadow(
                    color: ClearBridgeColors.cyan.withValues(alpha: 0.18),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.ios_share,
                      size: 14, color: ClearBridgeColors.cyan),
                  const SizedBox(width: 5),
                  Text('Share',
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.cyan,
                          fontWeight: FontWeight.w700,
                          fontSize: 11)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section label / quick actions / recent activity ───────────────────────────
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: ClearBridgeTypography.h3.copyWith(fontSize: 13));
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onHelp});
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _QuickTile(
            icon: Icons.history_rounded,
            label: 'History',
            sub: 'View past applications',
            onTap: () => context.push(AppConstants.historyRoute),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _QuickTile(
            icon: Icons.help_rounded,
            label: 'Help',
            sub: 'Fingerprint capture guide',
            onTap: onHelp,
          ),
        ),
      ],
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.025),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: ClearBridgeColors.cyan.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: ClearBridgeColors.cyan),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: ClearBridgeTypography.body.copyWith(
                          color: ClearBridgeColors.silverBright,
                          fontWeight: FontWeight.w700,
                          fontSize: 12)),
                  const SizedBox(height: 1),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silverDim, fontSize: 10)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentActivity extends StatelessWidget {
  const _RecentActivity({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            const Icon(Icons.description_rounded,
                color: ClearBridgeColors.cyan, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text('$count clearance application(s)',
                  style: ClearBridgeTypography.body.copyWith(
                      color: ClearBridgeColors.silverBright,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: ClearBridgeColors.silverDim, size: 20),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.015),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.history_rounded,
                size: 22, color: ClearBridgeColors.silverDim),
          ),
          const SizedBox(height: 10),
          Text('No activity yet',
              style: ClearBridgeTypography.body.copyWith(
                  color: ClearBridgeColors.silver, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Capture your fingerprints to get started',
              style: ClearBridgeTypography.caption
                  .copyWith(color: ClearBridgeColors.silverDim)),
        ],
      ),
    );
  }
}

// ── Capture-guide bottom sheet ────────────────────────────────────────────────
class _CaptureGuideSheet extends StatelessWidget {
  const _CaptureGuideSheet({required this.onStart});
  final VoidCallback onStart;

  static const _tips = [
    (Icons.wash_rounded, 'Clean, dry finger', 'Wipe away moisture, oil or lotion first'),
    (Icons.light_mode_rounded, 'Even, bright light', 'Avoid shadows and direct glare on the lens'),
    (Icons.back_hand_rounded, 'Hold steady', 'Keep your hand still until the angle locks'),
  ];

  static const _angles = [
    (1, 'FRONT', 'Lay your thumb flat, pad facing the camera. Hold still while the system calibrates your baseline angle.'),
    (2, 'LEFT', 'Rotate your thumb so the left edge faces the camera. This captures the left ridge of your fingerprint.'),
    (3, 'TOP', 'Continue rotating until the back of your thumb faces the camera. Records the upper surface of the print.'),
    (4, 'RIGHT', 'Rotate your thumb so the right edge faces the camera. This final angle completes your MAC capture.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      decoration: const BoxDecoration(
        color: ClearBridgeColors.navy,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0x2600BFFF))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Row(
              children: [
                const Icon(Icons.fingerprint,
                    color: ClearBridgeColors.cyan, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('How to Capture Your Print',
                          style: ClearBridgeTypography.h3.copyWith(fontSize: 15)),
                      const SizedBox(height: 1),
                      Text('MULTI-ANGLE CAPTURE · 4 STEPS',
                          style: ClearBridgeTypography.label.copyWith(
                              color: ClearBridgeColors.cyan,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.12)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close,
                      color: ClearBridgeColors.silverDim, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0x0FFFFFFF)),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'We capture your thumb from four angles to build a complete, '
                    'court-grade fingerprint. Follow the on-screen guide — each '
                    'angle locks automatically once it\'s sharp.',
                    style: ClearBridgeTypography.body.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 16),
                  Text('BEFORE YOU START',
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silverDim,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.12)),
                  const SizedBox(height: 8),
                  for (final (icon, title, sub) in _tips)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _GuideRow(icon: icon, title: title, sub: sub),
                    ),
                  const SizedBox(height: 8),
                  Text('THE FOUR ANGLES',
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silverDim,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.12)),
                  const SizedBox(height: 8),
                  for (final (n, angle, tip) in _angles)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _AngleRow(n: n, angle: angle, tip: tip),
                    ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ClearBridgeColors.success.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: ClearBridgeColors.success
                              .withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.verified_user,
                            color: ClearBridgeColors.success, size: 18),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            'All four prints are encrypted on-device and stored '
                            'securely — the whole capture takes under a minute.',
                            style: ClearBridgeTypography.caption
                                .copyWith(color: ClearBridgeColors.silver, height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: onStart,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        gradient: ClearBridgeColors.gradPrimary,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: ClearBridgeColors.cyan.withValues(alpha: 0.3),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.fingerprint,
                              color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                          Text('Start Capture',
                              style: ClearBridgeTypography.h3.copyWith(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
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

class _GuideRow extends StatelessWidget {
  const _GuideRow({required this.icon, required this.title, required this.sub});
  final IconData icon;
  final String title;
  final String sub;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: ClearBridgeColors.cyan.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: ClearBridgeColors.cyan),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: ClearBridgeTypography.body.copyWith(
                        color: ClearBridgeColors.silverBright,
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
                const SizedBox(height: 1),
                Text(sub,
                    style: ClearBridgeTypography.label.copyWith(
                        color: ClearBridgeColors.silverDim, fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AngleRow extends StatelessWidget {
  const _AngleRow({required this.n, required this.angle, required this.tip});
  final int n;
  final String angle;
  final String tip;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ClearBridgeColors.cardBorder),
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: ClearBridgeColors.cyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: ClearBridgeColors.cyan.withValues(alpha: 0.35)),
                ),
                child: const Icon(Icons.fingerprint,
                    size: 26, color: Color(0xD900BFFF)),
              ),
              Positioned(
                top: -7,
                left: -7,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: ClearBridgeColors.cyan,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text('$n',
                      style: const TextStyle(
                          color: ClearBridgeColors.void_,
                          fontSize: 11,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(angle,
                    style: ClearBridgeTypography.mono.copyWith(
                        color: ClearBridgeColors.cyan,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(tip,
                    style: ClearBridgeTypography.caption
                        .copyWith(color: ClearBridgeColors.silver, height: 1.55)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Setup journey tracker ─────────────────────────────────────────────────────
class _SetupJourneyTracker extends StatelessWidget {
  const _SetupJourneyTracker();

  @override
  Widget build(BuildContext context) {
    const steps = [
      (Icons.verified_user, 'Identity', 'Verified', 'done'),
      (Icons.fingerprint, 'Fingerprints', 'Next step', 'active'),
      (Icons.badge_rounded, 'Clearance', 'Soon', 'locked'),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 13, 18, 12),
      decoration: BoxDecoration(
        color: ClearBridgeColors.steel.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('YOUR SETUP',
              style: ClearBridgeTypography.label.copyWith(
                  color: ClearBridgeColors.silverDim,
                  letterSpacing: 0.12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = 0; i < steps.length; i++) ...[
                SizedBox(
                  width: 62,
                  child: Column(
                    children: [
                      _StepCircle(icon: steps[i].$1, state: steps[i].$4),
                      const SizedBox(height: 6),
                      Text(steps[i].$2,
                          style: ClearBridgeTypography.label.copyWith(
                              color: steps[i].$4 == 'locked'
                                  ? ClearBridgeColors.silverDim
                                  : ClearBridgeColors.silverBright,
                              fontSize: 10,
                              fontWeight: FontWeight.w700),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 2),
                      Text(steps[i].$3,
                          style: ClearBridgeTypography.label.copyWith(
                              color: steps[i].$4 == 'done'
                                  ? ClearBridgeColors.success
                                  : steps[i].$4 == 'active'
                                      ? ClearBridgeColors.cyan
                                      : ClearBridgeColors.silverDim,
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.06),
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
                if (i < steps.length - 1)
                  Expanded(
                    child: Container(
                      height: 2,
                      margin: const EdgeInsets.only(top: 18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: steps[i].$4 == 'done'
                            ? const LinearGradient(colors: [
                                ClearBridgeColors.success,
                                Color(0x8000BFFF),
                              ])
                            : null,
                        color: steps[i].$4 == 'done'
                            ? null
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _StepCircle extends StatelessWidget {
  const _StepCircle({required this.icon, required this.state});
  final IconData icon;
  final String state;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color iconColor;
    final Color borderColor;
    switch (state) {
      case 'done':
        bg = const Color(0xFF22C55E);
        iconColor = Colors.white;
        borderColor = Colors.transparent;
      case 'active':
        bg = ClearBridgeColors.cyan.withValues(alpha: 0.14);
        iconColor = ClearBridgeColors.cyan;
        borderColor = ClearBridgeColors.cyan;
      default:
        bg = Colors.white.withValues(alpha: 0.04);
        iconColor = ClearBridgeColors.silverDim;
        borderColor = Colors.white.withValues(alpha: 0.08);
    }

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        border: Border.all(
            color: borderColor, width: state == 'active' ? 1.5 : 1),
        boxShadow: state == 'done'
            ? [
                BoxShadow(
                  color: ClearBridgeColors.success.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                )
              ]
            : state == 'active'
                ? [
                    BoxShadow(
                      color: ClearBridgeColors.cyan.withValues(alpha: 0.30),
                      blurRadius: 16,
                    )
                  ]
                : null,
      ),
      child: Icon(
        state == 'done' ? Icons.check : icon,
        size: 20,
        color: iconColor,
      ),
    );
  }
}

// ── Capture pulse button ──────────────────────────────────────────────────────
class _CapturePulseButton extends StatefulWidget {
  const _CapturePulseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CapturePulseButton> createState() => _CapturePulseButtonState();
}

class _CapturePulseButtonState extends State<_CapturePulseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final glowAlpha = 0.50 + _pulse.value * 0.30;
        final blurRadius = 40.0 + _pulse.value * 20.0;
        return GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 154,
            height: 154,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ClearBridgeColors.success.withValues(alpha: 0.08),
              border: Border.all(
                color: ClearBridgeColors.success.withValues(alpha: 0.70),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      ClearBridgeColors.success.withValues(alpha: glowAlpha),
                  blurRadius: blurRadius,
                ),
                BoxShadow(
                  color: ClearBridgeColors.success
                      .withValues(alpha: glowAlpha * 0.6),
                  blurRadius: blurRadius * 0.75,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [ClearBridgeColors.success, Color(0xFF16A34A)],
              ),
              boxShadow: [
                BoxShadow(
                  color: ClearBridgeColors.success.withValues(alpha: 0.40),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(Icons.fingerprint, size: 26, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            'Capture\nFingerprints',
            textAlign: TextAlign.center,
            style: ClearBridgeTypography.body.copyWith(
              color: ClearBridgeColors.silverBright,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'MAC 3D',
            style: ClearBridgeTypography.label.copyWith(
              color: ClearBridgeColors.cyan,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.08,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Get clearance card ────────────────────────────────────────────────────────
class _GetClearanceCard extends StatelessWidget {
  const _GetClearanceCard();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.60,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x1200BFFF), Color(0x081E88E5)],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: ClearBridgeColors.cyan.withValues(alpha: 0.28)),
        ),
        child: Column(
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ClearBridgeColors.cyan.withValues(alpha: 0.14),
                border: Border.all(
                    color: ClearBridgeColors.cyan.withValues(alpha: 0.35)),
                boxShadow: [
                  BoxShadow(
                    color: ClearBridgeColors.cyan.withValues(alpha: 0.20),
                    blurRadius: 22,
                  ),
                ],
              ),
              child: const Icon(Icons.badge_rounded,
                  size: 38, color: ClearBridgeColors.gold),
            ),
            const SizedBox(height: 10),
            Text(
              'Get Police Clearance',
              style: ClearBridgeTypography.h3
                  .copyWith(color: ClearBridgeColors.cyan, letterSpacing: 0.01),
            ),
            const SizedBox(height: 4),
            Text(
              'Police clearance certificate',
              style: ClearBridgeTypography.caption
                  .copyWith(color: ClearBridgeColors.silver),
            ),
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                gradient: ClearBridgeColors.gradPrimary,
                borderRadius: BorderRadius.circular(100),
                boxShadow: [
                  BoxShadow(
                    color: ClearBridgeColors.cyan.withValues(alpha: 0.40),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                'COMING SOON',
                style: ClearBridgeTypography.label.copyWith(
                  color: ClearBridgeColors.void_,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Notifications sheet ───────────────────────────────────────────────────────
class _NotificationsSheet extends StatelessWidget {
  const _NotificationsSheet();

  static const _notifs = [
    (
      Icons.fingerprint,
      ClearBridgeColors.success,
      true,
      'Fingerprint saved successfully',
      'Your print was captured and encrypted.',
      'Just now'
    ),
    (
      Icons.badge_rounded,
      ClearBridgeColors.cyan,
      false,
      'Police Clearance — coming soon',
      "You'll be notified the moment submissions go live.",
      '2 days ago'
    ),
    (
      Icons.stars_rounded,
      ClearBridgeColors.gold,
      false,
      'ClearCoin balance updated',
      '+10 coins added after your last capture session.',
      '3 days ago'
    ),
    (
      Icons.verified_user,
      ClearBridgeColors.success,
      false,
      'Account secured',
      'AES-256 encryption active on your profile.',
      '5 days ago'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      decoration: const BoxDecoration(
        color: ClearBridgeColors.navy,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0x2600BFFF))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Row(
              children: [
                const Icon(Icons.notifications_rounded,
                    color: ClearBridgeColors.cyan, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Notifications',
                          style:
                              ClearBridgeTypography.h3.copyWith(fontSize: 15)),
                      const SizedBox(height: 1),
                      Text('1 UNREAD',
                          style: ClearBridgeTypography.label.copyWith(
                              color: ClearBridgeColors.cyan,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.12)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close,
                      color: ClearBridgeColors.silverDim, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0x0FFFFFFF)),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                children: [
                  for (final (icon, color, unread, title, sub, time)
                      in _notifs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _NotifItem(
                        icon: icon,
                        color: color,
                        unread: unread,
                        title: title,
                        sub: sub,
                        time: time,
                      ),
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

// ── Silver ambient background ─────────────────────────────────────────────────
class _SilverAmbientBg extends StatelessWidget {
  const _SilverAmbientBg();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _SilverOrbPainter());
  }
}

class _SilverOrbPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    _orb(canvas, Offset(size.width + 80, 60), 280, const Color(0x21E2E8F0));
    _orb(canvas, Offset(-80, size.height - 100), 300, const Color(0x1CB5BCC4));
    _orb(canvas, Offset(size.width * 0.56, size.height * 0.40), 180, const Color(0x12E2E8F0));
    _streak(canvas, size, 0.18);
    _streak(canvas, size, 0.58);
  }

  void _orb(Canvas canvas, Offset center, double radius, Color color) {
    final shader = RadialGradient(
      colors: [color, color.withAlpha(0)],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  void _streak(Canvas canvas, Size size, double yFraction) {
    final y = size.height * yFraction;
    final shader = const LinearGradient(
      colors: [
        Color(0x00E2E8F0),
        Color(0x1AE2E8F0),
        Color(0x00E2E8F0),
      ],
    ).createShader(Rect.fromLTWH(0, y - 0.5, size.width, 1));
    canvas.drawRect(
      Rect.fromLTWH(0, y - 0.5, size.width, 1),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_SilverOrbPainter old) => false;
}

class _NotifItem extends StatelessWidget {
  const _NotifItem({
    required this.icon,
    required this.color,
    required this.unread,
    required this.title,
    required this.sub,
    required this.time,
  });
  final IconData icon;
  final Color color;
  final bool unread;
  final String title;
  final String sub;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: unread
                ? ClearBridgeColors.cyan.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.025),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: unread
                  ? ClearBridgeColors.cyan.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.05),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: ClearBridgeTypography.body.copyWith(
                            color: ClearBridgeColors.silverBright,
                            fontWeight: FontWeight.w700,
                            fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(sub,
                        style: ClearBridgeTypography.caption
                            .copyWith(color: ClearBridgeColors.silver, height: 1.5)),
                    const SizedBox(height: 4),
                    Text(time,
                        style: ClearBridgeTypography.label.copyWith(
                            color: ClearBridgeColors.silverDim,
                            fontSize: 9,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (unread)
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: ClearBridgeColors.cyan,
                boxShadow: [
                  BoxShadow(
                      color: ClearBridgeColors.cyan, blurRadius: 8),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
