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
_TARGET_PERIOD = 9.0      # ridge period (px) to normalise to — ~500 DPI domain
_STACK_MAX = 4            # max same-pose frames to align+average (denoise)
_STACK_ANGLE_DEG = 5.0    # only stack frames within this angle of the sharpest

# Gabor/CLAHE tuning (2026-07-15): swept against the local ResNet18 proxy on 5
# real captures whose actual nfiq2Score is known (2 good/72, 2 bad/7, 1
# worst-case/1 — see Notion session log), reproducing main.py's scoring
# exactly enough to match its recorded proxy values to within ~0.1. Gamma and
# sigma-ratio moves were broadly positive (or flat) on EVERY case tested,
# good and bad alike, so they're low-risk. Not yet confirmed against real
# NFIQ2 (the sidecar can't be reached from this sandbox) — validate on the
# next real device captures before trusting the absolute gain.
_GABOR_SIGMA_RATIO = 0.65   # was 0.56 -- slightly wider envelope, helped coarser-ridge (larger native wavelength) captures without hurting clean ones
_GABOR_GAMMA = 0.85         # was 0.60 -- monotonically improved every one of the 5 real test cases as it rose toward 1.0; kept <1.0 to preserve some orientation-selectivity rather than going fully isotropic
_FEATHER_SIGMA = 2.5        # was 4.0 -- small, uniformly-nonnegative gain across all 5 cases
_FREQ_SCALE_MIN = 0.7       # was 0.35 -- the real Firestore correlation (24 scored captures)
# shows every capture whose winning variant applied a rescale below ~0.7 (i.e. shrinking
# native ridge period by more than ~30%) scored catastrophically on REAL nfiq2Score
# regardless of variant (722ae3b0: scale 0.5 -> real 7; d7dd0c68: scale 0.9 -> real 5),
# while captures needing little/no rescale did well (c34911b5, 3e54236a: both real 72).
# Capping how aggressive the resample is allowed to get also improved the LOCAL proxy
# score substantially on the same real bad case (722ae3b0: 65.3 -> 72.6). Left as a
# floor rather than disabling freq_normalize entirely -- a mild correction still helps
# (d7dd0c68's 0.9 scale case, while bad, wasn't as bad as the 0.5/0.45 cases).

_MASK_COVER_DILATE = 1.3    # grow the guide oval by this factor to form the OUTER
# BOUND for coverage expansion: the flash-diff/U-Net-detected real pad is used as the
# mask (covering more of the pad incl. the tip, which the tight guide oval cuts off --
# CTO: "entire thumbpad should be covered"), then clipped to this dilated guide so it can
# never wander onto background or the hand behind the pad. 1.0 == legacy behaviour
# (intersect with the bare guide -> shrink only). Set to 1.3 rather than a larger value
# from a local sweep on the 14-capture set: 1.3 adds real pad/tip coverage while a more
# aggressive 1.6 measurably HURT a capture whose guide was already well-placed
# (c34911b5: local NFIQ2 79->68) by reaching into poor-contact periphery. The metrics
# available in-sandbox (real NFIQ2, foolable; bozorth vs a single weak ink scan,
# noise-limited) cannot finely arbitrate a fidelity gain from coverage, so this is a
# conservative choice honouring the explicit "cover the pad" ask with limited downside --
# confirm on-device before trusting further expansion. See CLAUDE.md "whole-pad coverage".

# Ridge-continuity tuning (2026-07-15, round 2): CTO reported ridges not
# connecting/flowing smoothly on real device captures. Tried morphological
# closing/opening directly on the binarized print first -- REJECTED, actively
# harmful: any kernel size large enough to visibly bridge a gap (>=5px) is
# already comparable to the native ridge spacing itself and collapses
# adjacent ridges together (proxy score craters from ~70 to ~38 on all 3 real
# test cases). Orientation-field smoothing was the real fix: swept 5.0 (old
# default) up to 28.0 against the same 3 real captures (nfiq2Score 72/63/0) --
# monotonically positive up to ~15, peaking there, mild falloff beyond.
# Visually confirmed: dramatically smoother, naturally-flowing ridge curves
# vs. the old choppy/jagged pattern, on both the good and the bad case.
_ORIENT_SMOOTH = 15.0       # was 5.0 -- fixes the actual "ridges don't flow
# smoothly" complaint; do NOT try morphological close/open on the binary
# print for this instead, it was tested and made things worse (see above).


def _normalize(img: np.ndarray, m0: float = 100.0, v0: float = 100.0) -> np.ndarray:
    img = img.astype(np.float32)
    m, v = img.mean(), max(img.var(), 1e-6)
    return m0 + np.sqrt(v0 * (img - m) ** 2 / v) * np.sign(img - m)


def _orientation_field(img: np.ndarray, bsize: int = _BLOCK, smooth: float = _ORIENT_SMOOTH) -> np.ndarray:
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


_STACK_ALIGN_PX = 512     # ECC alignment resolution (warp scaled to full-res)


def _align_face_on_stack(cand: List[Optional[np.ndarray]]) -> Optional[List[np.ndarray]]:
    """ECC-affine align near-identical same-pose frames to the sharpest
    (cand[0]) reference and return the aligned float32 stack (reference first).

    The alignment warp is estimated on downscaled (_STACK_ALIGN_PX) copies for
    speed, then scaled up and applied at full resolution -- ECC on full-res
    burst stills is far too slow for the Cloud Function budget. Returns None if
    fewer than 2 usable frames survive the correlation guard, so the caller
    keeps the single sharpest frame (stacking must never degrade the print)."""
    grays = [c if c is None or c.ndim == 2 else cv2.cvtColor(c, cv2.COLOR_BGR2GRAY)
             for c in cand]
    grays = [g for g in grays if g is not None]
    if len(grays) < 2:
        return None
    ref = grays[0]
    h, w = ref.shape[:2]
    s = _STACK_ALIGN_PX / max(h, w)
    small = (max(1, int(w * s)), max(1, int(h * s)))
    cl = cv2.createCLAHE(3.0, (8, 8))
    ref_small = cl.apply(cv2.resize(ref, small))
    # Scale matrix mapping small-space warp to full-res.
    up = np.array([[1 / s, 0, 0], [0, 1 / s, 0]], dtype=np.float32)
    dn = np.array([[s, 0, 0], [0, s, 0], [0, 0, 1]], dtype=np.float32)
    crit = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 80, 1e-4)
    stack = [ref.astype(np.float32)]
    for g in grays[1:]:
        gg = g if g.shape[:2] == (h, w) else cv2.resize(g, (w, h))
        try:
            warp = np.eye(2, 3, dtype=np.float32)
            _, warp = cv2.findTransformECC(
                ref_small, cl.apply(cv2.resize(gg, small)), warp,
                cv2.MOTION_AFFINE, crit, None, 5)
            # full-res warp = up · [warp;0 0 1] · dn
            warp_full = (up @ np.vstack([warp, [0, 0, 1]]) @ dn).astype(np.float32)
            aligned = cv2.warpAffine(gg, warp_full, (w, h), flags=cv2.INTER_LINEAR)
            if float(np.corrcoef(aligned.ravel(), ref.ravel())[0, 1]) > 0.5:
                stack.append(aligned.astype(np.float32))
        except cv2.error:
            continue
    if len(stack) < 2:
        return None
    return stack


