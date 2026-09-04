"""STAGE C follow-up -- local ridge-PHASE correction on top of TPS position
correction, testing the specific fix PHASE3_COMPOSITE_FINDINGS.md's own
diagnosis pointed at.

Stage C (phase3_composite.py) found a real, decisive negative and diagnosed
WHY: TPS corrects minutia POSITION (fitted to correspondences accepted
within dist_tol=12px), never ridge PHASE (which exact black/white line a
pixel sits on). Two prints of the same finger can have matching minutiae
positions while their ridge "waves" are offset from each other by a
fraction of a ridge period -- something no position-only fit, however
accurate, corrects. That is very likely the same thing Stage A's own
diagnostic already flagged without naming it: "every source's fitted
maxDisplacement pinned at ~12px, which is exactly dist_tol... TPS here
corrects sub-tolerance residual only" -- a ridge period here is ~9px
(afis_print's own _TARGET_PERIOD), so a sub-dist_tol residual is squarely
in "less than one ridge period" territory, i.e. plausibly a phase offset
hiding inside the correspondence tolerance the whole time.

THE CLASSICAL, CHEAP TEST (not the learned Cui/Feng et al. network the
README also names -- deliberately not building that yet, same "don't train
a model before the metric is understood" discipline Stage A already
invoked once): every contributing source's TPS-warped image genuinely
OVERLAPS the anchor's own real coverage in real, substantial territory
(that overlap is exactly what phase3_composite.py's own `1 - anchor_cov`
gate throws away before compositing -- it was never used for anything).
Within that overlap, BOTH images show the same real physical ridges, just
from two different captures -- so any sub-pixel translational disagreement
between them, measured directly via Fourier phase correlation
(`cv2.phaseCorrelate`, principled and standard for exactly this: fast
sub-pixel translational registration of periodic/textured content), IS the
local phase residual TPS left uncorrected. Apply that shift to the warped
source before compositing its NEW-territory pixels and re-run the exact
same real scoring Stage C used.

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
from phase3_composite import (                 # noqa: E402
    _rigid_matrix, _coherence, _keep_mask, KEEP_RADIUS_PX, DEFAULT_MAX_ADDED,
)
from sfm_pipeline import _multiband_combine    # noqa: E402  (production, read-only)

# Minimum genuine anchor/source overlap (px) before trusting a phase-
# correlation estimate from it -- phaseCorrelate degrades on tiny/noisy
# windows, and a bad estimate here would actively mis-shift real content
# rather than merely fail to help. Chosen as a round number well above the
# smallest overlap regions this real capture's sources produce; not tuned
# to this one capture's specific numbers.
MIN_OVERLAP_PX = 400

# A phase residual should be sub-ridge-period-ish by construction (that is
# the whole hypothesis) -- afis_print normalises every print toward
# _TARGET_PERIOD=9.0px, so a "correction" bigger than about 1.5 periods is
# more likely phaseCorrelate locking onto something else (a repeating
# ridge pattern one period over, a genuine registration failure) than a
# real phase offset. Reject rather than trust a fit outside this bound --
# same discipline as tps.py's own MAX_PLAUSIBLE_DISPLACEMENT_PX guard.
MAX_PLAUSIBLE_PHASE_SHIFT_PX = 14.0

# phaseCorrelate's own confidence metric (peak sharpness of the
# cross-power spectrum, 0-1). Below this the estimate is noise-dominated;
# self-skip rather than apply it.
MIN_RESPONSE = 0.05


def _phase_shift(anchor_img: np.ndarray, warped_img: np.ndarray,
                 overlap: np.ndarray) -> Optional[Tuple[float, float, float]]:
    """Sub-pixel (dx, dy, response) translation aligning warped_img onto
    anchor_img within `overlap` (bool mask, True = both have real content).
    None if there isn't enough real overlap to trust, or the estimate is
    implausible."""
    ys, xs = np.where(overlap)
    if ys.size < MIN_OVERLAP_PX:
        return None
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    a_crop = anchor_img[y0:y1, x0:x1].astype(np.float32)
    w_crop = warped_img[y0:y1, x0:x1].astype(np.float32)
    m_crop = overlap[y0:y1, x0:x1]
    # Zero out non-overlap pixels inside the bounding box (the box itself
    # can be larger than the mask if the overlap region isn't a solid
    # rectangle) -- both crops zeroed identically so this can't itself
    # manufacture a spurious shift.
    a_crop = np.where(m_crop, a_crop, 0.0)
    w_crop = np.where(m_crop, w_crop, 0.0)
    if a_crop.shape[0] < 8 or a_crop.shape[1] < 8:
        return None
    try:
        (dx, dy), response = cv2.phaseCorrelate(a_crop, w_crop)
    except cv2.error:
        return None
    if response < MIN_RESPONSE:
        return None
    if max(abs(dx), abs(dy)) > MAX_PLAUSIBLE_PHASE_SHIFT_PX:
        return None
    return float(dx), float(dy), float(response)


def run(cap_id: str, max_added: int = DEFAULT_MAX_ADDED) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== Stage C+phase: local phase-correlation correction -- '
          f'{cap_id[:12]} (max_added={max_added}) ===')
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

    # ---- Per-source: measure + apply the local phase correction ----
    tex_list: List[np.ndarray] = [a_img.astype(np.float64)]
    weight_list: List[np.ndarray] = [a_cov.astype(np.float64)]
    inv_a_cov = 1.0 - a_cov.astype(np.float64)
    phase_report: Dict[str, dict] = {}

    print(f'\n  {"source":16} {"overlap_px":>10} {"dx":>7} {"dy":>7} {"resp":>6}  note')
    for name, warp in warps.items():
        n_kept = contributed.get(name, 0)
        if n_kept == 0:
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
        warped_cov = (tps.warp_image(warp, rigid_cov, a_shape) > 127)

        # The genuine anchor/source overlap -- thrown away by
        # phase3_composite.py's own `inv_a_cov` gate, used here instead of
        # ignored, since both images show real matching content there.
        overlap = warped_cov & (a_cov > 0)
        est = _phase_shift(a_img, warped_img, overlap)
        n_overlap_px = int(overlap.sum())

        if est is None:
            phase_report[name] = {'overlapPx': n_overlap_px, 'applied': False}
            print(f'  {name:16} {n_overlap_px:10} {"--":>7} {"--":>7} {"--":>6}  '
                  f'no trustworthy phase estimate, TPS-only kept')
            corrected_img = warped_img
        else:
            dx, dy, resp = est
            T = np.array([[1, 0, dx], [0, 1, dy]], dtype=np.float32)
            corrected_img = cv2.warpAffine(
                warped_img, T, (a_shape[1], a_shape[0]),
                flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=255)
            phase_report[name] = {'overlapPx': n_overlap_px, 'applied': True,
                                  'dx': round(dx, 2), 'dy': round(dy, 2),
                                  'response': round(resp, 3)}
            print(f'  {name:16} {n_overlap_px:10} {dx:7.2f} {dy:7.2f} {resp:6.3f}  applied')

        kept_pts = [(m.x, m.y) for m in fused if m.source == name]
        keep = _keep_mask(kept_pts, a_shape)
        coh = np.clip(_coherence(corrected_img), 0.0, 1.0)
        w = warped_cov.astype(np.float64) * keep * coh * inv_a_cov
        if w.max() <= 0:
            continue
        tex_list.append(corrected_img.astype(np.float64))
        weight_list.append(w)

    blended, total_w = _multiband_combine(tex_list, weight_list, num_bands=5)
    composite = np.where(total_w > 0, blended, 255.0).astype(np.uint8)

    out_img_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_phasecorr.png')
    cv2.imwrite(out_img_path, composite)
    print(f'\n  wrote phase-corrected composite -> {out_img_path}')

    # ---- Score, same real references and harness as every prior phase ----
    comp_xyt_path = os.path.join(CACHE, f'{cap_id[:12]}_composite_phasecorr.xyt')
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

    scores: Dict[str, Dict[str, Optional[int]]] = {'anchor_alone': {}, 'phase_corrected': {}}
    for rn, rx in refs.items():
        scores['anchor_alone'][rn] = _best_score(anchor_xyt_path, rx)
        scores['phase_corrected'][rn] = _best_score(comp_xyt_path, rx)

    print(f'\n  bozorth3 (higher = better match):')
    header = '  ' + f'{"candidate":18}' + ''.join(f'{r:>16}' for r in refs)
    print(header)
    for cname in ('anchor_alone', 'phase_corrected'):
        row = '  ' + f'{cname:18}'
        for rn in refs:
            row += f'{str(scores[cname][rn]):>16}'
        print(row)

    print('\n  VERDICT (per reference):')
    beat, informative = 0, 0
    for rn in refs:
        a, c = scores['anchor_alone'][rn], scores['phase_corrected'][rn]
        if a is None or c is None:
            continue
        if rn != 'ink_scan':
            informative += 1
            if c > a:
                beat += 1
        vv = 'BEATS' if c > a else ('ties' if c == a else 'loses to')
        note = '  (noise floor, not counted)' if rn == 'ink_scan' else ''
        print(f'    {rn:16} phase-corrected {c} {vv} anchor {a}{note}')
    print(f'\n  On the {informative} informative reference(s): '
          f'phase-corrected composite beats anchor-alone on {beat}.')

    result = {'capture': cap_id, 'max_added': max_added, 'phase_report': phase_report,
              'scores': scores, 'composite_image_path': out_img_path}
    out = os.path.join(HERE, 'results', 'phase3b_phase_correct.json')
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase3b_phase_correct.py <captureId> [max_added]')
        sys.exit(1)
    cap = sys.argv[1]
    ma = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_ADDED
    run(cap, ma)
