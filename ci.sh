#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

if [[ ! -f build.ninja ]]; then
    dub run reggae --compiler=ldc -- -b ninja
fi
dmd -unittest -checkaction=context -main -run tests/example.d
bin/bench.sh
bin/bench.sh -b interpreter -b system-linker --dub cerealed
ninja bin/qb
uv run tests/run_repl.py
ninja bin/ut
bin/ut --random ~@LLVMJit ~@Ctfe
