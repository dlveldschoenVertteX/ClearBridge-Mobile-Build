"""
Fingerprint Enhancement Pipeline
CLAHE → Multi-scale Gabor → NNS inference → Post-processing

NNS Stage 1 (NNSController):
  Input:  1×1×512×512 float32
  Output: wavelength_map (1×1×64×64, range 8–14px)
          strength_map   (1×1×64×64, range 0.5–2.0)

NNS Stage 3 (FingerprintUNet) — loaded when nns_stage3.pt exists:
  Input:  1×1×512×512 float32
  Output: 1×1×512×512 float32 (directly enhanced image)
  Trained on synthetic MAC3D pairs from NISTSD300 rolled prints.
"""

from __future__ import annotations

import logging
import os
from functools import lru_cache

import cv2
import numpy as np

logger = logging.getLogger(__name__)

_MODEL_DIR       = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'model')
_NNS_STAGE1_PATH = os.path.join(_MODEL_DIR, 'nns_stage1.pt')
_NNS_STAGE3_PATH = os.path.join(_MODEL_DIR, 'nns_stage3.pt')

_BLOCK  = 8    # 8×8 blocks → 64×64 grid (Stage 1 only)
_GRID   = 64   # output grid size from Stage 1 NNS


# ── Public entry point ────────────────────────────────────────────────────────

