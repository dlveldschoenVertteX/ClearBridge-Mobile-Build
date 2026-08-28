"""Layer 6: cheap pre-pass -- compute the ambient:flash sharpness ratio for
every real recent capture, BEFORE spending the expensive dual-arm
generate() test only where the guard would actually change anything.

flash_pair_sharpness_ratio itself is cheap (two Laplacian-variance
computations over a small guide crop, no ECC). _fuse_flash_ambient's own
registration is full-resolution ECC (unlike _align_face_on_stack, which
downscales for speed) -- expensive enough that testing all 24 captures in
both arms is impractical. Narrowing to only the captures where ratio > 2.0
(guard fires) plus a couple of controls where it doesn't (byte-identical
arms, confirms the flag is a true no-op there) mirrors round 45's own
narrowing for the U-Net seed test.
"""
import os, sys, json
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

caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g,fr=d.get('guideRegion'),d.get('frames')
    if isinstance(g,dict) and isinstance(fr,list) and fr: caps.append((s.id,d,g,fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))

rows=[]
for cid,d,g,fr in caps:
    amb=[f for f in fr if not f.get('flashOn')]; fl=[f for f in fr if f.get('flashOn')]
    if not amb or not fl: continue
    try: a=fetch(amb[0]['path']); f0=fetch(fl[0]['path'])
    except Exception as e: print("  %s download failed: %s"%(cid[:8],e)); continue
    if a is None or f0 is None or a.shape!=f0.shape: continue
    ratio = afis_print.flash_pair_sharpness_ratio(a, f0, g)
    rows.append((cid[:8], ratio))
    print("  %s  ratio=%s  %s" % (cid[:8], round(ratio,2) if isinstance(ratio,float) else ratio,
                                  'GUARD FIRES' if isinstance(ratio,float) and ratio > afis_print._FLASH_PAIR_MAX_SHARPNESS_RATIO else ''))

json.dump(rows, open(os.path.join(HERE,'results','fuse_ratios.json'),'w'), indent=1)
fires = [r for r in rows if isinstance(r[1],float) and r[1] > afis_print._FLASH_PAIR_MAX_SHARPNESS_RATIO]
print("\n  n=%d captures, guard would fire on %d" % (len(rows), len(fires)))