def _stack_face_on(cand: List[Optional[np.ndarray]]) -> Optional[np.ndarray]:
    """Align (ECC affine) and AVERAGE near-identical same-pose frames -> a
    denoised full-resolution grayscale (pure noise reduction). Returns None if
    fewer than 2 usable frames survive."""
    stack = _align_face_on_stack(cand)
    if stack is None:
        return None
    return np.mean(np.stack(stack), axis=0).astype(np.uint8)


def _focus_stack_face_on(cand: List[Optional[np.ndarray]]) -> Optional[np.ndarray]:
    """Align (ECC affine) same-pose frames, then combine by LOCAL SHARPNESS
    rather than a flat mean -- classic focus stacking. Each output pixel is a
    sharpness-weighted blend across the aligned frames, so the region that was
    best-focused in ANY frame dominates there. This targets the pad's curved
    edges going soft under a single frame's shallow macro depth-of-field:
    different frames (slightly different hand distance across the burst) hold
    focus at different radii, and this keeps the sharpest of each.

    Weighted blend (not hard per-pixel argmax) to avoid seam artifacts where
    the sharpest-frame index would flip abruptly. Returns None if fewer than 2
    frames align, so the caller falls back to the single sharpest frame."""
    stack = _align_face_on_stack(cand)
    if stack is None:
        return None
    # Local sharpness energy per frame: |Laplacian| smoothed to a small window
    # so the weight reflects neighbourhood focus, not single-pixel noise.
    weights = []
    for g in stack:
        lap = np.abs(cv2.Laplacian(g, cv2.CV_32F, ksize=3))
        weights.append(cv2.GaussianBlur(lap, (0, 0), 4.0) + 1e-3)
    w = np.stack(weights)                      # (N, H, W)
    w /= w.sum(axis=0, keepdims=True)
    out = (w * np.stack(stack)).sum(axis=0)
    return np.clip(out, 0, 255).astype(np.uint8)


def _fuse_flash_ambient(ambient: np.ndarray, flash: np.ndarray,
                        mode: str = 'maxc') -> Optional[np.ndarray]:
    """Fuse a SAME-POSE ambient+flash pair into one enhanced grayscale.

    Flash and ambient stills of the same pose carry complementary ridge
    signal: the flash exposure gives strong specular contrast where the pad is
    in closest contact (ridge crests catch the light), while the ambient
    exposure reads ridge/valley modulation across the whole pad without
    blow-out. Because it's the same pose this is PURE signal fusion with no
    geometric distortion (unlike multi-angle reconstruction, which warps
    oblique views and hurts NFIQ).

    Registers flash→ambient (ECC affine — the hand drifts slightly between the
    two exposures) then combines:
      'maxc' : per-_BLOCK-px block, take whichever source has higher ridge
               coherence. Biggest, most consistent NFIQ gain in testing
               (+5–7 on the two hardest real captures).
      'avg'  : intensity average — cross-illumination denoise; wins on
               already-clean captures.
    Returns a fused uint8 gray, or None if the pair can't be registered (caller
    then skips the fusion variant and keeps the single-source renderings)."""
    if ambient is None or flash is None:
        return None
    ga = ambient if ambient.ndim == 2 else cv2.cvtColor(ambient, cv2.COLOR_BGR2GRAY)
    gf = flash if flash.ndim == 2 else cv2.cvtColor(flash, cv2.COLOR_BGR2GRAY)
    if gf.shape[:2] != ga.shape[:2]:
        gf = cv2.resize(gf, (ga.shape[1], ga.shape[0]))
    cl = cv2.createCLAHE(3.0, (8, 8))
    warp = np.eye(2, 3, dtype=np.float32)
    try:
        _, warp = cv2.findTransformECC(
            cl.apply(ga), cl.apply(gf), warp, cv2.MOTION_AFFINE,
            (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 100, 1e-4), None, 5)
        gf_reg = cv2.warpAffine(gf, warp, (ga.shape[1], ga.shape[0]),
                                flags=cv2.INTER_LINEAR)
    except cv2.error:
        return None
    if float(np.corrcoef(gf_reg.ravel(), ga.ravel())[0, 1]) < 0.3:
        return None   # not actually the same view — don't blend
    if mode == 'avg':
        return ((ga.astype(np.float32) + gf_reg.astype(np.float32)) / 2).astype(np.uint8)

    def _coh(gray: np.ndarray) -> np.ndarray:
        gg = gray.astype(np.float32)
        gx = cv2.Sobel(gg, cv2.CV_32F, 1, 0, ksize=3)
        gy = cv2.Sobel(gg, cv2.CV_32F, 0, 1, ksize=3)
        gxx = cv2.boxFilter(gx * gx, -1, (_BLOCK, _BLOCK))
        gyy = cv2.boxFilter(gy * gy, -1, (_BLOCK, _BLOCK))
        gxy = cv2.boxFilter(gx * gy, -1, (_BLOCK, _BLOCK))
        return np.sqrt((gxx - gyy) ** 2 + 4 * gxy ** 2) / (gxx + gyy + 1e-6)

    ca, cf = _coh(ga), _coh(gf_reg)
    if mode == 'soft':
        # Feathered coherence weighting: each pixel is a blend biased toward the
        # locally higher-coherence exposure. Smoother than a hard per-block
        # switch (which leaves seams the orientation field then trips on), while
        # still favouring the exposure that resolves ridges best in each region.
        w = cv2.GaussianBlur(ca / (ca + cf + 1e-6), (0, 0), _BLOCK)
        return (w * ga.astype(np.float32) +
                (1.0 - w) * gf_reg.astype(np.float32)).astype(np.uint8)
    # 'maxc': hard per-block selection.
    return np.where(ca >= cf, ga.astype(np.float32),
                    gf_reg.astype(np.float32)).astype(np.uint8)


