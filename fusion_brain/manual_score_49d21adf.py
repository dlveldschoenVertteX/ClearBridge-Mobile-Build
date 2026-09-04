"""Manual real-pipeline scoring of fusion_v1 capture 49d21adf (2026-09-02
08:47 UTC) -- the first real A55 capture on the build carrying the
hold-duration/sharpness-gate change (clearbridge_beta, unrelated to this
capture mode) AND the earlier A55 macro-calibration + AF-diagnostic work.
fusion_v1's production trigger is off, so this never gets an automatic
score -- same manual-harness pattern as every other fusion_v1 capture this
session.

Real, decisive finding already visible in the raw doc before this script
even runs: cameraLensInfo['2'].afAvailableModes == ['OFF'] -- camera "2"
(macro) has NO real autofocus mode on this device at all, only cameras
'1' and '3' also read ['OFF'] (fixed too), and camera '0' (main) is the
only one with real AF (AUTO/CONTINUOUS_PICTURE/etc). This is the direct,
decisive answer the afAvailableModes diagnostic was added to get.
"""
import os, sys, subprocess, tempfile
import cv2
import firebase_admin
from firebase_admin import storage
import fs_rest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
CID = '49d21adf-cdb2-46b5-bd78-6f53874f3e75'
CACHE = os.path.join(HERE, 'results', 'cache', '49d21adf')
os.makedirs(CACHE, exist_ok=True)
IMGDIR = '/tmp/49d21adf_imgs'
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

print("=== cameraLensInfo.afAvailableModes (real AF-hardware answer) ===")
for cid, info in sorted(d.get('cameraLensInfo', {}).items()):
    print("  cam %s: afAvailableModes=%s  focalLengthMm=%.2f  focusCalib=%s" % (
        cid, info.get('afAvailableModes'), info.get('focalLengthMm', -1),
        info.get('focusDistanceCalibration')))

print("\n=== FRONT BURST ===")
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
    out = os.path.join(IMGDIR, 'front_%s.png' % name)
    if img is not None:
        cv2.imwrite(out, img)
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'front_%s' % name, img)

print("\n=== MACRO (real A55 calibration: cx=0.61 cy=0.49 rx=0.11 ry=0.09) ===")
macro_guide = dict(cx=0.61, cy=0.49, rx=0.11, ry=0.09, tipAngleDeg=0.0)
macro = {f['tag']: fetch(f['path']) for f in d.get('macroShots', [])}
m_amb = macro.get('macro_amb_0'); m_fl = macro.get('macro_fl_0')
if m_amb is not None:
    fl_list = [m_fl] if m_fl is not None else [m_amb]
    for name, base in (('ambient', m_amb), ('flash', m_fl if m_fl is not None else m_amb)):
        img, p = afis_print.generate([base], [0.0], ['ambient'], guide_region=macro_guide,
                                      ambient_frames=[base], flash_frames=fl_list,
                                      ambient_burst=[m_amb], flash_burst=fl_list,
                                      stack_cache={})
        s = nfiq2(img)
        print("  %-8s nfiq2=%s mask=%s" % (name, s, p.get('afisMask')))
        out = os.path.join(IMGDIR, 'macro_%s.png' % name)
        if img is not None:
            cv2.imwrite(out, img)
        if img is not None and s is not None and (best[0] is None or s > best[0]):
            best = (s, 'macro_%s' % name, img)
    # Save a raw crop too, for direct visual inspection of whether the
    # macro sensor itself resolved any ridge detail at all (independent of
    # the enhancement pipeline's own ridge-synthesizing Gabor bank).
    h, w = m_amb.shape
    cx_px, cy_px = int(macro_guide['cx']*w), int(macro_guide['cy']*h)
    rx_px, ry_px = int(macro_guide['rx']*w*1.3), int(macro_guide['ry']*h*1.3)
    x0, x1 = max(0, cx_px-rx_px), min(w, cx_px+rx_px)
    y0, y1 = max(0, cy_px-ry_px), min(h, cy_px+ry_px)
    cv2.imwrite(os.path.join(IMGDIR, 'macro_raw_crop.png'), m_amb[y0:y1, x0:x1])
else:
    print("  no macro ambient frame in this capture")

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
    out = os.path.join(IMGDIR, 'sweep_%s.png' % zone)
    if img is not None:
        cv2.imwrite(out, img)
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
    out = os.path.join(IMGDIR, 'tilt_%s.png' % zone)
    if img is not None:
        cv2.imwrite(out, img)
    if img is not None and s is not None and (best[0] is None or s > best[0]):
        best = (s, 'tilt_%s' % zone, img)

print("\n=== OVERALL BEST ===")
print("  %s  nfiq2=%s" % (best[1], best[0]))
if best[2] is not None:
    out = os.path.join(IMGDIR, 'best_%s.png' % best[1])
    cv2.imwrite(out, best[2])
    print("  saved:", out)
