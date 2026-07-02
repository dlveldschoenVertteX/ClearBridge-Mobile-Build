import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Relative device orientation (current pose minus the zeroed reference),
/// expressed as Euler components in degrees plus the unsigned shortest-arc
/// rotation magnitude. All four are derived from the relative quaternion.
@immutable
class RelativeOrientation {
  final double yaw; // rotation about device Z, degrees (-180..180)
  final double pitch; // rotation about device Y, degrees (-90..90)
  final double roll; // rotation about device X, degrees (-180..180)
  final double magnitude; // total rotation from reference, degrees (0..180)

  const RelativeOrientation({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.magnitude,
  });

  static const zero =
      RelativeOrientation(yaw: 0, pitch: 0, roll: 0, magnitude: 0);
}

/// Streams the device's fused orientation quaternion from the Android
/// GAME_ROTATION_VECTOR sensor (registered in MainActivity.kt over the
/// `clearbridge/orientation` EventChannel) and exposes it relative to a
/// zeroed "front" reference.
///
/// The capture motion is a phone orbiting a static thumb, so the capture angle
/// is the device's own orientation — not the thumb's shape. This service is the
/// angle source; MediaPipe stays responsible for thumb framing/sharpness.
class DeviceOrientationService {
  static const _channel = EventChannel('clearbridge/orientation');

  StreamSubscription<dynamic>? _sub;

  // Latest absolute orientation quaternion (x, y, z, w). Identity until the
  // first sensor event arrives.
  double _x = 0, _y = 0, _z = 0, _w = 1;

  // Zeroed reference quaternion captured at the front pose.
  double _rx = 0, _ry = 0, _rz = 0, _rw = 1;

  bool _hasSample = false;
  bool get hasSample => _hasSample;

  /// Begins listening to the sensor stream. No-op on non-Android platforms or
  /// if the sensor is unavailable (the stream simply never emits).
  void start() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _sub ??= _channel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is List && event.length >= 4) {
          _x = (event[0] as num).toDouble();
          _y = (event[1] as num).toDouble();
          _z = (event[2] as num).toDouble();
          _w = (event[3] as num).toDouble();
          _hasSample = true;
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  /// Zeroes the reference to the current pose. Call at the front calibration so
  /// every subsequent reading is measured relative to the user's natural hold.
  void captureReference() {
    _rx = _x;
    _ry = _y;
    _rz = _z;
    _rw = _w;
  }

  /// Current orientation relative to the captured reference.
  RelativeOrientation relativeOrientation() {
    // q_rel = q_ref^-1 * q_cur. For a unit quaternion the inverse is the
    // conjugate (-x, -y, -z, w).
    final ix = -_rx, iy = -_ry, iz = -_rz, iw = _rw;
    // Hamilton product (i * cur).
    final w = iw * _w - ix * _x - iy * _y - iz * _z;
    final x = iw * _x + ix * _w + iy * _z - iz * _y;
    final y = iw * _y - ix * _z + iy * _w + iz * _x;
    final z = iw * _z + ix * _y - iy * _x + iz * _w;

    const rad2deg = 180.0 / math.pi;

    // Roll (about X).
    final sinrCosp = 2 * (w * x + y * z);
    final cosrCosp = 1 - 2 * (x * x + y * y);
    final roll = math.atan2(sinrCosp, cosrCosp) * rad2deg;

    // Pitch (about Y), clamped at the gimbal poles.
    final sinp = 2 * (w * y - z * x);
    final pitch = (sinp.abs() >= 1
            ? (sinp.isNegative ? -math.pi / 2 : math.pi / 2)
            : math.asin(sinp)) *
        rad2deg;

    // Yaw (about Z).
    final sinyCosp = 2 * (w * z + x * y);
    final cosyCosp = 1 - 2 * (y * y + z * z);
    final yaw = math.atan2(sinyCosp, cosyCosp) * rad2deg;

    // Unsigned shortest-arc magnitude.
    final magnitude = 2 * math.acos(w.abs().clamp(0.0, 1.0)) * rad2deg;

    return RelativeOrientation(
      yaw: yaw,
      pitch: pitch,
      roll: roll,
      magnitude: magnitude,
    );
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
