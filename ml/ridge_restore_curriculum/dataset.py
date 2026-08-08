"""Dataset for curriculum-degradation ridge restoration training.

Splitting is by SOURCE PRINT, subject-disjoint discipline matches every
other ml/ project here -- a held-out validation print's clean content is
never seen during training, degraded or not.
"""
from __future__ import annotations

import random
from pathlib import Path
from typing import List, Tuple

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

from degrade import degrade

_SIZE = 384


def make_splits(data_root: str, val_frac: float = 0.15, seed: int = 0
                ) -> Tuple[List[str], List[str]]:
    paths = sorted(str(p) for p in Path(data_root).glob('*.png'))
    if not paths:
        raise RuntimeError(f'no .png prints found under {data_root}')
    rng = random.Random(seed)
    rng.shuffle(paths)
    n_val = max(1, int(len(paths) * val_frac))
    return paths[n_val:], paths[:n_val]


def _load_clean(path: str) -> np.ndarray:
    g = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if g is None:
        raise RuntimeError(f'unreadable print: {path}')
    h, w = g.shape
    scale = _SIZE / min(h, w) if min(h, w) < _SIZE else _SIZE / max(h, w)
    # Real SD302 rolled-print scans vary widely in raw resolution; centre-
    # crop after a scale-to-fit resize (not a plain resize to SIZE x SIZE,
    # which would distort aspect ratio and, more importantly, ridge scale
    # non-uniformly on the two axes).
    new_w, new_h = max(_SIZE, int(w * scale)), max(_SIZE, int(h * scale))
    g = cv2.resize(g, (new_w, new_h),
                   interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC)
    y0 = (new_h - _SIZE) // 2
    x0 = (new_w - _SIZE) // 2
    return g[y0:y0 + _SIZE, x0:x0 + _SIZE]


class CurriculumRestoreDataset(Dataset):
    def __init__(self, paths: List[str], augment: bool = True):
        self.paths = paths
        self.augment = augment
        self.severity_cap = 0.2   # train.py updates this each epoch
        if not self.paths:
            raise RuntimeError('empty print list -- check the data split')

    def __len__(self) -> int:
        return len(self.paths)

    def __getitem__(self, i: int):
        clean_u8 = _load_clean(self.paths[i])
        rng = random.Random() if self.augment else random.Random(hash(self.paths[i]) & 0xffffffff)
        cap = self.severity_cap if self.augment else 1.0   # val always sees full range
        degraded = degrade(clean_u8, cap, rng)
        clean = clean_u8.astype(np.float32) / 255.0
        return (torch.from_numpy(degraded)[None].float(),
                torch.from_numpy(clean)[None].float())
