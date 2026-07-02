import 'dart:async';

import 'package:flutter/material.dart';

import 'capture_colors.dart';
import 'capture_typography.dart';

enum _DistanceZone { tooClose, perfect, approaching, tooFar }

/// Shows thumb-to-lens distance feedback below the haptic guidance circle.
/// [thumbCoverageRatio] is the normalized hand height in frame (0–1).
///
/// Thresholds are aligned with CaptureAxisController coverage gate (0.40–0.75):
///   > 0.80 → too close (warn before the 0.75 gate clips quality)
///   0.45–0.80 → perfect
///   0.30–0.45 → approaching (progressive "getting closer" sub-zone)
///   < 0.30 → too far ("move much closer")
///
/// "Perfect distance" confirmation auto-hides after 1500ms.
class DistanceGuidanceWidget extends StatefulWidget {
  const DistanceGuidanceWidget({super.key, required this.thumbCoverageRatio});

  final double thumbCoverageRatio;

  @override
  State<DistanceGuidanceWidget> createState() => _DistanceGuidanceWidgetState();
}

class _DistanceGuidanceWidgetState extends State<DistanceGuidanceWidget> {
  Timer? _hideTimer;
  bool _perfectVisible = false;

  _DistanceZone _zone(double ratio) {
    if (ratio > 0.80) return _DistanceZone.tooClose;
    if (ratio >= 0.45) return _DistanceZone.perfect;
    if (ratio >= 0.30) return _DistanceZone.approaching;
    return _DistanceZone.tooFar;
  }

  @override
  void initState() {
    super.initState();
    if (_zone(widget.thumbCoverageRatio) == _DistanceZone.perfect) {
      _perfectVisible = true;
      _scheduleHide();
    }
  }

  @override
  void didUpdateWidget(covariant DistanceGuidanceWidget old) {
    super.didUpdateWidget(old);
    final prev = _zone(old.thumbCoverageRatio);
    final now = _zone(widget.thumbCoverageRatio);
    if (now == _DistanceZone.perfect && prev != _DistanceZone.perfect) {
      _hideTimer?.cancel();
      setState(() => _perfectVisible = true);
      _scheduleHide();
    } else if (now != _DistanceZone.perfect) {
      _hideTimer?.cancel();
    }
  }

  void _scheduleHide() {
    _hideTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _perfectVisible = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zone = _zone(widget.thumbCoverageRatio);

    if (zone == _DistanceZone.perfect) {
      return AnimatedOpacity(
        opacity: _perfectVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: _pill(
          icon: Icons.check_circle_outline,
          text: 'Perfect distance',
          color: CaptureColors.success,
        ),
      );
    }

    if (zone == _DistanceZone.tooClose) {
      return _pill(
        icon: Icons.arrow_upward,
        text: 'Move further back',
        color: CaptureColors.warning,
      );
    }

    if (zone == _DistanceZone.approaching) {
      return _pill(
        icon: Icons.arrow_downward,
        text: 'Getting closer — keep going',
        color: CaptureColors.cyan,
      );
    }

    // tooFar
    return _pill(
      icon: Icons.arrow_downward,
      text: 'Move much closer to camera',
      color: CaptureColors.warning,
    );
  }

  Widget _pill({required IconData icon, required String text, required Color color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 4),
        Text(
          text,
          style: CaptureTypography.label.copyWith(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
