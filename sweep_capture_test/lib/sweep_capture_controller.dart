import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:mac_capture/mac_capture.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// One sweep zone. `progress` is the 0..1 horizontal sweep position (fed to
/// _sweepGuideShapeForProgress, which converts it to the guide's on-screen
/// cx); `dyFrac` offsets the guide VERTICALLY as a fraction of screen height,
/// which the original three horizontal-only zones never varied.
class _SweepZone {
  final String name;
  final double progress;
  final double dyFrac;
  const _SweepZone(this.name, this.progress, {this.dyFrac = 0.0});
}

/// Standalone test of the sweep-burst capture architecture -- deliberately
/// NOT layered after a main burst the way clearbridge_beta's
/// FrontCaptureController runs it (real data, commit db1a94e 2026-08-06:
/// 1/137 wins, 0/3 cross-zone mosaic wins, 17% of captures permanently
/// stuck at pending/enhancing, averaging 161s ON TOP of the main burst's
/// own time). The working hypothesis this app tests: sweep-burst never got
/// a fair trial because it always shared a Cloud Function request's time
/// budget with the main burst's own AFIS variant loop, and always fired
/// after the user's hand was already fatigued from holding through 8 main-
/// burst shots. Here, the sweep zones ARE the whole capture -- fresh camera
/// session, fresh hand position, and (critically) the ONLY thing populating
/// this request's `frames` field is the center zone's own ambient/flash
/// pair, so the backend's AFIS variant loop has far less competing work
/// than a real front_only_v1 capture, leaving sweep-burst's own zone/fusion
/// scoring a much larger share of the same 300s ceiling.
///
/// Ported from FrontCaptureController._captureSweepBurst (clearbridge_beta)
/// -- same guide-region math (_stillSpaceRegionForShape), same zone timing
/// constants, same real fixes already validated there (EV-compensated
/// flash, per-zone ambient+flash pairs, sequential encode/upload to avoid
/// CPU/bandwidth starvation) -- plus this session's own new
/// _zoneFramingSimilarity real-motion check (2026-08-08), carried over
/// rather than re-derived.
class SweepCaptureController extends ChangeNotifier {
  // ─── Guide geometry (ported from PadSilhouetteShape.defaultShape usage) ──
  static const double _guideN = 2.5;
  // Matches front_capture_controller.dart's _sweepGuideShiftFrac exactly --
  // re-derive by hand only if that project's own guide is re-tuned.
  //
  // REAL GAP FOUND 2026-08-11: this standalone app has its OWN independent
  // copy of this constant -- when front_capture_controller.dart's own
  // value was fixed (0.335396 -> 0.15, real measurement showed the old
  // spacing left ZERO overlap between adjacent zones, guaranteeing
  // `_front_anchored_mosaic_zones` registration failure) this file's copy
  // was missed, since this app is what the CTO has actually been testing
  // ("sweep_burst_standalone" captureMethod, confirmed via real Firestore
  // docs) -- so every real device test since that fix still ran the OLD,
  // too-wide spacing. Kept in sync by hand now; re-derive both together if
  // the guide is ever re-tuned again.
  static const double _sweepGuideShiftFrac = 0.15;

  // ─── Zone timing (ported from _captureSweepBurst's own constants) ────────
  static const int _calibrationHoldMs = 1500;
  static const int _calibrationTickMs = 700;
  // Scaled back down 3100->1400 alongside the spacing fix above -- same
  // velocity-consistency reasoning as front_capture_controller.dart's own
  // _sweepZoneMoveMs (keep the guide's on-screen translation speed
  // constant even though the distance it travels shrank).
  static const int _zoneMoveMs = 1400;
  static const int _zoneSettleMs = 700;

  // Vertical offset magnitude for the two vertical stations ('tip' above the
  // centre, 'tipLow' below), as a fraction of screen height applied to the
  // guide's cy. Sized at roughly half the guide's own ry (defaultShape.ry =
  // 0.137275) so BOTH still overlap the centre zone across most of their
  // area -- the mosaic registers every side against 'center', so overlap is
  // exactly what makes a station usable rather than an orphan frame.
  //
  // DIRECTION, settled 2026-08-12 by CTO observation of a real capture, and
  // it is the OPPOSITE of what an earlier comment here assumed. Moving the
  // guide UP moves the USER's thumb up to follow it, which leaves the guide
  // framing a region LOWER on the thumb -- toward the base, where the DELTA
  // singular points sit. Moving the guide DOWN reaches the fingertip.
  // Zones are named for the pad region they actually capture ('delta' for
  // the guide-up station, 'tip' for guide-down), not for the direction the
  // guide moves, since the two are inverted and conflating them is exactly
  // the mistake that produced the earlier backwards naming.
  static const double _tipZoneDyFrac = 0.07;

  // Ambient luma at or above which the sweep declines the torch outright.
  //
  // RAISED 100 -> 160, 2026-08-13, on CTO judgement plus real data. The
  // first value was set from a single capture and proved too aggressive:
  // it stood the torch down at calibBrightness 127.7 and 144.6, both
  // ordinary indoor rooms that the CTO judged dim enough for the torch to
  // still contribute. More importantly the gate made that judgement
  // UNTESTABLE -- no torch means no flash frame to measure, so the band
  // between 100 and AdaptiveFlashController's own bright cut-off (185) was
  // permanently unmeasured.
  //
  // 160 fires across every indoor brightness observed so far (51.5, 127.7,
  // 136.5, 144.6) while still standing down as the scene approaches
  // AdaptiveFlashController's 185, where the torch genuinely degrades
  // quality. Firing costs capture TIME but not print quality: the backend's
  // _FLASH_PAIR_MAX_SHARPNESS_RATIO guard independently rejects a flash
  // frame that is too soft to fuse (real: it skipped 2 of 4 zones on the
  // torch-on capture 60b4de13), so a useless flash frame is measured and
  // discarded rather than blended in.
  static const double _sweepTorchMaxAmbient = 160.0;

  // Adaptive flash EV curve, ported verbatim (same constants) from
  // front_capture_controller.dart's _adaptiveFlashEvStep -- see the real
  // call site's own comment for why a flat EV step was a correctness gap,
  // not just an untuned one. Real device history behind these two cuts:
  // calibrated against a real overexposure case (cb684c57) then softened
  // ~30% after two more real data points showed the original curve
  // over-correcting toward underexposure -- inherited as-is rather than
  // re-derived, since this app captures the same torch/sensor combination.
  static const double _flashEvMinCut = -0.2; // intensity=1.0 (pitch dark)
  static const double _flashEvMaxCut = -1.1; // intensity=0.3 (near bright-mode)
  static const double _flashEvDarkRoomThreshold = 30.0; // /255

