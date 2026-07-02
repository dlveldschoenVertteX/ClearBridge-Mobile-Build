import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';

/// A single captured frame plus the context it was shot in. The bytes are the
/// raw luminance (Y) plane of the YUV camera frame — the upload service is
/// responsible for any re-encoding (kept identical to the previous contract).
///
/// Ground-truth design: [zoneId] is a controller-assigned label (hint only).
/// The backend should verify and re-classify using [thumbAngleDegrees] +
/// [targetAngleDegrees] + [angularError] — these are measured independently
/// and survive a mislabeled zone.
class TaggedFrame {
  final Uint8List bytes;
  final DateTime timestamp;
  final bool flashOn;
  final double flashIntensity;
  final double laplacianScore;

  /// App-assigned zone label — treat as a hint, not ground truth.
  /// e.g. 'angle_front', 'transition_front_left'.
  final String zoneId;

  /// Actual thumb rotation angle from MediaPipe at the moment of capture.
  /// This is the verifiable ground truth the backend uses for re-classification.
  final double thumbAngleDegrees;

  /// The target angle this zone was aiming for (e.g. 0.0 for front, -90.0 for
  /// left). Null for transition frames which have no fixed target.
  final double? targetAngleDegrees;

  /// Shortest-arc degrees between [thumbAngleDegrees] and [targetAngleDegrees]
  /// at the moment of capture. Null for transition frames.
  /// If this exceeds ~20°, the backend should consider re-classifying the frame.
  final double? angularError;

  /// Normalized hand height in frame (0–1) as a distance-from-lens proxy.
  /// Values outside 0.35–0.85 indicate the user was too close or too far.
  final double thumbCoverageRatio;

  /// Normalized thumb bounding box at the moment of capture (values 0–1 in
  /// frame coordinates). Sent to the backend so SfM can crop exactly to the
  /// thumb without re-running detection on compressed frames.
  final Rect? thumbRoi;

  /// Raw Y-plane dimensions. The backend decodes [bytes] as:
  ///   np.frombuffer(data, dtype=uint8).reshape((imageHeight, bytesPerRow))[:, :imageWidth]
  /// [bytesPerRow] is the effective stride (capped to buffer capacity / height)
  /// and may equal [imageWidth] on devices that don't pad the Y-plane.
  final int imageWidth;
  final int imageHeight;
  final int bytesPerRow;

  const TaggedFrame({
    required this.bytes,
    required this.timestamp,
    required this.flashOn,
    required this.flashIntensity,
    required this.laplacianScore,
    required this.zoneId,
    required this.thumbAngleDegrees,
    required this.imageWidth,
    required this.imageHeight,
    required this.bytesPerRow,
    this.targetAngleDegrees,
    this.angularError,
    this.thumbCoverageRatio = 0.0,
    this.thumbRoi,
  });
}

/// Frame-fed burst collector.
///
/// A [CameraController] supports only one image stream at a time, and the
/// capture controller keeps that single stream running so MediaPipe hand
/// detection never stops (constraint #10). This service therefore does NOT open
/// its own stream — the controller pushes every live frame in via [offerFrame],
/// and [captureAngleBurst] / [captureTransitionBurst] open a short timed window
/// over those frames, keeping the two sharpest.
class HybridCaptureService {
  // Exit the burst window as soon as this many candidates are buffered; the
  // timeout (windowMs) is only a fallback for slow-frame-rate devices.
  static const _minCandidates = 8;
  // Hard cap on retained candidates — prevents unbounded Y-plane copies and
  // the GC pressure they cause (~2 MB each at max stream resolution).
  static const _maxCandidates = 12;
  // Early exit only fires when _minCandidates frames ALL exceed this score.
  // Prevents the burst from closing on the first 8 frames when they are
  // blurry/dim — better frames later in the 700ms window are then considered.
  static const _minBurstQuality = 50.0;

  bool _collecting = false;
  final List<_Candidate> _window = [];
  Completer<void>? _earlyExitCompleter;
  Map<String, dynamic>? _lastBurstStats;

  /// Stats from the most recent burst window.
  Map<String, dynamic>? get lastBurstStats => _lastBurstStats;

  /// Latest flash state, supplied by the controller each frame so captured
  /// frames can be tagged without reaching back into the flash controller.
  bool _flashOn = false;
  double _flashIntensity = 0.0;

