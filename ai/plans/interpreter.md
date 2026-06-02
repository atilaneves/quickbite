# Plan: Tree-Walking Executor

## Summary

Walk the semantically-analysed DMD AST directly and execute it in a
single recursive descent, with no lowering pass and no intermediate
representation. The goal is to reach CTFE parity on the language
surface covered by the existing test suite, driven first by the
simplest existing `eval` tests and then by similarly small CTFE-only
tests promoted one at a time to the tree-walking backend.

Rename the backend from `TreeWalker` to `Interpreter` as the supported
interpreter surface grows. Keep any compatibility aliases or test-matrix
transitions narrow and temporary; the long-term public backend name should be
`Interpreter`, not `TreeWalker`.

The process mirrors the IR backend: pick the simplest test that does
not yet run under the tree walker, add the tree-walking backend to it,
confirm it is red, implement the smallest handler that makes it green,
then move on. Do not add implementation beyond what a failing test
demands.

When a test passes without any implementation change, do not assume
the feature works. Mutate the test or the production code to confirm
the passing result would become a failure under a meaningful change.
Only then accept the slice as done.

## Architecture

- Implement `TreeWalker.eval` first. It may parse an expression through
  the same frontend expression path used by the bytecode backend, then
  walk that expression directly.
- Leave `evalRepl`, broader module-backed test execution, and test-summary
  behavior alone until an approved test specifically requires them.
- Walk `FuncDeclaration` and `UnitTestDeclaration` AST nodes for
  unittest bodies; dispatch to statement and expression handlers by
  dynamic type only after eval coverage has forced enough expression
  support to make module-backed tests the next smallest step.
- No intermediate form. Values are produced and consumed in the same
  recursive descent; no register allocation or instruction selection.
- Interpreter values, locals, temporaries, and function returns must use
  `quickbite.lang.Value` from the start. Do not use `long`, `bool`, or
  `void*`-keyed placeholder state for early slices just because the first
  promoted test only observes integer or boolean behaviour.
- Use a flat environment model: a locals map keyed by declaration
  identity, extended and restored on scope entry and exit.
- The executor must not import or delegate to other backends.
  Unsupported AST nodes must emit an explicit unsupported diagnostic
  rather than crashing or falling through.
- Keep DMD coupling behind the walker itself. Public types and return
  values must not expose `dmd.*` identities across the executor
  boundary.
- `tree_walking_old.d` is a reference for feature scope, not
  production code. Do not port code from it mechanically; re-derive
  each slice from a failing test.

## Slice Plan

Promote tests in order of complexity. Start with
`tests/ut/backends/pure_/lang/eval.d`, because those tests exercise the
smallest backend surface: parse an expression or tiny eval cell, walk
it, and return one `Value`. Prefer integer literals first, then simple
arithmetic, then the next eval behavior with the fewest required D
language features. Once the first integer literal slice is green, keep
the eval roadmap covering all D integer scalar types (`byte`, `ubyte`,
`short`, `ushort`, `int`, `uint`, `long`, and `ulong`) before treating
integer scalar preservation as complete.

After the existing eval tests are done, do not jump to an entire broad
language file. Identify the next similarly simple test by counting the
required language features in the fixture and choosing the smallest
delta from the tree walker's current support. The target module after
`eval.d` is `tests/ut/backends/pure_/lang/logic.d`, starting with the
simplest individual tests such as `logicalNot`, then plain `&&` and
`||` cases before call-based or short-circuit cases.

Do not pick a CTFE-only test at random just because it currently lacks
`TreeWalker`. Before migrating one test, inspect the fixture and choose
the test most likely to need the fewest production changes. Count the
visible AST features first: literals only is better than locals;
locals are broader than direct literals; calls, imports, control flow,
assertion formatting, type coercion, arrays, structs, and exceptions
are each reasons to defer the test. Prefer a test whose expected red
failure points at one missing AST handler or one tiny fake.

Do not decide the ordering in advance beyond the immediate next test.
Let the smallest plausible failing test determine what to implement.

Use this rough ordering when comparing candidates with similar size:
literal and scalar value preservation; one binary or unary expression;
casts that do not require locals; comparisons and boolean operations;
one local declaration plus final expression; simple assignment or
increment; one direct function call; then module-backed unittest assertions.
Defer imports, assertion context formatting, control flow, arrays,
structs, exceptions, pointers, delegates, and diagnostics until simpler
tests stop being available.

### Eval Slice Lessons

Current progress: all tests in `tests/ut/backends/pure_/lang/eval.d` are
covered by `TreeWalker`, including `stringLiteralIsArray`. Keep future eval
work focused on regressions or newly added CTFE-backed eval behaviours.

When promoting one eval test, isolate that test in its own `static
foreach` backend block if the surrounding block contains later eval
tests. Do not change a broad block from `backends` to
`backendsWith!TreeWalker` unless every test in that block is part of
the current slice. When integrating worker commits, check that earlier
TreeWalker promotions remain present; a later worker must not move a
previously promoted test back to CTFE-only coverage.

If a promoted test is already green because of an earlier slice, verify
signal by temporarily mutating the production handler that should cover
it, then revert the mutation before committing. The final commit for
that slice may be test-only.

