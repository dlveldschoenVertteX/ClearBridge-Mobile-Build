"""Layer 3 arm 3: is the refinement delta just AREA?: does content-aware
mask refinement beat the BARE GUIDE at all?

Every masking round so far has compared detectors against each other --
guide+flashdiff vs guide+unet (round 20), forced-unet vs flashdiff on matched
captures (round 21), seed fixes (round 16). None has run the control this
whole layer rests on: refinement ON vs refinement OFF, same capture, same
everything else.

That matters because the answer decides whether the detector is worth
improving at all. If the bare guide ties or wins, then the U-Net's 31% miss
rate is not a defect worth fixing -- a miss just falls back to the bare guide,
which would be the better arm anyway -- and this layer's remaining effort
belongs elsewhere.

Arms, on every real recent front_only_v1 capture:
  prod  -- production as-is (flash-diff, U-Net fallback, accept gate)
  bare  -- guide_region only, refinement disabled entirely

Scored with the real NFIQ2 binary. NFIQ2 is a floor, not the target (this
project's own prime directive), so a small delta either way should be read as
"no evidence", not as a result.

Research-only, read-only Firestore/Storage.
"""
import os, sys, json, statistics, subprocess, tempfile
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
MIN_DATE = '2026-08-17'

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()
CACHE = os.path.join(HERE, 'results', 'cache', 'mask'); os.makedirs(CACHE, exist_ok=True)

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

def nfiq2(img):
    if img is None: return None
    r = cv2.resize(img, (500, 500), interpolation=cv2.INTER_LANCZOS4)
    f = tempfile.NamedTemporaryFile(suffix='.png', delete=False); cv2.imwrite(f.name, r)
    try:
        o = subprocess.run([NFIQ2,'-m',MODEL,'-i',f.name,'-F'],capture_output=True,text=True,timeout=180)
        for t in o.stdout.replace(',',' ').split():
            try: v=float(t)
            except ValueError: continue
            if 0.0<=v<=100.0: return v
    finally: os.unlink(f.name)

_FD, _UN = afis_print._flash_diff_mask, afis_print._unet_mask

caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g,fr = d.get('guideRegion'), d.get('frames')
    if isinstance(g,dict) and isinstance(fr,list) and fr: caps.append((s.id,d,g,fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))
print("%d real captures on/after %s\n" % (len(caps), MIN_DATE))

out=[]
for cid,d,g,fr in caps:
    amb=[f for f in fr if not f.get('flashOn')]; fl=[f for f in fr if f.get('flashOn')]
    if not amb or not fl: continue
    try: a=fetch(amb[0]['path']); f0=fetch(fl[0]['path'])
    except Exception as e: print("  %s download failed: %s"%(cid[:8],e)); continue
    if a is None or f0 is None or a.shape!=f0.shape: continue
    res={}
    for arm in ('prod','bare','dilated'):
        gg = g
        if arm in ('bare','dilated'):
            afis_print._flash_diff_mask = lambda *A, **K: None
            afis_print._unet_mask = lambda *A, **K: None
        else:
            afis_print._flash_diff_mask, afis_print._unet_mask = _FD, _UN
        if arm == 'dilated':
            # The bare guide grown to the SAME outer bound refinement is
            # clipped to -- no detector at all. If this matches or beats the
            # refined arm, the detector is contributing nothing and the whole
            # delta is an area effect.
            D = afis_print._MASK_COVER_DILATE
            gg = {**g, 'rx': float(g['rx'])*D, 'ry': float(g['ry'])*D}
        try:
            img,p = afis_print.generate([a],[0.0],['ambient'],guide_region=gg,
                                        ambient_burst=[a],flash_burst=[f0],
                                        freq_normalize=True,stack_cache={})
            res[arm]=(nfiq2(img), p.get('afisMask'))
        except Exception as e:
            res[arm]=(None,'ERR:%s'%str(e)[:40])
    afis_print._flash_diff_mask, afis_print._unet_mask = _FD, _UN
    pv,bv,dv = res['prod'][0], res['bare'][0], res['dilated'][0]
    print("  %s  refined=%-6s %-18s bare-guide=%-6s dilated-guide=%-6s"
          % (cid[:8], pv, res['prod'][1], bv, dv), flush=True)
    out.append(dict(id=cid[:8], prod=pv, prod_mask=res['prod'][1], bare=bv, dilated=dv))
    json.dump(out, open(os.path.join(HERE,'results','mask_arm3_dilated.json'),'w'), indent=1)

import statistics as st
tri=[(o['prod'],o['bare'],o['dilated']) for o in out
     if None not in (o['prod'],o['bare'],o['dilated'])]
if tri:
    print("\n  n=%d   refined %.2f   bare guide %.2f   dilated guide %.2f"
          % (len(tri), st.mean([t[0] for t in tri]), st.mean([t[1] for t in tri]),
             st.mean([t[2] for t in tri])))
pair=[]
if pair:
    pv=[x[0] for x in pair]; bv=[x[1] for x in pair]
    better=sum(1 for a,b in pair[:0] or zip(pv,bv) if a>b); worse=sum(1 for a,b in zip(pv,bv) if a<b)
    print("\n  n=%d   refined mean=%.2f   bare-guide mean=%.2f   delta=%+.2f"
          % (len(pv), statistics.mean(pv), statistics.mean(bv),
             statistics.mean(pv)-statistics.mean(bv)))
    print("  refined better on %d, worse on %d, tied on %d"
          % (better, worse, len(pv)-better-worse))
    for tag in ('guide+flashdiff','guide+unet'):
        sub=[(a,b) for a,b,m in pair if m==tag]
        if sub:
            print("    %-16s n=%-3d refined mean=%.1f  bare mean=%.1f  delta=%+.1f"
                  % (tag,len(sub),statistics.mean([x[0] for x in sub]),
                     statistics.mean([x[1] for x in sub]),
                     statistics.mean([x[0]-x[1] for x in sub])))
