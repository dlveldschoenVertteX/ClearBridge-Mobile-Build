import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:clearbridge/clearance_model.dart';

part 'clearance_repository.g.dart';

@riverpod
ClearanceRepository clearanceRepository(Ref ref) {
  return ClearanceRepository();
}

class ClearanceRepository {
  final FirebaseFirestore _firestore;

  ClearanceRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Streams the latest clearance document for a given user
  Stream<ClearanceModel?> streamLatestClearance(String userId) {
    return _firestore
        .collection('applications')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .map((snapshot) {
          if (snapshot.docs.isEmpty) return null;

          final doc = snapshot.docs.first;
          final data = doc.data();
          final status = (data['status'] as String?)?.toLowerCase() ?? '';

          // Filter in Dart: Only show if it's a paid/processing or final state
          final validStatuses = [
            'paid',
            'processing',
            'completed',
            'cleared',
            'ready',
            'submitted',
            'failed',
          ];
          if (!validStatuses.contains(status)) {
            return null;
          }

          return ClearanceModel.fromFirestore(doc);
        });
  }

  /// Streams the 50 most recent clearance documents for the history screen.
  Stream<List<ClearanceModel>> streamUserClearances(String userId) {
    return _firestore
        .collection('applications')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => ClearanceModel.fromFirestore(doc))
              .toList();
        });
  }
}
