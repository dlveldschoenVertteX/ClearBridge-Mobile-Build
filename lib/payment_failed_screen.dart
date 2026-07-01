import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_primary_button.dart';
import 'package:clearbridge/payment_provider.dart';

class PaymentFailedScreen extends ConsumerWidget {
  const PaymentFailedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paymentState = ref.watch(paymentNotifierProvider);

    // Determine the title based on whether it was cancelled or failed
    final isCancelled = paymentState.status == PaymentStatus.cancelled;
    final title = isCancelled ? 'Payment Cancelled' : 'Payment Failed';
    final icon = isCancelled
        ? Icons.cancel_presentation_rounded
        : Icons.error_outline_rounded;
    final color =
        isCancelled ? ClearBridgeColors.warning : ClearBridgeColors.error;
    final message = paymentState.errorMessage ??
        (isCancelled
            ? 'The payment process was cancelled before completion.'
            : 'We were unable to process your payment. Please check your payment details and try again.');

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.4),
                    width: 2,
                  ),
                ),
                child: Icon(icon, color: color, size: 64),
              ),
              const SizedBox(height: 32),
              Text(
                title,
                style: ClearBridgeTypography.h1,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: ClearBridgeTypography.body,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              CbPrimaryButton(
                label: 'Try Again',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () {
                  ref.read(paymentNotifierProvider.notifier).setIdle();
                  // Go back to the payment summary screen to try again
                  context.go(AppConstants.paymentRoute);
                },
              ),
              const SizedBox(height: 12),
              CbPrimaryButton.ghost(
                label: 'Return to Dashboard',
                onPressed: () {
                  ref.read(paymentNotifierProvider.notifier).setIdle();
                  context.go(AppConstants.dashboardRoute);
                },
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
