"""
Geometry-aware cylindrical fingerprint unwrapping — superprint pipeline.

Design rationale
----------------
Feature-based SfM (ORB/SIFT) requires ≥60% pixel overlap between adjacent frames.
The 4-view capture protocol (front/right/top/left, 90° apart) images largely
different thumb surfaces, giving near-zero pixel overlap between adjacent views.

This pipeline instead uses the KNOWN rotation angle from each capture position to
project each frame directly onto its correct location on a virtual cylinder — the
"superprint" — with no feature matching required.  The algorithm:

  1. Centre-crop all frames to squares at their native resolution.
     Camera intrinsics scale proportionally from the 512px calibration baseline.
  2. Estimate thumb cylinder radius R from the front-frame silhouette bbox width.
     Set D = fx (self-consistent: projected silhouette half-width = fx·R/fx = R).
  3. Segment the thumb in EACH frame; locate the cylinder axis as the
     BOUNDING-BOX MIDPOINT of the largest contour.
     Key: for any cylindrical cross-section at any rotation angle, the silhouette
     is symmetric about the axis, so bbox midpoint = axis projection exactly.
  4. For each frame at rotation angle φ, build the mapping:
       cylinder surface (θ, h)  →  world 3D  →  frame pixel
     using:
       Px = R·sin(θ−φ),  Py = h,  Pz = D − R·cos(θ−φ)
       px = fx·Px/Pz + tx,  py = fy·Py/Pz + ty
  5. Exclude background: accumulate only pixels inside the thumb mask.
  6. Weight each pixel by cos(θ−φ) (cosine visibility); normalise; fill gaps
     with nearest-neighbour lookup.

Coverage with 4×90° views, output θ ∈ [−120°, +120°]:
  front  (  0°): primary — full ridge detail for θ ∈ (−120°, +120°)
  right  ( 90°): fills right sector  θ ∈ (  0°, +120°)
  left   (270°): fills left sector   θ ∈ (−120°,   0°)
  top    (180°): marginal — contributes near the ±120° edges only; optional

Known limitations
-----------------
- R / D estimated heuristically from front-frame silhouette; calibration target
  at known distance would improve accuracy.
- Segmentation (CLAHE + Otsu) can fail on very dark or overexposed frames;
  fallback is full-frame mask + image centre.
- Vertical height range uses R/D from the front frame only.
"""

from __future__ import annotations

import logging
import os
from concurrent.futures import ThreadPoolExecutor
from typing import List, Optional, Tuple

import cv2
import numpy as np
from scipy.spatial import cKDTree

logger = logging.getLogger(__name__)

# ── Baseline camera intrinsics (calibrated for 512×512, ~56° HFOV) ───────────
_FX_BASE = 480.0
_FY_BASE = 480.0

# ── Output texture angular span ───────────────────────────────────────────────
_OUT_THETA_MIN = -2.0 * np.pi / 3.0   # −120°  (right/left frames cover the ±90°→±120° wings)
_OUT_THETA_MAX =  2.0 * np.pi / 3.0   # +120°

# ── Default capture angles ─────────────────────────────────────────────────────
_CAPTURE_ANGLES_DEG: List[float] = [0.0, 90.0, 180.0, 270.0]

# ── Fallback geometry (if segmentation fails entirely) ────────────────────────
_DEFAULT_R_FRAC = 0.3125   # R as fraction of frame width (≈ 160px at 512)

# ── Quality gates ─────────────────────────────────────────────────────────────
_MIN_COVERAGE      = 0.20    # minimum texture coverage after projection
_MAX_ANGLE_GAP_DEG = 120.0   # block captures sparser than this (raised from 100°:
                              # IMU-seeded angles cluster closer together than the
                              # nominal 90° steps, so inter-frame gaps can reach ~110°)

# Segmentation quality confidence weights — prior-fallback frames contribute
# less to the texture to limit background contamination from the ellipse mask.
# 'ml_model' sits between 'adaptive' and 'prior': validated against 6 real
# captures it recovers the thumb correctly in several cases that collapse
# classical thresholding to the ellipse prior, but still occasionally emits
# a spurious secondary blob, so it isn't trusted as fully as the
# photometric tiers.
_SEG_CONFIDENCE = {'flash_diff': 1.0, 'otsu': 1.0, 'adaptive': 0.85, 'center_lobe': 0.90, 'ml_model': 0.60, 'prior': 0.35}


class CaptureQualityError(Exception):
    """Raised when the cylindrical projection cannot cover enough of the output texture."""


# ── Nominal device-orbit angles (Flutter ThumbAngleService.targets) ───────────
# These are the IMU pitch/roll values the Flutter gate requires the user to
# reach before firing each capture.  They map to the canonical cylindrical
# camera positions (0°/90°/180°/270°) used in the projection model.
#
# Axis note:  left and right use the PITCH component; top uses ROLL.
#             Front uses magnitude (always near 0°, treated the same as pitch≈0).
_NOMINAL_ORBIT_DEG  = {'front': 0.0, 'right': 15.0, 'top': -20.0, 'left': -20.0}
_NOMINAL_CYL_SIGNED = {'front': 0.0, 'right': 90.0, 'top': 180.0, 'left': -90.0}


def orbit_to_cylindrical_seed(actual_orbit_deg: float, angle_name: str) -> Optional[float]:
    """
    Convert a measured device orbit angle to an initial cylindrical camera angle.

    The Flutter capture gate fires when the IMU reading is within ±12° of the
    nominal target (front=0°, right=+15°, top=−20° roll, left=−20° pitch).
    When the user fires slightly short (e.g. pitch=−17° instead of −20° for
    left), the hardcoded 270° cylindrical seed is wrong by an amount
    proportional to the shortfall.  This function scales the nominal cylindrical
    angle by the ratio (actual / nominal) so the seed reflects the real
    camera position.

    Only left and right (pitch axis) are scaled — they map directly onto the
    azimuthal (left-right wrap) axis of the cylinder.  Front is always 0°.
    Top (roll axis, orthogonal to azimuthal) stays at its nominal 180°
    because roll deviations do not have a clean azimuthal interpretation.

    Returns the seed in degrees [0, 360) or None for unknown angle names.
    Returns None when orbit data is unavailable (near-zero on a non-front angle
    where the nominal is non-zero) so main.py falls back to nominal 90°/270°.
    Clamps scale to [0.2, 1.5] to avoid seeding wild values from borderline
    captures.
    """
    if angle_name == 'front':
        return 0.0
    if angle_name == 'top':
        return 180.0   # roll axis — keep nominal
    nominal = _NOMINAL_ORBIT_DEG.get(angle_name)
    if nominal is None or abs(nominal) < 1e-3:
        return None

    # Orbit near zero for a non-front angle means the sensor didn't fire or
    # the phone didn't move (thumb-rotation capture on a device lacking
    # GAME_ROTATION_VECTOR). Fall back to nominal so the gap check passes.
    if abs(actual_orbit_deg) < 1.0:
        return None

    scale = actual_orbit_deg / nominal
    scale = max(0.2, min(1.5, scale))
    seed  = _NOMINAL_CYL_SIGNED[angle_name] * scale
    return float(seed % 360.0)


# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

