import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/application_data.dart';
import '../services/clearance_service.dart';

part 'application_repository.g.dart';

@riverpod
ApplicationRepository applicationRepository(Ref ref) {
  final clearanceService = ref.watch(clearanceServiceProvider);
  return ApplicationRepository(clearanceService: clearanceService);
}

class ApplicationRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  final ClearanceService _clearanceService;

  ApplicationRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ClearanceService? clearanceService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _clearanceService = clearanceService ?? ClearanceService();

  // Getter to access Firestore instance
  FirebaseFirestore get firestore => _firestore;

  /// Creates/Updates the user profile data in the 'users' collection.
  /// Optionally writes referral tracking fields and a referralCodes lookup doc.
  Future<void> createUserProfile(
    ApplicationData application, {
    String? referralCode,
    String? referredBy,
  }) async {
    try {
      final profileData = application.toMap();
      profileData['popiaConsentedAt'] = FieldValue.serverTimestamp();
      profileData['creditBalance'] = 0;
      if (referralCode != null) profileData['referralCode'] = referralCode;
      if (referredBy != null && referredBy.isNotEmpty) {
        profileData['referredBy'] = referredBy;
      }

      await _firestore
          .collection('users')
          .doc(application.userId)
          .set(profileData, SetOptions(merge: true));

      if (referralCode != null) {
        await _firestore.collection('referralCodes').doc(referralCode).set({
          'userId': application.userId,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      throw Exception('Failed to create user profile: $e');
    }
  }

  /// Submits the final clearance application after payment
  Future<void> submitApplication(ApplicationData application) async {
    try {
      final now = DateTime.now().toUtc();
      final deadlineAt = _clearanceService.calculateDeadline(
        application.tier,
        now,
      );

      final applicationWithDeadline = application.copyWith(
        createdAt: now,
        deadlineAt: application.status == 'pending' ? null : deadlineAt,
      );

      await _firestore
          .collection('applications')
          .add(applicationWithDeadline.toMap());
    } catch (e) {
      throw Exception('Failed to submit application: $e');
    }
  }

  /// Streams the application data for a specific user from the 'users' collection (profile data)
  Stream<ApplicationData?> streamUserProfileApplication(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .handleError((error) {
          if (error is FirebaseException &&
              (error.code == 'permission-denied' ||
                  error.code == 'unauthenticated')) {
            // If the user was deleted from the console, their token becomes invalid
            // and Firestore reads will fail with permission-denied.
            // We can force a sign-out here to clear the local state.
            Future.microtask(() => _auth.signOut());
          }
          throw error;
        })
        .map((snapshot) {
          if (!snapshot.exists || snapshot.data() == null) return null;
          return ApplicationData.fromMap(snapshot.data()!, snapshot.id);
        });
  }

  /// Streams an application document from the 'applications' collection
  Stream<DocumentSnapshot> getApplicationStream(String applicationId) {
    return _firestore.collection('applications').doc(applicationId).snapshots();
  }

  /// Updates profile-level capture data
  Future<void> updateCaptureData({
    required String userId,
    required String selfieUrl,
    required String idFrontUrl,
    required String idBackUrl,
    required String fingerprintUrl,
  }) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'selfieUrl': selfieUrl,
        'idFrontUrl': idFrontUrl,
        'idBackUrl': idBackUrl,
        'fingerprintUrl': fingerprintUrl,
        'captureCompleted': true,
      });
    } catch (e) {
      throw Exception('Failed to update capture data: $e');
    }
  }

  /// Updates notification settings for a specific user
  Future<void> updateNotificationSettings(
    String userId,
    Map<String, bool> settings,
  ) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'notificationSettings': settings,
      });
    } catch (e) {
      throw Exception('Failed to update notification settings: $e');
    }
  }

  Future<String> ensureClearanceDraft({
    required String userId,
    String? clearanceId,
  }) async {
    try {
      final docRef = clearanceId != null
          ? _firestore.collection('applications').doc(clearanceId)
          : _firestore.collection('applications').doc();

      final snapshot = await docRef.get();
      if (!snapshot.exists) {
        await docRef.set({
          'userId': userId,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        await docRef.set({
          'userId': userId,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      return docRef.id;
    } catch (e) {
      throw Exception('Failed to prepare clearance draft: $e');
    }
  }

  Future<void> updateFingerprintMultiCapture({
    required String clearanceId,
    required String userId,
    required String fingerprintFront,
    required String fingerprintLeft,
    required String fingerprintTop,
    required String fingerprintRight,
  }) async {
    try {
      final data = {
        'fingerprintFront': fingerprintFront,
        'fingerprintLeft': fingerprintLeft,
        'fingerprintTop': fingerprintTop,
        'fingerprintRight': fingerprintRight,
        'fingerprintCapturedAt': FieldValue.serverTimestamp(),
        'fingerprintUrl': fingerprintFront,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final batch = _firestore.batch();
      batch.set(
        _firestore.collection('applications').doc(clearanceId),
        {'userId': userId, ...data},
        SetOptions(merge: true),
      );
      batch.set(
        _firestore.collection('users').doc(userId),
        data,
        SetOptions(merge: true),
      );
      await batch.commit();
    } catch (e) {
      throw Exception('Failed to update fingerprint capture data: $e');
    }
  }

  Future<void> updateFingerprintVideoCapture({
    required String clearanceId,
    required String userId,
    required List<String> frameUrls,
  }) async {
    try {
      final data = {
        'fingerprintFrames': frameUrls,
        'fingerprintCapturedAt': FieldValue.serverTimestamp(),
        'captureType': 'video',
        'fingerprintUrl': frameUrls.isNotEmpty ? frameUrls.first : null,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final batch = _firestore.batch();
      batch.set(
        _firestore.collection('applications').doc(clearanceId),
        {'userId': userId, ...data},
        SetOptions(merge: true),
      );
      batch.set(
        _firestore.collection('users').doc(userId),
        data,
        SetOptions(merge: true),
      );
      await batch.commit();
    } catch (e) {
      throw Exception('Failed to update fingerprint video capture data: $e');
    }
  }

  Future<void> updateHybridFingerprintCapture({
    required String clearanceId,
    required String userId,
    required List<String> frameUrls,
    String? macroUrl,
  }) async {
    try {
      final data = {
        'fingerprintFrames': frameUrls,
        'macroImage': macroUrl,
        'fingerprintCapturedAt': FieldValue.serverTimestamp(),
        'captureType': 'hybrid',
        'fingerprintUrl': frameUrls.isNotEmpty ? frameUrls.first : null,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final batch = _firestore.batch();
      batch.set(
        _firestore.collection('applications').doc(clearanceId),
        {'userId': userId, ...data},
        SetOptions(merge: true),
      );
      batch.set(
        _firestore.collection('users').doc(userId),
        data,
        SetOptions(merge: true),
      );
      await batch.commit();
    } catch (e) {
      throw Exception('Failed to update hybrid fingerprint capture data: $e');
    }
  }
}
