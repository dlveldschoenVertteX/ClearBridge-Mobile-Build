"""
NFIQ2 + NBIS sidecar HTTP service.

Wraps NIST CLI binaries (installed in the Dockerfile) behind HTTP endpoints
so processEnhanceAndScore (Firebase Functions, no Dockerfile of its own) can
call them instead of subprocess. Two families:

- /score      — NFIQ2 (quality metric, existing).
- /minutiae, /match — NBIS mindtct (minutiae extraction) + bozorth3
  (minutiae matching), added for the fidelity/matching prime-directive axis
  (docs/GROUND_TRUTH_MATCHING_SCOPE.md). A different, older NIST project
  from NFIQ2 -- public domain, source-built (see Dockerfile), not an apt
  package.

IMPORTANT — invocation syntax is best-effort, not confirmed against the
REAL compiled binaries: this sandbox cannot execute the Dockerfile's build
to check real CLI behavior (no Docker daemon here; Cloud Build is where
this actually runs). Syntax below is taken from NBIS's own man pages
(mindtct.1: `mindtct [-b] [-m1] <finger_img_in> <oroot>`, producing
`<oroot>.xyt`; bozorth3.1: `bozorth3 [options] probe.xyt gallery.xyt`,
default output is a bare similarity score) — same "best-effort, not
confirmed" caveat this file already carries for NFIQ2's own `-i` flag.
_parse_score() below is deliberately permissive for the same reason: a
syntax mismatch fails soft (None, logged raw output), not silently wrong.
Check this service's Cloud Run logs after first deploy and adjust if the
real output shape differs.
"""

import logging
import os
import re
import subprocess
import tempfile

from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

NFIQ2_BIN = 'nfiq2'
NFIQ2_TIMEOUT_SEC = 8  # caller's HTTP timeout is 10s; leave margin for the round trip


def _parse_score(stdout: str) -> int | None:
    stdout = stdout.strip()
    if not stdout:
        return None
    # Bare integer/float on its own line.
    try:
        return int(round(float(stdout)))
    except ValueError:
        pass
    # CSV row: "<filename>,<score>[,...]" -- take the first numeric field.
    for field in stdout.replace('\n', ',').split(','):
        field = field.strip()
        try:
            return int(round(float(field)))
        except ValueError:
            continue
    # Last resort: first standalone number anywhere in the output.
    m = re.search(r'-?\d+(?:\.\d+)?', stdout)
    if m:
        return int(round(float(m.group(0))))
    return None


def _parse_nfiq2_score(stdout: str) -> int | None:
    """NFIQ2-SPECIFIC parse for /score, stricter than the generic
    _parse_score() above (which /match also uses and must stay permissive,
    since bozorth3's match score has no fixed range).

    Real production bug found 2026-07-17: the `nfiq2 -i <path>` call below
    was missing `-F`, and _parse_score()'s permissive "first numeric field"
    fallback then picked up the WRONG field from nfiq2's non-`-F` default
    output, writing an impossible nfiq2Score=898 to a real capture doc (NFIQ2
    is defined on 0-100). Fixed by always passing `-F` (this project's own
    local NFIQ2 build was calibrated against exactly the `-F` CSV format —
    column index 2, "QualityScore" — and confirmed an exact match to a real
    production score; see CLAUDE.md), preferring that column explicitly here,
    and hard-validating the final result is in [0,100] -- an out-of-range
    number is DEFINITIONALLY a parsing error, not a real NFIQ2 score, so this
    returns None (the route's existing 'could not parse' 502) rather than
    ever writing a nonsense value to Firestore again."""
    stdout = stdout.strip()
    score = None
    for line in stdout.splitlines():
        fields = line.split(',')
        if len(fields) >= 3:
            try:
                score = int(round(float(fields[2])))
                break
            except ValueError:
                continue
    if score is None:
        score = _parse_score(stdout)
    if score is None or not (0 <= score <= 100):
        logger.warning('NFIQ2 score failed range validation: parsed=%r stdout=%r',
                        score, stdout)
        return None
    return score


@app.route('/healthz', methods=['GET'])
def healthz():
    return jsonify({'ok': True}), 200


@app.route('/score', methods=['POST'])
def score():
    image_bytes = request.get_data()
    if not image_bytes:
        return jsonify({'error': 'empty request body'}), 400

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as f:
            f.write(image_bytes)
            tmp_path = f.name

        # -F forces NFIQ2's documented CSV output format -- REQUIRED, not
        # cosmetic: without it, a real production capture got an impossible
        # nfiq2Score=898 written to Firestore because the generic permissive
        # parser below picked up the wrong field from nfiq2's non-`-F`
        # default output. See _parse_nfiq2_score's docstring.
        proc = subprocess.run(
            [NFIQ2_BIN, '-i', tmp_path, '-F'],
            capture_output=True, text=True, timeout=NFIQ2_TIMEOUT_SEC,
        )
        logger.info('nfiq2 rc=%s stdout=%r stderr=%r', proc.returncode, proc.stdout, proc.stderr)

        if proc.returncode != 0:
            return jsonify({'error': f'nfiq2 exited {proc.returncode}', 'stderr': proc.stderr[:500]}), 502

        parsed = _parse_nfiq2_score(proc.stdout)
        if parsed is None:
            return jsonify({'error': 'could not parse a valid (0-100) score from stdout', 'stdout': proc.stdout[:500]}), 502

        return jsonify({'score': parsed}), 200

    except subprocess.TimeoutExpired:
        logger.warning('nfiq2 timed out after %ss', NFIQ2_TIMEOUT_SEC)
        return jsonify({'error': 'nfiq2 timed out'}), 504
    except Exception as e:   # noqa: BLE001 — this endpoint must always return JSON, never crash
        logger.exception('nfiq2 scoring failed')
        return jsonify({'error': str(e)}), 500
    finally:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


