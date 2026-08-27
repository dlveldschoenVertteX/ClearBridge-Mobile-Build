"""Does the legacy NNS enhancer improve if it is shown the pad instead of the room?

CTO question (2026-08-27): "Have we ever tried to optimize the legacy NNS
enhancer? There may be some levers to pull on."

History says its BUGS were fixed three times (pre-mask ringing, the
512-resize scale collapse, and the same defect class in sfm_pipeline's
gap-fill mask) but its PARAMETERS were never swept. This tests something
upstream of any parameter.

For front_only_v1, main.py hands `enhancement_pipeline.enhance()` the output
of `sfm_pipeline._prepare(frames[0])` -- a centre-square of the raw frame
with NO pad mask -- which is then resized to a fixed 512x512. Real
consequences, all measurable:

  * the guide occupies ~12.5% of that square on real captures, so the pad
    lands at roughly 180px across inside a 512px input and ~87% of the
    model's fixed budget is spent on desk, wall and clothing;
  * `_estimate_ridge_frequency` picks the highest-Laplacian-variance
    QUADRANT of the whole scene, crops 128x128 from it, and FFTs that to get
    "the ridge period" -- which then sets every wavelength in
    `_multiscale_gabor`. On a capture shot over decking or a striped blind,
    that quadrant is background and the bank gets tuned to plank spacing;
  * CLAHE normalises contrast against the room rather than skin.

Arms, one variable (what `enhance()` is given):
  scene   the centre-square of the raw frame               (production today)
  guide   the guide-region bbox, the same region AFIS uses
  guideM  the guide bbox with everything outside the superellipse greyed,
          so the frequency estimator cannot reach past the pad at all

Gate: real NIST NFIQ2 on the enhancer's own output, plus the estimated ridge
frequency each arm derives -- the frequency is the diagnostic that says
whether the mechanism above is actually what is happening.

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
import enhancement_pipeline as ep                 # noqa: E402
import sfm_pipeline as sfm                        # noqa: E402
from phase0c_real_fusion_capture import _bucket   # noqa: E402
from frame_selection_test import (                # noqa: E402
    _center_square, nfiq2, population, RESULTS,
)

OUT = os.path.join(HERE, 'results', 'cache', 'nns')
os.makedirs(OUT, exist_ok=True)


def guide_bbox(shape, guide: dict, pad: float = 1.15):
    """Guide superellipse bbox, mildly dilated. The dilation matters: the
    enhancer has no mask of its own, so a crop tight to the guide would clip
    ridge content the AFIS path keeps via _MASK_COVER_DILATE."""
    h, w = shape[:2]
    cx, cy = float(guide['cx']) * w, float(guide['cy']) * h
    rx, ry = float(guide['rx']) * w * pad, float(guide['ry']) * h * pad
    x0, x1 = int(max(0, cx - rx)), int(min(w, cx + rx))
    y0, y1 = int(max(0, cy - ry)), int(min(h, cy + ry))
    return (x0, y0, x1, y1) if x1 - x0 > 32 and y1 - y0 > 32 else None


def run_capture(doc: dict, tmp: str) -> Optional[dict]:
    cid, guide = doc['_id'], doc['guideRegion']
    amb = sorted([f for f in doc['frames'] if not f.get('flashOn')],
                 key=lambda f: -(f.get('laplacianScore') or 0))
    if not amb:
        return None
    b = _bucket.blob(amb[0]['path'])
    if not b.exists():
        return None
    arr = cv2.imdecode(np.frombuffer(b.download_as_bytes(), np.uint8),
                       cv2.IMREAD_COLOR)
    if arr is None:
        return None

    sq = _center_square(arr)
    scene = cv2.cvtColor(sfm._prepare(sq), cv2.COLOR_BGR2GRAY)

    bb = guide_bbox(sq.shape, guide)
    if bb is None:
        return None
    x0, y0, x1, y1 = bb
    gray_sq = cv2.cvtColor(sq, cv2.COLOR_BGR2GRAY)
    crop = gray_sq[y0:y1, x0:x1]

    gm = ap._superellipse_mask(gray_sq.shape[:2], guide)
    masked = crop.copy()
    if gm is not None and (gm > 0).any():
        sub = gm[y0:y1, x0:x1]
        # Mid-grey outside the pad: neutral to CLAHE and carrying no
        # periodicity for the frequency estimator to lock onto.
        masked[sub == 0] = 128

    row = {'captureId': cid,
           'guideFracOfScene': round(float((gm > 0).mean()), 4) if gm is not None else None}
    for arm, img in (('scene', scene), ('guide', crop), ('guideM', masked)):
        try:
            enh, _ = ep.enhance(img, sfm_coverage=1.0)
        except Exception as e:
            print(f'    {arm} failed: {e}')
            row[f'nfiq2_{arm}'] = None
            continue
        small = cv2.resize(img, (512, 512), interpolation=cv2.INTER_AREA)
        row[f'ridgePeriod_{arm}'] = round(1.0 / ep._estimate_ridge_frequency(small), 1)
        row[f'nfiq2_{arm}'] = nfiq2(enh, tmp)
        cv2.imwrite(os.path.join(OUT, f'{cid[:8]}_{arm}.png'), enh)

    print(f'  {cid[:8]}  guide={100*(row["guideFracOfScene"] or 0):.1f}% of frame   '
          + '  '.join(f'{a}: nfiq={row.get(f"nfiq2_{a}")} period='
                      f'{row.get(f"ridgePeriod_{a}")}px'
                      for a in ('scene', 'guide', 'guideM')))
    return row


def main(limit: int = 10):
    docs = population(limit)
    print(f'{len(docs)} real production front_only_v1 captures\n')
    out = os.path.join(RESULTS, 'nns_guidecrop_test.json')
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

    print('\n=== RESULT ===')
    for arm in ('scene', 'guide', 'guideM'):
        v = [r[f'nfiq2_{arm}'] for r in rows if r.get(f'nfiq2_{arm}') is not None]
        base = [r['nfiq2_scene'] for r in rows
                if r.get(f'nfiq2_{arm}') is not None and r.get('nfiq2_scene') is not None]
        p = [r.get(f'ridgePeriod_{arm}') for r in rows
             if r.get(f'ridgePeriod_{arm}') is not None]
        if not v:
            continue
        d = [a - b for a, b in zip(v, base)] if len(base) == len(v) else []
        print(f'  {arm:<7} NFIQ2 mean {np.mean(v):6.2f}'
              + (f'  vs scene {np.mean(d):+6.2f} '
                 f'({sum(1 for x in d if x > 0)} better / '
                 f'{sum(1 for x in d if x < 0)} worse)' if d else '')
              + f'   median estimated ridge period {np.median(p):5.1f}px')
    print('\n(the AFIS path targets ~9px; a period far from that is the '
          'frequency estimator locking onto something that is not a ridge)')
    print(f'wrote {out}')


if __name__ == '__main__':
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 10)
