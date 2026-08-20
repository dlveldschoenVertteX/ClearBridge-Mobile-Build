"""Local CPU smoke test: does ScaleRegressorNet show a real learning trend
on self-supervised synthetic scale distortion, over a small number of
epochs, before any SageMaker spend is considered? Same discipline as this
project's own prior local-CPU-smoke-test step for `ml/deform_correct`.

Usage: python3 train.py [--epochs 15] [--source-glob ...]
"""
from __future__ import annotations

import argparse
import sys
import time

import torch
from torch.utils.data import DataLoader

from dataset import ScaleDistortionDataset, load_split
from model import ScaleRegressorNet


def run(epochs: int, source_glob: str, train_len: int, val_len: int, seed: int = 0) -> None:
    torch.manual_seed(seed)

    train_sources, val_sources = load_split(source_glob, val_frac=0.2, seed=seed)
    print(f'sources: {len(train_sources)} train images, {len(val_sources)} val images', flush=True)

    train_ds = ScaleDistortionDataset(train_sources, length=train_len, seed=seed)
    val_ds = ScaleDistortionDataset(val_sources, length=val_len, seed=seed + 1000)

    train_loader = DataLoader(train_ds, batch_size=16, shuffle=True, num_workers=0)
    val_loader = DataLoader(val_ds, batch_size=16, shuffle=False, num_workers=0)

    model = ScaleRegressorNet()
    n_params = sum(p.numel() for p in model.parameters())
    print(f'model params: {n_params:,}', flush=True)

    opt = torch.optim.Adam(model.parameters(), lr=1e-3)
    # Cosine LR decay -- added after the 113-image run showed real val_loss
    # oscillation late in training (epochs 51-57 climbing back to 0.015-0.034
    # after already reaching 0.0064-0.0092) on a FLAT lr=1e-3 the whole way.
    # That pattern (converges, then bounces) is the standard signature of a
    # step size too large to settle once near a minimum -- a smooth decay to
    # ~0 by the final epoch is the standard fix, not a new hyperparameter to
    # tune (T_max=epochs, no separate schedule shape to pick).
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=epochs)
    loss_fn = torch.nn.MSELoss()

    history = []
    for epoch in range(1, epochs + 1):
        model.train()
        train_loss = 0.0
        n = 0
        for x, y in train_loader:
            opt.zero_grad()
            pred = model(x)
            loss = loss_fn(pred, y)
            if not torch.isfinite(loss):
                print(f'epoch {epoch}: non-finite loss, skipping batch', flush=True)
                continue
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step()
            train_loss += loss.item() * x.size(0)
            n += x.size(0)
        train_loss /= max(1, n)

        model.eval()
        val_loss = 0.0
        val_mae_scale = 0.0
        nv = 0
        with torch.no_grad():
            for x, y in val_loader:
                pred = model(x)
                loss = loss_fn(pred, y)
                val_loss += loss.item() * x.size(0)
                # Real-units MAE: |exp(pred) - exp(true)| on the actual
                # scale factor, more interpretable than log-space MSE alone.
                val_mae_scale += (torch.exp(pred) - torch.exp(y)).abs().sum().item()
                nv += x.size(0)
        val_loss /= max(1, nv)
        val_mae_scale /= max(1, nv)
        sched.step()

        history.append((epoch, train_loss, val_loss, val_mae_scale))
        print(f'epoch {epoch:2d}/{epochs}  lr={sched.get_last_lr()[0]:.5f}  train_loss={train_loss:.4f}  '
              f'val_loss={val_loss:.4f}  val_scale_mae={val_mae_scale:.4f}', flush=True)

    print('\n=== TREND CHECK ===')
    first_half = [h[2] for h in history[:len(history)//2]]
    second_half = [h[2] for h in history[len(history)//2:]]
    if first_half and second_half:
        fh_mean = sum(first_half) / len(first_half)
        sh_mean = sum(second_half) / len(second_half)
        print(f'val_loss mean, first half of epochs: {fh_mean:.4f}')
        print(f'val_loss mean, second half of epochs: {sh_mean:.4f}')
        print(f'improvement: {(fh_mean - sh_mean) / max(fh_mean, 1e-9) * 100:.1f}%')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--epochs', type=int, default=15)
    ap.add_argument('--source-glob', type=str,
                     default='/tmp/claude-0/-home-user-ClearBridge-Mobile-Build/'
                              '7c276512-7b7e-5f85-8f5b-2eb1bc5e7593/scratchpad/ps/sp/*.png')
    ap.add_argument('--train-len', type=int, default=400)
    ap.add_argument('--val-len', type=int, default=80)
    args = ap.parse_args()

    t0 = time.time()
    run(args.epochs, args.source_glob, args.train_len, args.val_len)
    print(f'\ntotal wall time: {time.time() - t0:.1f}s')
