import 'dart:typed_data';

/// Real per-shot exposure diagnostics read directly out of a JPEG's own EXIF
/// metadata -- the camera HAL's own record of what it actually did, not
/// anything the app requested or controlled.
///
/// Built as a cheap, zero-native-code Stage 1 for the locked-shutter-speed
/// investigation: this project's `camera` plugin (camera_android_camerax)
/// has no public API for manual SENSOR_EXPOSURE_TIME/SENSOR_SENSITIVITY
/// control -- confirmed against the plugin's own changelog -- so before
/// spending a native Camera2Interop lift on actually LOCKING shutter speed,
/// this reads what the existing auto-exposure burst already produced, so
/// real variance can be measured first.
class JpegExposureExif {
  const JpegExposureExif({this.exposureTimeUs, this.isoValue});

  /// Actual shutter time in microseconds, or null if the tag wasn't present
  /// / couldn't be parsed (some devices/HALs omit EXIF exposure tags).
  final int? exposureTimeUs;

  /// Actual sensor sensitivity (ISOSpeedRatings / PhotographicSensitivity),
  /// or null if unavailable.
  final int? isoValue;

  bool get hasData => exposureTimeUs != null || isoValue != null;

  /// e.g. "1/150" for diagnostics -- decimal seconds if 1s or slower, null
  /// if the exposure time itself is unknown.
  String? get exposureTimeReadable {
    final us = exposureTimeUs;
    if (us == null || us <= 0) return null;
    final seconds = us / 1e6;
    if (seconds >= 1.0) return '${seconds.toStringAsFixed(2)}s';
    return '1/${(1.0 / seconds).round()}';
  }
}

/// Parses ExposureTime (EXIF tag 0x829A) and ISOSpeedRatings /
/// PhotographicSensitivity (0x8827) out of a JPEG's EXIF APP1 segment.
///
/// Hand-rolled rather than a pub dependency: this is a small, bounded read
/// of exactly two tags out of one TIFF IFD, and avoids vetting a new
/// third-party package for something this contained (same "verify before
/// pulling in external code" discipline this project applies to every other
/// dependency). Never throws -- returns an empty result on any malformed,
/// truncated, or missing data, since this must never risk the real capture
/// flow for a diagnostic.
JpegExposureExif parseJpegExposureExif(Uint8List jpeg) {
  try {
    return _parse(jpeg);
  } catch (_) {
    return const JpegExposureExif();
  }
}

JpegExposureExif _parse(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) {
    return const JpegExposureExif();
  }
  var offset = 2;
  while (offset + 4 <= b.length) {
    if (b[offset] != 0xFF) break; // lost segment sync -- bail, not garbage-parse
    final marker = b[offset + 1];
    // Markers with no length/payload (RST0-7, TEM) -- skip past just the marker.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    if (marker == 0xD9) break; // EOI
    if (marker == 0xDA) break; // start of scan -- no more marker segments follow
    if (offset + 4 > b.length) break;
    final segLen = (b[offset + 2] << 8) | b[offset + 3];
    if (segLen < 2 || offset + 2 + segLen > b.length) break;
    if (marker == 0xE1) {
      final result = _parseApp1(b, offset + 4, offset + 2 + segLen);
      if (result.hasData) return result;
    }
    offset += 2 + segLen;
  }
  return const JpegExposureExif();
}

JpegExposureExif _parseApp1(Uint8List b, int start, int end) {
  // "Exif\0\0" header, then a TIFF header (byte-order marker + magic + IFD0 offset).
  if (end - start < 8 ||
      b[start] != 0x45 /* E */ ||
      b[start + 1] != 0x78 /* x */ ||
      b[start + 2] != 0x69 /* i */ ||
      b[start + 3] != 0x66 /* f */) {
    return const JpegExposureExif();
  }
  final tiffStart = start + 6;
  if (tiffStart + 8 > end) return const JpegExposureExif();

  final bool little;
  if (b[tiffStart] == 0x49 && b[tiffStart + 1] == 0x49) {
    little = true;
  } else if (b[tiffStart] == 0x4D && b[tiffStart + 1] == 0x4D) {
    little = false;
  } else {
    return const JpegExposureExif();
  }

  final reader = _TiffReader(b, little);

  final ifd0Abs = tiffStart + reader.u32(tiffStart + 4);
  final exifPtr = reader.findEntry(ifd0Abs, end, 0x8769);
  if (exifPtr == null || exifPtr.valueFieldOffset + 4 > end) {
    return const JpegExposureExif();
  }
  final exifIfdAbs = tiffStart + reader.u32(exifPtr.valueFieldOffset);

  int? exposureUs;
  final expEntry = reader.findEntry(exifIfdAbs, end, 0x829A);
  if (expEntry != null &&
      (expEntry.type == 5 || expEntry.type == 10) && // RATIONAL / SRATIONAL
      expEntry.valueFieldOffset + 4 <= end) {
    final dataAbs = tiffStart + reader.u32(expEntry.valueFieldOffset);
    if (dataAbs + 8 <= end) {
      final num = reader.u32(dataAbs);
      final den = reader.u32(dataAbs + 4);
      if (den > 0) exposureUs = ((num / den) * 1e6).round();
    }
  }

  int? iso;
  final isoEntry = reader.findEntry(exifIfdAbs, end, 0x8827);
  if (isoEntry != null) {
    final off = isoEntry.valueFieldOffset;
    if (isoEntry.type == 3 && off + 2 <= end) {
      iso = reader.u16(off); // SHORT, count 1 -> inline in the value field
    } else if (isoEntry.type == 4 && off + 4 <= end) {
      iso = reader.u32(off); // LONG, count 1 -> inline in the value field
    }
  }

  return JpegExposureExif(exposureTimeUs: exposureUs, isoValue: iso);
}

class _TiffReader {
  _TiffReader(this.bytes, this.littleEndian);
  final Uint8List bytes;
  final bool littleEndian;

  int u16(int o) => littleEndian
      ? (bytes[o] | (bytes[o + 1] << 8))
      : ((bytes[o] << 8) | bytes[o + 1]);

  int u32(int o) => littleEndian
      ? (bytes[o] |
          (bytes[o + 1] << 8) |
          (bytes[o + 2] << 16) |
          (bytes[o + 3] << 24))
      : ((bytes[o] << 24) |
          (bytes[o + 1] << 16) |
          (bytes[o + 2] << 8) |
          bytes[o + 3]);

  /// Finds [tag] in the IFD at absolute offset [ifdAbs] (bounded by
  /// [segEnd], the end of the APP1 segment) and returns its EXIF type code
  /// plus the absolute offset of its 4-byte value/offset field, or null if
  /// not found or the IFD runs past the segment.
  ({int type, int valueFieldOffset})? findEntry(int ifdAbs, int segEnd, int tag) {
    if (ifdAbs < 0 || ifdAbs + 2 > segEnd) return null;
    final count = u16(ifdAbs);
    var p = ifdAbs + 2;
    for (var i = 0; i < count; i++) {
      if (p + 12 > segEnd) return null;
      if (u16(p) == tag) return (type: u16(p + 2), valueFieldOffset: p + 8);
      p += 12;
    }
    return null;
  }
}
