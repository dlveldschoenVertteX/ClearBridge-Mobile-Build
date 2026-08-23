import 'dart:typed_data';

/// Host-app interface for persisting an arc-sweep capture, mirroring
/// [CaptureUploader] for the 4-angle flow: the package owns the capture
/// mechanics, the host owns storage/auth/backend.
///
/// Implementations must upload frames under the backend's arc filename
/// contract (`frame_{N}_arc_{binIndex}.jpg`) and pass [arcAngles] through to
/// the processing call — see the ClearBridge backend's `_download_arc_frames`.
abstract class ArcCaptureUploader {
  Future<String> uploadArcAndProcess(
    List<Uint8List> frames, {
    required List<double> arcAngles,
    required String userId,
    String? captureId,
    void Function(double progress)? onProgress,
    List<Map<String, dynamic>> frameMetadata,
  });
}
