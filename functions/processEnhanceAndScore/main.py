"""
processEnhanceAndScore — Firebase Cloud Function (africa-south1)
Full pipeline: SfM unwrap → NNS enhancement → NFIQ scoring → Henry classification

Input:  Firebase callable { captureId, userId, basePath }
Output: Firestore captures/{captureId} updated with scoring result
"""

from __future__ import annotations

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

import firebase_admin
from firebase_admin import firestore, storage
from firebase_functions import https_fn, options

import nfiq2_client

# cv2 / numpy / sfm_pipeline / enhancement_pipeline are heavy (DLL load on Windows).
# Deferring them to first function invocation keeps module import <1 s so that the
# Firebase CLI local analysis server (10 s timeout) can return functions.yaml.
cv2 = None              # type: ignore[assignment]
np  = None              # type: ignore[assignment]
enhancement_pipeline = None   # type: ignore[assignment]
sfm_pipeline         = None   # type: ignore[assignment]
afis_print           = None   # type: ignore[assignment]
CaptureQualityError  = Exception  # placeholder; replaced by _init_heavy_deps()

def _init_heavy_deps() -> None:
    """Import scientific libraries on first call. No-op on subsequent calls."""
    global cv2, np, enhancement_pipeline, sfm_pipeline, afis_print, CaptureQualityError
    if cv2 is not None:
        return
    import cv2 as _cv2
    import numpy as _np
    import enhancement_pipeline as _ep
    import sfm_pipeline as _sfm
    import afis_print as _afis
    from sfm_pipeline import CaptureQualityError as _CQE
    cv2 = _cv2
    np  = _np
    enhancement_pipeline = _ep
    sfm_pipeline         = _sfm
    afis_print           = _afis
    CaptureQualityError  = _CQE

# force=True: the Functions Framework/firebase_functions runtime configures the
# root logger before this module imports, so a plain basicConfig() call here is
# documented to be a silent no-op (it only acts if the root logger has no
# handlers yet). Confirmed in production: none of this module's logger.info/
# logger.warning calls -- including the ones that would explain an AFIS
# failure -- were reaching Cloud Logging, only infra-level entries were.
# force=True tears down whatever handler got installed first and replaces it
# with a plain synchronous StreamHandler, so our own log calls actually emit.
logging.basicConfig(level=logging.INFO, force=True)
logger = logging.getLogger(__name__)

# ── Constants ─────────────────────────────────────────────────────────────────
# Models live in Firebase Storage and are downloaded to /tmp/ on cold start.
_STORAGE_MODEL_PREFIX = 'models'
_NFIQ_PATH      = '/tmp/nfiq_resnet18.onnx'
_NNS_PATH       = '/tmp/nns_stage3.pt'    # Stage 3 UNet; falls back to nns_stage1.pt in enhancement_pipeline
_NNS_PATH_S1    = '/tmp/nns_stage1.pt'
_THUMB_SEG_PATH = '/tmp/thumb_seg_unet.onnx'   # bootstrap segmentation fallback; see sfm_pipeline._segment_via_ml_model
_PASS_THRESHOLD_BETA       = 35.0   # collect all prints for training
_PASS_THRESHOLD_PRODUCTION = 80.0   # API quality gate — switch when going live
_PASS_THRESHOLD = _PASS_THRESHOLD_BETA
# Minimum raw Laplacian variance a secondary camera's best frame must have to
# be allowed to BEAT the main-camera result. Below this threshold the frame is
# too blurry for the proxy to be trusted (Gabor synthesis creates plausible
# ridge texture from a blurry input, fooling the proxy — confirmed: camera 3
# scored proxy 74.81 / real NFIQ2 5 on frames with Laplacian 19-22). The
# secondary camera is still scored and its proxy score still appears in
# secondaryCamScores for diagnostics; it simply cannot displace a better
# main-camera result. 50.0 sits well above every confirmed-blurry secondary
# frame (19-22) and well below sharp frames (558 for camera 2 far shot).
_SECONDARY_MIN_LAPLACIAN = 50.0
# Native ridge wavelength ceiling from afis_print._ridge_wavelength's own clip.
# A secondary frame that reports exactly 19.5+ px hit the measurement ceiling --
# the actual wavelength is >=19.5px, meaning the user is too close for the sweet
# spot (9-14px). Block the secondary from winning in this case: it cannot beat
# a main-camera frame already in the sweet spot, and Gabor synthesis on a
# too-close secondary frame produces plausible-looking but non-AFIS-matchable
# output, exactly the same failure mode as the blurry-frame problem above.
_SECONDARY_MAX_WAVELENGTH_PX = 19.5
# True monochrome/NIR sensors (Camera2 colorFilterArrangement MONO or NIR) have
# different optical scattering -- ridges may appear at 7-11px instead of 9-14px,
# so the closeness ceiling can be tighter (user doesn't need to be as far back).
# Applied only when cameraLensInfo reports one of these exact string values
# (written by MainActivity.colorFilterArrangementName). Zero impact on Bayer
# cameras (RGGB/GBRG/GRBG/BGGR) which cover all current test-device cameras.
_IR_CFA_VALUES: frozenset = frozenset({'MONO', 'NIR'})
_SECONDARY_MAX_WAVELENGTH_PX_IR = 16.0
# IR-tuned Gabor sigma ratio: IR ridge contrast is steeper (less ambient
# scattering) and may benefit from a tighter envelope. Used as a second
# max-of-variants candidate when scoring a MONO/NIR camera frame, alongside
# the standard sigma -- whichever scores higher wins. NOT applied to Bayer
# cameras; 0.3 is a hypothesis pending real IR captures on an S24 Ultra or
# equivalent device with a true MONO sensor.
_IR_GABOR_SIGMA_RATIO = 0.3
_TARGET_SIZE    = (500, 500)
_SCORE_PRESCALE_PX = 700   # two-step downscale waypoint before the 500x500 LANCZOS
_RATE_LIMIT_SEC = 60   # minimum seconds between pipeline calls per user

# Beta phase flag — retains ALL raw frames globally for pipeline training.
# Set to False before production launch; frame deletion then reverts to the
# per-capture preserveRawFrames / isTestParticipant / dev-UID rules only.
_BETA_PHASE = True

# Developer UID — frames are never deleted for this account so the SFM optimizer
# can replay any capture offline without needing preserveRawFrames set manually.
_DEV_UID = 'S7B5LAvXiJdKjHTbpAFMoINv4Um2'


@firestore.transactional
def _check_rate_limit_tx(transaction, user_ref):
    """Atomically check rate-limit and stamp lastCaptureCallAt. Returns remaining
    seconds to wait, or None if the call is allowed."""
    snap = user_ref.get(transaction=transaction)
    last_call = (snap.to_dict() or {}).get('lastCaptureCallAt')
    if last_call is not None:
        try:
            elapsed = time.time() - last_call.timestamp()
            if elapsed < _RATE_LIMIT_SEC:
                return int(_RATE_LIMIT_SEC - elapsed)
        except AttributeError:
            pass  # field is not a Timestamp — treat as no limit
    transaction.set(user_ref, {'lastCaptureCallAt': firestore.SERVER_TIMESTAMP}, merge=True)
    return None

# Angle order matches Flutter upload: front, right, top, left (index 0–3)
_ANGLE_NAMES = ['front', 'right', 'top', 'left']

# Standard phone Y-plane resolutions for raw-frame fallback decoding
_KNOWN_DIMS = [
    (1600, 1200), (1200, 1600),
    (1280,  960), ( 960, 1280),
    (1920, 1080), (1080, 1920),
    (1280,  720), ( 720, 1280),
    ( 640,  480), ( 480,  640),
]

# ── Firebase initialisation ───────────────────────────────────────────────────
# Must run at module level so the callable SDK middleware can verify ID tokens
# before user code (processEnhanceAndScore) executes. Lazy init inside
# _get_firebase() caused "default Firebase app does not exist" auth failures.
#
# K_SERVICE is set by the Cloud Run runtime (all Cloud Functions Gen2).
# It is NOT set during Firebase CLI local analysis, which would otherwise
# hang for 10s on the GCP metadata server 169.254.169.254.
if not firebase_admin._apps and os.environ.get('K_SERVICE'):
    firebase_admin.initialize_app()

_db     = None
_bucket = None
_nfiq_session = None


def _get_firebase():
    global _db, _bucket
    if _db is None:
        _db     = firestore.client()
        _bucket = storage.bucket()
    return _db, _bucket


def _ensure_models():
    """Load model files into /tmp/: bundled source copy first, Storage fallback."""
    import shutil
    _, bucket = _get_firebase()
    # (required=True) models abort the function on failure; optional models degrade gracefully
    model_specs = [
        (_NFIQ_PATH,      'nfiq_resnet18.onnx', True),
        (_NNS_PATH,       'nns_stage3.pt',       False),
        (_NNS_PATH_S1,    'nns_stage1.pt',       False),
        (_THUMB_SEG_PATH, 'thumb_seg_unet.onnx', False),
    ]
    src_dir = os.path.dirname(os.path.abspath(__file__))
    for local_path, remote_name, required in model_specs:
        if not os.path.exists(local_path):
            # Prefer the model bundled with the function source (faster cold start,
            # no Storage round-trip). Fall back to Firebase Storage if absent.
            bundled = os.path.join(src_dir, remote_name)
            if os.path.exists(bundled):
                shutil.copy(bundled, local_path)
                logger.info(f'Model loaded from bundle: {remote_name} ({os.path.getsize(local_path) // 1024 // 1024} MB)')
                continue
            remote_path = f'{_STORAGE_MODEL_PREFIX}/{remote_name}'
            try:
                logger.info(f'Downloading model {remote_path} → {local_path}')
                bucket.blob(remote_path).download_to_filename(local_path)
                logger.info(f'Model ready: {local_path} ({os.path.getsize(local_path) // 1024 // 1024} MB)')
            except Exception as e:
                if required:
                    raise
                logger.warning(f'Optional model {remote_name} not found in Storage (skipping): {e}')


def _get_nfiq_session():
    global _nfiq_session
    if _nfiq_session is None:
        _ensure_models()
        import onnxruntime as ort
        _nfiq_session = ort.InferenceSession(_NFIQ_PATH, providers=['CPUExecutionProvider'])
        logger.info("NFIQ ONNX session initialised")
    return _nfiq_session


# ── Cloud Function ────────────────────────────────────────────────────────────

