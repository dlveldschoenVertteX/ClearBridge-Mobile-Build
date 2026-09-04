"""STAGE C follow-up #2 -- blend SOFTENED (not hard-binary) content, then
threshold once at the end, instead of blending already-hard-binarized
black/white ridge maps.

PHASE3_COMPOSITE_FINDINGS.md's phase-correlation follow-up ruled out "a
small constant per-source translational offset" as the mechanism, and
raised an untested candidate instead: `sfm_pipeline._multiband_combine`
was built for smooth CONTINUOUS-TONE photographic content, and every image
composited by phase3/phase3b so far was already hard-binarized (pure
black/white) before compositing.

FIRST ATTEMPT at this test tried to intercept afis_print.generate()'s own
internal pre-threshold Gabor response (via a read-only in-process wrapper
on `_gabor_enhance`) -- abandoned after finding, from the real captured
shape, that generate() applies a real rotation + crease-trim + vignette +
final crop-to-bbox pipeline AFTER binarization, all before its actual
return. Correctly replaying that geometry outside production code would
mean reimplementing several real, non-trivial steps this track's own
"read-only, never reimplement production" discipline exists specifically
to avoid -- the exact risk class this project has been burned by before
(hand-copied geometry silently drifting from its real source, per
CLAUDE.md's own repeated `_scoreRoi`/`_focusPointScreenSpace` history).

THIS VERSION avoids that risk entirely: it never touches generate()'s
internals. It operates on `prints[name]` -- the SAME already-correct,
already-rotated/cropped/trimmed final print image phase3_composite.py
uses -- and applies a small Gaussian blur (re-using the exact anti-alias
technique afis_print.py already has on the shelf as `_AA_SIGMA`, shipped
OFF by default there because it measurably hurts NFIQ2 on a SINGLE
un-fused print; the question here is different -- does it help a
COMPOSITE survive its seams) before compositing, then binarizes the
composite once at the end instead of compositing already-binary content.
Real, lower-fidelity proxy for "give the blender smooth content" than the
true pre-threshold signal would have been, but zero reimplementation risk.

Read-only: Firestore/Storage reads, no writes outside fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'functions', 'processEnhanceAndScore'))

import cv2                                     # noqa: E402
import numpy as np                             # noqa: E402

import fuse_minutiae as fm                     # noqa: E402
import minutiae_io as mio                      # noqa: E402
import registration as reg                     # noqa: E402
import tps                                     # noqa: E402
from minutiae_io import Minutia                # noqa: E402
from phase0c_real_fusion_capture import (      # noqa: E402
    _db, collect_sources, _render, _coverage, _warp_coverage,
    DIST_TOL, ANGLE_TOL, CACHE,
)
from phase1_consensus_fusion import _normalized_ink_xyt   # noqa: E402
from phase2_tps_fusion import _ref_xyt, _best_score, MACRO_REFS  # noqa: E402
from phase3_composite import _rigid_matrix, _coherence, _keep_mask, DEFAULT_MAX_ADDED  # noqa: E402
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

# Soften before blending, not the AA sigma range afis_print.py already
# swept (0.0-1.6, measured to cost real NFIQ2 on a single print). Slightly
# larger here on purpose: the goal isn't cosmetic anti-aliasing, it's
# giving the Laplacian pyramid genuine low-frequency structure to blend
# across a seam with -- a bigger sigma than pure staircase-removal needs.
BLUR_SIGMA = 2.0


def run(cap_id: str, max_added: int = DEFAULT_MAX_ADDED,
        blur_sigma: float = BLUR_SIGMA) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== Stage C+softened-blend -- {cap_id[:12]} '
          f'(max_added={max_added}, blur_sigma={blur_sigma}) ===')
    srcs = collect_sources(v)
    prints, minu = {}, {}
    for name, (img, guide) in srcs.items():
        p = _render(img, guide, f'{cap_id[:12]}_{name}')
        if p is None:
            continue
        prints[name] = p
        minu[name] = mio.extract_minutiae(p, source=name)

    anchor = 'front_v1'
    if anchor not in prints:
        print('  no anchor, stopping')
        return None
    a_minu = minu[anchor]
    a_img = prints[anchor]
    a_shape = a_img.shape[:2]
    a_cov = _coverage(a_img)
    a_soft = cv2.GaussianBlur(a_img, (0, 0), blur_sigma)

    # ---- Rigid registration + TPS refinement, identical to Stage A/C ----
    transforms: Dict[str, reg.Transform] = {}
    rigid_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    cov: Dict[str, np.ndarray] = {anchor: a_cov}
    warps: Dict[str, tps.TpsWarp] = {}
    tps_minu: Dict[str, List[Minutia]] = {anchor: a_minu}

    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            continue
        transforms[name] = t
        rigid_minu[name] = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)
        warp, n_ctrl = tps.fit_from_correspondences(
            a_minu, rigid_minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if warp is None:
            tps_minu[name] = rigid_minu[name]
            continue
        warps[name] = warp
        tps_minu[name] = warp.apply_minutiae(rigid_minu[name])

    fused, reliability, contributed = fm.fuse(
        minu, tps_minu, cov, transforms, anchor, max_added=max_added)
    print(f'\n  anchor alone : {len(a_minu):4} minutiae')
    print(f'  composite    : {len(fused):4} minutiae (+{len(fused) - len(a_minu)})')

    # ---- Composite the SOFTENED renders, same policy as phase3 ----
    tex_list: List[np.ndarray] = [a_soft.astype(np.float64)]
    weight_list: List[np.ndarray] = [a_cov.astype(np.float64)]
    inv_a_cov = 1.0 - a_cov.astype(np.float64)

    for name, warp in warps.items():
        n_kept = contributed.get(name, 0)
        if n_kept == 0:
            continue
        M = _rigid_matrix(transforms[name])
        soft_src = cv2.GaussianBlur(prints[name], (0, 0), blur_sigma)
        rigid_img = cv2.warpAffine(
            soft_src, M, (a_shape[1], a_shape[0]),
            flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        warped_img = tps.warp_image(warp, rigid_img, a_shape)

        rigid_cov = cv2.warpAffine(
            (_coverage(prints[name]) * 255).astype(np.uint8), M,
            (a_shape[1], a_shape[0]), flags=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        warped_cov = (tps.warp_image(warp, rigid_cov, a_shape) > 127).astype(np.float64)

        kept_pts = [(m.x, m.y) for m in fused if m.source == name]
        keep = _keep_mask(kept_pts, a_shape).astype(np.float64)
        # Coherence measured on the UN-softened warped print -- blurring
        # first would itself lower measured ridge coherence and distort the
        # confidence signal; the blur is only for what gets fed to the
        # blender, not for judging where a source is trustworthy.
        raw_rigid = cv2.warpAffine(
            prints[name], M, (a_shape[1], a_shape[0]),
            flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        raw_warped = tps.warp_image(warp, raw_rigid, a_shape)
        coh = np.clip(_coherence(raw_warped), 0.0, 1.0)

        w = warped_cov * keep * coh * inv_a_cov
        if w.max() <= 0:
            continue
        tex_list.append(warped_img.astype(np.float64))
        weight_list.append(w)
        print(f'    {name:16} composited (softened) near {len(kept_pts)} kept points')

    blended, total_w = _multiband_combine(tex_list, weight_list, num_bands=5)
    blended_gray = np.where(total_w > 0, blended, 255.0)
    composite = np.where(blended_gray < 127, 0, 255).astype(np.uint8)

    out_img_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_softblend.png')
    cv2.imwrite(out_img_path, composite)
    print(f'\n  wrote composite image -> {out_img_path}')

    # ---- Score, same real references and harness as every prior phase ----
    comp_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_softblend.xyt')
    mio.write_xyt(mio.extract_minutiae(composite, source='composite'), comp_xyt_path)
    anchor_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_anchor_alone_stage3.xyt')
    mio.write_xyt(mio.extract_minutiae(a_img, source='anchor'), anchor_xyt_path)

    refs: Dict[str, str] = {}
    ink = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))
    if ink:
        refs['ink_scan'] = ink
    for rname, rpath in MACRO_REFS.items():
        r = _ref_xyt(rname, rpath)
        if r:
            refs[rname] = r

    scores: Dict[str, Dict[str, Optional[int]]] = {'anchor_alone': {}, 'soft_composite': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt_path, rx)
        scores['soft_composite'][rn] = _best_score(comp_xyt_path, rx)

    print(f'\n  bozorth3 (higher = better match):')
    header = '  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs)
    print(header)
    for cname in ('anchor_alone', 'soft_composite'):
        row = '  ' + f'{cname:16}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    print('\n  VERDICT (per reference):')
    beat, informative = 0, 0
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['soft_composite'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        vv = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} soft {c} {vv} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'soft-blended composite beats anchor-alone on {beat}.')

    result = {'capture': cap_id, 'max_added': max_added, 'blur_sigma': blur_sigma,
              'scores': scores, 'composite_image_path': out_img_path}
    out = os.path.join(HERE, 'results', 'phase3c_soft_blend.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase3c_continuous_blend.py <captureId> [max_added] [blur_sigma]')
        sys.exit(1)
    cap = sys.argv[1]
    ma = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_ADDED
    bs = float(sys.argv[3]) if len(sys.argv) > 3 else BLUR_SIGMA
    run(cap, ma, bs)
