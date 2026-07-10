"""
AFIS-style binary superprint from the best plain (face-on) capture frame.

Why this exists: the cylindrical unwrap is the right tool for *coverage*
metadata, but the human-recognisable "superprint" deliverable — the classic
black-ridges-on-white rolled-print look — is produced far more faithfully by
enhancing the single sharpest face-on frame directly:

    sharpest near-0° frame
      → U-Net thumb mask            (existing trained model, thumb_seg_unet.onnx)
      → local normalisation + CLAHE
      → block orientation field     (doubled-angle Sobel averaging)
      → ridge-wavelength estimate   (block autocorrelation)
      → oriented Gabor filter bank  (per-pixel orientation-selected response)
      → sign binarisation           (ridges black / valleys white)
      → mask + crop

Validated against a real sunlight capture (2c31b594): produces a clean,
reference-comparable binary loop pattern where the cylindrical unwrap of the
same capture appears geometrically stretched. This runs *in addition to* the
existing unwrap→NNS→NFIQ path, not instead of it — output is saved alongside
enhanced_flat.jpg for the user/AFIS-facing artefact.

No torch dependency; cv2 + numpy + the ONNX session already provisioned by
main._ensure_models / sfm_pipeline._get_thumb_seg_session.
"""
from __future__ import annotations

import logging
from typing import List, Optional, Tuple

import cv2
import numpy as np

logger = logging.getLogger('afis_print')

_BLOCK = 16          # orientation/variance block size (px)
_N_ORIENT = 16       # Gabor bank orientation count
_FACE_ON_MAX_DEG = 12.0   # a frame counts as "plain impression" within this angle


def _normalize(img: np.ndarray, m0: float = 100.0, v0: float = 100.0) -> np.ndarray:
    img = img.astype(np.float32)
    m, v = img.mean(), max(img.var(), 1e-6)
    return m0 + np.sqrt(v0 * (img - m) ** 2 / v) * np.sign(img - m)


def _orientation_field(img: np.ndarray, bsize: int = _BLOCK, smooth: float = 5.0) -> np.ndarray:
    gx = cv2.Sobel(img, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(img, cv2.CV_32F, 0, 1, ksize=3)
    vx = cv2.boxFilter(2 * gx * gy, -1, (bsize, bsize))
    vy = cv2.boxFilter(gx * gx - gy * gy, -1, (bsize, bsize))
    theta = 0.5 * np.arctan2(vx, vy)
    cs = cv2.GaussianBlur(np.cos(2 * theta), (0, 0), smooth)
    sn = cv2.GaussianBlur(np.sin(2 * theta), (0, 0), smooth)
    return 0.5 * np.arctan2(sn, cs) + np.pi / 2  # ridge direction


def _ridge_wavelength(img: np.ndarray, orient: np.ndarray, bsize: int = 32) -> float:
    h, w = img.shape
    freqs = []
    for y in range(0, h - bsize, bsize):
        for x in range(0, w - bsize, bsize):
            blk = img[y:y + bsize, x:x + bsize]
            if blk.std() < 8:
                continue
            ang = orient[y + bsize // 2, x + bsize // 2]
            M = cv2.getRotationMatrix2D((bsize / 2, bsize / 2), np.degrees(ang), 1.0)
            rot = cv2.warpAffine(blk, M, (bsize, bsize))
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


def _gabor_enhance(img: np.ndarray, orient: np.ndarray, wavelength: float) -> np.ndarray:
    h, w = img.shape
    sigma = 0.56 * wavelength
    ksize = int(2 * np.ceil(3 * sigma) + 1)
    outs = np.zeros((_N_ORIENT, h, w), np.float32)
    for i in range(_N_ORIENT):
        th = np.pi * i / _N_ORIENT
        k = cv2.getGaborKernel((ksize, ksize), sigma, th + np.pi / 2,
                               wavelength, 0.6, 0, cv2.CV_32F)
        k -= k.mean()
        outs[i] = cv2.filter2D(img, cv2.CV_32F, k)
    idx = np.round((orient % np.pi) / (np.pi / _N_ORIENT)).astype(int) % _N_ORIENT
    yy, xx = np.mgrid[0:h, 0:w]
    return outs[idx, yy, xx]


def _unet_mask(gray: np.ndarray) -> Optional[np.ndarray]:
    """Thumb mask via the shared U-Net ONNX session (None if unavailable)."""
    try:
        import sfm_pipeline
        session = sfm_pipeline._get_thumb_seg_session()
        if session is None:
            return None
        size = sfm_pipeline._THUMB_SEG_IMG_SIZE
        small = cv2.resize(gray, (size, size)).astype(np.float32) / 255.0
        logits = session.run(['logits'], {'input': small[None, None]})[0][0, 0]
        probs = 1.0 / (1.0 + np.exp(-logits))
        m = (probs > 0.5).astype(np.uint8) * 255
        m = cv2.resize(m, (gray.shape[1], gray.shape[0]), interpolation=cv2.INTER_NEAREST)
        m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((31, 31), np.uint8))
        m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((21, 21), np.uint8))
        n, lab, stats, _ = cv2.connectedComponentsWithStats(m)
        if n > 1:
            big = 1 + np.argmax(stats[1:, cv2.CC_STAT_AREA])
            m = (lab == big).astype(np.uint8) * 255
        if (m > 0).mean() < 0.03:   # implausibly small — treat as failed
            return None
        return m
    except Exception as e:              # noqa: BLE001 — mask is best-effort
        logger.warning('U-Net mask unavailable for AFIS print: %s', e)
        return None


