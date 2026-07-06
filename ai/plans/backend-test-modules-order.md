# Backend Test Module Order

This order ranks the shared backend behaviour modules by the amount of D
language surface a new backend must implement before the whole module can pass.
Use it when choosing which existing tests to promote to a backend.
`SystemLinker` (compiled D) is the oracle for these modules
(`ai/plans/single-oracle.md`); `Ctfe` is a fixture source, not an oracle.

This is the shared ordering companion for backend-specific plans. New backend
plans should be able to reuse this order without changing this file.
Backend-specific plans should reference this file by path instead of copying
this order into their own documents.

Scores are approximate and intentionally relative. A lower score means the
module should usually be promoted before a higher-scored module. Within a
module, still promote one named unittest, or one tightly-related family of
unittests, at a time.

## How To Use This Order

Use this file to choose the next module to inspect, not to blindly promote a
whole module. For each backend, read the backend-specific architecture plan
first, then use this module order as the shared language-surface roadmap.

Backend-specific progress notes can go stale. Before editing a test matrix,
search for the named candidate in the current checkout and verify its
enclosing `static foreach` still excludes the target backend. If the candidate
is already covered, treat the note as historical progress and choose the next
smallest current candidate from the files, not from the stale text.

Start with the earliest module whose remaining not-yet-promoted tests can be
promoted honestly through the target backend's real pipeline. If a backend
plan has
entry-point slices before it can join the shared language matrix, finish those
first, then use this order for shared behavior coverage.

Within the selected module:

- Pick the smallest named unittest that is not yet covered by the target
  backend in the current checkout.
- Prefer tests that require one new language feature or one small diagnostic
  behavior.
- Defer tests that combine calls, imports, control flow, aggregates,
  diagnostics, pointers, delegates, exceptions, or integration behavior when a
  smaller test remains available.
- Promote one named unittest, or one tight family of failure-message tests, by
  adding the target backend to that test's backend list.
- Confirm the promoted test is red for the target backend before implementing
  production code.
- Make the smallest honest backend change that turns the promoted test green.

There is no global `backends` matrix any more. Each test block lists its
backends explicitly with `static foreach (backend; AliasSeq!(...))`. Promoting
a test means adding the target backend type to that one block's `AliasSeq`,
not broadening an entire file at once.

Adding a backend to an existing shared behaviour test is a backend promotion,
not a new behavior test. Adding a new test or changing expected behavior still
needs the normal test-approval stop.

| Order | Difficulty | Module |
| ---: | ---: | --- |
| 1 | 3.0 | `tests/ut/backends/evaluator/eval.d` |
| 2 | 3.5 | `tests/ut/backends/runner/rt/cstdlib.d` |
| 3 | 4.0 | `tests/ut/backends/runner/ct/integrals.d` |
| 4 | 5.0 | `tests/ut/backends/runner/ct/logic.d` |
| 5 | 5.5 | `tests/ut/backends/runner/results.d` |
| 6 | 6.5 | `tests/ut/backends/runner/ct/diagnostics.d` |
| 7 | 7.0 | `tests/ut/backends/runner/ct/math.d` |
| 8 | 8.0 | `tests/ut/backends/runner/ct/arrays.d` |
| 9 | 8.5 | `tests/ut/backends/runner/ct/structs.d` |
| 10 | 9.0 | `tests/ut/backends/runner/ct/control_flow.d` |
| 11 | 9.5 | `tests/ut/backends/runner/ct/exceptions.d` |
| 12 | 10.0 | `tests/ut/backends/runner/ct/expressions.d` |
| 13 | 10.0 | `tests/ut/backends/runner/ct/cerealed.d` |
| 14 | 10.5 | `tests/ut/bin/repl.d` |

Re-graded 2026-06-15 against the current checkout. The order still holds, and
observed backend breadth now decreases monotonically as the difficulty score
rises, which corroborates the ranking. Modules ranked 1-7 run on several
backends (four to six, spanning `Ctfe`, `Interpreter`, `Bytecode`,
`BytecodeNewCore`, `IR`, and `SystemLinker`). Since the 2026-06-10 grading,
`SystemLinker` (and in places `Interpreter`) has been promoted across the
formerly `Ctfe`-only tail: `arrays.d` and `structs.d` (8-9) now run mostly on
`Ctfe`, `Interpreter`, and `SystemLinker`; `control_flow.d`, `exceptions.d`,
`expressions.d`, and `cerealed.d` (10-13) now run mostly on `Ctfe` and
`SystemLinker`, with diverging diagnostic-message tests split into per-backend
variants. The REPL module still runs its early session-state tests on three
backends (`Ctfe`, `Interpreter`, `Bytecode`) but has added `Interpreter` to its
Phobos and display-format tests, so only the Bytecode-incompatible cases remain
on `Ctfe`/`Interpreter` rather than `Ctfe` alone.

## Classification Notes

- `eval.d`: Direct `eval`, scalar values, literals, arithmetic, unary ops,
  casts across every scalar width with type preservation, simple multi-cell
  declarations and mutation, string literals, and `std.math` `fabs`/`pow`
  return-type behavior.
- `cstdlib.d`: A single `malloc`/`free` test whose only backend requirement is
  to fail when a called function has no available body; the pointer casts,
  indexing, and `scope(exit)` in the source are never reached. Asserts the
  diagnostic that such a function cannot be interpreted at compile time. Gated
  by `runner`'s unittest-execution surface and `core.stdc` import resolution,
  not by any pointer behavior.
- `integrals.d`: All integral widths and signedness, runtime casts and
  truncation/wrapping, typed locals, aliases, function parameters and returns,
  and signed/unsigned assertion-message formatting.
