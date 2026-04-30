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

## TDD

Write everything in strict TDD style. Write a test, make sure it
fails, write the code, make sure the tests pass again. When you write
production code to make a test pass, write the dumbest simplest thing
that will get the job done, no matter how much repetition. Do not
attempt to refactor the code to make it better until all tests pass.
Ask for feedback on the code you wrote once the refactoring step is
done.

## Style

Use the one true brace coding style, not dmd/phobos. However, sometimes
with a lot of attributes and characters on one line that can get unwieldy.
Use judgement to place opening braces for *functions* on their own line.
Look at the rest of the code for guidance.

Use UFCS liberally.

Use local imports where possible. For parameters and return types use
`imported!"module"`.

Use trailing commas.

Use `private:` at the top of every module. Be explicit with `public`
and `private` anyway.

Use as many attributes as can be used: `@safe @nogc nothrow pure const
scope`, for instance.

Private functions should be placed directly below where they used if
possible.

Prefer `std.conv.text` to `writefln` or `to!string`.

Make parameters `in` if possible.

Prefer `const` to `auto` when declaring variables.

Do not use `synchronized`.

# Testing

Run `dub test` after every editing "session" to assess the current
status.

Never delete test code to cause the tests to pass.

# Do nots

* When you make a new mistake, add it to `ai/mistakes.md`. Only *new*
mistakes, don't add the same one again.

* Do not assume the code has not been edited by someone else in the
meanwhile. Always re-read files that you are about to edit.

* Do not use classes because they are reference types. Only use
  classes if the goal is OOP. Classes with no base classes/interfaces,
  or no children, or no virtual member functions are structs.


# Do

* Consult `ai/mistakes.md` for mistakes made by previous agents that
you learn from so as to not do them again.

* Consult the git history when starting a new session to understand
what has already been done.

* When asked to write something to a markdown file, make it 80 columns
wide at most.
