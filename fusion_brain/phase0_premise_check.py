"""PHASE 0 -- does the fusion premise actually hold?

The core claim behind the whole fusion idea is that different capture
architectures see DIFFERENT parts of the real finger: "Front V1 is good but
falls off at the edges, SfM captures the edges, sweep captures ridge detail
neither of the others can." That is a testable claim, and it is much cheaper
to test than to build a fusion brain on top of it.

For each real capture this:
  1. renders every available source through the REAL production
     afis_print.generate() (never a reimplementation),
  2. extracts minutiae per source with real mindtct,
  3. registers every source onto the front-V1 anchor in MINUTIAE space,
  4. classifies each non-anchor minutia as
       corroborated        -- another source independently sees it
                              => likely genuine
       unique_in_overlap   -- unmatched, but sitting where other sources DO
                              have coverage => likely spurious
       unique_new_coverage -- unmatched, in territory only this source
                              covers => genuine added coverage, the value-add

KILL CRITERION: if non-anchor sources are dominated by unique_in_overlap
(spurious) rather than corroborated + unique_new_coverage, the premise is
false and no fusion brain should be built on top of it.

Read-only: Firestore/Storage reads, no writes anywhere outside
fusion_brain/results/.
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

import afis_print as ap                       # noqa: E402  (production, read-only)
import minutiae_io as mio                     # noqa: E402
import registration as reg                    # noqa: E402
from minutiae_io import Minutia               # noqa: E402

os.environ.setdefault(
    'GOOGLE_APPLICATION_CREDENTIALS',
    '/root/.claude/uploads/7c276512-7b7e-5f85-8f5b-2eb1bc5e7593/'
    'bc6dc4ea-clearbridgedc699firebaseadminsdkfbsvc6dfd1c643f.json')
from google.cloud import firestore, storage   # noqa: E402

BUCKET = 'clearbridge-dc699.firebasestorage.app'
CACHE = os.path.join(HERE, 'results', 'cache')
os.makedirs(CACHE, exist_ok=True)

DIST_TOL = 12.0     # px, minutia correspondence radius after registration
ANGLE_TOL = 25.0    # deg, orientation agreement required for a correspondence

_bucket = storage.Client().bucket(BUCKET)
_db = firestore.Client()


def _download(path: str) -> Optional[np.ndarray]:
    local = os.path.join(CACHE, path.replace('/', '_'))
    if not os.path.exists(local):
        blob = _bucket.blob(path)
        if not blob.exists():
            return None
        blob.download_to_filename(local)
    return cv2.imread(local)


def _render(img: np.ndarray, guide: dict, tag: str) -> Optional[np.ndarray]:
    """Render one source through the real production print pipeline."""
    cached = os.path.join(CACHE, f'print_{tag}.png')
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


def _coverage(print_img: np.ndarray) -> np.ndarray:
    """Binary mask of real print content (background is white)."""
    return (print_img < 240).astype(np.uint8)


def _warp_coverage(cov: np.ndarray, t: reg.Transform,
                   out_shape: Tuple[int, int]) -> np.ndarray:
    th = np.radians(t.theta_deg)
    c, s = np.cos(th) * t.scale, np.sin(th) * t.scale
    M = np.array([[c, -s, t.dx], [s, c, t.dy]], dtype=np.float32)
    return cv2.warpAffine(cov, M, (out_shape[1], out_shape[0]),
                          flags=cv2.INTER_NEAREST)


def collect_sources(cap_id: str, doc: dict) -> Dict[str, Tuple[np.ndarray, dict]]:
    """Every independently-captured source available on this real capture."""
    sources: Dict[str, Tuple[np.ndarray, dict]] = {}
    guide = doc.get('guideRegion')
    if not guide:
        return sources

    # --- Front V1 anchor: production's own best-ambient selection ---
    frames = doc.get('frames') or []
    amb = [f for f in frames if not f.get('flashOn')]
    if amb:
        best = max(amb, key=lambda f: f.get('laplacianScore') or 0)
        img = _download(best['path'])
        if img is not None:
            sources['front_v1'] = (img, guide)

    # --- Small-offset dedicated stills (the "10-degree oscillation") ---
    for e in (doc.get('focusZoneShots') or []):
        zone, path = e.get('zone'), e.get('path')
        if not zone or not path:
            continue
        img = _download(path)
        if img is not None:
            # Same framing as the main burst -- only the AF/AE target moved --
            # so each is rendered as its OWN full print with the main guide,
            # not as a sub-patch. That is the "independent candidate" model.
            sources[f'focuszone_{zone}'] = (img, guide)

    # --- Camera-2 macro (different lens entirely) ---
    for cam in (doc.get('secondaryCameras') or []):
        if cam.get('name') != '2':
            continue
        path = cam.get('ambientPath') or (cam.get('paths') or [None])[0]
        if not path:
            continue
        img = _download(path)
        if img is None:
            continue
        # Real measured camera-2 geometry (rounds 31/33), same values
        # main.py's own secondary-camera loop uses.
        sources['macro_cam2'] = (img, {'cx': 0.5, 'cy': 0.34, 'rx': 0.11,
                                        'ry': 0.13, 'tipAngleDeg': 0.0,
                                        'n': guide.get('n', 2.5)})

    # --- Sweep zones (texture via per-zone ambient/flash) ---
    sw = doc.get('sweepBurstDebug') or {}
    paths = sw.get('paths') or {}
    gregions = sw.get('guideRegions') or {}
    for key, path in paths.items():
        if not key.endswith('_amb2'):     # ambient frame per zone
            continue
        zone = key[:-len('_amb2')]
        img = _download(path)
        if img is None:
            continue
        zg = gregions.get(zone) or guide
        sources[f'sweep_{zone}'] = (img, zg)
    return sources


def analyse_capture(cap_id: str, doc: dict) -> Optional[dict]:
    print(f'\n=== {cap_id[:12]} (nfiq2={doc.get("nfiq2Score")}) ===')
    srcs = collect_sources(cap_id, doc)
    if 'front_v1' not in srcs or len(srcs) < 2:
        print('  insufficient sources, skipping')
        return None
    print(f'  sources: {sorted(srcs.keys())}')

    prints: Dict[str, np.ndarray] = {}
    minu: Dict[str, List[Minutia]] = {}
    for name, (img, guide) in srcs.items():
        p = _render(img, guide, f'{cap_id[:12]}_{name}')
        if p is None:
            continue
        prints[name] = p
        minu[name] = mio.extract_minutiae(p, source=name)
        print(f'    {name:22} print={p.shape}  minutiae={len(minu[name])}')

    if 'front_v1' not in prints:
        return None
    anchor = 'front_v1'
    a_minu = minu[anchor]
    a_shape = prints[anchor].shape[:2]

    # Register every other source onto the anchor, in minutiae space.
    transforms: Dict[str, reg.Transform] = {}
    reg_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    cov: Dict[str, np.ndarray] = {anchor: _coverage(prints[anchor])}
    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name],
                            dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t,
                              dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            print(f'    {name:22} REGISTRATION FAILED (inliers={n})')
            continue
        transforms[name] = t
        reg_minu[name] = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)
        print(f'    {name:22} registered, inliers={n}/{len(minu[name])}')

    # Classify each source's minutiae against every OTHER source.
    rows = []
    for name, ms in reg_minu.items():
        others = [o for o in reg_minu if o != name]
        corroborated = unique_overlap = unique_new = 0
        for m in ms:
            hit = False
            for o in others:
                for mo in reg_minu[o]:
                    if (abs(mo.x - m.x) < DIST_TOL and abs(mo.y - m.y) < DIST_TOL
                            and reg._angle_diff(mo.theta, m.theta) <= ANGLE_TOL
                            and np.hypot(mo.x - m.x, mo.y - m.y) < DIST_TOL):
                        hit = True
                        break
                if hit:
                    break
            if hit:
                corroborated += 1
                continue
            xi, yi = int(round(m.x)), int(round(m.y))
            covered_elsewhere = False
            for o in others:
                c = cov.get(o)
                if c is None:
                    continue
                if 0 <= yi < c.shape[0] and 0 <= xi < c.shape[1] and c[yi, xi]:
                    covered_elsewhere = True
                    break
            if covered_elsewhere:
                unique_overlap += 1
            else:
                unique_new += 1
        rows.append({'source': name, 'total': len(ms),
                     'corroborated': corroborated,
                     'unique_in_overlap': unique_overlap,
                     'unique_new_coverage': unique_new})

    print(f'\n  {"source":22} {"total":>6} {"corrob":>7} {"uniq/ovl":>9} {"uniq/new":>9}')
    for r in rows:
        print(f'  {r["source"]:22} {r["total"]:6} {r["corroborated"]:7} '
              f'{r["unique_in_overlap"]:9} {r["unique_new_coverage"]:9}')
    return {'capture': cap_id, 'rows': rows,
            'registered': sorted(transforms.keys())}


def main(limit: int = 4, require_sweep: bool = False, scan: int = 60):
    docs = list(_db.collection('captures')
                .order_by('createdAt', direction=firestore.Query.DESCENDING)
                .limit(scan).stream())
    results = []
    for d in docs:
        v = d.to_dict()
        if v.get('status') != 'scored':
            continue
        sweep_paths = (v.get('sweepBurstDebug') or {}).get('paths') or {}
        if require_sweep and not sweep_paths:
            continue
        has_multi = bool(v.get('focusZoneShots')) or bool(v.get('secondaryCameras')) \
            or bool(sweep_paths)
        if not has_multi:
            continue
        r = analyse_capture(d.id, v)
        if r:
            results.append(r)
        if len(results) >= limit:
            break
    out = os.path.join(HERE, 'results',
                        'phase0_premise_sweep.json' if require_sweep
                        else 'phase0_premise.json')
    with open(out, 'w') as f:
        json.dump(results, f, indent=2)
    print(f'\nwrote {out}  ({len(results)} captures)')


if __name__ == '__main__':
    _lim = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    _sweep = len(sys.argv) > 2 and sys.argv[2] == 'sweep'
    main(limit=_lim, require_sweep=_sweep, scan=400 if _sweep else 60)
