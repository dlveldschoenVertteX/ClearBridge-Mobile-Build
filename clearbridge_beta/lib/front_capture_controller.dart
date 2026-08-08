import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback, MethodChannel;
import 'package:mac_capture/mac_capture.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum FrontCapturePhase {
  idle,
  calibrating,
  holding,
  // Guided thumb-sweep capture (2026-07-30, diagnostic-first): two phases
  // inserted between the existing on-target focus-lock (end of `holding`)
  // and the burst actually firing. Replaces "hold still -> fire
  // immediately" with "sweep left-to-right -> fire as qualifying frames
  // pass" -- the burst mechanics themselves (8 shots, Laplacian gate, flash
  // alternation, encode/upload) are unchanged, only the trigger/pacing is
  // new. See FrontCaptureController's _beginSweepPositioning/_beginSweepActive.
  sweepPositioning,
  sweepActive,
  capturing,
  // Primary burst is done and already scored well enough to keep — now
  // grabbing best-effort secondary-camera (IR/ultrawide) and distance-stage-2
  // bonus shots of the SAME thumb placement. Distinct from `uploading` so the
  // UI can tell the user to hold still instead of implying capture is
  // already finished (see the 2026-07-17 "fires blindly" report: the extra
  // torch shots used to fire while the phase already said "Uploading…", so
  // the user had already moved/looked away).
  capturingExtra,
  uploading,
  complete,
  error,
}

class FrontCaptureState {
  const FrontCaptureState({
    this.phase = FrontCapturePhase.idle,
    this.onTarget = false,
    this.holdProgress = 0.0,
    this.isCapturingBurst = false,
    this.burstProgress = 0.0,
    this.extraProgress = 0.0,
    this.uploadProgress = 0.0,
    this.captureId,
    this.error,
    this.confirmationText,
    this.distanceHint,
    this.isSteady = true,
    this.lightingValue = 0.5,
    this.activeGuideShape,
    this.sweepProgress = 0.0,
    this.sweepCentroidX,
    this.sweepFastWarning = false,
    this.sweepPositionOk = false,
    this.sweepDwellProgress = 0.0,
    this.videoSweepActive = false,
  });

  final FrontCapturePhase phase;
  final bool onTarget;
  final double holdProgress;
  final bool isCapturingBurst;
  // Guided thumb-sweep (sweepPositioning/sweepActive phases): the thumb's
  // last-known intensity-weighted centroid X position, normalized 0.0 (left
  // edge of the guide ROI) to 1.0 (right edge) -- drives both the moving
  // highlight on the horizontal band overlay and the fill of the sweep
  // progress bar (sweepProgress mirrors it 1:1; kept as a separate field so
  // the UI can read "progress" without knowing it's just the raw centroid).
  final double sweepProgress;
  final double? sweepCentroidX;
  // True when the current frame's sharpness is below the fire-gate
  // threshold during sweepActive -- drives the highlight's orange
  // "moving too fast" state (green otherwise).
  final bool sweepFastWarning;
  // True during sweepPositioning once the thumb's centroid is actually
  // inside the left zone (dwelling, about to transition to sweepActive) --
  // real device-test feedback (2026-07-30 round 3): with no visible signal
  // that positioning was even being evaluated, a stuck sweep looked
  // identical to a working-but-slow one ("just static"). Drives a text/
  // colour change in the UI so detection is visibly happening.
  final bool sweepPositionOk;
  // Fraction (0..1) of the left-zone dwell timer elapsed during
  // sweepPositioning -- drives the outer progress ring so it fills (silver,
  // matching the classic burst-progress look) as soon as the thumb reaches
  // the left zone, instead of sitting empty the whole time positioning is
  // in progress.
  final double sweepDwellProgress;
  // Fraction of the main burst fired so far (0..1) -- drives the pad-guide
  // fill animation during FrontCapturePhase.capturing, same "fills up as
  // capture progresses" cue the oscillating dial's scan-fill arc already
  // gives (CTO real-device feedback 2026-07-20: front_only_v1 had no
  // equivalent progress indicator).
  final double burstProgress;
  // Fraction of the "extra capture" work done during FrontCapturePhase.
  // capturingExtra (secondary cameras + the distance-stage-2 attempt) --
  // drives the pad-guide fill during that phase. CTO real-device feedback
  // 2026-07-22: unlike the main burst, secondary cameras (wide lens/IR) had
  // no progress cue at all -- the guide sat static the whole time.
  final double extraProgress;
  final double uploadProgress;
  final String? captureId;
  final String? error;
  final String? confirmationText;
  final String? distanceHint;
  // False while the device is being held too unsteadily (gyroscope-derived)
  // for the hold timer to progress -- surfaced separately from onTarget so
  // the UI can tell the user specifically to hold the phone still, distinct
  // from "align your thumb".
  final bool isSteady;
  // Normalised 0..1 brightness read from the ROI (torch-off samples only),
  // for the lighting meter alongside the focus meter.
  final double lightingValue;
  // Overrides the on-screen guide shape during the sweep-burst zone
  // sequence (see FrontCaptureController._sweepGuideShapeForProgress) --
  // null means "use PadSilhouetteShape.defaultShape".
  final PadSilhouetteShape? activeGuideShape;
  // True only while the burst+sweep hybrid capture's zone sequence is
  // actively moving/capturing (see FrontCaptureController._captureSweepBurst
  // -- name predates the 2026-08-03 switch from a video recording to real
  // per-zone stills, kept as-is since it's just a UI-driving flag, not a
  // capture-mechanism label). Drives the screen's directional arrow cue.
  // Reuses sweepProgress/activeGuideShape (already existed for the disabled
  // guided-sweep feature) to animate the guide left-to-right in sync with
  // the real zone sequence; this flag is what tells the screen those fields
  // mean "sweep in progress" rather than their old sweepPositioning/
  // sweepActive meaning (which never applies here -- this step runs during
  // capturingExtra, not those phases).
  final bool videoSweepActive;

  FrontCaptureState copyWith({
    FrontCapturePhase? phase,
    bool? onTarget,
    double? holdProgress,
    bool? isCapturingBurst,
    double? burstProgress,
    double? extraProgress,
    double? uploadProgress,
    Object? captureId = _sentinel,
    Object? error = _sentinel,
    Object? confirmationText = _sentinel,
    Object? distanceHint = _sentinel,
    bool? isSteady,
    double? lightingValue,
    Object? activeGuideShape = _sentinel,
    double? sweepProgress,
    Object? sweepCentroidX = _sentinel,
    bool? sweepFastWarning,
    bool? sweepPositionOk,
    double? sweepDwellProgress,
    bool? videoSweepActive,
  }) =>
      FrontCaptureState(
        phase: phase ?? this.phase,
        onTarget: onTarget ?? this.onTarget,
        holdProgress: holdProgress ?? this.holdProgress,
        isCapturingBurst: isCapturingBurst ?? this.isCapturingBurst,
        burstProgress: burstProgress ?? this.burstProgress,
        extraProgress: extraProgress ?? this.extraProgress,
        uploadProgress: uploadProgress ?? this.uploadProgress,
        captureId: identical(captureId, _sentinel) ? this.captureId : captureId as String?,
        error: identical(error, _sentinel) ? this.error : error as String?,
        confirmationText: identical(confirmationText, _sentinel)
            ? this.confirmationText
            : confirmationText as String?,
        distanceHint:
            identical(distanceHint, _sentinel) ? this.distanceHint : distanceHint as String?,
        isSteady: isSteady ?? this.isSteady,
        lightingValue: lightingValue ?? this.lightingValue,
        activeGuideShape: identical(activeGuideShape, _sentinel)
            ? this.activeGuideShape
            : activeGuideShape as PadSilhouetteShape?,
        sweepProgress: sweepProgress ?? this.sweepProgress,
        sweepCentroidX: identical(sweepCentroidX, _sentinel)
            ? this.sweepCentroidX
            : sweepCentroidX as double?,
        sweepFastWarning: sweepFastWarning ?? this.sweepFastWarning,
        sweepPositionOk: sweepPositionOk ?? this.sweepPositionOk,
        sweepDwellProgress: sweepDwellProgress ?? this.sweepDwellProgress,
        videoSweepActive: videoSweepActive ?? this.videoSweepActive,
      );
}

const _sentinel = Object();

class _BurstEncodeArgs {
  final Uint8List luma;
  final int width;
  final int height;
  // Defaults to encodeGrayscaleJpeg's own default (90) -- only the sweep-
  // zone encode call site passes a lower value (see _sweepZoneJpegQuality)
  // to keep those single-candidate stills' encode/upload time bounded now
  // that they're captured at full (unzoomed) frame detail.
  final int quality;
  // Still-space (normalized 0-1) crop to restrict _stillLaplacianVariance
  // to, added 2026-08-06 -- see that function's docstring for the real bug
  // this fixes. Null means whole-frame (the original, still-confounded
  // behaviour) -- only the main-burst call site passes one.
  final Rect? sharpnessRoi;
  const _BurstEncodeArgs(this.luma, this.width, this.height,
      {this.quality = 90, this.sharpnessRoi});
}

class _BurstEncodeResult {
  final Uint8List jpeg;
  final double sharpness;
  const _BurstEncodeResult(this.jpeg, this.sharpness);
}

/// REAL BUG, found 2026-08-03 auditing a capture where every one of the 8
/// main-burst frames' `laplacianScore` came back byte-for-byte identical
/// (138.2). Root cause: `_fireBurst` calls `_stopStream()` ONCE before the
/// whole 8-shot loop (line ~2152, to avoid contending with takePicture()),
/// but each shot's `laplacianScore` was read from `_focusValue`/`_focusPeak`
/// -- fields only ever updated by the live image-stream callback. With the
/// stream stopped for the entire burst, those fields are frozen at whatever
/// they read the instant before the first shot, so every shot recorded the
/// SAME stale pre-burst value -- not a coincidence, a structural guarantee.
/// This is very likely the same root cause behind this project's own
/// already-documented finding that "the CLIENT laplacianScore is an
/// unreliable whole-preview-frame proxy... observed identical across a
/// burst" (round 11's rejected ambient-vs-flash priority swap) -- that
/// symptom was previously treated as an unexplained proxy limitation, never
/// traced to this specific stream-stopped freeze.
///
/// Fixed by computing a REAL per-frame sharpness score from each frame's
/// own decoded still (the same Welford's-online-variance 4-neighbour
/// Laplacian already proven in frame_capture_service.dart's
/// `_computeThumbFocus`, just re-targeted at a decoded still buffer instead
/// of a live CameraImage plane) -- piggybacked onto the JPEG re-encode's
/// existing isolate hop (see _encodeBurstWithSharpnessIsolate) so this adds
/// no extra isolate spawn. Only used for the main burst's own frames; the
/// sweep-zone/detail-zoom call sites still use the plain _encodeBurstIsolate
/// since they don't feed this per-frame-ranking metadata.
///
/// SECOND real bug found + fixed 2026-08-06, same family as the one above:
/// this scanned the WHOLE decoded still with no ROI restriction at all --
/// unlike the LIVE preview meter (frame_capture_service.dart's
/// estimateRidgeWavelengthPx/_computeThumbFocus, both take a `thumbRoi`),
/// this final-still metric was confounded by whatever's in the BACKGROUND,
/// not just the thumb. Confirmed via two real captures scored catastrophic
/// NFIQ2 (3 and 5) with `refocusDebug.converged: false`: downloading and
/// visually inspecting the raw frames showed the thumb pad ridges were
/// actually reasonably visible in both, while a real capture that scored 95
/// had a comparably-small thumb in frame but a heavily textured background
/// (patterned fabric) -- the two failing captures' backgrounds were a plain
/// painted wall. A richly-textured background can inflate this score
/// regardless of thumb sharpness; a plain one can sink it regardless of how
/// sharp the thumb actually is -- and this score is what the app uses
/// throughout to pick "sharpest ambient"/"sharpest flash" per shot. `roi`
/// (still-space, normalized 0-1, same convention as guideRegion) restricts
/// the scan to the guide's own bounding box when supplied; null preserves
/// the original whole-frame behaviour for callers that don't have a guide
/// region available.
double _stillLaplacianVariance(Uint8List luma, int width, int height, {Rect? roi}) {
  if (width < 4 || height < 4) return 0.0;
  var x0 = 1, y0 = 1, x1 = width - 1, y1 = height - 1;
  if (roi != null) {
    x0 = (roi.left * width).clamp(1, width - 2).round();
    y0 = (roi.top * height).clamp(1, height - 2).round();
    x1 = (roi.right * width).clamp(x0 + 1, width - 1).round();
    y1 = (roi.bottom * height).clamp(y0 + 1, height - 1).round();
  }
  var mean = 0.0;
  var m2 = 0.0;
  var n = 0;
  for (var y = y0; y < y1; y += 2) {
    final row = y * width;
    final up = (y - 1) * width;
    final dn = (y + 1) * width;
    for (var x = x0; x < x1; x += 2) {
      final c = luma[row + x];
      final lap = (4 * c - luma[row + x - 1] - luma[row + x + 1] - luma[up + x] - luma[dn + x])
          .toDouble();
      n++;
      final d = lap - mean;
      mean += d / n;
      m2 += d * (lap - mean);
    }
  }
  return n > 1 ? m2 / (n - 1) : 0.0;
}

_BurstEncodeResult _encodeBurstWithSharpnessIsolate(_BurstEncodeArgs args) => _BurstEncodeResult(
      encodeGrayscaleJpeg(args.luma, args.width, args.height, quality: args.quality),
      _stillLaplacianVariance(args.luma, args.width, args.height, roi: args.sharpnessRoi),
    );

Uint8List _encodeBurstIsolate(_BurstEncodeArgs args) =>
    encodeGrayscaleJpeg(args.luma, args.width, args.height, quality: args.quality);

class _RawShot {
  final Uint8List jpeg;
  final bool flashOn;
  final double? laplacianScore;
  final DateTime timestamp;
  // Real per-shot exposure time/ISO read straight out of the JPEG's own
  // EXIF (see JpegExposureExif) -- what the auto-exposure pipeline actually
  // did, not anything the app requested.
  final JpegExposureExif exif;
  // Per-shot device rotation rate (deg/s, EMA-smoothed), sampled at the
  // moment THIS shot fired -- added 2026-08-06. Previously only one gyro
  // value reached the backend, snapshotted once at hold-completion
  // (gyroMagnitudeDegPerSec at the top level of the capture doc), which
  // says nothing about whether any INDIVIDUAL shot inside the 8-shot burst
  // was captured mid-shake. The backend's fusion functions (ECC alignment
  // in _stack_face_on/_focus_stack_face_on) currently have no per-frame
  // motion signal at all -- they only ever see the pixels themselves.
  final double? gyroMagnitudeDegPerSec;
  const _RawShot({
    required this.jpeg,
    required this.flashOn,
    required this.laplacianScore,
    required this.timestamp,
    this.exif = const JpegExposureExif(),
    this.gyroMagnitudeDegPerSec,
  });
}

/// Front-only single-burst capture controller.
///
/// Simplified flow: camera opens → calibrate → user seats thumb in guide →
/// auto-fire burst (ambient+flash pairs) → upload → processEnhanceAndScore.
///
/// captureMode='front_only_v1' so the backend's dedicated front-only downloader
/// picks it up (no SfM reconstruction, no oscillation, pure AFIS single-frame
/// + deep-fuse variants).
class FrontCaptureController extends ChangeNotifier {
  // 4 ambient + 4 flash. Bumped from 4 (2+2): a bigger candidate pool raises
  // the odds afis_print's ridge-energy single-frame selection lands on a
  // genuinely sharp shot -- the real-data pattern behind this project's best
  // scores (four-angle/oscillating captures with 12-24 total frames vastly
  // outscored front-only's fixed 4) -- and gives the deepFuse variant (now
  // wired in for front_only_v1) a real multi-frame stack per illumination
  // instead of the bare 2-frame minimum.
  static const int _burstFrameCount = 8;
  static const int _burstShotDelayMs = 0;

  // Burst+sweep hybrid capture (2026-08-03, see
  // docs/BURST_VIDEO_HYBRID_SCOPE.md): best-effort extra stills captured at
  // three positions (left/centre/right) while the guide sweeps across the
  // screen, giving the backend off-centre candidate frames the static
  // burst/hold can never capture.
  //
  // Originally shipped as a 9s VIDEO recording with candidate frames
  // extracted backend-side (_extract_video_zone_candidates in main.py) --
  // replaced 2026-08-03 after real device-test data (captures 9408bb2a,
  // 1febdba7) showed every extracted video-zone frame scored Laplacian
  // 23-59, vs 311-327 for plain main-burst stills on the SAME captures.
  // Root cause is structural, not tunable: 30fps video gives each frame
  // only ~33ms exposure (vs a still's proper exposure time), and H.264
  // compression further softens detail relative to an uncompressed JPEG
  // still. Not one real sweep-zone candidate ever won selection across
  // either capture. Firing real JPEG stills at each zone (this file's own
  // main/secondary bursts' own proven approach) removes both problems at
  // the source instead of trying to extract more signal out of an
  // intrinsically lower-quality source.
  //
  // The guide motion/timing UX itself (calibration hold, count-in, smooth
  // left-to-right translation, direction-arrow cue) is unchanged from the
  // video version -- only WHAT fires at each stop changed.
  static const int _sweepCalibrationHoldMs = 1500;
  static const int _sweepCalibrationTickMs = 700;
  // Time to animate the guide translating from one zone to the next
  // (left->centre, centre->right) -- gives the user's eye + thumb real time
  // to track the motion, same real-time-to-react reasoning as the former
  // video version's 9s full-sweep duration, just now split across 2
  // transitions instead of one continuous motion.
  //
  // Scaled up proportionally (1400->3100, same ~2.24x ratio as
  // _sweepGuideShiftFrac's own increase, 2026-08-03) when the left/right
  // zones were pushed out toward the screen edges -- the guide now travels
  // ~2.24x farther per hop, so animating it in the same 1400ms would make
  // it visibly speed up and outrun the user's real thumb movement. Scaling
  // the duration by the same factor keeps the guide's on-screen VELOCITY
  // (and therefore how rushed it feels) unchanged even though the distance
  // covered is much greater.
  static const int _sweepZoneMoveMs = 3100;
  // Dwell after the guide stops translating, before the shutter fires --
  // real settle time for the user to finish repositioning their thumb at
  // the new zone, same role as the secondary-camera distance-sweep's own
  // _camera2SweepMoveDelayMs.
  static const int _sweepZoneSettleMs = 700;
  // Bounds the whole 3-zone sequence (2 guide translations + settle/count-in
  // delays + 3 takePicture() calls) -- NOT the decode/upload after it, which
  // has its own separate per-zone timeouts below. takePicture() is a raw
  // platform-channel await with no bound of its own; a hang on any one zone
  // must not block the rest of the capture forever the way an uncaught-hang
  // camera Future would (try/catch alone does not protect against that --
  // same reasoning as every other bounded camera sequence in this file).
  // Budget: 2 moves (2*3100=6200) + left settle (700) + 2 full count-ins
  // (2*3*700=4200) + 6 shots -- ambient+flash PER zone now, not 1 shot per
  // zone (2026-08-05, see the real blowout fix at the flash-activation call
  // site) -- at ~500-2000ms each in practice (more with torch AE
  // convergence), plus 2 flash-settle delays per zone (on+off) + margin.
  // Widened 18000->24000 once center/right zones each gained their own
  // 3-tick count-in (2026-08-03), 24000->28000 when _sweepZoneMoveMs grew
  // 1400->3100 for the wider edge-to-edge travel, then 28000->34000 for the
  // doubled shot count -- real observed per-zone timings before this round
  // (7 real captures' zoneDebug) stayed well inside 28000 with ~10s to
  // spare, so the extra 3 shots' worst-case cost (~2000ms each) fits with
  // real margin still intact.
  static const int _sweepBurstTimeoutMs = 34000;
  // Bound the per-zone decode+encode and upload steps separately from the
  // capture loop above -- these run AFTER the shots are already in hand, so
  // a hang here has no camera-hardware excuse and must not silently freeze
  // the screen with no feedback (see the 2026-08-03 real-device report:
  // "flash went off [on the right zone]... it stalled after" -- the capture
  // loop itself had already completed by then, distanceHint was just stuck
  // on the last count-in tick with no update during this unbounded phase).
  //
  // REAL BUG, 2026-08-03: the first cut of this fix set
  // _sweepZoneEncodeTimeoutMs=6000, guessed with no real timing data. The
  // very next real test's Firestore doc (640f563a) showed EVERY zone's
  // decode+encode hitting that timeout and silently falling back to the
  // raw, undecoded ~19MB camera JPEG (the existing catch(_) {} swallows a
  // TimeoutException same as any other decode error) -- which then blew
  // straight through the 15000ms upload timeout too, so all 3 zones failed
  // (`sweepBurstDebug.paths` empty, `sweepBurstCandidates.present: false`).
  // Real per-zone decode+encode at _stillDecodeTargetWidth=3200 legitimately
  // takes ~7000-11200ms even for a properly-sized (~1.3-1.4MB) result
  // (confirmed across 3 real captures' `zoneDebug` timings) -- 6000ms was
  // simply never achievable. Real per-zone upload of that properly-sized
  // result took up to 15275ms on real device network -- 15000ms was also
  // already too tight. Both raised well above every real observed value.
  static const int _sweepZoneEncodeTimeoutMs = 20000;
  // Lowered 30000->18000 (2026-08-05): now that each zone uploads an
  // ambient+flash PAIR (6 zones total, not 3), 2 real tests in a row showed
  // the SAME shape -- one zone succeeds in 8-14s, then every subsequent
  // zone burns the full 30s and fails (5c3eaa9b: 5 of 6 uploads timed out
  // at exactly 30000ms, ~150s wasted on uploads that were never going to
  // succeed). Every real SUCCESSFUL upload observed so far has finished in
  // 8-14s, so 18000ms still gives ~30% margin over the slowest real success
  // while cutting the cost of each failure by 40%. Paired with
  // _sweepZoneMaxConsecutiveUploadFailures below, which stops trying
  // further zones once the failure pattern shows up instead of paying this
  // reduced-but-still-real cost 5 more times.
  static const int _sweepZoneUploadTimeoutMs = 18000;
  // 2026-08-05: both real ambient+flash-pair tests so far show the exact
  // same shape -- once one zone's upload fails, every later zone fails too
  // (network degradation doesn't recover mid-session on this evidence).
  // After this many CONSECUTIVE failures, stop attempting the remaining
  // zones entirely -- they're already-uploaded bytes (kept in `encoded`,
  // just never sent), so nothing is lost that a retry could have saved,
  // and the user isn't stuck waiting through failures that were already
  // near-certain.
  static const int _sweepZoneMaxConsecutiveUploadFailures = 2;
  // Real data from the 640f563a/fd1da8c1 tests: once zoom-to-fill was
  // disabled, sweep-zone JPEGs (full, unzoomed frame detail) jumped from
  // ~1.3-1.4MB to ~4.7-4.8MB at the default quality=90 -- still one zone
  // (right) missed the upload timeout above. Each sweep zone is a single,
  // unstacked candidate competing on its own (never fused/averaged the way
  // the main burst's frames are), so it doesn't need main-burst-grade file
  // size to carry real ridge detail -- a moderate JPEG quality cut trades
  // some fine compression detail for a real, substantial encode+upload time
  // win. Only the sweep-zone encode call site uses this; the main burst and
  // detail-zoom frames stay at the default quality=90.
  static const int _sweepZoneJpegQuality = 75;

