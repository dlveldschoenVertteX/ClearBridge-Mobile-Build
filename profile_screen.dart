import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../../../shared/widgets/cb_primary_button.dart';
import '../../auth/providers/auth_controller_provider.dart';
import '../../auth/providers/auth_provider.dart';
import '../../auth/providers/user_profile_provider.dart';
import '../../application/providers/clearance_provider.dart';
import '../../clearcoin/clearcoin_service.dart';
import '../../dashboard/widgets/clearcoin_card.dart';

/// Profile — Flutter port of the prototype `ProfileScreen`: logo avatar with
/// verified badge, biometric-lock card (→ encryption sheet), stats, action
/// rows, Sign Out, plus the encryption and settings bottom sheets.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).valueOrNull;
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final coins = ref.watch(clearCoinBalanceProvider);
    final clearances = ref.watch(userClearancesProvider).valueOrNull ?? [];
    final prints = (coins / ClearCoinService.perSession).floor();

    final firstName = profile?.firstName ?? '';
    final surname = profile?.surname ?? '';
    final fullName = [firstName, surname].where((s) => s.isNotEmpty).join(' ');
    final name = fullName.isNotEmpty
        ? fullName
        : (user?.displayName ?? 'Your Profile');
    final initials = [
      firstName.isNotEmpty ? firstName[0] : '',
      surname.isNotEmpty ? surname[0] : '',
    ].join().toUpperCase();
    final email = profile?.email ?? '';
    final idNumber = profile?.idNumber ?? '';
    final verified = idNumber.isNotEmpty;

    void openEncryption() => showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          isScrollControlled: true,
          builder: (_) => const _EncryptionSheet(),
        );

    void openSettings() => showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          isScrollControlled: true,
          builder: (_) => _SettingsSheet(
            onPersonalInfo: () {
              Navigator.of(context).pop();
              context.push(AppConstants.personalDetailsRoute);
            },
            onEncryption: () {
              Navigator.of(context).pop();
              openEncryption();
            },
            onPrivacy: () {
              Navigator.of(context).pop();
              context.push('/privacy');
            },
          ),
        );

    return SafeArea(
      child: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(child: _ProfileSilverBg()),
          ),
          Positioned.fill(
            child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Column(
                children: [
                  // Nav row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go(AppConstants.dashboardRoute);
                          }
                        },
                        child: const Icon(Icons.arrow_back,
                            color: ClearBridgeColors.silver, size: 22),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Profile', style: ClearBridgeTypography.h3),
                          const SizedBox(width: 8),
                          const _GoldBetaBadge(),
                        ],
                      ),
                      GestureDetector(
                        onTap: openSettings,
                        child: const Icon(Icons.settings,
                            color: ClearBridgeColors.silver, size: 22),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Avatar hero
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: ClearBridgeColors.cyanBorder, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  ClearBridgeColors.cyan.withValues(alpha: 0.25),
                              blurRadius: 30,
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: Image.asset(
                            AppConstants.logoPath,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              decoration: const BoxDecoration(
                                  gradient: ClearBridgeColors.gradPrimary),
                              alignment: Alignment.center,
                              child: Text(
                                initials.isNotEmpty ? initials : 'CB',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: ClearBridgeColors.success,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: ClearBridgeColors.void_, width: 2.5),
                          ),
                          child: const Icon(Icons.check,
                              size: 14, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(name, style: ClearBridgeTypography.h2),
                  if (email.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(email, style: ClearBridgeTypography.caption),
                  ],
                  if (idNumber.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('ID · $idNumber',
                        style: ClearBridgeTypography.mono.copyWith(fontSize: 11)),
                  ],
                  if (verified) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: ClearBridgeColors.success.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(100),
                        border: Border.all(
                            color: ClearBridgeColors.success
                                .withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: ClearBridgeColors.success,
                              boxShadow: [
                                BoxShadow(
                                    color: ClearBridgeColors.success,
                                    blurRadius: 8),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('VERIFIED IDENTITY',
                              style: ClearBridgeTypography.label.copyWith(
                                  color: ClearBridgeColors.success,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.12)),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  const ClearCoinCard(),
                  const SizedBox(height: 14),
                  // Biometric lock → encryption sheet
                  GestureDetector(
                    onTap: openEncryption,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0x1A00BFFF), Color(0x0A1E88E5)],
                        ),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                            color: ClearBridgeColors.success
                                .withValues(alpha: 0.3)),
                        boxShadow: [
                          BoxShadow(
                            color: ClearBridgeColors.success
                                .withValues(alpha: 0.2),
                            blurRadius: 24,
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: ClearBridgeColors.success
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: ClearBridgeColors.success
                                      .withValues(alpha: 0.3)),
                            ),
                            child: const Icon(Icons.verified_user,
                                color: ClearBridgeColors.success, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Biometric Lock',
                                    style: ClearBridgeTypography.body.copyWith(
                                        color: ClearBridgeColors.silverBright,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13)),
                                const SizedBox(height: 2),
                                Text('AES-256 · TLS 1.3 · Secure Enclave',
                                    style: ClearBridgeTypography.label.copyWith(
                                        color: ClearBridgeColors.silverDim,
                                        fontSize: 10)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: ClearBridgeColors.cyan, size: 18),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Stats
                  Row(
                    children: [
                      Expanded(
                          child: _MiniStat(
                              value: '${clearances.length}',
                              label: 'Clearances')),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _MiniStat(value: '$prints', label: 'Prints')),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _MiniStat(
                              value: '$coins', label: 'ClearCoins')),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Action rows
                  _ActionRow(
                    icon: Icons.person,
                    iconColor: ClearBridgeColors.cyan,
                    iconBg: const Color(0x2600BFFF),
                    borderColor: const Color(0x4000BFFF),
                    title: 'Personal Info',
                    sub: 'Edit your details',
                    onTap: () => context.push(AppConstants.personalDetailsRoute),
                  ),
                  const SizedBox(height: 8),
                  const _ComingSoonRow(
                    icon: Icons.credit_card,
                    iconColor: ClearBridgeColors.blueDark,
                    title: 'Payment Methods',
                    sub: 'Linked cards & wallets',
                  ),
                  const SizedBox(height: 8),
                  const _ComingSoonRow(
                    icon: Icons.support_agent,
                    iconColor: ClearBridgeColors.cyan,
                    title: 'Support',
                    sub: 'Email · chat · call',
                  ),
                  const SizedBox(height: 8),
                  _ActionRow(
                    icon: Icons.gavel,
                    iconColor: ClearBridgeColors.gold,
                    iconBg: const Color(0x2EC9A84C),
                    borderColor: const Color(0x40C9A84C),
                    title: 'Privacy & Terms',
                    sub: 'POPIA · Full compliance details',
                    onTap: () => context.push('/privacy'),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: CbPrimaryButton.danger(
              label: 'Sign Out',
              icon: const Icon(Icons.logout),
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).logout(),
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

class _ProfileSilverBg extends StatelessWidget {
  const _ProfileSilverBg();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ProfileSilverPainter());
  }
}

