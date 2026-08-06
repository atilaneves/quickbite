# Goal

Write a bytecode VM for the D programming language.

# Design

Optimise for unittest result latency from any edit — this overrides
all other concerns. JIT would improve runtime but tests run in
milliseconds; JIT compile time would dominate.

Avoid the linker tax: no object files, no whole-program
compilation. Drive compilation from unittest blocks; generate only the
bytecode needed for each test and its transitive dependencies.

Keep code isolated from dmd internals behind a stable interface that
wraps dmd-as-a-library.

# Plan

Consult `ai/plans` for implementation plans.

A plan exists for one reason: so the next agent knows what to do and
why. It carries the decisions and their rationale, the contracts and
invariants the code depends on, the alternatives already rejected, and
the work that remains. It is not a record of what was done — git
history already carries that, in more detail and more reliably, and a
plan that narrates completed work buries the part a reader actually
needs.

So do not append progress or ledger entries, and do not restate in
prose what the diff already says. When your change settles a question,
*edit* the decision, contract, or remaining-work item it affects and
delete whatever it made untrue. The test for a sentence in a plan: if
it would still be worth reading a year from now by someone who will
never look at this commit, keep it; otherwise it belongs in the commit
message.

# Coding Guidelines

## Git worktrees

Do work in a git worktree unless instructed otherwise. Name worktrees
the same as their branch, e.g. worktree named "foo" →
`./worktrees/foo` at repo root. Always use the `worktrees` directory
in this repo unless instructed otherwise.

## Style

### General

* One True Brace Style. For functions with many attributes, `{` on its
  own line is acceptable.
* Use UFCS liberally.
* Always re-read files before editing; another agent or person may have
  changed them in the meantime.
* Trailing commas.
* Maximise attributes: `@safe @nogc nothrow pure const scope`. Do not
  abuse `@trusted` to make functions `@safe`.
* Private functions below their first use, as close as possible.
* Prefer `std.conv.text`; use `text(x)` not `x.to!string`.
* Make parameters `in` if possible.
* Prefer `const`; use `auto` with a comment if `const` fails; explicit
  LHS type only if `auto` fails (comment why). Explicit types are fine
  for uninitialised declarations.
* No `synchronized`.
* Omit empty parens: `doStuff;` not `doStuff();`.
* Variables as close to their usage as possible.
* Use `with` in `switch`/`final switch` with enums for more readability.
* private variables start with an underscore, e.g. `_member`.
* D has modules and types within types, do not use C-like naming
  conventions like `Foo` and `FooEnum`, instead place enums inside the
  corresponding class/struct so that one uses `Foo.Enum` instead.

### Production code (in `source`)

- Use `imported!"module"` for parameter and return types at
  module-scope.  Do not use `imported!"module"` in non-module scopes
  such as inside a function, struct, or class.
- `private:` at top of every module; still annotate each declaration
  explicitly with `public`/`private`.
- Do not use exceptions for control flow.

### Test modules (in `tests`)

- Use module-scope imports to avoid repeating the same import in every
  test block. Unit test modules should not use `imported`.
- Use package modules liberally to avoid imports in test modules - see
  `import ut;` for a good example.

## Testing

Run tests after every edit you make.

Prefer to run focussed tests instead of the whole test suite by passing
the relevant test names to `bin/ut`.

To build `/bin/ut`, run `dub run reggae --compiler=ldc -- -b ninja` if
`build.ninja` does not exist, then `ninja bin/ut`. Do not assume you
can run `bin/ut`. It might be stale, and running ninja is either 1)
required anyway or 2) so fast it doesn't matter, so don't skip running
ninja.

If the sandbox blocks these commands, request escalation for the same
command instead of trying alternate test runners.

To run the full unit test suite, run `bin/ut --random`. If there's a
test failure, first check with `--seed` (using the seed in the output
to the last `bin/ut --random`) to investigate the cause of failure in
that particular ordering.

Run `ci.sh` before creating a PR. It must pass before the PR is
created or merged: a failure that reproduces on `master` may be
documented with an appropriate backend-matrix omission, but it may not
be ignored. If the benchmarks fail to run properly for any backend,
identify why and come up with a D language feature unit test that
exposes the flaw in that backend's implementation.

Never delete test code to make tests pass.

Test behaviours, not implementations.

Language-surface tests must match D's compiled-code behaviour, with
`SystemLinker` as the oracle (`ai/plans/single-oracle.md`). If a backend
disagrees with `SystemLinker`, the backend or test is wrong. `Ctfe` is not an
oracle: where it diverges from `SystemLinker`, pin `Ctfe`'s actual behaviour as
a characterization test (with a comment naming the divergence) rather than
treating it as truth. `Ctfe` is still a convenient real-D fixture source — a
fixture written for it is real D — but it never arbitrates correctness.

Promoting an already-existing backend-matrix test to another backend
is pre-approved when the test is backed by that oracle.

## TDD

Strict TDD for implementing new features or fixing bugs: failing test
→ dumbest passing code → green suite → refactor.

Stop and wait for approval before adding or modifying any test for new
functionality. Tests that you write exposing a bug do not need
approval, but you do have to first run the test to make sure it fails
as intended. Always run bug-exposing tests on all backends when
determining its redness, do not pre-emptively add `Omit`.


## Code organisation

* Backends must not import each other: nothing in one backend's package
  may import another backend's package, and vice versa. Within a single
  backend package, modules can and should import each other, including
  package-private code.


# Do nots

- No classes unless the goal is OOP (virtual dispatch, inheritance). A
  class with no base, no children, and no virtual methods is a struct.
- CI must never be red. Not locally, not in a PR.
- Do not mention quickbite implementation details in comments attached
  to tests.

# Do

- Read `ai/mistakes.md` before starting.
- Add new mistakes to `ai/mistakes.md`. No duplicates.
- Read git history when starting a new session.
- Wrap markdown files at 80 columns.
- Explain why a unittest block is testing an AST shape by referring to
  language semantics. If necessary, you are allowed to refer to dmd
  internal implementation details.

## Github

- Label PR comments as from an agent (identify which one).
- Open new PRs in the browser.
- Check for local worktrees before using `gh` to look at diffs etc.
- When you create or update a PR, check to see if it can be merged and
  fix any conflicts, don't wait to be told to do so.
- When you create or update a PR, monitor CI status until the CI run
  completes. If it's red once done, loop spawning fixer subagents
  until it's green.

## Reviews

Present review findings one by one for discussion and approval. This
applies to reviewing code or plans.
