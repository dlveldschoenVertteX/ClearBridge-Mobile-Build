# Deformation-correction network (C2CL-style)

The learned piece `geom_correct.py`'s `elastic_flatten()` currently stubs as
an identity placeholder, waiting for exactly this. See
`docs/FIDELITY_WALL_SCOPE.md` for why this exists: three independent tools
(SourceAFIS, ORB+RANSAC, bozorth3) confirmed our contactless prints don't
AFIS-match, and the literature (C2CL, Grosz/Jain TIFS 2021) says the missing
piece is cross-domain geometry correction — perspective + elastic deformation
toward contact-print geometry — which this network learns from real paired
data (NIST SD 302) instead of the hand-tuned parametric approximation
`geom_correct.cylindrical_rectify()` already does.

## Design summary

- **Input at inference**: ONLY the contactless probe image (no paired contact
  scan exists live in production) — see `model.py`'s docstring for why this
  is a real constraint, not a simplification, and how it differs from a
  generic two-image registration setup (e.g. VoxelMorph's usual moving+fixed
  input).
- **Trained** with real (probe, gallery) pairs from SD 302 for supervision,
  but the gallery is used ONLY in the training loss, never fed to the network.
- **Loss**: primarily ridge-ORIENTATION similarity (a differentiable torch
  reimplementation of `afis_print._orientation_field`'s own math), not raw
  pixel similarity — orientation is a modality-invariant structural feature
  that survives the photograph-vs-scan domain gap; raw SSIM is kept as a
  small secondary term. Plus a flow-smoothness regularizer. See `train.py`'s
  docstring for the full reasoning.
- **The REAL validation gate** is NOT this training loss. It's the
  SourceAFIS-based genuine-vs-impostor ROC
  (`ml/fidelity_benchmark/benchmark.py`), run offline after export — same
  standing discipline as everywhere else in this project (docs/
  FIDELITY_WALL_SCOPE.md: "select on cross-domain match score, never NFIQ2").

## Status (2026-07-17)

Built and smoke-tested end-to-end on synthetic data in-sandbox (dataset
loading → model forward → differentiable warp → orientation/SSIM/smoothness
loss → backward → checkpoint save → ONNX export → ONNX Runtime inference all
verified working). **Not yet run against real data** — SD 302 hasn't landed
yet. The SD 302 `_sd302_record()` classifier in `ml/fidelity_benchmark/
ingest.py` is based on NIST's own documented part descriptions (confirmed via
the CTO's actual download email, not guessed), but the EXACT folder/filename
convention inside the real extracted archives has not been seen yet — run
`python3 ../fidelity_benchmark/ingest.py --root <sd302 root>` first and sanity
-check the printed subject/finger/pairable counts look sane before trusting
`build_manifest.py`'s output; a naming-convention mismatch would need a small
regex fix in `_sd302_record`, not a redesign.

## Pipeline, once SD 302 lands

```
# 1. Sanity-check the real folder layout parses sensibly
python3 ../fidelity_benchmark/ingest.py --root /path/to/sd302

# 2. Build the training manifest (only 302a/b/d vs 302f pairs; see
#    ingest.py's _SD302_CONTACT_PARTS/_SD302_CONTACTLESS_PARTS)
python3 build_manifest.py --root /path/to/sd302 --layout sd302 --out manifest.json

# 3a. Local/CPU smoke run (tiny, just to confirm real data loads correctly
#     before spending any SageMaker money)
python3 train.py --manifest manifest.json --data-root /path/to/sd302 \
    --epochs 2 --batch 4 --size 256 --out runs/smoke

# 3b. Real training on SageMaker (see "AWS setup" below first)
python3 sagemaker_launch.py --role-arn <arn> --bucket <bucket> \
    --manifest s3://<bucket>/manifests/sd302_v1.json \
    --images-prefix s3://<bucket>/sd302/ \
    --max-runtime-hours 4          # dry run by default; add --go to submit

# 4. Export + validate (only after training converges)
python3 -c "from model import export_onnx; export_onnx('runs/v1/best.pt', 'deform_v1.onnx')"
# then run ml/fidelity_benchmark/benchmark.py's ROC with geom_correct.py
# wired to load this ONNX model, comparing against the current
# cylindrical_rectify()-only baseline -- ONLY wire into afis_print.py's
# production variant list if it measurably improves the ROC.
```

## AWS setup (one-time, needs YOUR console access — not automated here)

This script deliberately does **not** create IAM roles, S3 buckets, or spend
any money on its own — see `sagemaker_launch.py`'s own docstring for the
budget guardrails (spot instances, hard runtime cap, `--go` required to
actually submit).

### Getting me credentials safely

1. **Create a scoped IAM user** (AWS Console → IAM → Users → Create user),
   NOT root account keys. Attach a policy limited to what this actually
   needs — SageMaker + a specific S3 bucket only, e.g.:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {"Effect": "Allow", "Action": "sagemaker:*", "Resource": "*"},
       {"Effect": "Allow", "Action": ["iam:PassRole"], "Resource": "arn:aws:iam::<account>:role/SageMakerExecutionRole"},
       {"Effect": "Allow", "Action": "s3:*", "Resource": [
         "arn:aws:s3:::<your-bucket>", "arn:aws:s3:::<your-bucket>/*"
       ]}
     ]
   }
   ```
   (SageMaker itself needs a separate **execution role** — a different,
   SageMaker-service-assumed IAM role, not your user — with
   `AmazonSageMakerFullAccess` + S3 access to the same bucket; create this
   once via SageMaker's own "create a new role" flow when you first open the
   SageMaker console, same as you likely already did for the NNS training.)
2. **Set a billing alarm.** AWS Console → Billing → Budgets → create a budget
   alert at, say, $10/$20/$35 — a real safety net independent of anything
   this script does, in case a job runs longer than expected outside my
   visibility.
3. **Generate an access key** for that IAM user (IAM → Users → your user →
   Security credentials → Create access key).
4. **Upload the key as a file**, the same way you shared the Firebase service
   account JSON earlier this session — don't paste the secret access key as
   plain chat text (it ends up in conversation history longer than
   necessary). A small `.csv` or `.json` with the access key ID + secret is
   fine.

Once I have it, I'll set it up as AWS credentials (same pattern as the
Firebase `GOOGLE_APPLICATION_CREDENTIALS` this session already uses) and can
run `build_manifest.py`/`sagemaker_launch.py` directly. **I will still always
show you the dry-run cost estimate and ask before passing `--go`** on an
actual paid job — same standing discipline this project already applies to
GCP deploys, just extended to real AWS spend.

### Uploading SD 302 to S3

The dataset needs to land in S3 for SageMaker to read it (this sandbox's own
disk allowance can't hold 66GB+ either). From wherever you download SD 302:
```
aws s3 sync /path/to/sd302 s3://<your-bucket>/sd302/
```
This can take a while for the ~66GB SD302f part; there's no rush since the
NIST download links are valid until August 1, 2026.
