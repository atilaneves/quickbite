#!/bin/sh

set -eu

coverage_file=${1:-tmp/dmd-ctfe-coverage/dmd-dinterpret.lst}

awk '
function trim(value) {
    sub(/^[ \t]+/, "", value)
    sub(/[ \t]+$/, "", value)
    return value
}

function remember(area) {
    if (!(area in seen)) {
        seen[area] = 1
        areas[++areaCount] = area
    }
}

function setArea(source) {
    source = trim(source)
    if (source ~ /^Expression interpretStatement\(/ ||
        source ~ /^Expression interpretStatement\(UnionExp\*/) {
        current = source
        kind[current] = "statement interpreter"
        remember(current)
    } else if (source ~ /^void visit[A-Za-z0-9_]*\(/) {
        current = source
        kind[current] = "statement visitor"
        remember(current)
    } else if (source ~ /^override void visit\(/) {
        current = source
        kind[current] = "expression visitor"
        remember(current)
    }
}

BEGIN {
    print "| DMD CTFE area | Coverage status | First uncovered line | Notes |"
    print "| --- | --- | --- | --- |"
}

{
    pipe = index($0, "|")
    if (pipe == 0)
        next

    prefix = substr($0, 1, pipe - 1)
    source = substr($0, pipe + 1)
    setArea(source)

    if (current == "")
        next

    if (prefix ~ /0000000/) {
        ++uncovered[current]
        if (!(current in firstUncovered))
            firstUncovered[current] = NR
    } else if (prefix ~ /[1-9][0-9]*/)
        ++covered[current]
}

END {
    for (i = 1; i <= areaCount; ++i) {
        area = areas[i]
        if (!(area in uncovered))
            continue

        status = covered[area] ? "Partially covered" : "Whole method uncovered"
        notes = kind[area] "; " uncovered[area] " uncovered executable line(s)"
        print "| `" area "` | " status " | " firstUncovered[area] " | " notes " |"
    }
}
' "$coverage_file"
