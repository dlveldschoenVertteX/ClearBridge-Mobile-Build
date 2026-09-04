"""Real range of flash_lap on captures that DID pass
_FLASH_DIFF_MIN_FLASH_LAPLACIAN (afisMask == guide+flashdiff), to compare
against the 4 known guard-failing captures (check_mask_guard_exposure.py).
Answers: is 50.0 a real, meaningful boundary, or is it clipping into the
legitimate range?
"""
import os, sys
import cv2
import firebase_admin
from firebase_admin import storage
import fs_rest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

CIDS = [
    '076a1775-1654-47c1-a769-7dc8b32bda3d',
    '14674391-c65c-4c84-8e36-04b1c0690137',
    '19184018-be77-4320-9648-42f44ba5a35b',
    '1cc301a8-bd8a-4750-91dd-b8d5b3cd6614',
    '1febdba7-99d3-4420-b216-11b9287809a7',
    '286f1f0a-15a3-4b2f-89d0-3ab3c914c835',
    '2a85bb36-7703-45bd-aa06-64f000ce3ef8',
    '315f79f1-470c-45c4-867a-f3dee40817c4',
]
CACHE = os.path.join(HERE, 'results', 'cache', 'mask_guard_passing')
os.makedirs(CACHE, exist_ok=True)

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
bucket = storage.bucket()


def fetch(p):
    local = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(local):
        bucket.blob(p).download_to_filename(local)
    return cv2.imread(local, cv2.IMREAD_GRAYSCALE)


passing_laps = []
for cid in CIDS:
    d = fs_rest.get_doc('captures', cid)
    frames = d.get('frames', [])
    amb = [f for f in frames if not f.get('flashOn')]
    fl = [f for f in frames if f.get('flashOn')]
    print('CAPTURE', cid)
    for i, ff in enumerate(fl):
        try:
            f_img = fetch(ff['path'])
        except Exception as e:
            print('  fetch fail', e)
            continue
        if f_img is None:
            continue
        f_lap = float(cv2.Laplacian(f_img, cv2.CV_64F).var())
        passes = f_lap >= afis_print._FLASH_DIFF_MIN_FLASH_LAPLACIAN
        print('  pair %d flash_lap=%.1f %s' % (i, f_lap, 'PASSES (first pass used by real code)' if passes else 'below guard'))
        if passes:
            passing_laps.append(f_lap)
            break  # real code stops at first passing pair

print()
print('=== Passing-pair flash_lap values (n=%d) ===' % len(passing_laps))
print(sorted(passing_laps))
if passing_laps:
    print('min:', min(passing_laps), 'median:', sorted(passing_laps)[len(passing_laps)//2])
