"""Real A/B: production U-Net (bad, unseeded pseudo-labels) vs the retrained
checkpoint (seeded flash-diff labels, round 45's own root-cause fix). Same
24-capture real population round 45 used, same `_unet_mask` code path,
`_UNET_GUIDE_SEED_ENABLED` left exactly as production has it (False) so
this isolates the retrain's own effect, not the separate inference-time
patch. Primary gate: does the new model correctly localize on the 4 known
failures (474b4d6a, 4ae6d13c, 1d186afc, 80a994ca)? Secondary: real NFIQ2
delta on the full 24-capture set.
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
MIN_DATE = '2026-08-17'
KNOWN_FAILURES = {'474b4d6a', '4ae6d13c', '1d186afc', '80a994ca'}
ONNX_PATH = sfm_pipeline._THUMB_SEG_ONNX_PATH
OLD_BACKUP = '/tmp/thumb_seg_unet_OLD_backup.onnx'
NEW_MODEL = '/tmp/thumb_seg_unet_seeded.onnx'

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
    d = s.to_dict() or {}
    if d.get('captureMode') != 'front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g, fr = d.get('guideRegion'), d.get('frames')
    if isinstance(g, dict) and isinstance(fr, list) and fr:
        caps.append((s.id, d, g, fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))
print("%d real front_only_v1 captures\n" % len(caps))

D = afis_print._MASK_COVER_DILATE

def run_arm(label):
    sfm_pipeline._thumb_seg_session = None
    sfm_pipeline._thumb_seg_unavailable = False
    rows = []
    for cid, d, g, fr in caps:
        amb = [f for f in fr if not f.get('flashOn')]
        if not amb: continue
        a = fetch(amb[0]['path'])
        if a is None: continue
        gm = afis_print._superellipse_mask(a.shape[:2], g)
        bd = afis_print._superellipse_mask(a.shape[:2], {
            **g, 'rx': float(g['rx']) * D, 'ry': float(g['ry']) * D})
        if gm is None or bd is None: continue
        ga = float((gm > 0).sum()); ba = float((bd > 0).sum())
        # Force the U-Net path specifically -- guide_region=None matches
        # production's real _UNET_GUIDE_SEED_ENABLED=False call exactly.
        pad = afis_print._unet_mask(a, None)
        if pad is None:
            rows.append(dict(id=cid[:8], detected=False, cov_over_guide=0.0, accepted=False))
            print("  [%s] %s  NO DETECTION (mask returned None)" % (label, cid[:8]))
            continue
        pad = afis_print._fill_mask_holes(pad)
        cov = float((cv2.bitwise_and(pad, bd) > 0).sum())
        cov_over_guide = cov / ga
        accepted = (0.35 * ga <= cov <= 0.92 * ba)
        rows.append(dict(id=cid[:8], detected=True, cov_over_guide=cov_over_guide,
                          accepted=bool(accepted)))
        flag = '  <-- KNOWN FAILURE CAPTURE' if cid[:8] in KNOWN_FAILURES else ''
        print("  [%s] %s  cov_over_guide=%.3f  accepted=%s%s"
              % (label, cid[:8], cov_over_guide, accepted, flag))
    return rows

# Arm 1: production model (already at ONNX_PATH)
shutil.copy(ONNX_PATH, OLD_BACKUP)
print("=== OLD (production) model ===")
old_rows = run_arm('OLD')

# Arm 2: swap in the retrained model
shutil.copy(NEW_MODEL, ONNX_PATH)
print("\n=== NEW (seeded-label retrain) model ===")
new_rows = run_arm('NEW')

# Restore production model file untouched
shutil.copy(OLD_BACKUP, ONNX_PATH)
sfm_pipeline._thumb_seg_session = None
sfm_pipeline._thumb_seg_unavailable = False
os.remove(OLD_BACKUP)
print("\n(production ONNX file restored)")

old_by_id = {r['id']: r for r in old_rows}
new_by_id = {r['id']: r for r in new_rows}

print("\n=== KNOWN FAILURE CAPTURES: localization before/after ===")
for cid in sorted(KNOWN_FAILURES):
    o = old_by_id.get(cid); n = new_by_id.get(cid)
    print("  %s  OLD: detected=%s cov=%.3f accepted=%s   ->   NEW: detected=%s cov=%.3f accepted=%s"
          % (cid,
             o['detected'] if o else '?', o['cov_over_guide'] if o else -1, o['accepted'] if o else '?',
             n['detected'] if n else '?', n['cov_over_guide'] if n else -1, n['accepted'] if n else '?'))

n_old_fail = sum(1 for r in old_rows if not r['accepted'])
n_new_fail = sum(1 for r in new_rows if not r['accepted'])
print("\n=== OVERALL LOCALIZATION (accepted = mask overlaps guide plausibly) ===")
print("  OLD model: %d/%d fail (%.0f%%)" % (n_old_fail, len(old_rows), 100*n_old_fail/len(old_rows)))
print("  NEW model: %d/%d fail (%.0f%%)" % (n_new_fail, len(new_rows), 100*n_new_fail/len(new_rows)))

json.dump({'old': old_rows, 'new': new_rows},
          open(os.path.join(HERE, 'results', 'ab_unet_seeded_labels.json'), 'w'), indent=1)
