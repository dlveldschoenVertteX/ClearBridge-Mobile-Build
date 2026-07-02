import 'package:flutter/material.dart';

/// Full-bleed radial vignette painted over the camera preview: the centre
/// stays fully transparent (so the thumb + [HapticGuidanceCircle] read
/// clearly) while everything outside smoothly fades to a dark scrim. This
/// gives the user a visual cue to keep background clutter out of frame —
/// the same reason the thumb needs to be centred and fill the guide circle
/// is exactly what keeps backend segmentation from bleeding onto busy
/// backgrounds (see sfm_pipeline._segment_and_locate's centre-ellipse prior).
///
/// Ignores pointer events so it never intercepts the tap-to-focus gesture on
/// the camera layer beneath it.
class CaptureVignetteOverlay extends StatelessWidget {
  const CaptureVignetteOverlay({super.key, this.intensity = 1.0});

  /// 0.0 = fully invisible, 1.0 = full scrim strength. Lets callers fade the
  /// vignette in/out (e.g. dim it once the shot is locked and about to fire).
  final double intensity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: intensity.clamp(0.0, 1.0),
        duration: const Duration(milliseconds: 300),
        child: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 0.85,
              colors: [
                Colors.transparent,
                Colors.transparent,
                Color(0xCC000000),
              ],
              stops: [0.0, 0.30, 0.95],
            ),
          ),
        ),
      ),
    );
  }
}
