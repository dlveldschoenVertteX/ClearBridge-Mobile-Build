# MAC3D learned ridge-restoration — data-collection spec

The single highest-leverage NFIQ gain left is replacing the hand-tuned Gabor
enhancement with a **learned restoration model** that maps a soft phone-macro
capture of a thumb pad to a clean, scanner-quality ridge image. Classical
enhancement took the pipeline from NFIQ ~36 to ~58; a learned model trained on
real paired data is the realistic path past that, because it can learn the
soft→clean mapping the Gabor bank only approximates.

A restoration model is **supervised** — it needs, for each capture, a
higher-quality *target* of the *same* finger to learn toward. Collecting that
target is the whole game. Without paired targets you can only train
self-supervised denoisers (marginal) — with them you can train a true
restoration net.

## What every beta capture must record

| # | Item | Why | Already captured? |
|---|------|-----|-------------------|
| 1 | Raw multi-angle burst (all shots, both illuminations) | model input + multi-frame priors | ✅ (front burst preserved) |
| 2 | **Paired reference of the SAME thumb** | supervised target — see below | ❌ **this is the gap** |
| 3 | Finger id + hand + which digit | de-dupe, subject-disjoint train/val split | partial (userId only) |
| 4 | Skin condition tag: dry / normal / moist | ridge contrast varies hugely with this | ❌ |
| 5 | Lighting tag: sunlight / bright indoor / dim + torch | domain balance | derivable from `flashOn` + luma |
| 6 | Device model | cross-device generalisation | ❌ (add to capture doc) |

### The reference target (item 2) — options, best first

1. **Optical/capacitive fingerprint scanner** of the same thumb (e.g. a cheap
   500 DPI USB scanner, or a livescan booth). This is the gold target — a real
   500 DPI print the model learns to reproduce. ~$40 hardware. **Strongly
   preferred.**
2. **Ink-and-roll card** scanned at ≥500 DPI. Same target quality, more manual.
3. **Self-target (bootstrap, no hardware):** the capture's own best-enhanced
   output, but *only* those a human grader marks "clean" (a QC pass). Weaker —
   the model can't exceed the enhancer it's learning from — but it lets you
   start today and it teaches robustness (many soft inputs → the one clean
   output for that finger). Use this to bootstrap, then upgrade to (1)/(2).

### Volume / balance targets

- **≥ 40 distinct fingers** to start (200+ ideal). Restoration generalises
  better than segmentation, but subject diversity still gates it.
- Per finger: **3–5 captures** across different lighting/skin states.
- Keep **train/val splits subject-disjoint** (never the same finger in both) —
  otherwise val NFIQ is inflated by memorised ridges.

## Storage layout the training code expects

```
gs://clearbridge-dc699/mac3d_dataset/
  <finger_id>/
    <capture_id>/
      input/            # raw near-face-on burst shots (grayscale PNG/JPG)
        shot_000.png ...
      target.png        # the paired reference, registered to the pad, 500 DPI-ish
      meta.json         # { finger_id, digit, hand, skin, lighting, device }
```

`dataset.py` reads exactly this layout. `meta.json` drives the subject-disjoint
split and lets you weight/balance domains. See `README.md` for the train →
ONNX → backend-variant path.
