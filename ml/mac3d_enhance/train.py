"""Train the MAC3D ridge-restoration U-Net.

    python train.py --data /path/to/mac3d_dataset --epochs 120 --out runs/v1

Loss = L1 + (1 - SSIM): L1 keeps ridge intensities faithful, SSIM keeps ridge
STRUCTURE (the part NFIQ actually rewards). Validation reports SSIM against the
held-out clean targets; the real gate is backend NFIQ after ONNX export
(see README.md) — SSIM is only the training proxy.

Deliberately dependency-light (torch + opencv + numpy). No GPU is present in the
build container; run this where a GPU is (Colab / a VM) — it auto-selects CUDA.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from dataset import RidgeRestoreDataset, make_splits
from model import RidgeRestoreUNet


def _gaussian_window(ch: int, ks: int = 11, sigma: float = 1.5) -> torch.Tensor:
    coords = torch.arange(ks).float() - ks // 2
    g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
    g = (g / g.sum())
    w = (g[:, None] @ g[None, :])
    return w.expand(ch, 1, ks, ks).contiguous()


def ssim(x: torch.Tensor, y: torch.Tensor, win: torch.Tensor) -> torch.Tensor:
    ks = win.shape[-1]
    pad = ks // 2
    mux = F.conv2d(x, win, padding=pad, groups=x.shape[1])
    muy = F.conv2d(y, win, padding=pad, groups=x.shape[1])
    mux2, muy2, muxy = mux * mux, muy * muy, mux * muy
    sx = F.conv2d(x * x, win, padding=pad, groups=x.shape[1]) - mux2
    sy = F.conv2d(y * y, win, padding=pad, groups=x.shape[1]) - muy2
    sxy = F.conv2d(x * y, win, padding=pad, groups=x.shape[1]) - muxy
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    s = ((2 * muxy + c1) * (2 * sxy + c2)) / ((mux2 + muy2 + c1) * (sx + sy + c2))
    return s.mean()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', required=True)
    ap.add_argument('--out', default='runs/v1')
    ap.add_argument('--epochs', type=int, default=120)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--lr', type=float, default=2e-4)
    ap.add_argument('--size', type=int, default=512)
    args = ap.parse_args()

    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    tr_ids, va_ids = make_splits(args.data)
    print(f'train fingers={len(tr_ids)} val fingers={len(va_ids)}')
    tr = DataLoader(RidgeRestoreDataset(args.data, tr_ids, args.size, augment=True),
                    batch_size=args.batch, shuffle=True, num_workers=4, drop_last=True)
    va = DataLoader(RidgeRestoreDataset(args.data, va_ids, args.size, augment=False),
                    batch_size=args.batch, shuffle=False, num_workers=2)

    model = RidgeRestoreUNet().to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.epochs)
    win = _gaussian_window(1).to(dev)

    best_val = -1.0
    for ep in range(args.epochs):
        model.train()
        for x, y in tr:
            x, y = x.to(dev), y.to(dev)
            pred = model(x)
            loss = F.l1_loss(pred, y) + (1.0 - ssim(pred, y, win))
            opt.zero_grad(); loss.backward(); opt.step()
        sched.step()

        model.eval()
        vs, n = 0.0, 0
        with torch.no_grad():
            for x, y in va:
                x, y = x.to(dev), y.to(dev)
                vs += ssim(model(x), y, win).item() * x.shape[0]; n += x.shape[0]
        vssim = vs / max(n, 1)
        print(f'ep {ep:3d}  val_ssim={vssim:.4f}')
        if vssim > best_val:
            best_val = vssim
            torch.save({'model': model.state_dict(), 'val_ssim': vssim,
                        'epoch': ep}, out / 'best.pt')
    print(f'done. best val_ssim={best_val:.4f} -> {out/"best.pt"}')
    print('Export: python -c "from model import export_onnx; '
          f'export_onnx(\'{out}/best.pt\', \'ridge_restore_unet.onnx\')"')


if __name__ == '__main__':
    main()