def reconstruct_and_unwrap(
    frames: List[np.ndarray],
    angles_deg: Optional[List[float]] = None,
    max_angle_gap_deg: Optional[float] = None,
    thumb_width_fraction: Optional[float] = None,
    sfm_config: Optional[dict] = None,
    ambient_frames: Optional[List[Optional[np.ndarray]]] = None,
    flash_frames: Optional[List[Optional[np.ndarray]]] = None,
    frame_weights: Optional[List[float]] = None,
) -> Tuple[np.ndarray, float, List[float], dict]:
    """
    Project each view onto a virtual cylinder and return the cylindrical
    superprint of the fingerprint-bearing surface.

    Parameters
    ----------
    frames :               list of BGR or grayscale uint8 images at any resolution.
                           The first element must be the front/volar view (angle = 0°).
    angles_deg :           rotation angle in degrees for each frame.
                           Defaults to [0, 90, 180, 270].
    max_angle_gap_deg :    override the maximum allowed angle gap (default 100°).
                           Pass 185.0 to allow 3-frame captures missing the top view.
    thumb_width_fraction : normalized thumb bbox width (0-1 fraction of frame width)
                           from MediaPipe. When provided, skips in-frame silhouette
                           detection and directly sets R = fraction × out_size / 2.
    ambient_frames,
    flash_frames :         optional parallel lists (same length/order as `frames`),
                           the raw PRE-FUSION ambient and flash-lit capture for each
                           angle. `frames` may already be Mertens-fused for ridge
                           detail, but fusion blends away the exact signal
                           segmentation needs, so the raw pair is threaded through
                           separately. When both are present for a given index,
                           segmentation uses flash-minus-ambient differencing
                           (near/far separation via LED-torch inverse-square
                           falloff — the thumb is inches from the torch, the
                           background is feet away, so torch brightness contribution
                           isolates near-camera surfaces regardless of how bright the
                           background happens to be on its own) as the first,
                           most reliable segmentation tier — see
                           _segment_via_flash_diff. None entries (flash wasn't fired
                           for that angle, e.g. a bright-ambient session) fall
                           through to the existing Otsu/adaptive/ellipse-prior
                           cascade unchanged.

    Returns
    -------
    (texture, coverage, refined_angles_deg, diagnostics)
      texture is a square uint8 grayscale cylindrical map;
      coverage is the fraction [0, 1] of the output texture that was populated;
      refined_angles_deg are the per-frame angles actually used (after phase
      correlation refinement, or the input angles if refinement was skipped);
      diagnostics is a dict of internal SfM metrics for Firestore logging.
    Raises CaptureQualityError on failure.
    """
    if angles_deg is None:
        angles_deg = _CAPTURE_ANGLES_DEG[: len(frames)]
    if len(frames) != len(angles_deg):
        raise ValueError(f"len(frames)={len(frames)} != len(angles_deg)={len(angles_deg)}")

    # ── Resolve sfm_config overrides ──────────────────────────────────────────
    cfg = sfm_config or {}
    _fx_scale           = float(cfg.get('fx_scale',             1.0))
    # clahe_clip/tile/morph_ksize re-optimised via optimize_sfm.py grid search
    # over 12 real captures (2026-07): 3.0/16/auto → 3.5/4/7 raised mean NFIQ
    # 4.1 → 20.6 by making Otsu segmentation succeed where it previously fell
    # back to the ellipse prior. The auto morph kernel (≈35px at 1200px input)
    # was smoothing away the thumb/background boundary; a fixed 7px kernel
    # preserves it. fx_scale/phase_conf/seg_prior showed no signal (Δ≤0.03)
    # and keep their previous defaults.
    _clahe_clip         = float(cfg.get('clahe_clip',           3.5))
    _clahe_tile         = int(  cfg.get('clahe_tile',           4))
    _morph_ksize        = cfg.get('morph_ksize',                7)
    _phase_conf_thr     = float(cfg.get('phase_conf_threshold', 0.15))  # optimised: 0.30→0.15
    _prior_weight       = float(cfg.get('seg_prior_weight',     0.35))
    _out_theta_deg      = float(cfg.get('out_theta_deg',        120.0))
    # Adaptive output span: real capture protocols orbit far less than the
    # nominal ±120° texture span (four-angle targets are ±32°; arc sweeps
    # ±90°). A fixed ±120° span leaves the wings empty by construction,
    # cratering the coverage metric on geometrically CORRECT reconstructions
    # and filling the void with nearest-neighbour hallucination that then
    # degrades NFIQ. Span = [min(φ)−65°, max(φ)+65°] (cos²65° ≈ 0.18, past
    # which a frame's contribution is negligible), clipped to ±_out_theta_deg.
    angles_deg_signed = [((a + 180.0) % 360.0) - 180.0 for a in angles_deg]
    _span_lo = max(-_out_theta_deg, min(angles_deg_signed) - 65.0)
    _span_hi = min( _out_theta_deg, max(angles_deg_signed) + 65.0)
    if _span_hi - _span_lo < 60.0:   # degenerate — keep a sane minimum window
        mid = 0.5 * (_span_hi + _span_lo)
        _span_lo, _span_hi = mid - 30.0, mid + 30.0
    _out_theta_min      = np.radians(_span_lo)
    _out_theta_max      = np.radians(_span_hi)
    seg_conf_map        = {**_SEG_CONFIDENCE, 'prior': _prior_weight}
    fw = [float(w) for w in frame_weights] if frame_weights else [1.0] * len(frames)

    gap_limit = max_angle_gap_deg if max_angle_gap_deg is not None else _MAX_ANGLE_GAP_DEG

    # ── Angle gap check ───────────────────────────────────────────────────────
    # INTERNAL gaps only. The wrap-around gap (from the last angle back to the
    # first through the uncovered side of the cylinder) is meaningless for the
    # partial-arc captures every protocol actually produces: an arc sweep
    # spanning ±90° always has a 180° wrap gap and the four-angle protocol's
    # ±32° orbit leaves ~296° uncovered — both were guaranteed to trip a
    # wrap-inclusive check regardless of capture quality. The uncovered side
    # is handled by the adaptive output span, not by rejecting the capture.
    sorted_a = sorted(((a + 180.0) % 360.0) - 180.0 for a in angles_deg)
    gaps     = [b - a for a, b in zip(sorted_a, sorted_a[1:])] or [0.0]
    max_gap  = max(gaps)
    if max_gap > gap_limit:
        raise CaptureQualityError(
            f"Max internal angle gap {max_gap:.0f}° > {gap_limit:.0f}° — too few views."
        )

    # ── Prepare: centre-crop to square at native resolution ───────────────────
    frames = [_prepare(f) for f in frames]
    grays  = [cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) for f in frames]

    def _prep_gray(img: Optional[np.ndarray]) -> Optional[np.ndarray]:
        if img is None:
            return None
        prepped = _prepare(img if img.ndim == 3 else cv2.cvtColor(img, cv2.COLOR_GRAY2BGR))
        return cv2.cvtColor(prepped, cv2.COLOR_BGR2GRAY)

    n_frames  = len(frames)
    amb_grays = [_prep_gray(ambient_frames[i]) for i in range(n_frames)] if ambient_frames else [None] * n_frames
    fl_grays  = [_prep_gray(flash_frames[i])   for i in range(n_frames)] if flash_frames   else [None] * n_frames

    # ── Derive size-dependent intrinsics ──────────────────────────────────────
    out_size = frames[0].shape[0]
    fx, fy, ksize = _scale_params(out_size)
    fx *= _fx_scale
    fy *= _fx_scale
    if _morph_ksize is not None:
        ksize = int(_morph_ksize) | 1   # ensure odd
    cx = out_size / 2.0
    cy = out_size / 2.0

    _cl = cv2.createCLAHE(clipLimit=_clahe_clip, tileGridSize=(_clahe_tile, _clahe_tile))
    eq_grays = [_cl.apply(g) for g in grays]

    # Geometry-seed frame: closest to 0° (most face-on), not frame index 0.
    # frames[0] is the true front view for the four-angle flow (fixed
    # [0,90,180,270] ordering), but arc-sweep and the oscillating flow both
    # sort frames by angle before calling this function, so index 0 is
    # whichever frame has the MOST NEGATIVE angle (the far edge of the sweep)
    # — the worst possible view for silhouette-width geometry estimation,
    # which wants the face-on pose. Silently seeding geometry off an edge
    # view was live in production for every arc-sweep capture.
    geom_idx = min(range(len(angles_deg)), key=lambda i: abs(angles_deg[i]))
    R, D = _estimate_thumb_geometry(
        grays[geom_idx], fx, ksize, out_size, thumb_width_fraction,
        eq=eq_grays[geom_idx], clahe_clip=_clahe_clip, clahe_tile=_clahe_tile,
        ambient_gray=amb_grays[geom_idx], flash_gray=fl_grays[geom_idx],
    )
    logger.info(
        f"Frame size={out_size}  R={R:.1f}  D={D:.1f}  fx={fx:.1f}  twf={thumb_width_fraction}"
        f"  geom_seed_idx={geom_idx} (angle={angles_deg[geom_idx]:.1f}°)"
    )

    texture = np.zeros((out_size, out_size), dtype=np.float64)
    weight  = np.zeros((out_size, out_size), dtype=np.float64)

    with ThreadPoolExecutor(max_workers=len(grays)) as ex:
        seg_futures = [
            ex.submit(
                _segment_and_locate, g, ksize, cx, cy, eq_g, _clahe_clip, _clahe_tile,
                amb_grays[i], fl_grays[i],
            )
            for i, (g, eq_g) in enumerate(zip(grays, eq_grays))
        ]
        seg_results = [f.result() for f in seg_futures]

    # Vertical re-centering: align thumb axes across all frames before projection.
    # When the user tilts slightly between capture angles the thumb drifts vertically
    # (observed: 150-307px across 4 angles on 720px frames), which cuts cylindrical
    # texture coverage in half. Shifting each frame so all thumb centroids share the
    # same vertical position before projection is the single highest-leverage fix.
    ty_values = [ty for (_, _, ty, _) in seg_results]
    mean_ty   = float(np.mean(ty_values))
    max_shift = max(abs(ty - mean_ty) for ty in ty_values)
    if max_shift > 20:
        logger.info(
            f"Vertical re-centering: max_drift={max_shift:.0f}px  mean_ty={mean_ty:.0f}px"
            f"  per_frame={[round(ty) for ty in ty_values]}"
        )
        def _vshift(img: np.ndarray, s: int) -> np.ndarray:
            if s == 0:
                return img
            out = np.zeros_like(img)
            h   = img.shape[0]
            if s > 0:
                out[s:, ...] = img[:h - s, ...]
            else:
                out[:h + s, ...] = img[-s:, ...]
            return out

        new_grays    = []
        new_eq_grays = []
        new_seg      = []
        for i, (mask, tx, ty, method) in enumerate(seg_results):
            shift = int(round(mean_ty - ty))
            if abs(shift) > 5:
                new_grays.append(_vshift(grays[i], shift))
                new_eq_grays.append(_vshift(eq_grays[i], shift))
                new_mask = _vshift(mask, shift) if mask is not None else mask
                new_seg.append((new_mask, tx, mean_ty, method))
            else:
                new_grays.append(grays[i])
                new_eq_grays.append(eq_grays[i])
                new_seg.append((mask, tx, ty, method))
        grays       = new_grays
        eq_grays    = new_eq_grays
        seg_results = new_seg

    # Phase-correlation refinement uses raw grays — CLAHE alters the ridge
    # frequency spectrum and reduces correlation confidence on overlap strips.
    angles_rad          = [np.radians(a) for a in angles_deg]
    refined_rad, pairs_info, ty_corrections = _refine_angles(
        grays, seg_results, angles_rad, R, D, fx, fy, out_size,
        phase_conf_threshold=_phase_conf_thr,
        fx_scale=_fx_scale,
        out_theta_min=_out_theta_min, out_theta_max=_out_theta_max,
    )
    refined_deg  = [np.degrees(r) for r in refined_rad]
    seg_results  = [
        (mask, tx, ty + ty_corrections[i], method)
        for i, (mask, tx, ty, method) in enumerate(seg_results)
    ]

    for (mask, tx, ty, seg_method), eq_gray, phi_deg, f_w in zip(seg_results, eq_grays, refined_deg, fw):
        conf = seg_conf_map.get(seg_method, 1.0) * f_w
        logger.info(
            f"  phi={phi_deg:6.1f}°  axis=({tx:.0f},{ty:.0f})"
            f"  mask={np.mean(mask>0):.1%}  seg={seg_method}  conf={conf:.2f}"
        )
        _accumulate_frame(
            eq_gray, np.radians(phi_deg), R, D,
            fx, fy, tx, ty, out_size,
            texture, weight, mask, seg_confidence=conf,
            out_theta_min=_out_theta_min, out_theta_max=_out_theta_max,
        )

    covered = float(np.mean(weight > 0))
    logger.info(f"Texture coverage: {covered:.1%}")
    min_coverage = _MIN_COVERAGE if len(frames) == 4 else max(0.12, _MIN_COVERAGE - 0.06)
    if covered < min_coverage:
        raise CaptureQualityError(
            f"Coverage {covered:.1%} < {min_coverage:.0%} — segmentation likely failed."
        )

    valid         = weight > 0
    texels_filled = int(np.sum(~valid))
    result        = np.full((out_size, out_size), 128.0)
    result[valid] = texture[valid] / weight[valid]
    if not valid.all():
        result = _fill_gaps(result, valid)

    # ── Diagnostics — internal metrics for Firestore logging ─────────────────
    # All numeric values are cast to Python-native float/int — numpy scalars and
    # nested lists (arrays-of-arrays) are rejected by Firestore with
    # "invalid nested entity". axisPositions uses dicts instead of inner lists.
    sorted_diag = sorted(((a + 180.0) % 360.0) - 180.0 for a in angles_deg)
    angle_gaps  = [float(round(b - a, 1)) for a, b in zip(sorted_diag, sorted_diag[1:])]
    diagnostics = {
        'cylR':           float(round(R, 1)),
        'cylD':           float(round(D, 1)),
        'outThetaSpan':   [float(round(_span_lo, 1)), float(round(_span_hi, 1))],
        'segMethods':     [m for (_, _, _, m) in seg_results],
        'axisPositions':  [{'x': float(round(tx, 1)), 'y': float(round(ty, 1))} for (_, tx, ty, _) in seg_results],
        'angleGaps':      angle_gaps,
        'phaseCorrPairs': pairs_info,
        'texelsFilled':   int(texels_filled),
    }

    return np.clip(result, 0, 255).astype(np.uint8), covered, refined_deg, diagnostics


