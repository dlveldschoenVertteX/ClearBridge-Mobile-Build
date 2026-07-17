"""Launch a deformation-correction training job on SageMaker.

    python sagemaker_launch.py \
        --role-arn arn:aws:iam::<account>:role/SageMakerExecutionRole \
        --bucket clearbridge-deform-correct \
        --manifest s3://clearbridge-deform-correct/manifests/sd302_v1.json \
        --images-prefix s3://clearbridge-deform-correct/sd302/ \
        --go

Prerequisites (run wherever this actually executes -- NOT verified inside
this dev sandbox, which hit an unrelated pip/setuptools build failure
installing the `sagemaker` SDK's transitive deps; that's an environment
issue here, not a sign anything is wrong with the SDK itself):
    pip install sagemaker boto3
    aws configure   # or otherwise have credentials available to boto3

BUDGET GUARDRAILS (real money, ~$40 total account budget -- see below):
  - Managed SPOT training by default (use_spot_instances=True) -- typically
    60-70% cheaper than on-demand for this instance class.
  - --max-runtime-hours hard-caps the job (default 4h) via
    max_run/max_wait -- SageMaker kills the job at this wall-clock limit
    regardless of training progress, so a bug that never converges can't
    silently burn the whole budget unattended.
  - Checkpointing to S3 every epoch (train.py already saves last.pt/best.pt
    every epoch) via checkpoint_s3_uri -- if spot capacity is reclaimed and
    the job restarts, it doesn't lose already-completed epochs.
  - Defaults to ml.g4dn.xlarge (1x T4, ~$0.526/hr on-demand, roughly
    $0.16-0.20/hr on spot) -- the cheapest real GPU instance class, sized for
    this network (~1.9M-ish params, same class as ml/mac3d_enhance's model).
    At spot pricing this is ~150-200 hours of headroom inside $40, far more
    than this training run should need (expect low hours, not the full cap)
    -- ml.g5.xlarge is available via --instance-type if more headroom per
    hour is worth the ~2x spot price.
  - `--go` is REQUIRED to actually submit the job (default is a dry run that
    prints the exact job config and estimated max cost for review) -- mirrors
    this project's standing "explicit go-ahead before spending/deploying"
    discipline (see CLAUDE.md) applied to real AWS spend, not just GCP.

This script does NOT create the IAM role/S3 bucket/upload the dataset --
those are one-time setup steps (see README.md) that need your own AWS
console access, not something to automate blindly with credentials this
session may hold.
"""
from __future__ import annotations

import argparse
import sys

