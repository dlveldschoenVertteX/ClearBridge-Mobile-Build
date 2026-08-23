"""Train the curriculum-degradation ridge restoration network.

    python train.py --data-root data/sd302d --epochs 150 --out runs/v1

Curriculum schedule: severity_cap ramps linearly from --severity-start to
--severity-end over the first --curriculum-epochs epochs, then holds at
--severity-end for the remainder -- the actual "increments" from the CTO's
original idea, implemented as a widening random-sampling range rather than
a small fixed set of discrete degradation levels (see degrade.py's
docstring for why: avoids the network memorizing a handful of exact
settings instead of generalizing across severity).

Loss: L1 (primary reconstruction signal -- input degraded and target clean
are the SAME pixel grid, so a direct per-pixel loss is a strong, reliable
signal here, unlike ml/deform_correct's cross-modality problem or
ml/mosaic_register's cross-image-registration problem tonight) + a
smaller-weight SSIM term (local contrast/structure) + a smaller-weight
orientation-field term (reused from ml/mosaic_register's own fixed
implementation) specifically rewarding RIDGE STRUCTURE fidelity, not just
any pixel match -- the actual downstream-relevant property, not a proxy
for it.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from dataset import CurriculumRestoreDataset, make_splits
from model import RidgeRestoreUNet
from orient_loss import orientation_loss


def _gaussian_window(ks: int = 11, sigma: float = 1.5) -> torch.Tensor:
    coords = torch.arange(ks).float() - ks // 2
    g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
    g = g / g.sum()
    return (g[:, None] @ g[None, :]).view(1, 1, ks, ks)


def ssim(x: torch.Tensor, y: torch.Tensor, win: torch.Tensor) -> torch.Tensor:
    ks = win.shape[-1]
    pad = ks // 2
    mux, muy = F.conv2d(x, win, padding=pad), F.conv2d(y, win, padding=pad)
    mux2, muy2, muxy = mux * mux, muy * muy, mux * muy
    sx = (F.conv2d(x * x, win, padding=pad) - mux2).clamp_min(0.0)
    sy = (F.conv2d(y * y, win, padding=pad) - muy2).clamp_min(0.0)
    sxy = F.conv2d(x * y, win, padding=pad) - muxy
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    s = ((2 * muxy + c1) * (2 * sxy + c2)) / ((mux2 + muy2 + c1) * (sx + sy + c2))
    return s.mean()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--data-root', default='data/sd302d',
                    help='comma-separated list of directories to mix as '
                         'training sources, e.g. "data/sd302d,data/real_captures_cropped"')
    ap.add_argument('--out', default='runs/v1')
    ap.add_argument('--epochs', type=int, default=150)
    ap.add_argument('--batch', type=int, default=16)
    ap.add_argument('--lr', type=float, default=2e-4)
    ap.add_argument('--severity-start', type=float, default=0.15)
    ap.add_argument('--severity-end', type=float, default=1.0)
    ap.add_argument('--curriculum-epochs', type=int, default=60)
    ap.add_argument('--w-l1', type=float, default=1.0)
    ap.add_argument('--w-ssim', type=float, default=0.3)
    ap.add_argument('--w-orient', type=float, default=0.3)
    args = ap.parse_args()

    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    data_roots = [r.strip() for r in args.data_root.split(',') if r.strip()]
    train_paths, val_paths = make_splits(data_roots)
    print(f'train prints={len(train_paths)} val prints={len(val_paths)} '
          f'data_root={args.data_root} device={dev}')
    train_ds = CurriculumRestoreDataset(train_paths, augment=True)
    val_ds = CurriculumRestoreDataset(val_paths, augment=False)
    train_dl = DataLoader(train_ds, batch_size=args.batch, shuffle=True,
                          num_workers=2, drop_last=True)
    val_dl = DataLoader(val_ds, batch_size=args.batch, shuffle=False, num_workers=1)

    model = RidgeRestoreUNet().to(dev)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    ssim_win = _gaussian_window().to(dev)

    best_val = float('inf')
    for epoch in range(args.epochs):
        t = min(1.0, epoch / max(1, args.curriculum_epochs))
        severity_cap = args.severity_start + t * (args.severity_end - args.severity_start)
        train_ds.severity_cap = severity_cap

        model.train()
        tr_loss = tr_l1 = tr_ssim = tr_orient = 0.0
        n_tr = n_skip = 0
        for degraded, clean in train_dl:
            degraded, clean = degraded.to(dev), clean.to(dev)
            restored = model(degraded)
            l_l1 = F.l1_loss(restored, clean)
            l_ssim = 1.0 - ssim(restored, clean, ssim_win)
            l_orient = orientation_loss(restored, clean)
            loss = args.w_l1 * l_l1 + args.w_ssim * l_ssim + args.w_orient * l_orient
            if not torch.isfinite(loss):
                n_skip += 1
                continue
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            opt.step()
            tr_loss += loss.item()
            tr_l1 += l_l1.item()
            tr_ssim += l_ssim.item()
            tr_orient += l_orient.item()
            n_tr += 1
        tr_loss, tr_l1, tr_ssim, tr_orient = (v / max(n_tr, 1) for v in
                                               (tr_loss, tr_l1, tr_ssim, tr_orient))
        if n_skip:
            print(f'  (skipped {n_skip} non-finite training batch(es))')

        model.eval()
        val_loss = val_l1 = 0.0
        n_val = 0
        with torch.no_grad():
            for degraded, clean in val_dl:
                degraded, clean = degraded.to(dev), clean.to(dev)
                restored = model(degraded)
                l_l1 = F.l1_loss(restored, clean)
                l_ssim = 1.0 - ssim(restored, clean, ssim_win)
                l_orient = orientation_loss(restored, clean)
                v = (args.w_l1 * l_l1 + args.w_ssim * l_ssim + args.w_orient * l_orient).item()
                if v == v and v not in (float('inf'), float('-inf')):
                    val_loss += v
                    val_l1 += l_l1.item()
                    n_val += 1
        val_loss, val_l1 = val_loss / max(n_val, 1), val_l1 / max(n_val, 1)
        print(f'epoch {epoch:03d} severity_cap={severity_cap:.2f} '
              f'train={tr_loss:.4f} (l1={tr_l1:.4f} ssim={tr_ssim:.4f} orient={tr_orient:.4f})  '
              f'val={val_loss:.4f} (l1={val_l1:.4f})')

        ckpt = {'model': model.state_dict(), 'epoch': epoch, 'val_loss': val_loss,
                'args': vars(args)}
        torch.save(ckpt, out / 'last.pt')
        if val_loss < best_val:
            best_val = val_loss
            torch.save(ckpt, out / 'best.pt')

    with open(out / 'summary.json', 'w') as f:
        json.dump({'best_val_loss': best_val, 'epochs': args.epochs}, f, indent=1)
    print(f'done. best val loss={best_val:.4f}. checkpoints in {out}')


if __name__ == '__main__':
    main()