@https_fn.on_call(
    region='africa-south1',
    # Raised from 120s 2026-07-16: real capture 9efb7d1e showed the AFIS
    # variant loop alone taking 15+ minutes on a poorly-correlated burst
    # (fixed separately via stack_cache + a 70s variant-loop budget), but
    # 120s left near-zero margin even for a normal capture once cold model
    # downloads (~15-55s per the real logs) are included. 300s gives real
    # headroom; the internal 70s variant budget already bounds runaway work,
    # so this ceiling costs nothing by itself (2nd-gen Functions bill actual
    # compute time, not the timeout allowance).
    timeout_sec=300,
    memory=options.MemoryOption.GB_4,
    cpu=4,
    min_instances=0,
)
def processEnhanceAndScore(req: https_fn.CallableRequest):
    """
    Flutter callable. Receives { captureId, userId, basePath }.
    Runs full SfM → enhancement → NFIQ pipeline.
    Writes result to Firestore captures/{captureId}.
    Returns { nfiqScore, nfiqPass, henryClass }.
    """
    if not req.auth:
        raise https_fn.HttpsError(
            code=https_fn.FunctionsErrorCode.UNAUTHENTICATED,
            message='User must be authenticated to process a capture',
        )

    data       = req.data or {}
    capture_id = (data.get('captureId') or '').strip()
    user_id    = (data.get('userId')    or '').strip()
    base_path  = (data.get('basePath')  or '').strip()
    # Normalized thumb width (0-1 fraction of frame width) from MediaPipe.
    # Used by SfM to skip unreliable in-frame silhouette detection.
    raw_twf = data.get('thumbWidthFraction')
    thumb_width_fraction: Optional[float] = float(raw_twf) if raw_twf is not None else None
    # Per-angle device orbit angles passed from Flutter to avoid a second
    # Firestore read during SfM seeding.  e.g. {'front': 0.0, 'left': -18.5}
    payload_orbit_angles: dict = data.get('orbitAngles') or {}
    arc_angles_raw: list = data.get('arcAngles') or []
    arc_angles: Optional[list[float]] = [float(a) for a in arc_angles_raw] if arc_angles_raw else None
    is_arc = bool(arc_angles)
    is_oscillating = (data.get('captureMode') or '') == 'oscillating_8phase'
    is_front_only = (data.get('captureMode') or '') == 'front_only_v1'

    if not capture_id or not user_id or not base_path:
        raise https_fn.HttpsError(
            code=https_fn.FunctionsErrorCode.INVALID_ARGUMENT,
            message='captureId, userId, and basePath are required',
        )

    if req.auth.uid != user_id:
        raise https_fn.HttpsError(
            code=https_fn.FunctionsErrorCode.PERMISSION_DENIED,
            message='userId does not match authenticated user',
        )

    _init_heavy_deps()  # cv2 / numpy / sfm_pipeline / enhancement_pipeline

    logger.info(f"Processing capture={capture_id} user={user_id} path={base_path}")
    t_start = time.monotonic()
    db, _ = _get_firebase()   # initialise db + bucket on first request

    # ── Ownership check ────────────────────────────────────────────────────────
    # The only prior authorization check (req.auth.uid != user_id) verifies the
    # caller's token matches a userId the CALLER supplied, not that captureId
    # actually belongs to them -- an authenticated caller could otherwise pass
    # their own userId alongside an arbitrary other user's real captureId +
    # basePath (e.g. leaked via a screenshot, log, or shared link) and have this
    # function read/re-process/overwrite that other user's capture document via
    # the Admin SDK, which bypasses Firestore rules entirely. captureId is a
    # random client-generated v4 UUID (see front_capture_controller.dart), so
    # this isn't trivially guessable in bulk, but relying on UUID entropy as the
    # only barrier is not a real authorization control. Reject early, before
    # consuming the per-user rate limit or any compute, if the capture doc
    # doesn't exist or its recorded userId doesn't match the caller.
    _owner_snap = db.collection('captures').document(capture_id).get()
    if not _owner_snap.exists or (_owner_snap.to_dict() or {}).get('userId') != user_id:
        raise https_fn.HttpsError(
            code=https_fn.FunctionsErrorCode.PERMISSION_DENIED,
            message='captureId does not belong to the authenticated user',
        )

    # ── Rate limit: 60 s per user ─────────────────────────────────────────────
    # Prevents cost-bomb abuse — each invocation runs a 4 GB / 4 vCPU pipeline.
    # Transaction ensures the check+write is atomic so concurrent requests
    # cannot both slip through before either stamps lastCaptureCallAt.
    # Admin SDK writes lastCaptureCallAt; Firestore rules block client resets.
    user_ref = db.collection('users').document(user_id)
    remaining = _check_rate_limit_tx(db.transaction(), user_ref)
    if remaining is not None:
        raise https_fn.HttpsError(
            code=https_fn.FunctionsErrorCode.RESOURCE_EXHAUSTED,
            message=f'Please wait {remaining}s before submitting another capture.',
        )

    _ensure_models()  # copy bundled NFIQ + NNS models to /tmp/ on cold start; Storage fallback if absent

    # Mark as enhancing
    _update_firestore(capture_id, {'status': 'enhancing', 'processingStartedAt': firestore.SERVER_TIMESTAMP})

    try:
        # ── 1. Download frames from Storage ───────────────────────────────────
        logger.info('stage=download_start elapsed=%.1fs', time.monotonic() - t_start)
        ambient_frames = None
        flash_frames   = None
        ambient_burst  = None
        flash_burst    = None
        ambient_burst_gyros = None
        flash_burst_gyros   = None
        arc_frame_wts  = None
        osc_theta_deg  = None
        if is_arc:
            frames, frame_meta, arc_sfm_angles, arc_sweep_stats, arc_frame_wts = _download_arc_frames(capture_id, base_path)
            actual_angles = arc_sfm_angles
            _update_firestore(capture_id, {
                'captureMode':  'arc_sweep',
                'arcAnglesDeg': [round(a, 1) for a in arc_sfm_angles],
                # Physical sweep span in degrees (left + right actual pitch range).
                # arcAnglesDeg now always spans ~±90° (normalised to actual data)
                # so the raw SfM range is no longer meaningful for diagnostics.
                'arcSpanDeg': round(
                    arc_sweep_stats['arcActualLeftDeg'] + arc_sweep_stats['arcActualRightDeg'], 1
                ),
                **arc_sweep_stats,
            })
        elif is_front_only:
            frames, frame_meta, actual_angles, ambient_frames, flash_frames = \
                _download_front_only_frames(capture_id, base_path)
            # Preserve the raw burst for the deepFuse variant -- same schema
            # _download_front_burst already expects (frames[] entries with
            # angleDeg/flashOn/type/laplacianScore/path), just never wired in
            # for this capture mode. Without this, deepFuse always self-skips
            # for front_only_v1 despite being worth +2.5-8.5 NFIQ elsewhere.
            ambient_burst, flash_burst, ambient_burst_gyros, flash_burst_gyros = \
                _download_front_burst(capture_id)
            _update_firestore(capture_id, {'captureMode': 'front_only_v1'})
        elif is_oscillating:
            (frames, frame_meta, osc_angles, osc_stats,
             arc_frame_wts, ambient_frames, flash_frames) = _download_oscillating_frames(capture_id, base_path)
            actual_angles = osc_angles
            # Tight output span instead of the default ±120°: this mode is a
            # single dense sweep, not four sparse checkpoints, so the ±65°
            # per-frame margin the adaptive-span logic uses elsewhere would
            # massively overshoot real coverage (e.g. a ±45° sweep would
            # otherwise get a ±110° output texture, hallucinating ~60° of
            # gap-filled edge on each side). Half the observed range plus a
            # small margin keeps the texture matched to what was actually
            # swept.
            _range_half   = (max(osc_angles) - min(osc_angles)) / 2.0
            osc_theta_deg = min(120.0, max(40.0, _range_half + 15.0))
            # Preserve the raw near-face-on front burst (in addition to the
            # binned frames) for the deep-fusion superprint variant.
            ambient_burst, flash_burst, ambient_burst_gyros, flash_burst_gyros = \
                _download_front_burst(capture_id)
            _update_firestore(capture_id, {
                'captureMode':    'oscillating_8phase',
                'oscAnglesDeg':   [round(a, 1) for a in osc_angles],
                **osc_stats,
            })
        else:
            frames, frame_meta, actual_angles, ambient_frames, flash_frames = _download_best_frames(base_path)
        t_download = time.monotonic()
        logger.info('stage=download_done  elapsed=%.1fs', t_download - t_start)

        # ── 1b. Build IMU-seeded cylindrical angles (orbit mode only) ─────────
        # Replace the hardcoded 0°/90°/180°/270° nominal cylindrical positions
        # with estimates derived from the device orbit angles recorded by the
        # Flutter app at capture time.  When a user fires slightly short of a
        # target (e.g. pitch=−17° instead of −20° for the left angle), the seed
        # places that frame at ~283° instead of 270°, giving the phase-correlation
        # refinement a more accurate starting point.
        # Top (roll axis) and front are kept at their nominal cylindrical values;
        # only left/right (pitch axis) are scaled.  Falls back to actual_angles
        # (nominal 0/90/180/270) when orbit data is unavailable.
        # Prefer payload-supplied orbit angles (eliminates a serial Firestore read)
        # and fall back to Firestore only when the Flutter client is older.
        if is_arc:
            # Already computed correctly (Firestore-ordered, roll-aware) by
            # _download_arc_frames above — nothing to redo here.
            angles_for_sfm = arc_sfm_angles
            orbit_angles   = {}
            logger.info('Arc-sweep angles: %s', [round(a, 1) for a in arc_sfm_angles])
        elif is_oscillating:
            # Already computed (binned, angle-sorted) by
            # _download_oscillating_frames above.
            angles_for_sfm = osc_angles
            orbit_angles   = {}
            logger.info('Oscillating angles: %s', [round(a, 1) for a in osc_angles])
        elif payload_orbit_angles:
            orbit_angles = {k: float(v) for k, v in payload_orbit_angles.items()}
            logger.info('Orbit angles from payload: %s', orbit_angles)
        else:
            orbit_angles = _extract_orbit_angles(capture_id)
        _nominal_cyl = {'front': 0.0, 'right': 90.0, 'top': 180.0, 'left': 270.0}

        # Guard: skip IMU seeding when all orbit values are near-zero (≤1°).
        # This happens when the Flutter app sends thumbAngleDegrees (MediaPipe thumb
        # tilt, typically ~0° when thumb is held still) instead of the device's
        # azimuthal orbit position.  Near-zero deltas clamp to scale=0.2 and
        # produce angles like [0°,18°,180°,342°] — a 162° gap that exceeds the
        # SFM 120° limit and silently triggers fallback_front_only.
        _orbit_all_near_zero = (
            orbit_angles
            and all(abs(float(v)) <= 1.0 for v in orbit_angles.values())
        )
        if _orbit_all_near_zero:
            logger.info(
                'Orbit sensor not calibrated (all values ≤1°) — using nominal angles'
            )
            orbit_angles = {}

        if is_arc or is_oscillating:
            # angles_for_sfm already final — set above by the respective
            # downloader. Skip the IMU/protocol-target seeding entirely;
            # falling through to the nominal-angle `else` branch below would
            # silently overwrite the already-correct oscillating/arc angles
            # with the unrelated four-angle protocol's 0/±32/-20 targets.
            pass
        elif is_front_only:
            # Single face-on frame — no SfM reconstruction, all angles 0°.
            angles_for_sfm = [0.0]
        elif orbit_angles:
            # Zero-point relative: subtract front orbit reading so any device-level
            # sensor offset cancels out.  Front is always φ=0 by definition; all
            # other angles are expressed as deltas from that reference.
            # The device orbiting the thumb by Δ degrees changes the viewing
            # azimuth by Δ degrees — use the measured orbit delta DIRECTLY as
            # the cylindrical angle. The previous mapping scaled Δ up to a
            # ±90° "nominal cylindrical target" (orbit 15° → 90°), a 3–6×
            # exaggeration that placed adjacent frames on non-overlapping
            # cylinder sectors; phase correlation then had nothing real to
            # correlate (observed as phaseCorrPairs=[None,None,None] on every
            # production capture with these seeds).
            front_orbit = float(orbit_angles.get('front', 0.0))
            angles_for_sfm = []
            for meta_entry in frame_meta:
                name  = meta_entry['angle']
                orbit = orbit_angles.get(name)
                if name == 'front':
                    angles_for_sfm.append(0.0)
                elif name == 'top':
                    # Roll-axis motion — no azimuthal displacement; contributes
                    # redundant coverage (SNR) around the front sector.
                    angles_for_sfm.append(0.0)
                elif orbit is not None:
                    delta = float(orbit) - front_orbit
                    # Clamp to a plausible physical orbit range.
                    angles_for_sfm.append(float(np.clip(delta, -75.0, 75.0)))
                else:
                    angles_for_sfm.append(_nominal_cyl.get(name, 0.0))
            logger.info(
                'IMU angles (direct orbit deltas, front_orbit=%.1f): %s',
                front_orbit,
                {m['angle']: round(a, 1) for m, a in zip(frame_meta, angles_for_sfm)},
            )
            # Sanity check: needs a real spread to stitch; degenerate orbit
            # data (all near-identical) → fall back to protocol targets.
            _imu_span = max(angles_for_sfm) - min(angles_for_sfm)
            if _imu_span < 15.0:
                logger.warning(
                    'IMU orbit data degenerate (span=%.1f° < 15°) — '
                    'falling back to protocol target angles', _imu_span,
                )
                _protocol_targets = _extract_target_angles(capture_id)
                angles_for_sfm = [
                    _protocol_targets.get(m['angle'], 0.0) for m in frame_meta
                ]
        else:
            # No usable IMU data. The old behaviour projected the four views at
            # nominal 0°/90°/180°/270° — but the capture protocol only orbits
            # the device ±32° (right/left targets) and −20° roll (top), so the
            # frames were being placed ~3× too far apart on the cylinder.
            # Consequences observed on every production capture: near-zero
            # genuine overlap between adjacent projections (phase correlation
            # returned None on all pairs), and the same thumb surface duplicated
            # into disjoint sectors. Place the frames at the protocol's actual
            # orbit targets read from the client's frame metadata
            # (targetAngleDegrees), falling back to the current protocol
            # constants. Left/right are azimuthal (pitch-axis); top is a roll
            # motion with no azimuthal displacement — it sits at 0° and
            # contributes redundant coverage (SNR) around the front sector.
            _protocol_targets = _extract_target_angles(capture_id)
            angles_for_sfm = []
            for meta_entry in frame_meta:
                name = meta_entry['angle']
                angles_for_sfm.append(_protocol_targets.get(name, 0.0))
            logger.info(
                'No IMU orbit data — using protocol target angles: %s',
                {m['angle']: round(a, 1) for m, a in zip(frame_meta, angles_for_sfm)},
            )

        # ── 2. Cylindrical superprint unwrap ──────────────────────────────────
        # Projects views onto a virtual cylinder.  Initial angles come from
        # IMU-seeded estimates (see above) or fall back to the nominal 90° step
        # convention.  Phase-correlation refinement in the SfM pipeline further
        # adjusts each angle based on ridge signal alignment across adjacent frames.
        # When 3 frames are present (top/180° missing), allows a 185° gap so
        # front+right+left together still produce a valid superprint.
        # Falls back to front-frame-only on segmentation failure (coverage < 20%).
        logger.info('stage=sfm_start      elapsed=%.1fs', time.monotonic() - t_start)
        n_frames = len(frames)
        # Internal-gap semantics (wrap-around gap no longer counted — see
        # reconstruct_and_unwrap): the default 120° limit works for every
        # mode, including 3-frame captures missing the top view.
        gap_limit = None
        sfm_coverage    = 0.0
        sfm_diagnostics: dict = {}
        fallback_mask   = None
        if is_front_only:
            # Single face-on frame — skip SfM reconstruction entirely.
            # Prepare the best frame the same way the fallback path would:
            # centre-square, greyscale, ready for enhancement + AFIS.
            front_sq = sfm_pipeline._prepare(frames[0])
            unwrapped = cv2.cvtColor(front_sq, cv2.COLOR_BGR2GRAY)
            sfm_refined_angles = [0.0]
            sfm_coverage = 0.35  # non-zero so downstream quality gates pass
            _update_firestore(capture_id, {
                'sfmStatus': 'skipped_front_only',
                'sfmCoverage': sfm_coverage,
                'sfmRefinedAngles': [0.0],
            })
        try:
            if is_front_only:
                raise CaptureQualityError('front_only_v1: single-frame AFIS only, no SfM')
            sfm_cfg = {'out_theta_deg': osc_theta_deg} if osc_theta_deg is not None else None
            unwrapped, sfm_coverage, sfm_refined_angles, sfm_diagnostics, sfm_valid_mask = (
                sfm_pipeline.reconstruct_and_unwrap(
                    frames, angles_deg=angles_for_sfm, max_angle_gap_deg=gap_limit,
                    thumb_width_fraction=thumb_width_fraction,
                    ambient_frames=ambient_frames, flash_frames=flash_frames,
                    frame_weights=arc_frame_wts,
                    sfm_config=sfm_cfg,
                )
            )
            # Same gap-fill periphery this project already found causes ridge-
            # filter ringing when fed to enhancement unmasked (see the
            # single-frame fallback's own fallback_mask below) — a successful
            # multi-frame reconstruction has exactly the same defect and never
            # got the same treatment until now. Reuse fallback_mask as the
            # carrier so the one compositing block below covers both paths.
            fallback_mask = (sfm_valid_mask.astype(np.uint8) * 255) if not sfm_valid_mask.all() else None
            if is_oscillating:
                sfm_status = 'success_oscillating'
            elif is_arc:
                sfm_status = 'success_arc'
            elif n_frames == 4:
                sfm_status = 'success'
            else:
                sfm_status = 'success_3view'
            sfm_fields = {
                'sfmStatus':        sfm_status,
                'sfmCoverage':      float(round(sfm_coverage, 3)),
                'sfmRefinedAngles': [float(round(a, 2)) for a in sfm_refined_angles],
                'sfmOrbitSeeds':    {m['angle']: float(round(a, 1))
                                     for m, a in zip(frame_meta, angles_for_sfm)}
                                    if (not is_arc and orbit_angles) else None,
            }
            if not is_arc and n_frames == 3:
                sfm_fields['sfmMissingAngle'] = 'top'
            _update_firestore(capture_id, sfm_fields)
        except CaptureQualityError as e:
            if is_front_only:
                # SfM was intentionally skipped; frame already prepared before
                # the try block. Nothing to do — sfm_coverage, unwrapped, and
                # sfm_refined_angles are all already set.
                pass
            else:
                logger.warning(f"Cylindrical projection failed — falling back to front frame: {e}")
                try:
                    # Pick the fallback frame deliberately. frames[0] is only the
                    # front view in four-angle mode; arc AND oscillating frames
                    # are both sorted by angle, so [0] is the extreme-left view —
                    # the worst possible single-frame print. Use the sharpest
                    # frame nearest mid-sweep.
                    if (is_arc or is_oscillating) and len(frames) > 1:
                        def _fb_key(i):
                            meta = frame_meta[i] if i < len(frame_meta) else {}
                            lap  = float(meta.get('laplacianScore') or 0.0)
                            ang  = abs(float(angles_for_sfm[i])) if i < len(angles_for_sfm) else 90.0
                            return (0 if ang <= 30.0 else 1, -lap)
                        fb_idx = min(range(len(frames)), key=_fb_key)
                    else:
                        fb_idx = 0
                    front_sq = sfm_pipeline._prepare(frames[fb_idx])
                    unwrapped = cv2.cvtColor(front_sq, cv2.COLOR_BGR2GRAY)
                    # The SfM path excludes background via the segmentation mask
                    # baked into the cylindrical warp; this single-frame fallback
                    # skipped that entirely and fed the *whole* photo (thumb +
                    # room background) into enhancement. Segment here too, but
                    # DON'T blank the background yet — masking before Gabor/NNS
                    # enhancement creates a hard edge between real content and a
                    # flat fill, and the ridge filters ring on that edge, painting
                    # concentric wave artefacts across the print. Instead keep
                    # `unwrapped` untouched, remember the mask, and composite it
                    # in afterwards once `enhanced` exists (see below).
                    fb_out_size       = unwrapped.shape[0]
                    _, _, fb_ksize    = sfm_pipeline._scale_params(fb_out_size)
                    fb_cx = fb_cy     = fb_out_size / 2.0
                    fb_mask, _, _, _  = sfm_pipeline._segment_and_locate(
                        unwrapped, fb_ksize, fb_cx, fb_cy,
                    )
                    fallback_mask = fb_mask
                    sfm_coverage  = float(np.mean(fb_mask > 0)) if fb_mask is not None else 0.0
                except Exception as frame_err:
                    _update_firestore(capture_id, {
                        'status':         'failed',
                        'sfmStatus':      'fallback_failed',
                        'failureReason':  f'SfM + front-frame fallback both failed: {str(frame_err)[:200]}',
                    }, critical=False)
                    raise https_fn.HttpsError(
                        code=https_fn.FunctionsErrorCode.INTERNAL,
                        message='Capture data corrupted — please retake.',
                    ) from frame_err
                _update_firestore(capture_id, {
                    'sfmStatus':  'fallback_front_only',
                    'sfmError':   str(e)[:200],
                    'needsRecapture': True,
                })
        t_sfm = time.monotonic()
        logger.info('stage=sfm_done       elapsed=%.1fs', t_sfm - t_start)

        # Signal low-coverage captures so Flutter can prompt a recapture.
        recapture_threshold = (
            0.45 if is_arc else
            0.35 if is_oscillating else
            (0.40 if n_frames == 4 else 0.28)
        )
        if 0.0 < sfm_coverage < recapture_threshold:
            _update_firestore(capture_id, {'needsRecapture': True, 'sfmCoverage': round(sfm_coverage, 3)})

        # ── 3. NNS Enhancement ─────────────────────────────────────────────────
        logger.info('stage=nns_start      elapsed=%.1fs', time.monotonic() - t_start)
        # Bilateral pre-denoise: removes stitching seam artefacts before UNet.
        unwrapped_d = cv2.bilateralFilter(unwrapped, d=5, sigmaColor=20, sigmaSpace=20)
        enhanced, enhancement_params = enhancement_pipeline.enhance(unwrapped_d, sfm_coverage=sfm_coverage)
        if fallback_mask is not None and 0.0 < sfm_coverage < 1.0:
            # Composite the background/gap-filled periphery out now that ridge
            # filtering is done, with a feathered edge (not a hard cut) so no
            # new ringing gets introduced at this stage either. Covers BOTH the
            # single-frame fallback's own segmentation mask and a successful
            # multi-frame SfM reconstruction's gap-fill mask (sfm_valid_mask,
            # set above) — the same class of defect, same fix, two sources.
            mask_rs = cv2.resize(fallback_mask, (enhanced.shape[1], enhanced.shape[0]),
                                  interpolation=cv2.INTER_NEAREST)
            mask_f  = cv2.GaussianBlur(mask_rs, (31, 31), 0).astype(np.float32) / 255.0
            bg      = np.full_like(enhanced, 245)
            enhanced = (enhanced.astype(np.float32) * mask_f
                        + bg.astype(np.float32) * (1.0 - mask_f)).astype(np.uint8)
        t_nns = time.monotonic()
        logger.info('stage=nns_done       elapsed=%.1fs', t_nns - t_start)

        # ── 4. NFIQ Scoring ────────────────────────────────────────────────────
        logger.info('stage=nfiq_start     elapsed=%.1fs', time.monotonic() - t_start)
        # Real bug found 2026-07-24: _score_nfiq's coverage-aware crop exists to
        # strip gap-filled KDTree periphery noise from a real SfM reconstruction
        # before scoring -- but front_only_v1 never runs reconstruct_and_unwrap
        # at all (single-frame AFIS only, no SfM; see the is_front_only branch
        # above), so `enhanced` here is just a plain center-crop of the raw
        # frame with no gap-filled periphery to strip. front_only_v1's own
        # sfm_coverage is a HARDCODED SENTINEL (0.35, "non-zero so downstream
        # quality gates pass" -- never a real coverage measurement), which
        # always falls below the crop function's 0.75 floor -- so the crop
        # fired unconditionally on every single front_only_v1 capture, cropping
        # ~44% of area off the SAVED enhanced_flat.jpg deliverable and the
        # Henry-classification input for a reason that never applied to this
        # capture mode. Pass the real sfm_coverage only for modes that actually
        # ran SfM reconstruction (arc/oscillating/four-angle); front_only_v1
        # scores/saves the full frame, matching how every AFIS-path _score_nfiq
        # call already passes sfm_coverage=1.0.
        nfiq_result = _score_nfiq(enhanced, sfm_coverage=(1.0 if is_front_only else sfm_coverage))
        t_nfiq = time.monotonic()
        logger.info('stage=nfiq_done      elapsed=%.1fs', t_nfiq - t_start)
        if nfiq_result.get('error'):
            _fail(capture_id, f"NFIQ error: {nfiq_result['error']}")
            return {'nfiqScore': 0, 'nfiqPass': False, 'henryClass': 'U'}

        cyl_nfiq    = nfiq_result['nfiq_score']
        best_enhanced = nfiq_result.get('best_image', enhanced)

        # ── 4b. Save enhanced flat print ──────────────────────────────────────
        # Scoring/classification below run on `best_enhanced` unmodified; the
        # ink/livescan contrast curve is cosmetic and only applied to the copy
        # that gets saved and shown to the user.
        display_image = enhancement_pipeline.ink_scanner_style(best_enhanced)
        enhanced_path = _save_enhanced_flat(display_image, user_id, capture_id)

        # ── 4c. AFIS-style binary superprint (the primary deliverable) ─────────
        # The cylindrical unwrap is a photographic grayscale of a stretched arc;
        # the AFIS path (afis_print.py) Gabor-enhances and binarises the
        # sharpest face-on frame into the classic rolled-print look. Measured
        # across real captures it scores 14–24 NFIQ points HIGHER than the
        # unwrap, so it — not the unwrap — is the print we report and save. We
        # score two renderings (native + ridge-frequency-normalised to the
        # ~500 DPI NFIQ domain) and keep whichever the model rates higher; the
        # official nfiqScore is the best across {unwrap, afis-native, afis-freq}.
        # Additive and non-blocking: any failure just falls back to the unwrap.
        afis_path = None
        afis_params: dict = {}
        afis_nfiq = 0.0
        best_afis_img = None
        freqnorm_img = None
        # Defined here (not just inside the try below) so the Firestore
        # write further down always finds it, even if an exception in the
        # AFIS variant loop happens before this runs -- same defensive
        # pattern this should have applied to _secondary_cam_scores too,
        # but that one predates this change.
        _sweep_burst_debug: dict = {}
        _minutiae_patch_debug: dict = {}
        try:
            _laps = [
                (m.get('laplacianScore') if isinstance(m, dict) else None)
                for m in frame_meta
            ]
            # Guided capture: the user seated the pad in the on-screen
            # silhouette, so the app wrote its region to the capture doc. The
            # backend uses that region AS the (feathered) crop mask -- no
            # free-range segmentation, no fragile ridge-periodicity crop. The
            # region is already in the center-square-cropped frame's normalized
            # coords (the space generate() receives), so it passes straight
            # through. Absent (legacy captures) -> None -> segmentation path.
            _guide_db, _ = _get_firebase()
            _guide_doc = _guide_db.collection('captures').document(capture_id).get().to_dict() or {}
            _guide_region = _guide_doc.get('guideRegion') or None
            # Score each rendering variant and keep the single best NFIQ. Every
            # variant is ADDITIVE — same-pose stacking and ridge-freq
            # normalisation each help some captures and hurt others, so they are
            # scored side-by-side rather than applied unconditionally. Taking the
            # max guarantees a variant can only raise the final score, never
            # regress a good capture.
            # Rendering variants (name, generate-kwargs). The max NFIQ across all
            # of them is kept, so each variant can only ever raise the score:
            #   native    — sharpest single face-on frame
            #   freqNorm  — resample ridge period to the ~500 DPI domain
            #   stack     — same-pose burst denoise (align+average)
            #   fuseAvg   — fuse same-pose flash+ambient exposures (biggest
            #               lever, +12 NFIQ on a well-paired capture)
            #   mosaicFreq— front-anchored minimal-yaw reconstruction: borrow
            #               pad-edge ridges from lightly-yawed neighbours without
            #               distorting the front centre (+~1.5 on some captures)
            # fuse/mosaic self-skip (return None) when the flow lacks the inputs
            # (arc, or no ambient/flash pair / no side frame), costing nothing.
            #   deepFuse  — deep-stack the whole preserved front burst per
            #               illumination then fuse, freq-normalised (+2.5 on the
            #               burst-rich indoor capture; self-skips when the raw
            #               burst wasn't preserved, e.g. non-osc flows).
            #   focusStack— same-pose burst combined by LOCAL sharpness (keep
            #               the best-focused region of each shot) rather than a
            #               flat mean: targets the pad's curved edges going soft
            #               under shallow macro depth-of-field. Self-skips (falls
            #               back to single frame) when <2 same-pose frames align.
            # freq_scale_min=0.9 (2026-08-07) -- shared by every freq_normalize
            # variant below. Real finding, same session as pyfingHybridFreqNorm:
            # mindtct's own per-minutia quality metric sits at 68-82 on ANY
            # freq_normalize output vs 19.7-40.9 across 20 real baseline
            # captures' native variant -- freq_normalize's resample (not
            # pyfing) is what drives the over-regularization, and it was
            # NEVER gated because production selection has only ever used
            # NFIQ2/proxy, which can't see this. Confirmed via SourceAFIS on
            # freqNorm's own real worst-case impostor pair (fcfa2e93 x
            # 2bd4986a, visually confirmed different users): unguarded
            # (scale floor 0.7) scored 76.39, nearly 2x SourceAFIS's ~40
            # recommended threshold. Same 22-capture/15-pair gate used all
            # session: floor=0.9 cuts that pair to 9.61 (floor=1.0 cuts it
            # further but that value clamps the resample to a no-op for
            # this population's real wavelength range, killing essentially
            # all of freqNorm's separation gain too -- 0.9 is the real
            # middle ground, not 1.0). Aggregate cost is real but modest:
            # separation 29.17->24.28, while genuine-beats-impostor-max rate
            # actually IMPROVES (2/15->3/15). See the matching margin guard
            # below, same discipline as pyfingHybridFreqNorm's.
            _afis_variants = (
                ('native',     dict()),
                ('freqNorm',   dict(freq_normalize=True, freq_scale_min=0.9)),
                ('stack',      dict(stack=True)),
                ('focusStack', dict(focus_stack=True)),
                ('fuseAvg',    dict(fuse='avg')),
                # Coherence-based flash+ambient fusion: per-region takes whichever
                # exposure resolves ridges best, recovering the specular-blown
                # flash centre the flat 'avg' washes out (CTO flash-smudge
                # feedback). The modes already existed in _fuse_flash_ambient but
                # were never wired as production variants. Confirmed to beat 'avg'
                # on real captures (3e54236a maxc: real NFIQ2 57->81, bozorth
                # 4->6). Max-of-variants, so purely additive.
                ('fuseMaxc',   dict(fuse='maxc')),
                ('fuseSoft',   dict(fuse='soft')),
                ('mosaicFreq', dict(mosaic=True, freq_normalize=True, freq_scale_min=0.9)),
                ('deepFuse',   dict(fuse='deep', freq_normalize=True, freq_scale_min=0.9)),
                ('deepMaxc',   dict(fuse='deepMaxc', freq_normalize=True, freq_scale_min=0.9)),
                # pyfing (SNFEN, pretrained neural enhancement) as an
                # alternative to the classical Gabor bank -- self-skips
                # (falls back to Gabor) if the pyfing_service sidecar isn't
                # configured/reachable. Max-of-variants: can only add a
                # candidate, never replace the Gabor path's own coverage.
                # Measured across all 14 real captures: never won (see
                # CLAUDE.md) -- likely because pyfing's own continuous-
                # tone, ridges-bright convention doesn't survive a plain
                # invert the way this pipeline's own Gabor+hard-binarize
                # step (tuned against these exact captures) does.
                ('pyfingSnfen', dict(enhance='pyfing')),
                # Hybrid: pyfing as a denoise pre-pass (its actual trained
                # job -- clean up ridge continuity from a noisy photo),
                # then this module's own tuned Gabor bank + binarization
                # does the final black-ridge/white-background conversion,
                # instead of a raw intensity invert of pyfing's output.
                ('pyfingHybrid', dict(enhance='pyfingHybrid')),
                # pyfingHybrid + freq_normalize -- 2026-08-07. pyfingHybrid
                # was NEVER called with freq_normalize=True in production:
                # pyfing was always denoising at native (often too-close,
                # too-coarse) resolution before this module's own Gabor bank
                # got a chance to run at its tuned ~9px sweet spot. Checked
                # the scale math doesn't double-resample (_pyfing_denoise's
                # own internal 500dpi rescale is undone before it returns,
                # so freq_normalize's resample is the only one that survives
                # into the Gabor stage) before trying this combination.
                #
                # Real result, 22-capture / 15-genuine-pair SourceAFIS gate
                # (scratchpad, not committed): genuine mean 57.49 vs ~30-40
                # for every other candidate tried the same night -- the best
                # raw separation found all session. But ALSO the worst
                # impostor false-match spike found all session: 150.58,
                # nearly 4x SourceAFIS's own documented ~40 "recommended
                # threshold" -- and NOT a fluke. Pulled the actual pair
                # (two different real users) and visually confirmed both
                # prints share a suspiciously generic, boundary-driven ridge
                # flow near the core, consistent with this project's already
                # -documented `gaborPyfingField` failure mode: a neural
                # front-end can win on visual/NFIQ2 quality by synthesizing
                # plausible-but-generic structure instead of preserving
                # person-specific minutiae. Gated below, same discipline as
                # the fusion-selection sharpness guard.
                #
                # Followed up same day with two real levers, both measured
                # against the identical 22-capture/15-pair gate (scratchpad):
                # (1) pyfing_blend (alpha-blend pyfing's output back toward
                # the pre-denoise image) tested alone -- 0.3/0.5/0.7, all
                # NET NEGATIVE: separation dropped (28-35 vs 39.33) AND the
                # risky pair's false-match score barely moved (120-142 vs
                # 150.58 baseline). Diluting pyfing's own output does not
                # fix this. (2) freq_scale_min=0.9 (this variant's own
                # per-call override, NOT the shared _FREQ_SCALE_MIN=0.7 used
                # by freqNorm/deepFuse/deepMaxc/mosaicFreq -- those stay
                # untouched) tested alone and combined with blend: 0.9 alone
                # roughly HALVED the risky pair's score (150.58 -> 11.82) for
                # a small separation cost. Combined with pyfing_blend=0.7,
                # separation came back to essentially the unguarded baseline
                # (39.02 vs 39.33) while KEEPING most of 0.9's risk reduction
                # (76.11 vs 150.58) and posting the best genuine-beats-
                # impostor-max rate of any variant tried all session (5/15,
                # vs 2/15 for the raw pyfing_blend=1.0/freq_scale_min=0.7
                # config). Shipped as the real config below; the two-lever
                # combination is real, not additive luck -- freq_scale_min
                # does the risk reduction, pyfing_blend recovers the
                # separation freq_scale_min alone gives up.
                ('pyfingHybridFreqNorm', dict(enhance='pyfingHybrid', freq_normalize=True,
                                              pyfing_blend=0.7, freq_scale_min=0.9)),
                # Coherence-enhancing diffusion (oriented smoothing along
                # ridge direction, classical, no sidecar dependency) as a
                # denoise pre-pass ahead of the same Gabor+binarize chain --
                # see docs/CAPTURE_OPTIMIZATION_SCOPE.md-adjacent scope work
                # on ridge continuity, 2026-07-16.
                ('coherenceDiff', dict(enhance='coherenceDiff')),
                # NNS (this project's OTHER, older enhancement model --
                # enhancement_pipeline.enhance(), CLAHE+Gabor+trained
                # FingerprintUNet) as a denoise pre-pass ahead of the same
                # Gabor+binarize chain -- CTO ask, 2026-07-16: combine NNS's
                # ridge smoothness/continuity with the AFIS template's NFIQ2
                # quality.
                ('nnsHybrid', dict(enhance='nnsHybrid')),
            )
            # Wall-clock budget on the whole variant loop -- found 2026-07-16
            # (real device capture 9efb7d1e): the deepFuse/deepMaxc/deepSoft
            # family each independently redo the expensive ambient/flash
            # burst ECC alignment (_stack_face_on) from scratch, and on a
            # capture with poorly-correlated flash frames this took 15+
            # minutes for a SINGLE variant, blowing through the Cloud Run
            # service's 2-minute request timeout and leaving the capture
            # stuck at status=enhancing forever. _stack_face_on is now
            # cached across the fuse family (see afis_print.py), but this
            # budget is kept as a second, independent safety net against
            # ANY future slow variant: once exceeded, stop trying further
            # NOT-yet-attempted variants and score with whatever's already
            # been produced -- identical to a variant self-skipping, so
            # this can never make the result worse, only bound the worst
            # case latency.
            _variants_deadline = time.monotonic() + 70.0
            _stack_cache: dict = {}   # request-scoped; see afis_print.generate's docstring

            # Fusion-selection sharpness guard (2026-07-23): capture 913758cf
            # (nfiq2Score 32) had a plain ambient frame at Laplacian 790.4 --
            # the sharpest of 15 real captures audited -- while its flash
            # frames scored only ~81-86 (the established "torch blows out an
            # already-decently-lit pad" pattern), yet the variant loop picked
            # a flash+ambient fusion anyway: the internal proxy this loop
            # selects by badly overestimated it (65.37 predicted vs 32 real).
            # Selection here is driven ENTIRELY by the proxy, never real
            # frame sharpness or real NFIQ2 (too slow/costly to call per
            # variant) -- when the raw inputs say a fusion variant is likely
            # diluting a much better ambient frame with a much worse flash
            # one, require it to beat the plain single-frame 'native'
            # variant by a real margin instead of just edging it out on a
            # proxy score already known to be foolable. Offline validation
            # against 17 real captures (scratchpad/harness.py-style sweep,
            # not committed): changed selection on 2/17 (one -1, one +21 real
            # NFIQ2) and was inert on the rest -- net positive, mostly a
            # no-op, never observed to regress a capture that didn't trigger
            # it. Purely a guard on an existing max-of-variants loop, so it
            # can only ever withhold a variant from winning, never invent a
            # worse result than what would otherwise have been produced by
            # variants earlier in _afis_variants (native/freqNorm/stack/...).
            _FUSION_VARIANT_NAMES = {'fuseAvg', 'fuseMaxc', 'fuseSoft', 'deepFuse', 'deepMaxc'}
            _SHARPNESS_RATIO_GUARD = 4.0
            _FUSION_MARGIN_REQUIRED = 3.0

            # pyfingHybridFreqNorm guard (2026-08-07) -- see the variant's own
            # comment above for the real SourceAFIS evidence. UNLIKE the fusion
            # guard above, this is not conditional on a raw-signal trigger --
            # there is no cheap per-request signal available that predicts the
            # over-regularization failure mode found (it showed up on a normal-
            # looking capture, not an unusually soft/blown-out one), so the
            # margin applies every time this variant is even considered. Higher
            # than the fusion guard's 3.0 given the worse real evidence: a
            # near-4x-recommended-threshold false-match spike, not just a
            # proxy-overestimate. Kept at 5.0 even after the freq_scale_min
            # =0.9/pyfing_blend=0.7 tune below roughly halved the measured
            # risk (150.58 -> 76.11 on the pair that motivated this) --
            # 76.11 is still well above SourceAFIS's own ~40 recommended
            # threshold, so the risk is reduced, not eliminated; the margin
            # stays the real backstop. Same guarantee as every other guard
            # in this loop: can only withhold a variant from winning, never
            # invent a worse result than the best already found.
            # nnsHybrid joins this guard 2026-08-07. Its _nns_denoise input
            # bug was fixed the same day (pre-mask ringing + the 512-resize
            # scale collapse), which took it from rarely-functional to a real
            # contender: mean real NFIQ2 on 5 real captures went ~broken ->
            # 51.0 -> 57.8, high enough to actually WIN selection now. But
            # every NNS-based variant measured against the real SourceAFIS
            # gate this session came in BELOW the pyfingHybridFreqNorm
            # baseline on separation (NNS+Gabor at 1.3x crop: 28.28, at 1.6x:
            # 20.57, vs baseline 39.02) while matching or beating it on
            # NFIQ2 -- the exact "high NFIQ2 hides worse matchability"
            # pattern that showed up five separate times this session. The
            # specific nnsHybrid config has NOT itself been SourceAFIS-gated
            # yet, so this margin is PRECAUTIONARY, not measured: it stops a
            # newly-strong-on-NFIQ2 neural variant from quietly displacing a
            # more matchable one before that measurement exists. Revisit
            # (and drop the margin if warranted) once nnsHybrid has its own
            # real genuine/impostor numbers.
            _NEURAL_GUARDED_VARIANT_NAMES = {'pyfingHybridFreqNorm', 'nnsHybrid'}
            _PYFING_HYBRID_MARGIN_REQUIRED = 5.0

            # freqNorm-family risk guard (2026-08-07) -- see this variant
            # group's own comment in _afis_variants above for the real
            # evidence. Same unconditional-margin pattern as the pyfing
            # guard above (no cheap per-request signal predicts this
            # failure mode either), lower margin than pyfing's 5.0: this
            # family's own real risk reduction from the freq_scale_min
            # tune (64.30 -> 56.05 on freqNorm's worst pair) was smaller
            # than pyfing's (150.58 -> 76.11), and these are established,
            # frequently-winning production variants (unlike the brand-new
            # pyfingHybridFreqNorm) -- a large margin would suppress them
            # on a meaningful fraction of otherwise-good real captures.
            # 3.0 matches the existing fusion-sharpness guard's own margin.
            _FREQNORM_RISK_VARIANT_NAMES = {'freqNorm', 'mosaicFreq', 'deepFuse', 'deepMaxc'}
            _FREQNORM_RISK_MARGIN_REQUIRED = 3.0
            try:
                # front_only_v1 can supply [None] (no ambient/flash frame was
                # uploaded) -- a one-element list is still truthy, so `if
                # ambient_frames` alone doesn't catch it; check the actual
                # first element too.
                _amb_lap = (float(cv2.Laplacian(ambient_frames[0], cv2.CV_64F).var())
                            if ambient_frames and ambient_frames[0] is not None else 0.0)
                _fl_lap = (float(cv2.Laplacian(flash_frames[0], cv2.CV_64F).var())
                           if flash_frames and flash_frames[0] is not None else 0.0)
            except Exception:   # noqa: BLE001 — guard is best-effort, never blocks scoring
                _amb_lap = _fl_lap = 0.0
            _fusion_guarded = _fl_lap > 0 and (_amb_lap / _fl_lap) >= _SHARPNESS_RATIO_GUARD
            _native_nfiq = None

            # fuseAvg/fuseMaxc/fuseSoft each pair a single flash_frames[0] with
            # ambient_frames[0]. Now that the EV bracket gives 4 distinct flash
            # exposures in flash_burst, multi-pair fuse tries each frame as the
            # partner and keeps the one with the best proxy score. deep* variants
            # already consume flash_burst for internal stacking, so they don't
            # need this inner sweep.
            _FUSE_PAIR_NAMES = {'fuseAvg', 'fuseMaxc', 'fuseSoft'}
            # Hard per-pair cap, real bug found 2026-08-08 (see
            # _call_with_hard_deadline's docstring): the ORIGINAL 2026-07-16
            # deepFuse/deepMaxc outage was 15+ minutes for one variant on a
            # poorly-correlated burst; this project's real logs show that
            # exact failure mode recurring through a different code path
            # (a single fuseAvg flash-bracket pair blocking ~144s). 40s is
            # generous against every real per-pair time this session's own
            # logs have shown for a WORKING alignment (single-digit to
            # low-double-digit seconds), while still bounding the true
            # pathological case far below the request's own harder 300s
            # Cloud Run ceiling.
            _FUSE_PAIR_HARD_TIMEOUT_SEC = 40.0

            for _vname, _vkw in _afis_variants:
                if time.monotonic() > _variants_deadline:
                    logger.warning('AFIS variant loop: time budget exceeded, '
                                    'skipping remaining variants from %s onward', _vname)
                    break
                # flash_burst is None for arc_sweep and the discontinued
                # four-angle flow (only front_only_v1/oscillating_8phase ever
                # populate it -- see the download-stage branches above), so
                # this must short-circuit before len() rather than assume a
                # list. Without the `flash_burst and` guard this raised
                # TypeError on 'fuseAvg' for those capture modes, aborting the
                # entire AFIS variant loop (everything from fuseAvg onward,
                # plus secondary-camera scoring and _save_afis_print, silently
                # never ran) -- caught only by the outer non-critical except,
                # so nfiqAfis/nfiqSource could be reported with no
                # corresponding superprintPath ever written.
                _fuse_fl_list = (
                    [[f] for f in flash_burst]
                    if _vname in _FUSE_PAIR_NAMES and flash_burst and len(flash_burst) > 1
                    else [flash_frames]
                )
                _img, _p, _s = None, None, 0.0
                for _fl_frames in _fuse_fl_list:
                    if time.monotonic() > _variants_deadline:
                        break
                    # Hard per-pair deadline (2026-08-08) -- see
                    # _call_with_hard_deadline's own docstring for the real
                    # live stuck-capture this closes. A fixed, absolute cap,
                    # not "whatever's left of _variants_deadline": that
                    # relative budget can still legitimately be the better
                    # part of 70s for an early pair, which is exactly how
                    # one poorly-correlated pair blocked the request for
                    # ~144s despite the existing between-pairs check.
                    _pair_result = _call_with_hard_deadline(
                        afis_print.generate,
                        frames, angles_for_sfm, _laps,
                        ambient_frames=ambient_frames, flash_frames=_fl_frames,
                        ambient_burst=ambient_burst, flash_burst=flash_burst,
                        ambient_burst_gyros=ambient_burst_gyros,
                        flash_burst_gyros=flash_burst_gyros,
                        guide_region=_guide_region,
                        stack_cache=_stack_cache,
                        timeout_sec=_FUSE_PAIR_HARD_TIMEOUT_SEC,
                        **_vkw)
                    if _pair_result is None:
                        continue
                    _ci, _cp = _pair_result
                    if _ci is None:
                        continue
                    _cr = _score_nfiq(_ci, sfm_coverage=1.0)
                    _cs = _cr.get('nfiq_score', 0.0) if not _cr.get('error') else 0.0
                    if _cs > _s:
                        _img, _p, _s = _ci, _cp, _cs
                if _img is None:
                    continue
                if _vname == 'freqNorm':
                    freqnorm_img = _img
                if len(_fuse_fl_list) > 1:
                    logger.info('AFIS variant %s nfiq=%.1f (best of %d flash pair candidates)',
                                _vname, _s, len(_fuse_fl_list))
                else:
                    logger.info('AFIS variant %s nfiq=%.1f', _vname, _s)
                if _vname == 'native':
                    _native_nfiq = _s
                if (_fusion_guarded and _vname in _FUSION_VARIANT_NAMES
                        and _native_nfiq is not None
                        and _s < _native_nfiq + _FUSION_MARGIN_REQUIRED):
                    logger.info(
                        'AFIS variant %s suppressed by sharpness guard '
                        '(amb/fl lap ratio %.1fx, needed >= native(%.1f)+%.1f, got %.1f)',
                        _vname, (_amb_lap / _fl_lap) if _fl_lap else 0.0,
                        _native_nfiq, _FUSION_MARGIN_REQUIRED, _s)
                    continue
                if (_vname in _NEURAL_GUARDED_VARIANT_NAMES and _native_nfiq is not None
                        and _s < _native_nfiq + _PYFING_HYBRID_MARGIN_REQUIRED):
                    logger.info(
                        'AFIS variant %s suppressed by neural-enhancer false-match guard '
                        '(needed >= native(%.1f)+%.1f, got %.1f)',
                        _vname, _native_nfiq, _PYFING_HYBRID_MARGIN_REQUIRED, _s)
                    continue
                if (_vname in _FREQNORM_RISK_VARIANT_NAMES and _native_nfiq is not None
                        and _s < _native_nfiq + _FREQNORM_RISK_MARGIN_REQUIRED):
                    logger.info(
                        'AFIS variant %s suppressed by freqNorm false-match guard '
                        '(needed >= native(%.1f)+%.1f, got %.1f)',
                        _vname, _native_nfiq, _FREQNORM_RISK_MARGIN_REQUIRED, _s)
                    continue
                if _s > afis_nfiq:
                    afis_nfiq = _s
                    best_afis_img = _img
                    afis_params = {**_p, 'afisNfiq': round(_s, 2)}

            # Secondary-camera candidates: independent single-frame renderings
            # from any OTHER back camera the device captured alongside the main
            # sweep (see OscillatingCaptureController's best-effort secondary
            # capture -- e.g. this Doogee S118's IR/night-vision sensor,
            # validated at +3 NFIQ over the main camera on a real capture).
            # Each is scored as its own single-frame candidate, same pattern as
            # the 'native' variant above, and only replaces best_afis_img if it
            # scores higher -- purely additive, same max-variant guarantee.
            # Reuse the capture doc already fetched above for guideRegion.
            # Secondary cameras: score each burst's sharpest frame as its own
            # single-frame candidate, same max-variant pattern as above.
            # Derive a focal-ratio-scaled guide region when cameraLensInfo is
            # available: secondary sensors have wider or narrower FOV than the
            # main camera, so the fingerprint appears proportionally smaller or
            # larger in their frame. Scaling the main guide's rx/ry by
            # (secondary_fl / main_fl) extracts the equivalent physical pad
            # region from the secondary frame. cx/cy default to 0.5/0.5 since
            # the main camera's BoxFit.cover-corrected cx is specific to that
            # sensor's framing and doesn't transfer to other lenses.
            _cap_doc = _guide_doc
            _lens_info = _cap_doc.get('cameraLensInfo') or {}
            _fl_main = (_lens_info.get('0') or {}).get('focalLengthMm')
            _secondary_cam_scores = {}
            for _cam in _cap_doc.get('secondaryCameras', []) or []:
                # 'paths' (a short per-camera burst, ranked by Laplacian
                # variance below) is the current schema; 'path' (a single
                # shot) is kept for backward compatibility with captures
                # already in flight when this changed.
                _spaths = _cam.get('paths') or ([_cam['path']] if _cam.get('path') else [])
                if not _spaths:
                    continue
                try:
                    if len(_spaths) > 1:
                        # Download all burst frames in parallel so stack/
                        # focusStack variants have multiple same-pose images
                        # to align — the same fix applied to the main-camera
                        # path in round 11, now extended to secondary cameras.
                        def _fetch_sec_frame(p):
                            b = _download_storage_file(p)
                            a = _decode_image(b)
                            s = float(cv2.Laplacian(
                                cv2.cvtColor(a, cv2.COLOR_BGR2GRAY),
                                cv2.CV_64F).var())
                            return p, a, s
                        _sframes = []
                        with ThreadPoolExecutor(
                                max_workers=min(len(_spaths), 6)) as _sex:
                            _sfuts = {_sex.submit(_fetch_sec_frame, p): p
                                      for p in _spaths}
                            for _sfut in as_completed(_sfuts):
                                try:
                                    _sframes.append(_sfut.result())
                                except Exception as _sfe:
                                    logger.warning(
                                        'secondary frame download failed: %s',
                                        _sfe)
                        if not _sframes:
                            continue
                        _sframes.sort(key=lambda x: x[2], reverse=True)
                        _spath = _sframes[0][0]
                        _simg = _sframes[0][1]
                        _all_simgs = [f[1] for f in _sframes]
                        _all_gyros = [0.0] * len(_all_simgs)
                        _all_illums = [None] * len(_all_simgs)
                    else:
                        _spath = _spaths[0]
                        _sbytes = _download_storage_file(_spath)
                        _simg = _decode_image(_sbytes)
                        _all_simgs = [_simg]
                        _all_gyros = [0.0]
                        _all_illums = [None]
                    # Laplacian of the best frame — already computed for multi-
                    # path bursts; compute on demand for single-path captures.
                    _best_lap = (
                        _sframes[0][2] if len(_spaths) > 1
                        else float(cv2.Laplacian(
                            cv2.cvtColor(_simg, cv2.COLOR_BGR2GRAY),
                            cv2.CV_64F).var())
                    )
                    _sname = f"secondary_{_cam.get('name', 'cam')}"
                    # Sensor-corrected FOV-scaled guide: gives generate() the
                    # right extraction region for this lens's FOV. Falls back
                    # to None (UNet/flash-diff segmentation path) if any input
                    # is missing -- purely additive, never blocks.
                    #
                    # Real bug found + fixed 2026-07-29: this used to scale by
                    # focal-length ratio alone (fl_sec/fl_main). Angular FOV --
                    # and thus how large a fixed physical object appears in a
                    # lens's own normalized frame -- depends on BOTH focal
                    # length AND sensor size (FOV ~ sensorSize/focalLength), not
                    # focal length alone. Confirmed via this device's own real
                    # cameraLensInfo (capture 3f8fd075): camera "2" has both a
                    # much shorter focal length (2.37mm vs main's 4.15mm) AND a
                    # much smaller sensor (3.92x2.94mm vs main's 5.98x4.49mm) --
                    # the two partly cancel. fl-only gives a ratio of 0.571
                    # (guide scaled to 57% of main -- more than 2x too small in
                    # AREA), while the sensor-corrected ratio is 0.871 (camera
                    # "2"'s real angular FOV is close to main's, not dramatically
                    # wider). Camera "3" is a smaller but still real correction
                    # (0.954 fl-only vs 0.859 corrected). An undersized guide
                    # directly explains the round-20 "mask covers 67% of frame"
                    # self-rejection on camera "2": the dilated bound the real
                    # pad detector gets clipped against was far smaller than
                    # that lens's actual field of view, so a correctly-sized
                    # detection blows past it and gets rejected.
                    _sec_guide = None
                    _main_lens = _lens_info.get('0') or {}
                    _sec_lens = _lens_info.get(_cam.get('name', '')) or {}
                    _sec_cfa = _sec_lens.get('colorFilterArrangement')
                    _fl_sec = _sec_lens.get('focalLengthMm')
                    _sw_main = _main_lens.get('sensorWidthMm')
                    _sh_main = _main_lens.get('sensorHeightMm')
                    _sw_sec = _sec_lens.get('sensorWidthMm')
                    _sh_sec = _sec_lens.get('sensorHeightMm')
                    if (_fl_main and _fl_sec and _guide_region and _fl_main > 0
                            and _sw_main and _sh_main and _sw_sec and _sh_sec):
                        _rx_ratio = (_fl_sec / _sw_sec) / (_fl_main / _sw_main)
                        _ry_ratio = (_fl_sec / _sh_sec) / (_fl_main / _sh_main)
                        # Camera "3" (largest sensor, most similar angle to
                        # main) uses cy=0.37 -- matching the main guide's own
                        # top-half-of-pad default (PadSilhouetteShape.cy).
                        # Camera "2" (wide, very different FOV) keeps cy=0.5
                        # (centred) since its framing offset is unknown without
                        # dedicated calibration data.
                        _sec_cy = (0.37 if _cam.get('name') == '3' else 0.5)
                        _sec_guide = {
                            'cx': 0.5,
                            'cy': _sec_cy,
                            'rx': _guide_region['rx'] * _rx_ratio,
                            'ry': _guide_region['ry'] * _ry_ratio,
                            'tipAngleDeg': 0.0,
                            'n': _guide_region.get('n', 2.5),
                        }
                    _simg_res, _sp = afis_print.generate(
                        _all_simgs, _all_gyros, _all_illums,
                        guide_region=_sec_guide,
                        freq_normalize=True,
                        stack_cache={},
                    )
                    if _simg_res is None:
                        continue
                    _sres = _score_nfiq(_simg_res, sfm_coverage=1.0)
                    _ss = _sres.get('nfiq_score', 0.0) if not _sres.get('error') else 0.0
                    _secondary_cam_scores[_cam.get('name', '?')] = round(_ss, 2)
                    logger.info('AFIS variant %s nfiq=%.1f lap=%.1f', _sname, _ss, _best_lap)
                    # Laplacian gate: a blurry secondary frame (Gabor synthesis
                    # can give a plausible-looking but non-identity print from
                    # soft input, fooling the proxy — confirmed: cam 3 scored
                    # proxy 74.81 / real NFIQ2 5 at Laplacian 19-22). Let the
                    # secondary camera WIN only if its sharpest frame clears the
                    # minimum raw sharpness threshold. The score is still logged
                    # in secondaryCamScores for diagnostics regardless.
                    _sec_wl = _sp.get('afisWavelengthPx') or 0.0
                    _is_ir_cam = _sec_cfa in _IR_CFA_VALUES
                    _wl_ceiling = (_SECONDARY_MAX_WAVELENGTH_PX_IR if _is_ir_cam
                                   else _SECONDARY_MAX_WAVELENGTH_PX)
                    if _best_lap < _SECONDARY_MIN_LAPLACIAN:
                        logger.info(
                            'secondary cam %s blocked from winning: lap=%.1f < %.1f',
                            _sname, _best_lap, _SECONDARY_MIN_LAPLACIAN)
                    elif _sec_wl >= _wl_ceiling:
                        logger.info(
                            'secondary cam %s blocked from winning: wavelength %.1fpx'
                            ' >= %.1fpx ceiling (user too close%s)',
                            _sname, _sec_wl, _wl_ceiling,
                            ', IR ceiling' if _is_ir_cam else '')
                    elif _ss > afis_nfiq:
                        afis_nfiq = _ss
                        best_afis_img = _simg_res
                        afis_params = {**_sp, 'afisNfiq': round(_ss, 2), 'afisSource': _sname}
                    # IR second-pass: for genuine MONO/NIR sensors, run a side-by-
                    # side with tighter Gabor sigma (sigma_ratio=0.3 vs default
                    # 0.65). IR ridge contrast is steeper — a narrower envelope
                    # better resolves the sharper transitions without blurring
                    # across ridge-valley gaps. Runs only when CFA confirms a real
                    # IR sensor; evaluates False on every current-device camera
                    # (all BGGR/GBRG/RGGB — standard Bayer). Same max-of-variants
                    # discipline: whichever score wins. Uses the same _wl_ceiling
                    # gate — the IR-specific ceiling already fired above if needed.
                    if _is_ir_cam and _best_lap >= _SECONDARY_MIN_LAPLACIAN and _sec_wl < _wl_ceiling:
                        try:
                            _ir_img, _ir_sp = afis_print.generate(
                                _all_simgs, _all_gyros, _all_illums,
                                guide_region=_sec_guide,
                                freq_normalize=True,
                                stack_cache={},
                                gabor_sigma_ratio=_IR_GABOR_SIGMA_RATIO,
                            )
                            if _ir_img is not None:
                                _ir_res = _score_nfiq(_ir_img, sfm_coverage=1.0)
                                _ir_ss = (_ir_res.get('nfiq_score', 0.0)
                                          if not _ir_res.get('error') else 0.0)
                                _ir_sname = f'{_sname}_ir_sigma'
                                logger.info('AFIS variant %s nfiq=%.1f', _ir_sname, _ir_ss)
                                if _ir_ss > afis_nfiq:
                                    afis_nfiq = _ir_ss
                                    best_afis_img = _ir_img
                                    afis_params = {**_ir_sp, 'afisNfiq': round(_ir_ss, 2),
                                                   'afisSource': _ir_sname}
                        except Exception as _ir_exc:  # noqa: BLE001
                            logger.warning('IR sigma second-pass failed (non-critical): %s', _ir_exc)
                except Exception as _sec_exc:   # noqa: BLE001 — never block the pipeline
                    logger.warning('secondary camera %s scoring failed (non-critical): %s', _spath, _sec_exc)

            # Sweep-burst candidates (2026-08-03, see
            # docs/BURST_VIDEO_HYBRID_SCOPE.md): the client-side sweep step
            # (front_capture_controller.dart, _captureSweepBurst) is
            # best-effort and often absent -- this whole block is a no-op
            # whenever sweepBurstDebug/paths isn't on the capture doc.
            #
            # Replaces the original video-recording + frame-extraction
            # design (_extract_video_zone_candidates): real device captures
            # (9408bb2a, 1febdba7) showed every video-extracted zone frame
            # scored Laplacian 23-59 vs 311-327 for plain main-burst stills
            # on the SAME captures -- a structural video-exposure/
            # compression problem, not something extraction tuning could
            # fix. Zero sweep-video candidates ever won selection across
            # every real capture checked. The client now fires a real JPEG
            # still at each of 3 zones (left/center/right) instead, so this
            # block just downloads and scores those 3 stills directly --
            # no frame extraction needed.
            #
            # Each zone's still uses its OWN guideRegion (the on-screen
            # guide translated for that zone -- see sweepBurstDebug.
            # guideRegions on the capture doc), falling back to the main
            # capture's guideRegion if the client couldn't compute one
            # (e.g. cached screen/preview geometry wasn't available).
            #
            # Max-of-candidates: can only ever raise afis_nfiq via the same
            # `if _zs > afis_nfiq` gate every other candidate source above
            # uses, never regress a capture this sweep-burst step doesn't
            # apply to.
            #
            # Sharpness-margin guard (2026-08-03): a real capture (fd1da8c1)
            # had a sweep-zone candidate win selection on proxyScore 58.4 --
            # narrowly beating whatever the main burst's own best candidate
            # scored -- backed by a real Laplacian of 1160 (genuinely sharp,
            # not blown-out/soft the way every sweep-zone still scored before
            # zoom-to-fill was disabled client-side). Real ground-truth NFIQ2
            # for the resulting capture still came back 9 -- one of the
            # lowest real scores this project has recorded, despite a
            # wavelength (11px) sitting right in the historically-good
            # 9-14px range. Same lesson as the existing fusion-selection
            # guard above: a single proxy-driven "just barely won" comparison
            # isn't enough evidence a sweep-zone single-frame candidate (no
            # ambient/flash pairing, no multi-frame stacking the way the main
            # burst's own candidates get) is actually the better print, not
            # just a sharp-looking but poorly-formed one. Require a real
            # margin, not just an edge-out, before letting a sweep zone win.
            # Not yet validated against a larger real sample (n=1) -- same
            # standing discipline as every other guard in this file: ship on
            # the strength of the one real regression it directly targets,
            # revisit if it ever suppresses a genuinely-better sweep zone.
            _SWEEP_ZONE_MARGIN_REQUIRED = 3.0
            _sweep_burst_debug: dict = {}
            try:
                _sb_meta = _cap_doc.get('sweepBurstDebug') or {}
                _sb_paths = _sb_meta.get('paths') or {}
                _sb_guides = _sb_meta.get('guideRegions') or {}
                _sweep_burst_debug['present'] = bool(_sb_paths)

                # 2026-08-05: the client now fires an ambient+flash PAIR per
                # zone (keys '<zone>_amb'/'<zone>_fl') instead of one
                # flash-only shot ('<zone>' bare) -- real captured images
                # (b1b5fc67) showed the old flash-only shots consistently
                # blown out (the client applied zero EV compensation, now
                # fixed alongside this). Detect which format this capture
                # used so historical captures keep scoring exactly as
                # before -- the old branch below is byte-for-byte the prior
                # logic, untouched.
                _sb_zone_names = sorted({
                    k.rsplit('_amb', 1)[0] if k.endswith('_amb') else k.rsplit('_fl', 1)[0]
                    for k in _sb_paths if k.endswith('_amb') or k.endswith('_fl')
                })

                if _sb_zone_names:
                    # NEW format: flash-diff-fuse each zone's ambient+flash
                    # pair the same already-proven way _fuse_flash_ambient
                    # fuses the main burst's pair, instead of scoring one
                    # (previously blown-out) flash shot alone.
                    _zone_grays: dict = {}   # zone -> (gray, guide) for the cross-zone fusion below
                    for _zone in _sb_zone_names:
                        _zone_debug: dict = {}
                        try:
                            _amb_path = _sb_paths.get(f'{_zone}_amb')
                            _fl_path = _sb_paths.get(f'{_zone}_fl')
                            _zone_debug['ambPath'] = _amb_path
                            _zone_debug['flPath'] = _fl_path
                            _zamb = (_decode_image(_download_storage_file(_amb_path))
                                     if _amb_path else None)
                            _zfl = (_decode_image(_download_storage_file(_fl_path))
                                    if _fl_path else None)
                            _zfused = (afis_print._fuse_flash_ambient(_zamb, _zfl, mode='soft')
                                       if (_zamb is not None and _zfl is not None) else None)
                            # Falls back to whichever single frame exists if the
                            # pair didn't register/fuse -- can only recover an
                            # otherwise-empty zone, never worse than before.
                            _zsrc = _zfused if _zfused is not None else (
                                _zamb if _zamb is not None else _zfl)
                            _zone_debug['fused'] = _zfused is not None
                            # REAL BUG, found 2026-08-05 (code audit): _fuse_
                            # flash_ambient's own output is already grayscale,
                            # but the fallback path above (_zamb/_zfl) is raw
                            # _decode_image() output, always BGR. That BGR
                            # image flowed into _zone_grays and, when the
                            # CENTER zone hit this exact fallback, into
                            # _front_anchored_mosaic below as `front` --
                            # which calls cv2 CLAHE .apply() on it directly
                            # with no channel check, throwing cv2.error
                            # (confirmed by direct reproduction). That
                            # exception was silently swallowed by the
                            # cross-zone fusion block's own broad except and
                            # logged identically to a genuine registration
                            # failure -- so every time a zone's ambient+flash
                            # pair failed to fuse, the real 'sweepFusion'
                            # candidate this session built could crash
                            # invisibly instead of ever running. Normalising
                            # to grayscale here (once, at the source) fixes
                            # every downstream consumer at once.
                            if _zsrc is not None and _zsrc.ndim != 2:
                                _zsrc = cv2.cvtColor(_zsrc, cv2.COLOR_BGR2GRAY)
                            if _zsrc is None:
                                _zone_debug['error'] = 'no usable frame'
                                _sweep_burst_debug[_zone] = _zone_debug
                                continue
                            _zlap = float(cv2.Laplacian(_zsrc, cv2.CV_64F).var())
                            _zone_debug['laplacian'] = round(_zlap, 1)
                            _zguide = _sb_guides.get(_zone) or _guide_region
                            _zone_grays[_zone] = (_zsrc, _zguide)
                            _zimg_res, _zp = afis_print.generate(
                                [_zsrc], [0.0], [None],
                                guide_region=_zguide,
                                freq_normalize=True,
                                stack_cache={},
                            )
                            if _zimg_res is not None:
                                _zres = _score_nfiq(_zimg_res, sfm_coverage=1.0)
                                _zs = _zres.get('nfiq_score', 0.0) if not _zres.get('error') else 0.0
                                _zone_debug['proxyScore'] = round(_zs, 2)
                                _zname = f'sweepBurst_{_zone}'
                                logger.info('AFIS variant %s nfiq=%.1f lap=%.1f fused=%s',
                                            _zname, _zs, _zlap, _zone_debug['fused'])
                                _zone_debug['wonSelection'] = bool(
                                    _zs > afis_nfiq + _SWEEP_ZONE_MARGIN_REQUIRED)
                                if _zs > afis_nfiq + _SWEEP_ZONE_MARGIN_REQUIRED:
                                    afis_nfiq = _zs
                                    best_afis_img = _zimg_res
                                    afis_params = {**_zp, 'afisNfiq': round(_zs, 2),
                                                   'afisSource': _zname}
                            else:
                                _zone_debug['wonSelection'] = False
                        except Exception as _vz_exc:   # noqa: BLE001
                            logger.warning('sweep burst zone %s (fused) scoring failed: %s',
                                            _zone, _vz_exc)
                            _zone_debug['error'] = str(_vz_exc)
                        _sweep_burst_debug[_zone] = _zone_debug

                    # Cross-zone fusion (2026-08-05, tested offline against
                    # real captures before wiring in -- reused-code mosaic
                    # measured +9 and +1 real NFIQ2 over the best single
                    # zone on the 2 real captures checked). Mosaic-fuses the
                    # per-zone (now flash-diff-fused) images together via
                    # _front_anchored_mosaic (built for the discontinued
                    # four-angle flow, never wired here before), anchored on
                    # center since that's the zone closest to the main
                    # capture's own guideRegion. Purely additive, same
                    # margin-guard gate as every other sweep candidate.
                    #
                    # REAL BUG FOUND + FIXED 2026-08-08: `_front_anchored_
                    # mosaic` registers on the WHOLE raw still, which was
                    # correct for the discontinued four-angle flow (camera
                    # yaws around a frame-filling thumb) but wrong here --
                    # the sweep-burst guide asks the FINGER to translate
                    # while the camera stays fixed and wide, so each zone's
                    # still is mostly a large, static, in-focus ROOM with
                    # the pad occupying a small fraction of the frame.
                    # Measured directly against 2 real captures with
                    # sweepBurstCandidates data: full-frame phase-correlation
                    # between adjacent zones gave a weak/noisy response
                    # (0.003-0.15, where ~1.0 is a confident single dominant
                    # shift) -- whole-frame ECC has no reliable pad-to-pad
                    # signal to lock onto and is easily dominated by the
                    # static background instead, explaining both the real
                    # 'mosaic registration failed' cases and why even a
                    # "successful" registration never won selection (very
                    # likely aligning the room, not the ridge content).
                    # `_front_anchored_mosaic_zones` crops every zone to the
                    # real union of all zones' own guide masks (with real
                    # registration search margin) before ECC, so the
                    # registration signal is dominated by pad content
                    # instead. Confirmed on the same 2 real captures: fixes
                    # one real outright registration failure (None -> a
                    # working 79 NFIQ2 mosaic); still doesn't beat the best
                    # single zone on either capture, consistent with a
                    # SEPARATE, capture-side finding from the same
                    # investigation (the 3 zones show very little real
                    # spatial diversity in practice -- near-duplicate
                    # framing, not the complementary coverage the design
                    # intends) -- that gap needs a capture-side fix
                    # (verify real repositioning before each zone fires,
                    # not just a timed animation), not a backend one.
                    # Purely additive here regardless: can only ever recover
                    # an already-failing mosaic or match the old one, never
                    # regress it.
                    try:
                        _mos, _mosaic_guide, _n_used = afis_print._front_anchored_mosaic_zones(_zone_grays)
                        if 'center' in _zone_grays:
                            _sides = [g for z, (g, _) in _zone_grays.items() if z != 'center']
                            _fusion_debug: dict = {'sidesAvailable': len(_sides)}
                            if _sides:
                                if _mos is not None:
                                    _fusion_debug['sidesUsed'] = _n_used
                                    _fusion_debug['method'] = 'zoneCrop'
                                    _mimg_res, _mp = afis_print.generate(
                                        [_mos], [0.0], [None],
                                        guide_region=_mosaic_guide,
                                        freq_normalize=True,
                                        stack_cache={},
                                    )
                                    if _mimg_res is not None:
                                        _mres = _score_nfiq(_mimg_res, sfm_coverage=1.0)
                                        _ms = (_mres.get('nfiq_score', 0.0)
                                               if not _mres.get('error') else 0.0)
                                        _fusion_debug['proxyScore'] = round(_ms, 2)
                                        logger.info(
                                            'AFIS variant sweepFusion nfiq=%.1f (sides %d/%d)',
                                            _ms, _n_used, len(_sides))
                                        _fusion_debug['wonSelection'] = bool(
                                            _ms > afis_nfiq + _SWEEP_ZONE_MARGIN_REQUIRED)
                                        if _ms > afis_nfiq + _SWEEP_ZONE_MARGIN_REQUIRED:
                                            afis_nfiq = _ms
                                            best_afis_img = _mimg_res
                                            afis_params = {**_mp, 'afisNfiq': round(_ms, 2),
                                                           'afisSource': 'sweepFusion'}
                                    else:
                                        _fusion_debug['wonSelection'] = False
                                else:
                                    _fusion_debug['error'] = 'mosaic registration failed'
                            _sweep_burst_debug['fusion'] = _fusion_debug
                    except Exception as _fu_exc:   # noqa: BLE001
                        logger.warning('sweep cross-zone fusion failed (non-critical): %s', _fu_exc)
                        _sweep_burst_debug['fusionError'] = str(_fu_exc)
                else:
                    # OLD format (pre-2026-08-05 captures, bare '<zone>'
                    # keys, one flash-only shot per zone) -- untouched.
                    for _zone, _zpath in _sb_paths.items():
                        _zone_debug: dict = {'path': _zpath}
                        try:
                            _zbytes = _download_storage_file(_zpath)
                            _zarr = _decode_image(_zbytes)
                            _zlap = (float(cv2.Laplacian(_zarr, cv2.CV_64F).var())
                                     if _zarr is not None else 0.0)
                            _zone_debug['laplacian'] = round(_zlap, 1)
                            _zguide = _sb_guides.get(_zone) or _guide_region
                            _zimg_res, _zp = afis_print.generate(
                                [_zarr], [0.0], [None],
                                guide_region=_zguide,
                                freq_normalize=True,
                                stack_cache={},
                            )
                            if _zimg_res is not None:
                                _zres = _score_nfiq(_zimg_res, sfm_coverage=1.0)
                                _zs = _zres.get('nfiq_score', 0.0) if not _zres.get('error') else 0.0
                                _zone_debug['proxyScore'] = round(_zs, 2)
                                _zname = f'sweepBurst_{_zone}'
                                logger.info('AFIS variant %s nfiq=%.1f lap=%.1f',
                                            _zname, _zs, _zlap)
                                _zone_debug['wonSelection'] = bool(
                                    _zs > afis_nfiq + _SWEEP_ZONE_MARGIN_REQUIRED)
                                if _zs > afis_nfiq + _SWEEP_ZONE_MARGIN_REQUIRED:
                                    afis_nfiq = _zs
                                    best_afis_img = _zimg_res
                                    afis_params = {**_zp, 'afisNfiq': round(_zs, 2),
                                                   'afisSource': _zname}
                            else:
                                _zone_debug['wonSelection'] = False
                        except Exception as _vz_exc:   # noqa: BLE001
                            logger.warning('sweep burst zone %s scoring failed: %s', _zone, _vz_exc)
                            _zone_debug['error'] = str(_vz_exc)
                        _sweep_burst_debug[_zone] = _zone_debug
            except Exception as _sv_exc:   # noqa: BLE001 -- never block the pipeline
                logger.warning('sweep burst candidate scoring failed (non-critical): %s', _sv_exc)
                _sweep_burst_debug['error'] = str(_sv_exc)

            # Minutiae-patch candidates (2026-08-03): three sub-region crops of
            # the same main burst frames, each scored independently as a
            # max-of-variants candidate.  Using tighter guide bounds on the same
            # already-downloaded stills amplifies ridge density in three distinct
            # pad sub-regions without any extra device capture:
            #   core  — 70 % of rx/ry, same centre: densest central-whorl ridges
            #   left  — cx shifted left by 35 % of rx, 70 % rx: left-delta ridges
            #   right — cx shifted right by 35 % of rx, 70 % rx: right-delta ridges
            # Reuses _stack_cache from the main variant loop: the ECC alignment
            # produced there is frame-content-keyed (not guide-keyed), so the
            # cached stacks are valid inputs for any sub-guide crop.
            # Skipped when _guide_region is absent (no sub-guides can be derived).
            try:
                if _guide_region:
                    _gr = _guide_region
                    _patch_subguides = {
                        'core': {
                            'cx': _gr['cx'],
                            'cy': _gr['cy'],
                            'rx': _gr['rx'] * 0.70,
                            'ry': _gr['ry'] * 0.70,
                            'n': _gr.get('n', 2.5),
                            'tipAngleDeg': _gr.get('tipAngleDeg', 0.0),
                        },
                        'left': {
                            'cx': _gr['cx'] - _gr['rx'] * 0.35,
                            'cy': _gr['cy'],
                            'rx': _gr['rx'] * 0.70,
                            'ry': _gr['ry'],
                            'n': _gr.get('n', 2.5),
                            'tipAngleDeg': _gr.get('tipAngleDeg', 0.0),
                        },
                        'right': {
                            'cx': _gr['cx'] + _gr['rx'] * 0.35,
                            'cy': _gr['cy'],
                            'rx': _gr['rx'] * 0.70,
                            'ry': _gr['ry'],
                            'n': _gr.get('n', 2.5),
                            'tipAngleDeg': _gr.get('tipAngleDeg', 0.0),
                        },
                    }
                    for _pname, _pguide in _patch_subguides.items():
                        _pdebug: dict = {
                            'guide': {k: round(v, 4) for k, v in _pguide.items()
                                      if isinstance(v, (int, float))}
                        }
                        try:
                            _pimg, _pp = afis_print.generate(
                                frames, angles_for_sfm, _laps,
                                ambient_frames=ambient_frames,
                                flash_frames=flash_frames,
                                ambient_burst=ambient_burst,
                                flash_burst=flash_burst,
                                ambient_burst_gyros=ambient_burst_gyros,
                                flash_burst_gyros=flash_burst_gyros,
                                guide_region=_pguide,
                                freq_normalize=True,
                                stack_cache=_stack_cache,
                            )
                            if _pimg is not None:
                                _pres = _score_nfiq(_pimg, sfm_coverage=1.0)
                                _ps = (_pres.get('nfiq_score', 0.0)
                                       if not _pres.get('error') else 0.0)
                                _pdebug['proxyScore'] = round(_ps, 2)
                                logger.info('AFIS minutiae patch %s nfiq=%.1f', _pname, _ps)
                                _pdebug['wonSelection'] = bool(_ps > afis_nfiq)
                                if _ps > afis_nfiq:
                                    afis_nfiq = _ps
                                    best_afis_img = _pimg
                                    afis_params = {**_pp, 'afisNfiq': round(_ps, 2),
                                                   'afisSource': f'minutiae_{_pname}'}
                            else:
                                _pdebug['wonSelection'] = False
                        except Exception as _pe:   # noqa: BLE001
                            logger.warning('minutiae patch %s scoring failed: %s', _pname, _pe)
                            _pdebug['error'] = str(_pe)
                        _minutiae_patch_debug[_pname] = _pdebug
                else:
                    _minutiae_patch_debug['skipped'] = 'no guide region'
            except Exception as _mp_exc:   # noqa: BLE001 -- never block the pipeline
                logger.warning('minutiae patch scoring failed (non-critical): %s', _mp_exc)
                _minutiae_patch_debug['error'] = str(_mp_exc)

            if best_afis_img is not None:
                afis_path = _save_afis_print(best_afis_img, user_id, capture_id)
        except Exception as afis_exc:   # noqa: BLE001 — never block the pipeline
            logger.warning('AFIS superprint failed (non-critical): %s', afis_exc)

        # Official quality = best of the unwrap and the AFIS renderings.
        nfiq_score = max(cyl_nfiq, afis_nfiq)
        nfiq_pass  = nfiq_score >= _PASS_THRESHOLD

        # ── 4d. Real NFIQ2 ground-truth score (additive, non-blocking) ─────────
        # nfiqScore above is the ResNet18 proxy -- fast, used as the training/
        # ranking signal throughout this pipeline, but a learned proxy, not the
        # NIST ground-truth algorithm. Score the SAME image that won nfiqScore
        # (mirrors the nfiqSource selection below) through the real NFIQ2
        # binary via the sidecar service. Never blocks or fails the pipeline:
        # score_nfiq2() itself never raises, and nfiq2Score is simply null in
        # Firestore if the sidecar is unreachable, unconfigured, or times out.
        #
        # Do NOT "fix" this to always score best_enhanced instead -- a real
        # production oscillating capture has scored 70% NFIQ2 via the
        # binarized AFIS superprint (nfiqSource=afis), so the binarized
        # rendering is not inherently out-of-distribution for NFIQ2. A
        # previous session incorrectly assumed otherwise (catastrophic
        # nfiq2Score of 4-6 on two front_only_v1 captures, both
        # nfiqSource=afis) and swapped this to always score best_enhanced;
        # that was reverted once the 70% counter-example surfaced. The 4-6
        # scores traced to real capture-quality problems on those two
        # captures (AF-lock timing, camera shake, red ambient-light cast) --
        # not to which image type NFIQ2 was scoring.
        winning_image = best_afis_img if (afis_nfiq >= cyl_nfiq and afis_nfiq > 0) else best_enhanced
        nfiq2_score = nfiq2_client.score_nfiq2(winning_image)
        nfiq2_source = 'winner'

        # Additive experiment: the ResNet18 proxy above doesn't appear to
        # penalise an out-of-domain ridge period the way real NFIQ2 does (a
        # real front_only_v1 capture won its proxy vote at afisWavelengthPx
        # 15.5-20px -- over 2x afis_print's own _TARGET_PERIOD=9.0 -- while
        # the frequency-normalised variant, which would correct that, scored
        # lower on the proxy and lost; the one real capture that hit exactly
        # 9.0px scored 62 NFIQ2, the best clean result on record). If the
        # freqNorm rendering differs from the proxy-selected winner, score it
        # too and keep whichever real NFIQ2 is higher -- same non-regressing
        # "keep the max" pattern as the proxy variants above, just applied to
        # the ground-truth score directly since the two models disagree here.
        if freqnorm_img is not None and freqnorm_img is not winning_image:
            _freqnorm_nfiq2 = nfiq2_client.score_nfiq2(freqnorm_img)
            if _freqnorm_nfiq2 is not None and (nfiq2_score is None or _freqnorm_nfiq2 > nfiq2_score):
                nfiq2_score = _freqnorm_nfiq2
                nfiq2_source = 'freqNorm'

        # ── 5. Henry classification ────────────────────────────────────────────
        # Use best TTA variant image — same preprocessing that scored highest.
        henry_class = _classify_henry(best_enhanced)
        t_henry = time.monotonic()

        processing_ms = int((t_henry - t_start) * 1000)
        nns_stage     = getattr(enhancement_pipeline, '_nns_stage', 1)
        logger.info(
            f"capture={capture_id} nfiq={nfiq_score:.1f} pass={nfiq_pass} "
            f"henry={henry_class} nns_stage={nns_stage} ms={processing_ms}"
        )

        # ── Write result to Firestore ──────────────────────────────────────────
        _update_firestore(capture_id, {
            'status':           'scored',
            'nfiqScore':        round(nfiq_score, 2),
            'nfiqPass':         nfiq_pass,
            'nfiq2Score':       nfiq2_score,
            # Which image nfiq2Score actually came from: 'winner' (the proxy's
            # own pick, same as nfiqSource) or 'freqNorm' (the frequency-
            # normalised rendering, when it beat the proxy's pick on real
            # NFIQ2 specifically) -- diagnostic for the prime-directive
            # frequency-mismatch experiment, see main.py's NFIQ2-scoring step.
            'nfiq2Source':      nfiq2_source,
            'nfiqSource':       'afis' if afis_nfiq >= cyl_nfiq and afis_nfiq > 0 else 'cylindrical',
            'nfiqCylindrical':  round(cyl_nfiq, 2),
            'nfiqAfis':         round(afis_nfiq, 2) if afis_nfiq > 0 else None,
            'henryClass':       henry_class,
            'processingTimeMs': processing_ms,
            'scoredAt':         firestore.SERVER_TIMESTAMP,
            'nnsStage':         nns_stage,
            'pipelineVersion':  'MAC3D-v31',
            'stagingLatencyMs': {
                'download': round((t_download - t_start) * 1000),
                'sfm':      round((t_sfm      - t_download) * 1000),
                'nns':      round((t_nns      - t_sfm)      * 1000),
                'nfiq':     round((t_nfiq     - t_nns)      * 1000),
                'henry':    round((t_henry    - t_nfiq)     * 1000),
            },
            'sfmDiagnostics':    sfm_diagnostics or None,
            'nfiqTtaScores':     nfiq_result.get('tta_scores'),
            'enhancementParams': enhancement_params,
            'enhancedImagePath': enhanced_path,
            'superprintPath':    afis_path,
            'superprintParams':  afis_params or None,
            # Per-camera proxy NFIQ scores for all secondary cameras that
            # completed scoring this run -- diagnostic for comparing cameras
            # without relying solely on which one happened to win the max.
            'secondaryCamScores': _secondary_cam_scores or None,
            # Burst+video hybrid capture, Phase 0 diagnostic (see
            # docs/BURST_VIDEO_HYBRID_SCOPE.md): per-zone real Laplacian +
            # proxy score + whether that zone's video-sourced candidate won
            # selection. Gate for building the spec's Phase 4 fusion: needs
            # wonSelection:true on a real fraction of captures (evidence a
            # video-sourced frame is genuinely competitive) before that
            # much harder, currently-unproven registration/stitching work
            # is justified.
            'sweepBurstCandidates': _sweep_burst_debug or None,
            # Minutiae-patch candidates diagnostic (2026-08-03): per-patch
            # sub-guide, proxy score, and whether that patch won selection.
            # Gate for deciding whether to invest further in patch-level
            # fusion: needs wonSelection:true on a real fraction of captures
            # (evidence a tighter crop genuinely beats the full-guide result).
            'minutiaeDebug': _minutiae_patch_debug or None,
        }, critical=True)

        # POPIA data minimization: raw frames served their purpose (pipeline input).
        # Skip deletion when preserveRawFrames=true OR when the capture belongs to the
        # developer account (_DEV_UID) so that optimize_sfm.py / run_sfm_test.py can
        # replay any capture without needing the flag set manually.
        cap_snap  = db.collection('captures').document(capture_id).get()
        user_snap = db.collection('users').document(user_id).get()
        is_test_participant = (user_snap.to_dict() or {}).get('isTestParticipant', False)
        cap_data = cap_snap.to_dict() or {}
        preserve = (
            _BETA_PHASE                                   # global beta retention
            or cap_data.get('preserveRawFrames', False)   # per-capture flag
            or (user_id == _DEV_UID)                      # dev account
            or is_test_participant                         # beta group
        )
        if preserve:
            logger.info(
                f'Skipping frame deletion for {capture_id} '
                f'(beta={_BETA_PHASE} dev={user_id==_DEV_UID} '
                f'flag={cap_data.get("preserveRawFrames",False)} '
                f'testParticipant={is_test_participant})'
            )
        else:
            try:
                _delete_capture_frames(base_path)
            except Exception as _del_exc:
                logger.warning(f'Frame deletion failed (non-critical): {_del_exc}')

        return {
            'nfiqScore':  round(nfiq_score, 2),
            'nfiqPass':   nfiq_pass,
            'henryClass': henry_class,
        }

    except Exception as e:
        logger.exception(f"Fatal error for capture={capture_id}: {e}")
        _fail(capture_id, str(e)[:500])
        raise https_fn.HttpsError(
            code=https_fn.FunctionsErrorCode.INTERNAL,
            message=f'Pipeline failed: {e}',
        )


