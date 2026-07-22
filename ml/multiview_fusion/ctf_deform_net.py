"""CoarseToFinePairNet -- pyramid (coarse-to-fine) flow net, the fix for the
mean-collapse failure diagnosed on the single-level CorrPairDeformNet
(multiview-pair-deform-v3, 2026-07-22).

Diagnosis this addresses (measured, not guessed):
- The trained v3 checkpoint predicts ~zero flow everywhere (mean |pred|
  0.034px vs mean |gt| 6.7px, cosine(pred, gt) = -0.05) -- textbook
  mean-collapse: when a regressor can't extract the answer from its inputs,
  the EPE-optimal output is the marginal mean of the target distribution,
  which for zero-centered random flows is identity. Val EPE pinned at
  EXACTLY the identity baseline all run (4.400-4.435 vs 4.400).
- Root cause: ridge-period ambiguity. Fingerprint texture is periodic
  (9-20px native wavelength); the synthetic flow family reaches well past
  half a period, so at the single 1/4-res correlation level the cost volume
  has one near-equal peak per ridge cycle inside the search window -- the
  same aliasing that broke NCC block-matching classically (README.md,
  Phase 0), now reproduced inside the learned correlation. Multimodal
  ambiguity + EPE loss => collapse to the prior mean.
- The fingerprint dense-registration literature says the same thing from
  the other direction: the field's methods treat the print as a 2-D cosine
  wave and register via PHASE (Cui & Feng, TIFS 2018 "2-D Phase
  Demodulation for Deformable Fingerprint Registration"; PDRNet, T-IFS
  2024 uses phase features as the correlation information), and dense
  refinement always runs AFTER a coarse alignment leaves sub-period
  residuals.

The fix, translated to this project's constraints: a 3-level coarse-to-fine
pyramid (PWC-Net principle, minimal version).
- At 1/16 resolution the ridge texture (9-20px period => 0.6-1.25px at that
  scale) is below Nyquist for the strided encoder -- effectively
  NON-periodic blur/structure -- so a small correlation window there is
  unambiguous while reaching +/-4px*16 = +/-64px of full-res displacement.
- Each finer level warps the side features by the upsampled coarse estimate
  first, so it only ever refines a residual well below half a period at its
  own scale -- the regime where correlation genuinely works.
- Supervision at every level (standard multi-scale EPE), flows in PIXELS at
  full resolution throughout (same scale-trap-avoidance contract as
  deform_net.py / corr_deform_net.py).

Not wired into production. Research-only, per ml/multiview_fusion/README.md.
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F

from corr_deform_net import local_correlation


def _conv(cin, cout, k=3, s=1):
    return nn.Sequential(
        nn.Conv2d(cin, cout, k, stride=s, padding=k // 2, bias=False),
        nn.BatchNorm2d(cout),
        nn.LeakyReLU(0.1, inplace=True),
    )


def _warp_features(feat: torch.Tensor, flow_px_at_scale: torch.Tensor) -> torch.Tensor:
    """grid_sample warp of a feature map by a PIXEL flow expressed at the
    feature map's own scale."""
    b, _, h, w = feat.shape
    device = feat.device
    ys, xs = torch.meshgrid(
        torch.linspace(-1, 1, h, device=device),
        torch.linspace(-1, 1, w, device=device),
        indexing='ij')
    base = torch.stack([xs, ys], dim=-1).unsqueeze(0).expand(b, -1, -1, -1)
    fx = flow_px_at_scale[:, 0] * (2.0 / max(w - 1, 1))
    fy = flow_px_at_scale[:, 1] * (2.0 / max(h - 1, 1))
    grid = base + torch.stack([fx, fy], dim=-1)
    return F.grid_sample(feat, grid, mode='bilinear',
                         padding_mode='border', align_corners=True)


