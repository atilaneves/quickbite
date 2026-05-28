#!/usr/bin/env python3

import os
import pty
import select
import signal
import subprocess
import sys
import time


TIMEOUT_SECONDS = 10.0


def main() -> int:
    repl = os.path.join(os.getcwd(), "bin", "repl")
    if not os.path.exists(repl):
        print(
            "bin/repl does not exist; run `dub build -c repl` first",
            file=sys.stderr,
        )
        return 1

    pid, fd = pty.fork()
    if pid == 0:
        os.execv(repl, [repl])

    transcript = bytearray()
    status = None
    try:
        offset, _ = read_until(fd, transcript, 0, b"Quickbite REPL\n> ")
        send(fd, b"1 + 2\n")
        offset, chunk = read_until(fd, transcript, offset, b"> ")
        assert_chunk(chunk, b"1 + 2\n3: int\n> ")
        send(fd, b"\x1b[A\n")
        offset, chunk = read_until(fd, transcript, offset, b"> ")
        assert_chunk(chunk, b"1 + 2\n3: int\n> ")
        send(fd, b":q\n")
        _, status = os.waitpid(pid, 0)
    finally:
        if status is None:
            terminate(pid)
        os.close(fd)

    if status != 0:
        print(transcript.decode(errors="replace"), file=sys.stderr)
        return subprocess.CalledProcessError(status, repl).returncode

    return 0


def read_until(
    fd: int,
    transcript: bytearray,
    offset: int,
    needle: bytes,
) -> tuple[int, bytes]:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while True:
        observed = terminal_text(transcript)
        index = observed.find(needle, offset)
        if index != -1:
            end = index + len(needle)
            return end, observed[offset:end]

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                "timed out waiting for "
                + repr(needle)
                + "\n"
                + transcript.decode(errors="replace")
            )

        readable, _, _ = select.select([fd], [], [], remaining)
        if not readable:
            continue

        chunk = os.read(fd, 4096)
        if not chunk:
            raise EOFError(
                "repl exited before "
                + repr(needle)
                + "\n"
                + transcript.decode(errors="replace")
            )

        transcript.extend(chunk)


def assert_chunk(actual: bytes, expected: bytes) -> None:
    if actual == expected:
        return

    raise AssertionError(
        "terminal chunk mismatch\n"
        + "--- expected ---\n"
        + expected.decode(errors="replace")
        + "\n--- actual ---\n"
        + actual.decode(errors="replace")
    )


def send(fd: int, text: bytes) -> None:
    os.write(fd, text)


def terminal_text(transcript: bytearray) -> bytes:
    return bytes(transcript).replace(b"\r\n", b"\n")


def terminate(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


if __name__ == "__main__":
    sys.exit(main())
