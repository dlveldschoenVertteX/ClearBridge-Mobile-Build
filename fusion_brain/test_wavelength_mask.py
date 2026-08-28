"""Layer 4: does mask-restricted wavelength estimation actually change NFIQ2?

diag_wavelength_mask_leak.py established the estimate itself is 96%
background-driven and moves >=1px on 11/23 captures once restricted to the
pad. That is necessary but not sufficient -- this project's own standing
lesson (round 43's crease-trim, round 45's masking control) is that a
correct-looking measurement fix still needs a real NFIQ2/matchability check
before shipping, because the direction isn't always obvious.

Runs the ACTUAL shipped generate() (not a reimplementation) with
_WAVELENGTH_MASK_RESTRICT toggled True/False, same real captures, same guide,
same freq_normalize=True every production variant uses, real NFIQ2 binary.
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

caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g,fr=d.get('guideRegion'),d.get('frames')
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
    for arm in ('prod','masked'):
        afis_print._WAVELENGTH_MASK_RESTRICT = (arm == 'masked')
        try:
            img,p = afis_print.generate([a],[0.0],['ambient'],guide_region=g,
                                        ambient_burst=[a],flash_burst=[f0],
                                        freq_normalize=True,stack_cache={})
            res[arm]=(nfiq2(img), p.get('afisWavelengthPx'), p.get('afisFreqScale'))
        except Exception as e:
            res[arm]=(None,None,'ERR:%s'%str(e)[:40])
    afis_print._WAVELENGTH_MASK_RESTRICT = False
    pv,pw,psc = res['prod']; mv,mw,msc = res['masked']
    dl = ('%+.0f'%(mv-pv)) if (pv is not None and mv is not None) else '?'
    print("  %s  prod: nfiq2=%-6s wl=%-6s scale=%-6s   masked: nfiq2=%-6s wl=%-6s scale=%-6s   delta=%s"
          % (cid[:8], pv, pw, psc, mv, mw, msc, dl), flush=True)
    out.append(dict(id=cid[:8], prod_nfiq2=pv, prod_wl=pw, prod_scale=psc,
                    masked_nfiq2=mv, masked_wl=mw, masked_scale=msc))
    json.dump(out, open(os.path.join(HERE,'results','wavelength_mask_test.json'),'w'), indent=1)

pair=[(o['prod_nfiq2'],o['masked_nfiq2']) for o in out
      if o['prod_nfiq2'] is not None and o['masked_nfiq2'] is not None]
if pair:
    pv=[x[0] for x in pair]; mv=[x[1] for x in pair]
    better=sum(1 for a,b in pair if b>a); worse=sum(1 for a,b in pair if b<a)
    print("\n  n=%d   prod mean=%.2f   masked mean=%.2f   delta=%+.2f"
          % (len(pair), statistics.mean(pv), statistics.mean(mv), statistics.mean(mv)-statistics.mean(pv)))
    print("  masked better on %d, worse on %d, tied on %d" % (better, worse, len(pair)-better-worse))
