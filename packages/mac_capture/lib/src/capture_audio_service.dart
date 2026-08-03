import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// Manages all capture-session audio:
///   • Angle success chime on each captured angle
///   • Brand jingle on the final angle
///   • Proximity guidance: pitch + tempo rise as angle closes in on target,
///     like a parking sensor. Four zones (far→lock) each backed by a
///     pre-generated WAV file where the silence padding bakes in the loop
///     period — LoopMode.one provides gapless, timer-free repetition (no
///     manual Timer.periodic rescheduling, so a zone flickering back and
///     forth near a boundary can never starve playback the way a
///     cancel-and-restart timer would).
class CaptureAudioService {
  final _successPlayer = AudioPlayer();
  final _finalPlayer   = AudioPlayer();
  final _beepPlayer    = AudioPlayer();
  // One-shot synthesized cues (sweep start/complete, etc.) -- separate
  // player from _beepPlayer since that one loops continuously and gets
  // stopped/restarted on every proximity-zone change; a one-shot cue firing
  // mid-loop-switch would otherwise race it.
  final _cuePlayer = AudioPlayer();

  int _currentZone = -1; // -1 = silent
  final List<String> _pipPaths = [];
  String? _sweepStartPath;
  String? _sweepCompletePath;

  // Zone specs: (frequencyHz, pipDurationMs, totalPeriodMs)
  // totalPeriodMs = pip + silence padding; LoopMode.one loops at this rate.
  static const List<(double, int, int)> _zoneSpecs = [
    (600.0,  55, 1100), // 0 — far     > 30°:  ~0.9 bps, low pitch
    (850.0,  50,  560), // 1 — medium  15–30°: ~1.8 bps, mid pitch
    (1100.0, 45,  270), // 2 — close    8–15°: ~3.7 bps, high-mid pitch
    (1400.0, 40,  115), // 3 — lock      < 8°: ~8.7 bps, high pitch
  ];

  /// Call once after construction — pre-generates pip files and loads assets.
  Future<void> init() async {
    await Future.wait([
      _successPlayer.setAsset('assets/audio/capture_success.wav').catchError((_) => null),
      _finalPlayer  .setAsset('assets/audio/brand_jingle.wav'   ).catchError((_) => null),
      _initBeepFiles(),
      _initCueFiles(),
    ]);
  }

  Future<void> _initBeepFiles() async {
    try {
      final tmpDir = await getTemporaryDirectory();
      for (final (freq, pipMs, totalMs) in _zoneSpecs) {
        final path = '${tmpDir.path}/cb_pip_${freq.round()}.wav';
        File(path).writeAsBytesSync(
          _generatePip(
            frequencyHz: freq,
            pipDurationMs: pipMs,
            totalDurationMs: totalMs,
          ),
        );
        _pipPaths.add(path);
      }
    } catch (_) {}
  }

  // Burst+video hybrid capture (2026-08-03): dedicated, synthesized cues for
  // the sweep-video step -- distinct from playAngleSuccess's two existing
  // sounds (capture_success.wav / brand_jingle.wav) so "start sweeping now"
  // and "sweep recording done" are each their own recognizable sound,
  // reusing the same WAV-synthesis machinery _generatePip already
  // established rather than needing new asset files.
  Future<void> _initCueFiles() async {
    try {
      final tmpDir = await getTemporaryDirectory();
      // Rising two-tone "go" chirp -- distinct from every other single-pip
      // sound in this file, reads as "begin an action" not "you arrived".
      final startPath = '${tmpDir.path}/cb_sweep_start.wav';
      File(startPath).writeAsBytesSync(_generateChirp(
        freq1Hz: 700, freq2Hz: 1050, eachMs: 70, gapMs: 40,
      ));
      _sweepStartPath = startPath;
      // Single higher, slightly longer pip -- distinct from the chirp above
      // and from capture_success.wav, reads as "that action finished".
      final completePath = '${tmpDir.path}/cb_sweep_complete.wav';
      File(completePath).writeAsBytesSync(_generatePip(
        frequencyHz: 1500, pipDurationMs: 140, totalDurationMs: 140,
      ));
      _sweepCompletePath = completePath;
    } catch (_) {}
  }

  /// Plays the sweep-video "start recording, please sweep now" cue.
  Future<void> playSweepStart() async {
    final path = _sweepStartPath;
    if (path == null) return;
    try {
      await _cuePlayer.stop();
      await _cuePlayer.setFilePath(path);
      unawaited(_cuePlayer.play());
    } catch (_) {}
  }

