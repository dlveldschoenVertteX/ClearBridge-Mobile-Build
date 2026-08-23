"""Build the training manifest: a flat JSON list of relative paths to real
binarized front prints (this project's own production superprintPath
images -- see README.md for how they were pulled from Firestore/Storage).

    python build_manifest.py --root data/real_prints --out manifest.json

Mirrors ml/deform_correct/build_synth_manifest.py's own {"clean": relpath}
shape closely enough to be a familiar pattern, but simplified to a bare
relpath list since this module's dataset.py reads the directory directly
(make_splits globs *.png) -- the manifest here exists mainly for the
SageMaker launch path, where the 'images' data channel needs a known,
uploaded file list to validate against before spending anything.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='data/real_prints')
    ap.add_argument('--out', default='manifest.json')
    args = ap.parse_args()

    root = Path(args.root)
    paths = sorted(p.name for p in root.glob('*.png'))
    if not paths:
        raise SystemExit(f'no .png files found under {root}')
    with open(args.out, 'w') as f:
        json.dump(paths, f, indent=1)
    print(f'wrote {len(paths)} entries to {args.out}')


if __name__ == '__main__':
    main()
