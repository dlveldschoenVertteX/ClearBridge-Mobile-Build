"""Layer 3: what does the mask accept-gate actually DO on real frames?

generate() accepts a refined pad mask only when
    0.35 * guide_area <= cov <= 0.92 * bound_area
with bound = guide dilated by _MASK_COVER_DILATE (1.3), so
    bound_area = 1.69 * guide_area
and the accept window is [0.35, 1.55] x guide_area.

If the U-Net over-segments, the intersection with the bound simply fills the
bound, cov -> 1.69 x guide_area, and the gate REJECTS -> bare guide. That is
the safety net working. But it also means `guide+unet` only ever survives on
captures where the U-Net happened to UNDER-segment -- a biased surviving
population, which is exactly the confound round 21 identified in the
guide+unet-vs-guide+flashdiff comparison.

This measures it directly. Research-only, read-only.
"""
import os, sys, glob
import numpy as np, cv2

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import sfm_pipeline, afis_print  # noqa: E402

# Real still-space front_only_v1 guide. cx/cy from round 16's real
# measurement; radii from PadSilhouetteShape rotated + the BoxFit.cover
# crop factor recorded in this session's layer-2 audit.
GUIDE = {'cx': 0.63, 'cy': 0.50, 'rx': 0.0830, 'ry': 0.1346,
         'tipAngleDeg': 0.0, 'n': 2.5}
DILATE = afis_print._MASK_COVER_DILATE
print("guide approx %s   _MASK_COVER_DILATE=%.2f -> bound = %.2f x guide"
      % ({k: GUIDE[k] for k in ('cx', 'cy', 'rx', 'ry')}, DILATE, DILATE ** 2))
print("accept window: cov in [0.35, %.2f] x guide_area\n" % (0.92 * DILATE ** 2))

paths = (sorted(glob.glob(os.path.join(HERE, 'results', 'cache', '*front_burst*.jpg')))
         + sorted(glob.glob(os.path.join(HERE, 'results', 'cache', '*front_focuszone*.jpg'))))
acc = rej_hi = rej_lo = 0
for p in paths:
    g = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
    if g is None:
        continue
    pad = afis_print._unet_mask(g)
    gm = afis_print._superellipse_mask(g.shape[:2], GUIDE)
    bound = afis_print._superellipse_mask(g.shape[:2], {
        **GUIDE, 'rx': GUIDE['rx'] * DILATE, 'ry': GUIDE['ry'] * DILATE})
    if pad is None or gm is None or bound is None:
        print("  %-30s unet=None" % os.path.basename(p)[-30:]); continue
    pad = afis_print._fill_mask_holes(pad)
    ga = float((gm > 0).sum()); ba = float((bound > 0).sum())
    cov = float((cv2.bitwise_and(pad, bound) > 0).sum())
    frame_frac = float((pad > 0).sum()) / g.size
    ratio = cov / ga
    if ratio < 0.35:
        verd, _ = 'REJECT(small)', rej_lo
        rej_lo += 1
    elif cov > 0.92 * ba:
        verd = 'REJECT(runaway)'; rej_hi += 1
    else:
        verd = 'accept'; acc += 1
    print("  %-30s unet=%5.1f%% of frame   cov=%.2f x guide   %s"
          % (os.path.basename(p)[-30:], 100 * frame_frac, ratio, verd))

n = acc + rej_hi + rej_lo
print("\n  accept %d/%d   reject-runaway %d   reject-small %d" % (acc, n, rej_hi, rej_lo))
