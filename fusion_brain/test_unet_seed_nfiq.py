"""Does recovering 474b4d6a's mask actually produce a BETTER print, or just a
different label? Round 43's crease work is the cautionary precedent: a
correct mask fix moved NFIQ2 the WRONG way, and shipping on the label alone
would have been wrong.

Runs the real production candidate through afis_print.generate() with
`_unet_mask` monkeypatched to the seeded-or-argmax rule, against production
as-is, on every U-Net-path capture -- so any regression on the 12 unchanged
ones would show up too.
"""
import os, sys, json, subprocess, tempfile, statistics
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print, sfm_pipeline  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
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

_ORIG = afis_print._unet_mask
_GUIDE = {}

def _patched(gray):
    """seeded-or-argmax: prefer the component under the guide centre, fall
    back to production's argmax(area) when that pick is unusable."""
    g = _GUIDE.get('g')
    sess = sfm_pipeline._get_thumb_seg_session()
    if sess is None or g is None: return _ORIG(gray)
    size = sfm_pipeline._THUMB_SEG_IMG_SIZE
    small = cv2.resize(gray,(size,size)).astype(np.float32)/255.0
    logits = sess.run(['logits'],{'input':small[None,None]})[0][0,0]
    m = ((1.0/(1.0+np.exp(-logits)))>0.5).astype(np.uint8)*255
    m = cv2.resize(m,(gray.shape[1],gray.shape[0]),interpolation=cv2.INTER_NEAREST)
    m = cv2.morphologyEx(m,cv2.MORPH_CLOSE,np.ones((31,31),np.uint8))
    m = cv2.morphologyEx(m,cv2.MORPH_OPEN,np.ones((21,21),np.uint8))
    n,lab,stats,cents = cv2.connectedComponentsWithStats(m)
    if n<=1: return _ORIG(gray)
    h,w = gray.shape
    gx=min(w-1,max(0,g['cx']*w)); gy=min(h-1,max(0,g['cy']*h))
    idx=int(lab[int(gy),int(gx)])
    if idx==0:
        d=[np.hypot(cents[i][0]-gx,cents[i][1]-gy) for i in range(1,n)]
        idx=1+int(np.argmin(d))
    cand=(lab==idx).astype(np.uint8)*255
    if (cand>0).mean()>=0.03: return cand
    return _ORIG(gray)

# Only the captures where the two arms actually pick a different component
# need the expensive 2-arm render; on the other 8 the picks are provably
# identical so the output would be too. Two of those are kept anyway as
# controls, to verify that "identical pick" really does mean identical score
# rather than something else varying underneath.
_all = json.load(open(os.path.join(HERE,'results','unet_guide_seed.json')))
CHANGED = [r['id'] for r in _all if r['argmax'] != r['seeded']]
CONTROL = [r['id'] for r in _all if r['argmax'] == r['seeded']][:2]
ids = CHANGED + CONTROL
print("changed:", CHANGED, " controls:", CONTROL)
caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1' or s.id[:8] not in ids: continue
    caps.append((s.id,d,d.get('guideRegion'),d.get('frames')))
caps.sort(key=lambda c: str(c[1].get('createdAt')))

out=[]
for cid,d,g,fr in caps:
    amb=[f for f in fr if not f.get('flashOn')]; fl=[f for f in fr if f.get('flashOn')]
    if not amb or not fl: continue
    a=fetch(amb[0]['path']); f0=fetch(fl[0]['path'])
    if a is None or f0 is None or a.shape!=f0.shape: continue
    res={}
    for arm in ('prod','seeded'):
        afis_print._unet_mask = _ORIG if arm=='prod' else _patched
        _GUIDE['g']=g
        try:
            img,p = afis_print.generate([a],[0.0],['ambient'],guide_region=g,
                                        ambient_burst=[a], flash_burst=[f0],
                                        freq_normalize=True, stack_cache={})
            res[arm]=(nfiq2(img), p.get('afisMask'))
        except Exception as e:
            res[arm]=(None,'ERR:%s'%e)
    afis_print._unet_mask=_ORIG
    ch = '  <-- CHANGED' if res['prod']!=res['seeded'] else ''
    print("  %s  prod=%-6s %-16s   seeded=%-6s %-16s%s"
          % (cid[:8],res['prod'][0],res['prod'][1],res['seeded'][0],res['seeded'][1],ch))
    out.append(dict(id=cid[:8],prod=res['prod'],seeded=res['seeded']))

json.dump(out,open(os.path.join(HERE,'results','unet_seed_nfiq.json'),'w'),indent=1)
pv=[o['prod'][0] for o in out if o['prod'][0] is not None and o['seeded'][0] is not None]
sv=[o['seeded'][0] for o in out if o['prod'][0] is not None and o['seeded'][0] is not None]
if pv:
    better=sum(1 for a,b in zip(pv,sv) if b>a); worse=sum(1 for a,b in zip(pv,sv) if b<a)
    print("\n  n=%d  prod mean=%.2f  seeded mean=%.2f  delta=%+.2f  (%d better / %d worse)"
          % (len(pv),statistics.mean(pv),statistics.mean(sv),
             statistics.mean(sv)-statistics.mean(pv),better,worse))
