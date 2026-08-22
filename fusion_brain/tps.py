"""STAGE A -- thin-plate-spline elastic registration from minutiae control points.

WHY THIS EXISTS (the Phase 1 post-mortem in one paragraph):
Phase 1 registered each source onto the anchor with a RIGID similarity
transform and merged whatever landed in new territory. It lost to the
anchor alone on real matchability. Rigid is the wrong model for skin --
between two captures the pad genuinely deforms non-rigidly, so a rigid fit
leaves real residual displacement everywhere except wherever it happened to
lock. Merged points land slightly off from where the same physical minutia
actually sits, and a matcher reads near-misses as competing evidence rather
than support.

TPS is the classical fix, and it is the specific technique this project has
had flagged as an unbuilt gap since 2026-07-17 (`geom_correct.py`'s
`elastic_flatten()` is still an identity placeholder; CLAUDE.md's own
prime-directive entry names "no TPS/RTPS elastic-deformation correction" as
a root cause). Prior art: Ross & Jain, "Fingerprint Mosaicking Using Thin
Plate Splines"; Bazen & Gerez, "Elastic minutiae matching by means of thin
plate spline models". The learned successor (Stage B) is Cui/Feng et al.,
arXiv:2004.05972.

The matched minutiae `registration.count_inliers()` already returns become
the TPS control points. No new correspondence machinery is needed -- this
uses the correspondences the rigid step already found, it just fits a far
better-suited deformation model to them.

APPLIED ON TOP OF the rigid transform, never instead of it. TPS's own affine
term could in principle absorb the rigid part, but pre-aligning globally and
fitting TPS to the RESIDUAL is both better conditioned and the order this
project already learned the hard way: `ml/deform_correct`'s training plateau
was root-caused to exactly this (a local-displacement model cannot undo a
gross global misalignment; see CLAUDE.md's deform_correct debugging chain).
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import numpy as np

import registration as reg
from minutiae_io import Minutia


# Minimum control points before a TPS fit is even attempted. A TPS solve
# needs >= 3 for the affine part alone; below ~8 the elastic term is fitting
# noise rather than real deformation, and this project has no shortage of
# evidence that an under-constrained warp does damage.
MIN_CONTROL_POINTS = 8

# Ridge-domain sanity bound. Real inter-capture skin deformation is a
# few ridge periods at most; afis_print normalises every print toward
# _TARGET_PERIOD = 9.0 px, so ~40px is already generous (>4 ridge periods).
# A fitted warp that wants to move a point further than this is not modelling
# skin, it is fitting noise -- reject the whole fit rather than trust it.
MAX_PLAUSIBLE_DISPLACEMENT_PX = 40.0


@dataclass
class TpsWarp:
    """A fitted TPS mapping source-space points into anchor space.

    Stores its own control points so `apply` can measure how far a query
    point sits from the region the fit was actually constrained by -- see
    `_extrapolation_weight` for why that matters here specifically.
    """
    control_src: np.ndarray      # (N,2) control points, source space
    weights_x: np.ndarray        # (N+3,) solved coefficients for x
    weights_y: np.ndarray        # (N+3,) solved coefficients for y
    n_control: int
    max_displacement: float      # largest control-point correction, px
    mean_residual: float         # mean post-fit control-point error, px

    def apply_points(self, pts: np.ndarray, blend_to_identity: bool = True) -> np.ndarray:
        """Warp (M,2) points. See `_extrapolation_weight` for blend_to_identity."""
        return _apply_tps(self, pts, blend_to_identity=blend_to_identity)

    def apply_minutiae(self, ms: Sequence[Minutia],
                       blend_to_identity: bool = True) -> List[Minutia]:
        """Warp minutiae, rotating each theta by the warp's LOCAL Jacobian.

        Skipping the angle update would be a real bug, not a nicety: a TPS
        warp is not conformal, so it rotates ridge direction differently in
        different places. bozorth3/SourceAFIS both use minutia orientation as
        a first-class matching feature, so leaving theta at its pre-warp
        value would hand the matcher points that are in the right place
        pointing the wrong way.
        """
        if not ms:
            return []
        pts = np.array([[m.x, m.y] for m in ms], dtype=np.float64)
        warped = self.apply_points(pts, blend_to_identity=blend_to_identity)
        rot = _local_rotation_deg(self, pts, blend_to_identity=blend_to_identity)
        out: List[Minutia] = []
        for i, m in enumerate(ms):
            out.append(Minutia(x=float(warped[i, 0]), y=float(warped[i, 1]),
                               theta=(m.theta + rot[i]) % 360,
                               quality=m.quality, source=m.source))
        return out


def _kernel(r2: np.ndarray) -> np.ndarray:
    """TPS radial basis U(r) = r^2 log(r^2), computed from squared radius.

    Using r^2 directly avoids a sqrt and the log(0) branch is handled by
    masking rather than an epsilon fudge -- U(0) is exactly 0 by definition.
    """
    out = np.zeros_like(r2)
    nz = r2 > 1e-12
    out[nz] = r2[nz] * np.log(r2[nz])
    return out


def fit_tps(src: np.ndarray, dst: np.ndarray,
            regularization: float = 1.0) -> Optional[TpsWarp]:
    """Fit a TPS mapping `src` -> `dst`. Both (N,2). None if not fittable.

    `regularization` (lambda) relaxes exact interpolation: with lambda=0 the
    warp passes exactly through every control point, which on real minutiae
    correspondences means faithfully reproducing every correspondence error
    as a real deformation. Minutiae correspondences are NOT exact -- they are
    accepted within `dist_tol` (12px) -- so exact interpolation is the wrong
    objective here and a smoothing fit is the right one. Reported
    `mean_residual` is how far the fit ends up from the controls, which is
    the diagnostic for whether lambda is sane.
    """
    src = np.asarray(src, dtype=np.float64)
    dst = np.asarray(dst, dtype=np.float64)
    n = src.shape[0]
    if n < MIN_CONTROL_POINTS or dst.shape[0] != n:
        return None

    # K: pairwise radial-basis matrix over control points.
    diff = src[:, None, :] - src[None, :, :]
    r2 = (diff ** 2).sum(axis=2)
    K = _kernel(r2)
    if regularization > 0:
        # Smoothing term. Scaled by mean control spacing so lambda means the
        # same thing regardless of how large the print is in pixels.
        scale = float(np.sqrt(r2[r2 > 0].mean())) if (r2 > 0).any() else 1.0
        K = K + np.eye(n) * regularization * scale

    P = np.hstack([np.ones((n, 1)), src])           # (N,3) affine part
    L = np.zeros((n + 3, n + 3), dtype=np.float64)
    L[:n, :n] = K
    L[:n, n:] = P
    L[n:, :n] = P.T                                  # (3,N), bottom-right stays 0

    rhs = np.zeros((n + 3, 2), dtype=np.float64)
    rhs[:n, :] = dst

    try:
        # lstsq, not solve: a degenerate control configuration (e.g. all
        # points collinear) makes L singular, and a hard exception there
        # would kill a source that should simply fall back to rigid.
        sol, *_ = np.linalg.lstsq(L, rhs, rcond=None)
    except np.linalg.LinAlgError:
        return None
    if not np.all(np.isfinite(sol)):
        return None

    warp = TpsWarp(control_src=src, weights_x=sol[:, 0], weights_y=sol[:, 1],
                   n_control=n, max_displacement=0.0, mean_residual=0.0)

    # Real self-check before this fit is trusted anywhere: re-apply it to its
    # own control points (no extrapolation blending -- we are inside the hull
    # by construction) and measure how far it actually moved things and how
    # well it reproduced the targets.
    check = _apply_tps(warp, src, blend_to_identity=False)
    warp.mean_residual = float(np.linalg.norm(check - dst, axis=1).mean())
    warp.max_displacement = float(np.linalg.norm(dst - src, axis=1).max())
    return warp


def _apply_tps(w: TpsWarp, pts: np.ndarray,
               blend_to_identity: bool = True) -> np.ndarray:
    pts = np.asarray(pts, dtype=np.float64)
    if pts.size == 0:
        return pts.reshape(0, 2)
    diff = pts[:, None, :] - w.control_src[None, :, :]
    r2 = (diff ** 2).sum(axis=2)
    U = _kernel(r2)                                   # (M,N)
    A = np.hstack([np.ones((pts.shape[0], 1)), pts])  # (M,3)
    basis = np.hstack([U, A])                         # (M,N+3)
    out = np.stack([basis @ w.weights_x, basis @ w.weights_y], axis=1)
    if blend_to_identity:
        alpha = _extrapolation_weight(w, pts)[:, None]
        out = alpha * out + (1.0 - alpha) * pts
    return out


def _extrapolation_weight(w: TpsWarp, pts: np.ndarray) -> np.ndarray:
    """1.0 near the control points, decaying to 0.0 far outside them.

    THIS IS THE MOST IMPORTANT SAFEGUARD IN THIS MODULE, because of a real
    structural hazard specific to what fusion uses TPS for: the minutiae
    fusion actually ADDS are, by definition, the ones in territory the anchor
    does NOT cover -- i.e. outside the overlap region, which is exactly where
    all the control points live. So the points most at risk of wild TPS
    extrapolation are precisely the points this whole exercise exists to
    contribute. TPS grows like r^2 log r away from its controls, so
    unblended extrapolation there could be arbitrarily wrong.

    Fix: blend smoothly back toward identity (i.e. toward the already-applied
    rigid alignment, since TPS here is fitted to the rigid residual) as a
    query point moves away from the control set. Near the controls the
    elastic correction applies in full; far outside it degrades gracefully to
    exactly the Phase 1 behaviour rather than to nonsense.
    """
    d = np.sqrt(((pts[:, None, :] - w.control_src[None, :, :]) ** 2).sum(axis=2)).min(axis=1)
    # Falloff scaled to the control set's own spread, so this adapts to print
    # size instead of hardcoding a pixel distance.
    spread = float(np.std(w.control_src)) if w.n_control > 1 else 1.0
    tau = max(spread * 0.5, 1e-6)
    return np.clip(np.exp(-(d / tau) ** 2), 0.0, 1.0)


def _local_rotation_deg(w: TpsWarp, pts: np.ndarray,
                        blend_to_identity: bool = True, eps: float = 1.0) -> np.ndarray:
    """Local rotation (deg) the warp induces at each point, via finite-
    difference Jacobian. `eps` is in px -- 1px is well below the ridge period
    (~9px) so this samples genuinely local behaviour."""
    dx = _apply_tps(w, pts + np.array([eps, 0.0]), blend_to_identity) - \
         _apply_tps(w, pts - np.array([eps, 0.0]), blend_to_identity)
    dy = _apply_tps(w, pts + np.array([0.0, eps]), blend_to_identity) - \
         _apply_tps(w, pts - np.array([0.0, eps]), blend_to_identity)
    # Jacobian columns: d(out)/dx and d(out)/dy, each /(2*eps).
    j00, j10 = dx[:, 0] / (2 * eps), dx[:, 1] / (2 * eps)
    j01, j11 = dy[:, 0] / (2 * eps), dy[:, 1] / (2 * eps)
    # Rotation of the closest rigid approximation to J (2D polar decomposition).
    return np.degrees(np.arctan2(j10 - j01, j00 + j11))


def fit_from_correspondences(
    anchor: Sequence[Minutia],
    source_rigid: Sequence[Minutia],
    dist_tol: float = 12.0,
    angle_tol: float = 25.0,
    regularization: float = 1.0,
) -> Tuple[Optional[TpsWarp], int]:
    """Fit a TPS from the correspondences between the anchor and an
    ALREADY-RIGIDLY-ALIGNED source. Returns (warp or None, n_controls).

    Takes the rigidly-transformed source on purpose: TPS models the residual
    the rigid step could not, which keeps the elastic term small and
    well-conditioned. Identity transform passed to count_inliers because the
    input is already in anchor space.
    """
    identity = reg.Transform(dx=0.0, dy=0.0, theta_deg=0.0, scale=1.0)
    n, pairs = reg.count_inliers(anchor, source_rigid, identity, dist_tol, angle_tol)
    if n < MIN_CONTROL_POINTS:
        return None, n
    src = np.array([[source_rigid[j].x, source_rigid[j].y] for _, j in pairs])
    dst = np.array([[anchor[i].x, anchor[i].y] for i, _ in pairs])
    warp = fit_tps(src, dst, regularization=regularization)
    if warp is None:
        return None, n
    # Reject an implausible fit outright rather than let it corrupt the merge.
    if warp.max_displacement > MAX_PLAUSIBLE_DISPLACEMENT_PX:
        return None, n
    return warp, n


def warp_image(w: TpsWarp, img: np.ndarray, out_shape: Tuple[int, int],
               blend_to_identity: bool = True) -> np.ndarray:
    """Dense image warp under the same TPS, for Stage C compositing.

    Builds the INVERSE sampling grid the honest way for a scattered-data
    warp: `_apply_tps` maps source->anchor, but cv2.remap needs, for each
    ANCHOR pixel, where to sample in the source. Rather than invert the TPS
    analytically (it has no closed-form inverse), this fits a second TPS in
    the opposite direction from the same control pairs -- standard practice,
    and exact at the control points themselves.
    """
    import cv2
    inv = fit_tps(_apply_tps(w, w.control_src, blend_to_identity=False),
                  w.control_src, regularization=0.0)
    if inv is None:
        return np.full(out_shape, 255, dtype=img.dtype)
    h, w_out = out_shape
    yy, xx = np.mgrid[0:h, 0:w_out]
    grid = np.stack([xx.ravel(), yy.ravel()], axis=1).astype(np.float64)
    src_pts = _apply_tps(inv, grid, blend_to_identity=blend_to_identity)
    map_x = src_pts[:, 0].reshape(h, w_out).astype(np.float32)
    map_y = src_pts[:, 1].reshape(h, w_out).astype(np.float32)
    return cv2.remap(img, map_x, map_y, interpolation=cv2.INTER_LINEAR,
                     borderMode=cv2.BORDER_CONSTANT, borderValue=255)


def _selftest() -> None:
    """Numerical self-check. This project's own standing rule: verify a
    closed-form solve numerically before trusting it in a real pipeline (see
    the quadratic-detrend Cramer's-rule check in CLAUDE.md, round 7)."""
    rng = np.random.default_rng(0)

    # 1. Pure affine input must be reproduced essentially exactly -- an affine
    #    map is inside TPS's own model class, so any real error here is a bug
    #    in the solve, not a modelling limitation.
    src = rng.uniform(0, 400, size=(30, 2))
    th = math.radians(7.0)
    R = np.array([[math.cos(th), -math.sin(th)], [math.sin(th), math.cos(th)]])
    dst = src @ R.T * 1.02 + np.array([12.0, -5.0])
    w = fit_tps(src, dst, regularization=0.0)
    assert w is not None, 'affine fit failed'
    err = np.linalg.norm(w.apply_points(src, blend_to_identity=False) - dst, axis=1).max()
    assert err < 1e-6, f'affine reproduction error too high: {err}'
    print(f'  [1] affine reproduction: max err {err:.2e} px  OK')

    # 2. Known smooth non-rigid warp: recovered within sub-pixel accuracy at
    #    held-out points, not just at the controls it was fitted on.
    def bend(p):
        return np.stack([p[:, 0] + 6.0 * np.sin(p[:, 1] / 90.0),
                         p[:, 1] + 4.0 * np.cos(p[:, 0] / 110.0)], axis=1)
    ctrl = rng.uniform(50, 350, size=(40, 2))
    w2 = fit_tps(ctrl, bend(ctrl), regularization=0.0)
    assert w2 is not None
    held = rng.uniform(80, 320, size=(25, 2))     # inside the control hull
    err2 = np.linalg.norm(w2.apply_points(held, blend_to_identity=False) - bend(held), axis=1).mean()
    assert err2 < 1.0, f'held-out warp error too high: {err2}'
    print(f'  [2] non-rigid held-out recovery: mean err {err2:.3f} px  OK')

    # 3. The extrapolation safeguard actually engages: far outside the control
    #    set the result must collapse back to identity, not to a large
    #    TPS extrapolation.
    far = np.array([[5000.0, 5000.0]])
    blended = w2.apply_points(far, blend_to_identity=True)
    raw = w2.apply_points(far, blend_to_identity=False)
    assert np.linalg.norm(blended - far) < 1e-6, 'extrapolation guard did not engage'
    print(f'  [3] extrapolation guard: raw moved {np.linalg.norm(raw - far):.1f}px, '
          f'blended moved {np.linalg.norm(blended - far):.2e}px  OK')

    # 4. Angle update tracks a known rotation.
    w3 = fit_tps(src, dst, regularization=0.0)
    rot = _local_rotation_deg(w3, src[:5], blend_to_identity=False)
    assert np.allclose(rot, 7.0, atol=0.5), f'angle update wrong: {rot}'
    print(f'  [4] Jacobian angle update: {rot.mean():.2f} deg (expected 7.00)  OK')

    # 5. Degenerate input must self-skip, never raise.
    assert fit_tps(src[:3], dst[:3]) is None, 'too-few-controls not rejected'
    collinear = np.stack([np.arange(20.0), np.arange(20.0)], axis=1)
    out = fit_tps(collinear, collinear + 1.0, regularization=1.0)
    assert out is None or np.all(np.isfinite(out.weights_x)), 'collinear produced non-finite fit'
    print('  [5] degenerate inputs self-skip cleanly  OK')

    print('tps selftest: ALL PASS')


if __name__ == '__main__':
    _selftest()
