"""Learned scale-normalization network -- narrower alternative to
`ml/deform_correct`'s full elastic deformation field, per the C2CL finding
(Grosz/Engelsma/Jain, TIFS 2021) that fixed/ridge-frequency-based resampling
is unreliable on contactless fingerprint captures, and per this project's
own real matchability sweep (2026-08-19) confirming the opposite of NFIQ2's
"closer is bad" assumption: real matches cluster at high native wavelength
(captured close), which the current pipeline can only partially correct
because `_FREQ_SCALE_MIN` caps how aggressively it will resample.

Unlike `deform_correct`'s per-pixel DeformFieldUNet, this predicts a single
SCALAR scale-correction factor -- a much more constrained, more tractable
regression target than a full deformation field. Real, deliberate scope cut:
this net does NOT attempt to correct perspective/elastic distortion, only
the pixel-domain scale mismatch that NFIQ2/Gabor-enhancement calibration
assumes (~9px ridge period). If this proves out, the residual elastic
correction is still `deform_correct`'s job, unchanged.

GroupNorm, not BatchNorm2d -- same preemptive lesson `ml/mac3d_enhance` and
`ml/ridge_restore_curriculum` already applied this project after a real
BatchNorm2d NaN-gradient failure on near-zero-variance batches (see
CLAUDE.md, 2026-08-08 "Two new ML lines tried" entry).
"""
from __future__ import annotations

import torch
import torch.nn as nn


def _conv_block(in_ch: int, out_ch: int, stride: int = 2, groups: int = 8) -> nn.Sequential:
    return nn.Sequential(
        nn.Conv2d(in_ch, out_ch, kernel_size=3, stride=stride, padding=1, bias=False),
        nn.GroupNorm(min(groups, out_ch), out_ch),
        nn.ReLU(inplace=True),
    )


class ScaleRegressorNet(nn.Module):
    """Grayscale image in (1, H, W) -> single scalar: predicted log-scale
    correction factor. Small by design (5 conv blocks + global average pool
    + 2-layer head) -- this is a much narrower regression target than a
    per-pixel field, so a small model is a deliberate, testable hypothesis,
    not an oversight. ~280K params.
    """

    def __init__(self) -> None:
        super().__init__()
        self.stem = _conv_block(1, 16, stride=2, groups=4)     # /2
        self.b1 = _conv_block(16, 32, stride=2)                 # /4
        self.b2 = _conv_block(32, 64, stride=2)                 # /8
        self.b3 = _conv_block(64, 96, stride=2)                 # /16
        self.b4 = _conv_block(96, 128, stride=2)                # /32
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.head = nn.Sequential(
            nn.Linear(128, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.stem(x)
        x = self.b1(x)
        x = self.b2(x)
        x = self.b3(x)
        x = self.b4(x)
        x = self.pool(x).flatten(1)
        return self.head(x).squeeze(-1)
