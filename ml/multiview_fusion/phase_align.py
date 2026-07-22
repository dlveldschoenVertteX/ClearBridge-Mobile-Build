"""Classical local phase-demodulation registration -- the literature-correct
fix for periodic ridge texture, per the close-out in README.md ("Phase 2
real-GPU training") after five negative results showed intensity-
correlation-based registration cannot reliably work on this data:

- Phase 0/1 (classical): NCC block-matching failed via periodicity
  aliasing (median match displacement scaled linearly with search-window
  size instead of converging), minutiae nearest-neighbor failed via
  chance-match density, seam-routed compositing came out mixed.
- Phase 2 (learned): the trained corr-net mean-collapsed (predicts ~zero
  flow everywhere). A zero-learning diagnostic (probe_minimal.py Part A)
  measured the actual ceiling directly -- raw local-intensity correlation
  on real fingerprint crops recovers a KNOWN small shift only 15% of the
  time (~12x above chance, but far too weak/noisy to train a network on).

The real fingerprint dense-registration literature (Cui & Feng, TIFS 2018,
"2-D Phase Demodulation for Deformable Fingerprint Registration"; PDRNet,
T-IFS 2024) never does patch/template matching at all -- it treats ridge
texture as a local 2-D cosine wave (amplitude + phase) and reads
displacement directly off the PHASE difference between two analytic
signals at the same location. This is NOT an incremental tweak to
correlation: phase varies *continuously and linearly* with sub-period
shift (no discrete-peak aliasing to speak of), so it sidesteps the exact
failure mode that broke every method tried so far on this branch.

## The aperture problem, and why it's the RIGHT restriction here

A single local orientation/frequency estimate only resolves displacement
along the ridge-NORMAL direction (the direction ridges vary in) -- shift
along a ridge's own tangent is invisible to phase (and to the human eye:
a print shifted along its own ridge direction looks identical). This is
the classical aperture problem for periodic 1-D-like texture (Fleet &
Jepson's phase-based optical flow hits the same wall generically). Rather
than fight it, this module treats it as the correct scope: ridge
CONTINUITY -- the actual failure mode this whole branch exists to fix --
only breaks under normal-direction misalignment. Tangential slip does not
create a visible seam. So a normal-direction-only residual estimator is
not a compromise; it is exactly the quantity that matters, still combined
with the existing ECC/homography step (common.ecc_homography_align) for
the global affine + any un-resolvable tangential component.

## Residual-only scope

Phase-difference here only recovers displacement UP TO HALF A RIDGE
PERIOD before it wraps and aliases the same way correlation does over a
full period -- so this is explicitly a REFINEMENT step on top of ECC's
existing coarse global alignment (same "coarse handles the big motion,
fine only resolves the sub-period residual" contract as the abandoned
CoarseToFinePairNet pyramid, just realized classically instead of with a
learned correlation volume that was shown to lack the signal for it).
"""
from __future__ import annotations

from typing import Optional

import cv2
import numpy as np

from common import (
    _GABOR_GAMMA,
    _GABOR_SIGMA_RATIO,
    _N_ORIENT,
    normalize,
    orientation_field,
    ridge_wavelength,
)


def _wrap_pi(a: np.ndarray) -> np.ndarray:
    return (a + np.pi) % (2 * np.pi) - np.pi


def analytic_phase(img: np.ndarray, orient: np.ndarray, wavelength: float
                    ) -> tuple[np.ndarray, np.ndarray]:
    """Per-pixel local ridge phase (radians) + amplitude (confidence), via
    a per-pixel-varying quadrature Gabor bank (even=cos-phase,
    odd=sin-phase) tuned to `orient`/`wavelength` -- same discretized-
    orientation-bank/per-pixel-index trick as common.gabor_enhance, run
    twice (psi=0, psi=-pi/2) to form an analytic (Hilbert-quadrature)
    pair. Z = even + i*odd; phase = angle(Z), amplitude = |Z|.
    """
    h, w = img.shape
    sigma = _GABOR_SIGMA_RATIO * wavelength
    ksize = int(2 * np.ceil(3 * sigma) + 1)
    even = np.zeros((_N_ORIENT, h, w), np.float32)
    odd = np.zeros((_N_ORIENT, h, w), np.float32)
    for i in range(_N_ORIENT):
        th = np.pi * i / _N_ORIENT
        ke = cv2.getGaborKernel((ksize, ksize), sigma, th + np.pi / 2,
                                 wavelength, _GABOR_GAMMA, 0, cv2.CV_32F)
        ko = cv2.getGaborKernel((ksize, ksize), sigma, th + np.pi / 2,
                                 wavelength, _GABOR_GAMMA, -np.pi / 2, cv2.CV_32F)
        ke = ke - ke.mean()
        ko = ko - ko.mean()
        even[i] = cv2.filter2D(img, cv2.CV_32F, ke)
        odd[i] = cv2.filter2D(img, cv2.CV_32F, ko)
    idx = np.round((orient % np.pi) / (np.pi / _N_ORIENT)).astype(int) % _N_ORIENT
    yy, xx = np.mgrid[0:h, 0:w]
    ev = even[idx, yy, xx]
    od = odd[idx, yy, xx]
    phase = np.arctan2(od, ev)
    amplitude = np.sqrt(ev * ev + od * od)
    return phase, amplitude


