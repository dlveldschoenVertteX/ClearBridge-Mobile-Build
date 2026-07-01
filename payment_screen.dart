import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../../../shared/widgets/cb_primary_button.dart';
import '../providers/payment_provider.dart';
import '../repository/pending_payment_repository.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/payment_result_handler.dart';

import '../../application/models/application_data.dart';
import '../../auth/providers/user_profile_provider.dart';
import '../../../core/config/app_config.dart';
import 'package:uuid/uuid.dart';

class PaymentScreen extends ConsumerWidget {
  const PaymentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugPrint('PaymentScreen: Building...');
    final selectedTier = ref.watch(selectedTierProvider);
    final paymentState = ref.watch(paymentNotifierProvider);
    final userProfile = ref.watch(userProfileProvider);
    final userId = ref.read(authProvider).valueOrNull?.uid;

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(),
            Expanded(
              child: userProfile.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: ClearBridgeColors.cyan,
                  ),
                ),
                error: (err, st) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Error loading profile: $err',
                      textAlign: TextAlign.center,
                      style: ClearBridgeTypography.body,
                    ),
                  ),
                ),
                data: (profile) {
                  final isPriority = selectedTier == 'priority';
                  final amount = isPriority
                      ? AppConstants.priorityTierAmount
                      : AppConstants.premiumTierAmount;
                  final processingTime = isPriority ? '2 hours' : '4 hours';

                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'SELECT CLEARANCE TIER',
                          style: ClearBridgeTypography.eyebrow,
                        ),
                        const SizedBox(height: 14),
                        _TierOption(
                          title: 'Priority Clearance',
                          price: 'R${AppConstants.priorityTierAmount}',
                          time: 'Processing: 2 hours',
                          isSelected: isPriority,
                          onTap: () => ref
                              .read(selectedTierProvider.notifier)
                              .setTier('priority'),
                        ),
                        const SizedBox(height: 12),
                        _TierOption(
                          title: 'Premium Clearance',
                          price: 'R${AppConstants.premiumTierAmount}',
                          time: 'Processing: 4 hours',
                          isSelected: !isPriority,
                          onTap: () => ref
                              .read(selectedTierProvider.notifier)
                              .setTier('premium'),
                        ),
                        const SizedBox(height: 28),
                        _SummaryCard(
                          tier: selectedTier,
                          amount: amount,
                          time: processingTime,
                        ),
                        const SizedBox(height: 36),
                        if (AppConfig.isBeta)
                          _BetaCreditButton(
                            onTap: () =>
                                context.go(AppConstants.dashboardRoute),
                          )
                        else
                          CbPrimaryButton(
                            label: 'Pay with Paystack',
                            icon: const Icon(Icons.lock_rounded),
                            isLoading:
                                paymentState.status == PaymentStatus.processing,
                            onPressed: paymentState.status ==
                                    PaymentStatus.processing
                                ? null
                                : () =>
                                    _handlePayment(context, ref, profile, userId),
                          ),
                        if (paymentState.status == PaymentStatus.error)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              paymentState.errorMessage ?? 'An error occurred',
                              style: ClearBridgeTypography.caption.copyWith(
                                color: ClearBridgeColors.error,
                                fontWeight: FontWeight.w700,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handlePayment(
    BuildContext context,
    WidgetRef ref,
    ApplicationData? profile,
    String? userId,
  ) async {
    final selectedTier = ref.read(selectedTierProvider);
    final amount = selectedTier == 'priority'
        ? AppConstants.priorityTierAmount
        : AppConstants.premiumTierAmount;

    if (profile?.email == null || profile!.email!.isEmpty) {
      ref
          .read(paymentNotifierProvider.notifier)
          .setError('User email not found. Please update your profile.');
      debugPrint('PaymentScreen: Error - Email is empty');
      return;
    }

    if (userId == null) {
      ref
          .read(paymentNotifierProvider.notifier)
          .setError('User not authenticated');
      debugPrint('PaymentScreen: Error - UserId is null');
      return;
    }

    debugPrint(
      'PaymentScreen: Handling payment for ${profile.email}, amount: $amount',
    );
    final paymentNotifier = ref.read(paymentNotifierProvider.notifier);
    paymentNotifier.setProcessing();

    try {
      debugPrint('PaymentScreen: Generating secure reference...');
      final String timestamp =
          DateTime.now().toUtc().millisecondsSinceEpoch.toString();
      final String randomStr = const Uuid().v4().substring(0, 8);
      final String reference = 'ref_${userId}_${timestamp}_$randomStr';

      debugPrint('PaymentScreen: Pre-persisting pending payment...');
      await ref.read(pendingPaymentRepositoryProvider).createPendingPayment(
            reference: reference,
            userId: userId,
            tier: selectedTier,
            amount: amount.toDouble(),
          );

      debugPrint('PaymentScreen: Preparing minimal metadata...');
      final metadata = {'userId': userId, 'tier': selectedTier};

      if (context.mounted) {
        await ref.read(paymentServiceProvider).startPayment(
              context: context,
              userId: userId,
              email: profile.email!,
              amountInZar: amount,
              reference: reference,
              metadata: metadata,
              onClosed: () {
                debugPrint('PaymentScreen: Popup was closed by user');
                if (context.mounted) {
                  context.go(AppConstants.paymentProcessingRoute);
                  ref
                      .read(paymentResultHandlerProvider)
                      .handlePostPayment(reference, wasClosedByUser: true);
                }
              },
              onSuccess: (refId) async {
                debugPrint(
                  'PaymentScreen: onSuccess callback reached. Reference: $refId',
                );
                if (context.mounted) {
                  context.go(AppConstants.paymentProcessingRoute);
                  ref
                      .read(paymentResultHandlerProvider)
                      .handlePostPayment(reference, wasClosedByUser: false);
                }
              },
            );
      }
    } catch (e, st) {
      debugPrint('PaymentScreen Error: $e');
      debugPrint(st.toString());
      if (context.mounted) {
        paymentNotifier.setError(e.toString());
      }
    } finally {
      if (context.mounted) {
        final currentState = ref.read(paymentNotifierProvider);
        if (currentState.status == PaymentStatus.processing) {
          paymentNotifier.setIdle();
        }
      }
    }
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (context.canPop()) context.pop();
            },
            child: Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0x0AFFFFFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x14FFFFFF)),
              ),
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: ClearBridgeColors.silverBright,
                size: 16,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('Payment', style: ClearBridgeTypography.h2),
        ],
      ),
    );
  }
}

