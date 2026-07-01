import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/user_profile_provider.dart';

/// Privacy & Terms — Flutter port of the prototype `PrivacyScreen`: a consent
/// summary banner plus five "ACCEPTED" sections (POPIA, Credit Bureau, MAC 3D,
/// Marketing, Data Sharing).
class PrivacyPolicyScreen extends ConsumerWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <_Section>[
    _Section(
      icon: Icons.verified_user,
      color: ClearBridgeColors.cyan,
      title: 'Protection of Personal Information Act (POPIA)',
      content: [
        'ClearBridge collects and processes your personal information solely for the purpose of providing police clearance certificate services.',
        'Your data is stored securely and will not be shared with third parties without your explicit consent, except where required by law.',
        'You have the right to access, correct, or request deletion of your personal data at any time by contacting us.',
        'All personal information is processed lawfully, minimally, and for the specific purpose for which it was collected.',
      ],
    ),
    _Section(
      icon: Icons.credit_score,
      color: ClearBridgeColors.blueDark,
      title: 'Credit Bureau Reporting',
      content: [
        'ClearBridge may perform identity verification checks through accredited credit bureaus in South Africa.',
        'These checks are used solely for identity verification purposes and do not constitute a credit application.',
        'No credit score impact will result from these checks.',
      ],
    ),
    _Section(
      icon: Icons.fingerprint,
      color: ClearBridgeColors.success,
      title: 'MAC 3D — AI Fingerprint Reconstruction (Proprietary)',
      content: [
        'Your fingerprint is stored using the MAC 3D system (multi-angle capture 3D), which reconstructs a complete, court-grade print from four angles.',
      ],
    ),
    _Section(
      icon: Icons.campaign,
      color: ClearBridgeColors.gold,
      title: 'Marketing Communications',
      content: [
        'ClearBridge may send you service updates, promotional offers, and product notifications via SMS or email.',
        'You may opt out of marketing communications at any time via your profile settings.',
        'Transactional communications (e.g. application status updates) are not affected by marketing opt-outs.',
      ],
    ),
    _Section(
      icon: Icons.share,
      color: ClearBridgeColors.warning,
      title: 'Data Sharing & Partners',
      content: [
        'Your data may be shared with the South African Police Service (SAPS) and the Department of Home Affairs solely for clearance processing purposes.',
        'ClearBridge does not sell your personal data to any third party.',
        'All third-party integrations are governed by data processing agreements compliant with POPIA.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final name = [profile?.firstName, profile?.surname]
            .where((s) => s != null && s.isNotEmpty)
            .join(' ')
            .trim();

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      if (context.canPop()) context.pop();
                    },
                    child: const Icon(Icons.arrow_back,
                        color: ClearBridgeColors.silver, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Privacy & Terms',
                        style: ClearBridgeTypography.h3),
                  ),
                  const SizedBox(width: 22),
                ],
              ),
            ),
            // Consent summary banner
            Container(
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: ClearBridgeColors.success.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: ClearBridgeColors.success.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.task_alt,
                      color: ClearBridgeColors.success, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('All terms accepted',
                            style: ClearBridgeTypography.body.copyWith(
                                color: ClearBridgeColors.success,
                                fontWeight: FontWeight.w700,
                                fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(
                          name.isNotEmpty
                              ? '$name · Accepted at signup'
                              : 'Accepted at signup',
                          style: ClearBridgeTypography.label.copyWith(
                              color: ClearBridgeColors.silverDim, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Sections
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                children: [
                  for (final s in _sections) ...[
                    _SectionCard(section: s),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 4),
                  Center(
                    child: Column(
                      children: [
                        Text('For queries regarding your data, please contact us.',
                            textAlign: TextAlign.center,
                            style: ClearBridgeTypography.label.copyWith(
                                color: ClearBridgeColors.silverDim,
                                height: 1.7)),
                        const SizedBox(height: 4),
                        Text('ClearBridge (Pty) Ltd · Reg. No. 2026/151580/07',
                            textAlign: TextAlign.center,
                            style: ClearBridgeTypography.label.copyWith(
                                color:
                                    ClearBridgeColors.silver.withValues(alpha: 0.35),
                                fontSize: 10)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section {
  const _Section({
    required this.icon,
    required this.color,
    required this.title,
    required this.content,
  });
  final IconData icon;
  final Color color;
  final String title;
  final List<String> content;
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section});
  final _Section section;

  @override
  Widget build(BuildContext context) {
    final color = section.color;
    return Container(
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ClearBridgeColors.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.12), Colors.transparent],
              ),
              border: const Border(
                bottom: BorderSide(color: ClearBridgeColors.cardBorder),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(section.icon, size: 18, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(section.title,
                      style: ClearBridgeTypography.body.copyWith(
                          color: ClearBridgeColors.silverBright,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          height: 1.3)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: ClearBridgeColors.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(
                        color:
                            ClearBridgeColors.success.withValues(alpha: 0.35)),
                  ),
                  child: Text('ACCEPTED',
                      style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.success,
                          fontWeight: FontWeight.w800,
                          fontSize: 8,
                          letterSpacing: 0.1)),
                ),
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final para in section.content)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.only(top: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            boxShadow: [BoxShadow(color: color, blurRadius: 6)],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(para,
                              style: ClearBridgeTypography.caption.copyWith(
                                  color: ClearBridgeColors.silver,
                                  height: 1.65)),
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
