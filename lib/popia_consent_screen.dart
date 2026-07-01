import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_primary_button.dart';

class BetaConsentScreen extends StatefulWidget {
  const BetaConsentScreen({super.key});

  @override
  State<BetaConsentScreen> createState() => _BetaConsentScreenState();
}

class _BetaConsentScreenState extends State<BetaConsentScreen> {
  // All boxes start unchecked — POPIA requires active, unambiguous consent.
  bool _captureConsent        = false;
  bool _superprintConsent     = false;
  bool _reuseConsent          = false;
  bool _durationConsent       = false;
  bool _trainingOptIn         = false;
  bool _loading               = false;

  bool get _allRequired =>
      _captureConsent && _superprintConsent && _reuseConsent && _durationConsent;

  Future<void> _saveConsent() async {
    if (!_allRequired) return;
    setState(() => _loading = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'consents': {
        'captureConsent':        true,
        'superprintConsent':     true,
        'reuseConsent':          true,
        'durationConsent':       true,
        'dataTraining':          _trainingOptIn,
        'consentedAt':           FieldValue.serverTimestamp(),
        'version':               '2.0',
        'biometricConsentWithdrawn': false,
        'withdrawalDate':        null,
      },
    }, SetOptions(merge: true));
    if (mounted) context.go(AppConstants.fingerprintRoute);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Before You Begin', style: ClearBridgeTypography.h1),
                    const SizedBox(height: 8),
                    Text(
                      'Your fingerprint is biometric data under South African POPIA. '
                      'Please read and actively agree to each item below.',
                      style: ClearBridgeTypography.body,
                    ),
                    const SizedBox(height: 24),

                    // ── 4 required consent checkboxes ─────────────────────────
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: ClearBridgeColors.cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: ClearBridgeColors.cardBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.verified_user_rounded,
                                  color: ClearBridgeColors.cyan, size: 16),
                              const SizedBox(width: 6),
                              Text('POPIA BIOMETRIC CONSENT',
                                  style: ClearBridgeTypography.eyebrow),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _ConsentBox(
                            value: _captureConsent,
                            onChanged: (v) =>
                                setState(() => _captureConsent = v ?? false),
                            text: 'I consent to capturing my fingerprint for '
                                'this police clearance application.',
                          ),
                          const SizedBox(height: 10),
                          _ConsentBox(
                            value: _superprintConsent,
                            onChanged: (v) =>
                                setState(() => _superprintConsent = v ?? false),
                            text: 'I consent to ClearBridge storing my '
                                'fingerprint superprint to speed up future '
                                'clearance applications.',
                          ),
                          const SizedBox(height: 10),
                          _ConsentBox(
                            value: _reuseConsent,
                            onChanged: (v) =>
                                setState(() => _reuseConsent = v ?? false),
                            text: 'I understand my fingerprint may be reused '
                                'for multiple clearance requests while I remain '
                                'opted in.',
                          ),
                          const SizedBox(height: 10),
                          _ConsentBox(
                            value: _durationConsent,
                            onChanged: (v) =>
                                setState(() => _durationConsent = v ?? false),
                            text: 'I understand my superprint will be stored '
                                'for the duration of my active account, and I '
                                'can request permanent deletion at any time.',
                          ),
                          const SizedBox(height: 14),
                          // Withdrawal notice
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: ClearBridgeColors.cyan.withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: ClearBridgeColors.cyan
                                      .withValues(alpha: 0.2)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline,
                                    color: ClearBridgeColors.cyan, size: 14),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'You can withdraw consent anytime from '
                                    'Settings → Delete My Fingerprint Data.',
                                    style: ClearBridgeTypography.caption
                                        .copyWith(
                                      fontSize: 11,
                                      color: ClearBridgeColors.cyan,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── Optional training opt-in ───────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: ClearBridgeColors.cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: ClearBridgeColors.cardBorder),
                      ),
                      child: Row(
                        children: [
                          Switch(
                            value: _trainingOptIn,
                            onChanged: (v) =>
                                setState(() => _trainingOptIn = v),
                            activeThumbColor: Colors.white,
                            activeTrackColor: ClearBridgeColors.cyan,
                            inactiveThumbColor: ClearBridgeColors.silverDim,
                            inactiveTrackColor: ClearBridgeColors.rim,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Help Improve ClearBridge (Optional)',
                                  style: ClearBridgeTypography.body.copyWith(
                                    color: ClearBridgeColors.silverBright,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Allow anonymised fingerprint data to train our '
                                  'AI model. Improves accuracy for all users.',
                                  style: ClearBridgeTypography.caption
                                      .copyWith(fontSize: 12, height: 1.4),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            // ── Bottom actions ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                children: [
                  CbPrimaryButton(
                    label: 'Continue to Capture',
                    icon: const Icon(Icons.arrow_forward),
                    isLoading: _loading,
                    onPressed:
                        _allRequired && !_loading ? _saveConsent : null,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.go('/privacy'),
                    child: Text(
                      'View Full Privacy Policy',
                      style: ClearBridgeTypography.caption.copyWith(
                        color: ClearBridgeColors.silverDim,
                        fontSize: 12,
                      ),
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

// ── Consent checkbox row ──────────────────────────────────────────────────────

class _ConsentBox extends StatelessWidget {
  const _ConsentBox({
    required this.value,
    required this.onChanged,
    required this.text,
  });

  final bool value;
  final ValueChanged<bool?> onChanged;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          value: value,
          onChanged: onChanged,
          activeColor: ClearBridgeColors.cyan,
          checkColor: Colors.white,
          side: BorderSide(
            color: value
                ? ClearBridgeColors.cyan
                : ClearBridgeColors.silverDim,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: () => onChanged(!value),
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text,
                style: ClearBridgeTypography.caption.copyWith(
                  color: value
                      ? ClearBridgeColors.silverBright
                      : ClearBridgeColors.silver,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
