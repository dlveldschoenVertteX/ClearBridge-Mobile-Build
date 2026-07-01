import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class FingerDetectionResult {
  final bool isFingerDetected;
  final bool hasContour;
  final bool centered;
  final double centerX;
  final double centerY;
  final double areaRatio;
  final double skinRatio;
  final double strongSkinRatio;
  final double fillRatio;
  final double aspectRatio;
  final double edgeDensity;
  final double textureScore;
  final String message;
  final String rejectionReason;

  const FingerDetectionResult({
    required this.isFingerDetected,
    required this.hasContour,
    required this.centered,
    required this.centerX,
    required this.centerY,
    required this.areaRatio,
    required this.skinRatio,
    required this.strongSkinRatio,
    required this.fillRatio,
    required this.aspectRatio,
    required this.edgeDensity,
    required this.textureScore,
    required this.message,
    required this.rejectionReason,
  });
}

class FingerDetectionService {
  static const double _minSkinRatio = 0.20;
  static const double _minContourFillRatio = 0.30;
  static const double _rejectSmallAreaRatio = 0.15;
  static const double _minAcceptAreaRatio = 0.20;
  static const double _maxAreaRatio = 0.95;
  static const double _centerMin = 0.25;
  static const double _centerMax = 0.75;
  static const double _minEdgeDensity = 0.001;
  static const double _maxEdgeDensity = 0.40;
  static const double _minTextureVariance = 400.0;
  static const int _sampleStep = 12;

  const FingerDetectionService();

