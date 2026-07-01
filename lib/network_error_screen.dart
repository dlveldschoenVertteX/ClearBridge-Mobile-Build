import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/clearbridge_typography.dart';
import 'package:clearbridge/app_constants.dart';
import 'package:clearbridge/cb_primary_button.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.

class NetworkErrorScreen extends StatelessWidget {
  const NetworkErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_off_rounded, size: 64, color: ClearBridgeColors.silverDim),
                const SizedBox(height: 16),
                Text('No Connection', style: ClearBridgeTypography.h2),
                const SizedBox(height: 8),
                Text(
                  'Check your internet connection and try again.',
                  style: ClearBridgeTypography.body,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                CbPrimaryButton(
                  label: 'Retry',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => context.go(AppConstants.dashboardRoute),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
