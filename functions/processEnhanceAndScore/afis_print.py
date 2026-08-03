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
_AA_SIGMA = 0.0               # 2026-08-03: sub-pixel anti-alias on the hard-
# binarized ridge edges themselves (not the mask boundary -- see
# _FADE_INSET_PX above). OFF by default -- measured negative on real NFIQ2,
# see the real sweep data at the call site below. 0.7 was the visually-best
# value tested (removes stairstep jaggedness, keeps ridges clearly
# separated) if this is ever turned on for a look-over-score trade-off.
_FADE_INSET_PX = 25.0       # 2026-08-03: real visual-QA finding -- a hard mask
# boundary (even with the thin _FEATHER_SIGMA anti-alias above) reads as an
# artificial "clipped" thumb silhouette instead of a real scanner print's
# natural ridge taper, and is also a known real source of spurious ridge-
# ending minutiae exactly along the crop curve (every ridge simultaneously
# "ends" on the same geometric boundary -- not how a real contact print
# looks, and a plausible real hit against AFIS matching, not just cosmetics).
# Value swept (15/25/35/45/60px) against REAL NFIQ2 (locally built nfiq2
# binary) on 4 diverse real captures (nfiq2Score 46-95): 25px gave both the
# best mean score (67.5, vs 60.5 for the old hard-boundary baseline) AND was
# the only value with a positive real delta on EVERY capture (+10/+9/+8/+1,
# zero regressions) -- 35-45px looked better on some individual captures but
# cost real score on cb684c57 specifically (-4/-2). Not a blind guess.
# Ridges now reach full black only this many px inside the mask and fade
# toward white over the same distance as they approach the edge, so the
# print visually thins out and terminates before the crop boundary rather
# than being sliced by it -- see the distance-transform blend below.
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

_FLASH_DIFF_MIN_FLASH_LAPLACIAN = 50.0  # below this, treat the flash frame as
# blown-out and don't trust it for flash-diff segmentation (2026-07-23: real capture
# dadd4ef9 -- nfiq2Score 81, but a visibly jagged/notched superprint boundary with a
# real hole in the ridge-bearing area -- had EVERY flash frame in its burst score
# Laplacian 17-20 (vs ambient's 232-245), the same recurring torch-blowout pattern
# documented throughout this project. A severely overexposed/clipped flash frame has
# little local brightness gradient left in the near-camera region, which is exactly
# the cue _segment_via_flash_diff's torch-falloff differencing depends on -- so it
# produces a noisy, patchy diff mask instead of a clean pad-shaped blob. That noise
# passed straight through the existing area-only accept-gate below and became a real,
# literal hole in the final print (afis_print.py hard-masks everything outside the
# mask to white -- see `binimg[mask == 0] = 255`), not just a cosmetic boundary
# artifact. 50.0 sits comfortably above every confirmed-blown-out real flash score
# seen this project (17-90 range) and comfortably below legitimately sharp captures
# (hundreds+), so this can only skip pairs already known unreliable.

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


_FOMFE_ORDER = 4   # basis order in each axis (5x5 (p,q) grid x 4 sin/cos
# combos - 3 duplicate DC terms = 97 real basis functions). Low on purpose:
# the whole point is a GLOBAL model with too few degrees of freedom to chase
# per-block noise, only the overall ridge-flow topology.
#
# MEASURED 2026-08-03, NOT WIRED INTO main.py's production variant list --
# same "quality win, matchability loss" category as gaborPyfingField (see
# that variant's own docstring above), and by the same discipline, not
# shipped. Real NFIQ2 (locally built nfiq2 binary) on 8 diverse real
# captures: 'fomfe' beat the tuned 'gabor' baseline on 7/8 (+2,+4,+1,-6,+10,
# +7,+5,+6 -- mean +3.6), the first denoise/orientation-hybrid variant this
# whole session to show a clean net NFIQ2 gain over the baseline (every
# prior one -- pyfingHybrid, coherenceDiff, nnsHybrid -- was net negative
# there). But real SourceAFIS matchability on the CTO's own 4 genuine
# cross-session captures (6 pairs) went the other way: mean 74.2 -> 58.1,
# driven mostly by one capture (382cc4b2) whose pairs fell sharply (e.g.
# vs c34911b5: 37.9 -> 2.5). Swept order in {1,2,3,4,5,6,8} specifically
# looking for a setting that keeps the NFIQ2 gain without the matchability
# cost: NONE of them did -- lower order reduced the damage (order=2: that
# same pair recovers to 20.6) but never reached the gabor baseline (37.9),
# and order=2 also cost real score on a pair that was previously fine
# (3e54236a vs 722ae3b0: 139.3 -> 127.5). The likely mechanism: a low-order
# GLOBAL model can't represent the real, legitimately-tight local curvature
# right at a whorl core/delta, so it warps genuine ridge geometry there
# toward the smooth global trend precisely where real matching depends on
# it most -- the model helps exactly where local noise was the problem and
# actively hurts exactly where local complexity was real signal, not noise.
# UPDATE 2026-08-04 -- CTO's own refinement, real improvement, STILL not a
# net win: rather than replacing the field everywhere, confidence-weight a
# per-pixel blend with the existing LOCAL field (see `blend=True` below) --
# trust local where it's genuinely strong, fall back to the global fit only
# where local signal is weak. This measurably helped: real SourceAFIS mean
# went 58.1 (pure global) -> 66.1 (blend, percentile=70) -> 69.1 (blend,
# percentile=90, more conservative -- now the shipped default) vs the 74.2
# gabor baseline, and at percentile=90, 3 of the 6 genuine pairs actually
# BEAT the baseline outright (only the 3 pairs involving 382cc4b2 stayed
# below it). Real NFIQ2 held up throughout (mean +4.0 at percentile=70,
# still positive at 90). This confirms the CTO's diagnosis was right --
# targeted/confidence-based blending IS a real improvement over uniform
# global replacement -- but the gap to the baseline never fully closed, and
# the SAME single capture (382cc4b2) stayed the holdout at every setting
# tried, suggesting something specific to that capture's own local
# coherence calibration rather than a blend-strength problem alone. Left
# here as an available, honestly-still-negative-on-mean scaffold (same
# treatment as gaborVarFreq/fidelity/gaborPyfingField/deepFocus*) -- do not
# wire into production without first understanding why 382cc4b2 resists
# every setting tried.


_FOMFE_BLEND_CONF_SIGMA = 12.0  # Gaussian smoothing (px) on the raw per-pixel
# coherence map before it's used as the local/global blend weight -- avoids a
# blocky/patchwork blend boundary that would itself look like a segmentation
# artifact (same rationale as _ORIENT_SMOOTH existing at all).
_FOMFE_BLEND_PERCENTILE = 90.0  # coherence percentile (within the mask) that
# maps to full trust-the-local-estimate weight. Swept 70 vs 90 against real
# SourceAFIS matchability (see update above) -- 90 (more conservative, only
# the weakest ~10% of local signal ever defers to the global fit) measurably
# closed more of the gap to the gabor baseline than 70 without losing the
# real NFIQ2 gain, so it's the default. Real captures have a wide,
# capture-specific coherence range (contact pressure/lighting vary a lot),
# so a PERCENTILE-relative threshold generalizes across captures where a
# fixed absolute cutoff wouldn't.


