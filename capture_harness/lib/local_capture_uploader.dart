import 'dart:io';

import 'package:mac_capture/mac_capture.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Test-harness [CaptureUploader]: writes captured frames to the device's
/// app-documents directory instead of a real backend, so the capture flow
/// can be exercised end-to-end without Firebase/Firestore/Storage.
class LocalCaptureUploader implements CaptureUploader {
  const LocalCaptureUploader();

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
  }) async {
    final id = captureId ?? _uuid.v4();
    final docsDir = await getApplicationDocumentsDirectory();
    final captureDir = Directory('${docsDir.path}/captures/$id');
    await captureDir.create(recursive: true);

    var written = 0;
    final total = capture.totalFrames;
    for (var angleIdx = 0; angleIdx < capture.capturedFrames.length; angleIdx++) {
      final angleName = CaptureAngles.keys[angleIdx];
      final frames = capture.capturedFrames[angleIdx];
      for (var frameIdx = 0; frameIdx < frames.length; frameIdx++) {
        final file = File('${captureDir.path}/${angleName}_$frameIdx.jpg');
        await file.writeAsBytes(frames[frameIdx]);
        written++;
        onProgress?.call(written / total);
      }
    }

    return id;
  }
}