  /// Brightness measured during the most recent flash-off frame.
  /// Used for scoring during flash-on frames so torch light doesn't inflate
  /// brightness scores and cause overexposed frames to win the burst window.
  double _lastStableBrightness = 128.0;

  void updateFlashState({required bool flashOn, required double intensity}) {
    _flashOn = flashOn;
    _flashIntensity = intensity;
  }

  /// Called from the controller's single image-stream callback for every frame.
  /// Computes focus once and, when a burst window is open, retains the frame
  /// bytes as a capture candidate. Returns raw sharpness (for the focus meter);
  /// candidates are ranked by a weighted sharpness+brightness score so the
  /// best-exposed AND sharpest frames win.
  ///
  /// Brightness is only measured on flash-off frames and cached as
  /// [_lastStableBrightness]. On flash-on frames the cached value is used for
  /// scoring, preventing torch-lit readings from inflating the brightness score
  /// and selecting overexposed frames during night-mode bursts.
  double offerFrame(CameraImage image, {Rect? thumbRoi}) {
    final sharpness = _computeThumbFocus(image, thumbRoi);
    if (_collecting) {
      // Use stable ambient brightness for scoring — not torch-lit readings.
      // Restrict brightness measurement to the thumb ROI so background
      // lighting doesn't dominate the score.
      final brightness = _flashOn
          ? _lastStableBrightness
          : _measureBrightness(image, thumbRoi: thumbRoi);
      if (!_flashOn) _lastStableBrightness = brightness;
      final brightnessScore = _mapBrightnessScore(brightness);
      final weightedScore = sharpness * 0.8 + brightnessScore * 0.2;
      // Score first — copy the Y-plane only for frames that earn a slot.
      // At ~2 MB per copy and up to 12 candidates, copying before the check
      // wastes ~24 MB of short-lived allocations per burst.
      if (_window.length < _maxCandidates) {
        final bytes = _extractBytes(image);
        if (bytes != null) {
          final h = image.height;
          final effectiveStride = h > 0
              ? math.min(image.planes[0].bytesPerRow, bytes.length ~/ h)
              : image.planes[0].bytesPerRow;
          _window.add(_Candidate(
            bytes, weightedScore, DateTime.now(),
            thumbRoi: thumbRoi,
            width: image.width,
            height: h,
            bytesPerRow: effectiveStride,
          ));
        }
      } else {
        var lowestIdx = 0;
        for (var i = 1; i < _window.length; i++) {
          if (_window[i].score < _window[lowestIdx].score) lowestIdx = i;
        }
        if (weightedScore > _window[lowestIdx].score) {
          final bytes = _extractBytes(image);
          if (bytes != null) {
            final h = image.height;
            final effectiveStride = h > 0
                ? math.min(image.planes[0].bytesPerRow, bytes.length ~/ h)
                : image.planes[0].bytesPerRow;
            _window[lowestIdx] = _Candidate(
              bytes, weightedScore, DateTime.now(),
              thumbRoi: thumbRoi,
              width: image.width,
              height: h,
              bytesPerRow: effectiveStride,
            );
          }
        }
      }
      // Early exit only when _minCandidates frames all clear the quality
      // floor — prevents closing the burst on an initial run of blurry frames.
      final goodCount = _window.where((c) => c.score >= _minBurstQuality).length;
      if (goodCount >= _minCandidates) {
        final c = _earlyExitCompleter;
        if (c != null && !c.isCompleted) c.complete();
      }
    }
    return sharpness; // raw sharpness drives the live focus meter
  }

  static double _measureBrightness(CameraImage image, {Rect? thumbRoi}) {
    if (image.planes.isEmpty) return 128.0;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    if (w < 1 || h < 1) return 128.0;
    final stride =
        h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;
    double sum = 0;
    int count = 0;
    if (thumbRoi != null) {
      final x0 = (thumbRoi.left * w).clamp(0, w - 1).toInt();
      final y0 = (thumbRoi.top * h).clamp(0, h - 1).toInt();
      final x1 = (thumbRoi.right * w).clamp(0, w - 1).toInt();
      final y1 = (thumbRoi.bottom * h).clamp(0, h - 1).toInt();
      if (x1 > x0 && y1 > y0) {
        for (int yy = y0; yy < y1; yy += 8) {
          final row = yy * stride;
          for (int xx = x0; xx < x1; xx += 8) {
            sum += bytes[row + xx];
            count++;
          }
        }
      }
    } else {
      for (int i = 0; i < bytes.length; i += 16) {
        sum += bytes[i];
        count++;
      }
    }
    return count > 0 ? sum / count : 128.0;
  }

