/// Isolate-safe single-pass frame quality analysis.
///
/// Extracted verbatim (May 2026) from the now-deprecated
/// `HybridCaptureScreen._computeFrameQuality`. Three signals are computed in
/// one pass over a *copied* byte buffer so the whole thing can be shipped to a
/// `compute()` isolate (a raw [CameraImage] cannot cross an isolate boundary —
/// that is the reason [FramePayload] exists):
///
///  1. YCbCr skin-centroid — thumb tracking without MediaPipe. **Unique to
///     this file**; not present in `focus_detector.dart` or
///     `mac_frame_scoring_service.dart`.
///  2. Welford online Laplacian variance — O(1) memory, single pass. NOTE:
///     this sub-computation is algorithmically identical to
///     `FocusDetector._computeVariance` (`focus_detector.dart`). It is kept
///     here because `FocusDetector` operates on a non-isolate-safe
///     [CameraImage]; this is the isolate-safe form. The live continuous
///     pipeline still uses `FocusDetector` — these were intentionally NOT
///     merged to avoid touching the active capture path.
///  3. Sub-sampled lighting mean (1/16 of pixels).
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';

class FramePayload {
  const FramePayload({
    required this.lumaBytes,
    required this.width,
    required this.height,
    required this.lumaRowStride,
    required this.lumaBytesPerPixel,
    this.cbBytes,
    this.crBytes,
    this.cbStride = 0,
    this.crStride = 0,
    this.cbPixelStride = 1,
    this.crPixelStride = 1,
  });

  final Uint8List lumaBytes;
  final int width;
  final int height;
  final int lumaRowStride;
  final int lumaBytesPerPixel;
  final Uint8List? cbBytes;
  final Uint8List? crBytes;
  final int cbStride;
  final int crStride;
  final int cbPixelStride;
  final int crPixelStride;

  factory FramePayload.fromImage(CameraImage image) {
    final luma = image.planes[0];
    Uint8List? cb, cr;
    int cbStride = 0, crStride = 0, cbPixelStride = 1, crPixelStride = 1;
    if (image.planes.length >= 3) {
      cb = Uint8List.fromList(image.planes[1].bytes);
      cr = Uint8List.fromList(image.planes[2].bytes);
      cbStride = image.planes[1].bytesPerRow;
      crStride = image.planes[2].bytesPerRow;
      cbPixelStride = image.planes[1].bytesPerPixel ?? 1;
      crPixelStride = image.planes[2].bytesPerPixel ?? 1;
    }
    return FramePayload(
      lumaBytes: Uint8List.fromList(luma.bytes),
      width: image.width,
      height: image.height,
      lumaRowStride: luma.bytesPerRow,
      lumaBytesPerPixel: luma.bytesPerPixel ?? 1,
      cbBytes: cb,
      crBytes: cr,
      cbStride: cbStride,
      crStride: crStride,
      cbPixelStride: cbPixelStride,
      crPixelStride: crPixelStride,
    );
  }
}

class FrameQualityResult {
  const FrameQualityResult({
    required this.rawFocus,
    required this.lightMean,
    this.thumbDx,
    this.thumbDy,
  });

  final double rawFocus;
  final double lightMean;
  final double? thumbDx;
  final double? thumbDy;
}

int extractGray(Uint8List bytes, int offset, int bpp) {
  if (offset < 0 || offset + bpp - 1 >= bytes.length) return 0;
  if (bpp == 1) return bytes[offset] & 0xFF;
  final b = bytes[offset] & 0xFF;
  final g = bytes[offset + 1] & 0xFF;
  final r = bytes[offset + 2] & 0xFF;
  return (0.299 * r + 0.587 * g + 0.114 * b).round();
}

/// Top-level so it can be sent to a Flutter `compute()` isolate.
FrameQualityResult computeFrameQuality(FramePayload p) {
  // 1. YCbCr thumb centroid ─────────────────────────────────────────────────
  double? thumbDx, thumbDy;
  if (p.cbBytes != null && p.crBytes != null) {
    const cbMin = 77, cbMax = 127, crMin = 133, crMax = 173, minSkin = 500;
    double sumX = 0, sumY = 0;
    int count = 0;
    for (int row = 0; row < p.height; row += 2) {
      final chromaRow = row ~/ 2;
      for (int col = 0; col < p.width; col += 2) {
        final chromaCol = col ~/ 2;
        // Use bytesPerRow + bytesPerPixel to handle both planar (YUV420) and
        // semi-planar (NV12/NV21) chroma formats correctly.
        final cbIdx = chromaRow * p.cbStride + chromaCol * p.cbPixelStride;
        final crIdx = chromaRow * p.crStride + chromaCol * p.crPixelStride;
        if (cbIdx >= p.cbBytes!.length || crIdx >= p.crBytes!.length) continue;
        final cb = p.cbBytes![cbIdx] & 0xFF;
        final cr = p.crBytes![crIdx] & 0xFF;
        if (cb >= cbMin && cb <= cbMax && cr >= crMin && cr <= crMax) {
          sumX += col / p.width;
          sumY += row / p.height;
          count++;
        }
      }
    }
    if (count >= minSkin) {
      thumbDx = sumX / count;
      thumbDy = sumY / count;
    }
  }

  // 2. Laplacian variance — Welford, O(1) memory, single pass ───────────────
  double rawFocus = 0.0;
  {
    const roiSize = 200;
    if (p.width >= roiSize + 2 && p.height >= roiSize + 2) {
      final startX = (p.width - roiSize) ~/ 2;
      final startY = (p.height - roiSize) ~/ 2;
      final rs = p.lumaRowStride;
      final bpp = p.lumaBytesPerPixel;
      int n = 0;
      double mean = 0.0, m2 = 0.0;
      for (int y = 1; y < roiSize - 1; y++) {
        for (int x = 1; x < roiSize - 1; x++) {
          final px = startX + x;
          final py = startY + y;
          final c = extractGray(p.lumaBytes, py * rs + px * bpp, bpp);
          final t = extractGray(p.lumaBytes, (py - 1) * rs + px * bpp, bpp);
          final b = extractGray(p.lumaBytes, (py + 1) * rs + px * bpp, bpp);
          final l = extractGray(p.lumaBytes, py * rs + (px - 1) * bpp, bpp);
          final r = extractGray(p.lumaBytes, py * rs + (px + 1) * bpp, bpp);
          final val = (t + b + l + r - 4 * c).toDouble();
          n++;
          final delta = val - mean;
          mean += delta / n;
          m2 += delta * (val - mean);
        }
      }
      rawFocus = n >= 2 ? m2 / n : 0.0;
    }
  }

  // 3. Lighting mean — 1/16 pixel sample ────────────────────────────────────
  double lightMean = 0.0;
  {
    double sum = 0;
    int count = 0;
    final bpp = p.lumaBytesPerPixel;
    for (int y = 0; y < p.height; y += 4) {
      for (int x = 0; x < p.width; x += 4) {
        final offset = y * p.lumaRowStride + x * bpp;
        if (offset >= p.lumaBytes.length) continue;
        sum += extractGray(p.lumaBytes, offset, bpp);
        count++;
      }
    }
    lightMean = count > 0 ? sum / count : 0.0;
  }

  return FrameQualityResult(
    rawFocus: rawFocus,
    lightMean: lightMean,
    thumbDx: thumbDx,
    thumbDy: thumbDy,
  );
}