For multiline `eval` input, the first small shape is not a general
REPL. Wrapping prior lines in a tiny function and assigning the final
line to a synthetic local is enough for simple cells, but keep the
interpreter limited to the concrete AST forms the promoted test shows.
For `int x; ++x; ++x; x`, DMD may expose declaration initialisation
through `assign`, `construct`, or `blit`, and prefix increment may
appear as `AddAssignExp`. Do not add decrement, generic assignment,
control flow, imports, or arithmetic in the multiline interpreter until
a promoted test requires it.

For cast slices, prefer evaluating through the current interpreter
state instead of chasing a variable declaration's initializer in a
separate helper. A local such as `double input = 7.75; cast(int) input`
should read `input` from the eval locals map, then perform only the
requested numeric conversion. Avoid adding broad cast fallback paths
that return guessed `long` values or silently unwrap arbitrary
expression wrappers.

For arithmetic slices, keep operations on `quickbite.lang.Value` once
the operands have been evaluated. Do not extract integer bits with
`cast(int)` helpers for subtraction, multiplication, division, or
future operators; that bypasses scalar preservation and makes the
first integer test silently constrain later numeric support.

For cast slices, put type-directed `Value` casting shared by multiple
backends in backend-common code. Do not leave one backend with its own
`TY` switch or `Value.castTo` matrix when bytecode, tree walker, or a
future backend needs the same cast target semantics.

Do not add a separate eval-source parser that splits on the last
newline, synthesizes a local result variable, or creates its own
function wrapper. Route tiny eval cells through common `frontend.cell`
classification/parsing code so declarations, statements, and the final
expression are classified by DMD-backed frontend code instead of local
string heuristics. Keep that common cell API backend-facing only:
REPL-only concepts such as type-display cells belong in
`frontend.repl`, not in the cell type consumed by backends.

### Logic Slice Lessons

Current progress in `tests/ut/backends/pure_/lang/logic.d`:
`logicalNot`, `logicalNotFailureMessage.0`, `logicalNotFailureMessage.1`,
`logicalNotCall`, `logicalNotCallFailureMessage.0`, and
`logicalNotCallFailureMessage.1` are covered by `TreeWalker`.

The next smallest slice is the plain local `logicalAnd` case, followed by
plain local `||` cases before broader call-based or short-circuit logic. Treat
each named unittest as its own promotion and commit.

Module-backed interpreter support remains intentionally narrow:
zero-argument free calls, return statements, comma-expression sequencing,
local bool declarations, unary `!`, equality failure messages, truthiness, and
DMD-lowered logical-not temporaries in assertion messages exist only because
promoted logic tests required them. Do not generalize call parameters, methods,
assignment, control flow, or assertion formatting until a promoted test forces
that behaviour.

### First PR Guardrails

The first PR must be smaller than a general-purpose interpreter slice.
Do not promote a module-backed unittest test that needs locals, declarations,
equality, assertion-message formatting, and type coercion all at once.
That is not a minimum implementation, even if those pieces are
individually small.

For the first tree-walker promotion, prefer an existing CTFE-passing
`eval` test whose red failure can be fixed by one AST handler or by a
tiny single-case fake. If no such test exists, stop and ask before
changing tests or production code. Do not silently broaden the slice.

Do not promote import-path retry tests as the first tree-walker test.
They have order-dependent frontend state and are easy to make flaky
when duplicated across backend lists.

Do not promote all-literal or enum-only fixtures for this first PR
unless the purpose is explicitly constant-folded input. DMD may fold
the expression before the walker sees it, producing a green test that
does not exercise the intended AST path.

After the promoted test is red, write down the exact missing AST node
or behavior named by the failure. The production change for that cycle
must address only that point. If passing the test appears to require a
locals map, type coercion, assertion context formatting, and comparison
support together, the chosen test is too broad for the first PR.

## Test Strategy

- CTFE-passing tests are the acceptance matrix. Promote a test by
  adding the tree-walking backend to it, confirm it turns red, then
  implement the minimum handler that makes it green. Start with one
  existing `eval` test. Existing CTFE-passing tests are pre-approved
  for promotion to the tree-walking backend; do not stop to ask before
  adding `TreeWalker` to exactly one existing test. This exception only covers
  adding the backend to an existing backend-matrix test; adding a new test or
  modifying test behaviour still requires approval before editing the test.
- When a promoted test is green without any implementation change,
  verify it is genuinely covered by mutating the test or the
  production code. A test that cannot be made to fail is not
  providing signal.
- Do not add new language-surface tests. The existing suite is the
  driver. Stop and ask before adding any new test.
- Add tree-walker-specific tests only for walker-native contracts:
  unsupported node diagnostics and environment scoping invariants.
- Never remove or weaken an existing test to satisfy the walker.
- CTFE coverage reports do not rank Quickbite test modules by simplicity. All
  backend `pure_` language modules run against CTFE, so choose post-`eval`
  targets by required D language features. `logic.d` is the first target
  module because its early tests need fewer features than `integral_types.d`,
  `expressions.d`, `diagnostics.d`, or broader modules.
- After each slice, run `dub test -- --random` to catch regressions.

## Assumptions

- AST-first execution is the baseline; no intermediate form is
  planned.
- The executor targets unittest latency, not long-running throughput.
- Eval is the cheapest first backend surface for both IR and the tree
  walker. Module-backed unittest execution is still required later, but it is
  not the right first slice.
- DMD AST node types are stable at the pinned version. If a node
  shape changes, update the handler at the point of breakage.
- Templates and mixin expansions are resolved by DMD before the
  walker sees the AST; they are not a separate concern.
