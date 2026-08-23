import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:google_fonts/google_fonts.dart';
import 'package:mac_capture/mac_capture.dart';

import 'front_capture_controller.dart';

/// Front-only fingerprint capture screen — MAC3D UX polish.
///
/// Layout: three-column while the guide is active (brightness meter |
/// 270×270 progress ring + oval guide | focus meter), with a status pill
/// in the header and guidance text below the ring.
class FrontCaptureScreen extends StatefulWidget {
  const FrontCaptureScreen({
    super.key,
    required this.getUserId,
    required this.onRequireLogin,
    required this.onComplete,
    required this.onClose,
  });

  final String? Function() getUserId;
  final VoidCallback onRequireLogin;
  final void Function(String captureId) onComplete;
  final VoidCallback onClose;

  @override
  State<FrontCaptureScreen> createState() => _FrontCaptureScreenState();
}

class _FrontCaptureScreenState extends State<FrontCaptureScreen>
    with TickerProviderStateMixin {
  final CameraService _cameraService = CameraService();
  late final FrontCaptureController _ctrl;
  late final AnimationController _scanAnim;
  // One-shot "pop" played on the guide outline the instant the primary burst
  // finishes (the mockup's successPop) -- see _onState's confirmationText
  // transition check below.
  late final AnimationController _popCtrl;
  late final Animation<double> _popScale;
  late final AnimationController _blinkCtrl;
  late final Animation<double> _blinkOpacity;
  late final AnimationController _distancePulseCtrl;
  late final Animation<double> _distancePulseOpacity;
  bool _ready = false;
  bool _navigated = false;
  String? _initError;

  // Locked at the moment the main burst begins so the focus meter stays
  // stable during shot-taking (flash alternation causes the peak-normalised
  // _focusValue to oscillate during the burst itself — cosmetically confusing
  // since the burst already started because focus was good). Cleared once
  // isCapturingBurst goes false.
  double? _lockedFocusValue;

  // Tracked purely to detect the false->true edge of the low-quality signal
  // (see _isLowQuality) so the warning haptic fires once on entry rather than
  // every rebuild, and to detect the confirmationText edge that triggers the
  // capture "pop".
  bool _wasLowQuality = false;
  String? _lastConfirmationText;

  CameraController? get _camera => _cameraService.controller;

  @override
  void initState() {
    super.initState();
    _ctrl = FrontCaptureController();
    _ctrl.addListener(_onState);
    // Not started here — driven by _onState so it only runs during active
    // shot-taking (not during the Processing… decode window, which is where
    // the 8× concurrent decodes happen and CPU headroom matters most).
    _scanAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _popCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      // Starts settled at the tween's END (full scale) -- only
      // forward(from: 0) (fired on the capture edge) should ever dip it
      // down to the tween's start, otherwise the guide would render at 90%
      // scale for the entire idle/holding/capturing phases before the
      // first "✓ Captured" ever fires.
      value: 1.0,
    );
    _popScale = Tween(begin: 0.9, end: 1.0)
        .animate(CurvedAnimation(parent: _popCtrl, curve: Curves.elasticOut));
    // Blinking brightness warning shown ABOVE the guide (CTO request,
    // 2026-08-06: the existing bottom warning row was easy to miss while
    // looking at the thumb inside the mask). Repeats indefinitely and is
    // only ever ticked while a brightness warning is actually on screen --
    // see the _brightnessBlink usage in build(). Driven by opacity rather
    // than a hard on/off toggle so it reads as a pulse, not a flicker.
    _blinkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _blinkOpacity = Tween(begin: 1.0, end: 0.25).animate(
      CurvedAnimation(parent: _blinkCtrl, curve: Curves.easeInOut),
    );
    // Pulsing distance-hint banner, top of screen (CTO request 2026-08-17:
    // the wavelength/distance signal lives in the bottom warning row today,
    // which real device testing already showed is easy to miss while
    // looking at the guide near the top -- same root complaint the
    // brightness pill above was built to fix, just never applied to this
    // signal). Own controller (not reusing _blinkCtrl) since brightness and
    // distance can in principle both be true at once and need independent
    // pulse phases.
    _distancePulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _distancePulseOpacity = Tween(begin: 1.0, end: 0.35).animate(
      CurvedAnimation(parent: _distancePulseCtrl, curve: Curves.easeInOut),
    );
    _init();
  }

  // Real camera/lighting signal only exists once the image stream is running
  // (started in FrontCaptureController.start(), triggered by the idle CTA) --
  // during FrontCapturePhase.idle, lightingValue/focusValue are still at
  // their pre-stream defaults (0.5 / 0), which would otherwise read as a
  // false "too dark / too soft" warning before the user has done anything.
  // Scoped further to `holding` specifically (not just "stream running"):
  // during `calibrating` the user hasn't placed their thumb yet either, so
  // focus is genuinely near-zero there too -- a real gap the initial
  // warning-state feature shipped with, tightened here rather than left for
  // a device test to catch.
  bool _isLowQuality(FrontCaptureState s) {
    if (s.phase != FrontCapturePhase.holding) return false;
    final focusVal = _lockedFocusValue ?? _ctrl.focusValue;
    return s.lightingValue < 0.30 || focusVal < 0.30;
  }

  Future<void> _init() async {
    try {
      // docs/LOCKED_SHUTTER_SPEED_SCOPE.md Phase 0: MUST run to completion
      // before CameraService.initializeCamera() below -- the probe opens
      // its own short-lived Camera2 session, and Android does not allow two
      // concurrent CameraDevice handles on the same physical camera.
      // Cached (see FrontCaptureController.probeTorchExposureCompat), so
      // this is a real cost only on the very first capture screen open per
      // app process, never on a second visit. Never blocks camera init on
      // failure -- the probe itself never throws past its own try/catch,
      // and this call is additionally timeout-bounded inside that method.
      await FrontCaptureController.probeTorchExposureCompat();
      await _cameraService.initializeCamera(
        lensDirection: CameraLensDirection.back,
        resolution: ResolutionPreset.max,
        // Burst+video hybrid capture, Phase 0: real, supported params
        // (see CameraService.initializeCamera's own doc comment) for the
        // post-burst sweep-video step. Harmless when video is never
        // recorded on a given run.
        fps: 30,
        videoBitrate: 2500000,
      );
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _initError = '$e');
    }
  }

  void _onState() {
    if (!mounted) return;
    final s = _ctrl.state;

    // Scan animation: run while shots are actively being taken (main burst)
    // OR while secondary cameras are firing (capturingExtra) -- real
    // device-test feedback (2026-08-01): the IR camera phase had no visible
    // motion at all, no way for the user to tell the app was doing anything.
    // Stops before the Processing… decode phase so the 8× concurrent
    // ui.instantiateImageCodec calls don't compete with 60 fps repaints.
    final shouldScan = s.confirmationText == null &&
        (s.isCapturingBurst ||
            s.phase == FrontCapturePhase.capturingExtra);
    if (shouldScan && !_scanAnim.isAnimating) {
      _scanAnim.repeat(reverse: true);
    } else if (!shouldScan && _scanAnim.isAnimating) {
      _scanAnim.stop();
      _scanAnim.value = 0;
    }

    // Focus meter: lock at burst-start value to avoid the
    // peak-normalisation oscillation that flash-vs-ambient alternation causes.
    if (s.isCapturingBurst && _lockedFocusValue == null) {
      _lockedFocusValue = _ctrl.focusValue;
    } else if (!s.isCapturingBurst && _lockedFocusValue != null) {
      _lockedFocusValue = null;
    }

    // A light tick the instant the guide flips INTO the low-quality warning
    // state (not on every frame while it stays there) -- the orange guide/
    // meter color is already a strong visual cue; this adds a physical one
    // for the moment it first becomes true, same "real-time confirmation"
    // pattern already used elsewhere in the controller for state changes.
    final lowQuality = _isLowQuality(s);
    if (lowQuality && !_wasLowQuality) {
      unawaited(HapticFeedback.lightImpact());
    }
    _wasLowQuality = lowQuality;

    // "Pop" the guide outline the instant the primary burst's own "✓
    // Captured" confirmation appears -- fires once per capture (the edge,
    // not the level), distinct from the secondary-camera/sweep-retry
    // confirmations which reuse the same confirmationText field with
    // different copy.
    if (s.confirmationText == '✓ Captured' && _lastConfirmationText != '✓ Captured') {
      _popCtrl.forward(from: 0);
    }
    _lastConfirmationText = s.confirmationText;

    setState(() {});

    if (!_navigated &&
        s.phase == FrontCapturePhase.complete &&
        s.captureId != null) {
      _navigated = true;
      widget.onComplete(s.captureId!);
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onState);
    _ctrl.dispose();
    _cameraService.disposeCamera();
    _scanAnim.dispose();
    _popCtrl.dispose();
    _blinkCtrl.dispose();
    _distancePulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _onStart() async {
    final userId = widget.getUserId();
    if (userId == null) {
      widget.onRequireLogin();
      return;
    }
    final cam = _camera;
    if (cam == null) return;
    await _ctrl.start(
      camera: cam,
      userId: userId,
      screenSize: MediaQuery.sizeOf(context),
      cameraService: _cameraService,
    );
  }

  // Returns (progress 0-1, fillColor) for the outer progress ring.
  (double, Color) _ringState(FrontCaptureState s) {
    if (s.isCapturingBurst) return (s.burstProgress, CaptureColors.silverBright);
    if (s.phase == FrontCapturePhase.capturingExtra) {
      return (s.extraProgress, CaptureColors.gold);
    }
    // Both sweep phases fill the same ring the classic static burst always
    // used (silver, s.burstProgress) -- real device-test feedback
    // (2026-07-30 round 4): the ring should "fill with progress just like
    // the original UI", not sit empty during positioning or switch to a
    // different colour during the active sweep. The horizontal sweep bar
    // and headline text already carry the fast/slow signal separately, so
    // the ring doesn't need to double as that indicator too.
    if (s.phase == FrontCapturePhase.sweepPositioning) {
      return (s.sweepDwellProgress, CaptureColors.silverBright);
    }
    if (s.phase == FrontCapturePhase.sweepActive) {
      return (s.sweepProgress, CaptureColors.silverBright);
    }
    if (s.phase == FrontCapturePhase.complete) return (1.0, CaptureColors.success);
    if (s.phase == FrontCapturePhase.holding && s.onTarget) {
      return (s.holdProgress, CaptureColors.cyan);
    }
    return (0.0, CaptureColors.cyan);
  }

  String? _headlineText(FrontCaptureState s) {
    if (s.phase == FrontCapturePhase.idle) return 'Place thumb in the guide';
    if (s.phase == FrontCapturePhase.calibrating) return 'Preparing camera…';
    if (s.phase == FrontCapturePhase.holding) {
      if (s.onTarget) return 'Hold still…';
      if (!s.isSteady) return 'Hold the phone steady…';
      return 'Align your thumb';
    }
    if (s.phase == FrontCapturePhase.sweepPositioning) {
      // Real device-test feedback (2026-07-30 round 3): with no visible
      // change while positioning was being evaluated, a stuck sweep looked
      // identical to one that was working but just needed a moment --
      // "just static". sweepPositionOk flips true the instant the centroid
      // enters the left zone (before the dwell timer even completes), so
      // the text itself is live confirmation that tracking is active.
      return s.sweepPositionOk ? 'Hold there…' : 'Place thumb at the left edge of the guide';
    }
    if (s.phase == FrontCapturePhase.sweepActive) {
      return s.sweepFastWarning ? 'Slow down a little…' : 'Slowly sweep right →';
    }
    if (s.phase == FrontCapturePhase.capturing) return 'Scanning fingerprint…';
    if (s.phase == FrontCapturePhase.capturingExtra) {
      return s.distanceHint ?? 'Capturing extra detail…';
    }
    return null;
  }

  Color _headlineColor(FrontCaptureState s) {
    if (s.phase == FrontCapturePhase.holding && s.onTarget) {
      return CaptureColors.success;
    }
    if (s.phase == FrontCapturePhase.sweepActive) {
      return s.sweepFastWarning ? CaptureColors.warning : CaptureColors.success;
    }
    if (s.phase == FrontCapturePhase.sweepPositioning) {
      return s.sweepPositionOk ? CaptureColors.success : CaptureColors.cyan;
    }
    return CaptureColors.silverBright;
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) return _errorScaffold('Camera error: $_initError');
    if (!_ready) {
      return const Scaffold(
        backgroundColor: CaptureColors.void_,
        body: Center(child: CircularProgressIndicator(color: CaptureColors.cyan)),
      );
    }

    final s = _ctrl.state;
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final topPad = mq.padding.top;
    final bottomPad = mq.padding.bottom;

    final showGuide = s.phase == FrontCapturePhase.idle ||
        s.phase == FrontCapturePhase.calibrating ||
        s.phase == FrontCapturePhase.holding ||
        s.phase == FrontCapturePhase.sweepPositioning ||
        s.phase == FrontCapturePhase.sweepActive ||
        s.phase == FrontCapturePhase.capturing ||
        s.phase == FrontCapturePhase.capturingExtra;

    // MAC3D capture-UX-polish mockup (2026-08-02): the guide outline itself
    // should read as a distinct "warning" (orange) state when the frame is
    // too dark or too soft to score well, not just implicitly via the
    // bottom warning row -- same 30% cutoff the mockup uses on its
    // brightness/focus sliders, translated to our own read-only lighting/
    // focus signals. Purely a UI cue (no capture-pipeline threshold touched)
    // so it's safe to adopt the mockup's exact number without a device-test
    // gate the way a capture-affecting parameter would need. Gated to the
    // `holding` phase only (see _isLowQuality) so it can't misfire before
    // the user has even placed their thumb.
    final focusVal = _lockedFocusValue ?? _ctrl.focusValue;
    final lowQuality = _isLowQuality(s);
    final brightWarn = lowQuality && s.lightingValue < 0.30;
    final focusWarn = lowQuality && focusVal < 0.30;

    // Blinking above-guide brightness warning (CTO request 2026-08-06).
    // Deliberately NOT gated on _isLowQuality: that helper also requires the
    // focus signal to be settled, but an over/under-exposed frame is worth
    // flagging the moment it's true -- it's the one problem the user can fix
    // instantly by moving. Gated on `showGuide` only, so it can't fire
    // before the thumb is being framed at all.
    //
    // Thresholds, both stated in the same units as `lightingValue`
    // (ROI mean luma / 255):
    //   * 0.30 low  -- reuses the exact cutoff the existing bottom warning
    //     row and guide-outline warning state already use, so the two cues
    //     can never disagree with each other.
    //   * 0.85 high -- deliberately matched to the controller's own
    //     _coverageMax (0.85), which is already this project's established
    //     "ROI is saturating" boundary on the same measured signal, rather
    //     than a fresh invented number. Real supporting data: ambient frames
    //     from good captures measure mean luma 126-151 (~0.49-0.59 here),
    //     comfortably inside this band, while the torch-blowout failures
    //     this project has documented repeatedly sit far above it.
    // UI-only -- no capture-pipeline threshold is touched by either.
    const double kBrightLow = 0.30;
    const double kBrightHigh = 0.85;
    final tooDark = showGuide && s.lightingValue < kBrightLow;
    final tooBright = showGuide && s.lightingValue > kBrightHigh;
    final showBrightnessBlink = tooDark || tooBright;

    final silhouetteState = (s.isCapturingBurst ||
            s.phase == FrontCapturePhase.capturingExtra ||
            s.phase == FrontCapturePhase.sweepActive)
        ? PadSilhouetteState.capturing
        : (lowQuality
            ? PadSilhouetteState.warning
            : (s.onTarget || s.phase == FrontCapturePhase.sweepPositioning
                ? PadSilhouetteState.locked
                : PadSilhouetteState.aligning));

    final (ringProgress, ringColor) = _ringState(s);

    // 270×270 ring centred at cy=0.37 — matches PadSilhouetteShape.cy.
    const ringD = 270.0;
    const ringR = ringD / 2;
    final ringCx = size.width / 2;
    final ringCy = size.height * 0.37;
    final ringLeft = ringCx - ringR;
    final ringTop = ringCy - ringR;

    // Vertical meters: 40×180, flanking the ring with a 10 px gap.
    const meterW = 40.0;
    const meterH = 180.0;
    const meterGap = 10.0;
    final meterTop = ringCy - meterH / 2;
    final brightLeft = ringLeft - meterGap - meterW;
    final focusLeft = ringLeft + ringD + meterGap;

    // Warning / hint row — lighting only now (distance moved to a top-of-
    // screen pulsing banner, see showDistancePulse below: CTO real-device
    // feedback 2026-08-17, "the wavelength signal text... can't see it at
    // the bottom" -- same root complaint the brightness pill was already
    // built to fix for lighting, 2026-08-06, just never applied to this
    // signal until now).
    String? warningText;
    Color warningColor = CaptureColors.warning;
    if (showGuide && s.distanceHint == null && lowQuality) {
      // MAC3D capture-UX-polish mockup: focus takes priority over brightness
      // when both are low (same order the mockup's own warningText uses).
      // Copy adapted from the mockup's "Move slider or refocus" -- this app
      // has no draggable slider, so the wording points at what the user can
      // actually do (hold steadier / move to better light).
      warningText = focusWarn
          ? 'Hold steadier — image is too soft'
          : 'Move to better light — image is too dark';
      warningColor = CaptureColors.warning;
    }

    // Top-of-screen pulsing distance banner -- direct, bold, impossible to
    // miss text driven by the exact same distanceHint signal that used to
    // render as a small row at the bottom. 'Move closer' is the only
    // coverage-driven "too far" case; every other non-null distanceHint
    // value (both the coverage-driven "too close" and the wavelength-gate-
    // driven "too close" cases -- see FrontCaptureController.rawOnTarget --
    // already share the single 'Move back slightly' string) means the
    // thumb needs to move BACK, so this two-way split covers every real
    // value the controller ever sets.
    final showDistancePulse = showGuide &&
        s.distanceHint != null &&
        s.phase != FrontCapturePhase.capturingExtra;
    final distanceBannerText =
        s.distanceHint == 'Move closer' ? 'Bring Print Closer' : 'Push Print Backward';

    // Run the blinks only while their warning is actually on screen -- an
    // always-repeating controller would keep the widget tree animating (and
    // burning frames) for the entire session. Scheduled post-frame because
    // build() must not mutate animation state synchronously.
    if (showBrightnessBlink != _blinkCtrl.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (showBrightnessBlink && !_blinkCtrl.isAnimating) {
          _blinkCtrl.repeat(reverse: true);
        } else if (!showBrightnessBlink && _blinkCtrl.isAnimating) {
          _blinkCtrl.stop();
          _blinkCtrl.value = 0.0;
        }
      });
    }
    if (showDistancePulse != _distancePulseCtrl.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (showDistancePulse && !_distancePulseCtrl.isAnimating) {
          _distancePulseCtrl.repeat(reverse: true);
        } else if (!showDistancePulse && _distancePulseCtrl.isAnimating) {
          _distancePulseCtrl.stop();
          _distancePulseCtrl.value = 0.0;
        }
      });
    }

    final headline = _headlineText(s);

    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: Stack(
        children: [
          // Camera preview — stopped before upload phase to prevent bleed-
          // through behind the upload scrim (real device test, 2026-07-23).
          if (s.phase != FrontCapturePhase.uploading)
            Positioned.fill(child: RepaintBoundary(child: _cameraLayer())),

          // Pad guide overlay: dark scrim + oval cutout + core reticle.
          // progress=0 suppresses the old boundary arc — the new external
          // ring replaces it. hint=null: guidance now lives in the bottom
          // section, not drawn inside the overlay.
          if (showGuide)
            Positioned.fill(
              child: RepaintBoundary(
                // MAC3D capture-UX-polish mockup: a brief "pop" (successPop)
                // on the guide outline the instant the primary burst's own
                // "✓ Captured" confirmation appears -- _popCtrl is driven
                // from _onState's confirmationText edge-detect, not from
                // build(), so it fires exactly once per capture.
                child: ScaleTransition(
                  scale: _popScale,
                  child: CapturePadSilhouetteOverlay(
                    state: silhouetteState,
                    hint: null,
                    progress: 0,
                    shape: s.activeGuideShape ?? PadSilhouetteShape.defaultShape,
                    distanceWaveCue: s.distanceWaveCue,
                  ),
                ),
              ),
            )
          else
            const Positioned.fill(
              child: RepaintBoundary(child: CaptureVignetteOverlay()),
            ),

          // 270×270 capture progress ring centred on the oval.
          if (showGuide)
            Positioned(
              left: ringLeft,
              top: ringTop,
              child: _CaptureProgressRing(progress: ringProgress, color: ringColor),
            ),

          // Blinking brightness warning, sited directly ABOVE the guide ring
          // (CTO request 2026-08-06) so it lands in the same eyeline as the
          // thumb being framed -- the pre-existing warning row sits far below
          // the mask and was easy to miss while looking at the guide.
          // Colour-coded from the existing CaptureColors semantic palette:
          // amber `warning` for too-dark (recoverable by moving to better
          // light) and red `error` for too-bright, which is the torch-blowout
          // regime this project has repeatedly measured as the more damaging
          // of the two. 28px above the ring keeps it clear of the ring stroke
          // at every screen size used so far.
          if (showBrightnessBlink)
            Positioned(
              left: 0,
              right: 0,
              top: ringTop - 28,
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: _blinkOpacity,
                  child: _BrightnessWarningPill(
                    text: tooBright
                        ? 'TOO BRIGHT — move out of direct light'
                        : 'TOO DARK — move to better light',
                    color: tooBright
                        ? CaptureColors.error
                        : CaptureColors.warning,
                  ),
                ),
              ),
            ),

          // Sweep Step 1 (positioning) needs no separate highlight overlay --
          // the guide silhouette itself shifts left via activeGuideShape
          // (see FrontCaptureController._sweepGuideShapeForProgress), a real
          // fix from 2026-07-30 device-test feedback that a static guide +
          // internal highlight band left the user unable to tell where
          // their thumb actually needed to be.

          // Sweep Step 2: horizontal progress bar + moving centroid-tracking
          // highlight beneath the guide. Replaces the need for mid-sweep text
          // instruction — the user watches this fill left-to-right instead.
          // Also reused for the burst+video hybrid's sweep-video step
          // (videoSweepActive) -- same visual, driven by elapsed-time
          // progress there instead of live centroid tracking.
          if (s.phase == FrontCapturePhase.sweepActive || s.videoSweepActive)
            Positioned(
              left: ringLeft,
              top: ringTop + ringD + 34,
              width: ringD,
              child: _SweepProgressBar(
                progress: s.sweepProgress,
                fastWarning: s.sweepFastWarning,
              ),
            ),

          // Directional arrow cue for the sweep-burst step -- real device-
          // test feedback (2026-08-03): "I did not recognize any sweep UX",
          // and separately asked for the guide to move + arrows to indicate
          // direction "as before" (the disabled guided-sweep feature's own
          // left-to-right guide translation). The guide itself already
          // moves via activeGuideShape (see _captureSweepBurst); this adds
          // the explicit "which way" cue on top.
          if (s.videoSweepActive)
            Positioned(
              left: ringLeft,
              top: ringTop + ringD + 10,
              width: ringD,
              child: _SweepDirectionArrows(progress: s.sweepProgress),
            ),

          // Brightness meter — left of ring.
          if (showGuide)
            Positioned(
              left: brightLeft,
              top: meterTop,
              child: _VerticalMeter(
                value: s.lightingValue,
                color: CaptureColors.gold,
                icon: Icons.wb_sunny_outlined,
                label: 'BRIGHT',
                tooltip: 'How well-lit your thumb is right now',
                warning: brightWarn,
              ),
            ),

          // Focus meter — right of ring. Uses the value locked at burst-start
          // while shooting so flash/ambient alternation doesn't make it flicker.
          if (showGuide)
            Positioned(
              left: focusLeft,
              top: meterTop,
              child: _VerticalMeter(
                value: focusVal,
                color: CaptureColors.cyan,
                icon: Icons.center_focus_strong_outlined,
                label: 'FOCUS',
                tooltip: 'How sharp the camera\'s autofocus is on your thumb',
                warning: focusWarn,
              ),
            ),

          // Scan line sweeping through the oval during burst OR while
          // secondary cameras are firing (same real-device-feedback fix as
          // shouldScan above -- keeps visible motion on-screen so the IR/
          // secondary camera phase doesn't look frozen).
          if (s.isCapturingBurst || s.phase == FrontCapturePhase.capturingExtra)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _scanAnim,
                  builder: (_, __) {
                    final lineY = ringTop + 16 + (ringD - 32) * _scanAnim.value;
                    return Stack(
                      children: [
                        Positioned(
                          top: lineY,
                          left: ringLeft + 20,
                          width: ringD - 40,
                          height: 2,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.transparent,
                                  Color(0x9900BFFF),
                                  Color(0xFF00BFFF),
                                  Color(0x9900BFFF),
                                  Colors.transparent,
                                ],
                                stops: [0.0, 0.2, 0.5, 0.8, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),

          // Frame counter + burst dots INSIDE the ring during the burst —
          // MAC3D capture-UX-polish mockup moves both from a plain "X / 8"
          // caption below the ring into the ring itself (mono counter near
          // the top, 8 glowing dots near the bottom) so progress reads at a
          // glance without competing with the headline text below.
          if (s.isCapturingBurst) ...[
            Positioned(
              top: ringTop + 20,
              left: ringLeft,
              width: ringD,
              child: Text(
                '${(s.burstProgress * 8).ceil()} / 8',
                textAlign: TextAlign.center,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: CaptureColors.silverBright,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            Positioned(
              top: ringTop + ringD - 34,
              left: ringLeft,
              width: ringD,
              child: _BurstDots(filled: (s.burstProgress * 8).ceil(), total: 8),
            ),
          ],

          // Per-camera confirmation banners (e.g. "✓ IR captured"), and the
          // sweep-retry prompt ("Try again — sweep a little slower") shown
          // via the same mechanism while briefly back in sweepPositioning.
          if (s.confirmationText != null)
            Positioned(
              top: topPad + 64,
              left: 40,
              right: 40,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ConfirmationBanner(
                    text: s.confirmationText!,
                    isWarning: s.phase == FrontCapturePhase.sweepPositioning,
                  ),
                  // MAC3D capture-UX-polish mockup: a small mono BRIGHT/FOCUS
                  // percentage readout under the "Captured" moment specifically
                  // (not the secondary-camera/sweep-retry banners, which reuse
                  // this same widget with different text) — a quick confirm of
                  // the conditions the just-finished burst was actually shot
                  // under.
                  if (s.confirmationText == '✓ Captured') ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'BRIGHT ${(s.lightingValue.clamp(0.0, 1.0) * 100).round()}%',
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: CaptureColors.silverDim,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Text(
                          'FOCUS ${(focusVal.clamp(0.0, 1.0) * 100).round()}%',
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: CaptureColors.silverDim,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

          // Header: back | "FRONT CAPTURE" | status pill.
          Positioned(
            top: topPad + 10,
            left: 0,
            right: 0,
            child: _buildHeader(s),
          ),

          // Top-of-screen pulsing distance banner (CTO real-device feedback
          // 2026-08-17: "the wavelength signal text needs to be displayed
          // on top of the screen in bold and it needs to pulse, can't see
          // it at the bottom"). Sited below the header row rather than
          // inside it so it never competes with the back button/status
          // pill for tap space, and above the guide ring so it's the first
          // thing in the user's eyeline while they're adjusting distance.
          if (showDistancePulse)
            Positioned(
              left: 16,
              right: 16,
              top: topPad + 54,
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: _distancePulseOpacity,
                  child: _DistanceBanner(text: distanceBannerText),
                ),
              ),
            ),

          // Headline + idle caption, anchored just below the ring.
          // Suppressed when the confirmationText banner is active so the two
          // don't render simultaneously (e.g. "Processing…" pill + "Scanning
          // fingerprint…" text both visible during the post-burst decode phase).
          if (headline != null &&
              s.confirmationText == null &&
              s.phase != FrontCapturePhase.uploading)
            Positioned(
              left: 24,
              right: 24,
              // Pushed down when the sweep-video arrows + progress bar are
              // occupying the space right below the ring, so the headline
              // text (which already shows this step's distanceHint) doesn't
              // collide with them.
              top: ringTop +
                  ringD +
                  (s.videoSweepActive
                      ? 58
                      : (s.isCapturingBurst ? 24 : 20)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    headline,
                    textAlign: TextAlign.center,
                    style: CaptureTypography.h3.copyWith(
                      fontSize: 16,
                      color: _headlineColor(s),
                    ),
                  ),
                  if (s.phase == FrontCapturePhase.idle) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Press your thumb pad flat against the camera lens and seat it in the outline.',
                      textAlign: TextAlign.center,
                      style: CaptureTypography.body.copyWith(
                        fontSize: 12,
                        color: CaptureColors.silver,
                      ),
                    ),
                  ],
                ],
              ),
            ),

          // Warning + CTA anchored to the bottom.
          if (s.phase != FrontCapturePhase.uploading &&
              s.phase != FrontCapturePhase.complete &&
              s.phase != FrontCapturePhase.error)
            Positioned(
              bottom: bottomPad + 16,
              left: 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (warningText != null) ...[
                    _WarningRow(text: warningText, color: warningColor),
                    const SizedBox(height: 10),
                  ],
                  _buildCta(s),
                ],
              ),
            ),

          // Upload overlay — camera already disposed before this phase.
          if (s.phase == FrontCapturePhase.uploading)
            Positioned.fill(child: _UploadingOverlay(progress: s.uploadProgress)),

          // Error overlay.
          if (s.phase == FrontCapturePhase.error)
            Positioned.fill(child: _errorOverlay(s.error ?? 'Capture failed')),
        ],
      ),
    );
  }

  Widget _buildHeader(FrontCaptureState s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: widget.onClose,
            child: const Icon(Icons.arrow_back_ios,
                color: CaptureColors.silverBright, size: 22),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: CaptureColors.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: CaptureColors.cyanBorder),
            ),
            child: Text(
              'FRONT CAPTURE',
              style: CaptureTypography.label.copyWith(
                fontSize: 11,
                color: CaptureColors.cyan,
                letterSpacing: 1.5,
              ),
            ),
          ),
          _StatusPill(phase: s.phase, onTarget: s.onTarget),
        ],
      ),
    );
  }

  // Bottom CTA row: only the idle and error phases show an action button.
  Widget _buildCta(FrontCaptureState s) {
    if (s.phase == FrontCapturePhase.idle) {
      // MAC3D capture-UX-polish mockup: a large circular shutter-style
      // button (fingerprint icon on a green radial gradient) replaces the
      // rectangular labelled button as the idle CTA — a stronger, more
      // immediately-recognizable "tap here" affordance than a text button.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CircularCaptureButton(onPressed: _onStart),
          const SizedBox(height: 12),
          Text(
            'PRESS TO CAPTURE',
            style: CaptureTypography.label.copyWith(letterSpacing: 1.2),
          ),
        ],
      );
    }
    // Active phases: small, non-interactive status line so the area
    // isn't blank while the user is in the flow.
    final note = s.phase == FrontCapturePhase.calibrating
        ? 'Preparing camera…'
        : (s.phase == FrontCapturePhase.holding && !s.onTarget && s.isSteady)
            ? 'Align your thumb'
            : null;
    if (note == null) return const SizedBox.shrink();
    return Text(
      note,
      textAlign: TextAlign.center,
      style: CaptureTypography.label
          .copyWith(fontSize: 13, color: CaptureColors.silver),
    );
  }

  Widget _cameraLayer() {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) {
      return const ColoredBox(color: CaptureColors.void_);
    }
    final preview = cam.value.previewSize;
    final w = preview?.height ?? 1080;
    final h = preview?.width ?? 1920;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: w, height: h, child: CameraPreview(cam)),
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
            Text(message,
                textAlign: TextAlign.center,
                style: CaptureTypography.body.copyWith(fontSize: 14)),
            const SizedBox(height: 22),
            CaptureButton(
              label: 'Back',
              variant: CaptureButtonVariant.ghost,
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold(String message) {
    return Scaffold(
      backgroundColor: CaptureColors.void_,
      body: SafeArea(child: _errorOverlay(message)),
    );
  }
}

