import 'dart:math' as math;

import 'package:hand_landmarker/hand_landmarker.dart';

/// Derives the thumb's rotation angle from MediaPipe hand landmarks so the
/// capture sequence can be driven by how the user rotates their *thumb* in
/// front of the camera — not by tilting the *device* (the IMU is no longer the
/// capture axis, see [project_clearbridge_flutter_migration]).
///
/// Rotation convention (degrees, -180..+180):
///   front =    0   thumb pad facing the camera
///   left  =  -90
///   top   =  180   (equivalently -180)
///   right =  +90
///
/// The signal is the orientation of the palm-plane normal relative to the
/// camera. When the pad faces the camera the normal points roughly back at the
/// lens (angle ≈ 0); as the user rolls the thumb, the normal swings through
/// ±90 (sides) to 180 (back/top). The exact zero-point depends on hand pose and
/// **must be calibrated on the Samsung A16 test device** — the geometry here is
/// a sound, monotonic model, but the offset/sign may need a per-device trim.
class ThumbAngleService {
  ThumbAngleService._();
  static final ThumbAngleService instance = ThumbAngleService._();

  /// Target device-orientation angle for each capture position, in degrees.
  /// Values are relative to the zeroed front pose and depend on the active axis
  /// (see [axis] below). Measured on Samsung A16 via the Step 1 HUD.
  static const Map<String, double> targets = {
    'front': 0.0,    // magnitude ≈ 0 immediately after calibration zeros the ref
    'left': -20.0,   // pitch ≈ -20° (orbit phone left around thumb)
    'top': -20.0,    // roll ≈ -20° (tip top of phone forward → camera looks down)
    'right': 15.0,   // pitch ≈ +15° (orbit phone right around thumb)
  };

  /// Which DeviceOrientationService component drives each capture position.
  /// 'magnitude' = shortest-arc total rotation (0..180, always ≥ 0).
  /// 'pitch' / 'roll' = signed Euler components from the relative quaternion.
  static const Map<String, String> axis = {
    'front': 'magnitude',
    'left': 'pitch',
    'top': 'roll',
    'right': 'pitch',
  };

  /// Capture/state order: front → left → top → right.
  static const List<String> order = ['front', 'left', 'top', 'right'];

  /// Acceptance window around each target.
  static const double tolerance = 20.0;

  // MediaPipe Hands landmark indices.
  static const int _wrist = 0;
  static const int _thumbTip = 4;
  static const int _indexMcp = 5;
  static const int _pinkyMcp = 17;

  /// Returns the thumb rotation in degrees (-180..+180). Returns 0 when the
  /// landmark list is too short to define the hand plane.
  double extractThumbAngle(List<Landmark> landmarks) {
    if (landmarks.length <= _pinkyMcp) return 0.0;

    final wrist = landmarks[_wrist];
    final thumbTip = landmarks[_thumbTip];
    final indexMcp = landmarks[_indexMcp];
    final pinkyMcp = landmarks[_pinkyMcp];

    // Hand-plane basis vectors anchored at the wrist.
    final v1 = _vec(wrist, indexMcp);
    final v2 = _vec(wrist, pinkyMcp);

    // Palm-plane normal (out of the palm).
    final normal = _cross(v1, v2);

    // Project onto the plane perpendicular to the camera view axis (z toward
    // the lens). atan2(normal.x, -normal.z): pad-facing-camera → ≈0, rolling
    // the thumb sweeps through ±90 (sides) to ±180 (back/top).
    var degrees = _deg(math.atan2(normal[0], -normal[2]));

    // Disambiguate the roll direction using where the thumb tip sits relative
    // to the wrist in the image plane, so left/right stay consistent even when
    // the normal is near-parallel to the view axis.
    final thumbDx = thumbTip.x - wrist.x;
    if (degrees.abs() < 1e-3 && thumbDx.abs() > 1e-3) {
      degrees = thumbDx < 0 ? -0.0 : 0.0;
    }

    return _wrap180(degrees);
  }

  /// Name of the nearest target within [tolerance], else 'transition'.
  String getNearestAngleName(double degrees) {
    var bestName = 'transition';
    var bestDist = double.infinity;
    for (final entry in targets.entries) {
      final d = distanceToTarget(degrees, entry.value);
      if (d < bestDist) {
        bestDist = d;
        bestName = entry.key;
      }
    }
    return bestDist <= tolerance ? bestName : 'transition';
  }

  /// Shortest arc distance between two angles, always 0..180.
  double distanceToTarget(double currentDeg, double targetDeg) {
    var diff = (currentDeg - targetDeg).abs() % 360.0;
    if (diff > 180.0) diff = 360.0 - diff;
    return diff;
  }

  /// front=0, left=1, top=2, right=3. Returns -1 for unknown names.
  int getAngleIndex(String angleName) => order.indexOf(angleName);

  // ── helpers ────────────────────────────────────────────────────────────────

  List<double> _vec(Landmark a, Landmark b) =>
      [b.x - a.x, b.y - a.y, b.z - a.z];

  List<double> _cross(List<double> a, List<double> b) => [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
      ];

  double _deg(double radians) => radians * 180.0 / math.pi;

  double _wrap180(double degrees) {
    var d = degrees % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d < -180.0) d += 360.0;
    return d;
  }
}
