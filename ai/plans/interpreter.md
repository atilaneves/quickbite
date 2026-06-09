# Plan: Tree-Walking Executor

## Summary

Walk the semantically-analysed DMD AST directly and execute it in a
single recursive descent, with no lowering pass and no intermediate
representation. The goal is to reach CTFE parity on the language
surface covered by the existing test suite, driven first by the
simplest existing `eval` tests and then by similarly small CTFE-only
tests promoted one at a time to the tree-walking backend.

Rename the backend from `Interpreter` to `Interpreter` as the supported
interpreter surface grows. Keep any compatibility aliases or test-matrix
transitions narrow and temporary; the long-term public backend name should be
`Interpreter`, not `Interpreter`.

The process mirrors the IR backend: pick the simplest test that does
not yet run under the tree walker, add the tree-walking backend to it,
confirm it is red, implement the smallest handler that makes it green,
then move on. Do not add implementation beyond what a failing test
demands.

When a test passes without any implementation change, do not assume
the feature works. Mutate the test or the production code to confirm
the passing result would become a failure under a meaningful change.
Only then accept the slice as done.

Run each promoted-test slice through a serial subagent. Spawn one
subagent for exactly one promoted test, let it work in the shared PR
worktree, review and integrate its result, then commit that slice before
spawning the next subagent. Use one commit per promoted test, including
test-only promotions that only required signal verification. These
subagent tasks are usually well contained, so default workers to
`gpt-5-mini`; still require enough reasoning budget to inspect the DMD
AST failure, identify the missing interpreter feature, and implement the
smallest honest handler rather than hard-coding the fixture.

## Architecture

- Implement `Interpreter.eval` first. It may parse an expression through
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

Promote CTFE-backed test modules in the order documented by
`ai/plans/backend-test-modules-order.md`. Start with
`tests/ut/backends/lang/eval.d`, because those tests exercise the
smallest backend surface: parse an expression or tiny eval cell, walk it, and
return one `Value`. Prefer integer literals first, then simple arithmetic, then
the next eval behavior with the fewest required D language features. Once the
first integer literal slice is green, keep the eval roadmap covering all D
integer scalar types (`byte`, `ubyte`, `short`, `ushort`, `int`, `uint`,
`long`, and `ulong`) before treating integer scalar preservation as complete.

Only migrate or promote tests from one test module per PR. Within that
module, keep each promoted test as its own subagent slice and commit, but do
not add interpreter coverage in a second test module until a follow-up PR.

After the existing eval tests are done, do not jump to an entire broad
language file. Identify the next similarly simple test by counting the
required language features in the fixture and choosing the smallest delta from
the tree walker's current support. The shared module order is only a module
ranking; within a module, start with the smallest individual tests before
call-based, short-circuit, aggregate, diagnostic, or integration cases.

Do not pick a CTFE-only test at random just because it currently lacks
`Interpreter`. Before migrating one test, inspect the fixture and choose
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

Current progress: all tests in `tests/ut/backends/lang/eval.d` are
covered by `Interpreter`, including `stringLiteralIsArray`. Keep future eval
work focused on regressions or newly added CTFE-backed eval behaviours.

When promoting one eval test, isolate that test in its own `static
foreach` backend block if the surrounding block contains later eval
tests. If the test is now expected to run on both CTFE and Interpreter,
change `backends` to `backendsWith!Interpreter` (or equivalent) so it
is explicitly visible in the module matrix. Avoid creating ad-hoc
`AliasSeq!(Interpreter)` blocks for promoted shared-surface tests.
When integrating worker commits, check that earlier Interpreter
promotions remain present; a later worker must not move a previously
promoted test back to CTFE-only coverage.

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

Current progress in `tests/ut/backends/lang/logic.d`:
All current logic tests are covered by `Interpreter`. Before doing more logic
work, verify the current file still has an unpromoted `backends` block. If it
does not, leave `logic.d` alone and choose the next smallest current candidate
from the shared module order.

