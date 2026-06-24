#!/usr/bin/env bash
# Builds and runs the quickbite benchmark binary, optimised including its
# dependencies, then forwards all flags and arguments to it.
#
# The hot code the benchmark measures is the dmd:frontend (parse + semantic) and
# the :dmd-backend-vendor codegen - both dub dependencies. reggae's per-target
# CompilerFlags optimise only the root package, never dependencies, so the dev
# build.ninja (shared with ci.sh / `ninja bin/ut`) leaves them `-debug` and the
# benchmark would end up timing unoptimised code while the header still prints
# `-O`. The lever that DOES reach the dependencies is the dub build type reggae
# passes to `dub describe`, so this builds with reggae into its own directory
# under `--dub-build-type=release-nobounds`, keeping the dev build `debug` for
# fast unittest latency.
#
# `release-nobounds` (-O -release -inline -boundscheck=off) is a standard dub
# build type - reggae's buildgen rejects custom ones like `benchmark-opt`. Its
# only delta from `benchmark-opt` is `-inline`, which is harmless here: the host
# is LDC-built and the `-inline`/lowering.d hang is DMD-specific.
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
# Dedicated build directory so the optimised dependency objects never mix with
# the dev `debug` build. reggae regenerates build.ninja itself when reggaefile.d
# changes, so generation only needs to run when the directory is fresh.
build_dir=bin/bench-build
if [[ ! -f "$build_dir/build.ninja" ]]; then
    # Pass absolute paths for both the project root (positional arg) and the
    # output directory (-C). reggae bakes these args verbatim into build.ninja's
    # rerun-check rule, which ninja re-invokes from inside $build_dir whenever a
    # reggae input changes. With relative paths that rerun resolves them against
    # the wrong cwd - the project root becomes $build_dir (so reggaefile.d isn't
    # found) and -C doubles to $build_dir/$build_dir - and the build fails.
    dub run reggae --compiler=ldc -- -b ninja -C "$PWD/$build_dir" \
        --dub-build-type=release-nobounds --dc=ldc2 "$PWD" >&2
fi
# Build progress goes to stderr (like the message above) so the only thing on
# this script's stdout is the benchmark's own result tables - redirecting stdout
# to a file then captures clean results without the build chatter.
ninja -C "$build_dir" bench >&2
# SystemLinker finds bench-exec next to the running binary (thisExePath.dirName),
# so the optimised host lands in bin/ alongside the DMD-built executor.
cp "$build_dir/bench" bin/bench
# The run executor must be DMD-built so its druntime/extern(D) ABI matches the
# DMD-codegen'd .so it loads.
dub build :bench-exec --compiler=dmd >&2
exec bin/bench "$@"