  FingerDetectionResult analyze(CameraImage image) {
    if (image.width <= 0 || image.height <= 0) {
      return _noFingerResult(rejectionReason: 'empty_frame');
    }

    final yPlane = image.planes[0];
    if (yPlane.bytes.isEmpty) {
      return _noFingerResult(rejectionReason: 'empty_y_plane');
    }

    final roiLeft = (image.width * 0.20).round();
    final roiTop = (image.height * 0.20).round();
    final roiRight = (image.width * 0.80).round();
    final roiBottom = (image.height * 0.80).round();
    final roiWidth = roiRight - roiLeft;
    final roiHeight = roiBottom - roiTop;
    if (roiWidth <= 0 || roiHeight <= 0) {
      return _noFingerResult(rejectionReason: 'roi_empty');
    }

    final widthSamples = ((roiWidth - 1) ~/ _sampleStep) + 1;
    final heightSamples = ((roiHeight - 1) ~/ _sampleStep) + 1;
    final foregroundMask = List.generate(
      heightSamples,
      (_) => List<bool>.filled(widthSamples, false),
    );

    // Pass 1: compute grayscale mean/variance (Y plane only) for ROI.
    int totalSamples = 0;
    double sum = 0;
    double sumSq = 0;
    for (int sampleY = 0; sampleY < heightSamples; sampleY++) {
      final y = roiTop + sampleY * _sampleStep;
      for (int sampleX = 0; sampleX < widthSamples; sampleX++) {
        final x = roiLeft + sampleX * _sampleStep;
        final luma = _getY(image, x, y);
        if (luma == null) continue;
        totalSamples++;
        sum += luma;
        sumSq += luma * luma;
      }
    }

    if (totalSamples == 0) {
      return _noFingerResult(rejectionReason: 'no_samples');
    }

    final mean = sum / totalSamples;
    final variance = math.max(0.0, (sumSq / totalSamples) - (mean * mean));
    final stdDev = math.sqrt(variance);
    final textureScore = variance; // requested variance-based texture signal

    // Pass 2: build a simple foreground mask and compute edge density in ROI.
    final delta = math.max(12.0, stdDev * 0.9);
    final lower = mean - delta;
    final upper = mean + delta;
    int foregroundSamples = 0;
    int eligibleEdgeSamples = 0;
    int edgeSamples = 0;
    int edgeSamplesBoost = 0;

    for (int sampleY = 0; sampleY < heightSamples; sampleY++) {
      final y = roiTop + sampleY * _sampleStep;
      if (y <= 0 || y >= image.height - 1) continue;
      for (int sampleX = 0; sampleX < widthSamples; sampleX++) {
        final x = roiLeft + sampleX * _sampleStep;
        if (x <= 0 || x >= image.width - 1) continue;
        final center = _getY(image, x, y);
        if (center == null) continue;

        final isForeground = center >= lower && center <= upper;
        if (isForeground) {
          foregroundSamples++;
          foregroundMask[sampleY][sampleX] = true;
        }

        final left = _getY(image, x - 1, y);
        final right = _getY(image, x + 1, y);
        final up = _getY(image, x, y - 1);
        final down = _getY(image, x, y + 1);
        if (left == null || right == null || up == null || down == null) {
          continue;
        }

        eligibleEdgeSamples++;
        final horizontal = (right - left).abs();
        final vertical = (down - up).abs();
        final gradient = (horizontal + vertical) / 2.0;
        if (gradient >= 18) {
          edgeSamples++;
        }
        // Edge boost pass: approximate Canny(30..100) by lowering gradient
        // threshold when edges are otherwise too sparse.
        if (gradient >= 10) {
          edgeSamplesBoost++;
        }
      }
    }

    final skinRatio =
        totalSamples == 0 ? 0.0 : (foregroundSamples / totalSamples);
    final edgeDensity =
        eligibleEdgeSamples == 0 ? 0.0 : (edgeSamples / eligibleEdgeSamples);
    final boostedEdgeDensity = eligibleEdgeSamples == 0
        ? 0.0
        : (edgeSamplesBoost / eligibleEdgeSamples);
    final effectiveEdgeDensity =
        edgeDensity < _minEdgeDensity ? boostedEdgeDensity : edgeDensity;

    if (kDebugMode) {
      debugPrint(
        'FINGER_PIPELINE | '
        'w=${image.width} h=${image.height} '
        'roi=${roiWidth}x$roiHeight '
        'mean=${mean.toStringAsFixed(1)} '
        'var=${variance.toStringAsFixed(1)} '
        'skin=${skinRatio.toStringAsFixed(3)} '
        'edge=${effectiveEdgeDensity.toStringAsFixed(3)}',
      );
    }

    if (skinRatio < _minSkinRatio) {
      return _noFingerResult(
        skinRatio: skinRatio,
        message: 'Place your thumb',
        rejectionReason: 'skin_below_threshold',
      );
    }

    final contour = _findLargestContour(foregroundMask);
    if (contour == null) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: false,
        centered: false,
        centerX: 0.5,
        centerY: 0.5,
        areaRatio: 0,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: 0,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Place your thumb',
        rejectionReason: 'no_dominant_contour',
      );
    }

    final boxWidthSamples = math.max(1, contour.maxX - contour.minX + 1);
    final boxHeightSamples = math.max(1, contour.maxY - contour.minY + 1);
    final boxWidth = boxWidthSamples * _sampleStep;
    final boxHeight = boxHeightSamples * _sampleStep;
    final areaRatio = (boxWidth * boxHeight) / (image.width * image.height);
    final fillRatio = contour.pixelCount / (boxWidthSamples * boxHeightSamples);
    final centerX = (contour.sumX / contour.pixelCount).clamp(0.0, 1.0);
    final centerY = (contour.sumY / contour.pixelCount).clamp(0.0, 1.0);
    final centered =
        centerX >= _centerMin &&
        centerX <= _centerMax &&
        centerY >= _centerMin &&
        centerY <= _centerMax;

    if (areaRatio < _rejectSmallAreaRatio) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: true,
        centered: centered,
        centerX: centerX,
        centerY: centerY,
        areaRatio: areaRatio,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: fillRatio,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Move closer',
        rejectionReason: 'too_small',
      );
    }

    if (areaRatio < _minAcceptAreaRatio) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: true,
        centered: centered,
        centerX: centerX,
        centerY: centerY,
        areaRatio: areaRatio,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: fillRatio,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Move closer',
        rejectionReason: 'too_small',
      );
    }

    if (areaRatio > _maxAreaRatio) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: true,
        centered: centered,
        centerX: centerX,
        centerY: centerY,
        areaRatio: areaRatio,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: fillRatio,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Use thumb only',
        rejectionReason: 'too_large_not_finger',
      );
    }

    if (!centered) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: true,
        centered: centered,
        centerX: centerX,
        centerY: centerY,
        areaRatio: areaRatio,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: fillRatio,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Align your thumb',
        rejectionReason: 'not_centered',
      );
    }

    if (fillRatio < _minContourFillRatio) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: true,
        centered: centered,
        centerX: centerX,
        centerY: centerY,
        areaRatio: areaRatio,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: fillRatio,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Use thumb only',
        rejectionReason: 'weak_contour',
      );
    }

    if (effectiveEdgeDensity < _minEdgeDensity ||
        effectiveEdgeDensity > _maxEdgeDensity) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: true,
        centered: centered,
        centerX: centerX,
        centerY: centerY,
        areaRatio: areaRatio,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: fillRatio,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Use thumb only',
        rejectionReason: 'invalid_edge_density',
      );
    }

    if (textureScore < _minTextureVariance) {
      return FingerDetectionResult(
        isFingerDetected: false,
        hasContour: true,
        centered: centered,
        centerX: centerX,
        centerY: centerY,
        areaRatio: areaRatio,
        skinRatio: skinRatio,
        strongSkinRatio: skinRatio,
        fillRatio: fillRatio,
        aspectRatio: 0,
        edgeDensity: effectiveEdgeDensity,
        textureScore: textureScore,
        message: 'Use thumb only',
        rejectionReason: 'no_fingerprint_texture',
      );
    }

    return FingerDetectionResult(
      isFingerDetected: true,
      hasContour: true,
      centered: centered,
      centerX: centerX,
      centerY: centerY,
      areaRatio: areaRatio,
      skinRatio: skinRatio,
      strongSkinRatio: skinRatio,
      fillRatio: fillRatio,
      aspectRatio: 0,
      edgeDensity: effectiveEdgeDensity,
      textureScore: textureScore,
      message: 'Hold steady',
      rejectionReason: 'accepted',
    );
  }

  FingerDetectionResult _noFingerResult({
    double skinRatio = 0,
    String message = 'Place your thumb',
    String rejectionReason = 'no_finger',
  }) {
    return FingerDetectionResult(
      isFingerDetected: false,
      hasContour: false,
      centered: false,
      centerX: 0.5,
      centerY: 0.5,
      areaRatio: 0,
      skinRatio: skinRatio,
      strongSkinRatio: skinRatio,
      fillRatio: 0,
      aspectRatio: 0,
      edgeDensity: 0,
      textureScore: 0,
      message: message,
      rejectionReason: rejectionReason,
    );
  }

  double? _getY(CameraImage image, int x, int y) {
    if (x < 0 || y < 0 || x >= image.width || y >= image.height) {
      return null;
    }

    final yPlane = image.planes[0];
    final index = y * yPlane.bytesPerRow + x;
    if (index < 0 || index >= yPlane.bytes.length) {
      return null;
    }
    return yPlane.bytes[index].toDouble();
  }

  _ContourCandidate? _findLargestContour(List<List<bool>> mask) {
    if (mask.isEmpty || mask.first.isEmpty) {
      return null;
    }

    final height = mask.length;
    final width = mask.first.length;
    final visited = List.generate(
      height,
      (_) => List<bool>.filled(width, false),
    );

    _ContourCandidate? largest;
    final queue = <(int, int)>[];
    const directions = [(1, 0), (-1, 0), (0, 1), (0, -1)];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (!mask[y][x] || visited[y][x]) {
          continue;
        }

        int pixelCount = 0;
        int minX = x;
        int maxX = x;
        int minY = y;
        int maxY = y;
        double sumX = 0;
        double sumY = 0;

        visited[y][x] = true;
        queue.add((x, y));

        while (queue.isNotEmpty) {
          final (currentX, currentY) = queue.removeLast();
          pixelCount++;
          minX = math.min(minX, currentX);
          maxX = math.max(maxX, currentX);
          minY = math.min(minY, currentY);
          maxY = math.max(maxY, currentY);
          sumX += ((currentX * _sampleStep) + (_sampleStep / 2)) /
              (width * _sampleStep);
          sumY += ((currentY * _sampleStep) + (_sampleStep / 2)) /
              (height * _sampleStep);

          for (final (deltaX, deltaY) in directions) {
            final nextX = currentX + deltaX;
            final nextY = currentY + deltaY;
            if (nextX < 0 ||
                nextX >= width ||
                nextY < 0 ||
                nextY >= height ||
                visited[nextY][nextX] ||
                !mask[nextY][nextX]) {
              continue;
            }
            visited[nextY][nextX] = true;
            queue.add((nextX, nextY));
          }
        }

        final candidate = _ContourCandidate(
          pixelCount: pixelCount,
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          sumX: sumX,
          sumY: sumY,
        );

        if (largest == null || candidate.pixelCount > largest.pixelCount) {
          largest = candidate;
        }
      }
    }

    return largest;
  }
}

class _ContourCandidate {
  final int pixelCount;
  final int minX;
  final int maxX;
  final int minY;
  final int maxY;
  final double sumX;
  final double sumY;

  const _ContourCandidate({
    required this.pixelCount,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.sumX,
    required this.sumY,
  });
}
