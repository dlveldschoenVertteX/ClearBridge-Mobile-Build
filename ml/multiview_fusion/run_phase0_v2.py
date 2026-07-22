"""Phase 0 re-run: does phase-demodulation local correction (phase_align.py
/ local_align.phase_correct) beat both the OLD ECC-only alignment and the
already-NO-GO TPS correction, on the SAME 4 real captures/blend used
throughout Phase 0/1? Three-way comparison, same unchanged blend for all.

Run: python3 run_phase0_v2.py <pulled_captures_dir>
"""
from __future__ import annotations

import json
import os
import sys

import cv2
import numpy as np

from common import ecc_homography_align, coherence_weighted_blend
from continuity_metric import seam_continuity_score
from local_align import tps_correct, phase_correct


def _contributor_mask(front_shape, registered_sides: list[np.ndarray]) -> np.ndarray:
    mask = np.zeros(front_shape, dtype=np.uint8)
    for reg in registered_sides:
        mask |= (reg > 0).astype(np.uint8)
    return mask


def run_one(cap_dir: str) -> dict:
    front = cv2.imread(os.path.join(cap_dir, 'front.png'), cv2.IMREAD_GRAYSCALE)
    side_files = sorted(f for f in os.listdir(cap_dir) if f.startswith('side_'))

    ecc_sides, tps_sides, phase_sides = [], [], []
    tps_diags, phase_diags = [], []
    for sf in side_files:
        side = cv2.imread(os.path.join(cap_dir, sf), cv2.IMREAD_GRAYSCALE)
        aligned = ecc_homography_align(front, side)
        if aligned is None:
            continue
        reg, _ = aligned
        ecc_sides.append(reg)

        tps_result = tps_correct(front, reg)
        if tps_result is None:
            tps_sides.append(reg)
            tps_diags.append({'fallback': True})
        else:
            warped, diag = tps_result
            tps_sides.append(warped)
            tps_diags.append(diag)

        phase_result = phase_correct(front, reg, mask=(reg > 0).astype(np.uint8))
        if phase_result is None:
            phase_sides.append(reg)
            phase_diags.append({'fallback': True})
        else:
            warped, diag = phase_result
            phase_sides.append(warped)
            phase_diags.append(diag)

    if not ecc_sides:
        return {'error': 'no side frames registered (ECC failed on all)'}

    old_composite, n_old = coherence_weighted_blend(front, ecc_sides)
    tps_composite, n_tps = coherence_weighted_blend(front, tps_sides)
    phase_composite, n_phase = coherence_weighted_blend(front, phase_sides)

    old_mask = _contributor_mask(front.shape, ecc_sides)
    tps_mask = _contributor_mask(front.shape, tps_sides)
    phase_mask = _contributor_mask(front.shape, phase_sides)

    old_score = seam_continuity_score(old_composite, old_mask)
    tps_score = seam_continuity_score(tps_composite, tps_mask)
    phase_score = seam_continuity_score(phase_composite, phase_mask)

    cv2.imwrite(os.path.join(cap_dir, 'composite_new_phase.png'), phase_composite)

    return {
        'n_sides_used': n_old,
        'phase_diagnostics': phase_diags,
        'tps_diagnostics': tps_diags,
        'old_ecc_only': old_score,
        'tps_corrected': tps_score,
        'phase_corrected': phase_score,
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

    out_path = os.path.join(pulled_dir, 'phase0_v2_results.json')
    json.dump(results, open(out_path, 'w'), indent=2, default=str)
    print(f'\nWrote {out_path}', flush=True)

    def _ratios(key):
        return [r[key]['ratio'] for r in results.values()
                if isinstance(r, dict) and r.get(key, {}).get('ratio') is not None]

    old_r, tps_r, phase_r = _ratios('old_ecc_only'), _ratios('tps_corrected'), _ratios('phase_corrected')
    print('\nMean seam/control discontinuity ratio (>1 = seam worse than baseline noise):')
    if old_r:
        print(f'  OLD (ECC-only):        {np.mean(old_r):.3f}  (n={len(old_r)})')
    if tps_r:
        print(f'  TPS-corrected (NO-GO):  {np.mean(tps_r):.3f}  (n={len(tps_r)})')
    if phase_r:
        print(f'  PHASE-corrected (new):  {np.mean(phase_r):.3f}  (n={len(phase_r)})')


if __name__ == '__main__':
    main(sys.argv[1])