  static double _mapBrightnessScore(double brightness) {
    if (brightness < 60 || brightness > 220) return 0.0;
    if (brightness < 120) return (brightness - 60) / 60; // ramp up
    if (brightness <= 180) return 1.0; // optimal
    return 1.0 - ((brightness - 180) / 40).clamp(0.0, 1.0); // ramp down
  }

  /// Angle lock burst: collect for 500ms, keep the 3 sharpest frames.
  /// [targetAngleDegrees] is the zone's intended target (used to compute
  /// [angularError] on each frame for backend ground-truth verification).
  Future<List<TaggedFrame>> captureAngleBurst({
    required String zoneId,
    required double thumbAngleDegrees,
    required double targetAngleDegrees,
    required double thumbCoverageRatio,
  }) {
    return _collect(
      zoneId: zoneId,
      thumbAngleDegrees: thumbAngleDegrees,
      targetAngleDegrees: targetAngleDegrees,
      thumbCoverageRatio: thumbCoverageRatio,
      windowMs: 700,
      keep: 3,
    );
  }

  /// Transition burst: collect for 300ms, keep the 2 sharpest frames.
  /// No fixed target — [targetAngleDegrees] and [angularError] are null.
  Future<List<TaggedFrame>> captureTransitionBurst({
    required String zoneId,
    required double thumbAngleDegrees,
    required double thumbCoverageRatio,
  }) {
    return _collect(
      zoneId: zoneId,
      thumbAngleDegrees: thumbAngleDegrees,
      targetAngleDegrees: null, // transitions have no fixed target
      thumbCoverageRatio: thumbCoverageRatio,
      windowMs: 300,
      keep: 2,
    );
  }

  Future<List<TaggedFrame>> _collect({
    required String zoneId,
    required double thumbAngleDegrees,
    required double? targetAngleDegrees,
    required double thumbCoverageRatio,
    required int windowMs,
    required int keep,
  }) async {
    _window.clear();
    _earlyExitCompleter = Completer<void>();
    _collecting = true;
    var earlyExit = false;

    // Exit as soon as _minCandidates frames are buffered, or after windowMs.
    await Future.any<void>([
      _earlyExitCompleter!.future.then((_) => earlyExit = true),
      Future<void>.delayed(Duration(milliseconds: windowMs)),
    ]);
    _collecting = false;
    _earlyExitCompleter = null;

    if (_window.isEmpty) {
      _lastBurstStats = {'candidateCount': 0, 'minScore': 0.0, 'maxScore': 0.0, 'earlyExit': false};
      return const [];
    }
    final scores = _window.map((c) => c.score).toList();
    _lastBurstStats = {
      'candidateCount': _window.length,
      'minScore':       double.parse(scores.reduce(math.min).toStringAsFixed(1)),
      'maxScore':       double.parse(scores.reduce(math.max).toStringAsFixed(1)),
      'earlyExit':      earlyExit,
    };
    final candidates = List<_Candidate>.from(_window)
      ..sort((a, b) => b.score.compareTo(a.score));
    _window.clear();

    // Compute shortest-arc angular error once (same for all frames in burst).
    final double? angularError = targetAngleDegrees != null
        ? _shortestArc(thumbAngleDegrees, targetAngleDegrees)
        : null;

    return candidates.take(keep).map((c) {
      return TaggedFrame(
        bytes: c.bytes,
        timestamp: c.timestamp,
        flashOn: _flashOn,
        flashIntensity: _flashIntensity,
        laplacianScore: c.score,
        zoneId: zoneId,
        thumbAngleDegrees: thumbAngleDegrees,
        targetAngleDegrees: targetAngleDegrees,
        angularError: angularError,
        thumbCoverageRatio: thumbCoverageRatio,
        thumbRoi: c.thumbRoi,
        imageWidth: c.width,
        imageHeight: c.height,
        bytesPerRow: c.bytesPerRow,
      );
    }).toList();
  }

  /// Shortest arc between two angles (0–180°).
  static double _shortestArc(double a, double b) {
    var diff = (a - b).abs() % 360.0;
    if (diff > 180.0) diff = 360.0 - diff;
    return diff;
  }