// ── Status pill ───────────────────────────────────────────────────────────────

class _StatusPill extends StatefulWidget {
  const _StatusPill({required this.phase, required this.onTarget});
  final FrontCapturePhase phase;
  final bool onTarget;

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dot;

  @override
  void initState() {
    super.initState();
    _dot = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _dot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isRec = widget.phase == FrontCapturePhase.capturing ||
        widget.phase == FrontCapturePhase.capturingExtra;
    // Real device-test feedback (2026-07-30 round 3): the header pill sat on
    // "READY" through both sweep phases, giving no indication the app was
    // actively doing anything -- a stuck sweep and a working one looked
    // identical from the header alone.
    final isSweeping = widget.phase == FrontCapturePhase.sweepPositioning ||
        widget.phase == FrontCapturePhase.sweepActive;
    final isCaptured = widget.phase == FrontCapturePhase.complete;

    final Color pillBg;
    final Color textColor;
    final String label;
    final Widget? leading;

    if (isCaptured) {
      pillBg = CaptureColors.success.withValues(alpha: 0.18);
      textColor = CaptureColors.success;
      label = 'Captured';
      leading = const Icon(Icons.check, color: CaptureColors.success, size: 11);
    } else if (isRec) {
      pillBg = CaptureColors.warning.withValues(alpha: 0.18);
      textColor = CaptureColors.warning;
      label = 'REC';
      leading = AnimatedBuilder(
        animation: _dot,
        builder: (_, __) => Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: CaptureColors.warning.withValues(alpha: 0.35 + 0.65 * _dot.value),
            shape: BoxShape.circle,
          ),
        ),
      );
    } else if (isSweeping) {
      pillBg = CaptureColors.cyan.withValues(alpha: 0.18);
      textColor = CaptureColors.cyan;
      label = 'TRACKING';
      leading = AnimatedBuilder(
        animation: _dot,
        builder: (_, __) => Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: CaptureColors.cyan.withValues(alpha: 0.35 + 0.65 * _dot.value),
            shape: BoxShape.circle,
          ),
        ),
      );
    } else {
      pillBg = CaptureColors.cyan.withValues(alpha: 0.12);
      textColor = CaptureColors.cyan;
      label = 'READY';
      leading = null;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: pillBg,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: textColor.withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 4)],
          Text(
            label,
            style: CaptureTypography.label.copyWith(
              fontSize: 10,
              color: textColor,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Circular capture button (idle CTA) ──────────────────────────────────────────

class _CircularCaptureButton extends StatefulWidget {
  const _CircularCaptureButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_CircularCaptureButton> createState() => _CircularCaptureButtonState();
}

class _CircularCaptureButtonState extends State<_CircularCaptureButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onPressed,
      child: AnimatedBuilder(
        animation: _glow,
        builder: (_, child) {
          final g = 0.35 + 0.25 * _glow.value;
          return AnimatedScale(
            scale: _pressed ? 0.93 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  center: Alignment(-0.3, -0.45),
                  radius: 0.9,
                  colors: [
                    Color(0xFF4ADE80),
                    Color(0xFF22C55E),
                    Color(0xFF16A34A),
                    Color(0xFF14532D),
                  ],
                  stops: [0.0, 0.42, 0.78, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: CaptureColors.success.withValues(alpha: g),
                    blurRadius: 26,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: child,
            ),
          );
        },
        child: const Icon(
          Icons.fingerprint,
          size: 40,
          color: Color(0x8C062A14),
        ),
      ),
    );
  }
}

