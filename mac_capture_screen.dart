import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/clearbridge_colors.dart';
import '../../../core/theme/clearbridge_typography.dart';
import '../../../core/widgets/cb_ui.dart';
import '../services/camera_service.dart';
import '../services/fingerprint_frame_upload_service.dart';
import '../services/multi_angle_capture_controller.dart';
import '../services/spatial_anchor_service.dart';
import '../services/thumb_angle_service.dart';
import '../widgets/angle_progress_circles.dart';
import '../widgets/capture_guidance_overlay.dart';
import '../widgets/capture_intro_animation.dart';
import '../widgets/distance_guidance_widget.dart';
import '../widgets/focus_meter_widget.dart';
import '../widgets/haptic_guidance_circle.dart';
import '../widgets/lighting_meter_widget.dart';
import '../widgets/spatial_anchor_overlay.dart';

// ---------------------------------------------------------------------------
// Thumb-rotation capture screen (routed at /fingerprint + /continuous-capture).
// Full-bleed camera preview with overlay guidance: lighting/focus meters, a
// central haptic guidance circle, the 4-angle progress row, and an intro
// animation. Capture is driven by MultiAngleCaptureController (thumb angle from
// MediaPipe — the IMU is no longer the capture axis).
// ---------------------------------------------------------------------------

class MacCaptureScreen extends ConsumerStatefulWidget {
  const MacCaptureScreen({super.key});

  @override
  ConsumerState<MacCaptureScreen> createState() => _MacCaptureScreenState();
}

class _MacCaptureScreenState extends ConsumerState<MacCaptureScreen> {
  final CameraService _cameraService = CameraService();
  int _sensorOrientation = 0;
  bool _ready = false;
  bool _navigated = false;
  String? _initError;

