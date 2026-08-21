"""PHASE 0b -- does small-angle TILT reveal edge ridge detail?

Phase 0 did NOT test this. What it labelled "focuszone" are stills that share
framing with the main burst and differ only in AF/AE target -- the finger
never changes pose, so they could not possibly reveal new pad surface. The
real claim ("tilting ~10 degrees rolls the curved sides of the pad into view,
exposing edge ridges a face-on capture geometrically cannot see") needs real
multi-angle data, which the discontinued oscillating_8phase captures have:
per-frame `angleDeg` spanning roughly -17 to +16 degrees.

CONTROL IS THE POINT. A tilted frame will always contribute SOME unmatched
minutiae simply because it is a different frame. To attribute anything to
tilt, a second FACE-ON frame is scored the same way. If face-on-vs-face-on
produces as much "new edge coverage" as tilt-vs-face-on, the effect is
frame-to-frame variation, not geometry.

Also breaks contribution down by RADIAL position: the hypothesis is
specifically about EDGES, so new coverage is split into an inner and outer
band of the pad rather than counted globally.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'functions', 'processEnhanceAndScore'))

import afis_print as ap                      # noqa: E402
import minutiae_io as mio                    # noqa: E402
import registration as reg                   # noqa: E402
from minutiae_io import Minutia              # noqa: E402

os.environ.setdefault(
    'GOOGLE_APPLICATION_CREDENTIALS',
    '/root/.claude/uploads/7c276512-7b7e-5f85-8f5b-2eb1bc5e7593/'
    'bc6dc4ea-clearbridgedc699firebaseadminsdkfbsvc6dfd1c643f.json')
from google.cloud import firestore, storage  # noqa: E402

BUCKET = 'clearbridge-dc699.firebasestorage.app'
CACHE = os.path.join(HERE, 'results', 'cache')
os.makedirs(CACHE, exist_ok=True)
DIST_TOL, ANGLE_TOL = 12.0, 25.0
MIN_LAP = 200.0          # sharp frames only -- a blurred tilt frame proves nothing
EDGE_BAND = 0.5          # normalised radius splitting inner pad from edge

_bucket = storage.Client().bucket(BUCKET)
_db = firestore.Client()


def _download(path: str) -> Optional[np.ndarray]:
    local = os.path.join(CACHE, path.replace('/', '_'))
    if not os.path.exists(local):
        b = _bucket.blob(path)
        if not b.exists():
            return None
        b.download_to_filename(local)
    return cv2.imread(local)


def _render(img, guide, tag) -> Optional[np.ndarray]:
    cached = os.path.join(CACHE, f'tilt_{tag}.png')
    if os.path.exists(cached):
        return cv2.imread(cached, cv2.IMREAD_GRAYSCALE)
    try:
        out, _ = ap.generate([img], [0.0], [None], guide_region=guide,
                             freq_normalize=True, stack_cache={})
    except Exception as e:
        print(f'    render failed {tag}: {e}')
        return None
    if out is None:
        return None
    cv2.imwrite(cached, out)
    return out if out.ndim == 2 else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)


def _coverage(p): return (p < 240).astype(np.uint8)


def _warp(cov, t, shape):
    th = np.radians(t.theta_deg)
    c, s = np.cos(th) * t.scale, np.sin(th) * t.scale
    M = np.array([[c, -s, t.dx], [s, c, t.dy]], dtype=np.float32)
    return cv2.warpAffine(cov, M, (shape[1], shape[0]), flags=cv2.INTER_NEAREST)


def pick_frames(doc: dict) -> Dict[str, dict]:
    """Sharpest face-on anchor, a face-on CONTROL, and sharpest tilt each way."""
    fr = [f for f in (doc.get('frames') or [])
          if f.get('angleDeg') is not None
          and (f.get('laplacianScore') or 0) >= MIN_LAP]
    face = sorted([f for f in fr if abs(f['angleDeg']) < 3.0],
                  key=lambda f: -(f.get('laplacianScore') or 0))
    def band(lo, hi):
        return sorted([f for f in fr if lo <= abs(f['angleDeg']) <= hi
                       and (f['angleDeg'] < 0) == (lo_sign < 0)],
                      key=lambda f: -(f.get('laplacianScore') or 0))
    out: Dict[str, dict] = {}
    if face:
        out['anchor_faceon'] = face[0]
    if len(face) > 1:
        out['CONTROL_faceon2'] = face[1]
    # Split MODERATE (~10 deg, the proposed design point) from EXTREME
    # (~15-18 deg) tilt. More tilt reveals more edge but adds more
    # perspective distortion, so which band is actually best is the real
    # design question -- not something to assume.
    for lo_sign, tag in ((-1, 'neg'), (1, 'pos')):
        mod = band(8.0, 13.0)
        ext = band(13.0, 18.0)
        if mod:
            out[f'tiltMOD_{tag}'] = mod[0]
        if ext:
            out[f'tiltEXT_{tag}'] = ext[0]
    return out


def analyse(cap_id: str, doc: dict) -> Optional[dict]:
    guide = doc.get('guideRegion')
    if not guide:
        print('  no guideRegion, skipping')
        return None
    picks = pick_frames(doc)
    if 'anchor_faceon' not in picks or len(picks) < 2:
        print('  not enough sharp frames across angles, skipping')
        return None
    print(f'\n=== {cap_id[:12]} (nfiq2={doc.get("nfiq2Score")}) ===')
    for k, f in picks.items():
        print(f'  {k:18} angle={f["angleDeg"]:+6.1f}  lap={f.get("laplacianScore"):.0f}')

    prints, minu = {}, {}
    for k, f in picks.items():
        img = _download(f['path'])
        if img is None:
            continue
        p = _render(img, guide, f'{cap_id[:12]}_{k}')
        if p is None:
            continue
        prints[k] = p
        minu[k] = mio.extract_minutiae(p, source=k)
        print(f'    {k:18} print={p.shape} minutiae={len(minu[k])}')

    if 'anchor_faceon' not in prints:
        return None
    A = 'anchor_faceon'
    a_minu, a_shape = minu[A], prints[A].shape[:2]
    a_cov = _coverage(prints[A])

    # Pad centre + extent, for the inner/edge split.
    ys, xs = np.nonzero(a_cov)
    cx, cy = xs.mean(), ys.mean()
    rmax = float(np.sqrt(((xs - cx) ** 2 + (ys - cy) ** 2).max()))

    reg_minu = {A: a_minu}
    cov = {A: a_cov}
    for k in prints:
        if k == A:
            continue
        t, n = reg.register(a_minu, minu[k], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[k], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            print(f'    {k:18} REGISTRATION FAILED (inliers={n})')
            continue
        reg_minu[k] = t.apply_all(minu[k])
        cov[k] = _warp(_coverage(prints[k]), t, a_shape)
        print(f'    {k:18} registered inliers={n}/{len(minu[k])}')

    rows = []
    for k, ms in reg_minu.items():
        if k == A:
            continue
        corrob = new_inner = new_edge = ovl = 0
        for m in ms:
            hit = any(np.hypot(x.x - m.x, x.y - m.y) < DIST_TOL
                      and reg._angle_diff(x.theta, m.theta) <= ANGLE_TOL
                      for x in a_minu)
            if hit:
                corrob += 1
                continue
            xi, yi = int(round(m.x)), int(round(m.y))
            inside_anchor = (0 <= yi < a_cov.shape[0] and 0 <= xi < a_cov.shape[1]
                             and a_cov[yi, xi])
            if inside_anchor:
                ovl += 1
            else:
                r = np.hypot(m.x - cx, m.y - cy) / max(rmax, 1e-6)
                if r >= EDGE_BAND:
                    new_edge += 1
                else:
                    new_inner += 1
        rows.append({'source': k, 'angle': picks[k]['angleDeg'],
                     'total': len(ms), 'corroborated': corrob,
                     'unmatched_inside_anchor': ovl,
                     'new_beyond_anchor_inner': new_inner,
                     'new_beyond_anchor_EDGE': new_edge})

    print(f'\n  {"source":18} {"angle":>7} {"total":>6} {"corrob":>7} '
          f'{"unmatch":>8} {"new_in":>7} {"new_EDGE":>9}')
    for r in rows:
        print(f'  {r["source"]:18} {r["angle"]:+7.1f} {r["total"]:6} '
              f'{r["corroborated"]:7} {r["unmatched_inside_anchor"]:8} '
              f'{r["new_beyond_anchor_inner"]:7} {r["new_beyond_anchor_EDGE"]:9}')
    return {'capture': cap_id, 'rows': rows}


def main():
    ids = ['353cb00b-a70f-4ce7-9005-6db8e70e3616',
           '3edf5455-0334-4068-b487-63e63b09e749',
           '2927b6bd-0cc1-4f75-bdca-44a0e87f98fc']
    results = []
    for cid in ids:
        doc = _db.collection('captures').document(cid).get().to_dict()
        if not doc:
            continue
        r = analyse(cid, doc)
        if r:
            results.append(r)
    out = os.path.join(HERE, 'results', 'phase0b_tilt.json')
    with open(out, 'w') as f:
        json.dump(results, f, indent=2)
    print(f'\nwrote {out} ({len(results)} captures)')


if __name__ == '__main__':
    main()
