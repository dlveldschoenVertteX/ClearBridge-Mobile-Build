/// Standalone MAC3D (Multi-Angle Capture) fingerprint capture flow.
///
/// Drop [MacCaptureScreen] into your navigation, implement [CaptureUploader]
/// against your backend, and supply the four callbacks it needs
/// (getUserId / onRequireLogin / onComplete / onQueued / onClose). Everything
/// else — camera control, quality gating, TFLite hand detection, guidance
/// UI, and the capture state machine — lives entirely inside this package.
library mac_capture;

export 'src/mac_capture_screen.dart' show MacCaptureScreen;

export 'src/arc_capture_uploader.dart' show ArcCaptureUploader;
export 'src/arc_sweep_capture_controller.dart'
    show
        ArcSweepCaptureController,
        ArcSweepPhase,
        ArcSweepState,
        arcSweepCaptureControllerProvider;
export 'src/arc_sweep_capture_screen.dart' show ArcSweepCaptureScreen;

export 'src/capture_uploader.dart'
    show CaptureUploader, CaptureNetworkException;

export 'src/multi_angle_capture_controller.dart'
    show
        MultiAngleCaptureController,
        CaptureSessionState,
        CapturePhase,
        multiAngleCaptureControllerProvider;

export 'src/multi_angle_capture.dart' show MultiAngleCapture, CaptureAngles;

export 'src/offline_capture_queue.dart'
    show
        OfflineCaptureQueue,
        PendingCapture,
        offlineCaptureQueueProvider,
        offlineMaxRetries;

export 'src/thumb_angle_service.dart' show ThumbAngleService;
export 'src/hand_types.dart';
export 'src/thumb_landmarker_service.dart' show ThumbLandmarkerService;
export 'src/thumb_orientation_classifier.dart'
    show ThumbOrientationClassifier, OrientationPrediction;

export 'src/camera_service.dart' show CameraService;
export 'src/still_jpeg_downscaler.dart'
    show DecodedStillLuma, decodeStillJpegToLuma, encodeGrayscaleJpeg;
export 'src/adaptive_flash_controller.dart' show AdaptiveFlashController;
export 'src/device_orientation_service.dart'
    show DeviceOrientationService, RelativeOrientation;
export 'src/frame_capture_service.dart'
    show TaggedFrame, HybridCaptureService;
export 'src/capture_axis_controller.dart'
    show CaptureAxisController, AxisEvaluationResult;
export 'src/spatial_anchor_service.dart' show SpatialAnchorService, ScreenAnchor;
export 'src/spatial_anchor_overlay.dart' show SpatialAnchorOverlay;

export 'src/angle_progress_circles.dart' show AngleProgressCircles;
export 'src/capture_guidance_overlay.dart'
    show CaptureGuidanceOverlay, RotationProgressArc, AngleDegreeText;
export 'src/capture_intro_animation.dart' show CaptureIntroAnimation;
export 'src/capture_vignette_overlay.dart' show CaptureVignetteOverlay;
export 'src/capture_reticle_overlay.dart'
    show CaptureReticleOverlay, ReticleState;
export 'src/capture_pad_silhouette_overlay.dart'
    show CapturePadSilhouetteOverlay, PadSilhouetteState, PadSilhouetteShape;
export 'src/distance_guidance_widget.dart' show DistanceGuidanceWidget;
export 'src/focus_meter_widget.dart' show FocusMeterWidget;
export 'src/haptic_guidance_circle.dart';
export 'src/lighting_meter_widget.dart' show LightingMeterWidget;

export 'src/capture_colors.dart' show CaptureColors;
export 'src/capture_typography.dart' show CaptureTypography;
export 'src/capture_button.dart' show CaptureButton, CaptureButtonVariant;
export 'src/capture_audio_service.dart' show CaptureAudioService;
