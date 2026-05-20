#!/usr/bin/env bash
# Builds and runs the quickbite benchmark binary.
# All flags and arguments are forwarded to the binary.
# Usage: benchmarks/run.sh [--dub=NAME] [bench-flags] [fixture ...]
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
printf 'Building benchmark binary if needed; this can take a while after source changes...\n' >&2
exec dub run -q -c benchmark -b benchmark-opt -- "$@"
