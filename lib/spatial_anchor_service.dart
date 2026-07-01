import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Visual state of a single spatial anchor circle.
enum AnchorState { pending, active, approaching, captured }

/// A projected anchor ready to paint: screen position, size, state, and whether
/// its leader line/label should be drawn.
class ScreenAnchor {
  final String angleKey; // 'front' | 'left' | 'top' | 'right'
  final String label; // 'PAD'  | 'OUTER' | 'NAIL' | 'INNER'
  final Offset screenPos;
  final double radius;
  final AnchorState state;
  final bool showLeaderLine;

  const ScreenAnchor({
    required this.angleKey,
    required this.label,
    required this.screenPos,
    required this.radius,
    required this.state,
    required this.showLeaderLine,
  });
}

class _P3 {
  final double x, y, z;
  const _P3(this.x, this.y, this.z);
}

/// Pure math/state layer for the spatial anchor overlay. Converts MediaPipe
/// hand landmarks into screen-space anchor circles locked to anatomical thumb
/// positions, accounting for the camera preview's BoxFit.cover transform.
///
/// No Flutter widgets — only geometry and per-anchor visual state.
class SpatialAnchorService {
  SpatialAnchorService._();

  static const _labels = {
    'front': 'PAD',
    'left': 'OUTER',
    'top': 'NAIL',
    'right': 'INNER',
  };

  // Order matches ThumbAngleService.order so currentAngleIndex / anglesComplete
  // map straight through from the controller state.
  static const _order = ['front', 'left', 'top', 'right'];

  /// Tracks which anchors have ever been the active target — drives the
  /// one-shot leader line. Cleared per session via [resetSession].
  static final Set<String> _everActivated = {};

  static void resetSession() => _everActivated.clear();

  static List<ScreenAnchor> compute({
    required List<dynamic> landmarks,
    required Size cameraImageSize,
    required Size previewWidgetSize,
    required Set<String> capturedAngles,
    required String currentAngleKey,
    required double distanceToTarget,
  }) {
    if (landmarks.length < 21) return const [];
    if (cameraImageSize.width <= 0 || cameraImageSize.height <= 0) {
      return const [];
    }

    // Landmark access can throw if the upstream type changes — fail silently.
    _P3 lm(int i) => _P3(
          (landmarks[i].x as num).toDouble(),
          (landmarks[i].y as num).toDouble(),
          (landmarks[i].z as num).toDouble(),
        );

    final Map<String, _P3> positions;
    try {
      _P3 sub(_P3 a, _P3 b) => _P3(a.x - b.x, a.y - b.y, a.z - b.z);
      _P3 norm(_P3 v) {
        final len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        return len < 1e-6
            ? const _P3(0, 0, 0)
            : _P3(v.x / len, v.y / len, v.z / len);
      }

      _P3 lerp(_P3 a, _P3 b, double t) =>
          _P3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
              a.z + (b.z - a.z) * t);

      final p1 = lm(1); // thumb CMC (base)
      final p3 = lm(3); // thumb IP joint  → PAD (front)
      final p4 = lm(4); // thumb tip       → NAIL (top)
      final p5 = lm(5); // index MCP  ┐ lateral direction
      final p17 = lm(17); // pinky MCP ┘

      final lat = norm(sub(p5, p17)); // across-the-hand axis
      final a70 = lerp(p1, p4, 0.70); // 70% up the thumb

      positions = {
        'front': p3,
        'left': _P3(
            a70.x + lat.x * 0.04, a70.y + lat.y * 0.04, a70.z + lat.z * 0.04),
        'top': p4,
        'right': _P3(
            a70.x - lat.x * 0.04, a70.y - lat.y * 0.04, a70.z - lat.z * 0.04),
      };
    } catch (_) {
      return const [];
    }

    // BoxFit.cover projection from normalized landmark space → preview pixels.
    Offset? project(_P3 pt) {
      final scaleX = previewWidgetSize.width / cameraImageSize.width;
      final scaleY = previewWidgetSize.height / cameraImageSize.height;
      final scale = math.max(scaleX, scaleY); // cover = fill, crop overflow
      final cropX =
          (cameraImageSize.width * scale - previewWidgetSize.width) / 2;
      final cropY =
          (cameraImageSize.height * scale - previewWidgetSize.height) / 2;
      final sx = pt.x * cameraImageSize.width * scale - cropX;
      final sy = pt.y * cameraImageSize.height * scale - cropY;
      if (sx < 0 ||
          sx > previewWidgetSize.width ||
          sy < 0 ||
          sy > previewWidgetSize.height) {
        return null; // off-screen
      }
      return Offset(sx, sy);
    }

    final result = <ScreenAnchor>[];
    for (final key in _order) {
      final p = positions[key]!;
      final pos = project(p);
      if (pos == null) continue; // skip off-screen anchors

      final z = p.z.clamp(0.0, 1.0);
      final radius = 10.0 + 10.0 * z; // 10px far → 20px near

      final AnchorState state;
      if (capturedAngles.contains(key)) {
        state = AnchorState.captured;
      } else if (key == currentAngleKey) {
        _everActivated.add(key);
        state = distanceToTarget <= 30.0
            ? AnchorState.approaching
            : AnchorState.active;
      } else {
        state = AnchorState.pending;
      }

      result.add(ScreenAnchor(
        angleKey: key,
        label: _labels[key]!,
        screenPos: pos,
        radius: radius,
        state: state,
        showLeaderLine: state == AnchorState.active &&
            _everActivated.contains(key) &&
            !capturedAngles.contains(key),
      ));
    }
    return result;
  }
}