def enhance(image: np.ndarray, sfm_coverage: float = 1.0, config: dict | None = None) -> tuple:
    """
    Accepts any square uint8 grayscale image (output of sfm_pipeline).
    Resizes to 512×512 (NNS fixed input shape), then runs CLAHE and adaptive
    Gabor with wavelengths tuned to the actual ridge period measured in the image.
    Returns (512×512 uint8 enhanced fingerprint, params_dict) for NFIQ scoring.

    sfm_coverage: fraction [0,1] of the cylindrical texture covered by real data.
    config: optional dict of parameter overrides for offline optimization. When
            None, production defaults are used. Keys and defaults:
              clahe_clip_normal  (1.5)   — CLAHE clip for well-exposed frames
              clahe_clip_dark    (2.5)   — CLAHE clip for dark frames (std < 40)
              clahe_tile         (4)     — tile size N for N×N grid
              unet_weight        (0.60)  — Stage-3 UNet weight; gabor = 1 - unet_weight
              stretch_lo         (1)     — percentile for contrast stretch low end
              stretch_hi         (99)    — percentile for contrast stretch high end
              unsharp_sigma      (1.5)   — Gaussian sigma for unsharp mask
              unsharp_strength   (1.4)   — unsharp blend weight (1.0 = no sharpen)
    """
    cfg         = config or {}
    clip_normal = float(cfg.get('clahe_clip_normal', 1.5))
    clip_dark   = float(cfg.get('clahe_clip_dark',   2.5))
    tile_n      = int(cfg.get('clahe_tile', 4))
    unet_w      = float(cfg.get('unet_weight', 0.60))

    # Scale UNet weight down for low-coverage cylindrical prints.
    # Below 0.6 coverage the edges are largely extrapolated; the UNet (trained on
    # complete rolled prints) produces artefacts there, so Gabor carries more weight.
    if sfm_coverage < 0.6:
        unet_w = unet_w * (sfm_coverage / 0.6)
        unet_w = max(unet_w, 0.20)

    if image.dtype != np.uint8:
        image = np.clip(image, 0, 255).astype(np.uint8)

    # Resize to 512×512 for NNS compatibility; INTER_AREA preserves ridge detail
    # when downsampling from the full-res superprint (e.g. 1200×1200 → 512×512).
    if image.shape[:2] != (512, 512):
        image = cv2.resize(image, (512, 512), interpolation=cv2.INTER_AREA)

    # 3.1 — CLAHE normalisation
    normalised = _clahe(image, cfg)
    clahe_clip = float(clip_dark if float(image.std()) < 40.0 else clip_normal)

    # Load NNS model now so _nns_stage is set before the Gabor path decision.
    # On a cold start _nns_stage is None until _nns_predict is called; checking it
    # before the first inference always chose the slow 32-filter bank incorrectly.
    _ensure_nns_loaded()

    # 3.2 — Gabor ridge enhancement (scale tuned to measured ridge period)
    # When Stage 3 UNet is active, replace the 32-filter bank with a single
    # oriented ridge pass (~32× faster).  UNet dominates at unet_w; the
    # Gabor contribution needs only one filter at the dominant orientation.
    # Full 32-filter bank is kept for Stage 1 where Gabor carries 60% weight.
    freq             = _estimate_ridge_frequency(normalised)
    period           = min(1.0 / freq, 30.0)
    gabor_wavelengths = sorted(set(max(4, int(round(period * m))) for m in (0.75, 0.875, 1.0, 1.125)))
    if _nns_stage == 3:
        gabor_fixed = _ridge_pass(normalised, freq=freq)   # 1 filter, dominant orientation
    else:
        gabor_fixed = _multiscale_gabor(normalised, freq=freq)

    # 3.3 — NNS inference (Stage 3 UNet if available, else Stage 1 dynamic Gabor)
    _nns_success = True
    _nns_error: str | None = None
    try:
        nns_out = _nns_predict(normalised)
        if isinstance(nns_out, np.ndarray):
            gabor_w  = 1.0 - unet_w
            enhanced = cv2.addWeighted(gabor_fixed, gabor_w, nns_out, unet_w, 0)
        else:
            wl_map, st_map = nns_out
            gabor_dynamic  = _dynamic_gabor(normalised, wl_map, st_map)
            enhanced       = cv2.addWeighted(gabor_fixed, 0.4, gabor_dynamic, 0.6, 0)
    except Exception as e:
        logger.error(f"NNS inference failed — falling back to fixed Gabor: {e}")
        enhanced = gabor_fixed
        _nns_success = False
        _nns_error   = str(e)[:120]

    # 3.5 — Post-processing
    result = _postprocess(enhanced, cfg)

    params: dict = {
        'nnsStage':         _nns_stage or 1,
        'nnsSuccess':       _nns_success,
        'nnsError':         _nns_error,
        'claheClip':        clahe_clip,
        'claheTile':        tile_n,
        'unetWeight':       unet_w,
        'gaborPath':        'ridge_pass' if _nns_stage == 3 else 'multiscale_bank',
        'gaborWavelengths': [max(4, int(round(period)))] if _nns_stage == 3 else gabor_wavelengths,
        'stretchLo':        float(cfg.get('stretch_lo', 1)),
        'stretchHi':        float(cfg.get('stretch_hi', 99)),
        'unsharpSigma':     float(cfg.get('unsharp_sigma', 3.5)),
    }
    return result, params


# ── Step 3.1: CLAHE ───────────────────────────────────────────────────────────

@lru_cache(maxsize=8)
def _make_clahe(clip: float, tile: int):
    return cv2.createCLAHE(clipLimit=clip, tileGridSize=(tile, tile))


def _clahe(image: np.ndarray, cfg: dict | None = None) -> np.ndarray:
    cfg = cfg or {}
    clip_normal = float(cfg.get('clahe_clip_normal', 1.5))
    clip_dark   = float(cfg.get('clahe_clip_dark',   2.5))
    tile        = int(cfg.get('clahe_tile', 4))
    clip = clip_dark if float(image.std()) < 40.0 else clip_normal
    return _make_clahe(clip, tile).apply(image)


# ── Step 3.2: Multi-scale Gabor bank ─────────────────────────────────────────

_ORIENTATIONS = [i * np.pi / 8 for i in range(8)]  # 0°, 22.5°, 45°, 67.5°, 90°, 112.5°, 135°, 157.5°