  double _adaptiveFlashEvStep() {
    if (_calibBrightness < _flashEvDarkRoomThreshold) return 0.0;
    final intensity = (_flash?.intensity ?? 0.6).clamp(0.3, 1.0);
    final t = (1.0 - intensity) / 0.7;
    return _flashEvMinCut + (_flashEvMaxCut - _flashEvMinCut) * t;
  }
  static const int _burstFlashSettleMs = 70;
  // Widened 34000->40000, 2026-08-12, alongside the second ambient shot per
  // zone: that adds 3 more takePicture() calls (~0.5-0.9s each on this
  // device's real numbers) to a loop whose last real captures already ran
  // 23-25s, leaving too little headroom against the old bound. Real
  // arithmetic, not a guess: 25s worst-case observed + 3 x 0.9s = ~27.7s,
  // and 40s keeps roughly the same proportional margin 34s gave the
  // 6-shot loop. This is a BOUND, not a delay -- a normal capture still
  // finishes in ~27s and never waits on it.
  // Widened 40000->52000, 2026-08-12, for the fifth zone. Real arithmetic
  // off the first real 4-zone capture, not a guess: that run measured
  // durationMs 35423 against the 40s bound -- only 4.6s of headroom -- and a
  // fifth zone adds one move animation (1400ms) + focus redirect and settle
  // (~900ms) + three shutters (~0.5-0.9s each), i.e. roughly 5-8s. 52s keeps
  // a similar proportional margin to what 40s gave four zones. It is a
  // BOUND, not a delay: a clean 5-zone run should finish near 43s and never
  // wait on it.
  // RAISED 52000 -> 64000, 2026-08-13. Real failure, not a precaution: the
  // torch-on capture 60b4de13 measured durationMs 53502 and BLEW the 52s
  // bound, losing its fifth zone entirely (only left/center/right/delta
  // uploaded, no 'tip'). Dim scenes are the slow case -- autofocus takes
  // longer to converge with less light -- and raising the torch threshold
  // above means more captures now take the torch path and pay that cost.
  // 64s covers the 53.5s worst case observed with real headroom. Still a
  // BOUND, not a delay: the brighter 5-zone capture the same session
  // finished in 46.4s and never waited on it.
  static const int _sweepTimeoutMs = 64000;
  static const int _zoneEncodeTimeoutMs = 20000;
  static const int _zoneUploadTimeoutMs = 18000;
  static const int _zoneJpegQuality = 75;

  // ─── Real-motion check (2026-08-08, this session) ─────────────────────────
  static const double _zoneSimilarityThreshold = 0.90;
  static const int _extraMoveMs = 1800;

  final CameraService _camera = CameraService();
  final HybridCaptureService _hybrid = HybridCaptureService();
  final CaptureAudioService _audio = CaptureAudioService();
  AdaptiveFlashController? _flash;

  int _sensorOrientation = 90;
  Size? _cachedScreenSize;
  Size? _cachedPreviewSize;
  double _focusPeak = 1.0;
  double _focusValue = 0.0;
  // Whole-frame calibration luma the torch decision was made from -- kept
  // only so it can be written to the capture doc for diagnosis (see the
  // zoneDebug writes in the sweep loop).
  double _calibBrightness = 128.0;

  // Motion-blur gate, ported 2026-08-13 from front_capture_controller.dart.
  // GAP FOUND: this file had ZERO motion-blur protection -- no gyroscope
  // subscription, no steadiness gate, nothing -- despite the main app
  // having a real, evidenced fix for exactly this failure mode ("Real
  // captures showed motion-blur streaking in BOTH ambient and flash frames
  // of the same burst -- camera shake at macro (thumb-pad-filling)
  // distance, independent of focus distance or exposure"). If anything the
  // sweep architecture is MORE exposed to this than the main burst: every
  // zone fires immediately after a guide-move animation, i.e. right when
  // the thumb is most likely to still be settling from motion, whereas the
  // main burst's single hold has one long static dwell before it fires at
  // all. `sensors_plus` needs no new pubspec entry -- it is already a
  // transitive dependency via `mac_capture`.
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gyroMagnitudeDegPerSec = 0.0;
  // Same threshold as front_capture_controller.dart's _maxSteadyDegPerSec --
  // reusing an already real-device-tuned number rather than guessing a new
  // one for a different capture flow.
  static const double _maxSteadyDegPerSec = 6.0;
  // Bounded wait for steadiness before each zone's shutter, same "verify,
  // don't just delay" pattern already used for focus (_redirectZoneFocus).
  // Capped short deliberately: this is a bonus check layered on top of the
  // zone's own existing settle delay, not a replacement for it, so it can
  // only add a little real margin, never meaningfully lengthen a capture
  // that's already steady (the common case).
  static const int _steadyWaitMaxMs = 500;
  static const int _steadyPollIntervalMs = 50;

  // Live ridge-wavelength distance gate, ported 2026-08-13 from
  // front_capture_controller.dart. GAP FOUND: this file had zero live
  // distance/scale signal at all -- distanceHint here is pure status text
  // ("Hold still -- capturing $zone"), never derived from anything measured.
  // Real consequence, confirmed via a same-tester SourceAFIS genuine-vs-
  // real-NIST-impostor test (2026-08-13): front_only_v1's own real captures
  // showed NEGATIVE separation (own finger scored worse against itself than
  // against a stranger's), traced by eye to two of the tester's own captures
  // sitting at visibly different physical scales despite each individually
  // reading fine on NFIQ2 -- front_capture_controller.dart's own equivalent
  // estimator exists but is advisory-only (a text hint the hold can complete
  // right past), so it never actually prevented that mismatch. This is that
  // same estimator, reused verbatim (HybridCaptureService.estimateRidgeWavelengthPx
  // is shared package code, not duplicated), but wired as an actual bounded
  // GATE before the sweep's first zone fires, not just a hint -- see
  // _calibrate()'s extended-wait block below.
  //
  // Unlike front, this can't run on a continuously-open preview stream:
  // this file already hit a real ANR from reopening startImageStream
  // mid-sweep (2026-07-30, see _zoneFramingSimilarity's own comment above),
  // so sampling happens on the SAME already-open stream _calibrate() uses
  // for focus/brightness, never a second stream.
  double? _liveWavelengthPx;
  double? _liveWavelengthStillPx;
  int _wavelengthSampleCount = 0;
  int _wavelengthOutlierStreak = 0;
  String? _wavelengthAxis;
  DateTime? _lastWavelengthEstimateAt;
  static const int _wavelengthEstimateIntervalMs = 250;
  // RECALIBRATED 2026-08-14 -- the original 16.0 (copied verbatim from
  // front_capture_controller.dart's own threshold) was wrong for sweep and
  // has been replaced, not just re-verified. front's 16.0 encodes the
  // front_only_v1 NFIQ2 finding that native wavelength >=15px on a SINGLE
  // plain frame is catastrophic -- but that finding doesn't transfer here.
  // Real backend afisWavelengthPxRaw across 16 real sweep captures (the
  // exact same still-decode-width/2048 domain this live estimate is scaled
  // into, so directly comparable, no unit conversion needed) clusters at
  // 15-30px, mean 26.7, sd 4.3 -- the OLD 16.0 threshold sits almost at the
  // very bottom of sweep's own normal real-world range, not near the top of
  // a good one, so as shipped it would have fired on ~15/16 real captures
  // and spent its whole 3s window without ever resolving, adding latency
  // while gating essentially nothing. Checked whether real matchability
  // (SourceAFIS vs NIST impostors) supports a "closer/lower is better" gate
  // for sweep the way it does for front: it does NOT -- across the 10 real
  // genuine pairs in this same set, per-pair wavelength SCALE MISMATCH
  // (not absolute wavelength) is the only thing that correlates with score
  // (r=-0.27; well-matched pairs mean 17.9 vs mismatched 10.4), and the two
  // single strongest real genuine matches this project has measured
  // (41.5, 42.6) both came from captures sitting at wlRaw~=29 -- the HIGH
  // end of the range, not the low end. Sweep's own fixed per-zone guide
  // geometry already produces that scale consistency for free (mean/sd
  // above), which is the real reason sweep already beats front_only_v1 on
  // matchability (see the sweep-vs-front decision above) -- there's no
  // real evidence a live "get farther back" push adds anything on top of
  // it. Recalibrated as a pure safety backstop instead of an optimization
  // target: set comfortably above the whole observed real range (mean +
  // ~2sd, rounds to 35.0) so it only fires on a genuine, far-outside-normal
  // outlier, never during ordinary use -- can't regress a real capture that
  // used to pass, only catch something new and clearly pathological.
  static const double _liveWavelengthTooHighPx = 35.0;
  static const int _liveWavelengthMinSamples = 3;
  // Same base ROI as front_capture_controller.dart's own _scoreRoi -- valid
  // to share directly because _sweepGuideShapeForProgress(0.5, dyFrac: 0.0)
  // (the 'center' zone, where this gate runs) resolves to EXACTLY
  // PadSilhouetteShape.defaultShape with no offset, the same base shape
  // front's ROI was derived from and kept in sync with.
  static const Rect _scoreRoi =
      Rect.fromLTRB(0.518805, 0.338475, 0.741195, 0.661525);
  // This file's own still-decode width (see _guideRegionForSweepZone's own
  // targetWidth: 2048 call) -- NOT front's 3200. Using the wrong width here
  // would silently scale every live estimate wrong.
  static const int _stillDecodeTargetWidth = 2048;
  // Guide half-width in still-normalized coordinates, set once from
  // _stillSpaceRegionForShape right after _cachedPreviewSize is known (see
  // _run()) -- mirrors front's own one-time _guideRx assignment from
  // _computeGuideRegion at start().
  double _guideRx = 0.13;
  // Bounded extra wait if the gate fires -- capped short deliberately, same
  // "verify, don't just delay" discipline as the gyro steadiness gate above:
  // real margin for a genuinely-too-close user to react to the hint, never
  // a long block on an already-correctly-positioned one (the common case,
  // where _wavelengthTooHigh is false and this window never triggers at all).
  static const int _wavelengthGateExtraMs = 3000;
  static const int _wavelengthGatePollIntervalMs = 300;
  Map<String, dynamic> _wavelengthDebug = {};

