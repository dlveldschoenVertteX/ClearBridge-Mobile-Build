import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as imglib;

/// A decoded still, converted to single-channel luma and rotated into
/// sensor (landscape) orientation -- ready for [encodeGrayscaleJpeg].
class DecodedStillLuma {
  final Uint8List luma;
  final int width;
  final int height;
  const DecodedStillLuma(this.luma, this.width, this.height);
}

/// Decodes a `CameraController.takePicture()` JPEG still down to a target
/// width and converts it to single-channel luma, rotated into the SAME
/// sensor (landscape) orientation the live preview stream's Y planes use --
/// so the backend sees a consistent frame set regardless of which capture
/// path a given frame came from.
///
/// Uses `dart:ui.instantiateImageCodec`'s `targetWidth` so the decode
/// happens directly at the reduced size rather than fully decoding a
/// native-ISP-resolution image (often 11-29MB) first -- this matters both
/// for speed and for peak memory on budget devices. This is a
/// Flutter-engine API, so unlike [encodeGrayscaleJpeg] it can only run on
/// the isolate that owns the Flutter engine -- it CANNOT be called inside a
/// `compute()` isolate.
///
/// The stream buffer is in sensor (landscape) orientation; takePicture
/// JPEGs decode EXIF-upright (portrait on a 90°/270° sensor). For those
/// sensors the upright image is rotated 90° CW back into buffer
/// orientation -- the inverse of ThumbLandmarkerService's buffer→upright
/// CCW rotation.
Future<DecodedStillLuma?> decodeStillJpegToLuma(
  Uint8List jpeg,
  int sensorOrientation, {
  int targetWidth = 2048,
}) async {
  final codec = await ui.instantiateImageCodec(jpeg, targetWidth: targetWidth);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    final rgba = byteData.buffer.asUint8List();
    final w = image.width;
    final h = image.height;

    // RGBA → luma (BT.601 integer approximation).
    final luma = Uint8List(w * h);
    for (var i = 0, p = 0; i < luma.length; i++, p += 4) {
      luma[i] = (77 * rgba[p] + 150 * rgba[p + 1] + 29 * rgba[p + 2]) >> 8;
    }

    if (sensorOrientation == 90 || sensorOrientation == 270) {
      // Rotate 90° CW: dst is h wide × w tall; dst(x,y) = src(y, h-1-x).
      final rotated = Uint8List(w * h);
      final dstW = h;
      final dstH = w;
      for (var y = 0; y < dstH; y++) {
        final srcCol = y;
        for (var x = 0; x < dstW; x++) {
          rotated[y * dstW + x] = luma[(h - 1 - x) * w + srcCol];
        }
      }
      return DecodedStillLuma(rotated, dstW, dstH);
    }
    return DecodedStillLuma(luma, w, h);
  } finally {
    image.dispose();
  }
}

/// Encodes a single-channel luma buffer as a grayscale JPEG. Pure Dart (the
/// `image` package) -- unlike [decodeStillJpegToLuma], safe to call inline
/// or inside a `compute()` isolate.
///
/// Real bug found + fixed 2026-07-25: constructing this via
/// `Image.fromBytes(numChannels: 1)` does NOT produce a true grayscale
/// JPEG. Confirmed against the actual published `image` v4.8.0 source
/// (pub.dev tarball): `PixelUint8.g`/`.b` return 0 for a numChannels==1
/// image instead of replicating the single channel (only `.r` returns the
/// real value), and `JpegEncoder._writeSOF0` always writes a 3-component
/// JPEG regardless of input channel count. So the encoder was computing
/// Y/Cb/Cr from (R=luma, G=0, B=0) per pixel instead of (R=G=B=luma) --
/// non-neutral, luma-correlated chroma, not a neutral-grayscale JPEG.
/// Measured on a real captured frame: 70% real contrast (std) loss and
/// ~3x brightness compression on decode -- not a cosmetic tint, a real
/// data-destroying bug that has been silently degrading every uploaded
/// grayscale frame (main burst AND secondary-camera) since this encode
/// path was introduced. Fix: manually replicate luma into all 3 channels
/// before handing off to the encoder, so the resulting Cb/Cr planes are
/// genuinely neutral regardless of this library's single-channel handling
/// -- verified against real capture data to exactly recover the original
/// mean/std (no residual loss beyond normal JPEG quantization).
Uint8List encodeGrayscaleJpeg(Uint8List gray, int width, int height, {int quality = 90}) {
  final rgb = Uint8List(gray.length * 3);
  for (var i = 0, p = 0; i < gray.length; i++, p += 3) {
    final v = gray[i];
    rgb[p] = v;
    rgb[p + 1] = v;
    rgb[p + 2] = v;
  }
  final image = imglib.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgb.buffer,
    numChannels: 3,
  );
  return Uint8List.fromList(imglib.encodeJpg(image, quality: quality));
}
