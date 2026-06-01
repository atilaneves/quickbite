#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$root/tmp/dmd-ctfe-coverage"
coverage_anchor="$output_dir/.dmd-dinterpret.anchor"

mkdir -p "$output_dir"
: > "$coverage_anchor"
trap 'rm -f "$coverage_anchor"' EXIT INT TERM

cd "$root"
dub test --force --build=unittest-cov -- "$@"

coverage_file=$(
    find "$root" -maxdepth 1 -name "*dmd-dinterpret.lst" -size +0c \
        -newer "$coverage_anchor" \
        -printf "%T@ %p\n" |
    sort -nr |
    sed -n "1s/^[^ ]* //p"
)

if [ -z "$coverage_file" ]; then
    echo "No non-empty dmd.dinterpret coverage file found in $root" >&2
    exit 1
fi

cp -- "$coverage_file" "$output_dir/dmd-dinterpret.lst"
"$root/scripts/report-dmd-ctfe-coverage.sh" \
    "$output_dir/dmd-dinterpret.lst" \
    > "$output_dir/dmd-dinterpret-audit.md"

cat <<EOF
Wrote:
  $output_dir/dmd-dinterpret.lst
  $output_dir/dmd-dinterpret-audit.md
EOF