@lru_cache(maxsize=None)
def _gabor_kernel(wavelength: int, theta: float) -> np.ndarray:
    sigma = wavelength * 0.56
    ksize = int(6 * sigma + 1) | 1
    k     = cv2.getGaborKernel(
        (ksize, ksize), sigma, theta, float(wavelength), 0.5, 0.0, ktype=cv2.CV_32F
    )
    # L2-normalise so filter response magnitude is independent of kernel size.
    # Without this, large wavelengths (30px+) saturate the uint8 output.
    norm = float(np.sqrt(np.sum(k.astype(np.float64) ** 2)))
    if norm > 0:
        k = k / norm
    return k


def _sharpest_roi(image: np.ndarray, half: int = 64) -> np.ndarray:
    """Return the 128×128 crop from the quadrant with the highest Laplacian variance.
    Avoids the cylindrical-superpaint seam which tends to land near the image centre."""
    h, w   = image.shape[:2]
    mid_y, mid_x = h // 2, w // 2
    quads  = [
        image[:mid_y,   :mid_x],
        image[:mid_y,   mid_x:],
        image[mid_y:,   :mid_x],
        image[mid_y:,   mid_x:],
    ]
    scores = [float(cv2.Laplacian(q, cv2.CV_64F).var()) for q in quads]
    best   = quads[int(np.argmax(scores))]
    # Crop 128×128 from the centre of the winning quadrant
    cy, cx = best.shape[0] // 2, best.shape[1] // 2
    bh = min(half, cy, cx)
    return best[cy - bh:cy + bh, cx - bh:cx + bh].astype(np.float32)


def _estimate_ridge_frequency(image: np.ndarray) -> float:
    """
    FFT-based ridge frequency estimate (cycles/pixel) on the sharpest 128×128 quadrant.
    Uses a 2D radial average around DC so the estimate is orientation-independent —
    vertical, diagonal and horizontal ridge flows all return the correct period.
    Returns a value clamped to [1/50, 1/5] (ridge period 5–50 px).
    """
    roi    = _sharpest_roi(image)
    fft    = np.abs(np.fft.fftshift(np.fft.fft2(roi)))
    h, w   = fft.shape
    fc     = h // 2
    Y, X   = np.ogrid[:h, :w]
    R      = np.hypot(Y - fc, X - fc).astype(int)
    r_max  = h // 2
    radial_sum = np.bincount(R.ravel(), weights=fft.ravel(), minlength=r_max + 1)
    radial_cnt = np.bincount(R.ravel(),                      minlength=r_max + 1).astype(np.float32) + 1e-9
    radial = (radial_sum / radial_cnt)[1:r_max]
    peak   = int(np.argmax(radial)) + 1
    freq   = peak / roi.shape[0]
    return float(np.clip(freq, 1.0 / 50.0, 1.0 / 5.0))


def _multiscale_gabor(image: np.ndarray, freq: float | None = None) -> np.ndarray:
    """
    Multi-scale Gabor bank with wavelengths centred on the detected ridge period.
    Adapts to the actual ridge frequency at the (512×512) input resolution.
    Wavelengths are capped at 30px to keep kernel sizes manageable (≤ 103px).
    """
    freq   = freq if freq is not None else _estimate_ridge_frequency(image)
    period = 1.0 / freq                        # pixels per ridge
    period = min(period, 30.0)                 # cap: sigma ≤ 16.8, ksize ≤ 103

    # Four wavelengths: ×0.75, ×0.875, ×1.0, ×1.125 of the detected period
    wavelengths = [max(4, int(round(period * m))) for m in (0.75, 0.875, 1.0, 1.125)]
    wavelengths = sorted(set(wavelengths))     # deduplicate

    logger.debug(f"Gabor: ridge_period={period:.1f}px  wavelengths={wavelengths}")

    responses: list = []
    for wl in wavelengths:
        wl_resp: list = []
        for theta in _ORIENTATIONS:
            k    = _gabor_kernel(wl, theta)
            resp = cv2.filter2D(image.astype(np.float32), cv2.CV_32F, k)
            wl_resp.append(np.abs(resp))
        responses.append(np.max(wl_resp, axis=0))

    fused = np.median(responses, axis=0)
    return np.clip(fused, 0, 255).astype(np.uint8)


# ── Step 3.3: NNS Controller inference ───────────────────────────────────────