# Spot price is volatile and instance availability varies by AZ; these are
# rough on-demand reference prices (us-east-1, 2026) for the cost estimate
# printed below -- NOT used for billing, just a sanity check before --go.
_ON_DEMAND_HOURLY = {
    'ml.g4dn.xlarge': 0.526,
    'ml.g5.xlarge': 1.006,
    'ml.p3.2xlarge': 3.06,
}
_SPOT_DISCOUNT = 0.35   # rough rule of thumb: spot ~= 30-40% of on-demand


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--role-arn', required=True,
                    help='SageMaker execution role ARN (IAM role, not a user)')
    ap.add_argument('--bucket', required=True,
                    help='S3 bucket for code/checkpoints/output (must exist)')
    ap.add_argument('--manifest', required=True,
                    help='s3:// path to the manifest.json build_manifest.py produced')
    ap.add_argument('--images-prefix', required=True,
                    help='s3:// PREFIX holding the actual SD 302 image tree '
                         '(the same --root you passed to build_manifest.py, '
                         'uploaded to S3) -- manifest.json\'s probe/gallery '
                         'paths are RELATIVE and get resolved against this '
                         'at training time, not against the manifest\'s own '
                         'location')
    ap.add_argument('--instance-type', default='ml.g4dn.xlarge',
                    choices=list(_ON_DEMAND_HOURLY))
    ap.add_argument('--max-runtime-hours', type=float, default=4.0)
    ap.add_argument('--no-spot', action='store_true',
                    help='disable managed spot training (costs ~3x more)')
    ap.add_argument('--epochs', type=int, default=60)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--size', type=int, default=512)
    ap.add_argument('--job-name', default='deform-correct-v1')
    ap.add_argument('--go', action='store_true',
                    help='actually submit the job (default: dry run / print only)')
    args = ap.parse_args()

    max_run_sec = int(args.max_runtime_hours * 3600)
    on_demand_cost = _ON_DEMAND_HOURLY[args.instance_type] * args.max_runtime_hours
    est_cost = on_demand_cost * (1.0 if args.no_spot else _SPOT_DISCOUNT)

    print('=== deform-correct SageMaker training job ===')
    print(f'  instance:        {args.instance_type}')
    print(f'  spot:            {not args.no_spot}')
    print(f'  max runtime:     {args.max_runtime_hours}h (hard cap)')
    print(f'  worst-case cost: ~${est_cost:.2f} '
          f'(if it runs the FULL {args.max_runtime_hours}h cap; a converging '
          f'run should finish well before that)')
    print(f'  manifest:        {args.manifest}')
    print(f'  bucket:          {args.bucket}')
    print(f'  epochs/batch/size: {args.epochs}/{args.batch}/{args.size}')

    if est_cost > 40.0:
        print(f'\nWARNING: worst-case cost ${est_cost:.2f} exceeds the stated '
              f'$40 budget. Lower --max-runtime-hours or pick a cheaper '
              f'instance before proceeding.')

    if not args.go:
        print('\nDry run only (pass --go to actually submit). '
              'Review the numbers above first.')
        return 0

    try:
        from sagemaker.pytorch import PyTorch
    except ImportError:
        print('\nERROR: sagemaker SDK not installed here. Run:\n'
              '  pip install sagemaker boto3\n'
              'in the environment that actually has your AWS credentials, '
              'then re-run with --go.', file=sys.stderr)
        return 1

    checkpoint_s3_uri = f's3://{args.bucket}/deform-correct/{args.job_name}/checkpoints'
    output_path = f's3://{args.bucket}/deform-correct/{args.job_name}/output'

    estimator = PyTorch(
        entry_point='train.py',
        source_dir='.',                       # ships this whole directory
        role=args.role_arn,
        instance_type=args.instance_type,
        instance_count=1,
        framework_version='2.4',              # matches this repo's torch 2.4.x
        py_version='py311',
        hyperparameters={
            'manifest': '/opt/ml/input/data/manifest/manifest.json',
            'data-root': '/opt/ml/input/data/images',
            'epochs': args.epochs,
            'batch': args.batch,
            'size': args.size,
            'out': '/opt/ml/checkpoints',      # SageMaker syncs this to checkpoint_s3_uri
        },
        max_run=max_run_sec,
        use_spot_instances=not args.no_spot,
        max_wait=max_run_sec + 1800 if not args.no_spot else None,  # spot: allow 30min extra for capacity waits
        checkpoint_s3_uri=checkpoint_s3_uri,
        checkpoint_local_path='/opt/ml/checkpoints',
        output_path=output_path,
        base_job_name=args.job_name,
    )

    # TWO separate channels: 'manifest' (tiny -- just manifest.json) and
    # 'images' (the actual SD 302 tree, potentially tens of GB). Kept
    # separate rather than one big channel so SageMaker doesn't need to
    # re-download the whole image tree just because the manifest changed,
    # and so build_manifest.py's RELATIVE paths resolve correctly against
    # the 'images' channel's mount point (see dataset.py/train.py's
    # --data-root) regardless of where each was uploaded from.
    manifest_prefix = args.manifest.rsplit('/', 1)[0]
    estimator.fit(
        {'manifest': manifest_prefix, 'images': args.images_prefix},
        job_name=args.job_name,
    )
    print(f'\nSubmitted job: {args.job_name}')
    print(f'Checkpoints: {checkpoint_s3_uri}')
    print(f'Output:      {output_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
