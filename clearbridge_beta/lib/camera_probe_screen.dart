import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:mac_capture/mac_capture.dart' show decodeStillJpegToLuma, DecodedStillLuma;

import 'package:clearbridge_beta/clearbridge_colors.dart';

/// Phase-0 device camera probe (see docs/CAPTURE_OPTIMIZATION_SCOPE.md).
///
/// Turns three guesses into measured facts, on THIS device:
///   1. which rear cameras Flutter can actually open (main / night-vision+IR /
///      ultrawide on the Doogee S118), with their capabilities;
///   2. which one resolves thumb ridges the sharpest (on-device Laplacian-
///      variance of a centre crop, so you get an instant ranking);
///   3. whether torch/flash helps each, and whether the IR night-vision camera
///      is worth pursuing as an ambient-independent source.
///
/// For each accessible back camera it captures a torch-off and a torch-on still
/// of whatever is framed (present a thumb pad), uploads both plus a `probe.json`
/// capability manifest under `captures/<uid>/camera_probe_<id>/` (the Storage
/// path the owner is already allowed to write — no rules change, and the
/// callable pipeline never runs on it). Reachable via a long-press on the
/// splash logo; never touches the normal capture flow.
class CameraProbeScreen extends StatefulWidget {
  const CameraProbeScreen({super.key, required this.getUserId});

  final String? Function() getUserId;

  @override
  State<CameraProbeScreen> createState() => _CameraProbeScreenState();
}

class _CamResult {
  final Map<String, dynamic> caps = {};
  double sharpOff = 0;
  double sharpOn = 0;
  String status = 'pending';
}

class _CameraProbeScreenState extends State<CameraProbeScreen> {
  final List<String> _log = [];
  final List<_CamResult> _results = [];
  bool _running = false;
  bool _done = false;
  String? _probeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { _runProbe(); });
  }

  void _say(String s) {
    debugPrint('[probe] $s');
    if (mounted) setState(() => _log.add(s));
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
      _results.add(r);
      _say('── probing ${desc.name} (${desc.lensType.name}) ──');
      CameraController? ctrl;
      try {
        ctrl = CameraController(desc, ResolutionPreset.max, enableAudio: false);
        await ctrl.initialize().timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 400));

        r.caps['name'] = desc.name;
        r.caps['lensType'] = desc.lensType.name;
        r.caps['lensDirection'] = desc.lensDirection.name;
        r.caps['sensorOrientation'] = desc.sensorOrientation;
        final ps = ctrl.value.previewSize;
        r.caps['previewSize'] = ps == null ? null : '${ps.width.toInt()}x${ps.height.toInt()}';
        r.caps['minExposureOffset'] = await _tryD(() => ctrl!.getMinExposureOffset());
        r.caps['maxExposureOffset'] = await _tryD(() => ctrl!.getMaxExposureOffset());
        r.caps['minZoom'] = await _tryD(() => ctrl!.getMinZoomLevel());
        r.caps['maxZoom'] = await _tryD(() => ctrl!.getMaxZoomLevel());

        await ctrl.setFocusMode(FocusMode.auto).catchError((_) {});
        await ctrl.setFocusPoint(const Offset(0.5, 0.5)).catchError((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 700)); // let AF settle

        // Torch OFF still.
        try {
          await ctrl.setFlashMode(FlashMode.off);
          final off = await _capture(ctrl);
          r.sharpOff = await _sharpness(off, desc.sensorOrientation);
          r.caps['imgOff'] = _jpegDims(off);
          r.caps['bytesOff'] = off.length;
          await _upload('$base/${_safe(desc.name)}_off.jpg', off);
          _say('  torch-off: ${(off.length / 1024).toStringAsFixed(0)}KB '
              '${r.caps['imgOff'] ?? ''} sharp=${r.sharpOff.toStringAsFixed(0)}');
        } catch (e) {
          _say('  torch-off capture failed: $e');
        }
        // Torch ON still (main flash LED; night-vision camera auto-uses its IR).
        try {
          await ctrl.setFlashMode(FlashMode.torch);
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final on = await _capture(ctrl);
          r.sharpOn = await _sharpness(on, desc.sensorOrientation);
          r.caps['imgOn'] = _jpegDims(on);
          await _upload('$base/${_safe(desc.name)}_torch.jpg', on);
          await ctrl.setFlashMode(FlashMode.off);
          _say('  torch-on:  sharp=${r.sharpOn.toStringAsFixed(0)}');
        } catch (e) {
          _say('  torch-on capture failed: $e');
        }
        r.status = 'ok';
      } catch (e) {
        r.status = 'init-failed';
        r.caps['error'] = e.toString();
        _say('  ${desc.name} init failed: $e');
      } finally {
        try { await ctrl?.dispose(); } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      r.caps['sharpnessOff'] = r.sharpOff;
      r.caps['sharpnessTorch'] = r.sharpOn;
      r.caps['status'] = r.status;
      docCams.add(r.caps);
      if (mounted) setState(() {});
    }

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
      await _upload('$base/probe.json',
          Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(meta))),
          contentType: 'application/json');
      _say('✓ wrote $base/probe.json');
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
  Future<double> _sharpness(Uint8List jpeg, int sensorOrientation) async {
    final DecodedStillLuma? d =
        await decodeStillJpegToLuma(jpeg, sensorOrientation, targetWidth: 1024);
    if (d == null) return 0;
    final lum = d.luma;
    final w = d.width, h = d.height;
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
        final lap = 4.0 * lum[i] - lum[i - 1] - lum[i + 1] - lum[i - w] - lum[i + w];
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

  String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<void> _upload(String path, Uint8List bytes, {String contentType = 'image/jpeg'}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await FirebaseStorage.instance.ref().child(path).putData(
            bytes, SettableMetadata(contentType: contentType));
        return;
      } catch (e) {
        if (attempt >= 2) { _say('  upload failed ($path): $e'); return; }
        await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
            Text(
              _running
                  ? 'Probing… hold a thumb pad in frame'
                  : _done
                      ? 'Done — uploaded (probe $_probeId)'
                      : 'Starting…',
              style: const TextStyle(color: ClearBridgeColors.cyan, fontWeight: FontWeight.bold),
            ),
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
    double best(_CamResult r) => r.sharpOff > r.sharpOn ? r.sharpOff : r.sharpOn;
    final ranked = [..._results]..sort((a, b) => best(b).compareTo(best(a)));
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black38, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Sharpness ranking (higher = crisper ridges)',
              style: TextStyle(color: ClearBridgeColors.silverBright, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          ...ranked.map((r) {
            final lensType = (r.caps['lensType'] ?? '?').toString();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${r.status == 'ok' ? '✓' : '✗'} $lensType  '
                'off=${r.sharpOff.toStringAsFixed(0)} torch=${r.sharpOn.toStringAsFixed(0)}  '
                '→ ${best(r).toStringAsFixed(0)}',
                style: const TextStyle(color: ClearBridgeColors.silverDim, fontSize: 13),
              ),
            );
          }),
        ],
      ),
    );
  }
}
