#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

if [[ ! -f build.ninja ]]; then
    dub run reggae --compiler=ldc -- -b ninja
fi
dmd -unittest -checkaction=context -main -run tests/example.d
bin/bench.sh  # example.d
bin/bench.sh -b system-linker -b interpreter -b bytecode -w 0 -r 1 --dub cerealed
ninja bin/qb
uv run tests/run_repl.py
ninja bin/ut bin/ffi-resolve-cache-late-load-fixture.so
bin/ut --random ~@LLVMJit ~@Ctfe
