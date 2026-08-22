"""PHASE 1 -- classical consensus minutiae fusion. No ML.

Gated on Phase 0/0b/0c all showing the same result: non-anchor sources
contribute real, non-spurious minutiae (corroborated + unique_new_coverage
dominate over unique_in_overlap) -- see fusion_brain/README.md's phase
table. This is the actual fusion step that plan was building toward.

RULE-BASED, three parts:

1. Per-source RELIABILITY GATE, before any minutia is considered at all.
   Phase 0c's own real data is why this exists: one real source (a sweep
   station whose raw frame turned out to be a badly motion-blurred,
   off-guide shot -- confirmed by eye, not inferred) registered with only
   14% inliers (37/258) and visibly did not look like a real print, while
   every other source that round registered at 21-30% and looked genuinely
   coherent. A source this poorly explained by the anchor's own geometry is
   more likely contributing NOISE than new coverage, and gets excluded
   entirely rather than blended in. This is the classical, explainable
   stand-in for what Phase 2's learned reliability model would eventually
   do with real training labels -- Phase 1 doesn't have those yet, so it
   uses the one signal already in hand: how well registration explains the
   source's own detected minutiae.

2. Per-minutia CLASSIFICATION (reusing Phase 0's own already-validated
   corroborated / unique_in_overlap / unique_new_coverage logic verbatim,
   not reinvented here).

3. FUSION RULE: keep the anchor's own minutiae untouched (it is the
   trusted base -- production's current single-best-candidate result is
   exactly this, alone). From each source that passed the reliability
   gate, add ONLY its unique_new_coverage minutiae -- genuine territory the
   anchor doesn't have. Drop unique_in_overlap (unmatched where another
   source COULD have corroborated it and didn't -- most likely spurious).
   Drop corroborated-with-a-non-anchor-source too: by construction that
   minutia already has a near-duplicate already included (from whichever
   source corroborated it), so re-adding it would just be a near-duplicate
   point, not new signal -- deliberately conservative for a first classical
   pass, not an attempt to also recover "anchor missed, two others agree"
   cases (a real, subtler category, left for Phase 2/3 once there's a
   reliable ground truth to validate it against).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

import registration as reg
from minutiae_io import Minutia


@dataclass
class SourceReliability:
    name: str
    inliers: int
    total: int
    inlier_frac: float
    passed: bool


def gate_sources(
    minu: Dict[str, List[Minutia]],
    transforms: Dict[str, reg.Transform],
    anchor: str,
    min_inlier_frac: float = 0.20,
    min_inlier_count: int = 15,
    dist_tol: float = 12.0,
    angle_tol: float = 25.0,
) -> Dict[str, SourceReliability]:
    """One reliability verdict per non-anchor, registered source."""
    a_minu = minu[anchor]
    out: Dict[str, SourceReliability] = {}
    for name, t in transforms.items():
        n, _ = reg.count_inliers(a_minu, minu[name], t, dist_tol, angle_tol)
        total = len(minu[name])
        frac = n / total if total else 0.0
        passed = n >= min_inlier_count and frac >= min_inlier_frac
        out[name] = SourceReliability(name, n, total, frac, passed)
    return out


def classify(
    reg_minu: Dict[str, List[Minutia]],
    cov: Dict[str, np.ndarray],
    dist_tol: float = 12.0,
    angle_tol: float = 25.0,
) -> Dict[str, List[Tuple[Minutia, str]]]:
    """Per source, each minutia tagged 'corroborated' / 'unique_in_overlap'
    / 'unique_new_coverage' -- identical rule to phase0_premise_check.py /
    phase0c_real_fusion_capture.py, factored out here so Phase 1 uses the
    exact same definition those two already validated, not a fresh copy."""
    result: Dict[str, List[Tuple[Minutia, str]]] = {}
    for name, ms in reg_minu.items():
        others = [o for o in reg_minu if o != name]
        tagged: List[Tuple[Minutia, str]] = []
        for m in ms:
            hit = False
            for o in others:
                for mo in reg_minu[o]:
                    if (abs(mo.x - m.x) < dist_tol and abs(mo.y - m.y) < dist_tol
                            and reg._angle_diff(mo.theta, m.theta) <= angle_tol
                            and np.hypot(mo.x - m.x, mo.y - m.y) < dist_tol):
                        hit = True
                        break
                if hit:
                    break
            if hit:
                tagged.append((m, 'corroborated'))
                continue
            xi, yi = int(round(m.x)), int(round(m.y))
            covered_elsewhere = False
            for o in others:
                c = cov.get(o)
                if c is None:
                    continue
                if 0 <= yi < c.shape[0] and 0 <= xi < c.shape[1] and c[yi, xi]:
                    covered_elsewhere = True
                    break
            tagged.append((m, 'unique_in_overlap' if covered_elsewhere else 'unique_new_coverage'))
        result[name] = tagged
    return result


def fuse(
    minu: Dict[str, List[Minutia]],
    reg_minu: Dict[str, List[Minutia]],
    cov: Dict[str, np.ndarray],
    transforms: Dict[str, reg.Transform],
    anchor: str,
    min_inlier_frac: float = 0.20,
    min_inlier_count: int = 15,
) -> Tuple[List[Minutia], Dict[str, SourceReliability], Dict[str, int]]:
    """Returns (fused minutiae in anchor space, per-source reliability
    verdicts, per-source count of minutiae actually contributed)."""
    reliability = gate_sources(minu, transforms, anchor,
                               min_inlier_frac, min_inlier_count)
    tags = classify(reg_minu, cov)

    fused: List[Minutia] = list(reg_minu[anchor])   # anchor is always kept whole
    contributed: Dict[str, int] = {}
    for name, verdict in reliability.items():
        if not verdict.passed:
            contributed[name] = 0
            continue
        added = [m for m, tag in tags[name] if tag == 'unique_new_coverage']
        fused.extend(added)
        contributed[name] = len(added)
    return fused, reliability, contributed