Do not trust this progress note as an edit target. Confirm the named test's
enclosing backend matrix before promoting it; if it already uses
`backendsWith!Interpreter`, it is historical progress, not the next slice.

Current next-candidate note: after verifying `logic.d` has no CTFE-only
`Interpreter` gaps, inspect `integrals.d` and `api/runner.d` but do not
promote their first remaining tests unless they are genuinely smaller than the
diagnostics candidates. In the current checkout, `integrals.d` combines
aliases, enum constants, typed casts, locals, and parameterized calls, while
`api/runner.d` quickly reaches runner summary/result behavior. The next
plausible interpreter slice is therefore
`diagnostics.voidFunctionReturnsToCaller`, provided its enclosing matrix still
excludes `Interpreter` when the work starts. If that promotion is already green,
verify signal by mutating the relevant interpreter call/return behavior, then
revert the mutation before accepting a test-only slice.

Module-backed interpreter support remains intentionally narrow:
direct free-function calls with evaluated arguments, `in`/`ref` parameter
binding, return statements, comma-expression sequencing, local bool
declarations, typed scalar default values, unary `!`, equality failure
messages, truthiness, and DMD-lowered logical-not and logical-and temporaries
in assertion messages exist only because promoted logic and diagnostics tests
required them. Logical `&&` and `||` short-circuiting exists only for the
promoted local and zero-argument free-call cases. Do not generalize methods,
assignment, control flow, or assertion formatting until a promoted test forces
that behaviour.

Runner progress: `runTests.runsAttributedUnittests` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. This required only
the narrow assertion-message fix for DMD-lowered equality assertions where the
generated boolean helper would otherwise report `true != true` instead of the
original integer operands.

Runner progress: `runTests.runsAttributedThrowingUnittests` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. This required only
narrow module-backed `throw new Exception("...")` support for string-literal
messages.

Runner progress: `runTests.importPathsRetryAfterFailure` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. It was already
green through the existing parse-with-import-paths runner path and folded
integer assert handling; signal was verified by temporarily mutating the module
interpreter integer expression handler.

Runner progress:
`runTestSummary.countsAttributedPassingAndFailingUnittests` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. This required only
narrow summary counting over attributed unittests, with pass/fail totals
derived by running each unittest and continuing after assertion failures.

Runner progress: `runTestSummary.countsAllPassingUnittests` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. It was already
green through existing summary counting; signal was verified by temporarily
mutating the Interpreter summary pass counter.

Runner progress: `runTestSummary.countsAssertErrorsAsFailures` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. It was already
green through existing throw-statement and summary failure counting; signal was
verified by temporarily mutating the Interpreter throw-statement handler.

Runner progress: `runTestResults.reportsDmdUnittestSymbolNames` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. This required only
narrow structured result cases with DMD unittest symbol names and pass/fail
summary counts; file-backed locations remain for the next runner slice.

Runner progress: `runTestResults.reportsFileBackedUnittestLocations` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. This required only
filling structured result locations from each DMD unittest declaration's
source location.

Runner progress: `runModulesTests.runsBothModules` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. It was already
green through existing `runModulesTests` iteration and Interpreter
module-backed `runTests`; signal was verified by temporarily returning after
the first module.

Runner progress: `runBackendSourceFixtureTests.withImportPaths` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. It was already
green through the existing parse-with-import-paths fixture path and narrow
direct free-function call handling; signal was verified by temporarily
disabling the Interpreter `call.f` dispatch.

Runner progress: `runBackendFileFixtureTests.withImportPaths` in
`tests/ut/backends/api/runner.d` now runs on `Interpreter`. It was already
green through the existing parse-file-with-import-paths fixture path and narrow
imported free-function call handling; signal was verified by temporarily
disabling both Interpreter direct free-function call dispatch paths. All
current `runner.d` backend-matrix tests now cover `Interpreter`.