  // Instant kill-switch for the whole sweep-burst step, same pattern as
  // the disabled guided-sweep feature's own _sweepEnabled -- if a real
  // device test finds a problem, flip this to false, commit, push, rebuild.
  // No revert or branch surgery needed to detach this specific feature
  // from everything else on this branch. The backend's own
  // sweepBurstCandidates scoring block (main.py) is already inert whenever
  // no sweepBurstDebug paths were uploaded, so this one flag fully controls
  // the feature's real-world effect regardless of what's deployed
  // backend-side.
  // DISABLED 2026-08-06 after a full real-data audit. Every number below is
  // measured from real Firestore/Storage captures, not estimated:
  //
  //   * WIN RATE: across 137 real scored captures, a sweep ZONE candidate won
  //     selection exactly ONCE (fd1da8c1) -- and that capture's real NFIQ2
  //     came back 9, one of the worst on record. The cross-zone mosaic
  //     ('sweepFusion') ran 3 times and won 0.
  //   * MINUTIAE comparison (the other additive candidate family, kept on):
  //     2 wins / 30 scored -- low, but an order of magnitude better than this
  //     AND effectively free, since it reuses already-downloaded frames.
  //   * REAL USER TIME COST: 76-316s per capture, mean 161s (n=13, summing
  //     the zone loop + this feature's own sequential per-zone encode and
  //     upload). That is minutes of post-shutter waiting for a candidate
  //     family that has never once produced a good winning print.
  //   * CAPTURE LOSS: since it went live (2026-08-03), 3 of 17 real captures
  //     (17%) are permanently stuck at pending/enhancing and were never
  //     scored at all. Stuck captures averaged 204s of sweep time vs 148s
  //     for ones that completed -- consistent with the long post-shutter
  //     window giving far more opportunity for the app to be backgrounded/
  //     killed before it can fire the processEnhanceAndScore trigger, and
  //     for the backend to run out its own request budget scoring 6 extra
  //     downloaded images on top of the main variant loop.
  //
  // Structurally, this was always fighting uphill: each zone contributes a
  // SINGLE unstacked frame at reduced JPEG quality (_sweepZoneJpegQuality
  // 75) of the same pad the main burst already covers with 8 frames plus
  // stacking and ambient/flash fusion at full quality. It is duplicative
  // rather than additive.
  //
  // Left as a one-line flag (not deleted) so it is trivially revivable, and
  // because the capture machinery itself is sound and well-hardened -- the
  // problem is the cost/benefit, not the implementation. If revived, fix the
  // economics first: fewer zones, parallel or deferred upload, and a real
  // reason to expect a single unstacked frame to beat the main burst.
  static const bool _sweepBurstHybridEnabled = false;
  // decodeStillJpegToLuma's own default (2048) was chosen purely for
  // decode speed/peak-memory safety on budget devices (still_jpeg_
  // downscaler.dart's own docstring), never evaluated as a data-quality
  // tradeoff. The on-screen pad guide only covers ~46%x38% of the frame
  // (capture_pad_silhouette_overlay.dart's defaultShape, rx=0.23/ry=0.19),
  // so at 2048px wide the actual pad region is only ~900-950px across
  // before any further processing -- discarding most of a modern sensor's
  // native detail before the crop even happens. Same principle already
  // proven to matter at a later pipeline stage (two-step downscale before
  // NFIQ's 500x500 resize -- preserving more source resolution before a
  // downsample measurably helps via better anti-aliasing). Bumped to 3200
  // (~2.4x the decode's peak memory, not full native res) as a first,
  // conservative test of the same principle here -- needs a real device
  // capture + NFIQ2/SourceAFIS comparison against the 2048 baseline before
  // trusting it; revert if budget devices show memory/latency regressions.
  static const int _stillDecodeTargetWidth = 3200;
  static const int _burstFlashSettleMs = 70;
  // EV multipliers applied to flashEvStep across the 4 flash shots in the
  // main burst. flashEvStep is negative (reduces exposure to guard against
  // torch blowout), so:
  //   0.5× = lighter reduction = brighter effective flash (catches dark scenes)
  //   1.0× = standard (the adaptive curve's own recommendation)
  //   1.5× = heavier reduction = darker flash (hard blowout guard)
  //   0.75× = intermediate
  // The backend picks the sharpest frame via Laplacian ranking; the bracket
  // gives it 4 real exposure candidates instead of 4 identical ones.
  // Works via setExposureOffset() -- no hardware variable-intensity flash
  // needed, same safe API already proven for the adaptive EV step itself.
  static const List<double> _flashEvBracketMultipliers = [0.5, 1.0, 1.5, 0.75];

  // Guided thumb-sweep capture (2026-07-30, diagnostic-first): replaces the
  // static "hold still -> fire immediately" trigger with two phases inserted
  // between the existing on-target focus-lock and the burst firing --
  // sweepPositioning (wait for the thumb to reach + dwell at the guide's
  // left edge) then sweepActive (fire the same 8 shots as the user sweeps
  // right, gated on sharpness same as before). Burst mechanics themselves
  // (_burstFrameCount, the 0.45 sharpness gate, flash alternation, encode/
  // upload) are UNCHANGED -- only the trigger/pacing of individual shots is
  // new. See _beginSweepPositioning/_handleSweepPositioningFrame/
  // _beginSweepActive/_handleSweepActiveFrame/_fireSweepShot/_completeSweep.
  // Loosened 0.25/0.75 -> 0.32/0.68 (2026-07-30 round 3): a real device test
  // showed the thumb correctly, visibly seated in the shifted guide never
  // registered as "left zone" (positioning stuck indefinitely). The main fix
  // was reverting an unrelated tracking-window widening that had compressed
  // every reading toward 0.5 (see _sweepTrackingRoi's own note) -- this
  // extra margin is a deliberate, honest hedge on top of that fix: the exact
  // raw-buffer-to-screen scale was never independently, precisely calibrated
  // (only reasoned from this project's known 90° rotation convention), so a
  // more forgiving threshold is safer than an exact-but-possibly-still-off
  // one. Worse case if this is now too loose: the sweep resolves a little
  // early -- far better than the confirmed real failure mode of never
  // resolving at all.
  static const double _sweepLeftZoneMax = 0.32;
  static const double _sweepRightZoneMin = 0.68;
  static const int _sweepLeftDwellMs = 400;
  // Hard bound on the whole sweepActive window -- the UX target pace is
  // 2.5-4s (fast enough to feel natural, slow enough that 8 qualifying
  // frames can clear the sharpness gate), so this timeout sits comfortably
  // above that ceiling rather than cutting off a merely-slightly-slow sweep.
  static const int _sweepTimeoutMs = 6000;
  static const int _sweepMinValidShots = 4;
  // Minimum spacing between fired shots -- without this, a frame run that
  // sustains above the sharpness gate would otherwise fire on every single
  // camera frame (15-30/sec). ~300ms spacing against an 8-shot quota targets
  // roughly the 2.5-4s sweep window called out in the UX spec.
  static const int _sweepMinShotIntervalMs = 300;

  // Real device-test feedback (2026-07-30): a static guide oval plus an
  // internal highlight band wasn't enough -- the user reported not seeing
  // their finger inside the mask and being asked to move, and asked for the
  // mask itself to move to the side the UX points it to, so the whole
  // finger stays framed as it sweeps. Fixed by shifting the guide's own
  // centre (cx) left during sweepPositioning and interpolating it left-to-
  // right in sync with sweepProgress during sweepActive -- see
  // _sweepGuideShapeForProgress. Round 2 feedback: "needs more distance...
  // a little further" -- raised 0.10 -> 0.15. The "kept deliberately short
  // of _sweepTrackingRoi's own margin" reasoning that used to live here only
  // applied to the OLD live centroid-tracked sweep (sweepPositioning/
  // sweepActive, disabled since round 5 below) -- the ACTIVE burst-hybrid
  // path (_captureSweepBurst) is a scripted animation with no centroid
  // fire-gate at all, so that constraint doesn't apply to it.
  //
  // CTO request (2026-08-03): left/right were "too close to center to have
  // real light differences" -- push them as far toward the screen edges as
  // the guide can go while staying fully on-screen, for a real illumination-
  // angle difference between zones (the whole point of a left/centre/right
  // sweep). Wanted to derive this from PadSilhouetteShape.defaultShape.rx
  // directly so a future guide resize couldn't silently drift it out of
  // sync (the way _scoreRoi's own manually-copied derivation already can) --
  // but `defaultShape.rx` is NOT a valid const-expression field access in
  // Dart (confirmed by a real build failure: "Error: Not a constant
  // expression" / "The property 'rx' can't be accessed... in a constant
  // expression"), so this has to be a hand-computed literal instead, same
  // as _scoreRoi. Derivation: 0.5 - rx(0.134604) - margin(0.03) = 0.335396.
  // If defaultShape.rx is ever re-tuned, this must be recomputed by hand.
  static const double _sweepGuideShiftFrac = 0.335396;

  // Guided thumb-sweep feature flag. DISABLED as of 2026-07-31 round 5
  // after five real device-test rounds each revealed a different failure
  // mode -- most recently a real, honest finding that the sweep's focus
  // math was applying an unnecessary 90°-rotation inversion that the
  // static hold's own working _beginAutofocus() never applied (the Flutter
  // camera plugin's setFocusPoint takes preview-widget coords, not raw-
  // sensor coords), plus a separate concern that the centroid tracker's
  // ROI mapping is not properly validated against real on-screen thumb
  // position. Rather than ship a sixth speculative fix on top, defaulting
  // BACK to the proven static capture flow (real NFIQ2 72-81 history) --
  // the sweep code stays in the repo behind this flag for a future proper
  // rebuild that can validate coordinate transforms against real captures
  // before shipping, not after.
  static const bool _sweepEnabled = false;

  static const int _holdDurationMs = 1500;
  static const int _calibDurationMs = 500;
  static const int _confirmationDisplayMs = 700;
  static const int _emitThrottleMs = 80;
  static const int _uploadConcurrency = 8;
  static const List<int> _uploadRetryDelaysMs = [500, 1500, 4000];

  // docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md item 4, Phase 0: a silent,
  // read-only query (native MethodChannel -> Camera2 CameraCharacteristics)
  // for whether any camera on this device advertises RAW_SENSOR capability
  // -- no capture, no new screen/UI (the prior diagnostic screen was
  // explicitly removed, commit 4a832c0). Queried once per app session
  // (cached statically) and attached to each capture's own Firestore doc,
  // purely so a future RAW/DNG capture path can be scoped against real
  // device data instead of a guess.
  static const _cameraCapabilitiesChannel = MethodChannel('clearbridge/cameraCapabilities');
  static Map<String, bool>? _rawSensorSupportCache;
  static bool _rawSensorSupportQueried = false;

