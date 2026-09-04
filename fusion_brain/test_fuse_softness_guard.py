"""Layer 6 (fusion): apply the already-validated sweep flash-softness guard
to front_only_v1's own fuse variants.

`flash_pair_sharpness_ratio`/`_FLASH_PAIR_MAX_SHARPNESS_RATIO=2.0` was built
and calibrated 2026-08-12 on real sweep captures: every zone whose ambient+
flash pair actually fused scored LOWER than that zone's plain ambient frame
(5/5 zones, 2/2 mosaics, up to -13 NFIQ2, zero counter-examples) whenever the
flash frame ran softer than ~2.8x the ambient's own sharpness. This same
torch-blowout pattern is independently, repeatedly documented on the MAIN
front burst throughout this project's own history (round 42: ambient
Laplacian ~3.4x flash's, real ISO/exposure measurements) -- but the guard
was only ever wired into the sweep zone-fusion code path, never into
front_only_v1's own fuseAvg/fuseMaxc/fuseSoft/deepFuse/deepMaxc.

Tests the 'avg' fuse mode specifically -- a flat average with no per-block
adaptive selection, the mode most exposed to a blown-out flash frame
dragging the fused result down (maxc/soft already partially self-correct by
locally favoring whichever exposure is more coherent).

Runs the actual shipped generate() with _FUSE_FLASH_SOFTNESS_GUARD toggled,
same real captures already cached from rounds 45/46/47, real NFIQ2 binary.
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

# Narrowed to where the guard actually changes behaviour (ratio > 2.0, see
# diag_fuse_ratios.py) plus 3 controls where it's a provable no-op --
# _fuse_flash_ambient's own ECC registration is full-resolution (unlike
# _align_face_on_stack's downscaled version), so a full 24-capture x 2-arm
# run is impractical; this mirrors round 45's own narrowing.
_ratio_rows = {r[0]: r[1] for r in json.load(open(os.path.join(HERE,'results','fuse_ratios.json')))}
FIRES = [k for k,v in _ratio_rows.items() if isinstance(v,float) and v > afis_print._FLASH_PAIR_MAX_SHARPNESS_RATIO]
CONTROLS = [k for k,v in _ratio_rows.items() if isinstance(v,float) and v <= afis_print._FLASH_PAIR_MAX_SHARPNESS_RATIO][:3]
TARGET = set(FIRES + CONTROLS)
print("testing %d captures (%d guard-fires, %d controls)" % (len(TARGET), len(FIRES), len(CONTROLS)))

caps=[]
for s in db.collection('captures').stream():
    d=s.to_dict() or {}
    if d.get('captureMode')!='front_only_v1': continue
    if s.id[:8] not in TARGET: continue
    g,fr=d.get('guideRegion'),d.get('frames')
    if isinstance(g,dict) and isinstance(fr,list) and fr: caps.append((s.id,d,g,fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))
print("%d real captures on/after %s\n" % (len(caps), MIN_DATE))

out=[]
ratios=[]
for cid,d,g,fr in caps:
    amb=[f for f in fr if not f.get('flashOn')]; fl=[f for f in fr if f.get('flashOn')]
    if not amb or not fl: continue
    try: a=fetch(amb[0]['path']); f0=fetch(fl[0]['path'])
    except Exception as e: print("  %s download failed: %s"%(cid[:8],e)); continue
    if a is None or f0 is None or a.shape!=f0.shape: continue
    # Real production ALWAYS also passes the full preserved burst
    # (main.py's variant loop: ambient_burst=ambient_burst,
    # flash_burst=flash_burst on every variant call, fuse family included) --
    # so the guarded arm has the same real fallback pairs production would,
    # not just the single pre-selected pair. Fetch the rest of the burst too.
    amb_burst = [fetch(f['path']) for f in amb]
    fl_burst = [fetch(f['path']) for f in fl]
    amb_burst = [x for x in amb_burst if x is not None]
    fl_burst = [x for x in fl_burst if x is not None]
    ratio = afis_print.flash_pair_sharpness_ratio(a, f0, g)
    ratios.append(ratio)
    res={}
    for arm in ('prod','guarded'):
        afis_print._FUSE_FLASH_SOFTNESS_GUARD = (arm == 'guarded')
        try:
            img,p = afis_print.generate([a],[0.0],['ambient'],guide_region=g,
                                        ambient_frames=[a], flash_frames=[f0],
                                        ambient_burst=amb_burst, flash_burst=fl_burst,
                                        fuse='avg', freq_normalize=True, stack_cache={})
            res[arm]=(nfiq2(img), p.get('afisFused'), p.get('afisFuseSoftnessSkipped'))
        except Exception as e:
            res[arm]=(None,'ERR:%s'%str(e)[:40],None)
    afis_print._FUSE_FLASH_SOFTNESS_GUARD = False
    pv,pf,_ = res['prod']; gv,gf,gskip = res['guarded']
    dl = ('%+.0f'%(gv-pv)) if (pv is not None and gv is not None) else '?'
    print("  %s  ratio=%-6s prod: nfiq2=%-6s fused=%-6s   guarded: nfiq2=%-6s fused=%-6s skip=%-6s  delta=%s"
          % (cid[:8], round(ratio,2) if isinstance(ratio,float) else ratio, pv, pf, gv, gf, gskip, dl), flush=True)
    out.append(dict(id=cid[:8], ratio=ratio, prod=pv, prod_fused=pf, guarded=gv, guarded_fused=gf))
    json.dump(out, open(os.path.join(HERE,'results','fuse_softness_guard_test.json'),'w'), indent=1)

pair=[(o['prod'],o['guarded']) for o in out if o['prod'] is not None and o['guarded'] is not None]
if pair:
    pv=[x[0] for x in pair]; gv=[x[1] for x in pair]
    better=sum(1 for a,b in pair if b>a); worse=sum(1 for a,b in pair if b<a)
    print("\n  n=%d   prod mean=%.2f   guarded mean=%.2f   delta=%+.2f"
          % (len(pair), statistics.mean(pv), statistics.mean(gv), statistics.mean(gv)-statistics.mean(pv)))
    print("  guarded better on %d, worse on %d, tied on %d" % (better, worse, len(pair)-better-worse))
finite = [r for r in ratios if r is not None and r != float('inf')]
if finite:
    print("  ambient:flash sharpness ratio across population: min=%.2f median=%.2f max=%.2f  (guard fires above %.1f)"
          % (min(finite), statistics.median(finite), max(finite), afis_print._FLASH_PAIR_MAX_SHARPNESS_RATIO))
