"""
MAC3D SfM Pipeline Optimizer
==============================
Grid-searches SfM reconstruction parameters against real captured frames
to maximise final NFIQ score end-to-end (SfM → enhance → NFIQ).

Workflow
--------
1. Mark test captures with  preserveRawFrames=true  in Firestore BEFORE
   the pipeline runs (or use --mark-captures to set the flag automatically).
   This prevents main.py from deleting the raw frames after processing.

2. Run this script after captures are processed:
     cd functions/processEnhanceAndScore
     source venv/Scripts/activate
     python optimize_sfm.py [--captures 20] [--cache-dir ./sfm_opt_cache]

3. Bake the winner sfm_config values into sfm_pipeline.py defaults and redeploy.

Parameters swept
----------------
Stage 1: CLAHE (segmentation quality)        — most impactful
Stage 2: Camera intrinsic scale (FOV match)  — corrects projection misalignment
Stage 3: Morphological kernel size           — contour noise vs detail
Stage 4: Phase-correlation threshold         — angle refinement sensitivity
Stage 5: Segmentation prior weight           — fallback frame influence

Usage
-----
  # Mark captures before the pipeline processes them
  python optimize_sfm.py --mark-captures <captureId1> <captureId2> ...

  # Run optimization on already-preserved captures
  python optimize_sfm.py --captures 20 --cache-dir ./sfm_opt_cache

  # Clean up (remove preserveRawFrames flags + delete cached frames)
  python optimize_sfm.py --cleanup
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

_HERE = Path(__file__).parent.resolve()
sys.path.insert(0, str(_HERE))


# ── Args ──────────────────────────────────────────────────────────────────────

def _parse_args():
    p = argparse.ArgumentParser(description='MAC3D SfM optimizer')
    p.add_argument('--captures',        type=int,    default=20,
                   help='Max preserved captures to include')
    p.add_argument('--cache-dir',       type=str,    default=str(_HERE / 'sfm_opt_cache'))
    p.add_argument('--project',         type=str,    default='clearbridge-dc699')
    p.add_argument('--bucket',          type=str,    default='clearbridge-dc699.firebasestorage.app')
    p.add_argument('--credentials',     type=str,    default=None)
    p.add_argument('--mark-captures',   nargs='+',   metavar='CAPTURE_ID',
                   help='Set preserveRawFrames=true on these capture IDs and exit')
    p.add_argument('--cleanup',         action='store_true',
                   help='Remove preserveRawFrames flags and exit')
    return p.parse_args()


# ── Firebase ──────────────────────────────────────────────────────────────────

def _init_firebase(project: str, bucket_name: str, key_file: str | None = None):
    import firebase_admin
    from firebase_admin import credentials, firestore, storage

    if not firebase_admin._apps:
        key_path = key_file or os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
        if key_path:
            cred = credentials.Certificate(key_path)
            firebase_admin.initialize_app(cred, options={
                'projectId': project, 'storageBucket': bucket_name,
            })
        else:
            firebase_admin.initialize_app(options={
                'projectId': project, 'storageBucket': bucket_name,
            })
    return firestore.client(), storage.bucket()


# ── Mark / cleanup utilities ──────────────────────────────────────────────────

def mark_captures(db, capture_ids: list[str]) -> None:
    for cid in capture_ids:
        db.collection('captures').document(cid).update({'preserveRawFrames': True})
        print(f'  Marked {cid}  preserveRawFrames=true')
    print(f'\nSet flag on {len(capture_ids)} captures.')
    print('Now run the MAC3D capture flow — frames will NOT be deleted after processing.')


def cleanup(db, cache_dir: Path) -> None:
    print('Scanning Firestore for preserved captures...')
    docs = db.collection('captures').where('preserveRawFrames', '==', True).stream()
    count = 0
    for doc in docs:
        doc.reference.update({'preserveRawFrames': False})
        print(f'  Cleared {doc.id}')
        count += 1
    print(f'Cleared {count} flags.')
    if cache_dir.exists():
        import shutil
        shutil.rmtree(cache_dir)
        print(f'Deleted cache dir {cache_dir}')


# ── Fetch preserved captures ──────────────────────────────────────────────────

def fetch_preserved_captures(db, n: int) -> list[dict]:
    # Compound (preserveRawFrames + createdAt) index may not exist — fetch recent
    # captures and filter client-side to avoid index requirement.
    docs = (
        db.collection('captures')
        .order_by('createdAt', direction='DESCENDING')
        .limit(n * 20)
        .stream()
    )
    results = []
    for doc in docs:
        d = doc.to_dict()
        if not d.get('preserveRawFrames'):
            continue
        if d.get('status') not in ('scored', 'enhancing', 'failed'):
            continue   # pending captures may not have frames yet
        user_id    = d.get('userId', '')
        capture_id = d.get('captureId') or doc.id
        if not user_id or not capture_id:
            continue
        results.append({
            'captureId':       capture_id,
            'userId':          user_id,
            'basePath':        f'captures/{user_id}/{capture_id}',
            'nfiqScore':       d.get('nfiqScore', 0.0),
            'sfmCoverage':     d.get('sfmCoverage', 0.0),
            'sfmDiagnostics':  d.get('sfmDiagnostics', {}),
            'pipelineVersion': d.get('pipelineVersion', ''),
        })
        if len(results) >= n:
            break
    print(f'Found {len(results)} preserved captures.')
    return results


# ── Frame download + local cache ──────────────────────────────────────────────

_ANGLE_NAMES = ['front', 'right', 'top', 'left']

# Standard phone Y-plane resolutions — mirrors main.py _KNOWN_DIMS
_KNOWN_DIMS = [
    (1600, 1200), (1200, 1600),
    (1280,  960), ( 960, 1280),
    (1920, 1080), (1080, 1920),
    (1280,  720), ( 720, 1280),
    ( 640,  480), ( 480,  640),
    ( 960,  720), ( 720,  960),
]


def _decode_frame(img_bytes: bytes) -> Optional[np.ndarray]:
    """Decode a frame uploaded by the Flutter capture service.
    Frames are raw Y-plane bytes (uncompressed grayscale), not JPEG.
    Mirrors main.py _decode_image logic.
    """
    arr = np.frombuffer(img_bytes, dtype=np.uint8)
    bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if bgr is not None:
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    # Raw Y-plane fallback: match byte count against standard phone resolutions
    n = len(img_bytes)
    for w, h in _KNOWN_DIMS:
        if w * h == n:
            return arr.reshape(h, w)
    return None


def _frame_cache_dir(cache_dir: Path, capture_id: str) -> Path:
    return cache_dir / 'frames' / capture_id


def download_frames(capture: dict, bkt, cache_dir: Path) -> Optional[dict[str, np.ndarray]]:
    """
    Download all angle frames for a capture to local disk.
    Returns {angle_name: best_frame_array} or None on failure.
    Skips download if already cached.
    """
    cdir = _frame_cache_dir(cache_dir, capture['captureId'])

    # Return from disk cache if all expected angles are present
    if cdir.exists():
        cached: dict[str, np.ndarray] = {}
        for angle in _ANGLE_NAMES:
            p = cdir / f'{angle}.png'
            if p.exists():
                img = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
                if img is not None:
                    cached[angle] = img
        if cached:
            print(f'  (cached) {capture["captureId"][:8]}… angles={list(cached.keys())}')
            return cached

    # Download from Firebase Storage
    base_path  = capture['basePath']
    try:
        blobs = list(bkt.list_blobs(prefix=base_path))
    except Exception as e:
        print(f'  SKIP (list blobs failed): {e}')
        return None

    if not blobs:
        print(f'  SKIP — no blobs found at {base_path} (frames already deleted?)')
        return None

    # Group blobs by angle
    blob_map: dict[str, list] = {a: [] for a in _ANGLE_NAMES}
    for blob in blobs:
        fname = blob.name.split('/')[-1]
        parts = fname.replace('.jpg', '').replace('.jpeg', '').split('_')
        if len(parts) < 3:
            continue
        angle = parts[2]
        if angle in blob_map:
            blob_map[angle].append(blob)

    frames: dict[str, np.ndarray] = {}
    for angle in _ANGLE_NAMES:
        angle_blobs = blob_map.get(angle, [])
        if not angle_blobs:
            continue
        # Pick the blob with highest Laplacian variance (sharpest frame)
        best_img, best_lap = None, -1.0
        for blob in angle_blobs:
            try:
                data = blob.download_as_bytes(timeout=30)
                img  = _decode_frame(data)
                if img is None:
                    continue
                lap = float(cv2.Laplacian(img, cv2.CV_64F).var())
                if lap > best_lap:
                    best_lap, best_img = lap, img
            except Exception:
                continue
        if best_img is not None:
            frames[angle] = best_img

    if not frames:
        print(f'  SKIP — could not decode any frames for {capture["captureId"][:8]}')
        return None

    # Cache to disk as PNG
    cdir.mkdir(parents=True, exist_ok=True)
    for angle, img in frames.items():
        cv2.imwrite(str(cdir / f'{angle}.png'), img)

    print(f'  Downloaded {capture["captureId"][:8]}… angles={list(frames.keys())}')
    return frames


def frames_to_list(frames_dict: dict[str, np.ndarray]) -> tuple[list, list]:
    """Return (frame_list, angles_deg_list) in canonical front/right/top/left order."""
    order  = [a for a in _ANGLE_NAMES if a in frames_dict]
    imgs   = [frames_dict[a] for a in order]
    angles = [{'front': 0.0, 'right': 90.0, 'top': 180.0, 'left': 270.0}[a] for a in order]
    return imgs, angles


# ── NFIQ scoring (mirrors optimize_pipeline.py) ───────────────────────────────

_nfiq_session = None

def _load_nfiq(cache_dir: Path):
    global _nfiq_session
    if _nfiq_session is not None:
        return _nfiq_session
    import onnxruntime as ort
    for p in [_HERE / 'nfiq_resnet18.onnx', Path('/tmp/nfiq_resnet18.onnx'), cache_dir / 'nfiq_resnet18.onnx']:
        if p.exists():
            _nfiq_session = ort.InferenceSession(str(p), providers=['CPUExecutionProvider'])
            print(f'NFIQ model loaded from {p}')
            return _nfiq_session
    raise FileNotFoundError('nfiq_resnet18.onnx not found')


def score_nfiq(image: np.ndarray, session, target=(500, 500)) -> float:
    from PIL import Image as PILImage
    inp  = session.get_inputs()[0].name
    out  = session.get_outputs()[0].name

    def _once(img):
        pil    = PILImage.fromarray(img).convert('L').resize(target, PILImage.LANCZOS)
        arr    = np.array(pil, dtype=np.float32) / 255.0
        tensor = arr[np.newaxis, np.newaxis, :, :]
        return float(np.clip(session.run([out], {inp: tensor})[0].flatten()[0], 0.0, 1.0))

    s1 = _once(image)
    lo, hi = int(np.percentile(image, 1)), int(np.percentile(image, 99))
    v2 = np.clip((image.astype(np.float32) - lo) / max(hi - lo, 1) * 255, 0, 255).astype(np.uint8) if hi > lo else image
    s2 = _once(v2)
    v3 = cv2.createCLAHE(clipLimit=1.5, tileGridSize=(8, 8)).apply(image)
    s3 = _once(v3)
    return max(s1, s2, s3) * 100.0


# ── SfM + enhance + score (one config) ───────────────────────────────────────

def run_sfm_config(
    frames_dict: dict,
    sfm_cfg:     dict,
    session,
) -> tuple[float, float, str]:
    """
    Run SfM with sfm_cfg, enhance with production defaults, score NFIQ.
    Returns (nfiq_score, sfm_coverage, seg_methods_str).
    """
    import sfm_pipeline
    import enhancement_pipeline

    imgs, angles = frames_to_list(frames_dict)

    try:
        unwrapped, coverage, _, diag, _ = sfm_pipeline.reconstruct_and_unwrap(
            imgs,
            angles_deg=angles,
            sfm_config=sfm_cfg,
        )
    except sfm_pipeline.CaptureQualityError as e:
        return 0.0, 0.0, f'CaptureQualityError: {e}'
    except Exception as e:
        return 0.0, 0.0, f'Error: {e}'

    enhanced, _ = enhancement_pipeline.enhance(unwrapped, sfm_coverage=coverage)
    nfiq        = score_nfiq(enhanced, session)
    seg_methods = ','.join(diag.get('segMethods', []))
    return nfiq, coverage, seg_methods


# ── Grid definition ───────────────────────────────────────────────────────────

def build_sfm_grid() -> list[dict]:
    """
    Sequential grid — lock best value at each stage before sweeping next.

    Stage 1: CLAHE for segmentation (most impactful: thumb isolation quality)
    Stage 2: Camera intrinsic scale (corrects FOV mismatch for Doogee S118)
    Stage 3: Morphological kernel size (contour quality)
    Stage 4: Phase-correlation confidence threshold (angle refinement gate)
    Stage 5: Segmentation prior fallback weight
    """
    stage1 = [
        {'clahe_clip': cc, 'clahe_tile': ct}
        for cc, ct in product(
            [1.5, 2.0, 2.5, 3.0, 3.5, 4.0],   # CLAHE clip
            [4, 8, 16],                          # CLAHE tile
        )
    ]
    stage2 = [{'fx_scale': s} for s in [0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15]]
    stage3 = [{'morph_ksize': k} for k in [7, 11, 15, 19, 23]]
    stage4 = [{'phase_conf_threshold': t} for t in [0.15, 0.20, 0.25, 0.30, 0.40]]
    stage5 = [{'seg_prior_weight': w} for w in [0.15, 0.25, 0.35, 0.50]]

    for d in stage1: d['_stage'] = 1
    for d in stage2: d['_stage'] = 2
    for d in stage3: d['_stage'] = 3
    for d in stage4: d['_stage'] = 4
    for d in stage5: d['_stage'] = 5
    return stage1 + stage2 + stage3 + stage4 + stage5


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    args      = _parse_args()
    cache_dir = Path(args.cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    db, bkt = _init_firebase(args.project, args.bucket, key_file=args.credentials)

    # ── Utility modes ─────────────────────────────────────────────────────────
    if args.mark_captures:
        mark_captures(db, args.mark_captures)
        return
    if args.cleanup:
        cleanup(db, cache_dir)
        return

    print(f'\n=== MAC3D SfM Optimizer ===')
    print(f'Captures: {args.captures}   Cache: {cache_dir}\n')

    # ── 1. Fetch preserved captures ───────────────────────────────────────────
    captures = fetch_preserved_captures(db, args.captures)
    if not captures:
        print('No preserved captures found.')
        print('TIP: Set preserveRawFrames=true on captures before the pipeline runs:')
        print('     python optimize_sfm.py --mark-captures <captureId1> <captureId2>')
        return

    print('\nBaseline scores from Firestore:')
    for c in captures:
        diag = c.get('sfmDiagnostics') or {}
        seg  = ','.join(diag.get('segMethods', ['?']))
        print(f'  {c["captureId"][:8]}…  nfiq={c["nfiqScore"]:.1f}  cov={c["sfmCoverage"]:.2f}  seg=[{seg}]')

    # ── 2. Download raw frames (cached) ───────────────────────────────────────
    print(f'\n--- Phase 1: Download raw frames ---')
    capture_frames: list[tuple[dict, dict]] = []
    for c in captures:
        t0 = time.monotonic()
        frames = download_frames(c, bkt, cache_dir)
        if frames:
            capture_frames.append((c, frames))
        else:
            print(f'  SKIP {c["captureId"][:8]}')

    if not capture_frames:
        print('No frame data available. Did frames get deleted before running this script?')
        print('Mark captures with --mark-captures BEFORE the pipeline processes them.')
        return

    print(f'\n{len(capture_frames)} captures ready.')

    # ── 3. Load NFIQ model ────────────────────────────────────────────────────
    print('\n--- Phase 2: Loading NFIQ model ---')
    session = _load_nfiq(cache_dir)

    # ── 4. Baseline: production defaults (sfm_config=None) ────────────────────
    print('\n--- Phase 3: Baseline (production SfM config) ---')
    baseline_scores: list[float] = []
    baseline_coverages: list[float] = []
    for c, frames in capture_frames:
        nfiq, cov, seg = run_sfm_config(frames, {}, session)
        baseline_scores.append(nfiq)
        baseline_coverages.append(cov)
        print(f'  {c["captureId"][:8]}…  nfiq={nfiq:.1f}  cov={cov:.2f}  seg=[{seg}]  (stored nfiq={c["nfiqScore"]:.1f})')

    b_mean = statistics.mean(baseline_scores)
    b_std  = statistics.stdev(baseline_scores) if len(baseline_scores) > 1 else 0.0
    b_cov  = statistics.mean(baseline_coverages)
    print(f'\n  BASELINE: nfiq_mean={b_mean:.2f}  std={b_std:.2f}  cov_mean={b_cov:.2f}')

    # ── 5. Grid search ────────────────────────────────────────────────────────
    print('\n--- Phase 4: SfM grid search ---')
    grid = build_sfm_grid()
    best_cfg:  dict  = {}
    best_mean: float = b_mean
    stage_results: dict[int, list] = {s: [] for s in range(1, 6)}

    for cfg in grid:
        stage = cfg.pop('_stage')
        merged = {**best_cfg, **cfg}
        nfiq_scores = []
        cov_scores  = []
        for c, frames in capture_frames:
            nfiq, cov, _ = run_sfm_config(frames, merged, session)
            nfiq_scores.append(nfiq)
            cov_scores.append(cov)

        mean_n = statistics.mean(nfiq_scores)
        std_n  = statistics.stdev(nfiq_scores) if len(nfiq_scores) > 1 else 0.0
        mean_c = statistics.mean(cov_scores)
        delta  = mean_n - b_mean
        sign   = '+' if delta >= 0 else ''
        stage_results[stage].append({
            'cfg': merged.copy(), 'mean': mean_n, 'std': std_n, 'cov': mean_c,
            'scores': nfiq_scores,
        })
        print(f'  S{stage} {json.dumps(cfg):<50}  nfiq={mean_n:.2f}  std={std_n:.2f}  cov={mean_c:.2f}  d={sign}{delta:.2f}')

        if mean_n > best_mean:
            best_mean = mean_n
            best_cfg  = merged.copy()

    # ── 6. Results ────────────────────────────────────────────────────────────
    print('\n' + '=' * 80)
    print('RESULTS SUMMARY')
    print('=' * 80)
    print(f'  Baseline:  nfiq={b_mean:.2f}  std={b_std:.2f}  cov={b_cov:.2f}')

    all_results = sorted(
        [r for rs in stage_results.values() for r in rs],
        key=lambda r: r['mean'], reverse=True,
    )

    print(f'\n  Top 10 configs:')
    for i, r in enumerate(all_results[:10], 1):
        delta = r['mean'] - b_mean
        sign  = '+' if delta >= 0 else ''
        print(f'  #{i:2d}  nfiq={r["mean"]:.2f}  std={r["std"]:.2f}  cov={r["cov"]:.2f}  d={sign}{delta:.2f}')
        print(f'        {json.dumps({k: v for k, v in r["cfg"].items()})}')

    winner = all_results[0]
    print(f'\n  WINNER (d={winner["mean"] - b_mean:+.2f} vs baseline):')
    print(f'  {json.dumps(winner["cfg"], indent=4)}')

    out_path = cache_dir / 'sfm_results.json'
    with open(out_path, 'w') as f:
        json.dump({
            'baseline': {'mean': b_mean, 'std': b_std, 'cov': b_cov},
            'captures': [c['captureId'] for c, _ in capture_frames],
            'results':  all_results,
        }, f, indent=2)
    print(f'\n  Full results -> {out_path}')
    print('\nNext: update sfm_pipeline.py defaults with winner config and redeploy.')
    print('      Run --cleanup to remove preserveRawFrames flags when done.')


if __name__ == '__main__':
    main()
