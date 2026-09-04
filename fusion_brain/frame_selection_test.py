"""Does selecting the burst's primary frame by RIDGE CONTENT beat production's
"sharpest ambient by client laplacianScore"?

WHY THIS IS NOT THE ALREADY-REJECTED EXPERIMENT. `main.py`'s own comment
records a real test from 2026-07-24 that was refuted and says not to
re-attempt it: comparing the sharpest ambient against the sharpest flash
*by client laplacianScore* and taking whichever reads higher. That test's
own stated failure reason is the metric -- "the client laplacianScore is a
known-unreliable whole-preview-frame proxy ... reading 'sharper' for flash
doesn't mean it's genuinely better raw material."

This tests a DIFFERENT metric, on the exact failure the CTO reported on
capture ed242f1c (2026-08-27): the ambient frames were visibly blurry --
no ridges at all -- yet scored HIGHEST on Laplacian variance (1003), because
Laplacian variance rewards broadband sensor noise, which a dark ambient
frame at high ISO has in abundance. Measuring band-limited, coherence-gated
ridge energy inside the guide instead inverts that ranking.

Selection policies compared, one variable only (the primary frame handed to
generate() as frames[0]); ambient_burst/flash_burst -- and therefore every
masking decision -- are held identical:
  prod   sharpest ambient by client laplacianScore, else sharpest flash
         (byte-for-byte what _download_front_only_frames does today)
  ridge  highest median ridge-band score inside the guide across ALL
         frames, ambient or flash, illumination-agnostic

Gate: the real NIST NFIQ2 binary, on the real production front_only_v1
population -- deliberately NOT the fusion_v1 population, which is what made
an earlier backend change this session look safe when it would have broken
57% of production captures.

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                       # noqa: E402
import numpy as np                               # noqa: E402

import afis_print as ap                          # noqa: E402
from phase0c_real_fusion_capture import _bucket, _db   # noqa: E402

RESULTS = os.path.join(HERE, 'results')
NFIQ2_BIN = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
NFIQ2_MODEL = ('/tmp/NFIQ2/build/install_staging/nfiq2/share/'
               'nist_plain_tir-ink.txt')


def _center_square(arr: np.ndarray) -> np.ndarray:
    """Byte-for-byte main.py's own `_load` crop."""
    h, w = arr.shape[:2]
    side = min(h, w)
    return arr[(h - side) // 2:(h - side) // 2 + side,
               (w - side) // 2:(w - side) // 2 + side]


def _ridge_score_map(gray: np.ndarray) -> np.ndarray:
    """`_pad_within_finger`'s own field: ridge-band energy x orientation
    coherence. Reused from production rather than re-derived."""
    g = gray.astype(np.float32)
    band = (cv2.GaussianBlur(g, (0, 0), ap._PAD_RIDGE_WL_LO / 3.0)
            - cv2.GaussianBlur(g, (0, 0), ap._PAD_RIDGE_WL_HI / 3.0))
    energy = cv2.GaussianBlur(np.abs(band), (0, 0), ap._PAD_RIDGE_WL_HI)
    return energy * ap._block_coherence(gray)


def frame_metrics(arr: np.ndarray, guide: dict) -> Dict[str, float]:
    """Every candidate selection signal, measured once per frame.

    `ridge` is raw band energy x coherence. It is NOT illumination-
    invariant: a torch-lit frame has higher absolute contrast everywhere,
    so it scores higher on this whether or not its ridges are better
    resolved -- measured directly on the first two captures, where the
    flash frames swept the top four places on both.

    `ridge_frac` divides that by the frame's own broadband high-pass
    energy, so a global contrast scale cancels. What survives is the SHARE
    of detail sitting at ridge scale rather than at noise scale -- which is
    the actual question behind the CTO's report that the ambient frames
    were "extremely blurry" while scoring highest on Laplacian variance.
    """
    gray = arr if arr.ndim == 2 else cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY)
    gm = ap._superellipse_mask(gray.shape[:2], guide)
    if gm is None or not (gm > 0).any():
        return {}
    inside = gm > 0
    g = gray.astype(np.float32)
    band = (cv2.GaussianBlur(g, (0, 0), ap._PAD_RIDGE_WL_LO / 3.0)
            - cv2.GaussianBlur(g, (0, 0), ap._PAD_RIDGE_WL_HI / 3.0))
    band_e = cv2.GaussianBlur(np.abs(band), (0, 0), ap._PAD_RIDGE_WL_HI)
    broad = np.abs(g - cv2.GaussianBlur(g, (0, 0), ap._PAD_RIDGE_WL_HI))
    broad_e = cv2.GaussianBlur(broad, (0, 0), ap._PAD_RIDGE_WL_HI)
    coh = ap._block_coherence(gray)
    lap = cv2.Laplacian(gray, cv2.CV_64F)
    return {
        'ridge': float(np.median((band_e * coh)[inside])),
        'ridge_frac': float(np.median((band_e / np.maximum(broad_e, 1e-6))[inside])),
        'ridge_frac_coh': float(np.median(
            (coh * band_e / np.maximum(broad_e, 1e-6))[inside])),
        'coherence': float(np.median(coh[inside])),
        'band_energy': float(np.median(band_e[inside])),
        'guide_lap': float(np.var(lap[inside])),
        'luma': float(np.mean(gray[inside])),
        'clip_frac': float((gray[inside] >= 250).mean()),
    }


