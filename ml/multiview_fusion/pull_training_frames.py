"""Pull REAL capture frames (any mode) from Firestore/Storage as single-frame
training sources for Phase 2's synthetic-pair training -- synth_multiview
generates pairs on the fly from single frames, so ANY real frame of the
deployment domain is usable training material (no pairing/labeling needed).

Schema-drift-robust on purpose: rather than hardcoding every per-mode field
layout (oscillating `frames[].path`, front_only burst path lists, secondary-
camera `paths`, distance-stage frames...), it recursively scans each capture
doc for ANY string that looks like a Storage image path and downloads up to
a per-capture cap. Same firebase_admin credential pattern as
scripts/backfill_nfiq2.py / pull_real_captures.py.

Usage:
    GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json \
        python3 pull_training_frames.py <out_dir> [max_captures]

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

import json
import os
import re
import sys

import cv2
import firebase_admin
import numpy as np
from firebase_admin import credentials, firestore, storage

_PROJECT_ID = 'clearbridge-dc699'
_BUCKET = 'clearbridge-dc699.firebasestorage.app'
_PATH_RE = re.compile(r'^captures/.+\.(jpe?g|png)$', re.IGNORECASE)
_MAX_FRAMES_PER_CAPTURE = 10
_MIN_SIDE_PX = 400        # skip thumbnails/tiny crops
_MAX_SIDE_PX = 1200       # center-CROP (never resize -- ridge scale!) if bigger


def _init_firebase():
    cred_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
    if not cred_path:
        print('ERROR: set GOOGLE_APPLICATION_CREDENTIALS first.')
        sys.exit(1)
    firebase_admin.initialize_app(
        credentials.Certificate(cred_path),
        {'storageBucket': _BUCKET, 'projectId': _PROJECT_ID})
    return firestore.client(), storage.bucket()


def _collect_paths(obj, found: list[str]) -> None:
    if isinstance(obj, str):
        if _PATH_RE.match(obj):
            found.append(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            _collect_paths(v, found)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            _collect_paths(v, found)


def _prep(jpeg_bytes: bytes) -> np.ndarray | None:
    arr = np.frombuffer(jpeg_bytes, dtype=np.uint8)
    g = cv2.imdecode(arr, cv2.IMREAD_GRAYSCALE)
    if g is None:
        return None
    h, w = g.shape[:2]
    side = min(h, w)
    if side < _MIN_SIDE_PX:
        return None
    y0, x0 = (h - side) // 2, (w - side) // 2
    g = g[y0:y0 + side, x0:x0 + side]
    if side > _MAX_SIDE_PX:   # center-crop, NEVER resize (preserve ridge scale)
        off = (side - _MAX_SIDE_PX) // 2
        g = g[off:off + _MAX_SIDE_PX, off:off + _MAX_SIDE_PX]
    return g


def pull(out_dir: str, max_captures: int = 80) -> None:
    db, bucket = _init_firebase()
    os.makedirs(out_dir, exist_ok=True)
    manifest = []
    n_caps = n_frames = 0
    for doc in db.collection('captures').stream():
        if n_caps >= max_captures:
            break
        v = doc.to_dict() or {}
        paths: list[str] = []
        _collect_paths(v, paths)
        paths = list(dict.fromkeys(paths))[:_MAX_FRAMES_PER_CAPTURE]
        if not paths:
            continue
        wrote_any = False
        for i, p in enumerate(paths):
            try:
                b = bucket.blob(p).download_as_bytes(timeout=60)
            except Exception:
                continue
            g = _prep(b)
            if g is None:
                continue
            fname = f'{doc.id[:8]}_{i:02d}.png'
            cv2.imwrite(os.path.join(out_dir, fname), g)
            manifest.append({'file': fname, 'captureId': doc.id,
                             'userId': v.get('userId'),
                             'captureMode': v.get('captureMode')})
            n_frames += 1
            wrote_any = True
        if wrote_any:
            n_caps += 1
            print(f'  {doc.id[:8]} ({v.get("captureMode")}): '
                  f'+{sum(1 for m in manifest if m["captureId"] == doc.id)} frames',
                  flush=True)
    json.dump(manifest, open(os.path.join(out_dir, 'manifest.json'), 'w'), indent=2)
    users = {m['userId'] for m in manifest}
    print(f'DONE: {n_frames} frames from {n_caps} captures, {len(users)} users -> {out_dir}')


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'pulled_frames'
    cap = int(sys.argv[2]) if len(sys.argv) > 2 else 80
    pull(out, cap)
