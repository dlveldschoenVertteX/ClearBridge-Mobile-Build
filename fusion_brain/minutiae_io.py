"""mindtct wrapper + .xyt minutiae I/O.

Uses the NBIS mindtct binary already vendored in this repo
(functions/nfiq2_service/vendor/nbis) and built at MINDTCT_BIN. Read-only
with respect to everything outside fusion_brain/.

.xyt format (mindtct -m1): one minutia per line, "x y theta quality"
  x, y   : pixel coords (mindtct emits y already flipped to image space)
  theta  : orientation in degrees, 0-359
  quality: 0-100 mindtct reliability x100
"""
from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass
from typing import List, Optional

import cv2
import numpy as np

MINDTCT_BIN = os.environ.get('MINDTCT_BIN', '/tmp/nbis_bin/mindtct')
BOZORTH3_BIN = os.environ.get('BOZORTH3_BIN', '/tmp/nbis_bin/bozorth3')


@dataclass
class Minutia:
    x: float
    y: float
    theta: float      # degrees 0-359
    quality: float    # 0-100
    source: str = ''  # which architecture produced it

    def as_xyt_line(self) -> str:
        return f'{int(round(self.x))} {int(round(self.y))} ' \
               f'{int(round(self.theta)) % 360} {int(round(self.quality))}'


def extract_minutiae(img: np.ndarray, source: str = '',
                     boost: bool = False) -> List[Minutia]:
    """Run mindtct on a grayscale/BGR image, return its minutiae.

    Writes to a PGM temp file -- mindtct's own supported input formats do not
    include PNG, and silently failing to read is worse than converting.
    """
    if img is None:
        return []
    gray = img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    with tempfile.TemporaryDirectory() as td:
        # mindtct's supported inputs are ANSI/NIST, WSQ, JPEGB, JPEGL and
        # IHead -- NOT PGM/PNG (verified directly: PGM returns
        # "image type UNKNOWN : not supported", exit 253). Baseline JPEG at
        # quality 100 is the least-lossy option it will actually read.
        src = os.path.join(td, 'in.jpg')
        cv2.imwrite(src, gray, [cv2.IMWRITE_JPEG_QUALITY, 100])
        oroot = os.path.join(td, 'out')
        cmd = [MINDTCT_BIN, '-m1']
        if boost:
            cmd.insert(1, '-b')
        cmd += [src, oroot]
        try:
            subprocess.run(cmd, capture_output=True, timeout=120, check=True)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            print(f'  [minutiae_io] mindtct failed for source={source!r}: {e}')
            return []
        xyt = oroot + '.xyt'
        if not os.path.exists(xyt):
            return []
        out: List[Minutia] = []
        with open(xyt) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 3:
                    continue
                try:
                    out.append(Minutia(
                        x=float(parts[0]), y=float(parts[1]),
                        theta=float(parts[2]),
                        quality=float(parts[3]) if len(parts) > 3 else 0.0,
                        source=source))
                except ValueError:
                    continue
        return out


def write_xyt(minutiae: List[Minutia], path: str) -> str:
    with open(path, 'w') as f:
        for m in minutiae:
            f.write(m.as_xyt_line() + '\n')
    return path


def bozorth_match(probe_xyt: str, gallery_xyt: str) -> Optional[int]:
    """Real bozorth3 match score. None on failure (never raises)."""
    try:
        r = subprocess.run([BOZORTH3_BIN, probe_xyt, gallery_xyt],
                            capture_output=True, text=True, timeout=120)
        line = r.stdout.strip().splitlines()
        return int(line[-1].strip()) if line else None
    except Exception:
        return None
