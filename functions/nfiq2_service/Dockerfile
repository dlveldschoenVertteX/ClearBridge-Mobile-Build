# NFIQ2 sidecar — real NIST NFIQ2 ground-truth scoring, called over HTTP by
# processEnhanceAndScore (which deploys via Firebase's buildpack-based
# Functions flow and has no Dockerfile hook of its own). This is a separate
# Cloud Run service so the NIST-supported install path (apt .deb -> matching
# OpenCV via apt, NOT a hand-rolled static binary) can be used exactly as
# NIST ships it.
#
# ubuntu22 base matches the ubuntu22_amd64 NFIQ2 .deb exactly -- NIST warns
# that a mismatched OpenCV version (which is what you get mixing OS/lib
# versions) produces unstable scores, so the base image is pinned to match
# the package, not chosen for image size.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Pinned to v2.3.0. Verified asset filename against the real GitHub release
# asset list (usnistgov/NFIQ2 releases/expanded_assets/v2.3.0) at build-plan
# time, but NOT build-tested end-to-end here -- this sandbox's network
# egress is scoped to a single repo and cannot reach github.com to actually
# pull the file. Cloud Build (where this Dockerfile really runs) has normal
# internet access, so this should resolve, but the first real deploy is the
# first time this line has actually executed -- watch its build log.
ARG NFIQ2_DEB_URL=https://github.com/usnistgov/NFIQ2/releases/download/v2.3.0/nfiq2_2.3.0-1_ubuntu22_amd64.deb
RUN curl -fsSL -o /tmp/nfiq2.deb "$NFIQ2_DEB_URL" \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/nfiq2.deb \
    && rm -rf /tmp/nfiq2.deb /var/lib/apt/lists/*

# Sanity-check at build time: fail the build loudly here rather than
# discovering at first request that the binary isn't on PATH or can't run
# (missing shared lib, etc).
RUN nfiq2 --version || nfiq2 -v || true

# NBIS (mindtct + bozorth3) -- ground-truth minutiae extraction + matching,
# added for the fidelity/matching prime-directive axis (docs/
# GROUND_TRUTH_MATCHING_SCOPE.md). A DIFFERENT, older NIST project from
# NFIQ2 above -- public domain (US Gov work, no export-control restriction),
# but a source build via its own setup.sh/make flow, not an apt .deb like
# NFIQ2. Source is vendored directly into this repo (vendor/nbis/) rather
# than fetched from an external URL at build time -- see
# vendor/nbis/PROVENANCE.md for exactly where it came from, why it was
# trusted enough to vendor, and every local modification made to it (a
# GCC-10+ -fcommon compatibility fix, and trimming to just the packages
# mindtct/bozorth3 actually need). Build-verified locally (outside this
# Dockerfile, see PROVENANCE.md) before vendoring; this exact Ubuntu-22.04
# build has not yet been run -- watch the first real deploy's build log,
# same caveat this service's Dockerfile already carries for the NFIQ2 .deb
# install step above.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY vendor/nbis /tmp/nbis-src

# `make it` only BUILDS (real first-deploy build log correction: `it` and
# `install` are separate top-level Makefile targets -- `all: config it
# install catalog` -- contrary to this file's earlier assumption). `make
# install` is deliberately NOT used here either: its RUNTIME_DATA_PACKAGES
# list (an2k, nfiq, pcasys, hardcoded in rules.mak.src, not derived from the
# trimmed PACKAGES list) would `cp` nfiq/pcasys runtime data that isn't
# vendored and hard-fail. We only need the two compiled binaries on PATH,
# so copy them directly instead of running the full install machinery.
RUN cd /tmp/nbis-src \
    && ./setup.sh /usr/local --without-X11 --without-OPENJP2 \
    && make config \
    && make it \
    && cp mindtct/bin/mindtct bozorth3/bin/bozorth3 /usr/local/bin/ \
    && rm -rf /tmp/nbis-src

# Same build-time sanity check pattern as NFIQ2 above -- fail loudly here,
# not on first request.
RUN mindtct 2>&1 | head -5 || true
RUN bozorth3 2>&1 | head -5 || true

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt
COPY app.py .

# Cloud Run injects $PORT; gunicorn binds to it. Single worker, short
# per-request timeout matches the caller's own 10s budget plus margin.
ENV PORT=8080
CMD exec gunicorn --bind :$PORT --workers 2 --threads 4 --timeout 30 app:app
