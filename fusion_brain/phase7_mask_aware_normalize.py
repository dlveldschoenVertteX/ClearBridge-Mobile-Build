"""PHASE 7 -- why do two renders of the SAME pad disagree?

Real defect found 2026-08-26 by chasing a 17-point score gap that should
not have existed. Rendering the SAME anchor two ways -- from the full
frame with its own guide, and from a pad-dominated crop with the
equivalent adjusted guide -- produces two genuinely different prints:

  full frame : 135 minutiae, 40,905 ink px, scores 34 / 44 / 29 / 31
  crop       : 135 minutiae, 36,675 ink px, scores 24 / 27 / 27 / 36

32% of pixels disagree even after phase-correlation alignment, and the
crop has 10% less ink. Yet both report identical afis params
(wavelength 20.0, freqScale 0.7, mask 'guide') and near-identical print
sizes -- so this is not a scale, mask or resample difference.

ROOT CAUSE, found by code read and then confirmed by measurement:
`_normalize()` computes its mean and variance over the WHOLE input
image, and at that point in `generate()` the input is the entire frame,
not the pad. Measured on this capture:

  full frame : whole-image mean 121.82 std 41.23 | guide is  3.1% of frame
  crop       : whole-image mean 124.15 std 29.69 | guide is  6.7% of frame
  inside-guide content is IDENTICAL in both: mean 180.15 std 57.42

Same pad pixels, but a ~39% different global std, so
`m0 + sqrt(v0*(x-m)^2/v)*sign(x-m)` maps them to ~1.4x different
normalised contrast. The Gabor bank downstream does not reveal ridges,
it SYNTHESISES them from what it is given -- so a different contrast
scale means a different ridge pattern, which is exactly what the pixel
diff shows.

WHY THIS MATTERS BEYOND THIS TRACK: in production `_normalize(g8)` runs
on the full captured frame too. The pad's normalisation therefore
depends on how much desk, hand and background happen to be in shot --
i.e. on framing, not on the finger. Two captures of the same finger at
different framings get different normalisation, which is a real source
of the cross-session inconsistency this project's prime directive is
about. Nothing about the pad changed; only the background did.

HYPOTHESIS 1 (mask-aware normalisation) -- TESTED AND REFUTED. Drawing
the statistics from inside the pad mask changed NOTHING: byte-identical
ink counts and identical scores on all four references. The reason is
worth recording so it is not re-attempted: `_normalize` reduces to
`m0 + sqrt(v0)*(x-m)/sqrt(v)`, a pure AFFINE intensity transform, and
everything downstream is affine-invariant -- Sobel orientation depends on
gradient RATIOS, ridge periodicity is unchanged by scaling, and the Gabor
stage is linear followed by a relative threshold. The global statistics
genuinely do not matter. A plausible-sounding mechanism, refuted by its
own experiment.

HYPOTHESIS 2 (CLAHE tile scale) -- the real one. `generate()` builds its
working image as
    g8 = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(gray)
and `tileGridSize` is relative to the IMAGE, not to the content. On this
capture that means:
    full frame 4266x3200 -> tiles of 533x400 px
    crop       2464x2563 -> tiles of 308x320 px
CLAHE is a NONLINEAR, LOCAL operator, so a different tile size over the
same pad pixels is a genuinely different contrast enhancement -- unlike
`_normalize`, this one downstream cannot be invariant to. It directly
explains a 10% ink difference and 32% pixel disagreement from identical
input pixels.

WHY THIS MATTERS BEYOND THIS TRACK, restated for hypothesis 2: in
production the pad's local contrast enhancement scales with the frame
dimensions and with how much of the frame the pad occupies -- i.e. with
framing and camera resolution, not with the finger. Two captures of the
same finger at different distances get different CLAHE tile scales over
the pad, hence different synthesised ridges. That is a real
cross-session inconsistency source on the axis this project's prime
directive is about.

THE FIX TESTED HERE: choose the tile grid so each tile is a consistent
PIXEL size regardless of frame dimensions, making the pad's contrast
enhancement a property of the content rather than of the framing.

Deliberately tested by MONKEYPATCHING production's `_normalize` from
this research module rather than editing `afis_print.py` -- production
stays untouched until this shows a real gain on real references, same
standing discipline as everything else in this track.

Read-only: Firestore/Storage reads, no writes outside fusion_brain/.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                      # noqa: E402
import numpy as np                              # noqa: E402

import afis_print as ap                         # noqa: E402
import minutiae_io as mio                       # noqa: E402
import phase6_tps_maxc_mosaic as p6             # noqa: E402
from phase0c_real_fusion_capture import (       # noqa: E402
    _db, collect_sources, CACHE,
)
from phase2_tps_fusion import _best_score        # noqa: E402

_ORIG_NORMALIZE = ap._normalize
_ORIG_CLAHE = cv2.createCLAHE
# Target tile edge in pixels. None = production behaviour (8x8 grid over
# whatever frame is supplied). 400 matches the full-frame arm's own tile
# height on this capture, i.e. the arm that scores best today -- a real
# observed value, not a guess, though n=1 and swept below.
_CLAHE_TILE_PX: Optional[int] = None
_CLAHE_SHAPE: Optional[tuple] = None
# Set to a uint8/bool mask (same HxW as the image being normalised) to make
# _normalize draw its statistics from inside it. None restores production.
_STATS_MASK: Optional[np.ndarray] = None


def _masked_normalize(img: np.ndarray, m0: float = 100.0,
                      v0: float = 100.0) -> np.ndarray:
    """Production `_normalize`, except the statistics come from the pad.

    Falls back to the original behaviour whenever the mask is absent,
    the wrong shape, or too small to give a stable estimate -- so this can
    only ever change the cases it was built for, never break another one.
    """
    m = _STATS_MASK
    if m is None or m.shape[:2] != img.shape[:2]:
        return _ORIG_NORMALIZE(img, m0, v0)
    sel = img[m > 0]
    if sel.size < 1024:
        return _ORIG_NORMALIZE(img, m0, v0)
    f = img.astype(np.float32)
    mu = float(sel.mean())
    var = max(float(sel.var()), 1e-6)
    return m0 + np.sqrt(v0 * (f - mu) ** 2 / var) * np.sign(f - mu)


def _fixed_tile_clahe(clipLimit=3.0, tileGridSize=(8, 8)):
    """createCLAHE that sizes its grid from the image, not from a constant.

    Only overrides the (8, 8) default `generate()` passes for its main
    working image; any caller asking for a different grid is left alone,
    so the ECC/registration helpers that build their own CLAHE at
    (8, 8) on DELIBERATELY downscaled copies are unaffected... except that
    they also use (8, 8), so this is scoped by `_CLAHE_SHAPE` instead:
    only the call whose target image matches the shape we are rendering
    gets the adaptive grid.
    """
    if _CLAHE_TILE_PX is None or _CLAHE_SHAPE is None:
        return _ORIG_CLAHE(clipLimit, tileGridSize)
    h, w = _CLAHE_SHAPE
    gx = max(1, int(round(w / float(_CLAHE_TILE_PX))))
    gy = max(1, int(round(h / float(_CLAHE_TILE_PX))))

    class _Wrapper:
        def apply(self, img):
            if img.shape[:2] == (h, w):
                return _ORIG_CLAHE(clipLimit, (gx, gy)).apply(img)
            return _ORIG_CLAHE(clipLimit, tileGridSize).apply(img)
    return _Wrapper()


def _render(img: np.ndarray, guide: dict, masked: bool) -> Optional[np.ndarray]:
    global _STATS_MASK
    if masked:
        _STATS_MASK = ap._superellipse_mask(img.shape[:2], guide)
        ap._normalize = _masked_normalize
    else:
        _STATS_MASK = None
        ap._normalize = _ORIG_NORMALIZE
    global _CLAHE_SHAPE
    _CLAHE_SHAPE = img.shape[:2]
    cv2.createCLAHE = _fixed_tile_clahe
    try:
        out, params = ap.generate([img], [0.0], [None], guide_region=guide,
                                  freq_normalize=True, stack_cache={})
    finally:
        cv2.createCLAHE = _ORIG_CLAHE
        ap._normalize = _ORIG_NORMALIZE
        _STATS_MASK = None
        _CLAHE_SHAPE = None
    if out is None:
        return None, {}
    return (out if out.ndim == 2 else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)), params


def run(cap_id: str) -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = doc.to_dict()
    if not (v.get('isExperiment') or v.get('fusionVersion')):
        print(f'{cap_id} is not a fusion_v1 capture -- refusing')
        return None

    print(f'\n=== PHASE 7 mask-aware normalisation -- {cap_id[:12]} ===')
    srcs = collect_sources(v)
    if 'front_v1' not in srcs:
        print('  no anchor'); return None
    a_img, a_g = srcs['front_v1']
    a_gray = p6._gray(a_img)
    shape = a_gray.shape[:2]

    zg = {'center': (a_gray, a_g)}
    for n, (i, g) in srcs.items():
        if n != 'front_v1':
            zg[n] = (p6._gray(i), g)
    box = p6._common_crop(zg, shape)
    if box is None:
        print('  crop derivation failed'); return None
    x0, x1, y0, y1 = box
    a_crop = a_gray[y0:y1, x0:x1]
    adj = p6._adjust_guide(a_g, box, shape)

    refs: Dict[str, str] = {}
    for rn in ('macro_round32', 'main_round32', 'macro_round35', 'main_round35'):
        p = os.path.join(CACHE, f'ref_{rn}.xyt')
        if os.path.exists(p):
            refs[rn] = p

    global _CLAHE_TILE_PX
    arms = [('full_frame', a_gray, a_g, False, None),
            ('full_frame+maskNorm', a_gray, a_g, True, None),
            ('crop', a_crop, adj, False, None),
            ('crop+maskNorm', a_crop, adj, True, None)]
    # Adaptive-tile sweep on BOTH paths. If CLAHE tiling is the mechanism,
    # a shared physical tile size should pull the two paths together.
    for tp in (300, 400, 533):
        arms.append((f'full_frame+tile{tp}', a_gray, a_g, False, tp))
        arms.append((f'crop+tile{tp}', a_crop, adj, False, tp))

    print(f'\n  {"arm":24}{"minutiae":>9}{"ink px":>9}'
          + ''.join(f'{r.replace("_round", ""):>13}' for r in refs))
    print('  ' + '-' * (42 + 13 * len(refs)))
    out: Dict[str, dict] = {}
    for lab, img, g, masked, tile in arms:
        _CLAHE_TILE_PX = tile
        pr, params = _render(img, g, masked)
        _CLAHE_TILE_PX = None
        if pr is None:
            print(f'  {lab:24} render failed'); continue
        cv2.imwrite(os.path.join(CACHE, f'{cap_id[:12]}_p7_{lab}.png'), pr)
        mm = mio.extract_minutiae(pr, source=lab)
        xp = os.path.join(CACHE, f'{cap_id[:12]}_p7_{lab}.xyt')
        mio.write_xyt(mm, xp)
        sc = {rn: _best_score(xp, rp) for rn, rp in refs.items()}
        ink = int((pr < 128).sum())
        print(f'  {lab:24}{len(mm):>9}{ink:>9}'
              + ''.join(f'{str(sc[r]):>13}' for r in refs))
        out[lab] = {'minutiae': len(mm), 'ink_px': ink, 'scores': sc,
                    'wl': (params or {}).get('afisWavelengthPx'),
                    'freq_scale': (params or {}).get('afisFreqScale')}

    res = {'capture': cap_id, 'arms': out}
    p = os.path.join(HERE, 'results', f'phase7_masknorm_{cap_id[:8]}.json')
    with open(p, 'w') as fh:
        json.dump(res, fh, indent=2)
    print(f'\nwrote {p}')
    return res


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 phase7_mask_aware_normalize.py <captureId>')
        sys.exit(1)
    run(sys.argv[1])
