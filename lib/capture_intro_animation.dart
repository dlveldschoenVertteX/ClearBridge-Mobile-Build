import 'package:flutter/material.dart';

import 'package:clearbridge/clearbridge_colors.dart';

// Placeholder reconstruction — see cb_primary_button.dart header comment.
//
// Contract (relied on by MultiAngleCaptureController.onAnimationComplete):
// plays a ~4s intro sequence once, then fires onComplete. When loop is true
// it repeats indefinitely instead (decorative use, no completion signal).

class CaptureIntroAnimation extends StatefulWidget {
  const CaptureIntroAnimation({super.key, this.onComplete, this.loop = false});

  final VoidCallback? onComplete;
  final bool loop;

  @override
  State<CaptureIntroAnimation> createState() => _CaptureIntroAnimationState();
}

class _CaptureIntroAnimationState extends State<CaptureIntroAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void initState() {
    super.initState();
    if (widget.loop) {
      _controller.repeat();
    } else {
      _controller.forward();
      _controller.addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onComplete?.call();
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final scale = 0.85 + 0.15 * (0.5 - (t - 0.5).abs()) * 2;
        return Center(
          child: Opacity(
            opacity: 0.4 + 0.6 * (0.5 - (t - 0.5).abs()) * 2,
            child: Transform.scale(
              scale: scale,
              child: Icon(
                Icons.fingerprint,
                size: 96,
                color: ClearBridgeColors.cyan,
              ),
            ),
          ),
        );
      },
    );
  }
}
