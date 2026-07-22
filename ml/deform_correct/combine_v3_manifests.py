"""Combine the SD302f-crop manifest and the real-MAC3D-clean manifest into
one synth-mode manifest + a single staged data directory (relative paths
prefixed by source, so dataset.py's single --data-root sees both), for the
v3 training run: SD302f (domain-closest public source, larger volume) +
real MAC3D captures (the actual target domain, small n but highest value
per image) as clean sources for the same self-supervised synthetic-
distortion pipeline. a/b/d volume alone was already tried (v2) and did not
beat v1 on the real gate -- see CLAUDE.md 2026-07-18 -- so this run
deliberately does NOT re-include a/b/d; it isolates the NEW variable
(domain match) instead of repeating the already-negative volume lever.

Usage:
    python3 combine_v3_manifests.py \
        --sd302f-dir /tmp/sd302f_crops --sd302f-manifest /tmp/sd302f_manifest.json \
        --mac3d-dir /tmp/mac3d_clean --mac3d-manifest /tmp/mac3d_manifest.json \
        --out-dir /tmp/deform_v3_data --out /tmp/deform_v3_manifest.json
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--sd302f-dir', required=True)
    ap.add_argument('--sd302f-manifest', required=True)
    ap.add_argument('--mac3d-dir', required=True)
    ap.add_argument('--mac3d-manifest', required=True)
    ap.add_argument('--out-dir', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    os.makedirs(os.path.join(a.out_dir, 'sd302f'), exist_ok=True)
    os.makedirs(os.path.join(a.out_dir, 'mac3d'), exist_ok=True)

    combined = []
    sd302f_recs = json.load(open(a.sd302f_manifest))
    for r in sd302f_recs:
        src = os.path.join(a.sd302f_dir, r['clean'])
        dst_rel = f"sd302f/{r['clean']}"
        shutil.copy(src, os.path.join(a.out_dir, dst_rel))
        combined.append({'clean': dst_rel})

    mac3d_recs = json.load(open(a.mac3d_manifest))
    for r in mac3d_recs:
        src = os.path.join(a.mac3d_dir, r['clean'])
        dst_rel = f"mac3d/{r['clean']}"
        shutil.copy(src, os.path.join(a.out_dir, dst_rel))
        combined.append({'clean': dst_rel})

    json.dump(combined, open(a.out, 'w'), indent=1)
    print(f'combined: {len(sd302f_recs)} sd302f + {len(mac3d_recs)} mac3d '
          f'= {len(combined)} total clean prints')
    print(f'staged data -> {a.out_dir}/  manifest -> {a.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
