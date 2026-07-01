import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_paystack_plus/flutter_paystack_plus.dart';
import 'package:clearbridge/app_constants.dart';

class PaymentService {
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  Future<void> initializePayment() async {
    // Note: flutter_paystack_plus usually handles initialization internally
  }

  Future<void> startPayment({
    required BuildContext context,
    required String userId,
    required String email,
    required int amountInZar,
    String? reference,
    Map<String, dynamic>? metadata,
    required ValueChanged<String> onSuccess,
    required VoidCallback onClosed,
  }) async {
    try {
      final String paymentReference =
          reference ??
          'CB_${userId}_${DateTime.now().toUtc().millisecondsSinceEpoch}';

      debugPrint('PaymentService: Initializing transaction on server...');

      // 1. Initialize transaction on server to get authorizationUrl
      final HttpsCallable callable = _functions.httpsCallable(
        'initializePaystackTransaction',
      );
      final result = await callable.call({
        'amount': amountInZar * 100, // ZAR to Cents
        'email': email,
        'reference': paymentReference,
        'metadata': metadata,
      });

      final String? authorizationUrl = result.data['authorization_url'];

      if (authorizationUrl == null) {
        throw Exception('Failed to get authorizationUrl from server');
      }

      debugPrint(
        'PaymentService: Server initialization successful. Opening popup...',
      );

      // 2. Open Paystack popup with authorizationUrl
      debugPrint(
        'PaymentService: About to open Paystack popup with URL: $authorizationUrl',
      );

      try {
        debugPrint(
          'PaymentService: About to open Paystack popup with URL: $authorizationUrl',
        );

        // Open popup and let backend handle everything - no frontend intervention
        if (context.mounted) {
          await FlutterPaystackPlus.openPaystackPopup(
            publicKey: AppConstants.paystackPublicKey,
            context: context,
            customerEmail: email,
            amount: (amountInZar * 100).toString(),
            reference: paymentReference,
            authorizationUrl: authorizationUrl, // Pass server-generated URL
            metadata: metadata,
            onClosed: () {
              debugPrint(
                'PaymentService: Popup Closed - onClosed callback fired',
              );
              onClosed();
            },
            onSuccess: () {
              debugPrint(
                'PaymentService: Popup Success - onSuccess callback fired',
              );
              onSuccess(paymentReference);
            },
          );
        }
        debugPrint('PaymentService: Paystack popup opened successfully');
      } catch (popupError) {
        debugPrint('PaymentService: Error opening popup: $popupError');
        rethrow;
      }
    } catch (e) {
      debugPrint('Error starting payment: $e');
      rethrow;
    }
  }
}
