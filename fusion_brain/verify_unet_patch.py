"""Verify the SHIPPED `_unet_mask` reproduces the harness result.

The harness (`test_unet_guide_seed.py`) used its own copy of the component
logic. This calls production's own patched function both ways to confirm the
code that will actually run behaves the same -- guarding against the classic
"validated a reimplementation, shipped something else" error this project has
hit before (round 42's first stack_policy_test).
"""
import os, sys, json
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()
CACHE = os.path.join(HERE, 'results', 'cache', 'mask')

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

ids = [r['id'] for r in json.load(open(os.path.join(HERE,'results','unet_guide_seed.json')))]
D = afis_print._MASK_COVER_DILATE
a_ok = s_ok = 0; n = 0
for s in db.collection('captures').stream():
    d = s.to_dict() or {}
    if d.get('captureMode') != 'front_only_v1' or s.id[:8] not in ids: continue
    g, fr = d.get('guideRegion'), d.get('frames') or []
    amb = [f for f in fr if not f.get('flashOn')]
    if not g or not amb: continue
    a = fetch(amb[0]['path'])
    if a is None: continue
    gm = afis_print._superellipse_mask(a.shape[:2], g)
    bd = afis_print._superellipse_mask(a.shape[:2], {**g, 'rx': g['rx']*D, 'ry': g['ry']*D})
    ga, ba = float((gm>0).sum()), float((bd>0).sum())
    verd = {}
    for arm, gr in (('argmax', None), ('shipped', g)):
        m = afis_print._unet_mask(a, gr)
        if m is None: verd[arm] = 'no-mask'; continue
        cov = float((cv2.bitwise_and(afis_print._fill_mask_holes(m), bd) > 0).sum())
        verd[arm] = 'ACCEPT' if (0.35*ga <= cov <= 0.92*ba) else 'reject'
    n += 1
    a_ok += verd['argmax'] == 'ACCEPT'; s_ok += verd['shipped'] == 'ACCEPT'
    if verd['argmax'] != verd['shipped']:
        print("  %s  argmax=%-7s -> shipped=%s" % (s.id[:8], verd['argmax'], verd['shipped']))
print("\n  n=%d   argmax(area) located the pad on %d   shipped code on %d" % (n, a_ok, s_ok))
print("  harness predicted 9 -> 10; shipped %s" % ("MATCHES" if (a_ok, s_ok) == (9, 10) else "DIFFERS"))