def _fomfe_orientation_field(img: np.ndarray, mask: np.ndarray,
                              bsize: int = _BLOCK,
                              order: int = _FOMFE_ORDER,
                              blend: bool = True) -> Optional[np.ndarray]:
    """
    Global 2D-Fourier-series orientation field model (2026-08-03,
    FOMFE-inspired -- Wang/Hu/Phillips, "A Fingerprint Orientation Model
    Based on 2D Fourier Expansion", IEEE TPAMI 2007).

    _orientation_field above already fixes noisy per-block orientation with
    a Gaussian blur on the doubled-angle (cos 2theta, sin 2theta) field --
    but that's a LOCAL smoother: it can only propagate information a few
    sigma (_ORIENT_SMOOTH=15px) before falling back to whatever noisy signal
    is locally present. A real fingerprint's ridge flow is a globally
    coherent pattern (loops/whorls/deltas all constrain each other) -- CTO's
    own observation: "points that clearly supposed to go together but
    segmentation error or something else is distorting flow". A GLOBAL
    low-order model uses every valid sample across the whole pad to
    determine the field EVERYWHERE, so it can bridge much larger low-
    contrast/creased gaps by following the surrounding flow topology,
    instead of either trusting a locally-noisy estimate or leaving it
    unconstrained beyond the blur radius.

    Fits cos(2*theta)/sin(2*theta) independently via weighted least squares
    (weight = local gradient-coherence energy, so noisy/background blocks
    barely influence the fit) against a small tensor-product cos/sin basis
    over normalized image coordinates, then evaluates the fitted model
    densely over the whole image. Returns None (self-skip, same contract as
    every other optional signal in this module) if too few valid samples
    exist for a stable fit.

    blend=True (default, 2026-08-04, CTO's own refinement): the pure global
    replacement (blend=False) measured a real matchability loss concentrated
    at whorl cores/deltas -- a low-order global model can't represent the
    real, legitimately-tight local curvature there, so it was overwriting
    genuine structure, not just noise. Instead of replacing the local field
    everywhere, CONFIDENCE-WEIGHT a blend between the two per pixel: trust
    the local estimate (_orientation_field's own smoothed field) where local
    signal is genuinely strong -- a sharp core has strong gradient coherence
    on its own, no reconstruction needed -- and fall back toward the global
    fit only where local coherence is weak (creases, low contact pressure,
    typically nearer the pad periphery, matching the CTO's own "outer edges"
    framing, but driven by actual signal strength rather than a hardcoded
    geometric ring, so it adapts per-capture instead of assuming where the
    weak regions will be).
    """
    h, w = img.shape
    gx = cv2.Sobel(img, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(img, cv2.CV_32F, 0, 1, ksize=3)
    vx = cv2.boxFilter(2 * gx * gy, -1, (bsize, bsize))
    vy = cv2.boxFilter(gx * gx - gy * gy, -1, (bsize, bsize))
    coherence = np.sqrt(vx * vx + vy * vy)
    theta_raw = 0.5 * np.arctan2(vx, vy)
    cs_raw = np.cos(2 * theta_raw)
    sn_raw = np.sin(2 * theta_raw)

    ys = np.arange(bsize // 2, h, bsize)
    xs = np.arange(bsize // 2, w, bsize)
    yy, xx = np.meshgrid(ys, xs, indexing='ij')
    valid = mask[yy, xx] > 0
    if int(valid.sum()) < 20:
        return None
    yy, xx = yy[valid], xx[valid]
    w_sample = coherence[yy, xx]
    cs_sample = cs_raw[yy, xx]
    sn_sample = sn_raw[yy, xx]

    def _basis(xn: np.ndarray, yn: np.ndarray) -> List[np.ndarray]:
        cols = [np.ones_like(xn)]
        for p in range(order + 1):
            for q in range(order + 1):
                if p == 0 and q == 0:
                    continue
                cols.append(np.cos(p * np.pi * xn) * np.cos(q * np.pi * yn))
                cols.append(np.cos(p * np.pi * xn) * np.sin(q * np.pi * yn))
                cols.append(np.sin(p * np.pi * xn) * np.cos(q * np.pi * yn))
                cols.append(np.sin(p * np.pi * xn) * np.sin(q * np.pi * yn))
        return cols

    xn_s = (xx.astype(np.float32) - w / 2.0) / (w / 2.0)
    yn_s = (yy.astype(np.float32) - h / 2.0) / (h / 2.0)
    A = np.stack(_basis(xn_s, yn_s), axis=1)
    sw = np.sqrt(np.clip(w_sample, 1e-3, None))
    Aw = A * sw[:, None]
    try:
        coef_cs, *_ = np.linalg.lstsq(Aw, cs_sample * sw, rcond=None)
        coef_sn, *_ = np.linalg.lstsq(Aw, sn_sample * sw, rcond=None)
    except np.linalg.LinAlgError:
        return None

    yg, xg = np.mgrid[0:h, 0:w].astype(np.float32)
    xng = (xg - w / 2.0) / (w / 2.0)
    yng = (yg - h / 2.0) / (h / 2.0)
    basis_full = _basis(xng, yng)
    cs_fit = sum(c * b for c, b in zip(coef_cs, basis_full))
    sn_fit = sum(c * b for c, b in zip(coef_sn, basis_full))

    if not blend:
        return 0.5 * np.arctan2(sn_fit, cs_fit) + np.pi / 2

    # LOCAL field: the existing, already-tuned smoother (Gaussian blur on
    # the same raw doubled-angle signal) -- reusing it rather than
    # re-deriving keeps this consistent with the field this pipeline
    # already ships when fomfe isn't involved at all.
    cs_local = cv2.GaussianBlur(cs_raw, (0, 0), _ORIENT_SMOOTH)
    sn_local = cv2.GaussianBlur(sn_raw, (0, 0), _ORIENT_SMOOTH)

    # Confidence weight: smooth the raw coherence map first (avoids a
    # blocky/patchwork blend boundary), then scale relative to its own
    # in-mask percentile so this adapts to each capture's own contrast/
    # pressure range rather than assuming a fixed absolute cutoff.
    coh_smooth = cv2.GaussianBlur(coherence, (0, 0), _FOMFE_BLEND_CONF_SIGMA)
    in_mask = coh_smooth[mask > 0]
    ref = float(np.percentile(in_mask, _FOMFE_BLEND_PERCENTILE)) if in_mask.size else 1.0
    ref = max(ref, 1e-6)
    alpha = np.clip(coh_smooth / ref, 0.0, 1.0).astype(np.float32)

    cs_blend = alpha * cs_local + (1.0 - alpha) * cs_fit
    sn_blend = alpha * sn_local + (1.0 - alpha) * sn_fit
    return 0.5 * np.arctan2(sn_blend, cs_blend) + np.pi / 2


def _ridge_wavelength(img: np.ndarray, orient: np.ndarray, bsize: int = 32) -> float:
    h, w = img.shape
    freqs = []
    for y in range(0, h - bsize, bsize):
        for x in range(0, w - bsize, bsize):
            blk = img[y:y + bsize, x:x + bsize]
            if blk.std() < 8:
                continue
            ang = orient[y + bsize // 2, x + bsize // 2]
            # Real bug found + fixed 2026-07-29: rotating by `ang` alone
            # rotates ridges TO the orientation direction, not TO vertical --
            # the opposite of what's needed before collapsing axis 0 (rows)
            # into a profile over x. Confirmed by direct execution: a block
            # of perfectly vertical stripes (orient == 90 deg, already
            # correctly aligned, needing ZERO rotation) got rotated a full
            # 90 degrees by the old `np.degrees(ang)` call, turning it into
            # HORIZONTAL stripes -- averaging over rows then averages
            # straight along the periodic direction, producing a dead-flat
            # signal (std=0.0) and silently contributing no frequency sample
            # at all. `_upright_rotate` (this same file) does the analogous
            # "bring a computed direction to vertical" operation and already
            # correctly subtracts 90 -- this and the two sibling functions
            # below (_ridge_frequency_map, _ridge_texture_strength) had
            # copy-pasted the idiom without it.
            M = cv2.getRotationMatrix2D((bsize / 2, bsize / 2), np.degrees(ang) - 90.0, 1.0)
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


def _gabor_enhance(
    img: np.ndarray, orient: np.ndarray, wavelength: float,
    *,
    sigma_ratio: float = _GABOR_SIGMA_RATIO,
    gamma: float = _GABOR_GAMMA,
) -> np.ndarray:
    h, w = img.shape
    sigma = sigma_ratio * wavelength
    ksize = int(2 * np.ceil(3 * sigma) + 1)
    outs = np.zeros((_N_ORIENT, h, w), np.float32)
    for i in range(_N_ORIENT):
        th = np.pi * i / _N_ORIENT
        k = cv2.getGaborKernel((ksize, ksize), sigma, th + np.pi / 2,
                               wavelength, gamma, 0, cv2.CV_32F)
        k -= k.mean()
        outs[i] = cv2.filter2D(img, cv2.CV_32F, k)
    idx = np.round((orient % np.pi) / (np.pi / _N_ORIENT)).astype(int) % _N_ORIENT
    yy, xx = np.mgrid[0:h, 0:w]
    return outs[idx, yy, xx]


# Spatially-varying ridge frequency. The single-wavelength _gabor_enhance above
# applies ONE ridge period across the whole print, but a real fingerprint's
# ridge frequency varies across the pad (finer toward the tip, coarser toward
# the base/joint) — the classic Hong/Wan/Jain (1998) observation. Filtering a
# region with the wrong period smears or splits ridges there, which reads
# exactly as the "ridge-continuity distortion" the prime directive targets.
# The var-freq path below estimates a per-BLOCK period map, then runs a Gabor
# bank over (orientation x a few discrete frequency levels) and selects each
# pixel by its LOCAL orientation AND period. Kept as its own variant (max-of-
# variants) so it can only ever add a candidate.
_FREQ_LEVELS = 5          # discrete ridge-period levels spanning the map's range
_FREQMAP_BLOCK = 24       # block size for the local-period estimate
_FREQMAP_SMOOTH = 24.0    # Gaussian smoothing (px) of the interpolated map


def _ridge_frequency_map(img: np.ndarray, orient: np.ndarray, mask: np.ndarray,
                         bsize: int = _FREQMAP_BLOCK) -> Optional[np.ndarray]:
    """Per-pixel ridge-period (wavelength) map, in px, over the masked pad.

    Same per-block projected-autocorrelation estimate as _ridge_wavelength, but
    keeps every reliable block value instead of collapsing to one median, fills
    unreliable/void blocks by nearest-reliable interpolation, and smooths. None
    if too few reliable blocks (caller falls back to the single-wavelength path).
    """
    h, w = img.shape
    ys = np.arange(0, h - bsize, bsize // 2)
    xs = np.arange(0, w - bsize, bsize // 2)
    grid = np.full((len(ys), len(xs)), np.nan, np.float32)
    for iy, y in enumerate(ys):
        for ix, x in enumerate(xs):
            if mask[y:y + bsize, x:x + bsize].mean() < 128:
                continue
            blk = img[y:y + bsize, x:x + bsize]
            if blk.std() < 8:
                continue
            ang = orient[y + bsize // 2, x + bsize // 2]
            # Same rotation-direction fix as _ridge_wavelength above (see its
            # comment) -- must bring the block TO vertical (ang - 90), not
            # rotate BY the orientation angle itself.
            M = cv2.getRotationMatrix2D((bsize / 2, bsize / 2), np.degrees(ang) - 90.0, 1.0)
            rot = cv2.warpAffine(blk, M, (bsize, bsize))
            sig = rot.mean(axis=0)
            sig = sig - sig.mean()
            ac = np.correlate(sig, sig, 'full')[bsize - 1:]
            d = np.diff(ac)
            peaks = np.where((d[:-1] > 0) & (d[1:] <= 0))[0] + 1
            peaks = peaks[peaks > 3]
            if len(peaks):
                grid[iy, ix] = float(np.clip(peaks[0], 5, 20))
    if np.isnan(grid).all() or np.count_nonzero(~np.isnan(grid)) < 4:
        return None
    # Fill unreliable/void blocks by iterative dilation of known values
    # (simple nearest-fill), then upscale to full res and smooth into a
    # continuous period field.
    valid = ~np.isnan(grid)
    filled = grid.copy()
    known = valid.copy()
    while not known.all():
        dil = cv2.dilate(np.nan_to_num(filled), np.ones((3, 3), np.uint8))
        cnt = cv2.dilate(known.astype(np.uint8), np.ones((3, 3), np.uint8))
        take = (~known) & (cnt > 0)
        # average of dilated neighbourhood approximated by the dilation value
        filled[take] = dil[take]
        known = known | take
        if not take.any():
            break
    fmap = cv2.resize(filled, (w, h), interpolation=cv2.INTER_LINEAR)
    fmap = cv2.GaussianBlur(fmap, (0, 0), _FREQMAP_SMOOTH)
    return fmap


def _gabor_enhance_varfreq(img: np.ndarray, orient: np.ndarray,
                           wl_map: np.ndarray, n_levels: int = _FREQ_LEVELS) -> np.ndarray:
    """Gabor enhancement with a per-pixel ridge period (wl_map) instead of one
    global wavelength. Builds a bank over (_N_ORIENT orientations x n_levels
    discrete period levels) spanning the map's actual range, then selects each
    pixel's response by its local orientation bin AND nearest period level."""
    h, w = img.shape
    lo, hi = float(np.percentile(wl_map, 5)), float(np.percentile(wl_map, 95))
    lo = max(lo, 4.0)
    hi = max(hi, lo + 1.0)
    levels = np.linspace(lo, hi, n_levels)
    # Response cube: [level, orient, h, w] is too big; instead compute the
    # selected response incrementally to keep memory ~one image per level.
    o_idx = np.round((orient % np.pi) / (np.pi / _N_ORIENT)).astype(int) % _N_ORIENT
    l_idx = np.clip(np.round((wl_map - lo) / max(hi - lo, 1e-6) * (n_levels - 1)),
                    0, n_levels - 1).astype(int)
    yy, xx = np.mgrid[0:h, 0:w]
    out = np.zeros((h, w), np.float32)
    for li, wl in enumerate(levels):
        sel_l = (l_idx == li)
        if not sel_l.any():
            continue
        sigma = _GABOR_SIGMA_RATIO * wl
        ksize = int(2 * np.ceil(3 * sigma) + 1)
        bank = np.zeros((_N_ORIENT, h, w), np.float32)
        for i in range(_N_ORIENT):
            th = np.pi * i / _N_ORIENT
            k = cv2.getGaborKernel((ksize, ksize), sigma, th + np.pi / 2,
                                   wl, _GABOR_GAMMA, 0, cv2.CV_32F)
            k -= k.mean()
            bank[i] = cv2.filter2D(img, cv2.CV_32F, k)
        resp = bank[o_idx, yy, xx]
        out[sel_l] = resp[sel_l]
    return out


# Ridge-confidence gate — the fidelity lever (prime directive). The Gabor bank
# synthesizes a ridge EVERYWHERE it runs, including low-signal regions where it
# invents plausible-but-wrong ridges. Those hallucinated ridges become spurious
# minutiae that (a) can false-match a DIFFERENT finger and (b) don't repeat
# across genuine captures of the SAME finger — measured: aggressive synthesis
# raises NFIQ2 but does NOT improve (and can hurt) SourceAFIS genuine-vs-
# impostor separation. This gate BLANKS the binarized print to background where
# the local ridge signal is unreliable (low orientation coherence AND/OR weak
# in-band ridge energy), so only trustworthy ridges survive to be transcribed
# into minutiae. Deliberately trades NFIQ2 texture for match fidelity — judged
# by SourceAFIS separation, never NFIQ2. See docs/FIDELITY_WALL_SCOPE.md.
_CONF_COH_MIN = 0.35        # below this orientation coherence => blank
_CONF_SOFT = 0.12           # soft transition width around the threshold


def _ridge_confidence(gray: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Per-pixel ridge trustworthiness in [0,1]: orientation coherence gated by
    presence of real ridge-band energy. High only where ridges genuinely flow
    coherently — i.e. where extracted minutiae are likely to be REPEATABLE."""
    coh = _block_coherence(gray)
    # In-band ridge energy: bandpass around the ridge frequency (DoG) then local
    # RMS. Distinguishes true ridges from flat/blurred skin the coherence of
    # noise can otherwise score high on.
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


def _apply_confidence_gate(binimg_signed: np.ndarray, conf: np.ndarray) -> np.ndarray:
    """Turn a signed Gabor response into a binarized print, but fade ridges
    toward background (white) where confidence is low, via a soft threshold on
    `conf`. Returns a uint8 ridges-black-on-white image."""
    ridges = (binimg_signed < 0).astype(np.float32)   # 1 where ridge
    w = np.clip((conf - _CONF_COH_MIN) / _CONF_SOFT + 0.5, 0.0, 1.0)
    gated = ridges * w                                 # keep ridge only if confident
    return (255 - (gated * 255)).astype(np.uint8)


_COH_DIFF_SIGMA = 1.2        # across-ridge smoothing extent (px) -- narrow, preserves ridge/valley contrast
_COH_DIFF_ORIENT_RATIO = 2.5  # along-ridge : across-ridge elongation of the smoothing kernel


def _coherence_diffusion(img: np.ndarray, orient: np.ndarray) -> np.ndarray:
    """Oriented smoothing along the local ridge direction -- a directional-
    kernel approximation of coherence-enhancing diffusion (Weickert-style
    structure-tensor anisotropic diffusion, well-established in the
    fingerprint-enhancement literature as a technique complementary to
    Gabor bandpass filtering: it repairs small ridge discontinuities by
    smoothing LENGTHWISE along the ridge while barely touching the
    across-ridge direction, rather than Gabor's frequency-selective
    response). Not a full iterative PDE solve -- reuses this module's own
    per-orientation-bank architecture (see _gabor_enhance) for efficiency:
    precompute elongated anisotropic Gaussian kernels at _N_ORIENT
    discretized angles, select per pixel by the same orientation index.

    Intended as a denoise PRE-PASS feeding the existing Gabor+binarize
    chain (same role as _pyfing_denoise in the pyfingHybrid path), not a
    replacement for it -- see enhance='coherenceDiff' in generate()."""
    h, w = img.shape
    sigma_across = _COH_DIFF_SIGMA
    sigma_along = _COH_DIFF_SIGMA * _COH_DIFF_ORIENT_RATIO
    half = int(np.ceil(3 * sigma_along))
    yy, xx = np.mgrid[-half:half + 1, -half:half + 1].astype(np.float32)
    outs = np.zeros((_N_ORIENT, h, w), np.float32)
    for i in range(_N_ORIENT):
        th = np.pi * i / _N_ORIENT   # ridge direction for this bin
        c, s = np.cos(th), np.sin(th)
        xr = xx * c + yy * s   # along-ridge axis
        yr = -xx * s + yy * c  # across-ridge axis
        k = np.exp(-(xr ** 2) / (2 * sigma_along ** 2) - (yr ** 2) / (2 * sigma_across ** 2))
        k /= k.sum()
        outs[i] = cv2.filter2D(img, cv2.CV_32F, k.astype(np.float32))
    idx = np.round((orient % np.pi) / (np.pi / _N_ORIENT)).astype(int) % _N_ORIENT
    yy2, xx2 = np.mgrid[0:h, 0:w]
    return outs[idx, yy2, xx2]


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


def _fill_mask_holes(mask: np.ndarray) -> np.ndarray:
    """Fills fully-enclosed holes/notches in a binary 0/255 mask -- belt-and-
    suspenders alongside the blown-out-flash-frame guard above: even a decent
    flash frame can produce a small noisy gap in the diff mask, and a hole
    anywhere in the mask becomes a literal hole in the final print (generate()
    hard-masks outside the mask to white). Flood-fills the background from a
    corner (the mask is always a roughly-centred blob well inside the frame,
    so a corner is reliably background), then anything NOT reached by that
    flood is either real foreground or an enclosed hole -- both get kept. Can
    only ADD area back inside already-enclosed gaps, never remove real
    foreground, so this can't regress an already-clean mask.

    Pads with a guaranteed-background 1px ring before flooding, rather than
    seeding from the bare (0,0) corner directly. If the mask's own
    foreground happens to touch the frame edge (a tight/zoomed capture, or
    a noisy detector that over-reaches to the border), a single bare-corner
    seed can get walled off from a real background pocket on the far side
    of the frame -- that pocket would then be indistinguishable from an
    enclosed hole and get wrongly merged into the foreground. The padding
    ring connects every edge of the frame to the (0,0) seed regardless of
    what the foreground does inside it, so this can only ever correctly
    identify MORE real background, never mistake foreground for a hole."""
    padded = cv2.copyMakeBorder(mask, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    h, w = padded.shape[:2]
    flood_mask = np.zeros((h + 2, w + 2), np.uint8)
    filled = padded.copy()
    cv2.floodFill(filled, flood_mask, (0, 0), 255)
    holes = cv2.bitwise_not(filled)
    combined = cv2.bitwise_or(padded, holes)
    return combined[1:-1, 1:-1]


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
            # Blown-out flash frame guard -- see _FLASH_DIFF_MIN_FLASH_LAPLACIAN's
            # own comment. A saturated/clipped flash frame has too little local
            # gradient left for the torch-falloff cue to work, and produces a
            # noisy mask rather than failing cleanly -- skip this pair (try the
            # next burst pair, if any) rather than trust it.
            f_lap = float(cv2.Laplacian(f_gray, cv2.CV_64F).var())
            if f_lap < _FLASH_DIFF_MIN_FLASH_LAPLACIAN:
                logger.info('flash-diff: skipping blown-out flash frame (lap=%.1f < %.0f)',
                            f_lap, _FLASH_DIFF_MIN_FLASH_LAPLACIAN)
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
            # Same rotation-direction fix as _ridge_wavelength (see its
            # comment) -- must bring the block TO vertical (ang - 90).
            M = cv2.getRotationMatrix2D((bsize / 2, bsize / 2), np.degrees(ang) - 90.0, 1.0)
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


def _geom_correct(g8: np.ndarray, mask: np.ndarray, mode: str):
    """Cross-domain geometry correction (C2CL-style) via geom_correct.py.

    Kept as a thin lazy-import wrapper (same non-blocking contract as the
    pyfing/nns hooks): returns (g8, mask) warped toward contact-print
    geometry, or None to self-skip the variant. See geom_correct.py and
    docs/FIDELITY_WALL_SCOPE.md for why this exists and how it's validated
    (SourceAFIS separation, not NFIQ2)."""
    try:
        import geom_correct
    except ImportError:
        return None
    try:
        return geom_correct.correct(g8, mask, mode=mode)
    except Exception as e:      # never let a geometry experiment break scoring
        logger.warning('AFIS geom correction (%s) failed: %s', mode, e)
        return None


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


def _pyfing_orientation_frequency(g8: np.ndarray, mask: np.ndarray):
    """RESEARCH SCAFFOLD (docs/FIDELITY_WALL_SCOPE.md): swap this module's own
    classical orientation (_orientation_field, gradient/structure-tensor) and
    frequency (_ridge_frequency_map, block autocorrelation) estimators for
    pyfing's neural equivalents (Snfoe/Snffe), while keeping the SAME
    downstream Gabor bank (_gabor_enhance_varfreq) -- isolates whether the
    FIELD ESTIMATE itself is the limiting factor, distinct from pyfing's
    SNFEN *enhancer* (enhance='pyfing'/'pyfingHybrid'), which already lost to
    the tuned Gabor pipeline.

    Returns (orientation, freq_map) in this module's own conventions --
    orientation in [0, pi) "ridge direction" (matching _orientation_field's
    return convention), freq_map a full-resolution ridge-PERIOD-in-px map
    (matching _ridge_frequency_map's return convention, so it drops straight
    into _gabor_enhance_varfreq) -- or None on any failure/unavailability
    (caller falls back to this module's own classical fields, same
    non-blocking contract as every other optional signal here).

    UNLIKE _pyfing_denoise, this does NOT internally rescale toward
    _TARGET_PERIOD -- resizing a per-pixel ANGLE field (wraps at 0/pi) or a
    per-pixel PERIOD-in-px field (values themselves change with scale) after
    the fact is a real correctness trap, not just an implementation detail.
    Callers MUST pass freq_normalize=True to generate() so g8/mask are
    already close to the ~500dpi/_TARGET_PERIOD domain BEFORE this runs,
    making dpi=500 a valid assumption for pyfing's calls without any
    post-hoc resize of the returned fields.

    PRODUCTION NOTE: this does a direct in-process `import pyfing` (NOT the
    pyfing_client HTTP-sidecar pattern _pyfing_denoise uses). That isolation
    exists for a real reason (pyfing_client.py's own docstring: keeps
    Keras/TensorFlow out of this Cloud Function's deploy footprint). This
    scaffold is safe today only because `pyfing` is not in this function's
    requirements.txt, so it self-skips via ImportError in the real deployed
    environment -- it is for LOCAL MEASUREMENT ONLY (scratchpad harness).
    If this measurably wins, build proper pyfing_service endpoints before
    ever wiring it into main.py's _afis_variants."""
    try:
        import pyfing
    except ImportError:
        return None

    ys, xs = np.where(mask > 0)
    if len(ys) < 200:
        return None

    try:
        foe = _pyfing_orientation_frequency._foe
        ffe = _pyfing_orientation_frequency._ffe
    except AttributeError:
        foe = pyfing.Snfoe(pyfing.SnfoeParameters())
        ffe = pyfing.Snffe(pyfing.SnffeParameters())
        _pyfing_orientation_frequency._foe = foe
        _pyfing_orientation_frequency._ffe = ffe

    try:
        pyfing_orient, _confidence = foe.run(g8, mask=mask, dpi=500)
        pyfing_freq = ffe.run(g8, mask, pyfing_orient, dpi=500)
    except Exception as e:
        logger.warning('pyfing orientation/frequency estimation failed: %s', e)
        return None

    # Convert pyfing's [-pi/2, pi/2] orientation convention to this module's
    # own [0, pi) "ridge direction" convention (see _orientation_field) --
    # both measure ridge angle mod pi (an undirected line, not a vector), so
    # this is a phase shift, not a sign flip. NOT independently re-verified
    # against a ground-truth angle beyond the sanity render this scaffold was
    # built with -- re-check visually (e.g. overlay a few orientation arrows
    # on a real print) before trusting downstream numbers.
    orientation = np.mod(pyfing_orient + np.pi / 2, np.pi)

    # pyfing marks low-confidence/background pixels with negative sentinel
    # values in the frequency map (observed on real prints: valid ~5-20px,
    # invalid negative) -- treat those as unreliable and reuse
    # _ridge_frequency_map's own nearest-fill + smoothing tail so the output
    # is a clean, full-resolution period-in-px map in the same units/shape
    # _gabor_enhance_varfreq already expects.
    grid = pyfing_freq.copy()
    grid[grid <= 0] = np.nan
    grid[mask == 0] = np.nan
    if np.count_nonzero(~np.isnan(grid)) < 4:
        return None
    valid = ~np.isnan(grid)
    filled = grid.copy()
    known = valid.copy()
    while not known.all():
        dil = cv2.dilate(np.nan_to_num(filled), np.ones((3, 3), np.uint8))
        cnt = cv2.dilate(known.astype(np.uint8), np.ones((3, 3), np.uint8))
        take = (~known) & (cnt > 0)
        filled[take] = dil[take]
        known = known | take
        if not take.any():
            break
    freq_map = cv2.GaussianBlur(filled, (0, 0), _FREQMAP_SMOOTH)
    return orientation, freq_map


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


def _nns_denoise(g8: np.ndarray, mask: np.ndarray) -> Optional[np.ndarray]:
    """Runs this project's OTHER, older enhancement model (`enhancement_pipeline.
    enhance()` -- CLAHE -> multi-scale Gabor -> trained FingerprintUNet ("NNS")
    -> unsharp post-process) as a denoise PRE-PASS, same role as
    `_pyfing_denoise`/`_coherence_diffusion`: feeds `enhance='nnsHybrid'` in
    generate(), which then runs the result through this module's own tuned
    Gabor bank + hard binarization for the final black-ridge/white-background
    conversion, rather than using the NNS output directly as the final image.

    Motivation (CTO, 2026-07-16): the NNS pipeline's continuous-tone output is
    visibly smoother/more continuous ridge-wise than the AFIS binarized
    template, but scores far lower on real NFIQ2 (measured: 39 vs 76 on the
    same real capture) -- almost certainly because NFIQ2 was calibrated
    against, and this project's whole Gabor pipeline has been tuned against,
    a hard-binarized image, not a soft continuous-tone one (the same class of
    convention gap `pyfingHybrid` addressed for pyfing). Unlike pyfing, NNS's
    own output convention already matches this project's (ridges dark,
    background light -- confirmed via `enhancement_pipeline.ink_scanner_style`'s
    docstring and `_postprocess`'s contrast-stretch, which assume the same
    polarity `_gabor_enhance`'s binarization does) -- no invert needed here.

    Crops to the mask's own bounding box and grey-fills outside it (same
    pattern as `_pyfing_denoise`) before calling `enhancement_pipeline.enhance()`,
    which internally resizes to its fixed 512x512 NNS input and returns a
    512x512 result -- resized back to the crop's own size afterward. Returns
    None on any failure (missing dependency, degenerate crop, or the NNS
    weights not being resolvable) -- same non-blocking contract as every
    other optional signal in this module."""
    try:
        import enhancement_pipeline
    except ImportError:
        return None

    ys, xs = np.where(mask > 0)
    if len(ys) < 200:
        return None
    y0, x0 = max(0, ys.min() - 10), max(0, xs.min() - 10)
    y1, x1 = min(g8.shape[0], ys.max() + 10), min(g8.shape[1], xs.max() + 10)
    crop = g8[y0:y1, x0:x1].copy()
    crop_mask = mask[y0:y1, x0:x1]
    crop[crop_mask == 0] = 128

    try:
        enhanced_512, _params = enhancement_pipeline.enhance(crop, sfm_coverage=1.0)
    except Exception as e:   # noqa: BLE001 -- must never block the pipeline
        logger.warning('NNS denoise pre-pass failed (non-critical): %s', e)
        return None
    if enhanced_512 is None:
        return None
    enhanced = cv2.resize(enhanced_512, (crop.shape[1], crop.shape[0]),
                           interpolation=cv2.INTER_CUBIC) if enhanced_512.shape != crop.shape else enhanced_512

    full = g8.copy()
    full[y0:y1, x0:x1] = enhanced
    return full


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
    stack_cache: Optional[dict] = None,
    geom: Optional[str] = None,
    gabor_sigma_ratio: Optional[float] = None,
    gabor_gamma: Optional[float] = None,
    mirror: bool = False,
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
                     FIDELITY SCAFFOLDS (opt-in, default off, NOT in main.py's
                     production variant list, judged by SourceAFIS matchability
                     not NFIQ2 -- see docs/FIDELITY_WALL_SCOPE.md):
                       'gaborVarFreq'     -- local per-region ridge-frequency
                                             Gabor (own classical field
                                             estimators);
                       'fidelity'         -- local-freq Gabor + ridge-
                                             confidence gate that blanks
                                             hallucinated ridges;
                       'gaborPyfingField' -- same Gabor bank as gaborVarFreq,
                                             but orientation+frequency come
                                             from pyfing's Snfoe/Snffe neural
                                             estimators instead -- LOCAL
                                             MEASUREMENT ONLY, requires
                                             freq_normalize=True, see
                                             _pyfing_orientation_frequency.
                     gaborVarFreq/fidelity measurably reduce impostor false-
                     matches (the right direction) but over-prune genuine
                     signal at their current first-guess thresholds; they need
                     the paired dataset to tune before they can win, so they
                     stay unwired for now. gaborPyfingField not yet measured.
    stack_cache    : optional caller-owned dict, reused across repeated calls
                     within ONE request (e.g. main.py's max-of-variants loop
                     calling generate() once per fuse mode) to avoid redoing
                     the expensive _stack_face_on ECC alignment for 'deep'/
                     'deepMaxc'/'deepSoft', which share identical inputs.
                     Pass a fresh {} per request -- never a module-level/
                     global cache, which would risk stale reuse across
                     different requests on a warm Cloud Run instance.

    geom           : optional cross-domain geometry correction toward contact-
                     print geometry (C2CL-style), applied to the masked pad
                     before enhancement. None (default) = off. 'cyl' = single-
                     image cylinder-curvature rectification; 'cylElastic' =
                     cyl + (currently identity) elastic flatten. See
                     geom_correct.py / docs/FIDELITY_WALL_SCOPE.md. SCAFFOLD:
                     validated by SourceAFIS genuine-vs-impostor separation
                     (NOT NFIQ2), not yet tuned/wired into production variants
                     — needs the paired dataset (scope doc item A) first.

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
    if fuse in ('deep', 'deepMaxc', 'deepSoft', 'deepFocusAvg', 'deepFocusMaxc', 'deepFocusSoft'):
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
        _deep_mode = {
            'deep': 'avg', 'deepMaxc': 'maxc', 'deepSoft': 'soft',
            'deepFocusAvg': 'avg', 'deepFocusMaxc': 'maxc', 'deepFocusSoft': 'soft',
        }[fuse]
        # deepFocus* variants (2026-07-24): combine two techniques already
        # separately validated but never together -- per-illumination
        # SHARPNESS-WEIGHTED stacking (_focus_stack_face_on, targets the
        # pad's curved edges going soft under a single frame's shallow
        # macro depth-of-field) feeding the SAME coherence-based ambient/
        # flash fusion (maxc/soft, already proven to win back the flash
        # specular-blown centre) that plain deep/deepMaxc/deepSoft use with
        # a flat average instead. Max-of-variants, so this can only ever
        # add a candidate.
        _use_focus_stack = fuse.startswith('deepFocus')
        _stack_fn = _focus_stack_face_on if _use_focus_stack else _stack_face_on
        _cache_key = ('da_focus', 'df_focus') if _use_focus_stack else ('da', 'df')
        ab = [g for g in (ambient_burst or []) if g is not None]
        fb = [g for g in (flash_burst or []) if g is not None]
        if not ab and not fb:
            return None, params
        # _stack_face_on/_focus_stack_face_on do ECC-affine registration
        # across the WHOLE burst -- expensive, and identical within each
        # family (deep/deepMaxc/deepSoft share one cache slot;
        # deepFocusAvg/deepFocusMaxc/deepFocusSoft share a SEPARATE one,
        # since they need the sharpness-weighted stack, not the flat-
        # averaged one). Found 2026-07-16 (real device capture 9efb7d1e):
        # on a burst with poorly-correlated flash frames, redoing this 3x
        # (once per fuse-mode variant) took 15+ minutes for a single
        # variant, blowing the Cloud Run request timeout and leaving the
        # capture stuck forever. Cache across the family via the caller-
        # supplied, request-scoped `stack_cache` dict (main.py creates one
        # fresh dict per request and passes it to every variant call) --
        # never a module-level/global cache, so there's no risk of stale
        # reuse across different requests.
        if stack_cache is not None and _cache_key[0] in stack_cache:
            da = stack_cache[_cache_key[0]]
        else:
            da = _stack_fn(ab) if len(ab) >= 2 else (ab[0] if ab else None)
            if stack_cache is not None:
                stack_cache[_cache_key[0]] = da
        if stack_cache is not None and _cache_key[1] in stack_cache:
            df = stack_cache[_cache_key[1]]
        else:
            df = _stack_fn(fb) if len(fb) >= 2 else (fb[0] if fb else None)
            if stack_cache is not None:
                stack_cache[_cache_key[1]] = df
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
        params['afisDeepFuse'] = {
            'nAmb': len(ab), 'nFla': len(fb), 'mode': _deep_mode,
            'stack': 'focus' if _use_focus_stack else 'mean',
        }
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
            # Real gap found 2026-07-24 (same root cause as stack/focusStack
            # above): for front_only_v1, ambient_frames/flash_frames are
            # each length 1 (the single pre-selected pair), so when THAT one
            # pair fails to register/fuse (real captures observed: 847fa2d3,
            # 5aa18155 -- all of fuseAvg/fuseMaxc/fuseSoft returned None),
            # the variant has no other pair to fall back to and dies
            # entirely. Try additional same-pose pairs from the raw
            # preserved burst (ambient_burst/flash_burst, already
            # downloaded for deepFuse) ONLY once the primary pair has
            # already failed -- the primary pair is still tried FIRST and
            # stops the loop on success exactly as before, so this can only
            # ever promote an already-guaranteed-None result to a real one.
            _burst_amb = [g for g in (ambient_burst or []) if g is not None]
            _burst_fla = [g for g in (flash_burst or []) if g is not None]
            _n = min(len(_burst_amb), len(_burst_fla))
            _burst_pairs = sorted(
                range(_n),
                key=lambda i: -min(_ridge_energy(_burst_amb[i]), _ridge_energy(_burst_fla[i])))
            for i in _burst_pairs:
                fused = _fuse_flash_ambient(_burst_amb[i], _burst_fla[i], mode=fuse)
                if fused is not None:
                    gray = fused
                    params['afisFused'] = fuse
                    params['afisFusedBin'] = f'burst_{i}'
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
        # Real bug found 2026-07-24: for front_only_v1 (this project's own
        # active capture mode), main.py's _download_front_only_frames hands
        # this function exactly ONE pre-selected frame -- `frames` (and
        # therefore `same_frames` above) is always length 1, so `stack`/
        # `focusStack` were STRUCTURALLY GUARANTEED to return None on every
        # single front_only_v1 request, despite being two of the variants
        # main.py's _afis_variants runs every single time. Confirmed via a
        # local sweep of the real capture library: with real multi-frame
        # material, focusStack alone jumped from a no-op (tied with `native`,
        # since it silently fell through) to real wins up to +17 real NFIQ2
        # on some captures. Fall back to the raw preserved same-pose burst
        # (ambient_burst/flash_burst -- already downloaded for every
        # front_only_v1 request to feed deepFuse, all same face-on pose by
        # construction) when the primary frame list can't supply the >=2
        # frames needed to stack anything itself. This can only ever
        # PROMOTE an already-guaranteed-None result to a real one -- it
        # never touches same_frames when `frames` already had enough
        # material (four-angle/oscillating capture modes, which don't hit
        # this starvation), so it can't regress those.
        if len(same_frames) < 2:
            _burst_pool = [g for g in ((ambient_burst or []) + (flash_burst or []))
                           if g is not None]
            if len(_burst_pool) >= 2:
                same_frames = sorted(_burst_pool, key=lambda g: -_ridge_energy(g))[:_STACK_MAX]
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
            # Real bug found 2026-07-23 (capture dadd4ef9): a noisy detector
            # can leave an enclosed hole/notch in an otherwise-plausible pad
            # mask, which becomes a literal white hole in the final print
            # (mask==0 is hard-forced to white below) even though the guide's
            # own area-only accept-gate has no way to catch it. Fill enclosed
            # holes before that gate runs -- can only recover area already
            # inside the detected pad, never grow past it.
            pad_mask = _fill_mask_holes(pad_mask)
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

    # Cross-domain geometry correction (C2CL-style), OFF unless requested via
    # `geom`. Undoes the contactless-vs-contact geometric mismatch (cylinder
    # foreshortening + eventually elastic flatten) on the masked pad BEFORE
    # enhancement, warping g8 and mask together so the rest of the pipeline
    # (freq-normalise, Gabor, feather, upright) is unchanged. Wired as its own
    # max-of-variants candidate in main.py — can only add a print, never
    # regress the best. Success is SourceAFIS genuine-vs-impostor separation,
    # NOT NFIQ2 (see geom_correct.py / docs/FIDELITY_WALL_SCOPE.md). Returns
    # None to self-skip (kept the un-corrected image) if the pad is degenerate.
    if geom:
        _gc = _geom_correct(g8, mask, geom)
        if _gc is None:
            return None, params
        g8, mask = _gc
        params['afisGeom'] = geom

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
    if enhance == 'gaborVarFreq':
        # Spatially-varying ridge-frequency Gabor: fit each region with its own
        # LOCAL ridge period instead of one global wavelength, so ridges stay
        # continuous where the pad's frequency deviates from the median (tip vs
        # base). Falls back to the single-wavelength Gabor if too few reliable
        # period blocks. See _ridge_frequency_map / _gabor_enhance_varfreq.
        norm = _normalize(g8)
        orient = _orientation_field(norm)
        fmap = _ridge_frequency_map(norm, orient, mask)
        if fmap is not None:
            enh = _gabor_enhance_varfreq(norm, orient, fmap)
            params['afisEnhance'] = 'gaborVarFreq'
        else:
            enh = _gabor_enhance(norm, orient, wl)
            params['afisEnhance'] = 'gaborVarFreq_fallback'
        binimg = 255 - (enh < 0).astype(np.uint8) * 255
    elif enhance == 'gaborPyfingField':
        # RESEARCH: same Gabor bank as gaborVarFreq, but the orientation +
        # frequency FIELDS feeding it come from pyfing's neural estimators
        # (Snfoe/Snffe) instead of this module's own classical ones -- isolates
        # whether the field estimate is the limiting factor. See
        # _pyfing_orientation_frequency's docstring for the freq_normalize=True
        # requirement and the LOCAL-MEASUREMENT-ONLY caveat.
        norm = _normalize(g8)
        fields = _pyfing_orientation_frequency(g8, mask)
        if fields is not None:
            orient, fmap = fields
            enh = _gabor_enhance_varfreq(norm, orient, fmap)
            params['afisEnhance'] = 'gaborPyfingField'
        else:
            orient = _orientation_field(norm)
            enh = _gabor_enhance(norm, orient, wl)
            params['afisEnhance'] = 'gaborPyfingField_fallback'
        binimg = 255 - (enh < 0).astype(np.uint8) * 255
    elif enhance == 'fidelity':
        # FIDELITY-oriented enhancement (prime directive): local-frequency
        # Gabor + a ridge-CONFIDENCE gate that blanks hallucinated ridges in
        # low-signal regions, so only repeatable, matchable minutiae survive.
        # Trades NFIQ2 texture for genuine-vs-impostor separation; judged by
        # SourceAFIS, not NFIQ2. See _ridge_confidence / _apply_confidence_gate.
        norm = _normalize(g8)
        orient = _orientation_field(norm)
        fmap = _ridge_frequency_map(norm, orient, mask)
        enh = (_gabor_enhance_varfreq(norm, orient, fmap) if fmap is not None
               else _gabor_enhance(norm, orient, wl))
        conf = _ridge_confidence(g8, mask)
        binimg = _apply_confidence_gate(enh, conf)
        params['afisEnhance'] = 'fidelity'
    elif enhance == 'pyfing':
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
    elif enhance == 'coherenceDiff':
        # Coherence-enhancing diffusion as a denoise PRE-PASS (same role as
        # _pyfing_denoise in the hybrid path, but classical, local, and
        # always available -- no sidecar dependency): smooth lengthwise
        # along the ridge direction to repair small discontinuities, THEN
        # run this module's own tuned Gabor bank + binarization on top for
        # the final black-ridge/white-background conversion.
        norm = _normalize(g8)
        orient0 = _orientation_field(norm)
        denoised = _coherence_diffusion(norm, orient0)
        orient = _orientation_field(denoised)
        enh = _gabor_enhance(denoised, orient, wl)
        binimg = 255 - (enh < 0).astype(np.uint8) * 255
        params['afisEnhance'] = 'coherenceDiff'
    elif enhance == 'nnsHybrid':
        # This project's OTHER enhancement model (enhancement_pipeline.enhance(),
        # CLAHE+Gabor+FingerprintUNet -- see "NNS Enhancement" in main.py) as a
        # denoise pre-pass: its continuous-tone output is visibly smoother/more
        # ridge-continuous than the AFIS binarized template but scores far
        # lower on real NFIQ2 alone (39 vs 76 on the same real capture,
        # 2026-07-16) -- feed it through this module's own tuned Gabor bank +
        # binarization instead of using it as the final image, same
        # denoise-then-Gabor pattern as pyfingHybrid/coherenceDiff. Unlike
        # pyfing, NNS's own convention already matches this project's
        # (ridges dark, background light) -- no invert needed.
        denoised = _nns_denoise(g8, mask)
        if denoised is not None:
            norm = _normalize(denoised)
            orient = _orientation_field(norm)
            enh = _gabor_enhance(norm, orient, wl)
            binimg = 255 - (enh < 0).astype(np.uint8) * 255
            params['afisEnhance'] = 'nnsHybrid'
        else:
            params['afisEnhance'] = 'nnsHybrid_unavailable'
    elif enhance == 'fomfe':
        # Global 2D-Fourier orientation-field model instead of a denoise
        # pre-pass -- see _fomfe_orientation_field's own docstring. No
        # separate denoise step: this replaces ONLY how the orientation
        # field itself is estimated (the direction Gabor filters at each
        # pixel), leaving the actual pixel content (g8/norm) untouched --
        # a different axis of change than every other hybrid variant above,
        # which all denoise the IMAGE then re-run the existing local
        # orientation estimator on the cleaned image.
        norm = _normalize(g8)
        orient = _fomfe_orientation_field(norm, mask)
        if orient is not None:
            enh = _gabor_enhance(norm, orient, wl)
            binimg = 255 - (enh < 0).astype(np.uint8) * 255
            params['afisEnhance'] = 'fomfe'
        else:
            params['afisEnhance'] = 'fomfe_unavailable'
    if binimg is None:
        # Either enhance == 'gabor', or a pyfing path was requested but the
        # sidecar wasn't configured/reachable -- same non-blocking contract
        # as every other optional signal in this module (fall back, don't
        # fail).
        norm = _normalize(g8)
        orient = _orientation_field(norm)
        enh = _gabor_enhance(
            norm, orient, wl,
            sigma_ratio=(gabor_sigma_ratio if gabor_sigma_ratio is not None
                         else _GABOR_SIGMA_RATIO),
            gamma=(gabor_gamma if gabor_gamma is not None else _GABOR_GAMMA),
        )
        binimg = 255 - (enh < 0).astype(np.uint8) * 255   # ridges black on white
        params.setdefault('afisEnhance', 'gabor')

    # Sub-pixel anti-alias pass (2026-08-03, visual-QA finding, MEASURED
    # NEGATIVE on real NFIQ2 -- OFF by default, see below). The hard sign-
    # threshold binarization above (`enh < 0`) quantizes a smooth Gabor
    # response straight to 0/255, leaving a visible pixel "staircase" along
    # every ridge edge -- clearly visible zoomed in, even in the print's
    # interior, far from any mask boundary. A real scanner print's ridge
    # edges are naturally anti-aliased, not stair-stepped, so a small
    # Gaussian blur on binimg looks visually closer to a real print.
    # Swept sigma 0.0/0.3/0.5/0.7/1.0/1.3/1.6 against REAL NFIQ2 (locally
    # built nfiq2 binary, not the proxy) on 4 diverse real captures
    # (nfiq2Score 46-95): mean score fell fairly consistently as sigma rose
    # (0.0: 66.75 -> 0.7: 64.00 -> 1.6: 59.75) -- confirms this pipeline's
    # own established finding that NFIQ2 specifically rewards high-frequency
    # ridge-like texture, and any smoothing directly trades that away. This
    # is a real look-vs-score conflict, not a bug: unlike the mask-taper fix
    # above (a clean win on both axes), this one only helps the visual read.
    # Left OFF (0.0) by default rather than unilaterally trading away score
    # for looks -- flip _AA_SIGMA to e.g. 0.7 if visual naturalness should
    # win this specific trade-off instead.
    if _AA_SIGMA > 0.0:
        binimg = cv2.GaussianBlur(binimg, (0, 0), sigmaX=_AA_SIGMA)

    binimg[mask == 0] = 255   # hard mask FIRST -- background is genuinely
    # pure white here, zero Gabor-noise content, before any blur touches it.
    #
    # Fade ridges out toward the mask edge instead of leaving a hard cutoff.
    # A real digital scanner print has no thumb-silhouette outline -- ridges
    # simply taper off at the contact edge, at slightly different points per
    # ridge, not all at once along one geometric curve. cv2.distanceTransform
    # gives each foreground pixel its distance (px) to the nearest background
    # pixel; normalizing that by _FADE_INSET_PX and clamping to [0, 1] builds
    # an alpha ramp that's 1.0 (full black ridges) once _FADE_INSET_PX inside
    # the mask and drops to 0.0 (white) exactly AT the boundary -- so the
    # print itself visually thins out and disappears before reaching the crop
    # edge, rather than being sliced by it. This also removes the real
    # spurious-ridge-ending-minutiae risk a hard boundary creates (every
    # ridge terminating simultaneously on the same curve is not a real
    # fingerprint feature). A small Gaussian pass on the alpha ramp itself
    # (same _FEATHER_SIGMA as before) just keeps the ramp from banding: the
    # underlying mask shape is already irregular (real segmentation, not a
    # perfect ellipse), so this reads as an organic taper, not a blurred
    # oval. Computed entirely from `binimg`/`mask` post-hard-crop, so it can
    # never reveal the unmasked Gabor response outside the pad the way an
    # earlier blur-the-mask-then-blend-against-unmasked-binimg version did
    # (that leaked a faint ghosted second boundary past the real edge).
    # `mask` itself stays hard-edged below (crop bounding box, _upright_
    # rotate's PCA) -- only the pixel blend is softened.
    dist = cv2.distanceTransform((mask > 0).astype(np.uint8), cv2.DIST_L2, 5)
    alpha = np.clip(dist / _FADE_INSET_PX, 0.0, 1.0).astype(np.float32)
    alpha = cv2.GaussianBlur(alpha, (0, 0), sigmaX=_FEATHER_SIGMA)
    binimg = (binimg.astype(np.float32) * alpha +
              255.0 * (1.0 - alpha)).astype(np.uint8)
    if guide_region is not None and guide_mask is not None and 'tipAngleDeg' in guide_region:
        # Deterministic upright from the guide's known tip direction -- the pad
        # silhouette is near-symmetric, so PCA (_upright_rotate) can pick the
        # wrong axis; the app tells us exactly which way the tip points.
        binimg, mask = _upright_from_tip(binimg, mask, float(guide_region['tipAngleDeg']))
    else:
        binimg, mask = _upright_rotate(binimg, mask)
    params['afisRotated'] = True

    # Mirror-correction SCAFFOLD (2026-08-03, CTO-reported): this capture
    # flow requires the user to twist their thumb behind the phone to
    # present the pad to the rear camera -- a real geometric mirror vs. a
    # direct scan/ink impression (finger pressed straight down, never
    # twisted), already root-caused in this project's history (see
    # CLAUDE.md, "CTO capture-geometry explanation: thumb-twist mirroring",
    # 2026-07-17). No flip has ever been applied anywhere in this pipeline
    # (confirmed: this module has zero `cv2.flip`/mirror logic elsewhere) --
    # so every AFIS print produced so far is in "as captured" orientation,
    # not "as if pressed directly" orientation. An earlier SourceAFIS test
    # that round found mirroring did NOT improve match score on average, but
    # was run against a single low-quality ink-scan reference already known
    # to sit at the matcher's noise floor -- inconclusive, not a refutation.
    # Applied LAST (after upright rotation), so it composes cleanly with
    # every other step. Default OFF -- gated the same as every other
    # unvalidated lever in this pipeline (geom=, enhance='fidelity', etc.):
    # needs a real matcher test against a trustworthy reference before this
    # becomes the default, not just a visual guess this time either.
    if mirror:
        binimg = cv2.flip(binimg, 1)
        mask = cv2.flip(mask, 1)
        params['afisMirrored'] = True

    ys, xs = np.where(mask > 0)
    m = 30
    y0, x0 = max(0, ys.min() - m), max(0, xs.min() - m)
    y1 = min(binimg.shape[0], ys.max() + m)
    x1 = min(binimg.shape[1], xs.max() + m)
    return binimg[y0:y1, x0:x1], params
