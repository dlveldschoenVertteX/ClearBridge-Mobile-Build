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

    // Reject anything below the same "good" bar used for the early-exit
    // check above -- previously the burst returned its top-scoring frames
    // unconditionally, so an angle that's physically harder to hold steady
    // (faster/awkward orbit -> motion blur) could still fire and upload a
    // blurry capture as long as SOME frame scored better than the others in
    // that window, even if none were actually sharp. _fireAngleCapture
    // already treats an empty return as "nothing usable — reset and let the
    // user re-hold"; this makes that path also cover "the whole burst was
    // too blurry", not just "no candidates were collected at all".
    final qualifying =
        candidates.where((c) => c.score >= _minBurstQuality).toList();
    if (qualifying.isEmpty) return const [];

    // Compute shortest-arc angular error once (same for all frames in burst).
    final double? angularError = targetAngleDegrees != null
        ? _shortestArc(thumbAngleDegrees, targetAngleDegrees)
        : null;

    return qualifying.take(keep).map((c) {
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

  /// Live, on-device estimate of the thumb's native ridge wavelength (in raw
  /// preview pixels) over [roi]. Diagnostic-only for now -- the caller writes
  /// it to Firestore alongside the capture for comparison against the
  /// backend's own authoritative `afisWavelengthPx`; it does not yet drive
  /// any user-facing hint (see FrontCaptureController's `distanceHint`).
  ///
  /// A deliberately coarser Dart port of `afis_print.py`'s
  /// `_ridge_wavelength()`/`_orientation_field()` (autocorrelation-based, no
  /// FFT needed -- no FFT/DSP package exists anywhere in this project's
  /// pubspec.yaml files, and the backend's own trusted algorithm doesn't use
  /// one either). Simplifications relative to the backend, and why each is
  /// necessary rather than just cheaper:
  ///   - No per-block affine rotation (the backend rotates each 32x32 block
  ///     to its own local ridge orientation via Sobel + boxFilter). Instead,
  ///     a single coarse whole-ROI orientation check picks ONE of two axes
  ///     (row-bands vs column-bands) for every strip. This still has to be a
  ///     real check, not an assumed "ridges are horizontal" default -- a
  ///     tip-up thumb's ridge flow inside the guide crop varies by finger/
  ///     core position, and projecting the wrong axis produces a
  ///     confidently WRONG estimate, not just a noisier one.
  ///   - Subpixel (parabolic) peak interpolation on the autocorrelation
  ///     peak. Required, not polish: live-preview resolution is well below
  ///     the still's 3200px decode width, so the same physical ridge
  ///     spacing shows up as only a handful of raw preview pixels -- integer
  ///     lag alone can't distinguish enough steps across the real 9-14px
  ///     (still-space) sweet spot once rescaled.
  ///
  /// Returns null (never a fabricated fallback like the backend's default-
  /// to-9.0) when fewer than 2 strips qualify -- a wrong-but-plausible
  /// number would be worse than no signal for a value this is meant to
  /// eventually be trusted more than the existing brightness/coverage proxy.
  static RidgeWavelengthEstimate? estimateRidgeWavelengthPx(
    CameraImage image, {
    required Rect roi,
    int stripCount = 5,
    int stripThicknessPx = 4,
    double minStripStd = 6.0,
    int minLagPx = 2,
    // Hard ceiling on the autocorrelation search window (raw preview pixels).
    // Ridge periods > 40px live-preview correspond to > ~55px still-space via
    // the ~1.4x scale factor -- well above any range that produces usable NFIQ2
    // scores. Without this cap, low-frequency torch-gradient trends in the
    // signal dominate the autocorrelation envelope at longer lags and cause
    // a spurious "first local max" to be found at ~89px rather than the true
    // ~12-14px ridge period.
    int maxLagRawPx = 40,
    int maxSignalSamples = 300,
  }) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    if (w < 8 || h < 8) return null;
    final stride =
        h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;

    final x0 = (roi.left * w).clamp(1, w - 2).toInt();
    final y0 = (roi.top * h).clamp(1, h - 2).toInt();
    final x1 = (roi.right * w).clamp(1, w - 2).toInt();
    final y1 = (roi.bottom * h).clamp(1, h - 2).toInt();
    final roiW = x1 - x0;
    final roiH = y1 - y0;
    if (roiW < 16 || roiH < 16) return null;

    // Coarse whole-ROI orientation check -- ROI-granularity stand-in for the
    // backend's per-pixel Sobel orientation field. sumAbsRowGrad is large
    // when brightness changes fastest moving DOWN (detects horizontal
    // ridges); sumAbsColGrad is large when it changes fastest moving RIGHT
    // (detects vertical ridges). Subsampled by gradStep -- this only needs
    // to pick the dominant axis, not measure it precisely.
    const gradStep = 3;
    var sumAbsRowGrad = 0.0;
    var sumAbsColGrad = 0.0;
    for (var yy = y0; yy < y1 - gradStep; yy += gradStep) {
      final row = yy * stride;
      final rowNext = (yy + gradStep) * stride;
      for (var xx = x0; xx < x1 - gradStep; xx += gradStep) {
        sumAbsRowGrad += (bytes[row + xx] - bytes[rowNext + xx]).abs();
        sumAbsColGrad += (bytes[row + xx] - bytes[row + xx + gradStep]).abs();
      }
    }
    // Column gradients dominant -> brightness changes fastest moving right
    // -> ridges run vertically -> the periodic (ridge-perpendicular) axis
    // is X, so strips are horizontal row-bands averaged down to a signal
    // that varies along X. Otherwise strips are vertical column-bands
    // averaged across to a signal that varies along Y.
    final ridgesVertical = sumAbsColGrad >= sumAbsRowGrad;

    final projectedLen = ridgesVertical ? roiW : roiH;
    // Bound the O(L^2) autocorrelation cost regardless of live-preview
    // resolution, same "subsample for cost control" convention already used
    // by meanLuma (stride 8) and _computeThumbFocus (stride 2) above.
    final sampleStride = math.max(1, projectedLen ~/ maxSignalSamples);
    final sigLen = projectedLen ~/ sampleStride;
    if (sigLen < 16) return null;

    final lags = <double>[];
    for (var s = 0; s < stripCount; s++) {
      final sig = List<double>.filled(sigLen, 0.0);
      if (ridgesVertical) {
        final bandStart = y0 +
            ((roiH - stripThicknessPx) * s / math.max(1, stripCount - 1))
                .round();
        final by0 = bandStart.clamp(y0, y1 - stripThicknessPx);
        final by1 = math.min(y1, by0 + stripThicknessPx);
        if (by1 <= by0) continue;
        for (var yy = by0; yy < by1; yy++) {
          final row = yy * stride;
          for (var i = 0; i < sigLen; i++) {
            sig[i] += bytes[row + x0 + i * sampleStride];
          }
        }
        final n = by1 - by0;
        for (var i = 0; i < sigLen; i++) sig[i] /= n;
      } else {
        final bandStart = x0 +
            ((roiW - stripThicknessPx) * s / math.max(1, stripCount - 1))
                .round();
        final bx0 = bandStart.clamp(x0, x1 - stripThicknessPx);
        final bx1 = math.min(x1, bx0 + stripThicknessPx);
        if (bx1 <= bx0) continue;
        for (var xx = bx0; xx < bx1; xx++) {
          for (var i = 0; i < sigLen; i++) {
            sig[i] += bytes[(y0 + i * sampleStride) * stride + xx];
          }
        }
        final n = bx1 - bx0;
        for (var i = 0; i < sigLen; i++) sig[i] /= n;
      }

      final mean = sig.reduce((a, b) => a + b) / sig.length;
      var variance = 0.0;
      for (final v in sig) {
        variance += (v - mean) * (v - mean);
      }
      variance /= sig.length;
      if (math.sqrt(variance) < minStripStd) continue;

      // Mean-center then linear-detrend to suppress torch-gradient trends that
      // would otherwise produce spurious autocorrelation peaks at long lags.
      // Linear detrend: fit a line through the mean-centered signal and subtract
      // it. This is O(sigLen) and keeps the ridge-period component intact while
      // removing the slow brightness ramp from uneven torch illumination across
      // the pad.
      final centered = List<double>.generate(sig.length, (i) => sig[i] - mean);
      final slope = centered.isNotEmpty
          ? (centered.last - centered.first) / math.max(1, centered.length - 1)
          : 0.0;
      for (var i = 0; i < centered.length; i++) {
        centered[i] -= slope * i;
      }
      // Only compute the autocorrelation up to the max-lag ceiling. Beyond
      // ~40 raw px there is no plausible ridge period worth measuring; computing
      // beyond it would be wasted O(L) work and risks finding spurious peaks.
      final maxLagSubsampled =
          math.min(centered.length - 1, (maxLagRawPx / sampleStride).ceil() + 1);
      final ac = List<double>.filled(maxLagSubsampled + 1, 0.0);
      for (var lag = 0; lag <= maxLagSubsampled; lag++) {
        var sum = 0.0;
        for (var i = 0; i < centered.length - lag; i++) {
          sum += centered[i] * centered[i + lag];
        }
        ac[lag] = sum;
      }

      // First local maximum via sign-change in the discrete derivative,
      // rejecting lag <= minLagPx (mirrors afis_print.py's peaks[peaks>3],
      // scaled down since live-preview pixels are coarser than still pixels
      // -- see class docs). The search is bounded to maxLagSubsampled to
      // prevent spurious peaks from low-frequency lighting gradients.
      int? peakLag;
      for (var lag = 1; lag < ac.length - 1; lag++) {
        if (lag <= minLagPx) continue;
        if (ac[lag] > ac[lag - 1] && ac[lag] >= ac[lag + 1]) {
          peakLag = lag;
          break;
        }
      }
      if (peakLag == null) continue;

      // Subpixel parabolic interpolation around the integer peak.
      final yPrev = ac[peakLag - 1], yPeak = ac[peakLag], yNext = ac[peakLag + 1];
      final denom = yPrev - 2 * yPeak + yNext;
      final refinedLag = denom.abs() > 1e-9
          ? peakLag + 0.5 * (yPrev - yNext) / denom
          : peakLag.toDouble();
      // Convert the subsampled-signal lag back to raw preview pixels.
      lags.add(refinedLag * sampleStride);
    }

    if (lags.length < 2) return null;
    lags.sort();
    final mid = lags.length ~/ 2;
    final medianLagPx =
        lags.length.isOdd ? lags[mid] : (lags[mid - 1] + lags[mid]) / 2;

    return RidgeWavelengthEstimate(
      medianLagPx: medianLagPx,
      qualifyingStrips: lags.length,
      // 'rows' = strips were horizontal row-bands (ridges run vertically);
      // 'cols' = strips were vertical column-bands (ridges run horizontally).
      axis: ridgesVertical ? 'rows' : 'cols',
    );
  }

  /// EMA smoothing helper (also used by the capture controller for the meters).
  static double ema(double previous, double incoming, {double alpha = 0.3}) =>
      alpha * incoming + (1 - alpha) * previous;

  /// Intensity-weighted centroid of whatever's in [roi], along either the
  /// raw buffer's column axis ([alongRows] false, the default) or its row
  /// axis ([alongRows] true), for the guided left-right thumb-sweep capture
  /// (diagnostic-first -- see FrontCaptureController's sweepPositioning/
  /// sweepActive phases). No optical flow, no tracker state carried between
  /// calls -- per the sweep spec's own explicit design choice, a simple
  /// per-frame brightness-weighted centroid within the existing guide
  /// bounds is sufficient, since under torch/ambient light the thumb pad
  /// reads meaningfully brighter than the background it sweeps across. Same
  /// stride-safe, subsampled-scan pattern as [meanLuma]/[_measureBrightness]
  /// above.
  ///
  /// [alongRows] exists because this raw CameraImage buffer is delivered in
  /// the sensor's native (unrotated) orientation -- unlike the still-JPEG
  /// path (`decodeStillJpegToLuma`) or the live preview widget
  /// (`CameraPreview`), which both apply their own rotation before this
  /// buffer's axes would visually match on-screen left/right. For a typical
  /// back camera with `sensorOrientation=90` (this project's real, already-
  /// confirmed convention -- see `_computeGuideRegion`'s "90°-CW rotation"),
  /// the raw buffer's ROW axis is the one that ends up mapped to on-screen
  /// HORIZONTAL after that rotation, not its column axis. The caller is
  /// responsible for both picking the right axis for what it's trying to
  /// measure on screen, and for any sign flip the rotation direction
  /// implies (see FrontCaptureController's `_sweepScreenXFraction`).
  ///
  /// Returns the brightness-weighted mean position along the selected axis
  /// within [roi], normalized 0.0 (the axis's start edge) to 1.0 (its end
  /// edge). Returns null when the ROI has no usable signal (zero total
  /// brightness) rather than a fabricated fallback -- same "null over a
  /// wrong-but-plausible number" discipline as [estimateRidgeWavelengthPx].
  static double? estimateThumbCentroidX(
    CameraImage image, {
    required Rect roi,
    bool alongRows = false,
  }) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    if (w < 8 || h < 8) return null;
    final stride =
        h > 0 ? math.min(plane.bytesPerRow, bytes.length ~/ h) : plane.bytesPerRow;

    final x0 = (roi.left * w).clamp(0, w - 1).toInt();
    final y0 = (roi.top * h).clamp(0, h - 1).toInt();
    final x1 = (roi.right * w).clamp(0, w - 1).toInt();
    final y1 = (roi.bottom * h).clamp(0, h - 1).toInt();
    if (x1 <= x0 + 1 || y1 <= y0 + 1) return null;

    const step = 4; // subsample -- same cost-control convention as meanLuma (step 8)
    var weightedSum = 0.0;
    var totalWeight = 0.0;
    if (alongRows) {
      for (var yy = y0; yy < y1; yy += step) {
        final row = yy * stride;
        for (var xx = x0; xx < x1; xx += step) {
          final v = bytes[row + xx].toDouble();
          weightedSum += v * yy;
          totalWeight += v;
        }
      }
      if (totalWeight <= 0) return null;
      final centroidYPx = weightedSum / totalWeight;
      return ((centroidYPx - y0) / (y1 - y0)).clamp(0.0, 1.0);
    }
    for (var yy = y0; yy < y1; yy += step) {
      final row = yy * stride;
      for (var xx = x0; xx < x1; xx += step) {
        final v = bytes[row + xx].toDouble();
        weightedSum += v * xx;
        totalWeight += v;
      }
    }
    if (totalWeight <= 0) return null;
    final centroidXPx = weightedSum / totalWeight;
    return ((centroidXPx - x0) / (x1 - x0)).clamp(0.0, 1.0);
  }

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

/// Result of [HybridCaptureService.estimateRidgeWavelengthPx].
class RidgeWavelengthEstimate {
  /// Median autocorrelation-peak lag across qualifying strips, in raw
  /// live-preview pixels (NOT yet scaled to the backend's still-space
  /// `afisWavelengthPx` convention -- the caller applies that scale factor).
  final double medianLagPx;

  /// How many of the requested strips had enough texture (std >= minStripStd)
  /// and a detectable autocorrelation peak to contribute to the median.
  final int qualifyingStrips;

  /// 'rows' or 'cols' -- which axis the strips were built along. See
  /// [HybridCaptureService.estimateRidgeWavelengthPx]'s doc comment.
  final String axis;

  const RidgeWavelengthEstimate({
    required this.medianLagPx,
    required this.qualifyingStrips,
    required this.axis,
  });
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
