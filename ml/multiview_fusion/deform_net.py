"""PairDeformFieldUNet -- Phase 2's learned per-pair registration net.

Same architectural family as ml/deform_correct/model.py's DeformFieldUNet
(U-Net encoder/decoder, zero-init flow head so an undertrained checkpoint
degrades gracefully to identity), with two deliberate contract changes:

1. **2-channel input** (front anchor stacked with the ECC-registered side).
   Unlike the deform_correct production constraint (only the probe exists at
   inference), BOTH images exist live here -- the multi-view pipeline always
   has the front and each registered side in hand -- so this is a standard
   pair-registration setup (VoxelMorph-style), a strictly easier learning
   problem than predicting flow toward an implicit canonical geometry.

2. **Flow in PIXELS, not normalized grid units.** The net trains on small
   random crops (preserving native ridge scale) and runs fully-
   convolutionally on full frames. A normalized-unit flow of 0.01 means
   1.3px on a 256 crop but 4.6px on a 912 frame -- the same physical-scale
   trap that invalidated the first deform-correct v2 evaluation (CLAUDE.md
   2026-07-18, "naive resize" round). PixelWarp converts px -> grid units
   per-image-size at warp time, so a trained checkpoint means the same
   physical displacement at every resolution.

Head cap: tanh * max_disp_px (default 24px) -- generous over the synthetic
family's ~12px worst case and the 5-20px residuals the failed classical
attempts suggested, but still bounded so a bad checkpoint cannot scramble
ridges wholesale (same "can only ever degrade toward identity" discipline).

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
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


class PairDeformFieldUNet(nn.Module):
    """(B, 2, H, W) in -- channel 0 = front anchor, channel 1 = ECC-registered
    side, both float in [0,1] -- and (B, 2, H, W) flow out in PIXELS,
    channel order (dx, dy): warping the side by this flow (PixelWarp) should
    reproduce the front's geometry."""

    def __init__(self, base: int = 24, max_disp_px: float = 24.0):
        super().__init__()
        self.max_disp_px = max_disp_px
        self.d1 = _block(2, base)
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
        return torch.tanh(self.head(u)) * self.max_disp_px   # (B,2,H,W) px


class PixelWarp(nn.Module):
    """grid_sample warp driven by a PIXEL-unit flow: out(p) = img(p + flow(p)).
    Converts px offsets to normalized grid units per image size at call time,
    which is what makes train-at-256/infer-at-912 physically consistent."""

    def forward(self, img: torch.Tensor, flow_px: torch.Tensor) -> torch.Tensor:
        b, _, h, w = img.shape
        device = img.device
        ys, xs = torch.meshgrid(
            torch.linspace(-1, 1, h, device=device),
            torch.linspace(-1, 1, w, device=device),
            indexing='ij')
        base = torch.stack([xs, ys], dim=-1).unsqueeze(0).expand(b, -1, -1, -1)
        # px -> normalized: dx_norm = 2*dx_px/(W-1), dy_norm = 2*dy_px/(H-1)
        fx = flow_px[:, 0] * (2.0 / max(w - 1, 1))
        fy = flow_px[:, 1] * (2.0 / max(h - 1, 1))
        grid = base + torch.stack([fx, fy], dim=-1)
        return F.grid_sample(img, grid, mode='bilinear',
                             padding_mode='border', align_corners=True)


def export_onnx(ckpt_path: str, onnx_path: str, size: int = 512) -> None:
    """Flow-net-only export, same convention as ml/deform_correct/model.py's:
    the warp itself is a trivial cv2.remap in numpy at consumption time."""
    model = PairDeformFieldUNet()
    model.load_state_dict(torch.load(ckpt_path, map_location='cpu')['model'])
    model.eval()
    dummy = torch.zeros(1, 2, size, size)
    torch.onnx.export(
        model, dummy, onnx_path,
        input_names=['pair'], output_names=['flow_px'],
        dynamic_axes={'pair': {2: 'h', 3: 'w'}, 'flow_px': {2: 'h', 3: 'w'}},
        opset_version=17,
    )
    print(f'exported {onnx_path}')
