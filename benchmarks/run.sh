#!/usr/bin/env bash
# Builds and runs the quickbite benchmark binary.
# All flags and arguments are forwarded to the binary.
# Usage: benchmarks/run.sh [--dub=NAME] [bench-flags] [fixture ...]
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
exec dub run -q -c benchmark -b release -- "$@"