def _load_nns_model():
    """
    Load NNS model. Prefers Stage 3 (FingerprintUNet) over Stage 1 (NNSController).
    /tmp/ is checked first (populated by main.py _ensure_models on cold start).
    Returns (model, stage) tuple.
    """
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    # ── Stage 3: FingerprintUNet (direct image output) ────────────────────────
    class _Block(nn.Module):
        def __init__(self, ic, oc):
            super().__init__()
            self.seq = nn.Sequential(
                nn.Conv2d(ic, oc, 3, padding=1, bias=False), nn.BatchNorm2d(oc), nn.ReLU(inplace=True),
                nn.Conv2d(oc, oc, 3, padding=1, bias=False), nn.BatchNorm2d(oc), nn.ReLU(inplace=True),
            )
        def forward(self, x): return self.seq(x)

    class FingerprintUNet(nn.Module):
        C = [1, 24, 48, 96, 192]
        def __init__(self):
            super().__init__()
            c = self.C
            self.enc1 = _Block(c[0], c[1]); self.enc2 = _Block(c[1], c[2])
            self.enc3 = _Block(c[2], c[3]); self.enc4 = _Block(c[3], c[4])
            self.bridge = _Block(c[4], c[4])
            self.dec4 = _Block(c[4]+c[4], c[3]); self.dec3 = _Block(c[3]+c[3], c[2])
            self.dec2 = _Block(c[2]+c[2], c[1]); self.dec1 = _Block(c[1]+c[1], c[1])
            self.head = nn.Conv2d(c[1], 1, 1)
            self.pool = nn.MaxPool2d(2)
        def forward(self, x):
            s1=self.enc1(x); s2=self.enc2(self.pool(s1))
            s3=self.enc3(self.pool(s2)); s4=self.enc4(self.pool(s3))
            b=self.bridge(self.pool(s4))
            up = lambda t, s: torch.cat([F.interpolate(t, scale_factor=2, mode='bilinear', align_corners=False), s], 1)
            d4=self.dec4(up(b,s4)); d3=self.dec3(up(d4,s3)); d2=self.dec2(up(d3,s2)); d1=self.dec1(up(d2,s1))
            return torch.sigmoid(self.head(d1))

    # ── Stage 1: NNSController (wavelength + strength maps) ───────────────────
    class NNSController(nn.Module):
        def __init__(self):
            super().__init__()
            self.input_proj = nn.Sequential(nn.Conv2d(1,64,7,stride=2,padding=3), nn.ReLU(), nn.MaxPool2d(2,2))
            self.encoder    = nn.Sequential(nn.Conv2d(64,128,3,stride=2,padding=1), nn.ReLU(), nn.Conv2d(128,256,3,stride=2,padding=1))
            self.decoder    = nn.Sequential(nn.ConvTranspose2d(256,128,4,stride=2,padding=1), nn.ReLU())
            self.wavelength_head = nn.Conv2d(128, 1, 1)
            self.strength_head   = nn.Conv2d(128, 1, 1)
        def forward(self, x):
            x = self.input_proj(x); x = self.encoder(x); x = self.decoder(x)
            return torch.sigmoid(self.wavelength_head(x))*6+8, torch.sigmoid(self.strength_head(x))*1.5+0.5

    def _resolve(tmp_name, local_path):
        tmp = f'/tmp/{tmp_name}'
        return tmp if os.path.exists(tmp) else (local_path if os.path.exists(local_path) else None)

    # Prefer Stage 3
    s3_path = _resolve('nns_stage3.pt', _NNS_STAGE3_PATH)
    if s3_path:
        model = FingerprintUNet()
        state = torch.load(s3_path, map_location='cpu', weights_only=True)
        if isinstance(state, dict) and 'model_state' in state:
            state = state['model_state']
        model.load_state_dict(state, strict=True)
        model.eval()
        logger.info(f"NNS Stage 3 (FingerprintUNet) loaded from {s3_path}")
        return model, 3

    # Fall back to Stage 1
    s1_path = _resolve('nns_stage1.pt', _NNS_STAGE1_PATH)
    model = NNSController()
    if s1_path:
        state = torch.load(s1_path, map_location='cpu', weights_only=True)
        if isinstance(state, dict) and 'model_state_dict' in state:
            state = state['model_state_dict']
        model.load_state_dict(state, strict=False)
        logger.info(f"NNS Stage 1 (NNSController) loaded from {s1_path}")
    else:
        logger.warning("No NNS model found — using untrained Stage 1 weights")
    model.eval()
    return model, 1


