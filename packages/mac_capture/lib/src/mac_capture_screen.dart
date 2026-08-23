import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'capture_colors.dart';
import 'capture_typography.dart';
import 'capture_button.dart';
import 'camera_service.dart';
import 'capture_uploader.dart';
import 'multi_angle_capture_controller.dart';
import 'spatial_anchor_service.dart';
import 'thumb_angle_service.dart';
import 'angle_progress_circles.dart';
import 'capture_guidance_overlay.dart';
import 'capture_intro_animation.dart';
import 'capture_vignette_overlay.dart';
import 'distance_guidance_widget.dart';
import 'focus_meter_widget.dart';
import 'haptic_guidance_circle.dart';
import 'lighting_meter_widget.dart';
import 'spatial_anchor_overlay.dart';

// ---------------------------------------------------------------------------
// Thumb-rotation capture screen. Full-bleed camera preview with overlay
// guidance: lighting/focus meters, a central haptic guidance circle, the
// 4-angle progress row, and an intro animation. Capture is driven by
// MultiAngleCaptureController (thumb angle from TFLite hand detection — the
// IMU is no longer the capture axis).
//
// This screen has no built-in backend or navigation: the host app supplies
// a [CaptureUploader] and the four callbacks below, so this package has zero
// dependency on any specific auth/routing/backend stack.
// ---------------------------------------------------------------------------

class MacCaptureScreen extends ConsumerStatefulWidget {
  const MacCaptureScreen({
    super.key,
    required this.uploader,
    required this.getUserId,
    required this.onRequireLogin,
    required this.onComplete,
    required this.onQueued,
    required this.onClose,
    this.showDebugHud = false,
  });

  /// Backend that persists a finished capture (Firebase, or anything else).
  final CaptureUploader uploader;

  /// Returns the current authenticated user's ID, or null if signed out.
  final String? Function() getUserId;

  /// Called when [getUserId] returns null right as capture is about to
  /// start — the host app should navigate to its login flow.
  final VoidCallback onRequireLogin;

  /// Called once the capture finishes uploading successfully, with the
  /// resulting capture ID.
  final void Function(String captureId) onComplete;

  /// Called when the capture couldn't upload (e.g. offline) and was saved
  /// to the local retry queue instead, with the resulting capture ID.
  final void Function(String captureId) onQueued;

  /// Called when the user backs out of the screen before/without capturing.
  final VoidCallback onClose;

