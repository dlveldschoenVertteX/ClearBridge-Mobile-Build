"""Are the stack path's two internal decisions both measuring background?

Two separate findings this session point at the same shape of defect, so
they are tested together here rather than one at a time:

  1. `generate()`'s nested `_ridge_energy` ORDERS the stack pool from a
     DoG band-energy probe on a CENTRE-HALF crop of the frame. Measured on
     real production captures, the guide occupies 12.5% of that crop, so
     87.5% of what decides the ordering is background.
  2. `_align_face_on_stack` ACCEPTS an aligned frame on
     `corrcoef(aligned, ref) > 0.5` over the ENTIRE frame -- again mostly
     background. 21% of stack arms (20 of 96) returned nothing at all in
     stack_policy_test.py, which is what that guard failing looks like from
     outside: fewer than 2 frames survive, so the whole stack is dropped.

Four arms, one variable at a time, so a win can be attributed:

  prod        centre-crop ranking, full-frame guard  (what runs today)
  rank        guide-restricted ranking, full-frame guard
  guard       centre-crop ranking, guide-restricted guard
  both        guide-restricted ranking and guard

The ranking arm deliberately keeps production's own DoG probe and changes
ONLY the region it is measured over. stack_policy_test.py already tested a
guide-region ranking that used a DIFFERENT metric (band energy x coherence)
and it lost by 1.8-2.4 points -- but that changed the region and the metric
together, so it cannot say which was responsible. This can.

Also reports, per arm, how many frames the alignment guard accepted and
rejected -- the failure rate is the point of arm 3 and is worth reading even
where the score does not move.

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from typing import Dict, List, Optional, Tuple

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
from stack_policy_test import prod_ridge_energy   # noqa: E402

_PROD_ALIGN = ap._align_face_on_stack


def guide_ridge_energy(arr: np.ndarray, mask: np.ndarray) -> float:
    """Production's own DoG probe, measured inside the guide instead of on a
    centre-half crop. Same sigmas, same |lo - hi| mean -- the ONLY change is
    the region, which is what makes this arm attributable."""
    g = arr if arr.ndim == 2 else cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY)
    f = g.astype(np.float32)
    d = np.abs(cv2.GaussianBlur(f, (0, 0), 1.2) - cv2.GaussianBlur(f, (0, 0), 3.5))
    return float(d[mask > 0].mean()) if (mask > 0).any() else float(d.mean())


def make_align(mask: Optional[np.ndarray], stats: Dict[str, int]):
    """`_align_face_on_stack` with the accept-guard optionally restricted to
    the guide. Everything else -- downscale, CLAHE, MOTION_AFFINE, criteria,
    the 0.5 threshold itself -- is copied unchanged from production so the
    only variable is WHERE the correlation is measured."""
    def _align(cand, gyros=None, align_cache=None, align_key=None):
        if align_cache is not None and align_key is not None and align_key in align_cache:
            return align_cache[align_key]
        pairs = list(zip(cand, gyros if gyros is not None else [None] * len(cand)))
        grays = [(c if c is None or c.ndim == 2 else cv2.cvtColor(c, cv2.COLOR_BGR2GRAY), gy)
                 for c, gy in pairs]
        grays = [(g, gy) for g, gy in grays if g is not None]
        if len(grays) < 2:
            return None
        ref, ref_gyro = grays[0]
        h, w = ref.shape[:2]
        s = ap._STACK_ALIGN_PX / max(h, w)
        small = (max(1, int(w * s)), max(1, int(h * s)))
        cl = cv2.createCLAHE(3.0, (8, 8))
        ref_small = cl.apply(cv2.resize(ref, small))
        up = np.array([[1 / s, 0, 0], [0, 1 / s, 0]], dtype=np.float32)
        dn = np.array([[s, 0, 0], [0, s, 0], [0, 0, 1]], dtype=np.float32)
        crit = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 80, 1e-4)
        sel = None
        if mask is not None:
            m = mask if mask.shape[:2] == (h, w) else cv2.resize(
                mask, (w, h), interpolation=cv2.INTER_NEAREST)
            sel = m > 0
            if not sel.any():
                sel = None
        stack = [ref.astype(np.float32)]
        stack_gyros = [ref_gyro]
        for g, gy in grays[1:]:
            gg = g if g.shape[:2] == (h, w) else cv2.resize(g, (w, h))
            try:
                warp = np.eye(2, 3, dtype=np.float32)
                _, warp = cv2.findTransformECC(
                    ref_small, cl.apply(cv2.resize(gg, small)), warp,
                    cv2.MOTION_AFFINE, crit, None, 5)
                warp_full = (up @ np.vstack([warp, [0, 0, 1]]) @ dn).astype(np.float32)
                aligned = cv2.warpAffine(gg, warp_full, (w, h), flags=cv2.INTER_LINEAR)
                a = aligned[sel] if sel is not None else aligned.ravel()
                r = ref[sel] if sel is not None else ref.ravel()
                if float(np.corrcoef(a.ravel(), r.ravel())[0, 1]) > 0.5:
                    stack.append(aligned.astype(np.float32))
                    stack_gyros.append(gy)
                    stats['accepted'] += 1
                else:
                    stats['rejected'] += 1
            except cv2.error:
                stats['ecc_error'] += 1
                continue
        out = None if len(stack) < 2 else (stack, stack_gyros)
        if out is None:
            stats['stack_dropped'] += 1
        if align_cache is not None and align_key is not None:
            align_cache[align_key] = out
        return out
    return _align


ARMS = (('prod', False, False), ('rank', True, False),
        ('guard', False, True), ('both', True, True))


def run_capture(doc: dict, tmp: str) -> Optional[dict]:
    cid, guide = doc['_id'], doc['guideRegion']
    loaded = []
    for e in doc['frames']:
        blob = _bucket.blob(e['path'])
        if not blob.exists():
            continue
        arr = cv2.imdecode(np.frombuffer(blob.download_as_bytes(), np.uint8),
                           cv2.IMREAD_COLOR)
        if arr is not None:
            loaded.append({'flash': bool(e.get('flashOn')),
                           'client_lap': float(e.get('laplacianScore') or 0.0),
                           'img': _center_square(arr)})
    amb = [f for f in loaded if not f['flash']]
    fl = [f for f in loaded if f['flash']]
    if len(loaded) < 2 or not amb or not fl:
        return None

    gm = ap._superellipse_mask(loaded[0]['img'].shape[:2], guide)
    if gm is None or not (gm > 0).any():
        return None
    for f in loaded:
        f['prod_re'] = prod_ridge_energy(f['img'])
        f['guide_re'] = guide_ridge_energy(f['img'], gm)

    amb_burst = [f['img'] for f in sorted(amb, key=lambda f: -f['client_lap'])]
    fl_burst = [f['img'] for f in sorted(fl, key=lambda f: -f['client_lap'])]

    row: Dict[str, object] = {'captureId': cid}
    for arm, guide_rank, guide_guard in ARMS:
        key = 'guide_re' if guide_rank else 'prod_re'
        pool = [f['img'] for f in sorted(loaded, key=lambda f: -f[key])][:ap._STACK_MAX]
        stats = {'accepted': 0, 'rejected': 0, 'ecc_error': 0, 'stack_dropped': 0}
        ap._align_face_on_stack = make_align(gm if guide_guard else None, stats)
        try:
            for focus in (False, True):
                vname = 'focusStack' if focus else 'stack'
                fn = ap._focus_stack_face_on if focus else ap._stack_face_on
                st = fn(pool, None, {}, None)
                score = None
                if st is not None:
                    try:
                        out, _ = ap.generate(
                            [st], [0.0], [None], guide_region=guide,
                            freq_normalize=True, stack_cache={},
                            ambient_frames=[amb_burst[0]],
                            flash_frames=[fl_burst[0]],
                            ambient_burst=amb_burst, flash_burst=fl_burst)
                        if out is not None:
                            score = nfiq2(out if out.ndim == 2 else
                                          cv2.cvtColor(out, cv2.COLOR_BGR2GRAY), tmp)
                    except Exception as e:
                        print(f'    {arm}/{vname} render failed: {e}')
                row[f'{vname}_{arm}'] = score
        finally:
            ap._align_face_on_stack = _PROD_ALIGN
        row[f'align_{arm}'] = dict(stats)

    print(f'  {cid[:8]}  ' + '  '.join(
        f'{a}={row.get(f"stack_{a}")}/{row.get(f"focusStack_{a}")}'
        f'[{row[f"align_{a}"]["accepted"]}a{row[f"align_{a}"]["rejected"]}r'
        f'{row[f"align_{a}"]["ecc_error"]}e]' for a, _, _ in ARMS))
    return row


def summarise(rows: List[dict]) -> None:
    print('\n=== RESULT ===')
    for vname in ('stack', 'focusStack'):
        print(f'\n{vname}')
        for arm, _, _ in ARMS:
            pairs = [(r[f'{vname}_prod'], r[f'{vname}_{arm}']) for r in rows
                     if r.get(f'{vname}_prod') is not None
                     and r.get(f'{vname}_{arm}') is not None]
            if not pairs:
                continue
            d = [b - a for a, b in pairs]
            print(f'  {arm:<6} mean {np.mean([p[1] for p in pairs]):6.2f}  '
                  f'vs prod {np.mean(d):+6.2f}  '
                  f'({sum(1 for x in d if x > 0)} better / '
                  f'{sum(1 for x in d if x < 0)} worse, n={len(pairs)})')
    print('\nalignment guard, summed over captures')
    print(f'  {"arm":<6}{"accepted":>10}{"rejected":>10}{"ecc err":>9}'
          f'{"stacks dropped":>16}')
    for arm, _, _ in ARMS:
        s = {k: sum(r[f'align_{arm}'][k] for r in rows)
             for k in ('accepted', 'rejected', 'ecc_error', 'stack_dropped')}
        print(f'  {arm:<6}{s["accepted"]:>10}{s["rejected"]:>10}'
              f'{s["ecc_error"]:>9}{s["stack_dropped"]:>16}')


def main(limit: int = 12):
    docs = population(limit)
    print(f'{len(docs)} real production front_only_v1 captures\n')
    out = os.path.join(RESULTS, 'sweep_stack_internals.json')
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
    summarise(rows)
    print(f'\nwrote {out}')


if __name__ == '__main__':
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 12)
