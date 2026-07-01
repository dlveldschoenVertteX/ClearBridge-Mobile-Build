import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/cb_pill.dart';
import 'package:clearbridge/cb_primary_button.dart';

class StatusScreen extends StatelessWidget {
  const StatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            children: [
              // Header
              Row(
                children: [
                  GestureDetector(
                    onTap: () => context.go(AppConstants.dashboardRoute),
                    child: Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: const Color(0x0AFFFFFF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x14FFFFFF)),
                      ),
                      child: const Icon(
                        Icons.close,
                        color: ClearBridgeColors.silverBright,
                        size: 18,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'Application Status',
                      textAlign: TextAlign.center,
                      style: ClearBridgeTypography.h3,
                    ),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
              const SizedBox(height: 32),

              // Status Card
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: ClearBridgeColors.cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: ClearBridgeColors.cardBorder),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: ClearBridgeColors.success.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color:
                              ClearBridgeColors.success.withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.check_circle_rounded,
                        size: 60,
                        color: ClearBridgeColors.success,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Submitted Successfully',
                      style: ClearBridgeTypography.h2,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Reference: #CB-982341',
                      style: ClearBridgeTypography.mono,
                    ),
                    const SizedBox(height: 28),
                    const Divider(color: Color(0x14FFFFFF)),
                    const SizedBox(height: 20),
                    _buildDetailRow('Service', 'Priority Clearance'),
                    const SizedBox(height: 16),
                    _buildDetailRow('Status', 'Processing', isStatus: true),
                    const SizedBox(height: 16),
                    _buildDetailRow('Deadline', 'March 9, 2026'),
                    const SizedBox(height: 16),
                    _buildDetailRow('Amount Paid', 'R170.00'),
                  ],
                ),
              ),

              const SizedBox(height: 36),
              CbPrimaryButton(
                label: 'Download Receipt',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: () {
                  // TODO: Implement receipt download
                },
              ),
              const SizedBox(height: 12),
              CbPrimaryButton.ghost(
                label: 'Done',
                onPressed: () => context.go(AppConstants.dashboardRoute),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isStatus = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: ClearBridgeTypography.body),
        if (isStatus)
          const CbPill(label: 'Processing', variant: PillVariant.cyan)
        else
          Text(
            value,
            style: ClearBridgeTypography.body.copyWith(
              color: ClearBridgeColors.silverBright,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}