// ── Vertical meter ────────────────────────────────────────────────────────────

// MAC3D capture-UX-polish mockup (2026-08-02): thin center track + a
// circular handle capsule at the fill line, icon above and a label/percentage
// readout below -- replaces the old solid filled-bar-in-a-card look. These
// are read-only telemetry (real camera lighting/focus signals), not user
// controls -- the mockup's own drag handlers have no backing camera API in
// this project (no manual EV/focus override exists; see CLAUDE.md's
// locked-shutter-speed research) so the handle is visual only, not
// draggable. [warning] recolors the handle/fill orange, matching the guide
// outline's own PadSilhouetteState.warning treatment for the same signal.
class _VerticalMeter extends StatelessWidget {
  const _VerticalMeter({
    required this.value,
    required this.color,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.warning = false,
  });

  final double value;
  final Color color;
  final IconData icon;
  final String label;
  final String tooltip;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    final activeColor = warning ? CaptureColors.warning : color;
    // Tap-to-explain: these are more prominent now than the old plain bar,
    // so a first-time user may not immediately know what "72%" means here.
    // Tap trigger (not the default long-press) since this is a quick glance
    // UI, not a discoverability-first one.
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 3),
      textStyle: CaptureTypography.label.copyWith(color: CaptureColors.silverBright, fontSize: 11),
      decoration: BoxDecoration(
        color: CaptureColors.steel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CaptureColors.cardBorder),
      ),
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 180,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              // Track painted first so the icon (below) sits visibly on top
              // of it rather than being covered by the track's fill.
              Positioned.fill(
                child: CustomPaint(
                  painter: _MeterPainter(value: v, color: activeColor),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: CaptureColors.void_.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: activeColor.withValues(alpha: 0.85), size: 14),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: CaptureTypography.label.copyWith(fontSize: 8, letterSpacing: 0.8),
        ),
        const SizedBox(height: 2),
        Text(
          '${(v * 100).round()}%',
          style: GoogleFonts.jetBrainsMono(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: CaptureColors.silver,
          ),
        ),
      ],
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  const _MeterPainter({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final trackW = 6.0;
    final cx = size.width / 2;
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - trackW / 2, 0, trackW, size.height),
      const Radius.circular(3),
    );
    canvas.drawRRect(track, Paint()..color = CaptureColors.cardBg);

    // Filled portion grows from the bottom.
    final fillH = size.height * value;
    if (fillH > 0) {
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - trackW / 2, size.height - fillH, trackW, fillH),
        const Radius.circular(3),
      );
      canvas.drawRRect(fillRect, Paint()..color = color.withValues(alpha: 0.55));
    }

    // Circular handle capsule at the fill line.
    final handleY = (size.height - fillH).clamp(8.0, size.height - 8.0);
    final handleCenter = Offset(cx, handleY);
    canvas.drawCircle(handleCenter, 8, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(handleCenter, 5.5, Paint()..color = CaptureColors.silverBright);
    canvas.drawCircle(
      handleCenter,
      5.5,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.value != value || old.color != color;
}

/// Bold, pulsing top-of-screen distance directive (CTO real-device feedback
/// 2026-08-17 -- see the build()-level comment above showDistancePulse for
/// the full context). Deliberately larger/bolder than _BrightnessWarningPill
/// (direct imperative text, not a small chip) since this is the signal a
/// real user reported being unable to see at all in its previous location.
class _DistanceBanner extends StatelessWidget {
  final String text;
  const _DistanceBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: CaptureColors.void_.withValues(alpha: 0.80),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: CaptureColors.gold, width: 2),
          boxShadow: [
            BoxShadow(color: CaptureColors.gold.withValues(alpha: 0.45), blurRadius: 16),
          ],
        ),
        child: Text(
          text.toUpperCase(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: CaptureColors.gold,
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}

// ── Capture progress ring ─────────────────────────────────────────────────────

/// Blinking exposure warning shown above the pad guide. Styled to match the
/// existing capture-screen chips (translucent steel fill + coloured border +
/// uppercase letter-spaced label), taking its accent colour from the caller
/// so the same widget serves both the too-dark (amber) and too-bright (red)
/// cases without duplicating layout.
class _BrightnessWarningPill extends StatelessWidget {
  final String text;
  final Color color;
  const _BrightnessWarningPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: CaptureColors.void_.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color, width: 1.5),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 12),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 15, color: color),
            const SizedBox(width: 7),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptureProgressRing extends StatelessWidget {
  const _CaptureProgressRing({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _RingPainter(progress: progress, color: color),
      size: const Size(270, 270),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    // MAC3D capture-UX-polish mockup: a much thicker donut-style ring
    // (roughly 20px band on a 270px circle) rather than a thin stroke arc --
    // reads as a more premium capture-progress indicator at a glance.
    const strokeW = 14.0;
    final r = cx - strokeW / 2 - 2; // inset so stroke doesn't clip at the widget edge
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    // Ring track — always visible, at low opacity.
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = color.withValues(alpha: 0.12)
        ..strokeWidth = strokeW
        ..style = PaintingStyle.stroke,
    );

    // Progress arc — starts at 12 o'clock (-π/2), fills clockwise.
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = color
          ..strokeWidth = strokeW
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

// ── Burst progress dots ───────────────────────────────────────────────────────

/// 8 small dots inside the ring, filled + glowing as each burst frame fires —
/// MAC3D capture-UX-polish mockup, replaces the plain "X / 8" text as the
/// sole progress cue (the counter now sits above these, not instead of them).
class _BurstDots extends StatelessWidget {
  const _BurstDots({required this.filled, required this.total});
  final int filled;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final on = i < filled;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on
                ? CaptureColors.silverBright
                : CaptureColors.silverBright.withValues(alpha: 0.22),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: CaptureColors.silverBright.withValues(alpha: 0.7),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
        );
      }),
    );
  }
}

