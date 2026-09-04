"""STAGE C follow-up #3 -- merge/dilate neighboring kept-minutiae discs
into contiguous regions instead of leaving them as separate small blobs.

Direct visual review (results/PHASE3_COMPOSITE_FINDINGS.md, 2026-08-26,
prompted by a real screenshot the CTO had of a composite sent a week
earlier) found that BOTH phase3_composite.py and
phase3c_continuous_blend.py produce a core print surrounded by several
small DISCONNECTED patches of ridge texture, not one coherent print --
because `_keep_mask` draws an independent 24px-radius disc around each
individually-kept minutia, and sparse kept points mostly don't have
their discs touch. bozorth3 doesn't penalize this (it scores point
correspondence, not visual contiguity), so phase3c's real matching-score
win says nothing about whether the image is one connected print.

THIS VERSION starts from phase3c's own already-validated softened-blend
compositing (unchanged: same rigid+TPS registration, same fm.fuse
selective-merge cap, same Gaussian-blur-before-composite / binarize-
once-at-the-end policy) and swaps ONLY the keep-mask construction:
after drawing the same per-point discs, applies a morphological CLOSE
with an elliptical kernel sized to bridge realistic point-to-point
gaps, so discs whose points sit near each other merge into one
contiguous region, while genuinely isolated points (far from every
other kept point) stay isolated -- which is the visually correct
behaviour there, since there is nothing real to interpolate between two
unrelated points. The merged mask is then blurred (not left hard-edged)
before use as a blend weight, matching phase3c's own softening
discipline rather than reintroducing a hard boundary at the new seam.

CLOSE_RADIUS_PX is a first-cut, reasoned-not-tuned value (not swept
against real point-spacing statistics) -- report the real result
honestly, do not oversell it as calibrated.

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
from phase3_composite import _rigid_matrix, _coherence, KEEP_RADIUS_PX, DEFAULT_MAX_ADDED  # noqa: E402
from phase3c_continuous_blend import BLUR_SIGMA  # noqa: E402
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

# Morphological-close kernel radius, in px. A gap between two discs
# smaller than roughly this bridges into one region; a gap bigger than
# it stays separate. 30px is a first-cut choice (discs are 24px radius,
# so this lets two discs whose CENTRES are up to ~2*(24+30)=108px apart
# still fuse into one blob) -- not derived from a measured real
# point-spacing distribution, flagged honestly rather than presented as
# tuned.
CLOSE_RADIUS_PX = 30.0

# Feather the merged mask's own new edges so the blender still sees a
# soft boundary, not a hard one reintroduced by the morphological op.
FEATHER_SIGMA_PX = 6.0


def _keep_mask_merged(points_xy: List[Tuple[float, float]], shape: Tuple[int, int],
                       radius: float = KEEP_RADIUS_PX,
                       close_radius: float = CLOSE_RADIUS_PX,
                       feather_sigma: float = FEATHER_SIGMA_PX) -> np.ndarray:
    h, w = shape
    mask = np.zeros((h, w), dtype=np.uint8)
    for x, y in points_xy:
        cv2.circle(mask, (int(round(x)), int(round(y))), int(round(radius)), 255, -1)
    if mask.max() == 0:
        return np.zeros((h, w), dtype=np.float64)
    if close_radius > 0:
        k = int(round(close_radius)) * 2 + 1
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mf = mask.astype(np.float64) / 255.0
    if feather_sigma > 0:
        mf = cv2.GaussianBlur(mf, (0, 0), feather_sigma)
    return np.clip(mf, 0.0, 1.0)


def run(cap_id: str, max_added: int = DEFAULT_MAX_ADDED,
        blur_sigma: float = BLUR_SIGMA,
        close_radius: float = CLOSE_RADIUS_PX) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== Stage C+merged-regions -- {cap_id[:12]} '
          f'(max_added={max_added}, blur_sigma={blur_sigma}, close_radius={close_radius}) ===')
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

    # ---- Composite the SOFTENED renders, merged-region keep mask ----
    tex_list: List[np.ndarray] = [a_soft.astype(np.float64)]
    weight_list: List[np.ndarray] = [a_cov.astype(np.float64)]
    inv_a_cov = 1.0 - a_cov.astype(np.float64)

    # All kept points across every source, merged into ONE mask -- points
    # from different sources that happen to sit near each other in anchor
    # space should merge too, not just points within the same source.
    all_kept_pts = [(m.x, m.y) for m in fused if m.source != anchor]
    merged_keep = _keep_mask_merged(all_kept_pts, a_shape, close_radius=close_radius)

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

        # Coherence measured on the UN-softened warped print, same reason
        # as phase3c: blurring first would itself lower measured ridge
        # coherence and distort the confidence signal.
        raw_rigid = cv2.warpAffine(
            prints[name], M, (a_shape[1], a_shape[0]),
            flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        raw_warped = tps.warp_image(warp, raw_rigid, a_shape)
        coh = np.clip(_coherence(raw_warped), 0.0, 1.0)

        w = warped_cov * merged_keep * coh * inv_a_cov
        if w.max() <= 0:
            continue
        tex_list.append(warped_img.astype(np.float64))
        weight_list.append(w)
        print(f'    {name:16} composited (softened, merged-region) near {n_kept} kept points')

    blended, total_w = _multiband_combine(tex_list, weight_list, num_bands=5)
    blended_gray = np.where(total_w > 0, blended, 255.0)
    composite = np.where(blended_gray < 127, 0, 255).astype(np.uint8)

    out_img_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_merged.png')
    cv2.imwrite(out_img_path, composite)
    print(f'\n  wrote composite image -> {out_img_path}')

    # ---- Score, same real references and harness as every prior phase ----
    comp_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_merged.xyt')
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

    scores: Dict[str, Dict[str, Optional[int]]] = {'anchor_alone': {}, 'merged_composite': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt_path, rx)
        scores['merged_composite'][rn] = _best_score(comp_xyt_path, rx)

    print(f'\n  bozorth3 (higher = better match):')
    header = '  ' + f'{"candidate":16}' + ''.join(f'{r:>16}' for r in refs)
    print(header)
    for cname in ('anchor_alone', 'merged_composite'):
        row = '  ' + f'{cname:16}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    print('\n  VERDICT (per reference):')
    beat, informative = 0, 0
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['merged_composite'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        vv = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} merged {c} {vv} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'merged-region composite beats anchor-alone on {beat}.')

    result = {'capture': cap_id, 'max_added': max_added, 'blur_sigma': blur_sigma,
              'close_radius': close_radius, 'scores': scores,
              'composite_image_path': out_img_path}
    out = os.path.join(HERE, 'results', 'phase3d_merged_regions.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase3d_merged_regions.py <captureId> [max_added] [blur_sigma] [close_radius]')
        sys.exit(1)
    cap = sys.argv[1]
    ma = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_ADDED
    bs = float(sys.argv[3]) if len(sys.argv) > 3 else BLUR_SIGMA
    cr = float(sys.argv[4]) if len(sys.argv) > 4 else CLOSE_RADIUS_PX
    run(cap, ma, bs, cr)