_nns_model = None
_nns_stage = None


def _ensure_nns_loaded():
    global _nns_model, _nns_stage
    if _nns_model is None:
        _nns_model, _nns_stage = _load_nns_model()


def _nns_predict(image: np.ndarray):
    """
    Run NNS inference.
    Stage 3: returns 512×512 uint8 enhanced image directly.
    Stage 1: returns (wavelength_map 64×64, strength_map 64×64).
    """
    import torch
    global _nns_model, _nns_stage
    if _nns_model is None:
        _nns_model, _nns_stage = _load_nns_model()

    tensor = torch.from_numpy(image.astype(np.float32) / 255.0).unsqueeze(0).unsqueeze(0)
    with torch.no_grad():
        out = _nns_model(tensor)

    if _nns_stage == 3:
        enhanced = (out.squeeze().numpy() * 255.0).clip(0, 255).astype(np.uint8)
        return enhanced   # np.ndarray → caller blends with fixed Gabor

    # Stage 1: tuple of (wl_t, st_t)
    wl_t, st_t = out
    return wl_t.squeeze().numpy(), st_t.squeeze().numpy()


# ── Step 3.4: Dynamic Gabor (NNS-guided, per-region) ─────────────────────────

def _dynamic_gabor(image: np.ndarray, wl_map: np.ndarray, st_map: np.ndarray) -> np.ndarray:
    """Apply per-block Gabor with NNS-predicted wavelength and strength."""
    out   = np.zeros_like(image, dtype=np.float32)
    img_f = image.astype(np.float32)
    # Compute Sobel once on the full image; slice per block (avoids 4096 Sobel calls)
    gx_full = cv2.Sobel(img_f, cv2.CV_32F, 1, 0, ksize=3)
    gy_full = cv2.Sobel(img_f, cv2.CV_32F, 0, 1, ksize=3)

    for gi in range(_GRID):
        for gj in range(_GRID):
            y0, y1 = gi * _BLOCK, (gi + 1) * _BLOCK
            x0, x1 = gj * _BLOCK, (gj + 1) * _BLOCK
            block  = img_f[y0:y1, x0:x1]

            wl     = float(np.clip(wl_map[gi, gj], 8, 14))
            st     = float(np.clip(st_map[gi, gj], 0.5, 2.0))

            # Circular mean of doubled angles resolves the 0°/180° ridge ambiguity —
            # same technique as _ridge_pass, applied per-block here.
            gx_blk  = gx_full[y0:y1, x0:x1].ravel()
            gy_blk  = gy_full[y0:y1, x0:x1].ravel()
            angles  = np.arctan2(gy_blk, gx_blk + 1e-9)
            theta   = float(np.angle(np.mean(np.exp(2j * angles))) / 2.0 + np.pi / 2.0) % np.pi

            k      = _gabor_kernel(int(round(wl)), theta)
            resp   = cv2.filter2D(block, cv2.CV_32F, k)
            out[y0:y1, x0:x1] = np.abs(resp) * st

    return np.clip(out, 0, 255).astype(np.uint8)


# ── Step 3.5: Post-processing ─────────────────────────────────────────────────

