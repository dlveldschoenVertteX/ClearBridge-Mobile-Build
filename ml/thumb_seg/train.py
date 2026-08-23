"""Train the thumb/pad segmentation U-Net on real flash-diff pseudo-labels.

    python train.py --data dataset/ --epochs 80 --out runs/v2

Heavy augmentation is the real engineering lever here, not architecture --
the real dataset is small (a few dozen unique real captures), same
constraint the original bootstrap model faced. In addition to standard
flips/rotation/brightness/contrast jitter, uses COPY-PASTE compositing:
cuts the segmented thumb out of one real image (using its own pseudo-label
mask) and pastes it onto another real image's background at a random
position/scale -- directly increases background diversity beyond what the
raw capture count alone provides, without needing new real data.

Validation is loss-based only during training (this script has no access to
the real downstream NFIQ2/SourceAFIS pipeline) -- the REAL gate, per this
project's standing discipline, is measuring the exported ONNX model as a new
mask candidate against real NFIQ2 and SourceAFIS genuine score on real
captures, done separately after export. Do not trust this script's val loss
as proof the mask is actually better.
"""
from __future__ import annotations

import argparse
import glob
import os
import random

import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader

from model import ThumbSegUNet

_SIZE = 256


class ThumbSegDataset(Dataset):
    def __init__(self, img_dir: str, mask_dir: str, augment: bool):
        self.img_paths = sorted(glob.glob(os.path.join(img_dir, '*.png')))
        self.mask_dir = mask_dir
        self.augment = augment

    def __len__(self) -> int:
        return len(self.img_paths)

    def _load(self, path: str) -> tuple[np.ndarray, np.ndarray]:
        img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        mask = cv2.imread(os.path.join(self.mask_dir, os.path.basename(path)),
                           cv2.IMREAD_GRAYSCALE)
        return img, mask

    def _copy_paste(self, img: np.ndarray, mask: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Cut the foreground out of a random OTHER sample and paste it onto
        this one's background, at a random scale/position. Both img and the
        donor are already real captures -- this recombines real backgrounds
        with real foregrounds in combinations that didn't literally occur,
        the same augmentation family the original bootstrap model used."""
        j = random.randrange(len(self.img_paths))
        donor_img, donor_mask = self._load(self.img_paths[j])
        if donor_img is None or donor_mask is None:
            return img, mask
        ys, xs = np.where(donor_mask > 0)
        if len(ys) < 50:
            return img, mask
        y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
        fg = donor_img[y0:y1 + 1, x0:x1 + 1]
        fg_mask = donor_mask[y0:y1 + 1, x0:x1 + 1]

        scale = random.uniform(0.7, 1.15)
        fh, fw = fg.shape
        nh, nw = max(8, int(fh * scale)), max(8, int(fw * scale))
        fg_r = cv2.resize(fg, (nw, nh))
        fm_r = cv2.resize(fg_mask, (nw, nh), interpolation=cv2.INTER_NEAREST)

        H, W = img.shape
        if nh >= H or nw >= W:
            return img, mask
        oy = random.randint(0, H - nh)
        ox = random.randint(0, W - nw)

        out_img = img.copy()
        out_mask = mask.copy()
        m = fm_r > 0
        roi_img = out_img[oy:oy + nh, ox:ox + nw]
        roi_img[m] = fg_r[m]
        out_img[oy:oy + nh, ox:ox + nw] = roi_img
        roi_mask = out_mask[oy:oy + nh, ox:ox + nw]
        roi_mask[m] = 255
        out_mask[oy:oy + nh, ox:ox + nw] = roi_mask
        return out_img, out_mask

    def __getitem__(self, idx: int):
        img, mask = self._load(self.img_paths[idx])

        if self.augment:
            if random.random() < 0.4:
                img, mask = self._copy_paste(img, mask)
            if random.random() < 0.5:
                img, mask = img[:, ::-1].copy(), mask[:, ::-1].copy()
            if random.random() < 0.3:
                img, mask = img[::-1, :].copy(), mask[::-1, :].copy()
            if random.random() < 0.6:
                angle = random.uniform(-20, 20)
                H, W = img.shape
                M = cv2.getRotationMatrix2D((W / 2, H / 2), angle, 1.0)
                img = cv2.warpAffine(img, M, (W, H), borderMode=cv2.BORDER_REFLECT)
                mask = cv2.warpAffine(mask, M, (W, H), borderMode=cv2.BORDER_REFLECT)
            if random.random() < 0.6:
                alpha = random.uniform(0.7, 1.3)  # contrast
                beta = random.uniform(-25, 25)    # brightness
                img = np.clip(img.astype(np.float32) * alpha + beta, 0, 255).astype(np.uint8)
            if random.random() < 0.3:
                k = random.choice([3, 5])
                img = cv2.GaussianBlur(img, (k, k), 0)

        img = cv2.resize(img, (_SIZE, _SIZE)).astype(np.float32) / 255.0
        mask = cv2.resize(mask, (_SIZE, _SIZE), interpolation=cv2.INTER_NEAREST)
        mask = (mask > 127).astype(np.float32)
        return torch.from_numpy(img[None]), torch.from_numpy(mask[None])


def dice_loss(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    probs = torch.sigmoid(logits)
    inter = (probs * target).sum(dim=(1, 2, 3))
    union = probs.sum(dim=(1, 2, 3)) + target.sum(dim=(1, 2, 3))
    return (1 - (2 * inter + 1) / (union + 1)).mean()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default=os.path.join(os.path.dirname(__file__), 'dataset'))
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), 'runs', 'v2'))
    ap.add_argument('--epochs', type=int, default=80)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--val-frac', type=float, default=0.15)
    args = ap.parse_args()

    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    os.makedirs(args.out, exist_ok=True)

    img_dir = os.path.join(args.data, 'images')
    mask_dir = os.path.join(args.data, 'masks')
    all_paths = sorted(glob.glob(os.path.join(img_dir, '*.png')))
    random.seed(0)
    random.shuffle(all_paths)
    n_val = max(1, int(len(all_paths) * args.val_frac))
    val_paths, train_paths = all_paths[:n_val], all_paths[n_val:]
    print(f'train={len(train_paths)} val={len(val_paths)}')

    def make_ds(paths, augment):
        ds = ThumbSegDataset(img_dir, mask_dir, augment)
        ds.img_paths = paths
        return ds

    train_dl = DataLoader(make_ds(train_paths, True), batch_size=args.batch,
                           shuffle=True, num_workers=2, drop_last=False)
    val_dl = DataLoader(make_ds(val_paths, False), batch_size=args.batch,
                         shuffle=False, num_workers=2)

    model = ThumbSegUNet().to(dev)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-5)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)

    best_val = float('inf')
    for epoch in range(args.epochs):
        model.train()
        tr_loss = 0.0
        for img, mask in train_dl:
            img, mask = img.to(dev), mask.to(dev)
            logits = model(img)
            loss = F.binary_cross_entropy_with_logits(logits, mask) + dice_loss(logits, mask)
            opt.zero_grad()
            loss.backward()
            opt.step()
            tr_loss += loss.item()
        tr_loss /= max(len(train_dl), 1)
        sched.step()

        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for img, mask in val_dl:
                img, mask = img.to(dev), mask.to(dev)
                logits = model(img)
                loss = F.binary_cross_entropy_with_logits(logits, mask) + dice_loss(logits, mask)
                val_loss += loss.item()
        val_loss /= max(len(val_dl), 1)
        if epoch % 10 == 0 or epoch == args.epochs - 1:
            print(f'epoch {epoch:03d} train={tr_loss:.4f} val={val_loss:.4f}')

        ckpt = {'model': model.state_dict(), 'epoch': epoch, 'val_loss': val_loss}
        torch.save(ckpt, os.path.join(args.out, 'last.pt'))
        if val_loss < best_val:
            best_val = val_loss
            torch.save(ckpt, os.path.join(args.out, 'best.pt'))

    print(f'done. best val loss={best_val:.4f}. checkpoints in {args.out}')


if __name__ == '__main__':
    main()