Runtime cstdlib progress: `malloc` in
`tests/ut/backends/runtime/cstdlib.d` now runs on `Interpreter`. The test is
covered by the same unsupported external-source diagnostic as CTFE; the
interpreter intentionally does not execute `malloc` or model C heap memory for
this slice.

Arrays progress: `arrayLength` in `tests/ut/backends/lang/arrays.d`
now runs on `Interpreter`. This required narrow module-backed
`ArrayLiteralExp` evaluation into `Value.arrayValue` and `ArrayLengthExp`
evaluation returning the array length as `size_t`.

Arrays progress: `emptyArrayLength` in `tests/ut/backends/lang/arrays.d`
now runs on `Interpreter`. It was already green through the same array literal
and length support as `arrayLength`; signal was verified by temporarily
mutating the active `ArrayLengthExp` handler.

Arrays progress: `ubyteArrayIndexRead` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. This required
read-only `IndexExp` evaluation over `Value.arrayValue` elements; array
writes, slices, append, and index diagnostics remain unpromoted.

### Math Slice Lessons

Math progress: `evaluatesRuntimePowDoubleInputsFailureMessage.0` and
`.1` in `tests/ut/backends/lang/math.d` now run on `Interpreter` as
PASSING tests. Because the Interpreter formats double assert messages
correctly (producing "16 != 17" and "3 <= 3.001"), these tests pass
without `@ShouldFail`. The user approved a split: the two existing
`@ShouldFail` unittests inside the `static foreach (backend; backends)`
block remain as-is (CTFE keeps `@ShouldFail` for `<double not
supported>`); a separate adjacent block
`static foreach (backend; imported!"std.meta".AliasSeq!(Interpreter))`
contains copies of those two tests with identical bodies and label
names but without `@ShouldFail`. No production change was required —
the pow infra already existed from the `evaluatesRuntimePowDoubleInputs`
slice.

Math progress: `evaluatesRuntimePowDoubleInputs` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. Three production
changes were required:

1. **`RealExp` in `EvalModuleInterpreter`** — The module interpreter's
   `runExpression` lacked a `RealExp` branch (floating-point literals such
   as `2.0`). Added `realValue` dispatch mirroring the existing
   `EvalFunctionWalker` handler.

2. **`pow` builtin dispatch in `EvalModuleInterpreter`** — The module
   `runCallExpression` had no builtin check before calling `runFunction`.
   Added an inline `isBuiltin`/`BUILTIN.pow`/`BUILTIN.fabs` switch at the
   top of `runCallExpression`, mirroring the pattern already in
   `EvalFunctionWalker.runCallExpression`.

3. **Floating-point ordering comparisons** — `runComparisonExpression`
   used `asLong` for both operands, which throws for `double` values.
   Added `asReal() const @safe pure` to `quickbite.lang.Value` (returns
   the stored value widened to `real`, covering both integer and
   floating-point scalars), then switched `runComparisonExpression` to use
   `asReal` instead of `asLong`.

Math progress: `doesNotTreatUserNamedPowAsMathIntrinsic` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. It was already
green through the existing direct free-function call path; signal was
verified by temporarily mutating the module interpreter's `call.f` dispatch
to return the first `pow` argument instead of executing the user-defined
function, which failed the focused test with `2 != 6`.

Math progress: `doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter addition to
subtraction, which failed the focused test with `-2 != 7` instead of `6 != 7`.

Math progress: `doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter addition to
subtraction, which failed the focused test with `-1 != 8` instead of `7 != 8`.

Math progress: `evaluatesRuntimeSqrtInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. This required
extracting Interpreter builtin dispatch into
`source/quickbite/backends/interpreter/builtins.d` and adding narrow
module-backed handling for DMD's `BUILTIN.sqrt`, evaluating one argument and
applying `std.math.sqrt` through the existing floating `Value` helper.

Math progress: `evaluatesRuntimeSqrtInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test with `9 != 4` instead of `3 != 4`.

Math progress: `evaluatesRuntimeSqrtInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test with `25 != 6` instead of `5 != 6`.

Math progress: `evaluatesDifferentRuntimeSqrtInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating Interpreter
`sqrt` to call `fabs`, which failed the focused test with `16 != 4`.

Math progress: `evaluatesDifferentRuntimeSqrtInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test with `16 != 5` instead of `4 != 5`.

Math progress: `evaluatesDifferentRuntimeSqrtInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test with `36 != 7` instead of `6 != 7`.

Math progress: `evaluatesRuntimeNonIntegerSqrtInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating Interpreter
`sqrt` to call `fabs`, which failed the focused test with `2.25 != 1.5`.

Math progress: `evaluatesRuntimeNonIntegerSqrtInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test with `2.25 != 2.5` instead of
`1.5 != 2.5`.

Math progress: `evaluatesRuntimeNonIntegerSqrtInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test with `6.25 != 3.5` instead of
`2.5 != 3.5`.

Math progress: `evaluatesRuntimeNonPerfectSqrtInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating Interpreter
`sqrt` to call `fabs`, which failed the focused test with `2 >= 1.415`.

Math progress: `evaluatesRuntimeNonPerfectSqrtInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test because the expression no longer
threw.

Math progress: `evaluatesRuntimeNonPerfectSqrtInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `sqrt` to
call `fabs`, which failed the focused test with `2 >= 1.414` instead of
`1.41421 >= 1.414`.

Math progress: `evaluatesRuntimeFabsDoubleInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating Interpreter
`fabs` to call `sqrt`, which failed the focused test with `-nan != 3.5`.

Math progress: `evaluatesRuntimeFabsDoubleInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `fabs` to
call `sqrt`, which failed the focused test with `-nan != 4.5` instead of
`3.5 != 4.5`.

Math progress: `evaluatesRuntimeFabsDoubleInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `fabs` to
call `sqrt`, which failed the focused test with `-nan != 13.25` instead of
`12.25 != 13.25`.

Math progress: `evaluatesRuntimeFabsPositiveDoubleInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating Interpreter
`fabs` to call `sqrt`, which failed the focused test with `2.78388 != 7.75`.

Math progress: `evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `fabs` to
call `sqrt`, which failed the focused test with `2.78388 != 8.75` instead of
`7.75 != 8.75`.

Math progress: `evaluatesRuntimeFabsPositiveDoubleInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
The CTFE `@ShouldFail` copy remains in the `backends` block for the upstream
double formatter limitation; the Interpreter copy is split into an adjacent
Interpreter-only block without `@ShouldFail`. No production change was
required. Signal was verified by temporarily mutating Interpreter `fabs` to
call `sqrt`, which failed the focused test with `3.08221 != 10.5` instead of
`9.5 != 10.5`.

Math progress: `evaluatesRuntimeIsNaNDoubleInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating Interpreter
logical-not handling, which failed the focused test with `false != true`.

Math progress: `evaluatesRuntimeIsNaNDoubleInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. This required
extending `assert(!expr)` failure messages to bool-typed expressions, so
`assert(!isNaN(notANumber))` reports `true == true` instead of the lowered
boolean assertion message `false != true`.

Math progress: `evaluatesRuntimeIsNaNDoubleInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating the
Interpreter bool assertion formatter, which failed the focused test with
`false != false` instead of `false != true`.

Math progress: `evaluatesRuntimeIsInfinityDoubleInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. This required
adding `std.math.isInfinity` to the Interpreter builtins module so the backend
does not fall through into unsupported druntime expression interpretation.

Math progress: `evaluatesRuntimeIsInfinityDoubleInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily routing Interpreter
`isInfinity` through `isNaN`, which made the focused test fail because the
fixture no longer threw.

Math progress: `evaluatesRuntimeIsInfinityDoubleInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily routing Interpreter
`isInfinity` through `fabs`, which failed the focused test because the fixture
no longer threw.

