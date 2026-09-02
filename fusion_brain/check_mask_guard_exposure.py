"""Completes the masking-reliability audit's own flagged next step (CLAUDE.md,
"Real audit: 34% of ALL real front_only_v1 captures ship with zero
content-aware masking"): determine whether the 4 real guard-failing captures
(181e8cd8, 4ae6d13c, 474b4d6a, c4dd4b24) trip _FLASH_DIFF_MIN_FLASH_LAPLACIAN
because the flash frame is OVER-exposed (blown out, the guard's own
docstring assumption) or UNDER-exposed (the direction already confirmed for
macro) -- the real evidence needed before choosing which lever to pull
(relax the guard vs. fix the EV curve that trips it).
"""
import os, sys, json
import cv2
import numpy as np
import firebase_admin
from firebase_admin import storage
import fs_rest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print  # noqa: E402

CIDS = [
    '181e8cd8-85b6-44ac-a970-74fdc0ff7d99',
    '4ae6d13c-f0dc-4700-8669-d4eec2c5a05a',
    '474b4d6a-7abd-4cb4-8e39-f8df12eefa2f',
    'c4dd4b24-00b9-49a2-ade4-633b44eef64c',
]
CACHE = os.path.join(HERE, 'results', 'cache', 'mask_guard_exposure')
os.makedirs(CACHE, exist_ok=True)

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
bucket = storage.bucket()


def fetch(p):
    local = os.path.join(CACHE, p.replace('/', '_'))
    if not os.path.exists(local):
        bucket.blob(p).download_to_filename(local)
    return cv2.imread(local, cv2.IMREAD_GRAYSCALE)


def find_full_id(prefix):
    # captures collection docs use full uuids; query the prefix via a
    # direct get using the prefix isn't possible over REST without knowing
    # the full id, so try common patterns: some are referenced by short
    # id elsewhere in this project's own notes as the literal doc id.
    return prefix


for short in CIDS:
    print('=' * 60)
    print('CAPTURE', short)
    try:
        d = fs_rest.get_doc('captures', short)
    except Exception as e:
        print('  could not fetch (may need full id):', e)
        continue
    if not d:
        print('  empty doc / not found')
        continue
    guide = d.get('guideRegion')
    frames = d.get('frames', [])
    amb = [f for f in frames if not f.get('flashOn')]
    fl = [f for f in frames if f.get('flashOn')]
    print('  frames:', len(frames), 'amb:', len(amb), 'fl:', len(fl),
          'afisMask(recorded):', d.get('superprintParams', {}).get('afisMask'))
    found_guard_hit = False
    for i, (af, ff) in enumerate(zip(amb, fl)):
        try:
            f_img = fetch(ff['path'])
            a_img = fetch(af['path'])
        except Exception as e:
            print('  fetch failed:', e)
            continue
        if f_img is None or a_img is None:
            continue
        f_lap = float(cv2.Laplacian(f_img, cv2.CV_64F).var())
        a_lap = float(cv2.Laplacian(a_img, cv2.CV_64F).var())
        mean_b = float(f_img.mean())
        mean_a = float(a_img.mean())
        clip_white = float((f_img >= 250).mean()) * 100
        clip_black = float((f_img <= 5).mean()) * 100
        guard_fires = f_lap < afis_print._FLASH_DIFF_MIN_FLASH_LAPLACIAN
        verdict = ('UNDEREXPOSED' if mean_b < 90 and clip_black > clip_white
                    else 'OVEREXPOSED/BLOWN OUT' if clip_white > 1.0
                    else 'AMBIGUOUS/NEITHER')
        print('  pair %d: flash_lap=%.1f (amb_lap=%.1f, ratio=%.2fx) guard_fires=%s '
              'flash_mean=%.1f amb_mean=%.1f clip_white%%=%.3f clip_black%%=%.3f -> %s' % (
            i, f_lap, a_lap, (a_lap / f_lap if f_lap > 0 else float('inf')),
            guard_fires, mean_b, mean_a, clip_white, clip_black,
            verdict if guard_fires else '(guard did not fire on this pair)'))
        if guard_fires and not found_guard_hit:
            found_guard_hit = True
    if not found_guard_hit:
        print('  (guard never fired on any real pair in this capture -- may not be guard-caused, or already fixed upstream)')
