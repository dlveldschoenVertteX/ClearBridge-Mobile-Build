"""Ridge-restoration U-Net for the curriculum-degradation training line
(CTO idea, 2026-08-08: train a network to reconstruct clean ridges from
increasingly-degraded real prints).

Architecture copied (not imported) from ml/mac3d_enhance/model.py's
RidgeRestoreUNet -- same reasoning as ml/mosaic_register/orient_loss.py's
own copy-not-import decision tonight: this project has THREE ml/ subfolders
that each define their own dataset.py/model.py/train.py, and Python's
import system resolves bare `import model`/`import dataset` against
whichever such file is EARLIEST on sys.path, not the one actually intended,
once more than one is on the path at once (confirmed as a real bug earlier
tonight in ml/mosaic_register). Keeping each ml/ project's own copy self-
contained avoids that whole class of bug.

One real, deliberate change from mac3d_enhance's original: BatchNorm2d ->
GroupNorm. Real bug found and fixed in ml/mosaic_register earlier tonight,
same day: BatchNorm2d's backward pass produces NaN when a batch/channel's
within-batch variance is near-zero, which real degraded-print training
data hits routinely (large uniform background/margin regions in real SD302
scans, or a heavily-blurred crop that's gone nearly flat). Applying that
fix here preemptively rather than waiting to rediscover the same bug --
mac3d_enhance's own original BatchNorm2d version has never actually been
stress-tested against this failure mode, it just hasn't been hit yet.
"""
from __future__ import annotations

import torch
import torch.nn as nn


def _block(cin: int, cout: int) -> nn.Sequential:
    return nn.Sequential(
        nn.Conv2d(cin, cout, 3, padding=1, bias=False),
        nn.GroupNorm(min(8, cout), cout),
        nn.ReLU(inplace=True),
        nn.Conv2d(cout, cout, 3, padding=1, bias=False),
        nn.GroupNorm(min(8, cout), cout),
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
    """Same I/O contract as ml/mac3d_enhance/model.py's own export (input
    'input', 1x1xHxW float [0,1]; output 'restored') so this drops into the
    same ONNX-loading pattern afis_print.py already uses for the other
    small models (thumb_seg_unet.onnx, nfiq_resnet18.onnx) with minimal new
    plumbing, IF this is ever validated well enough to wire in."""
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
