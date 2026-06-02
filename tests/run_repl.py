#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pexpect==4.9.0", "pytest==8.4.1"]
# ///

import os
import re
import subprocess
from pathlib import Path

import pexpect
import pytest

_ANSI_ESCAPE = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

TIMEOUT = 10
UP_ARROW = "\x1b[A"


def test_repl() -> None:
    repl = qb_path()
    child = pexpect.spawn(repl, timeout=TIMEOUT, encoding="utf-8")
    try:
        child.expect_exact("Quickbite REPL")
        child.expect_exact("> ")

        child.sendline("1 + 2")
        child.expect_exact("> ")
        output = clean(child.before)
        assert "3\n" in output

        child.sendline(UP_ARROW)
        child.expect_exact("> ")
        output = clean(child.before)
        assert "3\n" in output

        child.sendline(":q")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0


def test_piped_blank_line_is_silent_noop() -> None:
    result = run_qb(input="\n")

    assert result.returncode == 0
    assert result.stdout == ""


def test_piped_whitespace_line_is_silent_noop() -> None:
    result = run_qb(input="   \n")

    assert result.returncode == 0
    assert result.stdout == ""


def test_interactive_error_label_is_red() -> None:
    child = pexpect.spawn(qb_path(), timeout=TIMEOUT, encoding="utf-8")
    try:
        child.expect_exact("Quickbite REPL")
        child.expect_exact("> ")

        child.sendline("unittest { assert(1 == 2); }")
        child.expect_exact("> ")

        child.sendline(":t")
        child.expect_exact(
            "\x1b[31mError:\x1b[0m unittest at <repl>(1) failed: 1 != 2",
        )
        child.expect_exact("> ")

        child.sendline(":q")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0


def test_piped_error_label_is_not_coloured() -> None:
    result = run_qb(input="1 / 0\n")

    assert result.returncode == 1
    assert result.stdout.startswith("Error: ")
    assert "\x1b[" not in result.stdout


def test_command_prints_expression_result() -> None:
    result = run_qb("-c", "1 + 2")

    assert result.returncode == 0
    assert result.stdout == "3\n"


def test_command_can_use_several_file_arguments(tmp_path: Path) -> None:
    first = tmp_path / "first.d"
    second = tmp_path / "second.d"
    first.write_text(
        "int firstValue() { return 19; }\n",
        encoding="utf-8",
    )
    second.write_text(
        "int secondValue() { return firstValue() + 23; }\n",
        encoding="utf-8",
    )

    result = run_qb(str(first), str(second), "-c", "secondValue()")

    assert result.returncode == 0
    assert result.stdout == "42\n"
    assert result.stderr == ""


def test_file_argument_loads_example_fixture() -> None:
    result = run_qb("tests/example.d")

    assert result.returncode == 0
    assert result.stdout == ""
    assert result.stderr == ""


def test_file_argument_exits_without_interactive_prompt() -> None:
    child = pexpect.spawn(
        qb_path(),
        ["tests/example.d"],
        timeout=TIMEOUT,
        encoding="utf-8",
    )
    try:
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0
    assert "Quickbite REPL" not in child.before
    assert "> " not in child.before


def test_live_flag_keeps_repl_open_after_file_arguments(tmp_path: Path) -> None:
    module = tmp_path / "loaded.d"
    module.write_text(
        "int loadedValue() { return 42; }\n",
        encoding="utf-8",
    )

    child = pexpect.spawn(
        qb_path(),
        ["-l", str(module)],
        timeout=TIMEOUT,
        encoding="utf-8",
    )
    try:
        child.expect_exact("Quickbite REPL")
        child.expect_exact("> ")

        child.sendline("loadedValue()")
        child.expect_exact("> ")
        output = clean(child.before)
        assert "42\n" in output

        child.sendline(":q")
        child.expect(pexpect.EOF)
    finally:
        child.close(force=True)

    assert child.exitstatus == 0


def run_qb(*args: str, input: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [qb_path(), *args],
        input=input,
        capture_output=True,
        check=False,
        text=True,
        timeout=TIMEOUT,
    )


def qb_path() -> str:
    repl = os.path.join(os.getcwd(), "bin", "qb")
    if not os.path.exists(repl):
        pytest.skip("bin/qb does not exist; run `dub build -c qb` first")

    return repl


def clean(text: str) -> str:
    return _ANSI_ESCAPE.sub("", text).replace("\r", "")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
