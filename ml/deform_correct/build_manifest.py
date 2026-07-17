"""Build a training-pairs manifest from any dataset ingest.py can index
(sd302, ridgebase, generic). Thin wrapper -- ALL the real parsing/pairing
logic lives in ml/fidelity_benchmark/ingest.py (index_dataset,
genuine_impostor_pairs), reused here rather than duplicated, so the
benchmark harness and this training pipeline never disagree about what
counts as a genuine (same-finger) pair.

Usage:
    python build_manifest.py --root /path/to/sd302 --layout sd302 \
        --out manifest.json
    python build_manifest.py --selftest   # no dataset needed
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'fidelity_benchmark'))
import ingest  # noqa: E402


def build(root: str, layout: str = 'auto', max_pairs: int | None = None) -> list[dict]:
    """Returns a list of {'probe': path, 'gallery': path, 'finger_key': str}
    dicts -- one entry per genuine (same-finger) contactless/contact pair.
    Multiple gallery impressions of the same probe (e.g. SD 302's rolled AND
    slap baselines for one finger) each contribute a separate training pair —
    intentional: it's real additional supervision, not a duplicate.

    Paths are stored RELATIVE to `root`, deliberately -- NOT absolute local
    paths. This manifest is meant to travel: built once locally (or wherever
    the dataset lives), then the SAME manifest.json is used against wherever
    the actual image files get mounted next (e.g. a SageMaker 'images'
    data channel at /opt/ml/input/data/images/, a different path than
    whatever --root was on the machine that built the manifest). dataset.py
    joins these against a separately-supplied data_root at load time -- see
    train.py's --data-root."""
    records = ingest.index_dataset(root, layout)
    genuine, _impostor = ingest.genuine_impostor_pairs(records)
    if max_pairs is not None:
        genuine = genuine[:max_pairs]
    return [
        {
            'probe': os.path.relpath(p.path, root),
            'gallery': os.path.relpath(g.path, root),
            'finger_key': p.finger_key,
        }
        for p, g in genuine
    ]


def _selftest() -> int:
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as d:
        for rel in [
            '00001234/SD302a/00001234_01_00.png',
            '00001234/SD302f/00001234_01_00.jpg',
            '00005678/SD302a/00005678_01_00.png',
            '00005678/SD302f/00005678_01_00.jpg',
        ]:
            fp = Path(d) / rel
            fp.parent.mkdir(parents=True, exist_ok=True)
            fp.write_bytes(b'\xff\xd8\xff' if rel.endswith('.jpg') else b'\x89PNG\r\n')
        pairs = build(d, 'sd302')
        assert len(pairs) == 2, pairs
        assert all('probe' in p and 'gallery' in p for p in pairs), pairs
        # Paths must be relative (portable across machines/containers), and
        # must actually resolve when joined back against root.
        for p in pairs:
            assert not os.path.isabs(p['probe']), p
            assert not os.path.isabs(p['gallery']), p
            assert os.path.isfile(os.path.join(d, p['probe'])), p
            assert os.path.isfile(os.path.join(d, p['gallery'])), p
        print('build_manifest selftest: OK', pairs)
    print('SELFTEST PASSED')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root')
    ap.add_argument('--layout', default='auto')
    ap.add_argument('--out', default='manifest.json')
    ap.add_argument('--max-pairs', type=int, default=None)
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest or not a.root:
        return _selftest()
    pairs = build(a.root, a.layout, a.max_pairs)
    with open(a.out, 'w') as f:
        json.dump(pairs, f, indent=1)
    print(f'wrote {len(pairs)} pairs to {a.out}')
    if not pairs:
        print('WARNING: zero pairs found -- check --layout matches the real '
              'folder structure (run ingest.py directly against --root first '
              'to sanity-check subject/finger/modality counts before trusting '
              'this manifest).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
