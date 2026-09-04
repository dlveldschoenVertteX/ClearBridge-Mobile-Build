"""Manual real-pipeline scoring of fusion_v1 capture 81ed8492 (2026-08-30
21:12 UTC). fusion_v1's production trigger is deliberately off, so this
capture never gets an automatic NFIQ2 score -- reproducing the real scoring
path locally, same discipline as every other fusion_brain review this
project has done. Uses the FULL variant pool for the front burst (native-
only was shown this session to understate real achievable quality -- see
80a994ca, native=32 vs deepFuse=78).
"""
import os, sys, json, subprocess, tempfile
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
CID = '81ed8492-d5c7-4886-bc85-a22cf8f89eb2'
CACHE = os.path.join(HERE, 'results', 'cache', '81ed8492')
os.makedirs(CACHE, exist_ok=True)
IMGDIR = '/tmp/81ed8492_imgs'
os.makedirs(IMGDIR, exist_ok=True)

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()

def fetch(p):
    l = os.path.join(CACHE, os.path.basename(p))
    if not os.path.exists(l):
        bucket.blob(p).download_to_filename(l)
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

d = db.collection('captures').document(CID).get().to_dict()
guide = d['guideRegion']
frames = d['frames']
amb = [f for f in frames if not f['flashOn']]
fl = [f for f in frames if f['flashOn']]
amb_imgs = [x for x in (fetch(f['path']) for f in amb) if x is not None]
fl_imgs = [x for x in (fetch(f['path']) for f in fl) if x is not None]

VARIANTS = (
    ('native', dict()),
    ('freqNorm', dict(freq_normalize=True, freq_scale_min=0.9)),
    ('fuseAvg', dict(fuse='avg')),
    ('fuseMaxc', dict(fuse='maxc')),
    ('deepFuse', dict(fuse='deep', freq_normalize=True, freq_scale_min=0.9)),
    ('deepMaxc', dict(fuse='deepMaxc', freq_normalize=True, freq_scale_min=0.9)),
)

print("=== FRONT BURST (guide=%s) ===" % {k: round(v,3) if isinstance(v,float) else v for k,v in guide.items()})
results = {}
best = (None, None, None)
stack_cache = {}
for name, kw in VARIANTS:
    img, p = afis_print.generate(amb_imgs, [0.0]*len(amb_imgs), ['ambient']*len(amb_imgs),
                                  guide_region=guide,
                                  ambient_frames=[amb_imgs[0]], flash_frames=[fl_imgs[0]] if fl_imgs else [amb_imgs[0]],
                                  ambient_burst=amb_imgs, flash_burst=fl_imgs,
                                  stack_cache=stack_cache, **kw)
    s = nfiq2(img)
    results['front_%s' % name] = (s, p.get('afisMask'), p.get('afisFused'))
    print("  %-10s nfiq2=%-6s mask=%-16s fused=%s" % (name, s, p.get('afisMask'), p.get('afisFused')))
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'front_%s' % name, img)

print("\n=== MACRO (camera 2, cx=0.66 cy=0.50 rx=0.13 ry=0.11) ===")
macro_guide = dict(cx=0.66, cy=0.50, rx=0.13, ry=0.11, tipAngleDeg=0.0)
macro = {f['tag']: fetch(f['path']) for f in d.get('macroShots', [])}
m_amb = macro.get('macro_amb_0'); m_fl = macro.get('macro_fl_0')
if m_amb is not None:
    fl_list = [m_fl] if m_fl is not None else [m_amb]
    img, p = afis_print.generate([m_amb], [0.0], ['ambient'], guide_region=macro_guide,
                                  ambient_frames=[m_amb], flash_frames=fl_list,
                                  ambient_burst=[m_amb], flash_burst=fl_list,
                                  stack_cache={})
    s = nfiq2(img)
    print("  native  nfiq2=%s mask=%s" % (s, p.get('afisMask')))
    results['macro_native'] = (s, p.get('afisMask'), None)
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'macro_native', img)

print("\n=== SWEEP ZONES ===")
fgr = d.get('fusionGuideRegions', {})
sweep = {f['tag']: fetch(f['path']) for f in d.get('sweepShots', [])}
for zone, gkey in (('left', 'sweep_left'), ('center', 'sweep_center'), ('right', 'sweep_right')):
    za = sweep.get('sweep_%s_amb' % zone)
    g = fgr.get(gkey)
    if za is None or g is None: continue
    zf = sweep.get('sweep_%s_fl' % zone)
    fl_list = [zf] if zf is not None else [za]
    img, p = afis_print.generate([za], [0.0], ['ambient'], guide_region=g,
                                  ambient_frames=[za], flash_frames=fl_list,
                                  ambient_burst=[za], flash_burst=fl_list,
                                  stack_cache={})
    s = nfiq2(img)
    print("  %-8s nfiq2=%s mask=%s" % (zone, s, p.get('afisMask')))
    results['sweep_%s' % zone] = (s, p.get('afisMask'), None)
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'sweep_%s' % zone, img)

print("\n=== TILT ZONES (using main guide as approximation) ===")
tilt = {f['tag']: fetch(f['path']) for f in d.get('tiltShots', [])}
main_g = fgr.get('main', guide)
for zone in ('left', 'tip', 'right'):
    ta = tilt.get('tilt_%s_amb' % zone)
    if ta is None: continue
    tf = tilt.get('tilt_%s_fl' % zone)
    fl_list = [tf] if tf is not None else [ta]
    img, p = afis_print.generate([ta], [0.0], ['ambient'], guide_region=main_g,
                                  ambient_frames=[ta], flash_frames=fl_list,
                                  ambient_burst=[ta], flash_burst=fl_list,
                                  stack_cache={})
    s = nfiq2(img)
    print("  %-8s nfiq2=%s mask=%s" % (zone, s, p.get('afisMask')))
    results['tilt_%s' % zone] = (s, p.get('afisMask'), None)
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'tilt_%s' % zone, img)

print("\n=== OVERALL BEST ===")
print("  %s  nfiq2=%s" % (best[1], best[0]))
if best[2] is not None:
    out = os.path.join(IMGDIR, 'best_%s.png' % best[1])
    cv2.imwrite(out, best[2])
    print("  saved:", out)

json.dump({k: v[:2] for k, v in results.items()}, open(os.path.join(HERE, 'results', 'manual_score_81ed8492.json'), 'w'), indent=1)
