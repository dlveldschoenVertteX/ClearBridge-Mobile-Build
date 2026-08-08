"""Differentiable ridge-orientation-field similarity loss.

Copied (not imported) from ml/deform_correct/train.py's own
orientation_field/orientation_loss -- importing that module directly would
work in isolation, but ml/deform_correct/train.py itself does bare
`from dataset import ...` / `from model import ...` at its own top level,
and this project (mosaic_register) has its OWN dataset.py/model.py on
sys.path too. Point both directories' modules at Python's generic
'dataset'/'model'/'train' names and the second import silently resolves
against the FIRST module's already-cached sys.modules entry instead of this
package's own file -- confirmed as a real ImportError when tried directly
(`from dataset import MosaicPairDataset` resolved to deform_correct's
dataset.py, which has no such class). Duplicating this one well-isolated,
stable ~50-line function is a smaller, safer surface than fighting Python's
import system across two same-named-file directories -- if
ml/deform_correct's own orientation_field math ever changes, port the
change here deliberately, don't assume it stays in sync automatically.
"""
from __future__ import annotations

import torch
import torch.nn.functional as F

_ORIENT_BLOCK = 16
_ORIENT_SMOOTH = 5.0


def _sobel_kernels(device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
    kx = torch.tensor([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]],
                       dtype=torch.float32, device=device).view(1, 1, 3, 3)
    ky = torch.tensor([[-1, -2, -1], [0, 0, 0], [1, 2, 1]],
                       dtype=torch.float32, device=device).view(1, 1, 3, 3)
    return kx, ky


def _box_blur(x: torch.Tensor, k: int) -> torch.Tensor:
    pad = k // 2
    kernel = torch.ones(1, 1, k, k, device=x.device) / (k * k)
    return F.conv2d(x, kernel, padding=pad)


def _gaussian_blur(x: torch.Tensor, sigma: float) -> torch.Tensor:
    k = int(2 * round(3 * sigma) + 1)
    coords = torch.arange(k, device=x.device).float() - k // 2
    g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
    g = g / g.sum()
    kernel = (g[:, None] @ g[None, :]).view(1, 1, k, k)
    return F.conv2d(x, kernel, padding=k // 2)


def orientation_field(img: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    kx, ky = _sobel_kernels(img.device)
    gx = F.conv2d(img, kx, padding=1)
    gy = F.conv2d(img, ky, padding=1)
    vx = _box_blur(2 * gx * gy, _ORIENT_BLOCK)
    vy = _box_blur(gx * gx - gy * gy, _ORIENT_BLOCK)
    r = torch.sqrt(vx * vx + vy * vy + 1e-6)
    cs = _gaussian_blur(vy / r, _ORIENT_SMOOTH)
    sn = _gaussian_blur(vx / r, _ORIENT_SMOOTH)
    # Real bug found + fixed 2026-08-08 via torch.autograd.set_detect_anomaly:
    # the ORIGINAL ml/deform_correct/train.py version of this function has
    # `norm = torch.sqrt(cs**2 + sn**2) + 1e-6` -- epsilon added AFTER the
    # sqrt, which protects the FORWARD value from ever being exactly 0 but
    # does nothing for sqrt's own BACKWARD gradient (1/(2*sqrt(u))), which
    # genuinely explodes to NaN when its argument u=cs**2+sn**2 is exactly
    # 0. That happens whenever vx=vy=0 exactly over an entire box-filter
    # window -- a perfectly flat patch. deform_correct's own training data
    # is continuous-tone (real photos/scans), which in practice always has
    # some residual noise even in "flat" regions, so u is never exactly 0
    # there. This module's training data is BINARIZED (this project's own
    # production AFIS superprints, pure 0/255 bitmaps) -- large background
    # regions are EXACTLY uniform, hitting the exact-zero case for real,
    # confirmed via anomaly detection on a real downloaded print (39/100
    # random synthetic-pair draws produced NaN gradients before this fix).
    # Same fix pattern as the `r` computation one line above: epsilon INSIDE
    # the sqrt, so its argument can never be exactly 0.
    norm = torch.sqrt(cs ** 2 + sn ** 2 + 1e-6)
    cs = torch.nan_to_num(cs / norm)
    sn = torch.nan_to_num(sn / norm)
    return cs, sn


def orientation_loss(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """1 - mean cosine similarity between two images' orientation fields,
    over pixels where both carry real ridge orientation. See
    ml/deform_correct/train.py's own orientation_loss docstring for the
    full reasoning (modality-invariant structural signal, mod-pi doubled-
    angle comparison, masking out featureless regions)."""
    ca, sa = orientation_field(a)
    cb, sb = orientation_field(b)
    valid = ((ca * ca + sa * sa > 0.25) & (cb * cb + sb * sb > 0.25)).float()
    cos_sim = ca * cb + sa * sb
    denom = valid.sum().clamp_min(1.0)
    return 1.0 - (cos_sim * valid).sum() / denom
