"""Phase 1: seam-routed compositing, tried straight on top of the existing
ECC-only alignment -- local-TPS correction (Phase 0, both the NCC block-
matching and minutiae-correspondence attempts) is a confirmed dead end on
this data (see README.md), but seam-routing doesn't need correspondence to
be solved at all: instead of blending front and a side view everywhere
(the OLD `common.coherence_weighted_blend`'s flaw -- a continuous weighted
average smears two slightly-misaligned ridge structures together over the
WHOLE frame, which is exactly the kind of ghosting/discontinuity the
2026-07-12 small-roll test and this branch's Phase 0 both hit), only ever
substitute side content in the specific places it's genuinely better, and
feather NARROWLY at just those boundaries.

Real literature basis (Efros & Freeman-style minimum-error-boundary image
compositing; classic panorama seam-finding) assumes the two sources' "which
is better" regions form large, spatially coherent, roughly bipartite areas
(e.g. left half vs. right half in a real panorama) -- which is why OpenCV's
own stitching seam finders (`cv2.detail_DpSeamFinder`,
`cv2.detail_GraphCutSeamFinder`) exist as the standard tool. **Checked this
assumption directly against real data before reusing that tool as-is**:
measured where local ridge coherence (front vs. an ECC-registered side)
prefers each source, per row -- found 7-23 label transitions PER ROW (not a
single clean left/right split), and `cv2.detail_DpSeamFinder` given the
raw full-overlap masks degenerately assigned the ENTIRE frame to one source
and nothing to the other (no meaningful cut at all). A single-seam DP/graph-
cut model assumes exactly the large-coherent-region structure this data
does NOT have -- the "which capture is locally sharper" difference here is
speckle/noise-like, not a geographic split.

Adapted approach, given that finding: instead of forcing a single cut
curve, use front's own local coherence WEAKNESS (already a real, existing
signal -- `common.block_coherence`) to define where side content is even
considered, drop small/noisy candidate regions via connected-component area
filtering (collapses the speckled per-pixel preference into a handful of
spatially real regions instead of a full-frame partition), and feather only
in a narrow band around each surviving region's boundary -- keeping the
"hard partition + narrow-band feather instead of whole-frame blend" spirit
of seam-routed compositing while matching what this real data actually
supports.

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

from typing import List, Optional, Tuple

import cv2
import numpy as np

from common import block_coherence

_COHERENCE_MARGIN = 0.08   # side must beat front's own local coherence by
                           # this much to even be considered -- avoids
                           # granting control on noise-level differences.
_MIN_BLOB_AREA_PX = 400    # drop connected regions smaller than this after
                           # thresholding -- the measured per-row
                           # transition-count check found the raw
                           # front-vs-side quality difference is speckled;
                           # this collapses that speckle into a small number
                           # of real, spatially coherent candidate regions.
_FEATHER_BAND_PX = 10      # Gaussian-blur sigma for the alpha ramp, applied
                           # only near each surviving region's boundary --
                           # narrow-band feathering, not a whole-frame blend.


def _candidate_region(front: np.ndarray, side: np.ndarray) -> np.ndarray:
    """Where side is meaningfully better than the current front/composite,
    filtered down to real, spatially coherent regions (not speckle)."""
    valid_side = (side > 0).astype(np.uint8)
    coh_front = block_coherence(front)
    coh_side = block_coherence(side) * valid_side
    raw = ((coh_side - coh_front) > _COHERENCE_MARGIN).astype(np.uint8) * 255

    n, labels, stats, _ = cv2.connectedComponentsWithStats(raw, connectivity=8)
    keep = np.zeros_like(raw)
    for lbl in range(1, n):
        if stats[lbl, cv2.CC_STAT_AREA] >= _MIN_BLOB_AREA_PX:
            keep[labels == lbl] = 255
    return keep


def _feathered_alpha(region_mask: np.ndarray) -> np.ndarray:
    """Binary region -> smooth [0,1] alpha, blurred only enough to feather
    a narrow band at the boundary (not the whole region)."""
    a = region_mask.astype(np.float32) / 255.0
    return cv2.GaussianBlur(a, (0, 0), _FEATHER_BAND_PX)


def seam_composite(front: np.ndarray, registered_sides: List[np.ndarray]
                    ) -> Tuple[Optional[np.ndarray], np.ndarray, int]:
    """Sequentially merge each ECC-registered side frame into a running
    composite (front-anchored, same anchoring philosophy as
    `common.coherence_weighted_blend` / the original `_front_anchored_
    mosaic`): a side frame only ever substitutes content in real, locally-
    better, spatially coherent regions, feathered narrowly at the boundary,
    never blended across the whole frame. Returns (composite, contributor_
    mask, n_used) -- contributor_mask matches the same contract
    `run_phase0.py`'s `_contributor_mask` used, for `continuity_metric.
    seam_continuity_score`."""
    composite = front.astype(np.float32).copy()
    contributor_mask = np.zeros(front.shape, dtype=np.uint8)
    n_used = 0
    for side in registered_sides:
        region = _candidate_region(composite.astype(np.uint8), side)
        if not np.any(region):
            continue
        alpha = _feathered_alpha(region)
        valid_side = (side > 0).astype(np.float32)
        alpha = alpha * valid_side  # never pull from side's own invalid border
        composite = composite * (1 - alpha) + side.astype(np.float32) * alpha
        contributor_mask |= (region > 0).astype(np.uint8)
        n_used += 1
    if n_used == 0:
        return None, contributor_mask, 0
    return composite.astype(np.uint8), contributor_mask, n_used
