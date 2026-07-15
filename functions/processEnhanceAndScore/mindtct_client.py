"""
Client for the NBIS mindtct/bozorth3 endpoints on the NFIQ2 sidecar Cloud Run
service (functions/nfiq2_service/) -- see docs/GROUND_TRUTH_MATCHING_SCOPE.md.

Same split-service reasoning as nfiq2_client.py: processEnhanceAndScore
deploys via Firebase's buildpack-based Functions flow with no Dockerfile
hook, so NBIS (a source-built C toolset, not portable/pip-installable) runs
in the separate sidecar instead of in-process.

This is the FIDELITY axis (does the print structurally/minutiae-match the
real finger), separate from and complementary to nfiq2_client's QUALITY axis
(does it look like a well-formed print). Neither substitutes for the other.

Deliberately does NOT resize images the way nfiq2_client does (500x500) --
NFIQ2's resize targets its ResNet's fixed input size (an arbitrary pixel
grid), but mindtct is calibrated for ~500 DPI fingerprint images, a real
physical-resolution assumption forcing a fixed pixel-square resize would
violate (it would distort real minutiae spacing differently depending on
each image's original size/aspect ratio). Images are sent at their native
resolution; if minutiae quality turns out poor in practice, the right fix is
DPI-aware resampling toward ~500 DPI, not a fixed-size resize -- revisit only
with real data, same discipline as everywhere else in this project.
"""

from __future__ import annotations

import io
import logging
import os

import requests

logger = logging.getLogger(__name__)

_NBIS_TIMEOUT_SEC = 10
_NFIQ2_SERVICE_URL = os.environ.get('NFIQ2_SERVICE_URL', '').rstrip('/')

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


def extract_minutiae(image_array) -> dict | None:
    """Extract minutiae via mindtct. Returns {'xyt': str, 'minutiaeCount':
    int} on success, or None on any failure -- same non-blocking contract as
    score_nfiq2: never raises, caller treats None as "skip this field"."""
    if not _NFIQ2_SERVICE_URL:
        logger.info('NFIQ2_SERVICE_URL not configured -- skipping minutiae extraction')
        return None

    try:
        png_bytes = _to_png_bytes(image_array)
        token = _fetch_id_token(_NFIQ2_SERVICE_URL)
        resp = requests.post(
            f'{_NFIQ2_SERVICE_URL}/minutiae',
            data=png_bytes,
            headers={'Authorization': f'Bearer {token}', 'Content-Type': 'image/png'},
            timeout=_NBIS_TIMEOUT_SEC,
        )
        if resp.status_code != 200:
            logger.warning('mindtct sidecar returned %s: %s', resp.status_code, resp.text[:300])
            return None
        return resp.json()

    except Exception as e:   # noqa: BLE001 — must never block or fail the pipeline
        logger.warning('minutiae extraction failed (non-critical): %s', e)
        return None


def match_prints(probe_image_array, gallery_image_array) -> int | None:
    """Match two images via mindtct + bozorth3. Returns a bozorth3
    similarity score (higher = more likely same finger; NO fixed universal
    pass/fail threshold -- see docs/GROUND_TRUTH_MATCHING_SCOPE.md), or None
    on any failure. Same non-blocking contract as score_nfiq2/
    extract_minutiae.

    probe_image_array / gallery_image_array: grayscale numpy arrays (e.g.
    the pipeline's own enhanced/superprint output vs. a ground-truth scan)."""
    if not _NFIQ2_SERVICE_URL:
        logger.info('NFIQ2_SERVICE_URL not configured -- skipping print matching')
        return None

    try:
        probe_png = _to_png_bytes(probe_image_array)
        gallery_png = _to_png_bytes(gallery_image_array)
        token = _fetch_id_token(_NFIQ2_SERVICE_URL)
        resp = requests.post(
            f'{_NFIQ2_SERVICE_URL}/match',
            files={
                'probe': ('probe.png', probe_png, 'image/png'),
                'gallery': ('gallery.png', gallery_png, 'image/png'),
            },
            headers={'Authorization': f'Bearer {token}'},
            timeout=_NBIS_TIMEOUT_SEC,
        )
        if resp.status_code != 200:
            logger.warning('bozorth3 match sidecar returned %s: %s', resp.status_code, resp.text[:300])
            return None
        score = resp.json().get('matchScore')
        return int(score) if score is not None else None

    except Exception as e:   # noqa: BLE001 — must never block or fail the pipeline
        logger.warning('print matching failed (non-critical): %s', e)
        return None
