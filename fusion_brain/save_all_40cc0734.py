"""Save every candidate image (not just the overall best) for capture
40cc0734, so ridge continuity can be visually compared across front/macro/
sweep/tilt rather than trusting NFIQ2 alone. Reuses the already-cached raw
frames from the prior scoring pass -- no new downloads.
"""
import os, sys, cv2
import firebase_admin
from firebase_admin import storage
import fs_rest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

CID = '40cc0734-d432-41a6-a026-2ced715f6f12'
CACHE = os.path.join(HERE, 'results', 'cache', '40cc0734')
IMGDIR = '/tmp/40cc0734_imgs'
os.makedirs(IMGDIR, exist_ok=True)

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
bucket = storage.bucket()

def fetch(p):
    l = os.path.join(CACHE, os.path.basename(p))
    if not os.path.exists(l):
        bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)

d = fs_rest.get_doc('captures', CID)
guide = d['guideRegion']
frames = d['frames']
amb = [f for f in frames if not f['flashOn']]
fl = [f for f in frames if f['flashOn']]
amb_imgs = [x for x in (fetch(f['path']) for f in amb) if x is not None]
fl_imgs = [x for x in (fetch(f['path']) for f in fl) if x is not None]

saved = []

# Front: just the two top scorers (deepFuse/deepMaxc tied 67, native 62)
stack_cache = {}
for name, kw in (('native', dict()), ('deepFuse', dict(fuse='deep', freq_normalize=True, freq_scale_min=0.9))):
    img, p = afis_print.generate(amb_imgs, [0.0]*len(amb_imgs), ['ambient']*len(amb_imgs),
                                  guide_region=guide,
                                  ambient_frames=[amb_imgs[0]], flash_frames=[fl_imgs[0]] if fl_imgs else [amb_imgs[0]],
                                  ambient_burst=amb_imgs, flash_burst=fl_imgs,
                                  stack_cache=stack_cache, **kw)
    if img is not None:
        out = os.path.join(IMGDIR, 'front_%s.png' % name)
        cv2.imwrite(out, img)
        saved.append(out)
        print('saved', out)

# Sweep: all 3 zones
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
    if img is not None:
        out = os.path.join(IMGDIR, 'sweep_%s.png' % zone)
        cv2.imwrite(out, img)
        saved.append(out)
        print('saved', out)

# Tilt: all 3 zones
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
    if img is not None:
        out = os.path.join(IMGDIR, 'tilt_%s.png' % zone)
        cv2.imwrite(out, img)
        saved.append(out)
        print('saved', out)

print('\nTOTAL SAVED:', len(saved))
for s in saved:
    print(' ', s)