# ── Frame download ─────────────────────────────────────────────────────────────


def _best_frame_from_paths(paths: list) -> 'tuple[Optional[np.ndarray], float, Optional[str]]':
    """Download all paths in parallel, return (best_arr, lap_score, best_path) by Laplacian variance."""
    best_path:  Optional[str]        = None
    best_score: float                = -1.0
    best_arr:   Optional[np.ndarray] = None

    def _fetch_and_score(path: str):
        img_bytes = _download_storage_file(path)
        arr       = _decode_image(img_bytes)
        gray      = cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY)
        score     = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        return path, arr, score

    with ThreadPoolExecutor(max_workers=min(len(paths), 6)) as ex:
        futures = {ex.submit(_fetch_and_score, p): p for p in paths}
        for fut in as_completed(futures):
            path, arr, score = fut.result()
            if score > best_score:
                best_score = score
                best_path  = path
                best_arr   = arr

    return best_arr, best_score, best_path


def _fuse_frames(amb_arr: np.ndarray, fl_arr: np.ndarray) -> 'tuple[np.ndarray, float]':
    """Mertens exposure fusion of ambient + flash frames. Returns (fused_bgr, lap_score)."""
    merge    = cv2.createMergeMertens()
    fused    = merge.process([amb_arr, fl_arr])
    fused_u8 = np.clip(fused * 255, 0, 255).astype(np.uint8)
    gray     = cv2.cvtColor(fused_u8, cv2.COLOR_BGR2GRAY)
    lap      = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    return fused_u8, lap


