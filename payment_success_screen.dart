import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../../../shared/widgets/cb_primary_button.dart';
import '../providers/payment_provider.dart';

class PaymentSuccessScreen extends ConsumerStatefulWidget {
  const PaymentSuccessScreen({super.key});

  @override
  ConsumerState<PaymentSuccessScreen> createState() =>
      _PaymentSuccessScreenState();
}

class _PaymentSuccessScreenState extends ConsumerState<PaymentSuccessScreen> {
  int _countdown = 3;

  @override
  void initState() {
    super.initState();
    // Auto-navigate to dashboard after 3 seconds
    _autoNavigateToDashboard();
  }

  void _autoNavigateToDashboard() {
    for (int i = 3; i > 0; i--) {
      Future.delayed(Duration(seconds: 3 - i), () {
        if (mounted) {
          setState(() {
            _countdown = i - 1;
          });
        }
      });
    }

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        debugPrint('PaymentSuccessScreen: Auto-navigating to dashboard');
        ref.read(paymentNotifierProvider.notifier).setIdle();
        context.go(AppConstants.dashboardRoute);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final paymentState = ref.watch(paymentNotifierProvider);

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
                  color: ClearBridgeColors.success.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ClearBridgeColors.success.withValues(alpha: 0.4),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: ClearBridgeColors.success.withValues(alpha: 0.3),
                      blurRadius: 36,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: ClearBridgeColors.success,
                  size: 64,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Payment Received',
                style: ClearBridgeTypography.h1,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Your clearance request is currently being processed. You will be notified once it is ready.',
                style: ClearBridgeTypography.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              if (paymentState.transactionRef != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: ClearBridgeColors.cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ClearBridgeColors.cardBorder),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'REFERENCE',
                        style: ClearBridgeTypography.eyebrow,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          paymentState.transactionRef!,
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: ClearBridgeTypography.mono.copyWith(
                            color: ClearBridgeColors.silverBright,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              CbPrimaryButton(
                label: _countdown > 0
                    ? 'Go to Dashboard ($_countdown)'
                    : 'Going to Dashboard…',
                icon: const Icon(Icons.arrow_forward),
                onPressed: _countdown > 0
                    ? () {
                        ref.read(paymentNotifierProvider.notifier).setIdle();
                        context.go(AppConstants.dashboardRoute);
                      }
                    : null,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
