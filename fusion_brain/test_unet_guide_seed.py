"""Layer 3 fix candidate: seed `_unet_mask`'s component pick with the guide.

`_unet_mask` keeps `argmax(area)` of the connected components. It has no idea
where the user actually seated the pad, even though every caller already holds
`guide_region`. `_flash_diff_mask`'s own lobe cut had exactly this gap and got
a guide seed in round 16; the U-Net path never did.

Why that should matter HERE specifically -- the U-Net's training labels
(`ml/thumb_seg/build_dataset.py`) come from
`_segment_via_flash_diff(amb, fl, _KSIZE)` called with NO seed, i.e. the
pre-round-16 frame-centre seed. So the model was distilled from a detector
aimed at the wrong point, and should be expected to find "the near-camera blob
near the frame centre" rather than "the guided pad". Measured failure mode
matches: 4/13 real captures miss, and every miss is MIS-LOCATION (a real blob
exists, just not at the guide), never over- or under-segmentation.

Arms, on every real capture whose production mask path reaches the U-Net:
  argmax  -- production today
  seeded  -- component containing the guide centre, else nearest centroid

Research-only, read-only Firestore/Storage.
"""
import os, sys, json, statistics, subprocess, tempfile
import numpy as np, cv2
import firebase_admin
from firebase_admin import firestore, storage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'functions', 'processEnhanceAndScore'))
import afis_print, sfm_pipeline  # noqa: E402

NFIQ2 = '/tmp/NFIQ2/build/install_staging/nfiq2/bin/nfiq2'
MODEL = '/tmp/NFIQ2/build/install_staging/nfiq2/share/nist_plain_tir-ink.txt'
MIN_DATE = '2026-08-17'

firebase_admin.initialize_app(options={'storageBucket': 'clearbridge-dc699.firebasestorage.app'})
db = firestore.client(); bucket = storage.bucket()
CACHE = os.path.join(HERE, 'results', 'cache', 'mask'); os.makedirs(CACHE, exist_ok=True)


def fetch(path):
    local = os.path.join(CACHE, path.replace('/', '_'))
    if not os.path.exists(local):
        bucket.blob(path).download_to_filename(local)
    return cv2.imread(local, cv2.IMREAD_GRAYSCALE)


def nfiq2(img):
    if img is None:
        return None
    r = cv2.resize(img, (500, 500), interpolation=cv2.INTER_LANCZOS4)
    f = tempfile.NamedTemporaryFile(suffix='.png', delete=False); cv2.imwrite(f.name, r)
    try:
        o = subprocess.run([NFIQ2, '-m', MODEL, '-i', f.name, '-F'],
                           capture_output=True, text=True, timeout=180)
        for t in o.stdout.replace(',', ' ').split():
            try: v = float(t)
            except ValueError: continue
            if 0.0 <= v <= 100.0: return v
    finally:
        os.unlink(f.name)
    return None


def unet_components(gray):
    """Everything `_unet_mask` does EXCEPT the final component choice."""
    sess = sfm_pipeline._get_thumb_seg_session()
    if sess is None: return None
    size = sfm_pipeline._THUMB_SEG_IMG_SIZE
    small = cv2.resize(gray, (size, size)).astype(np.float32) / 255.0
    logits = sess.run(['logits'], {'input': small[None, None]})[0][0, 0]
    m = ((1.0 / (1.0 + np.exp(-logits))) > 0.5).astype(np.uint8) * 255
    m = cv2.resize(m, (gray.shape[1], gray.shape[0]), interpolation=cv2.INTER_NEAREST)
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((31, 31), np.uint8))
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((21, 21), np.uint8))
    return cv2.connectedComponentsWithStats(m)


def pick(cc, shape, guide=None):
    n, lab, stats, cents = cc
    if n <= 1: return None
    if guide is None:
        idx = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    else:
        h, w = shape
        gx = min(w - 1, max(0, guide['cx'] * w)); gy = min(h - 1, max(0, guide['cy'] * h))
        idx = int(lab[int(gy), int(gx)])
        if idx == 0:
            d = [np.hypot(cents[i][0] - gx, cents[i][1] - gy) for i in range(1, n)]
            idx = 1 + int(np.argmin(d))
    m = (lab == idx).astype(np.uint8) * 255
    return m if (m > 0).mean() >= 0.03 else None