MINDTCT_BIN = 'mindtct'
BOZORTH3_BIN = 'bozorth3'
NBIS_TIMEOUT_SEC = 8  # same budget reasoning as NFIQ2_TIMEOUT_SEC


def _run_mindtct(image_bytes: bytes, workdir: str, name: str) -> str | None:
    """Run mindtct on one image, return the path to its .xyt minutiae file,
    or None on failure (never raises -- caller decides how to report)."""
    img_path = os.path.join(workdir, f'{name}.png')
    oroot = os.path.join(workdir, name)
    with open(img_path, 'wb') as f:
        f.write(image_bytes)
    proc = subprocess.run(
        [MINDTCT_BIN, img_path, oroot],
        capture_output=True, text=True, timeout=NBIS_TIMEOUT_SEC,
    )
    logger.info('mindtct(%s) rc=%s stdout=%r stderr=%r', name, proc.returncode, proc.stdout, proc.stderr)
    xyt_path = f'{oroot}.xyt'
    return xyt_path if os.path.exists(xyt_path) else None


@app.route('/minutiae', methods=['POST'])
def minutiae():
    """Extract minutiae (mindtct) from one image. Request body = raw image
    bytes (same convention as /score). Returns the .xyt file content (plain
    text: one 'x y theta quality' row per minutia) and a minutiae count."""
    image_bytes = request.get_data()
    if not image_bytes:
        return jsonify({'error': 'empty request body'}), 400

    try:
        with tempfile.TemporaryDirectory() as workdir:
            xyt_path = _run_mindtct(image_bytes, workdir, 'probe')
            if xyt_path is None:
                return jsonify({'error': 'mindtct produced no .xyt output'}), 502
            with open(xyt_path) as f:
                xyt_content = f.read()
            n_minutiae = sum(1 for line in xyt_content.splitlines() if line.strip())
            return jsonify({'xyt': xyt_content, 'minutiaeCount': n_minutiae}), 200

    except subprocess.TimeoutExpired:
        logger.warning('mindtct timed out after %ss', NBIS_TIMEOUT_SEC)
        return jsonify({'error': 'mindtct timed out'}), 504
    except Exception as e:   # noqa: BLE001 — this endpoint must always return JSON, never crash
        logger.exception('mindtct extraction failed')
        return jsonify({'error': str(e)}), 500


@app.route('/match', methods=['POST'])
def match():
    """Match two images' minutiae via mindtct + bozorth3. Request body =
    multipart/form-data with 'probe' and 'gallery' image file fields (two
    images needed, unlike /score and /minutiae's single-image raw body).
    Returns a bozorth3 similarity score -- NOT a fixed pass/fail threshold;
    see docs/GROUND_TRUTH_MATCHING_SCOPE.md for why no universal cutoff is
    hardcoded here."""
    if 'probe' not in request.files or 'gallery' not in request.files:
        return jsonify({'error': "multipart fields 'probe' and 'gallery' required"}), 400

    try:
        with tempfile.TemporaryDirectory() as workdir:
            probe_bytes = request.files['probe'].read()
            gallery_bytes = request.files['gallery'].read()
            probe_xyt = _run_mindtct(probe_bytes, workdir, 'probe')
            gallery_xyt = _run_mindtct(gallery_bytes, workdir, 'gallery')
            if probe_xyt is None or gallery_xyt is None:
                return jsonify({
                    'error': 'mindtct produced no .xyt output for one or both images',
                    'probeOk': probe_xyt is not None,
                    'galleryOk': gallery_xyt is not None,
                }), 502

            proc = subprocess.run(
                [BOZORTH3_BIN, probe_xyt, gallery_xyt],
                capture_output=True, text=True, timeout=NBIS_TIMEOUT_SEC,
            )
            logger.info('bozorth3 rc=%s stdout=%r stderr=%r', proc.returncode, proc.stdout, proc.stderr)
            if proc.returncode != 0:
                return jsonify({'error': f'bozorth3 exited {proc.returncode}', 'stderr': proc.stderr[:500]}), 502

            score = _parse_score(proc.stdout)
            if score is None:
                return jsonify({'error': 'could not parse match score from stdout', 'stdout': proc.stdout[:500]}), 502
            return jsonify({'matchScore': score}), 200

    except subprocess.TimeoutExpired:
        logger.warning('bozorth3 matching timed out after %ss', NBIS_TIMEOUT_SEC)
        return jsonify({'error': 'bozorth3 timed out'}), 504
    except Exception as e:   # noqa: BLE001 — this endpoint must always return JSON, never crash
        logger.exception('bozorth3 matching failed')
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 8080)))