class _ProfileSilverPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    _orb(canvas, Offset(size.width + 60, 90), 220, const Color(0x1AE2E8F0));
    _orb(canvas, Offset(-70, size.height - 60), 240, const Color(0x14B5BCC4));
    _orb(canvas, Offset(size.width * 0.30 + 42, size.height * 0.42), 140, const Color(0x0DE2E8F0));
  }

  void _orb(Canvas canvas, Offset center, double radius, Color color) {
    final shader = RadialGradient(
      colors: [color, color.withAlpha(0)],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ProfileSilverPainter old) => false;
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

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ClearBridgeColors.steel.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Text(value,
              style: ClearBridgeTypography.h2.copyWith(
                  fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(label.toUpperCase(),
              textAlign: TextAlign.center,
              style: ClearBridgeTypography.label.copyWith(
                  color: ClearBridgeColors.silverDim, fontSize: 9)),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.borderColor,
    required this.title,
    required this.sub,
    required this.onTap,
  });
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final Color borderColor;
  final String title;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [iconBg, Colors.transparent],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: iconColor, size: 20),
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
                          fontSize: 13)),
                  const SizedBox(height: 1),
                  Text(sub,
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silver.withValues(alpha: 0.7),
                          fontSize: 11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: iconColor, size: 18),
          ],
        ),
      ),
    );
  }
}

