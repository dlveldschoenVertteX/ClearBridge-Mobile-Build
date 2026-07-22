"""Phase 2 go/no-go: does the LEARNED pair-deformation net (train_pair.py's
PairDeformFieldUNet checkpoint) improve real front/side alignment where
every classical estimator failed?

Two metrics, most direct first:

1. **Overlap orientation agreement** (new for Phase 2): mean doubled-angle
   ridge-orientation difference between the front and the (ECC-registered,
   optionally net-corrected) side, over pixels where BOTH images have real
   ridge coherence. This is a dense, paired, direct measure of ridge-level
   alignment -- sharper than the seam metric (which lost its control band
   on 2 of 4 captures in Phases 0/1) and measured BEFORE any blending, so
   it isolates alignment quality from compositing choices.

2. **Seam continuity of the blended composite** (same
   `continuity_metric.seam_continuity_score` as Phases 0/1, same unchanged
   `coherence_weighted_blend`), for comparability with the earlier phases.

Run:
    python3 run_phase2.py <pulled_captures_dir> <checkpoint.pt>

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

import json
import os
import sys

import cv2
import numpy as np
import torch

from common import (block_coherence, coherence_weighted_blend,
                    ecc_homography_align, orientation_field)
from continuity_metric import seam_continuity_score
from corr_deform_net import CorrPairDeformNet
from deform_net import PairDeformFieldUNet, PixelWarp

_COH_MIN = 0.35   # both-coherent gate for the orientation-agreement metric


def _pad_to_multiple(img: np.ndarray, m: int = 8) -> tuple[np.ndarray, tuple[int, int]]:
    h, w = img.shape[:2]
    ph, pw = (m - h % m) % m, (m - w % m) % m
    if ph or pw:
        img = cv2.copyMakeBorder(img, 0, ph, 0, pw, cv2.BORDER_REFLECT)
    return img, (h, w)


def _net_correct(model: PairDeformFieldUNet, warp: PixelWarp,
                 front: np.ndarray, reg: np.ndarray) -> tuple[np.ndarray, dict]:
    fp, (h, w) = _pad_to_multiple(front)
    rp, _ = _pad_to_multiple(reg)
    pair = np.stack([fp, rp]).astype(np.float32) / 255.0
    with torch.no_grad():
        t = torch.from_numpy(pair)[None]
        flow = model(t)
        out = warp(t[:, 1:2], flow)[0, 0].numpy()
    flow_np = flow[0].numpy()[:, :h, :w]
    corrected = (np.clip(out[:h, :w], 0, 1) * 255).astype(np.uint8)
    # The side's valid-region boundary must move WITH the flow; re-derive
    # validity from the corrected image rather than warping the mask
    # separately (border-padding keeps invalid zeros zero enough to gate on).
    diag = {'mean_abs_flow_px': float(np.abs(flow_np).mean()),
            'max_abs_flow_px': float(np.abs(flow_np).max())}
    return corrected, diag


def _overlap_orientation_disagreement(front: np.ndarray, side: np.ndarray) -> dict:
    """Mean doubled-angle orientation difference over pixels where both
    images carry real ridge signal. Lower = better ridge-level alignment."""
    valid = side > 0
    coh_f = block_coherence(front)
    coh_s = block_coherence(side)
    gate = valid & (coh_f > _COH_MIN) & (coh_s > _COH_MIN)
    if gate.sum() < 500:
        return {'orient_disagreement': None, 'n_px': int(gate.sum())}
    of = orientation_field(front)
    os_ = orientation_field(side)
    d = np.abs(of - os_)
    d = np.minimum(d, np.pi - d)
    return {'orient_disagreement': float(d[gate].mean()), 'n_px': int(gate.sum())}


def _contributor_mask(shape, sides):
    m = np.zeros(shape, dtype=np.uint8)
    for s in sides:
        m |= (s > 0).astype(np.uint8)
    return m


def run_one(cap_dir: str, model, warp) -> dict:
    front = cv2.imread(os.path.join(cap_dir, 'front.png'), cv2.IMREAD_GRAYSCALE)
    side_files = sorted(f for f in os.listdir(cap_dir) if f.startswith('side_'))

    ecc_sides, net_sides, per_side = [], [], []
    for sf in side_files:
        side = cv2.imread(os.path.join(cap_dir, sf), cv2.IMREAD_GRAYSCALE)
        aligned = ecc_homography_align(front, side)
        if aligned is None:
            continue
        reg, _ = aligned
        corrected, diag = _net_correct(model, warp, front, reg)
        ecc_sides.append(reg)
        net_sides.append(corrected)
        before = _overlap_orientation_disagreement(front, reg)
        after = _overlap_orientation_disagreement(front, corrected)
        per_side.append({'file': sf, **diag,
                         'orient_before': before['orient_disagreement'],
                         'orient_after': after['orient_disagreement']})

    if not ecc_sides:
        return {'error': 'no side frames registered'}

    old_comp, _ = coherence_weighted_blend(front, ecc_sides)
    new_comp, _ = coherence_weighted_blend(front, net_sides)
    old_seam = seam_continuity_score(old_comp, _contributor_mask(front.shape, ecc_sides))
    new_seam = seam_continuity_score(new_comp, _contributor_mask(front.shape, net_sides))
    cv2.imwrite(os.path.join(cap_dir, 'composite_p2_eccOnly.png'), old_comp)
    cv2.imwrite(os.path.join(cap_dir, 'composite_p2_net.png'), new_comp)

    return {'per_side': per_side, 'old_seam': old_seam, 'new_seam': new_seam}


def main(pulled_dir: str, ckpt_path: str) -> None:
    ck = torch.load(ckpt_path, map_location='cpu')
    if ck.get('model_type') == 'corr':
        model = CorrPairDeformNet(base=ck.get('base', 24))
    else:
        model = PairDeformFieldUNet(base=ck.get('base', 24))
    model.load_state_dict(ck['model'])
    model.eval()
    warp = PixelWarp()
    print(f'checkpoint: epoch {ck.get("epoch")}, val EPE {ck.get("val_epe"):.3f} px')

    manifest = json.load(open(os.path.join(pulled_dir, 'manifest.json')))
    results = {}
    ob, oa = [], []
    for entry in manifest:
        cap = entry['captureId'][:8]
        print(f'=== {cap} ===', flush=True)
        r = run_one(os.path.join(pulled_dir, cap), model, warp)
        results[cap] = r
        print(f'  {json.dumps(r, default=str)}', flush=True)
        for s in r.get('per_side', []):
            if s['orient_before'] is not None and s['orient_after'] is not None:
                ob.append(s['orient_before'])
                oa.append(s['orient_after'])

    json.dump(results, open(os.path.join(pulled_dir, 'phase2_results.json'), 'w'),
              indent=2, default=str)
    if ob:
        ob, oa = np.array(ob), np.array(oa)
        print(f'\nOverlap orientation disagreement (rad, lower=better), '
              f'n={len(ob)} real side frames:')
        print(f'  ECC-only:       {ob.mean():.4f}')
        print(f'  net-corrected:  {oa.mean():.4f}   '
              f'(improved on {(oa < ob).sum()}/{len(ob)} frames)')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
