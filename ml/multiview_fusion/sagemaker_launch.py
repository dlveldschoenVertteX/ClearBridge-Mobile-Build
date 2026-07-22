"""Launch the Phase 2 pair-deformation training on SageMaker GPU.

Adapted from ml/deform_correct/sagemaker_launch.py (same budget guardrails,
same explicit-`--go` discipline), pointed at train_pair.py and the pulled
real-frame set uploaded to S3.

Why GPU is justified (see README.md Phase 2 + CLAUDE.md): the correlation
net (CorrPairDeformNet) provably CAN fit this task -- it overfits a fixed
8-sample batch cleanly (EPE 8.7 -> ~2) -- but a CPU-scale run (base 24,
crop 160, ~40 epochs) stays flat at the identity baseline on the full
distribution: a capacity/steps problem, not an architecture one. GPU
makes a properly-sized run (wider base, 256px crops, hundreds of epochs)
cheap: this net is tiny by GPU standards, so even the worst-case cap cost
is around a dollar on spot.

    AWS_PROFILE=clearbridge python3 sagemaker_launch.py \
        --frames-s3 s3://<bucket>/multiview-fusion/frames/ \
        [--go]

Dry run by default; `--go` required to spend, per standing discipline.
"""
from __future__ import annotations

import argparse
import sys

_ON_DEMAND_HOURLY = {
    'ml.g4dn.xlarge': 0.977,   # REAL af-south-1 price (verified 2026-07-17
                               # via the AWS Pricing API -- higher than
                               # us-east-1's 0.526; use the real region price
                               # for the estimate, not the cheapest region's)
    'ml.g5.xlarge': 1.4,
}
_SPOT_DISCOUNT = 0.35


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--role-arn',
                    default='arn:aws:iam::085068687041:role/ClearBridgeSageMakerRole',
                    help='existing ClearBridge SageMaker execution role')
    ap.add_argument('--bucket',
                    default='clearbridge-fingerprint-training-085068687041-af-south-1-an')
    ap.add_argument('--frames-s3', required=True,
                    help='s3:// prefix holding the pulled frames + manifest.json '
                         '(upload via: aws s3 sync <local_frames_dir> <this-prefix>)')
    ap.add_argument('--instance-type', default='ml.g4dn.xlarge',
                    choices=list(_ON_DEMAND_HOURLY))
    ap.add_argument('--max-runtime-hours', type=float, default=2.0)
    ap.add_argument('--no-spot', action='store_true')
    ap.add_argument('--model', default='corr', choices=['plain', 'corr'])
    ap.add_argument('--epochs', type=int, default=400)
    ap.add_argument('--batch', type=int, default=16)
    ap.add_argument('--crop', type=int, default=256)
    ap.add_argument('--base', type=int, default=32)
    ap.add_argument('--lr', type=float, default=2e-3)
    ap.add_argument('--job-name', default='multiview-pair-deform-v1')
    ap.add_argument('--go', action='store_true')
    args = ap.parse_args()

    max_run_sec = int(args.max_runtime_hours * 3600)
    on_demand = _ON_DEMAND_HOURLY[args.instance_type] * args.max_runtime_hours
    est = on_demand * (1.0 if args.no_spot else _SPOT_DISCOUNT)

    print('=== multiview-fusion pair-deform SageMaker job ===')
    print(f'  region/role:     af-south-1 / {args.role_arn.rsplit("/", 1)[-1]}')
    print(f'  instance:        {args.instance_type} (spot={not args.no_spot})')
    print(f'  max runtime:     {args.max_runtime_hours}h hard cap')
    print(f'  worst-case cost: ~${est:.2f} at the full cap '
          f'(~${on_demand:.2f} if forced on-demand)')
    print(f'  model/epochs/batch/crop/base: '
          f'{args.model}/{args.epochs}/{args.batch}/{args.crop}/{args.base}')
    print(f'  frames:          {args.frames_s3}')
    if est > 20.0:
        print('\nWARNING: worst-case exceeds the $20 AWS budget alert -- '
              'shrink --max-runtime-hours first.')
    if not args.go:
        print('\nDry run only (pass --go to submit).')
        return 0

    from sagemaker.pytorch import PyTorch
    ckpt = f's3://{args.bucket}/multiview-fusion/{args.job_name}/checkpoints'
    out = f's3://{args.bucket}/multiview-fusion/{args.job_name}/output'
    estimator = PyTorch(
        entry_point='train_pair.py',
        source_dir='.',
        role=args.role_arn,
        instance_type=args.instance_type,
        instance_count=1,
        framework_version='2.3',   # newest image the pinned sagemaker==2.232.1
                                   # SDK knows; our code is version-agnostic torch
        py_version='py311',
        hyperparameters={
            'frames-dir': '/opt/ml/input/data/frames',
            'out-dir': '/opt/ml/checkpoints',
            'model': args.model,
            'epochs': args.epochs,
            'batch': args.batch,
            'crop': args.crop,
            'base': args.base,
            'lr': args.lr,
        },
        max_run=max_run_sec,
        use_spot_instances=not args.no_spot,
        max_wait=max_run_sec + 1800 if not args.no_spot else None,
        checkpoint_s3_uri=ckpt,
        checkpoint_local_path='/opt/ml/checkpoints',
        output_path=out,
        base_job_name=args.job_name,
    )
    # wait=False: submit and return -- job progress is polled separately via
    # describe_training_job rather than blocking this process on a log stream.
    estimator.fit({'frames': args.frames_s3}, job_name=args.job_name, wait=False)
    print(f'\nSubmitted {args.job_name}\nCheckpoints: {ckpt}\nOutput: {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
