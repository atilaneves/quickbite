#!/usr/bin/env bash
# Run the quickbite benchmark suite.
#
# Usage: benchmarks/run.sh [bench-flags] [fixture ...]
#
# With no fixture arguments, runs the default fixture set. Any --warmup /
# --iterations flags are forwarded to the benchmark binary, as are any
# explicit fixture paths.

set -euo pipefail

cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

default_fixtures=(tests/minicereal.d)

# Split forwarded flags from explicit fixture paths so we can fall back to
# the default fixture set when none were provided.
flags=()
fixtures=()
for arg in "$@"; do
    case "$arg" in
        -*) flags+=("$arg") ;;
        *)  fixtures+=("$arg") ;;
    esac
done

if [ ${#fixtures[@]} -eq 0 ]; then
    fixtures=("${default_fixtures[@]}")
fi

exec dub run -q -c benchmark -b release -- "${flags[@]}" "${fixtures[@]}"
