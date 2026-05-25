# Goal

Write a bytecode VM for the D programming language.

# Design

Optimise for unittest result latency from any edit — this overrides all other
concerns. JIT would improve runtime but tests run in milliseconds; JIT compile
time would dominate.

Avoid the linker tax: no object files, no whole-program compilation. Drive
compilation from unittest blocks; generate only the bytecode needed for each
test and its transitive dependencies.

Keep code isolated from dmd internals behind a stable interface that wraps
dmd-as-a-library.

# Plan

Consult `ai/plans` for implementation plans.

# Coding Guidelines

## Git worktrees

Do work in a git worktree unless instructed otherwise. Name worktrees
the same as their branch, e.g. worktree named "foo" →
`./worktrees/foo` at repo root. Always use the `worktrees` directory
in this repo unless instructed otherwise.

## TDD

Strict TDD: failing test → dumbest passing code → green suite. No refactoring
until all tests pass. Ask for feedback after the refactoring step.

Stop and wait for approval before adding or modifying any test.

Test behaviours, not implementations.

## Style

- OTBS. For functions with many attributes, `{` on its own line is acceptable.
- Use UFCS liberally.
- Local imports inside functions/types. `imported!"module"` only for parameter
  and return types. Exception: unit test modules may use module-scope imports
  to avoid repeating the same import in every test block.
- Always re-read files before editing; another agent or person may have
  changed them in the meantime.
- Trailing commas.
- `private:` at top of every module; still annotate each declaration explicitly
  with `public`/`private`.
- Maximise attributes: `@safe @nogc nothrow pure const scope`. Do not abuse
  `@trusted` to make functions `@safe`.
- Private functions directly below their first use.
- Prefer `std.conv.text`; use `text(x)` not `x.to!string`.
- Make parameters `in` if possible.
- Prefer `const`; use `auto` with a comment if `const` fails; explicit LHS type
  only if `auto` fails (comment why). Explicit types are fine for uninitialised
  declarations.
- No `synchronized`.
- Omit empty parens: `doStuff;` not `doStuff();`.
- Functions below first use; variables close to use.
- Do not use exceptions for control flow.
- Use `with` in `switch`/`final switch` with enums for more readability.

# Testing

Run `dub test` after every editing session.

Run `benchmarks/run.sh` before creating a PR to make sure the
benchmarks still work.

No per-test process spawning, network access, or repeated dependency resolution
unless explicitly approved.

Never delete test code to make tests pass.

# Do nots

- Add new mistakes to `ai/mistakes.md`. New ones only — no duplicates.
- No classes unless the goal is OOP (virtual dispatch, inheritance). A class
  with no base, no children, and no virtual methods is a struct.

# Do

- Read `ai/mistakes.md` before starting.
- Read git history when starting a new session.
- Wrap markdown files at 80 columns.

## Github

- Label PR comments as from an agent (identify which one).
- Open new PRs in the browser.
- Check for local worktrees before using `gh` to look at diffs etc.

## CI

The repo is private for now, which is causing Github Actions failures
due to billing issues. CI is not currently checking anything we can't
and don't do locally, so ignore its failures for as long as the repo
is private.

## Reviews

Present review findings one by one for discussion and approval. This
applies to reviewing code or plans.
