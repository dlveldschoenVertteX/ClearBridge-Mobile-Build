import 'multi_angle_capture.dart';

/// Host-app-supplied backend for persisting a finished [MultiAngleCapture].
/// This package has no knowledge of Firebase or any other backend — the app
/// embedding [MacCaptureScreen] provides a concrete implementation (e.g.
/// backed by Firestore/Storage/Cloud Functions) and passes it in.
abstract class CaptureUploader {
  /// Uploads all captured frames and returns the resulting capture ID.
  /// [captureId] lets the caller pre-generate the ID (e.g. so the same ID is
  /// reused if the capture later has to be queued offline after a failed
  /// upload attempt).
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
  });
}

/// Thrown by a [CaptureUploader] implementation to signal a retryable
/// network failure. The capture controller catches this and falls back to
/// the local [OfflineCaptureQueue] instead of surfacing a hard error.
class CaptureNetworkException implements Exception {
  const CaptureNetworkException(this.cause);
  final Object cause;

  @override
  String toString() => 'CaptureNetworkException: $cause';
}