def nfiq2(img: np.ndarray, tmp: str) -> Optional[float]:
    """Same calibration the rest of this project uses: resize 500x500
    LANCZOS, then the real binary."""
    p = os.path.join(tmp, 'n.png')
    cv2.imwrite(p, cv2.resize(img, (500, 500), interpolation=cv2.INTER_LANCZOS4))
    try:
        r = subprocess.run([NFIQ2_BIN, '-m', NFIQ2_MODEL, '-i', p, '-F'],
                           capture_output=True, text=True, timeout=120)
    except Exception:
        return None
    for line in (r.stdout or '').splitlines():
        tok = line.strip().split(',')[-1].strip()
        try:
            v = float(tok)
        except ValueError:
            continue
        if 0.0 <= v <= 100.0:
            return v
    return None


def population(limit: int) -> List[dict]:
    """Real production front_only_v1 captures only. fusion_v1 / experiment
    captures are excluded explicitly -- mixing them is exactly what made an
    earlier verification this session measure the wrong population."""
    out = []
    for d in (_db.collection('captures')
              .where('captureMode', '==', 'front_only_v1')
              .limit(limit * 4).stream()):
        v = d.to_dict() or {}
        if v.get('isExperiment') or v.get('fusionVersion'):
            continue
        if not v.get('guideRegion') or not v.get('frames'):
            continue
        amb = [f for f in v['frames'] if not f.get('flashOn')]
        fl = [f for f in v['frames'] if f.get('flashOn')]
        if len(amb) + len(fl) < 4 or not amb or not fl:
            continue
        v['_id'] = d.id
        out.append(v)
        if len(out) >= limit:
            break
    return out


def run_capture(doc: dict, tmp: str) -> Optional[dict]:
    """Render EVERY burst frame as the primary and score each with real
    NFIQ2, so the best-possible choice is known rather than assumed. That
    turns policy comparison into an offline question over recorded numbers
    -- any candidate rule can be evaluated later without re-rendering, and
    the gap to the oracle says whether better selection is worth anything
    at all on this population.
    """
    cid = doc['_id']
    guide = doc['guideRegion']

    loaded = []
    for e in doc['frames']:
        blob = _bucket.blob(e['path'])
        if not blob.exists():
            continue
        raw = np.frombuffer(blob.download_as_bytes(), np.uint8)
        arr = cv2.imdecode(raw, cv2.IMREAD_COLOR)
        if arr is None:
            continue
        loaded.append({
            # basename only: this repo is PUBLIC and the full Storage path
            # carries the capturing user's uid.
            'path': os.path.basename(e['path']),
            'flash': bool(e.get('flashOn')),
            'client_lap': float(e.get('laplacianScore') or 0.0),
            'img': _center_square(arr),
        })
    amb = [f for f in loaded if not f['flash']]
    fl = [f for f in loaded if f['flash']]
    if not amb or not fl:
        return None

    for f in loaded:
        f.update(frame_metrics(f['img'], guide))

    amb_s = sorted(amb, key=lambda f: f['client_lap'], reverse=True)
    fl_s = sorted(fl, key=lambda f: f['client_lap'], reverse=True)

    # Masking inputs are held identical for every arm on purpose: the only
    # variable is frames[0].
    amb_burst = [f['img'] for f in amb_s]
    fl_burst = [f['img'] for f in fl_s]

    for f in loaded:
        try:
            out, _ = ap.generate(
                [f['img']], [0.0], [None], guide_region=guide,
                freq_normalize=True, stack_cache={},
                ambient_frames=[amb_s[0]['img']],
                flash_frames=[fl_s[0]['img']],
                ambient_burst=amb_burst, flash_burst=fl_burst)
        except Exception as e:
            print(f'    render failed {os.path.basename(f["path"])}: {e}')
            out = None
        f['nfiq2'] = (None if out is None else
                      nfiq2(out if out.ndim == 2
                            else cv2.cvtColor(out, cv2.COLOR_BGR2GRAY), tmp))

    prod = amb_s[0]
    scored = [f for f in loaded if f['nfiq2'] is not None]
    best = max(scored, key=lambda f: f['nfiq2']) if scored else None
    print(f'  {cid[:8]}  prod={prod["nfiq2"]}  '
          f'best={best["nfiq2"] if best else None} '
          f'({"FL" if best and best["flash"] else "AM"})  '
          f'headroom={None if not best or prod["nfiq2"] is None else best["nfiq2"] - prod["nfiq2"]}')

    return {
        'captureId': cid,
        'prodPath': prod['path'],
        'frames': [{k: (round(v, 4) if isinstance(v, float) else v)
                    for k, v in f.items() if k != 'img'} for f in loaded],
    }


