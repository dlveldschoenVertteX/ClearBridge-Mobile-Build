import 'dart:typed_data';

/// Angle definitions — order matches training pipeline
class CaptureAngles {
  static const List<String> keys = ['front', 'right', 'top', 'left'];
  static const List<String> keyList = keys;
  // Not currently wired into any screen. Degrees intentionally left out of
  // this copy -- the real fire angles live in ThumbAngleService._offAxisDeg /
  // _topOffAxisDeg and are still being tuned; a previous version of this text
  // hardcoded 45° here while the actual target was 15-20°, which is exactly
  // the kind of instructed-vs-required mismatch that causes "won't fire"
  // confusion.
  static const List<String> instructions = [
    'Point camera straight down at your thumb',
    'Tilt phone to the RIGHT — capture right edge',
    'Tilt toward THUMB TIP — capture top of thumbprint',
    'Tilt phone to the LEFT — capture left edge',
  ];
  static const List<String> details = [
    'Place RIGHT thumb flat on dark surface. Hold phone 15-20cm above, straight down.',
    'Keep thumb flat. Tilt phone right — right edge of thumbprint in frame.',
    'Tilt phone forward — tip of thumb fills frame, ridges converge at top.',
    'Mirror of right side. Left edge of thumbprint in frame.',
  ];
  static const List<int> frameCounts = [1, 2, 2, 2];
}

/// Stores all frames and metadata for a complete 4-angle capture session.
class MultiAngleCapture {
  /// Angle order: [0]=front, [1]=right, [2]=top, [3]=left
  final List<List<Uint8List>> capturedFrames; // [angle][frame]

  /// Parallel to [capturedFrames]: true = frame was captured with torch on.
  /// Used by upload service to tag ambient vs flash frames in Storage filenames
  /// so the backend can Mertens-fuse both types per angle. Empty list means
  /// all frames are treated as ambient (backward-compatible with older captures).
  final List<List<bool>> isFlashFrame;

  final Map<String, dynamic> metadata;

  /// Per-angle accelerometer smoothness score (0–1, higher = steadier hold).
  final List<double> accelerometerSmoothnessPerAngle;

  /// Time taken to complete each angle in milliseconds.
  final List<int> angleTimingsMs;

  const MultiAngleCapture({
    required this.capturedFrames,
    required this.metadata,
    this.isFlashFrame = const [],
    this.accelerometerSmoothnessPerAngle = const [],
    this.angleTimingsMs = const [],
  });

  /// Total frame count: 1 + 2 + 2 + 2 = 7
  int get totalFrames =>
      capturedFrames.fold(0, (sum, frames) => sum + frames.length);

  bool get isComplete =>
      capturedFrames.length == 4 &&
      capturedFrames[0].isNotEmpty &&
      capturedFrames[1].length >= 2 &&
      capturedFrames[2].length >= 2 &&
      capturedFrames[3].length >= 2;
}
