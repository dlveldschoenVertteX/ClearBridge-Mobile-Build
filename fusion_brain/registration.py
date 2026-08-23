"""Minutiae-set registration via RANSAC over similarity transforms.

This is the piece that makes minutiae-space fusion possible where pixel-space
fusion failed. Registering SPARSE POINT SETS is a far better-conditioned
problem than registering pixels: it needs no per-pixel ridge-phase agreement,
so the non-rigid skin deformation between captures (the thing that
manufactures spurious minutiae at every composited seam) does not have to be
solved exactly -- only approximately enough to put corresponding minutiae
within a tolerance of each other.

Deliberately classical, not learned. This project's own `ml/mosaic_register`
attempt (a CNN regressing transform params from a global-average-pooled
embedding) never learned anything -- val loss frozen across a 200-epoch real
GPU run -- because global pooling discards the spatial correspondence the
task depends on. RANSAC over minutiae correspondences uses that structure
directly instead of trying to learn it from scratch.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import numpy as np

from minutiae_io import Minutia


@dataclass
class Transform:
    """Similarity transform: rotate by theta, scale, then translate."""
    dx: float
    dy: float
    theta_deg: float
    scale: float = 1.0

    def apply(self, m: Minutia) -> Minutia:
        t = math.radians(self.theta_deg)
        c, s = math.cos(t), math.sin(t)
        x = self.scale * (c * m.x - s * m.y) + self.dx
        y = self.scale * (s * m.x + c * m.y) + self.dy
        return Minutia(x=x, y=y, theta=(m.theta + self.theta_deg) % 360,
                       quality=m.quality, source=m.source)

    def apply_all(self, ms: Sequence[Minutia]) -> List[Minutia]:
        return [self.apply(m) for m in ms]


def _angle_diff(a: float, b: float) -> float:
    d = abs(a - b) % 360
    return min(d, 360 - d)


def count_inliers(a: Sequence[Minutia], b: Sequence[Minutia], t: Transform,
                  dist_tol: float, angle_tol: float
                  ) -> Tuple[int, List[Tuple[int, int]]]:
    """Greedy one-to-one correspondence count between transformed `b` and `a`.

    One-to-one matters: without it a single dense cluster in one set can
    "match" many minutiae in the other and inflate the inlier count, which
    would make a bad transform look good.
    """
    tb = t.apply_all(b)
    used_a = set()
    pairs: List[Tuple[int, int]] = []
    for j, mb in enumerate(tb):
        best_i, best_d = -1, dist_tol
        for i, ma in enumerate(a):
            if i in used_a:
                continue
            d = math.hypot(ma.x - mb.x, ma.y - mb.y)
            if d < best_d and _angle_diff(ma.theta, mb.theta) <= angle_tol:
                best_i, best_d = i, d
        if best_i >= 0:
            used_a.add(best_i)
            pairs.append((best_i, j))
    return len(pairs), pairs


def _score_transform(A: np.ndarray, B: np.ndarray, t: Transform,
                     dist_tol: float, angle_tol: float) -> int:
    """Fast (vectorised, non-exclusive) inlier count for hypothesis ranking.

    Counts how many of B land within tolerance of ANY minutia in A. Not
    one-to-one -- that stricter count is only worth paying for on the single
    winning hypothesis, via count_inliers().
    """
    th = math.radians(t.theta_deg)
    c, s_ = math.cos(th) * t.scale, math.sin(th) * t.scale
    bx = c * B[:, 0] - s_ * B[:, 1] + t.dx
    by = s_ * B[:, 0] + c * B[:, 1] + t.dy
    bt = (B[:, 2] + t.theta_deg) % 360
    dx = bx[:, None] - A[None, :, 0]
    dy = by[:, None] - A[None, :, 1]
    close = (dx * dx + dy * dy) < (dist_tol * dist_tol)
    da = np.abs(bt[:, None] - A[None, :, 2]) % 360
    da = np.minimum(da, 360 - da)
    return int((close & (da <= angle_tol)).any(axis=1).sum())


def register(a: Sequence[Minutia], b: Sequence[Minutia],
             dist_tol: float = 12.0, angle_tol: float = 25.0,
             top_k: int = 50, scales: Sequence[float] = (0.9, 1.0, 1.11),
             iters: int = 0, seed: int = 0,
             allow_scale: bool = True) -> Tuple[Optional[Transform], int]:
    """Find the transform mapping `b` onto `a`. Returns (transform, inliers).

    ORIENTATION-ANCHORED, not classic 2-point RANSAC. Each minutia carries its
    own ridge orientation, so ONE assumed correspondence fully determines a
    rotation (difference of the two thetas) and a translation (whatever maps
    one onto the other) -- a property point clouds in general do not have.
    That turns hypothesis generation from "sample 2 points from each set and
    hope both correspond" (probability ~1/N^2 per draw -- measured on
    synthetic data to find only 6/50 true inliers, with a wildly wrong
    transform) into an exhaustive sweep over single correspondences, which
    cannot miss the right one if it is present.

    Scale is swept over a narrow set rather than estimated, because
    generate() resamples every print toward the same target ridge period
    (freq_normalize=True), so cross-source scale should already sit near 1.0
    -- the large differences in print DIMENSIONS come from differing crop
    extents, not differing ridge scale.

    `iters`/`seed` are accepted and ignored, kept so existing callers of the
    older RANSAC signature do not break.
    """
    if len(a) < 3 or len(b) < 3:
        return None, 0
    A = np.array([[m.x, m.y, m.theta] for m in a], dtype=np.float64)
    B = np.array([[m.x, m.y, m.theta] for m in b], dtype=np.float64)
    ai = sorted(range(len(a)), key=lambda i: -a[i].quality)[:top_k]
    bi = sorted(range(len(b)), key=lambda j: -b[j].quality)[:top_k]
    scale_set = tuple(scales) if allow_scale else (1.0,)

    best_t: Optional[Transform] = None
    best_n = 0
    for sc in scale_set:
        for i in ai:
            for j in bi:
                theta = (A[i, 2] - B[j, 2]) % 360
                th = math.radians(theta)
                c, s_ = math.cos(th) * sc, math.sin(th) * sc
                dx = A[i, 0] - (c * B[j, 0] - s_ * B[j, 1])
                dy = A[i, 1] - (s_ * B[j, 0] + c * B[j, 1])
                t = Transform(dx, dy, theta, sc)
                n = _score_transform(A, B, t, dist_tol, angle_tol)
                if n > best_n:
                    best_n, best_t = n, t
    if best_t is None:
        return None, 0
    strict, _ = count_inliers(a, b, best_t, dist_tol, angle_tol)
    return best_t, strict


def refine(a: Sequence[Minutia], b: Sequence[Minutia], t: Transform,
           dist_tol: float = 12.0, angle_tol: float = 25.0,
           rounds: int = 4) -> Tuple[Transform, int]:
    """Least-squares refinement of a RANSAC transform, iterated.

    RANSAC's hypothesis comes from exactly 2 point correspondences, so it is
    only as good as that one sample. Re-fitting over ALL current inliers and
    re-collecting typically recovers correspondences the 2-point estimate
    missed. Added after Phase 0 measured only 16-25% inlier rates on sweep
    zones -- too low to trust the resulting "unique coverage" counts, since a
    poor transform makes genuinely-shared minutiae look unique.

    Closed-form similarity fit (Umeyama): scale from the ratio of RMS radii
    about each centroid, rotation from the mean angular difference, then
    translation from the centroids.
    """
    best_t, best_n = t, count_inliers(a, b, t, dist_tol, angle_tol)[0]
    for _ in range(rounds):
        n, pairs = count_inliers(a, b, best_t, dist_tol, angle_tol)
        if len(pairs) < 3:
            break
        pa = np.array([[a[i].x, a[i].y] for i, _ in pairs], dtype=np.float64)
        pb = np.array([[b[j].x, b[j].y] for _, j in pairs], dtype=np.float64)
        ca, cb = pa.mean(axis=0), pb.mean(axis=0)
        qa, qb = pa - ca, pb - cb
        na = np.sqrt((qa ** 2).sum())
        nb = np.sqrt((qb ** 2).sum())
        if nb < 1e-9:
            break
        scale = float(na / nb)
        if not (0.6 <= scale <= 1.7):
            break
        # Rotation that best aligns qb onto qa (2D Procrustes).
        num = float((qa[:, 1] * qb[:, 0] - qa[:, 0] * qb[:, 1]).sum())
        den = float((qa[:, 0] * qb[:, 0] + qa[:, 1] * qb[:, 1]).sum())
        theta = math.degrees(math.atan2(-num, den))
        th = math.radians(theta)
        c, s = math.cos(th) * scale, math.sin(th) * scale
        dx = float(ca[0] - (c * cb[0] - s * cb[1]))
        dy = float(ca[1] - (s * cb[0] + c * cb[1]))
        cand = Transform(dx, dy, theta % 360, scale)
        cn, _ = count_inliers(a, b, cand, dist_tol, angle_tol)
        if cn <= best_n:
            break
        best_t, best_n = cand, cn
    return best_t, best_n
