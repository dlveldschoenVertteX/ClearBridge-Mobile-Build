"""
Mark the N most recent captures as preserveRawFrames=true so frames survive
pipeline processing for offline SFM/enhancement testing.

Usage:
    python mark_preserve.py                    # mark 3 most recent captures
    python mark_preserve.py --n 1              # mark 1 capture
    python mark_preserve.py --id <captureId>   # mark a specific capture
"""

import argparse, os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))

_UID     = 'S7B5LAvXiJdKjHTbpAFMoINv4Um2'
_PROJECT = 'clearbridge-dc699'
_BUCKET  = 'clearbridge-dc699.firebasestorage.app'

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--n',  type=int, default=3)
    p.add_argument('--id', type=str, default=None)
    args = p.parse_args()

    import firebase_admin
    from firebase_admin import credentials, firestore
    if not firebase_admin._apps:
        key = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')
        if key:
            firebase_admin.initialize_app(credentials.Certificate(key), {'projectId': _PROJECT})
        else:
            firebase_admin.initialize_app(options={'projectId': _PROJECT})
    db = firestore.client()

    if args.id:
        cap_ids = [args.id]
    else:
        docs = (db.collection('captures')
                  .where('userId', '==', _UID)
                  .order_by('createdAt', direction='DESCENDING')
                  .limit(args.n)
                  .stream())
        cap_ids = [d.id for d in docs]

    for cid in cap_ids:
        db.collection('captures').document(cid).update({'preserveRawFrames': True})
        print(f'  Marked {cid}  preserveRawFrames=true')

    print(f'\nDone. Frames for these {len(cap_ids)} captures will NOT be deleted after pipeline.')
    print('Run run_sfm_test.py afterward to test against them.')

if __name__ == '__main__':
    main()
