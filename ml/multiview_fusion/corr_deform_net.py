"""CorrPairDeformNet -- a correlation-layer flow net, the architectural fix
for the generalization failure the plain PairDeformFieldUNet (deform_net.py)
hit on this task.

Diagnosis that motivates this (2026-07-22, see README.md Phase 2): the plain
2-channel U-Net OVERFITS a fixed batch cleanly (EPE 8.5->1.2 jitter-off,
9.6->1.6 jitter-on) but its TRAIN loss stays stuck at the identity baseline
on fresh random samples every batch -- it can memorize dense flow but cannot
learn it as a GENERALIZABLE function. That's the textbook FlowNet vs
FlowNetC lesson: stacking two images and regressing dense flow through a
plain encoder-decoder lacks the inductive bias to match structure it hasn't
seen; an explicit CORRELATION (cost-volume) layer -- which computes, per
pixel, the similarity of a front patch to shifted side patches -- gives the
network the matching primitive directly, so it generalizes.

Design kept deliberately small and CPU-trainable (this project's standing
discipline -- prove descent locally before any paid GPU run):
- Shared shallow feature encoder on each image (front, side) at 1/4 res.
- A local correlation volume over a bounded displacement window (max_disp
  at 1/4 res -> covers the real residual range at full res), the FlowNetC
  primitive, but windowed (not global) since after ECC the residual is
  small -- keeps the cost volume tiny.
- A small decoder from [front features + correlation volume] -> flow at
  1/4 res -> bilinear upsample x4 to full-res PIXEL flow (scaled by 4).
- Zero-init flow head (graceful identity, same discipline as before).

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


def _conv(cin, cout, k=3, s=1):
    return nn.Sequential(
        nn.Conv2d(cin, cout, k, stride=s, padding=k // 2, bias=False),
        nn.BatchNorm2d(cout),
        nn.LeakyReLU(0.1, inplace=True),
    )


def local_correlation(fa: torch.Tensor, fb: torch.Tensor, max_disp: int) -> torch.Tensor:
    """Per-pixel correlation of fa against fb shifted over a
    (2*max_disp+1)^2 window. Returns (B, (2d+1)^2, H, W). fb is padded so
    every shift is defined. Normalised by channel count so the scale is
    stable across feature widths."""
    b, c, h, w = fa.shape
    fb_pad = F.pad(fb, (max_disp, max_disp, max_disp, max_disp))
    cost = []
    for dy in range(2 * max_disp + 1):
        for dx in range(2 * max_disp + 1):
            fb_shift = fb_pad[:, :, dy:dy + h, dx:dx + w]
            cost.append((fa * fb_shift).mean(dim=1, keepdim=True))
    return torch.cat(cost, dim=1)   # (B, (2d+1)^2, H, W)


class CorrPairDeformNet(nn.Module):
    """(B,2,H,W) in (front, ECC-registered side, [0,1]) -> (B,2,H,W) PIXEL
    flow warping side toward front. Correlation computed at 1/4 res over a
    +/-max_disp_q window (in 1/4-res px); flow upsampled x4 to full res."""

    def __init__(self, base: int = 24, max_disp_q: int = 6, max_disp_px: float = 28.0):
        super().__init__()
        self.max_disp_q = max_disp_q
        self.max_disp_px = max_disp_px
        # Shared encoder to 1/4 resolution.
        self.enc = nn.Sequential(
            _conv(1, base, s=1),
            _conv(base, base, s=2),        # 1/2
            _conv(base, base * 2, s=1),
            _conv(base * 2, base * 2, s=2),  # 1/4
        )
        corr_ch = (2 * max_disp_q + 1) ** 2
        self.dec = nn.Sequential(
            _conv(corr_ch + base * 2, base * 4),
            _conv(base * 4, base * 4),
            _conv(base * 4, base * 2),
            _conv(base * 2, base),
        )
        self.head = nn.Conv2d(base, 2, 1)
        nn.init.zeros_(self.head.weight)
        nn.init.zeros_(self.head.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        b, _, h, w = x.shape
        front = x[:, 0:1]
        side = x[:, 1:2]
        fa = self.enc(front)
        fb = self.enc(side)
        corr = local_correlation(fa, fb, self.max_disp_q)
        dec = self.dec(torch.cat([corr, fa], dim=1))
        flow_q = torch.tanh(self.head(dec)) * self.max_disp_px   # 1/4-res, px units
        # Upsample flow to full res. Displacement magnitude in PIXELS is scale-
        # invariant to the grid it lives on (a shift of N full-res px is N px
        # whether stored on a 1/4 or full grid), so NO x4 magnitude scaling --
        # only spatial upsampling of where each vector applies. (Contrast a
        # normalized-unit flow, which WOULD need rescaling -- avoided here for
        # exactly the scale-trap reason deform_net documents.)
        flow = F.interpolate(flow_q, size=(h, w), mode='bilinear', align_corners=True)
        return flow


def export_onnx(ckpt_path: str, onnx_path: str, size: int = 512) -> None:
    model = CorrPairDeformNet()
    model.load_state_dict(torch.load(ckpt_path, map_location='cpu')['model'])
    model.eval()
    dummy = torch.zeros(1, 2, size, size)
    torch.onnx.export(
        model, dummy, onnx_path,
        input_names=['pair'], output_names=['flow_px'],
        dynamic_axes={'pair': {2: 'h', 3: 'w'}, 'flow_px': {2: 'h', 3: 'w'}},
        opset_version=17)
    print(f'exported {onnx_path}')
