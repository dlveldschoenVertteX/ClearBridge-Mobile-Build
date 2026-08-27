"""What does the additive flash-primary candidate buy against REAL production?

CONFOUND FOUND ON FIRST RUN, and the reason this file reports a date-filtered
number rather than its headline one. `nfiq2Score` is HISTORICAL -- it was
produced by whatever backend was deployed the day that capture was taken --
while the candidate here is rendered by today's code. Run unfiltered across
16 captures it reported +18.50, but the five captures carrying almost all of
that (+64, +57, +56, +53, +41) were taken 2026-07-24 to 2026-08-05 and
delivered 5-10 via `secondary_3` / `minutiae_left` / `detailZoom` -- selection
paths that have since been changed outright (minutiae patches were barred
from winning selection on 2026-08-17). That delta is mostly three weeks of
pipeline fixes, not frame selection.

The clean number is the within-harness one from eval_selection_guards.py,
where BOTH arms are rendered by the same code: +6.61.

frame_selection_test.py's own "prod" arm renders the ambient primary through
ONE variant (freqNorm). Real production renders it through sixteen and keeps
the best, so that arm understates the real baseline and any delta measured
against it overstates the gain.

The honest comparison uses the score production actually delivered -- the
`nfiq2Score` already on each capture doc, which IS the max over the full
variant pool -- against what the new candidate would add on top of it. Since
the change is additive, the new result is exactly
    max(delivered, flash-primary candidate)
so this is a bound, not an estimate: the candidate can only ever raise it.
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'functions', 'processEnhanceAndScore'))

from phase0c_real_fusion_capture import _db          # noqa: E402
from eval_selection_guards import flash_guidelap     # noqa: E402
from frame_selection_test import RESULTS             # noqa: E402


# Captures before this date were scored by a materially different pipeline
# (the minutiae-patch selection bar landed 2026-08-17), so their delivered
# score is not a fair baseline for a candidate rendered by today's code.
_MIN_DATE = '2026-08-17'


def main(min_date: str = _MIN_DATE):
    rows = json.load(open(os.path.join(RESULTS, 'frame_selection_test.json')))
    out, missing = [], 0
    for r in rows:
        doc = _db.collection('captures').document(r['captureId']).get().to_dict()
        delivered = (doc or {}).get('nfiq2Score')
        if delivered is None or not (0 <= float(delivered) <= 100):
            missing += 1
            continue
        if min_date and str((doc or {}).get('createdAt'))[:10] < min_date:
            missing += 1
            continue
        cand = flash_guidelap(r['frames'])
        if cand is None:
            continue
        out.append((r['captureId'][:8], float(delivered), float(cand['nfiq2'])))

    if not out:
        print('no comparable captures')
        return
    delivered = np.array([o[1] for o in out])
    withnew = np.array([max(o[1], o[2]) for o in out])
    gain = withnew - delivered
    print(f'{len(out)} captures with a real delivered nfiq2Score from '
          f'{min_date} onward ({missing} skipped: no score, or scored by an '
          f'older pipeline)\n')
    print(f'{"capture":<10}{"delivered":>10}{"flashPrim":>11}{"result":>8}{"gain":>7}')
    for (cid, d, c) in sorted(out, key=lambda o: o[1] - max(o[1], o[2])):
        print(f'{cid:<10}{d:10.0f}{c:11.0f}{max(d, c):8.0f}{max(d, c) - d:+7.0f}')
    print(f'\nmean delivered {delivered.mean():.2f} -> {withnew.mean():.2f} '
          f'({gain.mean():+.2f})')
    print(f'improves {int((gain > 0).sum())}/{len(out)} captures, '
          f'regresses {int((gain < 0).sum())} (structurally impossible), '
          f'max single gain {gain.max():+.0f}')


if __name__ == '__main__':
    main()
