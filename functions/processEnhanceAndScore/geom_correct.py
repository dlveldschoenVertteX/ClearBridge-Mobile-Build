"""Cross-domain geometry correction for contactless -> contact fingerprint
matching (C2CL-style).

Prime-directive context (2026-07-16, docs/FIDELITY_WALL_SCOPE.md): our prints
score well on NFIQ2 (~70) but do NOT AFIS-match — SourceAFIS separates
same-finger from different-finger only faintly (genuine mean ~5.6 vs impostor
floor ~0.07, both far below the ~40 real-match threshold). The published root
cause (Grosz/Engelsma/Jain, "C2CL: Contact to Contactless Fingerprint
Matching", IEEE TIFS 2021) is that a contactless capture is a photo of a
CURVED 3D finger from one viewpoint, while a contact/ink print is the finger
pressed FLAT onto a platen. Two geometric distortions separate them, and our
pipeline currently corrects NEITHER:

  1. **Cylinder foreshortening** — the pad is ~a cylinder; equal-arc-length
     ridges near the left/right silhouette edges project onto FEWER pixels
     than ridges at the centre. Contact printing spreads them evenly. This is
     a deterministic, single-image, parameter-light correction (below).
  2. **Elastic (skin) deformation** — pressing the elastic pad flat spreads
     ridges radially outward from the contact centre. C2CL learns a robust
     thin-plate-spline (RTPS) for this; it needs PAIRED training data we don't
     have yet, so `elastic_flatten` here is a PARAMETRIC placeholder with the
     same call signature, ready to be swapped for a trained model.

Design contract (matches every other addition in afis_print.py):
  - Pure, self-contained, no new heavy deps (numpy + OpenCV only), trivially
    removable.
  - Operates on the already-masked, upright-agnostic grayscale pad + its mask,
    warping BOTH with the same map so mask alignment is preserved.
  - Wired as MAX-OF-VARIANTS candidates in main.py, so it can only ever ADD a
    print, never regress the existing best.
  - **Success is measured by SourceAFIS genuine-vs-impostor separation, NOT
    NFIQ2** (which is already saturated and blind to this axis). Until a
    paired dataset lands (scope doc item A) the parameters cannot be tuned —
    they are deliberately mild defaults so the transform is a small, testable
    perturbation, not an aggressive unwrap. `docs/FIDELITY_WALL_SCOPE.md`
    item B tracks the tuning/validation plan.

NOTE this is deliberately a SINGLE-IMAGE frontal rectification, NOT the
multi-view SfM cylindrical unroll in sfm_pipeline.py — that full unroll was
already found to HURT (unwrapping oblique deformable-skin views scored 15-18
NFIQ below the single frame; see afis_print.generate's stacking comments and
ml/mac3d_enhance/SMALL_ROLL_SCOPE.md's NO-GO). We only gently undo the
curvature of ONE frontal frame here.
"""
from __future__ import annotations

from typing import Optional, Tuple

import numpy as np
import cv2


# ---- tunable defaults (mild; not yet fit to paired data) --------------------
# Half-angle (deg) of pad arc assumed VISIBLE from silhouette edge to edge.
# A frontal contactless capture shows roughly the front third of the finger
# circumference, so ~60 deg half-angle (120 deg total) is a conservative start.
# Larger => more edge stretch. Real value is subject/pose dependent and is the
# first thing to fit once paired data exists.
_CYL_HALF_ANGLE_DEG = 55.0
# Blend between identity (0.0) and full cylinder unwrap (1.0). <1 keeps the
# correction gentle so a wrong angle estimate can't badly distort the centre.
_CYL_STRENGTH = 0.6
# Elastic-flatten radial gain (parametric placeholder). 0 = identity.
# Positive spreads ridges outward from the pad centroid (mimics contact
# flattening); intentionally 0 by default until a trained RTPS replaces it.
_ELASTIC_GAIN = 0.0


def _pad_bounds(mask: np.ndarray) -> Optional[Tuple[int, int, int, int]]:
    ys, xs = np.where(mask > 0)
    if xs.size == 0:
        return None
    return int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())


