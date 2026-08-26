# Goal

Write alternative backends for the D programming language.

# Communication guidelines

Use ASD-STE100 - Simplified Technical English in all communication.

# Coding Guidelines

See ai/CODING.md.

## Git worktrees

Do work in a git worktree unless instructed otherwise.

## Testing

Run tests after every code edit you make. Plan documents are not code.

Prefer to run focussed tests instead of the whole test suite by passing
the relevant test names to `bin/ut`.

To build `/bin/ut`, run `dub run reggae --compiler=ldc -- -b ninja` if
`build.ninja` does not exist, then `ninja bin/ut`. Do not assume you
can run `bin/ut`. It might be stale, and running ninja is either 1)
required anyway or 2) so fast it doesn't matter.

If the sandbox blocks these commands, request escalation for the same
command instead of trying alternate test runners.

Run `ci.sh` before creating a PR. It must pass before the PR is
created or merged: a failure that reproduces on `master` may be
documented with an appropriate backend-matrix omission, but it may not
be ignored. If the benchmarks fail to run properly for any backend,
identify why and come up with a D language feature unit test that
exposes the flaw in that backend's implementation.

Test behaviours, not implementations.

Language-surface tests must match D's compiled-code behaviour — including
assertion-failure and diagnostic text — with `SystemLinker` as the oracle
(vocabulary in `CONTEXT.md`; matrix mechanics enforced in
`tests/ut/backends/package.d`). If a backend disagrees with `SystemLinker`,
the backend or test is wrong. `Ctfe` is not an oracle: where it diverges from
`SystemLinker`, pin `Ctfe`'s actual behaviour as a characterization test (with
a comment naming the divergence) rather than treating it as truth. `Ctfe` is
still a convenient real-D fixture source — a fixture written for it is real D
— but it never arbitrates correctness.

Promoting an already-existing backend-matrix test to another backend
is pre-approved when the test is backed by that oracle.

## TDD

Strict TDD for implementing NEW features or fixing bugs.

Stop and wait for approval before adding or modifying any test for NEW
functionality. Tests that you write exposing a bug do not need
approval, but you do have to first run the test to make sure it fails
as intended. Always run bug-exposing tests on all backends when
determining its redness, do not pre-emptively add `Omit`.

## Runtime semantics

Druntime-first: when druntime already implements a runtime behaviour
(associative arrays, array append and growth, hashing, exception
chaining, TypeInfo), a backend executes druntime's real source or real
hooks instead of carrying its own version. A local reimplementation
needs a written justification in the owning GitHub issue and a stated
retirement condition. Interpreter deviations are tracked by their
GitHub issues: monitors (#561), static-array construction (#562),
array allocation and length (#565), append and reserve (#566),
exception chaining (#568), and concatenation (#569).

Guest bytes are identical to compiled D's layout in every backend
except `Ctfe`, which is DMD's own engine and holds no guest bytes.
There is no fact about a guest value that native bytes cannot express:
compiled D stores callable identity, delegate context, dynamic class
type, and TypeInfo identity as pointer-sized words inside the value,
and so does each other backend. No table keyed by a guest address
supplements a stored value. The only permitted side structure is a
lookup keyed by the stored value itself. Examples: an identity pointer
resolved to an interpreted callable, and a trampoline address aliased
to that same identity. An ordinary byte copy, move, or clear carries
the value with no reconciliation. Known deviations: the Interpreter
class object header (#578) and retention of address-keyed tables
(#563).


# Do nots

- No classes unless the goal is OOP (virtual dispatch, inheritance). A
  class with no base, no children, and no virtual methods is a struct.
- CI must never be red. Not locally, not in a PR.
- Do not mention quickbite implementation details in comments attached
  to tests.
- Do not "intercept" D code by name to shortcut implementation.
- Never delete test code to make tests pass.

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

Present review findings one by one for discussion and approval.
