"""
MAC3D Enhancement Pipeline Optimizer
=====================================
Downloads the N most recent scored captures from Firebase Storage,
caches the SfM-unwrapped intermediates locally, then grid-searches
enhancement parameters using the local NFIQ ONNX model.

Usage (from the processEnhanceAndScore directory with venv active):
    python optimize_pipeline.py [--captures 15] [--cache-dir ./opt_cache]

Requirements: ADC credentials configured (firebase_admin uses default creds).
"""

from __future__ import annotations

import argparse
import json
import os
import pickle
import statistics
import sys
import time
from itertools import product
from pathlib import Path
from typing import Optional

import cv2
import numpy as np

# ── Bootstrap: add this directory to path so local imports work ───────────────
_HERE = Path(__file__).parent.resolve()
sys.path.insert(0, str(_HERE))


# ── Args ──────────────────────────────────────────────────────────────────────

def _parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--captures',    type=int, default=15, help='Number of recent captures to use')
    p.add_argument('--cache-dir',   type=str, default=str(_HERE / 'opt_cache'), help='Local cache folder')
    p.add_argument('--project',     type=str, default='clearbridge-dc699')
    p.add_argument('--bucket',      type=str, default='clearbridge-dc699.firebasestorage.app')
    p.add_argument('--credentials', type=str, default=None,
                   help='Path to a Firebase service account JSON key file. '
                        'Also reads from GOOGLE_APPLICATION_CREDENTIALS env var. '
                        'If neither is set, falls back to gcloud ADC.')
    return p.parse_args()


# ── Firebase init ─────────────────────────────────────────────────────────────

def _init_firebase(project: str, bucket_name: str, key_file: str | None = None):
    import firebase_admin
    from firebase_admin import credentials, firestore, storage

    if not firebase_admin._apps:
        # Resolve credentials: explicit arg > env var > ADC
        key_path = key_file or os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
        if key_path:
            cred = credentials.Certificate(key_path)
            firebase_admin.initialize_app(cred, options={
                'projectId':     project,
                'storageBucket': bucket_name,
            })
        else:
            # Falls back to gcloud ADC (requires `gcloud auth application-default login`)
            firebase_admin.initialize_app(options={
                'projectId':     project,
                'storageBucket': bucket_name,
            })
    db  = firestore.client()
    bkt = storage.bucket()
    return db, bkt


# ── Firestore: fetch recent captures ─────────────────────────────────────────

def fetch_recent_captures(db, n: int) -> list[dict]:
    """Return list of {captureId, basePath, thumbWidthFraction, nfiqScore}."""
    # createdAt is set on ALL docs at creation — safe single-field ordering.
    # basePath is NOT stored in Firestore; reconstruct from userId + captureId.
    docs = (
        db.collection('captures')
        .order_by('createdAt', direction='DESCENDING')
        .limit(n * 5)   # over-fetch: many docs will be pending/failed/enhancing
        .stream()
    )
    results = []
    for doc in docs:
        d = doc.to_dict()
        if d.get('status') != 'scored':
            continue
        user_id    = d.get('userId', '')
        capture_id = d.get('captureId') or doc.id
        if not user_id or not capture_id:
            continue
        base = f"captures/{user_id}/{capture_id}"
        results.append({
            'captureId':          doc.id,
            'basePath':           base,
            'thumbWidthFraction': d.get('thumbWidthFraction'),
            'nfiqScore':          d.get('nfiqScore', 0.0),
            'sfmCoverage':        d.get('sfmCoverage', 1.0),
            'pipelineVersion':    d.get('pipelineVersion', ''),
        })
        if len(results) >= n:
            break
    print(f"Fetched {len(results)} scored captures from Firestore")
    return results


# ── Frame download (self-contained — avoids importing main.py / firebase_functions) ──

_ANGLE_NAMES_OPT = ['front', 'right', 'top', 'left']
_KNOWN_DIMS_OPT  = [
    (1600, 1200), (1200, 1600),
    (1280,  960), ( 960, 1280),
    (1920, 1080), (1080, 1920),
    (1280,  720), ( 720, 1280),
    ( 640,  480), ( 480,  640),
    ( 960,  720), ( 720,  960),
]


def _decode_frame_opt(img_bytes: bytes) -> Optional[np.ndarray]:
    """Decode raw Y-plane or JPEG frame bytes. Returns BGR array."""
    arr = np.frombuffer(img_bytes, dtype=np.uint8)
    bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if bgr is not None:
        return bgr
    n = len(img_bytes)
    for w, h in _KNOWN_DIMS_OPT:
        if w * h == n:
            gray = arr.reshape(h, w)
            return cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    return None


