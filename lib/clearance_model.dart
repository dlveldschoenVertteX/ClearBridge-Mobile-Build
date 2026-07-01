import 'package:cloud_firestore/cloud_firestore.dart';

class ClearanceModel {
  final String clearanceId;
  final String userId;
  final String reference;
  final String tier;
  final String status;
  final double price;
  final DateTime paidAt;
  final DateTime createdAt;
  final DateTime expectedCompletionTime;
  final DateTime? completedAt;
  final String? certificateUrl;

  ClearanceModel({
    required this.clearanceId,
    required this.userId,
    required this.reference,
    required this.tier,
    required this.status,
    required this.price,
    required this.paidAt,
    required this.createdAt,
    required this.expectedCompletionTime,
    this.completedAt,
    this.certificateUrl,
  });

  factory ClearanceModel.fromFirestore(DocumentSnapshot doc) {
    try {
      final data = doc.data() as Map<String, dynamic>;

      final tier = data['tier'] as String? ?? 'premium';
      final createdAt = (data['createdAt'] ?? Timestamp.now()) as Timestamp;
      final paidAt =
          (data['paidAt'] ?? data['paymentVerifiedAt'] ?? createdAt)
              as Timestamp;

      // Calculate default expectedCompletionTime if missing, handling 'deadlineAt' alias
      DateTime? expected;
      final deadlineAt = data['deadlineAt'] ?? data['expectedCompletionTime'];

      if (deadlineAt != null) {
        expected = (deadlineAt as Timestamp).toDate().toUtc();
      } else {
        final hours = tier.toLowerCase() == 'priority' ? 2 : 4;
        expected = paidAt.toDate().toUtc().add(Duration(hours: hours));
      }

      return ClearanceModel(
        clearanceId: doc.id,
        userId: data['userId'] ?? '',
        reference: data['reference'] ?? data['paymentReference'] ?? '',
        tier: tier,
        status: data['status'] ?? '',
        price: (data['price'] as num?)?.toDouble() ?? 0.0,
        paidAt: paidAt.toDate().toUtc(),
        createdAt: createdAt.toDate().toUtc(),
        expectedCompletionTime: expected.toUtc(),
        completedAt: (data['completedAt'] as Timestamp?)?.toDate().toUtc(),
        certificateUrl: data['certificateUrl'],
      );
    } catch (e) {
      // Return a safe fallback model if Firestore data is corrupt
      final now = DateTime.now().toUtc();
      return ClearanceModel(
        clearanceId: doc.id,
        userId: '',
        reference: '',
        tier: 'premium',
        status: 'error',
        price: 0.0,
        paidAt: now,
        createdAt: now,
        expectedCompletionTime: now,
        certificateUrl: null,
      );
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'reference': reference,
      'tier': tier,
      'status': status,
      'price': price,
      'paidAt': Timestamp.fromDate(paidAt),
      'createdAt': Timestamp.fromDate(createdAt),
      'expectedCompletionTime': Timestamp.fromDate(expectedCompletionTime),
      'completedAt': completedAt != null
          ? Timestamp.fromDate(completedAt!)
          : null,
      'certificateUrl': certificateUrl,
    };
  }

  /// Returns true if the clearance is in a final success state.
  /// Robust check: considers status string AND existence of PDF URL.
  bool get isFinished {
    final s = status.toLowerCase();
    return s == 'completed' ||
        s == 'cleared' ||
        (certificateUrl != null && certificateUrl!.isNotEmpty && s != 'failed');
  }

  /// Returns a clean, display-friendly status
  String get displayStatus {
    if (isFinished) return 'CLEARED';
    final s = status.toLowerCase();
    if (s == 'failed') return 'FAILED';
    if (s == 'paid' || s == 'processing') return 'PROCESSING';
    return 'PENDING';
  }
}
