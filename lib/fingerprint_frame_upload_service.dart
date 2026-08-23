import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:mac_capture/mac_capture.dart';

const _uuid = Uuid();

/// Uploads frames from a [MultiAngleCapture] to Firebase Storage, creates the
/// `captures/{captureId}` Firestore document, and invokes the
/// `processEnhanceAndScore` Cloud Function (africa-south1). Returns the
/// captureId. This is the app's concrete [CaptureUploader] — the mac_capture
/// package knows nothing about Firebase, only this interface.
class FingerprintFrameUploadService
    implements CaptureUploader, ArcCaptureUploader {
  const FingerprintFrameUploadService();

  @override
  Future<String> uploadAndProcess(
    MultiAngleCapture capture, {
    required String userId,
    String? captureId,
    void Function(double progress)? onProgress,
    List<Map<String, dynamic>> frameMetadata = const [],
    double? thumbWidthFraction,
    List<Map<String, dynamic>> burstStats = const [],
    List<Map<String, dynamic>> axisGateAtCapture = const [],
    Map<String, double> orbitAngles = const {},
    List<Map<String, dynamic>> debugTelemetry = const [],
  }) async {
    try {
      return await _uploadAndProcess(
        capture,
        userId: userId,
        captureId: captureId,
        onProgress: onProgress,
        frameMetadata: frameMetadata,
        thumbWidthFraction: thumbWidthFraction,
        burstStats: burstStats,
        axisGateAtCapture: axisGateAtCapture,
        orbitAngles: orbitAngles,
        debugTelemetry: debugTelemetry,
      );
    } on FirebaseException catch (e) {
      final isNetwork = e.code == 'unavailable' ||
          e.code == 'deadline-exceeded' ||
          e.code == 'network-request-failed' ||
          (e.message?.toLowerCase().contains('network') ?? false);
      if (isNetwork) throw CaptureNetworkException(e);
      rethrow;
    }
  }

  Future<String> _uploadAndProcess(
    MultiAngleCapture capture, {
    required String userId,
    String? captureId,
    void Function(double progress)? onProgress,
    List<Map<String, dynamic>> frameMetadata = const [],
    double? thumbWidthFraction,
    List<Map<String, dynamic>> burstStats = const [],
    List<Map<String, dynamic>> axisGateAtCapture = const [],
    Map<String, double> orbitAngles = const {},
    List<Map<String, dynamic>> debugTelemetry = const [],
  }) async {
    // Fail fast before touching Storage/Firestore — both require auth.
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) {
      throw Exception('[unauthenticated] Session expired — sign in again before capture.');
    }

    final db = FirebaseFirestore.instance;
    final id = captureId ?? _uuid.v4();
    final basePath = 'captures/$userId/$id';

    final total = capture.totalFrames;

    // Build upload tasks as closures — not started yet, so we can batch them.
    final uploadTasks = <(Uint8List, String)>[];
    int frameNum = 1;

    for (int ai = 0; ai < CaptureAngles.keyList.length; ai++) {
      final angleName = CaptureAngles.keyList[ai];
      final frames = capture.capturedFrames[ai];
      final flashFlags = capture.isFlashFrame.length > ai
          ? capture.isFlashFrame[ai]
          : List.filled(frames.length, false);
      for (int fi = 0; fi < frames.length; fi++) {
        final type = flashFlags[fi] ? 'fl' : 'amb';
        final path = '$basePath/frame_${frameNum}_${angleName}_${type}_${fi + 1}.jpg';
        uploadTasks.add((frames[fi], path));
        frameNum++;
      }
    }

    // Start Firestore write and token refresh in parallel with the first upload
    // batch — neither depends on uploads completing.
    final firestoreFuture = db.collection('captures').doc(id).set({
      'captureId': id,
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
      'status': 'pending',
      'source': 'flutter_apk',
      'captureMethod': 'image_stream_extraction',
      'frameCount': capture.totalFrames,
      'angleCount': 4,
      'allSuitable': true,
      'metadata': capture.metadata,
      'angles': List.generate(4, (i) => {
        'angle_index': i + 1,
        'angle_name': CaptureAngles.keyList[i],
        'frame_count': capture.capturedFrames[i].length,
      }),
      // Per-frame capture context (zone, focus, flash, thumb angle) — includes
      // transition-zone frames that aren't part of the 4 primary angle images.
      'frames': frameMetadata,
      'behavioralSignals': {
        'accelerometerSmoothnessPerAngle':
            capture.accelerometerSmoothnessPerAngle,
        'angleTimingsMs': capture.angleTimingsMs,
        if (burstStats.isNotEmpty)         'burstStats':          burstStats,
        if (axisGateAtCapture.isNotEmpty)  'axisGateAtCapture':   axisGateAtCapture,
      },
    }, SetOptions(merge: true));

    // Force-refresh the token in parallel with uploads — Storage uploads can
    // take long enough for a token to expire; this keeps the refresh off the
    // critical path so it doesn't add latency after uploads finish.
    final tokenFuture = authUser.getIdToken(true);

    // Upload in batches of 6 to avoid saturating the mobile connection.
    var completed = 0;
    for (var i = 0; i < uploadTasks.length; i += 6) {
      final batchEnd = math.min(i + 6, uploadTasks.length);
      await Future.wait([
        for (var j = i; j < batchEnd; j++)
          _uploadFrame(uploadTasks[j].$1, uploadTasks[j].$2)
              .then((_) => onProgress?.call(++completed / total)),
      ]);
    }

    // Ensure Firestore write and token are ready before triggering the callable.
    await Future.wait([firestoreFuture, tokenFuture]);

    // Trigger processing — fire-and-forget so a callable auth issue never
    // blocks the user from seeing their upload succeed. Frames are safe in
    // Storage; the Firestore doc is pending and can be reprocessed.
    () async {
      try {
        await FirebaseFunctions.instanceFor(region: 'africa-south1')
            .httpsCallable('processEnhanceAndScore')
            .call({
          'captureId': id,
          'userId': userId,
          'basePath': basePath,
          if (thumbWidthFraction != null)
            'thumbWidthFraction': thumbWidthFraction,
          if (orbitAngles.isNotEmpty)
            'orbitAngles': orbitAngles,
        });
      } catch (e) {
        debugPrint('[processEnhanceAndScore] trigger failed (non-blocking): $e');
      }
    }();

    // Debug telemetry (gyro/CV trajectory for retuning + CV retraining) is a
    // separate collection/write on purpose -- it can be large enough to risk
    // hitting Firestore's 1MB doc limit on a long/retried session, and it
    // must never be able to fail the actual capture upload above.
    if (debugTelemetry.isNotEmpty) {
      () async {
        try {
          await db.collection('captureTelemetry').doc(id).set({
            'captureId': id,
            'userId': userId,
            'createdAt': FieldValue.serverTimestamp(),
            'telemetry': debugTelemetry,
          });
        } catch (e) {
          debugPrint('[captureTelemetry] write failed (non-blocking): $e');
        }
      }();
    }

    return id;
  }

  /// Uploads an arc-sweep capture (continuous gyro-tracked sweep, one best
  /// frame per angular bin) and triggers processing. The backend identifies
  /// arc captures by the `frame_{N}_arc_{binIndex}.jpg` filename convention
  /// and by `arcAngles` in the callable payload (main.py `_download_arc_frames`
  /// / `is_arc`) — both must stay in sync with that contract.
  ///
  /// [frames] and [arcAngles] are parallel lists ordered by bin. Bin indices
  /// are read from `frameMetadata[i]['binIndex']` when present so Storage
  /// filenames carry the true bin even if some bins were skipped; falls back
  /// to the list position otherwise.
  @override
  Future<String> uploadArcAndProcess(
    List<Uint8List> frames, {
    required List<double> arcAngles,
    required String userId,
    String? captureId,
    void Function(double progress)? onProgress,
    List<Map<String, dynamic>> frameMetadata = const [],
  }) async {
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) {
      throw Exception('[unauthenticated] Session expired — sign in again before capture.');
    }
    if (frames.length != arcAngles.length) {
      throw ArgumentError(
          'frames (${frames.length}) and arcAngles (${arcAngles.length}) must be parallel');
    }

    final db = FirebaseFirestore.instance;
    final id = captureId ?? _uuid.v4();
    final basePath = 'captures/$userId/$id';

    final uploadTasks = <(Uint8List, String)>[];
    for (int i = 0; i < frames.length; i++) {
      final binIndex = (i < frameMetadata.length
              ? frameMetadata[i]['binIndex'] as int?
              : null) ??
          i;
      uploadTasks.add(
          (frames[i], '$basePath/frame_${i + 1}_arc_$binIndex.jpg'));
    }

    final firestoreFuture = db.collection('captures').doc(id).set({
      'captureId': id,
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
      'status': 'pending',
      'source': 'flutter_apk',
      'captureMethod': 'arc_sweep',
      'captureMode': 'arc_sweep',
      'frameCount': frames.length,
      'arcAngles': arcAngles,
      'frames': frameMetadata,
    }, SetOptions(merge: true));

    final tokenFuture = authUser.getIdToken(true);

    var completed = 0;
    for (var i = 0; i < uploadTasks.length; i += 6) {
      final batchEnd = math.min(i + 6, uploadTasks.length);
      await Future.wait([
        for (var j = i; j < batchEnd; j++)
          _uploadFrame(uploadTasks[j].$1, uploadTasks[j].$2)
              .then((_) => onProgress?.call(++completed / frames.length)),
      ]);
    }

    await Future.wait([firestoreFuture, tokenFuture]);

    // Fire-and-forget, same rationale as the 4-angle path above.
    () async {
      try {
        await FirebaseFunctions.instanceFor(region: 'africa-south1')
            .httpsCallable('processEnhanceAndScore')
            .call({
          'captureId': id,
          'userId': userId,
          'basePath': basePath,
          'arcAngles': arcAngles,
        });
      } catch (e) {
        debugPrint('[processEnhanceAndScore] arc trigger failed (non-blocking): $e');
      }
    }();

    return id;
  }

  /// Streams real-time updates for a capture document.
  Stream<DocumentSnapshot<Map<String, dynamic>>> watchCapture(String captureId) {
    return FirebaseFirestore.instance
        .collection('captures')
        .doc(captureId)
        .snapshots();
  }

  Future<void> _uploadFrame(Uint8List data, String path) async {
    await FirebaseStorage.instance
        .ref()
        .child(path)
        .putData(data, SettableMetadata(contentType: 'application/octet-stream'));
  }
}

final fingerprintFrameUploadServiceProvider =
    Provider<FingerprintFrameUploadService>((_) {
  return const FingerprintFrameUploadService();
});
