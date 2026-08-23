"""
Client for the pyfing enhancement sidecar (functions/pyfing_service/).

Same split-service reasoning as nfiq2_client.py/mindtct_client.py:
processEnhanceAndScore deploys via Firebase's buildpack-based Functions
flow with no Dockerfile hook, and pyfing needs a full second ML framework
(Keras/TensorFlow) alongside the existing PyTorch stack -- kept in its own
sidecar rather than added to the shared function's dependency footprint.

This is a candidate INPUT to the fidelity axis (docs/
GROUND_TRUTH_MATCHING_SCOPE.md), not a replacement for the existing
classical Gabor enhancement (afis_print.py) -- see
`ml/mac3d_enhance/README.md`'s max-of-variants integration pattern, which
this is meant to slot into eventually as a `('pyfing', ...)` entry in
main.py's `_afis_variants`, scored alongside every existing variant so it
can only ever raise the result.

First real test (this session): SNFEN (the default method) scored
competitively with the production pipeline's own tuned output on a real
capture (bozorth3 match score 7 vs. 6 against the CTO's ink scan) using a
crude manual crop, no guideRegion alignment, no multi-frame fusion, zero
training. GBFEN (classical, non-neural) scored lower (4). SNFEN is the
default here for that reason -- revisit if real data on the pipeline's own
guideRegion-cropped input says otherwise.
"""

from __future__ import annotations

import io
import logging
import os

import requests

logger = logging.getLogger(__name__)

_PYFING_TIMEOUT_SEC = 30  # pyfing's Keras models are much slower than mindtct/bozorth3's C binaries
_PYFING_SERVICE_URL = os.environ.get('PYFING_SERVICE_URL', '').rstrip('/')

_id_token_cache: dict[str, tuple[str, float]] = {}


def _fetch_id_token(audience: str) -> str:
    """Identical pattern to nfiq2_client._fetch_id_token -- see that module."""
    import time
    cached = _id_token_cache.get(audience)
    if cached and cached[1] > time.monotonic():
        return cached[0]

    import google.auth.transport.requests
    import google.oauth2.id_token
    token = google.oauth2.id_token.fetch_id_token(
        google.auth.transport.requests.Request(), audience)
    _id_token_cache[audience] = (token, time.monotonic() + 50 * 60)
    return token


def _to_png_bytes(image_array) -> bytes:
    from PIL import Image
    import numpy as np

    img = image_array
    if img.dtype != np.uint8:
        img = np.clip(img, 0, 255).astype(np.uint8)
    if img.ndim == 3:
        img = img[..., 0] if img.shape[-1] == 1 else \
            np.array(Image.fromarray(img).convert('L'))
    buf = io.BytesIO()
    Image.fromarray(img, mode='L').save(buf, format='PNG')
    return buf.getvalue()


def enhance_fingerprint(image_array, method: str = 'SNFEN', dpi: int = 500) -> 'np.ndarray | None':
    """Enhance a grayscale fingerprint image via the pyfing sidecar. Returns
    the enhanced image as a grayscale numpy array, or None on any failure --
    same non-blocking contract as score_nfiq2/extract_minutiae/match_prints:
    never raises, caller treats None as "skip this variant".

    image_array: a grayscale numpy array (e.g. a raw burst frame or the
    pipeline's own guideRegion-cropped pad image -- NOT resized to any fixed
    size; pyfing's own dpi parameter is how it's told the physical scale).
    method: 'SNFEN' (neural, scored higher in this project's first real
    test) or 'GBFEN' (classical Gabor, no Keras dependency server-side but
    scored lower here)."""
    if not _PYFING_SERVICE_URL:
        logger.info('PYFING_SERVICE_URL not configured -- skipping pyfing enhancement')
        return None

    try:
        from PIL import Image
        import numpy as np

        png_bytes = _to_png_bytes(image_array)
        token = _fetch_id_token(_PYFING_SERVICE_URL)
        resp = requests.post(
            f'{_PYFING_SERVICE_URL}/enhance',
            params={'method': method, 'dpi': dpi},
            data=png_bytes,
            headers={'Authorization': f'Bearer {token}', 'Content-Type': 'image/png'},
            timeout=_PYFING_TIMEOUT_SEC,
        )
        if resp.status_code != 200:
            logger.warning('pyfing sidecar returned %s: %s', resp.status_code, resp.text[:300])
            return None

        return np.array(Image.open(io.BytesIO(resp.content)).convert('L'))

    except Exception as e:   # noqa: BLE001 — must never block or fail the pipeline
        logger.warning('pyfing enhancement failed (non-critical): %s', e)
        return None
