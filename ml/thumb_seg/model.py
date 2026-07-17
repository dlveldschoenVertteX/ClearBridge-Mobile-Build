"""Small U-Net for thumb/pad binary segmentation.

Matches the exact I/O contract `sfm_pipeline._segment_via_ml_model` expects
from the bundled ONNX model, so a retrained checkpoint is a drop-in
replacement:
  - input:  (1, 1, 256, 256) float32, grayscale normalized to [0, 1], named 'input'
  - output: (1, 1, 256, 256) float32 raw logits (sigmoid applied by the
            caller), named 'logits'
"""
from __future__ import annotations

import torch
import torch.nn as nn


def _block(cin: int, cout: int) -> nn.Sequential:
    return nn.Sequential(
        nn.Conv2d(cin, cout, 3, padding=1), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
        nn.Conv2d(cout, cout, 3, padding=1), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
    )


class ThumbSegUNet(nn.Module):
    """~1.9M params -- same class as the original bootstrap model, matching
    its documented size so downstream latency/footprint doesn't regress."""

    def __init__(self, base: int = 16):
        super().__init__()
        self.enc1 = _block(1, base)
        self.enc2 = _block(base, base * 2)
        self.enc3 = _block(base * 2, base * 4)
        self.enc4 = _block(base * 4, base * 8)
        self.pool = nn.MaxPool2d(2)

        self.bottleneck = _block(base * 8, base * 16)

        self.up4 = nn.ConvTranspose2d(base * 16, base * 8, 2, stride=2)
        self.dec4 = _block(base * 16, base * 8)
        self.up3 = nn.ConvTranspose2d(base * 8, base * 4, 2, stride=2)
        self.dec3 = _block(base * 8, base * 4)
        self.up2 = nn.ConvTranspose2d(base * 4, base * 2, 2, stride=2)
        self.dec2 = _block(base * 4, base * 2)
        self.up1 = nn.ConvTranspose2d(base * 2, base, 2, stride=2)
        self.dec1 = _block(base * 2, base)

        self.head = nn.Conv2d(base, 1, 1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        e1 = self.enc1(x)
        e2 = self.enc2(self.pool(e1))
        e3 = self.enc3(self.pool(e2))
        e4 = self.enc4(self.pool(e3))
        b = self.bottleneck(self.pool(e4))

        d4 = self.dec4(torch.cat([self.up4(b), e4], dim=1))
        d3 = self.dec3(torch.cat([self.up3(d4), e3], dim=1))
        d2 = self.dec2(torch.cat([self.up2(d3), e2], dim=1))
        d1 = self.dec1(torch.cat([self.up1(d2), e1], dim=1))
        return self.head(d1)


def export_onnx(ckpt_path: str, onnx_path: str, size: int = 256) -> None:
    model = ThumbSegUNet()
    state = torch.load(ckpt_path, map_location='cpu')
    model.load_state_dict(state['model'] if 'model' in state else state)
    model.eval()
    dummy = torch.zeros(1, 1, size, size)
    torch.onnx.export(
        model, dummy, onnx_path,
        input_names=['input'], output_names=['logits'],
        dynamic_axes=None, opset_version=17,
    )


if __name__ == '__main__':
    m = ThumbSegUNet()
    n_params = sum(p.numel() for p in m.parameters())
    print(f'params: {n_params:,}')
    x = torch.zeros(2, 1, 256, 256)
    y = m(x)
    print('output shape:', tuple(y.shape))
    assert y.shape == (2, 1, 256, 256)
    print('OK')
