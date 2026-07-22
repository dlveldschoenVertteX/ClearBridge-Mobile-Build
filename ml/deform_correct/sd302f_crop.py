"""Fingertip cropping + quality-gating for SD302f's raw N2N-rig photographs.

SD302f is the ONLY part of SD302 that is actually PHOTOGRAPHED contactless
skin (a 15-camera rig), unlike SD302a/b/d's clean contact-scanner prints --
i.e. the part of this dataset genuinely closest in domain/appearance to
MAC3D's own phone-camera fingerphoto captures (the CTO's own framing: "spread
out prints that are closest to MAC3D domain"). SD302a/b/d volume was already
tried as a `ml/deform_correct` synthetic-distortion source (the v2 run,
3810 prints) and did NOT beat the smaller v1 checkpoint on the real MAC3D
SourceAFIS gate -- see CLAUDE.md 2026-07-18. This module makes SD302f usable
as an alternative/additional source for that same self-supervised pipeline
(dataset.py's SynthDeformDataset + synth_distort.py), testing domain-match
instead of raw volume as the lever.

Ports (self-contained, no afis_print.py import -- same dependency-light
discipline as ml/multiview_fusion/common.py) the exact three-gate cropping
approach already prototyped and visually validated this session in
scratchpad/sd302/crop_and_manifest.py (research-only, never committed):
  1. Restrict the search to an empirically-observed ROI sub-region (the
     rig's finger-insertion slot lands in roughly the same part of the frame
     across all of the rig's cameras) -- confirmed by eye across 28 real
     samples.
  2. Within the ROI, seed on ridge-CONFIDENCE (orientation coherence gated by
     in-band ridge energy) x orientation-CURVATURE (near 0 for a straight
     edge like the rig's metal rail, near 1 near a real fingertip's
     loop/whorl core) -- confidence alone was fooled by the rail's own
     coherent, energetic texture; only curvature distinguishes a real
     fingertip.
  3. A post-hoc whole-crop quality re-check (mean confidence*curvature over
     the WHOLE crop, not just the seed patch) -- a good seed patch can still
     sit at the edge of an otherwise-bad crop.

On the original 40-sample calibration, 21/40 (52.5%) passed all three gates
and were visually confirmed genuinely centered on real finger ridge detail.
"""
from __future__ import annotations

from typing import Optional, Tuple

import cv2
import numpy as np

_BLOCK = 16
_QUALITY_CUTOFF = 0.012   # calibrated threshold, see crop_quality's docstring
_SEED_CONF_MIN = 0.15
_SD302F_ROI = (0.08, 0.02, 0.66, 0.82)  # (x0,y0,x1,y1) as frac of (w,h)


def block_coherence(gray: np.ndarray, blur: float = 8.0) -> np.ndarray:
    """Port of afis_print._block_coherence (identical to
    ml/multiview_fusion/common.py's own port of the same function)."""
    gg = gray.astype(np.float32)
    gx = cv2.Sobel(gg, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gg, cv2.CV_32F, 0, 1, ksize=3)
    gxx = cv2.boxFilter(gx * gx, -1, (_BLOCK, _BLOCK))
    gyy = cv2.boxFilter(gy * gy, -1, (_BLOCK, _BLOCK))
    gxy = cv2.boxFilter(gx * gy, -1, (_BLOCK, _BLOCK))
    c = np.sqrt((gxx - gyy) ** 2 + 4 * gxy ** 2) / (gxx + gyy + 1e-6)
    return cv2.GaussianBlur(c, (0, 0), blur)


