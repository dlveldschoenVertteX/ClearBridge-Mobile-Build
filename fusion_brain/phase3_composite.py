"""STAGE C -- composite the TPS-registered, SELECTIVELY-fused minutiae into
an actual superprint IMAGE, per fusion_brain/README.md's own roadmap.

Phase 1 and Stage A both operate purely on minutiae point sets -- neither
produces a picture, which is what production actually needs to deliver.
This is that step, built on the SAME registration and the SAME selectivity
policy Stage A already validated (`fuse_minutiae.fuse(max_added=...)`),
never re-decided ad hoc:

1. Rigid-register + TPS-refine every source onto the anchor (identical to
   phase2_tps_fusion.py -- no new registration code).
2. Run the selective minutia merge (`fm.fuse`, same `max_added` cap Stage A's
   own dose-response sweep found promising) to decide WHICH points are worth
   adding, exactly as before.
3. NEW: for each source that actually contributed kept points, warp its
   PRINT IMAGE (not just its minutiae) into anchor space via the same rigid
   transform + TPS warp (`tps.warp_image`, already built and self-tested,
   never yet exercised on a real image before this file). Composite only
   near the SAME kept minutiae -- a small keep-radius disk around each one --
   rather than the source's whole new-coverage region. This operationalises
   Stage A's own selectivity finding in pixel space instead of inventing a
   separate blending heuristic: "add only the specific points worth adding"
   becomes "paint only the pixels around those specific points."
4. Blend with `sfm_pipeline._multiband_combine` (Laplacian-pyramid seam
   blending, already built for the cylindrical SfM path, unused elsewhere --
   this is its first use outside that path), gated so the anchor's own
   territory is NEVER touched (source weight is masked by
   `1 - anchor_coverage`) and each source pixel's contribution is further
   weighted by local ridge coherence, the same confidence signal
   `afis_print._fuse_flash_ambient` already uses for cross-illumination
   fusion -- reused, not reinvented.
5. Score the resulting REAL image against the SAME real references
   (ink_scan noise floor + the two real cross-session macro captures) used
   by every phase before this one, via the same real mindtct+bozorth3
   harness, gated on beating anchor-alone. This is the actual test: does a
   real composited PICTURE do what Stage A's point-set analysis predicted,
   or does image compositing reopen the phase-mismatch failure mode every
   PRIOR pixel-fusion attempt in this project hit (see README's own table)?

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
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

# Radius (px) painted around each individually-kept minutia when
# compositing pixels. Not a pinpoint dot -- a keep radius has to span a few
# ridge periods (afis_print normalises every print toward _TARGET_PERIOD =
# 9.0px) to show real local ridge FLOW rather than an isolated blob, but
# should stay well inside dist_tol*2=24px so it can't reach past the
# correspondence radius that justified keeping the point in the first
# place. 24px lands exactly on that ceiling -- deliberately, not tuned.
KEEP_RADIUS_PX = 24.0

# Matches the top of Stage A's own "promising, not yet validated" range
# (results/PHASE2_TPS_FINDINGS.md: top-10/top-20 matched or beat anchor on
# both references at n=1; top-30+ degraded monotonically). Provisional,
# same as every other threshold in this pipeline until more real captures
# confirm it.
DEFAULT_MAX_ADDED = 20


def _rigid_matrix(t: reg.Transform) -> np.ndarray:
    """Same construction as phase0c_real_fusion_capture._warp_coverage's own
    M, factored out here so the image warp and the coverage-mask warp use
    byte-identical math -- a mismatch here would silently misalign the two."""
    th = np.radians(t.theta_deg)
    c, s = np.cos(th) * t.scale, np.sin(th) * t.scale
    return np.array([[c, -s, t.dx], [s, c, t.dy]], dtype=np.float32)


def _coherence(gray: np.ndarray, block: int = 16) -> np.ndarray:
    """Structure-tensor ridge coherence, identical to afis_print.py's own
    `_coh` inside `_fuse_flash_ambient` (same _BLOCK=16) -- reused verbatim
    as this file's per-pixel confidence signal, not reinvented."""
    gg = gray.astype(np.float32)
    gx = cv2.Sobel(gg, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gg, cv2.CV_32F, 0, 1, ksize=3)
    gxx = cv2.boxFilter(gx * gx, -1, (block, block))
    gyy = cv2.boxFilter(gy * gy, -1, (block, block))
    gxy = cv2.boxFilter(gx * gy, -1, (block, block))
    return np.sqrt((gxx - gyy) ** 2 + 4 * gxy ** 2) / (gxx + gyy + 1e-6)


