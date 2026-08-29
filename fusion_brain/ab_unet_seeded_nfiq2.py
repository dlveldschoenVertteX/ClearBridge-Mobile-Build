"""Secondary check (per the retraining spec): real NFIQ2 delta on the 13
real captures that actually route to the U-Net in production (flash-diff
fails/unavailable on these -- see mask_contribution.json's own tag field),
old vs new checkpoint, through the REAL end-to-end generate() pipeline
(native variant), not just the isolated mask.
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
OLD_BACKUP = '/tmp/thumb_seg_unet_OLD_backup2.onnx'
NEW_MODEL = '/tmp/thumb_seg_unet_seeded.onnx'

UNET_IDS = ['01662ffb', '181e8cd8', '1c019820', '1d186afc', '474b4d6a', '4ae6d13c',
            '5363a49b', '774f2252', '80a994ca', 'b615f37b', 'd0ec5195', 'e50047c7', 'eacb0b2c']

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
        img, p = afis_print.generate([a], [0.0], ['ambient'], guide_region=g,
                                      ambient_frames=[a], flash_frames=[f0] if f0 is not None else [a],
                                      ambient_burst=amb_burst, flash_burst=fl_burst,
                                      stack_cache={})
        s = nfiq2(img)
        mask_used = p.get('afisMask')
        out[cid[:8]] = (s, mask_used)
        print("  [%s] %s  nfiq2=%s mask=%s" % (label, cid[:8], s, mask_used))
    return out

shutil.copy(ONNX_PATH, OLD_BACKUP)
print("=== OLD (production) model, real generate() ===")
old = run_arm('OLD')

shutil.copy(NEW_MODEL, ONNX_PATH)
print("\n=== NEW (seeded-label retrain) model, real generate() ===")
new = run_arm('NEW')

shutil.copy(OLD_BACKUP, ONNX_PATH)
sfm_pipeline._thumb_seg_session = None
sfm_pipeline._thumb_seg_unavailable = False
os.remove(OLD_BACKUP)
print("\n(production ONNX file restored)")

print("\n=== DELTAS ===")
deltas = []
for cid in old:
    o, om = old[cid]; n, nm = new.get(cid, (None, None))
    if o is not None and n is not None:
        deltas.append(n - o)
    print("  %s  OLD=%-6s(%s)  NEW=%-6s(%s)  delta=%s"
          % (cid, o, om, n, nm, ('%+.0f' % (n-o)) if (o is not None and n is not None) else '?'))
if deltas:
    print("\n  n=%d  mean delta=%+.2f  better=%d worse=%d tied=%d"
          % (len(deltas), sum(deltas)/len(deltas),
             sum(1 for x in deltas if x > 0), sum(1 for x in deltas if x < 0),
             sum(1 for x in deltas if x == 0)))

json.dump({'old': old, 'new': new}, open(os.path.join(HERE, 'results', 'ab_unet_seeded_nfiq2.json'), 'w'), indent=1)
