"""Train the two-crop rigid-registration network (self-supervised,
synthetic-transform only -- see synth_pair.py's docstring for why real
angled-pair training is deliberately NOT an option here, per this project's
own ml/deform_correct SD302f precedent).

    python train.py --data-root data/real_prints --epochs 60 --out runs/v1

Loss: PRIMARY signal is direct supervised regression against the known
synthetic transform (rotation as a normalised (cos,sin) vector -- MSE;
translation -- Huber/smooth-L1, more robust to the occasional large target
near this task's +/-18%-of-crop shift range than plain L2). This is the
real advantage this task has over ml/deform_correct's own original task:
because the pair is synthetically constructed, exact ground truth always
exists, so a strong direct-parameter loss is available -- deform_correct
had to rely on an INDIRECT orientation-field/SSIM loss because real
(probe, gallery) pairs there have no closed-form ground-truth transform.
Kept the orientation-field loss here too (reusing ml/deform_correct/
train.py's own implementation directly, not reimplemented) as a smaller-
weight AUXILIARY term: it regularises against "technically-off-target but
visually-equivalent" solutions (e.g. a locally rotationally-symmetric ridge
patch where a slightly different angle still aligns ridges well) and
doubles as a real training-time proxy for "would this transform actually
help compositing", closer to the real end goal than parameter error alone.

The REAL validation gate, once this is trained and something is ready to
wire into afis_print.py, is the same one this session's own hand-rolled
prototype used: real NFIQ2 on the resulting composite across a real,
non-trivial set of archived captures (see CLAUDE.md, 2026-08-08 "mosaic
ridge-orientation registration" section) -- NOT this script's own training/
val loss, same standing discipline as every other ML effort in this
project.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from dataset import MosaicPairDataset, make_splits
from model import TwoCropRegistrationNet, warp_with_params
from orient_loss import orientation_loss


def param_loss(pred: torch.Tensor, target: torch.Tensor,
               w_rot: float = 1.0, w_trans: float = 1.0
               ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    pred_rot = pred[:, :2]
    norm = pred_rot.norm(dim=1, keepdim=True).clamp_min(1e-6)
    pred_rot_n = pred_rot / norm
    l_rot = F.mse_loss(pred_rot_n, target[:, :2])
    l_trans = F.smooth_l1_loss(pred[:, 2:], target[:, 2:])
    return w_rot * l_rot + w_trans * l_trans, l_rot, l_trans


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--data-root', default='data/real_prints')
    ap.add_argument('--out', default='runs/v1')
    ap.add_argument('--epochs', type=int, default=60)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--lr', type=float, default=1e-4)
    ap.add_argument('--w-param', type=float, default=1.0)
    ap.add_argument('--w-orient', type=float, default=0.3)
    args = ap.parse_args()

    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    train_paths, val_paths = make_splits(args.data_root)
    print(f'train prints={len(train_paths)} val prints={len(val_paths)} '
          f'data_root={args.data_root} device={dev}')
    train_ds = MosaicPairDataset(train_paths, augment=True)
    val_ds = MosaicPairDataset(val_paths, augment=False)
    train_dl = DataLoader(train_ds, batch_size=args.batch, shuffle=True,
                          num_workers=2, drop_last=True)
    val_dl = DataLoader(val_ds, batch_size=args.batch, shuffle=False, num_workers=1)

    model = TwoCropRegistrationNet().to(dev)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)

    best_val = float('inf')
    for epoch in range(args.epochs):
        model.train()
        tr_loss = tr_rot = tr_trans = tr_orient = 0.0
        n_tr = n_skip = 0
        for x, target in train_dl:
            x, target = x.to(dev), target.to(dev)
            pred = model(x)
            l_param, l_rot, l_trans = param_loss(pred, target)
            side = x[:, 1:2]
            reference = x[:, 0:1]
            warped_side = warp_with_params(side, pred)
            l_orient = orientation_loss(warped_side, reference)
            loss = args.w_param * l_param + args.w_orient * l_orient
            if not torch.isfinite(loss):
                # Same discipline as ml/deform_correct/train.py: a single
                # pathological batch (e.g. a near-degenerate synthetic crop
                # with almost no ridge content after a large transform)
                # producing a non-finite loss must not poison every
                # subsequent step -- skip the update, don't crash or corrupt.
                n_skip += 1
                continue
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            opt.step()
            tr_loss += loss.item()
            tr_rot += l_rot.item()
            tr_trans += l_trans.item()
            tr_orient += l_orient.item()
            n_tr += 1
        tr_loss, tr_rot, tr_trans, tr_orient = (v / max(n_tr, 1) for v in
                                                 (tr_loss, tr_rot, tr_trans, tr_orient))
        if n_skip:
            print(f'  (skipped {n_skip} non-finite training batch(es))')

        model.eval()
        val_loss = val_rot = val_trans = val_orient = 0.0
        n_val = 0
        with torch.no_grad():
            for x, target in val_dl:
                x, target = x.to(dev), target.to(dev)
                pred = model(x)
                l_param, l_rot, l_trans = param_loss(pred, target)
                warped_side = warp_with_params(x[:, 1:2], pred)
                l_orient = orientation_loss(warped_side, x[:, 0:1])
                v = (args.w_param * l_param + args.w_orient * l_orient).item()
                if v == v and v not in (float('inf'), float('-inf')):
                    val_loss += v
                    val_rot += l_rot.item()
                    val_trans += l_trans.item()
                    val_orient += l_orient.item()
                    n_val += 1
        val_loss, val_rot, val_trans, val_orient = (v / max(n_val, 1) for v in
                                                     (val_loss, val_rot, val_trans, val_orient))
        print(f'epoch {epoch:03d} train={tr_loss:.4f} (rot={tr_rot:.4f} '
              f'trans={tr_trans:.4f} orient={tr_orient:.4f})  '
              f'val={val_loss:.4f} (rot={val_rot:.4f} trans={val_trans:.4f} '
              f'orient={val_orient:.4f})')

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