def orientation_field(img: np.ndarray, bsize: int = _BLOCK, smooth: float = 12.0) -> np.ndarray:
    """Port of afis_print._orientation_field."""
    gx = cv2.Sobel(img, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(img, cv2.CV_32F, 0, 1, ksize=3)
    vx = cv2.boxFilter(2 * gx * gy, -1, (bsize, bsize))
    vy = cv2.boxFilter(gx * gx - gy * gy, -1, (bsize, bsize))
    theta = 0.5 * np.arctan2(vx, vy)
    cs = cv2.GaussianBlur(np.cos(2 * theta), (0, 0), smooth)
    sn = cv2.GaussianBlur(np.sin(2 * theta), (0, 0), smooth)
    return 0.5 * np.arctan2(sn, cs) + np.pi / 2


def ridge_confidence(gray: np.ndarray, mask: Optional[np.ndarray] = None) -> np.ndarray:
    """Port of afis_print._ridge_confidence: orientation coherence gated by
    in-band ridge energy (distinguishes true ridges from flat/blurred skin
    or coherent-but-non-ridge texture like the rig's own metal rail)."""
    coh = block_coherence(gray)
    g = gray.astype(np.float32)
    band = cv2.GaussianBlur(g, (0, 0), 1.2) - cv2.GaussianBlur(g, (0, 0), 3.5)
    energy = cv2.GaussianBlur(np.abs(band), (0, 0), _BLOCK)
    if mask is not None:
        m = mask > 0
        e_hi = np.percentile(energy[m], 75) if m.any() else 1.0
    else:
        e_hi = np.percentile(energy, 75)
    energy_n = np.clip(energy / max(e_hi, 1e-6), 0, 1)
    return np.clip(coh, 0, 1) * energy_n


def _orient_curvature(gray: np.ndarray, win: int = 15) -> np.ndarray:
    """1 - local resultant length of the doubled-angle orientation field:
    near 0 where orientation is locally uniform (straight edge, e.g. the
    rig's rail), near 1 where it genuinely curves (a real fingertip's
    loop/whorl core)."""
    orient = orientation_field(gray)
    cs = cv2.GaussianBlur(np.cos(2 * orient), (0, 0), win / 3)
    sn = cv2.GaussianBlur(np.sin(2 * orient), (0, 0), win / 3)
    r = np.sqrt(cs ** 2 + sn ** 2)
    return 1.0 - r


def find_fingertip_crop(img_bgr: np.ndarray, scale: float = 0.25,
                         crop_frac: float = 0.14, roi=_SD302F_ROI
                         ) -> Tuple[Optional[np.ndarray], float]:
    """Locate and crop a real fingertip within an SD302f raw rig photo.
    Returns (grayscale crop, seed confidence) or (None, 0.0) if no
    confident seed was found."""
    h, w = img_bgr.shape[:2]
    if roi is not None:
        rx0, ry0, rx1, ry1 = roi
        rx0, rx1 = int(rx0 * w), int(rx1 * w)
        ry0, ry1 = int(ry0 * h), int(ry1 * h)
    else:
        rx0, ry0, rx1, ry1 = 0, 0, w, h
    region = img_bgr[ry0:ry1, rx0:rx1]
    gray_full = cv2.cvtColor(region, cv2.COLOR_BGR2GRAY)
    small = cv2.resize(gray_full, None, fx=scale, fy=scale)
    conf = ridge_confidence(small, None)
    curv = np.clip(_orient_curvature(small), 0, 1)
    combo = conf * curv
    thresh = np.percentile(combo, 97)
    ys, xs = np.where(combo >= thresh)
    if len(ys) < 20:
        return None, 0.0
    weights = combo[ys, xs]
    cy_s = float(np.average(ys, weights=weights))
    cx_s = float(np.average(xs, weights=weights))
    cy, cx = ry0 + cy_s / scale, rx0 + cx_s / scale
    mean_conf = float(np.mean(weights))
    half = int(min(h, w) * crop_frac)
    y0, y1 = max(0, int(cy - half)), min(h, int(cy + half))
    x0, x1 = max(0, int(cx - half)), min(w, int(cx + half))
    crop_bgr = img_bgr[y0:y1, x0:x1]
    if crop_bgr.size == 0:
        return None, 0.0
    return cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2GRAY), mean_conf


def crop_quality(gray_crop: np.ndarray) -> float:
    """Post-hoc whole-crop quality gate: mean confidence*curvature over the
    WHOLE crop, not just the seed patch. See module docstring, gate 3."""
    small = cv2.resize(gray_crop, (128, 128))
    conf = ridge_confidence(small, None)
    curv = np.clip(_orient_curvature(small), 0, 1)
    return float(np.mean(conf * curv))


def crop_and_gate(img_bgr: np.ndarray) -> Optional[np.ndarray]:
    """Convenience wrapper: run all three gates, return the accepted
    grayscale crop or None. This is the function build_sd302f_manifest.py
    calls per raw image."""
    crop, conf = find_fingertip_crop(img_bgr)
    if crop is None or conf < _SEED_CONF_MIN:
        return None
    if crop_quality(crop) < _QUALITY_CUTOFF:
        return None
    return crop