def _download_best_frames(base_path: str):
    """
    Download all frames per angle from Firebase Storage, then select the best
    per angle. When both ambient (_amb_) and flash (_fl_) frames are present,
    fuses the sharpest of each via Mertens exposure fusion for ridge detail from
    both natural contrast and torch fill.

    All four angles are fetched concurrently to cut serial download latency.

    Storage path formats:
      New:    {basePath}/frame_{N}_{angleName}_amb_{idx}.jpg  (ambient)
              {basePath}/frame_{N}_{angleName}_fl_{idx}.jpg   (torch-lit)
      Legacy: {basePath}/frame_{N}_{angleName}_{idx}.jpg      (treated as ambient)

    Returns (bgr_frames, meta_out, actual_angles_deg).
    """
    _, bucket = _get_firebase()
    blobs     = list(bucket.list_blobs(prefix=base_path))
    blob_map_amb: dict[str, list] = {a: [] for a in _ANGLE_NAMES}
    blob_map_fl:  dict[str, list] = {a: [] for a in _ANGLE_NAMES}
    for blob in blobs:
        fname = blob.name.split('/')[-1]
        parts = fname.replace('.jpg', '').split('_')
        # New format:    frame_{num}_{angle}_{type}_{idx}  — parts[3] in {'amb','fl'}
        # Legacy format: frame_{num}_{angle}_{idx}         — parts[3] is a digit string
        if len(parts) >= 3 and parts[0] == 'frame':
            angle = parts[2]
            if angle not in blob_map_amb:
                continue
            frame_type = parts[3] if len(parts) >= 5 and parts[3] in ('amb', 'fl') else 'amb'
            (blob_map_fl if frame_type == 'fl' else blob_map_amb)[angle].append(blob.name)

    def _fetch_one_angle(angle_idx: int, angle: str):
        """Download + select best frame for one angle. Returns (angle_idx, arr, meta, amb_arr, fl_arr) or None for missing top."""
        amb_paths = blob_map_amb.get(angle, [])
        fl_paths  = blob_map_fl.get(angle, [])
        has_amb   = bool(amb_paths)
        has_fl    = bool(fl_paths)
        amb_arr   = None
        fl_arr    = None

        if not has_amb and not has_fl:
            if angle == 'top':
                logger.warning("Top (180°) frame missing — continuing with 3 views")
                return None
            raise CaptureQualityError(
                f"No Storage frames found for angle '{angle}' under '{base_path}'"
            )

        if has_amb and has_fl:
            amb_arr, amb_lap, amb_path = _best_frame_from_paths(amb_paths)
            fl_arr,  fl_lap,  fl_path  = _best_frame_from_paths(fl_paths)
            fused_arr, fused_lap = _fuse_frames(amb_arr, fl_arr)
            # Guard: fall back to single best if fusion severely degraded sharpness.
            # 0.58 is intentionally permissive — Mertens fused ambient+flash yields
            # better ridge-valley contrast even when Laplacian is slightly lower,
            # because complementary lighting fills shadows that single frames miss.
            threshold = 0.58 * max(amb_lap, fl_lap)
            if fused_lap >= threshold:
                best_arr, best_score = fused_arr, fused_lap
                best_path            = f'mertens({amb_path},{fl_path})'
                frame_source         = 'mertens_fused'
            else:
                logger.warning(
                    f"  Mertens degraded {angle} (fused={fused_lap:.1f} < "
                    f"0.58×{max(amb_lap, fl_lap):.1f}) — using single best"
                )
                if amb_lap >= fl_lap:
                    best_arr, best_score, best_path = amb_arr, amb_lap, amb_path
                else:
                    best_arr, best_score, best_path = fl_arr,  fl_lap,  fl_path
                frame_source = 'fallback_single'
        elif has_amb:
            best_arr, best_score, best_path = _best_frame_from_paths(amb_paths)
            frame_source = 'ambient_only'
        else:
            best_arr, best_score, best_path = _best_frame_from_paths(fl_paths)
            frame_source = 'flash_only'

        # Center-square crop at native resolution.
        h, w = best_arr.shape[:2]
        side = min(h, w)
        y0 = (h - side) // 2
        x0 = (w - side) // 2
        best_arr = best_arr[y0:y0 + side, x0:x0 + side]

        meta = {
            'angle': angle,
            'storagePath': best_path,
            'laplacianScore': best_score,
            'frameSource': frame_source,
        }
        logger.info(f"  angle={angle} source={frame_source} lap={best_score:.1f}")
        return angle_idx, best_arr, meta, amb_arr, fl_arr

    # Fetch all angles concurrently — iterate futures in submission order to
    # preserve front/right/top/left ordering and propagate any exceptions cleanly.
    with ThreadPoolExecutor(max_workers=len(_ANGLE_NAMES)) as pool:
        futures = [
            pool.submit(_fetch_one_angle, i, angle)
            for i, angle in enumerate(_ANGLE_NAMES)
        ]
        raw_results = [f.result() for f in futures]   # raises if any angle errored

    bgr_frames     = []
    meta_out       = []
    ambient_frames = []
    flash_frames   = []
    actual_angles_filtered = []
    _cylindrical = [0.0, 90.0, 180.0, 270.0]
    for r in raw_results:
        if r is None:
            continue   # missing top angle
        angle_idx, arr, meta, amb_arr, fl_arr = r
        bgr_frames.append(arr)
        meta_out.append(meta)
        ambient_frames.append(amb_arr)
        flash_frames.append(fl_arr)
        actual_angles_filtered.append(angle_idx)

    actual_angles = [_cylindrical[i] for i in actual_angles_filtered]
    return bgr_frames, meta_out, actual_angles, ambient_frames, flash_frames



