import 'package:flutter/material.dart';

import 'capture_colors.dart';
import 'capture_typography.dart';

/// A "spotlight" capture reticle: a portrait thumb-pad oval kept bright while
/// everything outside it is darkened to a scrim, plus a branded border ring
/// that reflects capture state. Unlike the soft [CaptureVignetteOverlay] this
/// draws an explicit target the user fills with the thumb pad — and its oval
/// is aligned 1:1 with the controller's scoring/focus ROI, so what the user
/// frames is exactly what gets focused, exposed, masked and scored. Landing
/// the pad consistently in this window is the single biggest capture-side
/// lever on the face-on frame the superprint is built from.
///
/// The oval bounding box is [reticleRect] in normalized (0–1) preview
/// coordinates; keep it in sync with OscillatingCaptureController._scoreRoi.
class CaptureReticleOverlay extends StatelessWidget {
  const CaptureReticleOverlay({
    super.key,
    this.state = ReticleState.aligning,
    this.hint,
  });

  final ReticleState state;

  /// Optional short instruction drawn under the oval (e.g. "Fill the oval").
  final String? hint;

  /// Normalized oval bounds — MUST match the controller's _scoreRoi.
  static const Rect reticleRect = Rect.fromLTRB(0.28, 0.22, 0.72, 0.78);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _ReticlePainter(state: state, hint: hint),
        child: const SizedBox.expand(),
      ),
    );
  }
}

enum ReticleState { aligning, locked, capturing }

class _ReticlePainter extends CustomPainter {
  _ReticlePainter({required this.state, this.hint});

  final ReticleState state;
  final String? hint;

  Color get _accent {
    switch (state) {
      case ReticleState.locked:
        return CaptureColors.success;
      case ReticleState.capturing:
        return CaptureColors.gold;
      case ReticleState.aligning:
        return CaptureColors.cyan;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = CaptureReticleOverlay.reticleRect;
    final oval = Rect.fromLTRB(
      r.left * size.width,
      r.top * size.height,
      r.right * size.width,
      r.bottom * size.height,
    );

    // Spotlight scrim: darken everything OUTSIDE the oval so the user places
    // the pad precisely in it (and background clutter is visually excluded,
    // which is what keeps the U-Net/segmentation from bleeding onto it).
    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addOval(oval.inflate(2))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = const Color(0xB3000000)); // ~70%

    // Feathered inner ring so the oval edge isn't a hard cut.
    canvas.drawOval(
      oval.inflate(6),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    final accent = _accent;

    // Main reticle ring.
    canvas.drawOval(
      oval,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    // Soft glow.
    canvas.drawOval(
      oval,
      Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // Corner ticks (biometric framing feel) at the oval's bounding box.
    final tick = Paint()
      ..color = accent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const t = 22.0;
    void corner(Offset c, double sx, double sy) {
      canvas.drawLine(c, c + Offset(sx * t, 0), tick);
      canvas.drawLine(c, c + Offset(0, sy * t), tick);
    }

    corner(oval.topLeft, 1, 1);
    corner(oval.topRight, -1, 1);
    corner(oval.bottomLeft, 1, -1);
    corner(oval.bottomRight, -1, -1);

    // Centre crosshair — the exact focus/exposure point.
    final cx = oval.center;
    final cross = Paint()
      ..color = accent.withValues(alpha: 0.7)
      ..strokeWidth = 2;
    canvas.drawLine(cx + const Offset(-10, 0), cx + const Offset(10, 0), cross);
    canvas.drawLine(cx + const Offset(0, -10), cx + const Offset(0, 10), cross);

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
        Offset((size.width - tp.width) / 2, oval.bottom + 14),
      );
    }
  }

  @override
  bool shouldRepaint(_ReticlePainter old) =>
      old.state != state || old.hint != hint;
}
