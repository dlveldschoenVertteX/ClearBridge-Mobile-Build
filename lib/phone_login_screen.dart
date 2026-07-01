import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/cb_primary_button.dart';
import 'package:clearbridge/error_dialog.dart';
import 'package:clearbridge/auth_controller_provider.dart';

/// Sign-up — phone step. Matches the prototype `SignUpScreen` (phone step):
/// hero logo + Beta/Fast/Secure/Digital badges + tagline pill, phone field,
/// POPIA line, "Send OTP Code". Firebase phone-auth logic is unchanged; the
/// OTP step lives in [OtpVerificationScreen].
class PhoneLoginScreen extends ConsumerStatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  ConsumerState<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends ConsumerState<PhoneLoginScreen>
    with TickerProviderStateMixin {
  String _phoneNumber = '';
  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;
  late final AnimationController _entryCtrl;
  late final Animation<double> _entryFade;
  late final Animation<Offset> _entrySlide;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat(reverse: true);
    _glowAnim = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);

    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    _entryFade = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic);
    _entrySlide = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    _entryCtrl.dispose();
    super.dispose();
  }

  void _startLogin() {
    if (_phoneNumber.isEmpty) return;
    ref.read(authControllerProvider.notifier).verifyPhoneNumber(
          phoneNumber: _phoneNumber,
          onCodeSent: (verificationId) {
            context.push(
              AppConstants.otpRoute,
              extra: {
                'phoneNumber': _phoneNumber,
                'verificationId': verificationId,
                'referralCode': '',
              },
            );
          },
          onError: (error) {
            if (!mounted) return;
            ErrorDialog.show(
              context: context,
              title: 'Verification Failed',
              message: error,
              buttonText: 'Try Again',
            );
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.isLoading;

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: FadeTransition(
          opacity: _entryFade,
          child: SlideTransition(
            position: _entrySlide,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _GlowLogo(animation: _glowAnim),
                            const SizedBox(height: 6),
                            const _BadgeRow(),
                            const SizedBox(height: 12),
                            const _TaglinePill(),
                            const SizedBox(height: 28),
                            Text(
                              'Create your account',
                              style: ClearBridgeTypography.h2.copyWith(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: Text(
                                'Enter your phone number to receive a one-time verification code',
                                style: ClearBridgeTypography.caption.copyWith(
                                  color: ClearBridgeColors.silverDim,
                                  height: 1.5,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(height: 18),
                            _PhoneField(
                              onChanged: (number) =>
                                  setState(() => _phoneNumber = number),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.lock,
                                    size: 14,
                                    color: ClearBridgeColors.silverDim),
                                const SizedBox(width: 6),
                                Text(
                                  'Protected under POPIA · End-to-end encrypted',
                                  style: ClearBridgeTypography.label.copyWith(
                                    color: ClearBridgeColors.silverDim,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            CbPrimaryButton(
                              label: 'Send OTP Code',
                              icon: const Icon(Icons.send_rounded),
                              isLoading: isLoading,
                              onPressed: _phoneNumber.isNotEmpty && !isLoading
                                  ? _startLogin
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            Text.rich(
                              TextSpan(
                                text: 'Already have an account? ',
                                style: ClearBridgeTypography.caption.copyWith(
                                  color: ClearBridgeColors.silverDim,
                                ),
                                children: [
                                  TextSpan(
                                    text: 'Sign In',
                                    style:
                                        ClearBridgeTypography.caption.copyWith(
                                      color: ClearBridgeColors.cyan,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _GlowLogo extends StatelessWidget {
  const _GlowLogo({required this.animation});
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final size = (screenWidth * 0.42).clamp(120.0, 168.0);

    return SizedBox(
      width: size + 80,
      height: size + 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: animation,
            builder: (_, __) => Opacity(
              opacity: 0.6 + 0.4 * animation.value,
              child: Transform.scale(
                scale: 1.0 + 0.08 * animation.value,
                child: Container(
                  width: size + 60,
                  height: size + 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        ClearBridgeColors.cyan.withValues(alpha: 0.28),
                        ClearBridgeColors.cyan.withValues(alpha: 0.07),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5, 0.75],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Image.asset(
            AppConstants.logoPath,
            width: size,
            errorBuilder: (_, __, ___) =>
                Text('ClearBridge', style: ClearBridgeTypography.h1),
          ),
        ],
      ),
    );
  }
}

class _BadgeRow extends StatelessWidget {
  const _BadgeRow();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        _Badge(
          label: 'BETA',
          bg: Color(0x26C9A84C),
          border: Color(0x66C9A84C),
          textColor: ClearBridgeColors.gold,
        ),
        _Badge(
          label: 'FAST',
          bg: Color(0xEBE2E8F0),
          border: Color(0x99E2E8F0),
          textColor: Color(0xFF0B0F1A),
        ),
        _Badge(
          label: 'SECURE',
          bg: Color(0x471E88E5),
          border: Color(0x8C1E88E5),
          textColor: Colors.white,
        ),
        _Badge(
          label: 'DIGITAL',
          bg: Color(0x2400BFFF),
          border: Color(0x8C00BFFF),
          textColor: ClearBridgeColors.cyan,
          glow: true,
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.bg,
    required this.border,
    required this.textColor,
    this.glow = false,
  });
  final String label;
  final Color bg;
  final Color border;
  final Color textColor;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: border),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: ClearBridgeColors.cyan.withValues(alpha: 0.5),
                  blurRadius: 14,
                ),
              ]
            : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.10,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

class _TaglinePill extends StatefulWidget {
  const _TaglinePill();

  @override
  State<_TaglinePill> createState() => _TaglinePillState();
}

class _TaglinePillState extends State<_TaglinePill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: ClearBridgeColors.cyan.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: ClearBridgeColors.cyan.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween<double>(begin: 0.4, end: 1.0).animate(_c),
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: ClearBridgeColors.cyan,
                boxShadow: [
                  BoxShadow(color: ClearBridgeColors.cyan, blurRadius: 10),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'POLICE CLEARANCE REIMAGINED',
            style: ClearBridgeTypography.eyebrow.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.14,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneField extends StatelessWidget {
  const _PhoneField({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return IntlPhoneField(
      decoration: InputDecoration(
        hintText: '8X XXX XXXX',
        hintStyle: ClearBridgeTypography.body
            .copyWith(color: ClearBridgeColors.silverDim),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.03),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0x14FFFFFF), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ClearBridgeColors.cyan, width: 1),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0x14FFFFFF), width: 1),
        ),
      ),
      initialCountryCode: 'ZA',
      style: ClearBridgeTypography.body.copyWith(
        color: ClearBridgeColors.silverBright,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      dropdownTextStyle: ClearBridgeTypography.body
          .copyWith(color: ClearBridgeColors.silverBright),
      dropdownIcon:
          const Icon(Icons.arrow_drop_down, color: ClearBridgeColors.silver),
      pickerDialogStyle: PickerDialogStyle(
        backgroundColor: ClearBridgeColors.navy,
        countryCodeStyle: const TextStyle(color: ClearBridgeColors.silverBright),
        countryNameStyle: const TextStyle(color: ClearBridgeColors.silverBright),
        searchFieldCursorColor: ClearBridgeColors.cyan,
        searchFieldInputDecoration: InputDecoration(
          hintText: 'Search country',
          hintStyle: const TextStyle(color: ClearBridgeColors.silverDim),
          prefixIcon: const Icon(Icons.search, color: ClearBridgeColors.silver),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      onChanged: (phone) => onChanged(phone.completeNumber),
    );
  }
}