  CameraController? get _camera => _cameraService.controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _cameraService.initializeCamera(
        lensDirection: CameraLensDirection.back,
        resolution: ResolutionPreset.max,
      );
      if (!mounted) return;
      _sensorOrientation = _cameraService.selectedCamera?.sensorOrientation ?? 0;
      setState(() => _ready = true);
      ref.read(multiAngleCaptureControllerProvider).startIntro();
    } catch (e) {
      if (mounted) setState(() => _initError = '$e');
    }
  }

  @override
  void dispose() {
    _cameraService.disposeCamera();
    super.dispose();
  }

  Future<void> _onStart() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Session expired — please log in again.'),
          backgroundColor: ClearBridgeColors.error,
        ));
        context.go(AppConstants.loginRoute);
      }
      return;
    }
    final cam = _camera;
    if (cam == null) return;
    SpatialAnchorService.resetSession(); // fresh leader-line state per session
    await ref.read(multiAngleCaptureControllerProvider).startCaptureSequence(
          camera: cam,
          uploadService: ref.read(fingerprintFrameUploadServiceProvider),
          userId: user.uid,
          sensorOrientation: _sensorOrientation,
        );
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppConstants.dashboardRoute);
    }
  }

  void _onStateChanged(CaptureSessionState s) {
    if (_navigated) return;
    if (s.captureId == null) return;
    if (s.phase == CapturePhase.complete) {
      _navigated = true;
      context.go('/capture/result', extra: s.captureId);
    } else if (s.phase == CapturePhase.queued) {
      _navigated = true;
      context.go('/capture/result',
          extra: {'captureId': s.captureId, 'queued': true});
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<MultiAngleCaptureController>(
      multiAngleCaptureControllerProvider,
      (_, next) => _onStateChanged(next.state),
    );

    // Show a one-shot banner when the camera calibration detects dark conditions.
    ref.listen<bool>(
      multiAngleCaptureControllerProvider.select((c) => c.state.isNightMode),
      (prev, next) {
        if (next && prev == false && mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.flashlight_on_rounded, color: ClearBridgeColors.gold, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Flash ready — fires automatically on each capture',
                      style: TextStyle(color: ClearBridgeColors.silverBright, fontSize: 13),
                    ),
                  ),
                ],
              ),
              backgroundColor: ClearBridgeColors.steel,
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ));
        }
      },
    );

    if (_initError != null) {
      return _errorScaffold(_initError!);
    }
    if (!_ready) {
      return const Scaffold(
        backgroundColor: ClearBridgeColors.void_,
        body: Center(
          child: CircularProgressIndicator(color: ClearBridgeColors.cyan),
        ),
      );
    }

    // Watch only phase — drives structural widget-tree changes (rare).
    // High-frequency values (meters, distance) are owned by Consumer widgets
    // so only those leaves rebuild on every controller notification.
    final phase = ref.watch(
      multiAngleCaptureControllerProvider.select((c) => c.state.phase),
    );

    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final previewSize = constraints.biggest;

          return Stack(
            children: [
              // Layer 1: camera preview — RepaintBoundary prevents the texture
              // from being invalidated by overlay rebuilds.
              Positioned.fill(
                child: RepaintBoundary(child: _cameraLayer()),
              ),

              // Layer 1b: spatial anchors — Consumer subscribes per-frame during
              // active capture; RepaintBoundary isolates ripple animations.
              if (phase == CapturePhase.capturing ||
                  phase == CapturePhase.angleComplete)
                Positioned.fill(
                  child: RepaintBoundary(
                    child: Consumer(
                      builder: (_, ref, __) {
                        final s = ref
                            .watch(multiAngleCaptureControllerProvider)
                            .state;
                        if (s.cameraImageSize == null ||
                            s.landmarks.length < 21) {
                          return const SizedBox.shrink();
                        }
                        final anchors = SpatialAnchorService.compute(
                          landmarks: s.landmarks,
                          cameraImageSize: s.cameraImageSize!,
                          previewWidgetSize: previewSize,
                          capturedAngles: _capturedKeys(s.anglesComplete),
                          currentAngleKey:
                              ThumbAngleService.order[s.currentAngleIndex],
                          distanceToTarget: s.distanceToTarget,
                        );
                        if (anchors.isEmpty) return const SizedBox.shrink();
                        return SpatialAnchorOverlay(
                            anchors: anchors, previewSize: previewSize);
                      },
                    ),
                  ),
                ),

              // Layer 2: lighting meter — select isolates rebuilds to this widget.
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: RepaintBoundary(
                  child: Center(
                    child: Consumer(
                      builder: (_, ref, __) {
                        final v = ref.watch(
                          multiAngleCaptureControllerProvider.select((c) => (
                            value: c.state.lightingValue,
                            locked: c.state.distanceToTarget <= 5,
                          )),
                        );
                        return AnimatedOpacity(
                          opacity: v.locked ? 0.2 : 1.0,
                          duration: const Duration(milliseconds: 300),
                          child: LightingMeterWidget(value: v.value),
                        );
                      },
                    ),
                  ),
                ),
              ),

              // Layer 3: focus meter.
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: RepaintBoundary(
                  child: Center(
                    child: Consumer(
                      builder: (_, ref, __) {
                        final v = ref.watch(
                          multiAngleCaptureControllerProvider.select((c) => (
                            value: c.state.focusValue,
                            locked: c.state.distanceToTarget <= 5,
                          )),
                        );
                        return AnimatedOpacity(
                          opacity: v.locked ? 0.2 : 1.0,
                          duration: const Duration(milliseconds: 300),
                          child: FocusMeterWidget(value: v.value),
                        );
                      },
                    ),
                  ),
                ),
              ),

              // Layer 4: haptic guidance circle + 4-axis guidance — visible from
              // awaitingStart onward so the ring is present before capture begins.
              // Consumer subscribes to per-frame distance/coverage values.
              if (phase == CapturePhase.capturing ||
                  phase == CapturePhase.angleComplete ||
                  phase == CapturePhase.awaitingStart ||
                  phase == CapturePhase.calibrating)
                Center(
                  child: RepaintBoundary(
                    child: Consumer(
                      builder: (_, ref, __) {
                        final s = ref
                            .watch(multiAngleCaptureControllerProvider)
                            .state;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                HapticGuidanceCircle(
                                  distanceToTarget: s.distanceToTarget,
                                  isLocked: s.distanceToTarget <= 5,
                                  isPulsing:
                                      s.phase == CapturePhase.angleComplete,
                                  isAtCorrectDistance:
                                      s.distanceToTarget >= 180.0 ||
                                          (s.thumbCoverageRatio >= 0.35 &&
                                              s.thumbCoverageRatio <= 0.85),
                                  rotationHint: _rotationHint(s),
                                  isRetrying: s.isRetrying,
                                ),
                                RotationProgressArc(
                                  distanceToTarget: s.distanceToTarget,
                                  axisGreenFrames: s.axisGreenFrames,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (s.guidanceMessage.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24),
                                child: CaptureGuidanceOverlay(
                                  message: s.guidanceMessage,
                                  isAllGreen: s.axisGreenFrames > 0,
                                  greenFraction: s.axisGreenFrames / 5.0,
                                ),
                              )
                            else if (s.distanceToTarget < 180.0)
                              DistanceGuidanceWidget(
                                  thumbCoverageRatio: s.thumbCoverageRatio),
                          ],
                        );
                      },
                    ),
                  ),
                ),

              // Layer 5: progress circles — Consumer for per-frame angle data.
              if (phase != CapturePhase.showingAnimation)
                Positioned(
                  bottom: 48,
                  left: 0,
                  right: 0,
                  child: Consumer(
                    builder: (_, ref, __) {
                      final s =
                          ref.watch(multiAngleCaptureControllerProvider).state;
                      return AngleProgressCircles(
                        currentAngleIndex: s.currentAngleIndex,
                        currentFillFraction:
                            (1.0 - (s.distanceToTarget / 20.0))
                                .clamp(0.0, 1.0),
                        anglesComplete: s.anglesComplete,
                        glowAll: s.allCirclesGlow,
                      );
                    },
                  ),
                ),

              // "Last angle!" banner — shown during the 600ms angleComplete pause
              // after the 3rd angle (top) fires, signalling the final angle is next.
              if (phase == CapturePhase.angleComplete)
                Positioned.fill(
                  child: Consumer(
                    builder: (_, ref, __) {
                      final s = ref
                          .watch(multiAngleCaptureControllerProvider)
                          .state;
                      if (s.currentAngleIndex != 2) return const SizedBox.shrink();
                      return Align(
                        alignment: const Alignment(0, -0.30),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 9),
                          decoration: BoxDecoration(
                            color: ClearBridgeColors.success
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: ClearBridgeColors.success
                                  .withValues(alpha: 0.40),
                            ),
                          ),
                          child: Text(
                            'Last angle!',
                            style: ClearBridgeTypography.label.copyWith(
                              fontSize: 15,
                              color: ClearBridgeColors.success,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

              // Layer 6: "Start Capture" button — only visible in awaitingStart.
              if (phase == CapturePhase.awaitingStart)
                Positioned(
                  left: 40,
                  right: 40,
                  bottom: 100,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Place your thumb in front of the camera',
                        textAlign: TextAlign.center,
                        style: ClearBridgeTypography.body.copyWith(
                          fontSize: 14,
                          color: ClearBridgeColors.silverBright,
                        ),
                      ),
                      const SizedBox(height: 20),
                      CbButton(
                        label: 'Start Capture',
                        leadingIcon: Icons.camera_alt_rounded,
                        onPressed: _onStart,
                      ),
                    ],
                  ),
                ),

              // Calibration prompt — autofocus + 0° baseline learning.
              if (phase == CapturePhase.calibrating)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                          color: ClearBridgeColors.cyan),
                      const SizedBox(height: 16),
                      Text(
                        'Calibrating…',
                        style:
                            ClearBridgeTypography.h2.copyWith(fontSize: 17),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Hold your thumb flat, pad facing the camera',
                        textAlign: TextAlign.center,
                        style: ClearBridgeTypography.body
                            .copyWith(fontSize: 13),
                      ),
                    ],
                  ),
                ),

              // Calibration progress bar — bottom of screen.
              if (phase == CapturePhase.calibrating)
                Positioned(
                  bottom: 80,
                  left: 40,
                  right: 40,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Preparing camera...',
                        textAlign: TextAlign.center,
                        style: ClearBridgeTypography.label.copyWith(
                          fontSize: 13,
                          color: ClearBridgeColors.silverBright,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(
                        backgroundColor: ClearBridgeColors.steelMuted,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            ClearBridgeColors.cyan),
                      ),
                    ],
                  ),
                ),

              // Layer 7: upload progress — only while uploading.
              if (phase == CapturePhase.uploading)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                          color: ClearBridgeColors.cyan),
                      const SizedBox(height: 16),
                      Text(
                        'Uploading…',
                        style: ClearBridgeTypography.body.copyWith(
                          color: ClearBridgeColors.silverBright,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),

              // Layer 8: intro animation — top layer, only during the intro.
              if (phase == CapturePhase.showingAnimation)
                Positioned.fill(
                  child: CaptureIntroAnimation(
                    onComplete: () => ref
                        .read(multiAngleCaptureControllerProvider)
                        .onAnimationComplete(),
                  ),
                ),

              // Error overlay.
              if (phase == CapturePhase.error)
                Positioned.fill(
                  child: Consumer(
                    builder: (_, ref, __) {
                      final err = ref.watch(
                        multiAngleCaptureControllerProvider
                            .select((c) => c.state.error),
                      );
                      return _errorOverlay(err ?? 'Capture failed');
                    },
                  ),
                ),

              // Layer 9: back arrow — always visible.
              Positioned(
                top: 48,
                left: 16,
                child: GestureDetector(
                  onTap: _close,
                  child: const Icon(Icons.arrow_back_ios,
                      color: ClearBridgeColors.silverBright, size: 22),
                ),
              ),

              // Live angle/zone caption: current → next.
              if (phase == CapturePhase.capturing ||
                  phase == CapturePhase.angleComplete)
                Positioned(
                  top: 96,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Consumer(
                      builder: (_, ref, __) {
                        final s = ref
                            .watch(multiAngleCaptureControllerProvider)
                            .state;
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          transitionBuilder: (child, animation) =>
                              SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0.25, 0),
                                  end: Offset.zero,
                                ).animate(CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOut,
                                )),
                                child: FadeTransition(
                                    opacity: animation, child: child),
                              ),
                          child: KeyedSubtree(
                            key: ValueKey(s.currentAngleIndex),
                            child: _buildAngleLabel(
                                s.currentAngleIndex, s.distanceToTarget <= 5),
                          ),
                        );
                      },
                    ),
                  ),
                ),

              // Flash status indicator + Night Mode badge + manual toggle — top-right.
              // Visible from awaitingStart so the user can enable flash before capture.
              if (phase == CapturePhase.awaitingStart ||
                  phase == CapturePhase.capturing ||
                  phase == CapturePhase.angleComplete ||
                  phase == CapturePhase.calibrating)
                Positioned(
                  top: 52,
                  right: 50,
                  child: Consumer(
                    builder: (_, ref, __) {
                      final s = ref
                          .watch(multiAngleCaptureControllerProvider)
                          .state;
                      return _buildFlashPanel(s);
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }


  /// Maps the [anglesComplete] flags to the set of completed angle keys,
  /// in ThumbAngleService order (front, left, top, right).
  Set<String> _capturedKeys(List<bool> anglesComplete) {
    final order = ThumbAngleService.order;
    return {
      for (var i = 0; i < order.length && i < anglesComplete.length; i++)
        if (anglesComplete[i]) order[i],
    };
  }

  /// Signed degrees remaining to the current target angle (-180..+180).
  /// Positive = rotate clockwise, negative = counter-clockwise.
  /// Returns null when there is no live thumb data or the angle is locked.
  double? _rotationHint(CaptureSessionState s) {
    if (s.distanceToTarget <= 5 || s.thumbAngleDegrees == 0.0) return null;
    final targetAngle =
        ThumbAngleService.targets[ThumbAngleService.order[s.currentAngleIndex]];
    if (targetAngle == null) return null;
    var diff = targetAngle - s.thumbAngleDegrees;
    while (diff > 180) {
      diff -= 360;
    }
    while (diff < -180) {
      diff += 360;
    }
    return diff;
  }

  /// Angle label pill: "● FRONT  →  LEFT" (dim next angle).
  Widget _buildAngleLabel(int angleIndex, bool locked) {
    final order = ThumbAngleService.order;
    final current = order[angleIndex].toUpperCase();
    final hasNext = angleIndex < order.length - 1;
    final next = hasNext ? order[angleIndex + 1].toUpperCase() : null;
    final dotColor = locked ? ClearBridgeColors.success : ClearBridgeColors.cyan;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: ClearBridgeColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ClearBridgeColors.cyanBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            current,
            style: ClearBridgeTypography.label.copyWith(
              fontSize: 13,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (next != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward,
                size: 12, color: ClearBridgeColors.silverDim),
            const SizedBox(width: 8),
            Text(
              next,
              style: ClearBridgeTypography.label.copyWith(
                fontSize: 12,
                color: ClearBridgeColors.silverDim,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Flash panel — shows FLASH AUTO (gold) when armed, FLASH (dim) while calibrating.
  /// Torch fires per burst window only — activates just before a burst and
  /// deactivates immediately after to avoid AE oscillation between angles.
  Widget _buildFlashPanel(CaptureSessionState s) {
    final isAutoNight = s.isNightMode;
    final isManualOn = s.manualFlashEnabled;
    final isActive = isAutoNight || isManualOn;

    final iconColor = isActive ? ClearBridgeColors.gold : ClearBridgeColors.silverDim;
    final pillBg = isActive
        ? ClearBridgeColors.gold.withValues(alpha: 0.15)
        : ClearBridgeColors.cardBg;
    final pillBorder = isActive
        ? ClearBridgeColors.gold.withValues(alpha: 0.45)
        : ClearBridgeColors.silverDim.withValues(alpha: 0.28);
    final pillTextColor = isActive ? ClearBridgeColors.gold : ClearBridgeColors.silverDim;
    final pillLabel = isActive ? 'FLASH AUTO' : 'FLASH';

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: pillBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: pillBorder),
        boxShadow: isActive
            ? [BoxShadow(color: ClearBridgeColors.gold.withValues(alpha: 0.18), blurRadius: 6)]
            : null,
      ),
      child: Text(
        pillLabel,
        style: ClearBridgeTypography.label.copyWith(
          fontSize: 9,
          color: pillTextColor,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );

    return SizedBox(
      width: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Icon(
              isActive ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
              key: ValueKey(isActive),
              color: iconColor,
              size: 22,
            ),
          ),
          const SizedBox(height: 4),
          pill,
        ],
      ),
    );
  }

  Widget _cameraLayer() {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      return const ColoredBox(color: ClearBridgeColors.void_);
    }
    final preview = cam.value.previewSize;
    // previewSize is reported in sensor (landscape) orientation; swap for the
    // portrait full-bleed cover fit.
    final w = preview?.height ?? cam.value.previewSize?.width ?? 1080;
    final h = preview?.width ?? cam.value.previewSize?.height ?? 1920;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: w,
        height: h,
        child: CameraPreview(cam),
      ),
    );
  }

  Widget _errorOverlay(String message) {
    return Container(
      color: ClearBridgeColors.void_.withValues(alpha: 0.92),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: ClearBridgeColors.error, size: 44),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: ClearBridgeTypography.body.copyWith(fontSize: 14),
            ),
            const SizedBox(height: 22),
            CbButton(
              label: 'Back',
              variant: CbButtonVariant.ghost,
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: ClearBridgeColors.void_,
      body: SafeArea(child: _errorOverlay('Camera error: $message')),
    );
  }
}