  /// Shows a live readout of the values behind the axis/CV gates (gyro
  /// magnitude, CV confidence + prediction, distance to target, focus,
  /// lighting) in the top-left corner. Off by default — for internal test
  /// builds diagnosing capture-firing issues, not end users.
  final bool showDebugHud;

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
        // Full sensor resolution: the backend SFM/NFIQ pipeline works from raw
        // Y-plane frames (not downscaled JPEGs), so more source detail
        // directly improves reconstruction and NFIQ score. This costs more
        // per-frame CPU in the live preprocessing loop (Laplacian scoring,
        // TFLite hand detection) than the previous 1080p cap -- if that
        // becomes a smoothness problem worth trading back, revisit here.
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
    final userId = widget.getUserId();
    if (userId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Session expired — please log in again.'),
          backgroundColor: CaptureColors.error,
        ));
        widget.onRequireLogin();
      }
      return;
    }
    final cam = _camera;
    if (cam == null) return;
    SpatialAnchorService.resetSession(); // fresh leader-line state per session
    await ref.read(multiAngleCaptureControllerProvider).startCaptureSequence(
          camera: cam,
          uploadService: widget.uploader,
          userId: userId,
          sensorOrientation: _sensorOrientation,
        );
  }

  void _close() => widget.onClose();

  void _onStateChanged(CaptureSessionState s) {
    if (_navigated) return;
    if (s.captureId == null) return;
    if (s.phase == CapturePhase.complete) {
      _navigated = true;
      widget.onComplete(s.captureId!);
    } else if (s.phase == CapturePhase.queued) {
      _navigated = true;
      widget.onQueued(s.captureId!);
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
                  Icon(Icons.flashlight_on_rounded, color: CaptureColors.gold, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Flash ready — fires automatically on each capture',
                      style: TextStyle(color: CaptureColors.silverBright, fontSize: 13),
                    ),
                  ),
                ],
              ),
              backgroundColor: CaptureColors.steel,
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
        backgroundColor: CaptureColors.void_,
        body: Center(
          child: CircularProgressIndicator(color: CaptureColors.cyan),
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
      backgroundColor: CaptureColors.void_,
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

              // Layer 1a: vignette — smoothly fades the background to black
              // so only the centred thumb region is visible, both as a
              // framing cue for the user and to visually reinforce keeping
              // busy backgrounds out of the shot. Shown whenever the guide
              // circle itself would be shown.
              if (phase == CapturePhase.capturing ||
                  phase == CapturePhase.angleComplete ||
                  phase == CapturePhase.awaitingStart ||
                  phase == CapturePhase.calibrating)
                const Positioned.fill(
                  child: RepaintBoundary(child: CaptureVignetteOverlay()),
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
                            if (s.distanceToTarget < 180.0)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: AngleDegreeText(
                                  distanceToTarget: s.distanceToTarget,
                                  isLocked: s.distanceToTarget <= 5,
                                ),
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
                            color: CaptureColors.success
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: CaptureColors.success
                                  .withValues(alpha: 0.40),
                            ),
                          ),
                          child: Text(
                            'Last angle!',
                            style: CaptureTypography.label.copyWith(
                              fontSize: 15,
                              color: CaptureColors.success,
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
                        'Place your thumb in front of the camera. Keep your '
                        'body still — move only the phone.',
                        textAlign: TextAlign.center,
                        style: CaptureTypography.body.copyWith(
                          fontSize: 14,
                          color: CaptureColors.silverBright,
                        ),
                      ),
                      const SizedBox(height: 20),
                      CaptureButton(
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
                          color: CaptureColors.cyan),
                      const SizedBox(height: 16),
                      Text(
                        'Calibrating…',
                        style:
                            CaptureTypography.h2.copyWith(fontSize: 17),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Hold your thumb flat, pad facing the camera',
                        textAlign: TextAlign.center,
                        style: CaptureTypography.body
                            .copyWith(fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      // This is the exact moment the orientation reference is
                      // zeroed (DeviceOrientationService.captureReference()) —
                      // if the user's body turns right now, every angle read
                      // for the rest of the session is thrown off, since the
                      // gyro can't tell "phone tilted relative to thumb" apart
                      // from "phone and thumb both turned together with the body."
                      Text(
                        'Stay still — don\'t turn your body, only the phone moves',
                        textAlign: TextAlign.center,
                        style: CaptureTypography.body.copyWith(
                          fontSize: 12,
                          color: CaptureColors.silverDim,
                        ),
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
                        style: CaptureTypography.label.copyWith(
                          fontSize: 13,
                          color: CaptureColors.silverBright,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(
                        backgroundColor: CaptureColors.steelMuted,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            CaptureColors.cyan),
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
                          color: CaptureColors.cyan),
                      const SizedBox(height: 16),
                      Text(
                        'Uploading…',
                        style: CaptureTypography.body.copyWith(
                          color: CaptureColors.silverBright,
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
                      color: CaptureColors.silverBright, size: 22),
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

              // Layer 10: debug HUD — internal test builds only.
              if (widget.showDebugHud)
                Positioned(
                  top: 48,
                  left: 48,
                  child: Consumer(
                    builder: (_, ref, __) {
                      final s = ref
                          .watch(multiAngleCaptureControllerProvider)
                          .state;
                      return _buildDebugHud(s);
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
    final dotColor = locked ? CaptureColors.success : CaptureColors.cyan;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: CaptureColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CaptureColors.cyanBorder),
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
            style: CaptureTypography.label.copyWith(
              fontSize: 13,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (next != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward,
                size: 12, color: CaptureColors.silverDim),
            const SizedBox(width: 8),
            Text(
              next,
              style: CaptureTypography.label.copyWith(
                fontSize: 12,
                color: CaptureColors.silverDim,
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

    final iconColor = isActive ? CaptureColors.gold : CaptureColors.silverDim;
    final pillBg = isActive
        ? CaptureColors.gold.withValues(alpha: 0.15)
        : CaptureColors.cardBg;
    final pillBorder = isActive
        ? CaptureColors.gold.withValues(alpha: 0.45)
        : CaptureColors.silverDim.withValues(alpha: 0.28);
    final pillTextColor = isActive ? CaptureColors.gold : CaptureColors.silverDim;
    final pillLabel = isActive ? 'FLASH AUTO' : 'FLASH';

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: pillBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: pillBorder),
        boxShadow: isActive
            ? [BoxShadow(color: CaptureColors.gold.withValues(alpha: 0.18), blurRadius: 6)]
            : null,
      ),
      child: Text(
        pillLabel,
        style: CaptureTypography.label.copyWith(
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

  /// Raw values behind the axis/CV gates — see [MacCaptureScreen.showDebugHud].
  Widget _buildDebugHud(CaptureSessionState s) {
    String row(String label, String value) => '$label: $value';
    final lines = <String>[
      row('angle', s.currentAngleIndex < ThumbAngleService.order.length
          ? ThumbAngleService.order[s.currentAngleIndex]
          : '?'),
      row('dist°', s.distanceToTarget.toStringAsFixed(1)),
      row('gyro', s.gyroMagnitude.toStringAsFixed(3)),
      row('cv', s.cvPredictedAngle == null
          ? '—'
          : '${s.cvPredictedAngle} ${(s.cvConfidence ?? 0).toStringAsFixed(2)}'),
      row('focus', s.focusValue.toStringAsFixed(2)),
      row('light', s.lightingValue.toStringAsFixed(2)),
      row('green', '${s.axisGreenFrames}/5'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(
              line,
              style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
        ],
      ),
    );
  }

  Widget _cameraLayer() {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      return const ColoredBox(color: CaptureColors.void_);
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
      color: CaptureColors.void_.withValues(alpha: 0.92),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: CaptureColors.error, size: 44),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: CaptureTypography.body.copyWith(fontSize: 14),
            ),
            const SizedBox(height: 22),
            CaptureButton(
              label: 'Back',
              variant: CaptureButtonVariant.ghost,
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: SafeArea(child: _errorOverlay('Camera error: $message')),
    );
  }
}
