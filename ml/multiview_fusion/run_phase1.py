"""Phase 1 go/no-go: does seam-routed compositing (front-anchored, narrow-
band feathered -- see seam_composite.py) reduce seam ridge-discontinuity vs.
the OLD whole-frame coherence-weighted blend, on the SAME ECC-only-aligned
real captures Phase 0 used? Local-TPS correction is a confirmed dead end
(README.md) so both arms here use ECC-only alignment -- the one variable
under test is the BLEND/COMPOSITE step itself.

Run: python3 run_phase1.py <pulled_captures_dir>
"""
from __future__ import annotations

import json
import os
import sys

import cv2
import numpy as np

from common import ecc_homography_align, coherence_weighted_blend
from continuity_metric import seam_continuity_score
from seam_composite import seam_composite


def _contributor_mask(front_shape, registered_sides: list[np.ndarray]) -> np.ndarray:
    mask = np.zeros(front_shape, dtype=np.uint8)
    for reg in registered_sides:
        mask |= (reg > 0).astype(np.uint8)
    return mask


def run_one(cap_dir: str) -> dict:
    front = cv2.imread(os.path.join(cap_dir, 'front.png'), cv2.IMREAD_GRAYSCALE)
    side_files = sorted(f for f in os.listdir(cap_dir) if f.startswith('side_'))

    ecc_sides = []
    for sf in side_files:
        side = cv2.imread(os.path.join(cap_dir, sf), cv2.IMREAD_GRAYSCALE)
        aligned = ecc_homography_align(front, side)
        if aligned is None:
            continue
        reg, _ = aligned
        ecc_sides.append(reg)

    if not ecc_sides:
        return {'error': 'no side frames registered (ECC failed on all)'}

    old_composite, n_old = coherence_weighted_blend(front, ecc_sides)
    if old_composite is None:
        return {'error': 'old blend failed'}
    old_mask = _contributor_mask(front.shape, ecc_sides)
    old_score = seam_continuity_score(old_composite, old_mask)

    new_composite, new_mask, n_new = seam_composite(front, ecc_sides)
    if new_composite is None:
        new_score = {'seam_discontinuity': None, 'control_discontinuity': None,
                     'ratio': None, 'note': 'seam_composite found no region worth substituting'}
    else:
        new_score = seam_continuity_score(new_composite, new_mask)

    cv2.imwrite(os.path.join(cap_dir, 'composite_old_blend.png'), old_composite)
    if new_composite is not None:
        cv2.imwrite(os.path.join(cap_dir, 'composite_new_seam.png'), new_composite)

    return {
        'n_sides_used_old': n_old,
        'n_sides_used_new': n_new,
        'old_blend': old_score,
        'new_seam': new_score,
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

    out_path = os.path.join(pulled_dir, 'phase1_results.json')
    json.dump(results, open(out_path, 'w'), indent=2, default=str)
    print(f'\nWrote {out_path}', flush=True)

    old_ratios = [r['old_blend']['ratio'] for r in results.values()
                  if isinstance(r, dict) and r.get('old_blend', {}).get('ratio') is not None]
    new_ratios = [r['new_seam']['ratio'] for r in results.values()
                  if isinstance(r, dict) and r.get('new_seam', {}).get('ratio') is not None]
    print('\nMean seam/control discontinuity ratio (>1 = seam worse than baseline noise):')
    if old_ratios:
        print(f'  OLD (coherence-weighted blend): {np.mean(old_ratios):.2f}  (n={len(old_ratios)})')
    if new_ratios:
        print(f'  NEW (seam-routed composite):    {np.mean(new_ratios):.2f}  (n={len(new_ratios)})')

    # Paired comparison -- only over captures where BOTH arms produced a
    # valid ratio, same discipline as Phase 0's own honest reporting.
    paired = [(r['old_blend']['ratio'], r['new_seam']['ratio']) for r in results.values()
              if isinstance(r, dict) and r.get('old_blend', {}).get('ratio') is not None
              and r.get('new_seam', {}).get('ratio') is not None]
    if paired:
        old_p = np.array([p[0] for p in paired])
        new_p = np.array([p[1] for p in paired])
        print(f'\nPaired (n={len(paired)}): OLD mean={old_p.mean():.2f}  NEW mean={new_p.mean():.2f}  '
              f'NEW better in {(new_p < old_p).sum()}/{len(paired)}')


if __name__ == '__main__':
    main(sys.argv[1])
