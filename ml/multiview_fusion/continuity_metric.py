"""Direct measurement of ridge continuity at a fusion seam -- the actual
failure mode the 2026-07-12 small-roll NO-GO only ever inferred indirectly
from a whole-print NFIQ2/SourceAFIS drop. This module measures it directly:
does the ridge orientation field agree across the boundary between
front-only content and borrowed side content, or does it jump?

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

from typing import Optional

import cv2
import numpy as np

from common import orientation_field

_SEAM_BAND_PX = 12   # half-width of the band straddling the seam
_CONTROL_OFFSET_PX = 40  # how far inside the front-only region the control band sits


def _doubled_angle_diff(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Mean absolute difference between two orientation fields, using the
    doubled-angle (mod pi) representation orientation_field already returns
    in, so a ridge direction of ~0 and ~pi (same physical ridge orientation)
    reads as zero difference, not a false near-pi discontinuity."""
    d = np.abs(a - b)
    return np.minimum(d, np.pi - d)


def seam_continuity_score(composite: np.ndarray, contributor_mask: np.ndarray
                           ) -> dict:
    """contributor_mask: same shape as composite, nonzero where the pixel's
    dominant contribution came from a BORROWED side view rather than the
    front-only anchor region (e.g. thresholded _block_coherence-based
    weight fraction from the fusion step, or simply the warped side's own
    valid-pixel mask before blending).

    Returns the mean orientation-field discontinuity right at the seam
    boundary (where contributor_mask transitions from 0 to nonzero) versus
    a control band deep inside the front-only region -- the control band is
    the noise floor: if the seam score isn't clearly above it, the fusion
    didn't introduce a measurable discontinuity.
    """
    orient = orientation_field(composite)
    boundary = cv2.Canny((contributor_mask > 0).astype(np.uint8) * 255, 50, 150)
    seam_ys, seam_xs = np.where(boundary > 0)
    if len(seam_ys) == 0:
        return {'seam_discontinuity': None, 'control_discontinuity': None,
                'ratio': None, 'note': 'no seam boundary found (single-source composite?)'}

    seam_vals = []
    for y, x in zip(seam_ys, seam_xs):
        y0, y1 = max(0, y - _SEAM_BAND_PX), min(orient.shape[0], y + _SEAM_BAND_PX)
        x0, x1 = max(0, x - _SEAM_BAND_PX), min(orient.shape[1], x + _SEAM_BAND_PX)
        patch = orient[y0:y1, x0:x1]
        if patch.size < 4:
            continue
        seam_vals.append(_doubled_angle_diff(patch[:-1, :], patch[1:, :]).mean())
        seam_vals.append(_doubled_angle_diff(patch[:, :-1], patch[:, 1:]).mean())

    # Control band: well inside the front-only (contributor_mask == 0) region,
    # offset away from any seam pixel -- the "how noisy is this metric on
    # content we KNOW is single-source and undisturbed" floor.
    front_only = contributor_mask == 0
    eroded = cv2.erode(front_only.astype(np.uint8),
                        np.ones((_CONTROL_OFFSET_PX, _CONTROL_OFFSET_PX), np.uint8))
    ctrl_ys, ctrl_xs = np.where(eroded > 0)
    control_vals = []
    if len(ctrl_ys):
        rng = np.random.default_rng(0)
        idx = rng.choice(len(ctrl_ys), size=min(500, len(ctrl_ys)), replace=False)
        for i in idx:
            y, x = ctrl_ys[i], ctrl_xs[i]
            y0, y1 = max(0, y - _SEAM_BAND_PX), min(orient.shape[0], y + _SEAM_BAND_PX)
            x0, x1 = max(0, x - _SEAM_BAND_PX), min(orient.shape[1], x + _SEAM_BAND_PX)
            patch = orient[y0:y1, x0:x1]
            if patch.size < 4:
                continue
            control_vals.append(_doubled_angle_diff(patch[:-1, :], patch[1:, :]).mean())
            control_vals.append(_doubled_angle_diff(patch[:, :-1], patch[:, 1:]).mean())

    seam_score = float(np.mean(seam_vals)) if seam_vals else None
    control_score = float(np.mean(control_vals)) if control_vals else None
    ratio = (seam_score / control_score) if (seam_score is not None and control_score) else None
    return {
        'seam_discontinuity': seam_score,
        'control_discontinuity': control_score,
        'ratio': ratio,  # >>1 means the seam is genuinely worse than baseline noise
    }
