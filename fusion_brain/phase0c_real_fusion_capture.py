"""PHASE 0c -- does the fusion premise hold on REAL fusion_capture output?

Phase 0/0b tested the premise (front/edge/sweep sources contribute
non-redundant minutiae) against captures from OTHER architectures
(front_only_v1, oscillating_8phase) as a proxy, because fusion_capture
itself hadn't produced any real data yet. It now has -- this is the first
run of the exact same registration/classification pipeline against an
actual fusion_v1 capture's own front+tilt+sweep frames.

Deliberately a separate script rather than extending phase0_premise_check's
own collect_sources(): that function's caller explicitly filters OUT
isExperiment/fusionVersion captures on purpose (see its own comment) --
fusion_v1 must never quietly enter the production baseline population.
This script is the one place that's actually allowed to load a fusion_v1
doc, and it does so by capture ID, never by scanning the general
population.

Same kill criterion as phase0/phase0b: if non-anchor sources are dominated
by unique_in_overlap (spurious) rather than corroborated + unique_new_
coverage, the premise is false on fusion_capture's own real data too.

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
CACHE = os.path.join(HERE, 'results', 'cache_fusion_v1')
os.makedirs(CACHE, exist_ok=True)

DIST_TOL = 12.0
ANGLE_TOL = 25.0

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
    return (print_img < 240).astype(np.uint8)


def _warp_coverage(cov: np.ndarray, t: reg.Transform,
                   out_shape: Tuple[int, int]) -> np.ndarray:
    th = np.radians(t.theta_deg)
    c, s = np.cos(th) * t.scale, np.sin(th) * t.scale
    M = np.array([[c, -s, t.dx], [s, c, t.dy]], dtype=np.float32)
    return cv2.warpAffine(cov, M, (out_shape[1], out_shape[0]),
                          flags=cv2.INTER_NEAREST)


def collect_sources(doc: dict) -> Dict[str, Tuple[np.ndarray, dict]]:
    """fusion_v1's own real schema: frames / tiltShots / sweepShots,
    fusionGuideRegions keyed by sweep station + 'main'. Tilt stations reuse
    the main guide (front_capture_controller.dart's tilt phase never moves
    the guide -- only the cue text changes), matching guideFor's own
    `(i) => PadSilhouetteShape.defaultShape` in fusion_capture_controller.
    dart."""
    sources: Dict[str, Tuple[np.ndarray, dict]] = {}
    guide = doc.get('guideRegion')
    if not guide:
        return sources

    frames = doc.get('frames') or []
    amb = [f for f in frames if not f.get('flashOn')]
    if amb:
        best = max(amb, key=lambda f: f.get('laplacianScore') or 0)
        img = _download(best['path'])
        if img is not None:
            sources['front_v1'] = (img, guide)

    # Tilt: one shot per station in this real capture (not always a full
    # ambient+flash pair -- 2 of 3 stations lost one upload to a real
    # 45s timeout, see fusionDebug). Prefer ambient (matches front_v1's own
    # convention), fall back to flash if that's the only one that landed --
    # either is a legitimate single-frame candidate for this premise check,
    # which only needs ONE rendered print per source, not a fused pair.
    tilt = doc.get('tiltShots') or []
    by_station: Dict[str, Dict[str, dict]] = {}
    for t in tilt:
        tag = t.get('tag', '')
        if '_' not in tag:
            continue
        station, kind = tag.rsplit('_', 1)  # 'tilt_left_amb' -> ('tilt_left', 'amb')
        by_station.setdefault(station, {})[kind] = t
    for station, kinds in by_station.items():
        pick = kinds.get('amb') or kinds.get('fl')
        if not pick:
            continue
        img = _download(pick['path'])
        if img is not None:
            sources[station] = (img, guide)

    # Sweep: real per-zone guide regions already recorded.
    fgr = doc.get('fusionGuideRegions') or {}
    sweep = doc.get('sweepShots') or []
    by_zone: Dict[str, Dict[str, dict]] = {}
    for s in sweep:
        tag = s.get('tag', '')
        if '_' not in tag:
            continue
        zone, kind = tag.rsplit('_', 1)
        by_zone.setdefault(zone, {})[kind] = s
    for zone, kinds in by_zone.items():
        pick = kinds.get('amb') or kinds.get('fl')
        if not pick:
            continue
        img = _download(pick['path'])
        if img is not None:
            sources[zone] = (img, fgr.get(zone, guide))

    # Macro (camera "2"): fusion_capture_controller.dart's macro phase
    # captures exactly ONE dedicated close-up position (not multiple
    # stations like tilt/sweep), tagged macro_amb_0 / macro_fl_0 -- so this
    # reuses front_v1's own prefer-ambient-fall-back-to-flash selection by
    # the `flashOn` field already on each entry, rather than tilt/sweep's
    # tag-parsing/station-grouping logic, which does not apply here (there
    # is no station to group by).
    macro = doc.get('macroShots') or []
    if macro:
        amb_m = [m for m in macro if not m.get('flashOn')]
        pick = amb_m[0] if amb_m else macro[0]
        img = _download(pick['path'])
        if img is not None:
            sources['macro'] = (img, _macro_guide(doc, guide))

    return sources


def _macro_guide(doc: dict, main_guide: dict) -> dict:
    """Crop region for the macro source -- real per-device correction when
    possible, a loudly-flagged approximation otherwise.

    `fusion_capture` now records `cameraLensInfo` (real Camera2
    characteristics per camera id, ported 2026-08-26) the same way
    `main.py`'s own secondary-camera scoring loop already does. When it's
    present for both the main camera ("0") and camera "2", this applies
    the SAME general FOV-correction formula production uses (main.py,
    ~line 1637): angular field of view ~= sensorSize/focalLength, so
    scaling rx/ry by (fl_sec/sensor_sec)/(fl_main/sensor_main) extracts
    the equivalent physical pad region from the differently-framed
    secondary lens.

    Deliberately DOES NOT port production's cy=0.34/rx=0.11/ry=0.13
    overrides for camera "2" -- those are real, but they are empirical
    calibration measured against ONE specific device's own camera "2"
    physical mounting (front_capture_controller.dart's round-31/33
    history), not a portable formula. Blindly applying a Doogee-specific
    offset to a different phone's different macro/auxiliary lens would
    silently introduce a NEW wrong assumption -- exactly the failure mode
    multi-device testing exists to catch, not repeat. cx/cy stay at the
    generic 0.5 centre (matching what production itself uses for every
    camera it has no per-device calibration for, e.g. its own camera "3").

    Falls back to the main camera's own guide_region, unchanged, with a
    loud runtime warning, whenever cameraLensInfo is absent (e.g. every
    capture before this field existed) or incomplete.
    """
    lens_info = doc.get('cameraLensInfo') or {}
    main_lens = lens_info.get('0') or {}
    macro_lens = lens_info.get('2') or {}
    fl_main = main_lens.get('focalLengthMm')
    fl_macro = macro_lens.get('focalLengthMm')
    sw_main = main_lens.get('sensorWidthMm')
    sh_main = main_lens.get('sensorHeightMm')
    sw_macro = macro_lens.get('sensorWidthMm')
    sh_macro = macro_lens.get('sensorHeightMm')
    if (fl_main and fl_macro and sw_main and sh_main and sw_macro and sh_macro
            and fl_main > 0 and sw_macro > 0 and sh_macro > 0):
        rx_ratio = (fl_macro / sw_macro) / (fl_main / sw_main)
        ry_ratio = (fl_macro / sh_macro) / (fl_main / sh_main)
        print(f'    [macro] cameraLensInfo-corrected crop: '
              f'rx_ratio={rx_ratio:.3f} ry_ratio={ry_ratio:.3f} '
              f'(fl {fl_main:.2f}->{fl_macro:.2f}mm, '
              f'sensor {sw_main:.2f}x{sh_main:.2f}->{sw_macro:.2f}x{sh_macro:.2f}mm)')
        return {
            'cx': 0.5,
            'cy': 0.5,
            'rx': main_guide['rx'] * rx_ratio,
            'ry': main_guide['ry'] * ry_ratio,
            'tipAngleDeg': main_guide.get('tipAngleDeg', 0.0),
            'n': main_guide.get('n', 2.5),
        }
    print('    [macro] WARNING: no cameraLensInfo for this capture -- '
          'cropped with the FRONT camera\'s unmodified guide_region, '
          'unvalidated for this lens. Visually confirm the rendered '
          'print before trusting this source.')
    return main_guide


def analyse(cap_id: str, doc: dict) -> Optional[dict]:
    print(f'\n=== REAL fusion_v1 capture {cap_id[:12]} (status={doc.get("status")}) ===')
    srcs = collect_sources(doc)
    if 'front_v1' not in srcs or len(srcs) < 2:
        print(f'  insufficient sources ({sorted(srcs.keys())}), stopping')
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
        print(f'    {name:16} print={p.shape}  minutiae={len(minu[name])}')

    if 'front_v1' not in prints:
        return None
    anchor = 'front_v1'
    a_minu = minu[anchor]
    a_shape = prints[anchor].shape[:2]

    transforms: Dict[str, reg.Transform] = {}
    reg_minu: Dict[str, List[Minutia]] = {anchor: a_minu}
    cov: Dict[str, np.ndarray] = {anchor: _coverage(prints[anchor])}
    for name in prints:
        if name == anchor:
            continue
        t, n = reg.register(a_minu, minu[name], dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is not None:
            t, n = reg.refine(a_minu, minu[name], t, dist_tol=DIST_TOL, angle_tol=ANGLE_TOL)
        if t is None or n < 6:
            print(f'    {name:16} REGISTRATION FAILED (inliers={n})')
            continue
        transforms[name] = t
        reg_minu[name] = t.apply_all(minu[name])
        cov[name] = _warp_coverage(_coverage(prints[name]), t, a_shape)
        print(f'    {name:16} registered, inliers={n}/{len(minu[name])}, '
              f'scale={t.scale:.2f} theta={t.theta_deg:.1f}')

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

    print(f'\n  {"source":16} {"total":>6} {"corrob":>7} {"uniq/ovl":>9} {"uniq/new":>9}')
    for r in rows:
        print(f'  {r["source"]:16} {r["total"]:6} {r["corroborated"]:7} '
              f'{r["unique_in_overlap"]:9} {r["unique_new_coverage"]:9}')

    return {'capture': cap_id, 'rows': rows, 'registered': sorted(transforms.keys()),
            'sources_available': sorted(srcs.keys())}


def main(cap_id: str):
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing (use phase0_premise_check.py instead)')
        return
    r = analyse(cap_id, v)
    out = os.path.join(HERE, 'results', 'phase0c_real_fusion_capture.json')
    with open(out, 'w') as f:
        json.dump([r] if r else [], f, indent=2)
    print(f'\nwrote {out}')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase0c_real_fusion_capture.py <captureId>')
        sys.exit(1)
    main(sys.argv[1])