def cylindrical_rectify(
    gray: np.ndarray,
    mask: np.ndarray,
    half_angle_deg: float = _CYL_HALF_ANGLE_DEG,
    strength: float = _CYL_STRENGTH,
) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """Undo single-image cylinder foreshortening along the pad's WIDTH axis.

    Models the pad as a cylinder whose axis runs vertically through the mask
    centroid. A surface point at circumferential angle theta projects to image
    column offset ``x = R * sin(theta)`` (orthographic), while its true
    arc-length position (what a flat contact print records) is ``s = R *
    theta``. We resample columns so output column position is proportional to
    ``theta`` instead of ``sin(theta)`` — i.e. stretch the compressed edges
    back out. Rows (finger long axis) are left unchanged: the finger is
    ~straight along the cylinder, only its cross-section curves.

    Warps ``gray`` and ``mask`` with the SAME horizontal map so the mask stays
    aligned. Returns (rectified_gray, rectified_mask) or None if degenerate.

    `strength` blends toward identity so a mis-estimated `half_angle_deg`
    perturbs, not destroys. Width axis is inferred from the mask's aspect: the
    cylinder curves across the SHORTER pad dimension, so if the pad is taller
    than wide we rectify columns (default); this holds for our upright pads.
    """
    if gray is None or mask is None:
        return None
    b = _pad_bounds(mask)
    if b is None:
        return None
    x0, x1, _y0, _y1 = b
    half_w = (x1 - x0) / 2.0
    if half_w < 4:
        return None
    theta_max = np.deg2rad(float(np.clip(half_angle_deg, 5.0, 85.0)))
    cx = (x0 + x1) / 2.0
    h, w = gray.shape[:2]

    # Build the inverse map: for each OUTPUT column, which INPUT column to
    # sample. Output columns are spaced by arc length (uniform theta); the
    # corresponding input column is R*sin(theta). Normalise so the pad edges
    # map to +/- theta_max and the output width matches the input width (we
    # keep the same canvas; edge content stretches inward toward the centre's
    # sampling, i.e. the map SAMPLES the compressed edges more densely).
    xs = np.arange(w, dtype=np.float32)
    # Normalised distance from axis in [-1, 1] across the pad half-width.
    u = (xs - cx) / max(half_w, 1.0)
    u = np.clip(u, -1.0, 1.0)
    # Full unwrap: output arc coordinate theta_out = u * theta_max; the input
    # column that carries that surface point sits at sin(theta_out)/sin(tmax).
    theta_out = u * theta_max
    src_u = np.sin(theta_out) / max(np.sin(theta_max), 1e-6)
    src_x_full = cx + src_u * half_w
    # Blend toward identity by `strength`.
    src_x = (1.0 - strength) * xs + strength * src_x_full
    map_x = np.repeat(src_x[None, :], h, axis=0).astype(np.float32)
    map_y = np.repeat(np.arange(h, dtype=np.float32)[:, None], w, axis=1)

    rect_gray = cv2.remap(gray, map_x, map_y, interpolation=cv2.INTER_LINEAR,
                          borderMode=cv2.BORDER_REPLICATE)
    rect_mask = cv2.remap(mask, map_x, map_y, interpolation=cv2.INTER_NEAREST,
                          borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    return rect_gray, rect_mask


def elastic_flatten(
    gray: np.ndarray,
    mask: np.ndarray,
    gain: float = _ELASTIC_GAIN,
) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """PARAMETRIC placeholder for contact-flattening elastic deformation.

    A trained RTPS model (C2CL) is the real answer and needs paired data we
    don't have yet. Until then this applies a mild radial OUTWARD spread from
    the mask centroid — a first-order approximation of how pressing the pad
    flat pushes ridges away from the contact centre. `gain=0` (default) is a
    strict identity, so wiring this in is a no-op until deliberately enabled or
    replaced by a learned warp with this same signature.

    Kept separate from `cylindrical_rectify` so the deterministic,
    physically-justified curvature correction can be evaluated on its own
    before the speculative elastic term is ever switched on.
    """
    if gray is None or mask is None:
        return None
    if abs(gain) < 1e-6:
        return gray, mask   # identity — the honest default
    b = _pad_bounds(mask)
    if b is None:
        return None
    x0, x1, y0, y1 = b
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    rx, ry = max((x1 - x0) / 2.0, 1.0), max((y1 - y0) / 2.0, 1.0)
    h, w = gray.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    nx, ny = (xx - cx) / rx, (yy - cy) / ry
    r = np.sqrt(nx * nx + ny * ny)
    # Outward spread: sample from slightly nearer the centre so ridges move
    # out. Scale by a smooth radial profile that vanishes at the pad edge.
    factor = 1.0 - gain * np.clip(1.0 - r, 0.0, 1.0)
    map_x = (cx + (xx - cx) * factor).astype(np.float32)
    map_y = (cy + (yy - cy) * factor).astype(np.float32)
    def_gray = cv2.remap(gray, map_x, map_y, interpolation=cv2.INTER_LINEAR,
                         borderMode=cv2.BORDER_REPLICATE)
    def_mask = cv2.remap(mask, map_x, map_y, interpolation=cv2.INTER_NEAREST,
                         borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    return def_gray, def_mask


def correct(
    gray: np.ndarray,
    mask: np.ndarray,
    mode: str = 'cyl',
    **kw,
) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """Dispatch entry point used by afis_print.generate().

    mode:
      'cyl'      -> cylindrical curvature rectification only (default).
      'cylElastic' -> cylinder rectify THEN the (currently identity) elastic
                      flatten — the eventual full C2CL-style chain.
    Returns (gray, mask) warped, or None to signal "skip this variant" so the
    max-of-variants caller keeps its existing renderings unchanged.
    """
    out = cylindrical_rectify(gray, mask,
                              half_angle_deg=kw.get('half_angle_deg', _CYL_HALF_ANGLE_DEG),
                              strength=kw.get('strength', _CYL_STRENGTH))
    if out is None:
        return None
    if mode == 'cylElastic':
        out = elastic_flatten(out[0], out[1], gain=kw.get('gain', _ELASTIC_GAIN))
    return out
