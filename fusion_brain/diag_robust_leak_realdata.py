"""Layer 4 follow-up: does the SAME leak affect `afisWavelengthPxRaw`
(`_ridge_wavelength_robust`), the field client-side distance gates were
calibrated against?

`_liveWavelengthTooHighPx = 35.0` (front_capture_controller.dart) was derived
from real `afisWavelengthPxRaw` stats across 44 captures: mean 23.8, sd 6.4,
"mean+2sd=36.6" -> 35.0, explicitly framed as a safety backstop rather than an
optimization target (round 17). `_ridge_wavelength_robust` never had a mask
parameter either -- same unmasked full-frame block scan, just unclipped and
peak-averaged. If it carries the same 96%-background contamination, that
calibration was derived from a distribution this same round's diagnostic says
is dominated by non-pad content.

Measures both values (current unmasked vs a masked variant) on the same real
population this diagnostic already downloaded, to see whether the working
distribution differs enough to matter. Does NOT propose a new threshold --
that needs its own dedicated recalibration, per this project's own standing
"don't tune blind off inferred numbers" discipline.
"""
import os, sys, json, statistics
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

MIN_DATE = '2026-08-17'
firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()
CACHE = os.path.join(HERE, 'results', 'cache', 'mask')

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

BSIZE = 32
def robust_wl(img, orient, mask=None):
    h, w = img.shape
    freqs, in_freqs = [], []
    for y in range(0, h - BSIZE, BSIZE):
        for x in range(0, w - BSIZE, BSIZE):
            blk = img[y:y+BSIZE, x:x+BSIZE]
            if blk.std() < 8: continue
            ang = orient[y+BSIZE//2, x+BSIZE//2]
            M = cv2.getRotationMatrix2D((BSIZE/2, BSIZE/2), np.degrees(ang)-90.0, 1.0)
            rot = cv2.warpAffine(blk, M, (BSIZE, BSIZE))
            sig = rot.mean(axis=0); sig = sig - sig.mean()
            ac = np.correlate(sig, sig, 'full')[BSIZE-1:]
            d = np.diff(ac)
            peaks = np.where((d[:-1] > 0) & (d[1:] <= 0))[0] + 1
            peaks = peaks[peaks > 3]
            if len(peaks) >= 2: v = float(np.mean(np.diff(peaks)))
            elif len(peaks) == 1: v = float(peaks[0])
            else: continue
            freqs.append(v)
            if mask is not None and mask[y+BSIZE//2, x+BSIZE//2] > 0:
                in_freqs.append(v)
    if mask is not None and in_freqs:
        return float(np.median(in_freqs))
    return float(np.median(freqs)) if freqs else 9.0

caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g,fr=d.get('guideRegion'),d.get('frames')
    if isinstance(g,dict) and isinstance(fr,list) and fr: caps.append((s.id,d,g,fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))

unmasked_vals, masked_vals = [], []
for cid,d,g,fr in caps:
    amb=[f for f in fr if not f.get('flashOn')]
    if not amb: continue
    a=fetch(amb[0]['path'])
    if a is None: continue
    g8 = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8,8)).apply(a.astype(np.uint8))
    gm = afis_print._superellipse_mask(a.shape[:2], g)
    if gm is None: continue
    norm0 = afis_print._normalize(g8)
    orient0 = afis_print._orientation_field(norm0)
    u = robust_wl(norm0, orient0, None)
    m = robust_wl(norm0, orient0, gm)
    unmasked_vals.append(u); masked_vals.append(m)
    print("  %s  unmasked(current)=%-6.1f  masked=%-6.1f" % (cid[:8], u, m))

print("\n  n=%d" % len(unmasked_vals))
print("  UNMASKED (what round 17's 35.0 threshold was calibrated against): mean=%.1f sd=%.1f max=%.1f  mean+2sd=%.1f"
      % (statistics.mean(unmasked_vals), statistics.pstdev(unmasked_vals),
         max(unmasked_vals), statistics.mean(unmasked_vals)+2*statistics.pstdev(unmasked_vals)))
print("  MASKED (pad-restricted):                                          mean=%.1f sd=%.1f max=%.1f  mean+2sd=%.1f"
      % (statistics.mean(masked_vals), statistics.pstdev(masked_vals),
         max(masked_vals), statistics.mean(masked_vals)+2*statistics.pstdev(masked_vals)))