caps = []
for s in db.collection('captures').stream():
    d = s.to_dict() or {}
    if d.get('captureMode') != 'front_only_v1': continue
    if str(d.get('createdAt'))[:10] < MIN_DATE: continue
    g, fr = d.get('guideRegion'), d.get('frames')
    if isinstance(g, dict) and isinstance(fr, list) and fr:
        caps.append((s.id, d, g, fr))
caps.sort(key=lambda c: str(c[1].get('createdAt')))

D = afis_print._MASK_COVER_DILATE
rows = []
for cid, d, g, fr in caps:
    amb = [f for f in fr if not f.get('flashOn')]; fl = [f for f in fr if f.get('flashOn')]
    if not amb or not fl: continue
    try:
        a = fetch(amb[0]['path']); f0 = fetch(fl[0]['path'])
    except Exception: continue
    if a is None or f0 is None or a.shape != f0.shape: continue
    # only captures whose production path actually reaches the U-Net
    if afis_print._flash_diff_mask([a], [f0], a.shape[:2], g) is not None:
        continue
    cc = unet_components(a)
    if cc is None: continue
    gm = afis_print._superellipse_mask(a.shape[:2], g)
    bd = afis_print._superellipse_mask(a.shape[:2], {
        **g, 'rx': float(g['rx']) * D, 'ry': float(g['ry']) * D})
    ga, ba = float((gm > 0).sum()), float((bd > 0).sum())

    out = {'id': cid[:8]}
    for arm, seed in (('argmax', None), ('seeded', g)):
        m = pick(cc, a.shape[:2], seed)
        if m is None:
            out[arm] = 'no-mask'; continue
        cov = float((cv2.bitwise_and(afis_print._fill_mask_holes(m), bd) > 0).sum())
        out[arm] = 'ACCEPT' if (0.35 * ga <= cov <= 0.92 * ba) else 'reject'
        out[arm + '_cov'] = round(cov / ga, 3)
    rows.append(out)
    print("  %s  argmax=%-7s(%.2fxguide)   seeded=%-7s(%.2fxguide)  %s"
          % (out['id'], out['argmax'], out.get('argmax_cov', 0),
             out['seeded'], out.get('seeded_cov', 0),
             'CHANGED' if out['argmax'] != out['seeded'] else ''))

json.dump(rows, open(os.path.join(HERE, 'results', 'unet_guide_seed.json'), 'w'), indent=1)
a_ok = sum(1 for r in rows if r.get('argmax') == 'ACCEPT')
s_ok = sum(1 for r in rows if r.get('seeded') == 'ACCEPT')
print("\n  U-Net-path captures: %d" % len(rows))
print("  pad located --  argmax(area): %d    guide-seeded: %d" % (a_ok, s_ok))

# ---- third arm, added after the straight swap came out a wash (9 vs 9) ----
# The one loss (774f2252) was not the seed being wrong: the guide-centre pixel
# landed in a small neighbouring component that failed the >=3% area floor and
# returned None. So try the ADDITIVE form -- prefer the guide-seeded component,
# fall back to argmax(area) when the seeded pick is unusable. Structurally that
# can only convert a reject into an accept, never the reverse.
print("\n  --- arm 3: seeded, falling back to argmax when unusable ---")
both = 0
for r in rows:
    v = r['seeded'] if r['seeded'] not in ('no-mask',) else r['argmax']
    r['seeded_or_argmax'] = v
    if v == 'ACCEPT': both += 1
    if v != r['argmax']:
        print("     %s  argmax=%-7s -> %s" % (r['id'], r['argmax'], v))
print("  pad located -- argmax %d   seeded %d   seeded-or-argmax %d   (of %d)"
      % (a_ok, s_ok, both, len(rows)))
json.dump(rows, open(os.path.join(HERE, 'results', 'unet_guide_seed.json'), 'w'), indent=1)