  /// Laplacian variance over the thumb ROI (normalized 0–1 rect) if provided,
  /// otherwise over a 200x200 centre crop. Higher = sharper.
  double _computeThumbFocus(CameraImage image, Rect? thumbRoi) {
    if (image.planes.isEmpty) return 0.0;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    if (w < 4 || h < 4) return 0.0;
    // Some Android devices (e.g. Samsung A16) report bytesPerRow > width but
    // deliver a buffer that is only width×height bytes. Cap stride to the
    // actual buffer capacity to prevent RangeError in the Laplacian loop.
    final stride = h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;

    int x0, y0, x1, y1;
    if (thumbRoi != null) {
      x0 = (thumbRoi.left * w).clamp(1, w - 2).toInt();
      y0 = (thumbRoi.top * h).clamp(1, h - 2).toInt();
      x1 = (thumbRoi.right * w).clamp(1, w - 2).toInt();
      y1 = (thumbRoi.bottom * h).clamp(1, h - 2).toInt();
    } else {
      const half = 100;
      final cx = w ~/ 2;
      final cy = h ~/ 2;
      x0 = (cx - half).clamp(1, w - 2);
      x1 = (cx + half).clamp(1, w - 2);
      y0 = (cy - half).clamp(1, h - 2);
      y1 = (cy + half).clamp(1, h - 2);
    }
    if (x1 - x0 < 2 || y1 - y0 < 2) return 0.0;

    // Welford's online variance over a 4-neighbour Laplacian, subsampled by 2.
    var mean = 0.0;
    var m2 = 0.0;
    var n = 0;
    for (var yy = y0; yy < y1; yy += 2) {
      final row = yy * stride;
      final up = (yy - 1) * stride;
      final dn = (yy + 1) * stride;
      for (var xx = x0; xx < x1; xx += 2) {
        final c = bytes[row + xx];
        final lap =
            (4 * c - bytes[row + xx - 1] - bytes[row + xx + 1] - bytes[up + xx] - bytes[dn + xx])
                .toDouble();
        n++;
        final d = lap - mean;
        mean += d / n;
        m2 += d * (lap - mean);
      }
    }
    return n > 1 ? m2 / (n - 1) : 0.0;
  }

  /// EMA smoothing helper (also used by the capture controller for the meters).
  static double ema(double previous, double incoming, {double alpha = 0.3}) =>
      alpha * incoming + (1 - alpha) * previous;

  /// Mean luminance of the Y plane, optionally restricted to [roi] (normalized
  /// 0-1 Rect). Shared brightness helper for controllers without their own ROI
  /// tracking (see MultiAngleCaptureController._meanLuma for the ROI variant).
  static double meanLuma(CameraImage image, {Rect? roi}) {
    if (image.planes.isEmpty) return 0.0;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    if (w < 8 || h < 8) return 0.0;
    final stride = h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;
    var sum = 0;
    var n = 0;
    if (roi != null) {
      final x0 = (roi.left * w).clamp(0, w - 1).toInt();
      final y0 = (roi.top * h).clamp(0, h - 1).toInt();
      final x1 = (roi.right * w).clamp(0, w - 1).toInt();
      final y1 = (roi.bottom * h).clamp(0, h - 1).toInt();
      if (x1 > x0 + 1 && y1 > y0 + 1) {
        for (var y = y0; y < y1; y += 8) {
          final row = y * stride;
          for (var x = x0; x < x1; x += 8) {
            sum += bytes[row + x];
            n++;
          }
        }
        return n > 0 ? sum / n : 0.0;
      }
    }
    for (var y = 0; y < h; y += 8) {
      final row = y * stride;
      for (var x = 0; x < w; x += 8) {
        sum += bytes[row + x];
        n++;
      }
    }
    return n > 0 ? sum / n : 0.0;
  }

  Uint8List? _extractBytes(CameraImage image) {
    if (image.planes.isEmpty) return null;
    try {
      return Uint8List.fromList(image.planes[0].bytes);
    } on RangeError {
      return null;
    }
  }

  void reset() {
    _collecting = false;
    _window.clear();
    _lastStableBrightness = 128.0;
    _lastBurstStats = null;
    final c = _earlyExitCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _earlyExitCompleter = null;
  }
}

class _Candidate {
  final Uint8List bytes;
  final double score;
  final DateTime timestamp;
  final Rect? thumbRoi;
  final int width;
  final int height;
  final int bytesPerRow;
  const _Candidate(
    this.bytes,
    this.score,
    this.timestamp, {
    this.thumbRoi,
    required this.width,
    required this.height,
    required this.bytesPerRow,
  });
}
