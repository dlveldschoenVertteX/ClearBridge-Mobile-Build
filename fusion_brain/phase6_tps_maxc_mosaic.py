"""PHASE 6 -- raw-domain mosaic with TPS registration and/or max-coherence
SELECTION, tested against the CORRECT control.

Phase 5 established (after its own confound was corrected, see
results/PHASE5_RAWDOMAIN_FINDINGS.md) that:
  * raw-domain fusion produces a genuinely coherent print -- one
    orientation field, one Gabor pass, continuity by construction;
  * the mosaic is 3.5x SHARPER than the anchor crop it is built from, so
    "averaging softens ridges" is NOT the mechanism here;
  * against its own control it wins round32 (25 v 24) and loses round35
    (20 v 27), and drops 44 minutiae (135 -> 91) at unchanged Laplacian.

A minutiae loss with no sharpness loss points at ridge CONTINUITY being
broken at the sub-ridge scale rather than detail being blurred away --
mindtct stops tracing a ridge where it steps sideways. Two candidate
causes, each with its own lever, tested here independently:

  1. REGISTRATION (`use_tps`). Phase 5 used production's ECC homography:
     ONE global 8-DOF transform for the whole frame. Skin is non-rigid,
     so local residual misregistration is expected, and a residual of a
     fraction of a ridge period is exactly what puts two sources' ridges
     out of phase. This track already built and validated TPS elastic
     registration (Stage A) fitted from matched minutiae. Applying it to
     the RAW frames before compositing corrects locally where a single
     homography cannot.

  2. COMBINE RULE (`combine`). Production's mosaic does a coherence-
     WEIGHTED AVERAGE. Where two sources overlap and disagree in phase,
     summing them is destructive interference regardless of how well each
     is registered. Winner-take-all SELECTION never sums two patterns, so
     interference cannot occur by construction. Direct in-project
     precedent: `deepMaxc` (coherence-max) beat `deepFuse` (flat average)
     on a real capture, 57 -> 81 real NFIQ2.

Both default OFF so `phase6 --arm ecc_avg` reproduces Phase 5 exactly,
which is what makes the other arms attributable.

CORRECTION, 2026-08-26 -- a real bug in THIS harness's first version,
found by reading its own numbers against its own code rather than by a
failing run. `_mosaic()` takes PRE-REGISTERED sides. In TPS mode the
sides were warped first, but the non-TPS path cropped each side and
passed it through with NO registration at all -- production does ECC
inside `_front_anchored_mosaic`, and replacing that function dropped the
registration with it. So the original `ecc_*` arms were not the Phase 5
baseline they were labelled as (2/6 sides passed the correlation gate vs
Phase 5's 3, and the scores differed). The avg-vs-maxc contrast was
still internally valid -- both arms saw identical sides -- but the
TPS-vs-ECC contrast was not, because one arm was registered and the
other was not. `_ecc_register()` below now performs production's exact
ECC step (small-scale estimate, WARP_INVERSE_MAP, warped ones-mask for
validity), so `ecc_*` is a real baseline and the 2x2 is interpretable.

CONTROL: every arm is scored against `generate()` on the ANCHOR CROP with
the same adjusted guide and no mosaic -- the control Phase 5 was missing.
Comparing against the full-frame anchor is what produced that confound;
this file never does it.

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

import afis_print as ap                        # noqa: E402  (production, read-only)
import minutiae_io as mio                      # noqa: E402
import registration as reg                     # noqa: E402
import tps                                     # noqa: E402
from phase0c_real_fusion_capture import (      # noqa: E402
    _db, collect_sources, _render, DIST_TOL, ANGLE_TOL, CACHE,
)
from phase1_consensus_fusion import _normalized_ink_xyt   # noqa: E402
from phase2_tps_fusion import _ref_xyt, _best_score, MACRO_REFS  # noqa: E402


def _gray(img: np.ndarray) -> np.ndarray:
    return img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)


def _common_crop(zone_grays: Dict[str, Tuple[np.ndarray, dict]],
                 shape: Tuple[int, int]) -> Optional[Tuple[int, int, int, int]]:
    """The same crop box `_front_anchored_mosaic_zones` derives internally.

    Reimplemented here (rather than imported) only because that function
    does not expose it, and every arm below -- including the control --
    must use the IDENTICAL box or the comparison is confounded again.
    Kept deliberately byte-equivalent to production's own derivation.
    """
    h, w = shape
    boxes = []
    for _zone, (_g, _region) in zone_grays.items():
        m = ap._superellipse_mask((h, w), _region)
        if m is None:
            continue
        ys, xs = np.where(m > 0)
        if ys.size == 0:
            continue
        pad_x = float(_region['rx']) * w * (ap._ZONE_MOSAIC_MARGIN - 1.0)
        pad_y = float(_region['ry']) * h * (ap._ZONE_MOSAIC_MARGIN - 1.0)
        boxes.append((xs.min() - pad_x, xs.max() + pad_x,
                      ys.min() - pad_y, ys.max() + pad_y))
    if not boxes:
        return None
    x0 = max(0, int(min(b[0] for b in boxes)))
    x1 = min(w, int(max(b[1] for b in boxes)))
    y0 = max(0, int(min(b[2] for b in boxes)))
    y1 = min(h, int(max(b[3] for b in boxes)))
    if x1 - x0 < 64 or y1 - y0 < 64:
        return None
    return x0, x1, y0, y1


def _adjust_guide(guide: dict, box: Tuple[int, int, int, int],
                  shape: Tuple[int, int]) -> dict:
    """Re-express a full-frame guide in the crop's own coordinate frame --
    identical arithmetic to `_front_anchored_mosaic_zones`' own."""
    x0, x1, y0, y1 = box
    h, w = shape
    cw, ch = (x1 - x0), (y1 - y0)
    adj = dict(guide)
    adj['cx'] = float(guide['cx']) * w / cw - x0 / cw
    adj['cy'] = float(guide['cy']) * h / ch - y0 / ch
    adj['rx'] = float(guide['rx']) * w / cw
    adj['ry'] = float(guide['ry']) * h / ch
    return adj