def _download_best_frames_local(base_path: str, bkt):
    """Download frames from GCS, group by angle+type, fuse amb+fl, return (frames, angles)."""
    blobs = list(bkt.list_blobs(prefix=base_path))
    blob_map_amb = {a: [] for a in _ANGLE_NAMES_OPT}
    blob_map_fl  = {a: [] for a in _ANGLE_NAMES_OPT}
    for blob in blobs:
        fname  = blob.name.split('/')[-1]
        parts  = fname.replace('.jpg', '').replace('.jpeg', '').split('_')
        if len(parts) < 3 or parts[0] != 'frame':
            continue
        angle      = parts[2] if len(parts) >= 3 else ''
        frame_type = parts[3] if len(parts) >= 5 and parts[3] in ('amb', 'fl') else 'amb'
        if angle in blob_map_amb:
            (blob_map_fl if frame_type == 'fl' else blob_map_amb)[angle].append(blob)

    def _best(blob_list):
        best_img, best_lap = None, -1.0
        for blob in blob_list:
            try:
                data = blob.download_as_bytes(timeout=30)
                img  = _decode_frame_opt(data)
                if img is None:
                    continue
                gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
                lap  = float(cv2.Laplacian(gray, cv2.CV_64F).var())
                if lap > best_lap:
                    best_lap, best_img = lap, img
            except Exception:
                continue
        return best_img

    _ANGLE_DEG = {'front': 0.0, 'right': 90.0, 'top': 180.0, 'left': 270.0}
    frames, angles = [], []
    for angle in _ANGLE_NAMES_OPT:
        amb = _best(blob_map_amb[angle])
        fl  = _best(blob_map_fl[angle])
        if amb is not None and fl is not None:
            merge  = cv2.createMergeMertens()
            fused  = merge.process([amb, fl])
            frame  = np.clip(fused * 255, 0, 255).astype(np.uint8)
        elif amb is not None:
            frame = amb
        elif fl is not None:
            frame = fl
        else:
            if angle == 'top':
                continue  # top is optional
            continue
        frames.append(frame)
        angles.append(_ANGLE_DEG[angle])

    return frames, angles


# ── Download + SfM (with disk cache) ─────────────────────────────────────────

def _cache_path(cache_dir: Path, capture_id: str) -> Path:
    return cache_dir / f'{capture_id}_unwrapped.pkl'


def _get_unwrapped(capture: dict, bkt, cache_dir: Path) -> Optional[np.ndarray]:
    import sfm_pipeline
    from sfm_pipeline import CaptureQualityError

    cpath = _cache_path(cache_dir, capture['captureId'])
    if cpath.exists():
        with open(cpath, 'rb') as f:
            return pickle.load(f)

    print(f"  SfM: {capture['captureId']} (path={capture['basePath']})")
    try:
        frames, actual_angles = _download_best_frames_local(capture['basePath'], bkt)
    except Exception as e:
        print(f"  SKIP (download failed): {e}")
        return None

    if not frames:
        print(f"  SKIP (no frames found)")
        return None

    twf = capture.get('thumbWidthFraction')
    thumb_width_fraction = float(twf) if twf is not None else None
    gap_limit = 185.0 if len(frames) == 3 else None

    try:
        unwrapped, _, _, _ = sfm_pipeline.reconstruct_and_unwrap(
            frames, angles_deg=actual_angles,
            max_angle_gap_deg=gap_limit,
            thumb_width_fraction=thumb_width_fraction,
        )
    except CaptureQualityError as e:
        print(f"  SfM fallback (front-only): {e}")
        unwrapped = cv2.cvtColor(frames[0], cv2.COLOR_BGR2GRAY)
    except Exception as e:
        print(f"  SKIP (SfM error): {e}")
        return None

    with open(cpath, 'wb') as f:
        pickle.dump(unwrapped, f)
    return unwrapped


# ── NFIQ scoring (mirrors main.py _score_nfiq with TTA) ──────────────────────

_nfiq_session = None

