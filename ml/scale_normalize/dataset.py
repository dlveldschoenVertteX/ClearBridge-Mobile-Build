"""Self-supervised scale-distortion dataset -- same "apply a KNOWN synthetic
distortion to real clean material, train the net to invert it" pattern
`ml/deform_correct/synth_distort.py` already validated (that line trained
cleanly on synthetic distortion after the earlier SD302f real-pair approach
was a dead end; see CLAUDE.md 2026-07-18). Here the distortion is pure
scale, matching this net's narrower scope.

Source material: real superprint_afis.png renders already downloaded this
session's SourceAFIS matchability sweep (`scratchpad/ps/sp/`, 63 real
captures). Small sample -- this is explicitly the local CPU smoke test, not
a production training run (same discipline as this project's own prior
"Local CPU smoke test of registration training pipeline" task, which
existed purely to prove the loop runs end-to-end, not to ship a model).
"""
from __future__ import annotations

import glob
import os
import random
from typing import List, Tuple

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

CANVAS = 224

# Real observed range this session's matchability sweep + wider capture
# library established: native backend ridge wavelength (raw) spans ~9-30px
# against a ~9px canonical target. log-scale range covers that plus margin
# for the sub-canonical (over-shrunk) direction a bad correction could land in.
LOG_SCALE_RANGE = (np.log(0.3), np.log(3.5))


def _load_sources(patterns) -> List[np.ndarray]:
    """`patterns` may be a single glob string or a list of them -- lets a
    caller mix multiple real source corpora (e.g. MAC3D superprints + NIST
    SD302 contact prints) into one pool. Both domains are equally valid
    source material for this task specifically because training operates
    on binarized/near-binarized ridge texture, not raw photometric detail
    -- a real scanner print and a real captured-then-Gabor-enhanced print
    occupy the same kind of pixel domain (CTO's own real-world observation,
    2026-08-19)."""
    if isinstance(patterns, str):
        patterns = [patterns]
    paths = []
    for pattern in patterns:
        paths.extend(sorted(glob.glob(pattern)))
    imgs = []
    for p in paths:
        img = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
        if img is None:
            continue
        h, w = img.shape[:2]
        side = min(h, w)
        img = img[(h - side) // 2:(h - side) // 2 + side, (w - side) // 2:(w - side) // 2 + side]
        img = cv2.resize(img, (CANVAS, CANVAS), interpolation=cv2.INTER_AREA)
        imgs.append(img)
    return imgs


def _apply_scale(img: np.ndarray, scale: float, rng: random.Random) -> np.ndarray:
    """Resize by `scale` (>1 = zoomed in / captured closer, matching this
    project's own established convention: closer capture -> more px per
    ridge -> effectively a larger scale here), then centre-crop/pad back to
    CANVAS so every network input has a fixed size regardless of scale."""
    h, w = img.shape[:2]
    new_h, new_w = max(4, round(h * scale)), max(4, round(w * scale))
    resized = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_LINEAR)

    canvas = np.full((CANVAS, CANVAS), 255, dtype=np.uint8)  # white bg, matches superprint convention
    if new_h >= CANVAS and new_w >= CANVAS:
        y0 = (new_h - CANVAS) // 2
        x0 = (new_w - CANVAS) // 2
        canvas = resized[y0:y0 + CANVAS, x0:x0 + CANVAS]
    else:
        y0 = max(0, (CANVAS - new_h) // 2)
        x0 = max(0, (CANVAS - new_w) // 2)
        ch = min(new_h, CANVAS - y0)
        cw = min(new_w, CANVAS - x0)
        canvas[y0:y0 + ch, x0:x0 + cw] = resized[:ch, :cw]

    # Light photometric jitter so the net can't shortcut on exact pixel
    # statistics alone -- same discipline as synth_distort.py's own
    # photometric block.
    if rng.random() < 0.7:
        o = canvas.astype(np.float32) / 255.0
        o = np.clip(o ** rng.uniform(0.85, 1.15), 0, 1)
        if rng.random() < 0.4:
            o = cv2.GaussianBlur(o, (0, 0), rng.uniform(0.3, 1.0))
        canvas = (o * 255).astype(np.uint8)
    return canvas


class ScaleDistortionDataset(Dataset):
    def __init__(self, sources: List[np.ndarray], length: int, seed: int = 0):
        self.sources = sources
        self.length = length
        self.rng = random.Random(seed)

    def __len__(self) -> int:
        return self.length

    def __getitem__(self, idx: int) -> Tuple[torch.Tensor, torch.Tensor]:
        img = self.rng.choice(self.sources)
        log_scale = self.rng.uniform(*LOG_SCALE_RANGE)
        scale = float(np.exp(log_scale))
        distorted = _apply_scale(img, scale, self.rng)
        x = torch.from_numpy(distorted.astype(np.float32) / 255.0).unsqueeze(0)
        y = torch.tensor(log_scale, dtype=torch.float32)
        return x, y


def load_split(patterns, val_frac: float = 0.2, seed: int = 0):
    sources = _load_sources(patterns)
    if not sources:
        raise RuntimeError(f'no source images matched {patterns}')
    rng = random.Random(seed)
    idx = list(range(len(sources)))
    rng.shuffle(idx)
    n_val = max(1, int(len(idx) * val_frac))
    val_idx = set(idx[:n_val])
    train_sources = [s for i, s in enumerate(sources) if i not in val_idx]
    val_sources = [s for i, s in enumerate(sources) if i in val_idx]
    return train_sources, val_sources