  static Future<Map<String, bool>?> _queryRawSensorSupport() async {
    if (_rawSensorSupportQueried) return _rawSensorSupportCache;
    _rawSensorSupportQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getRawSensorSupport');
      if (result != null) {
        _rawSensorSupportCache = result.map((k, v) => MapEntry(k, v as bool));
      }
    } catch (e) {
      debugPrint('[front] RAW sensor capability query failed (non-fatal): $e');
    }
    return _rawSensorSupportCache;
  }

  // docs/CAPTURE_OPTIMIZATION_SCOPE.md Lever C.1, Phase 0: same read-only,
  // no-capture, no-UI, once-per-session-cached pattern as
  // _queryRawSensorSupport() above -- answers whether real devices even
  // ADVERTISE support for disabling noise-reduction/edge smoothing before
  // any harder live-session Camera2-interop override work is attempted.
  static Map<String, Map<String, bool>>? _noiseReductionSupportCache;
  static bool _noiseReductionSupportQueried = false;

  static Future<Map<String, Map<String, bool>>?> _queryNoiseReductionSupport() async {
    if (_noiseReductionSupportQueried) return _noiseReductionSupportCache;
    _noiseReductionSupportQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getNoiseReductionOffSupport');
      if (result != null) {
        _noiseReductionSupportCache = result.map((k, v) => MapEntry(
              k,
              (v as Map).map((k2, v2) => MapEntry(k2 as String, v2 as bool)),
            ));
      }
    } catch (e) {
      debugPrint('[front] noise-reduction capability query failed (non-fatal): $e');
    }
    return _noiseReductionSupportCache;
  }

  // Real-device finding, 2026-07-23: secondary camera "2" times out on
  // upload far more often than "3" across several real captures (always
  // stuck mid-upload, at a different shot each time), but nothing in the
  // app has ever distinguished WHICH physical lens each raw camera-id
  // string actually is. Same read-only, no-capture, once-per-session-cached
  // pattern as the two queries above -- lets the next real capture's
  // secondaryCameraDebug be cross-referenced against real focal-length/
  // sensor-size data instead of an opaque id.
  static Map<String, Map<String, dynamic>>? _cameraLensInfoCache;
  static bool _cameraLensInfoQueried = false;

  static Future<Map<String, Map<String, dynamic>>?> _queryCameraLensInfo() async {
    if (_cameraLensInfoQueried) return _cameraLensInfoCache;
    _cameraLensInfoQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getCameraLensInfo');
      if (result != null) {
        _cameraLensInfoCache = result.map((k, v) => MapEntry(
              k,
              (v as Map).map((k2, v2) => MapEntry(k2 as String, v2)),
            ));
      }
    } catch (e) {
      debugPrint('[front] camera lens-info query failed (non-fatal): $e');
    }
    return _cameraLensInfoCache;
  }

  // Locked-shutter-speed handoff doc, Phase 0 (2026-07-31): same read-only,
  // no-capture, once-per-session-cached pattern as the three queries above
  // -- answers whether any real device even advertises MANUAL_SENSOR +
  // a real exposure-time range before any native Camera2Interop work
  // (which this app has none of today) is considered for a real locked-
  // shutter capture mode. A positive result here does NOT by itself mean
  // "locked shutter + auto ISO" is available for free -- Camera2 has no
  // such combined AE mode; AE_MODE_OFF requires driving ISO manually too.
  // See MainActivity.kt's manualExposureSupportByCameraId() for the full
  // caveat. Same discipline as rawSensorSupport: this is what would have
  // closed out RAW/DNG immediately instead of after real capture work,
  // had it existed sooner.
  static Map<String, Map<String, dynamic>>? _manualExposureSupportCache;
  static bool _manualExposureSupportQueried = false;

  static Future<Map<String, Map<String, dynamic>>?> _queryManualExposureSupport() async {
    if (_manualExposureSupportQueried) return _manualExposureSupportCache;
    _manualExposureSupportQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('getManualExposureSupport');
      if (result != null) {
        _manualExposureSupportCache = result.map((k, v) => MapEntry(
              k,
              (v as Map).map((k2, v2) => MapEntry(k2 as String, v2)),
            ));
      }
    } catch (e) {
      debugPrint('[front] manual-exposure capability query failed (non-fatal): $e');
    }
    return _manualExposureSupportCache;
  }

  // docs/LOCKED_SHUTTER_SPEED_SCOPE.md, Phase 0 (2026-08-02): unlike the
  // four capability queries above (plain CameraCharacteristics reads, safe
  // to run anytime, including while the live CameraX session is open), this
  // one briefly opens its OWN throwaway Camera2 session natively
  // (TorchExposureProbe.kt) to test whether the torch survives
  // CONTROL_AE_MODE_OFF on this device's HAL. Android does not allow two
  // concurrent CameraDevice handles on the same physical camera, so this
  // MUST be awaited to completion BEFORE CameraService.initializeCamera()
  // ever runs -- callers (FrontCaptureScreen._init()) must call this first,
  // never from inside an already-active capture. Public (not `_`-prefixed)
  // specifically so the screen can call it ahead of camera init; every
  // other probe in this file is queried lazily on _finishAndUpload instead,
  // which this one architecturally cannot do.
  static Map<String, dynamic>? torchExposureProbeCache;
  static bool _torchExposureProbeQueried = false;

  static Future<Map<String, dynamic>?> probeTorchExposureCompat() async {
    if (_torchExposureProbeQueried) return torchExposureProbeCache;
    // Set the lock immediately to prevent concurrent probe attempts (e.g.,
    // two rapid screen opens before the first probe returns). Cleared below
    // if the result is a permission-denied skip so the NEXT screen open can
    // retry -- camera permission can be granted between app sessions, so a
    // "not granted yet" result must never be cached as a permanent failure.
    _torchExposureProbeQueried = true;
    try {
      final result = await _cameraCapabilitiesChannel
          .invokeMapMethod<String, dynamic>('probeTorchWithManualExposure')
          // Belt-and-suspenders on top of the native 6s bound -- if the
          // platform channel call itself somehow never returns, this must
          // still not block the real camera init that follows.
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (result != null) {
        torchExposureProbeCache = result;
        // Permission-denied skips are transient: if the user hasn't granted
        // camera permission yet, the probe can't open a Camera2 session.
        // Reset the queried flag so the next screen open retries instead of
        // returning a stale unavailable result every time.
        final isPermissionSkip = result['skipped'] == true &&
            (result['reason'] as String? ?? '').contains('permission');
        if (isPermissionSkip) _torchExposureProbeQueried = false;
      }
    } catch (e) {
      debugPrint('[front] torch-exposure probe failed (non-fatal): $e');
    }
    return torchExposureProbeCache;
  }

  static const Set<String> _uploadNonRetryableCodes = {
    'unauthorized', 'unauthenticated', 'no-default-bucket',
    'invalid-argument', 'invalid-url', 'object-not-found', 'quota-exceeded',
  };

  // ROI the focus/exposure meters score on — aligned to the pad silhouette
  // bounding box so framing, metering and the superprint crop all agree.
  // Kept 1:1 with PadSilhouetteShape.defaultShape.boundingRect + taper.
  // Updated 2026-07-25 for the third -10% mask shrink (CTO audit after two
  // afisWavelengthPx=20 captures on the cam-3-only build -- see
  // defaultShape's own docstring for the full derivation, including the
  // real _MASK_COVER_DILATE finding on why the scored mask reads bigger
  // than this on-screen shape implies):
  //   cx=0.5, cy=0.37, rx=0.134604*(1+0.20)=0.161525, ry=0.111195
  //   -> [0.338475,0.258805,0.661525,0.481195]
  //
  // REAL, MAJOR BUG found + fixed 2026-08-06 -- the value above is stated in
  // SCREEN space, but every consumer below applies it to a raw `CameraImage`
  // buffer, which arrives in the sensor's own (unrotated) orientation. Those
  // two spaces differ by exactly the (u,v) -> (1-v, u) rotation that
  // `_computeGuideRegion`/`_stillSpaceRegionForShape` already apply when
  // deriving the backend's `guideRegion` -- so the metering ROI was never
  // actually pointed at the thumb pad.
  //
  // Proven three independent ways before changing anything:
  //  1. ARITHMETIC: the old constant is EXACTLY the un-rotated form. Its
  //     x-span [0.3385, 0.6615] equals the correct y-span, and 1 minus its
  //     y-span [0.2588, 0.4812] equals the correct x-span [0.5188, 0.7412].
  //     That is the precise signature of a missing (u,v) -> (1-v, u).
  //  2. AGAINST REAL DATA: every real capture writes `guideRegion` with
  //     cx=0.63, cy=0.5 -- which is exactly this corrected centre, and which
  //     the backend has always used successfully as the AFIS mask.
  //  3. VISUALLY: cropping a real capture (19184018, real NFIQ2 95) by the
  //     OLD rect yields knuckle skin plus background with essentially no pad
  //     ridges at all; cropping the same frame by `guideRegion` yields a
  //     cleanly-framed, ridge-filled thumb pad.
  //
  // Why this plausibly caused the intermittent soft captures being chased:
  // the knuckle sits at a visibly DIFFERENT depth from the pad, so the hold
  // gate could read "sharp" off the knuckle and fire the burst while the pad
  // itself was still out of focus -- matching the observed pattern of the
  // same device producing both excellent (real NFIQ2 72-95) and catastrophic
  // (3-21) captures, with guide-ROI sharpness differing 10-100x while
  // `afisMaskCoverPx` (distance) stayed effectively constant. It also
  // explains the recurring `liveWavelengthDebug.sampleCount: 0` -- the
  // sampled region genuinely had no ridges to measure.
  //
  // NOTE this is the CameraImage/sensor-space ROI only. `setFocusPoint`/
  // `setExposurePoint` take PREVIEW-space coordinates and therefore keep the
  // original screen-space centre -- see `_focusPointScreenSpace` below.
  static const Rect _scoreRoi =
      Rect.fromLTRB(0.518805, 0.338475, 0.741195, 0.661525);

  // Pre-fix screen-space rect, retained ONLY for the two AF/AE point call
  // sites, which take preview-space (not sensor-space) coordinates and were
  // therefore always correct. Kept as its own named constant so the two
  // spaces can never be silently conflated again.
  static const Rect _focusPointScreenSpace =
      Rect.fromLTRB(0.3385, 0.2588, 0.6615, 0.4812);

  // Row-axis (maps to on-screen X, see _sweepScreenXFraction) tracking
  // window used by the guided sweep's own CENTROID tracking only. Named
  // separately from _scoreRoi (which stays completely untouched, still
  // feeding the static hold's focus/brightness/coverage signal) purely for
  // clarity about which code depends on it.
  //
  // REAL MATH ERROR, found + reverted 2026-07-30 round 3: an earlier
  // version of this widened the row span 1.8x, reasoning the tracker
  // "needed more room" to follow the thumb across the wider guide-shift
  // range (_sweepGuideShiftFrac). That reasoning was backwards -- the
  // centroid fraction is normalized by DIVIDING by this window's own
  // height, so a WIDER window makes the SAME physical thumb displacement
  // produce a LESS extreme (closer to 0.5) normalized value, making the
  // 0.25/0.75 zone thresholds HARDER to reach, not easier. A real device
  // test (round 3) confirmed the symptom this predicts: focus locked on
  // the thumb correctly (validating the underlying rotation/axis math is
  // right), but sweepPositioning never progressed past "place thumb at the
  // left edge" even with the thumb visibly, correctly seated in the
  // shifted guide -- consistent with the widened window compressing every
  // real reading toward the middle, below the zone threshold. Reverted to
  // exactly _scoreRoi's own span (a value already implicitly proven
  // reasonably well-scaled by months of real static-hold captures, even
  // though it was never explicitly validated for lateral tracking) rather
  // than guessing a new width without real data.
  //
  // REAL REGRESSION, found + fixed round 4: this same constant used to
  // ALSO drive the focus re-aim point (_refocusForSweepPositioning /
  // _beginSweepActive), which is a SEPARATE concern from centroid zone
  // detection -- reverting the width here for the (correct) centroid-math
  // fix silently moved the focus target too, undoing round 2's real-
  // device-confirmed focus fix (that fix shipped and was validated together
  // with the WIDE window, never with this narrow one). A real device test
  // confirmed exactly this: "focus... catching the background instead of
  // the foreground" returned. Split into two independent constants below --
  // _sweepFocusRoi (kept at the wide, validated-for-focus span) for the
  // two focus call sites, _sweepTrackingRoi (narrow, _scoreRoi) for
  // centroid/zone detection only. Never let one constant silently serve two
  // independently-tuned purposes again.
  // Deliberately pinned to the PRE-2026-08-06 literal values rather than
  // following _scoreRoi's rotation fix: the guided thumb-sweep is disabled
  // (_sweepEnabled = false) and its centroid math was tuned/validated
  // against these exact numbers on real hardware. Re-pointing a disabled
  // feature's tracker as a side effect of fixing the ACTIVE static-hold path
  // would silently invalidate that tuning with no way to re-test it. If the
  // sweep is ever revived, re-derive this against _scoreRoi's corrected
  // space first -- do not assume these values are still right.
  static const Rect _sweepTrackingRoi =
      Rect.fromLTRB(0.3385, 0.2588, 0.6615, 0.4812);

  // Wide row-axis window used ONLY for the sweep's focus re-aim point
  // (_refocusForSweepPositioning / _beginSweepActive) -- this exact span is
  // what round 2's real device test confirmed fixes "focus locked on
  // background, not thumb". Kept deliberately separate from
  // _sweepTrackingRoi (see its docs above) so a future centroid-math tweak
  // can never again silently regress this independently-validated value.
  static const Rect _sweepFocusRoi = Rect.fromLTRB(0.3385, 0.17, 0.6615, 0.57);

  // Guide region in landscape-still coords (the space afis_print.generate()
  // receives after decodeStillJpegToLuma's 90°-CW rotation). Computed at
  // runtime in start() from the actual screen size + camera preview size --
  // NOT a fixed constant. The on-screen silhouette is drawn in
  // screen-normalized coords, but _cameraLayer() displays the preview via
  // BoxFit.cover, which CROPS part of the preview frame whenever the
  // preview's aspect ratio differs from the screen's. A hardcoded rotation-
  // only formula (the previous approach) ignores that crop entirely, so the
  // backend mask silently drifts from what the on-screen guide actually
  // shows on any device where the crop is non-trivial -- confirmed via a
  // real device screenshot showing the live guide sitting higher/tighter on
  // the pad than the backend's masked region. See _computeGuideRegion.
  double _guideCx = 0.63;
  double _guideCy = 0.50;
  double _guideRx = 0.13;
  double _guideRy = 0.17;
  static const double _guideN = 2.5;

  // Cached inputs to the BoxFit.cover transform (_stillSpaceRegionForShape),
  // set once in start(). Lets the sweep-burst zone capture (see
  // _guideRegionForSweepZone) re-derive a still-space guide region for the
  // TRANSLATED sweep guide on demand, without threading screenSize/
  // previewSize through the whole _finishAndUpload call chain -- the same
  // geometry that already produced _guideCx/_guideCy/_guideRx/_guideRy for
  // the base (untranslated) guide.
  Size? _cachedScreenSize;
  Size? _cachedPreviewSize;

  static const double _glareHighLuma = 205.0;
  // Hysteresis gap below _glareHighLuma before walking the EV offset back
  // toward 0 -- a real gap (not right at 205) so a scene sitting near the
  // trigger threshold can't oscillate step-down/step-up every other frame.
  static const double _glareLowLuma = 150.0;
  static const double _glareEvStep = -0.7;
  // Minimum time between successive glare EV steps. Every other exposure/
  // focus-changing mechanism in this file (flash-transition settle, refocus
  // settle, secondary-camera focus-lock wait) has a real settle delay because
  // this project's own history repeatedly found the sensor needs time to
  // converge before the next reading can be trusted -- this one previously
  // had none, so several -0.7 steps could ratchet through in well under a
  // second on a bright scene, before _lastStableBrightness had a chance to
  // reflect the prior correction.
  static const int _glareEvSettleMs = 500;
  // Adaptive flash EV step (2026-07-22): the fixed -1.0 this replaces was
  // sized off the FIRST real overexposure capture, then never revisited —
  // but a later real capture (cb684c57) showed the opposite failure at a
  // DIFFERENT ambient level: flash frames scored Laplacian 15-19 vs 343-395
  // on ambient frames from the SAME hold (gyro only 1.22°/s, ruling out
  // motion blur) — contrast collapse from the torch adding on top of
  // already-decent ambient light, the fixed -1.0 wasn't enough headroom at
  // that brightness. A single constant can't be right for both a
  // near-pitch-dark hold (torch is the ONLY light — a big EV cut there
  // needlessly darkens the one useful frame) and a bright-normal hold
  // (torch competes with substantial existing light — under-cutting risks
  // exactly cb684c57's blowout). Scale off AdaptiveFlashController's own
  // already-calibrated `intensity` (the fraction of exposure the torch
  // itself contributes, derived from the session's one-time ambient
  // calibration) instead of guessing a second fixed constant.
  //
  // Endpoints were a first-cut, physically-reasoned curve, calibrated
  // against n=1 real overexposure case (cb684c57) — the caveat this item
  // carried from the start ("needs its own dedicated real-data test").
  // 2026-07-24 (round 19/20): two independent real captures since then
  // (03b91b6f/70d69867's paired IR-camera comparison, and 3f8fd075 — real
  // flash-frame pixel stats: mean=28.3/255, max=78/255, at evStep=-1.043,
  // intensity=0.6) now show the OPPOSITE failure mode — the main camera's
  // flash frame coming out badly UNDERexposed, not blown out. A single
  // overexposure data point drove the original curve; the accumulated
  // real evidence now points the other way. Scaled both endpoints down by
  // the same ~30% the CTO asked for (-1.0 -> -0.7 equivalent at a typical
  // mid-intensity torch): at intensity=0.6 this curve now yields evStep
  // ~-0.71 instead of -1.043. Still a real device test needed to confirm
  // this doesn't reopen the original cb684c57-style blowout risk — same
  // "one variable at a time" discipline as the rest of this file.
  static const double _flashEvMinCut = -0.2; // intensity=1.0 (pitch dark: torch is
                                              // the sole light source, minimal cut needed)
  static const double _flashEvMaxCut = -1.1; // intensity=0.3 (near the bright-mode
                                              // threshold: torch adds on top of
                                              // substantial ambient, needs the most cut)
  // When ambient mean luma is below this threshold the torch is already the
  // ONLY meaningful light source.  Dimming it with a negative EV offset is
  // counterproductive — the EV curve was calibrated on the overexposure
  // case (bright ambient + flash on top), not on a pitch-dark room.
  static const double _flashEvDarkRoomThreshold = 30.0; // /255

  double _adaptiveFlashEvStep() {
    // Skip the correction entirely in a dark room: ambient mean < ~12%
    // brightness means the torch is already the sole light source and any
    // negative EV step only makes an already-underexposed frame worse.
    if (_lastStableBrightness < _flashEvDarkRoomThreshold) return 0.0;
    final intensity = (_flash?.intensity ?? 0.6).clamp(0.3, 1.0);
    final t = (1.0 - intensity) / 0.7; // 0 at intensity=1.0, 1 at intensity=0.3
    return _flashEvMinCut + (_flashEvMaxCut - _flashEvMinCut) * t;
  }

  static const double _coverageMin = 0.35;
  static const double _coverageMax = 0.85;

  // Generic centered guide shown during each secondary camera's (IR/wide)
  // own live feed (2026-07-23) -- NOT calibrated to that lens's real FOV
  // offset from the main camera (no measured data exists yet; the
  // camera-comparison investigation this session found the thumb is
  // completely absent from the secondary lens's frame in ~3/8 real
  // captures, and off-center/uncontrolled in the rest). Reusing the
  // default shape is a deliberate first cut -- it gives the user SOME
  // framing target instead of none, and the countdown below gives them
  // real time to use it, before ever investing in precise per-lens
  // calibration.
  // Device must be this still (gyroscope magnitude, deg/s) before the hold
  // timer counts and the burst can fire. Real captures showed motion-blur
  // streaking in BOTH ambient and flash frames of the same burst — camera
  // shake at macro (thumb-pad-filling) distance, independent of focus
  // distance or exposure. First-cut threshold; tune from real telemetry
  // (gyroMagnitudeDegPerSec is stored per-frame below).
  static const double _maxSteadyDegPerSec = 6.0;

  // Diagnostic snapshot of _adaptiveFlashEvStep()'s inputs/output for the
  // burst just fired -- written to the capture doc so the next real device
  // round gives concrete evidence on whether this first-cut curve is sane,
  // same "measure before tuning further" discipline as every other capture
  // parameter in this file.
  Map<String, dynamic> _flashEvDebug = {};

  CameraController? _camera;
  CameraService? _cameraService;
  // Guards _transitionToUploading() so the camera-dispose + phase-flip only
  // ever happens once per capture -- see that method's own docs for why.
  bool _transitionedToUploading = false;
  String? _userId;
  AdaptiveFlashController? _flash;
  int _sensorOrientation = 0;

  bool _disposed = false;
  bool _starting = false;
  bool _streamRunning = false;
  bool _burstInFlight = false;

  bool _refocusing = false;
  // True once a fresh auto->lock cycle has run for the CURRENT hold attempt.
  // Mirrors OscillatingCaptureController's _refocusedThisStep: focus is
  // deliberately NOT locked at session start (before the thumb is anywhere
  // near the lens, which was locking onto empty background) -- it's
  // re-acquired fresh the moment the thumb is first confirmed on-target.
  bool _refocusedThisHold = false;
  // _refocus() convergence-polling constants, added 2026-08-06. The
  // original 600ms auto->settle->lock cycle was a BLIND fixed wait with no
  // verification that AF had actually converged before locking -- a real
  // capture (a2943016) showed all 8 burst frames uniformly soft (Laplacian
  // 8-12 vs the hundreds-to-thousands seen on healthy captures), consistent
  // with focus having been locked mid-hunt rather than at a genuinely
  // settled position. _refocusMinMs preserves the original proven floor
  // (350ms was documented as "re-locking mid-hunt" for the oscillating
  // flow's own RIGHT-angle fix, so 600ms is not shortened here) --
  // _refocusMaxMs adds real headroom for slower-converging cases instead of
  // locking blind at exactly 600ms regardless of what the lens is doing.
  static const int _refocusMinMs = 600;
  static const int _refocusMaxMs = 1200;
  static const int _refocusPollIntervalMs = 150;
  // "Converged" = the live absolute-sharpness EMA (_liveAbsSharpness, the
  // same signal already tracked every frame) has stopped moving -- two
  // consecutive polls agreeing within this relative band, rather than
  // comparing against any externally-calibrated absolute threshold (no real
  // device data yet ties this live-preview signal to a calibrated floor,
  // same caveat _liveAbsSharpness's own field docs already state).
  static const double _refocusStableRatio = 0.12;
  static const int _refocusStableStreakRequired = 2;
  // Diagnostic snapshot of the most recent _refocus() call -- see field
  // docs above. Written to the capture doc alongside _flashEvDebug/
  // _wavelengthDebug so real convergence behaviour (or its absence) is
  // visible on every capture going forward, not just this investigation.
  Map<String, dynamic> _refocusDebug = {};
  // Tracks whether the thumb was in coverage range on the previous frame so
  // we can detect the entry transition and immediately point AF at the thumb.
  bool _wasInCoverageRange = false;

  double _appliedEvOffset = 0.0;
  bool _evChangeInFlight = false;
  double _lastStableBrightness = 128.0;
  DateTime? _lastGlareEvAdjustAt;

  // Zoom-to-fill (2026-07-22): compensates for the pad under-filling the
  // guide at the ALREADY-correct working distance, WITHOUT asking the user
  // to physically move closer -- physically moving closer is exactly what
  // this project's own real data (native ridge wavelength -> NFIQ2/
  // matchability) says to avoid; the guide has been shrunk twice specifically
  // to push users FARTHER back. Zoom-in-only is deliberate: it recovers
  // framing without paying the wavelength cost a "move closer" fix would.
  // Never zooms OUT to fix over-fill -- backing away physically is the
  // correct (and free) fix there, per the same reasoning in reverse.
  double _zoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  bool _zoomChangeInFlight = false;
  int _underfillStreak = 0;
  bool _zoomEverApplied = false;
  static const int _underfillStreakThreshold = 8; // ~consecutive frames, not
      // a single noisy reading -- same hysteresis rationale as
      // _maxSteadyDegPerSec's gyro smoothing.
  static const double _zoomStep = 0.15;
  // Zoom-to-fill disabled: digital zoom inflates afisWavelengthPx even when
  // the user is correctly positioned, because zoom-in is never reversed during
  // the hold phase. Guide is already calibrated for the right working distance;
  // the "Move closer" hint handles under-fill without zooming. Set to 1.0 so
  // _maxZoomLevel clamps to 1.0 and _maybeAdjustZoom is always a no-op.
  static const double _maxZoomFill = 1.0;

  // Detail-zoom burst REMOVED 2026-08-05: real Firestore audit across all
  // 11 real captures that ever ran it found it won selection exactly once
  // (0bd23cc2), and that single win's real production nfiq2Score was 8 --
  // one of the worst scores in this project's whole history, the same
  // proxy-fooled-false-positive pattern documented elsewhere in this file.
  // Its own sharpness (Laplacian 4-337 across real captures) never came
  // close to the main burst's ambient frames (routinely 3000+). Real device
  // capture + processing time for a feature that never once produced a
  // genuine win -- cut outright rather than left dark, per the CTO's
  // explicit choice once shown the data.

  // Live ridge-wavelength estimate (2026-07-26, Phase 0 -- diagnostic-only,
  // does NOT drive distanceHint yet). Reconciling "closer for detail" with
  // "far enough for good pixel wavelength" (see _maxZoomFill's own comment
  // above) has so far relied entirely on the brightness/fill proxy
  // (coverage) below -- this measures the thing that actually matters
  // (native ridge wavelength) directly from the live preview, so the next
  // several real captures can confirm it tracks the backend's own
  // afisWavelengthPx before it's ever trusted to change user-facing text.
  double? _liveWavelengthPx;
  double? _liveWavelengthStillPx;
  int _wavelengthSampleCount = 0;
  // Consecutive-outlier counter for the EMA guard below. A single rejected
  // sample is assumed to be frame noise; two in a row in the SAME direction
  // are assumed to be a genuine, sustained change (the user actually moved)
  // and get accepted instead of permanently anchoring the EMA to a stale
  // value. See the outlier-rejection block in _onFrame.
  int _wavelengthOutlierStreak = 0;
  String? _wavelengthAxis;
  DateTime? _lastWavelengthEstimateAt;
  static const int _wavelengthEstimateIntervalMs = 250;
  // "Move back slightly" fires when liveWavelengthStillPx exceeds this
  // threshold, even if the coverage/brightness proxy says "in range". Root
  // cause: brightness is an imperfect distance proxy -- the thumb can be in
  // the luma sweet spot [_coverageMin, _coverageMax] while the actual ridge
  // scale (the thing that directly drives NFIQ2) is already too high.
  //
  // Retuned 2026-08-06 alongside the _scoreRoi rotation fix, which this
  // value is directly coupled to and MUST move with.
  //
  // The old 25.0 was calibrated against readings inflated ~1.45x by that
  // same bug: _wavelengthScaleToStill divides by `_scoreRoi.width`, and the
  // old (un-rotated) rect's width was 0.3230 where the correct, guide-
  // matching width is 0.2224 -- a 1.4524x over-estimate on every live
  // wavelength reading ever recorded. Leaving 25.0 in place after the fix
  // would have silently killed the hint: a genuinely too-close capture that
  // used to read 30.8 now reads ~21.2, i.e. below the old threshold.
  //
  // Real paired validation of the corrected scale (the calibration data the
  // old comment here asked for, now actually available): capture f799bb74
  // read liveWavelengthStillPx 30.8 under the bug -> 21.2 corrected, and its
  // sibling capture 3841b287 (same user, ~4.5 min later) measured backend
  // afisWavelengthPx 20.0 (raw 22.0). So after the fix the live estimate
  // tracks the backend's own authoritative value to within ~1px, which is
  // what it was always supposed to do.
  //
  // 16.0 therefore sits in the SAME units as afisWavelengthPx and is chosen
  // against this project's own established real-data finding: 9-14px is the
  // NFIQ2 sweet spot and >=15px correlates with catastrophic real scores.
  // 16.0 keeps a 1px margin above that boundary to avoid firing on captures
  // sitting right at the edge.
  static const double _liveWavelengthTooHighPx = 16.0;
  // Minimum wavelength EMA samples before the hint can fire, to guard
  // against a transient first-frame estimate triggering "Move back" on a
  // correctly-positioned thumb.
  static const int _liveWavelengthMinSamples = 3;
  Map<String, dynamic> _wavelengthDebug = {};

  // Guided thumb-sweep state (see the constants block above for the
  // phase-timing constants). _sweepRawShots/_sweepCentroids are parallel
  // lists built in fire order -- index i of one corresponds to index i of
  // the other, which _finishAndUpload relies on to attach centroidX to the
  // right frame's metadata.
  bool _sweepActivating = false;
  bool _sweepShotInFlight = false;
  DateTime? _lastSweepShotAt;
  int _sweepFlashShotIndex = 0;
  bool _sweepWasFlashLastShot = false;
  final List<_RawShot> _sweepRawShots = [];
  final List<double?> _sweepCentroids = [];
  DateTime? _sweepActiveStart;
  DateTime? _sweepLeftDwellStart;
  double? _lastCentroidX;
  bool _sweepTorchCapable = false;
  double _sweepFlashEvStep = 0.0;
  double? _sweepMinEv;
  double? _sweepMaxEv;
  Map<String, dynamic> _sweepDebug = {};

  StreamSubscription<GyroscopeEvent>? _gyroSub;
  double _gyroMagnitudeDegPerSec = 0.0;

  DateTime? _calibStart;
  bool _calibDone = false;
  final List<double> _brightnessSamples = [];

  double _focusValue = 0;
  double _focusPeak = 1.0;
  double get focusValue => _focusValue;

  // Absolute (NOT peak-normalized) live sharpness EMA, added 2026-08-06.
  // _focusValue above is relative to THIS session's own running peak, which
  // hides a real failure mode: a capture whose thumb never produces strong
  // texture anywhere in the whole hold (near-flat/underexposed/out-of-focus
  // throughout) can still read _focusValue near 1.0, since the peak itself
  // is just as low as everything else -- a ratio near 1 says nothing about
  // whether the underlying signal was ever good. Confirmed via a real
  // cross-capture investigation: 3 of 5 real captures that scored
  // catastrophic NFIQ2 (5-9) despite an otherwise-unremarkable wavelength
  // reading shared one real trait -- their raw ambient burst frame's
  // Laplacian variance was near background-noise level (9-39, vs 300-2000+
  // on captures that scored well), i.e. genuinely flat/textureless frames,
  // not a distance problem at all.
  //
  // Diagnostic-only for now, deliberately NOT wired to a live hint yet --
  // unlike the wavelength estimator (which already has a real still-space
  // scale factor via _wavelengthScaleToStill), this raw preview-resolution
  // Laplacian value has no established scale relationship to the backend's
  // still-resolution amb_lap numbers above yet. Inventing an absolute
  // threshold now would repeat the exact mistake the wavelength hint's own
  // history already warns against (its 25px threshold is explicitly
  // flagged as "first-cut, don't reduce without real calibration pairs") --
  // this field exists so the next several real captures give real
  // (liveAbsSharpness, backend amb_lap) pairs to calibrate one properly.
  double? _liveAbsSharpness;
  int _sharpnessSampleCount = 0;

  DateTime? _holdStart;
  DateTime? _lastEmitAt;

  final _hybrid = HybridCaptureService();
  final _audio = CaptureAudioService();

  FrontCaptureState _state = const FrontCaptureState();
  FrontCaptureState get state => _state;

  Future<void> start({
    required CameraController camera,
    required String userId,
    required Size screenSize,
    CameraService? cameraService,
  }) async {
    if (_starting || _streamRunning) return;
    _starting = true;
    _disposed = false;
    _camera = camera;
    _cameraService = cameraService;
    _userId = userId;
    _sensorOrientation = camera.description.sensorOrientation;

    _cachedScreenSize = screenSize;
    _cachedPreviewSize = camera.value.previewSize;
    _computeGuideRegion(screenSize: screenSize, previewSize: camera.value.previewSize);

    _holdStart = null;
    _calibDone = false;
    _brightnessSamples.clear();
    _focusValue = 0;
    _focusPeak = 1.0;
    _appliedEvOffset = 0.0;
    _refocusedThisHold = false;
    _wasInCoverageRange = false;
    _gyroMagnitudeDegPerSec = 0.0;
    _zoomLevel = 1.0;
    _maxZoomLevel = 1.0;
    _underfillStreak = 0;
    _zoomEverApplied = false;
    _sweepActivating = false;
    _sweepShotInFlight = false;
    _lastSweepShotAt = null;
    _sweepFlashShotIndex = 0;
    _sweepWasFlashLastShot = false;
    _sweepRawShots.clear();
    _sweepCentroids.clear();
    _sweepActiveStart = null;
    _sweepLeftDwellStart = null;
    _lastCentroidX = null;
    _sweepDebug = {};
    try {
      _maxZoomLevel = (await camera.getMaxZoomLevel()).clamp(1.0, _maxZoomFill);
    } catch (_) {}

    _flash = AdaptiveFlashController(camera);

    // Loads the chime WAV assets into the players -- without this call,
    // every later playAngleSuccess() plays a source-less player, which
    // just_audio silently no-ops on (swallowed by that method's own
    // catch), so no chime is ever audible even though every call site looks
    // correctly wired. Real device test, 2026-07-23: confirmed missing here
    // (the sibling oscillating_capture_controller.dart already calls this
    // in its own setup; this call was never copied over when the chime call
    // sites were retrofitted into this controller).
    unawaited(_audio.init());

    _apply((s) => s.copyWith(phase: FrontCapturePhase.calibrating), force: true);

    // Enable continuous autofocus tracking the ROI right away, but DO NOT
    // lock yet -- locking here (before the thumb is anywhere near the lens)
    // freezes the AF distance on whatever's in frame at cold-open (empty
    // background) and it never re-adjusts once locked, which was the root
    // cause of inconsistent blur: the on-screen "on target" gate is a
    // software Laplacian score normalised against its own running peak, so
    // it can read as "locked" even though the underlying AF never actually
    // pointed at the pad. The real re-acquire+lock now happens in
    // _onFrame/_refocus, once the thumb is confirmed on-target.
    try {
      await _beginAutofocus();
    } catch (_) {}

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

    _calibStart = DateTime.now();
    _brightnessSamples.clear();

    try {
      await camera.startImageStream(_onFrame);
      _streamRunning = true;
    } catch (e) {
      _fail('Camera stream failed: $e');
      return;
    } finally {
      _starting = false;
    }
  }

  /// Maps the on-screen pad silhouette (screen-normalized coords) into
  /// landscape-still-normalized guideRegion coords, accounting for the
  /// BoxFit.cover crop _cameraLayer() applies (the previous fixed-constant
  /// approach only rotated the raw on-screen fraction, silently ignoring
  /// that crop -- confirmed wrong via a real device screenshot comparing
  /// the live guide against the actual masked backend region).
  void _computeGuideRegion({required Size screenSize, Size? previewSize}) {
    if (previewSize == null || screenSize.width <= 0 || screenSize.height <= 0) {
      return; // keep the existing (last-good or default) values
    }
    final region = _stillSpaceRegionForShape(
      PadSilhouetteShape.defaultShape,
      screenSize: screenSize,
      previewSize: previewSize,
    );
    if (region == null) return;
    _guideCx = region.cx;
    _guideCy = region.cy;
    _guideRx = region.rx;
    _guideRy = region.ry;
  }

  /// Shared BoxFit.cover + 90°-rotation transform underlying
  /// _computeGuideRegion above -- factored out so the sweep-burst zone
  /// capture (_guideRegionForSweepZone) can derive a still-space guide
  /// region for the TRANSLATED sweep guide shape using the exact same,
  /// already-verified math, instead of a second hand-copied derivation that
  /// could silently drift out of sync with this one.
  ({double cx, double cy, double rx, double ry})? _stillSpaceRegionForShape(
    PadSilhouetteShape shape, {
    required Size screenSize,
    required Size previewSize,
  }) {
    // _cameraLayer() swaps previewSize's width/height to get the portrait
    // display aspect ratio before handing it to FittedBox(fit: BoxFit.cover).
    final wp = previewSize.height;
    final hp = previewSize.width;
    final ws = screenSize.width;
    final hs = screenSize.height;
    if (wp <= 0 || hp <= 0 || ws <= 0 || hs <= 0) return null;
    final scale = math.max(ws / wp, hs / hp);
    final offX = (wp * scale - ws) / 2;
    final offY = (hp * scale - hs) / 2;

    // Screen-normalized point -> landscape-still-normalized point: undo the
    // BoxFit.cover crop/scale to recover the true preview-frame fraction,
    // then apply the same 90°-CW rotation decodeStillJpegToLuma performs
    // ((u,v) in portrait-preview -> (1-v,u) in landscape-still).
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

  /// Still-space guide region for one sweep-burst zone (progress 0.0/0.5/1.0
  /// = left/center/right) -- the region the backend should use as this
  /// zone's own AFIS mask, since the on-screen guide (and therefore where
  /// the pad actually sits in that zone's still frame) has translated away
  /// from the base guide's position. Returns null if the cached screen/
  /// preview geometry isn't available yet (camera not started) -- callers
  /// fall back to the base guide region in that case, same as any other
  /// best-effort capture-side diagnostic in this file.
  Map<String, dynamic>? _guideRegionForSweepZone(double progress, double tipAngleDeg) {
    final screenSize = _cachedScreenSize;
    final previewSize = _cachedPreviewSize;
    if (screenSize == null || previewSize == null) return null;
    final region = _stillSpaceRegionForShape(
      _sweepGuideShapeForProgress(progress),
      screenSize: screenSize,
      previewSize: previewSize,
    );
    if (region == null) return null;
    return {
      'cx': region.cx,
      'cy': region.cy,
      'rx': region.rx,
      'ry': region.ry,
      'n': _guideN,
      'tipAngleDeg': tipAngleDeg,
    };
  }

  /// Converts a raw-live-preview-pixel wavelength estimate into the same
  /// still-space pixel units the backend's own `afisWavelengthPx` uses
  /// (measured directly on the still decoded to _stillDecodeTargetWidth,
  /// no further resize before _ridge_wavelength runs).
  ///
  /// `_guideRx` is the guide's half-width already in still-normalized,
  /// crop-and-rotation-corrected coordinates (_computeGuideRegion above);
  /// `_scoreRoi` is the same ROI already feeding meanLuma/the wavelength
  /// estimator, in raw-CameraImage-normalized coordinates. These are two
  /// INDEPENDENTLY derived approximations of "the same" guide region
  /// (_scoreRoi's own comment says it's only "kept 1:1" with the guide
  /// shape, not identical to the crop-corrected _guideRx) -- fine for a
  /// coarse scale factor, but exactly why liveWavelengthStillPx must be
  /// checked against real backend afisWavelengthPx data (not trusted
  /// because it looks reasonable) before this ever drives distanceHint.
  double? _wavelengthScaleToStill(CameraImage image) {
    final roiWidthPx = _scoreRoi.width * image.width;
    if (roiWidthPx <= 0 || _guideRx <= 0) return null;
    return (2 * _guideRx * _stillDecodeTargetWidth) / roiWidthPx;
  }

  void _onFrame(CameraImage image) {
    if (_disposed) return;

    final roi = _scoreRoi;

    // Coverage hint (distance from camera).
    double? coverage;
    try {
      coverage = HybridCaptureService.meanLuma(image, roi: roi) / 255.0;
    } catch (_) {}
    final tooFar = coverage != null && coverage < _coverageMin;
    final tooClose = coverage != null && coverage > _coverageMax;
    // Hoisted here (was previously computed further down, just before the
    // focus-tracking block) so the live wavelength estimator below can also
    // gate on it -- no point running autocorrelation on a background frame
    // before the thumb is plausibly present.
    final inCoverageRange = coverage != null && !tooFar && !tooClose;
    // Try zoom-to-fill before ever telling the user to physically move
    // closer -- zooming preserves the guided working distance (and the
    // native ridge wavelength it was tuned for); physically moving closer
    // does not. Only fall back to the "Move closer" hint once zoom is
    // already maxed out and genuinely can't help further.
    final zoomMaxedOut = _maybeAdjustZoom(tooFar);
    // Wavelength-based "too close" guard: fires even when coverage/brightness
    // is in the nominal [_coverageMin, _coverageMax] range, because luma is
    // an imperfect distance proxy. Uses the EMA estimate from the previous
    // frame (updated a few lines below) -- fine since the EMA is stable
    // across 250ms intervals; a per-frame race would add noise without value.
    final wavelengthTooHigh = inCoverageRange &&
        _liveWavelengthStillPx != null &&
        _wavelengthSampleCount >= _liveWavelengthMinSamples &&
        _liveWavelengthStillPx! > _liveWavelengthTooHighPx;
    final hint = (tooFar && zoomMaxedOut)
        ? 'Move closer'
        : (tooClose || wavelengthTooHigh)
            ? 'Move back slightly'
            : null;
    if (hint != _state.distanceHint) {
      _apply((s) => s.copyWith(distanceHint: hint));
    }

    // Live ridge-wavelength estimate (Phase 0, diagnostic-only -- see the
    // field docs above _gyroSub). Throttled to a wall-clock interval (mirrors
    // this file's one existing throttling convention, _emitThrottleMs/
    // _calibDurationMs) and gated on inCoverageRange, since the autocorrelation
    // pass is real work and there's no point running it on a background
    // frame. Wrapped in try/catch -- must never be able to break the hold.
    if (inCoverageRange) {
      final now = DateTime.now();
      if (_lastWavelengthEstimateAt == null ||
          now.difference(_lastWavelengthEstimateAt!).inMilliseconds >=
              _wavelengthEstimateIntervalMs) {
        _lastWavelengthEstimateAt = now;
        try {
          final est =
              HybridCaptureService.estimateRidgeWavelengthPx(image, roi: roi);
          if (est != null) {
            // Outlier guard, added 2026-08-06: once a prior EMA value
            // exists, reject a raw sample that's wildly different (>2.5x
            // either direction) rather than folding it straight in. Root
            // cause this addresses: a single spurious frame -- most often
            // the coarse whole-ROI axis pick (rows vs cols, see
            // estimateRidgeWavelengthPx's docs) flipping near a whorl core,
            // where ridge orientation isn't uniform across the ROI -- could
            // otherwise swing the reported number on its own, which is
            // exactly the "not consistent" pattern a real user reported
            // despite visually identical thumb placement across captures.
            // Can't reject the very first sample (nothing to compare
            // against yet) -- that's an inherent bootstrapping limit, not a
            // regression versus the old unconditional-fold behaviour.
            //
            // Two rejections in a row are accepted anyway (streak counter
            // below) -- otherwise a genuine sustained change (the user
            // actually moving closer/farther mid-hold) would permanently
            // wedge the EMA on a stale value once one outlier is rejected,
            // since nothing would ever update `prior` again.
            final prior = _liveWavelengthPx;
            final isOutlier = prior != null &&
                prior > 0 &&
                (est.medianLagPx > prior * 2.5 ||
                    est.medianLagPx < prior / 2.5);
            if (isOutlier && _wavelengthOutlierStreak < 1) {
              _wavelengthOutlierStreak++;
            } else {
              _wavelengthOutlierStreak = 0;
              _liveWavelengthPx = HybridCaptureService.ema(
                prior ?? est.medianLagPx,
                est.medianLagPx,
              );
              final scale = _wavelengthScaleToStill(image);
              _liveWavelengthStillPx =
                  scale != null ? _liveWavelengthPx! * scale : null;
              _wavelengthAxis = est.axis;
              _wavelengthSampleCount++;
            }
          }
        } catch (_) {}
      }
    }

    // Focus tracking: offerFrame returns raw Laplacian variance; normalise by
    // running peak so the meter reads 0→1 relative to the sharpest frame seen.
    //
    // Peak is only updated when the thumb is in coverage range. Without this
    // gate, sharp background frames before the thumb arrives set _focusPeak
    // far above anything the (initially blurry) thumb can achieve, preventing
    // the focus meter from ever clearing the 0.45 on-target threshold.
    //
    // On thumb ENTRY we immediately point AF at the thumb ROI and reset the
    // peak to the current (low) raw value, giving focus tracking a fresh
    // baseline calibrated to the thumb — not leftover background sharpness.
    try {
      final rawFocus = _hybrid.offerFrame(image, thumbRoi: roi);
      if (inCoverageRange && !_wasInCoverageRange) {
        // Thumb just entered range: reset peak and immediately direct AF.
        // Skip if a full refocus cycle is already running — it will redirect
        // AF itself and calling _beginAutofocus() concurrently would race
        // with its 600ms settle timer.
        _focusPeak = rawFocus + 1e-6;
        _focusValue = 0;
        if (!_refocusing) unawaited(_beginAutofocus());
      } else if (inCoverageRange && rawFocus > _focusPeak) {
        _focusPeak = rawFocus;
      }
      _focusValue = HybridCaptureService.ema(
        _focusValue,
        (rawFocus / (_focusPeak + 1e-6)).clamp(0.0, 1.0),
      );
      // Absolute sharpness EMA (diagnostic-only) -- see field docs above.
      if (inCoverageRange) {
        _liveAbsSharpness =
            HybridCaptureService.ema(_liveAbsSharpness ?? rawFocus, rawFocus);
        _sharpnessSampleCount++;
      }
    } catch (_) {}
    _wasInCoverageRange = inCoverageRange;

    // Brightness tracking for exposure.
    if (!(_flash?.isFlashOn ?? false)) {
      try {
        _lastStableBrightness = HybridCaptureService.meanLuma(image, roi: roi);
        _apply((s) => s.copyWith(
              lightingValue: (_lastStableBrightness / 255.0).clamp(0.0, 1.0),
            ));
      } catch (_) {}
    }
    if (!_refocusing) _maybeAdjustExposure();

    // Calibration: sample brightness for AdaptiveFlash.
    if (!_calibDone) {
      try {
        _brightnessSamples.add(HybridCaptureService.meanLuma(image, roi: roi));
      } catch (_) {}
      final start = _calibStart;
      if (start != null &&
          DateTime.now().difference(start).inMilliseconds >= _calibDurationMs) {
        unawaited(_finalizeCalibration());
      }
      return;
    }

    if (_burstInFlight) return;

    // Guided thumb-sweep phases -- inserted between the existing on-target
    // focus-lock (below) and the burst firing. Each has its own per-frame
    // handler; both return early so the holding-phase logic below never
    // runs concurrently with the sweep.
    if (_state.phase == FrontCapturePhase.sweepPositioning) {
      _handleSweepPositioningFrame(image);
      return;
    }
    if (_state.phase == FrontCapturePhase.sweepActive) {
      _handleSweepActiveFrame(image);
      return;
    }

    if (_state.phase != FrontCapturePhase.holding) return;

    // On-target: focus score crosses threshold, distance is right, AND the
    // device is objectively still (gyroscope-derived). Real captures showed
    // motion-blur streaking even when the software focus score read "on
    // target" -- a fixed hold timer alone doesn't catch handshake at macro
    // distance.
    final steady = _gyroMagnitudeDegPerSec < _maxSteadyDegPerSec;
    final rawOnTarget = _focusValue > 0.45 && !tooFar && !tooClose && steady;

    if (rawOnTarget) {
      // Re-acquire focus FRESH the first time this hold reaches on-target,
      // instead of trusting whatever the lens converged to before the thumb
      // arrived. Mirrors OscillatingCaptureController's per-pose re-lock
      // (the fix for "RIGHT angle always blurs").
      if (!_refocusedThisHold) {
        _refocusedThisHold = true;
        _holdStart = null;
        unawaited(_refocus());
        _apply((s) => s.copyWith(onTarget: true, holdProgress: 0, isSteady: steady));
        return;
      }
      if (_refocusing) {
        // Hold the user steady while the lens converges; don't start the
        // hold timer or fire on a mid-hunt frame.
        _apply((s) => s.copyWith(onTarget: true, holdProgress: 0, isSteady: steady));
        return;
      }
      _holdStart ??= DateTime.now();
      final heldMs = DateTime.now().difference(_holdStart!).inMilliseconds;
      final progress = (heldMs / _holdDurationMs).clamp(0.0, 1.0);
      _apply((s) => s.copyWith(onTarget: true, holdProgress: progress, isSteady: steady));
      if (heldMs >= _holdDurationMs) {
        _holdStart = null;
        // Sweep behind a disabled flag (see _sweepEnabled's own docs) --
        // routes back to the proven static burst path _fireBurst() by
        // default, which is _fireBurst's original pre-sweep behaviour when
        // called with no preCollectedShots argument.
        unawaited(_sweepEnabled ? _beginSweepPositioning() : _fireBurst());
      }
    } else {
      _holdStart = null;
      // Only restart the focus-acquire cycle when the thumb genuinely leaves
      // coverage range (real distance change — AF may need to re-acquire at a
      // new distance). Gyro spikes and transient focus dips while the thumb
      // stays in frame don't stale the locked focus; resetting here would
      // trigger a fresh 600ms refocus wait the moment the score recovers,
      // multiplying unnecessary waits when the user is just slightly unsteady.
      if (tooFar || tooClose || coverage == null) {
        _refocusedThisHold = false;
      }
      _apply((s) => s.copyWith(onTarget: false, holdProgress: 0, isSteady: steady));
    }
  }

  // ── Guided thumb-sweep capture ──────────────────────────────────────────
  //
  // Phase 1 (sweepPositioning): wait for the thumb's centroid to reach the
  // guide's left zone and dwell there briefly, so the sweep always starts
  // from a known, consistent position rather than wherever the thumb
  // happened to be when the hold-still timer completed.
  //
  // Phase 2 (sweepActive): fire the same 8-shot alternating-flash burst as
  // before, but gated per-frame on sharpness as the user sweeps right,
  // instead of firing all 8 back-to-back the instant a static hold
  // completes. Ends on quota (8 shots), an early right-zone exit once the
  // minimum valid-shot count is already met, or a hard timeout.

  /// The on-screen guide shape for a given sweep progress (0.0 = fully
  /// left-shifted, 1.0 = fully right-shifted) -- interpolates `cx` linearly,
  /// everything else copied from `PadSilhouetteShape.defaultShape`. This IS
  /// "the mask" the 2026-07-30 device-test feedback asked to move: rather
  /// than a static guide the user's thumb sweeps across (with a separate,
  /// easy-to-miss highlight band), the guide itself translates across the
  /// screen so the whole finger stays inside it throughout the sweep.
  PadSilhouetteShape _sweepGuideShapeForProgress(double progress) {
    const base = PadSilhouetteShape.defaultShape;
    final cx = (0.5 - _sweepGuideShiftFrac) +
        (2 * _sweepGuideShiftFrac) * progress.clamp(0.0, 1.0);
    return PadSilhouetteShape(
      cx: cx,
      cy: base.cy,
      rx: base.rx,
      ry: base.ry,
      n: base.n,
      taper: base.taper,
      coreTargetDyFrac: base.coreTargetDyFrac,
      coreTargetDxFrac: base.coreTargetDxFrac,
    );
  }

  Future<void> _beginSweepPositioning() async {
    _sweepActivating = false;
    _sweepShotInFlight = false;
    _lastSweepShotAt = null;
    _sweepFlashShotIndex = 0;
    _sweepWasFlashLastShot = false;
    _sweepRawShots.clear();
    _sweepCentroids.clear();
    _sweepLeftDwellStart = null;
    _lastCentroidX = null;
    _apply(
      (s) => s.copyWith(
        phase: FrontCapturePhase.sweepPositioning,
        sweepProgress: 0.0,
        sweepCentroidX: null,
        sweepFastWarning: false,
        sweepPositionOk: false,
        sweepDwellProgress: 0.0,
        // Guide shifted fully left -- this IS the "place thumb at the left
        // edge" target now, not a separate highlight overlay on a static
        // guide (see _sweepGuideShapeForProgress).
        activeGuideShape: _sweepGuideShapeForProgress(0.0),
      ),
      force: true,
    );
    // Real device-test finding (2026-07-30 round 2): "focus is not locked
    // on the thumb but rather on the background". Root cause: focus was
    // locked (FocusMode.locked) at the ORIGINAL static hold's centred point
    // (set once by the hold phase's own _refocus(), before this sweep flow
    // even existed) and nothing here ever re-aimed it -- so once the guide
    // shifted left and the user actually moved their thumb to match, the
    // lens stayed pointed at whatever background was now exposed at the
    // OLD centred spot. This very likely also explains "capture never
    // initiates": with the lens focused on the wall, the thumb itself reads
    // soft in _scoreRoi, so _focusValue's Laplacian score can't clear the
    // 0.45 fire-gate threshold no matter how well the user positions their
    // thumb. Fix: continuous (not locked) autofocus re-aimed at the
    // shifted guide's actual position for the whole positioning phase, so
    // the lens is already converging on the right spot before the user's
    // thumb gets there -- _beginSweepActive's existing settle+lock cycle
    // then takes over once positioning resolves.
    unawaited(_refocusForSweepPositioning());
  }

  /// Converts a SCREEN-space left(0)-right(1) fraction into the raw
  /// CameraImage buffer point setFocusPoint/setExposurePoint expect, via
  /// _sweepFocusRoi -- the ONE constant every sweep focus-targeting call
  /// site must share (see _sweepFocusRoi's own docs for why this was split
  /// out from _sweepTrackingRoi after a real round-4 regression). Column
  /// axis fixed at the ROI's own centre ("centre Y fixed" per the sweep
  /// spec); row axis inverted per this project's confirmed 90°CW
  /// raw-buffer-to-screen rotation (see _sweepScreenXFraction).
  Offset _sweepFocusPointFor(double targetScreenX) {
    final rawBufferX = (_sweepFocusRoi.left + _sweepFocusRoi.right) / 2;
    final rawBufferY = (_sweepFocusRoi.top +
            (1.0 - targetScreenX) * _sweepFocusRoi.height)
        .clamp(0.0, 1.0);
    return Offset(rawBufferX, rawBufferY);
  }

  /// Re-aims CONTINUOUS autofocus (not locked) at the sweep-positioning
  /// guide's actual on-screen position -- see the real-bug note in
  /// _beginSweepPositioning above. Evaluated at progress=0.0 (the guide's
  /// fully-left-shifted cx) since the guide doesn't move further during
  /// positioning itself.
  Future<void> _refocusForSweepPositioning() async {
    final cam = _camera;
    if (cam == null) return;
    final pt = _sweepFocusPointFor(_sweepGuideShapeForProgress(0.0).cx);
    try {
      await cam.setFocusMode(FocusMode.auto);
      await cam.setFocusPoint(pt);
      await cam.setExposurePoint(pt);
    } catch (_) {}
  }

  /// Maps the raw CameraImage buffer's own axes into an on-screen
  /// left(0.0)-to-right(1.0) fraction, for the guided thumb-sweep. Given
  /// this project's real, already-confirmed `sensorOrientation=90`
  /// convention (see `_computeGuideRegion`'s "90°-CW rotation" derivation --
  /// the same class of screen-vs-buffer coordinate fix that took NFIQ2 from
  /// single digits to 72 for the guideRegion mask), a 90°CW rotation from
  /// raw sensor space to upright portrait maps the raw buffer's ROW axis to
  /// the upright image's HORIZONTAL axis, inverted (screen-left = a large
  /// raw-row fraction, screen-right = a small one) -- NOT the buffer's
  /// column axis.
  ///
  /// Real bug found via a real device test (2026-07-30): the sweep asked
  /// the user to move their thumb toward an on-screen "left zone"/"sweep
  /// right" cue, but the original centroid tracking measured the buffer's
  /// COLUMN axis -- which this rotation actually maps to on-screen VERTICAL
  /// position, not horizontal. The positioning/sweep gates could never
  /// reliably resolve against real left-right thumb motion, matching the
  /// report ("did not see my finger in mask", capture never firing). Same
  /// standing discipline as everywhere else in this file: reasoned from
  /// this project's own already-confirmed rotation convention, not device-
  /// tested yet -- the next real capture's `sweepDebug.centroids` trend
  /// (now recorded in already-correct screen-space fractions) is the actual
  /// go/no-go check.
  ///
  /// Uses `_sweepTrackingRoi` (wider than `_scoreRoi`, row axis only --
  /// see its own docs) so the tracker has real room to follow the thumb
  /// across the sweep's widened guide-shift range.
  double? _sweepScreenXFraction(CameraImage image) {
    final rowFrac = HybridCaptureService.estimateThumbCentroidX(
      image, roi: _sweepTrackingRoi, alongRows: true,
    );
    if (rowFrac == null) return null;
    return (1.0 - rowFrac).clamp(0.0, 1.0);
  }

  void _handleSweepPositioningFrame(CameraImage image) {
    // Already transitioning to sweepActive (re-aiming focus, an async
    // sequence spanning several frames) -- avoid re-triggering it on every
    // subsequent frame while that's in flight.
    if (_sweepActivating) return;

    double? centroid;
    try {
      centroid = _sweepScreenXFraction(image);
    } catch (_) {}
    _lastCentroidX = centroid ?? _lastCentroidX;

    final inLeftZone = centroid != null && centroid <= _sweepLeftZoneMax;
    var dwellProgress = 0.0;
    if (inLeftZone) {
      _sweepLeftDwellStart ??= DateTime.now();
      final dwelledMs = DateTime.now().difference(_sweepLeftDwellStart!).inMilliseconds;
      dwellProgress = (dwelledMs / _sweepLeftDwellMs).clamp(0.0, 1.0);
      if (dwelledMs >= _sweepLeftDwellMs) {
        _sweepActivating = true;
        unawaited(_beginSweepActive(centroid!));
        return;
      }
    } else {
      _sweepLeftDwellStart = null;
    }
    _apply((s) => s.copyWith(
          sweepCentroidX: centroid,
          sweepProgress: 0.0,
          sweepPositionOk: inLeftZone,
          sweepDwellProgress: dwellProgress,
        ));
  }

  /// Re-aims focus to the guide's own left-shifted position (centre Y
  /// fixed) -- the same point _refocusForSweepPositioning has already been
  /// continuously converging on -- waits for it to settle, locks it, then
  /// transitions to sweepActive. Deliberately does this ONCE at sweep
  /// start, not continuously during the sweep itself -- focus-chase latency
  /// mid-sweep would introduce exactly the motion blur the sharpness gate
  /// is trying to avoid.
  Future<void> _beginSweepActive(double startCentroidX) async {
    final cam = _camera;
    if (cam == null) {
      _sweepActivating = false;
      return;
    }

    // Deliberately NOT derived from startCentroidX (which is a live
    // _sweepTrackingRoi-relative reading) -- REAL REGRESSION, round 4: an
    // earlier version of this reused startCentroidX through this same
    // inverse transform, which silently mixed _sweepTrackingRoi's (narrow,
    // centroid-tuned) calibration into a focus target, undoing round 2's
    // validated focus fix. _refocusForSweepPositioning has already been
    // continuously re-aiming at the guide's own fixed left-shifted position
    // throughout positioning, and reaching sweepActive only happens once
    // the dwell condition confirms the thumb is actually there -- so
    // re-aiming at that SAME already-validated point (not a fresh,
    // differently-calibrated one) is both simpler and correct.
    final pt = _sweepFocusPointFor(_sweepGuideShapeForProgress(0.0).cx);
    try {
      await cam.setFocusMode(FocusMode.auto);
      await cam.setFocusPoint(pt);
      await cam.setExposurePoint(pt);
      // Same 600ms auto->settle->lock convention as _refocus() -- this
      // device's proven AF convergence timing elsewhere in this file.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await cam.setFocusMode(FocusMode.locked);
    } catch (_) {}

    if (_disposed || _state.phase != FrontCapturePhase.sweepPositioning) {
      _sweepActivating = false;
      return;
    }

    _sweepTorchCapable = _flash?.isNeeded ?? false;
    _sweepFlashEvStep = _adaptiveFlashEvStep();
    _sweepMinEv = null;
    _sweepMaxEv = null;
    if (_sweepTorchCapable) {
      try {
        _sweepMinEv = await cam.getMinExposureOffset();
        _sweepMaxEv = await cam.getMaxExposureOffset();
      } catch (_) {}
    }
    _sweepActiveStart = DateTime.now();
    _sweepActivating = false;
    _apply(
      (s) => s.copyWith(
        phase: FrontCapturePhase.sweepActive,
        // Continuous with sweepPositioning's own progress/guide position
        // (both 0.0, left-shifted) rather than jumping to startCentroidX --
        // _handleSweepActiveFrame takes over from here on every live frame.
        sweepProgress: 0.0,
        sweepCentroidX: startCentroidX,
        sweepFastWarning: false,
        activeGuideShape: _sweepGuideShapeForProgress(0.0),
      ),
      force: true,
    );
  }

  void _handleSweepActiveFrame(CameraImage image) {
    double? centroid;
    try {
      centroid = _sweepScreenXFraction(image);
    } catch (_) {}
    if (centroid != null) _lastCentroidX = centroid;
    final effectiveCentroid = centroid ?? _lastCentroidX;

    // Same 0.45 threshold as the existing on-target gate above -- reused,
    // not a second independent value, per "must not change the existing
    // Laplacian gate threshold".
    final sharpnessOk = _focusValue > 0.45;
    final progress = (effectiveCentroid ?? _state.sweepProgress).clamp(0.0, 1.0);
    _apply((s) => s.copyWith(
          sweepCentroidX: effectiveCentroid,
          sweepProgress: progress,
          sweepFastWarning: !sharpnessOk,
          // The guide itself tracks the sweep (see _sweepGuideShapeForProgress)
          // so the whole finger stays framed as it moves, instead of a
          // static oval the thumb sweeps across.
          activeGuideShape: _sweepGuideShapeForProgress(progress),
        ));

    final capturedCount = _sweepRawShots.length;
    final elapsedMs = _sweepActiveStart == null
        ? 0
        : DateTime.now().difference(_sweepActiveStart!).inMilliseconds;

    // Completion checks run before the fire gate so a frame that both
    // qualifies to fire AND crosses a completion boundary doesn't squeeze
    // in one extra shot past where the sweep should already have ended.
    if (capturedCount >= _burstFrameCount) {
      unawaited(_completeSweep(success: true));
      return;
    }
    if (effectiveCentroid != null &&
        effectiveCentroid >= _sweepRightZoneMin &&
        capturedCount >= _sweepMinValidShots) {
      unawaited(_completeSweep(success: true));
      return;
    }
    if (elapsedMs >= _sweepTimeoutMs) {
      unawaited(_completeSweep(success: capturedCount >= _sweepMinValidShots));
      return;
    }

    // Fire gate: only capture when sharp, not already mid-shot, and enough
    // time has passed since the last shot -- natural pacing across the
    // sweep window rather than pile-firing every frame once sharp.
    if (!_sweepShotInFlight) {
      final now = DateTime.now();
      final sinceLastShot = _lastSweepShotAt == null
          ? _sweepMinShotIntervalMs
          : now.difference(_lastSweepShotAt!).inMilliseconds;
      if (sharpnessOk && sinceLastShot >= _sweepMinShotIntervalMs) {
        unawaited(_fireSweepShot(effectiveCentroid));
      }
    }
  }

  /// Captures one sweep shot. Stops the image stream before the still
  /// capture and restarts it immediately after, matching the SAME pattern
  /// every other still-capture path in this file already uses (the static
  /// burst, secondary cameras, the detail-zoom burst) -- unlike an earlier
  /// version of this method, which kept `startImageStream` running
  /// continuously across every sweep shot so centroid/sharpness tracking
  /// wouldn't have to pause. That was a real, explicitly-flagged unverified
  /// assumption (concurrent ImageAnalysis + ImageCapture use), and a real
  /// device test (2026-07-30) hit an Android ANR ("app isn't responding:
  /// Close/Wait") consistent with it not being safe on this hardware/plugin
  /// combination -- this project's own history has repeatedly traced ANRs
  /// to exactly this class of camera-session contention. Restarting per
  /// shot costs real, bounded latency (a stream stop/start cycle, up to
  /// _sweepMinShotIntervalMs's worth of tracking gap) but removes the ANR
  /// risk category entirely, at the cost of a NEW, also-unverified
  /// assumption -- that 8 rapid stop/restart cycles are themselves safe on
  /// real hardware. Flagged for the next real device test same as
  /// everywhere else in this file; if THIS turns out to be a problem too,
  /// the next lever is spacing shots further apart, not going back to a
  /// continuously-running stream.
  Future<void> _fireSweepShot(double? centroidAtFire) async {
    final cam = _camera;
    if (cam == null || _sweepShotInFlight) return;
    _sweepShotInFlight = true;
    _lastSweepShotAt = DateTime.now();
    try {
      await _stopStream();

      final i = _sweepRawShots.length;
      // Same alternation convention as the static burst: even index =
      // ambient (torch off), odd = flash (torch on with negative EV).
      final wantFlash = _sweepTorchCapable && i.isOdd;
      try {
        if (wantFlash) {
          await _flash!.activate();
          if (_sweepMinEv != null && _sweepMaxEv != null) {
            final multiplier = _flashEvBracketMultipliers[
                _sweepFlashShotIndex % _flashEvBracketMultipliers.length];
            final target = _appliedEvOffset + _sweepFlashEvStep * multiplier;
            await cam.setExposureOffset(target.clamp(_sweepMinEv!, _sweepMaxEv!));
          }
          await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
        } else {
          await _flash?.deactivate();
          if (_sweepMinEv != null && _sweepMaxEv != null) {
            await cam.setExposureOffset(_appliedEvOffset.clamp(_sweepMinEv!, _sweepMaxEv!));
          }
          // Same flash-off settle delay as the static burst -- only applied
          // when the immediately preceding shot actually fired the flash.
          if (_sweepWasFlashLastShot) {
            await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
          }
        }
      } catch (_) {}
      if (wantFlash) _sweepFlashShotIndex++;
      _sweepWasFlashLastShot = wantFlash;

      final xfile = await cam.takePicture();
      final jpeg = await xfile.readAsBytes();
      _sweepRawShots.add(_RawShot(
        jpeg: jpeg,
        flashOn: _flash?.isFlashOn ?? false,
        laplacianScore: _focusValue > 0 ? _focusValue * (_focusPeak + 1e-6) : null,
        timestamp: DateTime.now(),
      ));
      _sweepCentroids.add(centroidAtFire);
      // Immediate per-shot feedback -- real device-test feedback (2026-07-30
      // round 2): "I can't hear or see anything fire". The static burst only
      // confirms once at the very end (all 8 shots); the sweep's shots are
      // spread over several seconds of active user motion, so a light tick
      // per shot (distinct from the final heavyImpact success pattern in
      // _fireBurst) gives real-time confirmation instead of total silence
      // until the whole sweep resolves.
      unawaited(HapticFeedback.selectionClick());
    } catch (e) {
      debugPrint('[front] sweep shot failed (non-fatal): $e');
    } finally {
      if (!_disposed && !_streamRunning) {
        try {
          await cam.startImageStream(_onFrame);
          _streamRunning = true;
        } catch (e) {
          debugPrint('[front] sweep stream restart failed (non-fatal): $e');
        }
      }
      _sweepShotInFlight = false;
    }
  }

  Future<void> _completeSweep({required bool success}) async {
    // Guard against double-invocation -- _handleSweepActiveFrame can fire
    // again on the next camera frame before the phase transition below
    // actually lands (async gap between the completion check and here).
    if (_state.phase != FrontCapturePhase.sweepActive) return;
    // Immediately move off sweepActive so a concurrent frame callback can't
    // re-enter this same completion path a second time. Also resets the
    // guide back to centered/default -- the rest of the flow (detail-zoom,
    // secondary cameras) expects the same centered guide the static burst
    // always used, not wherever the sweep's moving guide last landed.
    _apply(
      (s) => s.copyWith(phase: FrontCapturePhase.capturing, activeGuideShape: null),
      force: true,
    );

    final capturedCount = _sweepRawShots.length;
    final elapsedMs = _sweepActiveStart == null
        ? 0
        : DateTime.now().difference(_sweepActiveStart!).inMilliseconds;

    try {
      await _flash?.deactivate();
    } catch (_) {}

    _sweepDebug = {
      'centroids': List<double?>.from(_sweepCentroids),
      'capturedCount': capturedCount,
      'sweepDurationMs': elapsedMs,
      'timedOut': elapsedMs >= _sweepTimeoutMs,
      'leftDwellMs': _sweepLeftDwellMs,
    };

    if (!success) {
      HapticFeedback.mediumImpact(); // distinct from the success heavyImpact below
      _apply(
        (s) => s.copyWith(
          phase: FrontCapturePhase.sweepPositioning,
          confirmationText: 'Try again — sweep a little slower',
          sweepProgress: 0.0,
        ),
        force: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: _confirmationDisplayMs));
      if (_disposed) return;
      _apply((s) => s.copyWith(confirmationText: null), force: true);
      unawaited(_beginSweepPositioning());
      return;
    }

    final rawShots = List<_RawShot>.from(_sweepRawShots);
    final centroids = List<double?>.from(_sweepCentroids);
    final gyroAtCapture = _gyroMagnitudeDegPerSec;
    unawaited(_fireBurst(
      preCollectedShots: rawShots,
      preCollectedCentroids: centroids,
      gyroAtCapture: gyroAtCapture,
    ));
  }

  Future<void> _finalizeCalibration() async {
    if (_calibDone || _disposed) return;
    _calibDone = true;
    if (_brightnessSamples.isNotEmpty) {
      final avg = _brightnessSamples.reduce((a, b) => a + b) / _brightnessSamples.length;
      try {
        await _flash?.calibrate(avg);
      } catch (_) {}
    }
    _apply((s) => s.copyWith(phase: FrontCapturePhase.holding), force: true);
  }

  Future<void> _beginAutofocus() async {
    final cam = _camera;
    if (cam == null) return;
    // Preview-space, NOT sensor-space -- setFocusPoint/setExposurePoint take
    // coordinates relative to the camera preview, so these keep the original
    // screen-space centre (0.5, 0.37). See _scoreRoi's own docs for why the
    // two spaces are now separate named constants.
    final cx = (_focusPointScreenSpace.left + _focusPointScreenSpace.right) / 2;
    final cy = (_focusPointScreenSpace.top + _focusPointScreenSpace.bottom) / 2;
    final pt = Offset(cx, cy);
    try {
      await cam.setFocusMode(FocusMode.auto);
    } catch (_) {}
    try {
      await cam.setFocusPoint(pt);
    } catch (_) {}
    try {
      await cam.setExposurePoint(pt);
    } catch (_) {}
  }

  Future<void> _lockFocusOnly() async {
    final cam = _camera;
    if (cam == null) return;
    try {
      await cam.setFocusMode(FocusMode.locked);
    } catch (_) {}
  }

  /// Re-acquire then re-lock focus at the pad's actual current distance,
  /// instead of trusting whatever the lens converged to before the thumb was
  /// in frame. Waits at least `_refocusMinMs` (the original proven floor)
  /// before ever locking, same as before -- but now VERIFIES the live
  /// absolute-sharpness signal has genuinely stopped changing (real
  /// convergence, not a guess) before locking, up to a bounded
  /// `_refocusMaxMs` ceiling, rather than always locking blind at exactly
  /// the floor regardless of whether AF is still hunting.
  ///
  /// Real bug this fixes, found 2026-08-06: the old version was a fixed
  /// 600ms sleep with zero verification -- if autofocus hunting genuinely
  /// took longer (plausible at close macro distance / low light), the lens
  /// got locked wherever it happened to be at the 600ms mark. A real
  /// capture (a2943016) showed exactly this signature: all 8 burst frames
  /// uniformly soft (Laplacian 8-12, a narrow low range -- not the wider
  /// spread classic per-shot hand-shake would produce, which the burst's
  /// own max-of-variants selection already defends against).
  ///
  /// `_onFrame`'s own focus-tracking block keeps updating `_liveAbsSharpness`
  /// on every incoming preview frame regardless of `_refocusing`, so polling
  /// it here needs no separate frame subscription -- it reuses the stream
  /// that's already running.
  Future<void> _refocus() async {
    if (_refocusing) return;
    _refocusing = true;
    final sw = Stopwatch()..start();
    double? lastSample;
    var stableStreak = 0;
    var converged = false;
    try {
      await _beginAutofocus();
      while (sw.elapsedMilliseconds < _refocusMaxMs) {
        await Future<void>.delayed(
            const Duration(milliseconds: _refocusPollIntervalMs));
        if (_disposed) break;
        final sample = _liveAbsSharpness;
        if (sample != null && sample > 0) {
          if (lastSample != null && lastSample! > 0) {
            final change = (sample - lastSample!).abs() / lastSample!;
            stableStreak = change < _refocusStableRatio ? stableStreak + 1 : 0;
          }
          lastSample = sample;
        }
        if (sw.elapsedMilliseconds >= _refocusMinMs &&
            stableStreak >= _refocusStableStreakRequired) {
          converged = true;
          break;
        }
      }
      await _lockFocusOnly();
      _refocusDebug = {
        'waitedMs': sw.elapsedMilliseconds,
        'converged': converged,
        'finalSharpness': lastSample,
      };
    } catch (e) {
      debugPrint('[front] refocus failed (non-fatal): $e');
    } finally {
      _refocusing = false;
    }
  }

  // Explicit per-camera-turn UI (2026-07-23) -- shared by every secondary-
  // camera turn inside capturingExtra so the whole phase reads as one
  // consistent sequence: guide shown -> countdown -> capturing -> explicit
  // stop -> confirmation.
  // Directly answers the CTO's real-device report that cameras fired with
  // no dead stop between them and no warning before the shutter.

  /// "3…" -> "2…" -> "1…", ~700ms apart with a light haptic pulse each, then
  /// hands off to "Capturing…". Real time for the user to react to
  /// whatever guide is currently shown, not just a label change.
  // Real bug found + fixed 2026-07-29: this previously had no settle delay
  // (could ratchet several -0.7 steps within under a second on a bright
  // scene, well before _lastStableBrightness reflected the prior
  // correction) and never reversed (_appliedEvOffset was only ever
  // decremented, so a brief glint during calibration permanently depressed
  // the exposure baseline -- including the main burst's ambient/flash EV,
  // which both use _appliedEvOffset as their base -- for the rest of that
  // capture session even if brightness later returned to normal). The old
  // "already converged" check also compared target against _appliedEvOffset
  // itself (always exactly _glareEvStep apart, so it could never actually
  // trip) instead of against the real hardware-clamped value, letting the
  // internal accounting value run away past what the camera actually
  // applied. Now: settled by _glareEvSettleMs, reconciled against the real
  // hardware min/max every adjustment (so _appliedEvOffset can't diverge
  // from what the sensor actually has), and walks back toward 0 with a
  // hysteresis gap (_glareLowLuma) once the glare clears.
  void _maybeAdjustExposure() {
    if (_evChangeInFlight) return;
    final cam = _camera;
    if (cam == null) return;
    final now = DateTime.now();
    if (_lastGlareEvAdjustAt != null &&
        now.difference(_lastGlareEvAdjustAt!).inMilliseconds < _glareEvSettleMs) {
      return;
    }
    final wantsDarker = _lastStableBrightness > _glareHighLuma;
    final wantsBrighter =
        _lastStableBrightness < _glareLowLuma && _appliedEvOffset < 0.0;
    if (!wantsDarker && !wantsBrighter) return;
    final step = wantsDarker ? _glareEvStep : -_glareEvStep;
    _evChangeInFlight = true;
    _lastGlareEvAdjustAt = now;
    cam.getMinExposureOffset().then((min) async {
      final max = await cam.getMaxExposureOffset();
      final target = (_appliedEvOffset + step).clamp(min, max);
      if ((target - _appliedEvOffset).abs() < 0.05) return;
      _appliedEvOffset = target;
      await cam.setExposureOffset(_appliedEvOffset);
    }).catchError((_) {}).whenComplete(() => _evChangeInFlight = false);
  }

  /// Zoom-to-fill: called every frame with the current under-fill reading.
  /// Only ever zooms IN, only after a sustained (not single-frame) under-fill
  /// streak, and only up to the device's own max zoom -- see the field
  /// comments above `_zoomLevel` for why this never zooms back out. Returns
  /// true once zoom is maxed out and can no longer help (the caller falls
  /// back to the existing "Move closer" hint at that point).
  bool _maybeAdjustZoom(bool tooFar) {
    if (!tooFar) {
      _underfillStreak = 0;
      return false;
    }
    final atMax = _zoomLevel >= _maxZoomLevel - 0.01;
    if (atMax) return true;
    _underfillStreak++;
    if (_underfillStreak < _underfillStreakThreshold) return false;
    _underfillStreak = 0;
    if (_zoomChangeInFlight) return false;
    final cam = _camera;
    if (cam == null) return false;
    final target = (_zoomLevel + _zoomStep).clamp(1.0, _maxZoomLevel);
    if ((target - _zoomLevel).abs() < 0.01) return false;
    _zoomChangeInFlight = true;
    cam.setZoomLevel(target).then((_) {
      _zoomLevel = target;
      _zoomEverApplied = true;
    }).catchError((_) {}).whenComplete(() => _zoomChangeInFlight = false);
    return false;
  }

  /// Fires (or finishes processing) the main 8-shot burst. When
  /// [preCollectedShots] is supplied (the guided-sweep path -- see
  /// _completeSweep), the shots are already captured; this skips straight to
  /// the shared post-collection work (torch-off restore, decode/encode,
  /// success feedback, upload). When null, falls back to
  /// the original static collection loop (stream stopped, all 8 shots fired
  /// back-to-back) -- kept for structural completeness, though the only
  /// active caller is now _completeSweep.
  Future<void> _fireBurst({
    List<_RawShot>? preCollectedShots,
    List<double?>? preCollectedCentroids,
    double? gyroAtCapture,
  }) async {
    if (_burstInFlight || _disposed) return;
    _burstInFlight = true;
    // Snapshot device stillness at the moment the burst fires -- diagnostic
    // only (stored alongside laplacianScore below), for tuning
    // _maxSteadyDegPerSec against real capture outcomes.
    final gyro = gyroAtCapture ?? _gyroMagnitudeDegPerSec;
    _apply(
      (s) => s.copyWith(
        isCapturingBurst: true,
        burstProgress: preCollectedShots != null ? 1.0 : 0.0,
        phase: FrontCapturePhase.capturing,
      ),
      force: true,
    );

    final cam = _camera;
    final torchCapable =
        preCollectedShots != null ? _sweepTorchCapable : (_flash?.isNeeded ?? false);
    final flashEvStep =
        preCollectedShots != null ? _sweepFlashEvStep : _adaptiveFlashEvStep();
    _flashEvDebug = {
      'evStep': double.parse(flashEvStep.toStringAsFixed(3)),
      'evBracket': _flashEvBracketMultipliers
          .map((m) => double.parse((flashEvStep * m).toStringAsFixed(3)))
          .toList(),
      'flashIntensity': _flash?.intensity,
      'flashMode': _flash?.modeName,
    };
    // Snapshot the running live-wavelength estimate at the moment the burst
    // actually fires (same convention as _flashEvDebug above), not at
    // doc-write time -- the hold could end slightly before upload.
    //
    // Gated on _liveWavelengthMinSamples, added 2026-08-06: a 1-2-sample
    // EMA is barely smoothed at all (alpha=0.3 on the very first sample IS
    // the first sample, unfiltered) -- writing that as if it were a
    // reliable measurement is exactly what made cross-capture wavelength
    // comparisons look "inconsistent" to a real user, since several real
    // captures logged this field off a single noisy frame. Below the
    // threshold, report null + the real sample count instead of a
    // misleadingly precise-looking number.
    final wlReliable = _wavelengthSampleCount >= _liveWavelengthMinSamples;
    _wavelengthDebug = {
      'liveWavelengthPx': wlReliable ? _liveWavelengthPx : null,
      'liveWavelengthStillPx': wlReliable ? _liveWavelengthStillPx : null,
      'scaleToStill': _liveWavelengthPx != null && _liveWavelengthPx! > 0
          ? (_liveWavelengthStillPx ?? 0) / _liveWavelengthPx!
          : null,
      'sampleCount': _wavelengthSampleCount,
      'belowMinSamples': !wlReliable,
      'axis': _wavelengthAxis,
      // Whether the wavelength-based distance hint ever fired during the
      // hold (i.e. liveWavelengthStillPx exceeded _liveWavelengthTooHighPx).
      // If true on a capture, the user moved back after seeing the hint --
      // correlate the final afisWavelengthPx against captures where this
      // was false to validate whether 25px is the right threshold.
      'wavelengthHintThresholdPx': _liveWavelengthTooHighPx,
      // Absolute (non-peak-normalized) live sharpness -- see field docs
      // above _liveAbsSharpness. Not gated on a minimum sample count the
      // way liveWavelengthStillPx is (it's an EMA fed every in-range frame,
      // not a low-frequency 250ms-interval sample, so it converges much
      // faster) -- written whenever any samples exist, real sample count
      // included so a genuinely short hold is still identifiable.
      'liveAbsSharpness': _liveAbsSharpness,
      'sharpnessSampleCount': _sharpnessSampleCount,
    };

    double? minEv, maxEv;
    if (preCollectedShots != null) {
      minEv = _sweepMinEv;
      maxEv = _sweepMaxEv;
    } else if (torchCapable) {
      try {
        minEv = await cam?.getMinExposureOffset();
        maxEv = await cam?.getMaxExposureOffset();
      } catch (_) {}
    }

    final rawShots = <_RawShot>[];

    try {
      if (cam == null) return;

      if (preCollectedShots != null) {
        rawShots.addAll(preCollectedShots);
      } else {
        await _stopStream();

        // Alternate: even-indexed shots are ambient (torch OFF), odd shots are
        // flash (torch ON with negative EV). At 10cm the torch at full ambient EV
        // blows out the pad centre completely (confirmed on first real capture:
        // NFIQ2=9). Alternating gives the backend both lighting conditions;
        // _download_front_only_frames already splits frames into ambient_frames
        // and flash_frames so AFIS can pick the best-exposed set.
        var wasFlashLastShot = false;
        var flashShotIndex = 0;
        for (var i = 0; i < _burstFrameCount; i++) {
          final wantFlash = torchCapable && i.isOdd;
          try {
            if (wantFlash) {
              await _flash!.activate();
              if (minEv != null && maxEv != null) {
                final multiplier = _flashEvBracketMultipliers[
                    flashShotIndex % _flashEvBracketMultipliers.length];
                final target = _appliedEvOffset + flashEvStep * multiplier;
                await cam.setExposureOffset(target.clamp(minEv, maxEv));
              }
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            } else {
              await _flash?.deactivate();
              if (minEv != null && maxEv != null) {
                await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
              }
              // Real asymmetry found 2026-07-24: the flash-ON transition above
              // gets an explicit settle delay before its shot fires, but the
              // flash-OFF transition (torch physically switching off AND the EV
              // offset dropping back from flashEvStep to base) went straight
              // into takePicture() with zero settle time -- only when this shot
              // actually FOLLOWS a real flash shot (`wasFlashLastShot`, not
              // just "this is an ambient slot" -- torch-incapable/bright-mode
              // bursts never fire flash at all, so they must NOT pick up this
              // delay on every single shot). If the sensor needs real time to
              // re-converge exposure after either change -- which is exactly
              // why the activate() side already waits -- every other "ambient"
              // shot in a normal-mode burst could be captured mid-transition,
              // still influenced by the prior flash frame's EV state.
              // Symmetric fix: same settle window on the way back down. Not
              // yet device-tested -- same standing discipline as every other
              // capture-side change this project.
              if (wasFlashLastShot) {
                await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
              }
            }
          } catch (_) {}
          if (wantFlash) flashShotIndex++;
          wasFlashLastShot = wantFlash;
          try {
            final xfile = await cam.takePicture();
            final jpeg = await xfile.readAsBytes();
            // Locked-shutter-speed investigation, Stage 1 (2026-08-02): the
            // `camera` plugin has no public API for manual SENSOR_EXPOSURE_
            // TIME/SENSITIVITY control (confirmed against the plugin's own
            // changelog), so real shutter-speed locking would need a native
            // Camera2Interop lift. Before spending that, read what the HAL's
            // own auto-exposure actually did for THIS shot straight out of
            // the JPEG's EXIF -- zero plugin/native change, just bytes we
            // already have.
            final exif = parseJpegExposureExif(jpeg);
            rawShots.add(_RawShot(
              jpeg: jpeg,
              flashOn: _flash?.isFlashOn ?? false,
              laplacianScore: _focusValue > 0 ? _focusValue * (_focusPeak + 1e-6) : null,
              timestamp: DateTime.now(),
              exif: exif,
              gyroMagnitudeDegPerSec: _gyroMagnitudeDegPerSec,
            ));
            // MAC3D capture-UX-polish mockup dev-handoff note: "fire a light
            // haptic tick on each burst frame, stronger buzz on capture
            // completion" -- the completion buzz already existed
            // (HapticFeedback.heavyImpact() below); this adds the per-frame
            // tick, same call already used elsewhere in this file for
            // real-time "something just happened" confirmation.
            unawaited(HapticFeedback.selectionClick());
          } catch (e) {
            debugPrint('[front] burst shot $i failed (non-fatal): $e');
          }
          _apply(
            (s) => s.copyWith(burstProgress: (i + 1) / _burstFrameCount),
            force: true,
          );
          if (i < _burstFrameCount - 1) {
            await Future<void>.delayed(const Duration(milliseconds: _burstShotDelayMs));
          }
        }
      }
      // Always restore torch-off and base EV when done.
      try {
        await _flash?.deactivate();
        if (minEv != null && maxEv != null) {
          await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
        }
      } catch (_) {}

      HapticFeedback.heavyImpact();
      unawaited(_audio.playAngleSuccess(isFinal: true));
      _apply(
        (s) => s.copyWith(
          isCapturingBurst: false,
          confirmationText: '✓ Captured',
        ),
        force: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: _confirmationDisplayMs));

      await _finishAndUpload(
        rawShots,
        gyro,
        sweepCentroids: preCollectedCentroids,
        sweepDebugData: preCollectedShots != null ? _sweepDebug : null,
      );
    } catch (e) {
      _fail('Capture failed: $e');
    } finally {
      _burstInFlight = false;
      if (!_disposed) {
        _apply((s) => s.copyWith(isCapturingBurst: false, confirmationText: null), force: true);
      }
    }
  }

  /// Best-effort extra stills captured at three sweep positions (left/
  /// centre/right) on the SAME main CameraController the burst just used
  /// (no second session, unlike the secondary-camera loop right after this,
  /// which switches to a DIFFERENT physical camera and has its own real,
  /// already-documented session-contention history).
  ///
  /// Replaces this step's original 9s VIDEO-recording implementation (see
  /// the constants block above for the real measured reason it was dropped:
  /// real device captures showed every video-extracted zone frame at
  /// Laplacian 23-59 vs 311-327 for plain main-burst stills on the SAME
  /// capture -- a 30fps video frame's ~33ms exposure plus H.264 compression
  /// can't match a real JPEG still, no matter how the extraction is tuned).
  /// Firing a real still at each zone removes that problem at the source,
  /// using the exact same takePicture()-then-encode-then-upload shape this
  /// file already uses for the main and secondary-camera bursts.
  ///
  /// The whole 3-zone sequence is wrapped in ONE .timeout() -- takePicture()
  /// is a raw platform-channel await with no bound of its own, so a hang on
  /// any single zone must not block the rest of the capture forever
  /// (try/catch alone does not protect against that). Each zone's shot is
  /// ALSO individually try/caught, so one failed zone just yields fewer
  /// candidates rather than aborting the other two -- same discipline as
  /// the secondary-camera burst's per-shot guard.
  ///
  /// Never throws past its own try/catch -- a failure here can't jeopardise
  /// the main burst, which is already safely uploaded via the caller's own
  /// separate path regardless of this method's outcome.

  /// Disposes the camera and flips the UI to the clean, fully-opaque
  /// "Uploading capture…" screen (_UploadingOverlay) -- idempotent, safe to
  /// call from multiple places.
  ///
  /// REAL BUG, found 2026-08-05 from a real device screenshot: this used to
  /// happen only once, at the very end of _finishAndUpload, AFTER the sweep
  /// burst's own decode+encode+upload work (capturingExtra phase, camera +
  /// guide still visibly live, just showing a "Processing…" text banner on
  /// top). That work is not fast -- a real capture's sweepBurstDebug showed
  /// 4 of 6 zone uploads individually burning the full 30s timeout each,
  /// ~140s total -- so the user was staring at a live camera preview with
  /// "Processing…" over it for minutes, which reads as a stuck/broken
  /// capture, not "please wait". The screenshot also showed what looked
  /// like the camera visibly reinitialising partway through -- plausibly
  /// the OS reclaiming an idle preview session left running that long.
  ///
  /// Fixed by calling this the moment the LAST real shutter press fires
  /// (end of _captureSweepBurst's own timeout-bounded capture loop) instead
  /// of after all the background decode/encode/upload work that follows
  /// it -- nothing after that point ever needs the live camera again. The
  /// original call site in _finishAndUpload is kept as a fallback
  /// (idempotent via _transitionedToUploading) for
  /// _sweepBurstHybridEnabled=false, where _captureSweepBurst never runs.
  Future<void> _transitionToUploading() async {
    if (_transitionedToUploading) return;
    _transitionedToUploading = true;
    try {
      await _cameraService?.disposeCamera();
    } catch (_) {}
    _apply((s) => s.copyWith(phase: FrontCapturePhase.uploading, uploadProgress: 0), force: true);
  }

  /// Real-motion check between two sweep-burst zone shots -- built to
  /// answer a question raised by real backend data (2026-08-08): the
  /// backend's cross-zone mosaic fusion has been failing/underperforming on
  /// real captures, and a direct pixel comparison of real uploaded zone
  /// stills (2 real captures) found the left/center/right shots showing the
  /// SAME core/whorl feature in nearly the same on-screen position --
  /// phase-correlation offset only ~10-50px on a ~450-550px crop, with a
  /// weak/noisy correlation response (0.003-0.15, where ~1.0 is a
  /// confident single dominant shift). The guide's on-screen position
  /// animates and the countdown/settle timing is fixed, but nothing has
  /// ever confirmed the user's actual thumb followed it -- unlike every
  /// other position-dependent capture in this file (focus convergence,
  /// distance zones), which measure before firing.
  ///
  /// Deliberately does NOT reuse the live camera stream for this check.
  /// This project hit a real ANR (2026-07-30, "app isn't responding") from
  /// repeatedly restarting `startImageStream` during an earlier sweep
  /// design, root-caused to camera-session contention between ImageAnalysis
  /// and ImageCapture -- the fix was the current stream-off, timer-only
  /// design `_captureSweepBurst` still uses. Reopening the stream mid-loop
  /// to re-check position would risk reintroducing exactly that failure
  /// category. Instead this compares the ALREADY-CAPTURED still JPEGs
  /// directly -- `decodeStillJpegToLuma` is a pure `dart:ui` image decode,
  /// not a camera-session operation, so it carries none of that risk.
  ///
  /// Decodes both JPEGs at a small target width (cheap: tens of ms, not the
  /// ~2048px decode the real upload path uses) and returns a normalized
  /// cross-correlation in [-1, 1] -- ~1.0 means near-duplicate framing,
  /// well below that means the content genuinely differs. Returns null on
  /// any decode failure or dimension mismatch (caller treats that as "can't
  /// tell", never blocks the sweep on it).
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

  // Threshold above which two zones' flash shots are treated as
  // "essentially unchanged" -- the user very likely didn't reposition.
  // FIRST-CUT VALUE, not yet validated against real device data: chosen
  // conservatively high (only flags genuinely near-duplicate framing) so
  // this can't false-positive on a real, modest repositioning and force an
  // unnecessary extra wait. The next real device test's own
  // `zoneFramingSimilarity` diagnostics (recorded regardless of whether
  // this threshold trips) are the real tuning signal -- same "measure
  // first" discipline as every other first-cut threshold in this file.
  static const double _sweepZoneSimilarityThreshold = 0.90;
  // Extra move-animation time granted to the NEXT zone transition when the
  // PREVIOUS one came back too similar -- bounded (one extension per
  // transition, not a retry loop) so this can only ever add a fixed, known
  // amount of latency, never hang.
  static const int _sweepExtraMoveMs = 1800;

  Future<Map<String, dynamic>> _captureSweepBurst(
    String basePath,
    double tipAngleDeg,
  ) async {
    final debug = <String, dynamic>{'attempted': true};
    final cam = _camera;
    if (cam == null) {
      debug['error'] = 'no camera controller';
      return debug;
    }
    final stopwatch = Stopwatch()..start();
    const zones = <MapEntry<String, double>>[
      MapEntry('left', 0.0),
      MapEntry('center', 0.5),
      MapEntry('right', 1.0),
    ];
    // Keyed by '${zone}_amb' / '${zone}_fl' (2026-08-05: each zone now
    // fires an ambient+flash pair, not one flash-only shot -- see the real
    // bug note at the flash-activation call site below). The downstream
    // encode/upload loops are already generic over rawShots.keys, so this
    // widened key space needs no changes there -- only guideRegions (still
    // keyed by bare zone name, shared by both illuminations of that zone)
    // stays a 3-entry map.
    final rawShots = <String, Uint8List>{};
    final zoneDebug = <String, dynamic>{};
    try {
      await _stopStream();

      // Same placement pre-roll as the video version -- real time to
      // physically get the thumb at the start position before the guide
      // starts translating. videoSweepActive is already true here so the
      // direction arrows/progress bar render during this static hold too.
      _apply(
        (s) => s.copyWith(
          distanceHint: 'Place your thumb at the start position',
          videoSweepActive: true,
          sweepProgress: 0.0,
          activeGuideShape: _sweepGuideShapeForProgress(0.0),
        ),
        force: true,
      );
      unawaited(HapticFeedback.lightImpact());
      await Future<void>.delayed(const Duration(milliseconds: _sweepCalibrationHoldMs));
      if (_disposed) return debug;
      for (final n in const ['Hold still…', '2…', '1…']) {
        if (_disposed) return debug;
        _apply((s) => s.copyWith(distanceHint: n));
        HapticFeedback.lightImpact();
        await Future<void>.delayed(const Duration(milliseconds: _sweepCalibrationTickMs));
      }
      if (_disposed) return debug;

      await (() async {
        // REAL BUG, found 2026-08-05: this used to leave the flash on
        // continuously for all 3 zone shots with ZERO EV compensation --
        // confirmed via real captured images (b1b5fc67): the pad tip was
        // visibly clipped to near-white in every single zone, the same
        // torch-blowout failure mode the main burst's own adaptive EV step
        // (_adaptiveFlashEvStep) was built to prevent, just never applied
        // here. Also, per the CTO's own request: an ambient+flash PAIR per
        // zone (not one flash-only shot) lets the backend flash-diff-fuse
        // each zone the same already-proven way _fuse_flash_ambient does
        // for the main burst, instead of scoring one blown-out flash shot
        // alone. Each zone now fires ambient (torch off) THEN flash (torch
        // on, EV-compensated) -- same alternation convention as the main
        // burst, just scoped per zone instead of per whole-burst index.
        final torchCapable = _flash?.isNeeded ?? false;
        final flashEvStep = torchCapable ? _adaptiveFlashEvStep() : 0.0;
        double? minEv, maxEv;
        if (torchCapable) {
          try {
            minEv = await cam.getMinExposureOffset();
            maxEv = await cam.getMaxExposureOffset();
          } catch (_) {}
        }
        debug['torchCapable'] = torchCapable;
        debug['flashEvStep'] = double.parse(flashEvStep.toStringAsFixed(3));
        unawaited(HapticFeedback.mediumImpact());
        unawaited(_audio.playSweepStart());

        // Tracks whether the immediately preceding shot fired the flash --
        // same asymmetric-settle discipline as the main burst (round 12):
        // only the transition AWAY from a real flash shot needs a settle
        // delay before the next (ambient) shot fires. Every zone after the
        // first ends on its own flash shot, so this fires between every
        // zone boundary except before zone 0's first ambient shot.
        var wasFlashLastShot = false;
        // Previous zone's flash JPEG + framing-similarity diagnostics --
        // see _zoneFramingSimilarity's own docstring for why this compares
        // already-captured stills instead of touching the live stream.
        Uint8List? prevZoneFlashBytes;
        var extraMoveMs = 0;

        for (var i = 0; i < zones.length; i++) {
          final zone = zones[i].key;
          final target = zones[i].value;
          if (_disposed) break;

          if (i == 0) {
            // Already at the left position from the pre-roll above.
            _apply((s) => s.copyWith(
                  sweepProgress: target,
                  activeGuideShape: _sweepGuideShapeForProgress(target),
                ));
          } else {
            // Animate the guide from the previous zone to this one -- real
            // time for the user's eye + thumb to track the motion, same
            // reasoning as the video version's continuous translation, now
            // paced per-hop instead of over one long continuous window.
            // Widened by extraMoveMs (bounded, one-shot) when the PREVIOUS
            // zone transition's framing-similarity check came back too high
            // -- see _zoneFramingSimilarity/_sweepZoneSimilarityThreshold.
            final fromProgress = zones[i - 1].value;
            final moveMs = _sweepZoneMoveMs + extraMoveMs;
            final grantedExtra = extraMoveMs > 0;
            if (grantedExtra) {
              zoneDebug['${zone}_extraMoveMsGranted'] = extraMoveMs;
              extraMoveMs = 0;
            }
            _apply((s) => s.copyWith(
                  distanceHint: grantedExtra
                      ? 'Move further this time'
                      : (zone == 'right'
                          ? 'Slowly move right'
                          : 'Slowly move to the middle'),
                ));
            final moveStart = DateTime.now();
            while (true) {
              final elapsedMs =
                  DateTime.now().difference(moveStart).inMilliseconds;
              final t = (elapsedMs / moveMs).clamp(0.0, 1.0);
              final progress = fromProgress + (target - fromProgress) * t;
              _apply((s) => s.copyWith(
                    sweepProgress: progress,
                    activeGuideShape: _sweepGuideShapeForProgress(progress),
                  ));
              if (t >= 1.0) break;
              await Future<void>.delayed(const Duration(milliseconds: 60));
            }
          }

          // Left zone: pre-roll already counted in above; a short settle is
          // enough. Center and right zones get a full count-in so the user
          // knows each shot is about to fire, not just the start of the sweep.
          if (i == 0) {
            unawaited(HapticFeedback.lightImpact());
            _apply((s) => s.copyWith(distanceHint: 'Hold still — capturing $zone'));
            await Future<void>.delayed(
                const Duration(milliseconds: _sweepZoneSettleMs));
            if (_disposed) break;
          } else {
            for (final n in const ['Hold still…', '2…', '1…']) {
              if (_disposed) break;
              _apply((s) => s.copyWith(distanceHint: n));
              unawaited(HapticFeedback.lightImpact());
              await Future<void>.delayed(
                  const Duration(milliseconds: _sweepCalibrationTickMs));
            }
            if (_disposed) break;
          }

          // Ambient shot (torch off). Only waits for the flash-off settle
          // if the flash was actually on a moment ago -- zone 0's first
          // ambient shot never waits (nothing to settle from yet).
          try {
            await _flash?.deactivate();
            if (minEv != null && maxEv != null) {
              await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
            }
            if (wasFlashLastShot) {
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            }
          } catch (_) {}
          wasFlashLastShot = false;
          final ambStart = DateTime.now();
          try {
            final xfile = await cam.takePicture();
            rawShots['${zone}_amb'] = await xfile.readAsBytes();
            zoneDebug['${zone}_amb_captureMs'] =
                DateTime.now().difference(ambStart).inMilliseconds;
          } catch (e) {
            zoneDebug['${zone}_amb_error'] = e.toString();
            debugPrint('[front] sweep-burst zone $zone ambient capture failed (non-blocking): $e');
          }

          // Flash shot (torch on, EV-compensated -- the real fix for the
          // blowout found in real captured images: every prior sweep-burst
          // zone fired at full/uncompensated exposure with no EV step at
          // all).
          if (torchCapable) {
            try {
              await _flash?.activate();
              if (minEv != null && maxEv != null) {
                await cam.setExposureOffset(
                    (_appliedEvOffset + flashEvStep).clamp(minEv, maxEv));
              }
              await Future<void>.delayed(const Duration(milliseconds: _burstFlashSettleMs));
            } catch (_) {}
          }
          wasFlashLastShot = torchCapable;
          final flStart = DateTime.now();
          try {
            final xfile = await cam.takePicture();
            rawShots['${zone}_fl'] = await xfile.readAsBytes();
            zoneDebug['${zone}_fl_captureMs'] =
                DateTime.now().difference(flStart).inMilliseconds;
          } catch (e) {
            zoneDebug['${zone}_fl_error'] = e.toString();
            debugPrint('[front] sweep-burst zone $zone flash capture failed (non-blocking): $e');
          }

          // Real-motion check against the PREVIOUS zone's flash shot -- see
          // _zoneFramingSimilarity's docstring. Diagnostic-only on its own
          // (always recorded, regardless of outcome, so the next real
          // device test's data can validate/tune the threshold); the one
          // corrective action it can take is granting the NEXT zone
          // transition extra move time (bounded, see extraMoveMs above).
          // Never blocks or retries THIS zone -- the shot is already taken.
          final thisFlash = rawShots['${zone}_fl'];
          if (thisFlash != null && prevZoneFlashBytes != null) {
            final sim = await _zoneFramingSimilarity(prevZoneFlashBytes, thisFlash);
            if (sim != null) {
              zoneDebug['${zone}_framingSimilarityToPrev'] =
                  double.parse(sim.toStringAsFixed(3));
              if (sim >= _sweepZoneSimilarityThreshold) {
                extraMoveMs = _sweepExtraMoveMs;
              }
            }
          }
          if (thisFlash != null) prevZoneFlashBytes = thisFlash;
        }

        try {
          await _flash?.deactivate();
          if (minEv != null && maxEv != null) {
            await cam.setExposureOffset(_appliedEvOffset.clamp(minEv, maxEv));
          }
        } catch (_) {}
      }()).timeout(const Duration(milliseconds: _sweepBurstTimeoutMs));
      stopwatch.stop();
      debug['durationMs'] = stopwatch.elapsedMilliseconds;

      // Every real shutter press is done -- nothing below needs the live
      // camera. Transition to the clean upload screen NOW rather than
      // after the decode/encode/upload work below, which can take minutes
      // on a slow connection (see _transitionToUploading's own docs for
      // the real device report this fixes). Called before the empty-shots
      // check too, since the camera work is over either way.
      await _transitionToUploading();

      if (rawShots.isEmpty) {
        debug['error'] = 'no zone shots captured';
        debug['zones'] = zoneDebug;
        return debug;
      }

      // Downscale + convert to grayscale AFTER the hold, same convention as
      // the main/secondary bursts -- keeps per-shot latency during the
      // actual capture window low; the expensive decode/encode work
      // happens once the user no longer needs to hold position.
      //
      // Encodes run SEQUENTIALLY, not concurrently. 6 simultaneous compute()
      // isolates on a mobile CPU starve each other -- real measurements
      // showed 18-22s per zone (vs ~3-4s expected) because each isolate was
      // waiting for a share of one constrained CPU, then collectively pushing
      // total encode wall-time close to the per-zone timeout. Sequential
      // encode gives each isolate the full CPU to itself; total wall-time is
      // roughly the same (N × single-encode-time either way) but each
      // individual zone stays well inside the timeout. On failure/timeout,
      // bytes stays empty (Uint8List(0)) -- the upload loop below skips
      // empty zones without counting them as consecutive failures.
      final zoneNames = rawShots.keys.toList(growable: false);
      final encoded = <Uint8List>[];
      for (final zone in zoneNames) {
        final encodeStart = DateTime.now();
        var bytes = Uint8List(0);
        try {
          final decoded = await decodeStillJpegToLuma(
            rawShots[zone]!, _sensorOrientation,
            targetWidth: _stillDecodeTargetWidth,
          ).timeout(const Duration(milliseconds: _sweepZoneEncodeTimeoutMs));
          if (decoded != null) {
            bytes = await compute(
              _encodeBurstIsolate,
              _BurstEncodeArgs(decoded.luma, decoded.width, decoded.height,
                  quality: _sweepZoneJpegQuality),
            ).timeout(const Duration(milliseconds: _sweepZoneEncodeTimeoutMs));
          }
        } catch (e) {
          zoneDebug['${zone}_encodeError'] = e.toString();
        }
        zoneDebug['${zone}_encodeMs'] =
            DateTime.now().difference(encodeStart).inMilliseconds;
        zoneDebug['${zone}_encodedBytes'] = bytes.length;
        encoded.add(bytes);
      }

      // REAL BUG, found 2026-08-03: these 3 uploads used to run concurrently
      // via Future.wait -- across 3 real tests (640f563a, fd1da8c1,
      // 0bd23cc2) the SAME zone (whichever ran last/largest) consistently
      // hit the upload timeout while the other two finished in 18-22s each,
      // even after the JPEG quality cut. The pattern (every concurrent
      // upload taking roughly 3x what a similar-sized single upload takes
      // elsewhere in this file) is consistent with 3 simultaneous uploads
      // splitting one constrained mobile-network pipe 3 ways rather than
      // each getting full bandwidth -- not 3 independent slow uploads, one
      // shared bottleneck. Fixed by uploading zones SEQUENTIALLY instead:
      // each one gets the full connection to itself, so the total time for
      // all 3 is expected to drop close to a single zone's own real upload
      // time x3, not x3 with contention on top. Each zone is still
      // individually try/caught + timeout-bounded so one failure only costs
      // that one candidate, same discipline as the capture loop above -- a
      // zone that fails simply doesn't get a `paths` entry.
      // 2026-08-05: once each zone started uploading an ambient+flash PAIR
      // (6 uploads, not 3), 2 real tests in a row showed the same shape --
      // one zone succeeds, then every later zone fails at the full
      // timeout (5c3eaa9b: 5 of 6 failed at exactly 18-30s each, ~150s
      // wasted on uploads that were never going to succeed). Bail out of
      // the remaining zones after _sweepZoneMaxConsecutiveUploadFailures
      // in a row -- their encoded bytes stay in `encoded`/rawShots, just
      // never sent, so this can only ever save time, never lose a zone
      // that would otherwise have succeeded (the whole point is that the
      // evidence says it wouldn't have).
      final paths = <String, String>{};
      var consecutiveUploadFailures = 0;
      for (var i = 0; i < zoneNames.length; i++) {
        if (consecutiveUploadFailures >= _sweepZoneMaxConsecutiveUploadFailures) {
          zoneDebug['${zoneNames[i]}_uploadSkipped'] =
              'bailed after $consecutiveUploadFailures consecutive failures';
          continue;
        }
        final zone = zoneNames[i];
        if (encoded[i].isEmpty) {
          // Encode failed for this zone -- skip without counting as a
          // consecutive upload failure (a bad encode on zone N shouldn't
          // cause the bail-out to drop zones N+1 and N+2 whose encodes
          // may have succeeded fine).
          zoneDebug['${zone}_uploadSkipped'] = 'encode failed';
          continue;
        }
        final path = '$basePath/sweep_burst_$zone.jpg';
        final uploadStart = DateTime.now();
        try {
          // Passed IN, not wrapped around the call -- see _uploadWithRetry's
          // own docs for why an external .timeout() here would silently
          // leave the real native upload running as a zombie instead of
          // actually cancelling it.
          await _uploadWithRetry(encoded[i], path,
              timeout: const Duration(milliseconds: _sweepZoneUploadTimeoutMs));
          paths[zone] = path;
          consecutiveUploadFailures = 0;
        } catch (e) {
          zoneDebug['${zone}_uploadError'] = e.toString();
          consecutiveUploadFailures++;
        }
        zoneDebug['${zone}_uploadMs'] =
            DateTime.now().difference(uploadStart).inMilliseconds;
      }

      // Per-zone guide region: the on-screen guide translated for each
      // zone, so the still-space AFIS mask must translate with it --
      // otherwise the backend would crop the LEFT zone's frame using the
      // CENTRE zone's guide bounds. Falls back silently (field just absent)
      // if cached screen/preview geometry isn't available; the backend
      // treats a missing per-zone guide as "use the main guideRegion".
      final guideRegions = <String, dynamic>{};
      for (final entry in zones) {
        final region = _guideRegionForSweepZone(entry.value, tipAngleDeg);
        if (region != null) guideRegions[entry.key] = region;
      }

      debug['paths'] = paths;
      debug['zones'] = zoneDebug;
      if (guideRegions.isNotEmpty) debug['guideRegions'] = guideRegions;
      debug['uploaded'] = true;
      // Distinct completion cue -- lighter than the main burst's
      // heavyImpact()+brand-jingle (this is one bonus step, not "the whole
      // capture is done"), but still a clear, real signal the sweep ended.
      unawaited(HapticFeedback.lightImpact());
      unawaited(_audio.playSweepComplete());
    } catch (e) {
      debug['error'] = e.toString();
      // Diagnostic only (2026-08-05 audit): the zone loop's takePicture()/
      // flash calls above have no real cancellation path if
      // _sweepBurstTimeoutMs actually fires -- unlike probeTorchExposureCompat
      // (a native-side hard-bounded throwaway Camera2 session) or
      // CameraService.initializeCamera() (which awaits its own pending
      // initialization before disposing), there's no evidence yet this
      // specific timeout has ever fired on a real device, so widening it
      // further or adding forced-dispose logic would be tuning blind. This
      // flag lets the next real capture confirm whether it's a live risk
      // before spending effort on it, same discipline as every other
      // diagnostic-before-fix change in this project.
      if (e is TimeoutException) debug['timedOut'] = true;
      debugPrint('[front] sweep burst capture failed (non-fatal): $e');
    } finally {
      try {
        await _flash?.deactivate();
      } catch (_) {}
      _apply(
        (s) => s.copyWith(
          distanceHint: null,
          videoSweepActive: false,
          sweepProgress: 0.0,
          activeGuideShape: null,
        ),
        force: true,
      );
    }
    return debug;
  }

  Future<void> _finishAndUpload(
    List<_RawShot> rawShots,
    double gyroAtCapture, {
    List<double?>? sweepCentroids,
    Map<String, dynamic>? sweepDebugData,
  }) async {
    _audio.silence();
    // NOT `uploading` yet -- the sweep burst below still needs the thumb held
    // in place on the main camera. `capturingExtra` keeps the guide + camera
    // preview visible; the real `uploading` transition happens after processing.
    // Clear confirmationText so the sweep's own status banners (distanceHint)
    // can render -- _fireBurst sets it to '✓ Captured' and only clears it in
    // its own finally block after we return, which would cover our banners.
    _apply(
      (s) => s.copyWith(
        phase: FrontCapturePhase.capturingExtra,
        extraProgress: 0.0,
        confirmationText: null,
      ),
      force: true,
    );

    final userId = _userId;
    if (userId == null) {
      _fail('No user ID');
      return;
    }

    try {
      final id = _uuid.v4();
      final basePath = 'captures/$userId/$id';

      final tipAngleDeg =
          (_sensorOrientation == 90 || _sensorOrientation == 270) ? 0.0 : 90.0;

      final rawSensorSupport = await _queryRawSensorSupport();
      final noiseReductionOffSupport = await _queryNoiseReductionSupport();
      final cameraLensInfo = await _queryCameraLensInfo();
      final manualExposureSupport = await _queryManualExposureSupport();
      // Already ran (and was awaited to completion) before the camera even
      // opened, in FrontCaptureScreen._init() -- this just reads the cached
      // result, does not re-trigger the native probe.
      final torchExposureProbe = await probeTorchExposureCompat();

      // Sweep burst: 3 zone stills (left/centre/right) on the same main camera
      // session, before the camera is disposed. Gated on _sweepBurstHybridEnabled
      // -- flip that flag to disable instantly without touching anything else.
      // _captureSweepBurst itself transitions to the uploading screen right
      // after its own last real shutter press -- the fallback call below
      // (_transitionedToUploading-guarded, so a no-op when that already
      // ran) only actually does anything when the flag is off.
      final sweepBurstDebug = _sweepBurstHybridEnabled
          ? await _captureSweepBurst(basePath, tipAngleDeg)
          : <String, dynamic>{'attempted': false, 'reason': 'feature disabled'};
      await _transitionToUploading();

      // Decode and encode all burst frames now (deferred until after the
      // sweep so the user never saw a live-camera "Processing…" banner
      // mid-session -- now happens under the clean uploading screen
      // instead, see _transitionToUploading). Each raw JPEG is converted to
      // grayscale + downscaled, same as before but moved here.
      //
      // Sharpness ROI, added 2026-08-06 -- see _stillLaplacianVariance's
      // docstring for the real background-confound bug this fixes. Built
      // once (the guide region is fixed for the whole capture, not
      // per-frame) from the same still-space _guideCx/_guideCy/_guideRx/
      // _guideRy already used for the AFIS mask sent to the backend. A
      // modest 1.2x dilation -- smaller than the backend's own 1.3x
      // _MASK_COVER_DILATE -- so a real ridge-bearing pad near the guide's
      // edge isn't clipped by a too-tight ROI; this is a sharpness METRIC,
      // not a hard content mask, so erring slightly generous costs nothing.
      final sharpnessRoi = Rect.fromLTRB(
        _guideCx - _guideRx * 1.2,
        _guideCy - _guideRy * 1.2,
        _guideCx + _guideRx * 1.2,
        _guideCy + _guideRy * 1.2,
      );
      final decodedShots = await Future.wait(rawShots.map((r) async {
        var bytes = r.jpeg;
        // Falls back to the stale stream-frozen r.laplacianScore only if
        // decode fails -- never worse than before this fix, since that was
        // already the only value available in that case.
        var lap = r.laplacianScore;
        try {
          final decoded = await decodeStillJpegToLuma(
            r.jpeg, _sensorOrientation,
            targetWidth: _stillDecodeTargetWidth,
          );
          if (decoded != null) {
            final result = await compute(
              _encodeBurstWithSharpnessIsolate,
              _BurstEncodeArgs(decoded.luma, decoded.width, decoded.height,
                  sharpnessRoi: sharpnessRoi),
            );
            bytes = result.jpeg;
            lap = result.sharpness;
          }
        } catch (_) {}
        return (
          bytes: bytes,
          flashOn: r.flashOn,
          lap: lap,
          ts: r.timestamp,
          exif: r.exif,
          gyro: r.gyroMagnitudeDegPerSec,
        );
      }));

      // Build upload tasks and Firestore frames metadata from the decoded shots.
      final uploadTasks = <(Uint8List, String)>[];
      final framesMeta = <Map<String, dynamic>>[];
      var ambIdx = 0, flIdx = 0;
      for (var frameIdx = 0; frameIdx < decodedShots.length; frameIdx++) {
        final s = decodedShots[frameIdx];
        if (s.bytes.isEmpty) continue;
        final type = s.flashOn ? 'fl' : 'amb';
        final idx = s.flashOn ? flIdx++ : ambIdx++;
        final path = '$basePath/front_burst_${type}_$idx.jpg';
        uploadTasks.add((s.bytes, path));
        final centroidX = (sweepCentroids != null && frameIdx < sweepCentroids.length)
            ? sweepCentroids[frameIdx]
            : null;
        framesMeta.add({
          'path': path,
          'angleDeg': 0.0,
          'flashOn': s.flashOn,
          'type': 'burst',
          if (s.lap != null) 'laplacianScore': double.parse(s.lap!.toStringAsFixed(1)),
          'timestamp': s.ts.toIso8601String(),
          if (centroidX != null) 'centroidX': double.parse(centroidX.toStringAsFixed(3)),
          if (s.exif.exposureTimeUs != null) 'shutterSpeedUs': s.exif.exposureTimeUs,
          if (s.exif.exposureTimeReadable != null)
            'shutterSpeedReadable': s.exif.exposureTimeReadable,
          if (s.exif.isoValue != null) 'isoValue': s.exif.isoValue,
          'isLockedShutter': false,
          // Per-shot device rotation rate at capture time (deg/s), added
          // 2026-08-06 -- lets the backend's fusion functions (ECC
          // alignment in _stack_face_on/_focus_stack_face_on) down-weight
          // or diagnose individual frames captured mid-shake, instead of
          // only ever seeing the pixels with no motion context. Additive;
          // the single top-level gyroMagnitudeDegPerSec field (captured at
          // hold-completion, not per-shot) is unchanged.
          if (s.gyro != null)
            'gyroMagnitudeDegPerSec': double.parse(s.gyro!.toStringAsFixed(2)),
        });
      }

      // Real upload begins here -- the actual Firestore write + main burst
      // upload below. Fallback transition only (see _transitionToUploading
      // docs) -- the normal path already switched the UI over right after
      // the sweep burst's last real shutter press, well before this point.
      await _transitionToUploading();

      // Single Firestore write for the whole capture -- evaluated by the
      // security rules as `create` (the doc doesn't exist yet), which is
      // the only client-writable path. Everything gathered above (main
      // burst frames, rawSensorSupport, secondary-camera results, distance-
      // stage-2 results) goes into this one call; there is no later
      // `.update()` on this doc from the client.
      final firestoreFuture = FirebaseFirestore.instance.collection('captures').doc(id).set({
        'captureId': id,
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'pending',
        'source': 'clearbridge_beta',
        'captureMode': 'front_only_v1',
        'captureMethod': 'front_only_v1',
        'guideRegion': {
          'cx': _guideCx,
          'cy': _guideCy,
          'rx': _guideRx,
          'ry': _guideRy,
          'n': _guideN,
          'tipAngleDeg': tipAngleDeg,
        },
        'burstFrameCount': decodedShots.where((s) => s.bytes.isNotEmpty).length,
        'flashEvDebug': _flashEvDebug,
        'liveWavelengthDebug': _wavelengthDebug,
        'refocusDebug': _refocusDebug,
        if (sweepDebugData != null) 'sweepDebug': sweepDebugData,
        'zoomDebug': {
          'zoomApplied': _zoomEverApplied,
          'finalZoomLevel': double.parse(_zoomLevel.toStringAsFixed(3)),
          'maxZoomLevel': double.parse(_maxZoomLevel.toStringAsFixed(3)),
        },
        'gyroMagnitudeDegPerSec': double.parse(gyroAtCapture.toStringAsFixed(2)),
        'frames': framesMeta,
        if (rawSensorSupport != null) 'rawSensorSupport': rawSensorSupport,
        if (noiseReductionOffSupport != null)
          'noiseReductionOffSupport': noiseReductionOffSupport,
        if (cameraLensInfo != null) 'cameraLensInfo': cameraLensInfo,
        if (manualExposureSupport != null)
          'manualExposureSupport': manualExposureSupport,
        if (torchExposureProbe != null) 'torchExposureProbe': torchExposureProbe,
        'sweepBurstDebug': sweepBurstDebug,
      }, SetOptions(merge: true));

      var completed = 0;
      final total = math.max(uploadTasks.length, 1);
      for (var i = 0; i < uploadTasks.length; i += _uploadConcurrency) {
        final end = math.min(i + _uploadConcurrency, uploadTasks.length);
        await Future.wait([
          for (var j = i; j < end; j++)
            _uploadWithRetry(uploadTasks[j].$1, uploadTasks[j].$2).then((_) {
              completed++;
              _apply((s) => s.copyWith(uploadProgress: completed / total));
            }),
        ]);
      }
      await firestoreFuture;

      () async {
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
          debugPrint('[front] processEnhanceAndScore trigger failed (non-blocking): $e');
        }
      }();

      _apply(
        (s) => s.copyWith(
          phase: FrontCapturePhase.complete,
          captureId: id,
          uploadProgress: 1.0,
        ),
        force: true,
      );
    } catch (e) {
      _fail('Upload failed: $e');
    }
  }

  // _captureSecondaryBurst and _waitForSecondaryFocusLock removed 2026-08-03
  // (secondary / IR camera removed -- see CLAUDE.md round-21 notes).

  /// REAL ROOT CAUSE, found 2026-08-05: `putData()` returns an `UploadTask`
  /// -- a real, cancellable native upload, not a plain Future. The previous
  /// version of this method discarded that reference and just awaited it
  /// directly, so a caller wrapping the whole call in `.timeout(...)` (the
  /// sweep-zone upload loop) only ever stopped DART from waiting on it --
  /// the underlying native upload kept running in the background,
  /// invisibly, indefinitely, still consuming real bandwidth. Every
  /// "failed" (timed-out) zone upload was actually a zombie task still
  /// fighting the NEXT zone's fresh upload attempt for the same
  /// connection -- exactly matching the real cascading-failure pattern
  /// seen across 2 real captures (one zone succeeds cleanly, then every
  /// later zone increasingly starved until all subsequent ones hit the
  /// timeout ceiling too). Timeout-tuning alone (lowering the ceiling,
  /// bailing out after N failures) could only ever reduce the symptom's
  /// cost, never fix it -- the pile of zombie uploads was the actual
  /// disease.
  ///
  /// Fixed by taking an optional `timeout` HERE (not at the call site) so
  /// this method keeps the real `UploadTask` reference in scope and can
  /// genuinely cancel it -- both on timeout (via `.timeout()`'s own
  /// `onTimeout` callback, which runs synchronously before the exception
  /// propagates) and on any other error that triggers a retry (so a failed
  /// attempt never lingers into the next one).
  Future<void> _uploadWithRetry(
    Uint8List bytes,
    String path, {
    String contentType = 'image/jpeg',
    Duration? timeout,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final task = FirebaseStorage.instance
          .ref()
          .child(path)
          .putData(bytes, SettableMetadata(contentType: contentType));
      try {
        if (timeout != null) {
          await task.timeout(timeout, onTimeout: () {
            unawaited(task.cancel().catchError((_) => false));
            throw TimeoutException('upload timed out after $timeout');
          });
        } else {
          await task;
        }
        return;
      } catch (e) {
        unawaited(task.cancel().catchError((_) => false));
        final code = e is FirebaseException ? e.code : null;
        final retryable = code == null || !_uploadNonRetryableCodes.contains(code);
        // TimeoutException has no Firebase code (code == null → retryable by
        // default), but a timed-out upload should never be retried -- the
        // cancel() above already fired, and re-trying immediately would just
        // queue another full-timeout attempt (3 retries × 18s = 54s extra).
        if (e is TimeoutException || !retryable || attempt >= _uploadRetryDelaysMs.length) rethrow;
        await Future.delayed(Duration(milliseconds: _uploadRetryDelaysMs[attempt]));
      }
    }
  }

  Future<void> _stopStream() async {
    if (!_streamRunning) return;
    _streamRunning = false;
    try {
      await _camera?.stopImageStream();
    } catch (_) {}
  }

  void _fail(String message) {
    _audio.silence();
    unawaited(_flash?.deactivate());
    unawaited(_stopStream());
    unawaited(_gyroSub?.cancel());
    _gyroSub = null;
    _apply((s) => s.copyWith(phase: FrontCapturePhase.error, error: message), force: true);
  }

  void _apply(FrontCaptureState Function(FrontCaptureState) update, {bool force = false}) {
    _state = update(_state);
    if (_disposed) return;
    final now = DateTime.now();
    if (force ||
        _lastEmitAt == null ||
        now.difference(_lastEmitAt!).inMilliseconds >= _emitThrottleMs) {
      _lastEmitAt = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_flash?.deactivate());
    unawaited(_stopStream());
    unawaited(_gyroSub?.cancel());
    _gyroSub = null;
    _audio.dispose();
    super.dispose();
  }
}
