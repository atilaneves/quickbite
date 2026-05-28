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

Language-surface tests must match D's compiled-code behaviour. In `pure_`,
`ExecutorBackend.dmdCtfe` is the canonical oracle for supported behaviour until
the dmd codegen backend is complete; if CTFE disagrees with a backend, assume
the backend or test is wrong unless compiled D code proves otherwise. Once dmd
codegen is complete, resolve any CTFE/codegen disagreement against compiled
code.

## Style

### General

- One True Brace Style. For functions with many attributes, `{` on its
  own line is acceptable.
- Use UFCS liberally.
- Always re-read files before editing; another agent or person may have
  changed them in the meantime.
- Trailing commas.
- Maximise attributes: `@safe @nogc nothrow pure const scope`. Do not
  abuse `@trusted` to make functions `@safe`.
- Private functions below their first use, as close as possible.
- Prefer `std.conv.text`; use `text(x)` not `x.to!string`.
- Make parameters `in` if possible.
- Prefer `const`; use `auto` with a comment if `const` fails; explicit
  LHS type only if `auto` fails (comment why). Explicit types are fine
  for uninitialised declarations.
- No `synchronized`.
- Omit empty parens: `doStuff;` not `doStuff();`.
- Variables as close to their usage as possible.
- Use `with` in `switch`/`final switch` with enums for more readability.

### Production code

- Local imports inside functions/types. `imported!"module"` only for
  parameter and return types.
- `private:` at top of every module; still annotate each declaration
  explicitly with `public`/`private`.
- Do not use exceptions for control flow.

### Test modules

- Use module-scope imports to avoid repeating the same import in every
  test block. Unit test modules should not use `imported`.
- Use package modules liberally to avoid imports in test modules - see
  `import ut;` for a good example.

## Code organisation

* Backends should not import each other, they must be completely
  isolated.

# Testing

Run `dub test` after every editing session.

Run `benchmarks/run.sh` before creating a PR to make sure the
benchmarks still work.

No per-test process spawning, network access, or repeated dependency
resolution unless explicitly approved.

Never delete test code to make tests pass.

# Do nots

- Add new mistakes to `ai/mistakes.md`. New ones only — no duplicates.
- No classes unless the goal is OOP (virtual dispatch, inheritance). A
  class with no base, no children, and no virtual methods is a struct.

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

# General LLM Coding Guidelines inspired by Andrej Karpathy

## Source

<https://github.com/multica-ai/andrej-karpathy-skills>

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with
project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For
trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick
  silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?"
If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's
request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them
  pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria
("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in
diffs, fewer rewrites due to overcomplication, and clarifying
questions come before implementation rather than after mistakes.
