import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_primary_button.dart';
import 'package:clearbridge/cb_otp_input.dart';
import 'package:clearbridge/error_dialog.dart';
import 'package:clearbridge/auth_controller_provider.dart';

class OtpVerificationScreen extends ConsumerStatefulWidget {
  final String phoneNumber;
  final String verificationId;
  final String referralCode;

  const OtpVerificationScreen({
    super.key,
    required this.phoneNumber,
    required this.verificationId,
    this.referralCode = '',
  });

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  String _otpCode = '';
  late String _currentVerificationId;
  int _resendCountdown = 60;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _currentVerificationId = widget.verificationId;
    _startCountdown();
  }

  void _startCountdown() {
    setState(() => _resendCountdown = 60);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCountdown > 0) {
        setState(() => _resendCountdown--);
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _verifyOtp() {
    if (_otpCode.length != 6) {
      ErrorDialog.show(
        context: context,
        title: 'Incomplete Code',
        message: 'Please enter all 6 digits of your OTP.',
      );
      return;
    }
    ref.read(authControllerProvider.notifier).verifyOtp(
          verificationId: _currentVerificationId,
          smsCode: _otpCode,
          onSuccess: () async {
            debugPrint('OTP verified successfully, waiting for router redirect');
            final code = widget.referralCode.trim().toUpperCase();
            if (code.isNotEmpty) {
              final uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid != null) {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(uid)
                    .set({'usedReferralCode': code}, SetOptions(merge: true));
              }
            }
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

  void _resendCode() {
    if (_resendCountdown > 0) return;
    ref.read(authControllerProvider.notifier).verifyPhoneNumber(
          phoneNumber: widget.phoneNumber,
          onCodeSent: (newVerificationId) {
            if (!mounted) return;
            setState(() => _currentVerificationId = newVerificationId);
            _startCountdown();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Code resent successfully ✓')),
            );
          },
          onError: (error) {
            if (!mounted) return;
            ErrorDialog.show(
              context: context,
              title: 'Failed to Resend Code',
              message: error,
              buttonText: 'OK',
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              // Header — logo glow + title + phone
              SizedBox(
                height: 96,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            ClearBridgeColors.cyan.withValues(alpha: 0.2),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.7],
                        ),
                      ),
                    ),
                    Image.asset(
                      AppConstants.logoPath,
                      width: 64,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Verify your number',
                style: ClearBridgeTypography.h1.copyWith(fontSize: 22),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  text: 'Code sent to ',
                  style: ClearBridgeTypography.caption.copyWith(
                    color: ClearBridgeColors.silver,
                    fontSize: 13,
                  ),
                  children: [
                    TextSpan(
                      text: widget.phoneNumber,
                      style: ClearBridgeTypography.caption.copyWith(
                        color: ClearBridgeColors.cyan,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              Text(
                'ENTER 6-DIGIT CODE',
                style: ClearBridgeTypography.label.copyWith(
                  letterSpacing: 0.16,
                  fontWeight: FontWeight.w700,
                  color: ClearBridgeColors.silverDim,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              CbOtpInput(
                length: 6,
                onChanged: (code) => setState(() => _otpCode = code),
                onCompleted: (code) {
                  setState(() => _otpCode = code);
                  if (!isLoading) _verifyOtp();
                },
              ),
              const SizedBox(height: 22),
              GestureDetector(
                onTap: (isLoading || _resendCountdown > 0) ? null : _resendCode,
                child: Text.rich(
                  _resendCountdown > 0
                      ? TextSpan(
                          text: 'Resend code in ',
                          style: ClearBridgeTypography.caption.copyWith(
                            color: ClearBridgeColors.silverDim,
                          ),
                          children: [
                            TextSpan(
                              text:
                                  '0:${_resendCountdown.toString().padLeft(2, '0')}',
                              style: ClearBridgeTypography.mono.copyWith(
                                color: ClearBridgeColors.silver,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        )
                      : TextSpan(
                          text: 'Resend code',
                          style: ClearBridgeTypography.caption.copyWith(
                            color: ClearBridgeColors.cyan,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                  textAlign: TextAlign.center,
                ),
              ),
              const Spacer(),
              CbPrimaryButton(
                label: 'Verify & Continue',
                icon: const Icon(Icons.arrow_forward),
                isLoading: isLoading,
                onPressed:
                    _otpCode.length == 6 && !isLoading ? _verifyOtp : null,
              ),
              const SizedBox(height: 14),
              Center(
                child: GestureDetector(
                  onTap: () {
                    if (context.canPop()) context.pop();
                  },
                  child: Text(
                    '← Wrong number?',
                    style: ClearBridgeTypography.caption.copyWith(
                      color: ClearBridgeColors.cyan,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
