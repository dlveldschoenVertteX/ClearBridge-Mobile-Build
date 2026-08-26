"""PHASE 3g -- A/B the footprint-vs-ink coverage fix, one variable only.

Real bug found 2026-08-26 by tracing a visible artifact rather than
guessing (see `_footprint`'s own docstring in
phase0c_real_fusion_capture.py, and diag_source_attribution.py which
produced the evidence): every consumer of `_coverage()` in this track
asks "what territory does this source cover", but `_coverage()` answers
"where is this print's ink". On a real anchor those differ by 2x --
measured 58,556 ink px inside a 117,015 px footprint, so 50.0% of the
anchor's own print (its ridge valleys) reads as uncovered territory.

Two real consequences, both fixed by the same change:
  1. `1 - anchor_coverage` lets a source composite INTO the anchor's own
     ridge valleys -> locally doubled ridge density -> the thick/tangled
     "smudge" patches reported on capture 5181d451.
  2. `fuse_minutiae.classify()` mis-tags candidates sitting in another
     source's valley as `unique_new_coverage` (genuine new territory)
     when that territory is fully imaged -> an inflated candidate pool
     for the selective merge to draw from.

This runs phase3f's exact pipeline twice -- once with ink coverage
(status quo), once with footprint coverage -- changing NOTHING else, and
scores both against the same real references. Anything that moves is
attributable to this one fix.

Honest note on what a "win" means here: consequence 2 means the fix
changes WHICH minutiae are eligible to merge, so the composite is
legitimately a different template, not just a cleaner picture. A lower
score would not necessarily mean the fix is wrong -- it could mean the
old score was partly built on candidates that were never really new
coverage. Report both numbers and the candidate counts, and say which.

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
    _db, collect_sources, _render, _coverage, _footprint, _warp_coverage,
    DIST_TOL, ANGLE_TOL, CACHE,
)
from phase1_consensus_fusion import _normalized_ink_xyt   # noqa: E402
from phase2_tps_fusion import _ref_xyt, _best_score, MACRO_REFS  # noqa: E402
from phase3_composite import _rigid_matrix, _coherence, KEEP_RADIUS_PX, DEFAULT_MAX_ADDED  # noqa: E402
from phase3c_continuous_blend import BLUR_SIGMA  # noqa: E402
from phase3f_validated_merge import (          # noqa: E402
    _bridge_mask, _unvalidated_xy, _validated_xy, MAX_BRIDGE_PX,
)
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)


def _build(prints: Dict[str, np.ndarray], anchor: str, max_added: int,
           cov_fn, tag: str, cap_id: str) -> Tuple[np.ndarray, dict]:
    """One full composite under the given coverage function."""
    minu = {n: mio.extract_minutiae(p, source=n) for n, p in prints.items()}
    a_minu, a_img = minu[anchor], prints[anchor]
    a_shape = a_img.shape[:2]
    a_cov = cov_fn(a_img)
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
        cov[name] = _warp_coverage(cov_fn(prints[name]), t, a_shape)
        warp, _ = tps.fit_from_correspondences(
            a_minu, rigid, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if warp is None:
            tps_minu[name] = rigid
            continue
        warps[name] = warp
        tps_minu[name] = warp.apply_minutiae(rigid)

    # Candidate-pool size BEFORE the cap -- the number consequence 2 moves.
    tags = fm.classify(tps_minu, cov)
    pool = sum(1 for nm, tl in tags.items() if nm != anchor
               for _, tg in tl if tg == 'unique_new_coverage')

    fused, _, contributed = fm.fuse(
        minu, tps_minu, cov, transforms, anchor, max_added=max_added)

    tex = [a_soft.astype(np.float64)]
    wts = [a_cov.astype(np.float64)]
    inside = 0
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
            (cov_fn(prints[name]) * 255).astype(np.uint8), M,
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
        keep, _, _ = _bridge_mask(validated, unval, a_shape, KEEP_RADIUS_PX,
                                  MAX_BRIDGE_PX, feather=0.0,
                                  clearance=KEEP_RADIUS_PX)
        w = avail * keep * coh
        if w.max() <= 0:
            continue
        # How much of this source's region lands INSIDE the anchor's own
        # print footprint -- the direct measure of the smudge mechanism.
        inside += int(((w > 1e-6) & (_footprint(a_img) > 0)).sum())
        tex.append(warped_img.astype(np.float64))
        wts.append(w)

    blended, total_w = _multiband_combine(tex, wts, num_bands=5)
    comp = np.where(np.where(total_w > 0, blended, 255.0) < 127, 0, 255).astype(np.uint8)
    path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.png')
    cv2.imwrite(path, comp)
    return comp, {'candidate_pool': pool, 'added': len(fused) - len(a_minu),
                  'inside_anchor_px': inside, 'path': path,
                  'contributed': {k: int(v) for k, v in contributed.items() if v}}


def run(cap_id: str, max_added: int = DEFAULT_MAX_ADDED) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== footprint-vs-ink coverage A/B -- {cap_id[:12]} '
          f'(max_added={max_added}) ===')
    srcs = collect_sources(v)
    prints = {}
    for name, (img, guide) in srcs.items():
        p = _render(img, guide, f'{cap_id[:12]}_{name}')
        if p is not None:
            prints[name] = p
    if 'front_v1' not in prints:
        print('  no anchor, stopping')
        return None

    arms = {}
    for tag, fn in (('ink', _coverage), ('footprint', _footprint)):
        print(f'\n  --- {tag} coverage ---')
        _, info = _build(prints, 'front_v1', max_added, fn, f'cov_{tag}', cap_id)
        print(f'    new-coverage candidate pool : {info["candidate_pool"]}')
        print(f'    minutiae added              : {info["added"]}')
        print(f'    source px INSIDE anchor print: {info["inside_anchor_px"]}')
        print(f'    contributed                 : {info["contributed"]}')
        arms[tag] = info

    a_img = prints['front_v1']
    anchor_xyt = os.path.join(CACHE, f'{cap_id[:12]}_anchor_alone_stage3.xyt')
    mio.write_xyt(mio.extract_minutiae(a_img, source='anchor'), anchor_xyt)

    refs: Dict[str, str] = {}
    ink_ref = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))
    if ink_ref:
        refs['ink_scan'] = ink_ref
    for rn, rp in MACRO_REFS.items():
        r = _ref_xyt(rn, rp)
        if r:
            refs[rn] = r

    scores = {'anchor_alone': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt, rx)
    for tag in arms:
        xyt = os.path.join(CACHE, f'{cap_id[:12]}_cov_{tag}.xyt')
        mio.write_xyt(mio.extract_minutiae(
            cv2.imread(arms[tag]['path'], cv2.IMREAD_GRAYSCALE),
            source='composite'), xyt)
        scores[tag] = {rn: _best_score(xyt, rx) for rn, rx in refs.items()}

    print('\n  bozorth3 (higher = better match):')
    print('  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs))
    for cn in ('anchor_alone', 'ink', 'footprint'):
        row = '  ' + f'{cn:16}'
        for rn in refs:
            row += f'{str(scores[cn][rn]):>16}'
        print(row)

    print('\n  VERDICT (informative references only):')
    for cn in ('ink', 'footprint'):
        beat = sum(1 for rn in refs if rn != 'ink_scan'
                   and scores[cn][rn] is not None
                   and scores['anchor_alone'][rn] is not None
                   and scores[cn][rn] > scores['anchor_alone'][rn])
        n = sum(1 for rn in refs if rn != 'ink_scan')
        print(f'    {cn:10} beats anchor on {beat}/{n}')

    result = {'capture': cap_id, 'max_added': max_added,
              'arms': arms, 'scores': scores}
    out = os.path.join(HERE, 'results', f'phase3g_footprint_{cap_id[:8]}.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase3g_footprint_coverage.py <captureId> [max_added]')
        sys.exit(1)
    run(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 15)