class _ComingSoonRow extends StatelessWidget {
  const _ComingSoonRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.sub,
  });
  final IconData icon;
  final Color iconColor;
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.55,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: iconColor, size: 20),
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
                          fontSize: 13)),
                  const SizedBox(height: 1),
                  Text(sub,
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silver.withValues(alpha: 0.7),
                          fontSize: 11)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: ClearBridgeColors.silver.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(100),
                border: Border.all(
                    color: ClearBridgeColors.silver.withValues(alpha: 0.18)),
              ),
              child: Text('SOON',
                  style: ClearBridgeTypography.label.copyWith(
                      color: ClearBridgeColors.silverDim,
                      fontWeight: FontWeight.w800,
                      fontSize: 9,
                      letterSpacing: 0.1)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Encryption bottom sheet ───────────────────────────────────────────────────
class _EncryptionSheet extends StatelessWidget {
  const _EncryptionSheet();

  static const _layers = [
    (Icons.lock, ClearBridgeColors.cyan, 'AES-256-GCM Encryption', 'Data at rest',
        'Your fingerprint templates and personal data are encrypted using AES-256-GCM — the same standard used by banks and government agencies worldwide. Your raw data is never stored in plain text.'),
    (Icons.vpn_lock, ClearBridgeColors.blueDark, 'TLS 1.3 Secure Transmission', 'Data in transit',
        'Every data packet sent between your device and ClearBridge servers is protected by TLS 1.3 — the latest, most secure transport protocol. Older, weaker protocols are blocked.'),
    (Icons.security, ClearBridgeColors.success, 'Device Secure Enclave', 'On-device isolation',
        'Biometric keys are generated and stored inside your device\'s hardware Secure Enclave (iOS) or StrongBox (Android). Encryption keys never leave your device.'),
    (Icons.key, ClearBridgeColors.gold, 'PBKDF2 Key Derivation', 'Key hardening',
        'All encryption keys are hardened using PBKDF2 with 310,000 iterations and a unique salt per user, making brute-force attacks computationally impossible.'),
    (Icons.shield, ClearBridgeColors.warning, 'POPIA Data Minimisation', 'Regulatory standard',
        'We only store what is strictly necessary. Biometric data is anonymised before any ML processing, and full fingerprint images are deleted within 24 hours of processing.'),
  ];

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      icon: Icons.verified_user,
      iconColor: ClearBridgeColors.success,
      title: 'Your Data is Safe',
      subtitle: 'MILITARY-GRADE ENCRYPTION ACTIVE',
      subtitleColor: ClearBridgeColors.success,
      child: Column(
        children: [
          for (final (icon, color, title, sub, desc) in _layers)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
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
                          Text(sub.toUpperCase(),
                              style: ClearBridgeTypography.label.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.05,
                                  fontSize: 10)),
                          const SizedBox(height: 6),
                          Text(desc,
                              style: ClearBridgeTypography.caption.copyWith(
                                  color: ClearBridgeColors.silver, height: 1.6)),
                        ],
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

// ── Settings bottom sheet ─────────────────────────────────────────────────────
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.onPersonalInfo,
    required this.onEncryption,
    required this.onPrivacy,
  });
  final VoidCallback onPersonalInfo;
  final VoidCallback onEncryption;
  final VoidCallback onPrivacy;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _push = true;
  bool _marketing = false;
  bool _deleting = false;

  Future<void> _deleteBiometricData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ClearBridgeColors.navy,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete My Fingerprint Data',
            style: ClearBridgeTypography.h3.copyWith(fontSize: 16)),
        content: Text(
          'This will permanently delete your fingerprint superprint and all '
          'captured frames. This cannot be undone.\n\n'
          'You will need to recapture to request future clearances.',
          style: ClearBridgeTypography.body.copyWith(
              color: ClearBridgeColors.silver, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: ClearBridgeTypography.body
                    .copyWith(color: ClearBridgeColors.silverDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete Permanently',
                style: ClearBridgeTypography.body.copyWith(
                    color: ClearBridgeColors.error,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Not authenticated');
      await FirebaseFunctions.instance
          .httpsCallable('deleteBiometricData')
          .call({'userId': uid});
      if (!mounted) return;
      Navigator.of(context).pop(); // close sheet
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fingerprint data permanently deleted.'),
          backgroundColor: ClearBridgeColors.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deletion failed: $e'),
          backgroundColor: ClearBridgeColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      icon: Icons.settings,
      iconColor: ClearBridgeColors.cyan,
      title: 'Settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetLabel('Account'),
          _SettingsLink(
            icon: Icons.person,
            color: ClearBridgeColors.cyan,
            label: 'Personal Info',
            sub: 'Edit your details',
            onTap: widget.onPersonalInfo,
          ),
          const SizedBox(height: 8),
          _SettingsLink(
            icon: Icons.verified_user,
            color: ClearBridgeColors.success,
            label: 'Security & Encryption',
            sub: 'AES-256 · Secure Enclave',
            onTap: widget.onEncryption,
          ),
          const SizedBox(height: 8),
          _SettingsLink(
            icon: Icons.gavel,
            color: ClearBridgeColors.gold,
            label: 'Privacy & Terms',
            sub: 'POPIA · Compliance details',
            onTap: widget.onPrivacy,
          ),
          const SizedBox(height: 16),
          _sheetLabel('Biometric Data'),
          // POPIA §24 right to erasure — biometric data only
          GestureDetector(
            onTap: _deleting ? null : _deleteBiometricData,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                color: ClearBridgeColors.error.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: ClearBridgeColors.error.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: ClearBridgeColors.error.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _deleting
                        ? const Padding(
                            padding: EdgeInsets.all(9),
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: ClearBridgeColors.error),
                          )
                        : const Icon(Icons.fingerprint,
                            size: 19, color: ClearBridgeColors.error),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Delete My Fingerprint Data',
                            style: ClearBridgeTypography.body.copyWith(
                                color: ClearBridgeColors.error,
                                fontWeight: FontWeight.w700,
                                fontSize: 13)),
                        const SizedBox(height: 1),
                        Text('Withdraw POPIA biometric consent',
                            style: ClearBridgeTypography.label.copyWith(
                                color: ClearBridgeColors.error
                                    .withValues(alpha: 0.6),
                                fontSize: 10)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right,
                      color: ClearBridgeColors.error.withValues(alpha: 0.5),
                      size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _sheetLabel('Preferences'),
          _SettingsToggle(
            icon: Icons.notifications,
            label: 'Push Notifications',
            sub: 'Status updates & alerts',
            value: _push,
            onChanged: (v) => setState(() => _push = v),
          ),
          const SizedBox(height: 8),
          _SettingsToggle(
            icon: Icons.campaign,
            label: 'Marketing Emails',
            sub: 'Offers & product news',
            value: _marketing,
            onChanged: (v) => setState(() => _marketing = v),
          ),
          const SizedBox(height: 16),
          _sheetLabel('Coming soon'),
          const _ComingSoonRow(
            icon: Icons.credit_card,
            iconColor: ClearBridgeColors.silverDim,
            title: 'Payment Methods',
            sub: 'Linked cards & wallets',
          ),
          const SizedBox(height: 8),
          const _ComingSoonRow(
            icon: Icons.support_agent,
            iconColor: ClearBridgeColors.silverDim,
            title: 'Support',
            sub: 'Email · chat · call',
          ),
        ],
      ),
    );
  }

  Widget _sheetLabel(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t.toUpperCase(),
            style: ClearBridgeTypography.label.copyWith(
                color: ClearBridgeColors.silverDim,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.12)),
      );
}

