"""Fidelity benchmark: score OUR pipeline's contactless->contact matchability
on a real paired dataset, and quantify matcher-based variant selection.

Pipeline (runs only when a dataset --root is given):
  1. ingest.py indexes the dataset into contactless probes + contact gallery.
  2. For each image, afis_print.generate() produces the AFIS print. For probes
     we generate under SEVERAL variants (incl. the geom/fidelity scaffolds) so
     we can compare selection strategies.
  3. SourceAFIS (the Java harness in scratchpad/sourceafis, via a TSV manifest)
     extracts templates and scores every probe-print against every gallery
     print.
  4. metrics.py computes genuine/impostor separation (EER, TAR@FAR, d').

Selection strategies compared (the "matcher-based selection" deliverable):
  - nfiq2   : pick each probe's variant by highest real NFIQ2 (today's prod).
  - minutiae: pick by mindtct reliable-minutiae count (a matcher-oriented
              proxy deployable in production — no gallery needed).
  - oracle  : pick the variant that maximises that probe's genuine score
              (upper bound; not deployable, measures headroom).
The gap oracle-vs-nfiq2 is how much matchability today's NFIQ2 selection leaves
on the table; minutiae-vs-nfiq2 is how much a deployable proxy recovers.

This module's metric core (`separation_metrics`, `select_variant`) is unit-
tested via --selftest with NO dataset and NO Java needed, so it can be committed
and verified now. Full end-to-end needs the dataset + the SourceAFIS harness.
"""
from __future__ import annotations

import argparse
import math
import sys
from typing import Dict, List, Tuple, Callable


# ---- metric core (pure, unit-tested) ----------------------------------------

def separation_metrics(genuine: List[float], impostor: List[float]) -> Dict[str, float]:
    """Standard verification metrics from genuine/impostor score lists
    (higher score = more similar). Returns EER, TAR at a few FARs, and d'."""
    if not genuine or not impostor:
        return {'eer': float('nan'), 'dprime': float('nan')}
    g = sorted(genuine)
    im = sorted(impostor)

    def far_at(th: float) -> float:
        return sum(1 for s in im if s >= th) / len(im)

    def frr_at(th: float) -> float:
        return sum(1 for s in g if s < th) / len(g)

    # EER: scan thresholds (FAR is non-increasing, FRR non-decreasing in th);
    # take the point where they cross, reporting the average of FAR/FRR there.
    thresholds = sorted(set(g + im))
    eer = 0.5
    prev = None
    for th in thresholds:
        far, frr = far_at(th), frr_at(th)
        if far <= frr:
            eer = (far + frr) / 2 if prev is None else min((far + frr) / 2, prev)
            break
        prev = (far + frr) / 2

    def tar_at_far(target_far: float) -> float:
        # highest TAR (=1-FRR) achievable while FAR <= target
        ok = [th for th in thresholds if far_at(th) <= target_far]
        if not ok:
            return 0.0
        th = min(ok)              # lowest threshold meeting the FAR budget
        return 1.0 - frr_at(th)

    mg, mi = _mean(g), _mean(im)
    vg, vi = _var(g, mg), _var(im, mi)
    dprime = abs(mg - mi) / math.sqrt(0.5 * (vg + vi) + 1e-9)
    return {
        'eer': round(eer, 4),
        'tar@far1e-2': round(tar_at_far(1e-2), 4),
        'tar@far1e-3': round(tar_at_far(1e-3), 4),
        'dprime': round(dprime, 3),
        'genuine_mean': round(mg, 2),
        'impostor_mean': round(mi, 2),
        'n_genuine': len(g),
        'n_impostor': len(im),
    }


def _mean(xs: List[float]) -> float:
    return sum(xs) / len(xs)


def _var(xs: List[float], m: float) -> float:
    return sum((x - m) ** 2 for x in xs) / max(len(xs) - 1, 1)


def select_variant(per_variant: Dict[str, Dict[str, float]], strategy: str) -> str:
    """Choose one variant name for a probe.
    per_variant: {variant_name: {'nfiq2':.., 'minutiae':.., 'genuine':..}}.
    strategy: 'nfiq2' | 'minutiae' | 'oracle'.
    """
    key = {'nfiq2': 'nfiq2', 'minutiae': 'minutiae', 'oracle': 'genuine'}[strategy]
    return max(per_variant, key=lambda v: per_variant[v].get(key, float('-inf')))


# ---- selftest ---------------------------------------------------------------

def _selftest() -> int:
    # Perfectly separable: genuine all high, impostor all low => EER ~0, d' large
    m = separation_metrics([80, 75, 90, 85], [3, 1, 4, 2])
    assert m['eer'] <= 0.01, m
    assert m['dprime'] > 3, m
    assert m['tar@far1e-2'] >= 0.99, m

    # Fully overlapping => EER ~0.5, d' ~0
    import random
    random.seed(0)
    g = [random.gauss(10, 3) for _ in range(500)]
    im = [random.gauss(10, 3) for _ in range(500)]
    m2 = separation_metrics(g, im)
    assert 0.4 <= m2['eer'] <= 0.6, m2
    assert m2['dprime'] < 0.3, m2

    # Selection strategies pick the right variant
    pv = {
        'A': {'nfiq2': 80, 'minutiae': 12, 'genuine': 5},
        'B': {'nfiq2': 60, 'minutiae': 40, 'genuine': 55},   # true best match
    }
    assert select_variant(pv, 'nfiq2') == 'A'      # NFIQ2 picks the wrong one
    assert select_variant(pv, 'minutiae') == 'B'   # minutiae proxy recovers it
    assert select_variant(pv, 'oracle') == 'B'
    print('SELFTEST PASSED (metrics + selection)')
    return 0


def _run(root: str, layout: str) -> int:
    # End-to-end path — requires the dataset and the SourceAFIS harness. Kept
    # thin on purpose: the heavy lifting (generate variants, run SourceAFIS)
    # reuses scratchpad/harness.py + scratchpad/sourceafis. Wired here as the
    # single entry point to run once real data lands.
    try:
        import ingest
    except ImportError:
        from ml.fidelity_benchmark import ingest  # type: ignore
    recs = ingest.index_dataset(root, layout)
    print('dataset summary:', ingest.summarize(recs))
    gen_pairs, imp_pairs = ingest.genuine_impostor_pairs(recs)
    print(f'genuine pairs={len(gen_pairs)} impostor pairs={len(imp_pairs)}')
    print('NOTE: full scoring needs the SourceAFIS harness (scratchpad/sourceafis)'
          ' and afis_print on PYTHONPATH; this entry point indexes + pairs only.'
          ' Wire generate()+SourceAFIS here when running on real data.')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root')
    ap.add_argument('--layout', default='auto')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest or not a.root:
        return _selftest()
    return _run(a.root, a.layout)


if __name__ == '__main__':
    sys.exit(main())
