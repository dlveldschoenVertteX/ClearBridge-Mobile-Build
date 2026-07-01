import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_pill.dart';
import 'package:clearbridge/cb_primary_button.dart';
import 'package:clearbridge/cb_progress_dots.dart';
import 'package:clearbridge/payment_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ServiceTierScreen extends ConsumerStatefulWidget {
  const ServiceTierScreen({super.key});

  @override
  ConsumerState<ServiceTierScreen> createState() => _ServiceTierScreenState();
}

class _ServiceTierScreenState extends ConsumerState<ServiceTierScreen> {
  void _handleBack() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppConstants.dashboardRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: ClearBridgeColors.void_,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _handleBack,
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
                    Expanded(
                      child: Text(
                        'Police Clearance',
                        style: ClearBridgeTypography.h2,
                      ),
                    ),
                    const CbProgressDots(total: 3, current: 1),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('CHOOSE YOUR TIER',
                          style: ClearBridgeTypography.eyebrow),
                      const SizedBox(height: 14),
                      _buildTierCard(
                        ref,
                        'priority',
                        'Priority Clearance',
                        'R${AppConstants.priorityTierAmount}',
                        'Fastest processing time.\nCleared within 2 hours.',
                        isRecommended: true,
                        isHot: true,
                      ),
                      const SizedBox(height: 14),
                      _buildTierCard(
                        ref,
                        'premium',
                        'Premium Clearance',
                        'R${AppConstants.premiumTierAmount}',
                        'Regular processing time.\nCleared within 4 hours.',
                        isRecommended: false,
                        isHot: false,
                      ),
                      const SizedBox(height: 36),
                      CbPrimaryButton(
                        label: 'Proceed to Payment',
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: () =>
                            context.push(AppConstants.paymentRoute),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTierCard(
    WidgetRef ref,
    String id,
    String title,
    String price,
    String description, {
    required bool isRecommended,
    required bool isHot,
  }) {
    final selectedTier = ref.watch(selectedTierProvider);
    final isSelected = selectedTier == id;

    return GestureDetector(
      onTap: () => ref.read(selectedTierProvider.notifier).setTier(id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: isSelected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x2400BFFF), Color(0x0A00BFFF)],
                )
              : null,
          color: isSelected ? null : ClearBridgeColors.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? ClearBridgeColors.cyan
                : ClearBridgeColors.cardBorder,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: ClearBridgeColors.cyan.withValues(alpha: 0.2),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: ClearBridgeTypography.h3),
                      if (isRecommended) ...[
                        const SizedBox(height: 6),
                        const CbPill(
                          label: 'Recommended',
                          variant: PillVariant.cyan,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      price,
                      style: ClearBridgeTypography.h1.copyWith(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: isSelected
                            ? ClearBridgeColors.cyan
                            : ClearBridgeColors.silverBright,
                      ),
                      textAlign: TextAlign.right,
                    ),
                    if (isHot) ...[
                      const SizedBox(height: 6),
                      const CbPill(
                        label: 'Popular',
                        variant: PillVariant.orange,
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              description,
              style: ClearBridgeTypography.body,
            ),
          ],
        ),
      ),
    );
  }
}
