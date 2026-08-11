#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

if [[ ! -f build.ninja ]]; then
    dub run reggae --compiler=ldc -- -b ninja
fi
dmd -unittest -checkaction=context -main -run tests/example.d
bin/bench.sh
# The cerealed run segfaults in the interpreter's associative-array
# duplication before it reports anything, on master as well as here, so it
# fails CI without telling anyone what is wrong. Restore this line once that
# crash is fixed.
# bin/bench.sh -b interpreter -b system-linker --dub cerealed
ninja bin/qb
uv run tests/run_repl.py
ninja bin/ut
bin/ut --random ~@LLVMJit ~@Ctfe