class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.icon,
    required this.color,
    required this.label,
    required this.sub,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: ClearBridgeTypography.body.copyWith(
                          color: ClearBridgeColors.silverBright,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                  const SizedBox(height: 1),
                  Text(sub,
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silverDim, fontSize: 10)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: color, size: 18),
          ],
        ),
      ),
    );
  }
}

class _SettingsToggle extends StatelessWidget {
  const _SettingsToggle({
    required this.icon,
    required this.label,
    required this.sub,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String label;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: ClearBridgeColors.cyan.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 19, color: ClearBridgeColors.cyan),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: ClearBridgeTypography.body.copyWith(
                        color: ClearBridgeColors.silverBright,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                const SizedBox(height: 1),
                Text(sub,
                    style: ClearBridgeTypography.label.copyWith(
                        color: ClearBridgeColors.silverDim, fontSize: 10)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: ClearBridgeColors.success,
            inactiveThumbColor: ClearBridgeColors.silverDim,
            inactiveTrackColor: ClearBridgeColors.rim,
          ),
        ],
      ),
    );
  }
}

/// Shared bottom-sheet shell: handle, header row, scrollable body.
class _SheetShell extends StatelessWidget {
  const _SheetShell({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    required this.child,
  });
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget child;

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
                Icon(icon, color: iconColor, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: ClearBridgeTypography.h3.copyWith(fontSize: 15)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 1),
                        Text(subtitle!,
                            style: ClearBridgeTypography.label.copyWith(
                                color: subtitleColor ?? ClearBridgeColors.cyan,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.06)),
                      ],
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
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
