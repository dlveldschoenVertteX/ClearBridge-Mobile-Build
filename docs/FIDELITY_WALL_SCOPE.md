# Scope: the fidelity wall — why NFIQ2 is high but matching fails (2026-07-16)

## Prime directive (CTO, this session)

> NFIQ score is high (~70% NFIQ2 consistently, even without the MAC3D
> dataset). But ridge continuity is the problem. Without the fingerprint
> matching each other there is no real point in having a high NFIQ2 signal.
> Optimize matchability by any means; exhaust everything doable solo before
> Beta. Prime directive: NFIQ **and** perfect fingerprint matching — ridge
> pattern continuity so AFIS can seamlessly match a print in their database
> to a MAC3D capture.

## What was measured this session (the honest wall)

Three **independent** matchers now agree the current pipeline output does
not structurally match — not against the ink scan, and not even against
another capture of the same finger:

| Tool | What it is | Genuine vs impostor separation on our 14 captures |
|---|---|---|
| **bozorth3** (NBIS) | classic minutiae matcher | 4–7 both = noise floor (established earlier) |
| **SourceAFIS 3.18** (newly stood up locally, Java) | modern minutiae matcher, calibrated: ~40 = FMR 0.01% | genuine cross-capture mean **2.8**, impostor mean **1.2**; **0 of 10** genuine pairs beat the impostor max. vs-ink genuine mean 6.2, impostor 1.9 — both far below any real-match threshold |
| **ORB + RANSAC homography** (matcher-independent geometry) | raw image feature correspondence | `3e54236a` vs `c34911b5` (SAME finger, BOTH NFIQ2 **72**): 531 mutual ORB matches but **0** good (<dist 40), **0** homography inliers |

**Conclusion (firm, not from theory — three tools, one answer):** the high
NFIQ2 score is measuring ridge-*like texture quality*, not fingerprint
*identity*. Two of our own best captures of the same finger, both scoring
NFIQ2 72, share no consistent minutiae or geometry. This is exactly the
"NFIQ2 is foolable" finding taken to its conclusion: the binarized AFIS
template contains a lot of Gabor-*synthesized* ridge structure that is
locally plausible but **not a repeatable transcription of the finger's true
minutiae**. That is why AFIS matching fails while NFIQ2 stays high.

### Render representation was tested and ruled out as the lever
Added a `render=` option to `afis_print.generate()` (binary / continuous /
raw) on the hypothesis that a matcher with its own enhancement (SourceAFIS)
might extract truer minutiae from continuous-tone or raw grayscale than from
the hard-binarized print. Measured across all 14 captures with SourceAFIS:
continuous and raw did **not** separate genuine from impostor either (0/10
both), and mindtct extracts far FEWER minutiae from raw/continuous (0–36)
than from binary (175–439). So the binary render is confirmed correct for
minutiae matching; the representation is not the bottleneck. **The
`render=` code was reverted** — production stays binary-only.

## Why (root-cause chain, aligned with published contactless→contact work)

Matching a finger-photo to a contact/ink print is a known-hard cross-domain
problem. The canonical reference is **C2CL** (Grosz, Engelsma, Jain, *IEEE
TIFS* 2021, "Contact to Contactless Fingerprint Matching"; app + preprocessing
code at github.com/ronny3050/FingerPhotos). Its measured, published gaps —
each of which our pipeline currently does **not** correct — are:

1. **Perspective distortion** of the contactless capture (a photo of a
   curved 3D finger from one viewpoint) vs the flattened contact print. C2CL
   trains a deep rectification network specifically for this.
2. **Elastic deformation**: contact printing squashes the elastic finger
   pad; contactless does not. C2CL fits a robust thin-plate-spline (RTPS)
   deformation-correction model. Our AFIS output is never warped toward the
   contact-print geometry at all.
3. **500-ppi ridge-frequency scaling** — we do part of this
   (`_ridge_wavelength`/`_TARGET_PERIOD`), which is likely *why* NFIQ2 is
   already decent; but scaling alone doesn't fix 1 or 2.
4. **Mask/coverage centering** — our own prior finding: the static
   `guideRegion` oval is sometimes mis-centered off the ridge-dense whorl
   core, so different captures frame different pad sub-regions — which alone
   can zero out cross-capture minutiae overlap regardless of enhancement.

