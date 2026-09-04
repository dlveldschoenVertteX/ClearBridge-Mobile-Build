"""Layer 2: where does the pad ACTUALLY sit in a camera-"2" macro frame?

main.py synthesises the secondary-camera guide as
    _sec_guide = {'cx': 0.5, 'cy': _sec_cy, 'rx': .., 'ry': ..}

For camera "2", `cy` (0.34) was measured from a real frame in round 31 and
`rx`/`ry` (0.11/0.13) in round 33.  **`cx` never was** -- it is still the
bare frame centre, the same unmeasured assumption that cost round 16 a
555px seeding error on the MAIN frame (real guide there sits at cx=0.63,
not 0.5).

Measures the pad with the ridge-specific signal round 42 established --
in-band ridge energy x orientation coherence -- not brightness, which the
round-31 lobe method used and which the fabric/background in these frames
is perfectly capable of winning.

Research-only, read-only imports of production.
"""
import sys, os, glob
import numpy as np
import cv2

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402


def ridge_score_map(gray: np.ndarray, block: int = 64):
    """Per-block (in-band ridge energy x orientation coherence)."""
    h, w = gray.shape
    ny, nx = h // block, w // block
    out = np.zeros((ny, nx), np.float32)
    g = gray.astype(np.float32)
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3)
    for by in range(ny):
        for bx in range(nx):
            ys, xs = by * block, bx * block
            p = g[ys:ys + block, xs:xs + block]
            if p.std() < 3.0:
                continue
            # orientation coherence from the structure tensor
            a = gx[ys:ys + block, xs:xs + block]
            b = gy[ys:ys + block, xs:xs + block]
            jxx, jyy, jxy = (a * a).mean(), (b * b).mean(), (a * b).mean()
            denom = jxx + jyy + 1e-9
            coh = float(np.sqrt((jxx - jyy) ** 2 + 4 * jxy ** 2) / denom)
            # in-band ridge energy: radial FFT power in the 6..40px period band
            pf = p - p.mean()
            F = np.abs(np.fft.fftshift(np.fft.fft2(pf * np.hanning(block)[:, None]
                                                   * np.hanning(block)[None, :])))
            cy0 = cx0 = block // 2
            yy, xx = np.mgrid[0:block, 0:block]
            r = np.sqrt((yy - cy0) ** 2 + (xx - cx0) ** 2)
            lo, hi = block / 40.0, block / 6.0        # period 6..40 px
            band = F[(r >= lo) & (r <= hi)].sum()
            tot = F[r >= 1].sum() + 1e-9
            out[by, bx] = float(band / tot) * coh
    return out


def centroid(m: np.ndarray, keep: float = 0.85):
    """Centroid of the top (1-keep) fraction of blocks, normalized 0..1."""
    thr = np.quantile(m[m > 0], keep) if (m > 0).any() else 0.0
    ys, xs = np.nonzero(m >= thr)
    if len(ys) == 0:
        return None
    wts = m[ys, xs]
    cy = float((ys + 0.5).dot(wts) / wts.sum() / m.shape[0])
    cx = float((xs + 0.5).dot(wts) / wts.sum() / m.shape[1])
    # extent of the kept blocks, as a half-width fraction
    ry = float((ys.max() - ys.min() + 1) / 2.0 / m.shape[0])
    rx = float((xs.max() - xs.min() + 1) / 2.0 / m.shape[1])
    return cx, cy, rx, ry


ASSUMED = {'cx': 0.5, 'cy': 0.34, 'rx': 0.11, 'ry': 0.13}

paths = sorted(glob.glob(os.path.join(HERE, 'results', 'cache', '*secondary_2_macro*.jpg')))
print(f"{len(paths)} real camera-'2' macro frames cached\n")
print("main.py assumes  cx=%.3f cy=%.3f rx=%.3f ry=%.3f\n" % (
    ASSUMED['cx'], ASSUMED['cy'], ASSUMED['rx'], ASSUMED['ry']))

for p in paths:
    img = cv2.imread(p, cv2.IMREAD_GRAYSCALE)   # same decode main.py uses
    if img is None:
        print("  !! could not decode", os.path.basename(p)); continue
    m = ridge_score_map(img)
    c = centroid(m)
    cap = os.path.basename(p).split('_')[2][:8]
    if c is None:
        print("  %s  %dx%d  no ridge-bearing blocks found" % (cap, img.shape[1], img.shape[0]))
        continue
    cx, cy, rx, ry = c
    print("  %s  frame %dx%d  ridge centroid cx=%.3f cy=%.3f  extent rx=%.3f ry=%.3f"
          % (cap, img.shape[1], img.shape[0], cx, cy, rx, ry))
    print("         delta vs assumed: dcx=%+.3f (%+.0f px)  dcy=%+.3f (%+.0f px)"
          % (cx - ASSUMED['cx'], (cx - ASSUMED['cx']) * img.shape[1],
             cy - ASSUMED['cy'], (cy - ASSUMED['cy']) * img.shape[0]))
