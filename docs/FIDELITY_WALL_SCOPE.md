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

## Path forward (prioritized; what's doable solo vs what needs the CTO)

### A. Get a real fidelity benchmark (highest priority — unblocks everything)
1. **CTO action — better reference scan.** A proper ≥500-DPI reference of a
   few of the CTO's own fingers (a cheap optical USB fingerprint scanner, or
   a well-inked card scanned at 1000 DPI flatbed), 2–3 impressions each. This
   turns fidelity from "noise floor" into a real genuine/impostor benchmark
   the SourceAFIS harness (already built, `scratchpad/sourceafis/`) can score.
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

### B. Build the missing geometry-correction stage (solo, high value)
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

## Standing discipline for this axis
- **Select/optimize on cross-domain MATCH score, never NFIQ2**, for anything
  targeting fidelity. NFIQ2 stays as the quality floor only.
- SourceAFIS harness (`scratchpad/sourceafis/`, Java+Maven, built and
  working locally) is the current best fidelity gate — reuse it, not
  bozorth3, for every fidelity measurement from here.
- Every geometry-correction addition follows the same max-of-variants,
  never-regress pattern as every enhancement variant.
