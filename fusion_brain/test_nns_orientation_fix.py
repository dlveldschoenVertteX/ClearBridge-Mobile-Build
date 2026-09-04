"""Does restricting _ridge_pass's orientation+frequency measurement to the
guide region remove the streaking without costing NFIQ2?

Mechanism confirmed visually before this ran: isolating Stage-3's single
Gabor filter (unet_weight=0) on a real capture reproduced the CTO-reported
diagonal streaking almost exactly; isolating the UNet (unet_weight=1) did
not. `_ridge_pass` derives ONE dominant orientation from the highest-
contrast quadrant of the WHOLE 512x512 scene and stamps it across the
entire image -- on a capture shot over decking or a blind, that quadrant is
background.

Two arms, everything else in enhance() identical to production (full-frame
CLAHE, full-frame UNet input, unet_weight=0.35):
  prod   roi_box=None                              (today)
  fixed  roi_box = guide region, 1.15x padded

Reports NFIQ2 (the population-level gate this project uses throughout) and
a directional edge-coherence measure inside a background-only ring around
the guide -- background streaking should measure LESS oriented after the
fix, since the filter's single orientation should now come from the pad
rather than from whatever the background happens to contain.

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
import enhancement_pipeline as ep                 # noqa: E402
import sfm_pipeline as sfm                        # noqa: E402
from phase0c_real_fusion_capture import _bucket   # noqa: E402
from frame_selection_test import (                # noqa: E402
    _center_square, nfiq2, population, RESULTS,
)
from test_nns_guidecrop import guide_bbox, OUT     # noqa: E402


def bg_ring_coherence(enh_512: np.ndarray, gm_512: np.ndarray) -> Optional[float]:
    """How strongly oriented the BACKGROUND ring around the pad is, in the
    enhanced output. If the single-orientation filter is streaking the
    background in its own detected direction (the failure mode), this reads
    high; if the background is left closer to its own pre-filter texture,
    lower. `_block_coherence` is AFIS's own already-used coherence field, so
    this reuses a validated measurement rather than inventing one."""
    ring = cv2.dilate(gm_512, np.ones((41, 41), np.uint8)) > 0
    ring &= ~(gm_512 > 0)
    if ring.sum() < 500:
        return None
    coh = ap._block_coherence(enh_512)
    return float(np.median(coh[ring]))


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
    scene_512 = cv2.resize(scene, (512, 512), interpolation=cv2.INTER_AREA)

    gm = ap._superellipse_mask(scene.shape[:2], guide)
    if gm is None or not (gm > 0).any():
        return None
    gm_512 = cv2.resize(gm, (512, 512), interpolation=cv2.INTER_NEAREST)

    bb = guide_bbox(scene.shape, guide, pad=1.15)
    if bb is None:
        return None
    # guide_bbox is in scene-space (== 512-space here since scene is already
    # square before enhance()'s own internal resize -- confirmed: enhance()
    # only resizes when shape != (512,512), and _prepare's output already is
    # whatever size sfm_pipeline uses; scale explicitly to be safe).
    sx = 512.0 / scene.shape[1]
    sy = 512.0 / scene.shape[0]
    roi_box = (int(bb[0] * sx), int(bb[1] * sy), int(bb[2] * sx), int(bb[3] * sy))

    row: Dict[str, object] = {'captureId': cid}
    for arm, rb in (('prod', None), ('fixed', roi_box)):
        try:
            enh, p = ep.enhance(scene, sfm_coverage=1.0, roi_box=rb)
        except Exception as e:
            print(f'    {arm} failed: {e}')
            row[f'nfiq2_{arm}'] = None
            continue
        row[f'nfiq2_{arm}'] = nfiq2(enh, tmp)
        row[f'bgCoherence_{arm}'] = bg_ring_coherence(enh, gm_512)
        cv2.imwrite(os.path.join(OUT, f'{cid[:8]}_orient_{arm}.png'), enh)

    print(f'  {cid[:8]}  nfiq2 prod={row.get("nfiq2_prod")} fixed={row.get("nfiq2_fixed")}   '
          f'bgCoherence prod={row.get("bgCoherence_prod")} '
          f'fixed={row.get("bgCoherence_fixed")}')
    return row


def main(limit: int = 12):
    docs = population(limit)
    print(f'{len(docs)} real production front_only_v1 captures\n')
    out = os.path.join(RESULTS, 'nns_orientation_fix_test.json')
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
    pairs = [(r['nfiq2_prod'], r['nfiq2_fixed']) for r in rows
             if r.get('nfiq2_prod') is not None and r.get('nfiq2_fixed') is not None]
    if pairs:
        d = [b - a for a, b in pairs]
        print(f'NFIQ2:  prod {np.mean([p[0] for p in pairs]):.2f} -> '
              f'fixed {np.mean([p[1] for p in pairs]):.2f}  ({np.mean(d):+.2f}, '
              f'{sum(1 for x in d if x > 0)} better / {sum(1 for x in d if x < 0)} worse '
              f'/ {sum(1 for x in d if x == 0)} same, n={len(pairs)})')
    bg = [(r['bgCoherence_prod'], r['bgCoherence_fixed']) for r in rows
          if r.get('bgCoherence_prod') is not None and r.get('bgCoherence_fixed') is not None]
    if bg:
        d2 = [b - a for a, b in bg]
        print(f'background streak coherence:  prod {np.mean([p[0] for p in bg]):.3f} -> '
              f'fixed {np.mean([p[1] for p in bg]):.3f}  ({np.mean(d2):+.3f}, '
              f'lower = less streaked)')
    print(f'\nwrote {out}')


if __name__ == '__main__':
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 12)
