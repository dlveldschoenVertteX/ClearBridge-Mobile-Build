"""Launch the two-crop registration training job on SageMaker.

    python sagemaker_launch.py \
        --role-arn arn:aws:iam::<account>:role/ClearBridgeSageMakerRole \
        --bucket clearbridge-fingerprint-training-<account>-af-south-1-an \
        --images-prefix s3://<bucket>/mosaic-register/real_prints/ \
        --go

Same budget-guardrail discipline as ml/deform_correct/sagemaker_launch.py
(reused directly, not redesigned): managed spot by default, a hard
--max-runtime-hours wall-clock cap, per-epoch checkpointing to S3,
--go required to actually spend (default is a dry-run cost estimate only).

Only ONE data channel here ('images'), unlike deform_correct's separate
manifest+images channels -- this module's dataset.py globs the images
directory directly (make_splits(data_root)), so there's no separate
manifest file the training job needs mounted; build_manifest.py's output is
for human/tracking reference only, not consumed by train.py.
"""
from __future__ import annotations

import argparse
import sys

_ON_DEMAND_HOURLY = {
    'ml.g4dn.xlarge': 0.977,   # real af-south-1 on-demand price, confirmed
    'ml.g5.xlarge': 1.86,      # rough multiplier off g4dn, not independently confirmed for af-south-1
}
_SPOT_DISCOUNT = 0.35


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--role-arn', default='arn:aws:iam::085068687041:role/ClearBridgeSageMakerRole')
    ap.add_argument('--bucket', default='clearbridge-fingerprint-training-085068687041-af-south-1-an')
    ap.add_argument('--images-prefix', required=True,
                    help='s3:// PREFIX holding the uploaded real_prints/*.png tree')
    ap.add_argument('--region', default='af-south-1')
    ap.add_argument('--instance-type', default='ml.g4dn.xlarge',
                    choices=list(_ON_DEMAND_HOURLY))
    ap.add_argument('--max-runtime-hours', type=float, default=1.5,
                    help='this task (60 real source prints, small model, '
                         'CPU epochs ran ~17s each) needs far less than '
                         'deform_correct\'s own default 4h cap -- kept '
                         'tight on purpose so a bug that never converges '
                         'burns minimal budget, not hours, before '
                         'CloudWatch/S3 checkpoints show something is wrong')
    ap.add_argument('--no-spot', action='store_true')
    ap.add_argument('--epochs', type=int, default=150)
    ap.add_argument('--batch', type=int, default=16)
    ap.add_argument('--job-name', default='mosaic-register-v1')
    ap.add_argument('--go', action='store_true')
    args = ap.parse_args()

    max_run_sec = int(args.max_runtime_hours * 3600)
    on_demand_cost = _ON_DEMAND_HOURLY[args.instance_type] * args.max_runtime_hours
    est_cost = on_demand_cost * (1.0 if args.no_spot else _SPOT_DISCOUNT)

    print('=== mosaic_register SageMaker training job ===')
    print(f'  instance:        {args.instance_type}')
    print(f'  region:          {args.region}')
    print(f'  spot:            {not args.no_spot}')
    print(f'  max runtime:     {args.max_runtime_hours}h (hard cap)')
    print(f'  worst-case cost: ~${est_cost:.2f} (full cap; a healthy run '
          f'should finish in well under 10 minutes given local CPU epochs '
          f'ran ~17s each on the same 60-print dataset)')
    print(f'  images:          {args.images_prefix}')
    print(f'  bucket:          {args.bucket}')
    print(f'  epochs/batch:    {args.epochs}/{args.batch}')

    if not args.go:
        print('\nDry run only (pass --go to actually submit). Review the '
              'numbers above first.')
        return 0

    try:
        from sagemaker.pytorch import PyTorch
    except ImportError:
        print('\nERROR: sagemaker SDK not installed. Run:\n'
              '  pip install sagemaker\nthen re-run with --go.', file=sys.stderr)
        return 1

    checkpoint_s3_uri = f's3://{args.bucket}/mosaic-register/{args.job_name}/checkpoints'
    output_path = f's3://{args.bucket}/mosaic-register/{args.job_name}/output'

    estimator = PyTorch(
        entry_point='train.py',
        source_dir='.',
        role=args.role_arn,
        instance_type=args.instance_type,
        instance_count=1,
        framework_version='2.3',   # matches deform_correct's own pinned choice
        py_version='py311',        # (2.4 has no resolvable DLC image URI on
        hyperparameters={          #  the sagemaker SDK version already proven
            'data-root': '/opt/ml/input/data/images',   #  working in this project)
            'epochs': args.epochs,
            'batch': args.batch,
            'out': '/opt/ml/checkpoints',
        },
        max_run=max_run_sec,
        use_spot_instances=not args.no_spot,
        max_wait=max_run_sec + 1800 if not args.no_spot else None,
        checkpoint_s3_uri=checkpoint_s3_uri,
        checkpoint_local_path='/opt/ml/checkpoints',
        output_path=output_path,
        base_job_name=args.job_name,
    )

    estimator.fit({'images': args.images_prefix}, job_name=args.job_name)
    print(f'\nSubmitted job: {args.job_name}')
    print(f'Checkpoints: {checkpoint_s3_uri}')
    print(f'Output:      {output_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
