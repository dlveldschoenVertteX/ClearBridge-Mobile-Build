"""Layer 3: does `afisMask: guide+<detector>` mean the detector contributed?

generate() accepts a refined pad mask when
    0.35 * guide_area <= cov <= 0.92 * bound_area,   bound = guide x 1.3 radii
then labels the result `guide+flashdiff` / `guide+unet`.

The gate is AREA-ONLY. If the detector over-segments (grabs hand/wrist/
background), `cand = pad AND bound` simply fills the bound, cov -> bound_area,
and as long as that lands under 0.92 x bound the capture is labelled
`guide+<detector>` while the mask actually used is just the dilated guide --
the detector contributed nothing. That mislabelling is not cosmetic: it is
exactly what made round 20's guide+unet-vs-guide+flashdiff population
comparison uninterpretable (round 21 found the confound but not this
mechanism).

Measures, per real capture, the detector's raw area, the bound area, the
accepted coverage, and how much of the bound the detector actually CUT.

Research-only: read-only Firestore/Storage, no writes.
"""
import os, sys, json, statistics
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

MIN_DATE = '2026-08-17'          # same vintage discipline as round 42
firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()

CACHE = os.path.join(HERE, 'results', 'cache', 'mask')
os.makedirs(CACHE, exist_ok=True)

def fetch(path):
    local = os.path.join(CACHE, path.replace('/', '_'))
    if not os.path.exists(local):
        bucket.blob(path).download_to_filename(local)
    return cv2.imread(local, cv2.IMREAD_GRAYSCALE)

caps = []
for s in db.collection('captures').stream():
    d = s.to_dict() or {}
    if d.get('captureMode') != 'front_only_v1':
        continue
    if str(d.get('createdAt'))[:10] < MIN_DATE:
        continue
    g = d.get('guideRegion'); fr = d.get('frames')
    if not isinstance(g, dict) or not isinstance(fr, list) or not fr:
        continue
    caps.append((s.id, d, g, fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))
print("%d real front_only_v1 captures on/after %s\n" % (len(caps), MIN_DATE))

D = afis_print._MASK_COVER_DILATE
rows = []
for cid, d, g, fr in caps:
    amb = [f for f in fr if not f.get('flashOn')]
    fl  = [f for f in fr if f.get('flashOn')]
    if not amb or not fl:
        continue
    try:
        a = fetch(amb[0]['path']); f0 = fetch(fl[0]['path'])
    except Exception as exc:
        print("  %s  download failed: %s" % (cid[:8], exc)); continue
    if a is None or f0 is None or a.shape != f0.shape:
        continue
    gm = afis_print._superellipse_mask(a.shape[:2], g)
    bd = afis_print._superellipse_mask(a.shape[:2], {
        **g, 'rx': float(g['rx']) * D, 'ry': float(g['ry']) * D})
    if gm is None or bd is None:
        continue
    ga = float((gm > 0).sum()); ba = float((bd > 0).sum())

    pad = afis_print._flash_diff_mask([a], [f0], a.shape[:2], g); tag = 'flashdiff'
    if pad is None:
        pad = afis_print._unet_mask(a); tag = 'unet'
    if pad is None:
        rows.append(dict(id=cid[:8], tag='guide', raw=None)); 
        print("  %s  no detector -> bare guide" % cid[:8]); continue
    pad = afis_print._fill_mask_holes(pad)
    raw_frac = float((pad > 0).sum()) / a.size
    cov = float((cv2.bitwise_and(pad, bd) > 0).sum())
    accepted = (0.35 * ga <= cov <= 0.92 * ba)
    # how much of the bound did the detector actually cut away?
    cut = 1.0 - cov / ba
    rows.append(dict(id=cid[:8], tag=tag, raw=raw_frac, cov_over_guide=cov / ga,
                     cov_over_bound=cov / ba, cut=cut, accepted=bool(accepted),
                     frame=f"{a.shape[1]}x{a.shape[0]}"))
    print("  %s  %-9s raw=%5.1f%% of frame  cov=%.2fxguide %.2fxbound  cut=%4.1f%%  %s"
          % (cid[:8], tag, 100 * raw_frac, cov / ga, cov / ba, 100 * cut,
             'ACCEPT' if accepted else 'reject->bare guide'))

json.dump(rows, open(os.path.join(HERE, 'results', 'mask_contribution.json'), 'w'), indent=1)
ok = [r for r in rows if r.get('accepted')]
print("\n  accepted %d / %d" % (len(ok), len([r for r in rows if r.get('raw') is not None])))
if ok:
    cuts = [r['cut'] for r in ok]
    print("  among ACCEPTED, fraction of the bound the detector actually cut:")
    print("     min=%.1f%%  median=%.1f%%  max=%.1f%%"
          % (100 * min(cuts), 100 * statistics.median(cuts), 100 * max(cuts)))
    token = [r for r in ok if r['cut'] < 0.10]
    print("  accepted with <10%% cut (label says guide+%s, mask is ~the dilated guide): %d/%d"
          % ('<det>', len(token), len(ok)))
