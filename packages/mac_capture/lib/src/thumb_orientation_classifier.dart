import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// A single classification result: the predicted capture angle name
/// ('front'/'right'/'top'/'left') and the model's confidence in it (0-1).
class OrientationPrediction {
  const OrientationPrediction(this.angleName, this.confidence);
  final String angleName;
  final double confidence;
}

/// CV-based thumb orientation classifier -- a small MobileNetV3-based model
/// trained on close-up thumb capture frames (see packages/mac_capture's
/// training pipeline), distinct from [ThumbLandmarkerService]'s general
/// 21-point hand model. Where the landmark model needs a wrist/knuckles in
/// frame to compute a rotation angle (unreliable at the close range this app
/// captures at), this model classifies orientation directly from the visible
/// thumb crop, so it works exactly at the range hand-landmark angle
/// extraction struggles with.
///
/// This is the "computer vision" half of the hybrid capture-firing gate: the
/// capture controller uses a confident, correct prediction from this model to
/// bypass/relax the IMU-based orientation check, and otherwise falls back to
/// IMU alone exactly as before. See MultiAngleCaptureController._checkLock
/// and _checkQualityOnlyCapture.
///
/// Preprocessing mirrors ThumbLandmarkerService exactly (85% center crop,
/// same sensorOrientation-90/270 rotation) since the model was trained on
/// frames produced by that exact preprocessing.
class ThumbOrientationClassifier {
  Interpreter? _interpreter;
  bool _ready = false;

  static const double _cropFraction = 0.85;
  static const int _inputSize = 224;
  static const List<String> _classes = ['front', 'right', 'top', 'left'];

  bool get isReady => _ready;

  void initialize() {
    _initAsync();
  }

  Future<void> _initAsync() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    for (final useGpu in [true, false]) {
      try {
        final opts = InterpreterOptions()..threads = 2;
        if (useGpu) opts.addDelegate(GpuDelegate());
        _interpreter = await Interpreter.fromAsset(
          'assets/models/thumb_orientation.tflite',
          options: opts,
        );
        _ready = true;
        debugPrint('[ThumbOrientation] init OK (${useGpu ? "gpu" : "cpu"})');
        return;
      } catch (e) {
        debugPrint(
            '[ThumbOrientation] init failed (${useGpu ? "gpu" : "cpu"}): $e');
        _interpreter?.close();
        _interpreter = null;
      }
    }
    debugPrint('[ThumbOrientation] all delegates failed');
  }

  /// Classifies the current camera frame's thumb orientation. Returns null
  /// when the model isn't ready or inference fails -- callers should treat
  /// that exactly like a low-confidence result (fall back to IMU).
  OrientationPrediction? classify(CameraImage image, int sensorOrientation) {
    if (!_ready || _interpreter == null) return null;
    try {
      final inputData = _preprocess(image, sensorOrientation);
      final outputBuffer = Float32List(_classes.length);
      _interpreter!.runForMultipleInputs([inputData], {0: outputBuffer});

      var bestIdx = 0;
      for (var i = 1; i < outputBuffer.length; i++) {
        if (outputBuffer[i] > outputBuffer[bestIdx]) bestIdx = i;
      }
      return OrientationPrediction(_classes[bestIdx], outputBuffer[bestIdx]);
    } catch (e) {
      debugPrint('[ThumbOrientation] classify error: $e');
      return null;
    }
  }

  /// Identical crop/rotate/resize/normalize pipeline to
  /// ThumbLandmarkerService._preprocess -- kept as its own copy rather than
  /// shared code so each model's preprocessing can evolve independently if a
  /// future retrain changes the contract for one but not the other.
  ///
  /// Flat Float32List instead of nested List<List<List<double>>>: the nested
  /// form allocated 150K+ boxed doubles across three levels of List on every
  /// throttled detect cycle (~11x/sec), a measurable source of jank on budget
  /// devices. tflite_flutter accepts a flat typed buffer for a fixed-shape
  /// input tensor via runForMultipleInputs, same as ThumbLandmarkerService
  /// already does -- the index math below is unchanged from the nested form.
  Float32List _preprocess(CameraImage image, int sensorOrientation) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final stride = plane.bytesPerRow;
    final rawW = image.width;
    final rawH = image.height;

    final cropW = (rawW * _cropFraction).toInt();
    final cropH = (rawH * _cropFraction).toInt();
    final x0 = (rawW - cropW) ~/ 2;
    final y0 = (rawH - cropH) ~/ 2;

    final out = Float32List(_inputSize * _inputSize * 3);

    if (sensorOrientation == 90 || sensorOrientation == 270) {
      // Matches numpy.rot90(crop, k=1) exactly (verified: rotated[i][j] ==
      // crop[j][cropW-1-i] for i in [0,cropW), j in [0,cropH)) -- the same
      // rotation the training pipeline applies, since these frames are
      // landscape-shaped raw buffers same as the exported training set.
      for (var py = 0; py < _inputSize; py++) {
        // i: row index into the rotated (cropW x cropH) image.
        final i = (py * cropW) ~/ _inputSize;
        for (var px = 0; px < _inputSize; px++) {
          // j: col index into the rotated image.
          final j = (px * cropH) ~/ _inputSize;
          final rowInCrop = j;
          final colInCrop = cropW - 1 - i;
          final byteIdx = (y0 + rowInCrop) * stride + (x0 + colInCrop);
          final luma = byteIdx < bytes.length ? bytes[byteIdx] / 255.0 : 0.0;
          final base = (py * _inputSize + px) * 3;
          out[base] = luma;
          out[base + 1] = luma;
          out[base + 2] = luma;
        }
      }
    } else {
      for (var py = 0; py < _inputSize; py++) {
        for (var px = 0; px < _inputSize; px++) {
          final sx = x0 + (px * cropW) ~/ _inputSize;
          final sy = y0 + (py * cropH) ~/ _inputSize;
          final byteIdx = sy * stride + sx;
          final luma = byteIdx < bytes.length ? bytes[byteIdx] / 255.0 : 0.0;
          final base = (py * _inputSize + px) * 3;
          out[base] = luma;
          out[base + 1] = luma;
          out[base + 2] = luma;
        }
      }
    }
    return out;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _ready = false;
  }
}
