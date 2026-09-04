"""Does measuring the crease on the PRE-GABOR grayscale trim the right thing?

The change under test threads `generate()`'s pre-Gabor normalized grayscale
into `_trim_base_crease` as its orientation source, instead of measuring the
already-Gabor-enhanced binarized print. See that function's docstring for the
circularity this removes.

Deliberately NOT gated on NFIQ2. Crease trim is already known to COST a few
NFIQ2 points when it works -- it removes non-ridge area, and NFIQ2 rewards
ridge-like texture wherever it appears, which is exactly the property that
lets a crease score well. The CTO's requirement is that below-crease content
must not survive, so the question here is how much gets trimmed and whether
the boundary lands at the crease. NFIQ2 is reported alongside so the cost is
visible, not used as the decision.

Reports per capture: trim fraction before and after, and whether the trim
fires at all -- the failure mode being fixed is a trim that never fires.

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from typing import List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                        # noqa: E402
import numpy as np                                # noqa: E402

import afis_print as ap                           # noqa: E402
from phase0c_real_fusion_capture import _bucket   # noqa: E402
from frame_selection_test import (                # noqa: E402
    _center_square, nfiq2, population, RESULTS,
)

OUT = os.path.join(HERE, 'results', 'cache', 'crease')
os.makedirs(OUT, exist_ok=True)
_TRIM = ap._trim_base_crease


def _no_src(binimg, mask, *a, **k):
    """The old behaviour: measure on the binarized print."""
    k.pop('orient_src', None)
    return _TRIM(binimg, mask, *a, **k)


def run_capture(doc: dict, tmp: str) -> Optional[dict]:
    cid, guide = doc['_id'], doc['guideRegion']
    amb = [f for f in doc['frames'] if not f.get('flashOn')]
    fl = [f for f in doc['frames'] if f.get('flashOn')]
    if not amb:
        return None

    def load(e):
        b = _bucket.blob(e['path'])
        if not b.exists():
            return None
        a = cv2.imdecode(np.frombuffer(b.download_as_bytes(), np.uint8),
                         cv2.IMREAD_COLOR)
        return None if a is None else _center_square(a)

    amb_s = sorted(amb, key=lambda f: -(f.get('laplacianScore') or 0))
    fl_s = sorted(fl, key=lambda f: -(f.get('laplacianScore') or 0))
    ab = [x for x in (load(e) for e in amb_s) if x is not None]
    fb = [x for x in (load(e) for e in fl_s) if x is not None]
    if not ab:
        return None

    def render(**kw):
        return ap.generate(
            [ab[0]], [0.0], [None], guide_region=guide, freq_normalize=True,
            stack_cache={}, ambient_frames=[ab[0]],
            flash_frames=[fb[0]] if fb else [None],
            ambient_burst=ab, flash_burst=fb or None, **kw)

    out_none, _ = render(crease_trim=False, circular_vignette=False)
    if out_none is None:
        return None
    base_area = int((out_none < 250).sum())

    ap._trim_base_crease = _no_src
    try:
        out_old, p_old = render(circular_vignette=False)
    finally:
        ap._trim_base_crease = _TRIM
    out_new, p_new = render(circular_vignette=False)

    def frac(p):
        t = p.get('afisCreaseTrimPx') or 0
        return 100.0 * t / max(base_area + t, 1)

    row = {
        'captureId': cid,
        'oldTrimPx': p_old.get('afisCreaseTrimPx'),
        'newTrimPx': p_new.get('afisCreaseTrimPx'),
        'oldTrimPct': round(frac(p_old), 1),
        'newTrimPct': round(frac(p_new), 1),
        'nfiq2_old': nfiq2(out_old, tmp) if out_old is not None else None,
        'nfiq2_new': nfiq2(out_new, tmp) if out_new is not None else None,
    }
    for tag, img in (('old', out_old), ('new', out_new)):
        if img is not None:
            sc = 700.0 / max(img.shape[:2])
            cv2.imwrite(os.path.join(OUT, f'{cid[:8]}_trim_{tag}.png'),
                        cv2.resize(img, None, fx=sc, fy=sc,
                                   interpolation=cv2.INTER_AREA))
    print(f'  {cid[:8]}  trim {row["oldTrimPct"]:5.1f}% -> {row["newTrimPct"]:5.1f}%'
          f'   nfiq2 {row["nfiq2_old"]} -> {row["nfiq2_new"]}'
          f'{"   << was not firing" if not row["oldTrimPx"] else ""}')
    return row


def by_ids(ids: List[str]) -> List[dict]:
    """Targeted lookup. The general population sample is unlikely to contain
    the captures this change is actually FOR -- the ones where the trim never
    fired -- so those are addressed by id."""
    from phase0c_real_fusion_capture import _db
    out = []
    for d in _db.collection('captures').where(
            'captureMode', '==', 'front_only_v1').limit(500).stream():
        if any(d.id.startswith(i) for i in ids):
            v = d.to_dict()
            if v.get('guideRegion') and v.get('frames'):
                v['_id'] = d.id
                out.append(v)
    return out


def main(limit: int = 12):
    docs = population(limit)
    print(f'{len(docs)} real production front_only_v1 captures\n')
    out = os.path.join(RESULTS, 'crease_fix_test.json')
    rows: List[dict] = []
    for doc in docs:
        tmp = tempfile.mkdtemp()
        try:
            r = run_capture(doc, tmp)
            if r:
                rows.append(r)
                with open(out, 'w') as f:
                    json.dump(rows, f, indent=2)
        except Exception as e:
            print(f'  {doc["_id"][:8]} failed: {e}')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    was_off = [r for r in rows if not r['oldTrimPx']]
    now_on = [r for r in was_off if r['newTrimPx']]
    print('\n=== RESULT ===')
    print(f'  trim was not firing on {len(was_off)}/{len(rows)} captures; '
          f'now fires on {len(now_on)} of those')
    print(f'  mean trim {np.mean([r["oldTrimPct"] for r in rows]):.1f}% -> '
          f'{np.mean([r["newTrimPct"] for r in rows]):.1f}%')
    sc = [(r['nfiq2_old'], r['nfiq2_new']) for r in rows
          if r['nfiq2_old'] is not None and r['nfiq2_new'] is not None]
    if sc:
        d = [b - a for a, b in sc]
        print(f'  NFIQ2 {np.mean([x[0] for x in sc]):.2f} -> '
              f'{np.mean([x[1] for x in sc]):.2f} ({np.mean(d):+.2f}), '
              f'{sum(1 for x in d if x > 0)} up / {sum(1 for x in d if x < 0)} down '
              f'-- reported, not the gate')
    print(f'\nwrote {out}')


def main_ids(ids: List[str]):
    docs = by_ids(ids)
    print(f'{len(docs)} captures by id\n')
    rows = []
    for doc in docs:
        tmp = tempfile.mkdtemp()
        try:
            r = run_capture(doc, tmp)
            if r:
                rows.append(r)
        except Exception as e:
            print(f'  {doc["_id"][:8]} failed: {e}')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    out = os.path.join(RESULTS, 'crease_fix_nofire.json')
    with open(out, 'w') as f:
        json.dump(rows, f, indent=2)
    was_off = [r for r in rows if not r['oldTrimPx']]
    print(f'\n  trim was not firing on {len(was_off)}/{len(rows)}; now fires on '
          f'{len([r for r in was_off if r["newTrimPx"]])} of those')
    print(f'wrote {out}')


if __name__ == '__main__':
    a = sys.argv[1:]
    if a and not a[0].isdigit():
        main_ids(a)
    else:
        main(int(a[0]) if a else 12)
