"""PHASE 5 -- RAW-DOMAIN fusion: composite BEFORE enhancement, enhance ONCE.

The structural problem every prior attempt in this track shares, stated
plainly: each source is put through `afis_print.generate()` SEPARATELY,
which runs its own orientation-field estimate and its own Gabor synthesis.
The Gabor bank does not reveal ridges, it DRAWS them from that field. Two
sources are therefore two INDEPENDENTLY SYNTHESISED ridge patterns, and
nothing ever made their ridge phase agree. Compositing them -- hard-edged,
feathered, softened, bridged, merged, angle-gated -- cannot produce
continuity, because continuity was destroyed before compositing began.
That is why every one of those experiments moved the score around without
ever producing a coherent print, and why the CTO's own read ("looks like
a print with smudges... I expect a coherent full print") is correct.

Raw-domain fusion removes the cause instead of treating it: register and
composite the RAW GRAYSCALE frames, then run the enhancement chain ONCE
over the fused result. There is then exactly one orientation field and one
Gabor pass spanning the whole print, so ridges are drawn continuously by
construction -- no seam to blend, because there is nothing to blend.

Crucially this needs NO new compositing code and NO production changes.
`generate()` already composites into `gray` BEFORE the enhancement chain
(its own `mosaic` branch does exactly this), and production already has
`_front_anchored_mosaic_zones()` -- which crops every source to a common
pad-dominated region first (its docstring documents the real 2026-08-08
measurement showing whole-frame ECC locks onto the static ROOM rather
than the pad), ECC-registers, coherence-weight blends anchored on the
front's own coherence, and returns the adjusted guide region the final
`generate()` call needs. This just feeds fusion_v1's sources into it.

WHAT THIS DOES NOT INHERIT, stated up front: this uses production's ECC
registration, NOT this track's own TPS. That is deliberate for a first
prototype -- it isolates the raw-vs-render question by changing exactly
one thing. If raw-domain shows promise, TPS-warping the raw frames before
compositing is the obvious follow-up; if it does not, TPS was never going
to rescue it and the negative is cheaper to establish this way.

HONEST PRIOR: this is the same FAMILY as four prior pixel-fusion attempts
that all lost (sweep cross-zone mosaic, field-domain fusion,
focusZoneSplice, zone reduction), and production's own `mosaicFreq`
variant -- which is this exact mechanism -- has won 0 of 116 real
captures. What makes it worth one real test anyway is that none of those
eliminated the two-independent-Gabor-syntheses cause; they all mitigated
its symptoms. Report the result either way.

Read-only: Firestore/Storage reads, no writes outside fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'functions', 'processEnhanceAndScore'))

import cv2                                     # noqa: E402
import numpy as np                             # noqa: E402

import afis_print as ap                        # noqa: E402  (production, read-only)
import minutiae_io as mio                      # noqa: E402
from phase0c_real_fusion_capture import (      # noqa: E402
    _db, collect_sources, _render, CACHE,
)
from phase1_consensus_fusion import _normalized_ink_xyt   # noqa: E402
from phase2_tps_fusion import _ref_xyt, _best_score, MACRO_REFS  # noqa: E402


def _gray(img: np.ndarray) -> np.ndarray:
    return img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)


def run(cap_id: str, tag: str = 'rawdomain') -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== PHASE 5 raw-domain fusion -- {cap_id[:12]} ===')
    srcs = collect_sources(v)
    if 'front_v1' not in srcs:
        print('  no front_v1 anchor, stopping')
        return None

    # `_front_anchored_mosaic_zones` keys the anchor as 'center' by
    # contract; every other key is a side. Sources whose raw frame is a
    # different shape than the anchor's are dropped by that function
    # itself (it compares `g.shape[:2] == (h, w)`), so no filtering here.
    anchor_img, anchor_guide = srcs['front_v1']
    zone_grays: Dict[str, Tuple[np.ndarray, dict]] = {
        'center': (_gray(anchor_img), anchor_guide)
    }
    for name, (img, guide) in srcs.items():
        if name == 'front_v1':
            continue
        zone_grays[name] = (_gray(img), guide)
    print(f'  sources into mosaic: {sorted(zone_grays)}')

    mos, adj_guide, n_used = ap._front_anchored_mosaic_zones(zone_grays)
    if mos is None:
        print('  raw-domain mosaic FAILED (registration or crop derivation) '
              '-- this is itself a real result, not an error')
        return {'capture': cap_id, 'mosaic': False}
    print(f'  mosaic built: {mos.shape}, sides actually used = {n_used} '
          f'(of {len(zone_grays) - 1} offered)')

    raw_mos_path = os.path.join(CACHE, f'{cap_id[:12]}_rawmosaic.png')
    cv2.imwrite(raw_mos_path, mos)

    # ONE enhancement pass over the fused raw -- the whole point.
    out, params = ap.generate([mos], [0.0], [None], guide_region=adj_guide,
                              freq_normalize=True, stack_cache={})
    if out is None:
        print('  generate() returned None on the mosaic')
        return {'capture': cap_id, 'mosaic': True, 'generate': False}
    comp = out if out.ndim == 2 else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
    comp_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.png')
    cv2.imwrite(comp_path, comp)
    print(f'  wrote raw-domain print -> {os.path.basename(comp_path)}')

    # Anchor-alone baseline, rendered the exact same way every other phase
    # in this track renders it (so the comparison is like-for-like).
    a_print = _render(anchor_img, anchor_guide, f'{cap_id[:12]}_front_v1')
    if a_print is None:
        print('  anchor render failed')
        return None

    a_minu = mio.extract_minutiae(a_print, source='anchor')
    c_minu = mio.extract_minutiae(comp, source='composite')
    print(f'\n  anchor alone : {len(a_minu):4} minutiae')
    print(f'  raw-domain   : {len(c_minu):4} minutiae')

    anchor_xyt = os.path.join(CACHE, f'{cap_id[:12]}_anchor_alone_stage3.xyt')
    comp_xyt = os.path.join(CACHE, f'{cap_id[:12]}_{tag}.xyt')
    mio.write_xyt(a_minu, anchor_xyt)
    mio.write_xyt(c_minu, comp_xyt)

    refs: Dict[str, str] = {}
    ink = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))
    if ink:
        refs['ink_scan'] = ink
    for rn, rp in MACRO_REFS.items():
        r = _ref_xyt(rn, rp)
        if r:
            refs[rn] = r

    scores = {'anchor_alone': {}, 'raw_domain': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt, rx)
        scores['raw_domain'][rn] = _best_score(comp_xyt, rx)

    print('\n  bozorth3 (higher = better match):')
    print('  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs))
    for cn in ('anchor_alone', 'raw_domain'):
        row = '  ' + f'{cn:16}'
        for rn in refs:
            row += f'{str(scores[cn][rn]):>16}'
        print(row)

    beat = informative = 0
    print('\n  VERDICT (per reference):')
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['raw_domain'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        vv = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} raw-domain {c} {vv} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'raw-domain beats anchor-alone on {beat}.')

    result = {'capture': cap_id, 'mosaic': True, 'sides_used': int(n_used),
              'sides_offered': len(zone_grays) - 1,
              'anchor_minutiae': len(a_minu), 'composite_minutiae': len(c_minu),
              'scores': scores, 'raw_mosaic_path': raw_mos_path,
              'composite_path': comp_path,
              'afis_params': {k: (float(x) if isinstance(x, (int, float)) else str(x))
                              for k, x in (params or {}).items()}}
    out_p = os.path.join(HERE, 'results', f'phase5_rawdomain_{cap_id[:8]}.json')
    with open(out_p, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out_p}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase5_raw_domain_fusion.py <captureId> [tag]')
        sys.exit(1)
    run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'rawdomain')
