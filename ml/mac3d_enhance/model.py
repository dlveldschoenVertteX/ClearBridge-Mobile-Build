"""Compact U-Net for MAC3D ridge restoration (soft phone-macro -> clean ridges).

Deliberately small (~1.9M params at base=32): it runs CPU-only in the
processEnhanceAndScore Cloud Function via ONNX Runtime alongside the existing
segmentation U-Net and NFIQ ResNet, and a bigger net would blow the function's
cold-start/latency budget for a marginal quality gain on 500x500-scored output.

Single-channel in/out, sigmoid head (target is a normalised ridge image in
[0,1]). Export to ONNX with export_onnx() and drop it in Storage models/ the
same way thumb_seg_unet.onnx is loaded (see afis_print._unet_mask /
sfm_pipeline._get_thumb_seg_session).
"""
from __future__ import annotations

import torch
import torch.nn as nn


def _block(cin: int, cout: int) -> nn.Sequential:
    return nn.Sequential(
        nn.Conv2d(cin, cout, 3, padding=1, bias=False),
        nn.BatchNorm2d(cout),
        nn.ReLU(inplace=True),
        nn.Conv2d(cout, cout, 3, padding=1, bias=False),
        nn.BatchNorm2d(cout),
        nn.ReLU(inplace=True),
    )


class RidgeRestoreUNet(nn.Module):
    def __init__(self, base: int = 32):
        super().__init__()
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
        self.head = nn.Conv2d(base, 1, 1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        c1 = self.d1(x)
        c2 = self.d2(self.pool(c1))
        c3 = self.d3(self.pool(c2))
        b = self.bott(self.pool(c3))
        x = self.u3(torch.cat([self.up3(b), c3], 1))
        x = self.u2(torch.cat([self.up2(x), c2], 1))
        x = self.u1(torch.cat([self.up1(x), c1], 1))
        return torch.sigmoid(self.head(x))


def export_onnx(ckpt_path: str, onnx_path: str, size: int = 512) -> None:
    """Export a trained checkpoint to ONNX matching the backend's I/O contract:
    input name 'input' (1x1xHxW float in [0,1]), output name 'restored'."""
    model = RidgeRestoreUNet()
    model.load_state_dict(torch.load(ckpt_path, map_location='cpu')['model'])
    model.eval()
    dummy = torch.zeros(1, 1, size, size)
    torch.onnx.export(
        model, dummy, onnx_path,
        input_names=['input'], output_names=['restored'],
        dynamic_axes={'input': {2: 'h', 3: 'w'}, 'restored': {2: 'h', 3: 'w'}},
        opset_version=17,
    )
    print(f'exported {onnx_path}')
