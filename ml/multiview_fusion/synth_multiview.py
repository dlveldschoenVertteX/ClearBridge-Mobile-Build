"""Synthetic same-domain pair generator for Phase 2's learned deformation
model -- the supervision trick that every classical attempt in this branch
lacked: instead of trying to ESTIMATE correspondence on one noisy real pair
(NCC block-matching and minutiae matching both failed, see README.md), we
MANUFACTURE pairs with exactly-known ground truth from single real frames.

Construction (direction matters -- chosen so no field inversion is ever
needed): take a real frame R, draw a random smooth flow field g (pixels),
and synthesize the FRONT as front(p) = R(p + g(p)). The pair fed to the
net is (front, R-as-side); the target flow that warps the side into the
front's geometry is then EXACTLY g, by construction:
    warp(R, g)(p) = R(p + g(p)) = front(p).
(Compare: synthesizing the side from the front would require inverting the
dense map p -> p+g(p) to get a supervision target -- approximate and messy.)

The residual family g models what remains AFTER the production ECC
homography alignment (the net always sees ECC-registered sides at
inference): small residual affine error + multi-scale smooth elastic
deformation. NOT gross rotation/translation -- ECC handles that, and
including it would teach the net to fight a solved problem. Magnitude range
includes zero so the net learns to do NOTHING when alignment is already
good (same graceful-identity discipline as ml/deform_correct/model.py's
zero-init flow head).

Photometric augmentation is applied INDEPENDENTLY to each view, and is
deliberately aggressive about smooth illumination gradients: on real
captures the torch highlight moves across the curved pad between views,
which is precisely why intensity-based matching (NCC) failed. Forcing the
net to align pairs whose intensities disagree teaches it to match ridge
STRUCTURE instead.

All flows are in PIXELS (not normalized grid units) -- see deform_net.py's
PixelWarp for why: the net trains on small crops and runs on full frames,
and normalized-unit flows silently change physical displacement with image
size (the exact class of scale bug that invalidated the first deform-
correct v2 evaluation, CLAUDE.md 2026-07-18).

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

from typing import Optional, Tuple

import cv2
import numpy as np

# Residual-deformation family (pixels, at native capture scale where ridge
# wavelength is ~9-20px). Total displacement is capped implicitly by the
# component ranges: worst case ~ 3 + 6 + 3 ~ 12px 1-sigma-ish, comfortably
# inside deform_net's ±24px head cap, and spanning the 5-20px range the
# failed classical attempts suggested real residuals occupy.
_AFFINE_RESID_PX = 3.0      # max residual affine corner displacement
_ELASTIC_COARSE_PX = 6.0    # max coarse elastic magnitude (smooth, ~1/6 frame)
_ELASTIC_FINE_PX = 3.0      # max fine elastic magnitude (~1/16 frame)
_GAIN_RANGE = (0.55, 1.45)  # smooth illumination-gradient gain field bounds


def _smooth_field(h: int, w: int, mag_px: float, smooth_frac: float,
                  rng: np.random.Generator) -> Tuple[np.ndarray, np.ndarray]:
    """Random smooth displacement field in PIXELS, std normalised to mag_px."""
    sigma = max(h, w) * smooth_frac
    dx = cv2.GaussianBlur(rng.standard_normal((h, w)).astype(np.float32), (0, 0), sigma)
    dy = cv2.GaussianBlur(rng.standard_normal((h, w)).astype(np.float32), (0, 0), sigma)
    dx = dx / (dx.std() + 1e-6) * mag_px
    dy = dy / (dy.std() + 1e-6) * mag_px
    return dx, dy


def _affine_residual_flow(h: int, w: int, mag_px: float,
                          rng: np.random.Generator) -> Tuple[np.ndarray, np.ndarray]:
    """Flow field of a small random affine residual (what's left when ECC's
    homography fit is slightly off -- e.g. it converged on blurred ridges)."""
    # Random affine: identity + small perturbation, expressed directly as flow.
    a = rng.uniform(-1, 1, size=6).astype(np.float32)
    scale = mag_px / max(h, w)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    xr, yr = xs - cx, ys - cy
    dx = scale * (a[0] * xr + a[1] * yr) + a[2] * mag_px * 0.5
    dy = scale * (a[3] * xr + a[4] * yr) + a[5] * mag_px * 0.5
    return dx, dy


def sample_flow(h: int, w: int, rng: np.random.Generator,
                strength: Optional[float] = None) -> np.ndarray:
    """Draw one residual flow field g, shape (2, H, W) float32 PIXELS,
    channel order (dx, dy). `strength` in [0,1] scales the whole family;
    drawn uniformly (including near-zero) if not given."""
    s = float(rng.uniform(0.0, 1.0)) if strength is None else float(strength)
    adx, ady = _affine_residual_flow(h, w, _AFFINE_RESID_PX * s, rng)
    cdx, cdy = _smooth_field(h, w, _ELASTIC_COARSE_PX * s, 1 / 6.0, rng)
    fdx, fdy = _smooth_field(h, w, _ELASTIC_FINE_PX * s, 1 / 16.0, rng)
    return np.stack([adx + cdx + fdx, ady + cdy + fdy]).astype(np.float32)


def _photometric(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Independent per-view photometric jitter: smooth illumination-gradient
    gain field (the moving-torch-highlight effect), gamma, contrast, blur,
    sensor noise."""
    o = img.astype(np.float32) / 255.0
    h, w = o.shape
    # Smooth multiplicative gain field -- low-frequency random, like a torch
    # highlight / shading gradient sliding across the curved pad.
    g = cv2.GaussianBlur(rng.standard_normal((h, w)).astype(np.float32),
                         (0, 0), max(h, w) * 0.25)
    g = (g - g.min()) / (g.max() - g.min() + 1e-6)
    lo, hi = _GAIN_RANGE
    gain = lo + (hi - lo) * g
    o = np.clip(o * gain, 0, 1)
    o = np.clip(o ** float(rng.uniform(0.75, 1.3)), 0, 1)                    # gamma
    o = np.clip((o - 0.5) * float(rng.uniform(0.7, 1.15)) + 0.5, 0, 1)       # contrast
    if rng.random() < 0.5:
        o = cv2.GaussianBlur(o, (0, 0), float(rng.uniform(0.4, 1.6)))        # blur
    o = np.clip(o + rng.standard_normal((h, w)).astype(np.float32)
                * float(rng.uniform(0.0, 0.02)), 0, 1)                        # noise
    return (o * 255).astype(np.uint8)


def synth_pair(frame: np.ndarray, rng: np.random.Generator,
               strength: Optional[float] = None
               ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Real grayscale frame -> (front u8, side u8, gt_flow_px (2,H,W) f32).

    warp(side, gt_flow_px) == front geometrically (exact, by construction);
    photometrically the two views differ (independent jitter), so the only
    reliable alignment signal is ridge structure -- as on real pairs.
    """
    h, w = frame.shape[:2]
    g = sample_flow(h, w, rng, strength)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    front_geom = cv2.remap(frame, xs + g[0], ys + g[1], cv2.INTER_LINEAR,
                           borderMode=cv2.BORDER_REFLECT)
    front = _photometric(front_geom, rng)
    side = _photometric(frame, rng)
    return front, side, g
