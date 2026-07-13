"""
NFIQ2 sidecar HTTP service.

Wraps the NIST NFIQ2 CLI binary (installed via apt in the Dockerfile) behind
a single POST /score endpoint so processEnhanceAndScore (Firebase Functions,
no Dockerfile of its own) can call it over HTTP instead of subprocess.

IMPORTANT — invocation syntax is best-effort, not confirmed: this sandbox
could not reach github.com or NIST's docs site to pull `nfiq2 --help`
output for the real v2.3.0 binary (network egress here is scoped to a
single unrelated repo). `-i <path>` is the modern NFIQ2 CLI's documented
single-image flag per NIST's own docs description ("only one image ->
prints just the score"), but this has not been run against the real
binary. _parse_score() is deliberately permissive (handles a bare number,
a trailing CSV field, or a stray number anywhere in stdout) so a syntax
mismatch fails soft (None, logged raw output) rather than corrupting a
result -- check this service's Cloud Run logs after first deploy and
adjust NFIQ2_ARGS below if the real output shape differs.
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

        proc = subprocess.run(
            [NFIQ2_BIN, '-i', tmp_path],
            capture_output=True, text=True, timeout=NFIQ2_TIMEOUT_SEC,
        )
        logger.info('nfiq2 rc=%s stdout=%r stderr=%r', proc.returncode, proc.stdout, proc.stderr)

        if proc.returncode != 0:
            return jsonify({'error': f'nfiq2 exited {proc.returncode}', 'stderr': proc.stderr[:500]}), 502

        parsed = _parse_score(proc.stdout)
        if parsed is None:
            return jsonify({'error': 'could not parse score from stdout', 'stdout': proc.stdout[:500]}), 502

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


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 8080)))
