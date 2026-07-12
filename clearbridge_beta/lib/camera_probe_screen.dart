import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart'
    show CameraService, CaptureReticleOverlay, ReticleState,
        decodeStillJpegToLuma, DecodedStillLuma;

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Phase-0 device camera probe (see docs/CAPTURE_OPTIMIZATION_SCOPE.md).
///
/// Turns three guesses into measured facts, on THIS device:
///   1. which rear cameras Flutter can actually open (main / night-vision+IR /
///      ultrawide on the Doogee S118), with their capabilities;
///   2. which one resolves thumb ridges the sharpest — a blur-then-Laplacian
///      estimate on a centre crop (raw Laplacian was found to be fooled by
///      sensor noise: a grainy shot outscored a genuinely cleaner one in
///      testing, hence the pre-smoothing);
///   3. whether torch/flash helps each, and whether a forced negative EV
///      offset recovers ridge detail on cameras whose metered still comes
///      back blown out (motivated by a field observation: ridges visible in
///      the IR/night-vision camera's LIVE preview, but every metered still
///      overexposed white — that split points at the still-capture exposure
///      being wrong, not the sensor being incapable).
///
/// Uses [CameraService] (the SAME camera-lifecycle helper the real capture
/// flow uses) instead of a raw CameraController, specifically for its
/// documented two-attempt retry (12s then 20s) around cold-HAL-start
/// negotiation on budget devices — a raw single-timeout init was the bug in
/// the first cut of this screen (camera index 0 hung with no visible
/// progress). A live preview is shown per camera so it's visually obvious
/// when a camera has actually opened, and a "Skip camera" button lets you
/// bail out of a slow one without waiting the full retry budget.
///
/// For each accessible back camera it captures a torch-off and a torch-on
/// still, uploads both plus a `probe.json` capability manifest under
/// `captures/<uid>/camera_probe_<id>/` (the Storage path the owner is already
/// allowed to write — no rules change, and the callable pipeline never runs on
/// it). Reachable via a long-press on the splash logo; never touches the
/// normal capture flow.
class CameraProbeScreen extends StatefulWidget {
  const CameraProbeScreen({super.key, required this.getUserId});

  final String? Function() getUserId;

  @override
  State<CameraProbeScreen> createState() => _CameraProbeScreenState();
}

class _SkipRequested implements Exception {}

class _CamResult {
  final Map<String, dynamic> caps = {};
  double sharpOff = 0;
  double sharpOn = 0;
  double sharpEvLow = 0;
  String status = 'pending';

  double get best {
    var m = sharpOff;
    if (sharpOn > m) m = sharpOn;
    if (sharpEvLow > m) m = sharpEvLow;
    return m;
  }

  String get bestLabel {
    if (best == sharpEvLow && sharpEvLow > 0) return 'ev-low';
    if (best == sharpOn && sharpOn > 0) return 'torch';
    return 'ambient';
  }
}

