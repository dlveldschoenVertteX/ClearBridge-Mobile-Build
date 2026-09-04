"""Build MAIN-CAMERA reference templates to replace the macro references.

Direct rectification of the evaluation-power problem the CTO identified
(2026-08-26) and `diag_reference_power.py` quantified: every bozorth3
score in this track is measured against `macro_round32`/`macro_round35`,
which are camera-"2" prints -- and round 40 established camera "2" is the
weakest of the three back cameras (won 2 of 136 real captures; beaten by
camera "3" on both mean and max real NFIQ2). Measured consequence:

  ref_macro_round32   96 minutiae, bbox  52,866   <- HALF the anchor's
  ref_macro_round35  130 minutiae, bbox 139,761
  anchor (6b43c255)  135 minutiae, bbox 103,016

Against round32, only 56 of a wide composite's 273 minutiae (20%) fall
where the reference can see them -- the other 79% cannot match anything
yet still enlarge the template, which this track has separately measured
costs real score. That is a directional bias against exactly the thing
fusion exists to do.

The fix is not a cleverer score, it is a better instrument. Both source
captures (`f4cb3ba5` round 32, `b615f37b` round 35) carry a full 8-frame
MAIN-camera burst and their own `guideRegion` -- the macro print was only
ever chosen as the reference because those two rounds were macro
investigations, not because it was the better reference. Rendering the
main-camera print from the same captures gives a cross-session reference
of the same finger from the higher-quality, wider-coverage camera, with
no change to how anything is scored.

Deliberately ADDITIVE: writes `ref_main_round32`/`ref_main_round35`
alongside the existing macro references rather than replacing them, so
every historical number stays reproducible and the two instruments can be
compared directly on the same candidates.

Read-only w.r.t. Firestore/Storage; writes only into the local cache.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                      # noqa: E402
import numpy as np                              # noqa: E402

import minutiae_io as mio                       # noqa: E402
from phase0c_real_fusion_capture import (       # noqa: E402
    _db, _download, _render, CACHE,
)

SESSIONS = {'main_round32': 'f4cb3ba5', 'main_round35': 'b615f37b'}


def build(label: str, prefix: str) -> bool:
    hits = [d for d in _db.collection('captures').limit(500).stream()
            if d.id.startswith(prefix)]
    if not hits:
        print(f'  {label}: capture {prefix} not found')
        return False
    v = hits[0].to_dict()
    guide = v.get('guideRegion')
    frames = v.get('frames') or []
    if not guide or not frames:
        print(f'  {label}: missing guideRegion or frames')
        return False

    # Sharpest AMBIENT frame, chosen the same way the client would --
    # ambient preferred over flash, matching main.py's own documented
    # front_only_v1 selection (client laplacianScore is unreliable as an
    # absolute, so measure it here on the real decoded frame instead).
    amb = [f for f in frames if isinstance(f, dict) and not f.get('flashOn')]
    pool = amb or [f for f in frames if isinstance(f, dict)]
    best, best_lap = None, -1.0
    for f in pool:
        p = f.get('path')
        if not p:
            continue
        img = _download(p)
        if img is None:
            continue
        g = img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        lap = float(cv2.Laplacian(g, cv2.CV_64F).var())
        if lap > best_lap:
            best, best_lap = img, lap
    if best is None:
        print(f'  {label}: no decodable frame')
        return False

    print(f'  {label}: anchor frame lap={best_lap:.1f} from {len(pool)} candidates')
    pr = _render(best, guide, f'ref_{label}')
    if pr is None:
        print(f'  {label}: render failed')
        return False
    minu = mio.extract_minutiae(pr, source=label)
    out = os.path.join(CACHE, f'ref_{label}.xyt')
    mio.write_xyt(minu, out)
    xs = [m.x for m in minu]
    ys = [m.y for m in minu]
    area = (max(xs) - min(xs)) * (max(ys) - min(ys)) if minu else 0
    print(f'  {label}: {len(minu)} minutiae, bbox area {area:.0f} -> {out}')
    return True


if __name__ == '__main__':
    print('\n=== building main-camera references ===')
    for lab, pre in SESSIONS.items():
        build(lab, pre)