def _coherence_hull_mask(g8: np.ndarray, bsize: int = _BLOCK) -> Optional[np.ndarray]:
    """Fallback mask: convex hull of the high-ridge-coherence region."""
    gf = g8.astype(np.float32)
    gx = cv2.Sobel(gf, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gf, cv2.CV_32F, 0, 1, ksize=3)
    gxx = cv2.boxFilter(gx * gx, -1, (bsize, bsize))
    gyy = cv2.boxFilter(gy * gy, -1, (bsize, bsize))
    gxy = cv2.boxFilter(gx * gy, -1, (bsize, bsize))
    coh = np.sqrt((gxx - gyy) ** 2 + 4 * gxy ** 2) / (gxx + gyy + 1e-6)
    m = (coh > 0.30).astype(np.uint8) * 255
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((41, 41), np.uint8))
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((21, 21), np.uint8))
    cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return None
    hull = cv2.convexHull(max(cnts, key=cv2.contourArea))
    out = np.zeros_like(m)
    cv2.drawContours(out, [hull], -1, 255, cv2.FILLED)
    return cv2.erode(out, np.ones((15, 15), np.uint8))


def _upright_rotate(binimg: np.ndarray, mask: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """
    Rotate so the thumb pad's long axis is VERTICAL, tip-up.

    The source frame's orientation depends on how the phone was held during
    capture (the burst still is sensor-rotation-corrected on-device, but
    nothing constrains portrait-vs-landscape hold or which way the thumb
    points within frame) -- so the pad can land in the output at any angle.
    A rolled/AFIS print is always presented upright, so this is a real
    correction, not cosmetic.

    Method: PCA on the mask's pixel coordinates gives the pad's principal
    (long) axis; rotate that to vertical. Up/down is then resolved by mask
    width profile -- the fingertip end is consistently the narrower, more
    tightly-curved end (the pad's widest point is roughly at the DIP crease
    it curves in from, the tip itself tapers), so the narrower half goes on
    top. This is a heuristic (no true anatomical landmark available from a
    single 2D silhouette) but is a firm improvement over a random angle.
    """
    ys, xs = np.where(mask > 0)
    if len(ys) < 50:
        return binimg, mask
    pts = np.column_stack([xs, ys]).astype(np.float64)
    mean = pts.mean(axis=0)
    _, s, vt = np.linalg.svd(pts - mean, full_matrices=False)
    # Only rotate when the pad has a CLEAR long axis. A near-circular mask (or a
    # failed whole-frame mask) has s[0]≈s[1] → the principal axis is noise, and
    # rotating by it spun the square output into a diamond. Leave those upright.
    if s[1] < 1e-6 or (s[0] / s[1]) < 1.25:
        return binimg, mask
    principal = vt[0]  # (dx, dy) of the long axis
    angle_deg = np.degrees(np.arctan2(principal[1], principal[0])) - 90.0

    h, w = mask.shape
    center = (w / 2.0, h / 2.0)
    # Expand canvas so rotation doesn't clip corners of an elongated mask.
    diag = int(np.ceil(np.hypot(h, w)))
    pad_y, pad_x = (diag - h) // 2 + 5, (diag - w) // 2 + 5
    bin_p = cv2.copyMakeBorder(binimg, pad_y, pad_y, pad_x, pad_x,
                               cv2.BORDER_CONSTANT, value=255)
    mask_p = cv2.copyMakeBorder(mask, pad_y, pad_y, pad_x, pad_x,
                                cv2.BORDER_CONSTANT, value=0)
    center_p = (center[0] + pad_x, center[1] + pad_y)
    M = cv2.getRotationMatrix2D(center_p, angle_deg, 1.0)
    size_p = (bin_p.shape[1], bin_p.shape[0])
    bin_r = cv2.warpAffine(bin_p, M, size_p, borderValue=255)
    mask_r = cv2.warpAffine(mask_p, M, size_p, borderValue=0)

    # Tip-up: compare mask width in the top vs bottom third; the narrower
    # third is the tip and belongs on top.
    ry, rx = np.where(mask_r > 0)
    if len(ry):
        y0, y1 = ry.min(), ry.max()
        third = max(1, (y1 - y0) // 3)
        def _width(y_lo, y_hi):
            band = mask_r[y_lo:y_hi, :]
            widths = [np.count_nonzero(row) for row in band if np.any(row)]
            return float(np.mean(widths)) if widths else 0.0
        top_w = _width(y0, y0 + third)
        bot_w = _width(y1 - third, y1)
        if top_w > bot_w:  # wider end currently on top -- flip 180
            bin_r = cv2.rotate(bin_r, cv2.ROTATE_180)
            mask_r = cv2.rotate(mask_r, cv2.ROTATE_180)
    return bin_r, mask_r


def generate(
    frames: List[np.ndarray],
    angles_deg: List[float],
    lap_scores: Optional[List[Optional[float]]] = None,
) -> Tuple[Optional[np.ndarray], dict]:
    """
    Build the AFIS-style binary print from the best face-on frame.

    frames      : BGR or grayscale frames (the same binned list fed to SfM).
    angles_deg  : per-frame sweep angle (0 = face-on plain impression).
    lap_scores  : optional per-frame sharpness (client laplacianScore).

    Returns (binary uint8 image or None, params dict for Firestore).
    """
    params: dict = {'afisSource': None, 'afisWavelengthPx': None, 'afisMask': None}
    if not frames:
        return None, params

    # Rank face-on candidates by SERVER-computed ridge-band energy — the
    # client's laplacianScore is a whole-preview-frame proxy captured before
    # the still fired (observed identical across a burst), so it can't
    # distinguish the sharp still from a soft one. A DoG band-energy probe on
    # a centre crop is ~ms per frame and measures the actual ridge signal.
    def _ridge_energy(frame: np.ndarray) -> float:
        g = frame if frame.ndim == 2 else cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        h, w = g.shape
        c = g[h // 4: 3 * h // 4, w // 4: 3 * w // 4].astype(np.float32)
        lo = cv2.GaussianBlur(c, (0, 0), 1.2)
        hi = cv2.GaussianBlur(c, (0, 0), 3.5)
        return float(np.abs(lo - hi).mean())

    face_on = [i for i in range(len(frames))
               if abs(float(angles_deg[i])) <= _FACE_ON_MAX_DEG and frames[i] is not None]
    candidates = face_on if face_on else [i for i in range(len(frames)) if frames[i] is not None]
    if not candidates:
        return None, params
    order = sorted(candidates, key=lambda i: -_ridge_energy(frames[i]))
    src = frames[order[0]]
    params['afisSource'] = {
        'frameIndex': int(order[0]),
        'angleDeg': float(round(float(angles_deg[order[0]]), 1)),
    }

    gray = src if src.ndim == 2 else cv2.cvtColor(src, cv2.COLOR_BGR2GRAY)
    g8 = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(gray.astype(np.uint8))

    norm = _normalize(g8)
    orient = _orientation_field(norm)
    wl = _ridge_wavelength(norm, orient)
    params['afisWavelengthPx'] = float(round(wl, 1))
    enh = _gabor_enhance(norm, orient, wl)

    mask = _unet_mask(gray)
    params['afisMask'] = 'unet' if mask is not None else 'coherence_hull'
    if mask is None:
        mask = _coherence_hull_mask(g8)
    if mask is None or (mask > 0).mean() < 0.03:
        logger.warning('AFIS print: no usable thumb mask — skipping')
        return None, params
    # A mask covering most of the frame means segmentation failed to isolate
    # the thumb (the whole photo, background included, would be Gabor-noised).
    # Better to emit nothing than a full-frame ridge-noise field.
    if (mask > 0).mean() > 0.55:
        logger.warning('AFIS print: mask covers %.0f%% of frame — segmentation '
                       'failed, skipping', 100 * (mask > 0).mean())
        params['afisMask'] = params['afisMask'] + '_rejected'
        return None, params

    binimg = 255 - (enh < 0).astype(np.uint8) * 255   # ridges black on white
    binimg[mask == 0] = 255
    binimg, mask = _upright_rotate(binimg, mask)
    params['afisRotated'] = True
    ys, xs = np.where(mask > 0)
    m = 30
    y0, x0 = max(0, ys.min() - m), max(0, xs.min() - m)
    y1 = min(binimg.shape[0], ys.max() + m)
    x1 = min(binimg.shape[1], xs.max() + m)
    return binimg[y0:y1, x0:x1], params
