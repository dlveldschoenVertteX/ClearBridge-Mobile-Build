"""Offline evaluation of GUARDED flash-preference policies.

frame_selection_test.py renders and NFIQ2-scores every burst frame, so any
selection rule can be scored after the fact without re-rendering. This file
holds the rules that are more than "argmax one column" -- specifically the
guards that decide when NOT to trust the torch-lit frames.

The guard matters because this project has repeatedly documented real
captures where the torch blows the pad out (flash Laplacian 15-19 against
ambient's 343-395 on cb684c57). An unconditional flash preference would
walk straight into those. The question these rules answer is whether a
cheap, measurable guard keeps the win while covering that case.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Callable, Dict, List, Optional

import numpy as np

RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')


def _best(frames: List[dict], key: str) -> Optional[dict]:
    pool = [f for f in frames if f.get('nfiq2') is not None]
    return max(pool, key=lambda f: f.get(key, 0.0)) if pool else None


def prod(frames):
    amb = [f for f in frames if not f['flash'] and f.get('nfiq2') is not None]
    return _best(amb or frames, 'client_lap')


def flash_guidelap(frames):
    fl = [f for f in frames if f['flash'] and f.get('nfiq2') is not None]
    return _best(fl or frames, 'guide_lap')


def _guarded(frames, ok: Callable[[dict, Optional[dict]], bool]):
    fl = [f for f in frames if f['flash'] and f.get('nfiq2') is not None]
    amb = [f for f in frames if not f['flash'] and f.get('nfiq2') is not None]
    bf = _best(fl, 'guide_lap')
    ba = _best(amb, 'guide_lap')
    if bf is None:
        return ba
    return bf if ok(bf, ba) else (ba or bf)


def prod_plus_flash(frames):
    """Additive, not a swap: keep production's own ambient primary AND add
    the best torch-lit frame as a second candidate, letting the existing
    max-of-variants NFIQ2 selection choose per capture.

    Strictly non-regressive by construction -- the same discipline every
    other addition to this pipeline follows -- so it cannot lose a capture
    the current code already handles well, unlike an unconditional swap.
    """
    a, b = prod(frames), flash_guidelap(frames)
    if a is None:
        return b
    if b is None:
        return a
    return a if a['nfiq2'] >= b['nfiq2'] else b


def ambient_guidelap(frames):
    amb = [f for f in frames if not f['flash'] and f.get('nfiq2') is not None]
    return _best(amb or frames, 'guide_lap')


def prod_plus_both(frames):
    """prod + best flash + best ambient, all ranked in the guide, all
    additive. Costs one more render pair than prod_plus_flash; this is what
    says whether that pair is worth its place in the 70s variant budget."""
    cands = [c for c in (prod(frames), flash_guidelap(frames),
                         ambient_guidelap(frames)) if c is not None]
    return max(cands, key=lambda f: f['nfiq2']) if cands else None


POLICIES: Dict[str, Callable] = {
    'prod (sharpest ambient, client lap)': prod,
    'flash only, guide Laplacian': flash_guidelap,
    'flash unless >15% of pad clipped':
        lambda fr: _guarded(fr, lambda bf, ba: bf.get('clip_frac', 0) <= 0.15),
    'flash unless >5% of pad clipped':
        lambda fr: _guarded(fr, lambda bf, ba: bf.get('clip_frac', 0) <= 0.05),
    'flash unless ambient is 2x sharper in guide':
        lambda fr: _guarded(
            fr, lambda bf, ba: ba is None
            or bf['guide_lap'] >= 0.5 * ba['guide_lap']),
    'flash unless ambient is 4x sharper in guide':
        lambda fr: _guarded(
            fr, lambda bf, ba: ba is None
            or bf['guide_lap'] >= 0.25 * ba['guide_lap']),
    'prod + best-flash as extra candidate (additive)': prod_plus_flash,
    'prod + best-flash + best-ambient (additive)': prod_plus_both,
    'flash unless it has more ridge energy nowhere':
        lambda fr: _guarded(
            fr, lambda bf, ba: ba is None or bf['ridge'] >= ba['ridge']),
}


def main(path: str = os.path.join(RESULTS, 'frame_selection_test.json')):
    rows = json.load(open(path))
    rows = [r for r in rows
            if any(f.get('nfiq2') is not None for f in r['frames'])]
    oracle = [max(f['nfiq2'] for f in r['frames'] if f['nfiq2'] is not None)
              for r in rows]
    base = None
    print(f'{len(rows)} production captures, every frame rendered + NFIQ2 scored\n')
    print(f'{"policy":<44} {"mean":>6} {"vs prod":>8} {"worst":>6} {"=oracle":>8}')
    for label, fn in POLICIES.items():
        picks, hits = [], 0
        for r, orc in zip(rows, oracle):
            p = fn(r['frames'])
            if p is None:
                continue
            picks.append(p['nfiq2'])
            hits += int(p['nfiq2'] == orc)
        m = float(np.mean(picks))
        if base is None:
            base = picks[:]
        deltas = [a - b for a, b in zip(picks, base)]
        print(f'{label:<44} {m:6.2f} {m - float(np.mean(base)):+8.2f} '
              f'{min(deltas):+6.0f} {hits:3d}/{len(picks):<4d}')
    print(f'{"ORACLE (unknowable live)":<44} {float(np.mean(oracle)):6.2f} '
          f'{float(np.mean(oracle)) - float(np.mean(base)):+8.2f}')

    # Where does each policy's remaining loss come from?
    losses = []
    for r, orc in zip(rows, oracle):
        p = flash_guidelap(r['frames'])
        if p is not None and p['nfiq2'] < orc:
            losses.append((r['captureId'][:8], p['nfiq2'], orc,
                           'FL' if p['flash'] else 'AM'))
    if losses:
        print('\nflash+guideLap misses (capture, picked, oracle, illum):')
        for l in sorted(losses, key=lambda x: x[1] - x[2]):
            print(f'  {l[0]}  {l[1]:5.0f} vs {l[2]:5.0f}  ({l[3]})')


if __name__ == '__main__':
    main(*sys.argv[1:])
