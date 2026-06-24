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
# which this project omits because DMD hangs inlining large lowering.d.
#
# The host is LDC-built: LDC nearly halves the frontend (parse + semantic) row,
# which executes no generated code. The native post-parse backends do execute
# DMD-codegen'd code, which an LDC host cannot run in-process (extern(D) ABI
# divergence, ai/spikes/ldc-eh/FINDINGS.md), so SystemLinker hands the linked
# .so to a small DMD-built executor (bin/bench-exec, built below) over a process
# boundary. llvmjit's in-process JIT has no such boundary and is unavailable
# under this build; use system-linker for native post-parse rows.
# Usage: bin/bench.sh [--dub=NAME ...] [bench-flags] [fixture ...]
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
printf '%s\n' 'Building benchmark binary if needed...' >&2
dub build --compiler=ldc2 --config=benchmark-ldc --build=benchmark-opt
# The run executor must be DMD-built so its druntime/extern(D) ABI matches the
# DMD-codegen'd .so it loads.
dub build :bench-exec --compiler=dmd
exec bin/bench "$@"
