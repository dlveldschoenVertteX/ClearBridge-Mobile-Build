"""Manual real-pipeline scoring of fusion_v1 capture 40cc0734 (2026-08-31
13:28 UTC). fusion_v1's production trigger is off, so this never gets an
automatic score. Full variant pool on front; each zone's own real
ambient/flash pair passed as ambient_burst/flash_burst so flash-diff can
actually engage everywhere (the bug fixed in the 81ed8492 rescore).
"""
import os, sys, json, subprocess, tempfile
import cv2
import firebase_admin
from firebase_admin import storage
import fs_rest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
CID = '40cc0734-d432-41a6-a026-2ced715f6f12'
CACHE = os.path.join(HERE, 'results', 'cache', '40cc0734')
os.makedirs(CACHE, exist_ok=True)
IMGDIR = '/tmp/40cc0734_imgs'
os.makedirs(IMGDIR, exist_ok=True)

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
bucket = storage.bucket()

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

d = fs_rest.get_doc('captures', CID)
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

print("=== FRONT BURST ===")
best = (None, None, None)
stack_cache = {}
for name, kw in VARIANTS:
    img, p = afis_print.generate(amb_imgs, [0.0]*len(amb_imgs), ['ambient']*len(amb_imgs),
                                  guide_region=guide,
                                  ambient_frames=[amb_imgs[0]], flash_frames=[fl_imgs[0]] if fl_imgs else [amb_imgs[0]],
                                  ambient_burst=amb_imgs, flash_burst=fl_imgs,
                                  stack_cache=stack_cache, **kw)
    s = nfiq2(img)
    print("  %-10s nfiq2=%-6s mask=%-16s" % (name, s, p.get('afisMask')))
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'front_%s' % name, img)

print("\n=== MACRO ===")
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
    print("  native(amb-base)  nfiq2=%s mask=%s" % (s, p.get('afisMask')))
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'macro_ambient', img)

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
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'sweep_%s' % zone, img)

print("\n=== TILT ZONES ===")
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
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'tilt_%s' % zone, img)

print("\n=== OVERALL BEST ===")
print("  %s  nfiq2=%s" % (best[1], best[0]))
if best[2] is not None:
    out = os.path.join(IMGDIR, 'best_%s.png' % best[1])
    cv2.imwrite(out, best[2])
    print("  saved:", out)
