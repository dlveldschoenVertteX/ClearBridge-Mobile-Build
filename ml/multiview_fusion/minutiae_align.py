"""Minutiae-based correspondence for local TPS alignment -- Phase 0 follow-up.

`local_align.py`'s first attempt used dense NCC block-matching for
correspondence and this project measured it fails on periodic ridge texture
(see README.md, "Phase 0 result (2026-07-22)"): median match displacement
scales almost linearly with search-window size (7.8/12.2/16.6/22.8px at
R=6/10/14/20) while NCC confidence stays flat (~0.57-0.60) regardless of
window size, and <2% of matches land near the already-good ECC-predicted
position at ANY radius tested -- the correlation surface has one near-equal
peak per ridge cycle, so a generic image-patch correlator can't localize.

Minutiae (ridge endings/bifurcations) are sparse, discrete, structurally
distinctive points identified by NBIS mindtct's own specialized ridge-flow
analysis, not a generic patch correlator -- they are the whole reason
fingerprint matching (bozorth3, SourceAFIS) works at all despite ridge
periodicity, so this is a genuinely different correspondence method, not a
retuned version of the one that already failed.

Requires mindtct itself preprocessed through this project's own tuned
Gabor+binarize chain first (`common.gabor_binarize`) -- mindtct finds ZERO
minutiae on a raw, unenhanced fingerphoto (confirmed empirically: 0 on
`3edf5455/front.png` directly, 406 after `gabor_binarize`). This mirrors
why every real mindtct/bozorth3 measurement elsewhere in this project has
always run against the enhanced/binarized AFIS print, never a raw capture.

Requires a local mindtct binary -- NBIS is vendored as C source in
`functions/nfiq2_service/vendor/nbis/mindtct/` (build via that directory's
own Makefile / `../setup.sh`); point the `MINDTCT_BIN` env var at a built
binary. This module never bundles a binary and never calls the deployed
HTTP sidecar (`mindtct_client.py`'s job, which talks to the Cloud Run
service) -- it is local research tooling only, same
self-contained-port convention as the rest of `ml/multiview_fusion/`.

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
from typing import List, Optional, Tuple

import cv2
import numpy as np

from common import gabor_binarize

_MATCH_RADIUS_PX = 30      # max distance (px) to pair a front/side minutia --
                           # generous vs. local_align's 14px block-match
                           # radius since minutiae are sparse (only ~400 per
                           # pad vs. a dense grid), so there's no nearby
                           # false-positive alternative to accidentally lock
                           # onto the way a periodic ridge patch would.
_MATCH_ANGLE_DEG = 35      # max ridge-angle disagreement (degrees) to accept
                           # a pairing -- a real corresponding minutia should
                           # agree in BOTH position and ridge direction; a
                           # generic block-match never had this second axis.
_MIN_CONTROL_POINTS = 8    # below this, TPS is underdetermined -- fall back
                           # to ECC-only (lower than local_align's 12 since
                           # minutiae are naturally sparser than a dense grid).


def _mindtct_bin() -> str:
    path = os.environ.get('MINDTCT_BIN', '')
    if not path or not os.path.isfile(path):
        raise RuntimeError(
            'Set MINDTCT_BIN to a local mindtct binary path (build from '
            'functions/nfiq2_service/vendor/nbis/mindtct/ via that '
            "directory's own Makefile / setup.sh, or reuse a copy already "
            'built earlier this project).')
    return path


def extract_minutiae(gray_binarized: np.ndarray) -> np.ndarray:
    """Run mindtct -m1 on an already Gabor-enhanced/binarized ridge image
    (see module docstring -- NOT a raw fingerphoto). Returns an Nx4 float32
    array of (x, y, theta_deg, quality), x/y in the SAME pixel coordinate
    space as the input image (confirmed empirically against the .min
    human-readable output -- no axis flip needed)."""
    binp = _mindtct_bin()
    with tempfile.TemporaryDirectory() as td:
        img_path = os.path.join(td, 'in.png')
        cv2.imwrite(img_path, gray_binarized)
        oroot = os.path.join(td, 'out')
        subprocess.run([binp, '-m1', img_path, oroot],
                        check=True, capture_output=True, timeout=30)
        xyt_path = oroot + '.xyt'
        pts: List[Tuple[float, float, float, float]] = []
        if os.path.isfile(xyt_path):
            with open(xyt_path) as f:
                for line in f:
                    parts = line.split()
                    if len(parts) < 4:
                        continue
                    x, y, theta, q = parts[:4]
                    pts.append((float(x), float(y), float(theta), float(q)))
    if not pts:
        return np.zeros((0, 4), dtype=np.float32)
    return np.array(pts, dtype=np.float32)


def find_minutiae_correspondences(front: np.ndarray, side_registered: np.ndarray
                                   ) -> Tuple[np.ndarray, np.ndarray]:
    """Extract minutiae from the front anchor and the ECC-registered side
    frame (each Gabor-binarized first, side gray-filled outside its valid
    warpPerspective region so the black->white border doesn't manufacture
    spurious edge minutiae), then correspond by greedy nearest-neighbor
    gated on BOTH position and ridge-angle agreement. Returns (src_pts,
    dst_pts) Nx2 float32 in (x, y) order -- same contract as
    local_align.find_local_correspondences (src = side's own point, dst =
    where that same ridge feature actually is in front)."""
    front_bin = gabor_binarize(front)
    side_mask = (side_registered > 0).astype(np.uint8) * 255
    side_bin = gabor_binarize(side_registered, mask=side_mask)

    m_front = extract_minutiae(front_bin)
    m_side = extract_minutiae(side_bin)
    if len(m_front) == 0 or len(m_side) == 0:
        return np.zeros((0, 2), np.float32), np.zeros((0, 2), np.float32)

    src_pts: List[Tuple[float, float]] = []
    dst_pts: List[Tuple[float, float]] = []
    used_front = set()
    for sx, sy, sth, _sq in m_side:
        best_j = -1
        best_d = _MATCH_RADIUS_PX
        for j in range(len(m_front)):
            if j in used_front:
                continue
            fx, fy, fth, _fq = m_front[j]
            d = float(np.hypot(sx - fx, sy - fy))
            if d > best_d:
                continue
            ang_diff = abs(((sth - fth) + 180.0) % 360.0 - 180.0)
            if ang_diff > _MATCH_ANGLE_DEG:
                continue
            best_d = d
            best_j = j
        if best_j >= 0:
            used_front.add(best_j)
            src_pts.append((float(sx), float(sy)))
            dst_pts.append((float(m_front[best_j][0]), float(m_front[best_j][1])))

    return (np.array(src_pts, dtype=np.float32),
            np.array(dst_pts, dtype=np.float32))


def tps_correct_minutiae(front: np.ndarray, side_registered: np.ndarray
                          ) -> Optional[Tuple[np.ndarray, dict]]:
    """Same contract as local_align.tps_correct, but sourced from minutiae
    correspondences instead of dense NCC block-matching. Returns
    (locally-corrected side image, diagnostics) or None if too few reliable
    minutiae pairs were found (falls back to ECC-only -- can only ever help,
    never regress, same discipline as every other variant in this project)."""
    src_pts, dst_pts = find_minutiae_correspondences(front, side_registered)
    n = len(src_pts)
    diag = {'n_control_points': n, 'method': 'minutiae'}
    if n < _MIN_CONTROL_POINTS:
        return None

    disp = dst_pts - src_pts
    diag['mean_disp_px'] = float(np.mean(np.linalg.norm(disp, axis=1)))
    diag['max_disp_px'] = float(np.max(np.linalg.norm(disp, axis=1)))

    tps = cv2.createThinPlateSplineShapeTransformer()
    matches = [cv2.DMatch(i, i, 0) for i in range(n)]
    src_shape = src_pts.reshape(1, -1, 2)
    dst_shape = dst_pts.reshape(1, -1, 2)
    try:
        tps.estimateTransformation(dst_shape, src_shape, matches)
        warped = tps.warpImage(side_registered)
    except cv2.error as e:
        diag['error'] = str(e)
        return None
    return warped, diag
