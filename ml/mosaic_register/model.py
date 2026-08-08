"""Two-crop rigid-registration network for stitching slightly-tilted views
of the same fingerprint pad into one superprint (CTO idea, 2026-08-08:
binarize each angled print, then register by finding where the ridge
PATTERNS link up, using the front capture as ground truth).

Deliberately NOT a dense flow-field network like ml/deform_correct's
DeformFieldUNet. That codebase's own dataset.py docstring documents the real
reason a bounded small-magnitude dense flow field is the wrong shape for
this: DeformPairDataset pre-aligns its pairs globally (rotation+scale+
translation) BEFORE ever training the flow net, specifically because "a full
rotation the net's small displacement budget could never undo" caused a real
training plateau when that pre-alignment was missing -- a dense flow field
can only fix small LOCAL residual deformation, not a large GLOBAL pose
difference (per-pixel displacement from a rotation grows with distance from
the rotation centre, which quickly exceeds any sane max_disp bound near the
image edges). This network's whole job IS the global alignment step -- there
is no upstream pre-alignment to lean on here -- so it regresses the rigid
transform PARAMETERS directly (rotation as a unit vector, translation in
normalised grid_sample units) instead of a dense field. Since the training
pair is synthetically constructed (see synth_pair.py), the exact ground-
truth transform is always known, making direct parameter regression a much
stronger, more stable supervised signal than the indirect photometric/
orientation-field loss deform_correct had to rely on for its own (genuinely
unknown-ground-truth) task.

A residual dense-flow refinement stage on top of this rigid alignment (the
same "global align -> residual deform" order deform_correct's own dataset
already validates) is a natural v2 extension once this baseline is proven,
not built here.
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


def _block(cin: int, cout: int, stride: int = 2) -> nn.Sequential:
    # GroupNorm, not BatchNorm2d: real bug found via this module's own local
    # smoke test (2026-08-08) -- a real downloaded print's crop landed ~50%
    # pure-white background (a large, exactly-uniform region is a realistic,
    # not edge-case, input here -- production crops routinely have real
    # background/margin). With a small batch (or batch=1 during debugging),
    # BatchNorm2d occasionally hits a channel with ~zero within-batch
    # variance for that specific input, and its backward pass produces NaN
    # gradients that poison every upstream parameter via the chain rule
    # (confirmed directly: isolating orientation_loss's own backward on the
    # same input was fully finite; the NaN only appeared once the encoder's
    # BatchNorm layers were in the graph). GroupNorm computes statistics
    # per-sample (never across the batch), sidestepping this exact failure
    # class -- the standard fix for small-batch/degenerate-input training.
    return nn.Sequential(
        nn.Conv2d(cin, cout, 3, stride=stride, padding=1, bias=False),
        nn.GroupNorm(min(8, cout), cout),
        nn.ReLU(inplace=True),
    )


class TwoCropRegistrationNet(nn.Module):
    """2-channel input (reference crop, side crop), both in [0, 1].
    Outputs a (B, 4) tensor: (cos_theta, sin_theta, tx, ty) describing the
    rigid transform that warps the SIDE crop onto the REFERENCE crop's
    frame, in the same normalised [-1, 1] grid_sample convention
    `build_theta`/`F.affine_grid` use (NOT pixel units) -- tx/ty of 1.0 is a
    full image-width/height shift.

    Zero/identity-biased init (see __init__) so an undertrained checkpoint
    predicts "no transform" rather than a random scramble -- same "degrade
    gracefully toward doing nothing" discipline as DeformFieldUNet's own
    zero-init head."""

    def __init__(self, base: int = 24):
        super().__init__()
        self.enc = nn.Sequential(
            _block(2, base),           # /2
            _block(base, base * 2),    # /4
            _block(base * 2, base * 4),   # /8
            _block(base * 4, base * 8),   # /16
            _block(base * 8, base * 8),   # /32
        )
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.head = nn.Sequential(
            nn.Linear(base * 8, base * 4),
            nn.ReLU(inplace=True),
            nn.Linear(base * 4, 4),   # cos, sin, tx, ty
        )
        # Bias the head to start near identity (cos=1, sin=0, tx=0, ty=0) --
        # zero-init the last layer's weight so output = bias alone at init,
        # then set that bias directly to the identity transform.
        nn.init.zeros_(self.head[-1].weight)
        with torch.no_grad():
            self.head[-1].bias.copy_(torch.tensor([1.0, 0.0, 0.0, 0.0]))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        f = self.enc(x)
        f = self.pool(f).flatten(1)
        return self.head(f)   # (B, 4)


def build_theta(params: torch.Tensor) -> torch.Tensor:
    """(B, 4) (cos, sin, tx, ty) -> (B, 2, 3) affine theta matrix for
    F.affine_grid, with the rotation part re-normalised to a true unit
    circle (the network's raw cos/sin outputs aren't constrained to lie on
    it, and an unnormalised "rotation" would also scale the image, which is
    never physically correct for this task -- two views of the same rigid
    pad differ by pose, not by ridge-spacing scale)."""
    cos_t, sin_t, tx, ty = params.unbind(-1)
    norm = torch.sqrt(cos_t * cos_t + sin_t * sin_t + 1e-6)
    cos_n, sin_n = cos_t / norm, sin_t / norm
    zeros = torch.zeros_like(cos_n)
    row0 = torch.stack([cos_n, -sin_n, tx], dim=-1)
    row1 = torch.stack([sin_n, cos_n, ty], dim=-1)
    return torch.stack([row0, row1], dim=1)


def invert_params(params: torch.Tensor) -> torch.Tensor:
    """Rigid-transform inverse in the (cos, sin, tx, ty) parameterisation --
    used by synth_pair.py to derive the network's training TARGET from the
    transform it actually used to build the synthetic side crop (see that
    module's docstring for the full derivation of why the target is the
    inverse, not the forward, transform, given affine_grid's pull-sampling
    convention). For an orthonormal rotation, the inverse rotation is the
    transpose; the inverse translation is -R^T @ t."""
    c, s, tx, ty = params.unbind(-1)
    inv_c, inv_s = c, -s
    inv_tx = -(c * tx + s * ty)
    inv_ty = (s * tx - c * ty)
    return torch.stack([inv_c, inv_s, inv_tx, inv_ty], dim=-1)


def warp_with_params(img: torch.Tensor, params: torch.Tensor) -> torch.Tensor:
    """Applies the rigid transform described by `params` (see build_theta)
    to `img` via the standard differentiable affine-sampling primitive."""
    theta = build_theta(params)
    grid = F.affine_grid(theta, img.shape, align_corners=True)
    return F.grid_sample(img, grid, mode='bilinear', padding_mode='border',
                         align_corners=True)


def export_onnx(ckpt_path: str, onnx_path: str, size: int = 384) -> None:
    """Export a trained checkpoint to ONNX. Input: (1, 2, size, size) float
    in [0,1] (reference and side crop stacked on the channel axis, both
    already binarized/normalised the same way afis_print.py's own pipeline
    prepares its candidates). Output: (1, 4) transform params -- the caller
    (afis_print.py, if/when this is wired in) applies warp_with_params'
    same math directly in numpy/cv2 (a 2x3 affine + cv2.warpAffine), so the
    ONNX graph doesn't need to include the grid_sample warp itself, same
    pattern as ml/deform_correct/model.py's own export."""
    model = TwoCropRegistrationNet()
    model.load_state_dict(torch.load(ckpt_path, map_location='cpu')['model'])
    model.eval()
    dummy = torch.zeros(1, 2, size, size)
    torch.onnx.export(
        model, dummy, onnx_path,
        input_names=['input'], output_names=['params'],
        dynamic_axes={'input': {2: 'h', 3: 'w'}},
        opset_version=17,
    )
    print(f'exported {onnx_path}')
