#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

dub test -- --random
dmd -unittest -checkaction=context -main -run tests/example.d
bin/bench.sh
dub build -c qb
uv run tests/run_repl.py
