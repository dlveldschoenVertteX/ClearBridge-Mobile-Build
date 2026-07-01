enum LaplacianTrend { sharpening, stable, blurring }

enum CaptureAxisStatus {
  holdSteady,
  moveCloser,
  moveFurther,
  betterLight,
  tooBright,
  tooFar,
  tooClose,
  allGreen,
}

enum CaptureAxis { gyro, focus, brightness, distance }

class AxisEvaluationResult {
  final CaptureAxisStatus status;
  final String message;
  final bool readyToCapture;
  final int consecutiveGreenFrames;
  final Map<CaptureAxis, bool> axisPass;

  const AxisEvaluationResult({
    required this.status,
    required this.message,
    required this.readyToCapture,
    required this.consecutiveGreenFrames,
    required this.axisPass,
  });

  bool get isAllGreen => status == CaptureAxisStatus.allGreen;
}

/// Priority-gate 4-axis quality evaluator. Pure logic — no streams, no Flutter.
///
/// Call [evaluate] once per detection frame with the latest sensor readings.
/// [reset] must be called between capture angles so the green-frame counter
/// starts fresh for each angle.
class CaptureAxisController {
  static const _greenRequired = 5;    // 5×90ms ≈ 450ms deliberate hold
  static const _gyroMax = 0.10;      // rad/s — tolerates budget-device gyro bias
  static const _focusMin = 0.45;     // normalised (0–1) — raised from 0.35 to reject soft frames
  static const _brightnessMin = 80.0;
  static const _brightnessMax = 180.0;
  // Raised from 0.25 → 0.40: thumb must fill 40% of frame height, which at
  // the A16's sensor maps to ~10–14cm. Closer distance = more ridge detail.
  static const _coverageMin = 0.40;
  static const _coverageMax = 0.75;

  int _consecutiveGreen = 0;

  void reset() => _consecutiveGreen = 0;

  AxisEvaluationResult evaluate({
    required double normalisedFocus,
    required LaplacianTrend trend,
    required double brightness,
    required double thumbCoverageRatio,
    required double gyroMagnitude,
    bool flashOn = false,
  }) {
    final gyroPass = gyroMagnitude <= _gyroMax;
    final focusPass = normalisedFocus >= _focusMin;
    final brightnessPass =
        brightness >= _brightnessMin && brightness <= _brightnessMax;
    final distancePass = thumbCoverageRatio >= _coverageMin &&
        thumbCoverageRatio <= _coverageMax;

    // Gate 1: gyro (highest priority — motion ruins all other axes)
    if (!gyroPass) {
      _consecutiveGreen = 0;
      return _block(
        CaptureAxisStatus.holdSteady,
        'Hold your hand steady',
        {
          CaptureAxis.gyro: false,
          CaptureAxis.focus: focusPass,
          CaptureAxis.brightness: brightnessPass,
          CaptureAxis.distance: distancePass,
        },
      );
    }

    // Gate 2: focus
    if (!focusPass) {
      // Sharpening is advisory — don't block, but don't count as green either.
      if (trend == LaplacianTrend.sharpening) {
        _consecutiveGreen = 0;
        return _block(
          CaptureAxisStatus.moveCloser,
          'Getting sharper, keep going...',
          {
            CaptureAxis.gyro: true,
            CaptureAxis.focus: false,
            CaptureAxis.brightness: brightnessPass,
            CaptureAxis.distance: distancePass,
          },
        );
      }
      _consecutiveGreen = 0;
      final msg = trend == LaplacianTrend.blurring
          ? 'Move your finger further away'
          : 'Move your finger closer';
      return _block(
        trend == LaplacianTrend.blurring
            ? CaptureAxisStatus.moveFurther
            : CaptureAxisStatus.moveCloser,
        msg,
        {
          CaptureAxis.gyro: true,
          CaptureAxis.focus: false,
          CaptureAxis.brightness: brightnessPass,
          CaptureAxis.distance: distancePass,
        },
      );
    }

    // Gate 3: brightness
    // The dark floor always blocks — indicates genuinely bad ambient conditions.
    // The bright ceiling is skipped when the torch is on: flash intentionally
    // raises luma and the streak must not be reset by our own illumination.
    if (brightness < _brightnessMin) {
      _consecutiveGreen = 0;
      return _block(
        CaptureAxisStatus.betterLight,
        'Find better lighting',
        {
          CaptureAxis.gyro: true,
          CaptureAxis.focus: true,
          CaptureAxis.brightness: false,
          CaptureAxis.distance: distancePass,
        },
      );
    }
    if (!flashOn && brightness > _brightnessMax) {
      _consecutiveGreen = 0;
      return _block(
        CaptureAxisStatus.tooBright,
        'Too much light, find some shade',
        {
          CaptureAxis.gyro: true,
          CaptureAxis.focus: true,
          CaptureAxis.brightness: false,
          CaptureAxis.distance: distancePass,
        },
      );
    }

    // Gate 4: distance via thumbCoverageRatio
    if (thumbCoverageRatio == 0 || thumbCoverageRatio < _coverageMin) {
      _consecutiveGreen = 0;
      return _block(
        CaptureAxisStatus.tooFar,
        'Move your finger closer',
        {
          CaptureAxis.gyro: true,
          CaptureAxis.focus: true,
          CaptureAxis.brightness: true,
          CaptureAxis.distance: false,
        },
      );
    }
    if (thumbCoverageRatio > _coverageMax) {
      _consecutiveGreen = 0;
      return _block(
        CaptureAxisStatus.tooClose,
        'Move your finger back slightly',
        {
          CaptureAxis.gyro: true,
          CaptureAxis.focus: true,
          CaptureAxis.brightness: true,
          CaptureAxis.distance: false,
        },
      );
    }

    // All axes green — increment streak
    _consecutiveGreen++;
    final ready = _consecutiveGreen >= _greenRequired;
    return AxisEvaluationResult(
      status: CaptureAxisStatus.allGreen,
      message: ready ? 'Capturing...' : 'Perfect — hold still',
      readyToCapture: ready,
      consecutiveGreenFrames: _consecutiveGreen,
      axisPass: const {
        CaptureAxis.gyro: true,
        CaptureAxis.focus: true,
        CaptureAxis.brightness: true,
        CaptureAxis.distance: true,
      },
    );
  }

  AxisEvaluationResult _block(
    CaptureAxisStatus status,
    String message,
    Map<CaptureAxis, bool> axisPass,
  ) {
    return AxisEvaluationResult(
      status: status,
      message: message,
      readyToCapture: false,
      consecutiveGreenFrames: _consecutiveGreen,
      axisPass: axisPass,
    );
  }
}
