import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'capture_colors.dart';
import 'capture_typography.dart';

/// The shared thumb-pad silhouette geometry, in normalized (0-1) preview
/// coordinates. This is the single source of truth for the shape the user
/// visually fills — the overlay draws it, and the controller maps it into the
/// captured still and writes it to Firestore as `guideRegion` so the backend
/// reconstructs the exact same superellipse as the (feathered) crop mask.
/// Keep [n] in sync with afis_print._superellipse_mask's default exponent.
///
/// Shape: tapered superellipse |(x-cx)/rx(t)|^n + |(y-cy)/ry|^n <= 1 where
/// rx(t) = rx*(1+taper*sin(t)). sin(t)>0 = bottom half (base, wider),
/// sin(t)<0 = top half (tip, narrower) — matches a real thumbprint silhouette.
/// Drawn tip-up: the pad's tip points toward the TOP of the portrait screen,
/// which is what lets the backend upright the print deterministically.
class PadSilhouetteShape {
  const PadSilhouetteShape({
    required this.cx,
    required this.cy,
    required this.rx,
    required this.ry,
    this.n = 2.5,
    this.taper = 0.0,
  });

  final double cx;
  final double cy;
  /// Nominal half-width (average across tip and base).
  final double rx;
  final double ry;
  final double n;
  /// Taper amount [0,1]: how much wider the base is vs the tip.
  /// At taper=0.20: base is rx*1.20 wide, tip is rx*0.80 wide.
  final double taper;

  /// Default pad shape — a thumbprint oval: fatter base, narrower rounded tip.
  /// Smaller than the prior symmetric superellipse based on CTO feedback.
  /// Bounding box kept in sync with FrontCaptureController._scoreRoi so
  /// framing, metering and the superprint crop all agree.
  static const PadSilhouetteShape defaultShape = PadSilhouetteShape(
    cx: 0.5,
    cy: 0.37,
    rx: 0.17,
    ry: 0.13,
    taper: 0.20,
  );

  /// Max half-width (at the base).
  double get rxMax => rx * (1.0 + taper);

  /// Normalized bounding rect (uses max width for conservative metering).
  Rect get boundingRect =>
      Rect.fromLTRB(cx - rxMax, cy - ry, cx + rxMax, cy + ry);

  /// Build the closed tapered-superellipse path in pixel space.
  /// rx varies with sin(t): wider at the bottom (base), narrower at the top (tip).
  Path toPath(Size size, {double inflate = 0.0}) {
    final pcx = cx * size.width;
    final pcy = cy * size.height;
    final b = ry * size.height + inflate;
    final e = 2.0 / n;
    final path = Path();
    const steps = 96;
    for (var i = 0; i <= steps; i++) {
      final t = (i / steps) * 2 * math.pi;
      final ct = math.cos(t);
      final st = math.sin(t);
      // Taper: rx scales with sin(t) — positive at bottom, negative at top.
      final a = (rx * (1.0 + taper * st)) * size.width + inflate;
      final x = pcx + a * _signPow(ct, e);
      final y = pcy + b * _signPow(st, e);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  static double _signPow(double v, double e) =>
      (v < 0 ? -1.0 : 1.0) * math.pow(v.abs(), e).toDouble();
}

/// A soft, ClearBridge-branded thumb-pad silhouette the user seats the pad in.
/// Unlike [CaptureReticleOverlay]'s oval, the shape is a rounded pad
/// superellipse and the scrim edge fades gradually (large-sigma blur) so it
/// reads as a guide, not a hard cut. Its region IS what the backend uses as
/// the crop mask (see [PadSilhouetteShape]).
class CapturePadSilhouetteOverlay extends StatelessWidget {
  const CapturePadSilhouetteOverlay({
    super.key,
    this.state = PadSilhouetteState.aligning,
    this.hint,
    this.shape = PadSilhouetteShape.defaultShape,
  });

  final PadSilhouetteState state;
  final String? hint;
  final PadSilhouetteShape shape;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _PadSilhouettePainter(state: state, hint: hint, shape: shape),
        child: const SizedBox.expand(),
      ),
    );
  }
}

enum PadSilhouetteState { aligning, locked, capturing }

class _PadSilhouettePainter extends CustomPainter {
  _PadSilhouettePainter({
    required this.state,
    required this.shape,
    this.hint,
  });

  final PadSilhouetteState state;
  final PadSilhouetteShape shape;
  final String? hint;

  Color get _accent {
    switch (state) {
      case PadSilhouetteState.locked:
        return CaptureColors.success;
      case PadSilhouetteState.capturing:
        return CaptureColors.gold;
      case PadSilhouetteState.aligning:
        return CaptureColors.cyan;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pad = shape.toPath(size);

    // Gradual scrim fade: instead of one hard scrim ring, layer several
    // increasingly-inflated, increasingly-transparent dark bands outside the
    // pad so the darkening ramps in softly toward the edge — "fades gradually
    // so it's not as sharp".
    const layers = 5;
    for (var i = layers; i >= 1; i--) {
      final inflate = i * 26.0;
      final alpha = (0.16 * (layers - i + 1)).clamp(0.0, 0.7).toDouble();
      final band = Path()
        ..addRect(Offset.zero & size)
        ..addPath(shape.toPath(size, inflate: inflate), Offset.zero)
        ..fillType = PathFillType.evenOdd;
      canvas.drawPath(
        band,
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, alpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
      );
    }
    // Solid inner scrim right at the boundary to fully exclude clutter.
    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addPath(pad, Offset.zero)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = const Color(0x66000000));

    final accent = _accent;

    // Main silhouette outline.
    canvas.drawPath(
      pad,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    // Soft glow.
    canvas.drawPath(
      pad,
      Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );

    // Tip marker: a small chevron at the top of the pad, cueing "tip up".
    final b = shape.boundingRect;
    final tipX = shape.cx * size.width;
    final tipY = b.top * size.height;
    final chevron = Paint()
      ..color = accent.withValues(alpha: 0.85)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const cw = 16.0;
    canvas.drawPath(
      Path()
        ..moveTo(tipX - cw, tipY - 4)
        ..lineTo(tipX, tipY - 4 - cw * 0.7)
        ..lineTo(tipX + cw, tipY - 4),
      chevron,
    );

    if (hint != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: hint,
          style: CaptureTypography.label.copyWith(
            color: accent,
            fontSize: 13,
            letterSpacing: 0.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width * 0.8);
      tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2, b.bottom * size.height + 16),
      );
    }
  }

  @override
  bool shouldRepaint(_PadSilhouettePainter old) =>
      old.state != state || old.hint != hint || old.shape != shape;
}
