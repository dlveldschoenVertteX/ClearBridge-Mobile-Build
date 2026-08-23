"""PHASE 1 runner -- build a fused minutiae template for one real fusion_v1
capture and score it against single-best-candidate on real bozorth3
matchability. The actual gate this whole track lives or dies by (see
fusion_brain/README.md): "Must beat single-best-candidate on real
SourceAFIS separation to proceed."

Reuses phase0c_real_fusion_capture.py's own render/register pipeline
verbatim (same cache, same sources) rather than re-deriving it -- this
script only adds the fusion + scoring step on top of data phase0c already
produces.

"Single-best-candidate" here is the front_v1 anchor alone: that is exactly
what production delivers today (max-of-variants selection of a single
source), so it is the correct, real baseline to beat -- not a strawman.

Read-only: Firestore/Storage reads, no writes anywhere outside
fusion_brain/results/.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'functions', 'processEnhanceAndScore'))

import cv2                                     # noqa: E402
import numpy as np                             # noqa: E402

import minutiae_io as mio                      # noqa: E402
import registration as reg                     # noqa: E402
import fuse_minutiae as fm                     # noqa: E402
import mindtct_client as mc                    # noqa: E402
from phase0c_real_fusion_capture import (      # noqa: E402
    _db, collect_sources, _render, _coverage, _warp_coverage,
    DIST_TOL, ANGLE_TOL, CACHE,
)

INK_SCAN_PATH = ('/tmp/claude-0/-home-user-ClearBridge-Mobile-Build/'
                  '7c276512-7b7e-5f85-8f5b-2eb1bc5e7593/scratchpad/ps/ink_scan.jpg')


def _load_gray(path: str) -> np.ndarray:
    from PIL import Image
    return np.array(Image.open(path).convert('L'))


def _normalized_ink_xyt(out_path: str) -> str:
    """Same DPI-normalization convention every other real matchability check
    this project runs uses (mindtct_client._normalize_dpi, target ~9px ridge
    period -- the identical domain afis_print.generate(freq_normalize=True)
    already normalizes every rendered print toward). Cached so repeat runs
    don't re-extract."""
    if os.path.exists(out_path):
        return out_path
    gray = _load_gray(INK_SCAN_PATH)
    norm, scale = mc._normalize_dpi(gray)
    print(f'  ink scan: native shape {gray.shape}, DPI-normalize scale={scale}')
    ms = mio.extract_minutiae(norm, source='ink_scan')
    mio.write_xyt(ms, out_path)
    print(f'  ink scan minutiae: {len(ms)}')
    return out_path


def run(cap_id: str):
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return

    print(f'\n=== Phase 1 consensus fusion: {cap_id[:12]} ===')
    srcs = collect_sources(v)
    if 'front_v1' not in srcs:
        print('  no front_v1 anchor, stopping')
        return
    print(f'  sources: {sorted(srcs.keys())}')

    prints, minu = {}, {}
    for name, (img, guide) in srcs.items():
        p = _render(img, guide, f'{cap_id[:12]}_{name}')
        if p is None:
            continue
        prints[name] = p
        minu[name] = mio.extract_minutiae(p, source=name)

    anchor = 'front_v1'
    if anchor not in prints:
        print('  anchor render failed, stopping')
        return
    a_minu = minu[anchor]
    a_shape = prints[anchor].shape[:2]

    transforms, reg_minu, cov = {}, {anchor: a_minu}, {anchor: _coverage(prints[anchor])}
    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            print(f'    {name:16} registration failed, excluded from fusion entirely')
            continue
        transforms[name] = t
        reg_minu[name] = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)

    fused, reliability, contributed = fm.fuse(minu, reg_minu, cov, transforms, anchor)

    print(f'\n  {"source":16} {"inliers":>9} {"total":>7} {"frac":>6}  {"gate":>6}  {"added":>6}')
    print(f'  {anchor:16} {"(anchor)":>9} {len(a_minu):7} {"--":>6}  {"n/a":>6}  {len(a_minu):6}')
    for name, r in reliability.items():
        verdict = 'PASS' if r.passed else 'REJECT'
        print(f'  {name:16} {r.inliers:9} {r.total:7} {r.inlier_frac:6.2f}  '
              f'{verdict:>6}  {contributed.get(name, 0):6}')

    print(f'\n  anchor alone:  {len(a_minu)} minutiae')
    print(f'  fused:         {len(fused)} minutiae '
          f'(+{len(fused) - len(a_minu)} from {sum(1 for r in reliability.values() if r.passed)} '
          f'reliable non-anchor source(s))')

    # -- Score both against the real ink scan, same bozorth3 gate this
    # project has used throughout, same DPI-normalization convention. --
    anchor_xyt = os.path.join(CACHE, f'{cap_id[:12]}_anchor.xyt')
    fused_xyt = os.path.join(CACHE, f'{cap_id[:12]}_fused.xyt')
    mio.write_xyt(a_minu, anchor_xyt)
    mio.write_xyt(fused, fused_xyt)
    ink_xyt = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))

    anchor_score = mio.bozorth_match(anchor_xyt, ink_xyt)
    fused_score = mio.bozorth_match(fused_xyt, ink_xyt)
    anchor_score_r = mio.bozorth_match(ink_xyt, anchor_xyt)
    fused_score_r = mio.bozorth_match(ink_xyt, fused_xyt)

    print(f'\n  bozorth3 vs real ink scan (both directions, higher of the two):')
    print(f'    anchor alone -> ink: {anchor_score}   ink -> anchor: {anchor_score_r}   '
          f'best: {max(x for x in (anchor_score, anchor_score_r) if x is not None)}')
    print(f'    fused        -> ink: {fused_score}   ink -> fused: {fused_score_r}   '
          f'best: {max(x for x in (fused_score, fused_score_r) if x is not None)}')

    a_best = max(x for x in (anchor_score, anchor_score_r) if x is not None)
    f_best = max(x for x in (fused_score, fused_score_r) if x is not None)
    print(f'\n  VERDICT: fused {"BEATS" if f_best > a_best else "DOES NOT BEAT" if f_best < a_best else "TIES"} '
          f'anchor-alone on this one real capture ({f_best} vs {a_best})')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase1_consensus_fusion.py <captureId>')
        sys.exit(1)
    run(sys.argv[1])