_MOSAIC_YAW_DEG   = 12.0   # only borrow from THIS-lightly-yawed neighbours
_MOSAIC_YAW_MIN   = 4.0    # ...but far enough to add genuine edge coverage
_MOSAIC_MAX_SIDE  = 6      # cap side frames (registration cost)
_MOSAIC_REG_PX    = 640    # ECC registration resolution (warp applied full-res)


def _block_coherence(gray: np.ndarray, blur: float = 8.0) -> np.ndarray:
    gg = gray.astype(np.float32)
    gx = cv2.Sobel(gg, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gg, cv2.CV_32F, 0, 1, ksize=3)
    gxx = cv2.boxFilter(gx * gx, -1, (_BLOCK, _BLOCK))
    gyy = cv2.boxFilter(gy * gy, -1, (_BLOCK, _BLOCK))
    gxy = cv2.boxFilter(gx * gy, -1, (_BLOCK, _BLOCK))
    c = np.sqrt((gxx - gyy) ** 2 + 4 * gxy ** 2) / (gxx + gyy + 1e-6)
    return cv2.GaussianBlur(c, (0, 0), blur)


def _front_anchored_mosaic(front: np.ndarray,
                           sides: List[np.ndarray]) -> Tuple[Optional[np.ndarray], int]:
    """Distortion-free minimal-yaw reconstruction.

    Keeps the sharp FACE-ON `front` frame as the undistorted geometric anchor
    and only BORROWS ridge detail from lightly-yawed side frames in the regions
    where they register well AND resolve ridges better than the front (the pad
    edges that curve away from the camera). At the small yaw this is restricted
    to (<=_MOSAIC_YAW_DEG) the ridge foreshortening is a few percent, so the
    borrowed edge ridges land at near-true scale -- unlike a full cylindrical
    unwrap of wide-baseline oblique views, which stretches ridges and lowers
    NFIQ. Composite is a per-pixel coherence-weighted average anchored on the
    front's own coherence, so the centre stays exactly the front frame.

    Homographies are estimated on _MOSAIC_REG_PX copies and applied at full
    resolution (ECC on full-res stills is too slow for the function budget).
    Returns (mosaic uint8, n_sides_used); n_used==0 means it degenerates to the
    front frame."""
    fh, fw = front.shape[:2]
    acc = front.astype(np.float32) * _block_coherence(front)
    wsum = _block_coherence(front).copy()
    s = _MOSAIC_REG_PX / max(fh, fw)
    small = (max(1, int(fw * s)), max(1, int(fh * s)))
    cl = cv2.createCLAHE(3.0, (8, 8))
    ref_small = cl.apply(cv2.resize(front, small))
    up = np.array([[1 / s, 0, 0], [0, 1 / s, 0], [0, 0, 1]], dtype=np.float32)
    dn = np.array([[s, 0, 0], [0, s, 0], [0, 0, 1]], dtype=np.float32)
    crit = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 60, 1e-4)
    used = 0
    for sd in sides:
        g = sd if sd.ndim == 2 else cv2.cvtColor(sd, cv2.COLOR_BGR2GRAY)
        if g.shape[:2] != (fh, fw):
            g = cv2.resize(g, (fw, fh))
        try:
            warp = np.eye(3, 3, dtype=np.float32)
            _, warp = cv2.findTransformECC(
                ref_small, cl.apply(cv2.resize(g, small)), warp,
                cv2.MOTION_HOMOGRAPHY, crit, None, 5)
            warp_full = (up @ warp @ dn).astype(np.float32)
            reg = cv2.warpPerspective(g, warp_full, (fw, fh), flags=cv2.INTER_LINEAR)
        except cv2.error:
            continue
        if float(np.corrcoef(reg.ravel(), front.ravel())[0, 1]) < 0.45:
            continue
        valid = (reg > 0).astype(np.float32)
        cs = _block_coherence(reg) * valid
        acc += reg.astype(np.float32) * cs
        wsum += cs
        used += 1
    if used == 0:
        return None, 0
    return (acc / np.maximum(wsum, 1e-6)).astype(np.uint8), used


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


def _flash_diff_mask(ambient_burst: Optional[List[np.ndarray]],
                      flash_burst: Optional[List[np.ndarray]],
                      shape: Tuple[int, int]) -> Optional[np.ndarray]:
    """Content-aware thumb mask via flash-minus-ambient differencing (see
    sfm_pipeline._segment_via_flash_diff) — picks the first ambient/flash
    pair whose shape matches the frame being processed. Used to refine the
    guide_region mask in generate(): the guide silhouette is a static,
    purely geometric region with zero awareness of what's actually in the
    frame, so background bleeding in past its edges (real-world alignment
    isn't pixel-perfect) still gets Gabor-enhanced as if it were ridge
    content. This is the same tier that already proved itself against real
    captures for the (currently unguided-only) segmentation fallback —
    reused here rather than re-derived. Best-effort: returns None on any
    failure, same contract as _unet_mask."""
    try:
        import sfm_pipeline
        ab = [g for g in (ambient_burst or []) if g is not None]
        fb = [g for g in (flash_burst or []) if g is not None]
        for a, f in zip(ab, fb):
            a_gray = a if a.ndim == 2 else cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)
            f_gray = f if f.ndim == 2 else cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
            if a_gray.shape != shape or f_gray.shape != shape:
                continue
            result = sfm_pipeline._segment_via_flash_diff(a_gray, f_gray, ksize=7)
            if result is not None:
                mask, _tx, _ty = result
                return mask
        return None
    except Exception as e:              # noqa: BLE001 — mask refinement is best-effort
        logger.warning('flash-diff mask unavailable for AFIS print: %s', e)
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