- `logic.d`: Boolean and non-boolean truthiness, `!`, `&&`, `||`,
  short-circuiting (including division-by-zero guards), comparisons inside
  logical expressions, operand calls, and an extensive assertion-message
  oracle covering both `x != y` and `` `assert(expr)` failed `` forms.
- `runner/results.d`: Module-backed unittest execution, attributed unittests,
  `throw new Exception` from a unittest (class construction plus unwinding to
  the runner), import paths for source and file fixtures, multiple modules,
  assertion failure handling, summary counts, DMD unittest symbol names, and
  source/file locations.
- `diagnostics.d`: DMD-like assertion messages for every comparison operator,
  explicit and dynamic assert messages, simple `if`/`else`, `in` and `ref`
  parameters, many-parameter calls, null class method/field/`typeid`
  diagnostics, and uninitialized (`= void`) scalar-read diagnostics.
- `math.d`: `std.math` imports and intrinsic-like calls (`pow`, `sqrt`,
  `fabs`, `isNaN`, `isInfinity`, `signbit`); NaN, infinity, `double.max`, and
  signed-zero semantics; user functions shadowing intrinsic names; and
  floating assertion diagnostics including DMD's rounding of displayed values.
- `arrays.d`: Dynamic and static arrays, indexing, writes, `.length` reads and
  resizing assignment, append, concatenation, runtime-bound slices, slice and
  block assignment with overlap rejection, array-wise element ops, nested
  arrays, associative arrays (`in`, `.keys`, `.values`, `.remove`, `.dup`,
  missing-key diagnostics), `new T[]` including multidimensional, bounds
  diagnostics, `ref` array parameters, pointer arithmetic, comparisons, and
  slicing with out-of-block diagnostics, and string copying.
- `structs.d`: Struct layout, default initialization, field access and writes,
  by-value copy semantics including shared array descriptors, methods,
  constructors, `this` mutation, template methods, `ref` parameters, dynamic
  and static array fields, returns, `new Struct`, `with` on structs and enums
  (including `goto` inside the body), destructors, postblits, and nested
  structs capturing enclosing locals.
- `control_flow.d`: `if`, `while`/`for`/`do-while`, `foreach` over arrays,
  ranges, and `AliasSeq`, `foreach_reverse`, UTF-8/16/32 string decoding and
  re-encoding during iteration, `break`, `continue`, labels, `switch`,
  `goto case`/`goto default` with runtime selectors, direct `goto`, `goto`
  restarting statements from inside `try`/`finally` and `catch` handlers
  (which forces early exception-handling machinery), and function pointers.
- `exceptions.d`: `new Exception` and user subclasses calling `super`, throw
  statements and expressions, uncaught-exception reporting, `try`/`catch`,
  class matching across multiple handlers, catch binding and member access,
  propagation across calls and branches with `ref` side effects preserved,
  unwinding, `finally` ordering, return-value capture before `finally`,
  `goto` in bodies and handlers, and exception chaining via `.next`.
- `expressions.d`: Broad expression runtime including arithmetic, bitwise ops,
  shifts, comparisons, compound assignment, comma expressions, increment and
  decrement, integer wrapping, mixed signed/unsigned/floating comparisons,
  `real` precision, complex literals, hex-string casts, slice/pointer/`void*`
  casts, `new`, classes, inheritance, virtual/interface dispatch, `typeid`,
  delegates, closures, member delegates, and vector splats under an SSE2
  target.
- `cerealed.d`: Integration stress coverage combining arrays,
  structs, methods, `ref` cursors, post-increment indexing, templates with
  `is(T == ...)` constraints, loops, bit packing and shifts, casts, enum round
  trips, nested arrays, associative arrays, pointers, `new`, static arrays,
  input range-style properties, overload resolution, bounds diagnostics, and
  float bit reinterpretation through pointer casts.
- `tests/ut/bin/repl.d` (the table's row 14; an earlier draft called it
  `bin/repl/package.d`): Persistent multi-cell session state, expression and
  no-display cells, statements, multi-line declaration buffering, functions,
  templates, structs, enums, mixin expressions, `typeof` and type-alias
  cells, `import std` with Phobos range pipelines (`map`/`filter`/`array`),
  display formatting for scalars with D literal suffixes, strings (narrow and
  wide), arrays, associative arrays, enums, ranges, and function literals,
  special-token (`__FILE__` etc.) rewriting, loaded unittest execution with
  `<repl>` and file location rewriting, and synthetic-wrapper-name cleanup in
  diagnostics. The full module is the largest surface in the suite even
  though its session-state slice is small.

## Not Behavior Targets

`tests/ut/backends/package.d` is promotion plumbing, not a behavior target: it
defines `newBackend` and the `runBackend*Fixture*` helpers. It does not
execute any test itself, and it no longer defines a `backends` matrix or
`backendsWith` — backend lists live in each test block's `AliasSeq`.

`tests/ut/backends/evaluator/value.d` tests the `Value` type directly with no
backend parameterization. It is shared infrastructure every backend relies on,
not a module to promote. (It is also scheduled for deletion together with the
shared `Value` struct — `value.md` remaining-work item 3.)

## Staleness note (2026-07-06)

Three `ct/` modules postdate the last grading and are absent from the table:
`archive.d` (static-archive linking; infrastructure more than language
surface), `pollution.d` (module-isolation/scapegoat-root pollution;
infrastructure), and `imports.d` (import resolution). Grade or explicitly
exclude them on the next table update. The grading notes also predate
`LLVMJit`'s promotion to the matrix (2026-06-15); backend-breadth commentary
should account for it.
