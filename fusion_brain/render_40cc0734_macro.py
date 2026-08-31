"""Manual render of the new fusion_v1 capture (40cc0734, 2026-08-31), CTO
hunch check: does the macro FLASH frame carry more real ridge content than
the macro AMBIENT frame? Renders 'native' from each as the base image
(not just as flash-diff mask input) so the actual enhanced ridge content
can be visually compared, not just raw-frame brightness stats.
"""
import os, sys, cv2, numpy as np
sys.path.insert(0, os.path.join('..', 'functions', 'processEnhanceAndScore'))
import afis_print
import firebase_admin
from firebase_admin import storage
import fs_rest

HERE = os.path.dirname(os.path.abspath(__file__))
firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
bucket = storage.bucket()
CID = '40cc0734-d432-41a6-a026-2ced715f6f12'
CACHE = os.path.join(HERE, 'results', 'cache', '40cc0734')
os.makedirs(CACHE, exist_ok=True)
IMGDIR = '/tmp/40cc0734_imgs'
os.makedirs(IMGDIR, exist_ok=True)


def fetch(p):
    l = os.path.join(CACHE, os.path.basename(p))
    if not os.path.exists(l):
        bucket.blob(p).download_to_filename(l)
    return cv2.imread(l, cv2.IMREAD_GRAYSCALE)


d = fs_rest.get_doc('captures', CID)
macro = {f['tag']: fetch(f['path']) for f in d.get('macroShots', [])}
m_amb = macro['macro_amb_0']; m_fl = macro['macro_fl_0']
macro_guide = dict(cx=0.66, cy=0.50, rx=0.13, ry=0.11, tipAngleDeg=0.0)

print("=== MACRO: ambient-as-base vs flash-as-base ===")
for label, base in (('ambient_base', m_amb), ('flash_base', m_fl)):
    img, p = afis_print.generate(
        [base], [0.0], ['ambient' if base is m_amb else 'flash'],
        guide_region=macro_guide,
        ambient_frames=[m_amb], flash_frames=[m_fl],
        ambient_burst=[m_amb], flash_burst=[m_fl],
        stack_cache={})
    out = os.path.join(IMGDIR, 'macro_%s.png' % label)
    if img is not None:
        cv2.imwrite(out, img)
    print("  %-14s mask=%s -> %s" % (label, p.get('afisMask'), out if img is not None else 'FAILED (None)'))

# Also render the raw enhanced-but-unbinarized flash frame for a direct
# visual sanity check that flash content is genuinely usable at all.
raw_out = os.path.join(IMGDIR, 'macro_flash_raw_crop.png')
gm = afis_print._superellipse_mask(m_fl.shape[:2], macro_guide)
ys, xs = np.where(gm > 0)
if len(ys):
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    cv2.imwrite(raw_out, m_fl[y0:y1, x0:x1])
    print("  raw flash crop (guide bbox, unenhanced) ->", raw_out)
    amb_raw_out = os.path.join(IMGDIR, 'macro_ambient_raw_crop.png')
    cv2.imwrite(amb_raw_out, m_amb[y0:y1, x0:x1])
    print("  raw ambient crop (guide bbox, unenhanced) ->", amb_raw_out)