// ── Warning row ───────────────────────────────────────────────────────────────

class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline, color: color, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: CaptureTypography.label
                  .copyWith(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Confirmation banner ───────────────────────────────────────────────────────

class _ConfirmationBanner extends StatelessWidget {
  const _ConfirmationBanner({required this.text, this.isWarning = false});
  final String text;
  // True for the sweep-retry prompt ("Try again — sweep a little slower")
  // -- same banner shape/mechanism as the success confirmations, but a
  // warning tone rather than green so a failed sweep doesn't read as success.
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final color = isWarning ? CaptureColors.warning : CaptureColors.success;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: color.withValues(alpha: 0.50)),
        ),
        child: Text(
          text,
          style: CaptureTypography.h3.copyWith(color: color, fontSize: 15),
        ),
      ),
    );
  }
}

// ── Sweep direction arrows ────────────────────────────────────────────────────

/// Row of chevrons with a brightness highlight that sweeps left-to-right in
/// a continuous loop — a direct "move this way" cue for the sweep-video step.
/// When progress reaches 1.0 (guide at far right), switches to a static
/// "Hold position" cue so the user knows to stop moving.
class _SweepDirectionArrows extends StatefulWidget {
  const _SweepDirectionArrows({required this.progress});
  final double progress;

  @override
  State<_SweepDirectionArrows> createState() => _SweepDirectionArrowsState();
}