The current pipeline is a strong *single-image enhancement + quality*
pipeline. It has **no cross-domain geometry-correction stage**, which is
precisely the part the literature says makes contactless prints AFIS-matchable.

## The measurement blocker (must fix first, or optimization is blind)

There is still **no reliable numeric fidelity target**:
- The single CTO ink scan is too low-quality ("best I could get" — blur, low
  contrast, 67 mindtct minutiae) to discriminate same- from different-finger,
  even with SourceAFIS.
- We have only ~4 captures of one known finger and no ground-truth contact
  reference for the others.

**You cannot optimize matchability against a target that can't tell a match
from a non-match.** Every fidelity number this project has produced (bozorth
4–7, SourceAFIS <15) is inside the noise floor of a weak reference.

## External impostor benchmark (2026-07-16) — SourceAFIS is a trustworthy gate; a FAINT genuine signal exists

Cloned the one reachable public contactless set from this sandbox —
`github.com/Chenhao03/DATASET` (public domain, 55 real contactless
fingerphotos, 320×240 `.pgm`, one per subject → every cross-pair is a
different finger = a true **impostor** population). All other real datasets
are behind license forms or egress-blocked hosts (see below). Ran the
production `afis_print.generate()` on them (unguided → U-Net mask path;
30/55 produced a usable mask, the rest are too full-frame for segmentation),
then SourceAFIS all-pairs:

- **External impostor pairs (different real fingers): mean 0.07, median 0,
  max 5.6, ZERO pairs ≥20.** SourceAFIS essentially never false-matches —
  it is a trustworthy gate, not a random scorer.
- **Our own genuine same-finger pairs: mean 5.6, max 14.2** — i.e. clearly
  above the external impostor floor (mean 0.07), but our genuine *mean* only
  reaches the external impostor *max*, and both are far below SourceAFIS's
  real-match threshold (~40).

**Refined conclusion:** there IS a faint real identity signal (genuine sits
above the impostor floor), so the pipeline is not pure noise — but it is
~an order of magnitude short of operational AFIS matching. This is precisely
the signal that cross-domain geometry correction (item B below) is meant to
amplify. NFIQ2 (already ~70) is blind to this gap; SourceAFIS separation is
the metric to move. Caveat: external prints used a different (U-Net) mask
path and are lower-res, so treat the absolute numbers as indicative, not a
controlled genuine-vs-impostor ROC — which still requires a proper paired
dataset (item A).

## Path forward (prioritized; what's doable solo vs what needs the CTO)

### A. Get a real fidelity benchmark (highest priority — unblocks everything)
1. **CTO action — better reference scan.** A proper ≥500-DPI reference of a
   few of the CTO's own fingers (a cheap optical USB fingerprint scanner, or
   a well-inked card scanned at 1000 DPI flatbed), 2–3 impressions each. This
   turns fidelity from "noise floor" into a real genuine/impostor benchmark
   the SourceAFIS harness (already built, `scratchpad/sourceafis/`) can score.
   **Reachability from this sandbox is the constraint.** Only `github.com`
   and language package registries are allowed by egress policy; HuggingFace,
   Kaggle, Zenodo, Google Drive, Buffalo, PolyU, NIST all return 403. The one
   GitHub-hosted public set found (`Chenhao03/DATASET`, used for the impostor
   benchmark above) is a 2019 partial upload — 55 low-res contactless images,
   one per subject, **no paired contact prints and no same-finger repeats**,
   so it can't produce genuine pairs. A complete paired dataset therefore has
   to be brought in by the CTO (downloaded in a normal browser, then dropped
   into the repo/session).
2. **Public paired dataset** (parallel, also CTO — most need a signed license
   form, and NIST hosts are egress-blocked from this sandbox):
   - **RidgeBase** (U. Buffalo CUBS) — 15k+ contactless/contact pairs, 88
     subjects; email license agreement.
   - **PolyU Contactless-to-Contact** — 2,016 pairs, 336 fingers.
   - **ISPFD** (IIT Jodhpur) — ~16.8k contactless / 2.4k contact.
   - **NIST SD 302 (N2N)** — public domain, but nigos.nist.gov is blocked
     here; the CTO can download and drop into the sandbox.
   With any of these, build a genuine/impostor benchmark of the FULL pipeline
   (the real numeric fidelity target the project lacks) and later fine-tune
   enhancement on real paired data.