def _load_nfiq(cache_dir: Path):
    global _nfiq_session
    if _nfiq_session is not None:
        return _nfiq_session
    import onnxruntime as ort
    # Prefer bundled model, fall back to /tmp/
    candidates = [
        _HERE / 'nfiq_resnet18.onnx',
        Path('/tmp/nfiq_resnet18.onnx'),
        cache_dir / 'nfiq_resnet18.onnx',
    ]
    for p in candidates:
        if p.exists():
            _nfiq_session = ort.InferenceSession(str(p), providers=['CPUExecutionProvider'])
            print(f"NFIQ model loaded from {p}")
            return _nfiq_session
    raise FileNotFoundError(
        f"nfiq_resnet18.onnx not found. Checked: {[str(c) for c in candidates]}\n"
        "Download it from Firebase Storage: models/nfiq_resnet18.onnx"
    )


def score_nfiq(image: np.ndarray, session, target=(500, 500)) -> float:
    from PIL import Image as PILImage
    input_name  = session.get_inputs()[0].name
    output_name = session.get_outputs()[0].name

    def _once(img):
        pil    = PILImage.fromarray(img).convert('L').resize(target, PILImage.LANCZOS)
        arr    = np.array(pil, dtype=np.float32) / 255.0
        tensor = arr[np.newaxis, np.newaxis, :, :]
        return float(np.clip(session.run([output_name], {input_name: tensor})[0].flatten()[0], 0.0, 1.0))

    s1 = _once(image)
    lo, hi = int(np.percentile(image, 1)), int(np.percentile(image, 99))
    v2 = np.clip((image.astype(np.float32) - lo) / max(hi - lo, 1) * 255, 0, 255).astype(np.uint8) if hi > lo else image
    s2 = _once(v2)
    v3 = cv2.createCLAHE(clipLimit=1.5, tileGridSize=(8, 8)).apply(image)
    s3 = _once(v3)
    return max(s1, s2, s3) * 100.0


# ── Grid search ───────────────────────────────────────────────────────────────

def build_grid() -> list[dict]:
    """
    Sequential grid search strategy — minimises total configs by locking
    the best value at each stage before sweeping the next parameter.

    Stage 1: Sweep CLAHE (most impactful, first)
    Stage 2: Sweep UNet weight
    Stage 3: Sweep unsharp mask
    Stage 4: Sweep contrast stretch percentiles
    """
    # Stage 1: CLAHE
    stage1 = [
        {'clahe_clip_normal': cn, 'clahe_clip_dark': cd, 'clahe_tile': t}
        for cn, cd, t in product(
            [1.5, 2.0, 2.5, 3.0, 3.5],   # clip_normal
            [2.5, 3.5, 4.5],              # clip_dark (underexposed frames)
            [4, 8, 16],                   # tile size
        )
    ]
    # Stage 2: UNet blend
    stage2 = [{'unet_weight': w} for w in [0.50, 0.60, 0.70, 0.80, 0.90]]
    # Stage 3: Unsharp mask
    stage3 = [
        {'unsharp_sigma': s, 'unsharp_strength': st}
        for s, st in [(1.5, 1.4), (2.5, 1.6), (3.5, 1.8), (2.0, 1.0)]
    ]
    # Stage 4: Contrast stretch
    stage4 = [
        {'stretch_lo': lo, 'stretch_hi': hi}
        for lo, hi in [(1, 99), (2, 98), (3, 97), (5, 95)]
    ]
    # Label each group
    for d in stage1: d['_stage'] = 1
    for d in stage2: d['_stage'] = 2
    for d in stage3: d['_stage'] = 3
    for d in stage4: d['_stage'] = 4
    return stage1 + stage2 + stage3 + stage4


