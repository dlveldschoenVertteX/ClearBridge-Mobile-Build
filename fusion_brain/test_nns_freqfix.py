"""The NNS enhancer's ridge-frequency estimator returns its clamp, always.

Found while testing the guide-crop lever: `_estimate_ridge_frequency` came
back at exactly 50.0px -- the ceiling of its own `np.clip(freq, 1/50, 1/5)`
-- on every capture and in every arm, including a pad-only crop.

Mechanism, measured on a real frame: the radial spectrum of the 128x128 ROI
falls monotonically from bin 1 (97530, 63237, 28752, 19763, ...). That is
the image's 1/f illumination falloff, not ridge structure, and `np.argmax`
selects bin 1 every time -> period 128px -> clamped to 50px. There is no
detrending or band restriction before the FFT. Removing the low-frequency
trend only moves the peak to bin 2. So the estimator never estimates a
ridge frequency, and `_multiscale_gabor` -- whose docstring says its
wavelengths are "centred on the detected ridge period" -- is centred on the
clamp on every single capture.

The scale of the error: native ridge period across 65 real production
captures is a median of 28px in the full frame. Inside NNS's fixed 512x512
input, where the pad occupies 3-5% of the area, that is roughly 4-5px. The
bank is tuned to 50px. More than an order of magnitude off.

This is also why the guide-crop arm alone could not show a benefit: cropping
raises the pad's share of the frame, but the bank stays pinned at 50px
either way. The two changes have to be tested together.

Arms:
  scene       centre-square, estimator as-is            (production today)
  guide       guide-region crop, estimator as-is
  sceneFix    centre-square, estimator replaced
  guideFix    guide-region crop, estimator replaced

The replacement reuses `afis_print._ridge_wavelength_robust` -- the
estimator the AFIS path already relies on and that this project has already
validated -- measured on the input and converted to the 512x512 working
scale, rather than inventing a second one.

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from typing import List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                        # noqa: E402
import numpy as np                                # noqa: E402

import afis_print as ap                           # noqa: E402
import enhancement_pipeline as ep                 # noqa: E402
import sfm_pipeline as sfm                        # noqa: E402
from phase0c_real_fusion_capture import _bucket   # noqa: E402
from frame_selection_test import (                # noqa: E402
    _center_square, nfiq2, population, RESULTS,
)
from test_nns_guidecrop import guide_bbox, OUT     # noqa: E402

_ORIG_FREQ = ep._estimate_ridge_frequency
_forced: dict = {}


def _freq_patched(image: np.ndarray) -> float:
    """Return the pre-computed real period for this arm, in 512-space."""
    p = _forced.get('period_px')
    if not p:
        return _ORIG_FREQ(image)
    return float(np.clip(1.0 / p, 1.0 / 50.0, 1.0 / 5.0))


def real_period_px(gray: np.ndarray) -> Optional[float]:
    """AFIS's own validated estimator, on the image as given."""
    try:
        norm = ap._normalize(gray.astype(np.float32))
        orient = ap._orientation_field(norm)
        wl = ap._ridge_wavelength(norm, orient)
        return float(wl) if wl and np.isfinite(wl) and wl > 0 else None
    except Exception:
        return None


def run_capture(doc: dict, tmp: str) -> Optional[dict]:
    cid, guide = doc['_id'], doc['guideRegion']
    amb = sorted([f for f in doc['frames'] if not f.get('flashOn')],
                 key=lambda f: -(f.get('laplacianScore') or 0))
    if not amb:
        return None
    b = _bucket.blob(amb[0]['path'])
    if not b.exists():
        return None
    arr = cv2.imdecode(np.frombuffer(b.download_as_bytes(), np.uint8),
                       cv2.IMREAD_COLOR)
    if arr is None:
        return None

    sq = _center_square(arr)
    scene = cv2.cvtColor(sfm._prepare(sq), cv2.COLOR_BGR2GRAY)
    gray_sq = cv2.cvtColor(sq, cv2.COLOR_BGR2GRAY)
    bb = guide_bbox(sq.shape, guide)
    if bb is None:
        return None
    x0, y0, x1, y1 = bb
    crop = gray_sq[y0:y1, x0:x1]

    # The pad's real ridge period, measured once on the pad itself.
    pad_period = real_period_px(crop)
    row = {'captureId': cid, 'padPeriodPx': round(pad_period, 1) if pad_period else None}

    for arm, img, fix in (('scene', scene, False), ('guide', crop, False),
                          ('sceneFix', scene, True), ('guideFix', crop, True)):
        _forced.clear()
        if fix:
            if pad_period is None:
                row[f'nfiq2_{arm}'] = None
                continue
            # Convert the pad's period into the 512x512 working scale this
            # arm's input will be resized to.
            _forced['period_px'] = pad_period * (512.0 / max(img.shape[:2]))
        ep._estimate_ridge_frequency = _freq_patched if fix else _ORIG_FREQ
        try:
            enh, _ = ep.enhance(img, sfm_coverage=1.0)
            row[f'nfiq2_{arm}'] = nfiq2(enh, tmp)
            row[f'periodUsed_{arm}'] = round(
                _forced.get('period_px', 50.0), 1) if fix else 50.0
            cv2.imwrite(os.path.join(OUT, f'{cid[:8]}_{arm}.png'), enh)
        except Exception as e:
            print(f'    {arm} failed: {e}')
            row[f'nfiq2_{arm}'] = None
        finally:
            ep._estimate_ridge_frequency = _ORIG_FREQ
            _forced.clear()

    print(f'  {cid[:8]}  padPeriod={row["padPeriodPx"]}px   '
          + '  '.join(f'{a}={row.get(f"nfiq2_{a}")}'
                      for a in ('scene', 'guide', 'sceneFix', 'guideFix')))
    return row


def main(limit: int = 10):
    docs = population(limit)
    print(f'{len(docs)} real production front_only_v1 captures\n')
    out = os.path.join(RESULTS, 'nns_freqfix_test.json')
    rows: List[dict] = []
    for doc in docs:
        tmp = tempfile.mkdtemp()
        try:
            r = run_capture(doc, tmp)
            if r:
                rows.append(r)
                with open(out, 'w') as f:
                    json.dump(rows, f, indent=2)
        except Exception as e:
            print(f'  {doc["_id"][:8]} failed: {e}')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    print('\n=== RESULT ===')
    base = [r['nfiq2_scene'] for r in rows if r.get('nfiq2_scene') is not None]
    for arm in ('scene', 'guide', 'sceneFix', 'guideFix'):
        pairs = [(r['nfiq2_scene'], r[f'nfiq2_{arm}']) for r in rows
                 if r.get('nfiq2_scene') is not None
                 and r.get(f'nfiq2_{arm}') is not None]
        if not pairs:
            continue
        d = [b - a for a, b in pairs]
        print(f'  {arm:<9} mean {np.mean([p[1] for p in pairs]):6.2f}  '
              f'vs scene {np.mean(d):+6.2f}  '
              f'({sum(1 for x in d if x > 0)} better / '
              f'{sum(1 for x in d if x < 0)} worse, n={len(pairs)})')
    print(f'\nwrote {out}')


if __name__ == '__main__':
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 10)