# ─────────────────────────────────────────────────────────────────────────────
# Scaling helpers
# ─────────────────────────────────────────────────────────────────────────────

def _scale_params(out_size: int) -> Tuple[float, float, int]:
    """
    Scale camera intrinsics and morphological kernel size from the 512px baseline.
    Returns (fx, fy, ksize) where ksize is the morphological structuring element size.
    """
    s     = out_size / 512.0
    fx    = _FX_BASE * s
    fy    = _FY_BASE * s
    ksize = max(5, int(round(15 * s)))
    if ksize % 2 == 0:
        ksize += 1   # ensure odd
    return fx, fy, ksize


# ─────────────────────────────────────────────────────────────────────────────
# Frame preparation
# ─────────────────────────────────────────────────────────────────────────────

def _prepare(frame: np.ndarray) -> np.ndarray:
    """Centre-crop to square at native resolution. Converts grayscale → BGR."""
    if frame.ndim == 2:
        frame = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
    h, w = frame.shape[:2]
    if h != w:
        side  = min(h, w)
        frame = frame[(h - side) // 2 : (h + side) // 2,
                      (w - side) // 2 : (w + side) // 2]
    return frame


# ─────────────────────────────────────────────────────────────────────────────
# Geometry estimation
# ─────────────────────────────────────────────────────────────────────────────

def _estimate_thumb_geometry(
    gray: np.ndarray,
    fx: float,
    ksize: int,
    out_size: int,
    thumb_width_fraction: Optional[float] = None,
    eq: Optional[np.ndarray] = None,
    clahe_clip: float = 2.0,
    clahe_tile: int = 8,
    ambient_gray: Optional[np.ndarray] = None,
    flash_gray: Optional[np.ndarray] = None,
) -> Tuple[float, float]:
    """
    Estimate R (cylinder radius) and D (camera-axis distance).

    When thumb_width_fraction is provided (MediaPipe normalized bbox width),
    use it directly: R = fraction × out_size / 2. This is more reliable than
    the in-frame silhouette detection on compressed JPEG captures.

    Otherwise, when an ambient/flash pair is available, prefer flash-minus-
    ambient differencing (see _segment_via_flash_diff) — it isolates the
    thumb by proximity to the LED torch rather than by absolute brightness,
    so it succeeds in the common real-world case where the background is
    about as bright as the thumb itself (a wall or desk under the same room
    light), which defeats a plain Otsu threshold.

    Fallback: CLAHE + Otsu threshold contour detection on the front frame.
    D = fx in both cases (self-consistent: projected half-width = fx·R/D = R).

    eq: pre-computed CLAHE-equalized image (skips internal CLAHE when provided).
    """
    if thumb_width_fraction is not None and 0.05 < thumb_width_fraction < 0.95:
        R = max(thumb_width_fraction * out_size / 2.0, 20.0)
        logger.info(f"R from MediaPipe bbox: {R:.1f}px  (fraction={thumb_width_fraction:.3f})")
        return R, fx

    def _radius_from_mask(mask: np.ndarray) -> Optional[float]:
        """Median row half-width of the mask — robust to residual hand pixels
        and protruding shaft, unlike the full bbox width (which came out ~3×
        too large on production captures where the silhouette included the
        hand: R=445px on a 1200px frame vs a ~150px true thumb radius)."""
        widths = []
        for row in mask[::4]:
            xs = np.nonzero(row)[0]
            if len(xs) > 1:
                widths.append(xs[-1] - xs[0])
        if not widths:
            return None
        r = float(np.median(widths)) / 2.0
        # Plausibility clamp: thumb pad radius is 6–30% of frame width given
        # the app's framing guide. Outside that, the mask isn't a thumb.
        lo, hi = 0.06 * mask.shape[1], 0.30 * mask.shape[1]
        return float(np.clip(r, lo, hi)) if r > 5 else None

    if ambient_gray is not None and flash_gray is not None and ambient_gray.shape == flash_gray.shape:
        fd_result = _segment_via_flash_diff(ambient_gray, flash_gray, ksize)
        if fd_result is not None:
            mask, _, _ = fd_result
            r_est = _radius_from_mask(mask)
            if r_est is not None:
                logger.info(f"R from flash-diff silhouette (median-row): {r_est:.1f}px")
                return r_est, fx

    if eq is None:
        cl = cv2.createCLAHE(clipLimit=clahe_clip, tileGridSize=(clahe_tile, clahe_tile))
        eq = cl.apply(gray)
    _, thresh = cv2.threshold(
        eq, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU
    )
    k      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ksize, ksize))
    thresh = cv2.morphologyEx(thresh, cv2.MORPH_CLOSE, k)
    thresh = cv2.morphologyEx(thresh, cv2.MORPH_OPEN,  k)

    # Prefer the isolated thumb lobe over the raw largest contour: when the
    # whole hand is in frame the largest blob's bbox width reflects the hand,
    # inflating R ~3× and breaking the cylinder scale for every frame.
    h_img, w_img = gray.shape[:2]
    lobe = _isolate_thumb_lobe(thresh, w_img / 2.0, h_img / 2.0, 0.14 * min(h_img, w_img))
    if lobe is not None:
        r_est = _radius_from_mask(lobe[0])
        if r_est is not None:
            logger.info(f"R from centre-lobe silhouette (median-row): {r_est:.1f}px")
            return r_est, fx

    cnts, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        logger.warning("Thumb silhouette not found — using default R")
        R = max(out_size * _DEFAULT_R_FRAC, 20.0)
        return R, fx

    _, _, w, _ = cv2.boundingRect(max(cnts, key=cv2.contourArea))
    R = max(w / 2.0, 20.0)
    D = fx   # self-consistent
    return R, D


