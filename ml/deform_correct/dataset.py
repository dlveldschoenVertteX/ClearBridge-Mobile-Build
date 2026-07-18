"""Dataset for the deformation-correction network. Reads the manifest
build_manifest.py produces: a flat list of {probe, gallery, finger_key}.

Each item is a (probe, gallery) pair of the SAME finger -- probe is the
contactless capture (network input), gallery is the paired contact print
(used ONLY in the training loss, never fed to the network -- see model.py's
docstring for why). Splitting is subject-disjoint by finger_key, same
discipline as ml/mac3d_enhance/dataset.py.
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


def make_splits(manifest_path: str, val_frac: float = 0.15, seed: int = 0
                ) -> Tuple[List[dict], List[dict]]:
    """Subject-disjoint (by finger_key) train/val split -- never the same
    finger in both, otherwise validation loss is inflated by a network that
    has effectively memorised that finger's specific correction."""
    pairs = json.load(open(manifest_path))
    fingers = sorted({p['finger_key'] for p in pairs})
    rng = random.Random(seed)
    rng.shuffle(fingers)
    n_val = max(1, int(len(fingers) * val_frac))
    val_fingers = set(fingers[:n_val])
    train = [p for p in pairs if p['finger_key'] not in val_fingers]
    val = [p for p in pairs if p['finger_key'] in val_fingers]
    return train, val


class DeformPairDataset(Dataset):
    def __init__(self, pairs: List[dict], data_root: str, size: int = 512,
                 augment: bool = True):
        self.pairs = pairs
        self.data_root = Path(data_root)
        self.size = size
        self.augment = augment
        if not self.pairs:
            raise RuntimeError('empty pair list -- check the manifest/split')

    def __len__(self) -> int:
        return len(self.pairs)

    def _load(self, rel_path: str) -> np.ndarray:
        p = self.data_root / rel_path
        g = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
        if g is None:
            raise RuntimeError(
                f'unreadable image: {p} (data_root={self.data_root}, '
                f'relative path from manifest={rel_path!r}) -- if this is a '
                f'fresh SageMaker run, double check --data-root points at '
                f'the "images" channel mount, not the "manifest" channel')
        return cv2.resize(g, (self.size, self.size)).astype(np.float32) / 255.0

    def __getitem__(self, i: int):
        rec = self.pairs[i]
        probe = self._load(rec['probe'])
        gallery = self._load(rec['gallery'])
        if self.augment:
            # Pairs are GLOBALLY PRE-ALIGNED upstream (align_pairs.py: probe
            # registered to its gallery by a rotation+scale+translation grid
            # search on the ridge-orientation field) so the network only has to
            # learn the residual LOCAL elastic deformation -- the standard C2CL
            # "global align -> residual deform" order, and the fix for the
            # training plateau (a full rotation the net's small displacement
            # budget could never undo was previously left in the input).
            # Augmentation must therefore stay SMALL: a big rot90/flip here
            # would throw the pair back out of global alignment and recreate
            # exactly the plateau we just removed. Small shared rotation +
            # translation only, so the pair stays registered while the net still
            # sees mild pose variation.
            ang = random.uniform(-15.0, 15.0)
            tx = random.uniform(-0.04, 0.04) * self.size
            ty = random.uniform(-0.04, 0.04) * self.size
            c = (self.size / 2.0, self.size / 2.0)
            M = cv2.getRotationMatrix2D(c, ang, 1.0)
            M[0, 2] += tx
            M[1, 2] += ty
            # Reflect (not a flat fill) at the borders so the small aug rotation
            # doesn't introduce new large uniform regions -- reflected ridges
            # stay locally oriented, which is both more realistic and avoids
            # feeding the orientation loss more near-degenerate patches.
            probe = cv2.warpAffine(probe, M, (self.size, self.size),
                                   borderMode=cv2.BORDER_REFLECT)
            gallery = cv2.warpAffine(gallery, M, (self.size, self.size),
                                     borderMode=cv2.BORDER_REFLECT)
            # Photometric jitter on the PROBE only -- the gallery is the
            # fixed reference the loss compares against, jittering it would
            # make the training target itself noisy.
            g = random.uniform(0.85, 1.15)
            probe = np.clip(probe ** g * random.uniform(0.9, 1.1), 0, 1)
        return (
            torch.from_numpy(probe)[None].float(),
            torch.from_numpy(gallery)[None].float(),
        )
