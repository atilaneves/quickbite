# Plan: Tree-Walking Executor

## Summary

Walk the semantically-analysed DMD AST directly and execute it in a
single recursive descent, with no lowering pass and no intermediate
representation. The goal is to reach CTFE parity on the language
surface covered by the existing test suite, driven first by the
simplest existing `eval` tests and then by similarly small CTFE-only
tests promoted one at a time to the tree-walking backend.

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
- Leave `evalRepl`, broader parsed-test execution, and test-summary
  behavior alone until an approved test specifically requires them.
- Walk `FuncDeclaration` and `UnitTestDeclaration` AST nodes for
  unittest bodies; dispatch to statement and expression handlers by
  dynamic type only after eval coverage has forced enough expression
  support to make parsed tests the next smallest step.
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
language features.

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
increment; one direct function call; then parsed unittest assertions.
Defer imports, assertion context formatting, control flow, arrays,
structs, exceptions, pointers, delegates, and diagnostics until simpler
tests stop being available.

### First PR Guardrails

The first PR must be smaller than a general-purpose interpreter slice.
Do not promote a parsed unittest test that needs locals, declarations,
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
  walker. Parsed unittest execution is still required later, but it is
  not the right first slice.
- DMD AST node types are stable at the pinned version. If a node
  shape changes, update the handler at the point of breakage.
- Templates and mixin expansions are resolved by DMD before the
  walker sees the AST; they are not a separate concern.
