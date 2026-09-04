"""STAGE C follow-up #5 -- merge regions, but only fill the corridor where
the ridge content there is SUPPORTED BY THE VALIDATED DATA.

Direct follow-up to the CTO's own read of the phase3e result (2026-08-26):
"if the blob beats the merge, that means it more meaningfully reconstructs
the ridges in the places it should be. there needs to be a merged where
ridges are reconstructed better and according to the data given."

That read is correct, and there is a real measured mechanism behind it.
Counting extracted minutiae on the two saved composites for the same real
capture (`6b43c255`, max_added=15):

| composite                     | minutiae | ink px |
|---|---|---|
| blobs (validated discs only)  |  171     | 56,582 |
| merged (corridors filled)     |  209     | 72,946 |

The selective merge validated exactly **15** added minutiae. Merging
introduced **38 extra** on top -- feature points sitting in corridor
pixels that NO gate in this track ever checked: not `fm.gate_sources`'s
per-source reliability check, not `fm.fuse`'s quality-sorted selective
cap, not the coherence weight (a soft multiplier, not a veto). Stage A's
own random-noise control already established that template DENSITY
itself carries a penalty of comparable size to the real added minutiae
(`results/PHASE2_TPS_FINDINGS.md`, and CLAUDE.md's own summary of it).
So the merged composite pays a density penalty for 38 unvetted points in
order to gain the 15 vetted ones -- which is exactly why it scores worse
while looking better.

**The fix this implies, and what this file builds**: keep the merged,
contiguous REGION (that is what buys visual ridge continuity), but
suppress corridor content that manufactures unvalidated feature points.
Concretely -- extract the warped source's own minutiae inside its merged
region, and for every one that is NOT in the validated fused set (no
counterpart within DIST_TOL), punch a small exclusion disc around it so
that location falls back to background rather than contributing a
feature the fusion logic never endorsed. Smooth ridge flow between
validated points survives; unvetted minutiae do not. That is "ridges
reconstructed according to the data given" made literal.

Deliberately NOT doing the tempting alternative (synthesising ridge
continuation across the corridor via the orientation field + Gabor):
this project has documented repeatedly that Gabor synthesis imposes
plausible ridge structure on nearly any input, and the prime directive
already flags NFIQ2-style "looks print-like" gains as untrustworthy.
Suppressing unsupported content is falsifiable; hallucinating supported-
looking content is not.

EXCLUDE_RADIUS_PX is a first-cut reasoned value, NOT swept. Report
accordingly.

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
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

# Radius of the suppression disc punched around each UNVALIDATED minutia
# found inside a merged region. Deliberately smaller than KEEP_RADIUS_PX
# (24): the goal is to remove the local feature, not to re-open the gap
# the merge just closed. First-cut reasoned value, NOT swept.
EXCLUDE_RADIUS_PX = 14.0

# Softens the suppression disc's own edge so it doesn't itself become a
# hard ridge termination -- the exact failure this whole exercise is
# about. Matches phase3c's soften-before-blend discipline.
EXCLUDE_FEATHER_PX = 4.0


def _validated_xy(fused: List[Minutia], name: str) -> np.ndarray:
    pts = [(m.x, m.y) for m in fused if m.source == name]
    return np.array(pts, dtype=np.float64) if pts else np.zeros((0, 2))


# Longest gap (px, centre-to-centre) that may be bridged between two
# validated points. Beyond this the corridor is too much unvetted
# territory to be worth connecting regardless of how clean it looks.
# First-cut reasoned value, NOT swept.
MAX_BRIDGE_PX = 120.0


def _seg_dist(px: np.ndarray, py: np.ndarray,
              ax: float, ay: float, bx: float, by: float) -> np.ndarray:
    vx, vy = bx - ax, by - ay
    L2 = vx * vx + vy * vy
    if L2 <= 1e-9:
        return np.hypot(px - ax, py - ay)
    t = np.clip(((px - ax) * vx + (py - ay) * vy) / L2, 0.0, 1.0)
    return np.hypot(px - (ax + t * vx), py - (ay + t * vy))


def _bridge_mask(validated: np.ndarray, unvalidated: np.ndarray,
                 shape: Tuple[int, int], radius: float,
                 max_bridge: float, feather: float,
                 clearance: float = -1.0) -> Tuple[np.ndarray, int, int]:
    """Discs around validated points, PLUS capsules joining pairs whose
    connecting corridor contains no unvalidated minutia.

    This grows contiguous regions only along paths the validated data
    actually supports, so it never introduces interior holes (which would
    manufacture ridge terminations -- the exact artifact this whole
    exercise is trying to avoid) and never fills corridors whose content
    no gate endorsed. Returns (mask, n_bridges_drawn, n_bridges_rejected).
    """
    h, w = shape
    m = np.zeros((h, w), dtype=np.uint8)
    for x, y in validated:
        cv2.circle(m, (int(round(x)), int(round(y))), int(round(radius)), 255, -1)
    drawn = rejected = 0
    n = validated.shape[0]
    ux = unvalidated[:, 0] if unvalidated.shape[0] else np.zeros(0)
    uy = unvalidated[:, 1] if unvalidated.shape[0] else np.zeros(0)
    for i in range(n):
        for j in range(i + 1, n):
            ax, ay = validated[i]
            bx, by = validated[j]
            if np.hypot(bx - ax, by - ay) > max_bridge:
                continue
            if ux.size:
                d = _seg_dist(ux, uy, ax, ay, bx, by)
                clr = radius if clearance < 0 else clearance
                if np.any(d <= clr):          # corridor is not clean
                    rejected += 1
                    continue
            cv2.line(m, (int(round(ax)), int(round(ay))),
                     (int(round(bx)), int(round(by))), 255, int(round(2 * radius)))
            drawn += 1
    mf = m.astype(np.float64) / 255.0
    if feather > 0:
        mf = cv2.GaussianBlur(mf, (0, 0), feather)
    return np.clip(mf, 0.0, 1.0), drawn, rejected


def _unvalidated_xy(warped_img: np.ndarray, region: np.ndarray,
                    validated: np.ndarray, shape: Tuple[int, int]) -> np.ndarray:
    """Minutiae the warped source presents inside its own coverage that no
    validated fused point endorses."""
    inside = region > 1e-6
    h, w = shape
    out = []
    for mm in mio.extract_minutiae(warped_img.astype(np.uint8), source='warp'):
        xi, yi = int(round(mm.x)), int(round(mm.y))
        if not (0 <= xi < w and 0 <= yi < h) or not inside[yi, xi]:
            continue
        if validated.shape[0]:
            if np.hypot(validated[:, 0] - mm.x, validated[:, 1] - mm.y).min() <= DIST_TOL:
                continue
        out.append((mm.x, mm.y))
    return np.array(out, dtype=np.float64) if out else np.zeros((0, 2))


def _unvalidated_suppression(warped_img: np.ndarray, region: np.ndarray,
                             validated: np.ndarray, shape: Tuple[int, int],
                             exclude_radius: float,
                             feather: float) -> Tuple[np.ndarray, int, int]:
    """1.0 everywhere except around minutiae in `region` that no validated
    point endorses. Returns (mask, n_found, n_suppressed)."""
    inside = (region > 1e-6)
    if not inside.any():
        return np.ones(shape, dtype=np.float64), 0, 0
    # Minutiae the warped source itself presents inside the merged region.
    local = mio.extract_minutiae(warped_img.astype(np.uint8), source='warp')
    h, w = shape
    supp = np.zeros(shape, dtype=np.uint8)
    n_found = n_supp = 0
    for m in local:
        xi, yi = int(round(m.x)), int(round(m.y))
        if not (0 <= xi < w and 0 <= yi < h) or not inside[yi, xi]:
            continue
        n_found += 1
        if validated.shape[0]:
            d = np.hypot(validated[:, 0] - m.x, validated[:, 1] - m.y).min()
            if d <= DIST_TOL:
                continue          # endorsed by the validated merge -- keep
        cv2.circle(supp, (xi, yi), int(round(exclude_radius)), 1, -1)
        n_supp += 1
    mf = 1.0 - supp.astype(np.float64)
    if feather > 0:
        mf = cv2.GaussianBlur(mf, (0, 0), feather)
    return np.clip(mf, 0.0, 1.0), n_found, n_supp


def run(cap_id: str, max_added: int = DEFAULT_MAX_ADDED,
        blur_sigma: float = BLUR_SIGMA,
        close_radius: float = CLOSE_RADIUS_PX,
        exclude_radius: float = EXCLUDE_RADIUS_PX,
        suppress: bool = True,
        tag: str = 'validmerge') -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== Stage C+validated merge -- {cap_id[:12]} '
          f'(max_added={max_added}, close={close_radius}, '
          f'exclude={exclude_radius}, suppress={suppress}) ===')
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
    a_soft = cv2.GaussianBlur(a_img, (0, 0), blur_sigma)

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
    print(f'  validated merge: +{len(fused) - len(a_minu)} minutiae')

    inv_a_cov = 1.0 - a_cov.astype(np.float64)
    tex_list: List[np.ndarray] = [a_soft.astype(np.float64)]
    weight_list: List[np.ndarray] = [a_cov.astype(np.float64)]
    tot_found = tot_supp = 0

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

        validated = _validated_xy(fused, name)
        avail = warped_cov * inv_a_cov
        if suppress:
            unval = _unvalidated_xy(raw_warped, avail, validated, a_shape)
            # `close_radius` is repurposed here as the corridor CLEARANCE:
            # how near an unvalidated minutia may sit to a candidate bridge
            # before that bridge is rejected. Smaller = more permissive.
            keep, drawn, rejected = _bridge_mask(
                validated, unval, a_shape, KEEP_RADIUS_PX,
                MAX_BRIDGE_PX, exclude_radius, clearance=close_radius)
            tot_found += int(unval.shape[0])
            tot_supp += rejected
            print(f'    {name:16} unvalidated in coverage {unval.shape[0]:3}, '
                  f'bridges drawn {drawn:3}, rejected {rejected:3}')
        else:
            own_pts = [(m.x, m.y) for m in fused if m.source == name]
            keep = _keep_mask_merged(own_pts, a_shape, close_radius=close_radius)
        region = avail * keep

        w = region * coh
        if np.max(w) <= 0:
            continue
        tex_list.append(warped_img.astype(np.float64))
        weight_list.append(w)

    if suppress:
        print(f'  TOTAL: {tot_found} unvalidated minutiae in coverage, '
              f'{tot_supp} bridges rejected as unsupported')

    blended, total_w = _multiband_combine(tex_list, weight_list, num_bands=5)
    blended_gray = np.where(total_w > 0, blended, 255.0)
    composite = np.where(blended_gray < 127, 0, 255).astype(np.uint8)

    out_img_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.png')
    cv2.imwrite(out_img_path, composite)
    comp_minu = mio.extract_minutiae(composite, source='composite')
    print(f'\n  composite image minutiae: {len(comp_minu)} '
          f'(anchor alone {len(a_minu)})')
    print(f'  wrote -> {out_img_path}')

    comp_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.xyt')
    mio.write_xyt(comp_minu, comp_xyt_path)
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

    print('\n  bozorth3 (higher = better match):')
    print('  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs))
    for cname in ('anchor_alone', 'composite'):
        row = '  ' + f'{cname:16}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    beat, informative = 0, 0
    print('\n  VERDICT (per reference):')
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
    print(f'\n  On the {informative} informative reference(s): beats anchor on {beat}.')

    result = {'capture': cap_id, 'max_added': max_added, 'close_radius': close_radius,
              'exclude_radius': exclude_radius, 'suppress': suppress,
              'region_minutiae': tot_found, 'suppressed': tot_supp,
              'composite_minutiae': len(comp_minu), 'anchor_minutiae': len(a_minu),
              'scores': scores, 'composite_image_path': out_img_path}
    out = os.path.join(HERE, 'results', f'phase3f_{tag}.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase3f_validated_merge.py <captureId> '
              '[max_added] [close_radius] [exclude_radius] [suppress:1|0] [tag]')
        sys.exit(1)
    cap = sys.argv[1]
    ma = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_ADDED
    cr = float(sys.argv[3]) if len(sys.argv) > 3 else CLOSE_RADIUS_PX
    er = float(sys.argv[4]) if len(sys.argv) > 4 else EXCLUDE_RADIUS_PX
    sp = (sys.argv[5] != '0') if len(sys.argv) > 5 else True
    tg = sys.argv[6] if len(sys.argv) > 6 else 'validmerge'
    run(cap, ma, BLUR_SIGMA, cr, er, sp, tg)
