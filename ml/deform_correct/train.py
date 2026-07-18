"""Train the deformation-correction network (unsupervised, pair-supervised).

    python train.py --manifest manifest.json --epochs 60 --out runs/v1

Loss design -- the real engineering decision in this script, not a detail:
probe and gallery come from DIFFERENT SENSOR MODALITIES (a photographic
contactless capture vs. a scanned/rolled contact print). Raw pixel-intensity
similarity (plain SSIM/MSE/NCC) is a WEAK signal here even after good
alignment, because the two modalities don't share pixel statistics -- a
photograph and an ink scan of the same aligned ridge can look very different
pixel-for-pixel. Ridge ORIENTATION, by contrast, is a structural property
that survives the modality change (a ridge flowing north-east is
north-east-flowing regardless of how it was imaged), so it is the primary
loss signal here: a differentiable reimplementation of afis_print.py's own
_orientation_field (same Sobel/structure-tensor math, in torch instead of
cv2, so gradients flow back through the warp) computed on both the warped
probe and the gallery, compared via cosine similarity on the doubled angle
(orientation is defined mod pi, not a full vector -- same convention as the
production module). A smaller-weight raw-intensity SSIM term (reused from
ml/mac3d_enhance/train.py) is kept as a secondary signal since it's cheap and
occasionally helps local contrast alignment, plus a flow-smoothness
regularizer (standard for registration nets -- without it the network can
learn a jagged, ridge-destroying warp that locally "matches" without being a
physically plausible correction).

The REAL validation gate, per docs/FIDELITY_WALL_SCOPE.md's standing
discipline, is NOT this training loss -- it's the SourceAFIS-based
genuine-vs-impostor ROC (ml/fidelity_benchmark/benchmark.py), run offline
after exporting to ONNX and wiring into geom_correct.py. This script's own
validation loss is a training-time proxy only, same relationship as
ml/mac3d_enhance/train.py's SSIM-vs-real-NFIQ discipline.

Deliberately dependency-light (torch + opencv + numpy) -- no GPU is present in
this build container; run this on SageMaker (see sagemaker_launch.py) or any
GPU host, it auto-selects CUDA.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader

from dataset import DeformPairDataset, make_splits
from model import DeformFieldUNet, SpatialTransformer

_ORIENT_BLOCK = 16     # matches afis_print._BLOCK
_ORIENT_SMOOTH = 15.0  # matches afis_print._ORIENT_SMOOTH


def _sobel_kernels(device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
    kx = torch.tensor([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]],
                       dtype=torch.float32, device=device).view(1, 1, 3, 3)
    ky = torch.tensor([[-1, -2, -1], [0, 0, 0], [1, 2, 1]],
                       dtype=torch.float32, device=device).view(1, 1, 3, 3)
    return kx, ky


def _box_blur(x: torch.Tensor, k: int) -> torch.Tensor:
    pad = k // 2
    kernel = torch.ones(1, 1, k, k, device=x.device) / (k * k)
    return F.conv2d(x, kernel, padding=pad)


def _gaussian_blur(x: torch.Tensor, sigma: float) -> torch.Tensor:
    k = int(2 * round(3 * sigma) + 1)
    coords = torch.arange(k, device=x.device).float() - k // 2
    g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
    g = g / g.sum()
    kernel = (g[:, None] @ g[None, :]).view(1, 1, k, k)
    return F.conv2d(x, kernel, padding=k // 2)


def orientation_field(img: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """Differentiable torch reimplementation of afis_print._orientation_field.
    img: (B, 1, H, W) in [0, 1]. Returns (cos2theta, sin2theta) -- kept as the
    doubled-angle vector components (not a bare angle) so the loss below can
    compare orientation fields with a simple dot product, correctly handling
    the mod-pi ("undirected line") ambiguity real ridge orientation has."""
    kx, ky = _sobel_kernels(img.device)
    gx = F.conv2d(img, kx, padding=1)
    gy = F.conv2d(img, ky, padding=1)
    vx = _box_blur(2 * gx * gy, _ORIENT_BLOCK)
    vy = _box_blur(gx * gx - gy * gy, _ORIENT_BLOCK)
    # Doubled-angle orientation vector computed WITHOUT atan2. For
    # theta = 0.5*atan2(vx, vy) the identities cos(2*theta) = vy/r and
    # sin(2*theta) = vx/r hold (r = |(vx, vy)|), so we form the same vector
    # directly. This is not a cosmetic rewrite: atan2's gradient is
    # vy/(vx^2+vy^2) which blows up to +/-inf on uniform patches where
    # vx,vy -> 0 (exactly the large white borders that global pre-alignment +
    # rotation augmentation introduce). Those Inf grads, once fed through
    # clip_grad_norm_, became NaN (inf * (max_norm/inf)) and corrupted the
    # weights -- the cause of ~all-batches-non-finite on the aligned run.
    # Flooring r with eps keeps the gradient bounded everywhere.
    r = torch.sqrt(vx * vx + vy * vy + 1e-6)
    cs = _gaussian_blur(vy / r, _ORIENT_SMOOTH)
    sn = _gaussian_blur(vx / r, _ORIENT_SMOOTH)
    norm = torch.sqrt(cs ** 2 + sn ** 2) + 1e-6
    return cs / norm, sn / norm


def orientation_loss(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """1 - mean cosine similarity between two images' orientation fields (0 =
    identical ridge flow everywhere, up to 2 = completely perpendicular)."""
    ca, sa = orientation_field(a)
    cb, sb = orientation_field(b)
    cos_sim = ca * cb + sa * sb   # cos(2*(theta_a - theta_b))
    return (1.0 - cos_sim.mean())


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
    # Variance is mathematically non-negative, but E[x^2] - mu^2 can go
    # slightly negative from fp32 round-off on near-uniform patches (e.g. the
    # grey-filled area outside a crop's mask) -- clamp before it compounds
    # through Adam's running moments into a NaN cascade a few epochs later.
    sx = (F.conv2d(x * x, win, padding=pad) - mux2).clamp_min(0.0)
    sy = (F.conv2d(y * y, win, padding=pad) - muy2).clamp_min(0.0)
    sxy = F.conv2d(x * y, win, padding=pad) - muxy
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    s = ((2 * muxy + c1) * (2 * sxy + c2)) / ((mux2 + muy2 + c1) * (sx + sy + c2))
    return s.mean()


def flow_smoothness(flow: torch.Tensor) -> torch.Tensor:
    dx = flow[:, :, :, 1:] - flow[:, :, :, :-1]
    dy = flow[:, :, 1:, :] - flow[:, :, :-1, :]
    return (dx ** 2).mean() + (dy ** 2).mean()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--data-root', default='.',
                    help='directory the manifest\'s relative probe/gallery '
                         'paths resolve against -- the "images" data channel '
                         'mount on SageMaker (e.g. /opt/ml/input/data/images), '
                         'or wherever the dataset actually lives locally')
    ap.add_argument('--out', default='runs/v1')
    ap.add_argument('--epochs', type=int, default=60)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--lr', type=float, default=1e-4)
    ap.add_argument('--size', type=int, default=512)
    ap.add_argument('--w-orient', type=float, default=1.0)
    ap.add_argument('--w-ssim', type=float, default=0.2)
    ap.add_argument('--w-smooth', type=float, default=0.5)
    args = ap.parse_args()

    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    train_pairs, val_pairs = make_splits(args.manifest)
    print(f'train pairs={len(train_pairs)} val pairs={len(val_pairs)} '
          f'data_root={args.data_root}')
    train_dl = DataLoader(
        DeformPairDataset(train_pairs, args.data_root, args.size, augment=True),
        batch_size=args.batch, shuffle=True, num_workers=4, drop_last=True)
    val_dl = DataLoader(
        DeformPairDataset(val_pairs, args.data_root, args.size, augment=False),
        batch_size=args.batch, shuffle=False, num_workers=2)

    model = DeformFieldUNet().to(dev)
    warp = SpatialTransformer().to(dev)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    ssim_win = _gaussian_window().to(dev)

    best_val = float('inf')
    for epoch in range(args.epochs):
        model.train()
        tr_loss = 0.0
        n_tr_finite = 0
        n_tr_skipped = 0
        for probe, gallery in train_dl:
            probe, gallery = probe.to(dev), gallery.to(dev)
            flow = model(probe)
            warped = warp(probe, flow)
            l_orient = orientation_loss(warped, gallery)
            l_ssim = 1.0 - ssim(warped, gallery, ssim_win)
            l_smooth = flow_smoothness(flow)
            loss = (args.w_orient * l_orient + args.w_ssim * l_ssim
                    + args.w_smooth * l_smooth)
            if not torch.isfinite(loss):
                # A single pathological batch (e.g. a near-degenerate crop)
                # producing a NaN/Inf loss is a real, observed failure mode on
                # this small, noisy real dataset (confirmed: training NaN'd
                # permanently from a single such batch on two prior runs,
                # epoch 12 and epoch 41 respectively -- gradient clipping
                # alone doesn't help here, since it only bounds an otherwise-
                # finite gradient, and can't rescue a loss that's already
                # NaN/Inf going INTO backward()). Skipping the update entirely
                # keeps the weights clean instead of permanently poisoning
                # every subsequent batch/epoch with a single corrupted step.
                n_tr_skipped += 1
                continue
            opt.zero_grad()
            loss.backward()
            # Standard safeguard against exploding-gradient divergence on a
            # small, noisy real dataset (181 pairs) -- caps how far a single
            # bad batch can push the weights, same discipline as clamping
            # ssim()'s variance terms above.
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            opt.step()
            tr_loss += loss.item()
            n_tr_finite += 1
        tr_loss /= max(n_tr_finite, 1)
        if n_tr_skipped:
            print(f'  (skipped {n_tr_skipped} non-finite training batch(es))')

        model.eval()
        val_loss = 0.0
        n_val_finite = 0
        with torch.no_grad():
            for probe, gallery in val_dl:
                probe, gallery = probe.to(dev), gallery.to(dev)
                flow = model(probe)
                warped = warp(probe, flow)
                l_orient = orientation_loss(warped, gallery)
                l_ssim = 1.0 - ssim(warped, gallery, ssim_win)
                l_smooth = flow_smoothness(flow)
                v = (args.w_orient * l_orient + args.w_ssim * l_ssim
                     + args.w_smooth * l_smooth).item()
                if math.isfinite(v):
                    val_loss += v
                    n_val_finite += 1
        val_loss /= max(n_val_finite, 1)
        print(f'epoch {epoch:03d} train={tr_loss:.4f} val={val_loss:.4f}')

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
