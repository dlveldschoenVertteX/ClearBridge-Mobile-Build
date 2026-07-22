"""Sample raw SD302f rig photos from S3, crop+quality-gate each to a real
fingertip via sd302f_crop.py, and emit a synth-mode manifest
({'clean': relpath} per accepted crop, same contract as
build_synth_manifest.py) -- the domain-closest-to-MAC3D alternative source
for dataset.py's SynthDeformDataset, per the CTO's "closest to MAC3D domain"
framing (SD302f is photographed contactless skin; SD302a/b/d are clean
contact-scanner prints).

Downloads one raw JPG at a time and deletes it immediately after cropping
(each is ~5MB; the crop kept is <1MB) to bound local disk usage regardless
of sample size. Samples across as many distinct participants/finger-slots as
possible rather than the first N keys, for real subject diversity.

Usage:
    python3 build_sd302f_manifest.py --bucket <bucket> --profile clearbridge \
        --region af-south-1 --n-per-slot 2 --out-dir sd302f_crops --out sd302f_manifest.json
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import time
from collections import defaultdict

import boto3
import cv2
import numpy as np
from PIL import Image

from sd302f_crop import crop_and_gate


def _download_with_retry(s3, bucket: str, key: str, dest: str, attempts: int = 4) -> bool:
    """S3 downloads in this environment go through an agent proxy that can
    hit transient connection errors under sustained sequential traffic
    (observed: botocore.exceptions.ProxyConnectionError partway through a
    ~2000-file run). Retry with exponential backoff rather than letting one
    transient failure kill the whole batch."""
    for attempt in range(attempts):
        try:
            s3.download_file(bucket, key, dest)
            return True
        except Exception as e:
            if attempt == attempts - 1:
                print(f'  ! giving up on {key} after {attempts} attempts: {e}', flush=True)
                return False
            wait = 2 ** attempt
            print(f'  ! download error on {key} (attempt {attempt + 1}/{attempts}): {e} '
                  f'-- retrying in {wait}s', flush=True)
            time.sleep(wait)
    return False

_PREFIX = 'sd302/extracted/SD302f/images/auxiliary/photograph/'
_KEY_RE = re.compile(r'/jpg/(\d+)/([^/]+)/')


def _list_keys(s3, bucket: str) -> list[str]:
    paginator = s3.get_paginator('list_objects_v2')
    keys = []
    for page in paginator.paginate(Bucket=bucket, Prefix=_PREFIX):
        for o in page.get('Contents', []):
            if o['Key'].endswith('.jpg'):
                keys.append(o['Key'])
    return keys


def _sample_keys(keys: list[str], n_per_slot: int, seed: int = 0) -> list[str]:
    """Group by (participant, finger-slot), take up to n_per_slot images per
    group (spread across shot indices via sorted-then-strided pick, not just
    the first N which would cluster on one rig camera angle), for real
    subject + shot diversity rather than raw volume from a few subjects."""
    groups: dict[tuple[str, str], list[str]] = defaultdict(list)
    for k in keys:
        m = _KEY_RE.search(k)
        if not m:
            continue
        groups[(m.group(1), m.group(2))].append(k)
    rng = np.random.default_rng(seed)
    sampled = []
    for key_tuple in sorted(groups):
        group_keys = sorted(groups[key_tuple])
        if len(group_keys) <= n_per_slot:
            sampled.extend(group_keys)
        else:
            idx = rng.choice(len(group_keys), size=n_per_slot, replace=False)
            sampled.extend(group_keys[i] for i in sorted(idx))
    return sampled


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--bucket', required=True)
    ap.add_argument('--profile', default='clearbridge')
    ap.add_argument('--region', default='af-south-1')
    ap.add_argument('--n-per-slot', type=int, default=2,
                     help='max raw images sampled per (participant, finger-slot) group')
    ap.add_argument('--out-dir', default='sd302f_crops')
    ap.add_argument('--out', default='sd302f_manifest.json')
    ap.add_argument('--tmp', default='/tmp/sd302f_raw_scratch.jpg')
    a = ap.parse_args()

    session = boto3.Session(profile_name=a.profile, region_name=a.region)
    s3 = session.client('s3')

    print('listing SD302f raw keys...', flush=True)
    keys = _list_keys(s3, a.bucket)
    print(f'{len(keys)} total raw jpgs found', flush=True)

    sample = _sample_keys(keys, a.n_per_slot)
    print(f'sampling {len(sample)} raw images '
          f'(<= {a.n_per_slot} per participant/finger-slot group)', flush=True)

    os.makedirs(a.out_dir, exist_ok=True)
    n_ok, n_fail = 0, 0
    recs = []
    for i, key in enumerate(sample):
        img = None
        try:
            if _download_with_retry(s3, a.bucket, key, a.tmp):
                img = cv2.imread(a.tmp, cv2.IMREAD_COLOR)
        finally:
            if os.path.exists(a.tmp):
                os.remove(a.tmp)  # bound disk usage regardless of pass/fail
        if img is None:
            n_fail += 1
            continue
        crop = crop_and_gate(img)
        if crop is None:
            n_fail += 1
        else:
            base = os.path.splitext(os.path.basename(key))[0]
            out_name = f'{base}.png'
            cv2.imwrite(os.path.join(a.out_dir, out_name), crop)
            recs.append({'clean': out_name})
            n_ok += 1
        if (i + 1) % 100 == 0:
            print(f'  {i + 1}/{len(sample)} processed -- ok={n_ok} fail={n_fail}', flush=True)
            json.dump(recs, open(a.out, 'w'), indent=1)  # checkpoint so a crash doesn't lose progress

    json.dump(recs, open(a.out, 'w'), indent=1)
    print(f'\nDONE: ok={n_ok} fail={n_fail} ({100 * n_ok / max(1, n_ok + n_fail):.1f}% pass rate)')
    print(f'crops -> {a.out_dir}/  manifest -> {a.out} ({len(recs)} entries)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
