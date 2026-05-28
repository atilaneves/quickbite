#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

dub test -- --random
bin/bench.sh
dub build -c repl
tests/run_repl.py
