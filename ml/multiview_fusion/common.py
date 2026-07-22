"""Self-contained ports of the specific afis_print.py techniques this module
builds on -- dependency-light, no import of afis_print.py itself, per this
project's own established convention (see ml/deform_correct/dataset.py's own
docstring on why: keeps this experimental module fully decoupled from the
production file it's being measured against).
"""
from __future__ import annotations

from typing import Optional, Tuple

import cv2
import numpy as np

_BLOCK = 16
_MOSAIC_REG_PX = 640  # ECC registration resolution (matches afis_print._MOSAIC_REG_PX)


def block_coherence(gray: np.ndarray, blur: float = 8.0) -> np.ndarray:
    """Port of afis_print._block_coherence: single-scale structure-tensor
    coherence via Sobel + boxFilter + one GaussianBlur. Used both as the
    original blend weight and, here, to gate where local correspondence
    points are allowed to land (never in flat/background regions)."""
    gg = gray.astype(np.float32)
    gx = cv2.Sobel(gg, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gg, cv2.CV_32F, 0, 1, ksize=3)
    gxx = cv2.boxFilter(gx * gx, -1, (_BLOCK, _BLOCK))
    gyy = cv2.boxFilter(gy * gy, -1, (_BLOCK, _BLOCK))
    gxy = cv2.boxFilter(gx * gy, -1, (_BLOCK, _BLOCK))
    c = np.sqrt((gxx - gyy) ** 2 + 4 * gxy ** 2) / (gxx + gyy + 1e-6)
    return cv2.GaussianBlur(c, (0, 0), blur)


def orientation_field(img: np.ndarray, bsize: int = _BLOCK, smooth: float = 12.0) -> np.ndarray:
    """Port of afis_print._orientation_field: doubled-angle Sobel averaging,
    returns per-pixel ridge direction in [0, pi). Used by continuity_metric
    to measure orientation discontinuity across a fusion seam."""
    gx = cv2.Sobel(img, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(img, cv2.CV_32F, 0, 1, ksize=3)
    vx = cv2.boxFilter(2 * gx * gy, -1, (bsize, bsize))
    vy = cv2.boxFilter(gx * gx - gy * gy, -1, (bsize, bsize))
    theta = 0.5 * np.arctan2(vx, vy)
    cs = cv2.GaussianBlur(np.cos(2 * theta), (0, 0), smooth)
    sn = cv2.GaussianBlur(np.sin(2 * theta), (0, 0), smooth)
    return 0.5 * np.arctan2(sn, cs) + np.pi / 2


def ecc_homography_align(front: np.ndarray, side: np.ndarray
                          ) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """Port of the coarse-alignment step inside afis_print._front_anchored_
    mosaic -- this part never failed (the failure was in the blend after
    it), so it's reused as-is rather than reinvented. Returns (registered
    side image at full front resolution, 3x3 homography used) or None if
    ECC fails to converge or the registration is too weak
    (corrcoef < 0.45, same gate the original uses).
    """
    fh, fw = front.shape[:2]
    g = side if side.ndim == 2 else cv2.cvtColor(side, cv2.COLOR_BGR2GRAY)
    if g.shape[:2] != (fh, fw):
        g = cv2.resize(g, (fw, fh))
    s = _MOSAIC_REG_PX / max(fh, fw)
    small = (max(1, int(fw * s)), max(1, int(fh * s)))
    cl = cv2.createCLAHE(3.0, (8, 8))
    ref_small = cl.apply(cv2.resize(front, small))
    up = np.array([[1 / s, 0, 0], [0, 1 / s, 0], [0, 0, 1]], dtype=np.float32)
    dn = np.array([[s, 0, 0], [0, s, 0], [0, 0, 1]], dtype=np.float32)
    crit = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 60, 1e-4)
    try:
        warp = np.eye(3, 3, dtype=np.float32)
        _, warp = cv2.findTransformECC(
            ref_small, cl.apply(cv2.resize(g, small)), warp,
            cv2.MOTION_HOMOGRAPHY, crit, None, 5)
        warp_full = (up @ warp @ dn).astype(np.float32)
        reg = cv2.warpPerspective(g, warp_full, (fw, fh), flags=cv2.INTER_LINEAR)
    except cv2.error:
        return None
    if float(np.corrcoef(reg.ravel(), front.ravel())[0, 1]) < 0.45:
        return None
    return reg, warp_full


def coherence_weighted_blend(front: np.ndarray, registered_sides: list[np.ndarray]
                              ) -> Tuple[Optional[np.ndarray], int]:
    """Port of afis_print._front_anchored_mosaic's OWN blend step, kept
    byte-for-byte equivalent -- Phase 0 deliberately leaves this UNCHANGED
    to isolate the one variable under test (does fixing the geometry alone,
    upstream of this exact blend, fix the seam?)."""
    fh, fw = front.shape[:2]
    acc = front.astype(np.float32) * block_coherence(front)
    wsum = block_coherence(front).copy()
    used = 0
    for reg in registered_sides:
        valid = (reg > 0).astype(np.float32)
        cs = block_coherence(reg) * valid
        acc += reg.astype(np.float32) * cs
        wsum += cs
        used += 1
    if used == 0:
        return None, 0
    return (acc / np.maximum(wsum, 1e-6)).astype(np.uint8), used