# ─────────────────────────────────────────────────────────────────────────────
# Thumb segmentation
# ─────────────────────────────────────────────────────────────────────────────

def _isolate_thumb_lobe(
    binary:     np.ndarray,
    cx:         float,
    cy:         float,
    expected_r: float,
) -> Optional[Tuple[np.ndarray, float, float]]:
    """
    Isolate the thumb lobe from a skin blob that may include the whole hand.

    Real beta captures frequently show the ENTIRE hand, not just a framed
    thumb: the thumb pad thresholds cleanly (bright, near the torch) but is
    connected to the hand/wrist as one blob, so contour plausibility gates
    (area/aspect/edge checks in _pick_thumb_contour) reject it and the
    cascade collapses to the centre-ellipse prior — observed as
    seg=['otsu','prior','otsu','prior'] with axis x pinned to frame centre
    on production captures. Rather than rejecting the blob, cut the thumb
    lobe out of it:

      1. Take the connected component containing (or nearest to) the frame
         centre — the capture UI guides the thumb tip there.
      2. Constrained dilation (geodesic approximation) from that seed,
         limited to a radius κ = 2.0 × expected thumb radius, clipped inside
         the blob. The hand/wrist is further than κ from the guided tip, so
         it is excluded even though it is connected.

    Runs at 256px for speed; the result is upscaled back. Returns
    (mask, tx, ty) with the axis at the lobe's bbox midpoint, or None when
    the blob near the centre is implausibly small.
    """
    h, w = binary.shape[:2]
    SMALL = 256
    sx, sy = w / SMALL, h / SMALL
    small = cv2.resize(binary, (SMALL, SMALL), interpolation=cv2.INTER_NEAREST)
    small = (small > 0).astype(np.uint8)

    n_lab, labels = cv2.connectedComponents(small)
    if n_lab < 2:
        return None

    scx, scy = cx / sx, cy / sy
    seed_label = labels[int(np.clip(scy, 0, SMALL - 1)), int(np.clip(scx, 0, SMALL - 1))]
    if seed_label == 0:
        # Centre pixel is background — find the blob pixel nearest the centre.
        ys, xs = np.nonzero(small)
        if len(xs) == 0:
            return None
        d2 = (xs - scx) ** 2 + (ys - scy) ** 2
        i  = int(np.argmin(d2))
        # Reject if the nearest blob pixel is far from the guided position —
        # whatever thresholding found, it isn't the centred thumb.
        if d2[i] > (0.35 * SMALL) ** 2:
            return None
        seed_label = labels[ys[i], xs[i]]
        scx, scy   = float(xs[i]), float(ys[i])

    blob = (labels == seed_label).astype(np.uint8)

    # Constrained dilation from the seed: grow a disc inside the blob.
    kappa = 2.0 * expected_r / sx          # radius in small-image pixels
    kappa = float(np.clip(kappa, 12, SMALL * 0.45))
    lobe  = np.zeros_like(blob)
    cv2.circle(lobe, (int(scx), int(scy)), 3, 1, -1)
    lobe &= blob
    kern = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    for _ in range(int(kappa / 3) + 1):    # each dilation grows ~3px radius
        lobe = cv2.dilate(lobe, kern) & blob
    # Final trim: hard-clip to a κ-radius disc around the seed so a thin
    # bridge (thumb shaft) can't leak the growth into the palm.
    disc = np.zeros_like(blob)
    cv2.circle(disc, (int(scx), int(scy)), int(kappa), 1, -1)
    lobe &= disc

    if lobe.sum() < 0.005 * SMALL * SMALL:
        return None

    mask = cv2.resize(lobe * 255, (w, h), interpolation=cv2.INTER_NEAREST)
    ys, xs = np.nonzero(mask)
    tx = float((xs.min() + xs.max()) / 2.0)
    ty = float((ys.min() + ys.max()) / 2.0)
    return mask, tx, ty


