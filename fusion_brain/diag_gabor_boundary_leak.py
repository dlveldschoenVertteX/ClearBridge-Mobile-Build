"""Layer 5 (enhancement): does the default Gabor path leak background into
real pad content near the mask edge?

The default enhance='gabor' branch (afis_print.py, every production
variant that has ever won selection routes through this) computes:
    norm = _normalize(g8)          # FULL FRAME, g8 unmasked
    orient = _orientation_field(norm)   # boxFilter(_BLOCK=16) + Gaussian(_ORIENT_SMOOTH=15)
    enh = _gabor_enhance(norm, orient, wl)   # kernel radius ~18-39px at wl 9-20

Only AFTER this does `binimg[mask==0]=255` discard the background OUTPUT.
But orientation/Gabor at a PAD pixel within the smoothing/kernel radius of
the boundary is computed from background CONTENT still sitting in the
input, since neither function is mask-aware. `_FADE_INSET_PX=25` is exactly
the band width where a fed-through Gabor response reaches the final print,
which overlaps the ~15-40px reach of these operators -- so real, delivered
ridge content near the pad edge can be measurably background-influenced,
not just wasted computation on discarded output.

This is a DIFFERENT intervention from Phase 7-8's already-refuted
"mask-aware _normalize" (byte-identical there, because _normalize reduces
to a pure global affine map). Grey-filling suppresses local GRADIENT/
CONTRAST content the orientation field and Gabor kernel actually respond
to -- neither of which _normalize's global mean/var touches.

Fills background with the in-mask mean (not white/black, to avoid creating
a NEW hard high-contrast edge at the boundary that Gabor could itself treat
as a spurious ridge) and feathers the fill boundary over the same
_FADE_INSET_PX distance production already uses downstream, so this cannot
introduce a discontinuity the pipeline doesn't already tolerate elsewhere.

Gated behind a flag, tested end-to-end against real NFIQ2 on the shipped
generate() -- same discipline as rounds 45/46.
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
CACHE = os.path.join(HERE, 'results', 'cache', 'mask')

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
    for arm in ('prod','feathered'):
        afis_print._GABOR_BOUNDARY_FEATHER = (arm == 'feathered')
        try:
            img,p = afis_print.generate([a],[0.0],['ambient'],guide_region=g,
                                        ambient_burst=[a],flash_burst=[f0],
                                        freq_normalize=True,stack_cache={})
            res[arm]=(nfiq2(img), p.get('afisMask'))
        except Exception as e:
            res[arm]=(None,'ERR:%s'%str(e)[:40])
    afis_print._GABOR_BOUNDARY_FEATHER = False
    pv,pm = res['prod']; fv,fm = res['feathered']
    dl = ('%+.0f'%(fv-pv)) if (pv is not None and fv is not None) else '?'
    print("  %s  prod=%-6s   feathered=%-6s   delta=%s" % (cid[:8], pv, fv, dl), flush=True)
    out.append(dict(id=cid[:8], prod=pv, feathered=fv))
    json.dump(out, open(os.path.join(HERE,'results','gabor_boundary_test.json'),'w'), indent=1)

pair=[(o['prod'],o['feathered']) for o in out if o['prod'] is not None and o['feathered'] is not None]
if pair:
    pv=[x[0] for x in pair]; fv=[x[1] for x in pair]
    better=sum(1 for a,b in pair if b>a); worse=sum(1 for a,b in pair if b<a)
    print("\n  n=%d   prod mean=%.2f   feathered mean=%.2f   delta=%+.2f"
          % (len(pair), statistics.mean(pv), statistics.mean(fv), statistics.mean(fv)-statistics.mean(pv)))
    print("  feathered better on %d, worse on %d, tied on %d" % (better, worse, len(pair)-better-worse))
