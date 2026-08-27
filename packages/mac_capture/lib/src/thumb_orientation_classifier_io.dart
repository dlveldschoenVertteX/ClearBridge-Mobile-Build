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
  String? _lastInitError;
  String? _loadedAssetKey;

  static const double _cropFraction = 0.85;
  static const int _inputSize = 224;
  static const List<String> _classes = ['front', 'right', 'top', 'left'];

  /// Asset keys tried in order. A host app that declares the model in its
  /// OWN pubspec (every app in this monorepo does) publishes it under the
  /// bare path; one that ever relies on mac_capture shipping the model
  /// itself would publish it package-scoped instead. Trying both removes a
  /// whole failure class for the cost of one extra rootBundle miss, and
  /// costs nothing at all in the common case -- the first key wins.
  static const List<String> _assetKeys = [
    'assets/models/thumb_orientation.tflite',
    'packages/mac_capture/assets/models/thumb_orientation.tflite',
  ];

  bool get isReady => _ready;

  /// Why the model is not ready, when it is not. Exposed because this
  /// classifier fails SILENTLY by design -- `classify()` returns null and
  /// every caller falls back to IMU -- which means a permanently-failing
  /// model load is invisible from the outside.
  ///
  /// REAL CASE this exists for (2026-08-27): the first fusion_capture run
  /// to record classifier telemetry came back `orientationDebug.samples =
  /// 0` while `padClipDebug` from the SAME `_onFrame` callback showed real
  /// measurements -- so the frame callback was firing and every single
  /// `classify()` call was returning null. "samples: 0" alone cannot
  /// distinguish "the model never loaded" from "the model loaded and every
  /// inference threw", and no capture in this project's Firestore history
  /// has ever recorded a successful classification, so it is entirely
  /// possible this model has never loaded on any real device. These two
  /// fields are what make the next real capture answer that directly.
  String? get lastInitError => _lastInitError;

  /// Which of [_assetKeys] actually loaded, or null if none did.
  String? get loadedAssetKey => _loadedAssetKey;

  /// The model's real tensor shapes, read off the interpreter at load.
  /// Exposed because a shape mismatch is the failure mode that already cost
  /// this classifier a full device round.
  String? get inputShape => _inputShape;
  String? get outputShape => _outputShape;
  String? _inputShape;
  String? _outputShape;

  void initialize() {
    _initAsync();
  }

  Future<void> _initAsync() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      _lastInitError = 'not android';
      return;
    }
    final failures = <String>[];
    for (final assetKey in _assetKeys) {
      for (final useGpu in [true, false]) {
        try {
          final opts = InterpreterOptions()..threads = 2;
          if (useGpu) opts.addDelegate(GpuDelegate());
          _interpreter = await Interpreter.fromAsset(assetKey, options: opts);
          // Explicit rather than relying on the first inference to do it:
          // the tensor-level path in classify() does NOT allocate on our
          // behalf the way runForMultipleInputs did.
          _interpreter!.allocateTensors();
          // Recorded so a REMAINING shape mismatch is immediately readable
          // from a real capture instead of needing another round of
          // guessing -- the whole reason the previous bug survived this
          // long is that it surfaced only as a generic message.
          _inputShape = _interpreter!.getInputTensor(0).shape.toString();
          _outputShape = _interpreter!.getOutputTensor(0).shape.toString();
          _ready = true;
          _loadedAssetKey = assetKey;
          _lastInitError = null;
          debugPrint('[ThumbOrientation] init OK '
              '(${useGpu ? "gpu" : "cpu"}, $assetKey)');
          return;
        } catch (e) {
          failures.add('${useGpu ? "gpu" : "cpu"}/$assetKey: $e');
          debugPrint('[ThumbOrientation] init failed '
              '(${useGpu ? "gpu" : "cpu"}, $assetKey): $e');
          _interpreter?.close();
          _interpreter = null;
        }
      }
    }
    // Truncated: this is written to a Firestore diagnostic field, and a
    // raw tflite stack trace can run to kilobytes.
    final joined = failures.join(' | ');
    _lastInitError =
        joined.length > 400 ? '${joined.substring(0, 400)}...' : joined;
    debugPrint('[ThumbOrientation] all delegates/assets failed');
  }

  /// Set by [classify] when inference itself throws (as opposed to load).
  String? get lastClassifyError => _lastClassifyError;
  String? _lastClassifyError;

  /// Classifies the current camera frame's thumb orientation. Returns null
  /// when the model isn't ready or inference fails -- callers should treat
  /// that exactly like a low-confidence result (fall back to IMU).
  OrientationPrediction? classify(CameraImage image, int sensorOrientation) {
    if (!_ready || _interpreter == null) return null;
    try {
      final inputData = _preprocess(image, sensorOrientation);

      // REAL BUG, found from a real capture (2026-08-27, 996a22c8): the
      // previous call was
      //     _interpreter.runForMultipleInputs([inputData], {0: outputBuffer})
      // with `inputData` a FLAT Float32List. That threw "Bad state: failed
      // precondition" on every single inference -- confirmed live, with
      // modelReady:true and initError:null in the same record, so the model
      // loaded fine and only inference failed.
      //
      // Mechanism: runForMultipleInputs infers a shape from each input via
      // Tensor.getInputShapeIfDifferent() and RESIZES the input tensor when
      // it differs. A flat Float32List of 224*224*3 infers as shape
      // [150528], which differs from the model's real [1, 224, 224, 3], so
      // the interpreter dutifully resized its input tensor to a rank-1
      // 150528 vector -- after which the first convolution has no valid
      // spatial dimensions and the graph fails its own preconditions.
      //
      // The flat buffer itself was the right call (the nested form boxes
      // 150K+ doubles per throttled inference, real jank on a budget phone).
      // What was wrong was the entry point. The tensor-level API takes the
      // same flat buffer and copies it into the already-correctly-shaped
      // tensor WITHOUT any shape inference or resize, so it keeps the
      // allocation win and drops the bug.
      final inTensor = _interpreter!.getInputTensor(0);
      final outTensor = _interpreter!.getOutputTensor(0);
      inTensor.setTo(inputData);
      _interpreter!.invoke();
      final outputBuffer = Float32List(_classes.length);
      outTensor.copyTo(outputBuffer);

      var bestIdx = 0;
      for (var i = 1; i < outputBuffer.length; i++) {
        if (outputBuffer[i] > outputBuffer[bestIdx]) bestIdx = i;
      }
      return OrientationPrediction(_classes[bestIdx], outputBuffer[bestIdx]);
    } catch (e) {
      _lastClassifyError = e.toString();
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
