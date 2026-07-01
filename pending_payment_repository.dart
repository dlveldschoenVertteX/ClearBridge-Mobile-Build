import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'pending_payment_repository.g.dart';

@riverpod
PendingPaymentRepository pendingPaymentRepository(Ref ref) {
  return PendingPaymentRepository();
}

class PendingPaymentRepository {
  final FirebaseFirestore _firestore;

  PendingPaymentRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  Future<void> createPendingPayment({
    required String reference,
    required String userId,
    required String tier,
    required double amount,
    String? clearanceId,
  }) async {
    try {
      await _firestore.collection('pending_payments').doc(reference).set({
        'reference': reference,
        'userId': userId,
        'tier': tier,
        'amount': amount,
        'status': 'pending',
        'clearanceId': clearanceId,
        'retryCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Failed to create pending payment: $e');
    }
  }

  Future<void> updatePaymentStatus({
    required String reference,
    required String status,
    String? errorMessage,
  }) async {
    try {
      final updateData = <String, dynamic>{
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (errorMessage != null) {
        updateData['errorMessage'] = errorMessage;
      }

      if (status == 'completed') {
        updateData['completedAt'] = FieldValue.serverTimestamp();
      }

      await _firestore
          .collection('pending_payments')
          .doc(reference)
          .update(updateData);
    } catch (e) {
      throw Exception('Failed to update payment status: $e');
    }
  }

  Future<void> incrementRetryCount(String reference) async {
    try {
      await _firestore.collection('pending_payments').doc(reference).update({
        'retryCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Failed to increment retry count: $e');
    }
  }

  Future<Map<String, dynamic>?> getPendingPayment(String reference) async {
    try {
      final doc = await _firestore
          .collection('pending_payments')
          .doc(reference)
          .get();
      return doc.data();
    } catch (e) {
      throw Exception('Failed to get pending payment: $e');
    }
  }

  Stream<Map<String, dynamic>?> watchPendingPayment(String reference) {
    return _firestore
        .collection('pending_payments')
        .doc(reference)
        .snapshots()
        .map((doc) => doc.data());
  }
}