def phase_residual_shift(front: np.ndarray, side_reg: np.ndarray,
                          mask: Optional[np.ndarray] = None,
                          min_amplitude_frac: float = 0.15) -> dict:
    """Dense residual displacement along the LOCAL RIDGE-NORMAL direction
    between `front` and an already-ECC/homography-registered `side_reg`
    (common.ecc_homography_align's output), via analytic phase
    difference. Front's own orientation/wavelength field is used to
    demodulate BOTH images (valid because after ECC alignment the two
    should already share close to the same local ridge geometry -- only
    a small residual remains).

    Returns:
      normal_shift_px : per-pixel scalar, wrapped to (-wavelength/2,
        wavelength/2] -- ONLY valid as a residual (assumes the true
        remaining displacement is already sub-half-period after ECC).
      shift_vec       : (2,H,W) full vector field, normal_shift_px
        projected onto the local ridge-normal direction (orient + pi/2).
      confidence      : per-pixel amplitude-product confidence, [0,1].
      valid           : confidence/mask gate.
      orient, wavelength: the front-derived field/scalar used.
    """
    norm_f = normalize(front)
    norm_s = normalize(side_reg)
    orient = orientation_field(norm_f)
    wavelength = ridge_wavelength(norm_f, orient)
    phase_f, amp_f = analytic_phase(norm_f, orient, wavelength)
    phase_s, amp_s = analytic_phase(norm_s, orient, wavelength)
    dphi = _wrap_pi(phase_f - phase_s)
    normal_shift = dphi * wavelength / (2 * np.pi)
    conf_raw = amp_f * amp_s
    # Normalize by a high PERCENTILE, not the raw max -- on a full real
    # capture (unlike the small, homogeneous-amplitude crops this method
    # was first validated on), amplitude is heavily right-skewed: a
    # handful of specular/high-contrast pixels can be 10-100x the typical
    # in-ridge value, and dividing by that single outlier max collapses
    # nearly the whole real ridge area below any reasonable threshold
    # (measured: max-normalized confidence had a MEDIAN of 0.0002-0.0013
    # within the real overlap region on real captures -- effectively
    # nothing passed). A percentile is robust to that outlier the way a
    # single max value is not.
    ref_pool = conf_raw if mask is None else conf_raw[mask > 0]
    scale = float(np.percentile(ref_pool, 95)) if ref_pool.size else 1.0
    conf = np.clip(conf_raw / max(scale, 1e-6), 0.0, 1.0)
    valid = conf > min_amplitude_frac
    if mask is not None:
        valid = valid & (mask > 0)
    nx, ny = np.cos(orient + np.pi / 2), np.sin(orient + np.pi / 2)
    shift_vec = np.stack([normal_shift * nx, normal_shift * ny], axis=0)
    return dict(normal_shift_px=normal_shift, shift_vec=shift_vec,
                confidence=conf, valid=valid, orient=orient,
                wavelength=wavelength)


def warp_by_normal_shift(side_reg: np.ndarray, result: dict) -> np.ndarray:
    """Apply `phase_residual_shift`'s vector field to `side_reg` via
    dense remap (sampling AT p + shift so the warped image content moves
    to cancel the estimated residual -- same forward-warp convention as
    the rest of this module's synth/deform code)."""
    h, w = side_reg.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    sx, sy = result['shift_vec']
    map_x = (xx + sx).astype(np.float32)
    map_y = (yy + sy).astype(np.float32)
    return cv2.remap(side_reg, map_x, map_y, cv2.INTER_LINEAR,
                      borderMode=cv2.BORDER_REFLECT)
