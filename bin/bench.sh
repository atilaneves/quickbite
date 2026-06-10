#!/usr/bin/env bash
# Builds and runs the quickbite benchmark binary.
# All flags and arguments are forwarded to the binary.
# Usage: bin/bench.sh [--dub=NAME] [bench-flags] [fixture ...]
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
if [[ ! -f build.ninja ]]; then
    dub run reggae --compiler=ldc -- -b ninja
fi
printf '%s\n' \
    'Building benchmark binary if needed...' \
    >&2
ninja bin/bench
exec bin/bench "$@"
