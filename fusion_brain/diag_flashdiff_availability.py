"""Layer 3: why does flash-diff -- the detector that never misses -- only run
on 46% of captures?

`_flash_diff_mask` is measurably the reliable one (0/11 misses on the recent
population, against the U-Net's 4/13). Every front_only_v1 capture uploads 4
ambient and 4 flash frames, so in principle it should always be available.
It returns None on 54% of them anyway.

If the reason is the blown-out-flash guard (`_FLASH_DIFF_MIN_FLASH_LAPLACIAN`,
50.0), that is not a masking problem at all -- it is layer 1 (exposure)
surfacing two layers downstream, and the flash EV work belongs there. If it is
the area accept gate, that is a masking threshold worth revisiting. Those two
answers point at completely different work, so the distinction is worth
measuring rather than assuming.

Instruments the real production function across every pair of every recent
capture. Research-only, read-only.
"""
import os, sys, json, collections
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print, sfm_pipeline  # noqa: E402

MIN_DATE = '2026-08-17'
firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()
CACHE = os.path.join(HERE, 'results', 'cache', 'mask'); os.makedirs(CACHE, exist_ok=True)

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

THR = afis_print._FLASH_DIFF_MIN_FLASH_LAPLACIAN
print("blown-out-flash guard threshold: %.1f\n" % THR)

caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g,fr=d.get('guideRegion'),d.get('frames')
    if isinstance(g,dict) and isinstance(fr,list) and fr: caps.append((s.id,d,g,fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))

reasons = collections.Counter(); rows=[]
for cid,d,g,fr in caps:
    amb=[f for f in fr if not f.get('flashOn')]; fl=[f for f in fr if f.get('flashOn')]
    if not amb or not fl: continue
    ab=[fetch(f['path']) for f in amb]; fb=[fetch(f['path']) for f in fl]
    ab=[x for x in ab if x is not None]; fb=[x for x in fb if x is not None]
    if not ab or not fb: continue
    laps=[float(cv2.Laplacian(x, cv2.CV_64F).var()) for x in fb]
    blown = sum(1 for L in laps if L < THR)
    # full-burst call, exactly as production does it
    m = afis_print._flash_diff_mask(ab, fb, ab[0].shape[:2], g)
    if m is not None:
        why='ok'
    elif blown == len(laps):
        why='all flash frames below the blowout guard'
    else:
        why='segmentation/accept-gate rejected every usable pair'
    reasons[why]+=1
    rows.append(dict(id=cid[:8], ok=m is not None, blown=blown, n=len(laps),
                     lap_min=round(min(laps),1), lap_max=round(max(laps),1), why=why))
    print("  %s  flash Laplacian %6.1f..%-7.1f  %d/%d under guard   %s"
          % (cid[:8], min(laps), max(laps), blown, len(laps),
             'flash-diff OK' if m is not None else 'NONE -> '+why), flush=True)

json.dump(rows, open(os.path.join(HERE,'results','flashdiff_availability.json'),'w'), indent=1)
print("\n  n=%d" % len(rows))
for k,v in reasons.most_common(): print("    %-48s %d" % (k,v))