### B. Build the missing geometry-correction stage (solo, high value) — SCAFFOLD BUILT 2026-07-16
Independent of new data, port the C2CL-style correction our pipeline lacks:
1. **Perspective/curvature rectification** of the pad before enhancement
   (the finger is a cylinder photographed off-axis; unwarp toward a frontal
   contact-equivalent). We already have `sfm_pipeline` cylindrical-unwrap
   machinery — repurpose it as a *mild* frontal rectification rather than a
   full unroll (the full unroll was already found to hurt).
2. **TPS/RTPS deformation model** as a post-enhancement warp toward
   contact-print geometry, gated as a new max-of-variants candidate so it can
   only help.
Validate both with the SourceAFIS harness on the same-finger captures — the
right success signal is **cross-capture genuine score rising above impostor**,
NOT NFIQ2 (which is already saturated and can't see this).

**Status — scaffold built (`functions/processEnhanceAndScore/geom_correct.py`,
wired into `afis_print.generate(geom=...)`, default OFF, self-skipping,
compile-clean):**
- `cylindrical_rectify()` — the deterministic single-image cylinder-curvature
  correction (item 1), fully implemented (arc-length column remap of the
  masked pad, `strength`-blended toward identity, mask warped in lockstep).
- `elastic_flatten()` — item 2's interface, present as a PARAMETRIC identity
  placeholder (`gain=0`) with the exact signature a trained RTPS will drop
  into. Not the real learned warp — that needs paired data.
- **Deliberately NOT yet wired into `main.py`'s `_afis_variants`.** Two
  reasons: (a) unvalidated on real paired data, and (b) production variant
  selection is by NFIQ2, which is blind to this axis, so it wouldn't be
  selected even if added — geom must be selected by a MATCHER, which needs
  the dataset. Kept as an offline-measurable scaffold until then.

**Preliminary measurement (our own 5-finger set, SourceAFIS, base vs `cyl`)
— directional only, NOT conclusive:** cyl raised genuine-pair mean 21.5→28.4
and, notably, **cut the worst impostor false-matches** (different fingers
scoring 101→58; the 87-scoring false pair dropped out of the top) — i.e. the
correction reduced spurious cross-identity minutiae alignment, the right
direction. BUT: genuine median fell (13.6→3.9), variance is huge, and several
scores are implausibly high (235 genuine, 101 impostor) — spurious minutiae
from small synthetic-ridge prints on a 5-finger sample. **This is exactly why
item A (a many-finger paired dataset) is the gate**: 5 fingers / 81 impostor
pairs with spurious matches cannot validate or tune this. The scaffold is
ready to be tuned (`_CYL_HALF_ANGLE_DEG`, `_CYL_STRENGTH`) and RTPS-fitted the
day real paired data lands.

### C. Fix capture-side centering (solo, cheap, already scoped)
Re-center the on-screen guide so the whorl core lands inside it
(`docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md`, and the content-aware
flash-diff/U-Net re-centering already built in `84ea9c6`). Two captures that
frame the *same* core is a precondition for any cross-capture match.

### D. Stronger deep representation matcher (solo, medium)
SourceAFIS is already a big step past bozorth3 as a fidelity *gate*. If a
public pretrained fixed-length extractor (DeepPrint-style, e.g.
`tim-rohwedder/fixed-length-fingerprint-extractors`, or FingerNet minutiae)
is license-clean and runnable locally, add it as a second independent
fidelity metric — a texture-based matcher can catch identity signal a
minutiae-only matcher misses on partial contactless prints.

## Solo work done 2026-07-17 (pre-dataset): scaffolds + honest negative results

Per the CTO's "improve everything you can before I upload the datasets / think
out the box," worked all four fronts and measured each against SourceAFIS
(matchability), not just NFIQ2:

### Backend enhancement — two fidelity-oriented variants built, both currently NEGATIVE on 5 fingers (kept as tunable scaffolds, NOT in production selection)
The key realized insight: the Gabor bank SYNTHESISES a ridge everywhere it
runs, inventing plausible-but-wrong ridges in low-signal regions. Those become
spurious minutiae that false-match different fingers and don't repeat across
genuine captures — aggressive synthesis buys NFIQ2, not matchability. Two
`afis_print.generate(enhance=...)` scaffolds attack this:
- `gaborVarFreq` — per-region local ridge-frequency Gabor (Hong/Wan/Jain)
  instead of one global wavelength (`_ridge_frequency_map`,
  `_gabor_enhance_varfreq`).
- `fidelity` — local-freq Gabor + a ridge-CONFIDENCE gate that blanks
  hallucinated ridges where orientation coherence × in-band energy is low
  (`_ridge_confidence`, `_apply_confidence_gate`).
Measured (SourceAFIS, our 5-finger set): **both cut impostor false-matches**
(the right direction — `gaborVarFreq` impostor p90 24→11, max 101→75) but also
**lost genuine signal** (`fidelity` genuine mean 21.5→5.7: the gate over-prunes
at its first-guess threshold). Neither beats the tuned baseline yet. They stay
opt-in, default-off, OUT of `main.py`'s variant list (NFIQ2 selection wouldn't
pick them anyway) — the machinery is correct and the direction is right; the
gate/level thresholds need the paired ROC to tune. Same "built, ready, not
validated" status as the geom scaffold. Confirms the wall: **fidelity-oriented
enhancement cannot be tuned on 5 noisy fingers without overfitting.**

