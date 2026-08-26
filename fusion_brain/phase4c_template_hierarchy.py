"""PHASE 4c -- hierarchical bracket fusion in MINUTIAE space, never
compositing an intermediate image.

`phase4b_bracket_fusion.py` built the CTO's bracket hierarchy at the IMAGE
level and scored 0/2 (30/23 vs anchor 34/29) on the first real capture --
worse than the flat validated-bridge merge's 40/30. The debug output gives
the mechanism precisely, and it is not subtle:

  bracket   anchor -> superprint   validated   UNVETTED
  tilt      148    -> 209 (+61)    25          36
  sweep     258    -> 305 (+47)    25          22

Compositing an image ALWAYS yields more extracted minutiae than the merge
validated -- phase3f measured the same ratio on the flat merge (135 -> 171
for 15 validated). Real warped fingerprint texture carries its own real
ridge endings and bifurcations, and pasting it in brings them along
whether or not any gate endorsed them. So a two-stage IMAGE hierarchy
compounds the exact template-density penalty Stage A documented: Stage 1
pollutes each bracket superprint, then Stage 2 treats that polluted
superprint as a trusted source and pollutes again on top.

**This version removes the intermediate entirely.** Each bracket is fused
into a TEMPLATE -- a merged minutiae set plus the union of its members'
coverage -- with no pixels composited and therefore no unvetted minutiae
introduced. The bracket templates are then registered and fused onto
`front_v1`'s own template. Every point in the final template traces to a
source minutia that passed `fm.gate_sources` and `fm.fuse`'s quality cap
at every level it survived.

That is exactly the principle this track has already validated (README:
"never composite pixels ... fuse the extracted MINUTIAE instead"), applied
one level deeper than before. The CTO's bracket idea is preserved intact
-- build a superprint per architecture, then fuse them -- it is only the
representation of the intermediate that changes, from picture to template.

Registration works unchanged because `registration.register` operates on
minutiae, not images, so a bracket TEMPLATE registers onto the anchor by
the same code path a raw source does.

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
from phase4b_bracket_fusion import BRACKETS, _central_anchor  # noqa: E402


def fuse_templates(minu: Dict[str, List[Minutia]],
                   cov: Dict[str, np.ndarray],
                   shape: Tuple[int, int],
                   anchor: str, max_added: int,
                   label: str = '') -> Tuple[List[Minutia], np.ndarray, dict]:
    """Fuse named minutiae templates onto `anchor`, in minutiae space only.

    Returns (fused_minutiae, union_coverage, debug). No image is ever
    composited, so no minutia enters the result that some gate did not
    endorse -- the whole point of this variant.
    """
    a_minu = minu[anchor]
    transforms: Dict[str, reg.Transform] = {}
    tps_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    warped_cov: Dict[str, np.ndarray] = {anchor: cov[anchor]}

    for name in minu:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            continue
        transforms[name] = t
        rigid = t.apply_all(minu[name])
        warped_cov[name] = _warp_coverage(cov[name], t, shape)
        warp, _ = tps.fit_from_correspondences(
            a_minu, rigid, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        tps_minu[name] = warp.apply_minutiae(rigid) if warp is not None else rigid

    fused, reliability, contributed = fm.fuse(
        minu, tps_minu, warped_cov, transforms, anchor, max_added=max_added)

    union = warped_cov[anchor].astype(bool)
    for name in transforms:
        if contributed.get(name, 0) > 0:
            union = union | warped_cov[name].astype(bool)

    dbg = {'anchor': anchor, 'anchor_minutiae': len(a_minu),
           'registered': sorted(transforms),
           'contributed': {k: int(v) for k, v in contributed.items()},
           'fused_minutiae': len(fused)}
    if label:
        print(f'    [{label}] anchor={anchor} registered={len(transforms)} '
              f'contributed={ {k: v for k, v in contributed.items() if v} } '
              f'-> template {len(a_minu)} -> {len(fused)} minutiae '
              f'(ALL validated)')
    return fused, union.astype(np.float64), dbg


def run(cap_id: str, stage1_max_added: int = 25, stage2_max_added: int = 15,
        tag: str = 'tmplhier') -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== PHASE 4c template-space hierarchy -- {cap_id[:12]} '
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

    minu = {n: mio.extract_minutiae(p, source=n) for n, p in prints.items()}
    cov = {n: _coverage(p) for n, p in prints.items()}
    front_shape = prints['front_v1'].shape[:2]

    # ---------------- Stage 1: bracket TEMPLATES (no pixels) -------------
    print('\n  STAGE 1 -- bracket templates (minutiae space, no compositing)')
    br_minu: Dict[str, List[Minutia]] = {}
    br_cov: Dict[str, np.ndarray] = {}
    stage1_dbg: Dict[str, dict] = {}
    for br, members in BRACKETS.items():
        have = [m for m in members if m in prints]
        if len(have) < 2:
            if have:
                only = have[0]
                br_minu[f'{br}_sp'] = minu[only]
                br_cov[f'{br}_sp'] = cov[only]
                stage1_dbg[br] = {'passthrough': only}
                print(f'    {br:6}: only 1 member -- passing {only} through')
            else:
                print(f'    {br:6}: absent')
            continue
        sub_prints = {m: prints[m] for m in have}
        b_anchor = _central_anchor(sub_prints)
        b_shape = prints[b_anchor].shape[:2]
        fused, union, dbg = fuse_templates(
            {m: minu[m] for m in have}, {m: cov[m] for m in have},
            b_shape, b_anchor, stage1_max_added, label=br)
        br_minu[f'{br}_sp'] = fused
        br_cov[f'{br}_sp'] = union
        stage1_dbg[br] = dbg

    # ---------------- Stage 2: bracket templates onto front --------------
    print('\n  STAGE 2 -- bracket templates onto front_v1')
    s2_minu = {'front_v1': minu['front_v1']}
    s2_cov = {'front_v1': cov['front_v1']}
    s2_minu.update(br_minu)
    s2_cov.update(br_cov)
    final, _, s2_dbg = fuse_templates(
        s2_minu, s2_cov, front_shape, 'front_v1', stage2_max_added, label='final')

    a_minu = minu['front_v1']
    print(f'\n  final template: {len(final)} minutiae '
          f'(anchor alone {len(a_minu)}, +{len(final) - len(a_minu)} all validated)')

    # ---------------- Score, same real references ------------------------
    final_xyt = os.path.join(CACHE, f'{cap_id[:12]}_template_{tag}.xyt')
    mio.write_xyt(final, final_xyt)
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

    scores: Dict[str, Dict[str, Optional[int]]] = {'anchor_alone': {}, 'template_hier': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt, rx)
        scores['template_hier'][rn] = _best_score(final_xyt, rx)

    print('\n  bozorth3 (higher = better match):')
    print('  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs))
    for cname in ('anchor_alone', 'template_hier'):
        row = '  ' + f'{cname:16}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    beat = informative = 0
    print('\n  VERDICT (per reference):')
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['template_hier'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        vv = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} template-hier {c} {vv} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'template hierarchy beats anchor-alone on {beat}.')

    result = {'capture': cap_id, 'stage1_max_added': stage1_max_added,
              'stage2_max_added': stage2_max_added, 'stage1': stage1_dbg,
              'stage2': s2_dbg, 'final_minutiae': len(final),
              'anchor_minutiae': len(a_minu), 'scores': scores}
    outp = os.path.join(HERE, 'results', f'phase4c_{tag}.json')
    with open(outp, 'w') as f:
        json.dump(result, f, indent=2, default=str)
    print(f'\nwrote {outp}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase4c_template_hierarchy.py <captureId> '
              '[stage1_max_added] [stage2_max_added] [tag]')
        sys.exit(1)
    cap = sys.argv[1]
    s1 = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    s2 = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    tg = sys.argv[4] if len(sys.argv) > 4 else 'tmplhier'
    run(cap, s1, s2, tg)
