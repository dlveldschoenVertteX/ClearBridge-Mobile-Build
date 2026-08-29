"""Launch thumb_seg U-Net training on real SageMaker GPU.

Reuses this project's own established real infra (account 085068687041,
role ClearBridgeSageMakerRole, bucket
clearbridge-fingerprint-training-085068687041-af-south-1-an, region
af-south-1, ml.g4dn.xlarge -- same pattern as ml/deform_correct's own
launcher). CPU training on this same dataset showed clean, real loss
descent (1.49->0.43 train / 1.40->0.39 val by epoch 10/80) but was
projected at ~5h wall-clock; GPU should finish the full 80 epochs in
minutes, at real on-demand cost of roughly $0.977/hr (af-south-1,
ml.g4dn.xlarge, per this project's own prior pricing check) -- a small
610-image/256px dataset, so total billable time is expected well under
30 minutes even with instance startup + data download overhead.
"""
import os
import sagemaker
from sagemaker.pytorch import PyTorch

REGION = 'af-south-1'
BUCKET = 'clearbridge-fingerprint-training-085068687041-af-south-1-an'
ROLE = 'arn:aws:iam::085068687041:role/ClearBridgeSageMakerRole'
PREFIX = 'thumb-seg-unet-seeded-2026-08-28'

HERE = os.path.dirname(os.path.abspath(__file__))

sess = sagemaker.Session(
    boto_session=__import__('boto3').Session(profile_name='clearbridge', region_name=REGION),
    default_bucket=BUCKET,
)

print('uploading dataset to S3 (this is the slow local step, ~3.3GB)...')
s3_data = sess.upload_data(
    path=os.path.join(HERE, 'dataset_seeded'),
    bucket=BUCKET,
    key_prefix=f'{PREFIX}/data',
)
print('uploaded to', s3_data)

estimator = PyTorch(
    entry_point='train.py',
    source_dir=HERE,
    role=ROLE,
    instance_type='ml.g4dn.xlarge',
    instance_count=1,
    framework_version='2.2',
    py_version='py310',
    hyperparameters={
        'data': '/opt/ml/input/data/training',
        'out': '/opt/ml/model',
        'epochs': 80,
        'batch': 8,
        'lr': 1e-3,
        'val-frac': 0.15,
    },
    sagemaker_session=sess,
    max_run=3600,  # hard 1h cap -- real expectation is well under this
    base_job_name='thumb-seg-unet-seeded',
)

print('submitting real SageMaker training job (real cost will be incurred)...')
estimator.fit({'training': s3_data})
print('done. model artifact:', estimator.model_data)
