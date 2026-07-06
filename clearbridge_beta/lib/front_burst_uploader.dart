import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Uploads the single winning front-burst frame to Storage, writes the
/// `captures/{captureId}` Firestore document, and fires
/// `processEnhanceAndScore` (africa-south1) — same backend contract the main
/// app and capture_harness use, so this app's captures land in the same
/// pipeline without any server-side changes.
class FrontBurstUploader {
  const FrontBurstUploader();

  Future<String> uploadAndProcess(
    Uint8List jpeg, {
    required String userId,
    required Map<String, dynamic> frameMetadata,
  }) async {
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) {
      throw Exception('[unauthenticated] No Firebase user — auth failed.');
    }

    final id = _uuid.v4();
    final basePath = 'captures/$userId/$id';

    await FirebaseStorage.instance
        .ref()
        .child('$basePath/frame_1_front.jpg')
        .putData(jpeg, SettableMetadata(contentType: 'image/jpeg'));

    await FirebaseFirestore.instance.collection('captures').doc(id).set({
      'captureId': id,
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
      'status': 'pending',
      'source': 'clearbridge_beta',
      'captureMethod': 'front_burst',
      'captureMode': 'front_burst',
      'frameCount': 1,
      'frames': [frameMetadata],
    }, SetOptions(merge: true));

    () async {
      try {
        await FirebaseFunctions.instanceFor(region: 'africa-south1')
            .httpsCallable('processEnhanceAndScore')
            .call({'captureId': id, 'userId': userId, 'basePath': basePath});
      } catch (e) {
        debugPrint('[processEnhanceAndScore] trigger failed (non-blocking): $e');
      }
    }();

    return id;
  }
}
