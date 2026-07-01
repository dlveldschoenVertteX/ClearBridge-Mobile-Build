import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'payment_provider.dart';

part 'payment_result_handler.g.dart';

class PaymentResultHandler {
  final FirebaseFirestore _firestore;
  final Ref _ref;

  PaymentResultHandler(this._firestore, this._ref);

  Future<void> handlePostPayment(
    String reference, {
    bool wasClosedByUser = false,
  }) async {
    final notifier = _ref.read(paymentNotifierProvider.notifier);

    // Switch to verifying state
    notifier.setVerifying(reference);

    debugPrint(
      'PaymentResultHandler: Starting verification for $reference - waiting for backend webhook',
    );

    StreamSubscription? subscription;
    Timer? timeoutTimer;

    try {
      final completer = Completer<bool>();

      // ONLY listen for backend webhook - no frontend intervention
      subscription = _firestore
          .collection('applications')
          .where('paymentReference', isEqualTo: reference)
          .snapshots()
          .listen(
            (snapshot) {
              debugPrint(
                'PaymentResultHandler: Backend webhook received: ${snapshot.docs.length} docs for $reference',
              );
              if (snapshot.docs.isNotEmpty) {
                final data = snapshot.docs.first.data();
                final status = data['status'] as String?;
                debugPrint(
                  'PaymentResultHandler: Backend application status: $status for $reference',
                );
                // Accept whatever status the backend sets
                if (status == 'processing' ||
                    status == 'completed' ||
                    status == 'paid' ||
                    status == 'success' ||
                    status == 'failed') {
                  debugPrint(
                    'PaymentResultHandler: Backend verification complete for $reference with status: $status',
                  );
                  if (!completer.isCompleted) completer.complete(true);
                }
              }
            },
            onError: (e) {
              debugPrint('PaymentResultHandler Stream Error: $e');
              if (!completer.isCompleted) completer.complete(false);
            },
          );

      // Short timeout if closed by user (2s), long timeout otherwise (5m)
      final timeoutDuration = wasClosedByUser
          ? const Duration(seconds: 2)
          : const Duration(minutes: 5);

      timeoutTimer = Timer(timeoutDuration, () {
        debugPrint(
          'PaymentResultHandler: Backend verification timeout for $reference - no webhook received (closedByUser: $wasClosedByUser)',
        );
        if (!completer.isCompleted) completer.complete(false);
      });

      final isSuccess = await completer.future;
      debugPrint(
        'PaymentResultHandler: Backend verification result: $isSuccess for $reference',
      );

      if (isSuccess) {
        debugPrint(
          'PaymentResultHandler: Setting success status for $reference',
        );
        notifier.setSuccess(reference);
        // ClearCoins are reset to 0 server-side by the onApplicationClearCoins
        // Cloud Function when the purchased application reaches a paid status.
      } else {
        if (wasClosedByUser) {
          debugPrint(
            'PaymentResultHandler: Setting cancelled status for $reference',
          );
          notifier.setCancelled();
        } else {
          debugPrint(
            'PaymentResultHandler: Setting failed status for $reference - backend did not respond',
          );
          notifier.setFailed(
            reference,
            'Payment verification failed. Backend did not respond. Please contact support if you completed payment.',
          );
        }
      }
    } catch (e) {
      debugPrint('PaymentResultHandler Error: $e');
      if (wasClosedByUser) {
        notifier.setCancelled();
      } else {
        notifier.setFailed(reference, 'An error occurred during verification.');
      }
    } finally {
      subscription?.cancel();
      timeoutTimer?.cancel();
    }
  }
}

@riverpod
PaymentResultHandler paymentResultHandler(Ref ref) {
  return PaymentResultHandler(FirebaseFirestore.instance, ref);
}
