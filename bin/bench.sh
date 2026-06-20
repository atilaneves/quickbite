#!/usr/bin/env bash
# Builds and runs the quickbite benchmark binary, optimised including its
# dependencies, then forwards all flags and arguments to it.
#
# The hot code the benchmark measures is the dmd:frontend (parse + semantic) and
# the :dmd-backend-vendor codegen - both dub dependencies. reggae's per-target
# CompilerFlags optimise only the root package, never dependencies, so the dev
# build.ninja (shared with ci.sh / `ninja bin/ut`) leaves them `-debug` and the
# benchmark ends up timing unoptimised code while the header still prints `-O`.
#
# Build instead with dub's `benchmark-opt` build type, whose buildOptions
# (optimize + releaseMode + noBoundsCheck) propagate to the dependencies. It is
# used rather than reggae/ninja on purpose: reggae's buildgen only accepts
# standard dub build types, and every optimising standard type adds `-inline`,
# which this project omits because DMD hangs inlining large lowering.d. The host
# stays DMD-compiled: SystemLinker dlopens DMD-backend `.so`s whose DMD
# exception-handling ABI an LDC host cannot load.
# Usage: bin/bench.sh [--dub=NAME] [bench-flags] [fixture ...]
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
printf '%s\n' 'Building benchmark binary if needed...' >&2
dub build --config=benchmark --build=benchmark-opt
exec bin/bench "$@"
