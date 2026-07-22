"""Phase 0 go/no-go test: does local TPS correction (on top of the existing
ECC/homography coarse alignment) measurably reduce seam ridge-discontinuity
vs. the OLD ECC-only alignment, when both feed the SAME unchanged blend
(common.coherence_weighted_blend)? Isolates the one variable under test.

Run: python3 run_phase0.py <pulled_captures_dir>
"""
from __future__ import annotations

import json
import os
import sys

import cv2
import numpy as np

from common import ecc_homography_align, coherence_weighted_blend
from continuity_metric import seam_continuity_score
from local_align import tps_correct


def _contributor_mask(front_shape, registered_sides: list[np.ndarray]) -> np.ndarray:
    """Nonzero wherever ANY registered side frame has valid (nonzero)
    content -- i.e. the region a real fusion could have borrowed from,
    regardless of how the blend weights it."""
    mask = np.zeros(front_shape, dtype=np.uint8)
    for reg in registered_sides:
        mask |= (reg > 0).astype(np.uint8)
    return mask


def run_one(cap_dir: str) -> dict:
    front = cv2.imread(os.path.join(cap_dir, 'front.png'), cv2.IMREAD_GRAYSCALE)
    manifest_path = os.path.join(cap_dir, '..', 'manifest.json')
    side_files = sorted(f for f in os.listdir(cap_dir) if f.startswith('side_'))

    ecc_only_sides = []
    tps_sides = []
    tps_diags = []
    for sf in side_files:
        side = cv2.imread(os.path.join(cap_dir, sf), cv2.IMREAD_GRAYSCALE)
        aligned = ecc_homography_align(front, side)
        if aligned is None:
            continue
        reg, _ = aligned
        ecc_only_sides.append(reg)

        tps_result = tps_correct(front, reg)
        if tps_result is None:
            tps_sides.append(reg)  # fall back to ECC-only, same as production would
            tps_diags.append({'fallback': True})
        else:
            warped, diag = tps_result
            tps_sides.append(warped)
            tps_diags.append(diag)

    if not ecc_only_sides:
        return {'error': 'no side frames registered (ECC failed on all)'}

    old_composite, n_old = coherence_weighted_blend(front, ecc_only_sides)
    new_composite, n_new = coherence_weighted_blend(front, tps_sides)
    if old_composite is None or new_composite is None:
        return {'error': 'blend failed'}

    old_mask = _contributor_mask(front.shape, ecc_only_sides)
    new_mask = _contributor_mask(front.shape, tps_sides)

    old_score = seam_continuity_score(old_composite, old_mask)
    new_score = seam_continuity_score(new_composite, new_mask)

    cv2.imwrite(os.path.join(cap_dir, 'composite_old_eccOnly.png'), old_composite)
    cv2.imwrite(os.path.join(cap_dir, 'composite_new_tps.png'), new_composite)

    return {
        'n_sides_used': n_old,
        'tps_diagnostics': tps_diags,
        'old_ecc_only': old_score,
        'new_tps_corrected': new_score,
    }


def main(pulled_dir: str) -> None:
    manifest = json.load(open(os.path.join(pulled_dir, 'manifest.json')))
    results = {}
    for entry in manifest:
        cap_short = entry['captureId'][:8]
        cap_dir = os.path.join(pulled_dir, cap_short)
        print(f'=== {cap_short} (nfiq2={entry.get("nfiq2Score")}) ===', flush=True)
        r = run_one(cap_dir)
        results[cap_short] = r
        print(f'  {json.dumps(r, default=str)}', flush=True)

    out_path = os.path.join(pulled_dir, 'phase0_results.json')
    json.dump(results, open(out_path, 'w'), indent=2, default=str)
    print(f'\nWrote {out_path}', flush=True)

    # Summary
    old_ratios = [r['old_ecc_only']['ratio'] for r in results.values()
                  if isinstance(r, dict) and r.get('old_ecc_only', {}).get('ratio') is not None]
    new_ratios = [r['new_tps_corrected']['ratio'] for r in results.values()
                  if isinstance(r, dict) and r.get('new_tps_corrected', {}).get('ratio') is not None]
    if old_ratios and new_ratios:
        print(f'\nMean seam/control discontinuity ratio (>1 = seam worse than baseline noise):')
        print(f'  OLD (ECC-only alignment):  {np.mean(old_ratios):.2f}  (n={len(old_ratios)})')
        print(f'  NEW (TPS-corrected):       {np.mean(new_ratios):.2f}  (n={len(new_ratios)})')


if __name__ == '__main__':
    main(sys.argv[1])
