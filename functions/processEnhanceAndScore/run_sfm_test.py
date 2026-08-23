"""
SFM Before/After Test Runner
==============================
Downloads frames via firebase-admin Storage SDK, runs the cylindrical SFM pipeline
twice per capture (broken zero-orbit vs fixed nominal angles), and compares NFIQ.

Usage:
    cd functions/processEnhanceAndScore
    venv\\Scripts\\activate
    python run_sfm_test.py [--max 8] [--out ./sfm_test_out]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

import cv2
import numpy as np

_HERE = Path(__file__).parent.resolve()
sys.path.insert(0, str(_HERE))

_ANGLE_NAMES   = ['front', 'right', 'top', 'left']
_UID           = 'S7B5LAvXiJdKjHTbpAFMoINv4Um2'
_PROJECT       = 'clearbridge-dc699'
_BUCKET_NAME   = 'clearbridge-dc699.firebasestorage.app'

# Broken: zero orbit → scale clamped to 0.2 → right=18°, left=342°
_BROKEN_ANGLES = [0.0, 18.0, 180.0, 342.0]
_FIXED_ANGLES  = [0.0, 90.0, 180.0, 270.0]


def _parse():
    p = argparse.ArgumentParser()
    p.add_argument('--max', type=int, default=8)
    p.add_argument('--out', type=str, default=str(_HERE / 'sfm_test_out'))
    p.add_argument('--cache-only', action='store_true',
                   help='Only run on captures already cached to disk — no network calls')
    return p.parse_args()


# ── Firebase init ─────────────────────────────────────────────────────────────

_bkt = None

def _bucket():
    global _bkt
    if _bkt is not None:
        return _bkt
    import firebase_admin
    from firebase_admin import credentials, storage
    if not firebase_admin._apps:
        key = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
        if key:
            cred = credentials.Certificate(key)
            firebase_admin.initialize_app(cred, {'projectId': _PROJECT, 'storageBucket': _BUCKET_NAME})
        else:
            firebase_admin.initialize_app(options={'projectId': _PROJECT, 'storageBucket': _BUCKET_NAME})
    _bkt = storage.bucket()
    return _bkt


# ── Storage helpers ───────────────────────────────────────────────────────────

def list_capture_ids(uid: str) -> list[str]:
    """Return capture IDs that have at least one blob under captures/{uid}/."""
    bkt = _bucket()
    blobs = list(bkt.list_blobs(prefix=f'captures/{uid}/'))
    seen: set[str] = set()
    for b in blobs:
        parts = b.name.split('/')
        if len(parts) >= 3 and parts[2]:
            seen.add(parts[2])
    return sorted(seen)


def _angle_from_name(fname: str) -> Optional[str]:
    parts = fname.replace('.jpg', '').split('_')
    if len(parts) >= 3:
        a = parts[2]
        return a if a in _ANGLE_NAMES else None
    return None


def download_best_frames(uid: str, cap_id: str, cache_dir: Path) -> Optional[dict[str, np.ndarray]]:
    cdir = cache_dir / cap_id

    # Disk cache — re-use frames from previous runs
    cached: dict[str, np.ndarray] = {}
    if cdir.exists():
        for angle in _ANGLE_NAMES:
            p = cdir / f'{angle}.png'
            if p.exists():
                img = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
                if img is not None:
                    cached[angle] = img
        if cached:
            print(f'  (cache) {cap_id[:8]}  angles={list(cached.keys())}')
            return cached

    # Download from Storage via firebase-admin SDK (no gsutil dependency)
    bkt   = _bucket()
    blobs = list(bkt.list_blobs(prefix=f'captures/{uid}/{cap_id}/'))
    if not blobs:
        print(f'  SKIP {cap_id[:8]}  no blobs in Storage')
        return None

    by_angle: dict[str, list] = {a: [] for a in _ANGLE_NAMES}
    for b in blobs:
        fname = b.name.split('/')[-1]
        if not fname.endswith('.jpg'):
            continue
        a = _angle_from_name(fname)
        if a:
            by_angle[a].append(b)

    frames: dict[str, np.ndarray] = {}
    for angle, blob_list in by_angle.items():
        if not blob_list:
            continue
        best_img, best_lap = None, -1.0
        for blob in blob_list:
            try:
                data = blob.download_as_bytes(timeout=30)
                arr  = np.frombuffer(data, np.uint8)
                img  = cv2.imdecode(arr, cv2.IMREAD_GRAYSCALE)
                if img is None:
                    continue
                lap = float(cv2.Laplacian(img, cv2.CV_64F).var())
                if lap > best_lap:
                    best_lap, best_img = lap, img
            except Exception as e:
                print(f'    warn: {blob.name} — {e}')
        if best_img is not None:
            frames[angle] = best_img

    if not frames:
        print(f'  SKIP {cap_id[:8]}  could not decode any frames')
        return None

    cdir.mkdir(parents=True, exist_ok=True)
    for angle, img in frames.items():
        cv2.imwrite(str(cdir / f'{angle}.png'), img)

    print(f'  (dl)    {cap_id[:8]}  angles={list(frames.keys())}')
    return frames


# ── NFIQ scoring ──────────────────────────────────────────────────────────────

_nfiq_sess = None

def _load_nfiq():
    global _nfiq_sess
    if _nfiq_sess:
        return _nfiq_sess
    import onnxruntime as ort
    model = _HERE / 'nfiq_resnet18.onnx'
    if not model.exists():
        raise FileNotFoundError(f'NFIQ model not found: {model}')
    _nfiq_sess = ort.InferenceSession(str(model), providers=['CPUExecutionProvider'])
    print(f'NFIQ model loaded.')
    return _nfiq_sess


def score_nfiq(image: np.ndarray) -> float:
    from PIL import Image as PILImage
    sess = _load_nfiq()
    inp, out_name = sess.get_inputs()[0].name, sess.get_outputs()[0].name

    def _once(img):
        pil    = PILImage.fromarray(img).convert('L').resize((500, 500), PILImage.LANCZOS)
        arr    = np.array(pil, np.float32) / 255.0
        tensor = arr[np.newaxis, np.newaxis]
        return float(np.clip(sess.run([out_name], {inp: tensor})[0].flatten()[0], 0.0, 1.0))

    s1 = _once(image)
    lo, hi = int(np.percentile(image, 1)), int(np.percentile(image, 99))
    v2 = np.clip((image.astype(np.float32)-lo)/max(hi-lo,1)*255, 0, 255).astype(np.uint8) if hi>lo else image
    s2 = _once(v2)
    v3 = cv2.createCLAHE(clipLimit=1.5, tileGridSize=(8,8)).apply(image)
    s3 = _once(v3)
    return max(s1, s2, s3) * 100.0


# ── SFM + enhance + score ─────────────────────────────────────────────────────

def run_sfm_pass(frames: dict[str, np.ndarray], angles_deg: list[float],
                 label: str, out_dir: Path, cap_id: str):
    import sfm_pipeline
    import enhancement_pipeline

    imgs, degs = [], []
    for i, a in enumerate(_ANGLE_NAMES):
        if a in frames:
            imgs.append(frames[a])
            degs.append(angles_deg[i])

    try:
        unwrapped, coverage, _, diag = sfm_pipeline.reconstruct_and_unwrap(imgs, angles_deg=degs)
        status = 'success'
    except sfm_pipeline.CaptureQualityError as e:
        front     = frames.get('front', imgs[0])
        unwrapped = cv2.resize(front.copy(), (512, 512))
        coverage, status = 0.0, 'fallback_front_only'
    except Exception as e:
        print(f'    [{label}] SFM error: {e}')
        return 0.0, 0.0, f'error', None

    try:
        enhanced, _ = enhancement_pipeline.enhance(unwrapped, sfm_coverage=coverage)
    except Exception as e:
        print(f'    [{label}] enhance error: {e}')
        return 0.0, coverage, 'enhance_error', None

    nfiq = score_nfiq(enhanced)

    tag = 'fixed' if 'FIXED' in label else 'broken'
    out_dir.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out_dir / f'{cap_id[:8]}_{tag}_unwrapped.png'), unwrapped)
    cv2.imwrite(str(out_dir / f'{cap_id[:8]}_{tag}_enhanced.png'),  enhanced)

    return nfiq, coverage, status, enhanced


# ── Firestore metadata ────────────────────────────────────────────────────────

def get_meta(cap_ids: list[str]) -> dict[str, dict]:
    import firebase_admin
    from firebase_admin import firestore as fs
    # firebase_admin already initialised by _bucket()
    db = fs.client()
    out: dict[str, dict] = {}
    for cid in cap_ids:
        try:
            doc = db.collection('captures').document(cid).get()
            if doc.exists:
                d = doc.to_dict()
                out[cid] = {
                    'pipeline': d.get('pipelineVersion', '?'),
                    'nfiq':     d.get('nfiqScore', 0.0),
                    'sfm':      d.get('sfmStatus', '?'),
                }
        except Exception:
            pass
    return out


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    args  = _parse()
    out   = Path(args.out)
    cache = out / 'frames'

    print(f'\n{"="*64}')
    print(f'SFM Before/After Test — max {args.max} captures')
    print(f'Broken angles : {_BROKEN_ANGLES}')
    print(f'Fixed  angles : {_FIXED_ANGLES}')
    print(f'{"="*64}\n')

    if args.cache_only:
        # Only use captures already on disk — no Firebase calls
        print('Cache-only mode — scanning disk...')
        all_ids = [d.name for d in cache.iterdir() if d.is_dir()] if cache.exists() else []
        print(f'  {len(all_ids)} cached captures found\n')
    else:
        print('Initialising Firebase + listing Storage...')
        all_ids = list_capture_ids(_UID)
        print(f'  {len(all_ids)} capture folders found\n')

    # Load frames; keep only captures with all 4 angles
    tested: list[str] = []
    for cid in all_ids:
        if len(tested) >= args.max:
            break
        if args.cache_only:
            # Load directly from disk
            frames: dict[str, np.ndarray] = {}
            for angle in _ANGLE_NAMES:
                p = cache / cid / f'{angle}.png'
                if p.exists():
                    img = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
                    if img is not None:
                        frames[angle] = img
            if not frames:
                continue
        else:
            frames = download_best_frames(_UID, cid, cache)
            if frames is None:
                continue
        missing = [a for a in _ANGLE_NAMES if a not in frames]
        if missing:
            print(f'  SKIP {cid[:8]}  missing angles: {missing}')
            continue
        print(f'  (ready) {cid[:8]}  angles={list(frames.keys())}')
        tested.append(cid)

    print(f'\nReady: {len(tested)} captures with all 4 angles\n')
    if not tested:
        print('Nothing to test.')
        out.mkdir(parents=True, exist_ok=True)
        (out / 'results.json').write_text('[]')
        return

    meta = get_meta(tested) if not args.cache_only else {}

    results = []
    for cid in tested:
        frames = {}
        for angle in _ANGLE_NAMES:
            p = cache / cid / f'{angle}.png'
            if p.exists():
                img = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
                if img is not None:
                    frames[angle] = img
        m = meta.get(cid, {})
        print(f'[{cid[:8]}]  pipeline={m.get("pipeline","?")}  stored_nfiq={m.get("nfiq",0):.1f}')

        nfiq_b, cov_b, st_b, _ = run_sfm_pass(frames, _BROKEN_ANGLES, 'BROKEN', out, cid)
        print(f'  BROKEN  nfiq={nfiq_b:.1f}  cov={cov_b:.2f}  {st_b}')

        nfiq_f, cov_f, st_f, _ = run_sfm_pass(frames, _FIXED_ANGLES, 'FIXED', out, cid)
        print(f'  FIXED   nfiq={nfiq_f:.1f}  cov={cov_f:.2f}  {st_f}')

        delta = nfiq_f - nfiq_b
        sym   = 'UP' if delta > 1 else ('DOWN' if delta < -1 else '=')
        print(f'  DELTA   {delta:+.1f}  {sym}\n')

        results.append({
            'id': cid, 'pipeline': m.get('pipeline','?'), 'stored_nfiq': m.get('nfiq', 0),
            'broken_nfiq': nfiq_b, 'broken_cov': cov_b, 'broken_status': st_b,
            'fixed_nfiq':  nfiq_f, 'fixed_cov':  cov_f, 'fixed_status':  st_f,
            'delta': delta,
        })

    # Summary
    print(f'\n{"="*76}')
    print(f'{"ID":10}  {"Pipeline":15}  {"Stored":7}  {"Broken":7}  {"Fixed":7}  {"Delta":7}  Cov')
    print(f'{"-"*76}')
    for r in results:
        print(f'{r["id"][:8]:10}  {r["pipeline"][:15]:15}  '
              f'{r["stored_nfiq"]:6.1f}  {r["broken_nfiq"]:6.1f}  '
              f'{r["fixed_nfiq"]:6.1f}  {r["delta"]:+6.1f}  {r["fixed_cov"]:.2f}')
    if results:
        avg_b = sum(r['broken_nfiq'] for r in results) / len(results)
        avg_f = sum(r['fixed_nfiq']  for r in results) / len(results)
        avg_c = sum(r['fixed_cov']   for r in results) / len(results)
        print(f'{"-"*76}')
        print(f'{"AVG":10}  {"":15}  {"":7}  {avg_b:6.1f}  {avg_f:6.1f}  {avg_f-avg_b:+6.1f}  {avg_c:.2f}')
        print(f'\nSFM fix: {avg_f-avg_b:+.1f} NFIQ pts avg  |  coverage {avg_c*100:.0f}%  |  n={len(results)}')

    out.mkdir(parents=True, exist_ok=True)
    with open(out / 'results.json', 'w') as f:
        json.dump(results, f, indent=2)
    print(f'\nSaved -> {out}/')


if __name__ == '__main__':
    main()
