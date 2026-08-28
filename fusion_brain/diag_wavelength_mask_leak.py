"""Layer 4 (pre-processing/normalization): does `_ridge_wavelength` leak
background into the estimate that drives `freq_normalize`'s resample scale?

`_ridge_wavelength`/`_ridge_wavelength_robust` scan the FULL, un-cropped frame
in bsize=32 blocks, keeping any block with `std() >= 8` -- no mask parameter
at all. Round 42 already found and fixed the analogous bug in the OTHER
enhancer (`enhancement_pipeline.enhance()`'s `_ridge_pass`, which measured
frequency/orientation from "the highest-contrast quadrant of the WHOLE
512x512 scene"). This checks whether the SAME failure mode exists here, in
afis_print.py's own Gabor path -- the one every production variant
(native/freqNorm/stack/...) actually runs through.

Why it's plausible here specifically: round 33 already measured, on a real
capture, that background (quilt fabric) can have HIGHER local contrast than
the pad itself (Laplacian 2282 background vs 1619 pad, same frame) -- so a
bare `std() >= 8` gate has no reason to prefer pad blocks. And round 42/43
both note the guide occupies a small fraction of the full frame (~12.5% in
one measurement), so background blocks can heavily outnumber pad blocks by
sheer count even where individual pad blocks pass the contrast gate.

Reimplements `_ridge_wavelength`'s exact block loop (copied, not imported --
need to know EACH contributing block's location, which the real function
doesn't expose) and classifies every contributing block as in-mask or
out-of-mask using the guide_region rasterized the same way generate() does
by this point in the pipeline. Research-only, read-only.
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
CACHE = os.path.join(HERE, 'results', 'cache', 'mask'); os.makedirs(CACHE, exist_ok=True)

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

BSIZE = 32

def instrumented_wavelength(img, orient, mask):
    """Exact copy of _ridge_wavelength's block loop, plus in/out-of-mask
    classification and both medians (all blocks vs in-mask-only)."""
    h, w = img.shape
    all_freqs, in_freqs, out_freqs = [], [], []
    n_in = n_out = 0
    for y in range(0, h - BSIZE, BSIZE):
        for x in range(0, w - BSIZE, BSIZE):
            blk = img[y:y+BSIZE, x:x+BSIZE]
            if blk.std() < 8:
                continue
            ang = orient[y+BSIZE//2, x+BSIZE//2]
            M = cv2.getRotationMatrix2D((BSIZE/2, BSIZE/2), np.degrees(ang)-90.0, 1.0)
            rot = cv2.warpAffine(blk, M, (BSIZE, BSIZE))
            sig = rot.mean(axis=0); sig = sig - sig.mean()
            ac = np.correlate(sig, sig, 'full')[BSIZE-1:]
            d = np.diff(ac)
            peaks = np.where((d[:-1] > 0) & (d[1:] <= 0))[0] + 1
            peaks = peaks[peaks > 3]
            if not len(peaks):
                continue
            wl = float(peaks[0])
            all_freqs.append(wl)
            cy, cx = y+BSIZE//2, x+BSIZE//2
            is_in = mask[cy, cx] > 0
            if is_in:
                in_freqs.append(wl); n_in += 1
            else:
                out_freqs.append(wl); n_out += 1
    def med(f): return float(np.clip(np.median(f), 5, 20)) if f else 9.0
    return dict(all_wl=med(all_freqs), in_wl=med(in_freqs), out_wl=med(out_freqs),
               n_all=len(all_freqs), n_in=n_in, n_out=n_out)


caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g,fr=d.get('guideRegion'),d.get('frames')
    if isinstance(g,dict) and isinstance(fr,list) and fr: caps.append((s.id,d,g,fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))
print("%d real captures on/after %s\n" % (len(caps), MIN_DATE))

rows=[]
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
    r = instrumented_wavelength(norm0, orient0, gm)
    prod_wl = afis_print._ridge_wavelength(norm0, orient0)   # the real function, unmodified
    r['id']=cid[:8]; r['prod_wl']=prod_wl
    r['frame_area']=a.size; r['guide_area']=int((gm>0).sum())
    rows.append(r)
    print("  %s  prod(unmasked)=%-5.1f  in-mask-only=%-5.1f  out-of-mask=%-5.1f   "
          "blocks: all=%-3d in=%-3d out=%-3d  guide=%.1f%% of frame"
          % (r['id'], r['prod_wl'], r['in_wl'], r['out_wl'],
             r['n_all'], r['n_in'], r['n_out'], 100*r['guide_area']/r['frame_area']))

json.dump(rows, open(os.path.join(HERE,'results','wavelength_mask_leak.json'),'w'), indent=1)
diffs = [r['prod_wl']-r['in_wl'] for r in rows if r['n_in']>0]
zero_in = sum(1 for r in rows if r['n_in']==0)
print("\n  n=%d captures" % len(rows))
print("  captures with ZERO in-mask contributing blocks (median falls back to 9.0, or is pure background): %d"
      % zero_in)
if diffs:
    print("  prod (unmasked) vs in-mask-only wavelength: mean |delta|=%.2f  max |delta|=%.2f"
          % (statistics.mean(abs(x) for x in diffs), max(abs(x) for x in diffs)))
    changed = sum(1 for x in diffs if abs(x) >= 1.0)
    print("  captures where masking would change the reported wavelength by >=1px: %d/%d"
          % (changed, len(diffs)))
    out_share = statistics.mean(r['n_out']/max(1,r['n_all']) for r in rows if r['n_all']>0)
    print("  mean share of ALL contributing blocks that are OUTSIDE the guide: %.0f%%" % (100*out_share))
