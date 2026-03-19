# Goal

The goal is to write a bytecode VM for the D programming language.

# High level design considerations

Optimise for the latency of getting unittest results from any given
edit. This is more important than anything else. A JIT would achieve
better runtime performance, but the tests themselves probably run in
milliseconds anyway so it would take longer to JIT compile the code
than running it in the VM.

I want to avoid paying the "linker tax". I don't want object files.  I
don't want to compile the whole code. I want the compilation to be
driven by unittest blocks and for the least amount of bytecode to be
generated in order for the test and its dependent code (code directly
under test and its transitive dependencies) to be able to execute.

# Low level design considerations

The code should be as isolated as possible from the dmd internals.  We
want a stable interface that we can call. This interface will in turn
use dmd as a library.

# Plan

Consult `ai/dlang_bytecode.md` for a detailed implementation plan.
Consult `ai/ir.md` for the minimal IR implementation plan for the
first supported slice.

# Coding Guidelines

Write everything in strict TDD style. Write a test, make sure it fails,
write the code, make sure the tests pass again.

Use the one true brace coding style, not dmd/phobos.

Use UFCS liberally.

Use local imports where possible. For parameters and return types use
`importer!"module"`.

Do not assume the code has not been edited by someone else in the
meanwhile. Always re-read files that you are about to edit.

Use trailing commas.

# Testing

Run `dub test` after every editing "session" to assess the current
status.

Never delete test code to cause the tests to pass.

# Do nots

Consult `ai/mistakes.md` for mistakes made by previous agents that you
learn from so as to not do them again.

# Do

Consult the git history when starting a new session to understand what
has already been done.

When asked to write something to a markdown file, make it 80 columns
wide at most.