def _keep_mask(points_xy: List[Tuple[float, float]], shape: Tuple[int, int],
               radius: float = KEEP_RADIUS_PX, feather_px: float = 0.0) -> np.ndarray:
    """Hard disk union around each kept point, optionally feathered.

    feather_px=0 (the original Stage C behaviour) hands `_multiband_combine`
    a mask that jumps 1->0 at the disk boundary -- a hard, unblended edge
    RIGHT AT the point the pyramid blend is supposed to be smoothing across.
    That defeats much of what multiband blending exists to do (see its own
    docstring: blend low frequencies over a wide region, high frequencies
    only right at the seam) -- the seam here is drawn with a knife, not
    handed to the blender to soften. feather_px > 0 Gaussian-blurs the mask
    before returning it, so contribution tapers smoothly to 0 instead.
    """
    mask = np.zeros(shape, dtype=np.uint8)
    for x, y in points_xy:
        cv2.circle(mask, (int(round(x)), int(round(y))), int(round(radius)), 1, -1)
    if feather_px <= 0:
        return mask.astype(np.float64)
    return cv2.GaussianBlur(mask.astype(np.float64), (0, 0), feather_px)


def run(cap_id: str, max_added: int = DEFAULT_MAX_ADDED,
        feather_px: float = 0.0) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== Stage C: composite superprint image -- {cap_id[:12]} '
          f'(max_added={max_added}) ===')
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

    # ---- Rigid registration + TPS refinement, identical to Stage A ----
    transforms: Dict[str, reg.Transform] = {}
    rigid_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    cov: Dict[str, np.ndarray] = {anchor: a_cov}
    warps: Dict[str, tps.TpsWarp] = {}
    tps_minu: Dict[str, List[Minutia]] = {anchor: a_minu}

    print(f'\n  {"source":16} {"ctrl":>5}  note')
    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            print(f'  {name:16} {"--":>5}  rigid registration failed, excluded')
            continue
        transforms[name] = t
        rigid_minu[name] = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)

        warp, n_ctrl = tps.fit_from_correspondences(
            a_minu, rigid_minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if warp is None:
            tps_minu[name] = rigid_minu[name]
            print(f'  {name:16} {n_ctrl:5}  no TPS fit, rigid retained')
            continue
        warps[name] = warp
        tps_minu[name] = warp.apply_minutiae(rigid_minu[name])
        print(f'  {name:16} {warp.n_control:5}  TPS fitted')

    # ---- Selective merge -- same policy Stage A already validated ----
    fused, reliability, contributed = fm.fuse(
        minu, tps_minu, cov, transforms, anchor, max_added=max_added)
    print(f'\n  anchor alone : {len(a_minu):4} minutiae')
    print(f'  composite    : {len(fused):4} minutiae '
          f'(+{len(fused) - len(a_minu)}), max_added={max_added}')
    for name, n in contributed.items():
        if n:
            print(f'    {name:16} contributed {n} kept minutiae to the composite')

    # ---- Stage C itself: composite the actual IMAGE, restricted to the
    # SAME kept points the selective merge above just decided on ----
    tex_list: List[np.ndarray] = [a_img.astype(np.float64)]
    weight_list: List[np.ndarray] = [a_cov.astype(np.float64)]
    inv_a_cov = 1.0 - a_cov.astype(np.float64)
    composited_sources: Dict[str, int] = {}

    for name, warp in warps.items():
        n_kept = contributed.get(name, 0)
        if n_kept == 0:
            # This source's minutiae all got dropped by the selective merge
            # (reliability gate failed, or none of its points made the
            # max_added cut) -- keep its pixels out of the composite too,
            # for exactly the same reason. Compositing pixels the merge
            # itself decided weren't worth keeping would silently
            # reintroduce the indiscriminate-merge failure mode Stage A's
            # own selectivity sweep found.
            continue
        M = _rigid_matrix(transforms[name])
        rigid_img = cv2.warpAffine(
            prints[name], M, (a_shape[1], a_shape[0]),
            flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255)
        warped_img = tps.warp_image(warp, rigid_img, a_shape)

        rigid_cov = cv2.warpAffine(
            (_coverage(prints[name]) * 255).astype(np.uint8), M,
            (a_shape[1], a_shape[0]), flags=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        warped_cov = (tps.warp_image(warp, rigid_cov, a_shape) > 127).astype(np.float64)

        kept_pts = [(m.x, m.y) for m in fused if m.source == name]
        keep = _keep_mask(kept_pts, a_shape, feather_px=feather_px)
        coh = np.clip(_coherence(warped_img), 0.0, 1.0)

        w = warped_cov * keep * coh * inv_a_cov
        if w.max() <= 0:
            continue
        tex_list.append(warped_img.astype(np.float64))
        weight_list.append(w)
        composited_sources[name] = int((w > 0).sum())
        print(f'    {name:16} composited pixels near {len(kept_pts)} kept '
              f'points ({composited_sources[name]}px contributing area)')

    blended, total_w = _multiband_combine(tex_list, weight_list, num_bands=5)
    composite = np.where(total_w > 0, blended, 255.0).astype(np.uint8)

    tag = f'maxadded{max_added}' + (f'_feather{int(feather_px)}' if feather_px > 0 else '')
    out_img_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.png')
    cv2.imwrite(out_img_path, composite)
    anchor_img_path = os.path.join(CACHE, f'{cap_id[:12]}_anchor_alone.png')
    cv2.imwrite(anchor_img_path, a_img)
    print(f'\n  wrote composite image -> {out_img_path}')
    print(f'  wrote anchor-alone image -> {anchor_img_path}')

    # ---- Score the REAL composite image against the SAME real references
    # every prior phase used, via the same real mindtct+bozorth3 harness ----
    comp_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_{tag}.xyt')
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

    scores: Dict[str, Dict[str, Optional[int]]] = {'anchor_alone': {}, 'composite_image': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt_path, rx)
        scores['composite_image'][rn] = _best_score(comp_xyt_path, rx)

    print(f'\n  bozorth3 (higher = better match), real IMAGE, not the point set:')
    header = '  ' + f'{"candidate":18}' + ''.join(f'{r:>16}' for r in refs)
    print(header)
    for cname in ('anchor_alone', 'composite_image'):
        row = '  ' + f'{cname:18}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    print('\n  VERDICT (per reference):')
    beat, informative = 0, 0
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['composite_image'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        v = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} composite {c} {v} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'composite IMAGE beats anchor-alone on {beat}.')

    result = {
        'capture': cap_id,
        'max_added': max_added,
        'feather_px': feather_px,
        'counts': {'anchor_alone': len(a_minu), 'composite_minutiae': len(fused)},
        'contributed': contributed,
        'composited_sources_px': composited_sources,
        'scores': scores,
        'composite_image_path': out_img_path,
        'anchor_image_path': anchor_img_path,
    }
    out = os.path.join(HERE, 'results', f'phase3_composite_{tag}.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase3_composite.py <captureId> [max_added] [feather_px]')
        sys.exit(1)
    cap = sys.argv[1]
    ma = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_ADDED
    fp = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    run(cap, ma, fp)