  /// Plays the sweep-video "recording finished" cue.
  Future<void> playSweepComplete() async {
    final path = _sweepCompletePath;
    if (path == null) return;
    try {
      await _cuePlayer.stop();
      await _cuePlayer.setFilePath(path);
      unawaited(_cuePlayer.play());
    } catch (_) {}
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Plays the angle-complete sound. Silences proximity beep first.
  /// [isFinal] plays the brand jingle for the last angle.
  Future<void> playAngleSuccess({required bool isFinal}) async {
    silence();
    try {
      if (isFinal) {
        await _finalPlayer.seek(Duration.zero);
        unawaited(_finalPlayer.play());
      } else {
        await _successPlayer.seek(Duration.zero);
        unawaited(_successPlayer.play());
      }
    } catch (_) {}
  }

  /// Update guidance beep based on degrees-to-target.
  /// Pass null to silence (burst firing, calibration, angle success pause).
  /// Zone transitions swap the pip file; same-zone calls are no-ops.
  void updateGuidanceTone(double? distanceDeg) {
    final zone = _zoneFor(distanceDeg);
    if (zone == _currentZone) return;
    _currentZone = zone;
    if (zone < 0) {
      unawaited(_beepPlayer.stop());
      return;
    }
    unawaited(_switchZone(zone));
  }

  /// Immediately stop the proximity beep.
  void silence() {
    _currentZone = -1;
    unawaited(_beepPlayer.stop());
  }

  void dispose() {
    silence();
    _successPlayer.dispose();
    _finalPlayer  .dispose();
    _beepPlayer   .dispose();
    _cuePlayer    .dispose();
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<void> _switchZone(int zone) async {
    if (zone >= _pipPaths.length) return;
    try {
      await _beepPlayer.stop();
      await _beepPlayer.setFilePath(_pipPaths[zone]);
      await _beepPlayer.setLoopMode(LoopMode.one);
      unawaited(_beepPlayer.play());
    } catch (_) {}
  }

  static int _zoneFor(double? d) {
    if (d == null || d > 45) return -1;
    if (d > 30) return 0;
    if (d > 15) return 1;
    if (d > 8)  return 2;
    return 3;
  }

  /// Generates a mono 16-bit PCM WAV.
  /// [pipDurationMs] of sine tone, then silence to fill [totalDurationMs].
  /// 5 ms linear fade-in/out on the pip prevents audible clicks.
  static Uint8List _generatePip({
    required double frequencyHz,
    required int    pipDurationMs,
    required int    totalDurationMs,
    double amplitude = 0.45,
    int sampleRate   = 44100,
  }) {
    final tone = _toneSamples(
      frequencyHz: frequencyHz,
      durationMs: pipDurationMs,
      amplitude: amplitude,
      sampleRate: sampleRate,
    );
    final totalSamples = (sampleRate * totalDurationMs / 1000).round();
    final padding = (totalSamples - tone.length).clamp(0, totalSamples);
    return _pcmToWav([...tone, ...List.filled(padding, 0)], sampleRate: sampleRate);
  }

  /// Two short tones back-to-back with a silent gap between -- a distinct
  /// "go"/attention cue, different in character from a single pip (used for
  /// the sweep-video "start recording" moment).
  static Uint8List _generateChirp({
    required double freq1Hz,
    required double freq2Hz,
    required int eachMs,
    required int gapMs,
    double amplitude = 0.45,
    int sampleRate = 44100,
  }) {
    final samples = [
      ..._toneSamples(frequencyHz: freq1Hz, durationMs: eachMs, amplitude: amplitude, sampleRate: sampleRate),
      ...List.filled((sampleRate * gapMs / 1000).round(), 0),
      ..._toneSamples(frequencyHz: freq2Hz, durationMs: eachMs, amplitude: amplitude, sampleRate: sampleRate),
    ];
    return _pcmToWav(samples, sampleRate: sampleRate);
  }

  /// Sine-tone samples (16-bit PCM ints) with a 5ms linear fade-in/out to
  /// prevent audible clicks at the tone's own boundaries.
  static List<int> _toneSamples({
    required double frequencyHz,
    required int durationMs,
    double amplitude = 0.45,
    int sampleRate = 44100,
  }) {
    final n = (sampleRate * durationMs / 1000).round();
    final fadeSmp = (sampleRate * 0.005).round(); // 5 ms
    return List.generate(n, (i) {
      final t = i / sampleRate;
      final fadeIn = i < fadeSmp ? i / fadeSmp : 1.0;
      final fadeOut = i > n - fadeSmp ? (n - i) / fadeSmp.toDouble() : 1.0;
      final raw = amplitude * fadeIn * fadeOut * math.sin(2 * math.pi * frequencyHz * t);
      return (raw * 32767).round().clamp(-32768, 32767);
    });
  }

  /// Wraps 16-bit PCM mono samples in a RIFF/WAV header.
  static Uint8List _pcmToWav(List<int> samples, {int sampleRate = 44100}) {
    final dataBytes = samples.length * 2;
    final totalBytes = 44 + dataBytes;
    final buf = ByteData(totalBytes);
    int o = 0;

    void str(String s) { for (final c in s.codeUnits) { buf.setUint8(o++, c); } }
    void u32(int v)    { buf.setUint32(o, v, Endian.little); o += 4; }
    void u16(int v)    { buf.setUint16(o, v, Endian.little); o += 2; }

    str('RIFF'); u32(totalBytes - 8); str('WAVE');
    str('fmt '); u32(16);
    u16(1); u16(1);
    u32(sampleRate); u32(sampleRate * 2);
    u16(2); u16(16);
    str('data'); u32(dataBytes);

    for (final sample in samples) {
      buf.setInt16(o, sample, Endian.little);
      o += 2;
    }

    return buf.buffer.asUint8List();
  }
}
