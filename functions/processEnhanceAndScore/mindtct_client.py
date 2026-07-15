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

DPI normalization (added after the first real baseline test, 2026-07-15):
mindtct is calibrated for ~500 DPI fingerprint images -- a real physical-
resolution assumption a fixed-size resize (like nfiq2_client's 500x500)
would violate, since it'd distort real minutiae spacing differently per
image. The first real probe/gallery pair tested (a 72-nfiq2Score digital
capture vs. the CTO's ink scan) came back at only bozorth3 score 3, and a
quick manual wavelength measurement (a single hand-picked ROI per image)
found a real, large scale mismatch (~13.6px native in the digital capture
vs. ~37.5px in the ink scan) -- correcting toward it raised the score to
14, real evidence scale matters. Building this into a real function
exposed that the quick manual measurement wasn't itself reliable: a naive
centered ROI swept across nearby crop sizes gave wildly inconsistent
estimates on the ink scan (61px to 163px) because a real photo's lighting/
shading gradient can dominate the low frequencies a small min_r cutoff
doesn't exclude. _estimate_ridge_wavelength_px's roi_frac=0.6/min_r=15
defaults were chosen because they're the ones that converge to a stable
answer across a wide range of nearby parameter values on both real images
(~11.7px digital capture, ~21.6px ink scan) -- convergence, not a single
lucky number, is what makes an estimate trustworthy on a noisy real photo.
Rerunning the real match with this more rigorous scale estimate actually
scored LOWER (6, vs. the quick pass's 14) -- an honest result, not tuned to
look good: it means the quick pass's estimate happened to be closer by
chance, and that scale alone isn't the dominant gap for this pair. Real
remaining candidates: the ink scan covers the whole thumb while the digital
capture's guideRegion only frames the pad's top portion (a coverage
mismatch, not fixable by scale/orientation correction), and the ink scan
photo itself has real quality issues (blur, low contrast, described by the
CTO as "the best I could get"). Don't over-read a single pair's score
either way -- more paired samples are needed before treating any number
here as a verdict on fidelity.

Mirror handling (same session): the CTO directly observed the loop is on
the wrong side between a digital capture and the ink scan. Checked
packages/mac_capture's still-image decode path (decodeStillJpegToLuma) for
an app-level mirroring bug -- found none; it only rotates for sensor
orientation, never flips, so this isn't a software bug traceable in this
codebase. Testing all 8 rotate/mirror combinations of one real pair only
spread bozorth3 scores 10-18 (too narrow/noisy at this quality level to
trust any single orientation as "the" correct one -- genuine matches
typically score far higher). Rather than hard-code a specific transform
from noisy, low-confidence data, match_prints() tries both the image as
normalized and its mirror image, and keeps the higher bozorth3 score -- the
same max-of-variants, cannot-regress pattern already used throughout this
project (NFIQ2 variant selection, AFIS enhancement variants). Revisit if a
real root cause for the mirroring is found.
"""

from __future__ import annotations

import io
import logging
import os

import numpy as np
import requests

logger = logging.getLogger(__name__)

_NBIS_TIMEOUT_SEC = 10
_NFIQ2_SERVICE_URL = os.environ.get('NFIQ2_SERVICE_URL', '').rstrip('/')

# Matches afis_print.py's _TARGET_PERIOD -- the ~500 DPI domain mindtct
# (like every scanner-trained ridge model in this project) is calibrated for.
_TARGET_RIDGE_WAVELENGTH_PX = 9.0
# Estimates outside this range are treated as unreliable (e.g. picked up
# lighting/shading gradient instead of ridge frequency on a noisy real
# photo) and left unscaled rather than trusted -- same "don't distort on a
# shaky number" discipline as afis_print.py's own frequency-scale clamp.
_MIN_RELIABLE_WAVELENGTH_PX = 4.0
_MAX_RELIABLE_WAVELENGTH_PX = 80.0
# Clamp the resulting resize factor itself too, independent of the above --
# a bad wavelength estimate near the edge of the "reliable" band could still
# imply an extreme, implausible resize.
_MIN_SCALE_FACTOR = 0.1
_MAX_SCALE_FACTOR = 4.0

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


def _estimate_ridge_wavelength_px(gray: 'np.ndarray') -> float | None:
    """FFT-based dominant ridge period estimate over a centered ROI.
    Returns None if the estimate falls outside a plausible range (e.g. a
    noisy real photo's lighting/shading gradient dominating the low
    frequencies instead of actual ridge periodicity) -- caller should skip
    scaling rather than trust a bad number, same discipline as everywhere
    else in this project.

    roi_frac=0.6 and min_r=15 were chosen by testing against two real
    images (a clean digital superprint and the CTO's real ink-scan photo),
    sweeping both parameters and picking the combination that gave a STABLE
    estimate across a wide range of nearby values for both -- smaller ROIs
    and/or a lower min_r cutoff gave wildly inconsistent estimates on the
    ink scan (61px to 163px depending on ROI size) because they let a
    low-frequency lighting/shading gradient win the radial peak search
    instead of the actual ridge periodicity. Convergence across parameter
    values, not a single lucky number, is what makes an estimate trustworthy
    here -- revisit only with more real paired images, not by tuning to a
    single case."""
    h, w = gray.shape[:2]
    roi_frac = 0.6
    rh, rw = int(h * roi_frac), int(w * roi_frac)
    if rh < 32 or rw < 32:
        return None
    y0, x0 = (h - rh) // 2, (w - rw) // 2
    roi = gray[y0:y0 + rh, x0:x0 + rw].astype(np.float64)
    roi = roi - roi.mean()
    # Hann window on both axes -- reduces edge leakage that would otherwise
    # smear energy into spurious low frequencies.
    roi = roi * np.hanning(roi.shape[0])[:, None] * np.hanning(roi.shape[1])[None, :]

    mag = np.abs(np.fft.fftshift(np.fft.fft2(roi)))
    ch, cw = mag.shape[0] // 2, mag.shape[1] // 2
    yy, xx = np.mgrid[0:mag.shape[0], 0:mag.shape[1]]
    r = np.sqrt((yy - ch) ** 2 + (xx - cw) ** 2).astype(int)
    max_r = min(ch, cw)

    min_r = 15
    if max_r <= min_r:
        return None
    profile = np.array([mag[r == i].mean() if (r == i).any() else 0.0
                        for i in range(min_r, max_r)])
    if profile.size == 0 or profile.max() <= 0:
        return None
    peak_r = int(np.argmax(profile)) + min_r

    wavelength_px = min(roi.shape) / peak_r
    if not (_MIN_RELIABLE_WAVELENGTH_PX <= wavelength_px <= _MAX_RELIABLE_WAVELENGTH_PX):
        logger.info('ridge wavelength estimate %.1fpx outside reliable range, skipping DPI scale', wavelength_px)
        return None
    return wavelength_px


def _normalize_dpi(gray: 'np.ndarray') -> tuple['np.ndarray', float | None]:
    """Rescale toward _TARGET_RIDGE_WAVELENGTH_PX based on a measured ridge
    wavelength. Returns (possibly-rescaled array, scale factor applied or
    None if left unscaled -- either no reliable estimate, or the implied
    scale itself was outside the sane clamp range)."""
    from PIL import Image

    wavelength_px = _estimate_ridge_wavelength_px(gray)
    if wavelength_px is None:
        return gray, None

    scale = _TARGET_RIDGE_WAVELENGTH_PX / wavelength_px
    if not (_MIN_SCALE_FACTOR <= scale <= _MAX_SCALE_FACTOR):
        logger.info('DPI scale factor %.3f outside sane range, skipping', scale)
        return gray, None

    h, w = gray.shape[:2]
    new_size = (max(1, int(w * scale)), max(1, int(h * scale)))
    img = Image.fromarray(gray).resize(new_size, Image.LANCZOS)
    return np.array(img), scale


def _to_png_bytes(image_array) -> bytes:
    from PIL import Image

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


def _call_match_endpoint(probe_gray: 'np.ndarray', gallery_gray: 'np.ndarray') -> int | None:
    """Single HTTP round-trip to the sidecar's /match endpoint. Returns the
    raw bozorth3 score, or None on any failure."""
    token = _fetch_id_token(_NFIQ2_SERVICE_URL)
    resp = requests.post(
        f'{_NFIQ2_SERVICE_URL}/match',
        files={
            'probe': ('probe.png', _to_png_bytes(probe_gray), 'image/png'),
            'gallery': ('gallery.png', _to_png_bytes(gallery_gray), 'image/png'),
        },
        headers={'Authorization': f'Bearer {token}'},
        timeout=_NBIS_TIMEOUT_SEC,
    )
    if resp.status_code != 200:
        logger.warning('bozorth3 match sidecar returned %s: %s', resp.status_code, resp.text[:300])
        return None
    score = resp.json().get('matchScore')
    return int(score) if score is not None else None


def match_prints(probe_image_array, gallery_image_array) -> dict | None:
    """Match two images via mindtct + bozorth3, with DPI normalization and
    mirror-orientation handling (see module docstring for why both exist --
    both are real, measured fixes from the first baseline test, not
    speculative). Returns None on any failure (same non-blocking contract as
    score_nfiq2/extract_minutiae), or a dict:

        {'matchScore': int,       # the higher of the two orientations' scores
         'mirrorApplied': bool,   # whether the mirrored probe won
         'rawScoreOriginal': int | None,
         'rawScoreMirrored': int | None,
         'probeDpiScale': float | None,   # None if left unscaled (no reliable estimate)
         'galleryDpiScale': float | None}

    probe_image_array / gallery_image_array: grayscale numpy arrays (e.g.
    the pipeline's own enhanced/superprint output vs. a ground-truth scan)."""
    if not _NFIQ2_SERVICE_URL:
        logger.info('NFIQ2_SERVICE_URL not configured -- skipping print matching')
        return None

    try:
        probe_gray = np.asarray(probe_image_array)
        gallery_gray = np.asarray(gallery_image_array)
        if probe_gray.dtype != np.uint8:
            probe_gray = np.clip(probe_gray, 0, 255).astype(np.uint8)
        if gallery_gray.dtype != np.uint8:
            gallery_gray = np.clip(gallery_gray, 0, 255).astype(np.uint8)

        probe_norm, probe_scale = _normalize_dpi(probe_gray)
        gallery_norm, gallery_scale = _normalize_dpi(gallery_gray)
        probe_mirrored = np.fliplr(probe_norm)

        score_original = _call_match_endpoint(probe_norm, gallery_norm)
        score_mirrored = _call_match_endpoint(probe_mirrored, gallery_norm)

        candidates = [s for s in (score_original, score_mirrored) if s is not None]
        if not candidates:
            return None
        mirror_won = (score_mirrored is not None
                      and score_mirrored >= (score_original if score_original is not None else -1))

        return {
            'matchScore': max(candidates),
            'mirrorApplied': mirror_won,
            'rawScoreOriginal': score_original,
            'rawScoreMirrored': score_mirrored,
            'probeDpiScale': probe_scale,
            'galleryDpiScale': gallery_scale,
        }

    except Exception as e:   # noqa: BLE001 — must never block or fail the pipeline
        logger.warning('print matching failed (non-critical): %s', e)
        return None
