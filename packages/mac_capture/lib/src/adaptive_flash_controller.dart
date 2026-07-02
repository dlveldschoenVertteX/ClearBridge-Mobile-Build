import 'package:camera/camera.dart';

/// Controls the rear torch during capture with ambient-aware gating.
///
/// Three automatic modes based on calibration brightness:
///
///   Pitch dark (< 25 luma)
///     Torch fires during calibration as soon as darkness is detected so
///     MediaPipe can locate the thumb. After calibration the torch stays on
///     continuously — deactivate() is a no-op. Both the "ambient" and flash
///     burst windows are torch-lit; the backend selects the sharpest frame
///     from the combined set.
///
///   Normal (25–184 luma)
///     Torch off during calibration. Fires only around each burst window
///     (activate → burst → deactivate). Server-side Mertens fusion combines
///     the ambient and torch-lit frames.
///
///   Bright (≥ 185 luma)
///     Torch skipped entirely (isNeeded = false). At high ambient the torch
///     at 10 cm creates a competing light source that degrades rather than
///     enhances ridge contrast. Single ambient burst per angle.
class AdaptiveFlashController {
  AdaptiveFlashController(this.cameraController);

  final CameraController cameraController;

  double _ambientBrightness = 128.0;
  bool _isOn = false;
  bool _isPitchDark = false;
  bool _isBright = false;

  static const double _pitchDarkThreshold = 25.0;
  static const double _brightThreshold = 185.0;

  /// Called once at calibration end with the measured ambient luma.
  /// Sets the session mode and (for pitch dark) maintains the torch that was
  /// already activated during calibration.
  Future<void> calibrate(double ambientBrightness) async {
    _ambientBrightness = ambientBrightness;
    _isPitchDark = ambientBrightness < _pitchDarkThreshold;
    _isBright = ambientBrightness >= _brightThreshold;
    if (_isPitchDark) {
      await _setTorch(true); // torch was already fired during calib — maintain
    } else {
      await _setTorch(false);
    }
  }

  /// Turns the torch on for a burst window.
  Future<void> activate() => _setTorch(true);

  /// Turns the torch off after a burst window.
  /// No-op in pitch dark mode — torch stays on for the whole session.
  Future<void> deactivate() async {
    if (_isPitchDark) return;
    await _setTorch(false);
  }

  Future<void> _setTorch(bool on) async {
    _isOn = on;
    try {
      await cameraController.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
  }

  /// True when ambient < 80 — torch is the primary or sole light source.
  bool get isNightMode => _ambientBrightness < 80.0;

  /// Always false — flash gating is fully automatic; no manual toggle offered.
  bool get isMarginal => false;

  /// False only in bright mode (≥ 185 luma) where torch degrades quality.
  bool get isNeeded => !_isBright;

  /// True when torch was fired during calibration and stays on continuously.
  bool get isPitchDark => _isPitchDark;

  bool get isFlashOn => _isOn;

  /// Human-readable mode name for logging and Firestore metadata.
  String get modeName => _isPitchDark ? 'pitch_dark' : _isBright ? 'bright' : 'normal';

  /// Fraction of the frame's exposure contributed by the torch (0.0–1.0).
  double get intensity {
    if (_isPitchDark) return 1.0; // torch is the sole light source
    if (_ambientBrightness >= 180) return 0.3;
    if (_ambientBrightness >= 80)  return 0.6;
    if (_ambientBrightness >= 30)  return 0.8;
    return 0.6;
  }
}