class _Level(nn.Module):
    """One pyramid level: correlate (front vs pre-warped side features),
    decode, predict a RESIDUAL flow in px at this level's scale."""

    def __init__(self, feat_ch: int, max_disp: int, max_resid_px: float):
        super().__init__()
        self.max_disp = max_disp
        self.max_resid_px = max_resid_px
        corr_ch = (2 * max_disp + 1) ** 2
        # +2 for the upsampled incoming flow (a standard PWC input: lets the
        # decoder condition its residual on what's already been explained).
        self.dec = nn.Sequential(
            _conv(corr_ch + feat_ch + 2, feat_ch * 2),
            _conv(feat_ch * 2, feat_ch),
            _conv(feat_ch, feat_ch // 2),
        )
        self.head = nn.Conv2d(feat_ch // 2, 2, 1)
        nn.init.zeros_(self.head.weight)
        nn.init.zeros_(self.head.bias)

    def forward(self, fa, fb, flow_in_scale):
        fb_w = _warp_features(fb, flow_in_scale)
        corr = local_correlation(fa, fb_w, self.max_disp)
        x = torch.cat([corr, fa, flow_in_scale], dim=1)
        resid = torch.tanh(self.head(self.dec(x))) * self.max_resid_px
        return flow_in_scale + resid


class CoarseToFinePairNet(nn.Module):
    """(B,2,H,W) in (front, ECC-registered side, [0,1]) -> list of flows,
    finest last, each (B,2,h_l,w_l) in FULL-RESOLUTION pixel units (the
    spatial grid varies per level but the displacement unit never does --
    a vector of 5 always means 5 full-res px). forward() returns all levels
    for multi-scale supervision; use `predict()` for the final full-res flow.
    """

    #             stride  max_disp(win)  max residual (FULL-RES px)
    _LEVELS = [(16, 4, 64.0),   # coarse: unambiguous blurred structure
               (8, 3, 12.0),    # refine: residual well below half-period
               (4, 2, 5.0)]     # fine: sub-period polish

    def __init__(self, base: int = 24):
        super().__init__()
        self.enc4 = nn.Sequential(
            _conv(1, base, s=1),
            _conv(base, base, s=2),          # 1/2
            _conv(base, base * 2, s=2),      # 1/4
        )
        self.enc8 = _conv(base * 2, base * 2, s=2)    # 1/8
        self.enc16 = _conv(base * 2, base * 2, s=2)   # 1/16
        ch = base * 2
        # _Level's tanh cap applies in ITS OWN scale's px (it runs inside
        # _refine's /stride ... *stride sandwich), so convert the full-res
        # caps here: e.g. 64 full-res px at stride 16 = 4px on that grid.
        self.level16 = _Level(ch, self._LEVELS[0][1], self._LEVELS[0][2] / 16)
        self.level8 = _Level(ch, self._LEVELS[1][1], self._LEVELS[1][2] / 8)
        self.level4 = _Level(ch, self._LEVELS[2][1], self._LEVELS[2][2] / 4)

    def _pyramid(self, x):
        f4 = self.enc4(x)
        f8 = self.enc8(f4)
        f16 = self.enc16(f8)
        return f4, f8, f16

    def forward(self, x: torch.Tensor) -> list[torch.Tensor]:
        front, side = x[:, 0:1], x[:, 1:2]
        fa4, fa8, fa16 = self._pyramid(front)
        fb4, fb8, fb16 = self._pyramid(side)

        # NOTE on units: flows are carried in FULL-RES px everywhere outside
        # _refine. _warp_features needs the displacement in px *at the
        # feature map's scale*, so _refine divides by the level's stride on
        # the way in and multiplies back on the way out (a 16px full-res
        # shift moves content 1px on the 1/16 grid).
        b, _, h16, w16 = fa16.shape
        zero16 = torch.zeros(b, 2, h16, w16, device=x.device)
        flow16 = self._refine(self.level16, fa16, fb16, zero16, stride=16)

        up8 = F.interpolate(flow16, size=fa8.shape[2:], mode='bilinear',
                            align_corners=True)
        flow8 = self._refine(self.level8, fa8, fb8, up8, stride=8)

        up4 = F.interpolate(flow8, size=fa4.shape[2:], mode='bilinear',
                            align_corners=True)
        flow4 = self._refine(self.level4, fa4, fb4, up4, stride=4)

        return [flow16, flow8, flow4]

    @staticmethod
    def _refine(level: _Level, fa, fb, flow_fullres_px, stride: int):
        # Convert incoming full-res px flow to this scale's px for warping/
        # conditioning, run the level, convert its output back to full-res px.
        flow_scale = flow_fullres_px / stride
        out_scale = level(fa, fb, flow_scale)
        return out_scale * stride

    def predict(self, x: torch.Tensor) -> torch.Tensor:
        """Final full-res pixel flow, upsampled from the finest level."""
        flows = self.forward(x)
        return F.interpolate(flows[-1], size=x.shape[2:], mode='bilinear',
                             align_corners=True)


def multiscale_epe(flows: list[torch.Tensor], gt_fullres: torch.Tensor,
                   weights=(0.32, 0.16, 0.08)) -> torch.Tensor:
    """FlowNet/PWC-style multi-scale supervision: downsample the ground
    truth SPATIALLY to each level's grid (values stay in full-res px, so no
    magnitude rescale) and sum weighted EPEs, coarse levels weighted higher
    (they must be right for the finer ones to refine)."""
    loss = 0.0
    for flow, w in zip(flows, weights):
        gt_l = F.interpolate(gt_fullres, size=flow.shape[2:], mode='bilinear',
                             align_corners=True)
        loss = loss + w * torch.sqrt(((flow - gt_l) ** 2).sum(dim=1) + 1e-9).mean()
    return loss
