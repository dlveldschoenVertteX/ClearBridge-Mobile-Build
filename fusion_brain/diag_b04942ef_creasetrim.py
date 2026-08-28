import os, sys
import cv2, numpy as np
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

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
    import subprocess, tempfile
    r = cv2.resize(img, (500, 500), interpolation=cv2.INTER_LANCZOS4)
    f = tempfile.NamedTemporaryFile(suffix='.png', delete=False); cv2.imwrite(f.name, r)
    try:
        o = subprocess.run(['/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2',
                             '-m','/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt',
                             '-i',f.name,'-F'],capture_output=True,text=True,timeout=180)
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

for label, ct in (('WITH crease_trim (production default)', True),
                   ('WITHOUT crease_trim', False)):
    img, p = afis_print.generate(amb_imgs, [0.0]*len(amb_imgs), ['ambient']*len(amb_imgs),
                                  guide_region=guide,
                                  ambient_frames=[amb_imgs[0]], flash_frames=[fl_imgs[0]],
                                  ambient_burst=amb_imgs, flash_burst=fl_imgs,
                                  fuse='deep', freq_normalize=True, freq_scale_min=0.9,
                                  crease_trim=ct, stack_cache={})
    nonwhite = (img < 250).sum()
    print("=== %s ===" % label)
    print("  shape=%s  non-white px=%d (%.1f%% of canvas)  creaseTrimPx=%s  nfiq2=%s"
          % (img.shape, nonwhite, 100.0*nonwhite/img.size, p.get('afisCreaseTrimPx'), nfiq2(img)))
    out = '/tmp/b04942ef_%s.png' % ('with_trim' if ct else 'no_trim')
    cv2.imwrite(out, img)
    print("  saved", out)