def _pick_thumb_contour(cnts, frame_shape: Tuple[int, int], min_area_frac: float = 0.15):
    """
    Selects the contour most likely to be the thumb, not just the largest.

    A busy/high-contrast real-world background (a wall, door frame, blinds —
    the conditions beta testers actually capture in, as opposed to a
    controlled dark backdrop) can produce an Otsu contour LARGER than the
    thumb itself: a bright wall merging with part of the hand/wrist shadow,
    for example. The old `max(cnts, key=cv2.contourArea)` selection picked
    exactly that contour with full confidence, producing wildly wrong axis
    positions and mask coverage — observed on a real capture ranging from
    16.7% to 83.1% mask coverage across the 4 angle frames of one session,
    where the "35%" one turned out on inspection to be mostly a background
    wall with the actual thumb reduced to a tiny notch. That misplaced
    background texture then gets projected onto the cylindrical output as if
    it were ridge detail, producing the striped/non-fingerprint-looking
    result.

    The app's own capture gate guides the thumb to fill 40-75% of frame
    HEIGHT and keeps it centered (CaptureAxisController coverage gate +
    HapticGuidanceCircle framing), so a real thumb silhouette should be:
      - a plausible fraction of frame area (not near-zero, not the majority
        of the frame),
      - close to the frame center,
      - not touching 3+ of the 4 frame edges (a centered, guided thumb
        shouldn't span edge-to-edge across most of the frame the way a
        background wall/doorway often does).
    Returns None if nothing among the candidates passes these checks, which
    correctly falls through to the adaptive-threshold / centre-ellipse-prior
    cascade in _segment_and_locate instead of confidently using a bad guess.
    """
    h, w = frame_shape[:2]
    frame_area = h * w
    cx0, cy0 = w / 2.0, h / 2.0
    diag = np.hypot(cx0, cy0)

    candidates = sorted(cnts, key=cv2.contourArea, reverse=True)[:5]
    best, best_score = None, -1.0
    for c in candidates:
        area = cv2.contourArea(c)
        area_frac = area / frame_area
        # A thumb framed per the app's own coverage gate (40-75% of frame
        # HEIGHT, roughly centered) works out to roughly 15-25%+ of frame
        # AREA. Below that, what Otsu found is more likely a fragment (a
        # shadow edge, a sliver of wrist/fingers) than the actual thumb --
        # accepting it anyway is worse than the centre-ellipse prior
        # fallback, which at least covers the real (guided, centered) thumb
        # region rather than confidently projecting the wrong surface.
        if area_frac < min_area_frac:
            continue  # too small to plausibly be the whole thumb
        if area_frac > 0.75:
            continue  # implausibly large — almost certainly background bleed

        x, y, cw, ch = cv2.boundingRect(c)
        edges_touched = sum([
            x <= 2, y <= 2, x + cw >= w - 2, y + ch >= h - 2,
        ])
        if edges_touched >= 3:
            continue  # spans most of the frame — background, not a centered thumb

        # A guided, centered thumb shouldn't span nearly the full frame in
        # either dimension. This catches diagonal wall/door-frame/blinds
        # edges specifically: their axis-aligned bounding box can be as
        # "square" and "centered" as a real thumb's despite the actual
        # silhouette being a thin diagonal sliver, because the box spans
        # top-to-bottom (or side-to-side) of the frame -- something a
        # centered thumb blob never does.
        if ch > 0.85 * h or cw > 0.85 * w:
            continue  # spans nearly the full frame height or width

        # A centre-cropped thumb pad/nail view is a rounded blob -- modestly
        # taller than wide at most. A thin diagonal strip of wall, door frame,
        # or blinds edge can otherwise pass the checks above (small enough,
        # centered enough) while being nothing like a thumb's proportions.
        aspect = max(cw, ch) / max(1, min(cw, ch))
        if aspect > 2.5:
            continue  # too elongated to be a thumb silhouette

        m = cv2.moments(c)
        if m['m00'] == 0:
            continue
        ccx, ccy = m['m10'] / m['m00'], m['m01'] / m['m00']
        dist_frac = np.hypot(ccx - cx0, ccy - cy0) / diag

        # Prefer contours close to center and a plausible thumb-sized fraction
        # of the frame (~35%) over ones that are merely large.
        score = (1.0 - dist_frac) - abs(area_frac - 0.35)
        if score > best_score:
            best_score, best = score, c

    return best


