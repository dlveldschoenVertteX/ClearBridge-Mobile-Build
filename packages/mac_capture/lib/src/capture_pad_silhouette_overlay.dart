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
    this.coreTargetDyFrac = 0.22,
    this.coreTargetDxFrac = -0.20,
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

  /// Where inside the pad the user should aim the DENSE RIDGE CORE (the whorl /
  /// loop swirl), as a fraction of [ry] from the guide centre (positive = down/
  /// toward the base, negative = up/toward the tip of the portrait screen).
  ///
  /// Re-measured 2026-07-17 against a real capture from this device-test round
  /// (`9b0fb988`): a Poincaré-index singularity scan (same orientation-field
  /// math as `afis_print._orientation_field`, run on the real raw burst frame,
  /// rotated upright via the same transform as `_upright_from_tip`) located the
  /// true ridge core at roughly +0.22*ry below the OLD guide centre — the
  /// previous value (-0.45, toward the tip) had it backwards; the real core
  /// sits toward the BASE, not the tip, on this real thumb. This corrects the
  /// original 2026-07-16 estimate, which was never measured against a real
  /// image.
  ///
  /// UI-ONLY: this does NOT change [boundingRect]/the Firestore `guideRegion`/
  /// the backend crop mask, so it cannot regress a previously well-placed
  /// capture — it only nudges user placement. Re-tune on-device if the core
  /// still lands outside the guide on further real captures.
  final double coreTargetDyFrac;

  /// Same idea as [coreTargetDyFrac] but horizontal, as a fraction of [rx]
  /// (positive = toward the right of the portrait screen).
  ///
  /// A pixel-level measurement on a real capture (Poincare-index singularity
  /// scan) found the core to the RIGHT, matching an earlier, independently-
  /// derived finding from a different real capture (CLAUDE.md, 2026-07-16:
  /// "the whorl core sits to the right") -- but the CTO's own explanation
  /// (2026-07-17) resolves why both of those still point the WRONG way to
  /// guide from: this capture flow has the user twist the thumb behind the
  /// phone to present the pad to the rear lens, which physically mirrors the
  /// print relative to a direct scan or ink impression (where the finger
  /// presses straight down, un-twisted). Both measurements above were taken
  /// from the raw captured (already-mirrored) image, so "right" in that
  /// domain is genuinely "left" relative to how the CTO's own capture
  /// pipeline actually renders it live -- confirmed directly by the CTO, who
  /// sees the real core on the LEFT in this pipeline. The reticle guides
  /// live, in-pipeline placement, so it needs the CTO's stated (mirrored-
  /// domain) direction, not the raw-image measurement.
  final double coreTargetDxFrac;

  /// Default pad shape — a thumbprint oval: fatter base, narrower rounded tip.
  /// Bounding box kept in sync with FrontCaptureController._scoreRoi so
  /// framing, metering and the superprint crop all agree.
  ///
  /// Enlarged twice 2026-07-15 per CTO request: the guide opening was
  /// constraining how close the user could bring the thumb -- a closer
  /// capture appears larger on screen and no longer fit inside a smaller
  /// opening. This directly targets the dominant real nfiq2Score lever
  /// found this session (native ridge wavelength / working distance -- see
  /// CLAUDE.md), so the guide needs to accommodate a bigger on-screen
  /// thumb, not just a fixed framing. Now that the BoxFit.cover guideRegion
  /// mapping bug is fixed, the on-screen guide and the backend mask are
  /// guaranteed to match, so this is a deliberate size choice, not a
  /// mask-position bug -- re-test visually if creases start showing up in
  /// superprints again, since a bigger opening extends closer to the DIP
  /// crease than the original top-half-only shrink.
  /// History: 0.17/0.13 -> 0.21/0.17 (first bump) -> 0.23/0.19 (the size the
  /// only NFIQ2=72 capture `c2104d45` was taken at) -> 0.2415/0.1995 (+5%,
  /// 2026-07-17, to stop the mask clipping when held "as close as possible")
  /// -> REVERTED back to 0.23/0.19 (2026-07-18). The +5% enlargement was a
  /// mistake: real Firestore data across ~10 captures shows a bigger on-screen
  /// guide makes the user hold the thumb CLOSER to fill it, which raises the
  /// native ridge wavelength (closer = more magnified = more px/ridge) into
  /// the >=17px zone that scores catastrophic NFIQ2 -- every capture at wl>=17
  /// scored 5-9, while wl 9-14 scored 72. Holding farther (smaller guide)
  /// fixes BOTH the original clipping complaint (a smaller pad can't clip) AND
  /// the wavelength. CTO independently asked to revert to the 72-capture size.
  /// `guideRegion` is written verbatim from this shape and used directly as
  /// the backend AFIS mask, so this single client-side change is sufficient.
  static const PadSilhouetteShape defaultShape = PadSilhouetteShape(
    cx: 0.5,
    cy: 0.37,
    rx: 0.23,
    ry: 0.19,
    taper: 0.20,
  );

  /// Max half-width (at the base).
  double get rxMax => rx * (1.0 + taper);

  /// Normalized (0-1 preview coords) point where the ridge core should sit.
  Offset get coreTarget =>
      Offset(cx + coreTargetDxFrac * rx, cy + coreTargetDyFrac * ry);

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

    // Core-target marker: a small concentric ring at the spot where the user
    // should seat the DENSE RIDGE CORE (the print's swirl), toward the tip
    // rather than the fleshy pad centre. Cues the user to place the ridge-dense
    // region inside the guide so it lands in the capture mask (see
    // PadSilhouetteShape.coreTargetDyFrac). Hidden during the capturing state
    // to avoid clutter while the burst fires. UI-only — no mask impact.
    if (state != PadSilhouetteState.capturing) {
      // Fixed gold (not `accent`, which shifts cyan/green/gold with capture
      // state) so this reads as a DISTINCT marker from the guide outline
      // itself, not just a differently-coloured echo of it -- a real device
      // test found the original thin ring (10/18px radius, 1.5-2px stroke)
      // effectively invisible against a live, textured camera feed. Redrawn
      // as a bold reticle: a soft glow halo + a crisp crosshair-in-a-ring,
      // both noticeably larger and thicker.
      const target = CaptureColors.gold;
      final core = shape.coreTarget;
      final c = Offset(core.dx * size.width, core.dy * size.height);
      // Soft halo so it draws the eye even against busy skin texture.
      canvas.drawCircle(
        c,
        26,
        Paint()
          ..color = target.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      // Crisp outer + inner rings.
      canvas.drawCircle(
        c,
        26,
        Paint()
          ..color = target.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      canvas.drawCircle(
        c,
        14,
        Paint()
          ..color = target
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5,
      );
      // Crosshair ticks (N/E/S/W) -- the classic "aim here" reticle shape,
      // reads instantly even at a glance.
      final tick = Paint()
        ..color = target
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      for (final d in [
        const Offset(0, -1), const Offset(0, 1),
        const Offset(-1, 0), const Offset(1, 0),
      ]) {
        canvas.drawLine(
          c + Offset(d.dx * 18, d.dy * 18),
          c + Offset(d.dx * 30, d.dy * 30),
          tick,
        );
      }
      // Centre dot.
      canvas.drawCircle(c, 3.0, Paint()..color = target);
    }

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
