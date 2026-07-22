"""Pull real oscillating_8phase captures (front + lightly-yawed side frames)
from Firestore/Storage for Phase 0 testing -- the same real capture library
the 2026-07-12 small-roll NO-GO test used. Adapts scripts/backfill_nfiq2.py's
credential/bucket pattern. NOT a Cloud Function -- run locally only.

Usage:
    GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json python3 pull_real_captures.py [out_dir]

Selects, per capture, the same front-anchor + side-frame window
afis_print.py's own mosaic path uses (_MOSAIC_YAW_MIN=4.0 <
abs(angleDeg) <= _MOSAIC_YAW_DEG=12.0), so this is an apples-to-apples
input set with the original 2026-07-12 test and the current production
mosaicFreq variant.
"""
from __future__ import annotations

import json
import os
import sys

import cv2
import firebase_admin
import numpy as np
from firebase_admin import credentials, firestore, storage

_PROJECT_ID = 'clearbridge-dc699'
_BUCKET = 'clearbridge-dc699.firebasestorage.app'
_MOSAIC_YAW_MIN = 4.0
_MOSAIC_YAW_DEG = 12.0
_MAX_SIDE = 4


def _init_firebase():
    cred_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
    if not cred_path:
        print('ERROR: set GOOGLE_APPLICATION_CREDENTIALS to a service account key path first.')
        sys.exit(1)
    firebase_admin.initialize_app(
        credentials.Certificate(cred_path),
        {'storageBucket': _BUCKET, 'projectId': _PROJECT_ID},
    )
    return firestore.client(), storage.bucket()


def _decode_and_square(jpeg_bytes: bytes) -> np.ndarray:
    arr = np.frombuffer(jpeg_bytes, dtype=np.uint8)
    bgr = cv2.imdecode(arr, cv2.IMREAD_GRAYSCALE)
    h, w = bgr.shape[:2]
    side = min(h, w)
    y0, x0 = (h - side) // 2, (w - side) // 2
    return bgr[y0:y0 + side, x0:x0 + side]


def pull(out_dir: str, limit: int = 30) -> None:
    db, bucket = _init_firebase()
    os.makedirs(out_dir, exist_ok=True)
    docs = db.collection('captures').where('captureMode', '==', 'oscillating_8phase').stream()
    manifest = []
    n_written = 0
    for doc in docs:
        if n_written >= limit:
            break
        v = doc.to_dict() or {}
        if v.get('status') != 'scored':
            continue
        frames_meta = v.get('frames', [])
        if not frames_meta:
            continue

        def _by_sharpness(e):
            return float(e.get('laplacianScore') or 0.0)

        front_cands = sorted(
            [e for e in frames_meta if abs(float(e.get('angleDeg', 999))) <= _MOSAIC_YAW_MIN
             and not e.get('flashOn')],
            key=_by_sharpness, reverse=True)
        if not front_cands:
            continue
        side_cands = sorted(
            [e for e in frames_meta
             if _MOSAIC_YAW_MIN < abs(float(e.get('angleDeg', 999))) <= _MOSAIC_YAW_DEG
             and not e.get('flashOn')],
            key=_by_sharpness, reverse=True)[:_MAX_SIDE]
        if len(side_cands) < 1:
            continue  # need at least one side frame to test fusion at all

        cap_dir = os.path.join(out_dir, doc.id[:8])
        os.makedirs(cap_dir, exist_ok=True)
        try:
            front_bytes = bucket.blob(front_cands[0]['path']).download_as_bytes(timeout=60)
        except Exception as e:
            print(f'  {doc.id[:8]}: front download failed, skipping ({e})')
            continue
        front_img = _decode_and_square(front_bytes)
        cv2.imwrite(os.path.join(cap_dir, 'front.png'), front_img)

        side_paths = []
        for i, sc in enumerate(side_cands):
            try:
                sb = bucket.blob(sc['path']).download_as_bytes(timeout=60)
            except Exception as e:
                print(f'  {doc.id[:8]}: side {i} download failed ({e})')
                continue
            side_img = _decode_and_square(sb)
            side_path = os.path.join(cap_dir, f'side_{i}.png')
            cv2.imwrite(side_path, side_img)
            side_paths.append({'file': f'side_{i}.png', 'angleDeg': float(sc.get('angleDeg', 0.0))})

        if not side_paths:
            continue
        manifest.append({
            'captureId': doc.id,
            'userId': v.get('userId'),
            'nfiq2Score': v.get('nfiq2Score'),
            'front': 'front.png',
            'sides': side_paths,
        })
        n_written += 1
        print(f'  pulled {doc.id[:8]}: front + {len(side_paths)} side frame(s)')

    with open(os.path.join(out_dir, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f'DONE: {n_written} captures with usable front+side frames -> {out_dir}')


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'pulled_captures'
    pull(out)
