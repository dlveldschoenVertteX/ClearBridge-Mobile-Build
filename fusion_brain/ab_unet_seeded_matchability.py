"""Real matchability check (SourceAFIS, not NFIQ2) for the U-Net seeded-
label retrain -- CTO directly asked to test matchability rather than trust
NFIQ2 alone, per this whole project's own standing prime directive.

Two real genuine cross-session pairs exist inside the 13-capture unet-
routed population itself (same userId, two real captures each):
  pair A: 4ae6d13c + 5363a49b  (one of the two localization-FIXED captures)
  pair B: 1d186afc + b615f37b  (1d186afc is one of the two STILL-FAILING
          captures -- included specifically to see whether the retrain
          changes anything for a capture it didn't actually fix)

For each of the 4 captures, renders the best-of-variant-pool print (same
method that found deepFuse=78 for 80a994ca) under OLD and NEW models, then
scores:
  - genuine: pair A and pair B, old-vs-old and new-vs-new
  - impostor: each of the 4 test captures against a real impostor pool
    (8 other real captures NOT in this test set, reusing cached raw
    frames), old-vs-old and new-vs-new
"""
import os, sys, json, shutil, subprocess, tempfile, re
import cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402
import sfm_pipeline  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
NFIQ2_MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
JAR = os.path.join(HERE, '..', 'scratchpad', 'sourceafis', 'target', 'sourceafis-matcher.jar')
ONNX_PATH = sfm_pipeline._THUMB_SEG_ONNX_PATH
OLD_BACKUP = '/tmp/thumb_seg_unet_OLD_backup_match.onnx'
NEW_MODEL = '/tmp/thumb_seg_unet_seeded.onnx'
CACHE = os.path.join(HERE, 'results', 'cache', 'mask')
IMGDIR = '/tmp/unet_match_imgs'
os.makedirs(IMGDIR, exist_ok=True)

GENUINE_PAIRS = [('4ae6d13c', '5363a49b'), ('1d186afc', 'b615f37b')]
TEST_IDS = ['4ae6d13c', '5363a49b', '1d186afc', 'b615f37b']
IMPOSTOR_IDS = ['e33d618e', 'a262d2b3', '01662ffb', 'fc142f97', '1cc301a8',
                'c27d0004', 'f4cb3ba5', '286f1f0a']

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

def fetch(p):
    l = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(l): bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

def nfiq2(img):
    if img is None: return None
    r = cv2.resize(img, (500, 500), interpolation=cv2.INTER_LANCZOS4)
    f = tempfile.NamedTemporaryFile(suffix='.png', delete=False); cv2.imwrite(f.name, r)
    try:
        o = subprocess.run([NFIQ2,'-m',NFIQ2_MODEL,'-i',f.name,'-F'],capture_output=True,text=True,timeout=180)
        for t in o.stdout.replace(',',' ').split():
            try: v=float(t)
            except ValueError: continue
            if 0.0<=v<=100.0: return v
    finally: os.unlink(f.name)

def safis(probe, gallery, dpi=500.0):
    out = subprocess.run(['java', '-jar', JAR, probe, gallery, str(dpi)],
                          capture_output=True, text=True, timeout=60)
    m = re.search(r'^score=([\d.]+)$', out.stdout, re.M)
    return float(m.group(1)) if m else None

def get_doc(cid_prefix):
    for s in db.collection('captures').stream():
        if s.id.startswith(cid_prefix):
            return s.to_dict()
    return None

def render_best(cid_prefix, label):
    d = get_doc(cid_prefix)
    g = d['guideRegion']; fr = d['frames']
    amb = [f for f in fr if not f.get('flashOn')]
    fl = [f for f in fr if f.get('flashOn')]
    a = fetch(amb[0]['path'])
    f0 = fetch(fl[0]['path']) if fl else None
    amb_burst = [x for x in (fetch(x['path']) for x in amb) if x is not None]
    fl_burst = [x for x in (fetch(x['path']) for x in fl) if x is not None] if fl else []
    best = (None, None, None)
    for vname, kw in VARIANTS:
        img, p = afis_print.generate([a], [0.0], ['ambient'], guide_region=g,
                                      ambient_frames=[a], flash_frames=[f0] if f0 is not None else [a],
                                      ambient_burst=amb_burst, flash_burst=fl_burst,
                                      stack_cache={}, **kw)
        s = nfiq2(img)
        if s is not None and (best[0] is None or s > best[0]):
            best = (s, vname, img)
    out = os.path.join(IMGDIR, '%s_%s.png' % (cid_prefix, label))
    if best[2] is not None:
        cv2.imwrite(out, best[2])
    print("  render %s [%s]  nfiq2=%s variant=%s -> %s" % (cid_prefix, label, best[0], best[1], out))
    return out, best[0]