class _SweepDirectionArrowsState extends State<_SweepDirectionArrows>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Once the guide has reached the far-right end, stop asking the user to
    // keep moving — show a static "hold" cue instead.
    if (widget.progress >= 0.99) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline_rounded, size: 18, color: CaptureColors.success),
          const SizedBox(width: 6),
          Text(
            'Hold position',
            style: TextStyle(
              color: CaptureColors.success,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      );
    }

    const count = 4;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final head = _ctrl.value * count;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(count, (i) {
            final dist = (head - i) % count;
            final proximity = (1.0 - (dist / count)).clamp(0.0, 1.0);
            final alpha = 0.25 + 0.65 * math.pow(proximity, 3);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: CaptureColors.cyan.withValues(alpha: alpha.toDouble()),
              ),
            );
          }),
        );
      },
    );
  }
}

// ── Sweep progress bar ────────────────────────────────────────────────────────

/// Horizontal left-to-right fill bar shown during sweepActive, beneath the
/// guide. Replaces the need for mid-sweep text instruction (per the UX
/// spec) — the user watches this fill instead of reading copy. Green while
/// the current frame is sharp enough to fire, orange while moving too fast.
class _SweepProgressBar extends StatelessWidget {
  const _SweepProgressBar({required this.progress, required this.fastWarning});
  final double progress;
  final bool fastWarning;

