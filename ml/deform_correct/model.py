"""Learned deformation-correction network for contactless->contact fingerprint
geometry (the C2CL-style piece docs/FIDELITY_WALL_SCOPE.md identifies as the
missing root-cause fix, and geom_correct.py's elastic_flatten() currently
stubs as a parametric placeholder waiting for exactly this).

CRITICAL design constraint, different from a generic image-registration setup
(e.g. VoxelMorph's usual moving+fixed-image-pair input): in PRODUCTION, only
the contactless PROBE image exists at inference time -- there is no live
paired contact scan to register against. So this network takes ONLY the
probe image as input and predicts a dense flow field toward an IMPLICIT
canonical (contact-print-like) geometry, learned from real (probe, gallery)
PAIRS at training time only. The gallery image is used exclusively in the
training LOSS (see train.py), never fed to the network -- this makes the
exported model's signature match geom_correct.elastic_flatten()'s existing
single-image contract exactly, so it drops in as a straight replacement for
the current identity placeholder once trained.

Architecture mirrors ml/mac3d_enhance/model.py's RidgeRestoreUNet (same
encoder/decoder block style, same base=32 size) for consistency and to keep
this CPU-inference-friendly for the same reason that model is small: it must
run inside processEnhanceAndScore's latency budget via ONNX Runtime alongside
the segmentation U-Net and NFIQ proxy. Only the head differs: 2-channel flow
output (dx, dy) instead of a 1-channel restored image, and no final
activation (a flow field is unbounded, not a normalised image).
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


def _block(cin: int, cout: int) -> nn.Sequential:
    return nn.Sequential(
        nn.Conv2d(cin, cout, 3, padding=1, bias=False),
        nn.BatchNorm2d(cout),
        nn.ReLU(inplace=True),
        nn.Conv2d(cout, cout, 3, padding=1, bias=False),
        nn.BatchNorm2d(cout),
        nn.ReLU(inplace=True),
    )


class DeformFieldUNet(nn.Module):
    """Single-image (1-channel) in, 2-channel dense flow field out. Flow is in
    NORMALISED grid_sample units (roughly [-0.2, 0.2] after the tanh+scale
    head below) -- deliberately bounded to a small range: this is meant to
    undo a mild geometric mismatch (cylinder foreshortening + elastic spread),
    not perform general-purpose deformable registration, so an unconstrained
    flow head risks learning a degenerate, ridge-destroying warp instead of
    the intended correction. `max_disp` caps the maximum displacement as a
    fraction of image size; tune only with real validation evidence (the
    SourceAFIS-based matchability ROC, per docs/FIDELITY_WALL_SCOPE.md
    discipline -- never on training loss alone)."""

    def __init__(self, base: int = 32, max_disp: float = 0.12):
        super().__init__()
        self.max_disp = max_disp
        self.d1 = _block(1, base)
        self.d2 = _block(base, base * 2)
        self.d3 = _block(base * 2, base * 4)
        self.bott = _block(base * 4, base * 8)
        self.pool = nn.MaxPool2d(2)
        self.up3 = nn.ConvTranspose2d(base * 8, base * 4, 2, stride=2)
        self.u3 = _block(base * 8, base * 4)
        self.up2 = nn.ConvTranspose2d(base * 4, base * 2, 2, stride=2)
        self.u2 = _block(base * 4, base * 2)
        self.up1 = nn.ConvTranspose2d(base * 2, base, 2, stride=2)
        self.u1 = _block(base * 2, base)
        self.head = nn.Conv2d(base, 2, 1)
        # Zero-init the flow head so training starts at the identity warp
        # (no distortion) rather than a random one -- standard practice for
        # registration nets, and matches this project's own "can only ever
        # add, never regress" discipline: an undertrained/early checkpoint
        # degrades gracefully toward doing nothing instead of scrambling
        # ridges immediately.
        nn.init.zeros_(self.head.weight)
        nn.init.zeros_(self.head.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        c1 = self.d1(x)
        c2 = self.d2(self.pool(c1))
        c3 = self.d3(self.pool(c2))
        b = self.bott(self.pool(c3))
        u = self.u3(torch.cat([self.up3(b), c3], 1))
        u = self.u2(torch.cat([self.up2(u), c2], 1))
        u = self.u1(torch.cat([self.up1(u), c1], 1))
        flow = torch.tanh(self.head(u)) * self.max_disp
        return flow   # (B, 2, H, W), channel order (dx, dy) in [-max_disp, max_disp]


class SpatialTransformer(nn.Module):
    """Warps an image by a dense flow field via bilinear grid_sample -- the
    standard differentiable-registration primitive (the same core operation
    VoxelMorph uses), reimplemented directly on PyTorch's built-in grid_sample
    rather than pulling in a registration-library dependency: it's a ~15-line
    op, and keeping this native avoids mixing frameworks (this project
    already isolates a Keras/TF dependency, pyfing, into its own sidecar
    specifically to keep the ONNX/PyTorch inference path clean -- see
    pyfing_client.py's docstring)."""

    def __init__(self):
        super().__init__()
        self._grid_cache: dict[tuple[int, int, str], torch.Tensor] = {}

    def _base_grid(self, h: int, w: int, device: torch.device) -> torch.Tensor:
        key = (h, w, str(device))
        if key not in self._grid_cache:
            ys, xs = torch.meshgrid(
                torch.linspace(-1, 1, h, device=device),
                torch.linspace(-1, 1, w, device=device),
                indexing='ij',
            )
            self._grid_cache[key] = torch.stack([xs, ys], dim=-1)   # (H, W, 2)
        return self._grid_cache[key]

    def forward(self, img: torch.Tensor, flow: torch.Tensor) -> torch.Tensor:
        b, _, h, w = img.shape
        base = self._base_grid(h, w, img.device).unsqueeze(0).expand(b, -1, -1, -1)
        # flow is (B, 2, H, W) as (dx, dy); grid_sample wants (B, H, W, 2).
        sample_grid = base + flow.permute(0, 2, 3, 1)
        return F.grid_sample(img, sample_grid, mode='bilinear',
                             padding_mode='border', align_corners=True)


def export_onnx(ckpt_path: str, onnx_path: str, size: int = 512) -> None:
    """Export a trained checkpoint to ONNX. Matches the SAME I/O convention
    as ml/mac3d_enhance/model.py's export (input name 'input', 1x1xHxW float
    in [0,1]) so it drops into afis_print.py's existing ONNX-loading pattern
    (see _get_thumb_seg_session/_unet_mask) with minimal new plumbing.
    Exports ONLY the flow-predicting network -- the warp itself
    (SpatialTransformer) is trivial enough to reimplement directly in numpy/
    cv2.remap inside geom_correct.py (consistent with that module's existing
    style), so the ONNX graph doesn't need to include grid_sample."""
    model = DeformFieldUNet()
    model.load_state_dict(torch.load(ckpt_path, map_location='cpu')['model'])
    model.eval()
    dummy = torch.zeros(1, 1, size, size)
    torch.onnx.export(
        model, dummy, onnx_path,
        input_names=['input'], output_names=['flow'],
        dynamic_axes={'input': {2: 'h', 3: 'w'}, 'flow': {2: 'h', 3: 'w'}},
        opset_version=17,
    )
    print(f'exported {onnx_path}')