def _ridge_texture_strength(img: np.ndarray, orient: np.ndarray, bsize: int = 48, stride: int = 16) -> np.ndarray:
    """
    Per-PIXEL continuous ridge-periodicity strength (not a thresholded
    block mask). A crease has a strong local gradient just like a ridge
    does -- gradient coherence alone can't tell them apart. A crease does
    NOT repeat at a short, consistent period the way a bank of parallel
    ridges does, though -- autocorrelating each window along its own local
    orientation (same technique as _ridge_wavelength) and reading off the
    first peak's strength is a specific "is this actually fingerprint
    ridge" signal (checked against a real capture: true pad windows median
    0.254, background median 0.023 -- real separation). Overlapping windows
    (stride < bsize) rather than a coarser upsampled grid: each window has
    enough samples for a stable estimate, and the dense overlap makes the
    field smooth by construction.
    """
    h, w = img.shape
    ys = list(range(0, max(1, h - bsize), stride)) or [0]
    xs = list(range(0, max(1, w - bsize), stride)) or [0]
    grid = np.zeros((len(ys), len(xs)), dtype=np.float32)
    for iy, y in enumerate(ys):
        for ix, x in enumerate(xs):
            blk = img[y:y + bsize, x:x + bsize]
            if blk.shape != (bsize, bsize) or blk.std() < 8:
                continue
            ang = orient[min(y + bsize // 2, h - 1), min(x + bsize // 2, w - 1)]
            M = cv2.getRotationMatrix2D((bsize / 2, bsize / 2), np.degrees(ang), 1.0)
            rot = cv2.warpAffine(blk, M, (bsize, bsize))
            sig = rot.mean(axis=0)
            sig = sig - sig.mean()
            if sig.std() < 1e-6:
                continue
            ac = np.correlate(sig, sig, 'full')[bsize - 1:]
            ac = ac / max(ac[0], 1e-6)
            d = np.diff(ac)
            peaks = np.where((d[:-1] > 0) & (d[1:] <= 0))[0] + 1
            peaks = peaks[peaks > 3]   # no upper bound -- native-res ridge period
            # varies with capture distance/resolution (matches _ridge_wavelength,
            # which clamps only its final aggregate, not each candidate peak)
            if len(peaks):
                grid[iy, ix] = max(0.0, float(ac[peaks[0]]))
    return cv2.resize(grid, (w, h), interpolation=cv2.INTER_LINEAR)


def _crop_to_pad_mask(gray: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """
    Tighten a thumb-silhouette mask down to just the ridge-bearing pad,
    dropping the DIP crease and everything beyond it (lower thumb segment,
    palm). The U-Net/hull masks segment "thumb-shaped skin" -- on a close,
    wide-framed capture that's far more than the pad.

    Earlier attempts classified individual 2D blocks/windows as ridge-like
    or not (first by gradient coherence, then by ridge periodicity) and
    tried to consolidate the result into one connected region. Both failed:
    coherence can't tell a crease from a ridge (a crease's strong local
    gradient reads as "coherent" too), and periodicity -- though a real,
    measurably discriminating signal -- turned out too spatially sparse at
    any single block scale to consolidate without either falling back to
    the unchanged mask or fragmenting into unusable islands, even after
    several rounds of tuning window size, stride, and threshold.

    This instead collapses the problem to 1D: project every mask pixel
    onto the mask's own principal (long) axis -- the same axis
    _upright_rotate independently computes for tip-up orientation -- and
    average ridge-texture strength across each thin cross-section
    perpendicular to that axis. A whole cross-section's average is far
    more stable than any single block (the pad's dense parallel ridges
    keep the average high; the crease's one sparse line plus the flat skin
    around it drag it down), so finding where the profile falls off from
    the pad's core is a single robust threshold crossing in each
    direction, not a fragile 2D consolidation problem.
    """
    orient = _orientation_field(_normalize(gray))
    strength = _ridge_texture_strength(gray, orient)

    ys, xs = np.where(mask > 0)
    if len(ys) < 200:
        return mask
    pts = np.column_stack([xs, ys]).astype(np.float64)
    center = pts.mean(axis=0)
    _, s, vt = np.linalg.svd(pts - center, full_matrices=False)
    if s[1] < 1e-6 or (s[0] / s[1]) < 1.15:
        return mask   # no clear long axis -- leave alone, same guard as _upright_rotate
    axis = vt[0]

    proj = (pts - center) @ axis   # every mask pixel's 1D position along the long axis
    vals = strength[ys, xs]

    lo, hi = float(proj.min()), float(proj.max())
    if hi - lo < 20:
        return mask
    n_bins = max(10, int((hi - lo) / 8))
    bin_idx = np.clip(((proj - lo) / (hi - lo) * (n_bins - 1)).astype(int), 0, n_bins - 1)
    bin_sum = np.bincount(bin_idx, weights=vals, minlength=n_bins)
    bin_cnt = np.bincount(bin_idx, minlength=n_bins)
    profile = np.where(bin_cnt > 0, bin_sum / np.maximum(bin_cnt, 1), 0.0).astype(np.float32)
    profile = cv2.GaussianBlur(profile.reshape(-1, 1), (0, 0), 1.5).flatten()

    # Pick the widest sustained band of periodicity, not simply the single
    # tallest bin. A narrow, spurious high-periodicity spot (a stray
    # reflection, a sharp-edged object at the frame's border) can outscore
    # the real ridge band on peak height alone while covering only a
    # handful of bins -- verified on a real capture where a 4-bin edge
    # spike (0.223) beat a genuine ~35-bin ridge plateau (peak 0.104) and
    # collapsed the kept region to nothing. Scoring contiguous above-floor
    # runs by total area (width x strength) favours the sustained plateau
    # a real print pad produces over a thin artifact spike.
    floor_val = 0.05
    above = profile >= floor_val
    runs = []
    start = None
    for i in range(n_bins):
        if above[i] and start is None:
            start = i
        elif not above[i] and start is not None:
            runs.append((start, i - 1))
            start = None
    if start is not None:
        runs.append((start, n_bins - 1))

    candidates = [(float(profile[a:b + 1].sum()), a, b)
                  for a, b in runs if float(profile[a:b + 1].max()) >= 0.10]
    if not candidates:
        return mask   # no confident, sustained ridge core found -- keep the original mask
    _, lo_bin, hi_bin = max(candidates, key=lambda c: c[0])

    bin_width = (hi - lo) / (n_bins - 1)
    keep_lo = lo - 0.5 * bin_width + lo_bin * bin_width
    keep_hi = lo - 0.5 * bin_width + (hi_bin + 1) * bin_width
    keep = (proj >= keep_lo) & (proj <= keep_hi)

    pad_mask = np.zeros_like(mask)
    pad_mask[ys[keep], xs[keep]] = 255
    pad_mask = cv2.morphologyEx(pad_mask, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    # Fraction of the ORIGINAL mask kept, not of the whole frame -- the
    # whole point of this function is to keep a genuine SUBSET of the mask
    # (excluding the crease/hand), so a correct result is naturally a small
    # fraction of the full image whenever the mask itself is. An earlier
    # version checked (pad_mask > 0).mean() against the whole image, which
    # rejected every real result as "too aggressive" purely because the
    # mask itself was a minority of the frame -- not because the crop was
    # actually wrong.
    kept_frac_of_mask = (pad_mask > 0).sum() / max((mask > 0).sum(), 1)
    if kept_frac_of_mask < 0.05:
        return mask   # too aggressive -- keep the original rather than emit nothing
    return pad_mask


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


def _superellipse_mask(shape: Tuple[int, int], region: dict) -> Optional[np.ndarray]:
    """
    Rasterize the app's guide silhouette into a binary pad mask.

    `region` is in the SAME normalized (0-1) coordinate space as the frame
    `generate()` receives (the center-square-cropped frame — main.py does the
    full-still → cropped-frame remap before calling us, so here we only scale
    by the frame's own dimensions). Shape is a superellipse
    |x/rx|^n + |y/ry|^n <= 1 (n≈2.5 reads as a rounded thumb pad, not a plain
    oval), matching what capture_pad_silhouette_overlay.dart draws so the
    region the user visually fills IS the mask.
    """
    h, w = shape
    cx = float(region['cx']) * w
    cy = float(region['cy']) * h
    rx = max(1.0, float(region['rx']) * w)
    ry = max(1.0, float(region['ry']) * h)
    n = float(region.get('n', 2.5))
    ys, xs = np.mgrid[0:h, 0:w]
    d = (np.abs((xs - cx) / rx) ** n) + (np.abs((ys - cy) / ry) ** n)
    mask = (d <= 1.0).astype(np.uint8) * 255
    if (mask > 0).sum() < 200:
        return None
    return mask


def _upright_from_tip(binimg: np.ndarray, mask: np.ndarray,
                      tip_angle_deg: float) -> Tuple[np.ndarray, np.ndarray]:
    """
    Deterministic tip-up rotation for guided captures.

    The app draws the silhouette tip-up on the portrait screen, so it knows
    exactly which way the tip points once the still is rotated into landscape.
    `tip_angle_deg` is that direction in the frame's own pixel space (standard
    math convention: 0° = +x/right, 90° = +y/up). We rotate the content so the
    tip ends up pointing UP -- no PCA guess (which is unstable on a near-
    symmetric pad) and no width heuristic. A rolled/AFIS print is always
    presented upright, so this is a real correction.
    """
    # Image y runs downward, so "up" on screen is -y. To send a vector at
    # math-angle `tip_angle_deg` to screen-up, rotate the image by this much
    # (getRotationMatrix2D's positive angle is CCW in math space).
    rot_deg = 90.0 - tip_angle_deg
    h, w = mask.shape
    center = (w / 2.0, h / 2.0)
    diag = int(np.ceil(np.hypot(h, w)))
    pad_y, pad_x = (diag - h) // 2 + 5, (diag - w) // 2 + 5
    bin_p = cv2.copyMakeBorder(binimg, pad_y, pad_y, pad_x, pad_x,
                               cv2.BORDER_CONSTANT, value=255)
    mask_p = cv2.copyMakeBorder(mask, pad_y, pad_y, pad_x, pad_x,
                                cv2.BORDER_CONSTANT, value=0)
    center_p = (center[0] + pad_x, center[1] + pad_y)
    M = cv2.getRotationMatrix2D(center_p, rot_deg, 1.0)
    size_p = (bin_p.shape[1], bin_p.shape[0])
    bin_r = cv2.warpAffine(bin_p, M, size_p, borderValue=255)
    mask_r = cv2.warpAffine(mask_p, M, size_p, borderValue=0)
    return bin_r, mask_r


def _pyfing_denoise(g8: np.ndarray, mask: np.ndarray, wl: float) -> Optional[np.ndarray]:
    """Runs the pyfing sidecar's SNFEN model as a denoising pre-pass and
    returns a full-frame-shaped CONTINUOUS-TONE image in pyfing's OWN
    convention (ridges bright, background dark) -- not yet inverted,
    not yet binarized. Feeds `_pyfing_enhance` (pure-pyfing variant) and
    `enhance='pyfingHybrid'` in generate() (pyfing-then-Gabor hybrid).

    Crops to the mask's own bounding box and grey-fills outside it before
    sending -- pyfing's own internal segmentation doesn't need to re-solve
    backgrounds we've already excluded via guide+flashdiff/U-Net. Pre-
    rescales the crop to the ~500 DPI domain itself (same convention as
    mindtct_client._normalize_dpi -- resample toward _TARGET_PERIOD) and
    always calls pyfing with dpi=500, rather than passing our own measured
    dpi through: pyfing's own Snfen.run() has a real bug when dpi != its
    dnn_input_dpi (500) -- it resizes image/mask/orientation to a scaled
    size but resizes ridge_periods to the ORIGINAL unscaled size, raising
    a numpy dstack shape-mismatch every time (reproduced standalone: a
    465px crop at dpi=300 crashes). Pre-normalizing ourselves and always
    passing dpi=500 sidesteps that internal rescale path entirely instead
    of working around a third-party bug with try/except.

    Returns None on any failure (sidecar not configured, network error,
    degenerate crop) -- caller treats this exactly like a failed fuse
    pair: skip this variant, single-source renderings still stand."""
    try:
        import pyfing_client
    except ImportError:
        return None

    ys, xs = np.where(mask > 0)
    if len(ys) < 200:
        return None
    y0, x0 = max(0, ys.min() - 10), max(0, xs.min() - 10)
    y1, x1 = min(g8.shape[0], ys.max() + 10), min(g8.shape[1], xs.max() + 10)
    crop = g8[y0:y1, x0:x1].copy()
    crop_mask = mask[y0:y1, x0:x1]
    crop[crop_mask == 0] = 128   # neutral grey outside the mask, not the raw
    # background pixels -- avoids handing pyfing's own segmentation a real
    # background texture to (mis)classify, same as the validated test crop.

    scale = float(np.clip(_TARGET_PERIOD / max(wl, 1.0), 0.3, 3.0))
    orig_shape = crop.shape
    if abs(scale - 1.0) > 0.02:
        new_w = max(32, int(round(crop.shape[1] * scale)))
        new_h = max(32, int(round(crop.shape[0] * scale)))
        interp = cv2.INTER_AREA if scale < 1.0 else cv2.INTER_CUBIC
        crop_scaled = cv2.resize(crop, (new_w, new_h), interpolation=interp)
    else:
        crop_scaled = crop

    enhanced_scaled = pyfing_client.enhance_fingerprint(crop_scaled, method='SNFEN', dpi=500)
    if enhanced_scaled is None or enhanced_scaled.shape != crop_scaled.shape:
        return None
    enhanced = cv2.resize(enhanced_scaled, (orig_shape[1], orig_shape[0]),
                           interpolation=cv2.INTER_CUBIC) if crop_scaled.shape != orig_shape else enhanced_scaled

    # Paste back into a full-frame canvas (native g8 outside the crop) so
    # the result can feed straight into _normalize/_orientation_field --
    # both only look at content inside `mask`, which is re-applied after
    # Gabor same as every other enhance path.
    full = g8.copy()
    full[y0:y1, x0:x1] = enhanced
    return full


def _pyfing_enhance(g8: np.ndarray, mask: np.ndarray, wl: float) -> Optional[np.ndarray]:
    """Alternative to _gabor_enhance: routes the masked pad through pyfing's
    SNFEN model and uses ITS output directly as the final print (inverted
    from pyfing's ridges-bright convention to this project's ridges-black
    convention). See CLAUDE.md "Pretrained fingerphoto-enhancement models"
    -- first real test scored competitively with this module's own tuned
    Gabor output (bozorth3 vs the CTO's ink scan: 7 vs 6), but measured
    across all 14 real front_only_v1 captures, never beat the tuned Gabor
    pipeline on real NFIQ2 (see CLAUDE.md's "pyfing wired in" section).
    See `enhance='pyfingHybrid'` in generate() for a second way to use
    pyfing (as a denoise pre-pass feeding this project's own Gabor+
    binarize chain, rather than as a standalone final image) motivated by
    the CTO's observation that pyfing's own image convention (continuous-
    tone, ridges bright) differs from what this pipeline's Gabor tuning
    (gamma/sigma/freq-scale/orient-smooth) has always been calibrated
    against (hard-binarized, ridges black) -- a plain invert isn't the
    same transformation as that binarization."""
    full = _pyfing_denoise(g8, mask, wl)
    if full is None:
        return None
    return 255 - full   # pyfing: ridges bright -> project: ridges dark (still continuous-tone)
    # caller (generate()) applies `binimg[mask == 0] = 255` right after,
    # same as every other enhance path -- no need to duplicate it here.


def generate(
    frames: List[np.ndarray],
    angles_deg: List[float],
    lap_scores: Optional[List[Optional[float]]] = None,
    ambient_frames: Optional[List[Optional[np.ndarray]]] = None,
    flash_frames: Optional[List[Optional[np.ndarray]]] = None,
    ambient_burst: Optional[List[np.ndarray]] = None,
    flash_burst: Optional[List[np.ndarray]] = None,
    freq_normalize: bool = False,
    stack: bool = False,
    focus_stack: bool = False,
    fuse: Optional[str] = None,
    mosaic: bool = False,
    guide_region: Optional[dict] = None,
    enhance: str = 'gabor',
) -> Tuple[Optional[np.ndarray], dict]:
    """
    Build the AFIS-style binary print from the best face-on frame.

    frames         : BGR or grayscale frames (the same binned list fed to SfM).
    angles_deg     : per-frame sweep angle (0 = face-on plain impression).
    lap_scores     : optional per-frame sharpness (client laplacianScore).
    ambient_frames : optional per-index ambient exposure for each bin (or None).
    flash_frames   : optional per-index flash exposure for each bin (or None).
                     Same-pose ambient/flash pairs enable `fuse` (see below).
    freq_normalize : resample so the ridge period → _TARGET_PERIOD before Gabor.
    stack          : same-pose burst denoise (align+average).
    mosaic         : front-anchored minimal-yaw reconstruction — borrow edge
                     ridges from lightly-yawed side frames without distorting
                     the front centre. Returns (None, params) if no side frame
                     registers, so single-source renderings still stand.
    ambient_burst  : optional flat list of RAW near-face-on ambient shots (the
    flash_burst      preserved front burst, before binning) for each
                     illumination. Enables fuse='deep'.
    fuse           : 'maxc' | 'avg' — fuse the sharpest face-on bin's ambient +
                     flash exposures instead of using a single source (uses
                     ambient_frames/flash_frames);
                     'deep' — deep-stack ALL preserved raw front-burst shots per
                     illumination (align+average = denoise) THEN fuse the two
                     stacks (uses ambient_burst/flash_burst). Returns
                     (None, params) when the required inputs are absent, so the
                     max-variant caller keeps the single-source renderings.
    enhance        : 'gabor' (default, this module's own tuned Gabor bank) or
                     'pyfing' (routes the masked pad through the pyfing sidecar's
                     SNFEN model instead -- see _pyfing_enhance). Returns
                     (None, params) if the sidecar isn't configured/reachable,
                     so the caller keeps the gabor-based renderings; this can
                     only ever add a candidate, never remove one.

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

    # Flash + ambient fusion. Walk the ridge-energy-ranked face-on candidates
    # and fuse the FIRST bin that has both an ambient and a flash exposure of
    # the same pose (they are already per-bin aligned by the oscillating
    # downloader). This is complementary-illumination signal fusion with no
    # geometric distortion and is the single biggest superprint lever found:
    # +5–7 NFIQ on the hardest captures. Emits None (variant skipped) when no
    # fusable pair exists, so single-source renderings still stand.
    if fuse in ('deep', 'deepMaxc', 'deepSoft'):
        # Deep raw-burst fusion: denoise each illumination by aligning+averaging
        # ALL its preserved near-face-on burst shots, THEN fuse the two clean
        # stacks. Strengthens both fusion inputs before combining — worth
        # +2.5–8.5 NFIQ over the single best shot in testing. Needs the raw
        # front burst preserved past binning (main._download_front_burst).
        #
        # Fusion mode matters for the flash SPECULAR SMUDGE (CTO feedback:
        # "shadows/dark smudges that cover ridge patterns because of too much
        # flash reflection"). Flat 'avg' keeps a blown-out flash centre half-
        # bright, washing out the ridges there; the coherence modes ('maxc'
        # hard per-block, 'soft' feathered) instead take whichever exposure
        # actually RESOLVES ridges in each region, so the ambient exposure
        # wins back the specular-blown centre. Confirmed on a real capture
        # (3e54236a): maxc-fused superprint is a clean, fully-covered whorl
        # with the centre smudge gone, vs. avg's washed centre (real NFIQ2
        # 57->81, bozorth 4->6). All three are scored as separate max-variants
        # in main.py, so the coherence modes can only ever raise the result.
        _deep_mode = {'deep': 'avg', 'deepMaxc': 'maxc', 'deepSoft': 'soft'}[fuse]
        ab = [g for g in (ambient_burst or []) if g is not None]
        fb = [g for g in (flash_burst or []) if g is not None]
        if not ab and not fb:
            return None, params
        da = _stack_face_on(ab) if len(ab) >= 2 else (ab[0] if ab else None)
        df = _stack_face_on(fb) if len(fb) >= 2 else (fb[0] if fb else None)
        if da is not None and da.ndim != 2:
            da = cv2.cvtColor(da, cv2.COLOR_BGR2GRAY)
        if df is not None and df.ndim != 2:
            df = cv2.cvtColor(df, cv2.COLOR_BGR2GRAY)
        if da is not None and df is not None:
            fused = _fuse_flash_ambient(da, df, mode=_deep_mode)
            gray = fused if fused is not None else da
        elif da is not None or df is not None:
            gray = da if da is not None else df
        else:
            return None, params
        params['afisDeepFuse'] = {'nAmb': len(ab), 'nFla': len(fb), 'mode': _deep_mode}
    elif fuse:
        if ambient_frames is None or flash_frames is None:
            return None, params
        # Rank fusion candidates by MOST FACE-ON first (smallest |angle|), then
        # by the weaker of the two exposures' ridge energy — a bin only fuses
        # well if BOTH its ambient and flash are sharp, and an off-centre bin
        # (even if one exposure is very sharp) reintroduces the oblique
        # distortion fusion is meant to avoid. This is deliberately different
        # from the single-source `order` (which maximises one frame's energy).
        def _pair_key(i):
            amb = ambient_frames[i] if i < len(ambient_frames) else None
            fla = flash_frames[i] if i < len(flash_frames) else None
            if amb is None or fla is None:
                return None
            return (abs(float(angles_deg[i])),
                    -min(_ridge_energy(amb), _ridge_energy(fla)))
        pair_cands = sorted((i for i in candidates if _pair_key(i) is not None),
                            key=_pair_key)
        fused = None
        for i in pair_cands:
            fused = _fuse_flash_ambient(ambient_frames[i], flash_frames[i], mode=fuse)
            if fused is not None:
                gray = fused
                params['afisFused'] = fuse
                params['afisFusedBin'] = int(i)
                params['afisFusedAngle'] = float(round(float(angles_deg[i]), 1))
                break
        if fused is None:
            return None, params

    # Front-anchored minimal-yaw reconstruction. Anchor on the sharpest face-on
    # frame (order[0]) and borrow edge ridge detail from lightly-yawed
    # neighbours. Distortion-free because the yaw is tiny and the front centre
    # is preserved; adds genuine pad-edge coverage the single frame lacks.
    if mosaic and not fuse:
        front_g = gray
        sides = [frames[i] for i in range(len(frames))
                 if _MOSAIC_YAW_MIN < abs(float(angles_deg[i])) <= _MOSAIC_YAW_DEG
                 and frames[i] is not None]
        sides = sorted(sides, key=lambda f: -_ridge_energy(f))[:_MOSAIC_MAX_SIDE]
        if not sides:
            return None, params
        mos, n_used = _front_anchored_mosaic(front_g, sides)
        if mos is None:
            return None, params
        gray = mos
        params['afisMosaicSides'] = int(n_used)

    # Same-pose multi-shot stacking. Aligning and averaging near-identical
    # views is PURE denoising with no geometric distortion -- unlike
    # multi-ANGLE reconstruction, which unrolls oblique deformable-skin views
    # and measurably HURTS NFIQ (tested: whole-print unwrap scored 15-18pts
    # below the single frame). Restrict to a TIGHT window around the sharpest
    # frame's angle (±_STACK_ANGLE_DEG) so only genuinely same-pose stills are
    # averaged -- a wider set blends slightly-different views and blurs ridges.
    # Lifts NFIQ ~+3 by cutting sensor/rolling-shutter noise; falls back to the
    # single sharpest frame if <2 same-pose frames or alignment fails.
    #
    # Gated behind `stack` because it can REGRESS a good capture: when the
    # binned frame list carries only ~2 near-face-on stills, or when the
    # "same-pose" frames are actually mild-different views, averaging softens
    # ridges (observed -3.3 NFIQ on the sunlight capture). main.py scores the
    # stacked rendering as an ADDITIONAL max-variant alongside the unstacked
    # ones and keeps the higher NFIQ, so stacking can only ever help.
    if (stack or focus_stack) and not fuse and not mosaic:
        src_ang = float(angles_deg[order[0]])
        same_pose = [i for i in order
                     if abs(float(angles_deg[i]) - src_ang) <= _STACK_ANGLE_DEG]
        same_frames = [frames[i] for i in same_pose[:_STACK_MAX]]
        # focus_stack: sharpness-weighted combine (keep the best-focused region
        # of each frame -- targets soft pad edges); stack: flat average (denoise).
        stacked = (_focus_stack_face_on(same_frames) if focus_stack
                   else _stack_face_on(same_frames))
        if stacked is not None:
            gray = stacked
            params['afisStacked'] = len(same_frames)
            params['afisStackMode'] = 'focus' if focus_stack else 'mean'
    g8 = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(gray.astype(np.uint8))

    # Guided path: the user visually seated the pad inside the on-screen
    # silhouette, so that region IS the mask -- no free-range segmentation to
    # bleed onto creases/hand/background, and no fragile ridge-periodicity crop
    # (which selected a crease-side sliver on real captures). See
    # _superellipse_mask. Falls through to segmentation only if the region
    # rasterizes to nothing (degenerate params).
    guide_mask = _superellipse_mask(gray.shape[:2], guide_region) if guide_region else None
    if guide_mask is not None:
        mask = guide_mask
        params['afisMask'] = 'guide'

        # Content-aware refinement, with COVERAGE EXPANSION. The guide
        # silhouette is only where the on-screen overlay sat -- the real
        # ridge-bearing pad extends BEYOND the tight guide oval (notably the
        # tip), so masking to the bare guide throws away real, matchable
        # ridge area (CTO feedback: "entire thumbpad should be covered").
        # But the guide is also purely geometric with zero awareness of what
        # is actually in frame, so background past its edges would get
        # Gabor-noised if we just grew it blindly.
        #
        # Resolve both with a real per-capture pad detector: flash-diff
        # (torch falls off with distance^2, so flash-minus-ambient isolates
        # the near-camera pad almost regardless of background -- see
        # sfm_pipeline._segment_via_flash_diff), U-Net fallback. Then:
        #   - use the DETECTED pad as the mask (covers the whole real pad,
        #     tip included), but
        #   - CLIP it to a generous dilation of the guide (bound), so we can
        #     never wander onto far background or the hand/wrist behind the
        #     pad even if the detector over-segments.
        # Falls back to the bare guide mask if the detector is unavailable or
        # the result looks degenerate/runaway, so this can't regress a
        # capture where the guide alone was already right.
        pad_mask = _flash_diff_mask(ambient_burst, flash_burst, gray.shape[:2])
        refine_tag = 'flashdiff'
        if pad_mask is None:
            pad_mask = _unet_mask(gray)
            refine_tag = 'unet'
        if pad_mask is not None:
            if _MASK_COVER_DILATE > 1.0:
                bound = _superellipse_mask(gray.shape[:2], {
                    **guide_region,
                    'rx': float(guide_region['rx']) * _MASK_COVER_DILATE,
                    'ry': float(guide_region['ry']) * _MASK_COVER_DILATE,
                })
                cand = cv2.bitwise_and(pad_mask, bound) if bound is not None else None
                bound_area = (bound > 0).sum() if bound is not None else 1
            else:
                cand = cv2.bitwise_and(mask, pad_mask)      # legacy shrink-only
                bound_area = (guide_mask > 0).sum()
            # Accept only a plausible mask: at least a third of the guide (not
            # a sliver from a misfire) and not filling ~the entire generous
            # bound (which would mean the detector grabbed everything ->
            # untrustworthy). Otherwise keep the bare guide.
            if cand is not None:
                cov = (cand > 0).sum()
                if 0.35 * (guide_mask > 0).sum() <= cov <= 0.92 * bound_area:
                    mask = cand
                    params['afisMask'] = f'guide+{refine_tag}'
                    params['afisMaskCoverPx'] = int(cov)
    else:
        # Mask FIRST, at native resolution -- the U-Net was trained on native-res
        # frames, so segmenting a resampled image degrades the mask.
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

        # Tighten to just the ridge-bearing pad -- the mask above segments the
        # whole visible thumb (creases, lower segment, palm on a close/wide
        # framing), not only the print-worthy area. See _crop_to_pad_mask. Uses
        # g8 (CLAHE-boosted): raw contrast is too low across most of the frame
        # for the block-std gate to pass at all.
        mask = _crop_to_pad_mask(g8, mask)

    # Ridge-frequency normalisation. NFIQ (and every scanner-trained ridge
    # model) is calibrated for 500 DPI prints, where the ridge period is ~9 px.
    # Our macro captures land anywhere from 9–20 px depending on phone
    # distance, so the model sees an out-of-domain frequency and scores low.
    # Estimate the native ridge wavelength on the MASKED pad, then resample the
    # image AND the mask together so the period becomes _TARGET_PERIOD before
    # enhancement (mask stays at native res for the U-Net; only the Gabor stage
    # sees the resampled version). Grid search over real captures: consistent
    # NFIQ gain when the estimate is reliable.
    norm0 = _normalize(g8)
    native_wl = _ridge_wavelength(norm0, _orientation_field(norm0))
    params['afisWavelengthPx'] = float(round(native_wl, 1))
    wl = native_wl
    if freq_normalize and native_wl > 1.0:
        scale = float(np.clip(_TARGET_PERIOD / native_wl, _FREQ_SCALE_MIN, 2.5))
        if abs(scale - 1.0) > 0.05:
            interp = cv2.INTER_CUBIC if scale > 1 else cv2.INTER_AREA
            g8 = cv2.resize(g8, None, fx=scale, fy=scale, interpolation=interp)
            mask = cv2.resize(mask, (g8.shape[1], g8.shape[0]),
                              interpolation=cv2.INTER_NEAREST)
            params['afisFreqScale'] = float(round(scale, 3))
            wl = _TARGET_PERIOD

    binimg = None
    if enhance == 'pyfing':
        binimg = _pyfing_enhance(g8, mask, wl)
        params['afisEnhance'] = 'pyfing' if binimg is not None else 'pyfing_unavailable'
    elif enhance == 'pyfingHybrid':
        # pyfing as a denoise PRE-PASS, not a standalone final image: run
        # SNFEN to clean up ridge continuity, then let this module's own
        # Gabor bank + hard binarization (calibrated against these exact
        # captures) do the final black-ridge/white-background conversion,
        # instead of a plain intensity invert of pyfing's own continuous-
        # tone output. See _pyfing_denoise's docstring for why the two
        # conventions aren't interchangeable via a simple invert.
        denoised = _pyfing_denoise(g8, mask, wl)
        if denoised is not None:
            norm = _normalize(denoised)
            orient = _orientation_field(norm)
            enh = _gabor_enhance(norm, orient, wl)
            binimg = 255 - (enh < 0).astype(np.uint8) * 255
            params['afisEnhance'] = 'pyfingHybrid'
        else:
            params['afisEnhance'] = 'pyfingHybrid_unavailable'
    if binimg is None:
        # Either enhance == 'gabor', or a pyfing path was requested but the
        # sidecar wasn't configured/reachable -- same non-blocking contract
        # as every other optional signal in this module (fall back, don't
        # fail).
        norm = _normalize(g8)
        orient = _orientation_field(norm)
        enh = _gabor_enhance(norm, orient, wl)
        binimg = 255 - (enh < 0).astype(np.uint8) * 255   # ridges black on white
        params.setdefault('afisEnhance', 'gabor')

    binimg[mask == 0] = 255   # hard mask FIRST -- background is genuinely
    # pure white here, zero Gabor-noise content, before any blur touches it.
    # Feather the mask edge instead of leaving a hard cutoff. A real digital
    # scanner print has no thumb-silhouette outline -- ridges simply fade
    # out at the contact edge. Blurring `binimg` directly (already masked to
    # solid white outside the pad) and blending that blur in ONLY near the
    # boundary softens the transition without ever revealing the unmasked
    # Gabor response outside the pad -- an earlier version of this blurred
    # the mask and blended it against the UNMASKED binimg, which leaked a
    # faint version of the background's own Gabor "ridges" through the fade
    # (visible as a ghosted second boundary/texture past the real edge).
    # `mask` itself stays hard-edged below (crop bounding box,
    # _upright_rotate's PCA) -- only the pixel blend is softened.
    blurred = cv2.GaussianBlur(binimg, (0, 0), sigmaX=_FEATHER_SIGMA)
    mask_soft = cv2.GaussianBlur(mask, (0, 0), sigmaX=_FEATHER_SIGMA).astype(np.float32) / 255.0
    edge_weight = 1.0 - np.abs(2.0 * mask_soft - 1.0)   # peaks at the boundary, ~0 elsewhere
    binimg = (blurred.astype(np.float32) * edge_weight +
              binimg.astype(np.float32) * (1.0 - edge_weight)).astype(np.uint8)
    if guide_region is not None and guide_mask is not None and 'tipAngleDeg' in guide_region:
        # Deterministic upright from the guide's known tip direction -- the pad
        # silhouette is near-symmetric, so PCA (_upright_rotate) can pick the
        # wrong axis; the app tells us exactly which way the tip points.
        binimg, mask = _upright_from_tip(binimg, mask, float(guide_region['tipAngleDeg']))
    else:
        binimg, mask = _upright_rotate(binimg, mask)
    params['afisRotated'] = True
    ys, xs = np.where(mask > 0)
    m = 30
    y0, x0 = max(0, ys.min() - m), max(0, xs.min() - m)
    y1 = min(binimg.shape[0], ys.max() + m)
    x1 = min(binimg.shape[1], xs.max() + m)
    return binimg[y0:y1, x0:x1], params
