"""Why does the crease trim not fire on some captures, and what does the
enhancement do to the below-crease region before it gets trimmed?

Direct CTO report (2026-08-27), on a real capture: "the blue circle
surrounding the print should be the only thing that survives ... it seems to
be enhancing everything past the crease at the bottom as well", plus visible
streaking through the enhanced print.

Established from Firestore before writing this: across 24 real production
captures since crease trim shipped, it fires on 19 (removing a median 27% of
the print) and does NOT fire at all on 5. So this is pipeline-wide on about
one capture in five, not one bad image.

This reproduces the trim's own decision on a real capture and reports the
profile it is thresholding, so the failure can be read rather than guessed:
  * the row-wise circular variance of the ridge-orientation field, raw and
    smoothed exactly as _trim_base_crease smooths it
  * where the threshold sits against that profile, and the longest run that
    ever cleared it against the run length required
  * an annotated overlay of the rendered print with the profile beside it

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import os
import sys
from typing import Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                        # noqa: E402
import numpy as np                                # noqa: E402

import afis_print as ap                           # noqa: E402
from phase0c_real_fusion_capture import _bucket, _db   # noqa: E402
from frame_selection_test import _center_square   # noqa: E402

OUT = os.path.join(HERE, 'results', 'cache', 'crease')
os.makedirs(OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Capture the PRE-Gabor normalized grayscale, in the same geometry the crease
# trim eventually decides on.
#
# The hypothesis this tests: `_trim_base_crease` measures ridge-orientation
# uniformity on the BINARIZED image, i.e. AFTER the Gabor bank has run. That
# bank synthesises coherent ridge structure from whatever local contrast it
# is given -- a property this project has already documented ("the
# enhancement pipeline's own orientation-field + Gabor bank will impose
# ridge-like structure on any input with enough local contrast"). So by the
# time the crease detector looks, the crease may no longer LOOK like a
# crease: the enhancer has already given it plausible, varied ridge flow.
# That would make the detector circular -- it runs on data the enhancer has
# already made fingerprint-shaped.
# ---------------------------------------------------------------------------
_stash: dict = {}
_orig_gabor = ap._gabor_enhance
_orig_upright = ap._upright_from_tip


def _gabor_spy(norm, orient, wl, *a, **k):
    _stash['norm'] = np.asarray(norm, dtype=np.float32).copy()
    return _orig_gabor(norm, orient, wl, *a, **k)


def _upright_spy(binimg, mask, ang):
    b, m = _orig_upright(binimg, mask, ang)
    n = _stash.get('norm')
    if n is not None:
        n8 = cv2.normalize(n, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
        # freq_normalize resamples, so the captured `norm` can be at a
        # different scale than the image being rotated here. Resize rather
        # than skip: this comparison is about ORIENTATION structure, which
        # a resample preserves.
        if n8.shape[:2] != binimg.shape[:2]:
            n8 = cv2.resize(n8, (binimg.shape[1], binimg.shape[0]),
                            interpolation=cv2.INTER_AREA)
        _stash['norm_rot'] = _orig_upright(n8, mask, ang)[0]
    return b, m


ap._gabor_enhance = _gabor_spy
ap._upright_from_tip = _upright_spy


def _profile(binimg: np.ndarray, mask: np.ndarray):
    """_trim_base_crease's own measurement, lifted out so the numbers it
    decides on can be inspected instead of inferred from whether it fired."""
    ys, _ = np.where(mask > 0)
    if ys.size == 0:
        return None
    y0, y1 = int(ys.min()), int(ys.max())
    span = y1 - y0
    orient = ap._orientation_field(binimg.astype(np.float32))
    raw = np.full(y1 - y0 + 1, np.nan, dtype=np.float32)
    for y in range(y0, y1 + 1):
        row = mask[y] > 0
        if row.sum() < 5:
            continue
        th = orient[y, row]
        c = float(np.mean(np.cos(2 * th)))
        s = float(np.mean(np.sin(2 * th)))
        raw[y - y0] = 1.0 - float(np.hypot(c, s))
    valid = (~np.isnan(raw)).astype(np.float32)
    filled = np.nan_to_num(raw, nan=0.0)
    k = np.ones(max(1, ap._CREASE_SMOOTH_PX), dtype=np.float32)
    num, den = np.convolve(filled, k, 'same'), np.convolve(valid, k, 'same')
    smoothed = np.divide(num, den, out=np.ones_like(num), where=den > 0)
    return y0, y1, span, raw, smoothed


def run(cap_id: str) -> Optional[dict]:
    doc = None
    for d in _db.collection('captures').where(
            'captureMode', '==', 'front_only_v1').limit(500).stream():
        if d.id.startswith(cap_id):
            doc, cap_id = d.to_dict(), d.id
            break
    if doc is None:
        print(f'{cap_id}: not found')
        return None
    guide = doc.get('guideRegion')
    frames = doc.get('frames') or []
    amb = [f for f in frames if not f.get('flashOn')]
    fl = [f for f in frames if f.get('flashOn')]
    if not guide or not amb:
        print(f'{cap_id}: no guide/frames')
        return None

    def load(entry):
        b = _bucket.blob(entry['path'])
        if not b.exists():
            return None
        a = cv2.imdecode(np.frombuffer(b.download_as_bytes(), np.uint8),
                         cv2.IMREAD_COLOR)
        return None if a is None else _center_square(a)

    amb_s = sorted(amb, key=lambda f: -(f.get('laplacianScore') or 0))
    fl_s = sorted(fl, key=lambda f: -(f.get('laplacianScore') or 0))
    ab = [x for x in (load(e) for e in amb_s) if x is not None]
    fb = [x for x in (load(e) for e in fl_s) if x is not None]
    if not ab:
        print(f'{cap_id}: no usable ambient frame')
        return None

    # Reproduce production's own render, then re-derive the pre-trim state by
    # rendering with crease_trim off -- that is the image the trim decides on.
    out_off, p_off = ap.generate(
        [ab[0]], [0.0], [None], guide_region=guide, freq_normalize=True,
        stack_cache={}, ambient_frames=[ab[0]],
        flash_frames=[fb[0]] if fb else [None],
        ambient_burst=ab, flash_burst=fb or None,
        crease_trim=False, circular_vignette=False)
    out_on, p_on = ap.generate(
        [ab[0]], [0.0], [None], guide_region=guide, freq_normalize=True,
        stack_cache={}, ambient_frames=[ab[0]],
        flash_frames=[fb[0]] if fb else [None],
        ambient_burst=ab, flash_burst=fb or None,
        crease_trim=True, circular_vignette=False)
    if out_off is None:
        print(f'{cap_id}: render failed')
        return None

    g = out_off if out_off.ndim == 2 else cv2.cvtColor(out_off, cv2.COLOR_BGR2GRAY)
    mask = (g < 250).astype(np.uint8)
    prof = _profile(g, mask)
    if prof is None:
        return None
    y0, y1, span, raw, sm = prof
    min_run = max(3, int(ap._CREASE_MIN_RUN_FRAC * span))
    mid = span // 2
    below = sm[mid:]
    runs, cur = [], 0
    for v in below:
        cur = cur + 1 if v < ap._CREASE_MIN_CIRCVAR else 0
        runs.append(cur)
    longest = max(runs) if runs else 0

    print(f'\n=== {cap_id[:8]} ===')
    print(f'  print spans rows {y0}-{y1} ({span}px), mask {int(mask.sum()):,}px')
    print(f'  threshold  circvar < {ap._CREASE_MIN_CIRCVAR}, '
          f'sustained for >= {min_run}px ({100*ap._CREASE_MIN_RUN_FRAC:.0f}% of span)')
    print(f'  smoothed circvar over the BASE half: '
          f'min {below.min():.3f}  median {np.median(below):.3f}  '
          f'max {below.max():.3f}')
    print(f'  longest run below threshold: {longest}px '
          f'({"FIRES" if longest >= min_run else "TOO SHORT -- no trim"})')
    print(f'  trimmed px reported: {p_on.get("afisCreaseTrimPx")}')

    pre = _stash.get('norm_rot')
    if pre is not None and pre.shape[:2] != g.shape[:2]:
        pre = cv2.resize(pre, (g.shape[1], g.shape[0]),
                         interpolation=cv2.INTER_AREA)
    if pre is not None:
        pr = _profile(pre, mask)
        if pr is not None:
            _, _, _, _, sm_pre = pr
            bp = sm_pre[mid:]
            c, best_pre = 0, 0
            for v in bp:
                c = c + 1 if v < ap._CREASE_MIN_CIRCVAR else 0
                best_pre = max(best_pre, c)
            print(f'  -- same measurement on the PRE-GABOR grayscale --')
            print(f'     base-half circvar: min {bp.min():.3f}  '
                  f'median {np.median(bp):.3f}  max {bp.max():.3f}')
            print(f'     longest run below {ap._CREASE_MIN_CIRCVAR}: '
                  f'{best_pre}px '
                  f'({"FIRES" if best_pre >= min_run else "too short"})')
    for q in (0.05, 0.10, 0.20, 0.30, 0.40, 0.50):
        c, best = 0, 0
        for v in below:
            c = c + 1 if v < q else 0
            best = max(best, c)
        print(f'    at threshold {q:.2f}: longest run {best:4d}px '
              f'{"-> would fire" if best >= min_run else ""}')

    # Overlay: rendered print with the profile drawn beside it.
    h, w = g.shape
    canvas = cv2.cvtColor(g, cv2.COLOR_GRAY2BGR)
    for i, v in enumerate(sm):
        y = y0 + i
        if 0 <= y < h:
            x = int(np.clip(v / 0.6, 0, 1) * (w * 0.25))
            cv2.circle(canvas, (x, y), 1, (0, 0, 255), -1)
    tx = int((ap._CREASE_MIN_CIRCVAR / 0.6) * (w * 0.25))
    cv2.line(canvas, (tx, y0), (tx, y1), (255, 0, 0), 2)
    cv2.line(canvas, (0, y0 + mid), (w, y0 + mid), (0, 160, 0), 2)
    p = os.path.join(OUT, f'{cap_id[:8]}_creaseprofile.png')
    sc = 900.0 / max(canvas.shape[:2])
    cv2.imwrite(p, cv2.resize(canvas, None, fx=sc, fy=sc,
                              interpolation=cv2.INTER_AREA))
    for tag, img in (('untrimmed', out_off), ('trimmed', out_on)):
        if img is not None:
            q = os.path.join(OUT, f'{cap_id[:8]}_{tag}.png')
            cv2.imwrite(q, cv2.resize(img, None, fx=sc, fy=sc,
                                      interpolation=cv2.INTER_AREA))
    print(f'  wrote {os.path.basename(p)} (red = smoothed circvar profile, '
          f'blue = threshold, green = scan start)')
    return {'longest_run': longest, 'min_run': min_run}


if __name__ == '__main__':
    for cid in sys.argv[1:] or ['01662ffb']:
        run(cid)
