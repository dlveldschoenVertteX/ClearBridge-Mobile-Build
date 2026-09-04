"""Sweep the PRE-processing stages -- the ones the filter sweep never touched.

The earlier `sweep_processing_levers.py` covered the ENHANCEMENT side
(Gabor sigma/gamma, frequency floor, crease trim, vignette) and found
production already at an optimum. It did not touch anything upstream of
those. This does.

Levers here, and why each is worth a real test:

  * **CLAHE clipLimit / tileGridSize** -- the FIRST processing step
    (`g8 = createCLAHE(3.0, (8,8)).apply(gray)`), never scored against
    matchability. Already known from the Phase 7/8 crop-path work to be a
    REAL sensitivity: `tileGridSize` is relative to the IMAGE, so the same
    pad gets 533x400px tiles full-frame vs 308x320px cropped, and changing
    it demonstrably moved minutiae counts and scores. It is nonlinear and
    it runs before everything else, so every later stage inherits its
    decisions. The most obviously untested lever in the pipeline.

  * **CLAHE OFF entirely** -- the control that says whether this stage
    earns its place at all. Never run before.

  * **_MASK_COVER_DILATE** -- how far the content-aware mask may grow
    beyond the guide (1.3 today). Its own comment records a real
    measurement (1.6 measurably hurt a well-placed capture, NFIQ2 79->68)
    but that was NFIQ2, not matchability, and 1.0 (shrink-only) was never
    tested against real bozorth3.

  * **Ambient multi-frame stacking** -- the anchor is currently ONE frame.
    Aligning and averaging the ambient burst is the one noise-reduction
    idea that does NOT inflate the template, which matters given this
    project's repeatedly-measured template-density penalty (r = -0.246
    across the filter sweep's 27 renders).

Same discipline as the filter sweep: one variable at a time from the
production baseline, real bozorth3 against the round-40 main-camera
references, 3 real captures, reported per capture, never as a bare mean.

HONEST PRIOR: this project has a long record of denoise/pre-pass stages
measuring negative (pyfing, nnsHybrid, coherenceDiff, ridgeRestoreHybrid --
four independent attempts, all negative). "Production is already right" is
a likely and perfectly good outcome here too.

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                      # noqa: E402
import numpy as np                              # noqa: E402

import afis_print as ap                         # noqa: E402
import minutiae_io as mio                       # noqa: E402
from phase0c_real_fusion_capture import (       # noqa: E402
    _db, collect_sources, _flash_pair_for, _download, CACHE,
)
from phase2_tps_fusion import _best_score        # noqa: E402

CAPS = ('6b43c255', '43378ea7', '5181d451')
REF_NAMES = ('main_round32', 'main_round35')

_ORIG_CLAHE = cv2.createCLAHE
# (clipLimit, tiles) to force on the ONE call that builds g8, or None to
# leave production behaviour alone. 'off' disables CLAHE entirely.
_CLAHE_OVERRIDE: Optional[object] = None
_TARGET_SHAPE: Optional[Tuple[int, int]] = None


class _Identity:
    def apply(self, img):
        return img


def _patched_clahe(clipLimit=3.0, tileGridSize=(8, 8)):
    """Override only the call whose target image is the frame being
    rendered -- the ECC/registration helpers build their own CLAHE at the
    same (8,8) default on deliberately DOWNSCALED copies, and must not be
    touched or the comparison is confounded."""
    if _CLAHE_OVERRIDE is None or _TARGET_SHAPE is None:
        return _ORIG_CLAHE(clipLimit, tileGridSize)
    ov = _CLAHE_OVERRIDE
    shape = _TARGET_SHAPE

    class _W:
        def apply(self, img):
            if img.shape[:2] != shape:
                return _ORIG_CLAHE(clipLimit, tileGridSize).apply(img)
            if ov == 'off':
                return img
            cl, tiles = ov
            return _ORIG_CLAHE(cl, tiles).apply(img)
    return _W()


def _stacked_ambient(doc: dict, guide: dict) -> Optional[np.ndarray]:
    """Align+average every ambient frame in the burst, via production's own
    `_align_face_on_stack`. Reuses production code rather than a lookalike."""
    frames = [f for f in (doc.get('frames') or [])
              if isinstance(f, dict) and not f.get('flashOn') and f.get('path')]
    if len(frames) < 2:
        return None
    imgs = []
    for f in frames:
        im = _download(f['path'])
        if im is None:
            continue
        imgs.append(im if im.ndim == 2 else cv2.cvtColor(im, cv2.COLOR_BGR2GRAY))
    if len(imgs) < 2:
        return None
    try:
        st = ap._stack_face_on(imgs)
    except Exception as e:
        print(f'    stack failed: {e}')
        return None
    return st


# Round 2: the first sweep found a monotonic dose-response on CLAHE clip
# (1.0 -> -16, 2.0 -> -1, 3.0 baseline, 5.0 -> +10). A trend is far more
# convincing than a single point, but a trend that only ever rises is
# equally suspect -- so this maps the curve out far enough to find where
# it turns over. If it never turns over, the "gain" is more likely an
# artifact of the metric than a real optimum, and should be treated as
# such.
ARMS: List[tuple] = [
    ('BASELINE (production clip=3)', {'clahe': None}),
    ('CLAHE clip=4.0',               {'clahe': (4.0, (8, 8))}),
    ('CLAHE clip=5.0',               {'clahe': (5.0, (8, 8))}),
    ('CLAHE clip=6.0',               {'clahe': (6.0, (8, 8))}),
    ('CLAHE clip=8.0',               {'clahe': (8.0, (8, 8))}),
    ('CLAHE clip=12.0',              {'clahe': (12.0, (8, 8))}),
    ('CLAHE clip=20.0',              {'clahe': (20.0, (8, 8))}),
]


def run() -> dict:
    global _CLAHE_OVERRIDE, _TARGET_SHAPE
    refs = {}
    for rn in REF_NAMES:
        p = os.path.join(CACHE, f'ref_{rn}.xyt')
        if os.path.exists(p):
            refs[rn] = p
    if not refs:
        print('no main-camera references cached'); return {}

    docs = list(_db.collection('captures').limit(500).stream())
    loaded = {}
    for short in CAPS:
        cid = next((d.id for d in docs if d.id.startswith(short)), None)
        if cid is None:
            continue
        v = _db.collection('captures').document(cid).get().to_dict()
        srcs = collect_sources(v)
        if 'front_v1' not in srcs:
            continue
        img, g = srcs['front_v1']
        fp = _flash_pair_for(v, 'front_v1')
        kw = ({'ambient_burst': [fp[0]], 'flash_burst': [fp[1]]} if fp else {})
        loaded[short] = (img, g, kw, v)

    hdr = f'{"arm":32}' + ''.join(f'{s:>22}' for s in loaded)
    print('\n' + hdr)
    print(f'{"":32}' + ''.join(f'{"minu  m32  m35":>22}' for _ in loaded))
    print('-' * len(hdr))

    cv2.createCLAHE = _patched_clahe
    results: Dict[str, dict] = {}
    baseline: Dict[str, tuple] = {}
    try:
        for label, cfg in ARMS:
            row = f'{label:32}'
            results[label] = {}
            for short, (img, g, kw, doc) in loaded.items():
                src = img
                if cfg.get('stack'):
                    st = _stacked_ambient(doc, g)
                    if st is None:
                        row += f'{"n/a":>22}'; continue
                    src = st
                gray = src if src.ndim == 2 else cv2.cvtColor(src, cv2.COLOR_BGR2GRAY)
                _TARGET_SHAPE = gray.shape[:2]
                _CLAHE_OVERRIDE = cfg.get('clahe')
                old_dil = ap._MASK_COVER_DILATE
                if 'dilate' in cfg:
                    ap._MASK_COVER_DILATE = cfg['dilate']
                try:
                    out, _p = ap.generate([src], [0.0], [None], guide_region=g,
                                          freq_normalize=True, stack_cache={}, **kw)
                except Exception as e:
                    row += f'{"ERR":>22}'
                    results[label][short] = {'error': str(e)[:60]}
                    continue
                finally:
                    ap._MASK_COVER_DILATE = old_dil
                    _CLAHE_OVERRIDE = None
                    _TARGET_SHAPE = None
                if out is None:
                    row += f'{"None":>22}'; continue
                pr = out if out.ndim == 2 else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
                m = mio.extract_minutiae(pr, source=short)
                xp = os.path.join(CACHE, f'pp_{short}_{abs(hash(label)) % 99999}.xyt')
                mio.write_xyt(m, xp)
                sc = {rn: _best_score(xp, rp) for rn, rp in refs.items()}
                vals = [sc.get(rn) for rn in REF_NAMES]
                results[label][short] = {'minutiae': len(m), 'scores': sc}
                if label.startswith('BASELINE'):
                    baseline[short] = tuple(vals); mark = ''
                else:
                    b = baseline.get(short)
                    if b and all(x is not None for x in vals) and all(x is not None for x in b):
                        d = sum(vals) - sum(b)
                        mark = f' {d:+d}' if d else '  ='
                    else:
                        mark = ''
                cell = (f'{len(m):4} {vals[0] if vals[0] is not None else "-":>4} '
                        f'{vals[1] if vals[1] is not None else "-":>4}{mark}')
                row += f'{cell:>22}'
                try:
                    os.remove(xp)
                except OSError:
                    pass
            print(row)
    finally:
        cv2.createCLAHE = _ORIG_CLAHE

    p = os.path.join(HERE, 'results', 'sweep_clahe_curve.json')
    with open(p, 'w') as f:
        json.dump(results, f, indent=2)
    print(f'\nwrote {p}')
    return results


if __name__ == '__main__':
    run()
