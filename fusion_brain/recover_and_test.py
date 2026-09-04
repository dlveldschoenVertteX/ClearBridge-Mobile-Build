"""Recover a fusion_v1 capture whose front frames were recorded as FAILED
but mostly landed in Storage, then run the flat validated-bridge merge.

REAL DATA-LOSS BUG this exists to work around, found 2026-08-26 on capture
`ffb1682f-ed0d-4ffc-bb00-c15f4ebc1225`:

  frames: []                                    <- Firestore
  fusionDebug.uploadFailed_front_amb_0: "TimeoutException after 0:00:45"
  ... all 8 front frames marked failed ...

  Storage nonetheless contains all 8 files.

Verified byte-level rather than assumed, and the honest picture is more
nuanced than "the timeout was spurious":

  front_amb_0.jpg  2,097,152 bytes (exactly 2 MiB), NO JPEG EOI marker
                   -> genuinely truncated, cut at an exact buffer boundary
  the other 7      valid EOI marker -> complete, usable files

So ONE upload really did fail and 7 completed, yet the client marked all 8
failed and emptied `frames` -- leaving a capture that is 7/8 intact in
Storage but entirely invisible to anything reading the document, the
production backend included. Both halves are worth fixing client-side: the
timeout should confirm against Storage before declaring failure, and it
should fail only the frame that actually failed rather than the whole
batch. Tilt and sweep on the same capture recorded fine; only the front
burst, the largest upload batch, hit the timeout.

**Integrity gate, learned the hard way**: cv2 decodes a truncated JPEG
anyway (emitting "Premature end of JPEG file"), and the garbage in the
missing region INFLATES Laplacian variance -- so on this script's first
run the single corrupt frame scored sharpest (56.6 vs 50-53) and was
chosen as the fusion anchor, quietly invalidating that run. Every file is
now checked for a real EOI marker before it is trusted. A file existing is
not evidence it is complete.

This script reconstructs the missing `frames` list from the files that
pass that gate, computes a real Laplacian per ambient frame so anchor
selection matches what the client would have chosen, and runs the flat
validated-bridge merge on the recovered capture.

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
        # INTEGRITY GATE -- do not trust a file just because it exists.
        # front_amb_0.jpg on this capture is exactly 2,097,152 bytes (2 MiB)
        # with no JPEG EOI marker: a genuinely truncated upload, cut at an
        # exact buffer boundary. cv2 still decodes it (emitting "Premature
        # end of JPEG file"), and the garbage in the missing region INFLATES
        # Laplacian variance -- so without this check the most corrupt frame
        # scores sharpest and gets chosen as the anchor, which is exactly
        # what happened on the first run of this script.
        local = os.path.join(p0c.CACHE, path.replace('/', '_'))
        try:
            with open(local, 'rb') as fh:
                fh.seek(-2, os.SEEK_END)
                if fh.read(2) != b'\xff\xd9':
                    print(f'    {os.path.basename(path):20} TRUNCATED '
                          f'({os.path.getsize(local)} bytes, no EOI) -- skipped')
                    continue
        except OSError:
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
