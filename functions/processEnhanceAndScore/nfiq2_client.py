"""
Client for the NFIQ2 sidecar Cloud Run service (functions/nfiq2_service/).

processEnhanceAndScore deploys via Firebase's buildpack-based Functions
flow, which has no Dockerfile hook, so the real NIST NFIQ2 binary (a C++
tool with an OpenCV dependency, distributed as an apt .deb -- not a
portable static binary) runs in a separate, purpose-built Cloud Run
service instead of in-process. This module is the HTTP client side of
that split.

nfiq_resnet18.onnx (see main.py's _score_nfiq) is a learned proxy trained
on scanner prints -- fast, used as the training/ranking signal throughout
this pipeline, but not the ground-truth NIST algorithm. NFIQ2 here is that
ground-truth validation layer, additive only: see score_nfiq2()'s contract
below.
"""

from __future__ import annotations

import io
import logging
import os

import requests

logger = logging.getLogger(__name__)

_NFIQ2_TARGET_SIZE = (500, 500)   # matches the ResNet18 proxy's input size
_NFIQ2_TIMEOUT_SEC = 10
_NFIQ2_SERVICE_URL = os.environ.get('NFIQ2_SERVICE_URL', '').rstrip('/')

_id_token_cache: dict[str, tuple[str, float]] = {}


def _fetch_id_token(audience: str) -> str:
    """Cloud Run service-to-service auth: an ID token scoped to the sidecar's
    own URL as audience, using this function's runtime service account.
    Cached per-audience for ~50 minutes (tokens are valid ~60 min) to avoid
    a metadata-server round trip on every capture.
    """
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


def score_nfiq2(image_array) -> int | None:
    """Score a grayscale image with the real NIST NFIQ2 binary via the
    sidecar service. Contract (per the pipeline's non-blocking design used
    everywhere else in this codebase): NEVER raises, NEVER blocks the
    pipeline beyond its own timeout budget. Returns an int 0-100 on
    success, or None on any failure (service unreachable, not configured,
    timeout, bad response) -- the caller treats None as "skip this field",
    not as an error to surface to the user.

    image_array: the same enhanced/rendered grayscale numpy image already
    passed to the ResNet18 proxy scorer (_score_nfiq in main.py).
    """
    if not _NFIQ2_SERVICE_URL:
        logger.info('NFIQ2_SERVICE_URL not configured -- skipping NFIQ2 scoring')
        return None

    try:
        from PIL import Image
        import numpy as np

        img = image_array
        if img.dtype != np.uint8:
            img = np.clip(img, 0, 255).astype(np.uint8)
        if img.ndim == 3:
            img = img[..., 0] if img.shape[-1] == 1 else \
                np.array(Image.fromarray(img).convert('L'))

        pil_img = Image.fromarray(img, mode='L').resize(
            _NFIQ2_TARGET_SIZE, Image.LANCZOS)
        buf = io.BytesIO()
        pil_img.save(buf, format='PNG')
        png_bytes = buf.getvalue()

        token = _fetch_id_token(_NFIQ2_SERVICE_URL)
        resp = requests.post(
            f'{_NFIQ2_SERVICE_URL}/score',
            data=png_bytes,
            headers={
                'Authorization': f'Bearer {token}',
                'Content-Type': 'image/png',
            },
            timeout=_NFIQ2_TIMEOUT_SEC,
        )
        if resp.status_code != 200:
            logger.warning('NFIQ2 sidecar returned %s: %s', resp.status_code, resp.text[:300])
            return None

        score = resp.json().get('score')
        return int(score) if score is not None else None

    except Exception as e:   # noqa: BLE001 — must never block or fail the pipeline
        logger.warning('NFIQ2 scoring failed (non-critical): %s', e)
        return None
