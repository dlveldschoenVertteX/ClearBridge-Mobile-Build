"""PHASE 4 -- HIERARCHICAL (per-architecture-bracket) fusion.

CTO's proposal (2026-08-26): "make a superprint out of each architecture
bracket, Front only, Angle tilt (oscillation architecture), sweep. then
find points that match and look like they can be bridged then fuse them."

Two-stage structure:

  Stage 1  tilt_left + tilt_right + tilt_tip  -> TILT superprint
           sweep_left + sweep_center + sweep_right -> SWEEP superprint
           (front bracket is already `front_v1`, itself a burst fusion)

  Stage 2  front_v1 (anchor) + TILT superprint + SWEEP superprint
           -> final superprint

**Why this could beat the flat merge, stated as a mechanism rather than a
hope**: phase3f measured the binding constraint -- sources present
119-134 UNVALIDATED minutiae inside their contributing coverage against
only 15 validated ones, and every merge policy is capped by that ratio.
Within one bracket the members share a pose family (three tilt stations
differ from each other far less than any of them differs from the face-on
front burst), so intra-bracket registration should be more accurate, more
of each member's minutiae should survive validation, and the intermediate
bracket superprint should be wider-coverage AND internally phase-coherent
-- a materially better input to the final fuse than any single raw source.

That premise is tested separately and FIRST by `phase4a_bracket_premise.py`
(this track's own Phase 0 discipline: never build the machinery before
checking the premise it rests on).

**Nothing that already works is discarded** -- this deliberately reuses,
unchanged, every mechanism this track has actually validated:
  - `fm.gate_sources` / `fm.fuse` selective merge with `max_added`
    (Stage A's validated dose-response)
  - rigid registration + TPS refinement (Stage A)
  - soften-then-composite-then-binarize-ONCE (phase3c's real positive)
  - validated-BRIDGE region growth: bridge two validated points only when
    the corridor between them holds no unvalidated minutia (phase3f's
    matchability-neutral result)
  - ridge-coherence weighting (`_fuse_flash_ambient`'s own signal)
and avoids every mechanism measured negative: no hard-edge compositing,
no feathered weight masks, no naive morphological merging, no weight
attenuation (which cannot remove content -- `_multiband_combine`
normalizes by total weight; see PHASE3_COMPOSITE_FINDINGS.md).

`fuse_group()` is the single shared implementation used for BOTH stages,
so Stage 1 and Stage 2 cannot silently drift apart.

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
from phase3_composite import _rigid_matrix, _coherence, KEEP_RADIUS_PX  # noqa: E402
from phase3c_continuous_blend import BLUR_SIGMA  # noqa: E402
from phase3f_validated_merge import (          # noqa: E402
    _bridge_mask, _unvalidated_xy, _validated_xy, MAX_BRIDGE_PX,
)
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

BRACKETS = {'tilt': ('tilt_left', 'tilt_right', 'tilt_tip'),
            'sweep': ('sweep_left', 'sweep_center', 'sweep_right')}


def fuse_group(prints: Dict[str, np.ndarray], anchor: str, max_added: int,
               blur_sigma: float = BLUR_SIGMA,
               label: str = '') -> Optional[Tuple[np.ndarray, List[Minutia], dict]]:
    """Fuse every print in `prints` onto `prints[anchor]`.

    Shared by both hierarchy stages. Returns (composite_image,
    fused_minutiae, debug) or None if the anchor is missing.
    """
    if anchor not in prints:
        return None
    minu = {n: mio.extract_minutiae(p, source=n) for n, p in prints.items()}
    a_minu, a_img = minu[anchor], prints[anchor]
    a_shape = a_img.shape[:2]
    a_cov = _coverage(a_img)
    a_soft = cv2.GaussianBlur(a_img, (0, 0), blur_sigma)

    transforms: Dict[str, reg.Transform] = {}
    cov: Dict[str, np.ndarray] = {anchor: a_cov}
    warps: Dict[str, tps.TpsWarp] = {}
    tps_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    rigid_minu: Dict[str, List[Minutia]] = {anchor: a_minu}

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
        warp, _ = tps.fit_from_correspondences(
            a_minu, rigid_minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if warp is None:
            tps_minu[name] = rigid_minu[name]
            continue
        warps[name] = warp
        tps_minu[name] = warp.apply_minutiae(rigid_minu[name])

    fused, reliability, contributed = fm.fuse(
        minu, tps_minu, cov, transforms, anchor, max_added=max_added)

    inv_a_cov = 1.0 - a_cov.astype(np.float64)
    tex_list: List[np.ndarray] = [a_soft.astype(np.float64)]
    weight_list: List[np.ndarray] = [a_cov.astype(np.float64)]
    dbg = {'anchor': anchor, 'anchor_minutiae': len(a_minu),
           'registered': sorted(transforms), 'contributed': dict(contributed),
           'bridges': {}, 'unvalidated': {}}

    for name, warp in warps.items():
        if contributed.get(name, 0) == 0:
            continue
        M = _rigid_matrix(transforms[name])
        soft_src = cv2.GaussianBlur(prints[name], (0, 0), blur_sigma)
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
        dbg['bridges'][name] = {'drawn': drawn, 'rejected': rejected}
        dbg['unvalidated'][name] = int(unval.shape[0])

        w = avail * keep * coh
        if np.max(w) <= 0:
            continue
        tex_list.append(warped_img.astype(np.float64))
        weight_list.append(w)

    blended, total_w = _multiband_combine(tex_list, weight_list, num_bands=5)
    composite = np.where(np.where(total_w > 0, blended, 255.0) < 127, 0, 255).astype(np.uint8)
    if label:
        print(f'    [{label}] anchor={anchor} '
              f'registered={len(transforms)} contributed='
              f'{ {k: v for k, v in contributed.items() if v} } '
              f'bridges={sum(b["drawn"] for b in dbg["bridges"].values())}')
    return composite, fused, dbg


def _central_anchor(prints: Dict[str, np.ndarray]) -> str:
    """Bracket anchor = the member that registers best against the others.

    Deliberately NOT 'the one with the most minutiae' -- a noisy source can
    carry the most points while registering worst, which is exactly the
    failure this whole track keeps finding. Centrality (total real inlier
    support) is the property that matters for being a fusion base.
    """
    names = sorted(prints)
    if len(names) <= 1:
        return names[0]
    minu = {n: mio.extract_minutiae(prints[n], source=n) for n in names}
    score = {n: 0 for n in names}
    for a in names:
        for b in names:
            if a == b:
                continue
            t, n = reg.register(minu[a], minu[b], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
            if t is not None:
                t, n = reg.refine(minu[a], minu[b], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
            if t is not None:
                score[a] += int(n)
    best = max(names, key=lambda n: score[n])
    print(f'    bracket anchor centrality: '
          f'{ {n: score[n] for n in names} } -> {best}')
    return best


def run(cap_id: str, stage1_max_added: int = 25, stage2_max_added: int = 15,
        blur_sigma: float = BLUR_SIGMA, tag: str = 'hier') -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== PHASE 4 hierarchical fusion -- {cap_id[:12]} '
          f'(s1_max={stage1_max_added}, s2_max={stage2_max_added}) ===')
    srcs = collect_sources(v)
    prints: Dict[str, np.ndarray] = {}
    for name, (img, guide) in srcs.items():
        p = _render(img, guide, f'{cap_id[:12]}_{name}')
        if p is not None:
            prints[name] = p
    if 'front_v1' not in prints:
        print('  no front_v1 anchor, stopping')
        return None

    # ---------------- Stage 1: one superprint per bracket ----------------
    print('\n  STAGE 1 -- bracket superprints')
    bracket_prints: Dict[str, np.ndarray] = {}
    stage1_dbg: Dict[str, dict] = {}
    for br, members in BRACKETS.items():
        have = {m: prints[m] for m in members if m in prints}
        if len(have) < 2:
            print(f'    {br:6}: only {len(have)} member(s) -- '
                  f'{"passing through unfused" if have else "absent"}')
            if have:
                only = next(iter(have))
                bracket_prints[f'{br}_sp'] = have[only]
                stage1_dbg[br] = {'passthrough': only}
            continue
        anchor = _central_anchor(have)
        out = fuse_group(have, anchor, stage1_max_added, blur_sigma, label=br)
        if out is None:
            continue
        comp, fused, dbg = out
        bracket_prints[f'{br}_sp'] = comp
        stage1_dbg[br] = dbg
        path = os.path.join(CACHE, f'{cap_id[:12]}_bracket_{br}.png')
        cv2.imwrite(path, comp)
        n_sp = len(mio.extract_minutiae(comp, source='sp'))
        n_anchor = dbg['anchor_minutiae']
        print(f'    {br:6}: superprint {n_sp} minutiae '
              f'(bracket anchor alone {n_anchor}) -> {os.path.basename(path)}')
        stage1_dbg[br]['superprint_minutiae'] = n_sp

    # ---------------- Stage 2: fuse brackets onto front ------------------
    print('\n  STAGE 2 -- bracket superprints onto front_v1')
    stage2_in = {'front_v1': prints['front_v1']}
    stage2_in.update(bracket_prints)
    out = fuse_group(stage2_in, 'front_v1', stage2_max_added, blur_sigma, label='final')
    if out is None:
        return None
    composite, fused, s2_dbg = out

    out_img = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.png')
    cv2.imwrite(out_img, composite)
    comp_minu = mio.extract_minutiae(composite, source='composite')
    a_img = prints['front_v1']
    a_minu = mio.extract_minutiae(a_img, source='anchor')
    print(f'\n  final composite: {len(comp_minu)} minutiae '
          f'(anchor alone {len(a_minu)}) -> {os.path.basename(out_img)}')

    # ---------------- Score against the same real references -------------
    comp_xyt = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.xyt')
    mio.write_xyt(comp_minu, comp_xyt)
    anchor_xyt = os.path.join(CACHE, f'{cap_id[:12]}_anchor_alone_stage3.xyt')
    mio.write_xyt(a_minu, anchor_xyt)

    refs: Dict[str, str] = {}
    ink = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))
    if ink:
        refs['ink_scan'] = ink
    for rname, rpath in MACRO_REFS.items():
        r = _ref_xyt(rname, rpath)
        if r:
            refs[rname] = r

    scores: Dict[str, Dict[str, Optional[int]]] = {'anchor_alone': {}, 'hierarchical': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt, rx)
        scores['hierarchical'][rn] = _best_score(comp_xyt, rx)

    print('\n  bozorth3 (higher = better match):')
    print('  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs))
    for cname in ('anchor_alone', 'hierarchical'):
        row = '  ' + f'{cname:16}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    beat = informative = 0
    print('\n  VERDICT (per reference):')
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['hierarchical'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        vv = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} hierarchical {c} {vv} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'hierarchical beats anchor-alone on {beat}.')

    result = {'capture': cap_id, 'stage1_max_added': stage1_max_added,
              'stage2_max_added': stage2_max_added, 'stage1': stage1_dbg,
              'stage2': s2_dbg, 'composite_minutiae': len(comp_minu),
              'anchor_minutiae': len(a_minu), 'scores': scores,
              'composite_image_path': out_img}
    outp = os.path.join(HERE, 'results', f'phase4b_{tag}.json')
    with open(outp, 'w') as f:
        json.dump(result, f, indent=2, default=str)
    print(f'\nwrote {outp}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase4b_bracket_fusion.py <captureId> '
              '[stage1_max_added] [stage2_max_added] [tag]')
        sys.exit(1)
    cap = sys.argv[1]
    s1 = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    s2 = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    tg = sys.argv[4] if len(sys.argv) > 4 else 'hier'
    run(cap, s1, s2, BLUR_SIGMA, tg)