Math progress: `evaluatesRuntimeSignbitDoubleInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. This required
adding narrow `std.math.signbit` handling to the Interpreter builtins module.

Math progress: `evaluatesRuntimeSignbitDoubleInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily routing Interpreter
`signbit` through `fabs`, which failed the focused test with `0 != 0` instead
of `1 != 0`.

Math progress: `evaluatesRuntimeSignbitDoubleInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily making Interpreter
`signbit` return `1`, which failed the focused test because the fixture no
longer threw.

Math progress: `evaluatesRuntimeSignbitNanInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily routing Interpreter
`signbit` through `fabs`, which failed the focused test with `nan != 0`.

Math progress: `evaluatesRuntimeSignbitNanInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily routing Interpreter
`signbit` through `fabs`, which failed the focused test with `nan != 0`
instead of `1 != 0`.

Math progress: `evaluatesRuntimeSignbitNanInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily routing Interpreter
`signbit` through `isNaN`, which failed the focused test because the fixture
no longer threw.

Math progress: `doesNotTreatUserNamedIsNaNAsMathIntrinsic` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily treating any function
named `isNaN` as the Interpreter math builtin, which failed the focused test
with `false != true`.

Math progress: `doesNotTreatUserNamedIsNaNAsMathIntrinsicFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
No production change was required. Signal was verified by temporarily treating
any function named `isNaN` as an Interpreter math builtin, which failed the
focused test because the fixture no longer threw the expected `true == true`
assertion message.

Math progress: `doesNotTreatUserNamedIsNaNAsMathIntrinsicFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING test.
No production change was required. Signal was verified by temporarily mutating
the promoted Interpreter expectation, which failed the focused test with
`true == true` instead of `false != true`.

Math progress: `callsUserNamedIsNaNForNanInput` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating the promoted
Interpreter expectation, which failed the focused test with `false != true`.

Math progress: `callsUserNamedIsNaNForNanInputFailureMessage.0` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating the promoted
Interpreter expectation, which failed the focused test with `false != true`.

Math progress: `callsUserNamedIsNaNForNanInputFailureMessage.1` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily mutating the promoted
Interpreter expectation, which failed the focused test with `false != true`.

Math progress: `doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsics` in
`tests/ut/backends/lang/math.d` now runs on `Interpreter`. No production
change was required. Signal was verified by temporarily making the
Interpreter direct user-function call path return the first argument, which
failed the focused test with `9 != 10`.

Math progress: `doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsicsFailureMessage.0`
in `tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING
test. No production change was required. Signal was verified by temporarily
mutating the promoted Interpreter expectation, which failed the focused test
with `10 != 11`.

Math progress: `doesNotTreatUserNamedSqrtOrFabsAsMathIntrinsicsFailureMessage.1`
in `tests/ut/backends/lang/math.d` now runs on `Interpreter` as a PASSING
test. No production change was required. Signal was verified by temporarily
mutating the promoted Interpreter expectation, which failed the focused test
with `11 != 12`. No current `math.d` backend-matrix tests still exclude
`Interpreter`.

REPL progress: `repl.backend.evaluatesExpressionCellsUntilQuit` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This required only
expression-cell `evalRepl` dispatch through the existing eval function walker.

REPL progress: `repl.backend.functionDeclarationsPersistWithoutSemicolon` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This only needed the
existing direct free-function call path plus the integer multiplication fix in
the function walker.

REPL progress: `repl.backend.skipsCommentOnlyLines` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through the shared REPL loop comment filter; signal was verified by temporarily
disabling that filter.

REPL progress: `repl.backend.evaluatesStandaloneMixinExpression` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through existing expression-cell `evalRepl` dispatch; signal was verified by
temporarily forcing Interpreter REPL expression cells to return `0`.

REPL progress: `repl.backend.declarationCellsPersistWithoutDisplay` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This required only
executing no-display EvalCells through the existing eval function walker and
returning `Value.void_` so the REPL suppresses display.

REPL progress: `repl.backend.expressionSideEffectsPersist` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This required only
narrow local-variable postfix `++` support in the eval function walker so a
single REPL session can persist `int x;`, `x++`, then `x`.

REPL progress: `repl.backend.statementsExecuteImmediately` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through existing no-display EvalCell execution and narrow local-variable
increment-assign support; signal was verified by temporarily disabling the
Interpreter increment-assign handler.

REPL progress: `repl.backend.userDefinedFunctionDoesNotCollideWithWrapper` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This needed the
REPL-only zero-argument direct call path plus the existing addition dispatch in
the eval walker; signal was verified with the focused slice and the random
suite.

REPL progress: `repl.backend.templateFunctionDeclarationsPersistWithoutDisplay`
in `tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already
green through existing direct free-function call dispatch over DMD's
instantiated function template; signal was verified by temporarily changing the
promoted test expectation.

