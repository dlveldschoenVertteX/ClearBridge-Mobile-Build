# pyfing enhancement sidecar -- see app.py's module docstring for the full
# reasoning (why a separate service, why pyfing was trusted, what the first
# real test found). Pure-Python service (pyfing/keras/tensorflow-cpu are all
# pip-installable, unlike NBIS's source-built mindtct/bozorth3), so this
# Dockerfile is much simpler than nfiq2_service/Dockerfile -- no apt build
# toolchain, no vendored source.
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# Sanity-check at build time: fail the build loudly here rather than
# discovering at first request that pyfing/keras/tensorflow don't actually
# import cleanly in this base image (same pattern as nfiq2_service's own
# build-time checks).
RUN python -c "import pyfing; import keras; print('pyfing', pyfing.__file__)"

# Cloud Run injects $PORT; gunicorn binds to it. Single worker (Keras models
# are memory-heavy; concurrent requests share one loaded model per worker,
# matching nfiq2_service's own single-purpose-sidecar sizing), long timeout
# since pyfing's Keras-based enhancement is much slower than mindtct/
# bozorth3's C binaries (~15-20s observed for a single frame in testing).
ENV PORT=8080
CMD exec gunicorn --bind :$PORT --workers 1 --threads 2 --timeout 60 app:app
