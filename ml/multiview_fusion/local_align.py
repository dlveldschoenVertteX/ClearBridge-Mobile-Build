"""Phase 0: local nonlinear deformation correction between an ECC/homography-
prealigned side view and the front anchor, via block-matching + Thin Plate
Spline (TPS) -- the technique real "fingerprint mosaicking for small-area
sensors" literature uses (Bazen & Gerez; block-correspondence TPS mosaicking)
and this project has never tried. The prior small-roll attempt only ever
fit a single GLOBAL homography per side frame (see common.ecc_homography_
align, ported unchanged) -- a single global transform cannot capture how
non-planar, elastic skin deforms differently region-to-region between shots.
This module isolates that ONE variable: local correspondence + TPS warp,
inserted between the existing coarse alignment and the existing (unchanged)
blend.

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

from typing import List, Optional, Tuple

import cv2
import numpy as np

from common import block_coherence

_GRID_STEP = 24        # control-point grid spacing (px) in the overlap region
_PATCH = 24            # template patch half-independent size for matchTemplate
_SEARCH_RADIUS = 20    # local search radius (px) around the pre-aligned position
_MIN_COHERENCE = 0.35  # skip flat/background points -- no reliable ridge signal
_MIN_NCC = 0.35        # matchTemplate confidence gate
_MIN_CONTROL_POINTS = 12  # below this, TPS is underdetermined/unreliable -- skip
_EDGE_CLAMP_PX = 2     # reject matches within this many px of the search window's
                       # edge -- Phase 0 measurement found ~1/4-1/3 of raw matches
                       # land exactly at the window corner (dist == sqrt(2)*radius,
                       # clustered at the four diagonal corners), a matchTemplate
                       # boundary artifact (the true correspondence lies outside the
                       # window, or the window aliases onto an adjacent ridge cycle),
                       # not a real local deformation -- these corrupt the TPS solve
                       # rather than correct it, so they're filtered before fitting.
_NEIGHBOR_RADIUS_PX = 60   # for the neighbor-consistency outlier filter
_NEIGHBOR_MAX_DEV_PX = 10  # reject a point whose displacement deviates from its
                           # local neighbors' median displacement by more than this
                           # -- real elastic skin deformation varies smoothly point
                           # to point; an isolated point jumping far from its
                           # neighbors' consensus is far more likely a mismatch than
                           # genuine local deformation.
_MIN_NEIGHBORS = 3


def find_local_correspondences(front: np.ndarray, side_registered: np.ndarray
                                ) -> Tuple[np.ndarray, np.ndarray]:
    """Grid-sample the overlap region, block-match each point from
    side_registered against a small search window in front, keep only
    coherent, high-confidence matches. Returns (src_pts, dst_pts) as Nx2
    float32 arrays in (x, y) order -- src = side_registered's own grid
    point, dst = where that content actually is in front -- ready for
    cv2.createThinPlateSplineShapeTransformer.estimateTransformation.
    """
    h, w = front.shape[:2]
    coh_side = block_coherence(side_registered)
    src_pts: List[Tuple[float, float]] = []
    dst_pts: List[Tuple[float, float]] = []

    y0 = _PATCH + _SEARCH_RADIUS
    y1 = h - _PATCH - _SEARCH_RADIUS
    x0 = _PATCH + _SEARCH_RADIUS
    x1 = w - _PATCH - _SEARCH_RADIUS
    for gy in range(y0, max(y0, y1), _GRID_STEP):
        for gx in range(x0, max(x0, x1), _GRID_STEP):
            if coh_side[gy, gx] < _MIN_COHERENCE:
                continue
            # Also require the corresponding front region to have real ridge
            # structure -- a coherent side patch matched into flat front skin
            # (or vice versa) is not a trustworthy control point.
            if side_registered[gy, gx] == 0:
                continue  # outside the warped side frame's valid region

            template = side_registered[gy - _PATCH:gy + _PATCH, gx - _PATCH:gx + _PATCH]
            search = front[gy - _PATCH - _SEARCH_RADIUS:gy + _PATCH + _SEARCH_RADIUS,
                            gx - _PATCH - _SEARCH_RADIUS:gx + _PATCH + _SEARCH_RADIUS]
            if template.shape[0] < 2 * _PATCH or search.shape[0] < 2 * _PATCH:
                continue
            res = cv2.matchTemplate(search, template, cv2.TM_CCOEFF_NORMED)
            _, max_val, _, max_loc = cv2.minMaxLoc(res)
            if max_val < _MIN_NCC:
                continue
            # res is (2*_SEARCH_RADIUS+1) square; max_loc == (0,0) or the far
            # edge means the reported "best" match sits AT the search window's
            # boundary -- the true correspondence may lie outside the window
            # (or matchTemplate aliased onto an adjacent ridge cycle), not a
            # trustworthy local match. Reject rather than feed it to the TPS
            # solve (see _EDGE_CLAMP_PX docstring above).
            res_h, res_w = res.shape[:2]
            if (max_loc[0] < _EDGE_CLAMP_PX or max_loc[0] > res_w - 1 - _EDGE_CLAMP_PX
                    or max_loc[1] < _EDGE_CLAMP_PX or max_loc[1] > res_h - 1 - _EDGE_CLAMP_PX):
                continue
            # max_loc is the top-left of the best match inside `search`;
            # convert back to a full-image (front) coordinate for the
            # matched centre.
            fx = (gx - _PATCH - _SEARCH_RADIUS) + max_loc[0] + _PATCH
            fy = (gy - _PATCH - _SEARCH_RADIUS) + max_loc[1] + _PATCH
            src_pts.append((float(gx), float(gy)))
            dst_pts.append((float(fx), float(fy)))

    src_arr = np.array(src_pts, dtype=np.float32)
    dst_arr = np.array(dst_pts, dtype=np.float32)
    return _reject_neighbor_outliers(src_arr, dst_arr)


def _reject_neighbor_outliers(src_pts: np.ndarray, dst_pts: np.ndarray
                               ) -> Tuple[np.ndarray, np.ndarray]:
    """Real elastic skin deformation varies smoothly point to point -- a
    control point whose displacement disagrees sharply with its nearby
    neighbors' consensus is far more likely a mismatched patch (periodic
    ridge texture confusing NCC) than genuine local deformation. Reject any
    point whose displacement vector deviates from the median displacement of
    its own spatial neighborhood by more than _NEIGHBOR_MAX_DEV_PX. Points
    with too few neighbors to judge are kept as-is (not enough evidence to
    reject)."""
    n = len(src_pts)
    if n < _MIN_NEIGHBORS + 1:
        return src_pts, dst_pts
    disp = dst_pts - src_pts
    keep = np.ones(n, dtype=bool)
    for i in range(n):
        d = np.linalg.norm(src_pts - src_pts[i], axis=1)
        neighbor_idx = np.where((d > 0) & (d <= _NEIGHBOR_RADIUS_PX))[0]
        if len(neighbor_idx) < _MIN_NEIGHBORS:
            continue
        local_median = np.median(disp[neighbor_idx], axis=0)
        if np.linalg.norm(disp[i] - local_median) > _NEIGHBOR_MAX_DEV_PX:
            keep[i] = False
    return src_pts[keep], dst_pts[keep]


def tps_correct(front: np.ndarray, side_registered: np.ndarray
                 ) -> Optional[Tuple[np.ndarray, dict]]:
    """Fit a TPS transform from side_registered's own grid points to where
    that content actually matches in front, then warp side_registered
    through it. Returns (locally-corrected side image, diagnostics) or None
    if too few reliable control points were found (falls back to the
    ECC-only registration -- can only ever help, never regress, same
    discipline as every other variant in this project)."""
    src_pts, dst_pts = find_local_correspondences(front, side_registered)
    n = len(src_pts)
    diag = {'n_control_points': n}
    if n < _MIN_CONTROL_POINTS:
        return None

    # Guard against a degenerate/near-identity correspondence set (e.g. all
    # points on one line) which can make the TPS solve unstable.
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
