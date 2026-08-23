"""STAGE A diagnostic -- WHY does adding minutiae lose, regardless of
registration model?

Stage A (TPS) barely moved the result (rigid 28 -> TPS 29, still far below
anchor-alone's 34). So "rigid registration slop" was at most a small part of
the story, and the honest next question is not "which warp model" but
"what does adding points to a template actually do to a bozorth3 score".

Two controls, both cheap, both decisive:

  A. PER-SOURCE ABLATION -- anchor + exactly one source at a time. If every
     single source individually drags the score down by a similar amount,
     the problem is the ACT of adding, not any particular bad source.

  B. RANDOM-POINT CONTROL -- anchor + N synthetic minutiae that are pure
     noise (uniform over the anchor's own print area, random orientation).
     This is the control that separates the two competing explanations:
       - if random points cost about the SAME as the real fused points, then
         bozorth3 is penalising template density per se, the comparison is
         confounded, and "fused loses" is not evidence the fused minutiae
         are bad;
       - if random points cost MUCH MORE than the real ones, then the real
         added minutiae are carrying genuine signal and the deficit is a
         smaller, more specific effect worth chasing.

  C. COVERAGE CHECK -- how many of the added minutiae even fall inside the
     region the reference print itself covers? Points outside the
     reference's own extent cannot possibly raise a score against it; they
     can only add competing evidence. If most added points are outside, this
     whole reference is structurally underpowered for measuring fusion, and
     that has to be said plainly rather than read as "fusion fails".

Read-only: no writes outside fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'functions', 'processEnhanceAndScore'))

import numpy as np                             # noqa: E402

import fuse_minutiae as fm                     # noqa: E402
import minutiae_io as mio                      # noqa: E402
import registration as reg                     # noqa: E402
from minutiae_io import Minutia                # noqa: E402
from phase0c_real_fusion_capture import (      # noqa: E402
    _db, collect_sources, _render, _coverage, _warp_coverage,
    DIST_TOL, ANGLE_TOL, CACHE,
)
from phase2_tps_fusion import _ref_xyt, _best_score, MACRO_REFS   # noqa: E402


def _score_set(ms: List[Minutia], tag: str, refs: Dict[str, str]) -> Dict[str, Optional[int]]:
    p = os.path.join(CACHE, f'abl_{tag}.xyt')
    mio.write_xyt(ms, p)
    return {rn: _best_score(p, rx) for rn, rx in refs.items()}


def run(cap_id: str):
    v = _db.collection('captures').document(cap_id).get().to_dict()
    srcs = collect_sources(v)
    prints, minu = {}, {}
    for name, (img, guide) in srcs.items():
        p = _render(img, guide, f'{cap_id[:12]}_{name}')
        if p is None:
            continue
        prints[name] = p
        minu[name] = mio.extract_minutiae(p, source=name)

    anchor = 'front_v1'
    a_minu = minu[anchor]
    a_shape = prints[anchor].shape[:2]

    transforms, rigid_minu, cov = {}, {anchor: a_minu}, {anchor: _coverage(prints[anchor])}
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

    refs = {}
    for rname, rpath in MACRO_REFS.items():
        r = _ref_xyt(rname, rpath)
        if r:
            refs[rname] = r
    if not refs:
        print('no usable references, stopping')
        return

    base = _score_set(a_minu, 'anchor', refs)
    print(f'\n=== Ablation: {cap_id[:12]} ===')
    print(f'\n  {"config":28} {"minutiae":>9}  ' + ''.join(f'{r:>16}' for r in refs))
    print(f'  {"anchor alone (baseline)":28} {len(a_minu):9}  '
          + ''.join(f'{str(base[r]):>16}' for r in refs))

    # ---- A. per-source ablation ----
    print('\n  -- A. anchor + ONE source at a time --')
    per_source = {}
    for name in transforms:
        sub_reg = {anchor: a_minu, name: rigid_minu[name]}
        sub_cov = {anchor: cov[anchor], name: cov[name]}
        fused, _, added = fm.fuse(minu, sub_reg, sub_cov, {name: transforms[name]}, anchor)
        sc = _score_set(fused, f'only_{name}', refs)
        per_source[name] = {'added': added.get(name, 0), 'n': len(fused), 'scores': sc}
        print(f'  {"+ " + name:28} {len(fused):9}  '
              + ''.join(f'{str(sc[r]):>16}' for r in refs))

    # ---- B. random-point control ----
    # Matched in COUNT to the real fusion's own addition, placed uniformly
    # inside the anchor's real print area with random orientation -- i.e.
    # exactly as many points, in plausible places, carrying zero real signal.
    full_fused, _, _ = fm.fuse(minu, rigid_minu, cov, transforms, anchor)
    n_added = len(full_fused) - len(a_minu)
    ys, xs = np.where(cov[anchor] > 0)
    rng = np.random.default_rng(0)
    print(f'\n  -- B. random-point control ({n_added} pure-noise minutiae) --')
    rand_scores = []
    for trial in range(3):     # 3 seeds, so one unlucky draw cannot decide this
        idx = rng.choice(len(xs), size=min(n_added, len(xs)), replace=False)
        noise = [Minutia(x=float(xs[i]), y=float(ys[i]),
                         theta=float(rng.uniform(0, 360)),
                         quality=50.0, source='random') for i in idx]
        sc = _score_set(list(a_minu) + noise, f'random{trial}', refs)
        rand_scores.append(sc)
        print(f'  {"+ random noise (seed " + str(trial) + ")":28} '
              f'{len(a_minu) + len(noise):9}  '
              + ''.join(f'{str(sc[r]):>16}' for r in refs))

    full_sc = _score_set(full_fused, 'full', refs)
    print(f'\n  {"+ ALL real sources (fusion)":28} {len(full_fused):9}  '
          + ''.join(f'{str(full_sc[r]):>16}' for r in refs))

    # ---- C. do the added points even land inside the reference's extent? ----
    print('\n  -- C. reference coverage of the added minutiae --')
    added_pts = full_fused[len(a_minu):]
    for rn, rx in refs.items():
        ref_ms = []
        with open(rx) as f:
            for line in f:
                p = line.split()
                if len(p) >= 3:
                    ref_ms.append((float(p[0]), float(p[1])))
        if not ref_ms:
            continue
        rx_arr = np.array(ref_ms)
        x0, y0 = rx_arr.min(axis=0)
        x1, y1 = rx_arr.max(axis=0)
        inside_anchor = sum(1 for m in a_minu if x0 <= m.x <= x1 and y0 <= m.y <= y1)
        inside_added = sum(1 for m in added_pts if x0 <= m.x <= x1 and y0 <= m.y <= y1)
        print(f'    {rn:16} ref extent x[{x0:.0f},{x1:.0f}] y[{y0:.0f},{y1:.0f}]  '
              f'anchor inside: {inside_anchor}/{len(a_minu)}  '
              f'added inside: {inside_added}/{len(added_pts)}')

    # ---- Interpretation ----
    print('\n  -- interpretation --')
    for rn in refs:
        b = base[rn]
        f_ = full_sc[rn]
        rs = [s[rn] for s in rand_scores if s[rn] is not None]
        if b is None or f_ is None or not rs:
            continue
        rmean = sum(rs) / len(rs)
        print(f'    {rn:16} anchor {b} | real fusion {f_} (delta {f_ - b:+d}) | '
              f'random noise mean {rmean:.1f} (delta {rmean - b:+.1f})')

    out = os.path.join(HERE, 'results', 'phase2b_ablation.json')
    with open(out, 'w') as fh:
        json.dump({'capture': cap_id, 'baseline': base, 'per_source': per_source,
                   'random_control': rand_scores, 'full_fusion': full_sc,
                   'n_added': n_added}, fh, indent=2)
    print(f'\nwrote {out}')


if __name__ == '__main__':
    run(sys.argv[1] if len(sys.argv) > 1 else '6b43c255-0d46-4aac-bdfa-f117bd0781a1')
