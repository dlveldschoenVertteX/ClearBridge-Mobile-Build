"""Synthetic training-pair generator for the two-crop registration network.

Builds (reference, side, target_params) triples from a SINGLE real front
print: `side` is a synthetically rigid-transformed crop of the same source
content as `reference`, with a KNOWN transform, so the network always has
exact ground truth to regress against -- the same reasoning
ml/deform_correct/synth_distort.py used to escape the real-pair-has-no-
consistent-signal trap (see that module's docstring and this project's own
2026-07-18 SD302f finding), applied here to a rigid-registration task
instead of a single-image dewarp task.

Ground-truth derivation (verified numerically, not just derived on paper --
see the round-trip self-test at the bottom of this file): F.affine_grid's
`theta` is a PULL-sample transform (output(p) = input(theta @ [p,1])), so if
`side = warp_with_params(canvas, P_gen)`, then reconstructing `reference`
FROM `side` requires `invert_params(P_gen)`, not `P_gen` itself. This
distinction is exactly the kind of sign/convention bug this project's own
history has repeatedly found the hard way (BoxFit.cover coordinate mismatch,
_ridge_wavelength's rotate-before-vs-after bug) -- it is verified here by an
explicit forward/inverse round-trip test, not assumed correct by inspection.
"""
from __future__ import annotations

import random

import cv2
import numpy as np
import torch

from model import warp_with_params, invert_params

_CANVAS = 480     # working canvas real prints are resized/padded to before cropping
_CROP = 320       # final training crop size (both reference and side)
_MAX_ANGLE_DEG = 20.0     # "slightly tilted", per the CTO's own framing -- not
                          # a wide-baseline stereo view
_MAX_SHIFT_FRAC = 0.18    # translation as a fraction of _CROP


def load_and_canvas(path: str) -> np.ndarray:
    """Real print -> a fixed CANVASxCANVAS grayscale canvas: resize so the
    long side fits CANVAS (preserving aspect ratio -- a resize, not a
    ridge-wavelength renormalisation, is enough here since every source
    print already came out of the SAME production pipeline at a broadly
    similar ridge scale), then white-pad (255 = background, matching this
    project's own binarized-print convention) to a centred square."""
    g = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if g is None:
        raise RuntimeError(f'unreadable print: {path}')
    h, w = g.shape
    scale = _CANVAS / max(h, w)
    new_w, new_h = max(1, int(w * scale)), max(1, int(h * scale))
    g = cv2.resize(g, (new_w, new_h),
                   interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC)
    pad_w, pad_h = _CANVAS - new_w, _CANVAS - new_h
    g = cv2.copyMakeBorder(g, pad_h // 2, pad_h - pad_h // 2,
                           pad_w // 2, pad_w - pad_w // 2,
                           cv2.BORDER_CONSTANT, value=255)
    return g


def _random_params(rng: random.Random) -> torch.Tensor:
    angle = rng.uniform(-_MAX_ANGLE_DEG, _MAX_ANGLE_DEG)
    tx = rng.uniform(-_MAX_SHIFT_FRAC, _MAX_SHIFT_FRAC) * (_CROP / _CANVAS) * 2
    ty = rng.uniform(-_MAX_SHIFT_FRAC, _MAX_SHIFT_FRAC) * (_CROP / _CANVAS) * 2
    # translation expressed directly in the CANVAS's own normalised
    # [-1,1] units (matching what warp_with_params expects when applied to
    # the canvas, before it's center-cropped down to _CROP).
    rad = np.deg2rad(angle)
    return torch.tensor([np.cos(rad), np.sin(rad), tx, ty], dtype=torch.float32)


def make_pair(path: str, rng: random.Random | None = None,
             photometric_jitter: bool = True
             ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Returns (reference_crop, side_crop, target_params) -- the first two
    as float32 [0,1] CROPxCROP arrays, the last as a length-4 float32 numpy
    array (cos, sin, tx, ty) the network should learn to predict, in the
    SAME normalised units warp_with_params(side_crop, target_params) needs
    to reconstruct something close to reference_crop."""
    rng = rng or random.Random()
    canvas = load_and_canvas(path)
    canvas_t = torch.from_numpy(canvas.astype(np.float32) / 255.0)[None, None]

    params_gen = _random_params(rng)[None]
    side_canvas_t = warp_with_params(canvas_t, params_gen)
    target_params = invert_params(params_gen)[0].numpy()
    # target_params' translation was derived in CANVAS-normalised units
    # (params_gen was applied to the full _CANVAS-sized image). The network
    # operates on _CROP-sized images (both at training time -- see the
    # self-test below -- and at inference time in production), and
    # grid_sample's normalised translation units are relative to the image
    # being warped, so the SAME physical pixel shift needs a DIFFERENT
    # numeric value depending on which size it's expressed against. Rescale
    # here so target_params is valid for warp_with_params(side_crop, ...),
    # not warp_with_params(canvas, ...). Real bug caught by this file's own
    # round-trip self-test (mean abs err ~0.3-0.5 before this fix, on real
    # prints -- the small synthetic-image sanity check run earlier used a
    # single fixed size throughout and never exercised this canvas-vs-crop
    # unit mismatch at all).
    target_params[2:] *= (_CANVAS - 1) / (_CROP - 1)

    off = (_CANVAS - _CROP) // 2
    reference = canvas_t[0, 0, off:off + _CROP, off:off + _CROP].numpy()
    side = side_canvas_t[0, 0, off:off + _CROP, off:off + _CROP].numpy()

    if photometric_jitter:
        reference = _jitter(reference, rng)
        side = _jitter(side, rng)

    return reference.astype(np.float32), side.astype(np.float32), target_params.astype(np.float32)


def _jitter(img: np.ndarray, rng: random.Random) -> np.ndarray:
    """Mild independent photometric jitter -- real front vs. angled shots
    come from different torch/exposure states within the same burst
    (adaptive flash EV, natural brightness drift), so the network shouldn't
    key off raw intensity matching."""
    g = rng.uniform(0.85, 1.15)
    c = rng.uniform(0.85, 1.1)
    out = np.clip(img ** g, 0, 1)
    out = np.clip((out - 0.5) * c + 0.5, 0, 1)
    return out


if __name__ == '__main__':
    # Self-test: round-trip a KNOWN transform through make_pair's own
    # generation + inversion logic on a real downloaded print, and confirm
    # warp_with_params(side, target_params) actually reconstructs something
    # close to reference in the shared overlap region. This is the same
    # "verify numerically before trusting" step already run standalone in
    # this session on a synthetic test image (mean abs err 0.007-0.01) --
    # repeated here against a REAL print to catch anything the synthetic
    # image's simpler content might not have exposed.
    import glob
    paths = glob.glob('data/real_prints/*.png')
    if not paths:
        print('no real prints found under data/real_prints/ -- run the '
              'download step first')
    else:
        rng = random.Random(0)
        errs = []
        for p in paths[:8]:
            ref, side, target = make_pair(p, rng=rng, photometric_jitter=False)
            recon = warp_with_params(
                torch.from_numpy(side)[None, None],
                torch.from_numpy(target)[None],
            )[0, 0].numpy()
            m = _CROP // 4
            valid = slice(m, _CROP - m)
            err = float(np.abs(recon[valid, valid] - ref[valid, valid]).mean())
            errs.append(err)
            print(f'{p}: round-trip mean abs err (center region) = {err:.4f}')
        print(f'\nmean over {len(errs)} real prints: {np.mean(errs):.4f}')
