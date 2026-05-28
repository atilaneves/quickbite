#!/usr/bin/env bash
# Builds and runs the quickbite benchmark binary.
# All flags and arguments are forwarded to the binary.
# Usage: bin/bench.sh [--dub=NAME] [bench-flags] [fixture ...]
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
printf '%s\n' \
    'Building benchmark binary if needed...' \
    >&2
dub build -q -c benchmark -b benchmark-opt
exec bin/bench "$@"
