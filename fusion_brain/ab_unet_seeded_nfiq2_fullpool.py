"""Corrected secondary NFIQ2 check: the original ab_unet_seeded_nfiq2.py
only ran the plain 'native' variant, which understates the real value of
the retrain -- a correctly-located mask feeds EVERY variant in production's
real max-of-variants loop (fuseAvg/fuseMaxc/deepFuse/deepMaxc/freqNorm),
not just native. CTO caught this directly by asking why one real capture's
best achievable print (deepFuse, nfiq2=78) was so much better than what the
first pass showed (native only, nfiq2=32). Rerunning the full pool, old vs
new model, same 13 real unet-routed captures, max-of-variants per capture
-- matching what main.py's real selection loop actually does.
"""
import os, sys, json, shutil, subprocess, tempfile
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402
import sfm_pipeline  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
ONNX_PATH = sfm_pipeline._THUMB_SEG_ONNX_PATH
OLD_BACKUP = '/tmp/thumb_seg_unet_OLD_backup5.onnx'
NEW_MODEL = '/tmp/thumb_seg_unet_seeded.onnx'

UNET_IDS = ['01662ffb', '181e8cd8', '1c019820', '1d186afc', '474b4d6a', '4ae6d13c',
            '5363a49b', '774f2252', '80a994ca', 'b615f37b', 'd0ec5195', 'e50047c7', 'eacb0b2c']

VARIANTS = (
    ('native', dict()),
    ('freqNorm', dict(freq_normalize=True, freq_scale_min=0.9)),
    ('fuseAvg', dict(fuse='avg')),
    ('fuseMaxc', dict(fuse='maxc')),
    ('deepFuse', dict(fuse='deep', freq_normalize=True, freq_scale_min=0.9)),
    ('deepMaxc', dict(fuse='deepMaxc', freq_normalize=True, freq_scale_min=0.9)),
)

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
    if s.id[:8] not in UNET_IDS: continue
    d = s.to_dict() or {}
    g, fr = d.get('guideRegion'), d.get('frames')
    if isinstance(g, dict) and isinstance(fr, list) and fr:
        caps.append((s.id, d, g, fr))

def run_arm(label):
    sfm_pipeline._thumb_seg_session = None
    sfm_pipeline._thumb_seg_unavailable = False
    out = {}
    for cid, d, g, fr in caps:
        amb = [f for f in fr if not f.get('flashOn')]
        fl = [f for f in fr if f.get('flashOn')]
        if not amb: continue
        a = fetch(amb[0]['path'])
        f0 = fetch(fl[0]['path']) if fl else None
        amb_burst = [x for x in (fetch(x['path']) for x in amb) if x is not None]
        fl_burst = [x for x in (fetch(x['path']) for x in fl) if x is not None] if fl else []
        best = (None, None)
        for vname, kw in VARIANTS:
            img, p = afis_print.generate([a], [0.0], ['ambient'], guide_region=g,
                                          ambient_frames=[a], flash_frames=[f0] if f0 is not None else [a],
                                          ambient_burst=amb_burst, flash_burst=fl_burst,
                                          stack_cache={}, **kw)
            s = nfiq2(img)
            if s is not None and (best[0] is None or s > best[0]):
                best = (s, vname)
        out[cid[:8]] = best
        print("  [%s] %s  best=%s (%s)" % (label, cid[:8], best[0], best[1]))
    return out

shutil.copy(ONNX_PATH, OLD_BACKUP)
print("=== OLD (production) model, full variant pool, max-of-variants ===")
old = run_arm('OLD')

shutil.copy(NEW_MODEL, ONNX_PATH)
print("\n=== NEW (seeded-label retrain) model, full variant pool, max-of-variants ===")
new = run_arm('NEW')

shutil.copy(OLD_BACKUP, ONNX_PATH)
sfm_pipeline._thumb_seg_session = None
sfm_pipeline._thumb_seg_unavailable = False
os.remove(OLD_BACKUP)
print("\n(production ONNX file restored)")

print("\n=== DELTAS (max-of-variants, real production selection behavior) ===")
deltas = []
for cid in old:
    o, ov = old[cid]; n, nv = new.get(cid, (None, None))
    if o is not None and n is not None:
        deltas.append(n - o)
    print("  %s  OLD=%-6s(%s)  NEW=%-6s(%s)  delta=%s"
          % (cid, o, ov, n, nv, ('%+.0f' % (n-o)) if (o is not None and n is not None) else '?'))
if deltas:
    print("\n  n=%d  mean delta=%+.2f  better=%d worse=%d tied=%d"
          % (len(deltas), sum(deltas)/len(deltas),
             sum(1 for x in deltas if x > 0), sum(1 for x in deltas if x < 0),
             sum(1 for x in deltas if x == 0)))

json.dump({'old': old, 'new': new}, open(os.path.join(HERE, 'results', 'ab_unet_seeded_nfiq2_fullpool.json'), 'w'), indent=1)