  double? _wavelengthScaleToStill(CameraImage image) {
    final roiWidthPx = _scoreRoi.width * image.width;
    if (roiWidthPx <= 0 || _guideRx <= 0) return null;
    return (2 * _guideRx * _stillDecodeTargetWidth) / roiWidthPx;
  }

  bool _disposed = false;

  SweepTestState _state = const SweepTestState();
  SweepTestState get state => _state;
  CameraController? get cameraController => _camera.controller;

  void _emit(SweepTestState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  // ─── Entry point ───────────────────────────────────────────────────────

  Future<void> start(String userId, {required Size screenSize}) async {
    if (_state.phase != SweepTestPhase.idle) return;
    _cachedScreenSize = screenSize;
    _emit(const SweepTestState(phase: SweepTestPhase.initializing));
    try {
      await _run(userId);
    } catch (e, st) {
      debugPrint('[SweepTest] fatal: $e\n$st');
      _emit(_state.copyWith(phase: SweepTestPhase.error, error: e.toString()));
    }
  }

  Future<void> _run(String userId) async {
    await _audio.init();
    await _camera.initializeCamera(
      lensDirection: CameraLensDirection.back,
      resolution: ResolutionPreset.veryHigh,
    );
    final cam = _camera.controller;
    if (cam == null) throw Exception('Camera failed to initialize');
    _sensorOrientation = _camera.selectedCamera?.sensorOrientation ?? 90;
    _cachedPreviewSize = cam.value.previewSize;
    _flash = AdaptiveFlashController(cam);

    // One-time still-space guide half-width for the live wavelength gate
    // below -- 'center' zone (progress=0.5, dyFrac=0.0) is exactly
    // PadSilhouetteShape.defaultShape, so this is the same real geometry
    // _guideRegionForSweepZone already computes per-zone post-capture, just
    // derived synchronously here (screen/preview size are already known)
    // before the gate needs it.
    final gateRegion = _stillSpaceRegionForShape(_sweepGuideShapeForProgress(0.5));
    if (gateRegion != null) _guideRx = gateRegion.rx;

    // Brief real calibration: sample live focus + brightness for a bounded
    // window (same discipline as every other capture in this project --
    // measure, don't assume) before committing to the sweep. Deliberately
    // simpler than clearbridge_beta's own multi-second hold-gate -- this
    // app's whole purpose is isolating the sweep architecture itself, not
    // re-testing the pre-capture readiness gate.
    _emit(_state.copyWith(phase: SweepTestPhase.calibrating, message: 'Reading light + focus…'));
    final calib = await _calibrate(cam);
    _calibBrightness = calib.brightness;
    await _flash!.calibrate(calib.brightness);

    _gyroSub ??= gyroscopeEventStream().listen((event) {
      final degPerSec = math.sqrt(
            event.x * event.x + event.y * event.y + event.z * event.z,
          ) *
          (180.0 / math.pi);
      _gyroMagnitudeDegPerSec = HybridCaptureService.ema(
        _gyroMagnitudeDegPerSec,
        degPerSec,
        alpha: 0.35,
      );
    });

    // ─ Sweep zones: the WHOLE capture ────────────────────────────────────
    // FOURTH ZONE ADDED 2026-08-12. The first three sweep only HORIZONTALLY
    // (cx varies, cy is fixed at PadSilhouetteShape.defaultShape.cy), so no
    // amount of left/right movement can reach the pad's vertical curvature
    // toward the tip -- that region is structurally unreachable by the
    // existing design, not merely under-sampled. 'tip' re-uses the centre
    // column and offsets the guide UP instead, which is the one direction
    // that adds genuinely new pad area.
    //
    // Deliberately anchored at the centre column rather than a corner: the
    // mosaic registers every side against 'center' (see
    // _front_anchored_mosaic_zones, which REQUIRES a 'center' key), and a
    // tip zone sharing the centre's own column keeps maximum overlap with
    // that anchor -- the condition registration actually needs. This is now
    // the safest of the three sides to register, not the riskiest.
    //
    // Ordered last so that if the loop's own timeout ever bites, it costs
    // the NEW zone rather than any of the three already proven to work.
    final basePath = 'captures/$userId/${_uuid.v4()}';
    final zones = <_SweepZone>[
      const _SweepZone('left', 0.0),
      const _SweepZone('center', 0.5),
      const _SweepZone('right', 1.0),
      const _SweepZone('delta', 0.5, dyFrac: -_tipZoneDyFrac),
      // FIFTH ZONE, 2026-08-12, per CTO: a second vertical station BELOW the
      // centre, fired after 'tip', to capture ridge continuity through the
      // fingertip. 'tip' sits ABOVE the centre and this one below, so the two
      // bracket the centre vertically and the three together sample the pad's
      // whole long axis instead of only its width.
      //
      // Which of the two actually exposes more TIP surface is an open
      // question the next real capture settles, and is worth stating plainly
      // rather than assuming: moving the guide moves the USER's thumb to
      // follow it, so the mapping from guide direction to revealed pad
      // surface depends on how the thumb pivots, not on screen direction
      // alone. Both zones therefore record their own framing similarity, and
      // whichever proves redundant can be dropped on evidence. Named by
      // POSITION ('tipLow' = the lower station) rather than by anatomy, so
      // the name cannot encode a guess that turns out backwards.
      const _SweepZone('tip', 0.5, dyFrac: _tipZoneDyFrac),
    ];
    final rawShots = <String, Uint8List>{};
    final guideRegions = <String, Map<String, dynamic>>{};
    final zoneDebug = <String, dynamic>{'liveWavelengthDebug': _wavelengthDebug};
    final stopwatch = Stopwatch()..start();

    _emit(_state.copyWith(
      phase: SweepTestPhase.sweeping,
      distanceHint: 'Place your thumb at the start position',
      sweepProgress: 0.0,
      activeGuideShape: _sweepGuideShapeForProgress(0.0),
    ));
    unawaited(HapticFeedback.lightImpact());
    // Real bug found 2026-08-12: real device data across 3 post-fix captures
    // showed the LEFT zone consistently blurred (no visible ridge detail)
    // while center was reliably sharp -- even after the progress-vs-cx unit
    // fix above. Root cause: 'left' is the FIRST zone processed, so its own
    // _redirectZoneFocus call is the very first real AF rack of the whole
    // capture (calibrate() never sets an explicit focus point), competing
    // for convergence against only 500ms of settle time -- a materially
    // bigger rack than center->right's much shorter re-converge. This exact
    // "first rack needs more time" pattern is why the main app's sweep
    // (front_capture_controller.dart)'s validated round-2 fix redirects
    // focus toward the left-shifted target during its own multi-second
    // "place your thumb" positioning phase, not just a short post-move
    // settle -- ported that same head-start here: kick off the left zone's
    // focus redirect in parallel with this pre-roll delay instead of after
    // it, so AF gets real, uninterrupted convergence time before the zone
    // loop's own (much shorter) settle window even starts.
    unawaited(_redirectZoneFocus(cam, 0.0));
    await Future<void>.delayed(const Duration(milliseconds: _calibrationHoldMs));

    try {
      await (() async {
        // Brightness gate on the torch (CTO's own proposal, 2026-08-12).
        // AdaptiveFlashController only declines the torch above 185 luma,
        // which is far too permissive here: the real capture that prompted
        // this calibrated at 136.5 (flashMode 'normal', torch fired) and
        // every one of its flash frames was measurably useless -- pad-crop
        // high-frequency energy at 0.31-0.63 of the ambient frame's, with
        // anisotropy of only 1.06-1.21x (so not motion blur) and no
        // clipping at all (so not blowout). That signature is the on-axis
        // torch flooding the valley micro-shadows that MAKE ridge contrast,
        // which no exposure or focus tuning can undo -- confirmed by the
        // focus-lock fix landing zero change on those ratios.
        //
        // So the torch only earns its slot when ambient genuinely cannot
        // carry the exposure. Threshold reuses AdaptiveFlashController's
        // OWN already-calibrated night-mode boundary (isNightMode < 80,
        // and its intensity curve steps at 30/80/180) rather than a number
        // fitted to the single capture above -- deliberately, because n=1
        // threshold-fitting is this project's own documented anti-pattern.
        // 100 sits just above that boundary: torch fires in genuinely dim
        // scenes where it is the only light, and stands down in the
        // moderately-lit ones where it only washes ridges out.
        final _ambientCarriesIt = _calibBrightness >= _sweepTorchMaxAmbient;
        final torchCapable = _flash!.isNeeded && !_ambientCarriesIt;
        // GAP FOUND 2026-08-13: this used a flat -0.6 EV step regardless of
        // scene brightness or torch intensity, while
        // front_capture_controller.dart has a real, multi-round-tuned
        // adaptive curve (_adaptiveFlashEvStep) -- interpolated -0.2 to
        // -1.1 by torch intensity, and explicitly SKIPPED in a dark room
        // (ambient < 30/255) because "the torch is already the sole light
        // source and any negative EV step only makes an already-
        // underexposed frame worse". The flat -0.6 had no such skip, so in
        // a genuinely dark scene it was ACTIVELY WRONG, not just untuned --
        // it would darken the one usable light source. Ported the same
        // curve rather than re-deriving a new one for this app.
        //
        // Adaptive EV does not fix the illumination-GEOMETRY problem this
        // session already found (isotropic high-frequency loss from the
        // on-axis torch, confirmed unrelated to exposure -- no clipping in
        // any measured flash frame). It fixes a separate, compounding
        // exposure error that the flat constant could add on top of that
        // geometry problem in specific lighting.
        final flashEvStep = torchCapable ? _adaptiveFlashEvStep() : 0.0;
        double? minEv, maxEv;
        if (torchCapable) {
          try {
            minEv = await cam.getMinExposureOffset();
            maxEv = await cam.getMaxExposureOffset();
          } catch (_) {}
        }
        zoneDebug['torchCapable'] = torchCapable;
        // Recorded 2026-08-12: the flash-softness investigation wanted both
        // of these off a real capture and neither was on the doc (the EV
        // step and the brightness the torch decision was actually made from,
        // which AdaptiveFlashController gates at >=185 whole-frame luma).
        // Cheap, diagnostic-only, no behaviour change.
        zoneDebug['flashEvStep'] = flashEvStep;
        zoneDebug['calibBrightness'] = double.parse(_calibBrightness.toStringAsFixed(1));
        zoneDebug['flashMode'] = _flash!.modeName;
        zoneDebug['torchSkippedForAmbient'] = _ambientCarriesIt;
        unawaited(HapticFeedback.mediumImpact());

        var wasFlashLastShot = false;
        Uint8List? prevZoneFlash;
        var extraMoveMs = 0;

        for (var i = 0; i < zones.length; i++) {
          final zone = zones[i].name;
          final target = zones[i].progress;
          final dy = zones[i].dyFrac;
          if (_disposed) break;

          if (i == 0) {
            _emit(_state.copyWith(
              sweepProgress: target,
              activeGuideShape: _sweepGuideShapeForProgress(target, dyFrac: dy),
            ));
          } else {
            final fromProgress = zones[i - 1].progress;
            final fromDy = zones[i - 1].dyFrac;
            final moveMs = _zoneMoveMs + extraMoveMs;
            final grantedExtra = extraMoveMs > 0;
            if (grantedExtra) {
              zoneDebug['${zone}_extraMoveMsGranted'] = extraMoveMs;
              extraMoveMs = 0;
            }
            _emit(_state.copyWith(
              distanceHint: grantedExtra
                  ? 'Move further this time'
                  : (zone == 'delta'
                      ? 'Slowly move up — showing the lower pad'
                      : (zone == 'tip'
                          ? 'Slowly move down — showing the fingertip'
                          : (zone == 'right'
                              ? 'Slowly move right'
                              : 'Slowly move to the middle'))),
            ));
            final moveStart = DateTime.now();
            while (true) {
              final elapsedMs = DateTime.now().difference(moveStart).inMilliseconds;
              final t = (elapsedMs / moveMs).clamp(0.0, 1.0);
              final progress = fromProgress + (target - fromProgress) * t;
              // Animate the vertical offset alongside the horizontal one so
              // the 'tip' hop reads as one continuous guide movement rather
              // than a jump -- same reasoning as the horizontal tween.
              final dyNow = fromDy + (dy - fromDy) * t;
              _emit(_state.copyWith(
                sweepProgress: progress,
                activeGuideShape:
                    _sweepGuideShapeForProgress(progress, dyFrac: dyNow),
              ));
              if (t >= 1.0) break;
              await Future<void>.delayed(const Duration(milliseconds: 60));
            }
          }

          // Real fix, 2026-08-11: redirect focus/exposure to THIS zone's own
          // on-screen point before firing -- see _redirectZoneFocus's own
          // docstring for why this app never did this before (real device
          // feedback: left/right zones had no focus at all).
          await _redirectZoneFocus(cam, target);
          zoneDebug['${zone}_focusRedirected'] = true;
          if (_disposed) break;

          if (i == 0) {
            unawaited(HapticFeedback.lightImpact());
            _emit(_state.copyWith(distanceHint: 'Hold still — capturing $zone'));
            await Future<void>.delayed(const Duration(milliseconds: _zoneSettleMs));
          } else {
            for (final n in const ['Hold still…', '2…', '1…']) {
              if (_disposed) break;
              _emit(_state.copyWith(distanceHint: n));
              unawaited(HapticFeedback.lightImpact());
              await Future<void>.delayed(const Duration(milliseconds: _calibrationTickMs));
            }
          }
          if (_disposed) break;

          // Motion-blur gate: bounded wait for the gyro to settle below
          // the steadiness threshold before this zone's shutters fire. See
          // the field docs above _gyroSub for why this was missing
          // entirely and why it matters more here than on the main burst.
          final steadyWaitStart = DateTime.now();
          while (_gyroMagnitudeDegPerSec >= _maxSteadyDegPerSec &&
              DateTime.now().difference(steadyWaitStart).inMilliseconds <
                  _steadyWaitMaxMs) {
            if (_disposed) break;
            await Future<void>.delayed(
                const Duration(milliseconds: _steadyPollIntervalMs));
          }
          zoneDebug['${zone}_gyroDegPerSec'] =
              double.parse(_gyroMagnitudeDegPerSec.toStringAsFixed(2));
          if (_disposed) break;

          // Ambient shot.
          try {
            await _flash!.deactivate();
            if (minEv != null && maxEv != null) {
              await cam.setExposureOffset((0.0).clamp(minEv, maxEv));
            }
            if (wasFlashLastShot) {
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            }
          } catch (_) {}
          wasFlashLastShot = false;
          try {
            final xfile = await cam.takePicture();
            rawShots['${zone}_amb'] = await xfile.readAsBytes();
          } catch (e) {
            zoneDebug['${zone}_amb_error'] = e.toString();
          }

          // SECOND ambient shot, same pose, fired immediately after the first
          // (2026-08-12). Real measurement this session: the ambient frame is
          // the only one of the pair carrying usable ridge detail -- the
          // torch-lit frame's high-frequency energy is isotropically
          // attenuated to 0.31-0.63 of ambient's (anisotropy only 1.06-1.21x,
          // ruling out motion blur; no clipping, ruling out blowout), which
          // is the signature of the on-axis torch filling the valley
          // micro-shadows that create ridge contrast in the first place.
          // A second ambient exposure gives the backend a same-pose PAIR it
          // can stack (_stack_face_on / _focus_stack_face_on, both already
          // proven in this pipeline) for real noise reduction -- genuinely
          // new ridge information, unlike the flash frame.
          //
          // Deliberately fired with NO delay and NO settle between the two:
          // exposure/focus/torch state are all unchanged from the shot above,
          // so back-to-back is exactly what makes them a valid same-pose
          // stack, and it keeps the added cost to one shutter (~0.5-0.9s).
          // Focus is locked across the whole zone (see _redirectZoneFocus),
          // so both frames share one converged distance.
          try {
            final xfile = await cam.takePicture();
            rawShots['${zone}_amb2'] = await xfile.readAsBytes();
          } catch (e) {
            // Non-fatal by design: the backend treats amb2 as optional and
            // falls back to the single ambient frame exactly as before.
            zoneDebug['${zone}_amb2_error'] = e.toString();
          }

          // Flash shot. Kept per CTO direction despite measuring as
          // unusable on every capture so far -- the backend's own
          // sharpness-ratio guard already rejects it per-zone when it is
          // too soft, so retaining it costs capture time but cannot cost
          // quality, and it keeps the pair available for the case the
          // guard is designed for (a genuinely comparable flash frame).
          if (torchCapable) {
            try {
              await _flash!.activate();
              if (minEv != null && maxEv != null) {
                await cam.setExposureOffset(flashEvStep.clamp(minEv, maxEv));
              }
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            } catch (_) {}
          }
          wasFlashLastShot = torchCapable;
          try {
            final xfile = await cam.takePicture();
            rawShots['${zone}_fl'] = await xfile.readAsBytes();
          } catch (e) {
            zoneDebug['${zone}_fl_error'] = e.toString();
          }

          final region = _guideRegionForSweepZone(target, dyFrac: dy);
          if (region != null) guideRegions[zone] = region;

          // Real-motion check against the PREVIOUS zone's flash shot --
          // ported from clearbridge_beta's front_capture_controller.dart
          // (2026-08-08 fix). Deliberately does NOT reopen the live camera
          // stream (this project hit a real ANR from repeatedly restarting
          // startImageStream mid-sweep, 2026-07-30) -- compares already-
          // captured JPEGs via decodeStillJpegToLuma, a pure dart:ui decode
          // with no camera-session involvement.
          final thisFlash = rawShots['${zone}_fl'];
          if (thisFlash != null && prevZoneFlash != null) {
            final sim = await _zoneFramingSimilarity(prevZoneFlash, thisFlash);
            if (sim != null) {
              zoneDebug['${zone}_framingSimilarityToPrev'] = double.parse(sim.toStringAsFixed(3));
              if (sim >= _zoneSimilarityThreshold) extraMoveMs = _extraMoveMs;
            }
          }
          if (thisFlash != null) prevZoneFlash = thisFlash;
        }

        try {
          await _flash?.deactivate();
        } catch (_) {}
      }()).timeout(const Duration(milliseconds: _sweepTimeoutMs));
    } catch (e) {
      zoneDebug['sweepError'] = e.toString();
    }
    stopwatch.stop();

    if (rawShots.isEmpty) {
      throw Exception('No zone shots captured');
    }

    _emit(_state.copyWith(phase: SweepTestPhase.uploading, message: 'Uploading…', uploadProgress: 0));
    await _camera.disposeCamera();

    await _uploadAndScore(
      userId: userId,
      basePath: basePath,
      rawShots: rawShots,
      guideRegions: guideRegions,
      zoneDebug: zoneDebug,
      durationMs: stopwatch.elapsedMilliseconds,
    );
  }

  Future<({double brightness, double focus})> _calibrate(CameraController cam) async {
    final completer = Completer<void>();
    double brightness = 128.0;
    var samples = 0;
    void onFrame(CameraImage image) {
      if (_disposed) return;
      try {
        final focus = _hybrid.offerFrame(image, thumbRoi: null);
        if (focus > _focusPeak) _focusPeak = focus;
        _focusValue = (focus / (_focusPeak + 1e-6)).clamp(0.0, 1.0);
        // Cheap mean-luma sample from the Y plane's own bytes, matching the
        // AdaptiveFlashController's own documented brightness convention.
        final plane = image.planes.first.bytes;
        if (plane.isNotEmpty) {
          var sum = 0;
          const stride = 97; // sparse sample, not every pixel
          var n = 0;
          for (var i = 0; i < plane.length; i += stride) {
            sum += plane[i];
            n++;
          }
          if (n > 0) brightness = sum / n;
        }
      } catch (_) {}
      // Live ridge-wavelength sample -- same throttling/EMA/outlier-
      // rejection discipline as front_capture_controller.dart's _onFrame.
      // Runs on every calibration frame regardless of `samples`/completer
      // state (including during the extra gate window below), since this
      // is the ONE stream this file keeps open, and closing/reopening it
      // is the exact thing that caused a real ANR before.
      final now = DateTime.now();
      if (_lastWavelengthEstimateAt == null ||
          now.difference(_lastWavelengthEstimateAt!).inMilliseconds >=
              _wavelengthEstimateIntervalMs) {
        _lastWavelengthEstimateAt = now;
        try {
          final est = HybridCaptureService.estimateRidgeWavelengthPx(image, roi: _scoreRoi);
          if (est != null) {
            final prior = _liveWavelengthPx;
            final isOutlier = prior != null &&
                prior > 0 &&
                (est.medianLagPx > prior * 2.5 || est.medianLagPx < prior / 2.5);
            if (isOutlier && _wavelengthOutlierStreak < 1) {
              _wavelengthOutlierStreak++;
            } else {
              _wavelengthOutlierStreak = 0;
              _liveWavelengthPx = HybridCaptureService.ema(prior ?? est.medianLagPx, est.medianLagPx);
              final scale = _wavelengthScaleToStill(image);
              _liveWavelengthStillPx = scale != null ? _liveWavelengthPx! * scale : null;
              _wavelengthAxis = est.axis;
              _wavelengthSampleCount++;
            }
          }
        } catch (_) {}
      }
      samples++;
      if (samples >= 15 && !completer.isCompleted) completer.complete();
    }

    await cam.setFocusMode(FocusMode.auto);
    await _camera.startImageStream(onFrame);
    await completer.future.timeout(const Duration(milliseconds: 2500), onTimeout: () {});

    // Distance/scale GATE, not just a hint: if the live estimate is already
    // reliable (enough qualifying samples) and reads too-close, give the
    // user a real bounded window to move back before the first zone ever
    // fires -- on the SAME still-open stream, never a second one. Reroutes
    // through the existing distanceHint field the sweep loop already uses
    // for status text, so no new UI plumbing is needed.
    var wavelengthTooHigh = _wavelengthSampleCount >= _liveWavelengthMinSamples &&
        (_liveWavelengthStillPx ?? 0) > _liveWavelengthTooHighPx;
    if (wavelengthTooHigh) {
      unawaited(HapticFeedback.mediumImpact());
      _emit(_state.copyWith(distanceHint: 'Move back slightly'));
      final deadline = DateTime.now().add(const Duration(milliseconds: _wavelengthGateExtraMs));
      while (wavelengthTooHigh && DateTime.now().isBefore(deadline) && !_disposed) {
        await Future.delayed(const Duration(milliseconds: _wavelengthGatePollIntervalMs));
        wavelengthTooHigh = _wavelengthSampleCount >= _liveWavelengthMinSamples &&
            (_liveWavelengthStillPx ?? 0) > _liveWavelengthTooHighPx;
      }
    }

    await _camera.stopImageStream();
    _wavelengthDebug = {
      'liveWavelengthPx': _liveWavelengthPx,
      'liveWavelengthStillPx': _liveWavelengthStillPx,
      'sampleCount': _wavelengthSampleCount,
      'axis': _wavelengthAxis,
      'gateThresholdPx': _liveWavelengthTooHighPx,
      // Whether the wait above actually resolved the too-close reading, or
      // just ran out its bounded window still too-close -- real signal for
      // whether _wavelengthGateExtraMs is long enough in practice, same
      // "measure, don't assume" discipline as the gyro gate's own recorded
      // per-zone readings.
      'gateResolvedInTime': !wavelengthTooHigh,
    };
    return (brightness: brightness, focus: _focusValue);
  }

  // ─── Guide geometry (ported verbatim from front_capture_controller.dart) ─

  PadSilhouetteShape _sweepGuideShapeForProgress(double progress,
      {double dyFrac = 0.0}) {
    const base = PadSilhouetteShape.defaultShape;
    final cx = (0.5 - _sweepGuideShiftFrac) + (2 * _sweepGuideShiftFrac) * progress.clamp(0.0, 1.0);
    return PadSilhouetteShape(
      cx: cx,
      cy: (base.cy + dyFrac).clamp(0.0, 1.0),
      rx: base.rx,
      ry: base.ry,
      n: base.n,
      taper: base.taper,
      coreTargetDyFrac: base.coreTargetDyFrac,
      coreTargetDxFrac: base.coreTargetDxFrac,
    );
  }

  ({double cx, double cy, double rx, double ry})? _stillSpaceRegionForShape(
    PadSilhouetteShape shape,
  ) {
    final screenSize = _cachedScreenSize;
    final previewSize = _cachedPreviewSize;
    if (screenSize == null || previewSize == null) return null;
    final wp = previewSize.height;
    final hp = previewSize.width;
    final ws = screenSize.width;
    final hs = screenSize.height;
    if (wp <= 0 || hp <= 0 || ws <= 0 || hs <= 0) return null;
    final scale = math.max(ws / wp, hs / hp);
    final offX = (wp * scale - ws) / 2;
    final offY = (hp * scale - hs) / 2;

    Offset toStill(double su, double sv) {
      final previewU = ((su * ws) + offX) / scale / wp;
      final previewV = ((sv * hs) + offY) / scale / hp;
      return Offset(1.0 - previewV, previewU);
    }

    final center = toStill(shape.cx, shape.cy);
    final top = toStill(shape.cx, shape.cy - shape.ry);
    final bottom = toStill(shape.cx, shape.cy + shape.ry);
    final left = toStill(shape.cx - shape.rx, shape.cy);
    final right = toStill(shape.cx + shape.rx, shape.cy);
    final xs = [top.dx, bottom.dx, left.dx, right.dx];
    final ys = [top.dy, bottom.dy, left.dy, right.dy];
    return (
      cx: center.dx,
      cy: center.dy,
      rx: (xs.reduce(math.max) - xs.reduce(math.min)) / 2,
      ry: (ys.reduce(math.max) - ys.reduce(math.min)) / 2,
    );
  }

  // REAL BUG FOUND 2026-08-12, second round: the previous "raw-buffer,
  // 90°CW-rotated" formula (ROI-based, X fixed at ~0.5, Y swept with the
  // zone) was carried over from front_capture_controller.dart's
  // sweepPositioning phase under the assumption that setFocusPoint/
  // setExposurePoint take raw sensor-buffer coordinates. Fixing the
  // progress-vs-cx unit mismatch (previous commit) and adding a left-zone
  // pre-roll + wider settle (also previous commit) BOTH assumed that
  // rotated formula was fundamentally correct and just needed better
  // inputs/timing -- but real device data after BOTH fixes still showed
  // left AND right consistently blurred, only center sharp, across 2 more
  // real captures. That rules out a timing/unit explanation: the target
  // POINT itself must be wrong.
  //
  // Re-examined the assumption itself: this exact file's `camera` package
  // (and every other real call site in front_capture_controller.dart, e.g.
  // `_beginAutofocus`'s `_focusPointScreenSpace` -- the MAIN hold's own
  // focus point, fired on every single real capture this whole project and
  // never once reported broken) already documents, and the official
  // `camera`/`camera_android_camerax` plugin API itself specifies, that
  // setFocusPoint/setExposurePoint take PREVIEW-space coordinates: (0,0)
  // top-left, (1,1) bottom-right of what's actually rendered on screen --
  // the SAME space the on-screen guide itself is drawn in, no rotation.
  // The "raw buffer" theory was never actually validated against this --
  // it only ever needed to explain a single always-centred point
  // (_focusPointScreenSpace) or a case (sweepPositioning's real device
  // test) where simply re-triggering continuous AF at all, after it had
  // been stuck locked, was itself already a big enough improvement to look
  // like confirmation regardless of whether the exact point was right.
  // Both hypotheses are mathematically IDENTICAL at cx=0.5 (center) --
  // which is exactly the one zone that has ever focused correctly here,
  // so "center works" was never evidence either way.
  //
  // Fix: return the guide's own on-screen (cx, cy) directly, no ROI/
  // rotation math at all -- the same convention `_beginAutofocus` already
  // uses successfully.
  Offset _sweepFocusPointFor(double cx) {
    const base = PadSilhouetteShape.defaultShape;
    return Offset(cx.clamp(0.0, 1.0), base.cy);
  }

  /// Real gap found 2026-08-11: this app's `_calibrate()` sets continuous
  /// AF once, before the sweep even starts, and NEVER redirects focus
  /// again for the rest of the run -- unlike front_capture_controller.dart,
  /// this file never even had the (unused) infrastructure to target a
  /// per-zone focus point. Real device feedback: "sweep struggles to focus
  /// on left and right sweep, only center has focus" -- exactly what
  /// "focus never re-targeted after the initial calibration point" would
  /// produce, since center is the zone closest to wherever that initial
  /// point happened to land.
  ///
  /// Deliberately does NOT poll a live image-stream signal to verify
  /// convergence the way front_capture_controller.dart's `_verifyZoneReady`
  /// does -- this file's own header comment already documents a real ANR
  /// from reopening `startImageStream` mid-sweep (2026-07-30), which is
  /// exactly what a live poll would require. Redirects focus/exposure to
  /// the zone's own point instead, then waits a fixed, bounded settle
  /// time -- same class of fix as `_refocus()`'s ORIGINAL version before
  /// its own verification upgrade, chosen here specifically because the
  /// stream-free constraint rules out the more rigorous polling approach.
  //
  // Widened 500->900ms, 2026-08-12: real device data showed the RIGHT zone
  // intermittently blurred (sharp in 1 of 3 post-fix test captures, blurred
  // in the other 2) -- consistent with a rack that's usually, but not
  // reliably, done converging within 500ms, rather than a systematic
  // targeting error (which would fail every time, the way LEFT did -- see
  // the left-zone pre-roll fix above). A blind bound can't guarantee
  // convergence the way real polling would, but 900ms roughly matches the
  // main app's own real-device-tuned ticks+extraMaxMs budget for the same
  // per-zone re-converge step, without reintroducing the image-stream ANR
  // risk this function is deliberately built to avoid.
  static const int _zoneFocusSettleMs = 900;

  // Real ANR reported 2026-08-11, the very next real device test after this
  // function shipped ("Sweep Test isn't responding"): three raw, unbounded
  // native platform-channel calls, the exact same class of bug already
  // found and fixed for camera disposal in the shared CameraService this
  // same night. Each call gets its own bound so one slow call can't eat
  // the other two's budget either.
  static const Duration _zoneFocusCallTimeout = Duration(seconds: 3);

  Future<void> _redirectZoneFocus(CameraController cam, double zoneProgress) async {
    // Real bug found 2026-08-12 (device feedback: "left/right zones out of
    // focus, front zone is perfect" -- ported fix, see
    // front_capture_controller.dart's _verifyZoneReady for the full
    // diagnosis): _sweepFocusPointFor's parameter is the guide's on-screen
    // CX fraction (~0.35-0.65), not the raw zone progress (0.0/0.5/1.0) --
    // they only coincide at progress=0.5, which is exactly why center
    // focused fine while left/right did not. Convert through the guide
    // shape lookup, same as every other real call site.
    final cx = _sweepGuideShapeForProgress(zoneProgress).cx;
    final pt = _sweepFocusPointFor(cx);
    try {
      await cam.setFocusMode(FocusMode.auto).timeout(_zoneFocusCallTimeout);
    } catch (_) {}
    try {
      await cam.setFocusPoint(pt).timeout(_zoneFocusCallTimeout);
    } catch (_) {}
    try {
      await cam.setExposurePoint(pt).timeout(_zoneFocusCallTimeout);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: _zoneFocusSettleMs));
    // REAL BUG, found 2026-08-12 by measuring the flash frames rather than
    // assuming: every zone's flash shot is optically SOFT (pad-crop Laplacian
    // 3.2-31.8) while its own ambient shot, fired ~70ms earlier from the same
    // position, is SHARP (30.0-105.2) -- up to a 16x gap on the same zone.
    // Exposure is NOT the cause: the flash frames carry essentially no
    // clipping (>=250 at 0.00-0.89%, and the very softest frame of all,
    // 4a1c4d89/center at Laplacian 3.2, has 0.00% clipped and 0.00% even
    // above 240) and no crushed shadows anywhere. Correctly exposed but
    // detail-free is the signature of focus/motion, not blowout.
    //
    // Structural cause: this controller only ever sets FocusMode.auto
    // (continuous) and never locks -- there is no FocusMode.locked anywhere
    // in this file. So between the ambient and flash shots, the torch turns
    // on and changes scene brightness dramatically, and continuous AF is
    // free to start hunting right as the flash frame fires. The main app's
    // burst has always locked focus before firing for exactly this reason
    // (_refocus's auto -> settle -> _lockFocusOnly cycle); this file never
    // ported that half. Locking after the settle keeps the whole ambient+
    // flash pair on the one converged distance -- which also preserves the
    // same-pose premise _fuse_flash_ambient depends on. The next zone's own
    // _redirectZoneFocus call re-enables FocusMode.auto as its first step,
    // so the lock is scoped to one zone and cannot leak forward.
    try {
      await cam.setFocusMode(FocusMode.locked).timeout(_zoneFocusCallTimeout);
    } catch (_) {}
  }

