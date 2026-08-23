# Vendored NBIS source — provenance

## What this is

A trimmed copy of NIST's NBIS (NIST Biometric Image Software) source, vendored
directly into this repo so the Cloud Run sidecar's Docker build compiles
`mindtct` (minutiae extraction) and `bozorth3` (minutiae matching) from a
pinned, reviewable copy instead of fetching a mutable external URL at build
time. See `docs/GROUND_TRUTH_MATCHING_SCOPE.md` for why these tools exist in
this project (the fidelity/matching prime-directive axis, alongside NFIQ2's
quality axis).

This exists because a first attempt at this (curling
`https://github.com/lessandro/nbis/archive/refs/heads/master.tar.gz` directly
in the Dockerfile) was correctly blocked by this session's own safety
tooling: an agent picking an unverified third-party mirror as a production
build dependency, without the user ever naming or vetting that specific
source, is exactly the kind of supply-chain risk that shouldn't be waved
through. Vendoring turns "trust a live URL forever" into "review this one
frozen, diffable copy once."

## Source

- Upstream: `https://github.com/lessandro/nbis` (a community mirror — there is
  no single official NIST-hosted git repo for NBIS, unlike NFIQ2's
  `usnistgov/NFIQ2`; NIST's own distribution page returns HTTP 403 to
  automated fetches).
- Commit vendored: `3d3b05f0144b706bed56407957bc00779baf2fa5` (2015-11-10).
- Upstream version per its own `CHANGELOG.txt`: NBIS Release 5.0.0.

## Why this mirror was trusted enough to vendor

Not on reputation alone — the actual file contents were inspected directly
after cloning, and they match NIST's own real NBIS release in ways a tampered
fork would be very unlikely to fake convincingly:

- `CHANGELOG.txt`'s license header is NIST's exact standard public-domain
  notice (17 U.S.C. §105, EAR Part 734.3 exemption language), verbatim.
- `CHANGELOG.txt`'s change history matches NIST's real, documented 5.0.0
  release notes (OpenJPEG 1.4→2.1 upgrade, native JP2K codec, POSIX
  `strdup`/`strncpy` fixes, CYGWIN install docs) — these are specific,
  checkable claims about a real release, not generic boilerplate.
- Every source file's header block carries NIST/ITL project metadata
  (`Project: NIST Fingerprint Software`, `Integrators: Kenneth Ko`,
  `Organization: NIST/ITL`) consistently across the whole tree.
- The directory layout, build system (`setup.sh` / `make config` / `make it`),
  and CLI syntax of `mindtct`/`bozorth3` all match NIST's own published man
  pages and installation guide exactly.

## License

Public domain — U.S. Government work under 17 U.S.C. §105, not subject to
copyright, and confirmed not subject to EAR export controls (Part 734.3).
See the license header repeated at the top of `CHANGELOG.txt` and every
source file. No attribution or redistribution restrictions apply.

## What was trimmed, and why

Upstream ships ~15 packages (~102MB); only 8 are needed to build `mindtct`
and `bozorth3`, traced by reading their own Makefiles' `LIBS` lists (which
libraries they actually link against) rather than guessing:

**Vendored:** `commonnbis`, `an2k`, `bozorth3`, `imgtools`, `mindtct`,
`buildutil`, `ijg`, `png`, plus `man` (has real `mindtct.1`/`bozorth3.1` man
pages) and an empty `doc/refs` (the build's directory-existence check wants
it, nothing else does).

**Not vendored:** `nfseg`, `nfiq`, `pcasys` (NIST's own separate quality/
classification tools — this project already has its own NFIQ2 sidecar via
NIST's supported `.deb`, so NBIS's older `nfiq` isn't needed), `jpeg2k`/
`openjp2` (JPEG2000 support — our images are PNG), `misc`/`doc` (~69MB of
sample data and documentation, not needed to build). Within `commonnbis`,
`clapck`/`f2c`/`fft` were also dropped (LAPACK/FFT libs used only by
`pcasys`, confirmed via `grep` that no vendored package references them).

Final size: ~9MB (was ~102MB upstream).

## Local modifications, and why (all diffable against upstream at the pinned commit above)

1. **`setup.sh`**: `REG_LIBS` trimmed to the 5 vendored packages (was 8,
   included the 3 dropped above). The unconditional `pcasys`/`jasper`
   header-generation steps (which touch directories this vendored copy
   doesn't ship) were removed rather than left to fail-and-continue.
2. **`rules.mak.src`**: added `-fcommon` to `CFLAGS`. This is 2015-era C89
   code that relies on "tentative definition" semantics GCC changed the
   default for in GCC 10 (this project's target base image, `ubuntu:22.04`,
   ships GCC 11) — without it, several packages fail to link with
   "multiple definition of ..." errors. This is a well-known, minimal,
   standard fix for building older C code on modern GCC; it does not change
   program behavior.
3. **`commonnbis/p_rules.mak.src`**: `LIBRARYS` trimmed to `cblas fet ioutil
   util` (was `cblas clapck f2c fet fft ioutil util`) — matches the "not
   vendored" trimming above.

## Build verified locally before vendoring

The full trimmed tree was test-built from scratch in a disposable copy
(`./setup.sh <dir> --without-X11 --without-OPENJP2 && make config && make it`,
gcc 13/Ubuntu 24.04) — exits 0, produces working `mindtct` and `bozorth3`
binaries whose `--help`/usage output matches NBIS's own man pages exactly.
Ran a synthetic end-to-end smoke test (`mindtct` on a generated test image →
`.xyt` minutiae file → `bozorth3` on two `.xyt` files → numeric match score)
to confirm the whole pipeline executes without error. The Dockerfile's real
build (Ubuntu 22.04, Cloud Build) has not yet been run against this vendored
copy — watch its build log on first deploy, same caveat this service's
Dockerfile already carries for the NFIQ2 `.deb` install step above it.
