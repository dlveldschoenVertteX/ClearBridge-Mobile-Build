import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

class CameraService {
  CameraController? _controller;
  CameraController? _pendingController;
  List<CameraDescription>? _cameras;
  CameraDescription? _selectedCamera;
  bool _isStreaming = false;
  bool _isProcessingStreamFrame = false;
  bool _isDisposing = false;
  Future<void>? _pendingInitialization;
  Timer? _periodicFocusTimer;

  CameraController? get controller => _controller;
  CameraDescription? get selectedCamera => _selectedCamera;
  bool get isInitialized =>
      _controller != null && _controller!.value.isInitialized;
  bool get isStreamingImages => _isStreaming;

  Future<List<CameraDescription>> getAvailableCameras() async {
    _cameras ??= await availableCameras();
    return List<CameraDescription>.unmodifiable(_cameras!);
  }

  /// Initializes the camera with the given [lensDirection].
  /// Default is [CameraLensDirection.back].
  ///
  /// [fps]/[videoBitrate] (burst+video hybrid capture, Phase 0, 2026-08-02):
  /// real, plugin-supported `CameraController` constructor params (confirmed
  /// against the `camera` package's own changelog -- "Adds support to
  /// control video fps and bitrate", v0.10.6+) for whoever later calls
  /// [startVideoRecording]. Unlike manual exposure control (see
  /// docs/LOCKED_SHUTTER_SPEED_SCOPE.md), this is NOT a Camera2Interop gap --
  /// it's a supported public API, just never previously wired up since
  /// nothing in this app called startVideoRecording until now. Harmless to
  /// pass even when the caller never records video (photo-only capture
  /// ignores them). Codec (H.264 vs H.265/HEVC) and true constant-bitrate
  /// enforcement are NOT controllable through this plugin -- the platform
  /// picks the codec; [videoBitrate] is a target, not a hard guarantee.
  Future<void> initializeCamera({
    CameraLensDirection lensDirection = CameraLensDirection.back,
    ResolutionPreset resolution = ResolutionPreset.max,
    CameraDescription? cameraDescription,
    int? fps,
    int? videoBitrate,
  }) async {
    // Budget devices (e.g. CameraX capability negotiation at
    // ResolutionPreset.max on a cold HAL start) occasionally exceed a single
    // 10s attempt without the hardware actually being unavailable -- retry
    // once with a longer budget before surfacing a hard failure to the user.
    try {
      await _initializeCameraAttempt(
        lensDirection: lensDirection,
        resolution: resolution,
        cameraDescription: cameraDescription,
        fps: fps,
        videoBitrate: videoBitrate,
        timeout: const Duration(seconds: 12),
      );
    } on TimeoutException {
      debugPrint('CameraService: First init attempt timed out, retrying once');
      try {
        await _initializeCameraAttempt(
          lensDirection: lensDirection,
          resolution: resolution,
          cameraDescription: cameraDescription,
          fps: fps,
          videoBitrate: videoBitrate,
          timeout: const Duration(seconds: 20),
        );
      } on TimeoutException {
        throw Exception('Camera initialization timed out');
      }
    }
  }

  Future<void> _initializeCameraAttempt({
    required CameraLensDirection lensDirection,
    required ResolutionPreset resolution,
    required CameraDescription? cameraDescription,
    required Duration timeout,
    int? fps,
    int? videoBitrate,
  }) async {
    try {
      // Get available cameras if not already fetched
      _cameras ??= await availableCameras();

      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception('No cameras found on device');
      }

      final camera =
          cameraDescription ??
          _selectPreferredCamera(lensDirection);
      await disposeCamera();

      final controller = CameraController(
        camera,
        resolution,
        enableAudio: false,
        fps: fps,
        videoBitrate: videoBitrate,
      );
      _pendingController = controller;
      debugPrint(
        'CameraService: Using camera ${camera.name} '
        '(direction=${camera.lensDirection}, type=${camera.lensType})',
      );

      _pendingInitialization = controller.initialize().timeout(timeout);

      await _pendingInitialization;

      // Samsung CameraX (A14 and similar) needs a brief settle period after
      // initialize() returns before the first frame is reliably available.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      if (!identical(_pendingController, controller)) {
        await _disposeController(controller);
        return;
      }

      _controller = controller;
      _selectedCamera = camera;
      _pendingController = null;
      _pendingInitialization = null;