  Map<String, dynamic>? _guideRegionForSweepZone(double progress,
      {double dyFrac = 0.0}) {
    final region = _stillSpaceRegionForShape(
        _sweepGuideShapeForProgress(progress, dyFrac: dyFrac));
    if (region == null) return null;
    return {
      'cx': region.cx,
      'cy': region.cy,
      'rx': region.rx,
      'ry': region.ry,
      'n': _guideN,
      'tipAngleDeg': (_sensorOrientation == 90 || _sensorOrientation == 270) ? 0.0 : 90.0,
    };
  }

  /// See front_capture_controller.dart's _zoneFramingSimilarity (2026-08-08)
  /// for the full real-bug writeup this targets. Ported verbatim.
  Future<double?> _zoneFramingSimilarity(Uint8List a, Uint8List b) async {
    try {
      final da = await decodeStillJpegToLuma(a, _sensorOrientation, targetWidth: 80);
      final db = await decodeStillJpegToLuma(b, _sensorOrientation, targetWidth: 80);
      if (da == null || db == null) return null;
      if (da.width != db.width || da.height != db.height) return null;
      final n = da.luma.length;
      if (n == 0) return null;
      double sumA = 0, sumB = 0;
      for (var i = 0; i < n; i++) {
        sumA += da.luma[i];
        sumB += db.luma[i];
      }
      final meanA = sumA / n, meanB = sumB / n;
      double cov = 0, varA = 0, varB = 0;
      for (var i = 0; i < n; i++) {
        final da_ = da.luma[i] - meanA;
        final db_ = db.luma[i] - meanB;
        cov += da_ * db_;
        varA += da_ * da_;
        varB += db_ * db_;
      }
      final denom = math.sqrt(varA * varB);
      if (denom < 1e-6) return null;
      return (cov / denom).clamp(-1.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  // ─── Upload + trigger ──────────────────────────────────────────────────

  Future<void> _uploadAndScore({
    required String userId,
    required String basePath,
    required Map<String, Uint8List> rawShots,
    required Map<String, Map<String, dynamic>> guideRegions,
    required Map<String, dynamic> zoneDebug,
    required int durationMs,
  }) async {
    // Decode + re-encode every shot at reduced quality, SEQUENTIALLY --
    // real bug already found and fixed in clearbridge_beta (concurrent
    // compute() isolates starve each other on a mobile CPU).
    final encoded = <String, Uint8List>{};
    for (final entry in rawShots.entries) {
      try {
        final decoded = await decodeStillJpegToLuma(
          entry.value, _sensorOrientation, targetWidth: 2048,
        ).timeout(const Duration(milliseconds: _zoneEncodeTimeoutMs));
        if (decoded != null) {
          final jpeg = await compute(_encodeIsolate,
              _EncodeArgs(decoded.luma, decoded.width, decoded.height));
          encoded[entry.key] = jpeg;
        }
      } catch (e) {
        zoneDebug['${entry.key}_encodeError'] = e.toString();
      }
    }

    // Upload sequentially (real bug already found in clearbridge_beta:
    // concurrent uploads split one constrained mobile pipe and starve
    // each other).
    var completed = 0;
    for (final entry in encoded.entries) {
      try {
        final task = FirebaseStorage.instance
            .ref()
            .child('$basePath/sweep_burst_${entry.key}.jpg')
            .putData(entry.value, SettableMetadata(contentType: 'image/jpeg'));
        await task.timeout(const Duration(milliseconds: _zoneUploadTimeoutMs), onTimeout: () {
          unawaited(task.cancel().catchError((_) => false));
          throw TimeoutException('zone upload timed out');
        });
      } catch (e) {
        zoneDebug['${entry.key}_uploadError'] = e.toString();
      }
      completed++;
      _emit(_state.copyWith(uploadProgress: completed / encoded.length));
    }

    // Repurpose the CENTER zone's own ambient+flash pair as this request's
    // `frames` field -- _download_front_only_frames (main.py) requires a
    // non-empty `frames` array to run at all, and center is the zone
    // closest to the standard (non-swept) guide position, so it's the
    // most representative single "main burst" stand-in available without
    // capturing a genuinely separate burst (which would reintroduce the
    // exact "layered after" problem this app exists to remove).
    final framesMeta = <Map<String, dynamic>>[];
    if (encoded.containsKey('center_amb')) {
      framesMeta.add({
        'path': '$basePath/sweep_burst_center_amb.jpg',
        'angleDeg': 0.0,
        'flashOn': false,
        'type': 'burst',
      });
    }
    if (encoded.containsKey('center_fl')) {
      framesMeta.add({
        'path': '$basePath/sweep_burst_center_fl.jpg',
        'angleDeg': 0.0,
        'flashOn': true,
        'type': 'burst',
      });
    }
    if (framesMeta.isEmpty) {
      throw Exception('Center zone never captured -- nothing to score');
    }

    // sweepBurstDebug in the SAME schema main.py already reads (2026-08-05
    // ambient+flash-pair format) -- no backend change needed for this app
    // to be scored by the existing, already-deployed sweep-burst pipeline.
    final paths = <String, String>{};
    for (final key in encoded.keys) {
      paths[key] = '$basePath/sweep_burst_$key.jpg';
    }
    final sweepBurstDebug = {
      'attempted': true,
      'uploaded': true,
      'durationMs': durationMs,
      'paths': paths,
      'guideRegions': guideRegions,
      'zones': zoneDebug,
    };

    final centerGuide = guideRegions['center'] ??
        {'cx': 0.63, 'cy': 0.5, 'rx': 0.1112, 'ry': 0.083, 'n': _guideN, 'tipAngleDeg': 0.0};

    final id = Uri.parse(basePath).pathSegments.last;
    await FirebaseFirestore.instance.collection('captures').doc(id).set({
      'captureId': id,
      'userId': userId,
      'createdAt': FieldValue.serverTimestamp(),
      'status': 'pending',
      'source': 'sweep_capture_test',
      'captureMode': 'front_only_v1',
      'captureMethod': 'sweep_burst_standalone',
      'guideRegion': centerGuide,
      'frames': framesMeta,
      'sweepBurstDebug': sweepBurstDebug,
    }, SetOptions(merge: true));

    try {
      await FirebaseFunctions.instanceFor(region: 'africa-south1')
          .httpsCallable('processEnhanceAndScore')
          .call({
        'captureId': id,
        'userId': userId,
        'basePath': basePath,
        'captureMode': 'front_only_v1',
      });
    } catch (e) {
      debugPrint('[SweepTest] processEnhanceAndScore trigger failed: $e');
    }

    await _audio.playAngleSuccess(isFinal: true);
    _emit(_state.copyWith(phase: SweepTestPhase.complete, captureId: id, uploadProgress: 1.0));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_gyroSub?.cancel());
    _gyroSub = null;
    _audio.dispose();
    _camera.disposeCamera();
    super.dispose();
  }
}

class _EncodeArgs {
  final Uint8List luma;
  final int width;
  final int height;
  const _EncodeArgs(this.luma, this.width, this.height);
}

Uint8List _encodeIsolate(_EncodeArgs args) {
  return encodeGrayscaleJpeg(
    args.luma, args.width, args.height,
    quality: SweepCaptureController._zoneJpegQuality,
  );
}

enum SweepTestPhase { idle, initializing, calibrating, sweeping, uploading, complete, error }

class SweepTestState {
  final SweepTestPhase phase;
  final String message;
  final String distanceHint;
  final double sweepProgress;
  final PadSilhouetteShape? activeGuideShape;
  final double uploadProgress;
  final String? captureId;
  final String? error;

  const SweepTestState({
    this.phase = SweepTestPhase.idle,
    this.message = '',
    this.distanceHint = '',
    this.sweepProgress = 0.0,
    this.activeGuideShape,
    this.uploadProgress = 0.0,
    this.captureId,
    this.error,
  });

  SweepTestState copyWith({
    SweepTestPhase? phase,
    String? message,
    String? distanceHint,
    double? sweepProgress,
    PadSilhouetteShape? activeGuideShape,
    double? uploadProgress,
    String? captureId,
    String? error,
  }) =>
      SweepTestState(
        phase: phase ?? this.phase,
        message: message ?? this.message,
        distanceHint: distanceHint ?? this.distanceHint,
        sweepProgress: sweepProgress ?? this.sweepProgress,
        activeGuideShape: activeGuideShape ?? this.activeGuideShape,
        uploadProgress: uploadProgress ?? this.uploadProgress,
        captureId: captureId ?? this.captureId,
        error: error ?? this.error,
      );
}
