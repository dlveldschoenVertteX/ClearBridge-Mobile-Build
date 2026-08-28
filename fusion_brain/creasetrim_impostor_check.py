"""Real impostor-risk check: does the untrimmed (full-pad) b04942ef print
show elevated false-match risk vs a real impostor population, compared to
the crease-trimmed version? CTO asked to "check" the full-pad candidate
before making it the pipeline default.
"""
import os, sys, subprocess, re, json
import cv2, numpy as np
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

JAR = os.path.join(HERE, '..', 'scratchpad', 'sourceafis', 'target', 'sourceafis-matcher.jar')
CACHE = os.path.join(HERE, 'results', 'cache', 'mask')

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

def safis(probe, gallery, dpi=500.0):
    out = subprocess.run(['java', '-jar', JAR, probe, gallery, str(dpi)],
                          capture_output=True, text=True, timeout=60)
    m = re.search(r'^score=([\d.]+)$', out.stdout, re.M)
    return float(m.group(1)) if m else None

IMPOSTOR_IDS = ['d0ec5195', 'f4cb3ba5', '8ed1c600', '4ae6d13c', '1c019820',
                 '80a994ca', 'c27d0004', '181e8cd8']

caps = []
for s in db.collection('captures').stream():
    if s.id[:8] not in IMPOSTOR_IDS: continue
    d = s.to_dict() or {}
    g, fr = d.get('guideRegion'), d.get('frames')
    if isinstance(g, dict) and isinstance(fr, list) and fr:
        caps.append((s.id, d, g, fr))

impostor_paths = []
for cid, d, g, fr in caps:
    amb = [f for f in fr if not f.get('flashOn')]
    if not amb: continue
    a = fetch(amb[0]['path'])
    if a is None: continue
    img, p = afis_print.generate([a], [0.0], ['ambient'], guide_region=g,
                                  ambient_frames=[a], flash_frames=[a],
                                  freq_normalize=True, freq_scale_min=0.9,
                                  stack_cache={})
    if img is None: continue
    out = '/tmp/impostor_%s.png' % cid[:8]
    cv2.imwrite(out, img)
    impostor_paths.append((cid[:8], out))

print("real impostor pool: %d prints\n" % len(impostor_paths))
results = {}
for label, path in (('with_trim', '/tmp/b04942ef_with_trim.png'),
                     ('no_trim', '/tmp/b04942ef_no_trim.png')):
    scores = []
    for cid, ipath in impostor_paths:
        s = safis(path, ipath)
        scores.append(s)
        print("  %-10s vs impostor %s: %s" % (label, cid, s))
    finite = [s for s in scores if s is not None]
    results[label] = dict(scores=finite, mean=sum(finite)/len(finite) if finite else None,
                           max=max(finite) if finite else None)
    print("  %s: n=%d mean=%.2f max=%.2f\n" % (label, len(finite), results[label]['mean'], results[label]['max']))

json.dump(results, open(os.path.join(HERE, 'results', 'b04942ef_creasetrim_impostor_check.json'), 'w'), indent=1)
