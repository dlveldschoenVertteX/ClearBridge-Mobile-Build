"""Pull real MAC3D `enhancedImagePath` (continuous-tone, pre-binarization)
prints from Firestore/Storage to use as a THIRD clean-source pool for
dataset.py's SynthDeformDataset -- the actual target domain itself, not
just "closest to" it (the CTO's own follow-up: the SD302f contactless-photo
source is a domain proxy, but real MAC3D captures already sitting in
Firestore are the literal thing). Small (dozens, not thousands) but the
highest-value examples per-image of any source tried for this pipeline.

Continuous-tone `enhancedImagePath` chosen over the binarized AFIS
`superprintPath` as the "clean" source: synth_contactless's distortion +
photometric jitter is applied to a natural-looking print, and a hard
black/white binarized template is a less realistic starting point for that
than a continuous-tone image (same reasoning as this project's own
`afis_print.py` history noting the binarized template is a lossy,
already-processed representation).

Usage:
    GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json python3 pull_mac3d_clean.py \
        --out-dir mac3d_clean --out mac3d_manifest.json
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys

import firebase_admin
from firebase_admin import credentials, firestore, storage
import numpy as np
from PIL import Image

_PROJECT_ID = 'clearbridge-dc699'
_BUCKET = 'clearbridge-dc699.firebasestorage.app'


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--out-dir', default='mac3d_clean')
    ap.add_argument('--out', default='mac3d_manifest.json')
    a = ap.parse_args()

    cred_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
    if not cred_path:
        print('ERROR: set GOOGLE_APPLICATION_CREDENTIALS first.', file=sys.stderr)
        return 1

    firebase_admin.initialize_app(
        credentials.Certificate(cred_path),
        {'storageBucket': _BUCKET, 'projectId': _PROJECT_ID},
    )
    db = firestore.client()
    bucket = storage.bucket()

    docs = list(db.collection('captures').where('status', '==', 'scored').stream())
    print(f'{len(docs)} scored captures total', flush=True)

    os.makedirs(a.out_dir, exist_ok=True)
    recs = []
    n_ok, n_fail = 0, 0
    for d in docs:
        data = d.to_dict() or {}
        path = data.get('enhancedImagePath')
        if not path:
            continue
        try:
            raw = bucket.blob(path).download_as_bytes(timeout=60)
            img = Image.open(io.BytesIO(raw)).convert('L')
        except Exception as e:
            print(f'  ! failed {d.id}: {e}', file=sys.stderr)
            n_fail += 1
            continue
        out_name = f'{d.id}.png'
        img.save(os.path.join(a.out_dir, out_name))
        recs.append({'clean': out_name})
        n_ok += 1

    json.dump(recs, open(a.out, 'w'), indent=1)
    print(f'\nDONE: ok={n_ok} fail={n_fail}')
    print(f'images -> {a.out_dir}/  manifest -> {a.out} ({len(recs)} entries)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