def _download_arc_frames(capture_id: str, base_path: str):
    """
    Download arc-sweep frames using the Firestore `frames` metadata array as the
    single source of truth for frame order AND per-frame SFM angle — NOT a
    Storage blob listing.

    Why not a Storage listing (the previous approach): frame_{N}_arc_{binIndex}.jpg
    filenames are not unique on binIndex alone — ambient + torch-lit frames share
    a bin, and checkpoint stills are tagged onto their leg's last bin too. GCS
    lists blobs in lexicographic filename order, so e.g. "frame_36_arc_5.jpg"
    (a still, uploaded near the end of the session) sorts BEFORE
    "frame_6_arc_5.jpg" (that bin's regular ambient frame) because '3' < '6' as
    characters — the opposite of true upload order. `reconstruct_and_unwrap`
    zips frames[i] with angles_deg[i] purely positionally, so that reordering
    silently paired each frame with a DIFFERENT frame's angle whenever a still
    or a flash-paired frame shared a bin — true of every arc-sweep capture now
    that stills and torch alternation are both in play. The Firestore `frames`
    array is written by the Flutter client in exact upload order (the same loop
    that assigns frame_{i+1}), so indexing into it directly is the only
    architecturally sound source of truth for this correspondence.

    Also computes the SFM cylindrical angle per frame here instead of trusting
    the flat pitch-only `arcAngles` payload: the cylindrical projection model
    (Px = R*sin(theta-phi) in reconstruct_and_unwrap) is a single-axis azimuthal
    rotation with no roll dimension at all. Passing raw pitch for the TOP leg
    (legIndex 1, a roll-dominant motion) made those frames' angles overlap the
    LEFT leg's pitch range (both traverse pitch through [-22, 0]) and get
    attributed to the wrong sector. LEFT/RIGHT legs are genuine azimuthal
    (pitch-axis) motions and get a real angle scaled from pitch.

    The scaling is derived from THIS capture's actual measured pitch/roll
    extremes, not a hardcoded checkpoint magnitude. The ±22°/-13° targets in
    ArcSweepCaptureController guide the user and gate leg transitions, but real
    users land anywhere in a ±5° window around those targets (the Flutter ratchet
    fires at 5° leeway). Normalising to actual extremes means whatever range was
    genuinely swept maps to the full ±90°/10° cylindrical span — frames are
    correctly distributed across the cylinder regardless of whether the user hit
    the exact checkpoint. Hardcoded targets serve as fallback only when a leg
    has fewer than two usable frames. TOP gets the same nominal angle treatment
    as the 4-angle flow's top view (roll has no clean azimuthal interpretation)
    — spread lightly (180-190 deg) via actual roll range so its frames don't
    collapse onto one identical angle.

    Individual frame download/decode failures are skipped (not fatal) so one
    bad blob can't sink an otherwise-good capture.

    Raises CaptureQualityError if fewer than 3 frames download successfully.
    """
    db, _ = _get_firebase()
    doc = db.collection('captures').document(capture_id).get()
    frames_meta_fs = (doc.to_dict() or {}).get('frames', [])

    # --- Derive angle scales from this capture's actual measured extremes ---
    # Flutter checkpoint targets (±22° pitch / 13° roll) guide the user and
    # serve as fallback; real users stop within ±5° of those targets.
    # Normalising to what was actually swept ensures frames span the full
    # cylindrical coordinate range regardless of whether exact targets were hit.
    _PITCH_CHECKPOINT = 22.0
    _ROLL_CHECKPOINT  = 13.0
    _MIN_SCALE_DEG    = 5.0  # guard against degenerate / nearly-static captures

    left_pitches  = [float(e.get('pitchDeg', 0.0)) for e in frames_meta_fs
                     if int(e.get('legIndex', 0)) == 0 and float(e.get('pitchDeg', 0.0)) < -1.0]
    right_pitches = [float(e.get('pitchDeg', 0.0)) for e in frames_meta_fs
                     if int(e.get('legIndex', 0)) == 2 and float(e.get('pitchDeg', 0.0)) >  1.0]
    top_rolls     = [float(e.get('rollDeg',  0.0)) for e in frames_meta_fs
                     if int(e.get('legIndex', 0)) == 1 and float(e.get('rollDeg', 0.0))  < -1.0]

    actual_left  = abs(min(left_pitches))  if len(left_pitches)  >= 2 else _PITCH_CHECKPOINT
    actual_right = max(right_pitches)      if len(right_pitches) >= 2 else _PITCH_CHECKPOINT
    actual_top   = abs(min(top_rolls))     if len(top_rolls)     >= 2 else _ROLL_CHECKPOINT

    pitch_left_scale  = 90.0 / max(actual_left,  _MIN_SCALE_DEG)
    pitch_right_scale = 90.0 / max(actual_right, _MIN_SCALE_DEG)
    roll_scale_top    = 1.0  / max(actual_top,   2.0)

    logger.info(
        'Arc angle scales — actual left=%.1f° right=%.1f° top_roll=%.1f° '
        '→ pitch_left=%.3f pitch_right=%.3f roll=%.3f',
        actual_left, actual_right, actual_top,
        pitch_left_scale, pitch_right_scale, roll_scale_top,
    )

    def _sfm_angle_for(entry: dict) -> Optional[float]:
        # Current client schema: pitchDeg/rollDeg/legIndex per frame.
        # Legacy clients (pre-July-4 APKs) wrote only arcAngleDeg — a
        # cumulative sweep angle. A capture whose frames lack BOTH schemas
        # yields None so the caller can fail loudly instead of silently
        # assigning every frame 0.0° (which is exactly what happened to the
        # first production arc capture: all angles defaulted to 0, the gap
        # check saw a 360° hole, and the whole capture fell back to
        # front-only with no diagnostic trail).
        if entry.get('pitchDeg') is not None or entry.get('legIndex') is not None:
            leg_index = int(entry.get('legIndex') or 0)
            pitch     = float(entry.get('pitchDeg') or 0.0)
            roll      = float(entry.get('rollDeg') or 0.0)
            if leg_index == 1:  # TOP leg — roll-dominant, no azimuthal meaning
                t = float(np.clip(roll * roll_scale_top, 0.0, 1.0))
                return 0.0 + t * 10.0
            if pitch < 0:       # LEFT leg
                return pitch * pitch_left_scale
            return pitch * pitch_right_scale  # RIGHT leg
        if entry.get('arcAngleDeg') is not None:
            # Legacy: cumulative sweep angle (0 → span). Centre it so the
            # mid-sweep frame sits at 0° (front), matching the cylindrical
            # convention. Uses the capture's own extremes for the range.
            return float(entry['arcAngleDeg'])
        return None

    def _fetch(i: int, entry: dict):
        try:
            bin_idx   = int(entry.get('binIndex', i))
            path      = f'{base_path}/frame_{i + 1}_arc_{bin_idx}.jpg'
            img_bytes = _download_storage_file(path)
            arr       = _decode_image(img_bytes)
            h, w      = arr.shape[:2]
            side      = min(h, w)
            arr       = arr[(h - side) // 2:(h - side) // 2 + side,
                            (w - side) // 2:(w - side) // 2 + side]
            angle = _sfm_angle_for(entry)
            meta  = {
                'angle':          f'arc_{bin_idx}',
                'storagePath':    path,
                'laplacianScore': entry.get('laplacianScore'),
                'frameSource':    'arc_still' if entry.get('still') else 'arc',
                'legIndex':       entry.get('legIndex'),
                'pitchDeg':       entry.get('pitchDeg'),
                'rollDeg':        entry.get('rollDeg'),
            }
            return i, arr, meta, angle
        except Exception as e:
            logger.warning(
                'Arc frame %d (bin=%s) failed to download/decode — skipping: %s',
                i, entry.get('binIndex'), e,
            )
            return i, None, None, None

    with ThreadPoolExecutor(max_workers=min(max(len(frames_meta_fs), 1), 8)) as ex:
        futures = [ex.submit(_fetch, i, entry) for i, entry in enumerate(frames_meta_fs)]
        raw_results = sorted([f.result() for f in as_completed(futures)], key=lambda x: x[0])

    results = [r for r in raw_results if r[1] is not None]
    if len(results) < 3:
        raise CaptureQualityError(
            f'Arc sweep requires at least 3 successfully-downloaded frames; '
            f'got {len(results)} of {len(frames_meta_fs)} Firestore frames[] '
            f'entries for {capture_id}'
        )

    # ── Angle sanity: fail LOUDLY on missing/degenerate metadata ─────────────
    n_missing = sum(1 for r in results if r[3] is None)
    if n_missing > len(results) // 2:
        raise CaptureQualityError(
            f'Arc frame metadata missing angle data on {n_missing}/{len(results)} '
            f'frames (no pitchDeg/legIndex, no arcAngleDeg) — client/backend '
            f'schema mismatch; cannot assign cylindrical angles.'
        )
    results = [r for r in results if r[3] is not None]

    # Legacy arcAngleDeg values are cumulative (0 → span); centre the whole
    # set so mid-sweep sits at 0° and clamp to the cylindrical ±90° range.
    legacy = [r for r in results if r[2].get('pitchDeg') is None and not r[2].get('legIndex')]
    if len(legacy) == len(results):
        a_vals = [r[3] for r in results]
        mid    = 0.5 * (min(a_vals) + max(a_vals))
        results = [
            (i, arr, meta, float(np.clip(a - mid, -90.0, 90.0)))
            for (i, arr, meta, a) in results
        ]
        logger.info('Legacy arcAngleDeg schema: centred %d frames around mid-sweep %.1f°', len(results), mid)

    angle_vals = [r[3] for r in results]
    if max(angle_vals) - min(angle_vals) < 10.0:
        raise CaptureQualityError(
            f'Arc angle span {max(angle_vals) - min(angle_vals):.1f}° < 10° — '
            f'degenerate sweep metadata; cannot stitch.'
        )

    # ── Blur filter: drop motion-smeared frames ──────────────────────────────
    # Arc frames are grabbed while the device is moving; half of a real
    # capture's frames can be motion smear (observed Laplacian 3.6–10 next to
    # 100–200 on the same sweep). Averaging those into the cylindrical
    # texture destroys ridge contrast in exactly the sectors they cover.
    laps = [float(r[2].get('laplacianScore') or 0.0) for r in results]
    lap_med = float(np.median([l for l in laps if l > 0]) or 0.0)
    if lap_med > 0 and len(results) > 4:
        keep_thr = max(15.0, 0.25 * lap_med)
        kept = [r for r, l in zip(results, laps) if l <= 0 or l >= keep_thr]
        if len(kept) >= 3:
            dropped = len(results) - len(kept)
            if dropped:
                logger.info('Blur filter: dropped %d/%d arc frames (lap < %.1f)',
                            dropped, len(results), keep_thr)
            results = kept

    # Sort by computed SFM angle (not upload order) before returning.
    # _refine_angles correlates frames[i] against frames[i+1] and propagates
    # corrections cumulatively forward — it assumes array-adjacent frames are
    # angularly adjacent. Firestore upload order puts all 3 checkpoint stills
    # at the end regardless of their angle, and leg transitions are large jumps
    # mid-array; the overlap/confidence checks in _correlate_overlap should
    # reject most resulting mismatched pairs, but sorting by angle first
    # removes the risk by construction instead of counting on that safety net.
    results = sorted(results, key=lambda r: r[3])

    bgr_frames     = [r[1] for r in results]
    meta_out       = [r[2] for r in results]
    angles_for_sfm = [r[3] for r in results]
    # Sharpness weights: sharper frames dominate where projections overlap.
    # Normalised to the sweep's own best frame; floor keeps every retained
    # frame contributing (the blur filter above already dropped the smear).
    kept_laps = [float(r[2].get('laplacianScore') or 0.0) for r in results]
    lap_top   = max(kept_laps) or 1.0
    frame_wts = [max(0.3, l / lap_top) if l > 0 else 0.7 for l in kept_laps]
    logger.info(
        'Arc frames downloaded: %d/%d (angle-ordered, range %.1f..%.1f deg)',
        len(results), len(frames_meta_fs), min(angles_for_sfm), max(angles_for_sfm),
    )
    # Return actual physical extremes so the caller can write meaningful sweep
    # stats to Firestore (the normalised SfM angles always span ~±90° now).
    sweep_stats = {
        'arcActualLeftDeg':    round(actual_left,  1),
        'arcActualRightDeg':   round(actual_right, 1),
        'arcActualTopRollDeg': round(actual_top,   1),
    }
    return bgr_frames, meta_out, angles_for_sfm, sweep_stats, frame_wts


def _download_front_only_frames(capture_id: str, base_path: str):
    """
    Download burst stills for front_only_v1 captures.

    The Flutter FrontCaptureController uploads stills at:
      {basePath}/front_burst_amb_{idx}.jpg  (ambient / torch-off)
      {basePath}/front_burst_fl_{idx}.jpg   (torch-lit)

    Returns (frames, frame_meta, actual_angles, ambient_frames, flash_frames)
    where all angles are 0° (face-on). The best (sharpest) single frame is used
    as the primary; all frames are also returned in ambient_frames / flash_frames
    so the deepFuse variant can denoise the burst.
    """
    db, _ = _get_firebase()
    doc_dict = db.collection('captures').document(capture_id).get().to_dict() or {}
    frames_meta = doc_dict.get('frames', [])

    if not frames_meta:
        raise CaptureQualityError(f'No frames metadata for front_only capture {capture_id}')

    def _sort_key(e):
        return float(e.get('laplacianScore') or 0.0)

    amb_entries = sorted([e for e in frames_meta if not e.get('flashOn')],
                         key=_sort_key, reverse=True)
    fl_entries  = sorted([e for e in frames_meta if e.get('flashOn')],
                         key=_sort_key, reverse=True)

    def _load(entry):
        arr = _decode_image(_download_storage_file(entry['path']))
        h, w = arr.shape[:2]
        side = min(h, w)
        return arr[(h - side) // 2:(h - side) // 2 + side,
                   (w - side) // 2:(w - side) // 2 + side]

    amb_frames_list, fl_frames_list = [], []
    for e in amb_entries:
        try:
            amb_frames_list.append(_load(e))
        except Exception as exc:
            logger.warning('front_only: ambient frame %s failed: %s', e.get('path'), exc)
    for e in fl_entries:
        try:
            fl_frames_list.append(_load(e))
        except Exception as exc:
            logger.warning('front_only: flash frame %s failed: %s', e.get('path'), exc)

    if not amb_frames_list and not fl_frames_list:
        raise CaptureQualityError('No usable frames in front_only capture')

    # Best single frame (sharpest ambient preferred, else sharpest flash).
    # TESTED 2026-07-24 and REJECTED: tried comparing the sharpest ambient
    # against the sharpest flash by client laplacianScore and picking
    # whichever reads higher, instead of always preferring ambient. Real
    # data refuted it -- of the 5 real library captures where this would
    # have flipped the selection, only 1 improved (+18 real NFIQ2) and 4
    # REGRESSED (-2, -4, -12, -13). The client laplacianScore is a known-
    # unreliable whole-preview-frame proxy (see afis_print.py's own
    # _ridge_energy comment) -- reading "sharper" for flash doesn't mean
    # it's genuinely better raw material, and ambient-preferred stays the
    # right default. Do not re-attempt this exact swap without new data.
    best_arr = amb_frames_list[0] if amb_frames_list else fl_frames_list[0]

    frames     = [best_arr]
    meta_out   = [{'angle': 'front', 'laplacianScore': 0, 'frameSource': 'front_only'}]
    angles_out = [0.0]

    # Per-angle lists indexed to match frames[] — single entry at position 0.
    ambient_frames_out = [amb_frames_list[0]] if amb_frames_list else [None]
    flash_frames_out   = [fl_frames_list[0]]  if fl_frames_list  else [None]

    logger.info('front_only: %d ambient + %d flash frames loaded',
                len(amb_frames_list), len(fl_frames_list))
    return frames, meta_out, angles_out, ambient_frames_out, flash_frames_out


def _download_oscillating_frames(capture_id: str, base_path: str):
    """
    Download frames for the 8-phase oscillating capture mode (front <-> left
    <-> right <-> top — see the Flutter OscillatingCaptureController for the
    capture geometry).

    FRONT/LEFT/RIGHT are a single continuous pitch-axis sweep and their
    angleDeg values are directly comparable. TOP is measured on roll — a
    physically different rotation (tilting the phone's top up/back, not
    panning left-right) — so its angleDeg values live on a DIFFERENT axis
    entirely and are not comparable to the sweep's. Mixing them into one
    bin-range computation would misattribute TOP frames to wherever their
    roll value numerically falls on the pitch scale (e.g. a ~20° roll
    landing inside the RIGHT leg's bin range) — the same bug
    _download_arc_frames' docstring documents for its own TOP leg, fixed
    there via a leg-aware nominal angle. TOP frames are identified via the
    Firestore `phases[]` array (whichever phaseNumber has label == 'TOP')
    and excluded from the sweep's angle-range computation; they get one
    dedicated bin at a small nominal angle near FRONT instead of their raw
    roll value.

    Unlike the four-angle/arc-sweep flows this mode captures densely: up to
    ~400 frames mixing full-resolution ISP burst stills (at the 4 hold
    positions) with preview-stream frames extracted continuously during the
    guided transitions between them. Feeding all of that into
    reconstruct_and_unwrap directly would blow the Cloud Function's
    time/memory budget (full-res JPEG decode + segmentation per frame) for
    no reconstruction benefit — frames a couple of degrees apart carry
    near-duplicate information.

    This bins the frames by angle (BIN_WIDTH_DEG-wide bins spanning the
    sweep's observed angle range) and keeps at most one frame per
    (bin, flashOn) cell: a burst-anchor frame if the bin contains one (real
    ISP quality, captured during a steady hold — always preferred over a
    transition frame), else the sharpest frame in the bin by the client's
    reported laplacianScore. When a bin has both an ambient and a flash-lit
    frame, both are kept and threaded through as an ambient/flash pair so
    flash-diff segmentation can run (see sfm_pipeline._segment_via_flash_diff
    — the single most reliable segmentation tier on every other capture
    mode). Burst-anchor frames are weighted more heavily than
    transition-derived ones in the final projection (steady real-ISP still
    vs. best-effort preview-stream frame grabbed mid-motion).

    Raises CaptureQualityError if fewer than 5 SWEEP bins have a usable
    frame — SfM needs real angular spread to stitch. TOP's single bin
    doesn't count toward that floor (it's auxiliary texture, not part of
    the azimuthal sweep the reconstruction actually needs coverage of).
    """
    db, _ = _get_firebase()
    doc = db.collection('captures').document(capture_id).get()
    doc_dict = doc.to_dict() or {}
    frames_meta_fs = doc_dict.get('frames', [])
    if not frames_meta_fs:
        raise CaptureQualityError(f'No frames[] metadata for oscillating capture {capture_id}')

    BIN_WIDTH_DEG     = 5.0
    BURST_WEIGHT      = 1.0
    TRANSITION_WEIGHT = 0.7
    TOP_NOMINAL_DEG   = 5.0  # placed just past FRONT (0°), distinguishable from the sweep

    phases_meta = doc_dict.get('phases', [])
    top_phase_numbers = {
        int(p.get('phaseNumber', 0)) for p in phases_meta if p.get('label') == 'TOP'
    }

    sweep_meta = [e for e in frames_meta_fs if int(e.get('phaseNumber', 0)) not in top_phase_numbers]
    top_meta   = [e for e in frames_meta_fs if int(e.get('phaseNumber', 0)) in top_phase_numbers]

    if not sweep_meta:
        raise CaptureQualityError(f'No non-TOP (sweep) frames for oscillating capture {capture_id}')

    angles = [float(e.get('angleDeg', 0.0)) for e in sweep_meta]
    lo, hi = min(angles), max(angles)
    n_bins = max(1, int((hi - lo) / BIN_WIDTH_DEG) + 2)
    top_bin = n_bins  # one dedicated bin, past the sweep's bin range

    def _bin_of(angle: float) -> int:
        return int(np.clip(round((angle - lo) / BIN_WIDTH_DEG), 0, n_bins - 1))

    # Group Firestore entries by (bin, flashOn) so a bin can retain a real
    # ambient/flash pair when both exist. Sweep entries bin by their real
    # angleDeg; TOP entries all collapse into the single top_bin regardless
    # of their (roll-axis, not-comparable) angleDeg value.
    buckets: dict = {}
    for e in sweep_meta:
        key = (_bin_of(float(e.get('angleDeg', 0.0))), bool(e.get('flashOn', False)))
        buckets.setdefault(key, []).append(e)
    for e in top_meta:
        key = (top_bin, bool(e.get('flashOn', False)))
        buckets.setdefault(key, []).append(e)

    def _pick_best(entries: list) -> dict:
        # Burst anchors (real ISP stills) always outrank transition frames;
        # within the same tier, prefer the highest reported sharpness.
        return max(
            entries,
            key=lambda e: (e.get('type') == 'burst', float(e.get('laplacianScore') or 0.0)),
        )

    bin_entries: dict = {}  # bin -> {'amb': entry, 'fl': entry}
    for (b, flash_on), entries in buckets.items():
        best = _pick_best(entries)
        bin_entries.setdefault(b, {})['fl' if flash_on else 'amb'] = best

    def _fetch(bin_idx: int, tag: str, entry: dict):
        try:
            img_bytes = _download_storage_file(entry['path'])
            arr = _decode_image(img_bytes)
            h, w = arr.shape[:2]
            side = min(h, w)
            arr = arr[(h - side) // 2:(h - side) // 2 + side,
                      (w - side) // 2:(w - side) // 2 + side]
            return bin_idx, tag, arr, entry
        except Exception as e:
            logger.warning(
                'Oscillating frame bin=%d tag=%s failed to download/decode: %s', bin_idx, tag, e
            )
            return bin_idx, tag, None, entry

    fetch_jobs = [
        (b, tag, entry) for b, tags in bin_entries.items() for tag, entry in tags.items()
    ]
    with ThreadPoolExecutor(max_workers=min(max(len(fetch_jobs), 1), 12)) as ex:
        futures = [ex.submit(_fetch, b, tag, entry) for b, tag, entry in fetch_jobs]
        raw = [f.result() for f in as_completed(futures)]

    by_bin: dict = {}  # bin -> {'amb': (arr, entry), 'fl': (arr, entry)}
    for bin_idx, tag, arr, entry in raw:
        if arr is None:
            continue
        by_bin.setdefault(bin_idx, {})[tag] = (arr, entry)

    sweep_bins_downloaded = len({b for b in by_bin if b != top_bin})
    if sweep_bins_downloaded < 5:
        raise CaptureQualityError(
            f'Oscillating capture has only {sweep_bins_downloaded} usable sweep angle bins '
            f'(need >=5) for {capture_id}'
        )

    results = []
    for b in sorted(by_bin.keys()):
        pair = by_bin[b]
        amb = pair.get('amb')
        fl = pair.get('fl')
        if amb and fl:
            # Primary projected frame is whichever of the pair is the burst
            # anchor; if neither/both are, prefer ambient (matches the other
            # flows' convention of scoring ambient brightness, not torch-lit).
            primary_arr, primary_entry = (
                fl if fl[1].get('type') == 'burst' and amb[1].get('type') != 'burst' else amb
            )
            ambient_arr, flash_arr = amb[0], fl[0]
        elif amb:
            primary_arr, primary_entry = amb
            ambient_arr, flash_arr = amb[0], None
        else:
            primary_arr, primary_entry = fl
            ambient_arr, flash_arr = None, fl[0]

        # TOP's raw angleDeg is roll-axis and not comparable to the sweep's
        # pitch-axis scale (see docstring) -- use the fixed nominal instead.
        angle = TOP_NOMINAL_DEG if b == top_bin else float(primary_entry.get('angleDeg', 0.0))
        is_burst = primary_entry.get('type') == 'burst'
        results.append({
            'angle': angle,
            'frame': primary_arr,
            'ambient': ambient_arr,
            'flash': flash_arr,
            'weight': BURST_WEIGHT if is_burst else TRANSITION_WEIGHT,
            'meta': {
                'angle': 'osc_top' if b == top_bin else f'osc_bin_{b}',
                'binIndex': b,
                'storagePath': primary_entry.get('path'),
                'laplacianScore': primary_entry.get('laplacianScore'),
                'frameSource': primary_entry.get('type'),
            },
        })

    results.sort(key=lambda r: r['angle'])

    bgr_frames     = [r['frame'] for r in results]
    ambient_frames = [r['ambient'] for r in results]
    flash_frames   = [r['flash'] for r in results]
    angles_for_sfm = [r['angle'] for r in results]
    frame_weights  = [r['weight'] for r in results]
    meta_out       = [r['meta'] for r in results]

    osc_stats = {
        'oscBinsUsed':       len(results),
        'oscAngleRangeDeg':  [round(lo, 1), round(hi, 1)],
        'oscBurstAnchors':   sum(1 for r in results if r['weight'] == BURST_WEIGHT),
        'oscTopIncluded':    top_bin in by_bin,
    }
    logger.info(
        'Oscillating frames binned: %d sweep bins (%.1f..%.1f deg) + top=%s, %d burst-anchored',
        sweep_bins_downloaded, lo, hi, osc_stats['oscTopIncluded'], osc_stats['oscBurstAnchors'],
    )
    return bgr_frames, meta_out, angles_for_sfm, osc_stats, frame_weights, ambient_frames, flash_frames


def _download_front_burst(capture_id: str, face_yaw_deg: float = 8.0,
                          top_k: int = 6):
    """Preserve the RAW near-face-on front burst for deep-fusion.

    The oscillating downloader bins the ~400 captured frames down to one still
    per (angle-bin, illumination) — great for SfM, but it throws away the rest
    of the front burst (5–11 shots per hold are uploaded to Storage). Deep
    fusion wants ALL of them: aligning+averaging every same-pose ambient shot,
    and every same-pose flash shot, denoises each illumination before they're
    fused, worth +2.5–8.5 NFIQ over the single sharpest shot.

    Returns (ambient_shots, flash_shots, ambient_gyros, flash_gyros): the
    first two are flat lists of centre-cropped grayscale arrays for the
    sharpest `top_k` near-face-on shots per illumination (burst-anchor stills
    preferred, then client laplacianScore); the gyro lists are index-aligned
    device-rotation-rate (deg/s) readings for those same shots, added
    2026-08-06 (client now writes `gyroMagnitudeDegPerSec` per frame entry --
    see front_capture_controller.dart) so afis_print.generate()'s fusion
    functions have real per-frame motion context, not just pixels. `None` per
    entry on older captures from before this field existed -- every consumer
    treats that as neutral/unweighted, never an error.
    Returns ([], [], [], []) on any error — the deep-fuse variant then
    self-skips."""
    try:
        db, _ = _get_firebase()
        doc = db.collection('captures').document(capture_id).get()
        doc_dict = doc.to_dict() or {}
        frames_meta = doc_dict.get('frames', [])
        phases_meta = doc_dict.get('phases', [])
        top_pn = {int(p.get('phaseNumber', 0)) for p in phases_meta
                  if p.get('label') == 'TOP'}
        face = [e for e in frames_meta
                if int(e.get('phaseNumber', 0)) not in top_pn
                and abs(float(e.get('angleDeg', 0.0))) <= face_yaw_deg]
        if not face:
            return [], [], [], []

        def _rank(e):
            return (e.get('type') == 'burst', float(e.get('laplacianScore') or 0.0))

        def _collect(flash_on: bool):
            cell = sorted([e for e in face if bool(e.get('flashOn', False)) == flash_on],
                          key=_rank, reverse=True)[:top_k]
            imgs, gyros = [], []
            for e in cell:
                try:
                    arr = _decode_image(_download_storage_file(e['path']))
                    h, w = arr.shape[:2]
                    side = min(h, w)
                    imgs.append(arr[(h - side) // 2:(h - side) // 2 + side,
                                     (w - side) // 2:(w - side) // 2 + side])
                    gy = e.get('gyroMagnitudeDegPerSec')
                    gyros.append(float(gy) if gy is not None else None)
                except Exception as e2:                       # noqa: BLE001
                    logger.warning('front-burst shot download failed: %s', e2)
            return imgs, gyros

        amb_imgs, amb_gyros = _collect(False)
        fla_imgs, fla_gyros = _collect(True)
        return amb_imgs, fla_imgs, amb_gyros, fla_gyros
    except Exception as exc:                                  # noqa: BLE001
        logger.warning('front-burst preservation skipped: %s', exc)
        return [], [], [], []


def _extract_orbit_angles(capture_id: str) -> dict:
    """
    Read per-angle device orbit angles from the Firestore captures document.

    The Flutter app stores the IMU orbit angle at the moment each burst was
    captured under frames[*].deviceOrbitDegrees alongside the zone label
    frames[*].zoneHint (e.g. 'angle_left').  We take the first ambient frame
    for each angle — all frames in a burst share the same orbit reading.

    Returns {angle_name: orbit_deg} for whichever angles have data.
    Silently returns {} on any error (Firestore unavailable, missing field).
    """
    try:
        db, _ = _get_firebase()
        doc        = db.collection('captures').document(capture_id).get()
        frames_meta = (doc.to_dict() or {}).get('frames', [])
        orbits: dict = {}
        for frame in frames_meta:
            zone  = frame.get('zoneHint', '')
            orbit = frame.get('deviceOrbitDegrees')
            if orbit is None:
                continue
            for name in _ANGLE_NAMES:
                if zone == f'angle_{name}' and name not in orbits:
                    orbits[name] = float(orbit)
                    break
        return orbits
    except Exception as exc:
        logger.warning(f"Could not read orbit angles from Firestore: {exc}")
        return {}


def _extract_target_angles(capture_id: str) -> dict:
    """
    Read the capture protocol's per-angle orbit TARGETS from the client's
    frame metadata (frames[*].targetAngleDegrees keyed by zoneHint), falling
    back to the current protocol constants. These are the angles the capture
    UI actually guides the user to — the correct cylindrical seed when IMU
    orbit telemetry is absent or dead (deviceOrbitDegrees=0.0 on every frame,
    which is what production clients currently send).

    'top' is a roll-axis motion with no azimuthal displacement — seeded at 0°.
    """
    # Signs follow the client's targetAngleDegrees convention (observed on
    # production capture docs: right=+32, left=−32, top=−20 roll).
    fallback = {'front': 0.0, 'right': 32.0, 'top': 0.0, 'left': -32.0}
    try:
        db, _ = _get_firebase()
        doc         = db.collection('captures').document(capture_id).get()
        frames_meta = (doc.to_dict() or {}).get('frames', [])
        targets: dict = {}
        for frame in frames_meta:
            zone   = frame.get('zoneHint', '')
            target = frame.get('targetAngleDegrees')
            if target is None:
                continue
            for name in _ANGLE_NAMES:
                if zone == f'angle_{name}' and name not in targets:
                    # Roll-axis top has no azimuthal meaning; pin to 0°.
                    targets[name] = 0.0 if name == 'top' else float(target)
                    break
        return {**fallback, **targets}
    except Exception as exc:
        logger.warning(f"Could not read target angles from Firestore: {exc}")
        return fallback


def _download_storage_file(path: str) -> bytes:
    _, bucket = _get_firebase()
    return bucket.blob(path).download_as_bytes(timeout=60)


def _decode_image(img_bytes: bytes) -> np.ndarray:
    """Decode a frame uploaded by the Flutter capture service.
    The upload is labelled image/jpeg but the bytes are the raw Y-plane
    from CameraImage.planes[0] — uncompressed grayscale at whatever
    resolution the device camera reported.
    """
    arr = np.frombuffer(img_bytes, dtype=np.uint8)
    bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if bgr is not None:
        return bgr

    # Raw Y-plane fallback: match byte count against standard phone resolutions
    n = len(img_bytes)
    for w, h in _KNOWN_DIMS:
        if w * h == n:
            gray = arr.reshape(h, w)
            logger.info(f'Decoded raw Y-plane {w}×{h}')
            return cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)

    raise ValueError(
        f'Failed to decode frame: {n} bytes — not JPEG and no standard '
        f'Y-plane dimensions match. Add dimensions to _KNOWN_DIMS.'
    )


# ── NFIQ scoring ──────────────────────────────────────────────────────────────

def _score_nfiq(image: np.ndarray, sfm_coverage: float = 1.0) -> dict:
    try:
        _init_heavy_deps()
        from PIL import Image as PILImage

        session     = _get_nfiq_session()
        input_name  = session.get_inputs()[0].name
        output_name = session.get_outputs()[0].name

        # Coverage-aware crop: central region has real ridge data; periphery is
        # gap-filled KDTree noise. Crop to sqrt(coverage) fraction of each axis,
        # clamped so we keep at least 75% of the image even for low coverage.
        crop_frac = float(min(1.0, max(0.75, sfm_coverage ** 0.5 + 0.05)))
        if crop_frac < 0.99:
            h, w  = image.shape[:2]
            ch    = int(h * crop_frac)
            cw    = int(w * crop_frac)
            y0    = (h - ch) // 2
            x0    = (w - cw) // 2
            image = image[y0:y0 + ch, x0:x0 + cw]

        def _score_once(img: np.ndarray) -> float:
            # Two-step downscale for large prints: area-average to ~700px first,
            # THEN LANCZOS to 500x500. A single big LANCZOS jump from a
            # ~1000-2000px enhanced print aliases the fine ridges; the
            # intermediate area-average is the standard antialiasing path and
            # yields a measurably cleaner 500x500 the model actually sees
            # (+0.6-0.9 NFIQ observed on real captures, more on larger prints).
            if max(img.shape[:2]) > _SCORE_PRESCALE_PX * 1.15:
                sc  = _SCORE_PRESCALE_PX / max(img.shape[:2])
                img = cv2.resize(img, (max(1, int(img.shape[1] * sc)),
                                       max(1, int(img.shape[0] * sc))),
                                 interpolation=cv2.INTER_AREA)
            pil    = PILImage.fromarray(img).convert('L').resize(_TARGET_SIZE, PILImage.LANCZOS)
            arr    = np.array(pil, dtype=np.float32) / 255.0
            tensor = arr[np.newaxis, np.newaxis, :, :]
            result = session.run([output_name], {input_name: tensor})[0]
            return float(np.clip(result.flatten()[0], 0.0, 1.0))

        lo, hi = int(np.percentile(image, 1)), int(np.percentile(image, 99))
        v2 = np.clip((image.astype(np.float32) - lo) / max(hi - lo, 1) * 255, 0, 255).astype(np.uint8) if hi > lo else image
        v3 = cv2.createCLAHE(clipLimit=1.5, tileGridSize=(4, 4)).apply(image)   # tile=4 (optimizer winner)
        v4 = cv2.bilateralFilter(image, d=9, sigmaColor=35, sigmaSpace=35)
        v5 = np.clip((image.astype(np.float32) / 255.0) ** 0.8 * 255, 0, 255).astype(np.uint8)
        blur6 = cv2.GaussianBlur(v2, (0, 0), 1.5)
        v6 = np.clip(v2.astype(np.float32) * 1.4 - blur6.astype(np.float32) * 0.4, 0, 255).astype(np.uint8)

        with ThreadPoolExecutor(max_workers=6) as ex:
            f1 = ex.submit(_score_once, image)
            f2 = ex.submit(_score_once, v2)
            f3 = ex.submit(_score_once, v3)
            f4 = ex.submit(_score_once, v4)
            f5 = ex.submit(_score_once, v5)
            f6 = ex.submit(_score_once, v6)
            s1, s2, s3, s4, s5, s6 = (
                f1.result(), f2.result(), f3.result(),
                f4.result(), f5.result(), f6.result(),
            )

        scores     = [s1, s2, s3, s4, s5, s6]
        confidence = max(scores)
        winner_idx = scores.index(confidence)
        names      = ('raw', 'stretched', 'clahe', 'bilateral', 'gamma', 'unsharp')
        images     = (image, v2, v3, v4, v5, v6)
        winner     = names[winner_idx]
        best_image = images[winner_idx]
        logger.info(
            f"NFIQ TTA6: {s1*100:.1f}/{s2*100:.1f}/{s3*100:.1f}/"
            f"{s4*100:.1f}/{s5*100:.1f}/{s6*100:.1f} -> {confidence*100:.1f} ({winner})"
        )
        return {
            'nfiq_score': round(confidence * 100.0, 2),
            'best_image': best_image,
            'tta_scores': {
                'raw':            round(s1 * 100.0, 1),
                'stretched':      round(s2 * 100.0, 1),
                'clahe':          round(s3 * 100.0, 1),
                'bilateral':      round(s4 * 100.0, 1),
                'gamma':          round(s5 * 100.0, 1),
                'unsharp':        round(s6 * 100.0, 1),
                'winningVariant': winner,
            },
            'error': None,
        }
    except Exception as e:
        logger.error(f"NFIQ error: {e}")
        return {'nfiq_score': 0.0, 'error': str(e)}


def _call_with_hard_deadline(fn, *args, timeout_sec: float, **kwargs):
    """Runs `fn(*args, **kwargs)` but stops WAITING on it after `timeout_sec`
    -- returns None on timeout instead of blocking forever, same "can only
    skip a candidate, never hang the request" contract as every other
    optional signal in this pipeline.

    REAL BUG this fixes (found 2026-08-08 from a live stuck capture,
    219939d0): the AFIS variant loop's own `_variants_deadline` wall-clock
    budget (2026-07-16, closed out the ORIGINAL deepFuse/deepMaxc 15-minute
    outage) only ever checks elapsed time BETWEEN variants -- it cannot
    interrupt a single variant's `afis_print.generate()` call that is
    already in progress. `fuseAvg`/`fuseMaxc`/`fuseSoft`'s own per-pair
    sweep (added after that fix, calling `_fuse_flash_ambient`'s own ECC
    alignment once per flash-bracket frame) has the exact same structural
    gap one level deeper: its per-pair deadline check (main.py, the
    `_fuse_fl_list` loop) can only skip a pair BEFORE it starts, not abort
    one already running. A single poorly-correlated pair reproduced this
    project's original failure mode through a code path the original fix
    never covered -- confirmed via Cloud Logging on the live capture: focus
    Stack finished at 44:38, nothing else logged until "time budget
    exceeded" fired (naming fuseMaxc, i.e. right after fuseAvg) at 47:02 --
    a single ~144s gap, consistent with one or more of fuseAvg's flash-
    bracket pairs blocking well past its share of the 70s budget, pushing
    the WHOLE request (which has its own separate, harder 300s Cloud Run
    ceiling) past that hard limit with no graceful failure -- the capture
    is silently killed mid-flight and stuck at status=enhancing forever.

    Runs `fn` in a single-worker background thread and calls `.result()`
    with a timeout instead of a bare (blocking-forever) call. On timeout,
    does NOT wait for the thread to actually finish (`shutdown(wait=False)`)
    -- Python cannot forcibly kill a running thread, but the caller no
    longer blocks on it; the orphaned thread's result is simply discarded
    once it eventually completes. This mirrors the same "abandon, don't
    wait forever" pattern already used capture-side for uploads
    (`_uploadWithRetry`'s cancellable UploadTask) and is the standard way
    to bound a call to code with no cooperative-cancellation hook of its
    own (`afis_print.generate()`/OpenCV are synchronous, CPU-bound, and
    have no internal timeout parameter to pass through)."""
    ex = ThreadPoolExecutor(max_workers=1)
    fut = ex.submit(fn, *args, **kwargs)
    try:
        return fut.result(timeout=max(0.1, timeout_sec))
    except Exception as e:   # noqa: BLE001 — TimeoutError or any exception from fn itself
        logger.warning('_call_with_hard_deadline: %s did not complete within %.1fs (%s)',
                        getattr(fn, '__name__', repr(fn)), timeout_sec, e)
        return None
    finally:
        ex.shutdown(wait=False)


# ── Extended Henry Classification ─────────────────────────────────────────────
# Codes:  PA  Plain Arch       TA  Tented Arch
#         UL  Ulnar Loop       RL  Radial Loop
#         PW  Plain Whorl      CPW Central Pocket Loop Whorl
#         DLW Double Loop      AW  Accidental Whorl
#         U   Unknown

_HB = 16    # orientation block size (px) — 256-px image → 16×16 block grid
_HR = 2     # Poincaré trace radius (blocks)
_HT = 0.45  # singular point threshold (|score| must exceed this)


def _henry_preprocess(image: np.ndarray) -> np.ndarray:
    img = cv2.resize(image, (256, 256), interpolation=cv2.INTER_AREA)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    return clahe.apply(img.astype(np.uint8))


def _henry_orientation(img: np.ndarray, block: int) -> np.ndarray:
    """
    Block-wise ridge orientation via double-angle Sobel averaging.
    Returns (R, C) float32 array with values in [-π/2, π/2].
    Using the doubled-angle trick avoids ±π aliasing when averaging orientations.
    """
    H, W = img.shape
    R, C = H // block, W // block
    f  = img.astype(np.float32)
    gx = cv2.Sobel(f, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(f, cv2.CV_32F, 0, 1, ksize=3)
    gxx = gx * gx - gy * gy   # |G|² cos2θ
    gxy = 2.0 * gx * gy        # |G|² sin2θ
    orient = np.zeros((R, C), np.float32)
    for r in range(R):
        for c in range(C):
            y0, y1 = r * block, (r + 1) * block
            x0, x1 = c * block, (c + 1) * block
            orient[r, c] = 0.5 * np.arctan2(
                float(gxy[y0:y1, x0:x1].sum()),
                float(gxx[y0:y1, x0:x1].sum()),
            )
    return orient


def _poincare_at(orient: np.ndarray, r: int, c: int, radius: int) -> float:
    """
    Poincaré index at grid cell (r, c). Traces 8 equally-spaced points around a
    circle of `radius` cells and sums wrapped angular differences in orientation.

    Return value (in our π-periodic convention):
        ≈ +1  →  core   (ridges rotate +π around this point)
        ≈ -1  →  delta  (ridges rotate -π around this point)
        ≈  0  →  ordinary point
    """
    R, C = orient.shape
    circle_angles = np.linspace(0.0, 2.0 * np.pi, 9)[:-1]
    pts = []
    for a in circle_angles:
        ri = int(round(r + radius * np.sin(a)))
        ci = int(round(c + radius * np.cos(a)))
        pts.append(orient[max(0, min(R - 1, ri)), max(0, min(C - 1, ci))])
    total = 0.0
    for i in range(len(pts)):
        d = pts[(i + 1) % len(pts)] - pts[i]
        # Wrap difference to [-π/2, π/2] (orientation is π-periodic)
        d = (d + np.pi / 2.0) % np.pi - np.pi / 2.0
        total += d
    return total / np.pi


def _find_singular(orient: np.ndarray, radius: int,
                   thresh: float) -> list[tuple[int, int, str]]:
    """
    Locate cores and deltas via Poincaré index + non-maximum suppression.
    Returns list of (row, col, 'core'|'delta').
    """
    R, C = orient.shape
    margin = radius + 1
    scores = np.zeros_like(orient)
    for r in range(margin, R - margin):
        for c in range(margin, C - margin):
            scores[r, c] = _poincare_at(orient, r, c, radius)

    singular: list[tuple[int, int, str]] = []
    used = np.zeros((R, C), bool)

    def _nms_pass(sorted_indices, sign: int, label: str) -> None:
        for idx in sorted_indices:
            r, c = divmod(int(idx), C)
            val = scores[r, c]
            if sign * val < thresh:
                break
            if used[r, c]:
                continue
            singular.append((r, c, label))
            r0, r1 = max(0, r - radius), min(R, r + radius + 1)
            c0, c1 = max(0, c - radius), min(C, c + radius + 1)
            used[r0:r1, c0:c1] = True

    flat = scores.ravel()
    _nms_pass(np.argsort(-flat),  +1, 'core')   # highest scores first; break when val < +thresh
    used[:] = False
    _nms_pass(np.argsort(flat),   -1, 'delta')  # lowest (most negative) first; break when val > -thresh

    return singular


def _classify_arch(orient: np.ndarray) -> str:
    """
    Distinguish Plain Arch (PA) from Tented Arch (TA).
    Tented arches have a steep upthrust at the centre — the local orientation
    at the mid-column is significantly more vertical (|angle| > 30°).
    """
    R, C = orient.shape
    rm, cm = R // 2, C // 2
    # 3×3 block around the centre cell
    centre = orient[max(0, rm - 1):rm + 2, max(0, cm - 1):cm + 2]
    mean_abs_angle = float(np.mean(np.abs(centre)))
    return 'TA' if mean_abs_angle > np.radians(30) else 'PA'


def _classify_loop(deltas: list[tuple[int, int]], orient: np.ndarray) -> str:
    """
    Ulnar Loop (UL) vs Radial Loop (RL) from delta position.

    In our cylindrical superprint the front of the thumb is centred; left and
    right flank sides of the image. For the right thumb (which ClearBridge
    captures), the ulnar side is the left half of the print:
        delta left  of centre → loop opens right (ulnar)  → UL
        delta right of centre → loop opens left  (radial) → RL
    """
    _, C = orient.shape
    dr, dc = deltas[0]
    return 'UL' if dc < C // 2 else 'RL'


def _line_crosses_inner(d1: tuple[int, int], d2: tuple[int, int],
                        cores: list[tuple[int, int]],
                        orient: np.ndarray) -> bool:
    """
    Heuristic for Plain Whorl vs Central Pocket Loop Whorl.

    An imaginary line between the two deltas "crosses" the innermost pattern
    when the ridge flow at the midpoint of that line is perpendicular (circular)
    to the line itself — i.e. the recurving ridges cross it.

    Returns True → PW (line crosses);  False → CPW (line doesn't cross).
    """
    R, C = orient.shape
    (r1, c1), (r2, c2) = d1, d2
    rm, cm = (r1 + r2) / 2.0, (c1 + c2) / 2.0
    line_angle = np.arctan2(r2 - r1, c2 - c1)
    # Expected ridge orientation perpendicular to the delta-delta line
    perp = line_angle + np.pi / 2.0
    ri, ci = int(round(rm)), int(round(cm))
    ri = max(0, min(R - 1, ri))
    ci = max(0, min(C - 1, ci))
    ridge_angle = float(orient[ri, ci])
    diff = abs(ridge_angle - perp)
    diff = min(diff, np.pi - diff)
    return diff < np.radians(45)


def _classify_whorl(deltas: list[tuple[int, int]],
                    cores:  list[tuple[int, int]],
                    orient: np.ndarray) -> str:
    """
    Distinguish the four whorl subtypes from singular point topology:

    Plain Whorl (PW)         — 2 deltas, 1 core, delta line crosses inner circuit
    Central Pocket Loop (CPW)— 2 deltas, 1 core, inner whorl NOT crossed by line
    Double Loop (DLW)        — 2 deltas, 2+ cores (two independent loop systems)
    Accidental Whorl (AW)    — ≥3 deltas, or 2 deltas with no core (irregular)
    """
    n_d = len(deltas)
    n_c = len(cores)

    if n_d >= 3:
        return 'AW'

    # 2 deltas
    if n_c >= 2:
        return 'DLW'
    if n_c == 0:
        return 'AW'

    # 1 core — check line-crossing test
    d1, d2 = deltas[0], deltas[1]
    return 'PW' if _line_crosses_inner(d1, d2, cores, orient) else 'CPW'


def _classify_henry(image: np.ndarray) -> str:
    try:
        _init_heavy_deps()
        img    = _henry_preprocess(image)
        orient = _henry_orientation(img, _HB)
        pts    = _find_singular(orient, _HR, _HT)

        deltas = [(r, c) for r, c, t in pts if t == 'delta']
        cores  = [(r, c) for r, c, t in pts if t == 'core']

        n_d = len(deltas)
        if n_d == 0:
            return _classify_arch(orient)
        if n_d == 1:
            return _classify_loop(deltas, orient)
        return _classify_whorl(deltas, cores, orient)

    except Exception as e:
        logger.warning(f'Henry classification error: {e}')
        return 'U'


# ── Storage helpers ───────────────────────────────────────────────────────────

def _save_enhanced_flat(image: np.ndarray, user_id: str, capture_id: str) -> str | None:
    """JPEG-encode the NNS-enhanced flat print and upload to Storage. Non-blocking on failure."""
    try:
        _, bucket = _get_firebase()
        ok, buf = cv2.imencode('.jpg', image, [cv2.IMWRITE_JPEG_QUALITY, 95])
        if not ok:
            logger.warning('cv2.imencode failed for enhanced_flat.jpg')
            return None
        path = f'captures/{user_id}/{capture_id}/enhanced_flat.jpg'
        bucket.blob(path).upload_from_string(buf.tobytes(), content_type='image/jpeg')
        logger.info('Enhanced flat print saved → %s', path)
        return path
    except Exception as exc:
        logger.warning('Failed to save enhanced_flat.jpg (non-critical): %s', exc)
        return None


def _save_afis_print(image: np.ndarray, user_id: str, capture_id: str) -> str | None:
    """PNG-encode the AFIS-style binary superprint and upload to Storage.
    PNG (not JPEG): the image is bilevel, PNG is lossless and far smaller here."""
    try:
        _, bucket = _get_firebase()
        ok, buf = cv2.imencode('.png', image)
        if not ok:
            logger.warning('cv2.imencode failed for superprint_afis.png')
            return None
        path = f'captures/{user_id}/{capture_id}/superprint_afis.png'
        bucket.blob(path).upload_from_string(buf.tobytes(), content_type='image/png')
        logger.info('AFIS superprint saved → %s', path)
        return path
    except Exception as exc:
        logger.warning('Failed to save superprint_afis.png (non-critical): %s', exc)
        return None


# ── Firestore helpers ─────────────────────────────────────────────────────────

def _update_firestore(capture_id: str, data: dict, critical: bool = False) -> None:
    db, _ = _get_firebase()
    ref = db.collection('captures').document(capture_id)
    last_exc: Exception | None = None
    for attempt in range(3):
        try:
            ref.update(data)
            return
        except Exception as e:
            last_exc = e
            if attempt < 2:
                time.sleep(0.25 * (2 ** attempt))
    logger.warning(f"Firestore update failed after 3 attempts: {last_exc}")
    if critical:
        raise last_exc


def _fail(capture_id: str, reason: str) -> None:
    _update_firestore(capture_id, {
        'status':        'failed',
        'failureReason': reason[:500],
    })


def _delete_capture_frames(base_path: str) -> None:
    """Delete all raw frame blobs from Storage (POPIA data minimization).
    Called after status='scored' — the superprint + Firestore metadata are the
    durable artifacts; raw JPEG frames are no longer needed."""
    _, bucket = _get_firebase()
    blobs = list(bucket.list_blobs(prefix=base_path))
    if not blobs:
        return
    for blob in blobs:
        try:
            blob.delete()
        except Exception as exc:
            logger.warning(f'Could not delete frame {blob.name}: {exc}')
    logger.info(f'Deleted {len(blobs)} raw frames under {base_path} (POPIA minimization)')


