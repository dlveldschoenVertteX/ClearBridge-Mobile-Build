import os, sys
import cv2
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

d = db.collection('captures').document(CID).get().to_dict()
guide = d['guideRegion']
frames = d['frames']
amb = [f for f in frames if not f['flashOn']]
fl = [f for f in frames if f['flashOn']]
amb_imgs = [fetch(f['path']) for f in amb]
fl_imgs = [fetch(f['path']) for f in fl]

img, p = afis_print.generate(amb_imgs, [0.0]*len(amb_imgs), ['ambient']*len(amb_imgs),
                              guide_region=guide,
                              ambient_frames=[amb_imgs[0]], flash_frames=[fl_imgs[0]],
                              ambient_burst=amb_imgs, flash_burst=fl_imgs,
                              fuse='deep', freq_normalize=True, freq_scale_min=0.9,
                              stack_cache={})
out = '/tmp/b04942ef_superprint_deepFuse.png'
cv2.imwrite(out, img)
print('saved', out, 'params=', p)