class _CameraProbeScreenState extends State<CameraProbeScreen> {
  final List<String> _log = [];
  final List<_CamResult> _results = [];
  final CameraService _cameraService = CameraService();
  bool _running = false;
  bool _done = false;
  bool _skipRequested = false;
  VoidCallback? _skipListener;
  String? _probeId;
  String? _currentCameraLabel;
  int? _countdown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { _runProbe(); });
  }

  @override
  void dispose() {
    _cameraService.disposeCamera();
    super.dispose();
  }

  void _say(String s) {
    debugPrint('[probe] $s');
    if (mounted) setState(() => _log.add(s));
  }

  void _checkSkip() {
    if (_skipRequested) throw _SkipRequested();
  }

  /// Visible "get ready" countdown before a shot fires. The whole point is
  /// giving the user time to see the live preview (now large, with the same
  /// reticle the real capture flow uses) and place their thumb pad ON TARGET
  /// before the shutter — the prior cut fired instantly on camera open, which
  /// is why the very first shot caught an empty desk.
  Future<void> _countdownThen(int seconds) async {
    for (var s = seconds; s >= 1; s--) {
      if (!mounted) return;
      _checkSkip();
      setState(() => _countdown = s);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (mounted) setState(() => _countdown = null);
  }

  Future<void> _runProbe() async {
    if (_running) return;
    setState(() => _running = true);
    final uid = widget.getUserId() ?? 'anon';
    final probeId = DateTime.now().millisecondsSinceEpoch.toString();
    _probeId = probeId;
    final base = 'captures/$uid/camera_probe_$probeId';

    List<CameraDescription> cams;
    try {
      cams = await availableCameras();
    } catch (e) {
      _say('availableCameras() failed: $e');
      setState(() { _running = false; _done = true; });
      return;
    }
    final back = cams.where((c) => c.lensDirection == CameraLensDirection.back).toList();
    _say('${cams.length} cameras total; ${back.length} rear-facing');
    for (final c in cams) {
      _say('  • ${c.name}  dir=${c.lensDirection.name} type=${c.lensType.name} '
          'orient=${c.sensorOrientation}°');
    }

    final docCams = <Map<String, dynamic>>[];
    for (final desc in back) {
      final r = _CamResult();
      // Recorded upfront so even a skip/failure before init completes still
      // leaves an identifiable entry in probe.json.
      r.caps['name'] = desc.name;
      r.caps['lensType'] = desc.lensType.name;
      r.caps['lensDirection'] = desc.lensDirection.name;
      r.caps['sensorOrientation'] = desc.sensorOrientation;
      _results.add(r);
      _skipRequested = false;
      setState(() => _currentCameraLabel = '${desc.name} (${desc.lensType.name})');
      _say('── probing ${desc.name} (${desc.lensType.name}) ──');
      try {
        _checkSkip();
        // CameraService.initializeCamera has its own bounded 12s+20s retry
        // for exactly this device class's cold-HAL-start negotiation — that
        // resilience is the whole point of using it instead of a raw
        // CameraController, so every camera gets a bounded (not unbounded)
        // wait even in the worst case. It can still take up to ~32s though,
        // so race it against the Skip button rather than only checking after
        // it returns — otherwise Skip does nothing while a camera is stuck
        // mid-init, exactly the case that motivated this rewrite.
        final skipDuringInit = Completer<void>();
        void onSkipDuringInit() {
          if (!skipDuringInit.isCompleted) skipDuringInit.complete();
        }
        _skipListener = onSkipDuringInit;
        final initFuture = _cameraService.initializeCamera(
          cameraDescription: desc,
          resolution: ResolutionPreset.max,
        );
        final raced = await Future.any<String>([
          initFuture.then((_) => 'done'),
          skipDuringInit.future.then((_) => 'skipped'),
        ]);
        _skipListener = null;
        if (raced == 'skipped') {
          r.status = 'skipped-by-user';
          _say('  ⏭ skipped while opening (finishing in background)');
          // Don't await the real init here — let it settle on its own and
          // clean up afterwards, so we don't block the next camera on it.
          unawaited(initFuture
              .then((_) => _cameraService.disposeCamera())
              .catchError((_) {}));
          r.caps['status'] = r.status;
          docCams.add(r.caps);
          if (mounted) setState(() {});
          continue;
        }
        setState(() {}); // let the preview widget pick up the new controller
        final ctrl = _cameraService.controller!;
        _checkSkip();

        final ps = ctrl.value.previewSize;
        r.caps['previewSize'] = ps == null ? null : '${ps.width.toInt()}x${ps.height.toInt()}';
        r.caps['minExposureOffset'] = await _tryD(() => ctrl.getMinExposureOffset());
        r.caps['maxExposureOffset'] = await _tryD(() => ctrl.getMaxExposureOffset());
        r.caps['minZoom'] = await _tryD(() => ctrl.getMinZoomLevel());
        r.caps['maxZoom'] = await _tryD(() => ctrl.getMaxZoomLevel());
        _say('  opened: preview=${r.caps['previewSize']} '
            'zoom=${r.caps['minZoom']}-${r.caps['maxZoom']}');

        await Future<void>.delayed(const Duration(milliseconds: 700)); // let AF settle
        _checkSkip();

        // Give the user time to see the (now large) live preview and place
        // their thumb pad on target before anything fires.
        await ctrl.setFlashMode(FlashMode.off);
        await _countdownThen(4);
        _checkSkip();

        // Torch OFF still.
        try {
          final off = await _capture(ctrl);
          r.sharpOff = await _sharpness(off, desc.sensorOrientation);
          r.caps['imgOff'] = _jpegDims(off);
          r.caps['bytesOff'] = off.length;
          final uploaded = await _upload('$base/${_safe(desc.name)}_off.jpg', off);
          _say('  torch-off: ${(off.length / 1024).toStringAsFixed(0)}KB '
              '${r.caps['imgOff'] ?? ''} sharp=${r.sharpOff.toStringAsFixed(0)} '
              '${uploaded ? '' : '(upload FAILED)'}');
        } catch (e) {
          if (e is _SkipRequested) rethrow;
          _say('  torch-off capture failed: $e');
        }
        _checkSkip();
        // Torch ON still (main flash LED; night-vision camera auto-uses its IR).
        try {
          await ctrl.setFlashMode(FlashMode.torch);
          await _countdownThen(2); // hold steady while AE re-settles for torch
          final on = await _capture(ctrl);
          r.sharpOn = await _sharpness(on, desc.sensorOrientation);
          r.caps['imgOn'] = _jpegDims(on);
          final uploaded = await _upload('$base/${_safe(desc.name)}_torch.jpg', on);
          await ctrl.setFlashMode(FlashMode.off);
          _say('  torch-on:  sharp=${r.sharpOn.toStringAsFixed(0)} '
              '${uploaded ? '' : '(upload FAILED)'}');
        } catch (e) {
          if (e is _SkipRequested) rethrow;
          _say('  torch-on capture failed: $e');
        }
        _checkSkip();
        // EV-compensated still. Motivated by a direct field observation: on
        // the IR/night-vision camera, ridges were visible in the LIVE preview
        // but every still (torch off AND on) came back fully blown out white.
        // That split points at the metered STILL exposure being wrong, not
        // the sensor being incapable -- Camera2/CameraX can meter a still
        // differently than the live preview, especially with a dedicated IR
        // illuminator that isn't driven by the visible-light torch API at
        // all. Force exposure down to the camera's own reported minimum and
        // shoot again with torch off to test whether that recovers detail.
        try {
          await ctrl.setFlashMode(FlashMode.off);
          final minEv = await _tryD(() => ctrl.getMinExposureOffset()) ?? -2.0;
          await ctrl.setExposureOffset(minEv);
          await _countdownThen(2);
          final evShot = await _capture(ctrl);
          r.sharpEvLow = await _sharpness(evShot, desc.sensorOrientation);
          r.caps['imgEvLow'] = _jpegDims(evShot);
          final uploaded =
              await _upload('$base/${_safe(desc.name)}_evlow.jpg', evShot);
          await ctrl.setExposureOffset(0.0);
          _say('  ev-low (${minEv.toStringAsFixed(1)}): '
              'sharp=${r.sharpEvLow.toStringAsFixed(0)} '
              '${uploaded ? '' : '(upload FAILED)'}');
        } catch (e) {
          if (e is _SkipRequested) rethrow;
          _say('  ev-low capture failed: $e');
        }
        r.status = 'ok';
      } on _SkipRequested {
        r.status = 'skipped-by-user';
        _say('  ⏭ skipped by user');
      } catch (e) {
        r.status = 'init-failed';
        r.caps['error'] = e.toString();
        _say('  ${desc.name} failed: $e');
      } finally {
        await _cameraService.disposeCamera();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      r.caps['sharpnessOff'] = r.sharpOff;
      r.caps['sharpnessTorch'] = r.sharpOn;
      r.caps['sharpnessEvLow'] = r.sharpEvLow;
      r.caps['status'] = r.status;
      docCams.add(r.caps);
      if (mounted) setState(() {});
    }

    setState(() => _currentCameraLabel = null);
    try {
      final meta = {
        'probeId': probeId,
        'userId': uid,
        'createdAt': DateTime.now().toIso8601String(),
        'source': 'clearbridge_beta',
        'cameraCount': cams.length,
        'rearCameraCount': back.length,
        'cameras': docCams,
      };
      final ok = await _upload('$base/probe.json',
          Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(meta))),
          contentType: 'application/json');
      if (ok) {
        _say('✓ wrote $base/probe.json');
      } else {
        // Storage rules on captures/ likely only allow image content-types --
        // fall back to logging the full manifest on-screen so nothing is lost
        // (a screenshot captures it, same as the sharpness ranking above).
        _say('✗ probe.json upload rejected -- full manifest below:');
        for (final line in const JsonEncoder.withIndent('  ').convert(meta).split('\n')) {
          _say('  $line');
        }
      }
    } catch (e) {
      _say('metadata upload failed: $e');
    }
    setState(() { _running = false; _done = true; });
  }

  Future<double?> _tryD(Future<double> Function() f) async {
    try { return await f(); } catch (_) { return null; }
  }

  Future<Uint8List> _capture(CameraController ctrl) async {
    final x = await ctrl.takePicture();
    return x.readAsBytes();
  }

  /// Native still dimensions parsed from the JPEG SOF marker — cheap (no pixel
  /// decode, so no risk of OOM on a 50MP still).
  String? _jpegDims(Uint8List j) {
    var i = 2;
    while (i + 9 < j.length) {
      if (j[i] != 0xFF) { i++; continue; }
      final marker = j[i + 1];
      // SOF0-15 carry frame dimensions, excluding DHT(C4)/JPG(C8)/DAC(CC).
      if (marker >= 0xC0 && marker <= 0xCF &&
          marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
        final h = (j[i + 5] << 8) | j[i + 6];
        final w = (j[i + 7] << 8) | j[i + 8];
        return '${w}x$h';
      }
      final len = (j[i + 2] << 8) | j[i + 3];
      if (len < 2) break;
      i += 2 + len;
    }
    return null;
  }

  /// Laplacian-variance sharpness on the central ROI — higher = crisper ridges.
  /// Decodes via the hardware-accelerated downscaler (targetWidth 1024) so a
  /// 50MP still never gets fully decoded in pure Dart.
  ///
  /// Pre-smooths before measuring: a raw Laplacian on the untouched still is
  /// fooled by sensor noise, since grain reads as high-frequency energy just
  /// like real ridges do. Confirmed on real captures during testing — a
  /// grainy low-light shot scored HIGHER than a genuinely cleaner one. A
  /// mild blur first removes single-pixel grain while ridge-scale structure
  /// (many pixels wide) survives, so the score tracks true detail again —
  /// same principle as the server-side ridge-energy probe, just implemented
  /// as blur-then-Laplacian here instead of a difference-of-Gaussians.
  Future<double> _sharpness(Uint8List jpeg, int sensorOrientation) async {
    final DecodedStillLuma? d =
        await decodeStillJpegToLuma(jpeg, sensorOrientation, targetWidth: 1024);
    if (d == null) return 0;
    final w = d.width, h = d.height;
    final raw = Float32List(w * h);
    for (var i = 0; i < raw.length; i++) {
      raw[i] = d.luma[i].toDouble();
    }
    final smoothed = _boxBlur3x(raw, w, h, 2);
    final s = w < h ? w : h;
    final x0 = (w - s) ~/ 2 + s ~/ 4;
    final y0 = (h - s) ~/ 2 + s ~/ 4;
    final cs = s ~/ 2;
    double mean = 0;
    var n = 0;
    final vals = <double>[];
    for (var y = y0 + 1; y < y0 + cs - 1; y += 2) {
      for (var x = x0 + 1; x < x0 + cs - 1; x += 2) {
        final i = y * w + x;
        final lap = 4.0 * smoothed[i] - smoothed[i - 1] - smoothed[i + 1] -
            smoothed[i - w] - smoothed[i + w];
        vals.add(lap);
        mean += lap;
        n++;
      }
    }
    if (n == 0) return 0;
    mean /= n;
    double v = 0;
    for (final x in vals) { final dd = x - mean; v += dd * dd; }
    return v / n;
  }

  /// 3-pass box blur (horizontal + vertical each pass) — a standard, cheap
  /// approximation of a Gaussian blur (each pass narrows the result toward a
  /// normal distribution per the Central Limit Theorem). Precision doesn't
  /// matter here, only that it meaningfully suppresses single-pixel noise.
  Float32List _boxBlur3x(Float32List src, int w, int h, int radius) {
    var buf = src;
    for (var pass = 0; pass < 3; pass++) {
      buf = _boxBlurH(buf, w, h, radius);
      buf = _boxBlurV(buf, w, h, radius);
    }
    return buf;
  }

  Float32List _boxBlurH(Float32List src, int w, int h, int r) {
    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      final rowBase = y * w;
      double sum = 0;
      for (var k = -r; k <= r; k++) {
        sum += src[rowBase + k.clamp(0, w - 1)];
      }
      out[rowBase] = sum / (2 * r + 1);
      for (var x = 1; x < w; x++) {
        final addIdx = (x + r).clamp(0, w - 1);
        final subIdx = (x - r - 1).clamp(0, w - 1);
        sum += src[rowBase + addIdx] - src[rowBase + subIdx];
        out[rowBase + x] = sum / (2 * r + 1);
      }
    }
    return out;
  }

  Float32List _boxBlurV(Float32List src, int w, int h, int r) {
    final out = Float32List(w * h);
    for (var x = 0; x < w; x++) {
      double sum = 0;
      for (var k = -r; k <= r; k++) {
        sum += src[k.clamp(0, h - 1) * w + x];
      }
      out[x] = sum / (2 * r + 1);
      for (var y = 1; y < h; y++) {
        final addIdx = (y + r).clamp(0, h - 1);
        final subIdx = (y - r - 1).clamp(0, h - 1);
        sum += src[addIdx * w + x] - src[subIdx * w + x];
        out[y * w + x] = sum / (2 * r + 1);
      }
    }
    return out;
  }

  String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Returns whether the upload actually succeeded — callers must check this
  /// rather than assume success, since a prior cut logged "✓ wrote" even when
  /// every retry had failed (probe.json silently never landed in Storage,
  /// likely a content-type restriction on the captures/ path).
  Future<bool> _upload(String path, Uint8List bytes, {String contentType = 'image/jpeg'}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await FirebaseStorage.instance.ref().child(path).putData(
            bytes, SettableMetadata(contentType: contentType));
        return true;
      } catch (e) {
        if (attempt >= 2) { _say('  upload failed ($path): $e'); return false; }
        await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _cameraService.controller;
    final showPreview = ctrl != null && ctrl.value.isInitialized;
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      appBar: AppBar(
        backgroundColor: ClearBridgeColors.void_,
        foregroundColor: ClearBridgeColors.silverBright,
        title: const Text('Camera Probe'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _running
                        ? 'Probing ${_currentCameraLabel ?? '…'} — hold a thumb pad in frame'
                        : _done
                            ? 'Done — uploaded (probe $_probeId)'
                            : 'Starting…',
                    style: const TextStyle(
                        color: ClearBridgeColors.cyan, fontWeight: FontWeight.bold),
                  ),
                ),
                if (_running && !_skipRequested)
                  TextButton(
                    onPressed: () {
                      setState(() => _skipRequested = true);
                      _skipListener?.call(); // interrupts an in-flight init immediately
                    },
                    child: const Text('Skip camera →',
                        style: TextStyle(color: ClearBridgeColors.silverBright)),
                  ),
              ],
            ),
            if (showPreview) ...[
              const SizedBox(height: 8),
              // Large and prominent — the whole point is you can SEE the
              // camera has opened and where to place your thumb, instead of
              // placing it blind. Same reticle oval the real capture flow
              // uses, so the framing target is familiar.
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.42,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: ctrl.value.previewSize?.height ?? 100,
                          height: ctrl.value.previewSize?.width ?? 100,
                          child: CameraPreview(ctrl),
                        ),
                      ),
                      CaptureReticleOverlay(
                        state: _countdown != null
                            ? ReticleState.capturing
                            : ReticleState.aligning,
                        hint: _countdown != null
                            ? 'Hold steady — capturing in $_countdown…'
                            : 'Place thumb pad in the oval',
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (_results.isNotEmpty) _rankCard(),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  children: _log
                      .map((l) => Text(l,
                          style: const TextStyle(
                              color: ClearBridgeColors.silverDim,
                              fontFamily: 'monospace',
                              fontSize: 12)))
                      .toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rankCard() {
    final ranked = [..._results]..sort((a, b) => b.best.compareTo(a.best));
    final overall = ranked.where((r) => r.status == 'ok').isEmpty
        ? null
        : ranked.firstWhere((r) => r.status == 'ok');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black38, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Sharpness ranking (higher = crisper ridges; on-device '
              'estimate only — the pipeline\'s real NFIQ score is the '
              'authority, this is triage)',
              style: TextStyle(color: ClearBridgeColors.silverBright, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          ...ranked.map((r) {
            final name = (r.caps['name'] ?? '?').toString();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${r.status == 'ok' ? '✓' : '✗'} cam$name  '
                'ambient=${r.sharpOff.toStringAsFixed(0)} '
                'torch=${r.sharpOn.toStringAsFixed(0)} '
                'evLow=${r.sharpEvLow.toStringAsFixed(0)}  '
                '→ ${r.best.toStringAsFixed(0)} (${r.bestLabel})  [${r.status}]',
                style: const TextStyle(color: ClearBridgeColors.silverDim, fontSize: 13),
              ),
            );
          }),
          if (overall != null) ...[
            const SizedBox(height: 8),
            Text(
              'Best pick so far: camera ${overall.caps['name']} · '
              '${overall.bestLabel} (score ${overall.best.toStringAsFixed(0)}) — '
              'multi-camera capture should let this kind of comparison pick '
              'the source per capture, same as the backend already does '
              'across renderings.',
              style: const TextStyle(
                  color: ClearBridgeColors.cyan, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ],
      ),
    );
  }
}
