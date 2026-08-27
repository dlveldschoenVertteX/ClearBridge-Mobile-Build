"""Is the `stack` variant averaging frames it should not be averaging?

CTO hypothesis (2026-08-27): "stacking ambient frames on noise explains why
the stacking function performed so badly."

What the code actually does is close to that but not identical, and the
difference matters. `generate()`'s stack path pools ambient_burst AND
flash_burst together, sorts the pool by its own local `_ridge_energy`, and
flat-averages the top `_STACK_MAX` (4). So the pool is ILLUMINATION-MIXED
by construction: a torch-lit frame and an unlit frame of the same pad have
opposite shading gradients, and averaging them cancels contrast rather than
cancelling noise -- which is the thing flat averaging is supposed to buy.

Three policies, one variable (which frames enter the pool). Masking inputs
(ambient_burst/flash_burst as handed to generate) are held identical across
all three, so the flash-diff mask decision cannot move:
  mixed    every burst frame, ranked by ridge-band score   (today)
  ambient  ambient frames only
  flash    flash frames only

Stacking is done here with production's own `_stack_face_on` and the result
handed to generate() as the primary frame, rather than via `stack=True` --
that is the only way to vary the pool without also perturbing masking,
because generate()'s pool builder is a closure and cannot be reached from
outside. Same alignment, same combine, same renderer.

Gate: real NIST NFIQ2, real production front_only_v1 population.
Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                        # noqa: E402
import numpy as np                                # noqa: E402

import afis_print as ap                           # noqa: E402
from phase0c_real_fusion_capture import _bucket   # noqa: E402
from frame_selection_test import (                # noqa: E402
    _center_square, frame_metrics, nfiq2, population, RESULTS,
)


def stack_of(pool: List[np.ndarray], focus: bool) -> Optional[np.ndarray]:
    fn = ap._focus_stack_face_on if focus else ap._stack_face_on
    return fn(pool[:ap._STACK_MAX], None, {}, None)


def run_capture(doc: dict, tmp: str) -> Optional[dict]:
    cid, guide = doc['_id'], doc['guideRegion']
    loaded = []
    for e in doc['frames']:
        blob = _bucket.blob(e['path'])
        if not blob.exists():
            continue
        arr = cv2.imdecode(np.frombuffer(blob.download_as_bytes(), np.uint8),
                           cv2.IMREAD_COLOR)
        if arr is None:
            continue
        loaded.append({'flash': bool(e.get('flashOn')),
                       'client_lap': float(e.get('laplacianScore') or 0.0),
                       'img': _center_square(arr)})
    amb = [f for f in loaded if not f['flash']]
    fl = [f for f in loaded if f['flash']]
    if len(amb) < 2 or len(fl) < 2:
        return None
    for f in loaded:
        f.update(frame_metrics(f['img'], guide))

    # generate()'s own pool ranking is a ridge-band-energy proxy; `ridge`
    # here is the same physical quantity measured inside the guide.
    rank = lambda xs: [f['img'] for f in sorted(xs, key=lambda f: -f['ridge'])]
    pools = {'mixed': rank(loaded), 'ambient': rank(amb), 'flash': rank(fl)}

    amb_burst = [f['img'] for f in sorted(amb, key=lambda f: -f['client_lap'])]
    fl_burst = [f['img'] for f in sorted(fl, key=lambda f: -f['client_lap'])]

    top4 = sorted(loaded, key=lambda f: -f['ridge'])[:ap._STACK_MAX]
    mix = f'{sum(1 for f in top4 if not f["flash"])}amb/{sum(1 for f in top4 if f["flash"])}fl'

    row: Dict[str, object] = {'captureId': cid, 'mixedPoolTop4': mix}
    for focus in (False, True):
        vname = 'focusStack' if focus else 'stack'
        for pname, pool in pools.items():
            st = stack_of(pool, focus)
            score = None
            if st is not None:
                try:
                    out, _ = ap.generate(
                        [st], [0.0], [None], guide_region=guide,
                        freq_normalize=True, stack_cache={},
                        ambient_frames=[amb_burst[0]], flash_frames=[fl_burst[0]],
                        ambient_burst=amb_burst, flash_burst=fl_burst)
                    if out is not None:
                        score = nfiq2(out if out.ndim == 2
                                      else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY), tmp)
                except Exception as e:
                    print(f'    {vname}/{pname} failed: {e}')
            row[f'{vname}_{pname}'] = score
    print(f'  {cid[:8]}  pool={mix}  '
          + '  '.join(f'{k}={row[k]}' for k in row if k.endswith(
              ('_mixed', '_ambient', '_flash'))))
    return row


def main(limit: int = 12):
    docs = population(limit)
    print(f'{len(docs)} real production front_only_v1 captures\n')
    out = os.path.join(RESULTS, 'stack_policy_test.json')
    rows = []
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

    print('\n=== RESULT ===')
    for vname in ('stack', 'focusStack'):
        print(f'\n{vname}')
        base = [r[f'{vname}_mixed'] for r in rows]
        for pname in ('mixed', 'ambient', 'flash'):
            pairs = [(r[f'{vname}_mixed'], r[f'{vname}_{pname}']) for r in rows
                     if r.get(f'{vname}_mixed') is not None
                     and r.get(f'{vname}_{pname}') is not None]
            if not pairs:
                continue
            m = float(np.mean([p[1] for p in pairs]))
            d = [p[1] - p[0] for p in pairs]
            print(f'  {pname:<8} mean {m:6.2f}  vs mixed {np.mean(d):+6.2f}  '
                  f'({sum(1 for x in d if x > 0)} better / '
                  f'{sum(1 for x in d if x < 0)} worse, n={len(pairs)})')
    print(f'\nwrote {out}')


if __name__ == '__main__':
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 12)
