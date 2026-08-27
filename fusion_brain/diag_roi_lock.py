"""DIAGNOSTIC -- how much of the guide region is NOT thumb pad, and can a
flash-free signal find it?

Direct CTO report (2026-08-27): "the real thumbprint is not always being
given the ROI ... the thumbprint needs to occupy all the enhancement
budget, no background at all, even when there is no flash diff."

Established before this ran, from real code + real data this session:
  * `_flash_diff_mask` needs an ambient/flash PAIR and a flash frame above
    `_FLASH_DIFF_MIN_FLASH_LAPLACIAN` (50.0). Measured on capture
    6b43c255: the ANCHOR's flash frame scores 26.1 -> correctly rejected.
    Only 2 of 6 sources on that capture engage at all.
  * `_unet_mask` is the only fallback, and on that same capture it returns
    a region with ZERO pixel overlap with the guide (centroid 1044,1971 vs
    the guide's 2688,1600).
  * So the render falls through to the BARE geometric guide oval, with no
    content awareness whatsoever. That is the background bleed.

`_pad_within_finger` already implements the right physical idea (ridge
band energy x orientation coherence) but its own docstring is emphatic
that it CANNOT run unguided -- over a whole frame it latches onto wood
grain and fabric, "coherent and band-energetic" just like ridges. It
needs a spatial prior, and it currently gets one from the U-Net that is
failing here.

THE QUESTION THIS FILE ANSWERS, before any fix is written: the GUIDE is
itself a strong spatial prior (the user physically aligned the pad to
it). Inside that bound, does the ridge-texture signal actually separate
real pad from the background that bled in? If the two distributions
overlap, no thresholding of this signal can work and a different lever is
needed. If they separate, the fix is well-founded.

Reports the real distributions rather than a verdict, and renders an
overlay so the numbers can be checked against what is actually there.

Read-only: Firestore/Storage reads, writes only into fusion_brain/results/.
"""
from __future__ import annotations

import os
import sys
from typing import Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE),
                                'functions', 'processEnhanceAndScore'))

import cv2                                      # noqa: E402
import numpy as np                              # noqa: E402

import afis_print as ap                         # noqa: E402
from phase0c_real_fusion_capture import (       # noqa: E402
    _db, collect_sources, CACHE,
)


def _ridge_score(gray: np.ndarray) -> np.ndarray:
    """Exactly `_pad_within_finger`'s own score field: ridge-band energy
    gated by orientation coherence. Reused rather than re-derived so this
    diagnostic measures the real production signal, not a lookalike."""
    g = gray.astype(np.float32)
    band = (cv2.GaussianBlur(g, (0, 0), ap._PAD_RIDGE_WL_LO / 3.0)
            - cv2.GaussianBlur(g, (0, 0), ap._PAD_RIDGE_WL_HI / 3.0))
    energy = cv2.GaussianBlur(np.abs(band), (0, 0), ap._PAD_RIDGE_WL_HI)
    return energy * ap._block_coherence(gray)


def run(cap_id: str, source: str = 'front_v1') -> Optional[dict]:
    doc = _db.collection('captures').document(cap_id).get()
    if not doc.exists:
        print(f'{cap_id}: not found')
        return None
    v = doc.to_dict()
    srcs = collect_sources(v)
    if source not in srcs:
        print(f'{cap_id}: no {source}')
        return None
    img, guide = srcs[source]
    gray = img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape[:2]

    gm = ap._superellipse_mask((h, w), guide)
    if gm is None:
        print('  guide rasterised to nothing')
        return None
    inside = gm > 0
    score = _ridge_score(gray)
    vals = score[inside]

    # Percentile structure of the signal INSIDE the guide. If the guide were
    # pure pad this would be unimodal and tight; a long low tail means real
    # non-ridge content is sitting inside the enhancement budget.
    pcts = {p: float(np.percentile(vals, p)) for p in (5, 10, 25, 50, 75, 90, 95)}
    print(f'\n=== {cap_id[:12]} / {source} ===')
    print(f'  frame {w}x{h}, guide covers {inside.sum():,} px '
          f'({100.0 * inside.mean():.1f}% of frame)')
    print('  ridge-score percentiles INSIDE the guide:')
    for p, val in pcts.items():
        print(f'    p{p:<3} {val:10.2f}')
    print(f'    ratio p90/p10 = {pcts[90] / max(pcts[10], 1e-6):.1f}x')

    # A ring just OUTSIDE the guide is a real, capture-specific sample of
    # what the local background actually looks like -- a far better
    # reference than any absolute constant, and it costs nothing.
    ring = cv2.dilate(gm, np.ones((201, 201), np.uint8)) > 0
    ring &= ~inside
    if ring.sum() > 1000:
        bvals = score[ring]
        bmed = float(np.median(bvals))
        imed = float(np.median(vals))
        print(f'  median ridge-score  inside guide : {imed:10.2f}')
        print(f'  median ridge-score  outside ring : {bmed:10.2f}')
        print(f'  separation (inside/outside)      : {imed / max(bmed, 1e-6):.2f}x')
        # What share of the guide scores BELOW the outside-ring median --
        # i.e. is no more ridge-like than known background?
        frac = float((vals < bmed).mean())
        print(f'  >> {100.0 * frac:.1f}% of the guide is no more ridge-like '
              f'than the surrounding background')

    ov = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    norm = np.clip(score / max(float(np.percentile(score[inside], 95)), 1e-6), 0, 1)
    heat = cv2.applyColorMap((norm * 255).astype(np.uint8), cv2.COLORMAP_JET)
    ov = cv2.addWeighted(heat, 0.45, ov, 0.55, 0)
    cnts, _ = cv2.findContours(gm, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(ov, cnts, -1, (255, 255, 255), 6)
    sc = 1500.0 / max(ov.shape[:2])
    out = os.path.join(CACHE, f'diag_roi_{cap_id[:8]}_{source}.png')
    cv2.imwrite(out, cv2.resize(ov, None, fx=sc, fy=sc,
                                interpolation=cv2.INTER_AREA))
    print(f'  wrote {os.path.basename(out)} (white = guide bound, '
          f'red = strong ridge signal, blue = none)')
    return {'percentiles': pcts, 'overlay': out}


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: python3 diag_roi_lock.py <captureId> [source]')
        sys.exit(1)
    run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'front_v1')