def run_config(unwrapped: np.ndarray, cfg: dict, session) -> float:
    import enhancement_pipeline
    enhanced, _ = enhancement_pipeline.enhance(unwrapped, sfm_coverage=1.0, config=cfg)
    return score_nfiq(enhanced, session)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    args = _parse_args()
    cache_dir = Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n=== MAC3D Enhancement Optimizer ===")
    print(f"Captures: {args.captures}   Cache: {cache_dir}\n")

    db, bkt = _init_firebase(args.project, args.bucket, key_file=args.credentials)

    # 1. Fetch recent captures
    captures = fetch_recent_captures(db, args.captures)
    if not captures:
        print("No scored captures found. Exiting.")
        return

    print(f"\nBaseline nfiqScores from Firestore:")
    for c in captures:
        print(f"  {c['captureId'][:8]}… v={c['pipelineVersion']}  nfiq={c['nfiqScore']:.1f}  sfm={c['sfmCoverage']:.2f}")

    # 2. Download + SfM (cached)
    print(f"\n--- Phase 1: SfM unwrap (cached to {cache_dir}) ---")

    unwrapped_list = []
    for c in captures:
        t0 = time.monotonic()
        uw = _get_unwrapped(c, bkt, cache_dir)
        elapsed = time.monotonic() - t0
        if uw is not None:
            unwrapped_list.append((c, uw))
            cached = '(cached)' if elapsed < 0.5 else f'({elapsed:.1f}s)'
            print(f"  OK {c['captureId'][:8]} {uw.shape}  {cached}")
        else:
            print(f"  SKIP {c['captureId'][:8]} SKIPPED")

    if not unwrapped_list:
        print("No unwrapped images available. Exiting.")
        return

    print(f"\n{len(unwrapped_list)} captures ready for enhancement grid search.")

    # 3. Load NFIQ model
    print("\n--- Phase 2: Loading NFIQ model ---")
    session = _load_nfiq(cache_dir)

    # 4. Baseline: score with current production config (config=None)
    print("\n--- Phase 3: Baseline (production config) ---")
    baseline_scores = []
    for c, uw in unwrapped_list:
        s = run_config(uw, {}, session)
        baseline_scores.append(s)
        print(f"  {c['captureId'][:8]}…  nfiq={s:.1f}  (stored={c['nfiqScore']:.1f})")

    baseline_mean = statistics.mean(baseline_scores)
    baseline_std  = statistics.stdev(baseline_scores) if len(baseline_scores) > 1 else 0.0
    baseline_pass = sum(1 for s in baseline_scores if s >= 35.0)
    print(f"\n  BASELINE: mean={baseline_mean:.2f}  std={baseline_std:.2f}  pass={baseline_pass}/{len(baseline_scores)}")

    # 5. Grid search — stage-by-stage
    print("\n--- Phase 4: Grid search ---")
    grid = build_grid()
    # Best config carries forward between stages as default override
    best_overall_cfg: dict = {}
    best_overall_mean: float = baseline_mean

    stage_results: dict[int, list] = {1: [], 2: [], 3: [], 4: []}

    for cfg in grid:
        stage = cfg.pop('_stage')
        # Merge with best-so-far from previous stages
        merged = {**best_overall_cfg, **cfg}
        scores = [run_config(uw, merged, session) for _, uw in unwrapped_list]
        mean_s = statistics.mean(scores)
        std_s  = statistics.stdev(scores) if len(scores) > 1 else 0.0
        n_pass = sum(1 for s in scores if s >= 35.0)
        stage_results[stage].append({
            'cfg': merged.copy(),
            'mean': mean_s,
            'std': std_s,
            'pass': n_pass,
            'scores': scores,
        })
        delta = mean_s - baseline_mean
        sign = '+' if delta >= 0 else ''
        print(f"  S{stage} {json.dumps(cfg)[:60]:<60}  mean={mean_s:.2f}  std={std_s:.2f}  pass={n_pass}  d={sign}{delta:.2f}")

        # Update best config when this stage's result improves on best-so-far
        if mean_s > best_overall_mean:
            best_overall_mean = mean_s
            best_overall_cfg = merged.copy()

    # 6. Final report
    print("\n" + "="*80)
    print("RESULTS SUMMARY")
    print("="*80)
    print(f"  Baseline:  mean={baseline_mean:.2f}  std={baseline_std:.2f}  pass={baseline_pass}/{len(unwrapped_list)}")

    all_results = [r for rs in stage_results.values() for r in rs]
    all_results.sort(key=lambda r: r['mean'], reverse=True)

    print(f"\n  Top 10 configs:")
    for i, r in enumerate(all_results[:10], 1):
        delta = r['mean'] - baseline_mean
        sign = '+' if delta >= 0 else ''
        print(f"  #{i:2d}  mean={r['mean']:.2f}  std={r['std']:.2f}  pass={r['pass']}  d={sign}{delta:.2f}")
        print(f"        {json.dumps({k:v for k,v in r['cfg'].items()})}")

    winner = all_results[0]
    print(f"\n  WINNER config (d={winner['mean']-baseline_mean:+.2f} vs baseline):")
    print(f"  {json.dumps(winner['cfg'], indent=4)}")

    # Save full results to JSON
    out_path = cache_dir / 'results.json'
    with open(out_path, 'w') as f:
        json.dump({
            'baseline': {'mean': baseline_mean, 'std': baseline_std, 'pass': baseline_pass},
            'captures': [c['captureId'] for c, _ in unwrapped_list],
            'results':  all_results,
        }, f, indent=2)
    print(f"\n  Full results saved to {out_path}")
    print("\nDone. Update enhancement_pipeline.py with winner config and redeploy.")


if __name__ == '__main__':
    main()