Arrays progress: `arrayLengthFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing array-length expression support and equality assertion
message formatting; signal was verified by temporarily mutating the
Interpreter array-length handler.

Arrays progress: `arrayLengthFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing array-length expression support and equality assertion
message formatting; signal was verified by temporarily mutating the
Interpreter array-length handler.

Arrays progress: `emptyArrayLengthFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing empty array literal, array-length expression, and
equality assertion message support; signal was verified by temporarily
mutating the Interpreter array-length handler.

Arrays progress: `emptyArrayLengthFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing nonempty array literal, array-length expression, and
equality assertion message support; signal was verified by temporarily
mutating the active Interpreter array-length handler.

Arrays progress: `ubyteArrayIndexReadFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing read-only array indexing and equality assertion message
support; signal was verified by temporarily mutating the Interpreter
`IndexExp` handler.

### Implementation Review Notes

**Finding 4 — `StringExp` handled in `EvalFunctionWalker` but absent from
`EvalModuleInterpreter`.**
`EvalFunctionWalker` converts `StringExp` to a `char[]` array `Value` (covers
the `stringLiteralIsArray` eval test). Before promoting any logic or
diagnostics test that involves string values, verify module-backed string
literal signal with the containing module's first follow-up PR. If that
promotion is already green, verify signal by mutating the relevant interpreter
handler, then revert the mutation before accepting a test-only slice.

**Finding 2 — Completed: top-level eval uses one expression walker.**
`Interpreter.eval()` now parses eval source into the common eval function
wrapper and runs it through `EvalFunctionWalker`. The stale standalone
`evalExpression()` helper has been removed, so top-level eval no longer has a
second, narrower expression dispatch table that can diverge from multiline
eval coverage.

**Finding 1 — Eval unsupported statements report diagnostics.**
`EvalFunctionWalker.runStatement` now throws
`"Unsupported eval statement: <kind>"` instead of reaching `assert(0)` for the
first eval-backed unsupported statement shape covered by `eval.d`. Remaining
`assert(0)` calls are outside this eval-only PR: unimplemented Backend API
stubs (`evalRepl`, `runTestResults`, `runTestSummary`), eval expression
invariants that still need a reachable `eval.d` signal, and module-backed
interpreter paths that belong to a follow-up PR for their containing test
module.

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
  changing that test's matrix to include Interpreter. For tests that should
  stay on both CTFE and Interpreter, prefer `backendsWith!Interpreter` (or
  equivalent) over adding a separate `AliasSeq!(Interpreter)` block.
  This exception only covers adding the backend to an existing backend-
  matrix test; adding a new test or modifying test behaviour still
  requires approval before editing the test.
- Before promoting any named test from this plan, verify in the current
  checkout that its enclosing `static foreach` still excludes `Interpreter`.
  If the test already uses `backendsWith!Interpreter`, do not edit it; inspect
  the current tests and choose the next smallest CTFE-only named unittest.
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
  backend language modules run against CTFE, so use
  `ai/plans/backend-test-modules-order.md` to choose post-`eval` targets by
  required D language features.
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
