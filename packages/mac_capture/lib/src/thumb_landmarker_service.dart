import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'hand_types.dart';

/// Thumb-specific hand landmark detector via full-precision TFLite model.
///
/// Uses `hand_landmark_full.tflite` (5.2MB, full-precision) instead of the lite
/// model. Better accuracy on partial hand views (thumb-only at close range).
///
/// **Critical fix for S118 (Helio G99, sensorOrientation=90°):**
/// The raw Y-plane is landscape; the thumb in portrait display appears rotated 90°
/// in the buffer. The TFLite model was trained on upright hands. Solution: detect
/// the portrait sensorOrientation, rotate the cropped image 90° CCW before feeding
/// to TFLite so the thumb matches the model's training orientation.
///
/// Initialization tries GPU delegate first; falls back to CPU (guaranteed to work).
class ThumbLandmarkerService {
  Interpreter? _interpreter;
  bool _ready = false;
  int _numOutputs = 0;
  int _landmarkIdx = -1;
  int _scoreIdx = -1;

  static const double _cropFraction = 0.85;
  static const int _inputSize = 224;
  static const double _minScore = 0.20; // lowered for close-range thumb detection

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
          'assets/models/hand_landmark_full.tflite',
          options: opts,
        );
        _numOutputs = _interpreter!.getOutputTensors().length;
        _landmarkIdx = -1;
        _scoreIdx = -1;
        for (var i = 0; i < _numOutputs; i++) {
          final shape = _interpreter!.getOutputTensor(i).shape;
          final total = shape.fold<int>(1, (a, b) => a * b);
          debugPrint(
              '[TFLite] ${useGpu ? "gpu" : "cpu"} output[$i] shape=$shape total=$total');
          if (total == 63 && _landmarkIdx < 0) _landmarkIdx = i;
          if (total == 1 && _scoreIdx < 0) _scoreIdx = i;
        }
        debugPrint('[TFLite] init OK (${useGpu ? "gpu" : "cpu"}) '
            'landmarkIdx=$_landmarkIdx scoreIdx=$_scoreIdx');
        if (_landmarkIdx < 0 || _scoreIdx < 0) {
          debugPrint('[TFLite] WARNING: could not identify landmark/score tensors');
        }
        _ready = _landmarkIdx >= 0 && _scoreIdx >= 0;
        return;
      } catch (e, st) {
        debugPrint(
            '[TFLite] init failed (${useGpu ? "gpu" : "cpu"}): $e\n$st');
        _interpreter?.close();
        _interpreter = null;
        _landmarkIdx = -1;
        _scoreIdx = -1;
      }
    }
    debugPrint('[TFLite] all delegates failed');
  }

  List<Hand> detect(CameraImage image, int sensorOrientation) {
    if (!_ready || _interpreter == null || _landmarkIdx < 0 || _scoreIdx < 0) {
      return const [];
    }
    try {
      final inputData = _preprocess(image, sensorOrientation);

      final Map<int, Object> outputBuffers = {};
      for (var i = 0; i < _numOutputs; i++) {
        final size = _interpreter!
            .getOutputTensor(i)
            .shape
            .fold<int>(1, (a, b) => a * b);
        outputBuffers[i] = Float32List(size);
      }

      _interpreter!.runForMultipleInputs([inputData], outputBuffers);

      final scoreList = outputBuffers[_scoreIdx] as Float32List;
      final confidence = scoreList[0];
      debugPrint('[TFLite] confidence=$confidence (min=$_minScore)');
      if (confidence < _minScore) return const [];

      final lmList = outputBuffers[_landmarkIdx] as Float32List;
      if (lmList.length < 63) return const [];

      final landmarks = List.generate(
        21,
        (i) => Landmark(lmList[i * 3], lmList[i * 3 + 1], lmList[i * 3 + 2]),
      );
      return [Hand(landmarks)];
    } catch (e, st) {
      debugPrint('[TFLite] detect error: $e\n$st');
      return const [];
    }
  }

  /// Convert CameraImage Y-plane → [1, 224, 224, 3] float32 [0,1].
  ///
  /// For sensorOrientation 90° (S118): rotate the cropped region 90° CCW so the
  /// thumb appears upright to the model. The raw Y-plane buffer is landscape, but
  /// the display is portrait.
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

    // For sensorOrientation 90° or 270°: rotate the crop 90° CCW before resize.
    if (sensorOrientation == 90 || sensorOrientation == 270) {
      // Rotate 90° CCW: dst[py][px] = src[px][cropH-1-py]
      final rotated = Float32List(cropW * cropH * 3);
      for (var py = 0; py < cropH; py++) {
        for (var px = 0; px < cropW; px++) {
          final srcX = px;
          final srcY = cropH - 1 - py;
          final byteIdx = (y0 + srcY) * stride + (x0 + srcX);
          final luma = byteIdx < bytes.length ? bytes[byteIdx] / 255.0 : 0.0;
          final dstIdx = (py * cropW + px) * 3;
          rotated[dstIdx] = luma;
          rotated[dstIdx + 1] = luma;
          rotated[dstIdx + 2] = luma;
        }
      }
      // After rotation: rotated is cropH wide × cropW tall (swapped dims).
      // Resize to 224×224 using swapped dimensions.
      final out = Float32List(_inputSize * _inputSize * 3);
      final srcW = cropH; // swapped
      final srcH = cropW;
      for (var py = 0; py < _inputSize; py++) {
        for (var px = 0; px < _inputSize; px++) {
          final sx = (px * srcW) ~/ _inputSize;
          final sy = (py * srcH) ~/ _inputSize;
          final luma = rotated[(sy * srcW + sx) * 3];
          final base = (py * _inputSize + px) * 3;
          out[base] = luma;
          out[base + 1] = luma;
          out[base + 2] = luma;
        }
      }
      return out;
    } else {
      // sensorOrientation 0°/180°: no rotation, standard crop + resize.
      final out = Float32List(_inputSize * _inputSize * 3);
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
      return out;
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _ready = false;
  }
}
