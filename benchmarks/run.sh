#!/usr/bin/env bash
# Run the quickbite benchmark suite.
#
# Usage: benchmarks/run.sh [bench-flags] [fixture ...]
#        benchmarks/run.sh --cerealed [bench-flags]
#
# --cerealed   benchmark all cerealed test files (resolves paths via dub)
#
# With no fixture arguments, runs the default fixture set. Any --warmup /
# --iterations flags are forwarded to the benchmark binary, as are any
# explicit fixture paths.

set -euo pipefail

cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

default_fixtures=(tests/minicereal.d)

use_cerealed=false
flags=()
fixtures=()
for arg in "$@"; do
    case "$arg" in
        --cerealed) use_cerealed=true ;;
        -*) flags+=("$arg") ;;
        *)  fixtures+=("$arg") ;;
    esac
done

if $use_cerealed; then
    mapfile -t dub_import_paths < <(
        dub describe --config=unittest --data=import-paths --data-list 2>/dev/null
    )
    cerealed_src=
    concepts_src=
    for p in "${dub_import_paths[@]}"; do
        case "$p" in
            */cerealed/src)    cerealed_src="$p" ;;
            */concepts/source) concepts_src="$p" ;;
        esac
    done
    if [[ -z "$cerealed_src" ]]; then
        echo "error: cerealed/src not found in dub import paths" >&2
        exit 1
    fi
    cerealed_tests="${cerealed_src%/src}/tests"
    flags+=(
        "--import-path=$cerealed_src"
        "--import-path=$(pwd)/vendor/ut_stubs"
    )
    [[ -n "$concepts_src" ]] && flags+=("--import-path=$concepts_src")
    mapfile -t cerealed_fixtures < <(ls "$cerealed_tests"/*.d)
    fixtures+=("${cerealed_fixtures[@]}")
fi

if [ ${#fixtures[@]} -eq 0 ]; then
    fixtures=("${default_fixtures[@]}")
fi

exec dub run -q -c benchmark -b release -- "${flags[@]}" "${fixtures[@]}"
