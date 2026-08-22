"""STAGE A runner -- TPS elastic fusion, measured against the two things it
has to beat.

Three-way comparison on the same real capture, same references, same
matcher, everything else held constant:
  1. anchor alone        -- what production delivers today (the real bar)
  2. rigid fusion        -- Phase 1, which LOST to anchor alone
  3. TPS elastic fusion  -- Stage A, this file

Only the registration model differs between (2) and (3). Same sources, same
correspondences, same reliability gate, same merge rule, same scoring. That
isolation is the whole point: if (3) beats (2), the rigid-model diagnosis in
PHASE1_CONSENSUS_FUSION_FINDINGS.md was right; if it does not, that
diagnosis was wrong and the honest conclusion is different.

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

# The same real references Phase 1 was scored against, so the numbers are
# directly comparable. The macro prints are this project's own real
# cross-session captures of the same finger; the ink scan is retained for
# continuity even though it sits at a known noise floor.
MACRO_REFS = {
    'macro_round32': ('/tmp/claude-0/-home-user-ClearBridge-Mobile-Build/'
                      '7c276512-7b7e-5f85-8f5b-2eb1bc5e7593/scratchpad/ps/'
                      'macro_review2/superprint_afis.png'),
    'macro_round35': ('/tmp/claude-0/-home-user-ClearBridge-Mobile-Build/'
                      '7c276512-7b7e-5f85-8f5b-2eb1bc5e7593/scratchpad/ps/'
                      'macro_review35/superprint_afis.png'),
}


def _ref_xyt(name: str, path: str) -> Optional[str]:
    """DPI-normalised reference template, cached. Same convention as every
    other real matchability check in this project."""
    out = os.path.join(CACHE, f'ref_{name}.xyt')
    if os.path.exists(out):
        return out
    if not os.path.exists(path):
        print(f'  reference {name} not found at {path}, skipping')
        return None
    import mindtct_client as mc
    from PIL import Image
    gray = np.array(Image.open(path).convert('L'))
    norm, _ = mc._normalize_dpi(gray)
    mio.write_xyt(mio.extract_minutiae(norm, source=name), out)
    return out


def _best_score(probe_xyt: str, ref_xyt: str) -> Optional[int]:
    """bozorth3 is not perfectly symmetric; take the higher direction, same
    as every prior comparison in this project."""
    a = mio.bozorth_match(probe_xyt, ref_xyt)
    b = mio.bozorth_match(ref_xyt, probe_xyt)
    vals = [v for v in (a, b) if v is not None]
    return max(vals) if vals else None


def run(cap_id: str) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== Stage A: TPS elastic fusion -- {cap_id[:12]} ===')
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
    a_shape = prints[anchor].shape[:2]

    # ---- Rigid registration (identical to Phase 1) ----
    transforms: Dict[str, reg.Transform] = {}
    rigid_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    cov: Dict[str, np.ndarray] = {anchor: _coverage(prints[anchor])}
    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            print(f'    {name:16} rigid registration failed, excluded')
            continue
        transforms[name] = t
        rigid_minu[name] = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)

    # ---- TPS refinement ON TOP of the rigid alignment ----
    tps_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    tps_info: Dict[str, dict] = {}
    print(f'\n  {"source":16} {"ctrl":>5} {"maxDisp":>8} {"resid":>7}  note')
    for name in transforms:
        warp, n_ctrl = tps.fit_from_correspondences(
            a_minu, rigid_minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if warp is None:
            # Self-skipping, exactly like every other optional stage in this
            # pipeline: fall back to the rigid result rather than drop the
            # source. Stage A can then only ever match or beat Phase 1 per
            # source, never do worse by failing to fit.
            tps_minu[name] = rigid_minu[name]
            tps_info[name] = {'fitted': False, 'controls': n_ctrl}
            print(f'  {name:16} {n_ctrl:5} {"--":>8} {"--":>7}  no TPS fit, rigid retained')
            continue
        tps_minu[name] = warp.apply_minutiae(minu_rigid := rigid_minu[name])
        tps_info[name] = {'fitted': True, 'controls': warp.n_control,
                          'maxDisplacementPx': round(warp.max_displacement, 2),
                          'meanResidualPx': round(warp.mean_residual, 2)}
        print(f'  {name:16} {warp.n_control:5} {warp.max_displacement:8.1f} '
              f'{warp.mean_residual:7.2f}  TPS applied ({len(minu_rigid)} minutiae)')

    # ---- Fuse under each registration model (same rule, same gate) ----
    rigid_fused, reliability, rigid_added = fm.fuse(
        minu, rigid_minu, cov, transforms, anchor)
    tps_fused, _, tps_added = fm.fuse(
        minu, tps_minu, cov, transforms, anchor)

    print(f'\n  anchor alone : {len(a_minu):4} minutiae')
    print(f'  rigid fusion : {len(rigid_fused):4} minutiae (+{len(rigid_fused) - len(a_minu)})')
    print(f'  TPS fusion   : {len(tps_fused):4} minutiae (+{len(tps_fused) - len(a_minu)})')

    # ---- Score all three against every real reference ----
    cands = {
        'anchor_alone': a_minu,
        'rigid_fusion': rigid_fused,
        'tps_fusion': tps_fused,
    }
    xyts = {}
    for cname, ms in cands.items():
        p = os.path.join(CACHE, f'{cap_id[:12]}_{cname}.xyt')
        mio.write_xyt(ms, p)
        xyts[cname] = p

    refs = {}
    ink = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))
    if ink:
        refs['ink_scan'] = ink
    for rname, rpath in MACRO_REFS.items():
        r = _ref_xyt(rname, rpath)
        if r:
            refs[rname] = r

    scores: Dict[str, Dict[str, Optional[int]]] = {}
    for cname, cxyt in cands.items():
        scores[cname] = {rn: _best_score(xyts[cname], rx) for rn, rx in refs.items()}

    print(f'\n  bozorth3 (higher = better match):')
    header = '  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs)
    print(header)
    for cname in cands:
        row = '  ' + f'{cname:16}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    # ---- Verdict, against BOTH bars, stated explicitly ----
    print('\n  VERDICT (per reference):')
    beat_anchor = beat_rigid = 0
    informative = 0
    for rn in refs:
        a, r, t = (scores['anchor_alone'][rn], scores['rigid_fusion'][rn],
                   scores['tps_fusion'][rn])
        if a is None or r is None or t is None:
            continue
        # The ink scan is retained for continuity but is a known noise floor
        # in this project; it does not count toward the verdict tally.
        if rn != 'ink_scan':
            informative += 1
            if t > a:
                beat_anchor += 1
            if t > r:
                beat_rigid += 1
        va = 'BEATS' if t > a else ('ties' if t == a else 'loses to')
        vr = 'BEATS' if t > r else ('ties' if t == r else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} TPS {t} {va} anchor {a}; {vr} rigid {r}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'TPS beats anchor-alone on {beat_anchor}, beats rigid on {beat_rigid}.')

    result = {'capture': cap_id, 'tps': tps_info, 'scores': scores,
              'counts': {c: len(m) for c, m in cands.items()},
              'added_rigid': rigid_added, 'added_tps': tps_added,
              'reliability': {k: {'inliers': r.inliers, 'total': r.total,
                                  'frac': round(r.inlier_frac, 3), 'passed': r.passed}
                              for k, r in reliability.items()}}
    out = os.path.join(HERE, 'results', 'phase2_tps_fusion.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase2_tps_fusion.py <captureId>')
        sys.exit(1)
    run(sys.argv[1])
