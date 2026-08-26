"""PHASE 4 premise check -- is INTRA-bracket registration actually better
than CROSS-bracket registration?

CTO's proposal (2026-08-26): build a superprint per architecture bracket
first -- front-only, angle-tilt, sweep -- then fuse those three bracket
superprints together, bridging wherever their points match.

The mechanism that makes this worth testing is specific, and it targets
the exact constraint phase3f measured: sources currently present 119-134
UNVALIDATED minutiae inside their contributing coverage against only 15
validated ones, and that ratio is what caps every merge policy tried so
far. Within one bracket the captures share a pose family (three tilt
stations differ from each other far less than a tilt station differs
from the face-on front burst), so registration between them should be
more accurate, more minutiae should survive validation, and the
intermediate bracket superprint should be both wider-coverage AND
internally phase-coherent -- a better input to the final fuse than any
single raw source.

That is a HYPOTHESIS with a cheap, direct test, and this track's own
discipline (Phase 0/0b/0c) is to test the premise before building the
machinery on top of it. If intra-bracket pairs do not register measurably
better than cross-bracket pairs, hierarchical fusion inherits the same
ceiling and there is no point building Stage 2.

Measures, for every ordered source pair on every real fusion_v1 capture:
the real inlier count and inlier fraction `reg.register` + `reg.refine`
produce, then groups them into INTRA-bracket vs CROSS-bracket and compares
against `fuse_minutiae.gate_sources`'s own production thresholds
(min_inlier_frac=0.20, min_inlier_count=15) -- the same gate that
rejected all three tilt sources on capture `43378ea7`.

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

import minutiae_io as mio                      # noqa: E402
import registration as reg                     # noqa: E402
from phase0c_real_fusion_capture import (      # noqa: E402
    _db, collect_sources, _render, DIST_TOL, ANGLE_TOL,
)

# Production gate thresholds, mirrored from fuse_minutiae.gate_sources so
# this check reports against the same bar the real pipeline applies.
MIN_INLIER_FRAC = 0.20
MIN_INLIER_COUNT = 15


def _bracket(name: str) -> str:
    if name.startswith('tilt'):
        return 'tilt'
    if name.startswith('sweep'):
        return 'sweep'
    if name.startswith('macro'):
        return 'macro'
    return 'front'


def _pair_quality(a: List, b: List) -> Optional[Tuple[int, float]]:
    """Real inlier count + fraction for registering b onto a."""
    t, n = reg.register(a, b, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
    if t is not None:
        t, n = reg.refine(a, b, t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
    if t is None:
        return None
    denom = min(len(a), len(b))
    return int(n), (float(n) / denom if denom else 0.0)


def run(cap_ids: List[str]) -> dict:
    rows: List[dict] = []
    for cap_id in cap_ids:
        doc = _db.collection('captures').document(cap_id).get()
        if not doc.exists:
            print(f'{cap_id} not found')
            continue
        v = doc.to_dict()
        if not (v.get('isExperiment') or v.get('fusionVersion')):
            print(f'{cap_id} is not a fusion_v1 capture -- refusing')
            continue

        print(f'\n=== {cap_id[:12]} ===')
        srcs = collect_sources(v)
        minu: Dict[str, List] = {}
        for name, (img, guide) in srcs.items():
            p = _render(img, guide, f'{cap_id[:12]}_{name}')
            if p is None:
                continue
            minu[name] = mio.extract_minutiae(p, source=name)
        names = sorted(minu)
        print('  sources:', ', '.join(f'{n}({len(minu[n])})' for n in names))

        for i, a in enumerate(names):
            for b in names:
                if a == b:
                    continue
                q = _pair_quality(minu[a], minu[b])
                if q is None:
                    rows.append({'capture': cap_id, 'ref': a, 'src': b,
                                 'kind': 'intra' if _bracket(a) == _bracket(b) else 'cross',
                                 'inliers': 0, 'frac': 0.0, 'registered': False})
                    continue
                n, f = q
                rows.append({'capture': cap_id, 'ref': a, 'src': b,
                             'kind': 'intra' if _bracket(a) == _bracket(b) else 'cross',
                             'inliers': n, 'frac': round(f, 4), 'registered': True})

    def summarize(kind: str) -> dict:
        sel = [r for r in rows if r['kind'] == kind]
        if not sel:
            return {'n': 0}
        inl = np.array([r['inliers'] for r in sel], dtype=float)
        frac = np.array([r['frac'] for r in sel], dtype=float)
        passes = sum(1 for r in sel
                     if r['inliers'] >= MIN_INLIER_COUNT and r['frac'] >= MIN_INLIER_FRAC)
        return {'n': len(sel), 'mean_inliers': round(float(inl.mean()), 2),
                'median_inliers': round(float(np.median(inl)), 2),
                'mean_frac': round(float(frac.mean()), 4),
                'gate_pass': passes, 'gate_pass_pct': round(100.0 * passes / len(sel), 1)}

    intra, cross = summarize('intra'), summarize('cross')
    print('\n\n=== PREMISE: intra-bracket vs cross-bracket registration ===')
    print(f'  {"":10}{"pairs":>8}{"mean inl":>10}{"median":>9}'
          f'{"mean frac":>11}{"gate pass":>11}')
    for lbl, s in (('intra', intra), ('cross', cross)):
        if not s.get('n'):
            print(f'  {lbl:10}{"(none)":>8}')
            continue
        print(f'  {lbl:10}{s["n"]:>8}{s["mean_inliers"]:>10}{s["median_inliers"]:>9}'
              f'{s["mean_frac"]:>11}{s["gate_pass"]:>7} ({s["gate_pass_pct"]}%)')

    verdict = 'INCONCLUSIVE'
    if intra.get('n') and cross.get('n'):
        if intra['mean_inliers'] > cross['mean_inliers'] and \
           intra['gate_pass_pct'] > cross['gate_pass_pct']:
            verdict = 'SUPPORTED -- intra-bracket registers better on both measures'
        elif intra['mean_inliers'] <= cross['mean_inliers'] and \
                intra['gate_pass_pct'] <= cross['gate_pass_pct']:
            verdict = 'REFUTED -- intra-bracket is no better on either measure'
        else:
            verdict = 'MIXED -- the two measures disagree'
    print(f'\n  PREMISE: {verdict}')

    # Per-bracket detail: which bracket, if any, is internally coherent.
    print('\n  intra-bracket detail (by bracket):')
    for br in ('tilt', 'sweep', 'macro', 'front'):
        sel = [r for r in rows if r['kind'] == 'intra' and _bracket(r['ref']) == br]
        if not sel:
            print(f'    {br:8} (no intra pairs -- bracket has <2 sources)')
            continue
        inl = np.array([r['inliers'] for r in sel], dtype=float)
        passes = sum(1 for r in sel
                     if r['inliers'] >= MIN_INLIER_COUNT and r['frac'] >= MIN_INLIER_FRAC)
        print(f'    {br:8} pairs={len(sel):3}  mean_inliers={inl.mean():6.2f}  '
              f'gate_pass={passes}/{len(sel)}')

    result = {'captures': cap_ids, 'intra': intra, 'cross': cross,
              'verdict': verdict, 'rows': rows}
    out = os.path.join(HERE, 'results', 'phase4a_bracket_premise.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    caps = sys.argv[1:] or [
        '6b43c255-0d46-4aac-bdfa-f117bd0781a1',
        '43378ea7-9f08-4a44-abe1-8e420bc344d7',
        '5181d451-3031-4e60-8ef8-65d6ec2eac8c',
    ]
    run(caps)
