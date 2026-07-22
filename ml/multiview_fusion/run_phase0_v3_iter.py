"""Follow-up to run_phase0_v2.py: does ITERATING phase_correct (re-estimate
the residual on the already-corrected image, repeat) close the gap, since a
single pass left seam continuity mildly worse than ECC-only on both real
paired-comparison captures? Same 4 real captures, same unchanged blend.

Run: python3 run_phase0_v3_iter.py <pulled_captures_dir> [n_iters]
"""
from __future__ import annotations

import json
import os
import sys

import cv2
import numpy as np

from common import ecc_homography_align, coherence_weighted_blend
from continuity_metric import seam_continuity_score
from local_align import phase_correct


def _contributor_mask(front_shape, registered_sides: list[np.ndarray]) -> np.ndarray:
    mask = np.zeros(front_shape, dtype=np.uint8)
    for reg in registered_sides:
        mask |= (reg > 0).astype(np.uint8)
    return mask


def run_one(cap_dir: str, n_iters: int) -> dict:
    front = cv2.imread(os.path.join(cap_dir, 'front.png'), cv2.IMREAD_GRAYSCALE)
    side_files = sorted(f for f in os.listdir(cap_dir) if f.startswith('side_'))

    ecc_sides, phase_sides = [], []
    iter_diags = []
    for sf in side_files:
        side = cv2.imread(os.path.join(cap_dir, sf), cv2.IMREAD_GRAYSCALE)
        aligned = ecc_homography_align(front, side)
        if aligned is None:
            continue
        reg, _ = aligned
        ecc_sides.append(reg)

        cur = reg
        diags = []
        for _ in range(n_iters):
            r = phase_correct(front, cur, mask=(cur > 0).astype(np.uint8))
            if r is None:
                break
            cur, diag = r
            diags.append(diag)
        phase_sides.append(cur)
        iter_diags.append(diags)

    if not ecc_sides:
        return {'error': 'no side frames registered'}

    old_composite, _ = coherence_weighted_blend(front, ecc_sides)
    phase_composite, _ = coherence_weighted_blend(front, phase_sides)

    old_mask = _contributor_mask(front.shape, ecc_sides)
    phase_mask = _contributor_mask(front.shape, phase_sides)

    old_score = seam_continuity_score(old_composite, old_mask)
    phase_score = seam_continuity_score(phase_composite, phase_mask)

    return {
        'n_iters': n_iters,
        'iter_diagnostics': iter_diags,
        'old_ecc_only': old_score,
        'phase_corrected_iterative': phase_score,
    }


def main(pulled_dir: str, n_iters: int) -> None:
    manifest = json.load(open(os.path.join(pulled_dir, 'manifest.json')))
    results = {}
    for entry in manifest:
        cap_short = entry['captureId'][:8]
        cap_dir = os.path.join(pulled_dir, cap_short)
        print(f'=== {cap_short} (nfiq2={entry.get("nfiq2Score")}) ===', flush=True)
        r = run_one(cap_dir, n_iters)
        results[cap_short] = r
        print(f'  {json.dumps(r, default=str)}', flush=True)

    out_path = os.path.join(pulled_dir, f'phase0_v3_iter{n_iters}_results.json')
    json.dump(results, open(out_path, 'w'), indent=2, default=str)
    print(f'\nWrote {out_path}', flush=True)

    old_r = [r['old_ecc_only']['ratio'] for r in results.values()
             if isinstance(r, dict) and r.get('old_ecc_only', {}).get('ratio') is not None]
    new_r = [r['phase_corrected_iterative']['ratio'] for r in results.values()
             if isinstance(r, dict) and r.get('phase_corrected_iterative', {}).get('ratio') is not None]
    print(f'\nMean ratio (n_iters={n_iters}):')
    if old_r:
        print(f'  OLD (ECC-only):             {np.mean(old_r):.3f}  (n={len(old_r)})')
    if new_r:
        print(f'  PHASE-corrected (iterative): {np.mean(new_r):.3f}  (n={len(new_r)})')


if __name__ == '__main__':
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3)
