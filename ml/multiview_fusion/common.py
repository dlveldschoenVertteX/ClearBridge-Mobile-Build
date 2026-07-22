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
_N_ORIENT = 16              # Gabor bank orientation count (matches afis_print._N_ORIENT)
_GABOR_SIGMA_RATIO = 0.65   # matches afis_print._GABOR_SIGMA_RATIO (tuned 2026-07-15)
_GABOR_GAMMA = 0.85         # matches afis_print._GABOR_GAMMA
_ORIENT_SMOOTH = 15.0       # matches afis_print._ORIENT_SMOOTH


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


def normalize(img: np.ndarray, m0: float = 100.0, v0: float = 100.0) -> np.ndarray:
    """Port of afis_print._normalize."""
    img = img.astype(np.float32)
    m, v = img.mean(), max(img.var(), 1e-6)
    return m0 + np.sqrt(v0 * (img - m) ** 2 / v) * np.sign(img - m)


def ridge_wavelength(img: np.ndarray, orient: np.ndarray, bsize: int = 32) -> float:
    """Port of afis_print._ridge_wavelength (block-autocorrelation ridge-period estimate)."""
    h, w = img.shape
    freqs = []
    for y in range(0, h - bsize, bsize):
        for x in range(0, w - bsize, bsize):
            blk = img[y:y + bsize, x:x + bsize]
            if blk.std() < 8:
                continue
            ang = orient[y + bsize // 2, x + bsize // 2]
            m = cv2.getRotationMatrix2D((bsize / 2, bsize / 2), np.degrees(ang), 1.0)
            rot = cv2.warpAffine(blk, m, (bsize, bsize))
            sig = rot.mean(axis=0)
            sig = sig - sig.mean()
            ac = np.correlate(sig, sig, 'full')[bsize - 1:]
            d = np.diff(ac)
            peaks = np.where((d[:-1] > 0) & (d[1:] <= 0))[0] + 1
            peaks = peaks[peaks > 3]
            if len(peaks):
                freqs.append(peaks[0])
    if not freqs:
        return 9.0
    return float(np.clip(np.median(freqs), 5, 20))


def gabor_enhance(img: np.ndarray, orient: np.ndarray, wavelength: float) -> np.ndarray:
    """Port of afis_print._gabor_enhance (single-wavelength oriented Gabor bank)."""
    h, w = img.shape
    sigma = _GABOR_SIGMA_RATIO * wavelength
    ksize = int(2 * np.ceil(3 * sigma) + 1)
    outs = np.zeros((_N_ORIENT, h, w), np.float32)
    for i in range(_N_ORIENT):
        th = np.pi * i / _N_ORIENT
        k = cv2.getGaborKernel((ksize, ksize), sigma, th + np.pi / 2,
                                wavelength, _GABOR_GAMMA, 0, cv2.CV_32F)
        k -= k.mean()
        outs[i] = cv2.filter2D(img, cv2.CV_32F, k)
    idx = np.round((orient % np.pi) / (np.pi / _N_ORIENT)).astype(int) % _N_ORIENT
    yy, xx = np.mgrid[0:h, 0:w]
    return outs[idx, yy, xx]


def gabor_binarize(gray: np.ndarray, mask: Optional[np.ndarray] = None) -> np.ndarray:
    """Port of afis_print.generate()'s default single-wavelength Gabor+binarize
    chain (_normalize -> _orientation_field -> _ridge_wavelength ->
    _gabor_enhance -> hard threshold). Needed as a preprocessing step before
    minutiae extraction: mindtct expects ridge-valley contrast like a real
    scanned/inked print, not a raw fingerphoto -- confirmed empirically (0
    minutiae detected on an unenhanced capture; 406 detected on the same
    capture after this chain). See minutiae_align.py."""
    norm = normalize(gray)
    orient = orientation_field(norm, smooth=_ORIENT_SMOOTH)
    wl = ridge_wavelength(norm, orient)
    enh = gabor_enhance(norm, orient, wl)
    binimg = 255 - (enh < 0).astype(np.uint8) * 255
    if mask is not None:
        binimg = binimg.copy()
        binimg[mask == 0] = 255
    return binimg


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