# Impostor pool: render once, native-only (fast, cheap, just needs to be a
# real different-finger reference, not necessarily each impostor's own best)
def render_impostor(cid_prefix):
    out = os.path.join(IMGDIR, 'impostor_%s.png' % cid_prefix)
    if os.path.exists(out):
        return out
    d = get_doc(cid_prefix)
    g = d['guideRegion']; fr = d['frames']
    amb = [f for f in fr if not f.get('flashOn')]
    a = fetch(amb[0]['path'])
    img, p = afis_print.generate([a], [0.0], ['ambient'], guide_region=g,
                                  ambient_frames=[a], flash_frames=[a],
                                  freq_normalize=True, freq_scale_min=0.9, stack_cache={})
    if img is not None:
        cv2.imwrite(out, img)
    return out

results = {'genuine': {}, 'impostor': {}}

shutil.copy(ONNX_PATH, OLD_BACKUP)

for arm, model_path in (('old', OLD_BACKUP), ('new', NEW_MODEL)):
    shutil.copy(model_path, ONNX_PATH)
    sfm_pipeline._thumb_seg_session = None
    sfm_pipeline._thumb_seg_unavailable = False
    print("\n=== %s model: rendering test captures ===" % arm.upper())
    paths = {}
    for cid in TEST_IDS:
        p, s = render_best(cid, arm)
        paths[cid] = (p, s)
    print("=== %s model: rendering impostor pool ===" % arm.upper())
    imp_paths = [render_impostor(cid) for cid in IMPOSTOR_IDS]

    print("=== %s model: genuine pair scores ===" % arm.upper())
    for a_id, b_id in GENUINE_PAIRS:
        pa, sa = paths[a_id]; pb, sb = paths[b_id]
        score = safis(pa, pb) if (os.path.exists(pa) and os.path.exists(pb)) else None
        key = '%s_x_%s' % (a_id, b_id)
        results['genuine'].setdefault(key, {})[arm] = score
        print("  %s vs %s  (nfiq2 %s/%s)  SourceAFIS=%s" % (a_id, b_id, sa, sb, score))

    print("=== %s model: impostor scores (max per test capture) ===" % arm.upper())
    for cid in TEST_IDS:
        p, s = paths[cid]
        if not os.path.exists(p): continue
        scores = [x for x in (safis(p, ip) for ip in imp_paths if os.path.exists(ip)) if x is not None]
        mx = max(scores) if scores else None
        mean = sum(scores)/len(scores) if scores else None
        results['impostor'].setdefault(cid, {})[arm] = dict(max=mx, mean=mean, n=len(scores))
        print("  %s vs impostor pool (n=%d)  mean=%.2f max=%.2f" % (cid, len(scores), mean or 0, mx or 0))

shutil.copy(OLD_BACKUP, ONNX_PATH)
sfm_pipeline._thumb_seg_session = None
sfm_pipeline._thumb_seg_unavailable = False
os.remove(OLD_BACKUP)
print("\n(production ONNX file restored)")

print("\n=== SUMMARY ===")
print("Genuine pair scores (old vs new):")
for k, v in results['genuine'].items():
    print("  %s  OLD=%s  NEW=%s" % (k, v.get('old'), v.get('new')))
print("Impostor max scores (old vs new):")
for k, v in results['impostor'].items():
    o = v.get('old', {}); n = v.get('new', {})
    print("  %s  OLD max=%s mean=%.2f   NEW max=%s mean=%.2f"
          % (k, o.get('max'), o.get('mean') or 0, n.get('max'), n.get('mean') or 0))

json.dump(results, open(os.path.join(HERE, 'results', 'ab_unet_seeded_matchability.json'), 'w'), indent=1)
