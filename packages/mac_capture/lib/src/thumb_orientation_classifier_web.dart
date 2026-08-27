import 'package:camera/camera.dart';

/// A single classification result: the predicted capture angle name
/// ('front'/'right'/'top'/'left') and the model's confidence in it (0-1).
///
/// Duplicated (not shared/imported) from thumb_orientation_classifier_io.dart
/// deliberately -- the conditional export in thumb_orientation_classifier.dart
/// means only ONE of these two files is ever compiled into a given build, so
/// there is no risk of two competing definitions colliding; keeping this
/// tiny value class self-contained here avoids adding a third shared file
/// just to avoid four lines of duplication.
class OrientationPrediction {
  const OrientationPrediction(this.angleName, this.confidence);
  final String angleName;
  final double confidence;
}

/// Web stub for [ThumbOrientationClassifier].
///
/// The real implementation (thumb_orientation_classifier_io.dart) depends on
/// `package:tflite_flutter`, which cannot compile for web at all (see
/// thumb_landmarker_service_web.dart's docstring for the full explanation --
/// same root cause, same fix pattern). Selected via
/// thumb_orientation_classifier.dart's conditional export
/// (`if (dart.library.io)`). Same public API, permanently "not ready" --
/// callers already treat a null/low-confidence classify() result as "fall
/// back to IMU" (see the real implementation's own docstring), so this
/// degrades exactly the same way a failed on-device model load already
/// does, not a new failure mode.
class ThumbOrientationClassifier {
  bool get isReady => false;

  String? get lastInitError => 'web stub';
  String? get inputShape => null;
  String? get outputShape => null;
  String? get lastClassifyError => null;
  String? get loadedAssetKey => null;

  void initialize() {}

  OrientationPrediction? classify(CameraImage image, int sensorOrientation) =>
      null;

  void dispose() {}
}
