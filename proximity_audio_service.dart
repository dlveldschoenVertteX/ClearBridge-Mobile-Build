import 'package:flutter/services.dart';

/// Proximity audio guidance: plays a short beep at increasing rate and
/// volume as [distanceToTarget] falls below 30°.
///
/// Uses Android ToneGenerator via a method channel (no audio files required).
/// Each [maybeTone] call is rate-limited per zone so beeps are evenly spaced
/// and not fired more often than the haptic system.
///
/// Call [stop] when capture completes or the screen is disposed.
class ProximityAudioService {
  static const _channel = MethodChannel('clearbridge/audio');

  // Maximum volume (0–100). Kept deliberately modest — this is a subtle cue.
  static const _maxVolume = 45;

  DateTime? _lastToneAt;
  bool _active = false;

  Future<void> start() async {
    _active = true;
    _lastToneAt = null;
  }

  Future<void> stop() async {
    _active = false;
    try {
      await _channel.invokeMethod<void>('stopTone');
    } catch (_) {}
  }

  /// Call once per detection frame. Schedules a beep if the distance is
  /// within the approach zone and enough time has passed since the last tone.
  Future<void> maybeTone(double distanceToTarget) async {
    if (!_active || distanceToTarget > 30.0) return;

    final int intervalMs;
    final int volume;
    if (distanceToTarget > 20.0) {
      intervalMs = 600;
      volume = 25;
    } else if (distanceToTarget > 10.0) {
      intervalMs = 300;
      volume = 33;
    } else if (distanceToTarget > 5.0) {
      intervalMs = 150;
      volume = 40;
    } else {
      // Within lock zone — play a higher locked tone at a controlled rate.
      intervalMs = 120;
      volume = _maxVolume;
    }

    final now = DateTime.now();
    if (_lastToneAt != null &&
        now.difference(_lastToneAt!).inMilliseconds < intervalMs) return;
    _lastToneAt = now;

    try {
      await _channel.invokeMethod<void>('playTone', {
        'volume': volume,
        'locked': distanceToTarget <= 5.0,
      });
    } catch (_) {
      // Silently ignore — audio is supplementary to haptics.
    }
  }
}
