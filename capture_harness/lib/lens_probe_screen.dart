import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mac_capture/mac_capture.dart';

/// Diagnostic-only screen, standalone-harness-scoped per this project's own
/// "no one-off diagnostic tooling in the production app" precedent (commit
/// 4a832c0). Built to answer a direct CTO question: their device's stock
/// camera app shows a distinct "Macro" mode tile (not a toggle inside
/// regular Photo mode) -- is that a genuinely separate hardware lens
/// ClearBridge could capture from, and if so, which of the camera IDs this
/// project already enumerates (0/1/2/3) is it?
///
/// Two independent checks, in order of how conclusive they are:
/// 1. `getCameraExtensionSupport` (Camera2 Extensions API, 31+): if this
///    device formally implements Macro as a vendor extension, this settles
///    it directly -- no visual comparison needed. Real expectation, stated
///    plainly: unlikely on a budget/rugged device (this API is mostly a
///    flagship feature), but free to check and definitive if positive.
/// 2. Visual comparison: fires one still from EACH back camera id in turn,
///    labelled with its real focal length/sensor size (already-collected
///    real data already points at camera "2" -- 2.37mm focal length,
///    3.92x2.94mm sensor, shortest/smallest of the four -- as the likely
///    macro sensor). The CTO can hold the SAME macro subject in frame and
///    compare each still's field-of-view/close-focus behaviour directly
///    against a reference photo taken with the stock app's own Macro mode.
class LensProbeScreen extends StatefulWidget {
  const LensProbeScreen({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<LensProbeScreen> createState() => _LensProbeScreenState();
}

class _CapturedLens {
  _CapturedLens({
    required this.description,
    required this.bytes,
    required this.lensInfo,
    required this.extensionInfo,
  });

  final CameraDescription description;
  final Uint8List bytes;
  final Map<String, dynamic>? lensInfo;
  final Map<String, dynamic>? extensionInfo;
}

class _LensProbeScreenState extends State<LensProbeScreen> {
  static const _channel = MethodChannel('clearbridge/cameraCapabilities');

  final CameraService _service = CameraService();
  List<CameraDescription> _backCameras = [];
  Map<String, dynamic> _lensInfoByCameraId = {};
  Map<String, dynamic> _extensionInfoByCameraId = {};
  int _index = 0;
  bool _loading = true;
  bool _capturing = false;
  bool _finished = false;
  String? _error;
  final List<_CapturedLens> _captured = [];

  @override
  void initState() {
    super.initState();
    _startup();
  }

  Future<void> _startup() async {
    try {
      final all = await _service.getAvailableCameras();
      _backCameras = all
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList();

      try {
        final lensInfo = await _channel.invokeMapMethod<String, dynamic>(
            'getCameraLensInfo');
        _lensInfoByCameraId = lensInfo ?? {};
      } catch (e) {
        debugPrint('LensProbe: getCameraLensInfo failed: $e');
      }
      try {
        final extInfo = await _channel.invokeMapMethod<String, dynamic>(
            'getCameraExtensionSupport');
        _extensionInfoByCameraId = extInfo ?? {};
      } catch (e) {
        debugPrint('LensProbe: getCameraExtensionSupport failed: $e');
      }

      if (_backCameras.isEmpty) {
        setState(() {
          _error = 'No back cameras found on this device';
          _loading = false;
        });
        return;
      }
      await _openCurrent();
    } catch (e) {
      setState(() {
        _error = 'Setup failed: $e';
        _loading = false;
      });
    }
  }

  CameraDescription get _currentDescription => _backCameras[_index];

  // Camera ids reported by the `camera` plugin match Camera2's own
  // cameraIdList strings on Android -- same assumption this project's
  // existing secondary-camera scoring already relies on (main.py matches
  // uploaded filenames back to `cameraLensInfo` by this same id).
  String get _currentId => _currentDescription.name;

  Map<String, dynamic>? get _currentLensInfo =>
      (_lensInfoByCameraId[_currentId] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get _currentExtensionInfo =>
      (_extensionInfoByCameraId[_currentId] as Map?)?.cast<String, dynamic>();

  Future<void> _openCurrent() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.initializeCamera(
        cameraDescription: _currentDescription,
        resolution: ResolutionPreset.high,
      );
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = 'Failed to open camera $_currentId: $e';
        _loading = false;
      });
    }
  }

  Future<void> _captureAndAdvance() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      final xfile = await _service.captureImage();
      final bytes = await xfile.readAsBytes();
      _captured.add(_CapturedLens(
        description: _currentDescription,
        bytes: bytes,
        lensInfo: _currentLensInfo,
        extensionInfo: _currentExtensionInfo,
      ));
      await _service.disposeCamera();
      if (_index < _backCameras.length - 1) {
        setState(() {
          _index++;
          _capturing = false;
        });
        await _openCurrent();
      } else {
        setState(() {
          _capturing = false;
          _finished = true;
        });
      }
    } catch (e) {
      setState(() {
        _capturing = false;
        _error = 'Capture failed: $e';
      });
    }
  }

  Future<void> _skipCurrent() async {
    await _service.disposeCamera();
    if (_index < _backCameras.length - 1) {
      setState(() {
        _index++;
        _error = null;
      });
      await _openCurrent();
    } else {
      setState(() => _finished = true);
    }
  }

  @override
  void dispose() {
    _service.disposeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      appBar: AppBar(
        backgroundColor: CaptureColors.void_,
        foregroundColor: CaptureColors.silverBright,
        title: const Text('Lens Probe'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onClose,
        ),
      ),
      body: SafeArea(
        child: _finished ? _buildReview() : _buildCaptureStep(),
      ),
    );
  }

  Widget _buildCaptureStep() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  style: CaptureTypography.body
                      .copyWith(color: CaptureColors.silverBright),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              CaptureButton(
                label: 'Skip this camera',
                leadingIcon: Icons.skip_next,
                onPressed: _skipCurrent,
              ),
            ],
          ),
        ),
      );
    }
    if (_loading || !_service.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }
    final lens = _currentLensInfo;
    final ext = _currentExtensionInfo;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Camera $_currentId  (${_index + 1} of ${_backCameras.length})',
                style: CaptureTypography.h2
                    .copyWith(color: CaptureColors.silverBright),
              ),
              const SizedBox(height: 6),
              if (lens != null)
                Text(
                  'focal ${lens['focalLengthMm']}mm  ·  sensor '
                  '${lens['sensorWidthMm']}×${lens['sensorHeightMm']}mm'
                  '${(lens['hasOwnFlash'] == true) ? '  ·  has flash' : ''}',
                  style: CaptureTypography.body
                      .copyWith(color: CaptureColors.silverBright.withOpacity(0.8)),
                )
              else
                Text('lens characteristics unavailable',
                    style: CaptureTypography.body
                        .copyWith(color: CaptureColors.silverBright.withOpacity(0.6))),
              const SizedBox(height: 4),
              Text(
                ext == null
                    ? 'extension support: unknown'
                    : (ext['supportsMacro'] == true)
                        ? 'extension support: MACRO (formal Camera2 Extension)'
                        : 'extension support: no formal macro extension'
                            '${ext['extensionsApiAvailable'] == false ? ' (API unavailable)' : ''}',
                style: CaptureTypography.body.copyWith(
                  color: (ext?['supportsMacro'] == true)
                      ? Colors.amberAccent
                      : CaptureColors.silverBright.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CameraPreview(_service.controller!),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: CaptureButton(
                  label: 'Skip',
                  leadingIcon: Icons.skip_next,
                  variant: CaptureButtonVariant.ghost,
                  onPressed: _capturing ? null : _skipCurrent,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: CaptureButton(
                  label: _capturing ? 'Capturing…' : 'Capture this camera',
                  leadingIcon: Icons.camera_alt,
                  onPressed: _capturing ? null : _captureAndAdvance,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReview() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Captured ${_captured.length} camera(s). Compare each against a '
            "photo taken with your stock camera app's Macro mode -- the "
            'one with matching field-of-view/close-focus behaviour is the '
            'real macro lens.',
            style: CaptureTypography.body
                .copyWith(color: CaptureColors.silverBright),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _captured.length,
            itemBuilder: (context, i) {
              final c = _captured[i];
              final lens = c.lensInfo;
              final ext = c.extensionInfo;
              return Card(
                color: Colors.white10,
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Camera ${c.description.name}',
                          style: CaptureTypography.h2.copyWith(
                              color: CaptureColors.silverBright, fontSize: 18)),
                      const SizedBox(height: 4),
                      if (lens != null)
                        Text(
                          'focal ${lens['focalLengthMm']}mm  ·  sensor '
                          '${lens['sensorWidthMm']}×${lens['sensorHeightMm']}mm',
                          style: CaptureTypography.body.copyWith(
                              color:
                                  CaptureColors.silverBright.withOpacity(0.7)),
                        ),
                      if (ext?['supportsMacro'] == true)
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Text('Formal Camera2 EXTENSION_MACRO support',
                              style: TextStyle(
                                  color: Colors.amberAccent, fontSize: 13)),
                        ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(c.bytes, fit: BoxFit.contain),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: CaptureButton(
            label: 'Done',
            leadingIcon: Icons.check,
            onPressed: widget.onClose,
          ),
        ),
      ],
    );
  }
}
