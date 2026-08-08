"""Launch the curriculum-degradation ridge restoration training job on
SageMaker. Same budget-guardrail discipline as every other ml/ launcher in
this project (spot by default, hard runtime cap, per-epoch checkpointing,
--go required to spend).

    python sagemaker_launch.py \
        --images-prefix s3://<bucket>/ridge-restore-curriculum/sd302d/ \
        --go
"""
from __future__ import annotations

import argparse
import sys

_ON_DEMAND_HOURLY = {'ml.g4dn.xlarge': 0.977}
_SPOT_DISCOUNT = 0.35


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--role-arn', default='arn:aws:iam::085068687041:role/ClearBridgeSageMakerRole')
    ap.add_argument('--bucket', default='clearbridge-fingerprint-training-085068687041-af-south-1-an')
    ap.add_argument('--images-prefix', required=True)
    ap.add_argument('--instance-type', default='ml.g4dn.xlarge')
    ap.add_argument('--max-runtime-hours', type=float, default=1.5)
    ap.add_argument('--no-spot', action='store_true')
    ap.add_argument('--epochs', type=int, default=150)
    ap.add_argument('--batch', type=int, default=16)
    ap.add_argument('--curriculum-epochs', type=int, default=60)
    ap.add_argument('--job-name', default='ridge-restore-curriculum-v1')
    ap.add_argument('--go', action='store_true')
    args = ap.parse_args()

    max_run_sec = int(args.max_runtime_hours * 3600)
    on_demand_cost = _ON_DEMAND_HOURLY[args.instance_type] * args.max_runtime_hours
    est_cost = on_demand_cost * (1.0 if args.no_spot else _SPOT_DISCOUNT)

    print('=== ridge_restore_curriculum SageMaker training job ===')
    print(f'  instance:        {args.instance_type}')
    print(f'  spot:            {not args.no_spot}')
    print(f'  max runtime:     {args.max_runtime_hours}h (hard cap)')
    print(f'  worst-case cost: ~${est_cost:.2f}')
    print(f'  images:          {args.images_prefix}')
    print(f'  epochs/batch/curriculum: {args.epochs}/{args.batch}/{args.curriculum_epochs}')

    if not args.go:
        print('\nDry run only (pass --go to actually submit).')
        return 0

    from sagemaker.pytorch import PyTorch

    checkpoint_s3_uri = f's3://{args.bucket}/ridge-restore-curriculum/{args.job_name}/checkpoints'
    output_path = f's3://{args.bucket}/ridge-restore-curriculum/{args.job_name}/output'

    estimator = PyTorch(
        entry_point='train.py',
        source_dir='.',
        role=args.role_arn,
        instance_type=args.instance_type,
        instance_count=1,
        framework_version='2.3',
        py_version='py311',
        hyperparameters={
            'data-root': '/opt/ml/input/data/images',
            'epochs': args.epochs,
            'batch': args.batch,
            'curriculum-epochs': args.curriculum_epochs,
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
    return 0


if __name__ == '__main__':
    sys.exit(main())
