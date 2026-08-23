"""
One-off local diagnostic: backfill nfiq2Score onto existing capture documents
that predate the NFIQ2 sidecar. NOT a Cloud Function -- run locally, not
deployed.

Usage (single-line, Windows CMD-safe):
    set GOOGLE_APPLICATION_CREDENTIALS=C:\\path\\to\\serviceAccountKey.json && set NFIQ2_SERVICE_URL=https://nfiq2-service-xxxxx-uc.a.run.app && python scripts\\backfill_nfiq2.py

Requires:
  - A Firebase Admin SDK service account key for clearbridge-dc699, pointed
    to by GOOGLE_APPLICATION_CREDENTIALS. This script never fetches or
    writes that key itself -- you provide the path.
  - NFIQ2_SERVICE_URL set to the deployed sidecar's URL (functions/nfiq2_service).
  - The identity backing GOOGLE_APPLICATION_CREDENTIALS needs the Cloud Run
    Invoker role on the nfiq2 sidecar, since it's deployed
    --no-allow-unauthenticated (see nfiq2_client._fetch_id_token).
"""

from __future__ import annotations

import io
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'functions', 'processEnhanceAndScore'))

import firebase_admin
from firebase_admin import credentials, firestore, storage
import numpy as np
from PIL import Image

import nfiq2_client

_PROJECT_ID = 'clearbridge-dc699'
_BUCKET     = 'clearbridge-dc699.firebasestorage.app'


def _init_firebase():
    cred_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
    if not cred_path:
        print('ERROR: set GOOGLE_APPLICATION_CREDENTIALS to a service account key path first.')
        sys.exit(1)
    if not os.environ.get('NFIQ2_SERVICE_URL'):
        print('ERROR: set NFIQ2_SERVICE_URL to the deployed nfiq2 sidecar URL first.')
        sys.exit(1)
    firebase_admin.initialize_app(
        credentials.Certificate(cred_path),
        {'storageBucket': _BUCKET, 'projectId': _PROJECT_ID},
    )
    return firestore.client(), storage.bucket()


def _load_grayscale(bucket, path: str) -> np.ndarray | None:
    try:
        raw = bucket.blob(path).download_as_bytes(timeout=60)
        img = Image.open(io.BytesIO(raw)).convert('L')
        return np.array(img)
    except Exception as e:
        print(f'  ! failed to download/decode {path}: {e}')
        return None


def main():
    db, bucket = _init_firebase()

    docs = list(
        db.collection('captures')
          .where('status', '==', 'scored')
          .stream()
    )
    targets = [d for d in docs if 'nfiq2Score' not in (d.to_dict() or {})]
    print(f'{len(docs)} scored captures total, {len(targets)} missing nfiq2Score.')

    rows = []
    for doc in targets:
        data = doc.to_dict() or {}
        capture_id = doc.id
        image_path = data.get('superprintPath') or data.get('enhancedImagePath')
        proxy_score = data.get('nfiqScore')

        if not image_path:
            print(f'{capture_id}: no superprintPath/enhancedImagePath on doc -- skipping')
            rows.append((capture_id, proxy_score, None, 'no image path on doc'))
            continue

        img = _load_grayscale(bucket, image_path)
        if img is None:
            rows.append((capture_id, proxy_score, None, 'download/decode failed'))
            continue

        nfiq2_score = nfiq2_client.score_nfiq2(img)
        if nfiq2_score is None:
            print(f'{capture_id}: NFIQ2 returned null (sidecar unreachable, timeout, or parse failure -- check sidecar logs)')
            rows.append((capture_id, proxy_score, None, 'sidecar returned null (see its Cloud Run logs)'))
            continue

        doc.reference.update({'nfiq2Score': nfiq2_score})
        delta = round((proxy_score or 0) - nfiq2_score, 1)
        print(f'{capture_id}: proxy={proxy_score}  nfiq2={nfiq2_score}  delta={delta:+}')
        rows.append((capture_id, proxy_score, nfiq2_score, delta))

    print('\n' + '=' * 90)
    print(f'{"Capture ID":<32} {"ResNet18 proxy":>15} {"NFIQ2":>8} {"Delta":>10}  Note')
    print('-' * 90)
    for capture_id, proxy_score, nfiq2_score, delta_or_note in rows:
        if nfiq2_score is None:
            print(f'{capture_id:<32} {str(proxy_score):>15} {"NULL":>8} {"--":>10}  {delta_or_note}')
        else:
            print(f'{capture_id:<32} {str(proxy_score):>15} {nfiq2_score:>8} {delta_or_note:>+10}')
    print('=' * 90)

    deltas = [d for _, _, s, d in rows if s is not None]
    if deltas:
        print(f'\nDelta (proxy - nfiq2): mean={sum(deltas)/len(deltas):+.1f}  '
              f'min={min(deltas):+.1f}  max={max(deltas):+.1f}  n={len(deltas)}')
    null_count = sum(1 for _, _, s, _ in rows if s is None)
    if null_count:
        print(f'{null_count} of {len(rows)} captures got a null NFIQ2 score -- see notes above and the sidecar Cloud Run logs.')


if __name__ == '__main__':
    main()
