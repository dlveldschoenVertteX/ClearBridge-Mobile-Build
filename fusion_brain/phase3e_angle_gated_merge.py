"""STAGE C follow-up #4 -- angle-gated region merging, plus the control
phase3d should have run and didn't.

TWO things are being fixed here, and they are deliberately separated so
the result is attributable:

1. **A real flaw in phase3d's own test design.** phase3c built the keep
   mask PER SOURCE (`[m for m in fused if m.source == name]`), so each
   source only ever contributed pixels near ITS OWN kept points.
   phase3d replaced that with ONE GLOBAL mask over every source's kept
   points, applied to every source -- so each source additionally
   contributed wherever its coverage happened to overlap some OTHER
   source's points. That is a much larger change than "merge nearby
   discs," and it manufactures precisely the multi-source overlap
   phase3d's own findings then blamed the regression on. Two variables
   moved at once; the conclusion drawn there ("merging removes the
   isolation protection") is therefore NOT established by that test.
   `merge_scope='per_source'` here restores phase3c's per-source
   masking and merges only within each source -- the honest control
   isolating merging alone.

2. **The angle gate itself**, the actual proposed fix: where two or more
   sources' contribution regions overlap, compare their local ridge
   ORIENTATION (production `afis_print._orientation_field`, read-only
   import, the same estimator the real pipeline uses) and suppress the
   lower-coherence source wherever they disagree beyond a threshold.
   Orientation is a direction mod pi, so disagreement is measured as
   |sin(theta_a - theta_b)| -- 0 when parallel (diff 0 or pi), 1 when
   perpendicular -- which handles the wrap correctly without special
   cases.

Real diagnostics are printed either way (how much area is actually
multi-source, how much the gate actually suppresses) so the mechanism is
measured rather than inferred from the score alone -- the specific gap
that made phase3d's conclusion unsafe.

ANGLE_TOL_SIN and CLOSE_RADIUS_PX are first-cut reasoned values, NOT
swept against real data. Report accordingly.

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
from phase1_consensus_fusion import _normalized_ink_xyt   # noqa: E402
from phase2_tps_fusion import _ref_xyt, _best_score, MACRO_REFS  # noqa: E402
from phase3_composite import _rigid_matrix, _coherence, KEEP_RADIUS_PX, DEFAULT_MAX_ADDED  # noqa: E402
from phase3c_continuous_blend import BLUR_SIGMA  # noqa: E402
from phase3d_merged_regions import _keep_mask_merged, CLOSE_RADIUS_PX  # noqa: E402
from afis_print import _orientation_field      # noqa: E402  (production, read-only)
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

# |sin(dtheta)| above which two sources are treated as disagreeing about
# ridge direction at a shared pixel. 0.35 ~= 20.5 degrees. First-cut
# reasoned value: comfortably inside "same ridge, slight residual
# misregistration" territory, well short of the ~45-90 degrees that
# produces the crossing/blocking artifact phase3d showed. NOT swept.
ANGLE_TOL_SIN = 0.35


def _ridge_angle(img: np.ndarray) -> np.ndarray:
    """Local ridge direction (radians, mod pi) via the production estimator."""
    return _orientation_field(img.astype(np.float32))


def run(cap_id: str, max_added: int = DEFAULT_MAX_ADDED,
        blur_sigma: float = BLUR_SIGMA,
        close_radius: float = CLOSE_RADIUS_PX,
        merge_scope: str = 'per_source',
        angle_gate: bool = True,
        angle_tol_sin: float = ANGLE_TOL_SIN,
        tag: str = 'anglegate') -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== Stage C+angle-gated merge -- {cap_id[:12]} '
          f'(max_added={max_added}, blur_sigma={blur_sigma}, '
          f'close_radius={close_radius}, scope={merge_scope}, '
          f'angle_gate={angle_gate}, tol_sin={angle_tol_sin}) ===')
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
    a_minu = minu[anchor]
    a_img = prints[anchor]
    a_shape = a_img.shape[:2]
    a_cov = _coverage(a_img)
    a_soft = cv2.GaussianBlur(a_img, (0, 0), blur_sigma)

    # ---- Rigid registration + TPS refinement, identical to Stage A/C ----
    transforms: Dict[str, reg.Transform] = {}
    rigid_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    cov: Dict[str, np.ndarray] = {anchor: a_cov}
    warps: Dict[str, tps.TpsWarp] = {}
    tps_minu: Dict[str, List[Minutia]] = {anchor: a_minu}

    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            continue
        transforms[name] = t
        rigid_minu[name] = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)
        warp, n_ctrl = tps.fit_from_correspondences(
            a_minu, rigid_minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if warp is None:
            tps_minu[name] = rigid_minu[name]
            continue
        warps[name] = warp
        tps_minu[name] = warp.apply_minutiae(rigid_minu[name])

    fused, reliability, contributed = fm.fuse(
        minu, tps_minu, cov, transforms, anchor, max_added=max_added)
    print(f'\n  anchor alone : {len(a_minu):4} minutiae')
    print(f'  composite    : {len(fused):4} minutiae (+{len(fused) - len(a_minu)})')

    inv_a_cov = 1.0 - a_cov.astype(np.float64)

    global_keep = None
    if merge_scope == 'global':
        all_pts = [(m.x, m.y) for m in fused if m.source != anchor]
        global_keep = _keep_mask_merged(all_pts, a_shape, close_radius=close_radius)

    # ---- Per-source warp + weight, collected before any gating ----
    entries: List[dict] = []
    for name, warp in warps.items():
        if contributed.get(name, 0) == 0:
            continue
        M = _rigid_matrix(transforms[name])
        soft_src = cv2.GaussianBlur(prints[name], (0, 0), blur_sigma)
        rigid_img = cv2.warpAffine(
            soft_src, M, (a_shape[1], a_shape[0]),
            flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        warped_img = tps.warp_image(warp, rigid_img, a_shape)

        rigid_cov = cv2.warpAffine(
            (_coverage(prints[name]) * 255).astype(np.uint8), M,
            (a_shape[1], a_shape[0]), flags=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        warped_cov = (tps.warp_image(warp, rigid_cov, a_shape) > 127).astype(np.float64)

        raw_rigid = cv2.warpAffine(
            prints[name], M, (a_shape[1], a_shape[0]),
            flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        raw_warped = tps.warp_image(warp, raw_rigid, a_shape)
        coh = np.clip(_coherence(raw_warped), 0.0, 1.0)

        if merge_scope == 'global':
            keep = global_keep
        else:
            own_pts = [(m.x, m.y) for m in fused if m.source == name]
            keep = _keep_mask_merged(own_pts, a_shape, close_radius=close_radius)

        w = warped_cov * keep * coh * inv_a_cov
        if w.max() <= 0:
            continue
        entries.append({'name': name, 'img': warped_img.astype(np.float64),
                        'w': w, 'coh': coh, 'ang': _ridge_angle(raw_warped),
                        'n_kept': contributed.get(name, 0)})

    # ---- Real diagnostic: how much area is genuinely multi-source? ----
    occ = np.zeros(a_shape, dtype=np.int32)
    for e in entries:
        occ += (e['w'] > 1e-6).astype(np.int32)
    multi = int(np.sum(occ >= 2))
    any_src = int(np.sum(occ >= 1))
    print(f'\n  contribution area: {any_src}px total, '
          f'{multi}px covered by 2+ sources '
          f'({(100.0 * multi / any_src) if any_src else 0:.1f}%)')

    # ---- Angle gate: suppress the lower-coherence source where two
    #      overlapping sources disagree about ridge direction ----
    suppressed = 0
    if angle_gate and len(entries) > 1:
        overlap = occ >= 2
        for i in range(len(entries)):
            for j in range(i + 1, len(entries)):
                ei, ej = entries[i], entries[j]
                both = overlap & (ei['w'] > 1e-6) & (ej['w'] > 1e-6)
                if not both.any():
                    continue
                dis = np.abs(np.sin(ei['ang'] - ej['ang']))
                bad = both & (dis > angle_tol_sin)
                if not bad.any():
                    continue
                # keep whichever source is locally more ridge-coherent
                drop_i = bad & (ei['coh'] < ej['coh'])
                drop_j = bad & ~drop_i
                ei['w'] = np.where(drop_i, 0.0, ei['w'])
                ej['w'] = np.where(drop_j, 0.0, ej['w'])
                suppressed += int(np.sum(bad))
        print(f'  angle gate: suppressed {suppressed}px of disagreeing overlap')

    tex_list: List[np.ndarray] = [a_soft.astype(np.float64)]
    weight_list: List[np.ndarray] = [a_cov.astype(np.float64)]
    for e in entries:
        if e['w'].max() <= 0:
            continue
        tex_list.append(e['img'])
        weight_list.append(e['w'])
        print(f"    {e['name']:16} composited near {e['n_kept']} kept points")

    blended, total_w = _multiband_combine(tex_list, weight_list, num_bands=5)
    blended_gray = np.where(total_w > 0, blended, 255.0)
    composite = np.where(blended_gray < 127, 0, 255).astype(np.uint8)

    out_img_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.png')
    cv2.imwrite(out_img_path, composite)
    print(f'\n  wrote composite image -> {out_img_path}')

    # ---- Score, same real references and harness as every prior phase ----
    comp_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.xyt')
    mio.write_xyt(mio.extract_minutiae(composite, source='composite'), comp_xyt_path)
    anchor_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_anchor_alone_stage3.xyt')
    mio.write_xyt(mio.extract_minutiae(a_img, source='anchor'), anchor_xyt_path)

    refs: Dict[str, str] = {}
    ink = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))
    if ink:
        refs['ink_scan'] = ink
    for rname, rpath in MACRO_REFS.items():
        r = _ref_xyt(rname, rpath)
        if r:
            refs[rname] = r

    scores: Dict[str, Dict[str, Optional[int]]] = {'anchor_alone': {}, 'composite': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt_path, rx)
        scores['composite'][rn] = _best_score(comp_xyt_path, rx)

    print(f'\n  bozorth3 (higher = better match):')
    header = '  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs)
    print(header)
    for cname in ('anchor_alone', 'composite'):
        row = '  ' + f'{cname:16}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    print('\n  VERDICT (per reference):')
    beat, informative = 0, 0
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['composite'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        vv = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} composite {c} {vv} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'composite beats anchor-alone on {beat}.')

    result = {'capture': cap_id, 'max_added': max_added, 'blur_sigma': blur_sigma,
              'close_radius': close_radius, 'merge_scope': merge_scope,
              'angle_gate': angle_gate, 'angle_tol_sin': angle_tol_sin,
              'multi_source_px': multi, 'total_contrib_px': any_src,
              'suppressed_px': suppressed, 'scores': scores,
              'composite_image_path': out_img_path}
    out = os.path.join(HERE, 'results', f'phase3e_{tag}.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase3e_angle_gated_merge.py <captureId> '
              '[max_added] [close_radius] [scope:per_source|global] '
              '[gate:1|0] [tol_sin] [tag]')
        sys.exit(1)
    cap = sys.argv[1]
    ma = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_ADDED
    cr = float(sys.argv[3]) if len(sys.argv) > 3 else CLOSE_RADIUS_PX
    sc = sys.argv[4] if len(sys.argv) > 4 else 'per_source'
    gt = (sys.argv[5] != '0') if len(sys.argv) > 5 else True
    tl = float(sys.argv[6]) if len(sys.argv) > 6 else ANGLE_TOL_SIN
    tg = sys.argv[7] if len(sys.argv) > 7 else 'anglegate'
    run(cap, ma, BLUR_SIGMA, cr, sc, gt, tl, tg)
