"""Real matchability check: with-trim vs no-trim on b04942ef, against the
CTO's own real ink scan (genuine, assuming this capture is the CTO's own
finger) via SourceAFIS -- CTO directly asked "I need you to check it"
after visually preferring the untrimmed (full-pad) version over the
delivered (crease-trimmed) one on NFIQ2.
"""
import subprocess, re

JAR = '/home/user/ClearBridge-Mobile-Build/scratchpad/sourceafis/target/sourceafis-matcher.jar'
INK = '/tmp/claude-0/-home-user-ClearBridge-Mobile-Build/7c276512-7b7e-5f85-8f5b-2eb1bc5e7593/scratchpad/ps/ink_scan.jpg'

def safis(probe, gallery, dpi=500.0):
    out = subprocess.run(['java', '-jar', JAR, probe, gallery, str(dpi)],
                          capture_output=True, text=True, timeout=60)
    m = re.search(r'^score=([\d.]+)$', out.stdout, re.M)
    return float(m.group(1)) if m else None

for label, path in (('WITH crease-trim (delivered, nfiq2=72)', '/tmp/b04942ef_with_trim.png'),
                     ('WITHOUT crease-trim (nfiq2=51)', '/tmp/b04942ef_no_trim.png')):
    s = safis(path, INK)
    print("%-42s SourceAFIS vs ink scan: %s" % (label, s))
