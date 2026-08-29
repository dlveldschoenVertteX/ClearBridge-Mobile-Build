"""Build a pseudo-labeled training set for the thumb/pad segmentation U-Net
from REAL ClearBridge captures.

Reuses `sfm_pipeline._segment_via_flash_diff` directly (not a reimplementation
-- avoids subtly diverging from the exact production algorithm) to generate
pseudo-labels from each capture's real ambient/flash burst frame pair. Both
the ambient AND flash frame of a pair are saved as separate training inputs
against the SAME derived mask (they share the same true thumb silhouette) --
a free 2x on a dataset this small.

Usage:
    python build_dataset.py --out dataset/ [--limit N]

Requires GOOGLE_APPLICATION_CREDENTIALS pointing at a service account with
Firestore + Storage read access.
"""
from __future__ import annotations

import argparse
import io
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                 '..', '..', 'functions', 'processEnhanceAndScore'))
from sfm_pipeline import _segment_via_flash_diff  # noqa: E402

_RELEVANT_METHODS = {'front_only_v1', 'front_burst', 'front_burst_hybrid_capture'}
_KSIZE = 15  # matches sfm_pipeline's typical closing kernel size for this stage


def _load_gray(data: bytes) -> np.ndarray | None:
    arr = np.frombuffer(data, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_GRAYSCALE)
    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), 'dataset'))
    ap.add_argument('--limit', type=int, default=0)
    args = ap.parse_args()

    import firebase_admin
    from firebase_admin import credentials, firestore, storage

    if not firebase_admin._apps:
        cred = credentials.ApplicationDefault()
        firebase_admin.initialize_app(cred, {'projectId': 'clearbridge-dc699'})
    db = firestore.client()
    bucket = storage.bucket('clearbridge-dc699.firebasestorage.app')

    docs = list(db.collection('captures').stream())
    pairs_built = 0
    frames_saved = 0
    captures_used = 0

    img_dir = os.path.join(args.out, 'images')
    mask_dir = os.path.join(args.out, 'masks')
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(mask_dir, exist_ok=True)

    n_unseeded = 0
    for d in docs:
        data = d.to_dict()
        if data.get('captureMethod') not in _RELEVANT_METHODS:
            continue
        frames = data.get('frames') or []
        ambient = [f for f in frames if f.get('flashOn') is False and f.get('path')]
        flash = [f for f in frames if f.get('flashOn') is True and f.get('path')]
        if not ambient or not flash:
            continue

        # Round 45 (layer 3) real root cause: this loop used to call
        # _segment_via_flash_diff with no seed at all, i.e. the pre-round-16
        # frame-centre default -- the exact 555px mis-seed round 16 (2026-
        # 08-19) found and fixed for LIVE production masking, but never
        # regenerated this model's own training labels for. guideRegion is
        # already written on every real front_only_v1 capture doc; reuse it
        # exactly the way afis_print._flash_diff_mask already does (real
        # still-space fractional coords * frame dimensions), so the labels
        # this model trains on are seeded the same way the mask it's meant
        # to approximate already is. Falls back to unseeded (old behaviour)
        # only when a capture genuinely has no guideRegion, so this can only
        # ever add correctly-seeded labels, never lose real data.
        guide_region = data.get('guideRegion')

        n_pairs_this_capture = min(len(ambient), len(flash))
        for i in range(n_pairs_this_capture):
            try:
                amb_blob = bucket.blob(ambient[i]['path'])
                fl_blob = bucket.blob(flash[i]['path'])
                amb_bytes = amb_blob.download_as_bytes()
                fl_bytes = fl_blob.download_as_bytes()
            except Exception as e:
                print(f'  skip (download failed): {d.id} pair {i}: {e}')
                continue

            amb_gray = _load_gray(amb_bytes)
            fl_gray = _load_gray(fl_bytes)
            if amb_gray is None or fl_gray is None or amb_gray.shape != fl_gray.shape:
                continue

            seed_cx = seed_cy = None
            if isinstance(guide_region, dict):
                try:
                    h, w = amb_gray.shape[:2]
                    seed_cx = float(guide_region['cx']) * w
                    seed_cy = float(guide_region['cy']) * h
                except (KeyError, TypeError, ValueError):
                    seed_cx = seed_cy = None
            if seed_cx is None:
                n_unseeded += 1

            result = _segment_via_flash_diff(amb_gray, fl_gray, _KSIZE,
                                              seed_cx=seed_cx, seed_cy=seed_cy)
            if result is None:
                print(f'  skip (flash-diff failed to segment): {d.id} pair {i}')
                continue
            mask, _tx, _ty = result

            # Plausibility gate: reject masks that are implausibly small/large
            # (a failed segmentation that still returned something) before
            # trusting it as a training label.
            frac = float((mask > 0).sum()) / mask.size
            if not (0.03 <= frac <= 0.55):
                print(f'  skip (implausible mask area frac={frac:.3f}): {d.id} pair {i}')
                continue

            base = f'{d.id}_{i}'
            cv2.imwrite(os.path.join(img_dir, base + '_amb.png'), amb_gray)
            cv2.imwrite(os.path.join(mask_dir, base + '_amb.png'), mask)
            cv2.imwrite(os.path.join(img_dir, base + '_fl.png'), fl_gray)
            cv2.imwrite(os.path.join(mask_dir, base + '_fl.png'), mask)
            frames_saved += 2
            pairs_built += 1

        if n_pairs_this_capture > 0:
            captures_used += 1
        if args.limit and captures_used >= args.limit:
            break

    print(f'\ncaptures used: {captures_used}')
    print(f'flash-diff pairs successfully segmented: {pairs_built}')
    print(f'training images saved (amb+flash, both against the same mask): {frames_saved}')
    print(f'pairs with no guideRegion (fell back to unseeded frame-centre): {n_unseeded}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
