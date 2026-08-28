"""Layer 7 (variant selection): does main.py's own fusion-selection sharpness
guard (`_fusion_guarded`, main.py ~1297-1308) measure the ratio correctly?

The guard's trigger is computed as:
    _amb_lap = Laplacian(ambient_frames[0]).var()   # WHOLE FRAME, no mask
    _fl_lap  = Laplacian(flash_frames[0]).var()      # WHOLE FRAME, no mask
    _fusion_guarded = (_amb_lap / _fl_lap) >= _SHARPNESS_RATIO_GUARD (4.0)

This is the exact "measured on the whole frame instead of the pad crop"
defect pattern already found and fixed three times this pass (layer 3
masking, layer 4 wavelength, layer 6's own flash_pair_sharpness_ratio,
whose own docstring states plainly: "a whole-frame Laplacian is dominated
by background texture and says almost nothing about the ridge content the
fusion actually operates on"). Layer 6 built the CORRECT version
(flash_pair_sharpness_ratio, guide-region-restricted) and used it inside
afis_print.py's own fuse call sites -- but never went back to check
whether main.py's OWN, separate, pre-existing sharpness guard (built
2026-07-23, predating flash_pair_sharpness_ratio) has the same defect.

This script measures, on the same real front_only_v1 population already
cached locally (fusion_brain/results/cache/mask, amb[0]/fl[0] per
capture): does restricting the SAME frame pair to guide_region change
whether main.py's own guard (threshold 4.0) would fire, vs its current
whole-frame measurement? Diagnostic only -- no fix applied yet.
"""
import os, sys, json
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

MIN_DATE = '2026-08-17'
SHARPNESS_RATIO_GUARD = 4.0  # main.py's own _SHARPNESS_RATIO_GUARD

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()
CACHE = os.path.join(HERE, 'results', 'cache', 'mask')

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

def wholeframe_ratio(amb, fl):
    la = float(cv2.Laplacian(amb, cv2.CV_64F).var())
    lf = float(cv2.Laplacian(fl, cv2.CV_64F).var())
    if lf <= 0:
        return None
    return la / lf

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
    wf = wholeframe_ratio(a, f0)
    gr = afis_print.flash_pair_sharpness_ratio(a, f0, g)
    wf_fires = isinstance(wf, float) and wf >= SHARPNESS_RATIO_GUARD
    gr_fires = isinstance(gr, float) and gr >= SHARPNESS_RATIO_GUARD
    flag = '' if wf_fires == gr_fires else '  <-- DISAGREE'
    rows.append(dict(id=cid[:8], wholeframe=wf, guideregion=gr,
                      wf_fires=wf_fires, gr_fires=gr_fires))
    print("  %s  wholeframe=%-7s guide=%-7s  wf_fires=%-5s gr_fires=%-5s%s"
          % (cid[:8], round(wf,2) if isinstance(wf,float) else wf,
             round(gr,2) if isinstance(gr,float) else gr, wf_fires, gr_fires, flag))

json.dump(rows, open(os.path.join(HERE,'results','fusion_guard_wholeframe_vs_guide.json'),'w'), indent=1)
n_disagree = sum(1 for r in rows if r['wf_fires'] != r['gr_fires'])
print("\n  n=%d captures, %d disagree on whether the guard fires (threshold %.1f)"
      % (len(rows), n_disagree, SHARPNESS_RATIO_GUARD))
