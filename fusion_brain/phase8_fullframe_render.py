"""PHASE 8 -- fix the crop path: register in crop space, RENDER full-frame.

The problem this fixes, established in Phase 7 by chasing a 17-point gap
that should not have existed. Rendering the SAME anchor two ways gives two
genuinely different prints from identical pad pixels:

    full frame  135 minutiae  40,905 ink   34 / 44 / 29 / 31
    crop        135 minutiae  36,675 ink   24 / 27 / 27 / 36

32% of pixels disagree after alignment. Phase 6's entire 2x2 was scored
against the CROP-rendered control, i.e. against an already-handicapped
baseline, which is why "beats the control" there was a weaker claim than
it looked.

Two candidate mechanisms were tested rather than assumed:

  * mask-aware `_normalize` -- REFUTED, byte-identical output. `_normalize`
    is a pure affine intensity map and everything downstream is
    affine-invariant.
  * CLAHE tile scale -- REAL. `tileGridSize=(8, 8)` is relative to the
    IMAGE, so the same pad gets 533x400px tiles full-frame and 308x320px
    tiles in the crop, and CLAHE is nonlinear and local. Forcing a common
    physical tile size DOES move minutiae counts and scores -- but it made
    both paths WORSE than the full-frame baseline and did not make them
    converge, so it is a real sensitivity, not a fix.

So this does not try to make the crop render better. It stops rendering
from the crop at all.

WHY THE CROP EXISTS AT ALL, so this does not throw it away: production's
`_front_anchored_mosaic_zones` crops to a pad-dominated region because
whole-frame ECC locks onto the static ROOM rather than the pad (its own
docstring records that real 2026-08-08 measurement). Registration
genuinely needs the crop. The RENDER does not.

THE FIX: build the mosaic in crop space exactly as before, then paste the
finished mosaic back into a copy of the full frame at the crop's own
offset and run `generate()` once on THAT, with the ORIGINAL full-frame
guide. Registration keeps its pad-dominated view; enhancement keeps the
full-frame framing it demonstrably prefers. Nothing is resampled and no
pixel outside the crop box is altered, so the only change versus Phase 6
is which framing the enhancement chain sees.

Read-only: Firestore/Storage reads, no writes outside fusion_brain/.
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
import phase6_tps_maxc_mosaic as p6             # noqa: E402
from phase0c_real_fusion_capture import (       # noqa: E402
    _db, collect_sources, CACHE,
)
from phase2_tps_fusion import _best_score        # noqa: E402

REF_NAMES = ('macro_round32', 'main_round32', 'macro_round35', 'main_round35')


def _score(pr: np.ndarray, tag: str, refs: Dict[str, str], cap: str):
    mm = mio.extract_minutiae(pr, source=tag)
    xp = os.path.join(CACHE, f'{cap[:12]}_p8_{tag}.xyt')
    mio.write_xyt(mm, xp)
    return len(mm), {rn: _best_score(xp, rp) for rn, rp in refs.items()}


def run(cap_id: str, combine: str = 'avg') -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== PHASE 8 full-frame render -- {cap_id[:12]} combine={combine} ===')
    srcs = collect_sources(v)
    if 'front_v1' not in srcs:
        print('  no anchor'); return None
    a_img, a_g = srcs['front_v1']
    a_gray = p6._gray(a_img)
    shape = a_gray.shape[:2]

    zg = {'center': (a_gray, a_g)}
    for n, (i, g) in srcs.items():
        if n != 'front_v1':
            zg[n] = (p6._gray(i), g)
    box = p6._common_crop(zg, shape)
    if box is None:
        print('  crop derivation failed'); return None
    x0, x1, y0, y1 = box
    a_crop = a_gray[y0:y1, x0:x1]
    adj = p6._adjust_guide(a_g, box, shape)
    print(f'  full frame {shape[1]}x{shape[0]}, crop {a_crop.shape[1]}x{a_crop.shape[0]}')

    # --- registration in CROP space, unchanged from Phase 6 -------------
    sides: List[np.ndarray] = []
    vmasks: List[Optional[np.ndarray]] = []
    for name, (g, _guide) in zg.items():
        if name == 'center' or g.shape[:2] != shape:
            continue
        out = p6._ecc_register(a_crop, g[y0:y1, x0:x1])
        if out is None:
            continue
        sides.append(out[0])
        vmasks.append(out[1])
    mos, used = p6._mosaic(a_crop, sides, combine, vmasks)
    if mos is None:
        print('  mosaic produced nothing'); return None
    print(f'  sides used: {used}/{len(sides)}')

    # --- paste the finished mosaic back into the full frame -------------
    # No resampling, and nothing outside the crop box is touched, so the
    # ONLY difference from Phase 6 is the framing the enhancement sees.
    pasted = a_gray.copy()
    pasted[y0:y1, x0:x1] = mos

    refs = {}
    for rn in REF_NAMES:
        p = os.path.join(CACHE, f'ref_{rn}.xyt')
        if os.path.exists(p):
            refs[rn] = p

    arms = [
        ('anchor_fullframe', a_gray, a_g),        # best known baseline
        ('anchor_crop', a_crop, adj),             # Phase 6's handicapped control
        ('mosaic_crop', mos, adj),                # Phase 6's own arm
        ('mosaic_fullframe', pasted, a_g),        # THE FIX
    ]
    print(f'\n  {"arm":22}{"minutiae":>9}'
          + ''.join(f'{r.replace("_round", ""):>13}' for r in refs))
    print('  ' + '-' * (31 + 13 * len(refs)))
    res: Dict[str, dict] = {}
    for lab, img, g in arms:
        out, _ = ap.generate([img], [0.0], [None], guide_region=g,
                             freq_normalize=True, stack_cache={})
        if out is None:
            print(f'  {lab:22} render failed'); continue
        pr = out if out.ndim == 2 else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
        cv2.imwrite(os.path.join(CACHE, f'{cap_id[:12]}_p8_{lab}.png'), pr)
        n, sc = _score(pr, lab, refs, cap_id)
        print(f'  {lab:22}{n:>9}' + ''.join(f'{str(sc[r]):>13}' for r in refs))
        res[lab] = {'minutiae': n, 'scores': sc}

    base = res.get('anchor_fullframe', {}).get('scores', {})
    fix = res.get('mosaic_fullframe', {}).get('scores', {})
    old = res.get('mosaic_crop', {}).get('scores', {})
    if base and fix and old:
        b = sum(1 for r in refs if fix.get(r) is not None
                and old.get(r) is not None and fix[r] > old[r])
        c = sum(1 for r in refs if fix.get(r) is not None
                and base.get(r) is not None and fix[r] > base[r])
        print(f'\n  full-frame render beats crop render on {b}/{len(refs)} references')
        print(f'  fused full-frame beats anchor-alone on   {c}/{len(refs)} references')

    out_p = os.path.join(HERE, 'results', f'phase8_fullframe_{cap_id[:8]}.json')
    with open(out_p, 'w') as fh:
        json.dump({'capture': cap_id, 'combine': combine,
                   'sides_used': int(used), 'arms': res}, fh, indent=2)
    print(f'\nwrote {out_p}')
    return res


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase8_fullframe_render.py <captureId> [avg|maxc]')
        sys.exit(1)
    run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'avg')
