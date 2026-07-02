import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Plays a short repeating "tick" as the thumb approaches the current target
/// angle, speeding up the closer the thumb gets — an audio complement to the
/// [HapticGuidanceCircle]'s visual jitter, using the exact same proximity
/// bands so the two stay in sync:
///   >30°   silent
///   20-30° slow tick  (2500ms)
///   10-20° medium tick (833ms)
///   5-10°  fast tick   (333ms)
///   ≤5°    silent (locked — the hold-steady phase needs no more ticking)
///
/// Call [updateDistance] on every guidance update; the service self-schedules
/// its own repeating timer and only reschedules when the proximity band
/// actually changes, so it's cheap to call every frame.
class AngleAudioGuidanceService {
  final AudioPlayer _player = AudioPlayer();
  Timer? _timer;
  double _intervalMs = 0;
  bool _assetLoaded = false;
  bool _disposed = false;

  Future<void> preload() async {
    try {
      await _player.setAsset('assets/audio/angle_tick.wav');
      _assetLoaded = true;
    } catch (_) {
      _assetLoaded = false;
    }
  }

  void updateDistance(double distanceToTarget) {
    final interval = _intervalFor(distanceToTarget);
    if (interval == _intervalMs) return;
    _intervalMs = interval;
    _reschedule();
  }

  double _intervalFor(double d) {
    if (d > 30) return 0;
    if (d > 20) return 2500;
    if (d > 10) return 833;
    if (d > 5) return 333;
    return 0; // locked — silent
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (_intervalMs <= 0) return;
    _timer = Timer.periodic(
      Duration(milliseconds: _intervalMs.round()),
      (_) => _tick(),
    );
  }

  void _tick() {
    if (_disposed || !_assetLoaded) return;
    unawaited(_playTick());
  }

  Future<void> _playTick() async {
    try {
      await _player.seek(Duration.zero);
      await _player.play();
    } catch (_) {}
  }

  /// Stops ticking immediately (angle locked, session reset, or capture
  /// advancing to the next angle).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _intervalMs = 0;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_player.dispose());
  }
}
