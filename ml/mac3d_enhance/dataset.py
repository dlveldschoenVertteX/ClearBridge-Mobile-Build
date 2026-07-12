"""Dataset for MAC3D ridge restoration. Reads the layout in DATA_SPEC.md:

    root/<finger_id>/<capture_id>/input/shot_*.png   (model inputs)
    root/<finger_id>/<capture_id>/target.png         (supervised target)
    root/<finger_id>/<capture_id>/meta.json

Each __getitem__ yields one (input_shot, target) pair; a capture with N input
shots contributes N pairs (every soft shot learns toward the same clean
target). Splitting is SUBJECT-DISJOINT by finger_id — see make_splits().
"""
from __future__ import annotations

import json
import random
from pathlib import Path
from typing import List, Tuple

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset


def make_splits(root: str, val_frac: float = 0.15, seed: int = 0
                ) -> Tuple[List[str], List[str]]:
    """Return (train_finger_ids, val_finger_ids) — disjoint by finger so no
    finger's ridges appear in both splits (which would inflate val NFIQ)."""
    fingers = sorted(p.name for p in Path(root).iterdir() if p.is_dir())
    rng = random.Random(seed)
    rng.shuffle(fingers)
    n_val = max(1, int(len(fingers) * val_frac))
    return fingers[n_val:], fingers[:n_val]


class RidgeRestoreDataset(Dataset):
    def __init__(self, root: str, finger_ids: List[str], size: int = 512,
                 augment: bool = True):
        self.root = Path(root)
        self.size = size
        self.augment = augment
        self.pairs: List[Tuple[Path, Path]] = []
        for fid in finger_ids:
            for cap in (self.root / fid).iterdir():
                target = cap / 'target.png'
                idir = cap / 'input'
                if not target.exists() or not idir.is_dir():
                    continue
                for shot in sorted(idir.glob('*.png')) + sorted(idir.glob('*.jpg')):
                    self.pairs.append((shot, target))
        if not self.pairs:
            raise RuntimeError(f'No (input, target) pairs found under {root}')

    def __len__(self) -> int:
        return len(self.pairs)

    def _load(self, p: Path) -> np.ndarray:
        g = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
        if g is None:
            raise RuntimeError(f'unreadable image: {p}')
        return cv2.resize(g, (self.size, self.size)).astype(np.float32) / 255.0

    def __getitem__(self, i: int):
        inp_p, tgt_p = self.pairs[i]
        x = self._load(inp_p)
        y = self._load(tgt_p)
        if self.augment:
            if random.random() < 0.5:
                x, y = x[:, ::-1].copy(), y[:, ::-1].copy()
            k = random.randint(0, 3)
            if k:
                x, y = np.rot90(x, k).copy(), np.rot90(y, k).copy()
            # photometric jitter on the INPUT only (target stays the clean ref)
            g = random.uniform(0.8, 1.2)
            x = np.clip(x ** g * random.uniform(0.85, 1.15), 0, 1)
        return (torch.from_numpy(x)[None], torch.from_numpy(y)[None])