class _TierOption extends StatelessWidget {
  const _TierOption({
    required this.title,
    required this.price,
    required this.time,
    required this.isSelected,
    required this.onTap,
  });

  final String title;
  final String price;
  final String time;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: isSelected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x2400BFFF), Color(0x0A00BFFF)],
                )
              : null,
          color: isSelected ? null : const Color(0x05FFFFFF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? ClearBridgeColors.cyan
                : const Color(0x14FFFFFF),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: ClearBridgeColors.cyan.withValues(alpha: 0.18),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: ClearBridgeTypography.h3.copyWith(
                      color: isSelected
                          ? ClearBridgeColors.silverBright
                          : ClearBridgeColors.silver,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(time, style: ClearBridgeTypography.caption),
                ],
              ),
            ),
            Text(
              price,
              style: ClearBridgeTypography.h2.copyWith(
                color: isSelected
                    ? ClearBridgeColors.cyan
                    : ClearBridgeColors.silverBright,
                fontSize: 20,
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color:
                  isSelected ? ClearBridgeColors.cyan : ClearBridgeColors.silverDim,
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.tier,
    required this.amount,
    required this.time,
  });

  final String tier;
  final int amount;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ClearBridgeColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ORDER SUMMARY', style: ClearBridgeTypography.eyebrow),
          const SizedBox(height: 18),
          _row('Selected Tier', tier.toUpperCase(), isBold: true),
          const Divider(height: 28, color: Color(0x14FFFFFF)),
          _row('Processing Time', time),
          const Divider(height: 28, color: Color(0x14FFFFFF)),
          _row(
            'Total Amount',
            'R$amount',
            isBold: true,
            valueColor: ClearBridgeColors.cyan,
            valueSize: 22,
          ),
        ],
      ),
    );
  }

  Widget _row(
    String label,
    String value, {
    bool isBold = false,
    Color? valueColor,
    double valueSize = 16,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: ClearBridgeTypography.body),
        Text(
          value,
          style: ClearBridgeTypography.body.copyWith(
            fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
            color: valueColor ?? ClearBridgeColors.silverBright,
            fontSize: valueSize,
          ),
        ),
      ],
    );
  }
}

class _BetaCreditButton extends StatelessWidget {
  const _BetaCreditButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ClearBridgeColors.success.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: ClearBridgeColors.success.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.card_giftcard,
                  color: ClearBridgeColors.success, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Beta Credit — R50 will be applied to your account. No payment required during beta.',
                  style: ClearBridgeTypography.caption.copyWith(
                    color: ClearBridgeColors.success,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        CbPrimaryButton(
          label: 'Continue (Beta)',
          icon: const Icon(Icons.arrow_forward),
          onPressed: onTap,
        ),
      ],
    );
  }
}
