"""Trainer for PairDeformFieldUNet on synthetic same-domain pairs generated
from REAL capture frames (synth_multiview.synth_pair).

Loss is directly SUPERVISED: L1 end-point-error against the exactly-known
ground-truth flow (the one structural advantage this whole Phase 2 has over
both the failed classical estimators and the unsupervised orientation-loss
training in ml/deform_correct/train.py), plus a small flow-smoothness term
for stability. No photometric-consistency term on purpose: the two views
carry INDEPENDENT photometric jitter by design, so at the true flow the
images still disagree in intensity -- a photometric loss would fight the
exact supervision rather than help it.

Go/no-go metric (reported every epoch): validation EPE vs. the IDENTITY
baseline (a model predicting zero flow scores EPE == mean |gt| by
definition). Learning is only real if val EPE lands well below identity.
Validation pairs are generated ONCE with a fixed seed (deterministic across
epochs) and drawn from held-out USERS (subject-disjoint split, same
discipline as ml/deform_correct/dataset.py).

CPU-friendly by default (small base width, 256px crops) -- proving descent
locally before any paid GPU run, per this project's standing discipline.

Run:
    python3 train_pair.py --frames-dir <pulled_frames_dir> --out-dir <ckpt_dir>

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import time

import cv2
import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

from deform_net import PairDeformFieldUNet, PixelWarp
from synth_multiview import synth_pair

_VAL_FRac = 0.2   # fraction of USERS held out for validation


def _user_is_val(user_id: str) -> bool:
    hv = int(hashlib.sha1(user_id.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return hv < _VAL_FRac


def _load_split(frames_dir: str):
    manifest = json.load(open(os.path.join(frames_dir, 'manifest.json')))
    train, val = [], []
    for e in manifest:
        p = os.path.join(frames_dir, e['file'])
        if not os.path.isfile(p):
            continue
        (val if _user_is_val(str(e.get('userId') or e.get('captureId') or e['file']))
         else train).append(p)
    return train, val


def _rich_crop(frame: np.ndarray, crop: int, rng: np.random.Generator) -> np.ndarray:
    """Random crop, retrying a few times for one with real ridge content
    (plain std gate -- flat background crops teach nothing)."""
    h, w = frame.shape[:2]
    if h <= crop or w <= crop:
        return cv2.resize(frame, (crop, crop))
    best = None
    for _ in range(6):
        y = int(rng.integers(0, h - crop))
        x = int(rng.integers(0, w - crop))
        c = frame[y:y + crop, x:x + crop]
        if c.std() >= 12:
            return c
        if best is None or c.std() > best.std():
            best = c
    return best


class SynthPairDataset(Dataset):
    def __init__(self, paths: list[str], crop: int, deterministic_seed: int | None = None):
        self.paths = paths
        self.crop = crop
        self.seed = deterministic_seed   # set -> reproducible pairs (val)

    def __len__(self):
        return len(self.paths)

    def __getitem__(self, i: int):
        rng = np.random.default_rng(
            self.seed + i if self.seed is not None else None)
        frame = cv2.imread(self.paths[i], cv2.IMREAD_GRAYSCALE)
        c = _rich_crop(frame, self.crop, rng)
        front, side, gt = synth_pair(c, rng)
        pair = np.stack([front, side]).astype(np.float32) / 255.0
        return torch.from_numpy(pair), torch.from_numpy(gt)


def _epe(pred: torch.Tensor, gt: torch.Tensor) -> torch.Tensor:
    return torch.sqrt(((pred - gt) ** 2).sum(dim=1) + 1e-9).mean()


def _smoothness(flow: torch.Tensor) -> torch.Tensor:
    dx = (flow[:, :, :, 1:] - flow[:, :, :, :-1]).abs().mean()
    dy = (flow[:, :, 1:, :] - flow[:, :, :-1, :]).abs().mean()
    return dx + dy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames-dir', required=True)
    ap.add_argument('--out-dir', required=True)
    ap.add_argument('--epochs', type=int, default=40)
    ap.add_argument('--crop', type=int, default=256)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--base', type=int, default=24)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--smooth-w', type=float, default=0.02)
    ap.add_argument('--limit-frames', type=int, default=0)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    train_paths, val_paths = _load_split(args.frames_dir)
    if args.limit_frames:
        train_paths = train_paths[:args.limit_frames]
        val_paths = val_paths[:max(8, args.limit_frames // 4)]
    print(f'train frames: {len(train_paths)}  val frames: {len(val_paths)} '
          f'(subject-disjoint)', flush=True)

    train_ds = SynthPairDataset(train_paths, args.crop)
    val_ds = SynthPairDataset(val_paths, args.crop, deterministic_seed=1234)
    train_dl = DataLoader(train_ds, batch_size=args.batch, shuffle=True, num_workers=2)
    val_dl = DataLoader(val_ds, batch_size=args.batch, shuffle=False, num_workers=2)

    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    model = PairDeformFieldUNet(base=args.base).to(device)
    warp = PixelWarp().to(device)   # noqa: F841 -- available for eval-time use
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)

    # Identity baseline on the fixed val set: EPE of predicting zero flow.
    with torch.no_grad():
        id_epes = []
        for _, gt in val_dl:
            id_epes.append(torch.sqrt((gt ** 2).sum(dim=1) + 1e-9).mean().item())
        identity_epe = float(np.mean(id_epes)) if id_epes else float('nan')
    print(f'identity-baseline val EPE: {identity_epe:.3f} px', flush=True)

    history = {'identity_epe': identity_epe, 'epochs': []}
    best_val = float('inf')
    for ep in range(args.epochs):
        model.train()
        t0 = time.time()
        tr_losses = []
        for pair, gt in train_dl:
            pair, gt = pair.to(device), gt.to(device)
            pred = model(pair)
            loss = _epe(pred, gt) + args.smooth_w * _smoothness(pred)
            if not torch.isfinite(loss):
                continue   # skip-not-corrupt, per deform_correct's NaN lesson
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step()
            tr_losses.append(loss.item())
        sched.step()

        model.eval()
        va_epes = []
        with torch.no_grad():
            for pair, gt in val_dl:
                pair, gt = pair.to(device), gt.to(device)
                va_epes.append(_epe(model(pair), gt).item())
        tr, va = float(np.mean(tr_losses)), float(np.mean(va_epes))
        history['epochs'].append({'epoch': ep, 'train': tr, 'val_epe': va})
        marker = ''
        if va < best_val:
            best_val = va
            torch.save({'model': model.state_dict(), 'epoch': ep,
                        'val_epe': va, 'base': args.base},
                       os.path.join(args.out_dir, 'best.pt'))
            marker = '  *saved*'
        print(f'ep {ep:3d}  train {tr:.3f}  val_epe {va:.3f} px '
              f'(identity {identity_epe:.3f}){marker}  [{time.time()-t0:.0f}s]',
              flush=True)
        json.dump(history, open(os.path.join(args.out_dir, 'history.json'), 'w'),
                  indent=2)

    print(f'done. best val EPE {best_val:.3f} px vs identity {identity_epe:.3f} px',
          flush=True)


if __name__ == '__main__':
    main()