def policy_pick(frames: List[dict], key: str, flash_only: bool = False,
                ambient_only: bool = False) -> Optional[dict]:
    pool = [f for f in frames if f.get('nfiq2') is not None]
    if flash_only:
        pool = [f for f in pool if f['flash']] or pool
    if ambient_only:
        pool = [f for f in pool if not f['flash']] or pool
    return max(pool, key=lambda f: f.get(key, 0.0)) if pool else None


POLICIES = [
    ('prod (sharpest ambient, client lap)', 'client_lap', False, True),
    ('sharpest anything, client lap', 'client_lap', False, False),
    ('guide-region Laplacian', 'guide_lap', False, False),
    ('ridge band energy', 'ridge', False, False),
    ('ridge fraction', 'ridge_frac', False, False),
    ('ridge fraction x coherence', 'ridge_frac_coh', False, False),
    ('coherence', 'coherence', False, False),
    ('ridge fraction, ambient only', 'ridge_frac', False, True),
    ('always sharpest flash (client lap)', 'client_lap', True, False),
    ('flash only, guide Laplacian', 'guide_lap', True, False),
    ('flash only, ridge band energy', 'ridge', True, False),
    ('flash only, ridge fraction', 'ridge_frac', True, False),
    ('flash only, least clipped', 'neg_clip', True, False),
]


def summarise(rows: List[dict]) -> None:
    for r in rows:
        for f in r['frames']:
            # Highlight clipping destroys ridges outright (saturated pixels
            # carry no gradient), so "least clipped" is a real candidate
            # tie-breaker among torch-lit frames, which is where clipping
            # actually happens.
            f['neg_clip'] = -f.get('clip_frac', 0.0)
    usable = [r for r in rows
              if any(f.get('nfiq2') is not None for f in r['frames'])]
    print(f'\n=== {len(usable)} captures, every burst frame rendered+scored ===')
    oracle = [max(f['nfiq2'] for f in r['frames'] if f['nfiq2'] is not None)
              for r in usable]
    print(f'{"policy":<40} {"mean":>7} {"vs prod":>8} {"= oracle":>9}')
    base = None
    for label, key, fo, ao in POLICIES:
        picks, hits = [], 0
        for r, orc in zip(usable, oracle):
            p = policy_pick(r['frames'], key, fo, ao)
            if p is None:
                continue
            picks.append(p['nfiq2'])
            hits += int(p['nfiq2'] == orc)
        m = float(np.mean(picks)) if picks else float('nan')
        if base is None:
            base = m
        print(f'{label:<40} {m:7.2f} {m - base:+8.2f} {hits:4d}/{len(picks):<4d}')
    print(f'{"ORACLE (best frame, unknowable live)":<40} '
          f'{float(np.mean(oracle)):7.2f} {float(np.mean(oracle)) - base:+8.2f}')


def main(limit: int = 16):
    docs = population(limit)
    print(f'{len(docs)} real production front_only_v1 captures\n')
    out = os.path.join(RESULTS, 'frame_selection_test.json')
    rows = []
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
    summarise(rows)
    print(f'wrote {out}')


if __name__ == '__main__':
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 16)
