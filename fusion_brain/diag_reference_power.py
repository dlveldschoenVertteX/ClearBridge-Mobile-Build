"""DIAGNOSTIC -- is the REFERENCE, not the fusion, the thing limiting every
score in this track?

Direct CTO question (2026-08-26): "we used cam 2 as ground truth for
evaluation -- if cam 2 is weaker than main, does that not give us an
unbalanced result, and does that not mean we may have been on the right
path with all the fusion tweaks and might not have known it?"

The concern is real and this file measures it rather than argues it.

MECHANISM, stated precisely. bozorth3 scores matched minutiae PAIRS. A
probe minutia in territory the reference does not cover cannot match
anything -- there is nothing there to match. But it still enlarges the
probe template, and this track has already MEASURED that template density
alone costs score roughly independently of whether the added points carry
signal (Stage A's random-noise control: -4.7/-5.7 for noise vs -6/-4 for
real added minutiae). Fusion's entire purpose is to add coverage the
anchor lacks. So fusion pays a measured density cost for coverage the
reference structurally cannot reward -- a real, DIRECTIONAL bias against
every fusion arm ever scored here.

Measured extents on the real cached templates make the size of it plain:

  ref_macro_round32   96 minutiae   bbox  52,866
  ref_macro_round35  130 minutiae   bbox 139,761
  anchor (6b43c255)  135 minutiae   bbox 103,016-107,184
  p6 tps_maxc        273 minutiae   bbox 268,650   <- 5.1x round32's

THE TEST: re-score every cached candidate against each reference TWICE --
once whole (status quo), once with the probe restricted to the
reference's own coordinate extent. The restricted arm removes the
density penalty for out-of-extent minutiae entirely and asks the only
question this instrument can actually answer: *within the region the
reference can see, did fusion improve the print?*

Reading the result honestly, both ways:
  * If restricted scores lift fusion arms relative to the control, the
    instrument was masking real gains and prior negatives need revisiting.
  * If they do not move, the added minutiae were not carrying signal even
    where measurable, and the negatives stand on their own merits.

Restriction is applied in the probe's own coordinate frame, which is
valid ONLY because both templates are DPI-normalised to the same
convention by `_ref_xyt`/`mio.write_xyt` -- the same assumption every
score in this track already rests on. It is a bounding-box test, not a
registration; it is deliberately generous (it keeps everything that could
possibly match) so it cannot manufacture a win.

Read-only: reads cached templates, writes only fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import minutiae_io as mio                      # noqa: E402
from phase0c_real_fusion_capture import CACHE   # noqa: E402
from phase2_tps_fusion import _best_score       # noqa: E402


def _read(path: str) -> List[Tuple[float, float, str]]:
    out = []
    for line in open(path):
        f = line.split()
        if len(f) >= 3:
            try:
                out.append((float(f[0]), float(f[1]), line))
            except ValueError:
                pass
    return out


def _extent(rows) -> Tuple[float, float, float, float]:
    xs = [r[0] for r in rows]
    ys = [r[1] for r in rows]
    return min(xs), max(xs), min(ys), max(ys)


def _restrict(probe: str, ref: str, out: str, pad: float = 0.0) -> Tuple[int, int]:
    """Write a copy of `probe` keeping only minutiae inside `ref`'s extent."""
    pr, rr = _read(probe), _read(ref)
    x0, x1, y0, y1 = _extent(rr)
    x0, x1, y0, y1 = x0 - pad, x1 + pad, y0 - pad, y1 + pad
    kept = [r for r in pr if x0 <= r[0] <= x1 and y0 <= r[1] <= y1]
    with open(out, 'w') as fh:
        for r in kept:
            fh.write(r[2])
    return len(pr), len(kept)


def run(cap_prefix: str = '6b43c255-0d4') -> dict:
    refs = {}
    for rn in ('macro_round32', 'macro_round35'):
        p = os.path.join(CACHE, f'ref_{rn}.xyt')
        if os.path.exists(p):
            refs[rn] = p
    if not refs:
        print('no cached references'); return {}

    cands: Dict[str, str] = {}
    for f in sorted(os.listdir(CACHE)):
        if not (f.startswith(cap_prefix) and f.endswith('.xyt')):
            continue
        if '_p6_' in f or 'anchor_alone' in f:
            cands[f.replace(f'{cap_prefix}_', '').replace('.xyt', '')] = \
                os.path.join(CACHE, f)
    if not cands:
        print('no cached candidates'); return {}

    print(f'\n=== reference-power diagnostic -- {cap_prefix} ===')
    for rn, rp in refs.items():
        rr = _read(rp)
        x0, x1, y0, y1 = _extent(rr)
        print(f'  {rn}: {len(rr)} minutiae, extent x {x0:.0f}-{x1:.0f} '
              f'y {y0:.0f}-{y1:.0f}')

    results: Dict[str, dict] = {}
    for rn, rp in refs.items():
        print(f'\n  --- vs {rn} ---')
        print(f'  {"candidate":22}{"minutiae":>10}{"in-extent":>11}'
              f'{"whole":>8}{"restricted":>12}{"delta":>8}')
        for cn, cp in sorted(cands.items()):
            tmp = os.path.join(CACHE, f'_restr_{cn}_{rn}.xyt')
            total, kept = _restrict(cp, rp, tmp)
            whole = _best_score(cp, rp)
            restr = _best_score(tmp, rp) if kept >= 4 else None
            d = ('' if whole is None or restr is None
                 else f'{restr - whole:+d}')
            print(f'  {cn[:22]:22}{total:>10}{kept:>11}'
                  f'{str(whole):>8}{str(restr):>12}{d:>8}')
            results.setdefault(rn, {})[cn] = {
                'minutiae': total, 'in_extent': kept,
                'whole': whole, 'restricted': restr}
            try:
                os.remove(tmp)
            except OSError:
                pass

    out = os.path.join(HERE, 'results', f'diag_refpower_{cap_prefix[:8]}.json')
    with open(out, 'w') as fh:
        json.dump(results, fh, indent=2)
    print(f'\nwrote {out}')
    return results


if __name__ == '__main__':
    run(sys.argv[1] if len(sys.argv) > 1 else '6b43c255-0d4')
