import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Circular capture-progress reticle: divided into [total] equal arc
/// segments, each filling cyan as a shot completes. Once every segment is
/// filled the whole ring switches to green and a checkmark bounces in at
/// the centre — the controller is responsible for pairing this with a
/// success chime + haptic pulse when [completed] reaches [total].
class CaptureBurstRing extends StatefulWidget {
  const CaptureBurstRing({
    super.key,
    required this.total,
    required this.completed,
    this.diameter = 208,
  });

  final int total;
  final int completed;
  final double diameter;

  @override
  State<CaptureBurstRing> createState() => _CaptureBurstRingState();
}

class _CaptureBurstRingState extends State<CaptureBurstRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _completeCtrl;
  late final Animation<double> _checkScale;

  bool get _isComplete => widget.total > 0 && widget.completed >= widget.total;

  @override
  void initState() {
    super.initState();
    _completeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _checkScale = CurvedAnimation(parent: _completeCtrl, curve: Curves.elasticOut);
    if (_isComplete) _completeCtrl.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant CaptureBurstRing old) {
    super.didUpdateWidget(old);
    final wasComplete = old.total > 0 && old.completed >= old.total;
    if (_isComplete && !wasComplete) {
      _completeCtrl.forward(from: 0);
    } else if (!_isComplete && wasComplete) {
      _completeCtrl.value = 0;
    }
  }

  @override
  void dispose() {
    _completeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.diameter,
      height: widget.diameter,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(widget.diameter),
            painter: _BurstRingPainter(
              total: widget.total,
              completed: widget.completed,
              isComplete: _isComplete,
            ),
          ),
          AnimatedBuilder(
            animation: _checkScale,
            builder: (_, __) {
              if (_checkScale.value <= 0) return const SizedBox.shrink();
              return Transform.scale(
                scale: _checkScale.value,
                child: Opacity(
                  opacity: _checkScale.value.clamp(0.0, 1.0),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: ClearBridgeColors.success,
                    size: 56,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BurstRingPainter extends CustomPainter {
  _BurstRingPainter({
    required this.total,
    required this.completed,
    required this.isComplete,
  });

  final int total;
  final int completed;
  final bool isComplete;

  static const double _strokeWidth = 7;
  static const double _gapDeg = 6; // gap between segments, degrees

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - _strokeWidth / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final segSweepDeg = (360.0 / total) - _gapDeg;
    final segSweepRad = segSweepDeg * math.pi / 180;
    final gapRad = _gapDeg * math.pi / 180;

    final trackPaint = Paint()
      ..color = ClearBridgeColors.silverDim.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = isComplete ? ClearBridgeColors.success : ClearBridgeColors.cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);

    var angle = -math.pi / 2 + gapRad / 2;
    for (int i = 0; i < total; i++) {
      final done = isComplete || i < completed;
      canvas.drawArc(rect, angle, segSweepRad, false, done ? fillPaint : trackPaint);
      angle += segSweepRad + gapRad;
    }
  }

  @override
  bool shouldRepaint(_BurstRingPainter old) =>
      old.completed != completed ||
      old.total != total ||
      old.isComplete != isComplete;
}
