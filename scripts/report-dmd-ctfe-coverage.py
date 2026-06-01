#!/usr/bin/env python3

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path


KEYWORDS = (
    "if",
    "else",
    "for",
    "foreach",
    "while",
    "switch",
    "case",
    "default",
    "catch",
    "scope",
    "return",
    "assert",
    "do",
    "goto",
    "break",
    "continue",
)

PREFIXES = (
    "public ",
    "private ",
    "protected ",
    "package ",
    "static ",
    "final ",
    "override ",
    "extern (C++) ",
    "extern (C) ",
    "extern (D) ",
    "pure ",
    "nothrow ",
    "@safe ",
    "@nogc ",
    "const ",
    "immutable ",
    "inout ",
    "shared ",
    "ref ",
    "auto ",
)


@dataclass
class AreaStats:
    kind: str
    uncovered: int = 0
    covered: int = 0
    first_uncovered: int | None = None


def trim(value: str) -> str:
    return value.strip()


def is_function_declaration(source: str) -> bool:
    source = trim(source)
    if not source or source.startswith("}"):
        return False

    if source.startswith("{"):
        return False

    if source.startswith(("//", "/*", "/**", "*", "///")):
        return False

    if source.startswith(KEYWORDS):
        return False

    if ";" in source or '"' in source or "//" in source:
        return False

    if any(token in source for token in (" class ", " struct ", " interface ",
                                         " enum ", " template ", " alias ",
                                         " mixin ")):
        return False

    while True:
        for prefix in PREFIXES:
            if source.startswith(prefix):
                source = source[len(prefix):]
                break
        else:
            break

    before_paren = source.split("(", 1)[0].strip()
    parts = before_paren.split()
    if len(parts) < 2:
        return False

    if parts[-1] in KEYWORDS:
        return False

    return True


def classify(source: str) -> str:
    if source.startswith("Expression interpretStatement(") or \
        source.startswith("Expression interpretStatement(UnionExp*"):
        return "statement interpreter"

    if source.startswith("override void visit("):
        return "expression visitor"

    if source.startswith("void visit"):
        return "statement visitor"

    return "helper function"


def parse_coverage(path: Path) -> tuple[dict[str, AreaStats], int, int]:
    areas: dict[str, AreaStats] = {}
    current: str | None = None
    covered_total = 0
    total_executable = 0

    with path.open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, start=1):
            pipe = line.find("|")
            if pipe == -1:
                continue

            prefix = line[:pipe].strip()
            source = line[pipe + 1 :].rstrip("\n")

            if not prefix and is_function_declaration(source):
                current = trim(source)
                areas.setdefault(current, AreaStats(kind=classify(current)))
                continue

            if current is None:
                continue

            if prefix == "0000000":
                total_executable += 1
                area = areas[current]
                area.uncovered += 1
                if area.first_uncovered is None:
                    area.first_uncovered = lineno
            elif prefix and prefix[0].isdigit():
                total_executable += 1
                areas[current].covered += 1
                covered_total += 1

    return areas, covered_total, total_executable


def emit_report(areas: dict[str, AreaStats], covered_total: int, total_executable: int) -> None:
    print("| DMD CTFE area | Coverage status | First uncovered line | Notes |")
    print("| --- | --- | --- | --- |")

    for area, stats in areas.items():
        if stats.uncovered == 0:
            continue

        status = "Partially covered" if stats.covered else "Whole method uncovered"
        print(
            f"| `{area}` | {status} | {stats.first_uncovered} | "
            f"{stats.kind}; {stats.uncovered} uncovered executable line(s) |"
        )

    if total_executable:
        pct = covered_total * 100.0 / total_executable
        print()
        print("| Coverage summary | Covered | Total | Coverage |")
        print("| --- | ---: | ---: | ---: |")
        print(
            f"| `dmd.dinterpret` executable entries | {covered_total} | "
            f"{total_executable} | {pct:.2f}% |"
        )


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else Path("tmp/dmd-ctfe-coverage/dmd-dinterpret.lst")
    areas, covered_total, total_executable = parse_coverage(path)
    emit_report(areas, covered_total, total_executable)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
