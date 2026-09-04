"""Manual real-pipeline scoring of fusion_v1 capture b04942ef (2026-08-28
14:41 UTC, first real capture after today's layer 2-7 backend deploy).
fusion_v1's production trigger is deliberately off, so this capture never
gets an automatic NFIQ2 score -- reproducing the real scoring path locally,
same discipline as every other fusion_brain review this project has done.
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
CID = 'b04942ef-bffb-488d-85e5-c493bcaf5102'
CACHE = os.path.join(HERE, 'results', 'cache', 'b04942ef')

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
amb_imgs = [fetch(f['path']) for f in amb]
fl_imgs = [fetch(f['path']) for f in fl]
print("=== FRONT BURST (guide=%s) ===" % {k: round(v,3) if isinstance(v,float) else v for k,v in guide.items()})
results = {}
stack_cache = {}
for name, kw in (('native', dict()),
                  ('freqNorm', dict(freq_normalize=True, freq_scale_min=0.9)),
                  ('fuseAvg', dict(fuse='avg')),
                  ('deepFuse', dict(fuse='deep', freq_normalize=True, freq_scale_min=0.9))):
    img, p = afis_print.generate(amb_imgs, [0.0]*len(amb_imgs), ['ambient']*len(amb_imgs),
                                  guide_region=guide,
                                  ambient_frames=[amb_imgs[0]], flash_frames=[fl_imgs[0]],
                                  ambient_burst=amb_imgs, flash_burst=fl_imgs,
                                  stack_cache=stack_cache, **kw)
    s = nfiq2(img)
    results[name] = (s, p.get('afisMask'), p.get('afisFused'), p.get('afisFuseSoftnessSkipped'))
    print("  %-10s nfiq2=%-6s mask=%-16s fused=%-6s softnessSkip=%s"
          % (name, s, p.get('afisMask'), p.get('afisFused'), p.get('afisFuseSoftnessSkipped')))

print("\n=== MACRO (camera 2, cx=0.66 cy=0.50 rx=0.13 ry=0.11) ===")
macro_guide = dict(cx=0.66, cy=0.50, rx=0.13, ry=0.11, tipAngleDeg=0.0)
macro = {f['tag']: fetch(f['path']) for f in d['macroShots']}
m_amb = macro.get('macro_amb_0'); m_fl = macro.get('macro_fl_0')
img, p = afis_print.generate([m_amb], [0.0], ['ambient'], guide_region=macro_guide,
                              ambient_frames=[m_amb], flash_frames=[m_fl], stack_cache={})
s = nfiq2(img)
print("  native  nfiq2=%s mask=%s" % (s, p.get('afisMask')))
results['macro_native'] = (s, p.get('afisMask'), None, None)

print("\n=== SWEEP ZONES ===")
fgr = d['fusionGuideRegions']
sweep = {f['tag']: fetch(f['path']) for f in d['sweepShots']}
for zone, gkey in (('left', 'sweep_left'), ('center', 'sweep_center'), ('right', 'sweep_right')):
    za = sweep.get('sweep_%s_amb' % zone)
    g = fgr[gkey]
    img, p = afis_print.generate([za], [0.0], ['ambient'], guide_region=g,
                                  ambient_frames=[za], flash_frames=[sweep.get('sweep_%s_fl' % zone)],
                                  stack_cache={})
    s = nfiq2(img)
    print("  %-8s nfiq2=%s mask=%s" % (zone, s, p.get('afisMask')))
    results['sweep_%s' % zone] = (s, p.get('afisMask'), None, None)

print("\n=== TILT ZONES (using main guide as approximation) ===")
tilt = {f['tag']: fetch(f['path']) for f in d['tiltShots']}
main_g = fgr['main']
for zone in ('left', 'tip', 'right'):
    ta = tilt.get('tilt_%s_amb' % zone)
    img, p = afis_print.generate([ta], [0.0], ['ambient'], guide_region=main_g,
                                  ambient_frames=[ta], flash_frames=[tilt.get('tilt_%s_fl' % zone)],
                                  stack_cache={})
    s = nfiq2(img)
    print("  %-8s nfiq2=%s mask=%s" % (zone, s, p.get('afisMask')))
    results['tilt_%s' % zone] = (s, p.get('afisMask'), None, None)

json.dump(results, open(os.path.join(HERE,'results','b04942ef_manual_score.json'),'w'), indent=1)
best = max(((v[0] or 0, k) for k,v in results.items()))
print("\n=== BEST OVERALL: %s (nfiq2=%s) ===" % (best[1], best[0]))
