import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';
import 'package:clearbridge/spatial_anchor_service.dart';

/// Additive overlay that paints the spatial anchor circles on top of the camera
/// preview. Owns the pulse / ripple / leader-fade animations; all geometry comes
/// pre-computed in [anchors] from [SpatialAnchorService]. Touches no capture
/// logic.
class SpatialAnchorOverlay extends StatefulWidget {
  const SpatialAnchorOverlay({
    super.key,
    required this.anchors,
    required this.previewSize,
  });

  final List<ScreenAnchor> anchors;
  final Size previewSize;

  @override
  State<SpatialAnchorOverlay> createState() => _SpatialAnchorOverlayState();
}

class _SpatialAnchorOverlayState extends State<SpatialAnchorOverlay>
    with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  final Map<String, AnimationController> _rippleCtrs = {};
  final Map<String, AnimationController> _labelFadeCtrls = {};
  final Set<String> _previouslyCaptured = {};
  // Pre-laid-out painters keyed by angleKey — reused every paint frame so
  // TextPainter.layout() is not called at 60fps inside the CustomPainter.
  final Map<String, TextPainter> _labelPainters = {};

  static const _slowPulse = Duration(milliseconds: 1000);
  static const _fastPulse = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: _slowPulse)
      ..repeat();
    _syncLabelPainters();
  }

  void _syncLabelPainters() {
    final current = widget.anchors.map((a) => a.angleKey).toSet();
    _labelPainters.removeWhere((k, tp) {
      if (!current.contains(k)) {
        tp.dispose();
        return true;
      }
      return false;
    });
    for (final a in widget.anchors) {
      if (!_labelPainters.containsKey(a.angleKey)) {
        _labelPainters[a.angleKey] = TextPainter(
          text: TextSpan(
            text: a.label,
            style: const TextStyle(
              fontFamily: 'Manrope',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: ClearBridgeColors.silverBright,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
      }
    }
  }

  @override
  void didUpdateWidget(SpatialAnchorOverlay old) {
    super.didUpdateWidget(old);
    _syncLabelPainters();

    // Ripple burst on each new capture.
    for (final a in widget.anchors) {
      if (a.state == AnchorState.captured &&
          !_previouslyCaptured.contains(a.angleKey)) {
        _previouslyCaptured.add(a.angleKey);
        final c = AnimationController(
            vsync: this, duration: const Duration(milliseconds: 400));
        _rippleCtrs[a.angleKey] = c;
        c.forward().then((_) {
          // If unmounted, dispose() already cleaned up every ripple controller
          // (including this one) — disposing again would throw.
          if (!mounted) return;
          setState(() {
            _rippleCtrs.remove(a.angleKey)?.dispose();
          });
        });
      }
    }

    // One-shot leader-line fade when an anchor first becomes the target.
    for (final a in widget.anchors) {
      if ((a.state == AnchorState.active ||
              a.state == AnchorState.approaching) &&
          !_labelFadeCtrls.containsKey(a.angleKey)) {
        _labelFadeCtrls[a.angleKey] = AnimationController(
            vsync: this, duration: const Duration(milliseconds: 2000))
          ..forward();
      }
    }

    // Pulse speed: fast when any anchor is within 30° (approaching).
    final hasApproaching =
        widget.anchors.any((a) => a.state == AnchorState.approaching);
    final target = hasApproaching ? _fastPulse : _slowPulse;
    if (_pulseCtrl.duration != target) {
      _pulseCtrl.duration = target;
      _pulseCtrl.repeat();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    for (final c in _rippleCtrs.values) {
      c.dispose();
    }
    for (final c in _labelFadeCtrls.values) {
      c.dispose();
    }
    for (final tp in _labelPainters.values) {
      tp.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // _pulseCtrl repeats continuously, so this rebuilds every frame and samples
    // the live ripple/label controller values without merging listenables.
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) => CustomPaint(
        size: widget.previewSize,
        painter: _AnchorPainter(
          anchors: widget.anchors,
          pulseProgress: _pulseCtrl.value,
          rippleProgress: {
            for (final e in _rippleCtrs.entries) e.key: e.value.value,
          },
          labelOpacity: {
            for (final e in _labelFadeCtrls.entries)
              e.key: (1.0 - e.value.value).clamp(0.0, 1.0),
          },
          labelPainters: _labelPainters,
        ),
      ),
    );
  }
}

class _AnchorPainter extends CustomPainter {
  final List<ScreenAnchor> anchors;
  final double pulseProgress;
  final Map<String, double> rippleProgress;
  final Map<String, double> labelOpacity;
  final Map<String, TextPainter> labelPainters;

  const _AnchorPainter({
    required this.anchors,
    required this.pulseProgress,
    required this.rippleProgress,
    required this.labelOpacity,
    required this.labelPainters,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in anchors) {
      _draw(canvas, a, size);
    }
  }

  void _draw(Canvas canvas, ScreenAnchor a, Size size) {
    final pos = a.screenPos;
    final r = a.radius;
    final pulse = (math.sin(pulseProgress * 2 * math.pi) + 1) / 2; // 0..1

    switch (a.state) {
      case AnchorState.pending:
        canvas.drawCircle(
          pos,
          r,
          Paint()
            ..color = ClearBridgeColors.cyan.withValues(alpha: 0.28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        canvas.drawCircle(
          pos,
          2.0,
          Paint()..color = ClearBridgeColors.cyan.withValues(alpha: 0.28),
        );

      case AnchorState.active:
      case AnchorState.approaching:
        // Outer glow ring (expands + brightens with the pulse).
        canvas.drawCircle(
          pos,
          r + 6.0 * pulse,
          Paint()
            ..color =
                ClearBridgeColors.gold.withValues(alpha: 0.25 + 0.35 * pulse)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
        // Solid ring.
        canvas.drawCircle(
          pos,
          r,
          Paint()
            ..color = ClearBridgeColors.gold
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
        // Center dot.
        canvas.drawCircle(
          pos,
          3.0,
          Paint()..color = ClearBridgeColors.gold,
        );
        if (a.showLeaderLine) {
          _drawLeaderLine(canvas, a, labelOpacity[a.angleKey] ?? 1.0, size, labelPainters);
        }

      case AnchorState.captured:
        // Ripple burst (while its controller is alive).
        final rp = rippleProgress[a.angleKey];
        if (rp != null) {
          canvas.drawCircle(
            pos,
            r + 24.0 * rp,
            Paint()
              ..color =
                  ClearBridgeColors.success.withValues(alpha: 0.80 * (1.0 - rp))
              ..style = PaintingStyle.fill,
          );
        }
        // Solid fill + ring.
        canvas.drawCircle(
          pos,
          r,
          Paint()
            ..color = ClearBridgeColors.success.withValues(alpha: 0.85)
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          pos,
          r,
          Paint()
            ..color = ClearBridgeColors.success
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        _drawCheckmark(canvas, pos, r * 0.45);
    }
  }

  void _drawLeaderLine(
      Canvas canvas, ScreenAnchor a, double opacity, Size size,
      Map<String, TextPainter> labelPainters) {
    if (opacity <= 0.01) return;

    // Radial direction away from an approximate thumb center.
    final thumbCenter = Offset(size.width / 2, size.height * 0.55);
    final raw = a.screenPos - thumbCenter;
    final len = raw.distance;
    if (len < 1) return;
    final dir = raw / len;

    final lineStart = a.screenPos + dir * (a.radius + 4);
    final lineEnd = lineStart + dir * 44;

    final tp = labelPainters[a.angleKey];
    final labelPos = tp != null
        ? lineEnd + Offset(dir.dx >= 0 ? 4 : -tp.width - 4, -tp.height / 2)
        : lineEnd;

    // Painters are pre-laid-out with full silver; apply opacity via saveLayer
    // only during the fade (avoids TextPainter.layout() at 60fps).
    if (opacity >= 0.99) {
      canvas.drawLine(lineStart, lineEnd,
          Paint()..color = ClearBridgeColors.gold.withValues(alpha: 0.7)..strokeWidth = 1.0);
      tp?.paint(canvas, labelPos);
    } else {
      canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: opacity));
      canvas.drawLine(lineStart, lineEnd,
          Paint()..color = ClearBridgeColors.gold.withValues(alpha: 0.7)..strokeWidth = 1.0);
      tp?.paint(canvas, labelPos);
      canvas.restore();
    }
  }

  void _drawCheckmark(Canvas canvas, Offset center, double s) {
    final path = Path()
      ..moveTo(center.dx - s * 0.5, center.dy)
      ..lineTo(center.dx - s * 0.1, center.dy + s * 0.45)
      ..lineTo(center.dx + s * 0.55, center.dy - s * 0.45);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_AnchorPainter old) => true; // driven by the pulse ticker
}