def _ecc_register(anchor_crop: np.ndarray,
                  side_crop: np.ndarray) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """Production's own ECC step, extracted so it can be swapped for TPS.

    Byte-equivalent to the registration block inside
    `_front_anchored_mosaic`: CLAHE-equalised copies downscaled to
    `_MOSAIC_REG_PX` for the estimate (full-res ECC is far too slow),
    MOTION_HOMOGRAPHY, and -- critically -- `WARP_INVERSE_MAP` on the
    application, which is the direction convention a real 2026-08-11 bug
    in production got wrong for months. Validity comes from warping an
    explicit all-ones mask, not from testing warped pixel values, for the
    same reason production does it that way (a genuinely black pixel
    inside the source is not "no data").

    Returns (registered, valid_mask float32 in 0..1) or None if ECC fails
    to converge.
    """
    fh, fw = anchor_crop.shape[:2]
    g = side_crop if side_crop.shape[:2] == (fh, fw) else cv2.resize(side_crop, (fw, fh))
    s = ap._MOSAIC_REG_PX / max(fh, fw)
    small = (max(1, int(fw * s)), max(1, int(fh * s)))
    cl = cv2.createCLAHE(3.0, (8, 8))
    ref_small = cl.apply(cv2.resize(anchor_crop, small))
    up = np.array([[1 / s, 0, 0], [0, 1 / s, 0], [0, 0, 1]], dtype=np.float32)
    dn = np.array([[s, 0, 0], [0, s, 0], [0, 0, 1]], dtype=np.float32)
    crit = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 60, 1e-4)
    try:
        warp = np.eye(3, 3, dtype=np.float32)
        _, warp = cv2.findTransformECC(
            ref_small, cl.apply(cv2.resize(g, small)), warp,
            cv2.MOTION_HOMOGRAPHY, crit, None, 5)
    except cv2.error:
        return None
    warp_full = (up @ warp @ dn).astype(np.float32)
    regd = cv2.warpPerspective(g, warp_full, (fw, fh),
                               flags=cv2.INTER_LINEAR + cv2.WARP_INVERSE_MAP)
    ones = np.full(g.shape[:2], 255, np.uint8)
    vm = cv2.warpPerspective(ones, warp_full, (fw, fh),
                             flags=cv2.INTER_NEAREST + cv2.WARP_INVERSE_MAP)
    return regd, (vm > 127).astype(np.float32)


