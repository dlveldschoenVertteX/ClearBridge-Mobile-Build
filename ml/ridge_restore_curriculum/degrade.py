"""Synthetic degradation generator for curriculum-based ridge restoration
training.

CTO's own idea, refined per the discussion before building this: rather
than a small fixed number of discrete blur-percentage "pairs" (which risks
the network memorizing those exact settings instead of generalizing), this
samples a FRESH random severity and degradation mix every time an image is
loaded -- same "different distortion each epoch" discipline as
ml/deform_correct's own synth_distort.py -- with the ALLOWED SEVERITY RANGE
widening over the course of training (the actual curriculum, applied via
`severity_cap` from train.py's epoch-based schedule, not via a fixed set of
pre-baked pairs).

Also broadened beyond blur alone to the real, already-documented failure
modes this project's own capture history has repeatedly hit on real
devices: flash/torch specular blowout, low contrast/underexposure, uneven
illumination. Training against blur alone would leave the network naive to
the defects that actually show up in production captures.
"""
from __future__ import annotations

import random

import cv2
import numpy as np


def _blur(img: np.ndarray, severity: float, rng: random.Random) -> np.ndarray:
    sigma = rng.uniform(0.0, 3.5 * severity)
    if sigma < 0.15:
        return img
    if rng.random() < 0.3:
        # Motion blur -- a directional kernel, mimicking hand-shake during
        # capture rather than pure defocus.
        ksize = max(3, int(sigma * 4) | 1)
        kernel = np.zeros((ksize, ksize), np.float32)
        angle = rng.uniform(0, 180)
        cv2.line(kernel, (0, ksize // 2), (ksize - 1, ksize // 2), 1.0, 1)
        M = cv2.getRotationMatrix2D((ksize / 2, ksize / 2), angle, 1.0)
        kernel = cv2.warpAffine(kernel, M, (ksize, ksize))
        kernel /= max(kernel.sum(), 1e-6)
        return cv2.filter2D(img, -1, kernel)
    return cv2.GaussianBlur(img, (0, 0), sigma)


def _specular_blowout(img: np.ndarray, severity: float, rng: random.Random) -> np.ndarray:
    """Real, repeatedly-documented failure mode in this project's own
    capture history: the flash/torch overexposing part of the pad, washing
    out ridge contrast in a roughly circular falloff region (distance-
    squared falloff from the light source, same physical mechanism
    CLAUDE.md's own capture-side notes describe)."""
    h, w = img.shape
    cx, cy = rng.uniform(0.15, 0.85) * w, rng.uniform(0.15, 0.85) * h
    radius = rng.uniform(0.25, 0.6) * max(h, w) * severity
    if radius < 5:
        return img
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    d2 = (xs - cx) ** 2 + (ys - cy) ** 2
    falloff = np.exp(-d2 / (2 * radius ** 2))
    strength = rng.uniform(0.3, 0.9) * severity
    return img + (1.0 - img) * falloff * strength   # blend toward white


def _low_contrast(img: np.ndarray, severity: float, rng: random.Random) -> np.ndarray:
    factor = 1.0 - rng.uniform(0.0, 0.65) * severity
    mean = img.mean()
    return (img - mean) * factor + mean


def _uneven_illumination(img: np.ndarray, severity: float, rng: random.Random) -> np.ndarray:
    h, w = img.shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    angle = rng.uniform(0, 2 * np.pi)
    grad = (xs / w) * np.cos(angle) + (ys / h) * np.sin(angle)
    grad = (grad - grad.min()) / (grad.max() - grad.min() + 1e-6)
    strength = rng.uniform(0.0, 0.5) * severity
    mult = 1.0 - strength * 0.5 + strength * grad
    return img * mult


def _noise(img: np.ndarray, severity: float, rng: random.Random) -> np.ndarray:
    sigma = rng.uniform(0.0, 0.04) * severity
    if sigma < 0.002:
        return img
    return img + np.random.default_rng(rng.randint(0, 2**31 - 1)).normal(0, sigma, img.shape)


_DEGRADATIONS = [
    (_blur, 0.9),
    (_specular_blowout, 0.35),
    (_low_contrast, 0.5),
    (_uneven_illumination, 0.45),
    (_noise, 0.3),
]


def degrade(clean_u8: np.ndarray, severity_cap: float, rng: random.Random) -> np.ndarray:
    """clean_u8: uint8 grayscale, real clean print. severity_cap: the
    CURRICULUM knob (train.py widens this over epochs, e.g. 0.2 early ->
    1.0 late) -- the actual per-call severity is drawn uniformly up to this
    cap, not fixed at it, so even early-curriculum batches see some easy
    (near-zero severity) examples and some near-cap ones. Applies a random
    SUBSET of degradation types (each with its own real-world-motivated
    probability) rather than always stacking all five -- real captures
    rarely hit every failure mode simultaneously."""
    img = clean_u8.astype(np.float32) / 255.0
    # Biased toward the cap (floor at 30% of it) rather than plain
    # uniform(0, cap) -- verified via a direct visual check that plain
    # uniform sampling let many individual calls land on mild severity
    # even with severity_cap=1.0 (mean draw is only cap/2, and combined
    # with each degradation's own independent fire-probability, a late-
    # curriculum epoch could still mostly serve barely-degraded examples
    # by chance). This keeps real variety (some calls near the floor, some
    # near the cap) while making genuinely hard examples the norm, not the
    # exception, once the curriculum reaches its harder stages.
    cap = max(0.02, severity_cap)
    this_call_severity = cap * (0.3 + 0.7 * rng.random())
    for fn, prob in _DEGRADATIONS:
        if rng.random() < prob:
            img = fn(img, this_call_severity, rng)
    return np.clip(img, 0.0, 1.0)