      await _configureCaptureController();
    } catch (e) {
      final pendingController = _pendingController;
      _pendingController = null;
      _pendingInitialization = null;
      if (pendingController != null) {
        await _disposeController(pendingController);
      }
      debugPrint('CameraService: Error initializing camera: $e');
      rethrow;
    }
  }

  /// Captures a photo and returns the [XFile].
  Future<XFile> captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      throw Exception('CameraService: Camera not initialized');
    }

    if (_controller!.value.isTakingPicture) {
      throw Exception('CameraService: Camera is already taking a picture');
    }

    try {
      if (_isStreaming) {
        await stopImageStream();
      }
      await _prepareCenterFocus();
      return await _controller!.takePicture();
    } catch (e) {
      debugPrint('CameraService: Error capturing image: $e');
      rethrow;
    }
  }

  Future<void> startVideoRecording({bool requirePreviewStream = false}) async {
    if (_controller == null || !_controller!.value.isInitialized) {
      throw Exception('CameraService: Camera not initialized');
    }

    if (_controller!.value.isRecordingVideo) {
      throw Exception('CameraService: Video recording already in progress');
    }

    try {
      await _prepareCenterFocus();
      await _controller!.startVideoRecording();
    } catch (e) {
      if (_isStreaming) {
        debugPrint(
          'CameraService: Video recording while streaming failed, retrying without stream: $e',
        );
        if (requirePreviewStream) {
          // Caller needs preview frames (thumb monitoring) during recording.
          rethrow;
        }
        await stopImageStream();
        await _prepareCenterFocus();
        await _controller!.startVideoRecording();
        return;
      }
      debugPrint('CameraService: Error starting video recording: $e');
      rethrow;
    }
  }

  Future<XFile> stopVideoRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      throw Exception('CameraService: Camera not initialized');
    }

    if (!_controller!.value.isRecordingVideo) {
      throw Exception('CameraService: No active video recording');
    }

    try {
      return await _controller!.stopVideoRecording();
    } catch (e) {
      debugPrint('CameraService: Error stopping video recording: $e');
      rethrow;
    }
  }

  Future<void> startImageStream(void Function(CameraImage image) onAvailable) async {
    if (_controller == null || !_controller!.value.isInitialized) {
      throw Exception('CameraService: Camera not initialized');
    }

    // If already streaming, stop first to avoid CameraX conflicts
    if (_isStreaming) {
      await stopImageStream();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    _isStreaming = true;
    _isProcessingStreamFrame = false;

    try {
      await _controller!.startImageStream((image) {
        if (!_isStreaming || _isProcessingStreamFrame) {
          return;
        }

        _isProcessingStreamFrame = true;
        try {
          // Process synchronously and do not retain the image beyond this callback,
          // so CameraX can release the frame buffer immediately.
          onAvailable(image);
        } on AssertionError catch (error) {
          // CameraX Analyzer null assertion — stop stream safely
          debugPrint(
            'CameraService: CameraX assertion in callback — stopping stream: $error',
          );
          _isStreaming = false;
        } catch (error) {
          debugPrint(
            'CameraService: Error processing preview frame: $error',
          );
        } finally {
          _isProcessingStreamFrame = false;
        }
      });
    } on AssertionError catch (error) {
      // CameraX throws AssertionError when Analyzer setup fails
      _isStreaming = false;
      _isProcessingStreamFrame = false;
      debugPrint('CameraService: CameraX assertion on stream start: $error');
      rethrow;
    } catch (error) {
      _isStreaming = false;
      _isProcessingStreamFrame = false;
      debugPrint('CameraService: Error starting image stream: $error');
      rethrow;
    }
  }

  Future<void> stopImageStream() async {
    if (_controller == null || !_isStreaming) return;

    _isStreaming = false;
    _isProcessingStreamFrame = false;

    try {
      await _controller!.stopImageStream();
    } catch (error) {
      debugPrint('CameraService: Error stopping image stream: $error');
    }
  }

  /// Disposes the camera controller safely.
  Future<void> disposeCamera() async {
    if (_isDisposing) return;

    _isDisposing = true;
    try {
      stopPeriodicFocusLock();
      final activeController = _controller;
      final pendingController = _pendingController;
      final pendingInitialization = _pendingInitialization;

      if (activeController == null && pendingController == null) {
        return;
      }

      _controller = null;
      _selectedCamera = null;
      _pendingController = null;
      _pendingInitialization = null;
      _isStreaming = false;
      _isProcessingStreamFrame = false;

      if (pendingController != null) {
        try {
          await pendingInitialization;
        } catch (_) {}

        if (!identical(pendingController, activeController)) {
          await _disposeController(pendingController);
        }
      }

      if (activeController != null) {
        await _disposeController(activeController);
      }
    } finally {
      _isDisposing = false;
    }
  }

  Future<void> _configureCaptureController() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    // Keep autofocus live during the preview / intro animation so the lens
    // isn't locked onto the background when the user presents their thumb.
    // The capture controller re-triggers AF and locks it after calibration.
    try {
      await _controller!.setFocusPoint(const Offset(0.5, 0.5));
    } catch (error) {
      debugPrint('CameraService: Focus point not available: $error');
    }
    try {
      await _controller!.setFocusMode(FocusMode.auto);
    } catch (error) {
      debugPrint('CameraService: Focus auto not available: $error');
    }
    try {
      await _controller!.setExposurePoint(const Offset(0.5, 0.5));
    } catch (error) {
      debugPrint('CameraService: Exposure point not available: $error');
    }
    // NOTE: setExposureMode() is intentionally NOT called here. On the CameraX
    // backend it engages Camera2 interop (Camera2CameraControl) on the live
    // session, which then persists for the whole session and blocks the torch
    // (CameraControl.enableTorch) from firing during the flash sub-burst. The
    // default exposure mode is already auto, so this call was redundant anyway.
  }

  /// Best-effort lock of focus/exposure to reduce "pumping" (visible shaking)
  /// while the user holds their thumb steady.
  Future<void> enableCaptureLock() async {
    stopPeriodicFocusLock(); // periodic re-anchor must stop before locking
    if (_controller == null || !_controller!.value.isInitialized) return;

    // Set points first, then attempt to lock.
    await _prepareCenterFocus();

    try {
      await _controller!.setFocusMode(FocusMode.locked);
    } catch (error) {
      debugPrint('CameraService: Focus lock not available: $error');
    }

    // NOTE: AE lock is intentionally omitted. setExposureMode() on the CameraX
    // backend engages Camera2 interop that persists on the session and blocks
    // the torch (enableTorch) from firing. Focus lock alone is enough to stop
    // visible pumping; exposure stability is handled via the EV offset.
  }

  /// Starts a 2.5-second periodic re-anchor of focus/exposure to the centre.
  /// Stops the hardware AF from hunting to background when the thumb is held
  /// still for several seconds (Helio G99 / CameraX FocusMode.auto drifts).
  /// Call [stopPeriodicFocusLock] before triggering a capture burst.
  void startPeriodicFocusLock() {
    _periodicFocusTimer?.cancel();
    _periodicFocusTimer = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => _prepareCenterFocus(),
    );
  }

  void stopPeriodicFocusLock() {
    _periodicFocusTimer?.cancel();
    _periodicFocusTimer = null;
  }

  Future<void> disableCaptureLock() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      await _controller!.setFocusMode(FocusMode.auto);
    } catch (error) {
      debugPrint('CameraService: Focus auto not available: $error');
    }

    // NOTE: setExposureMode() intentionally omitted — see enableCaptureLock /
    // _configureCaptureController. Engaging Camera2 interop on the CameraX
    // backend blocks the torch from firing during capture bursts.
  }

  Future<void> _prepareCenterFocus() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      await _controller!.setFocusPoint(const Offset(0.5, 0.5));
    } catch (error) {
      debugPrint('CameraService: Focus point not available: $error');
    }

    try {
      await _controller!.setExposurePoint(const Offset(0.5, 0.5));
    } catch (error) {
      debugPrint('CameraService: Exposure point not available: $error');
    }

    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  CameraDescription _selectPreferredCamera(CameraLensDirection lensDirection) {
    final matching = _cameras!
        .where((camera) => camera.lensDirection == lensDirection)
        .toList();

    if (matching.isEmpty) {
      return _cameras!.first;
    }

    if (lensDirection != CameraLensDirection.back) {
      return matching.first;
    }

    final preferredWide = matching.where((camera) {
      final name = camera.name.toLowerCase();
      return camera.lensType == CameraLensType.wide ||
          name.contains('wide') ||
          name.contains('main') ||
          name.contains('default');
    }).toList();

    if (preferredWide.isNotEmpty) {
      return preferredWide.first;
    }

    return matching.first;
  }

  // Real ANR reported 2026-08-11: "ClearBridge Beta isn't responding" on the
  // static BetaThankYouScreen, right after a successful capture -- a screen
  // with no polling/listeners of its own (StatelessWidget, plain
  // buttons), so the hang had to be residual background work from the
  // capture flow it navigated away from. front_capture_screen.dart's own
  // dispose() calls disposeCamera() fire-and-forget (State.dispose() can't
  // be async), which was fine -- but the two native platform-channel calls
  // this eventually reaches, controller.stopImageStream() and
  // controller.dispose(), were both RAW unbounded awaits with zero timeout
  // protection -- the exact same risk category this project has already
  // found and fixed repeatedly elsewhere (secondary-camera capture,
  // distance-sweep bursts, the sweep-burst zone sequence), just never
  // applied to the disposal path itself. If the native Camera2 teardown
  // genuinely hangs or is slow under contention right after a multi-shot
  // burst + uploads (plausible, matching this project's own documented
  // history of camera-session-teardown ANRs), nothing here could ever
  // recover -- the await just never returns. Bounded the same way every
  // other unbounded native camera call in this codebase already is.
  static const Duration _disposeCallTimeout = Duration(seconds: 5);

  Future<void> _disposeController(CameraController controller) async {
    try {
      if (controller.value.isStreamingImages) {
        try {
          await controller.stopImageStream().timeout(_disposeCallTimeout);
        } catch (error) {
          debugPrint('CameraService: Error/timeout stopping image stream: $error');
        }
      }

      await controller.dispose().timeout(_disposeCallTimeout);
      debugPrint('CameraService: Camera disposed');
    } catch (error) {
      debugPrint('CameraService: Error/timeout disposing controller: $error');
    }
  }
}
