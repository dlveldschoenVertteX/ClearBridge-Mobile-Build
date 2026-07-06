import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clearbridge_beta/cb_input_field.dart';
import 'package:clearbridge_beta/cb_primary_button.dart';
import 'package:clearbridge_beta/clearbridge_colors.dart';
import 'package:clearbridge_beta/clearbridge_typography.dart';

/// "Before You Begin" — beta participant details + POPIA biometric consent.
/// Anonymous-auth account for now; the phone number is collected so a
/// production migration can link this profile to a real account later
/// without losing ClearCoin balance/progress.
class UserDetailsPopiaScreen extends StatefulWidget {
  const UserDetailsPopiaScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  State<UserDetailsPopiaScreen> createState() => _UserDetailsPopiaScreenState();
}

class _UserDetailsPopiaScreenState extends State<UserDetailsPopiaScreen> {
  final _firstNameController = TextEditingController();
  final _surnameController = TextEditingController();
  final _ageController = TextEditingController();
  final _phoneController = TextEditingController();

  // All boxes start unchecked — POPIA requires active, unambiguous consent.
  bool _captureConsent = false;
  bool _superprintConsent = false;
  bool _reuseConsent = false;
  bool _durationConsent = false;
  bool _trainingOptIn = false;
  bool _trainingAnswered = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_firstNameController, _surnameController, _ageController, _phoneController]) {
      c.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _surnameController.dispose();
    _ageController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  int? get _age => int.tryParse(_ageController.text.trim());

  bool get _detailsValid =>
      _firstNameController.text.trim().length >= 2 &&
      _surnameController.text.trim().length >= 2 &&
      _age != null &&
      _age! >= 16 &&
      _age! <= 120;

  bool get _allRequired =>
      _detailsValid &&
      _captureConsent && _superprintConsent && _reuseConsent && _durationConsent &&
      _trainingAnswered;

  Future<void> _save() async {
    if (!_allRequired) return;
    setState(() => _saving = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _saving = false);
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'firstName': _firstNameController.text.trim(),
        'surname': _surnameController.text.trim(),
        'age': _age,
        'phone': _phoneController.text.trim(),
        'source': 'clearbridge_beta',
        'consents': {
          'captureConsent': true,
          'superprintConsent': true,
          'reuseConsent': true,
          'durationConsent': true,
          'dataTraining': _trainingOptIn,
          'consentedAt': FieldValue.serverTimestamp(),
          'version': '2.0',
        },
      }, SetOptions(merge: true));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save your details. Please try again.'),
          backgroundColor: ClearBridgeColors.error,
        ),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('popia_completed', true);
    if (mounted) widget.onContinue();
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
                      'Your fingerprint is biometric data under South African '
                      'POPIA. Please read and actively agree to each item below.',
                      style: ClearBridgeTypography.body,
                    ),
                    const SizedBox(height: 24),

                    _card(
                      icon: Icons.badge_outlined,
                      title: 'YOUR DETAILS',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: CbInputField(
                                  label: 'First Name',
                                  placeholder: 'Thabo',
                                  controller: _firstNameController,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: CbInputField(
                                  label: 'Surname',
                                  placeholder: 'Mtshali',
                                  controller: _surnameController,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          CbInputField(
                            label: 'Age',
                            placeholder: '25',
                            controller: _ageController,
                            keyboardType: TextInputType.number,
                            maxLength: 3,
                          ),
                          const SizedBox(height: 10),
                          CbInputField(
                            label: 'Phone Number (optional)',
                            placeholder: '082 123 4567',
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'So we can credit your ClearCoins to your account '
                            'once ClearBridge launches fully.',
                            style: ClearBridgeTypography.caption.copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    _card(
                      icon: Icons.verified_user_rounded,
                      title: 'POPIA BIOMETRIC CONSENT',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ConsentBox(
                            value: _captureConsent,
                            onChanged: (v) => setState(() => _captureConsent = v ?? false),
                            text: 'I consent to capturing my fingerprint for this beta.',
                          ),
                          const SizedBox(height: 10),
                          _ConsentBox(
                            value: _superprintConsent,
                            onChanged: (v) => setState(() => _superprintConsent = v ?? false),
                            text: 'I consent to ClearBridge storing my fingerprint '
                                'superprint to speed up future clearance applications.',
                          ),
                          const SizedBox(height: 10),
                          _ConsentBox(
                            value: _reuseConsent,
                            onChanged: (v) => setState(() => _reuseConsent = v ?? false),
                            text: 'I understand my fingerprint may be reused for '
                                'multiple clearance requests while I remain opted in.',
                          ),
                          const SizedBox(height: 10),
                          _ConsentBox(
                            value: _durationConsent,
                            onChanged: (v) => setState(() => _durationConsent = v ?? false),
                            text: 'I understand my superprint will be stored for the '
                                'duration of my active account, and I can request '
                                'permanent deletion at any time.',
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    _card(
                      icon: Icons.psychology_outlined,
                      title: 'HELP IMPROVE CLEARBRIDGE',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Switch(
                                value: _trainingOptIn,
                                onChanged: (v) => setState(() {
                                  _trainingOptIn = v;
                                  _trainingAnswered = true;
                                }),
                                activeThumbColor: Colors.white,
                                activeTrackColor: ClearBridgeColors.cyan,
                                inactiveThumbColor: ClearBridgeColors.silverDim,
                                inactiveTrackColor: ClearBridgeColors.rim,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Allow anonymised fingerprint data to train our AI '
                                  'model. Improves accuracy for all users.',
                                  style: ClearBridgeTypography.caption.copyWith(fontSize: 12, height: 1.4),
                                ),
                              ),
                            ],
                          ),
                          if (!_trainingAnswered) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Please make a selection to continue.',
                              style: ClearBridgeTypography.caption.copyWith(
                                color: ClearBridgeColors.cyan,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: CbPrimaryButton(
                label: 'Continue to Capture',
                icon: const Icon(Icons.arrow_forward),
                isLoading: _saving,
                onPressed: _allRequired && !_saving ? _save : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required IconData icon, required String title, required Widget child}) {
    return Container(
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
              Icon(icon, color: ClearBridgeColors.cyan, size: 16),
              const SizedBox(width: 6),
              Text(title, style: ClearBridgeTypography.eyebrow),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ConsentBox extends StatelessWidget {
  const _ConsentBox({required this.value, required this.onChanged, required this.text});

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
            color: value ? ClearBridgeColors.cyan : ClearBridgeColors.silverDim,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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
                  color: value ? ClearBridgeColors.silverBright : ClearBridgeColors.silver,
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