def _segment_via_flash_diff(
    ambient_gray: np.ndarray,
    flash_gray:   np.ndarray,
    ksize:        int,
) -> Optional[Tuple[np.ndarray, float, float]]:
    """
    Segment via flash-minus-ambient differencing: the LED torch is inches from
    the thumb but feet from the background, so its brightness contribution
    falls off with distance squared. flash_gray - ambient_gray therefore
    isolates near-camera surfaces (the thumb, and some adjoining hand) almost
    regardless of how bright the background happens to be on its own.

    This is the tier that actually succeeds where CLAHE+Otsu, adaptive
    threshold, and even GrabCut fail on real captures: a well-lit background
    wall/desk a few feet behind the thumb can share nearly identical absolute
    brightness with the (also well-lit, torch-assisted) thumb, which defeats
    any method that thresholds on brightness alone. Verified against real
    captures where the thumb sat well off-centre in frame (breaking the
    centre-ellipse-prior fallback too) — flash-diff correctly isolated just
    the near-camera silhouette in every case, with zero background bleed,
    even when the background was individually brighter than the thumb.

    Returns None when ambient/flash shapes mismatch, the diff has no usable
    bimodal split (Otsu finds nothing), or nothing passes the plausibility
    checks (area/aspect/centeredness/edge-touching, same as the Otsu/adaptive
    tiers but with a lower minimum-area floor — see min_area_frac below) —
    callers should fall through to the Otsu/adaptive/ellipse-prior cascade
    in that case.
    """
    if ambient_gray.shape != flash_gray.shape:
        return None

    ambient_f = ambient_gray.astype(np.float32)
    flash_f   = flash_gray.astype(np.float32)

    # Brightness/contrast-match the flash frame to the ambient frame's global
    # stats before differencing. Real captures showed the camera's auto-
    # exposure sometimes compensates for the added torch light by lowering
    # gain/exposure globally during the flash burst, so the flash frame can
    # come out DARKER on average than ambient overall -- naive subtraction
    # then picks up that global AE shift instead of (or on top of) the local
    # near-camera brightening the torch actually produces. Matching mean/std
    # first isolates the local relative signal the torch-falloff cue depends on.
    fl_std = float(flash_f.std())
    fl_norm = (flash_f - flash_f.mean()) * (float(ambient_f.std()) / (fl_std + 1e-6)) + float(ambient_f.mean())

    diff = np.clip(fl_norm - ambient_f, 0, 255).astype(np.uint8)
    diff = cv2.normalize(diff, None, 0, 255, cv2.NORM_MINMAX)
    diff = cv2.GaussianBlur(diff, (9, 9), 0)
    _, diff_otsu = cv2.threshold(diff, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    k      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ksize, ksize))
    closed = cv2.morphologyEx(diff_otsu, cv2.MORPH_CLOSE, k)
    opened = cv2.morphologyEx(closed, cv2.MORPH_OPEN, k)

    # Isolate the thumb lobe from the near-camera blob. The torch lights the
    # thumb AND the hand holding it — both are "near" by the inverse-square
    # cue, so the flash-diff blob routinely includes the whole hand (observed
    # directly: the front-frame flash_diff mask on a production capture
    # covered hand + wrist, flooding the superprint with non-ridge skin).
    # The lobe cut keeps just the guided, centred thumb pad.
    h_img, w_img = ambient_gray.shape[:2]
    expected_r   = 0.14 * min(h_img, w_img)
    lobe = _isolate_thumb_lobe(opened, w_img / 2.0, h_img / 2.0, expected_r)
    if lobe is not None:
        mask, tx, ty = lobe
        k2_size = max(3, (ksize // 2) | 1)
        k2      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k2_size, k2_size))
        mask    = cv2.erode(mask, k2)
        return mask, tx, ty

    cnts, _ = cv2.findContours(opened, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return None
    # Lower area floor than the Otsu/adaptive tiers (0.08 vs 0.15): flash-diff
    # isolates by proximity to the torch rather than by brightness/texture, so
    # it doesn't pick up the small background fragments (shadow edges, wall
    # texture slivers) that motivated the stricter 0.15 floor for those tiers
    # -- a genuinely smaller thumb-only silhouette shouldn't be rejected here.
    contour = _pick_thumb_contour(cnts, ambient_gray.shape, min_area_frac=0.08)
    if contour is None:
        return None

    mask = np.zeros_like(ambient_gray)
    cv2.drawContours(mask, [contour], -1, 255, cv2.FILLED)
    k2_size = max(3, (ksize // 2) | 1)
    k2      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k2_size, k2_size))
    mask    = cv2.erode(mask, k2)

    M = cv2.moments(contour)
    if M['m00'] > 0:
        tx, ty = M['m10'] / M['m00'], M['m01'] / M['m00']
    else:
        x, y, w, h = cv2.boundingRect(contour)
        tx, ty = float(x + w / 2), float(y + h / 2)
    return mask, tx, ty


# ── ML segmentation fallback (bootstrap v1) ──────────────────────────────────
# Small U-Net (~1.94M params) trained on flash-diff pseudo-labels with
# copy-paste augmentation (230 frames from single-subject captures). Not a
# primary tier — it's a learned prior that generalizes past pure
# thresholding, tried only after Otsu/adaptive both fail and before giving
# up to the centre-ellipse guess. Optional at runtime: if the bundled ONNX
# file is missing, _get_thumb_seg_session() returns None and every caller
# falls straight through to the existing prior fallback unchanged.
_THUMB_SEG_IMG_SIZE  = 256
_THUMB_SEG_ONNX_PATH = '/tmp/thumb_seg_unet.onnx'
_thumb_seg_session      = None
_thumb_seg_unavailable  = False


def _get_thumb_seg_session():
    global _thumb_seg_session, _thumb_seg_unavailable
    if _thumb_seg_session is not None or _thumb_seg_unavailable:
        return _thumb_seg_session
    if not os.path.exists(_THUMB_SEG_ONNX_PATH):
        _thumb_seg_unavailable = True
        return None
    import onnxruntime as ort
    _thumb_seg_session = ort.InferenceSession(
        _THUMB_SEG_ONNX_PATH, providers=['CPUExecutionProvider']
    )
    logger.info("Thumb-seg ONNX session initialised")
    return _thumb_seg_session


def _segment_via_ml_model(gray: np.ndarray, ksize: int) -> Optional[Tuple[np.ndarray, float, float]]:
    """
    Segment via the bootstrap U-Net. Validated against 6 real captures:
    correctly recovers the thumb silhouette on cluttered/textured backgrounds
    (wood-plank desks, patterned wallpaper) where Otsu/adaptive collapse
    entirely — but degrades on heavy motion blur, so its output is still run
    through the same _pick_thumb_contour plausibility gate as the other
    tiers and simply returns None (falls through to the prior) when nothing
    passes.
    """
    session = _get_thumb_seg_session()
    if session is None:
        return None

    h, w = gray.shape[:2]
    small = cv2.resize(gray, (_THUMB_SEG_IMG_SIZE, _THUMB_SEG_IMG_SIZE)).astype(np.float32) / 255.0
    logits = session.run(['logits'], {'input': small[None, None, :, :]})[0][0, 0]
    probs = 1.0 / (1.0 + np.exp(-logits))
    mask_small = (probs > 0.5).astype(np.uint8) * 255
    mask_full  = cv2.resize(mask_small, (w, h), interpolation=cv2.INTER_NEAREST)

    k      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ksize, ksize))
    closed = cv2.morphologyEx(mask_full, cv2.MORPH_CLOSE, k)
    opened = cv2.morphologyEx(closed, cv2.MORPH_OPEN, k)
    cnts, _ = cv2.findContours(opened, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return None
    # Same 0.10 floor logic as the flash-diff tier (0.08) — a learned mask
    # doesn't pick up small background fragments the way brightness
    # thresholding does, so the stricter 0.15 Otsu/adaptive floor isn't needed.
    contour = _pick_thumb_contour(cnts, gray.shape, min_area_frac=0.10)
    if contour is None:
        return None

    mask = np.zeros_like(gray)
    cv2.drawContours(mask, [contour], -1, 255, cv2.FILLED)
    k2_size = max(3, (ksize // 2) | 1)
    k2      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k2_size, k2_size))
    mask    = cv2.erode(mask, k2)

    M = cv2.moments(contour)
    if M['m00'] > 0:
        tx, ty = M['m10'] / M['m00'], M['m01'] / M['m00']
    else:
        x, y, w2, h2 = cv2.boundingRect(contour)
        tx, ty = float(x + w2 / 2), float(y + h2 / 2)
    return mask, tx, ty


def _segment_and_locate(
    gray:         np.ndarray,
    ksize:        int,
    cx:           float,
    cy:           float,
    eq:           Optional[np.ndarray] = None,
    clahe_clip:   float = 2.0,
    clahe_tile:   int = 8,
    ambient_gray: Optional[np.ndarray] = None,
    flash_gray:   Optional[np.ndarray] = None,
) -> Tuple[np.ndarray, float, float, str]:
    """
    Segment the thumb and return (mask, tx, ty) where (tx, ty) is the
    cylinder axis projection = bounding-box midpoint of the silhouette.

    Four-method cascade to avoid background bleed on segmentation failure:
      0. Flash-minus-ambient differencing, when ambient_gray/flash_gray are
         both provided (near/far separation via torch inverse-square falloff
         — see _segment_via_flash_diff). Tried first: on real captures this
         succeeds in cases that defeat all three methods below, because it
         doesn't depend on the thumb being brighter (or darker) than the
         background in absolute terms, only nearer to the torch.
      1. CLAHE + Otsu (works in normal lighting)
      2. Adaptive threshold (works on low-contrast / uneven illumination)
      3. Centre-ellipse prior (guaranteed fallback — excludes frame edges)

    Previously the fallback was mask[:]=255 (full frame), which let background
    pixels contaminate the cylindrical texture. The centre-ellipse fallback
    covers ~70% of the frame area around the expected thumb region and keeps
    background outside the projected silhouette excluded.

    eq: pre-computed CLAHE-equalized image (skips internal CLAHE when provided).
    """
    if ambient_gray is not None and flash_gray is not None:
        fd_result = _segment_via_flash_diff(ambient_gray, flash_gray, ksize)
        if fd_result is not None:
            mask, tx, ty = fd_result
            return mask, tx, ty, 'flash_diff'

    if eq is None:
        cl = cv2.createCLAHE(clipLimit=clahe_clip, tileGridSize=(clahe_tile, clahe_tile))
        eq = cl.apply(gray)
    k     = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (ksize, ksize))

    def _try_contours(binary):
        closed = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, k)
        opened = cv2.morphologyEx(closed, cv2.MORPH_OPEN,  k)
        cnts, _ = cv2.findContours(opened, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not cnts:
            return None
        return _pick_thumb_contour(cnts, gray.shape)

    # Method 1: Otsu
    seg_method = 'otsu'
    _, otsu = cv2.threshold(eq, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    largest = _try_contours(otsu)

    # Method 2: Adaptive threshold (handles uneven illumination)
    if largest is None:
        block = max(ksize * 2 + 1, 31)
        if block % 2 == 0:
            block += 1
        adaptive = cv2.adaptiveThreshold(
            eq, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, block, 2
        )
        largest = _try_contours(adaptive)
        if largest is not None:
            seg_method = 'adaptive'
            logger.debug("Thumb segmentation: adaptive threshold fallback used")

    mask = np.zeros_like(gray)

    if largest is not None:
        cv2.drawContours(mask, [largest], -1, 255, cv2.FILLED)
        # Erode inward to exclude the blurry edge fringe and background pixels
        # that Otsu/adaptive may have pulled into the contour boundary.
        k2_size = max(3, (ksize // 2) | 1)
        k2      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k2_size, k2_size))
        mask    = cv2.erode(mask, k2)
        M = cv2.moments(largest)
        if M['m00'] > 0:
            tx = M['m10'] / M['m00']
            ty = M['m01'] / M['m00']
        else:
            x, y, w, h = cv2.boundingRect(largest)
            tx, ty = float(x + w / 2), float(y + h / 2)
        return mask, tx, ty, seg_method

    # Method 2.4: centre-seeded lobe extraction. The dominant real-world
    # failure is NOT "no blob found" — it's "the blob is thumb+hand and the
    # plausibility gates rightly refuse to call it a thumb". Instead of
    # rejecting, cut the thumb lobe out of the blob around the guided frame
    # centre (see _isolate_thumb_lobe). This recovers exactly the production
    # captures that used to land on 'prior' with axis pinned to frame centre.
    h_img, w_img = gray.shape[:2]
    expected_r   = 0.14 * min(h_img, w_img)
    _, otsu_raw  = cv2.threshold(eq, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    otsu_morph   = cv2.morphologyEx(otsu_raw, cv2.MORPH_CLOSE, k)
    otsu_morph   = cv2.morphologyEx(otsu_morph, cv2.MORPH_OPEN, k)
    lobe = _isolate_thumb_lobe(otsu_morph, cx, cy, expected_r)
    if lobe is not None:
        mask, tx, ty = lobe
        k2_size = max(3, (ksize // 2) | 1)
        k2      = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k2_size, k2_size))
        mask    = cv2.erode(mask, k2)
        logger.info("Thumb segmentation: centre-seeded lobe extraction used")
        return mask, tx, ty, 'center_lobe'

    # Method 2.5: ML segmentation model (bootstrap U-Net) — tried only after
    # Otsu/adaptive both fail, i.e. only when the alternative would otherwise
    # be the centre-ellipse prior. No-ops (returns None) if the bundled ONNX
    # model isn't present, so this is safe to ship ahead of the model file.
    ml_result = _segment_via_ml_model(gray, ksize)
    if ml_result is not None:
        mask, tx, ty = ml_result
        return mask, tx, ty, 'ml_model'

    # Method 3: Centre-ellipse prior — covers thumb region, excludes frame edges.
    # Better than full-frame fallback: background corners (with varied backgrounds)
    # stay excluded, keeping the texture cleaner.
    #
    # Semi-axes are sized from the actual frame width/height (not a single
    # shape[0]-derived size applied to both axes — on a 4:3 landscape frame
    # that previously made the vertical semi-axis ~96% of the frame height,
    # which on real captures pulled in most of whatever was above/below the
    # thumb). Verified against a real off-center capture: at 0.26/0.30 the
    # prior still swept in enough door-panel/wallpaper background for Gabor
    # to legitimately enhance it as ridge-like texture (it can't tell
    # periodic wall lines from periodic ridges). 0.20/0.19 hugs just the
    # thumb pad with a smaller margin — tighter than ideal for off-centre
    # framing, but a clipped print beats a print with fake ridges baked in.
    logger.warning("Thumb segmentation failed — centre-ellipse prior fallback")
    h, w = gray.shape[:2]
    cv2.ellipse(
        mask,
        (int(cx), int(cy)),
        (int(w * 0.20), int(h * 0.19)),
        0, 0, 360, 255, -1,
    )
    return mask, cx, cy, 'prior'


# ─────────────────────────────────────────────────────────────────────────────
# Cylindrical projection (vectorised)
# ─────────────────────────────────────────────────────────────────────────────

def _accumulate_frame(
    gray:           np.ndarray,
    phi:            float,
    R:              float,
    D:              float,
    fx:             float,
    fy:             float,
    tx:             float,
    ty:             float,
    out_size:       int,
    texture:        np.ndarray,
    weight:         np.ndarray,
    mask:           Optional[np.ndarray] = None,
    seg_confidence: float = 1.0,
    out_theta_min:  float = _OUT_THETA_MIN,
    out_theta_max:  float = _OUT_THETA_MAX,
) -> None:
    """
    Project one frame onto the cylindrical texture.

    For each output texel (u, v):
      θ   = OUT_THETA_MIN + u·(OUT_THETA_MAX − OUT_THETA_MIN)
      h   = (v − 0.5)·2·h_half
      Px  = R·sin(θ−φ),  Py = h,  Pz = D − R·cos(θ−φ)
      px  = fx·Px/Pz + tx,  py = fy·Py/Pz + ty
      w   = cos(θ−φ) × seg_confidence  [down-weights prior-fallback frames]
    """
    us = np.linspace(0.0, 1.0, out_size, endpoint=False)
    vs = np.linspace(0.0, 1.0, out_size)
    uu, vv = np.meshgrid(us, vs)

    theta  = out_theta_min + uu * (out_theta_max - out_theta_min)
    h_half = 0.5 * out_size / fy * max(D - R, D * 0.5)
    h      = (vv - 0.5) * 2.0 * h_half

    dth = theta - phi
    Px  = R * np.sin(dth)
    Py  = h
    Pz  = D - R * np.cos(dth)

    vis   = np.maximum(np.cos(dth), 0.0) ** 2
    valid = (vis > 0.0) & (Pz > 0.0)

    safe_Pz = np.where(Pz > 0.0, Pz, 1.0)
    px = np.where(valid, fx * Px / safe_Pz + tx, -1.0)
    py = np.where(valid, fy * Py / safe_Pz + ty, -1.0)

    in_b = (
        valid
        & (px >= 0.0) & (px <= out_size - 2.0)
        & (py >= 0.0) & (py <= out_size - 2.0)
    )

    if mask is not None:
        ix   = np.clip(px.astype(np.int32), 0, out_size - 1)
        iy   = np.clip(py.astype(np.int32), 0, out_size - 1)
        in_b = in_b & (mask[iy, ix] > 0)

    if not in_b.any():
        return

    map_x   = px.astype(np.float32)
    map_y   = py.astype(np.float32)
    sampled = cv2.remap(
        gray.astype(np.float32), map_x, map_y,
        interpolation=cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0.0,
    )
    vis_gated = np.where(in_b, vis, 0.0)
    texture  += sampled.astype(np.float64) * vis_gated * seg_confidence
    weight   += vis_gated * seg_confidence


# ─────────────────────────────────────────────────────────────────────────────
# Phase-correlation angle refinement
# ─────────────────────────────────────────────────────────────────────────────

def _project_single_frame(
    gray:     np.ndarray,
    phi:      float,
    R:        float,
    D:        float,
    fx:       float,
    fy:       float,
    tx:       float,
    ty:       float,
    out_size: int,
    mask:     Optional[np.ndarray] = None,
    out_theta_min: float = _OUT_THETA_MIN,
    out_theta_max: float = _OUT_THETA_MAX,
) -> Tuple[np.ndarray, np.ndarray]:
    """Project one frame onto its own (texture, weight) arrays without accumulating."""
    tex = np.zeros((out_size, out_size), dtype=np.float64)
    wt  = np.zeros((out_size, out_size), dtype=np.float64)
    _accumulate_frame(gray, phi, R, D, fx, fy, tx, ty, out_size, tex, wt, mask,
                      out_theta_min=out_theta_min, out_theta_max=out_theta_max)
    return tex, wt


def _correlate_overlap(
    tex_a:          np.ndarray,
    w_a:            np.ndarray,
    tex_b:          np.ndarray,
    w_b:            np.ndarray,
    out_size:       int,
    conf_threshold: float = 0.3,
    out_theta_min:  float = _OUT_THETA_MIN,
    out_theta_max:  float = _OUT_THETA_MAX,
) -> Optional[Tuple[float, float, float]]:
    """
    Cross-correlate the shared overlap strip between two per-frame projections using 2D FFT.

    Returns (offset_deg, dy_px, confidence):
      offset_deg — angular offset of b relative to a (positive = b shifted right; subtract to correct)
      dy_px      — vertical offset of b relative to a in texture pixels (positive = b is below a)
      confidence — normalised peak correlation (0–1)

    Returns None when overlap is < 10 columns or peak confidence < threshold.
    """
    from scipy.signal import fftconvolve

    col_a   = w_a.sum(axis=0) > 0
    col_b   = w_b.sum(axis=0) > 0
    ov_cols = np.where(col_a & col_b)[0]
    if len(ov_cols) < 10:
        return None

    sl = slice(int(ov_cols[0]), int(ov_cols[-1]) + 1)

    def _norm_patch(tex: np.ndarray, w: np.ndarray) -> np.ndarray:
        w_sl  = w[:, sl]
        t_sl  = tex[:, sl]
        patch = np.where(w_sl > 0, t_sl / np.maximum(w_sl, 1e-9), 0.0)
        return patch - patch.mean()

    patch_a  = _norm_patch(tex_a, w_a)
    patch_b  = _norm_patch(tex_b, w_b)
    corr_2d  = fftconvolve(patch_a, patch_b[::-1, ::-1], mode='full')
    cy_peak, cx_peak = np.unravel_index(np.argmax(corr_2d), corr_2d.shape)
    center_y = patch_a.shape[0] - 1
    center_x = patch_a.shape[1] - 1

    norm = float(np.sqrt((patch_a ** 2).sum() * (patch_b ** 2).sum()))
    if norm < 1e-6:
        return None
    confidence = float(corr_2d[cy_peak, cx_peak]) / norm
    if confidence < conf_threshold:
        logger.debug(f"Phase corr 2D: conf={confidence:.3f} — below threshold, skipping")
        return None

    deg_per_px = float(np.degrees(out_theta_max - out_theta_min)) / out_size
    offset_deg = (cx_peak - center_x) * deg_per_px
    dy_px      = float(cy_peak - center_y)
    logger.info(
        f"Phase corr 2D: offset={offset_deg:+.2f}  dy={dy_px:+.1f}px  conf={confidence:.3f}"
    )
    return float(offset_deg), dy_px, confidence


def _refine_angles(
    grays:                  List[np.ndarray],
    seg_results:            list,
    initial_angles_rad:     List[float],
    R:                      float,
    D:                      float,
    fx:                     float,
    fy:                     float,
    out_size:               int,
    phase_conf_threshold:   float = 0.3,
    fx_scale:               float = 1.0,
    out_theta_min:          float = _OUT_THETA_MIN,
    out_theta_max:          float = _OUT_THETA_MAX,
) -> Tuple[List[float], list, List[float]]:
    """
    Refine capture angles by phase-correlating overlap bands between adjacent frames.

    Frame 0 (front) is the fixed anchor. Corrections propagate cumulatively:
      refined[1] = initial[1] − δ₀₁
      refined[2] = initial[2] − (δ₀₁ + δ₁₂)
      refined[3] = initial[3] − (δ₀₁ + δ₁₂ + δ₂₃)

    Pairs whose overlap is too thin (right↔top, top↔left) will typically fall
    below the confidence threshold and be skipped automatically. Returns
    (initial_angles_rad, []) unchanged if all pair correlations fail.

    Returns (refined_angles_rad, pairs_info) where pairs_info is a list of
    {offset, confidence} dicts (or None when a pair was skipped).
    """
    # Project at half resolution for speed — angular offsets are scale-invariant.
    REFINE_SIZE = max(256, out_size // 2)
    rs = REFINE_SIZE / out_size   # scale factor
    fx_r, fy_r, _ = _scale_params(REFINE_SIZE)
    fx_r *= fx_scale   # apply the same focal-length scale used in the main projection
    fy_r *= fx_scale
    sm_grays = [cv2.resize(g, (REFINE_SIZE, REFINE_SIZE)) for g in grays]

    def _project_one(args):
        (mask, tx, ty, _), sm_g, phi = args
        return _project_single_frame(
            sm_g, phi, R * rs, D * rs, fx_r, fy_r,
            tx * rs, ty * rs, REFINE_SIZE,
            cv2.resize(mask, (REFINE_SIZE, REFINE_SIZE),
                       interpolation=cv2.INTER_NEAREST) if mask is not None else None,
            out_theta_min=out_theta_min, out_theta_max=out_theta_max,
        )

    with ThreadPoolExecutor(max_workers=len(grays)) as ex:
        per_frame = list(ex.map(_project_one, zip(seg_results, sm_grays, initial_angles_rad)))

    refined          = list(initial_angles_rad)
    total_correction = 0.0   # cumulative radians; anchored at frame 0
    total_ty         = 0.0   # cumulative texture-pixel vertical shift
    pairs_info: list = []
    ty_corrections: List[float] = [0.0] * len(grays)

    for i in range(len(grays) - 1):
        tex_a, w_a = per_frame[i]
        tex_b, w_b = per_frame[i + 1]
        result = _correlate_overlap(tex_a, w_a, tex_b, w_b, REFINE_SIZE, conf_threshold=phase_conf_threshold,
                                    out_theta_min=out_theta_min, out_theta_max=out_theta_max)
        if result is None:
            pairs_info.append(None)
            continue
        offset_deg, dy_px, corr_conf = result
        # Angular clamp: the seeds are physically grounded (protocol targets /
        # IMU deltas / arc pitch), so genuine residual error is small. A
        # correction beyond ~18° is far more likely a ridge-periodicity false
        # peak (ridges repeat every few degrees of cylinder arc, giving the
        # correlator confident wrong answers) than a real seed error — cap it.
        _MAX_OFFSET = 18.0
        if abs(offset_deg) > _MAX_OFFSET:
            logger.info(
                f"Phase corr [{i}->{i+1}]: offset={offset_deg:+.1f}° exceeds ±{_MAX_OFFSET:.0f}° — clamped"
            )
            offset_deg = float(np.clip(offset_deg, -_MAX_OFFSET, _MAX_OFFSET))
        # Sanity-clamp: vertical offsets > ~14% of frame height are almost always
        # false positives caused by repeating ridge patterns in the overlap strip.
        # Ridge periodicity creates spurious peaks at 100–300px; real alignment
        # errors after vertical re-centering are ≤50px. Keep angular correction.
        _MAX_TY = 50.0
        if abs(dy_px) > _MAX_TY:
            logger.info(
                f"Phase corr [{i}->{i+1}]: dy={dy_px:+.0f}px exceeds {_MAX_TY:.0f}px limit — vertical component discarded"
            )
            dy_px = 0.0
        pairs_info.append({'offset': round(offset_deg, 2), 'dy': round(dy_px, 1), 'confidence': round(corr_conf, 3)})
        # Positive offset → b shifted right → angle too large → subtract.
        # Positive dy → b is below a in texture → decrease ty for b.
        total_correction += np.radians(offset_deg)
        total_ty         += dy_px
        for j in range(i + 1, len(grays)):
            refined[j]        = initial_angles_rad[j] - total_correction
            ty_corrections[j] = -total_ty
        logger.info(
            f"Angle+ty refinement [{i}->{i+1}]: "
            f"{np.degrees(initial_angles_rad[i+1]):.1f}° -> {np.degrees(refined[i+1]):.1f}°  "
            f"ty_corr={ty_corrections[i+1]:+.1f}px"
        )

    return refined, pairs_info, ty_corrections


# ─────────────────────────────────────────────────────────────────────────────
# Gap filling
# ─────────────────────────────────────────────────────────────────────────────

def _fill_gaps(texture: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """
    Fill uncovered texels in two passes:
      - Pixels within 30px of a real texel: KDTree nearest-neighbour (plausible
        ridge continuation for small inter-frame gaps).
      - Pixels farther away (large structural gaps): neutral mean gray so the
        enhancement pipeline doesn't process spurious copied-texture patterns as
        if they were real ridge data.
    """
    ys, xs = np.where(mask)
    if len(ys) == 0:
        return texture
    mean_val = float(texture[ys, xs].mean())
    tree   = cKDTree(np.column_stack([ys, xs]))
    gy, gx = np.where(~mask)
    if len(gy) == 0:
        return texture
    dists, idx = tree.query(np.column_stack([gy, gx]))
    result = texture.copy()
    close  = dists <= 30
    result[gy[close],  gx[close]]  = texture[ys[idx[close]],  xs[idx[close]]]
    result[gy[~close], gx[~close]] = mean_val
    return result


# ─────────────────────────────────────────────────────────────────────────────
# Offline validation utility
# ─────────────────────────────────────────────────────────────────────────────

def validate_sfm(captures_dir: str) -> None:
    """
    Offline testing utility.  Iterates sub-directories, reads one frame per angle,
    runs reconstruct_and_unwrap, and prints Laplacian variance as a sharpness proxy.

    Usage:
        python -c "from sfm_pipeline import validate_sfm; validate_sfm('./captures')"
    """
    for capture_id in sorted(os.listdir(captures_dir)):
        capture_path = os.path.join(captures_dir, capture_id)
        if not os.path.isdir(capture_path):
            continue

        frames: List[np.ndarray] = []
        for angle in ["front", "right", "top", "left"]:
            for idx in range(1, 3):
                p = os.path.join(capture_path, f"frame_{angle}_{idx}.jpg")
                if os.path.exists(p):
                    f = cv2.imread(p)
                    if f is not None:
                        frames.append(f)
                        break

        if not frames:
            print(f"[SKIP] {capture_id} — no frames found")
            continue

        try:
            result, coverage, refined_angles, _ = reconstruct_and_unwrap(frames)
            lap_var = float(cv2.Laplacian(result, cv2.CV_64F).var())
            angles_str = '  '.join(f'{a:.1f}°' for a in refined_angles)
            print(f"[OK]   {capture_id}  shape={result.shape}  lap={lap_var:.1f}  cov={coverage:.0%}  angles=[{angles_str}]")
            cv2.imwrite(os.path.join(capture_path, "unwrapped.png"), result)
        except CaptureQualityError as e:
            print(f"[FAIL] {capture_id} — {e}")
        except Exception as e:
            print(f"[ERR]  {capture_id} — {e}")