def _tps_warp_crop(anchor_crop: np.ndarray, side_crop: np.ndarray,
                   a_print: np.ndarray, s_print: np.ndarray,
                   box: Tuple[int, int, int, int],
                   shape: Tuple[int, int]) -> Optional[np.ndarray]:
    """TPS-warp a side's RAW crop into the anchor crop's frame.

    Correspondences come from the RENDERED prints (mindtct needs enhanced
    input to find minutiae at all), so the fitted transform lives in PRINT
    space and cannot be applied to a raw crop directly. Rather than
    reimplement generate()'s full crop/rotate/trim geometry to map between
    the two -- exactly the reimplementation-drift risk this track has
    already been burned by -- this fits the warp on minutiae RESCALED into
    the crop's own pixel frame, which is valid because both prints derive
    from the same guide region and therefore share one linear relationship
    to their crops. Returns None if registration fails.
    """
    a_minu = mio.extract_minutiae(a_print, source='a')
    s_minu = mio.extract_minutiae(s_print, source='s')
    if len(a_minu) < 8 or len(s_minu) < 8:
        return None
    t, n = reg.register(a_minu, s_minu, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
    if t is not None:
        t, n = reg.refine(a_minu, s_minu, t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
    if t is None or n < 6:
        return None
    rigid = t.apply_all(s_minu)
    warp, _ = tps.fit_from_correspondences(
        a_minu, rigid, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
    if warp is None:
        return None

    # Print-space -> crop-space scale. Both prints are renders of the same
    # guide region, so this is a uniform scale in each axis.
    ch, cw = anchor_crop.shape[:2]
    ph, pw = a_print.shape[:2]
    sx, sy = cw / float(pw), ch / float(ph)

    # Apply the rigid part in crop pixels, then the TPS field.
    th = np.radians(t.theta_deg)
    c, s = np.cos(th) * t.scale, np.sin(th) * t.scale
    M = np.array([[c, -s, t.dx * sx], [s, c, t.dy * sy]], dtype=np.float32)
    rigid_img = cv2.warpAffine(side_crop, M, (cw, ch), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    try:
        return tps.warp_image(warp, rigid_img, (ch, cw))
    except Exception:
        return rigid_img


def _mosaic(anchor_crop: np.ndarray, sides: List[np.ndarray],
            combine: str,
            valid_masks: Optional[List[Optional[np.ndarray]]] = None
            ) -> Tuple[Optional[np.ndarray], int]:
    """Composite pre-registered raw crops onto the anchor.

    `combine='avg'`  -- coherence-weighted average, production's own rule.
    `combine='maxc'` -- per-pixel winner-take-all on the same weight
                        field. Never sums two ridge patterns, so
                        destructive interference cannot occur.

    `valid_masks[i]`, when given, is the REAL warped-footprint mask for
    `sides[i]` (production's own validity mechanism -- see
    `_ecc_register`'s docstring for why a warped ones-mask is used instead
    of testing pixel values). `None` per-entry falls back to the old
    `(sd > 0)` pixel test, which is what an un-registered crop (nothing to
    warp) has to use.

    Both reuse production's `_block_coherence`/`_block_sharpness` and the
    same anchor-dominant gate, so the ONLY difference between arms is the
    combine rule itself.
    """
    fh, fw = anchor_crop.shape[:2]
    a_coh = ap._block_coherence(anchor_crop)
    a_sharp = ap._block_sharpness(anchor_crop)

    acc = anchor_crop.astype(np.float32) * a_coh
    wsum = a_coh.copy()
    best_w = a_coh.copy()
    best_px = anchor_crop.astype(np.float32).copy()
    used = 0

    vm_list = valid_masks if valid_masks is not None else [None] * len(sides)
    for sd, vm in zip(sides, vm_list):
        if sd is None or sd.shape[:2] != (fh, fw):
            continue
        if float(np.corrcoef(sd.ravel(), anchor_crop.ravel())[0, 1]) < 0.45:
            continue
        valid = vm if vm is not None else (sd > 0).astype(np.float32)
        if ap._MOSAIC_FEATHER_ERODE > 0:
            valid = cv2.erode(valid.astype(np.uint8), np.ones(
                (ap._MOSAIC_FEATHER_ERODE,) * 2, np.uint8)).astype(np.float32)
        valid = cv2.GaussianBlur(valid, (0, 0), ap._MOSAIC_FEATHER_SIGMA)
        cs = ap._block_coherence(sd) * valid
        # Same anchor-dominant gate production uses: zero contribution at
        # sharpness parity, ramping only where the side genuinely resolves
        # better. Keeping it identical is what makes the combine rule the
        # only variable between arms.
        if ap._MOSAIC_ANCHOR_DOMINANT_T > 1.0:
            ratio = ap._block_sharpness(sd) / (a_sharp + 1e-6)
            gain = np.clip((ratio - 1.0) / (ap._MOSAIC_ANCHOR_DOMINANT_T - 1.0),
                           0.0, 1.0)
            gain = cv2.GaussianBlur(gain, (0, 0), ap._MOSAIC_ANCHOR_RAMP_BLUR)
            cs = cs * gain
        acc += sd.astype(np.float32) * cs
        wsum += cs
        win = cs > best_w
        best_px = np.where(win, sd.astype(np.float32), best_px)
        best_w = np.where(win, cs, best_w)
        used += 1

    if used == 0:
        return None, 0
    if combine == 'maxc':
        return best_px.astype(np.uint8), used
    return (acc / np.maximum(wsum, 1e-6)).astype(np.uint8), used


def run(cap_id: str, use_tps: bool = False, combine: str = 'avg',
        tag: Optional[str] = None) -> Optional[dict]:
    tag = tag or f'{"tps" if use_tps else "ecc"}_{combine}'
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== PHASE 6 -- {cap_id[:12]}  registration='
          f'{"TPS" if use_tps else "ECC"}  combine={combine} ===')
    srcs = collect_sources(v)
    if 'front_v1' not in srcs:
        print('  no anchor, stopping')
        return None
    anchor_img, anchor_guide = srcs['front_v1']
    a_gray = _gray(anchor_img)
    shape = a_gray.shape[:2]

    zone_grays = {'center': (a_gray, anchor_guide)}
    for name, (img, guide) in srcs.items():
        if name != 'front_v1':
            zone_grays[name] = (_gray(img), guide)

    box = _common_crop(zone_grays, shape)
    if box is None:
        print('  crop derivation failed')
        return None
    x0, x1, y0, y1 = box
    adj_guide = _adjust_guide(anchor_guide, box, shape)
    a_crop = a_gray[y0:y1, x0:x1]
    print(f'  crop {a_crop.shape}, sources offered: {len(zone_grays) - 1}')

    a_print = _render(anchor_img, anchor_guide, f'{cap_id[:12]}_front_v1')
    if a_print is None:
        print('  anchor render failed')
        return None

    sides: List[np.ndarray] = []
    valid_masks: List[Optional[np.ndarray]] = []
    for name, (g, guide) in zone_grays.items():
        if name == 'center' or g.shape[:2] != shape:
            continue
        s_crop = g[y0:y1, x0:x1]
        if not use_tps:
            # Real ECC registration -- production's own step, extracted
            # into `_ecc_register` (see the correction note in this
            # module's docstring: the original version of this arm did
            # NOT register at all, and this is the fix).
            reg_out = _ecc_register(a_crop, s_crop)
            if reg_out is None:
                print(f'    {name}: ECC registration failed, skipped')
                continue
            regd, vmask = reg_out
            sides.append(regd)
            valid_masks.append(vmask)
            continue
        s_print = _render(srcs[name][0], guide, f'{cap_id[:12]}_{name}')
        if s_print is None:
            continue
        w = _tps_warp_crop(a_crop, s_crop, a_print, s_print, box, shape)
        if w is not None:
            sides.append(w)
            valid_masks.append(None)
        else:
            print(f'    {name}: TPS registration failed, skipped')

    mos, used = _mosaic(a_crop, sides, combine, valid_masks)
    if mos is None:
        print('  mosaic produced nothing (no side passed the gates)')
        return {'capture': cap_id, 'arm': tag, 'mosaic': False}
    print(f'  sides used: {used}/{len(sides)}   mosaic lap='
          f'{cv2.Laplacian(mos, cv2.CV_64F).var():.1f}  '
          f'(anchor crop lap={cv2.Laplacian(a_crop, cv2.CV_64F).var():.1f})')

    out, _ = ap.generate([mos], [0.0], [None], guide_region=adj_guide,
                         freq_normalize=True, stack_cache={})
    if out is None:
        print('  generate() returned None')
        return {'capture': cap_id, 'arm': tag, 'mosaic': True, 'generate': False}
    comp = out if out.ndim == 2 else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
    comp_path = os.path.join(CACHE, f'{cap_id[:12]}_p6_{tag}.png')
    cv2.imwrite(comp_path, comp)

    # THE CONTROL Phase 5 was missing: same crop, same adjusted guide, no
    # mosaic. Cached across arms since it does not depend on them.
    ctrl_path = os.path.join(CACHE, f'{cap_id[:12]}_p6_CONTROL.png')
    if os.path.exists(ctrl_path):
        ctrl = cv2.imread(ctrl_path, cv2.IMREAD_GRAYSCALE)
    else:
        c_out, _ = ap.generate([a_crop], [0.0], [None], guide_region=adj_guide,
                               freq_normalize=True, stack_cache={})
        if c_out is None:
            print('  control generate() failed')
            return None
        ctrl = c_out if c_out.ndim == 2 else cv2.cvtColor(c_out, cv2.COLOR_BGR2GRAY)
        cv2.imwrite(ctrl_path, ctrl)

    c_minu = mio.extract_minutiae(ctrl, source='control')
    m_minu = mio.extract_minutiae(comp, source='mosaic')
    print(f'\n  CONTROL (no mosaic): {len(c_minu):4} minutiae  '
          f'lap={cv2.Laplacian(ctrl, cv2.CV_64F).var():.0f}')
    print(f'  {tag:19}: {len(m_minu):4} minutiae  '
          f'lap={cv2.Laplacian(comp, cv2.CV_64F).var():.0f}')

    ctrl_xyt = os.path.join(CACHE, f'{cap_id[:12]}_p6_CONTROL.xyt')
    comp_xyt = os.path.join(CACHE, f'{cap_id[:12]}_p6_{tag}.xyt')
    mio.write_xyt(c_minu, ctrl_xyt)
    mio.write_xyt(m_minu, comp_xyt)

    refs: Dict[str, str] = {}
    ink = _normalized_ink_xyt(os.path.join(CACHE, 'ink_scan.xyt'))
    if ink:
        refs['ink_scan'] = ink
    for rn, rp in MACRO_REFS.items():
        r = _ref_xyt(rn, rp)
        if r:
            refs[rn] = r

    scores = {'control': {}, tag: {}}
    for rn, rx in refs.items():
        scores['control'][rn] = _best_score(ctrl_xyt, rx)
        scores[tag][rn] = _best_score(comp_xyt, rx)

    print('\n  bozorth3 vs the CORRECT control:')
    print('  ' + f'{"candidate":20}' + ''.join(f'{r:>16}' for r in refs))
    for cn in ('control', tag):
        row = '  ' + f'{cn:20}'
        for rn in refs:
            row += f'{str(scores[cn][rn]):>16}'
        print(row)

    beat = informative = 0
    for rn in refs:
        if rn == 'ink_scan':
            continue
        a, c = scores['control'][rn], scores[tag][rn]
        if a is None or c is None:
            continue
        informative += 1
        if c > a:
            beat += 1
    print(f'\n  {tag} beats the control on {beat}/{informative} '
          f'informative reference(s).')

    result = {'capture': cap_id, 'arm': tag, 'use_tps': use_tps,
              'combine': combine, 'sides_used': int(used),
              'control_minutiae': len(c_minu), 'mosaic_minutiae': len(m_minu),
              'scores': scores, 'composite_path': comp_path}
    out_p = os.path.join(HERE, 'results', f'phase6_{tag}_{cap_id[:8]}.json')
    with open(out_p, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'\nwrote {out_p}')
    return result


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase6_tps_maxc_mosaic.py <captureId> '
              '[tps|ecc] [avg|maxc]')
        sys.exit(1)
    cap = sys.argv[1]
    use_tps = (sys.argv[2].lower() == 'tps') if len(sys.argv) > 2 else False
    combine = sys.argv[3].lower() if len(sys.argv) > 3 else 'avg'
    run(cap, use_tps, combine)
