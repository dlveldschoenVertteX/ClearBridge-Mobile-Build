"""Dataset wrapping synth_pair.py's synthetic-pair generator.

Splitting is by SOURCE PRINT (each real Firestore capture is one
independent subject/session), same subject-disjoint discipline as
ml/deform_correct/dataset.py's finger_key split -- a held-out validation
print is never seen, in any synthetic pairing, during training.
"""
from __future__ import annotations

import random
from pathlib import Path
from typing import List, Tuple

import numpy as np
import torch
from torch.utils.data import Dataset

from synth_pair import make_pair


def make_splits(data_root: str, val_frac: float = 0.15, seed: int = 0
                ) -> Tuple[List[str], List[str]]:
    paths = sorted(str(p) for p in Path(data_root).glob('*.png'))
    if not paths:
        raise RuntimeError(f'no .png prints found under {data_root}')
    rng = random.Random(seed)
    rng.shuffle(paths)
    n_val = max(1, int(len(paths) * val_frac))
    return paths[n_val:], paths[:n_val]


class MosaicPairDataset(Dataset):
    """Each epoch draws a FRESH random synthetic transform per source print
    (not a fixed pre-generated set) -- same "different distortion each
    epoch" discipline as ml/deform_correct's SynthDeformDataset, so a small
    real print count (60 real captures locally, see README) still yields
    effectively unlimited distinct training examples via the transform
    sampling itself, not just epoch-to-epoch repetition of the same 60
    fixed pairs."""

    def __init__(self, paths: List[str], augment: bool = True):
        self.paths = paths
        self.augment = augment
        if not self.paths:
            raise RuntimeError('empty print list -- check the data split')

    def __len__(self) -> int:
        return len(self.paths)

    def __getitem__(self, i: int):
        rng = random.Random() if self.augment else random.Random(hash(self.paths[i]) & 0xffffffff)
        reference, side, target = make_pair(self.paths[i], rng=rng,
                                            photometric_jitter=self.augment)
        x = np.stack([reference, side], axis=0)   # (2, H, W)
        return torch.from_numpy(x).float(), torch.from_numpy(target).float()
