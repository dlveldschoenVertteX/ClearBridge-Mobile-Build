"""DIAGNOSTIC -- attribute every composited region back to the SOURCE that
produced it, so a visible artifact can be traced rather than guessed at.

Direct follow-up to a real CTO observation on capture 5181d451 (the
sunlight capture): the composite shows a couple of noticeably denser,
smudged patches (right-centre and lower-right) where ridge lines go thick
and tangled instead of staying clean single strokes. Nothing in this
track's existing output says WHICH source put content there, so the
question could not be answered from the saved artifacts alone.

This re-runs phase3f's exact composite pipeline (same registration, same
fm.fuse selective merge, same validated-bridge keep mask) but instead of
blending everything into one binary print, it emits:

  * a per-source contribution MAP (each source's kept region drawn in its
    own colour over the anchor, so overlaps and locations are visible)
  * one isolated composite PER SOURCE (anchor + that source alone), so a
    specific artifact can be reproduced or ruled out source by source
  * real per-source stats: region area, how much of it overlaps ANOTHER
    source's region, and mean ridge coherence inside it

The overlap number is the one that matters most for the reported
artifact: two sources writing conflicting ridge content into the same
pixels is the mechanism most likely to produce a locally thick/tangled
patch, and phase3e already measured that multi-source overlap is real
(1.8-4.4% of contributed area) even though gating it changed nothing.

Read-only: Firestore/Storage reads, no writes outside fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'functions', 'processEnhanceAndScore'))

import cv2                                     # noqa: E402
import numpy as np                             # noqa: E402

import fuse_minutiae as fm                     # noqa: E402
import minutiae_io as mio                      # noqa: E402
import registration as reg                     # noqa: E402
import tps                                     # noqa: E402
from minutiae_io import Minutia                # noqa: E402
from phase0c_real_fusion_capture import (      # noqa: E402
    _db, collect_sources, _render, _coverage, _warp_coverage,
    DIST_TOL, ANGLE_TOL, CACHE,
)
from phase3_composite import _rigid_matrix, _coherence, KEEP_RADIUS_PX  # noqa: E402
from phase3c_continuous_blend import BLUR_SIGMA  # noqa: E402
from phase3f_validated_merge import (          # noqa: E402
    _bridge_mask, _unvalidated_xy, _validated_xy, MAX_BRIDGE_PX,
)
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

# Distinct BGR colours for the contribution map. Chosen to stay legible
# over black ridge lines on white background.
_COLOURS = [
    (0, 0, 255),      # red
    (0, 200, 0),      # green
    (255, 0, 0),      # blue
    (0, 180, 255),    # orange
    (255, 0, 255),    # magenta
    (200, 200, 0),    # teal
]


def run(cap_id: str, max_added: int = 15) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== source attribution -- {cap_id[:12]} (max_added={max_added}) ===')
    srcs = collect_sources(v)
    prints, minu = {}, {}
    for name, (img, guide) in srcs.items():
        p = _render(img, guide, f'{cap_id[:12]}_{name}')
        if p is None:
            continue
        prints[name] = p
        minu[name] = mio.extract_minutiae(p, source=name)

    anchor = 'front_v1'
    if anchor not in prints:
        print('  no anchor, stopping')
        return None
    a_minu, a_img = minu[anchor], prints[anchor]
    a_shape = a_img.shape[:2]
    a_cov = _coverage(a_img)
    a_soft = cv2.GaussianBlur(a_img, (0, 0), BLUR_SIGMA)
    inv_a_cov = 1.0 - a_cov.astype(np.float64)

    transforms: Dict[str, reg.Transform] = {}
    warps: Dict[str, tps.TpsWarp] = {}
    tps_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    cov: Dict[str, np.ndarray] = {anchor: a_cov}
    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            continue
        transforms[name] = t
        rigid = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)
        warp, _ = tps.fit_from_correspondences(
            a_minu, rigid, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if warp is None:
            tps_minu[name] = rigid
            continue
        warps[name] = warp
        tps_minu[name] = warp.apply_minutiae(rigid)

    fused, _, contributed = fm.fuse(
        minu, tps_minu, cov, transforms, anchor, max_added=max_added)

    # ---- Build each contributing source's real weight + texture ----
    entries: List[dict] = []
    for name, warp in warps.items():
        if contributed.get(name, 0) == 0:
            continue
        M = _rigid_matrix(transforms[name])
        soft_src = cv2.GaussianBlur(prints[name], (0, 0), BLUR_SIGMA)
        rigid_img = cv2.warpAffine(
            soft_src, M, (a_shape[1], a_shape[0]), flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        warped_img = tps.warp_image(warp, rigid_img, a_shape)

        rigid_cov = cv2.warpAffine(
            (_coverage(prints[name]) * 255).astype(np.uint8), M,
            (a_shape[1], a_shape[0]), flags=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        warped_cov = (tps.warp_image(warp, rigid_cov, a_shape) > 127).astype(np.float64)

        raw_rigid = cv2.warpAffine(
            prints[name], M, (a_shape[1], a_shape[0]), flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        raw_warped = tps.warp_image(warp, raw_rigid, a_shape)
        coh = np.clip(_coherence(raw_warped), 0.0, 1.0)

        validated = _validated_xy(fused, name)
        avail = warped_cov * inv_a_cov
        unval = _unvalidated_xy(raw_warped, avail, validated, a_shape)
        keep, drawn, rejected = _bridge_mask(
            validated, unval, a_shape, KEEP_RADIUS_PX, MAX_BRIDGE_PX,
            feather=0.0, clearance=KEEP_RADIUS_PX)
        w = avail * keep * coh
        if w.max() <= 0:
            continue
        entries.append({'name': name, 'img': warped_img.astype(np.float64),
                        'w': w, 'coh': coh, 'bridges': drawn,
                        'n_kept': contributed.get(name, 0)})

    if not entries:
        print('  no contributing sources')
        return None

    # ---- Real per-source stats, including cross-source overlap ----
    occ = np.zeros(a_shape, dtype=np.int32)
    for e in entries:
        occ += (e['w'] > 1e-6).astype(np.int32)

    print(f'\n  {"source":16}{"area px":>10}{"overlapped":>12}{"overlap%":>10}'
          f'{"mean coh":>10}{"bridges":>9}{"kept":>6}')
    stats = []
    for e in entries:
        m = e['w'] > 1e-6
        area = int(m.sum())
        over = int((m & (occ >= 2)).sum())
        mc = float(e['coh'][m].mean()) if area else 0.0
        pct = (100.0 * over / area) if area else 0.0
        print(f'  {e["name"]:16}{area:>10}{over:>12}{pct:>9.1f}%{mc:>10.3f}'
              f'{e["bridges"]:>9}{e["n_kept"]:>6}')
        stats.append({'source': e['name'], 'area_px': area,
                      'overlap_px': over, 'overlap_pct': round(pct, 2),
                      'mean_coherence': round(mc, 4),
                      'bridges': e['bridges'], 'kept': e['n_kept']})

    # ---- Contribution map: each source's region in its own colour ----
    canvas = cv2.cvtColor(a_img, cv2.COLOR_GRAY2BGR)
    overlay = canvas.copy()
    for i, e in enumerate(entries):
        colour = _COLOURS[i % len(_COLOURS)]
        m = (e['w'] > 1e-6).astype(np.uint8)
        overlay[m > 0] = colour
        cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(canvas, cnts, -1, colour, 2)
        # Label each region at its own centroid so the map is readable.
        for c in cnts:
            if cv2.contourArea(c) < 150:
                continue
            mm = cv2.moments(c)
            if mm['m00'] <= 0:
                continue
            cx, cy = int(mm['m10'] / mm['m00']), int(mm['m01'] / mm['m00'])
            cv2.putText(canvas, e['name'].replace('sweep_', 's_').replace('tilt_', 't_'),
                        (cx - 28, cy), cv2.FONT_HERSHEY_SIMPLEX, 0.38, colour, 1,
                        cv2.LINE_AA)
    blended_map = cv2.addWeighted(overlay, 0.30, canvas, 0.70, 0)
    # Mark multi-source overlap in solid black-outlined white so it stands out.
    multi = (occ >= 2).astype(np.uint8)
    if multi.any():
        cnts, _ = cv2.findContours(multi, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(blended_map, cnts, -1, (0, 0, 0), 2)
    map_path = os.path.join(CACHE, f'{cap_id[:12]}_attribution_map.png')
    cv2.imwrite(map_path, blended_map)
    print(f'\n  wrote contribution map -> {os.path.basename(map_path)}')
    print(f'  (black outlines = pixels written by 2+ sources: '
          f'{int((occ >= 2).sum())}px)')

    # ---- Isolated composite per source ----
    iso_paths = {}
    for e in entries:
        blended, total_w = _multiband_combine(
            [a_soft.astype(np.float64), e['img']],
            [a_cov.astype(np.float64), e['w']], num_bands=5)
        comp = np.where(np.where(total_w > 0, blended, 255.0) < 127, 0, 255).astype(np.uint8)
        p = os.path.join(CACHE, f'{cap_id[:12]}_iso_{e["name"]}.png')
        cv2.imwrite(p, comp)
        iso_paths[e['name']] = p
        print(f'  wrote isolated composite ({e["name"]}) -> {os.path.basename(p)}')

    result = {'capture': cap_id, 'max_added': max_added, 'stats': stats,
              'multi_source_px': int((occ >= 2).sum()),
              'attribution_map': map_path, 'isolated': iso_paths}
    out = os.path.join(HERE, 'results', f'diag_attribution_{cap_id[:8]}.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 diag_source_attribution.py <captureId> [max_added]')
        sys.exit(1)
    run(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 15)
