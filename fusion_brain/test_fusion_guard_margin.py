"""Layer 7: for the 3 real captures where main.py's whole-frame fusion-
selection guard disagrees with a guide-region-restricted measurement (see
diag_fusion_guard_wholeframe.py), check what native vs fuseAvg/deepFuse
actually score in real NFIQ2 -- does the corrected guard's tighter
detection land in the "would have blocked a low-margin fusion win" zone
main.py's guard is meant to guard, or is it moot (fusion already clears
+3.0 either way)?
"""
import os, sys, json
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
import subprocess, tempfile

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()
CACHE = os.path.join(HERE, 'results', 'cache', 'mask')

TARGET = {'a262d2b3', '1cc301a8', 'c27d0004'}

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
    if s.id[:8] not in TARGET: continue
    d=s.to_dict() or {}
    g,fr=d.get('guideRegion'),d.get('frames')
    if isinstance(g,dict) and isinstance(fr,list) and fr: caps.append((s.id,d,g,fr))

for cid,d,g,fr in caps:
    amb=[f for f in fr if not f.get('flashOn')]; fl=[f for f in fr if f.get('flashOn')]
    a=fetch(amb[0]['path']); f0=fetch(fl[0]['path'])
    amb_burst=[x for x in (fetch(f['path']) for f in amb) if x is not None]
    fl_burst=[x for x in (fetch(f['path']) for f in fl) if x is not None]
    out={}
    for name,kw in (('native',dict()),
                     ('fuseAvg',dict(fuse='avg')),
                     ('deepFuse',dict(fuse='deep', freq_normalize=True, freq_scale_min=0.9))):
        img,p = afis_print.generate([a],[0.0],['ambient'],guide_region=g,
                                    ambient_frames=[a], flash_frames=[f0],
                                    ambient_burst=amb_burst, flash_burst=fl_burst,
                                    stack_cache={}, **kw)
        out[name]=nfiq2(img)
    print("  %s  native=%-6s fuseAvg=%-6s(%s) deepFuse=%-6s(%s)"
          % (cid[:8], out['native'],
             out['fuseAvg'], ('+%.1f'%(out['fuseAvg']-out['native']) if out['fuseAvg'] is not None and out['native'] is not None else '?'),
             out['deepFuse'], ('+%.1f'%(out['deepFuse']-out['native']) if out['deepFuse'] is not None and out['native'] is not None else '?')))
