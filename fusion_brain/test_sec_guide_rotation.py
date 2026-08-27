"""Layer 2: validate the rotated `_sec_guide` constants on real macro frames.

Both cached camera-"2" macro frames predate round 36's `_normalizeMacroFrame`
fix, so they are the PORTRAIT frames the old constants were measured in.
Round 36 now rotates this frame 90 deg CW client-side before upload, so a
fresh capture arrives landscape.

This applies that exact rotation (copied from decodeStillJpegToLuma's own
indexing) to reconstruct what the backend will actually receive, then renders
the real production candidate both ways -- OLD portrait-convention constants
vs NEW rotated ones -- and scores each with the real NFIQ2 binary.

If the rotation reading is right, OLD should crop somewhere useless on the
rotated frame and NEW should recover the pad. If both score the same, the
premise is wrong and the change should be reverted.

Research-only; read-only imports of production.
"""
import os, sys, subprocess, tempfile
import numpy as np
import cv2

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'


def rotate_cw_like_client(img):
    """Exactly decodeStillJpegToLuma's rotation:
       dst is h wide x w tall; rotated[y*dstW+x] = luma[(h-1-x)*w + y]."""
    h, w = img.shape[:2]
    dst = np.empty((w, h), img.dtype)          # dstH=w rows, dstW=h cols
    for y in range(w):
        dst[y, :] = img[h - 1 - np.arange(h), y]
    return dst


def nfiq2(img):
    if img is None:
        return None
    r = cv2.resize(img, (500, 500), interpolation=cv2.INTER_LANCZOS4)
    with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as f:
        cv2.imwrite(f.name, r)
        try:
            out = subprocess.run([NFIQ2, '-m', MODEL, '-i', f.name, '-F'],
                                 capture_output=True, text=True, timeout=120)
            for tok in out.stdout.replace(',', ' ').split():
                try:
                    v = float(tok)
                except ValueError:
                    continue
                if 0.0 <= v <= 100.0:
                    return v
        finally:
            os.unlink(f.name)
    return None


OLD = dict(cx=0.5,  cy=0.34, rx=0.11, ry=0.13, tipAngleDeg=0.0, n=2.5)
NEW = dict(cx=0.66, cy=0.50, rx=0.13, ry=0.11, tipAngleDeg=0.0, n=2.5)

import glob
paths = sorted(glob.glob(os.path.join(HERE, 'results', 'cache', '*secondary_2_macro*.jpg')))
print(f"{len(paths)} real camera-'2' macro frames\n")
print("  OLD (portrait-convention, currently deployed): cx=0.50 cy=0.34 rx=0.11 ry=0.13")
print("  NEW (rotated into shared landscape convention): cx=0.66 cy=0.50 rx=0.13 ry=0.11\n")

for p in paths:
    cap = os.path.basename(p).split('_')[2][:8]
    raw = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
    rot = rotate_cw_like_client(raw)
    print("  %s  raw %dx%d -> post-round-36 upload %dx%d"
          % (cap, raw.shape[1], raw.shape[0], rot.shape[1], rot.shape[0]))
    for label, guide in (('OLD', OLD), ('NEW', NEW)):
        try:
            img, params = afis_print.generate(
                [rot], [0.0], ['flash'],
                guide_region=dict(guide), freq_normalize=True, stack_cache={})
            sc = nfiq2(img)
            print("        %-3s  nfiq2=%-6s  mask=%-16s coverPx=%s"
                  % (label, sc, params.get('afisMask'), params.get('afisMaskCoverPx')))
        except Exception as exc:
            print("        %-3s  FAILED: %s" % (label, exc))
    print()
