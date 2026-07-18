"""Synthetic contactless-distortion generator for self-supervised deform
training.

The SD302f contactless rig photos proved to be a dead end for training a
deformation net (see CLAUDE.md 2026-07-18: crude crops + per-pair alignment
noise => no generalizable shared signal). This module takes the OPPOSITE
approach, using the clean, abundant SD302a/b/d CONTACT prints as source:
apply a KNOWN, physically-grounded contactless-capture distortion to a clean
contact print, then train the net to invert it. Perfect ground truth (we
applied the warp), a consistent distortion family by construction (no
contradictory per-pair targets), and clean source material.

The dominant real effect is CYLINDER FORESHORTENING: a fingertip is ~a
cylinder, and a contactless lens sees it in perspective -- the pad centre
(tangent to the camera) images at full scale while the sides recede and
compress toward the silhouette. Contact printing instead "unrolls" the
cylinder to uniform arc spacing. So contactless = centre-normal, edges-
compressed; contact = uniform. We synthesise the former from the latter and
train the net to recover the latter (which is exactly the contactless->contact
geometry MAC3D needs). Modelled as nx = sin(nu*A)/sin(A): a flat arc position
nu in [-1,1] images at contactless position nx, with A the half wrap angle.

Deliberately NOT modelled here: the CTO's twist-MIRROR (a global horizontal
flip a small local-flow net structurally cannot undo -- handled separately in
preprocessing, not by this net) and gross rotation/translation (also global).
This net's job is the local elastic + foreshortening residual only.
"""
from __future__ import annotations

import cv2
import numpy as np


def _elastic_field(h: int, w: int, mag: float, smooth: float,
                   rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """Smooth low-frequency random displacement field (normalised units),
    representing residual skin elasticity on top of the cylinder model."""
    dx = cv2.GaussianBlur(rng.standard_normal((h, w)).astype(np.float32), (0, 0), smooth)
    dy = cv2.GaussianBlur(rng.standard_normal((h, w)).astype(np.float32), (0, 0), smooth)
    dx = dx / (dx.std() + 1e-6) * mag
    dy = dy / (dy.std() + 1e-6) * mag
    return dx, dy


def synth_contactless(clean: np.ndarray, rng: np.random.Generator | None = None,
                      wrap_angle: float | None = None,
                      elastic_mag: float | None = None,
                      photometric: bool = True) -> np.ndarray:
    """Return a synthetic contactless-distorted version of a clean contact
    print (uint8 grayscale in, uint8 grayscale out, same shape)."""
    if rng is None:
        rng = np.random.default_rng()
    h, w = clean.shape[:2]
    A = wrap_angle if wrap_angle is not None else float(rng.uniform(0.9, 1.4))  # ~52-80 deg
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    nx = (xs / (w - 1)) * 2 - 1
    ny = (ys / (h - 1)) * 2 - 1
    # cylinder foreshortening on the across-finger (x) axis: for output column
    # nx, read source at flat arc nu = arcsin(nx*sinA)/A.
    sinA = float(np.sin(A))
    src_nx = np.arcsin(np.clip(nx * sinA, -1.0, 1.0)) / A
    src_ny = ny
    # residual elastic
    em = elastic_mag if elastic_mag is not None else float(rng.uniform(0.0, 0.04))
    edx, edy = _elastic_field(h, w, em, smooth=max(h, w) * 0.06, rng=rng)
    src_nx = src_nx + edx
    src_ny = src_ny + edy
    map_x = ((src_nx + 1) / 2 * (w - 1)).astype(np.float32)
    map_y = ((src_ny + 1) / 2 * (h - 1)).astype(np.float32)
    out = cv2.remap(clean, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
    if photometric:
        o = out.astype(np.float32) / 255.0
        o = np.clip(o ** float(rng.uniform(0.8, 1.2)), 0, 1)          # gamma
        o = np.clip((o - 0.5) * float(rng.uniform(0.7, 1.0)) + 0.5, 0, 1)  # contrast down
        if rng.random() < 0.5:
            o = cv2.GaussianBlur(o, (0, 0), float(rng.uniform(0.5, 1.5)))
        out = (o * 255).astype(np.uint8)
    return out