### Fidelity benchmark harness — BUILT and self-tested (`ml/fidelity_benchmark/`)
The tooling to turn a real dataset into a verdict, ready before the data:
- `ingest.py` — indexes RidgeBase / NIST SD 302 / generic layouts into
  (subject, finger, modality) records and builds genuine/impostor cross-modality
  pairs. Self-tests pass with no data present.
- `benchmark.py` — verification metric core (EER, TAR@FAR, d′) plus the
  **matcher-based variant-selection** logic comparing three strategies:
  `nfiq2` (today's prod), `minutiae` (a deployable mindtct reliable-minutiae
  proxy), `oracle` (per-probe genuine-max upper bound). The oracle−nfiq2 gap
  will quantify exactly how much matchability today's NFIQ2 selection leaves on
  the table, and minutiae−nfiq2 how much a deployable proxy recovers. Metric +
  selection core unit-tested via `--selftest` (no data, no Java needed).

### Matcher-based selection — offline path built; production path identified, deliberately NOT switched blind
`benchmark.select_variant` does matcher-based selection offline today. For
PRODUCTION, the deployable signal is mindtct reliable-minutiae count (the
sidecar already runs mindtct) — but switching production selection off NFIQ2
is exactly the kind of change that must be validated on the ROC first, so it is
staged for the post-dataset step, not flipped on speculatively.

### Capture-side — assessed honestly; camera-plugin ceiling reached, real lever is gated on a device
The `camera` plugin's `takePicture()` is always platform JPEG with no
quality/format knob, so there is no safe blind capture-constant tweak that
provably raises raw print quality. The real remaining lever is RAW/DNG capture
(bypasses JPEG's 8px DCT grid that sits almost on the 9px ridge target) — a
native Camera2 lift gated on the Phase-0 `rawSensorSupport` capability check
already built, which needs a real device to report back. The single highest-
value capture-side change that IS grounded in this project's own data is
**re-centering the on-screen guide** so the whorl core lands inside it (the
documented mis-centering root cause) — but changing guide geometry needs device
iteration to avoid regressing well-placed captures, so it's a flagged
recommendation, not a blind constant change.

## Standing discipline for this axis
- **Select/optimize on cross-domain MATCH score, never NFIQ2**, for anything
  targeting fidelity. NFIQ2 stays as the quality floor only.
- SourceAFIS harness (`scratchpad/sourceafis/`, Java+Maven, built and
  working locally) is the current best fidelity gate — reuse it, not
  bozorth3, for every fidelity measurement from here.
- Every geometry-correction addition follows the same max-of-variants,
  never-regress pattern as every enhancement variant.
