"""Recover a fusion_v1 capture whose front frames uploaded successfully but
were recorded as FAILED, then run the flat validated-bridge merge on it.

REAL CLIENT BUG this exists to work around, found 2026-08-26 on capture
`ffb1682f-ed0d-4ffc-bb00-c15f4ebc1225`:

  frames: []                                    <- Firestore
  fusionDebug.uploadFailed_front_amb_0: "TimeoutException after 0:00:45"
  fusionDebug.uploadFailed_front_fl_1:  "TimeoutException after 0:00:45"
  ... all 8 front frames marked failed ...

  Storage actually contains all 8: front_amb_{0,2,4,6}.jpg,
                                   front_fl_{1,3,5,7}.jpg

So the uploads SUCCEEDED and the client's own 45s timeout fired anyway --
each frame was then recorded as failed and omitted from `frames`, leaving a
capture with complete data in Storage that is unusable by anything reading
the document (production backend included). The tilt and sweep shots on the
same capture recorded fine; only the front burst hit the timeout, which is
consistent with the front burst being the largest upload batch.

This script reconstructs the missing `frames` list from what is really in
Storage, computes a REAL Laplacian sharpness per ambient frame (so anchor
selection matches what the client would have chosen rather than defaulting
to whichever happened to be first), and runs the flat validated-bridge
merge on the recovered capture.

Read-only: Firestore/Storage reads, no writes to Firestore or Storage.
"""
from __future__ import annotations

import os
import re
import sys
from typing import List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, 'functions', 'processEnhanceAndScore'))

import cv2                                     # noqa: E402
import numpy as np                             # noqa: E402

import phase0c_real_fusion_capture as p0c      # noqa: E402
import phase3f_validated_merge as p3f          # noqa: E402


class _FakeDoc:
    def __init__(self, data: dict):
        self.exists = True
        self._d = data

    def to_dict(self) -> dict:
        return self._d


class _FakeRef:
    def __init__(self, data: dict):
        self._d = data

    def get(self) -> _FakeDoc:
        return _FakeDoc(self._d)


class _FakeCollection:
    def __init__(self, data: dict):
        self._d = data

    def document(self, _id: str) -> _FakeRef:
        return _FakeRef(self._d)


class _FakeDb:
    def __init__(self, data: dict):
        self._d = data

    def collection(self, _name: str) -> _FakeCollection:
        return _FakeCollection(self._d)


def recover_frames(cap_id: str) -> Optional[dict]:
    doc = p0c._db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id} not found')
        return None
    v = dict(doc.to_dict())
    if v.get('frames'):
        print(f'  {cap_id[:12]} already has {len(v["frames"])} frames -- no recovery needed')
        return v

    base = v.get('basePath') or f'captures/{v.get("userId")}/{cap_id}'
    blobs = list(p0c._bucket.list_blobs(prefix=base))
    front = [b.name for b in blobs
             if re.search(r'/front_(amb|fl)_\d+\.jpg$', b.name)]
    if not front:
        print('  no front frames in Storage either -- genuinely unrecoverable')
        return None

    print(f'  recovering {len(front)} front frames the client marked failed')
    frames: List[dict] = []
    for path in sorted(front):
        img = p0c._download(path)
        if img is None:
            continue
        g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
        lap = float(cv2.Laplacian(g, cv2.CV_64F).var())
        frames.append({'path': path,
                       'flashOn': '_fl_' in os.path.basename(path),
                       'laplacianScore': lap})
        print(f'    {os.path.basename(path):20} laplacian={lap:9.1f}')
    v['frames'] = frames
    amb = [f for f in frames if not f['flashOn']]
    if amb:
        best = max(amb, key=lambda f: f['laplacianScore'])
        print(f'  anchor will be {os.path.basename(best["path"])} '
              f'(sharpest ambient, laplacian={best["laplacianScore"]:.1f})')
    return v


def main(cap_id: str, max_added: int = 15) -> None:
    print(f'\n=== recovering {cap_id[:12]} ===')
    data = recover_frames(cap_id)
    if data is None:
        return
    # Point every module that resolves the capture at the recovered dict.
    fake = _FakeDb(data)
    p0c._db = fake
    p3f._db = fake
    print(f'\n=== flat validated-bridge merge on recovered capture ===')
    p3f.run(cap_id, max_added, p3f.BLUR_SIGMA, p3f.CLOSE_RADIUS_PX,
            0.0, True, 'recovered')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 recover_and_test.py <captureId> [max_added]')
        sys.exit(1)
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 15)
