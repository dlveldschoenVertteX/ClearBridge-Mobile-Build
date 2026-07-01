import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/error_dialog.dart';
import 'package:clearbridge/payment_provider.dart';

class PaymentProcessingScreen extends ConsumerWidget {
  const PaymentProcessingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Listen to payment state changes to navigate when verification completes
    ref.listen(paymentNotifierProvider, (previous, next) {
      debugPrint(
        'PaymentProcessingScreen: State changed from ${previous?.status} to ${next.status}',
      );
      if (next.status == PaymentStatus.success) {
        debugPrint(
          'PaymentProcessingScreen: Success detected, navigating to success screen',
        );
        context.go(AppConstants.paymentSuccessRoute);
      } else if (next.status == PaymentStatus.cancelled) {
        // Cancelled: show dialog with specific message before navigating
        ErrorDialog.show(
          context: context,
          title: 'Payment Cancelled',
          message: next.errorMessage ??
              'The payment was cancelled before completion. No charges were made.',
          buttonText: 'OK',
          onPressed: () => context.go(AppConstants.paymentFailedRoute),
        );
      } else if (next.status == PaymentStatus.failed ||
          next.status == PaymentStatus.error) {
        // Failed: show dialog with specific message before navigating
        ErrorDialog.show(
          context: context,
          title: 'Payment Verification Failed',
          message: next.errorMessage ??
              'We could not verify your payment. Please contact support if your account was charged.',
          buttonText: 'OK',
          onPressed: () => context.go(AppConstants.paymentFailedRoute),
        );
      }
    });

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      ClearBridgeColors.cyan,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Verifying payment…',
                  style: ClearBridgeTypography.h2,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Please wait while we confirm your transaction securely with our servers.',
                  textAlign: TextAlign.center,
                  style: ClearBridgeTypography.body,
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: ClearBridgeColors.cardBg,
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(color: ClearBridgeColors.cardBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: ClearBridgeColors.success,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Secure Connection',
                        style: ClearBridgeTypography.label.copyWith(
                          color: ClearBridgeColors.silver,
                          letterSpacing: 0.06,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () {
                    debugPrint(
                      'PaymentProcessingScreen: User cancelled payment',
                    );
                    ref.read(paymentNotifierProvider.notifier).setCancelled();
                  },
                  child: Text(
                    'Cancel Payment',
                    style: ClearBridgeTypography.body.copyWith(
                      color: ClearBridgeColors.silverDim,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'If you completed payment but verification is taking too long, please wait a few more moments or contact support.',
                  textAlign: TextAlign.center,
                  style: ClearBridgeTypography.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
