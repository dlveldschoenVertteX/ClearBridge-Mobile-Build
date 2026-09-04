"""Sweep the enhancement pipeline's real levers against real matchability.

CTO ask (2026-08-27): "look into all the processing levers and run a few
tests on what the best settings would be so we can find an optimum setting
within the different filters."

METHOD, and why it is shaped this way:
  * ONE VARIABLE AT A TIME from the production baseline. This project has
    been burned repeatedly by multi-variable tests that could not attribute
    their own result (phase3d's conflated merge, Phase 5's crop-vs-fullframe
    confound). Every row below differs from the baseline in exactly one
    parameter.
  * Scored with real bozorth3 against the MAIN-CAMERA references built in
    round 40 (`ref_main_round32`, 161 minutiae over a 106,673 bbox), not
    the macro ones -- round 40 measured those as the weaker instrument
    (96 minutiae, 52,866 bbox).
  * Reported PER CAPTURE, never as a bare mean. This gate is noisy at these
    magnitudes and a mean hides disagreement between captures, which is the
    single most useful signal for deciding whether a lever is real.

HONEST PRIOR, stated so the results are read correctly: `_GABOR_SIGMA_RATIO`,
`_GABOR_GAMMA`, `_FEATHER_SIGMA` and `_FREQ_SCALE_MIN` were ALREADY tuned
once against real data (2026-07-15, "first tuning pass"), and `_FREQ_SCALE_MIN`
was independently re-validated on real matchability in round 19 (relaxing it
0.7 -> 0.15 made matchability WORSE: 2/4 genuine-beats-impostor -> 0/4). So
the baseline is not an arbitrary starting point, and finding "production is
already near-optimal" is a likely and perfectly good outcome.

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                      # noqa: E402
import numpy as np                              # noqa: E402

import afis_print as ap                         # noqa: E402
import minutiae_io as mio                       # noqa: E402
from phase0c_real_fusion_capture import (       # noqa: E402
    _db, collect_sources, _flash_pair_for, CACHE,
)
from phase2_tps_fusion import _best_score        # noqa: E402

CAPS = ('6b43c255', '43378ea7', '5181d451')
# Main-camera references only -- round 40 established the macro ones are the
# weaker instrument.
REF_NAMES = ('main_round32', 'main_round35')

# (label, generate-kwargs). Baseline first; every other row changes exactly
# one thing from it.
ARMS: List[tuple] = [
    ('BASELINE (production)',      {}),
    ('gabor_sigma_ratio=0.50',     {'gabor_sigma_ratio': 0.50}),
    ('gabor_sigma_ratio=0.80',     {'gabor_sigma_ratio': 0.80}),
    ('gabor_gamma=0.70',           {'gabor_gamma': 0.70}),
    ('gabor_gamma=1.00',           {'gabor_gamma': 1.00}),
    ('freq_scale_min=0.50',        {'freq_scale_min': 0.50}),
    ('freq_scale_min=0.90',        {'freq_scale_min': 0.90}),
    ('crease_trim=OFF',            {'crease_trim': False}),
    ('circular_vignette=OFF',      {'circular_vignette': False}),
]


def _refs() -> Dict[str, str]:
    out = {}
    for rn in REF_NAMES:
        p = os.path.join(CACHE, f'ref_{rn}.xyt')
        if os.path.exists(p):
            out[rn] = p
    return out


def run() -> dict:
    refs = _refs()
    if not refs:
        print('no main-camera references cached -- run build_main_refs.py first')
        return {}

    docs = list(_db.collection('captures').limit(500).stream())
    loaded = {}
    for short in CAPS:
        cid = next((d.id for d in docs if d.id.startswith(short)), None)
        if cid is None:
            continue
        v = _db.collection('captures').document(cid).get().to_dict()
        srcs = collect_sources(v)
        if 'front_v1' not in srcs:
            continue
        img, g = srcs['front_v1']
        fp = _flash_pair_for(v, 'front_v1')
        kw = ({'ambient_burst': [fp[0]], 'flash_burst': [fp[1]]} if fp else {})
        loaded[short] = (img, g, kw)
    if not loaded:
        print('no captures loaded')
        return {}

    hdr = f'{"arm":26}'
    for short in loaded:
        hdr += f'{short:>22}'
    print('\n' + hdr)
    print(f'{"":26}' + ''.join(f'{"minu  m32  m35":>22}' for _ in loaded))
    print('-' * len(hdr))

    results: Dict[str, dict] = {}
    baseline: Dict[str, tuple] = {}
    for label, extra in ARMS:
        row = f'{label:26}'
        results[label] = {}
        for short, (img, g, kw) in loaded.items():
            try:
                out, _p = ap.generate([img], [0.0], [None], guide_region=g,
                                      freq_normalize=True, stack_cache={},
                                      **kw, **extra)
            except Exception as e:
                row += f'{"ERR":>22}'
                results[label][short] = {'error': str(e)}
                continue
            if out is None:
                row += f'{"None":>22}'
                results[label][short] = None
                continue
            pr = out if out.ndim == 2 else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
            m = mio.extract_minutiae(pr, source=short)
            xp = os.path.join(CACHE, f'sweep_{short}_{abs(hash(label)) % 99999}.xyt')
            mio.write_xyt(m, xp)
            sc = {rn: _best_score(xp, rp) for rn, rp in refs.items()}
            vals = [sc.get(rn) for rn in REF_NAMES]
            results[label][short] = {'minutiae': len(m), 'scores': sc}
            if label.startswith('BASELINE'):
                baseline[short] = tuple(vals)
                mark = ''
            else:
                b = baseline.get(short)
                if b and all(v is not None for v in vals) and all(v is not None for v in b):
                    d = sum(vals) - sum(b)
                    mark = f' {d:+d}' if d else '  ='
                else:
                    mark = ''
            cell = f'{len(m):4} {vals[0] if vals[0] is not None else "-":>4} ' \
                   f'{vals[1] if vals[1] is not None else "-":>4}{mark}'
            row += f'{cell:>22}'
            try:
                os.remove(xp)
            except OSError:
                pass
        print(row)

    out_p = os.path.join(HERE, 'results', 'sweep_processing_levers.json')
    with open(out_p, 'w') as f:
        json.dump(results, f, indent=2)
    print(f'\nwrote {out_p}')
    print('\n(minu = minutiae count; m32/m35 = bozorth3 vs ref_main_round32 / '
          'ref_main_round35; +/- = summed change vs BASELINE for that capture)')
    return results


if __name__ == '__main__':
    run()