  @override
  Widget build(BuildContext context) {
    final color = fastWarning ? CaptureColors.warning : CaptureColors.success;
    return SizedBox(
      height: 10,
      child: CustomPaint(
        painter: _SweepBarPainter(progress: progress.clamp(0.0, 1.0), color: color),
      ),
    );
  }
}

class _SweepBarPainter extends CustomPainter {
  const _SweepBarPainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(track, Paint()..color = CaptureColors.cardBg);

    final fillW = size.width * progress;
    if (fillW > 0) {
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, fillW, size.height),
        Radius.circular(size.height / 2),
      );
      canvas.drawRRect(fillRect, Paint()..color = color.withValues(alpha: 0.55));
    }

    // Marker dot at the current leading edge -- the moving "tracking" cue
    // the UX spec calls for, distinct from the fill itself.
    final markerX = fillW.clamp(size.height / 2, size.width - size.height / 2);
    canvas.drawCircle(
      Offset(markerX, size.height / 2),
      size.height / 2 + 2,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SweepBarPainter old) =>
      old.progress != progress || old.color != color;
}

// ── Upload overlay ────────────────────────────────────────────────────────────

class _UploadingOverlay extends StatelessWidget {
  const _UploadingOverlay({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    // Fully opaque (camera already stopped before this phase). ClearBridge
    // logo + spinner + linear progress — replaces the generic fingerprint
    // icon placeholder per CTO device-test feedback 2026-07-23.
    return Container(
      color: CaptureColors.void_,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 132,
              height: 132,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const SizedBox(
                    width: 132,
                    height: 132,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: CaptureColors.cyan,
                    ),
                  ),
                  ClipOval(
                    child: Image.asset(
                      'assets/images/app_logo.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.fingerprint,
                        size: 96,
                        color: CaptureColors.cyan,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Uploading capture…',
              style: CaptureTypography.body
                  .copyWith(color: CaptureColors.silverBright, fontSize: 15),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: CaptureColors.cardBg,
                color: CaptureColors.cyan,
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
