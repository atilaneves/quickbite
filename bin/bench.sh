#!/usr/bin/env bash
# Builds and runs the quickbite benchmark binary, optimised including its
# dependencies, then forwards all flags and arguments to it.
#
# The hot code the benchmark measures is the dmd:frontend (parse + semantic) and
# the :dmd-backend-vendor codegen - both dub dependencies. Plain `dub build`'s
# `-b`/`--build` flag sets the build type for the whole dependency tree (unlike
# reggae's per-target CompilerFlags, which only reach the root package), so
# `benchmark-opt` (dub.sdl: optimize, releaseMode, noBoundsCheck) applies to
# dmd:frontend and :dmd-backend-vendor too. dub keeps its own build cache keyed
# by config/build-type/compiler, so this never disturbs the plain `debug` build
# that `ninja bin/ut` / ci.sh use.
#
# The host is LDC-built: LDC nearly halves the frontend (parse + semantic) row,
# which executes no generated code. The native post-parse backends do execute
# DMD-codegen'd code, which an LDC host cannot run in-process (extern(D) ABI
# divergence, ai/spikes/ldc-eh/FINDINGS.md), so SystemLinker hands the linked
# .so to a small DMD-built executor (bin/bench-exec, built below) over a process
# boundary. LLVMJit sends its objects to the same executor, which performs the
# ORC link and calls there, so both native backends are measurable under LDC.
# Usage: bin/bench.sh [--dub=NAME ...] [bench-flags] [fixture ...]
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
dub build -q -c benchmark-ldc -b benchmark-opt --compiler=ldc2 >&2
# bench-exec is the DMD-built run executor (the `bench-exec` sub-package); its
# druntime must match the DMD-codegen'd `.so` that SystemLinker produces, so it
# builds with dmd regardless of the host compiler above. It needs no
# optimisation of its own - it just dlopens and calls into the `.so`.
dub build -q quickbite:bench-exec --compiler=dmd >&2
exec bin/bench "$@"