def _postprocess(image: np.ndarray, cfg: dict | None = None) -> np.ndarray:
    """
    Contrast stretch + unsharp mask → enhanced grayscale for NFIQ scoring.
    NFIQ ResNet18 is trained on grayscale images; binarisation/thinning here
    would produce misleading quality scores.
    """
    cfg = cfg or {}
    lo_pct  = float(cfg.get('stretch_lo', 1))
    hi_pct  = float(cfg.get('stretch_hi', 99))
    sigma   = float(cfg.get('unsharp_sigma', 1.5))    # optimised: 3.5→1.5
    strength = float(cfg.get('unsharp_strength', 1.4))  # optimised: 1.8→1.4

    lo, hi = int(np.percentile(image, lo_pct)), int(np.percentile(image, hi_pct))
    if hi > lo:
        stretched = np.clip((image.astype(np.float32) - lo) / (hi - lo) * 255, 0, 255).astype(np.uint8)
    else:
        stretched = image.copy()

    if strength > 1.0:
        blurred   = cv2.GaussianBlur(stretched, (0, 0), sigmaX=sigma)
        sharpened = cv2.addWeighted(stretched, strength, blurred, -(strength - 1.0), 0)
        return np.clip(sharpened, 0, 255).astype(np.uint8)
    return stretched


# ── Step 3.7: Cosmetic ink/livescan display style ─────────────────────────────

def ink_scanner_style(image: np.ndarray, strength: float = 7.0) -> np.ndarray:
    """
    Display-only S-curve: pushes ridge/valley contrast toward the high-contrast,
    evenly-illuminated look of a real ink or livescan capture. This is what FBI
    EBTS Appendix F / ANSI-NIST-ITL fingerprint images actually look like —
    8-bit grayscale with strong local contrast, not the softer photographic
    gradient `enhance()` produces, and NOT colourised (colour images aren't a
    valid AFIS submission format).

    Deliberately NOT applied before NFIQ scoring or Henry classification —
    both are calibrated against the pre-curve grayscale output, and pushing
    contrast this hard beforehand risks feeding them an out-of-distribution
    image. Call this only on the copy that gets saved/shown to the user.
    """
    img_f = image.astype(np.float32)
    fg    = img_f[img_f < 235]
    mid   = float(np.median(fg)) if fg.size else 128.0
    x     = (img_f - mid) / 255.0
    y     = 1.0 / (1.0 + np.exp(-strength * x))
    out   = np.clip(y * 255, 0, 255).astype(np.uint8)
    bg    = img_f > 245
    out[bg] = image[bg]   # leave true (near-white) background pixels untouched
    return out


# ── Step 3.6: Ridge-orientation final pass ────────────────────────────────────

def _ridge_pass(image: np.ndarray, freq: float | None = None) -> np.ndarray:
    """
    Single-orientation Gabor pass tuned to the detected ridge frequency and dominant
    ridge direction. Adds 20% ridge-frequency contrast on top of the post-processed
    image, targeting exactly what NFIQ measures (ridge clarity at the local period).

    Uses circular mean of doubled Sobel angles to avoid the 0°/180° ambiguity in
    ridge orientation estimation (ridges are symmetric; doubling maps both halves
    to the same semicircle, mean gives the dominant orientation).
    """
    freq   = freq if freq is not None else _estimate_ridge_frequency(image)
    period = min(1.0 / freq, 30.0)
    wl     = max(4, int(round(period)))

    # Dominant ridge orientation from the sharpest quadrant (avoids centre seam artefacts)
    roi    = _sharpest_roi(image)
    gx     = cv2.Sobel(roi, cv2.CV_32F, 1, 0, ksize=3)
    gy     = cv2.Sobel(roi, cv2.CV_32F, 0, 1, ksize=3)
    # Double the gradient angle → circular mean → halve back: resolves 0°/180° ambiguity
    angles = np.arctan2(gy.ravel(), gx.ravel())
    theta  = float(np.angle(np.mean(np.exp(2j * angles))) / 2.0 + np.pi / 2.0) % np.pi

    k     = _gabor_kernel(wl, theta)
    resp  = cv2.filter2D(image.astype(np.float32), cv2.CV_32F, k)
    ridge = np.clip(np.abs(resp), 0, 255).astype(np.uint8)
    return cv2.addWeighted(image, 0.80, ridge, 0.20, 0)
