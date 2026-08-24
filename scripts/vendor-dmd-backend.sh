#!/usr/bin/env bash
# Vendor the DMD backend source files needed to drive in-process code generation.
# Re-run whenever dmd:frontend is bumped in dub.sdl.
#
# Reads the dmd version from dub.selections.json and copies:
#   compiler/src/dmd/backend/  -> vendor/dmd-backend/dmd/backend/
#   compiler/src/dmd/dmsc.d    -> vendor/dmd-backend/dmd/dmsc.d
#   compiler/src/dmd/iasm/     -> vendor/dmd-backend/dmd/iasm/
# from the matching dub cache entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DMD_VERSION=$(jq -r 'if .versions.dmd | type == "object" then .versions.dmd.version else .versions.dmd end' "$REPO_ROOT/dub.selections.json")
if [[ -z "$DMD_VERSION" || "$DMD_VERSION" == "null" ]]; then
    echo "error: could not read dmd version from dub.selections.json" >&2
    exit 1
fi

echo "Vendoring DMD backend for dmd $DMD_VERSION..."

DMD_CACHE="$HOME/.dub/packages/dmd/$DMD_VERSION/dmd"
if [[ ! -d "$DMD_CACHE" ]]; then
    echo "error: dmd $DMD_VERSION not found in dub cache at $DMD_CACHE" >&2
    echo "Run: dub fetch dmd@$DMD_VERSION" >&2
    exit 1
fi

SRC="$DMD_CACHE/compiler/src/dmd"
DEST="$REPO_ROOT/vendor/dmd-backend/dmd"

mkdir -p "$DEST"

echo "  copying backend/..."
rm -rf "$DEST/backend"
cp -r "$SRC/backend" "$DEST/backend"

echo "  copying dmsc.d..."
cp "$SRC/dmsc.d" "$DEST/dmsc.d"

# The dmd:frontend Dub package omits the assembler sources. Download the
# matching tagged files from the official DMD repository instead.
echo "  copying iasm/..."
mkdir -p "$DEST/iasm"
for file in dmdaarch64.d dmdx86.d gcc.d; do
    curl -fL \
        "https://raw.githubusercontent.com/dlang/dmd/v$DMD_VERSION/compiler/src/dmd/iasm/$file" \
        -o "$DEST/iasm/$file"
done

echo "Done. vendor/dmd-backend/ is up to date for dmd $DMD_VERSION."
