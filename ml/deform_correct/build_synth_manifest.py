"""Build a synth-mode manifest: a JSON list of {'clean': relpath} for clean
contact prints (SD302a/b/d) to use as self-supervised training source. Paths
are relative to a data root, same portability contract as build_manifest.py.

Usage:
    python build_synth_manifest.py --root /path/to/prints --out synth.json
    python build_synth_manifest.py --root ... --glob '*.png' --out synth.json
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys


def build(root: str, pattern: str = '**/*.png') -> list[dict]:
    files = glob.glob(os.path.join(root, pattern), recursive=True)
    return [{'clean': os.path.relpath(f, root)} for f in sorted(files)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--glob', default='**/*.png')
    ap.add_argument('--out', default='synth_manifest.json')
    a = ap.parse_args()
    recs = build(a.root, a.glob)
    json.dump(recs, open(a.out, 'w'), indent=1)
    print(f'wrote {len(recs)} clean prints -> {a.out}')
    if not recs:
        print('WARNING: zero prints found -- check --root and --glob')
    return 0


if __name__ == '__main__':
    sys.exit(main())
