import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_input_field.dart';
import 'package:clearbridge/cb_primary_button.dart';
import 'package:clearbridge/application_provider.dart';
import 'package:clearbridge/auth_repository.dart';
import 'package:clearbridge/user_profile_provider.dart';

/// "Your Details" — matches the prototype `UserDetailsScreen` (4 fields +
/// POPIA consent toggle). The richer clearance fields (address, province,
/// etc.) are not collected in the beta; they are submitted empty so the
/// existing [ApplicationSubmit.submit] contract is preserved. SA-ID validation
/// and DOB extraction logic are retained.
class PersonalDetailsScreen extends ConsumerStatefulWidget {
  const PersonalDetailsScreen({super.key});

  @override
  ConsumerState<PersonalDetailsScreen> createState() =>
      _PersonalDetailsScreenState();
}

class _PersonalDetailsScreenState extends ConsumerState<PersonalDetailsScreen> {
  final _firstNameController = TextEditingController();
  final _surnameController = TextEditingController();
  final _emailAddressController = TextEditingController();
  final _idNumberController = TextEditingController();

  String _phone = '';
  DateTime? _extractedDob;
  bool _accepted = false;

  /// True when the screen is opened to EDIT an already-completed profile
  /// (Profile → Personal Info), as opposed to the onboarding first-run.
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user?.phoneNumber != null) _phone = user!.phoneNumber!;

    // Pre-fill from the existing profile when editing. The same screen is
    // reused for onboarding, where there is nothing to pre-fill.
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (profile != null &&
        profile.firstName.isNotEmpty &&
        profile.idNumber.isNotEmpty) {
      _isEditing = true;
      _firstNameController.text = profile.firstName;
      _surnameController.text = profile.surname;
      _emailAddressController.text = profile.email ?? '';
      _idNumberController.text = profile.idNumber;
      if (profile.phone.isNotEmpty) _phone = profile.phone;
      _accepted = true; // already consented during onboarding
      if (profile.idNumber.length == 13 && _validateSAID(profile.idNumber)) {
        _extractedDob = _extractDOB(profile.idNumber);
      }
    }

    _firstNameController.addListener(_refresh);
    _surnameController.addListener(_refresh);
    _idNumberController.addListener(_onIdChanged);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _surnameController.dispose();
    _emailAddressController.dispose();
    _idNumberController.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _onIdChanged() {
    final val = _idNumberController.text.trim();
    if (val.length == 13 && _validateSAID(val)) {
      _extractedDob = _extractDOB(val);
    } else {
      _extractedDob = null;
    }
    setState(() {});
  }

  bool get _canContinue =>
      _accepted &&
      _firstNameController.text.trim().length >= 2 &&
      _surnameController.text.trim().length >= 2 &&
      _idNumberController.text.trim().isNotEmpty;

  bool _validateSAID(String idNumber) {
    if (idNumber.length != 13) return false;
    if (!RegExp(r'^[0-9]+$').hasMatch(idNumber)) return false;
    int nCheck = 0, nDigit = 0;
    bool bEven = false;
    for (int i = idNumber.length - 1; i >= 0; i--) {
      nDigit = int.parse(idNumber[i]);
      if (bEven) {
        if ((nDigit *= 2) > 9) nDigit -= 9;
      }
      nCheck += nDigit;
      bEven = !bEven;
    }
    return (nCheck % 10) == 0;
  }

  DateTime? _extractDOB(String idNumber) {
    if (idNumber.length < 6) return null;
    try {
      final year = int.parse(idNumber.substring(0, 2));
      final month = int.parse(idNumber.substring(2, 4));
      final day = int.parse(idNumber.substring(4, 6));
      final currentYY =
          int.parse(DateTime.now().toUtc().year.toString().substring(2, 4));
      final fullYear = year > currentYY ? 1900 + year : 2000 + year;
      return DateTime(fullYear, month, day);
    } catch (_) {
      return null;
    }
  }

  bool _isValidEmail(String email) => RegExp(
        r"^[a-zA-Z0-9.!#$%&'*+-/=?^_`{|}~]+@[a-zA-Z0-9]+\.[a-zA-Z]+",
      ).hasMatch(email);

  Future<void> _submit() async {
    final id = _idNumberController.text.trim();
    if (!_validateSAID(id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid South African ID number'),
          backgroundColor: ClearBridgeColors.error,
        ),
      );
      return;
    }
    final email = _emailAddressController.text.trim();
    if (email.isNotEmpty && !_isValidEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid email address'),
          backgroundColor: ClearBridgeColors.error,
        ),
      );
      return;
    }

    await ref.read(applicationSubmitProvider.notifier).submit(
          firstName: _firstNameController.text.trim(),
          surname: _surnameController.text.trim(),
          phone: _phone,
          email: email,
          idNumber: id,
          dob: _extractedDob,
          streetAddress: '',
          suburb: '',
          city: '',
          province: '',
          postalCode: '',
          currentLocation: '',
          referredBy: null,
        );

    if (!mounted) return;
    final state = ref.read(applicationSubmitProvider);
    if (state.hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(state.error.toString()),
          backgroundColor: ClearBridgeColors.error,
        ),
      );
    } else if (_isEditing && context.canPop()) {
      // Editing from Profile → return where we came from.
      context.pop();
    } else {
      context.go(AppConstants.dashboardRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitState = ref.watch(applicationSubmitProvider);
    final isSubmitting = submitState.isLoading;

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Nav row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: () {
                      if (context.canPop()) context.pop();
                    },
                    child: const Icon(Icons.arrow_back,
                        color: ClearBridgeColors.silver, size: 22),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isEditing ? 'EDIT PROFILE' : 'STEP 1 OF 3',
                        style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silverDim,
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const _BetaBadge(),
                    ],
                  ),
                  const SizedBox(width: 24),
                ],
              ),
              const SizedBox(height: 8),
              Text('Your Details', style: ClearBridgeTypography.h2),
              const SizedBox(height: 2),
              Text(
                'Personal info & data consent',
                style: ClearBridgeTypography.label.copyWith(
                  color: ClearBridgeColors.silverDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        label: 'Email (optional)',
                        placeholder: 'you@email.com',
                        controller: _emailAddressController,
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 10),
                      CbInputField(
                        label: 'SA ID Number',
                        placeholder: '000000 0000 000',
                        controller: _idNumberController,
                        keyboardType: TextInputType.number,
                        maxLength: 13,
                      ),
                      const SizedBox(height: 14),
                      _PopiaConsent(
                        accepted: _accepted,
                        onToggle: () => setState(() => _accepted = !_accepted),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: CbPrimaryButton.ghost(
                      label: _isEditing ? 'Cancel' : 'Decline',
                      onPressed: () {
                        if (context.canPop()) context.pop();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 14,
                    child: CbPrimaryButton(
                      label: _isEditing ? 'Save Changes' : 'Continue',
                      isLoading: isSubmitting,
                      onPressed:
                          _canContinue && !isSubmitting ? _submit : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BetaBadge extends StatelessWidget {
  const _BetaBadge();

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

class _PopiaConsent extends StatelessWidget {
  const _PopiaConsent({required this.accepted, required this.onToggle});

  final bool accepted;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ClearBridgeColors.cyan.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user,
                  color: ClearBridgeColors.cyan, size: 18),
              const SizedBox(width: 6),
              Text(
                'POPIA CONSENT',
                style: ClearBridgeTypography.eyebrow.copyWith(
                  letterSpacing: 0.18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text.rich(
            TextSpan(
              text:
                  'By continuing, you consent to ClearBridge processing your personal data for identity verification, credit bureau reporting, ML fingerprint training, and service communications — in compliance with the ',
              style: ClearBridgeTypography.caption.copyWith(
                color: ClearBridgeColors.silver,
                fontSize: 11,
                height: 1.65,
              ),
              children: [
                TextSpan(
                  text: 'Protection of Personal Information Act (POPIA)',
                  style: ClearBridgeTypography.caption.copyWith(
                    color: ClearBridgeColors.silverBright,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    height: 1.65,
                  ),
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onToggle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: accepted
                    ? ClearBridgeColors.cyan.withValues(alpha: 0.07)
                    : Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: accepted
                      ? ClearBridgeColors.cyan
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'I accept all terms',
                          style: ClearBridgeTypography.body.copyWith(
                            color: ClearBridgeColors.silverBright,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'POPIA · Credit · ML · Marketing · Sharing',
                          style: ClearBridgeTypography.label.copyWith(
                            color: ClearBridgeColors.silverDim,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _MiniSwitch(on: accepted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 46,
      height: 26,
      decoration: BoxDecoration(
        color: on
            ? ClearBridgeColors.cyan
            : ClearBridgeColors.silver.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(13),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.all(3),
          width: 20,
          height: 20,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Color(0x4D000000), blurRadius: 6),
            ],
          ),
        ),
      ),
    );
  }
}
