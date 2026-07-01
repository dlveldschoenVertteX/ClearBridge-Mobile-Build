import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';

/// Static fallback guide shown when no hand landmarks are detected.
/// Gives the user a clear target before TFLite picks up their thumb.
/// Disappears the instant landmarks arrive (no transition animation needed —
/// the SpatialAnchorOverlay replaces it immediately).
class CaptureReticleWidget extends StatefulWidget {
  const CaptureReticleWidget({super.key});

  @override
  State<CaptureReticleWidget> createState() => _CaptureReticleWidgetState();
}

class _CaptureReticleWidgetState extends State<CaptureReticleWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.92, end: 1.06).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
    _opacity = Tween<double>(begin: 0.55, end: 0.90).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => Opacity(
              opacity: _opacity.value,
              child: Transform.scale(
                scale: _scale.value,
                child: CustomPaint(
                  size: const Size(160, 160),
                  painter: _ReticlePainter(pulse: _pulse.value),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: _opacity,
            builder: (_, __) => Opacity(
              opacity: _opacity.value,
              child: Text(
                'Place thumb pad here',
                style: ClearBridgeTypography.caption.copyWith(
                  color: ClearBridgeColors.cyan,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  const _ReticlePainter({required this.pulse});
  final double pulse; // 0.0 → 1.0 from AnimationController

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = size.width / 2 - 6;

    // Outer dashed ring
    final dashPaint = Paint()
      ..color = ClearBridgeColors.cyan.withOpacity(0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    _drawDashedCircle(canvas, Offset(cx, cy), radius, dashPaint, dashCount: 20);

    // Inner solid ring (thinner)
    final innerPaint = Paint()
      ..color = ClearBridgeColors.cyan.withOpacity(0.30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(Offset(cx, cy), radius * 0.72, innerPaint);

    // Center crosshair
    final crossPaint = Paint()
      ..color = ClearBridgeColors.cyan.withOpacity(0.50)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    const arm = 10.0;
    canvas.drawLine(Offset(cx - arm, cy), Offset(cx + arm, cy), crossPaint);
    canvas.drawLine(Offset(cx, cy - arm), Offset(cx, cy + arm), crossPaint);

    // Pulsing glow dot at center
    final glowPaint = Paint()
      ..color = ClearBridgeColors.cyan.withOpacity(0.15 + 0.20 * pulse)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 6 + 4 * pulse, glowPaint);
  }

  void _drawDashedCircle(
    Canvas canvas,
    Offset center,
    double radius,
    Paint paint, {
    required int dashCount,
  }) {
    final dashAngle = 2 * math.pi / dashCount;
    final gapFraction = 0.35;
    for (int i = 0; i < dashCount; i++) {
      final startAngle = i * dashAngle;
      final sweepAngle = dashAngle * (1 - gapFraction);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ReticlePainter old) => old.pulse != pulse;
}
