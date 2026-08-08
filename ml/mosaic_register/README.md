# mosaic_register

Two-crop rigid-registration network for stitching slightly-tilted views of
the same fingerprint pad into one superprint (CTO idea, 2026-08-08:
binarize each angled print, then register by finding where ridge PATTERNS
link up, using the front capture as ground truth).

Trained entirely on **synthetic transforms of real content** — never on
real angled-pair ground truth directly. `ml/deform_correct`'s own history
already ran the real-pair version of this experiment (SD302f contactless-
vs-contact pairs) and got a "definitive negative": a shared network
overfits small fixed batches but the full real-pair training set flatlines,
because every real pair's actual distortion is uncontrolled and
inconsistent. The synthetic-distortion line in that same project, by
contrast, trained cleanly. This module follows that proven recipe, applied
to a rigid-registration objective instead of single-image dewarping.

## Files

- `model.py` — `TwoCropRegistrationNet` (2-channel conv encoder -> global
  pool -> MLP head predicting (cos, sin, tx, ty)), `build_theta`/
  `warp_with_params`/`invert_params` (the rigid-transform math, verified via
  a numerical round-trip self-test).
- `synth_pair.py` — builds (reference, side, target_params) training
  triples from one real print, via a KNOWN synthetic rigid+mild-perspective
  transform. Run directly (`python synth_pair.py`) to re-run its own
  round-trip self-test against `data/real_prints/*.png`.
- `orient_loss.py` — differentiable ridge-orientation-field similarity loss.
  Copied from `ml/deform_correct/train.py`'s own implementation (NOT
  imported — both projects have same-named `dataset.py`/`model.py`/
  `train.py` files, and importing across them causes a real, confirmed
  `sys.modules` cache collision). Fixed a real latent gradient-NaN bug in
  this copy (see the comment in `orientation_field`) that `deform_correct`'s
  own continuous-tone training data apparently never triggers, but this
  module's *binarized* training data does.
- `dataset.py` — `MosaicPairDataset`, subject-disjoint (by source print)
  train/val split.
- `train.py` — training loop. Primary loss is direct supervised regression
  against the known synthetic transform; a smaller-weight orientation-field
  term is an auxiliary regularizer/proxy for "would this actually help
  compositing."
- `build_manifest.py` / `sagemaker_launch.py` — same dry-run-by-default,
  `--go`-required-to-spend discipline as `ml/deform_correct`'s own launcher.

## Data

`data/real_prints/` (gitignored — real user capture-derived images, this
repo is public) holds real binarized `superprintPath` images pulled
directly from Firestore/Storage for every scored `front_only_v1` capture
(60 as of 2026-08-08). Re-pull as the library grows:

```python
# see this session's own pull script for the exact pattern: query
# captures where status=='scored' and captureMode=='front_only_v1',
# download each doc's superprintPath blob.
```

## Status (2026-08-08)

Local CPU smoke test runs clean end-to-end (no NaN, no crashes) after
fixing the two real bugs above. A longer local sanity run (40 epochs, CPU)
is the next real gate before considering any SageMaker spend — this
project's own `deform_correct` precedent took ~100 epochs to show real
val-loss descent on a much larger (930-3810 image) dataset, so a flat trend
in the first 10-15 epochs here isn't yet conclusive either way.

**The real validation gate, once a checkpoint exists**, is NOT this
script's own training/val loss — it's real NFIQ2 on the resulting
composite across a real, non-trivial set of archived captures, matching
this session's own hand-rolled prototype (`scratchpad/
ridge_link_mosaic_test*.py`, see CLAUDE.md's 2026-08-08 "mosaic ridge-
orientation registration" section) and every other ML effort in this
project's history.
