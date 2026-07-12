# MAC3D learned ridge restoration

Turnkey training scaffold for the learned enhancement model that replaces (as a
scored max-variant, never a hard swap) the hand-tuned Gabor stage in
`functions/processEnhanceAndScore/afis_print.py`.

**Why this is the lever:** classical enhancement plateaued at NFIQ ~58. NFIQ
downsamples every print to 500x500, so resolution/super-resolution can't help
(measured). The remaining gain is ridge *clarity* within that 500x500 — exactly
what a model trained on real clean targets learns to produce.

## Pipeline

1. **Collect** paired data per `DATA_SPEC.md` (the gap is the clean *target*
   per finger — a $40 USB 500 DPI scanner is the recommended source).
2. **Train** (needs a GPU — not available in the build container):
   ```bash
   pip install torch opencv-python numpy
   python train.py --data /path/to/mac3d_dataset --epochs 120 --out runs/v1
   ```
   Loss = L1 + (1−SSIM). Val metric = SSIM vs held-out clean targets on
   **subject-disjoint** fingers. Real gate = backend NFIQ (step 4).
3. **Export** to ONNX:
   ```bash
   python -c "from model import export_onnx; export_onnx('runs/v1/best.pt', 'ridge_restore_unet.onnx')"
   ```
   Contract: input `input` (1×1×H×W, float [0,1]), output `restored` (same).
4. **Integrate** exactly like the segmentation U-Net already is:
   - Upload `ridge_restore_unet.onnx` to Storage `models/`.
   - Add a loader mirroring `sfm_pipeline._get_thumb_seg_session()`.
   - In `afis_print.generate()`, add a `restore=True` branch that runs the net
     on the normalised pad crop and feeds its output into the existing
     binarise → mask → upright-rotate tail.
   - In `main.py`, add `('learned', dict(restore=True))` to `_afis_variants`.
     The **max-of-variants** design means the learned model can only ever raise
     the score — if it underperforms on a capture, the existing renderings win,
     so shipping it is zero-risk.

## Files
- `DATA_SPEC.md` — what the beta must collect (read this first).
- `model.py` — compact CPU-friendly restoration U-Net (~1.9M params) + ONNX export.
- `dataset.py` — reads the DATA_SPEC layout; subject-disjoint splits.
- `train.py` — L1+SSIM training loop, cosine schedule, best-checkpoint save.

## Notes
- Keep the net small — it runs CPU-only in the Cloud Function next to the
  segmentation U-Net and NFIQ ResNet. Base=32 is the ceiling for the latency
  budget; go bigger only if you move scoring to a GPU endpoint.
- Bootstrap option (no scanner yet): use QC-passed best-enhanced outputs as
  targets to start, then upgrade to real scans. See DATA_SPEC.md item 2.
