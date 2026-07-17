"""Dataset ingestion for the contactless->contact fidelity benchmark.

Prime-directive tooling (docs/FIDELITY_WALL_SCOPE.md): the moment a real paired
contactless/contact dataset (RidgeBase / PolyU / NIST SD 302) lands, this loader
maps its on-disk layout into (subject, finger, sample, modality) records so the
benchmark (`benchmark.py`) can score genuine (same finger) vs impostor
(different finger) separation of OUR pipeline through a real matcher (SourceAFIS).

Nothing here depends on any dataset being present — it is pure parsing/indexing
plus a self-test on synthetic paths, so it can be committed and verified before
the data arrives. Point it at a dataset root with `--root` once you have one.

Supported layouts (auto-detected from the directory tree; add more in
`_LAYOUTS` as needed):

  RidgeBase (WACV 2023, Buffalo CUBS)
    Task1/ (CL2CL) and Task2/ (C2CL) splits; images named with a subject and
    finger identifier and a "CL"/"CB" (contactless / contact-based) tag.
    We index every image and recover (subject, finger, modality) from the
    filename token pattern, robust to the exact separator used.

  NIST SD 302 (N2N)
    Per-subject directories; contact rolled/plain baselines (302a/302b) vs
    auxiliary/N2N device captures (302c/302d). Modality inferred from the part
    (a/b = contact, c/d = "contactless-ish" device). Finger position from the
    standard NIST frmt position code in the filename.

  generic
    Fallback: any tree of images where the immediate parent directory names the
    subject, an optional next-level directory names the finger, and a
    'contactless'/'contact' token (in path or filename) names the modality.

Usage:
    python ingest.py --root /path/to/dataset [--layout auto|ridgebase|sd302|generic]
    python ingest.py --selftest          # no dataset needed
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, asdict
from typing import Optional, List, Dict, Iterable

_IMG_EXT = {'.png', '.jpg', '.jpeg', '.bmp', '.tif', '.tiff', '.pgm', '.wsq'}


@dataclass(frozen=True)
class Record:
    path: str
    subject: str          # opaque subject/person id (namespaced per dataset)
    finger: str           # finger id within subject; '' if unknown/single
    modality: str         # 'contactless' | 'contact'
    sample: str           # sample/impression id; '' if unknown

    @property
    def finger_key(self) -> str:
        """Identity key a genuine pair must share (same physical finger)."""
        return f'{self.subject}/{self.finger}'


# ---- filename parsers -------------------------------------------------------

def _is_img(name: str) -> bool:
    return os.path.splitext(name)[1].lower() in _IMG_EXT


def _ridgebase_record(root: str, path: str) -> Optional[Record]:
    """RidgeBase filenames encode subject, finger, and a CL/CB modality tag.
    The dataset uses tokens like  <sid>_<finger>_<sample>_CL.png  /  ..._CB.png
    (contactless / contact-based). We stay tolerant to separators and case."""
    base = os.path.splitext(os.path.basename(path))[0]
    toks = re.split(r'[ _\-.]+', base)
    up = [t.upper() for t in toks]
    if 'CL' in up:
        modality = 'contactless'
    elif 'CB' in up or 'CT' in up:
        modality = 'contact'
    else:
        # fall back to a path token
        pl = path.lower()
        if 'contactless' in pl or '/cl' in pl:
            modality = 'contactless'
        elif 'contact' in pl or '/cb' in pl:
            modality = 'contact'
        else:
            return None
    # First long alphanumeric token = subject; a following short numeric = finger.
    subject = toks[0] if toks else base
    finger = ''
    for t in toks[1:]:
        if t.isdigit() and len(t) <= 2:
            finger = t
            break
    sample = toks[-1] if toks and toks[-1].isdigit() else ''
    return Record(path, f'rb:{subject}', finger, modality, sample)


_SD302_POS = re.compile(r'_(\d{1,2})\.[A-Za-z0-9]+$')   # trailing FRGP before ext

# Verified against NIST's own SD 302 (N2N) part descriptions, 2026-07-17
# (the CTO's actual download-link email, not guessed): 302a (Challenger
# rolled friction ridge), 302b (operator-assisted rolled + 4-4-2 slap,
# "baseline"), and 302d (plain fingerprints from AUXILIARY DEVICES) are ALL
# still sensor/scanner captures -- "auxiliary" means a different SENSOR
# vendor, not a different acquisition MODALITY. 302f (unprocessed
# PHOTOGRAPHS from Challenger T's PROTOTYPE device) is the one genuinely
# contactless/photographic, unassisted part -- confirmed via NIST TN 2007's
# own description of the N2N challenge (untrained users, no operator, full
# nail-to-nail capture). An earlier version of this classifier incorrectly
# grouped 302d in with contactless via a vague 'aux|device' regex -- fixed
# here to key off the literal, documented part codes instead of guessing
# from loose keywords. 302c (palm), 302e (latent), 302g/h/i (EBTS
# annotation/transaction files, not raw images) are all out of scope for
# this contactless-vs-contact pairing and won't classify as either modality
# below (never matched as contact OR contactless -> excluded from pairing).
_SD302_CONTACT_PARTS = ('sd302a', 'sd302b', 'sd302d')
_SD302_CONTACTLESS_PARTS = ('sd302f',)


def _sd302_record(root: str, path: str) -> Optional[Record]:
    # Verified against the REAL extracted archives + NIST's own
    # README_302d.txt, 2026-07-17: filenames are
    # SUBJECT_DEVICE[_RESOLUTION]_CAPTURE_FRGP.EXT (token count varies by
    # part -- 302a has no resolution field, 302b/d do) and the DIRECTORY tree
    # is organized by device/resolution/capture-type, NOT by subject at all
    # (e.g. images/auxiliary/flat/M/500/plain/png/00002502_M_500_plain_04.png).
    # An earlier version of this parser read `subject = parts[0]` from the
    # PATH, which for the real layout grabs a device/collection directory
    # name -- collapsing every image in an archive into one fake "subject".
    # It also required the FRGP digits to be sandwiched between two
    # underscores, which never matches (FRGP sits right before the
    # extension), so `finger` silently came out empty for every real record,
    # collapsing all 10 fingers of a subject into one. Both are fixed here:
    # subject is always the FIRST underscore token in the FILENAME, FRGP is
    # always the LAST, regardless of how many tokens sit between them.
    rel = os.path.relpath(path, root)
    low = rel.lower()
    if any(p in low for p in _SD302_CONTACTLESS_PARTS):
        modality = 'contactless'
    elif any(p in low for p in _SD302_CONTACT_PARTS):
        modality = 'contact'
    else:
        return None   # 302c/e/g/h/i or unrecognized -- not part of this pairing
    base = os.path.basename(path)
    subject = base.split('_')[0] if base else 'unknown'
    m = _SD302_POS.search(base)
    finger = m.group(1).zfill(2) if m else ''
    return Record(path, f'sd302:{subject}', finger, modality, '')


def _generic_record(root: str, path: str) -> Optional[Record]:
    rel = os.path.relpath(path, root)
    parts = rel.split(os.sep)
    low = rel.lower()
    if 'contactless' in low or 'touchless' in low or 'photo' in low:
        modality = 'contactless'
    elif 'contact' in low or 'rolled' in low or 'slap' in low or 'scanner' in low:
        modality = 'contact'
    else:
        return None
    subject = parts[0] if len(parts) >= 1 else 'unknown'
    finger = parts[1] if len(parts) >= 3 else ''
    return Record(path, f'gen:{subject}', finger, modality, '')


_LAYOUTS = {
    'ridgebase': _ridgebase_record,
    'sd302': _sd302_record,
    'generic': _generic_record,
}


def detect_layout(root: str) -> str:
    names = ' '.join(os.listdir(root)).lower() if os.path.isdir(root) else ''
    if 'task1' in names or 'task2' in names or 'ridgebase' in names:
        return 'ridgebase'
    if 'sd302' in names or '302a' in names or '302b' in names:
        return 'sd302'
    return 'generic'


def index_dataset(root: str, layout: str = 'auto') -> List[Record]:
    if layout == 'auto':
        layout = detect_layout(root)
    parse = _LAYOUTS[layout]
    out: List[Record] = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            if not _is_img(f):
                continue
            rec = parse(root, os.path.join(dirpath, f))
            if rec is not None:
                out.append(rec)
    return out


def summarize(records: Iterable[Record]) -> Dict[str, object]:
    records = list(records)
    subjects = {r.subject for r in records}
    fingers = {r.finger_key for r in records}
    by_mod: Dict[str, int] = {}
    for r in records:
        by_mod[r.modality] = by_mod.get(r.modality, 0) + 1
    # a finger is "pairable" if it has >=1 contactless AND >=1 contact image
    cl = {r.finger_key for r in records if r.modality == 'contactless'}
    ct = {r.finger_key for r in records if r.modality == 'contact'}
    pairable = cl & ct
    return {
        'images': len(records),
        'subjects': len(subjects),
        'fingers': len(fingers),
        'by_modality': by_mod,
        'pairable_fingers': len(pairable),
    }


def genuine_impostor_pairs(records: List[Record], max_impostors: int = 20000):
    """Build cross-modality (contactless probe vs contact gallery) pairs.
    Genuine = same finger_key; impostor = different. Returns (genuine, impostor)
    lists of (probe_record, gallery_record)."""
    probes = [r for r in records if r.modality == 'contactless']
    gallery = [r for r in records if r.modality == 'contact']
    gen, imp = [], []
    for p in probes:
        for g in gallery:
            if p.finger_key == g.finger_key:
                gen.append((p, g))
            else:
                imp.append((p, g))
    if len(imp) > max_impostors:
        # deterministic stride subsample to keep the matrix tractable
        step = len(imp) // max_impostors
        imp = imp[::step][:max_impostors]
    return gen, imp


# ---- self-test (no dataset needed) ------------------------------------------

def _selftest() -> int:
    import tempfile
    from pathlib import Path
    ok = True
    with tempfile.TemporaryDirectory() as d:
        # Fake RidgeBase-ish tree
        for rel in [
            'Task2/S001_1_0_CL.png', 'Task2/S001_1_0_CB.png',
            'Task2/S001_2_0_CL.png', 'Task2/S002_1_0_CL.png',
            'Task2/S002_1_0_CB.png',
        ]:
            fp = Path(d) / rel
            fp.parent.mkdir(parents=True, exist_ok=True)
            fp.write_bytes(b'\x89PNG\r\n')
        recs = index_dataset(d, 'ridgebase')
        s = summarize(recs)
        assert s['images'] == 5, s
        assert s['pairable_fingers'] == 2, s   # S001/1 and S002/1
        gen, imp = genuine_impostor_pairs(recs)
        # S001/1 CL x S001/1 CB, and S002/1 CL x S002/1 CB => 2 genuine
        assert len(gen) == 2, (len(gen), gen)
        # 3 CL probes x 2 CB gallery = 6 total; 2 genuine => 4 impostor
        assert len(imp) == 4, (len(imp), imp)
        print('ridgebase layout: OK', s)

        # Generic tree
        for rel in ['P1/f1/contactless/a.png', 'P1/f1/contact/a.png']:
            fp = Path(d) / 'gen' / rel
            fp.parent.mkdir(parents=True, exist_ok=True)
            fp.write_bytes(b'\x89PNG\r\n')
        grecs = index_dataset(str(Path(d) / 'gen'), 'generic')
        gs = summarize(grecs)
        assert gs['pairable_fingers'] == 1, gs
        print('generic layout:   OK', gs)

        # Real SD 302 tree shape (verified against the actual archives,
        # 2026-07-17): NOT per-subject directories -- flat, organized by
        # device/resolution/capture-type, with subject+FRGP encoded only in
        # the filename (SUBJECT_DEVICE[_RESOLUTION]_CAPTURE_FRGP.EXT, token
        # count varies by part). Deliberately has NO subject-named directory
        # anywhere so this actually exercises "subject comes from the
        # filename, not the path" rather than accidentally passing because a
        # subject dir happens to still be part of the tree.
        for rel in [
            'SD302a/images/challengers/C/roll/png/00001234_C_roll_01.png',
            'SD302a/images/challengers/C/roll/png/00005678_C_roll_01.png',
            'SD302b/images/baseline/V/1000/roll/png/00001234_V_1000_roll_01.png',
            'SD302d/images/auxiliary/flat/M/500/plain/png/00001234_M_500_plain_02.png',
            'SD302f/images/challengers/T/photo/png/00001234_T_photo_01.jpg',
            'SD302f/images/challengers/T/photo/png/00005678_T_photo_01.jpg',
            'SD302c/images/palm/00001234_C_palm_00.png',   # irrelevant, must not pair
        ]:
            fp = Path(d) / 'sd302' / rel
            fp.parent.mkdir(parents=True, exist_ok=True)
            fp.write_bytes(b'\xff\xd8\xff' if rel.endswith('.jpg') else b'\x89PNG\r\n')
        srecs = index_dataset(str(Path(d) / 'sd302'), 'sd302')
        ss = summarize(srecs)
        # 6 classified records (subject1: a,b,d contact + f contactless;
        # subject2: a contact + f contactless) -- the SD302c palm image is
        # excluded entirely (returns None), not counted at all.
        assert ss['images'] == 6, ss
        assert ss['by_modality'] == {'contact': 4, 'contactless': 2}, ss
        # pairable: subject 00001234 finger 01 (a+b+f all present) and
        # subject 00005678 finger 01 (a+f present) => 2 pairable fingers.
        # Subject 00001234's finger 02 (SD302d only, no contactless) is NOT
        # pairable on its own.
        assert ss['pairable_fingers'] == 2, ss
        sgen, simp = genuine_impostor_pairs(srecs)
        assert len(sgen) == 3, (len(sgen), sgen)   # a+f and b+f for 00001234, a+f for 00005678
        print('sd302 layout:     OK', ss)
    print('SELFTEST PASSED')
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root')
    ap.add_argument('--layout', default='auto',
                    choices=['auto', 'ridgebase', 'sd302', 'generic'])
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest or not a.root:
        return _selftest()
    recs = index_dataset(a.root, a.layout)
    s = summarize(recs)
    print(f'layout={a.layout if a.layout != "auto" else detect_layout(a.root)}')
    for k, v in s.items():
        print(f'  {k}: {v}')
    gen, imp = genuine_impostor_pairs(recs)
    print(f'  genuine_pairs: {len(gen)}  impostor_pairs(capped): {len(imp)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
