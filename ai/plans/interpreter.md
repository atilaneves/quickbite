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

## Current Status

As of 2026-06-17, the ordered module-promotion campaign from
`ai/plans/backend-test-modules-order.md` is complete for the current checkout.
All current oracle-backed backend-matrix tests in the ordered modules now
either include `Interpreter` or are deliberately split into a CTFE
characterization / runtime-only / compiled-only block. The merged suite has no
known failing `Interpreter` tests.

The `Interpreter` is now a first-class user-facing backend as well as a test
backend:

- the REPL CLI can select `Interpreter` with `--backend=interpreter`; `ctfe`
  remains the default when no backend is specified;
- the benchmark driver registers `interpreter`;
- default benchmark runs include `ctfe`, `interpreter`, `system-linker`, and
  `llvmjit` unless the user narrows the set with `-b` / `--backend`.

Remaining work is no longer "promote the next module" by default. Treat future
interpreter work as one of these categories:

- newly added oracle-backed tests that do not yet include `Interpreter`;
- mutation-based signal verification for older bulk promotions that were kept
  green without individual proof;
- cleanup of historical notes in this file after confirming they are
  superseded by current tests;
- intentional non-target decisions for CTFE characterizations, runtime-only
  native tests, and linker/codegen pollution tests.

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
  promoted test only observes integer or boolean behaviour. Per
  `ai/plans/value.md` (decision 2026-06-17) this boxed representation is
  the interpreter's own and is slated to become interpreter-package-private
  as the shared `quickbite.lang.Value` is dismantled — it is not being
  removed from the interpreter, only un-shared. The bytecode VM, by
  contrast, stays native-layout and uses no boxed value.
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
green through the existing parse-file-with-import-paths fixture path and
narrow imported free-function call handling; signal was verified by
temporarily disabling both Interpreter direct free-function call dispatch
paths. All current `runner.d` backend-matrix tests now cover `Interpreter`.

Control-flow module probe:
`tests/ut/backends/runner/ct/control_flow.d` was promoted wholesale to
`Interpreter` on branch `interpreter-next-module`. The focused run
`bin/ut $(bin/ut -l | rg
'^ut\.backends\.runner\.ct\.control_flow\..*Interpreter$')` ran 65
interpreter cases: 33 passed and 32 failed. The passing promoted surface
already includes ordinary free-function calls, parameters, `in` and `ref`
parameters, explicit returns, default arguments, overload resolution, basic
`if`/`else`, simple `while`/`do`/`for` loops without control-transfer, and
simple array/range foreach.

Failure causes from that first focused run:

- `continue` and `break` need structured loop control, not plain unsupported
  statements. Failures include `for.continue`,
  `doWhile.breakAndContinue`, labelled loop break/continue, and foreach tuple
  break/continue.
- `switch`/`case`/`default`, including `goto case` and `goto default`, are
  still unsupported interpreter statements. All switch cases in the module
  fail with `Unsupported eval statement: Switch`.
- Direct `goto` currently records a target but does not restart compound
  traversal robustly enough for the module's restart-point tests, and
  `try`/`finally`/`catch` goto variants still only execute the happy body path.
- Struct member `return` currently marks the caller as returned; method-return
  control must be restored after member calls just like free-function calls.
- Function pointer tests need `FuncDeclaration` values to survive assignment,
  equality, and call dispatch through the interpreter.
- UTF string foreach tests need D's foreach decoding/encoding semantics for
  `char`/`wchar`/`dchar` strings; simple array and range foreach already pass.

Loop-control progress: `for.continue`, `doWhile.breakAndContinue`,
`labeledBreak.exitsOuterForLoop`,
`labeledContinue.skipsToOuterForIncrement`, and
`foreach.expressionTupleBreakAndContinue` now pass on `Interpreter` through
structured `break`/`continue` state in the walker.

Member-return progress:
`function.structMethodReturnDoesNotSkipCallerStatements` now passes on
`Interpreter`. The method body's `return;` remains isolated to the child
walker, and the caller reaches the following unittest-body `assert(false)`,
which currently matches the existing Ctfe-style literal assertion
characterization.

Function-pointer progress: the three `functionPointer.*` control-flow tests
now pass on `Interpreter`. Function symbols are preserved as opaque
`Value.FunctionPointer` ids keyed by `FuncDeclaration` identity, not by name
or hash, so the hash-collision fixture dispatches to the correct callee.

UTF foreach progress: the four promoted UTF string foreach tests now pass on
`Interpreter`. The walker intercepts the DMD-lowered `_aApply*` helper calls
needed by these fixtures, decodes UTF-8/UTF-16 to `dchar`, encodes `dstring`
iteration to UTF-8 `char`, and writes back nested foreach delegate locals.

Switch progress: basic `switch` case/default selection, fallthrough,
`goto case`, `goto default`, labelled outer breaks from a switch, final switch
over enums, and try/finally goto-case/default now pass on `Interpreter`.
Remaining switch-related failures after this slice are string-case hashing
(`leftShift`) and case-range/multi-value AST handling.

Catch progress: the three `catch.gotoRestarts*` control-flow tests now pass on
`Interpreter`. Direct `throw new Exception(...)` in interpreted code is
represented separately from backend/assertion failures so `catch (Exception)`
can run its handler without swallowing test-framework failures.

Control-flow module completion: all 65 promoted
`tests/ut/backends/runner/ct/control_flow.d` `Interpreter` cases now pass in
the focused run. The final switch-tail fixes added the integer bitwise/shift
operators reached by DMD-lowered string-switch hashing and made switch target
matching handle nested case/default/case-range wrappers used by range and
multi-value case syntax.

Runtime cstdlib progress: `malloc` in
`tests/ut/backends/runtime/cstdlib.d` now runs on `Interpreter`. The test is
covered by the same unsupported external-source diagnostic as CTFE; the
interpreter intentionally does not execute `malloc` or model C heap memory for
this slice.

Runtime cstdlib promotion probe:
All remaining CTFE-only no-source diagnostics in
`tests/ut/backends/runner/rt/cstdlib.d` were promoted to also run on
`Interpreter` in branch `interpreter-rt-cstdlib-module`.

Running only the cstdlib Interpreter tests left exactly one failing promoted
test:

- `strtol.noSource.Interpreter`: the interpreter reports
  `Unsupported eval expression: symbolOffset` instead of
  `` `strtol` cannot be interpreted at compile time, because it has no
  available source code``.

Failure cause: the fixture evaluates `"123xyz".ptr` and `&endptr` as
arguments before the external `strtol` call. Unlike `malloc`, `free`,
`atoi`, and `div`, this reaches DMD's `symbolOffset` expression shape while
building the call arguments, so the interpreter fails on unsupported pointer
argument construction before it can report the no-available-source diagnostic
for the extern(C) callee. The desired slice is not host libc or pointer
execution; it is only to preserve the existing unsupported-external-call
diagnostic precedence for this promoted runtime fixture.

Resolution: direct non-member calls whose callee has no available source now
report that diagnostic before evaluating generic call arguments, after the
interpreter's builtin and runtime hook dispatch has had a chance to handle
known supported calls. The focused cstdlib Interpreter-only module run now
passes: 12 run, 0 failed.

Integrals progress:
All remaining CTFE-only backend-matrix tests in
`tests/ut/backends/runner/ct/integrals.d` were promoted to also run on
`Interpreter` in branch `interpreter-module-promotion-20260613`.

Running only the integrals Interpreter tests made the two newly promoted
overflow diagnostics crash with SIGFPE before unit-threaded could report a
normal failure:

- `int.divisionOverflowAtIntMinIsRejected.Interpreter`
- `int.moduloOverflowAtIntMinIsRejected.Interpreter`

Failure cause: the interpreter's `DivExp` and `ModExp` paths evaluated
`int.min / -1` and `int.min % -1` with native D integer operators before
checking D's CTFE overflow diagnostic case. On x86_64 this raises SIGFPE,
matching why native runtime backends stay excluded. The interpreter now guards
exactly the signed 32-bit `int.min`/`-1` division and modulo cases and throws
the same diagnostic strings expected by the existing CTFE-backed tests:
`integer overflow: `int.min / -1`` and
`integer overflow: `int.min % -1``, followed by
`cannot compare `__error` at compile time` from the surrounding comparison.
All current `integrals.d` backend-matrix tests now cover `Interpreter`.

Arrays progress:
`nestedSliceWritesPropagateToOriginalArrayFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing nested slice alias write-through; signal was verified by
temporarily disabling that write-through, which changed the promoted failure
message from `99 != 100` to `1 != 100`.

Arrays progress:
`nestedSliceWritesPropagateToOriginalArrayFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing nested slice alias write-through with accumulated slice
offsets; signal was verified by temporarily dropping the accumulated offset,
which changed the promoted failure message from `98 != 99` to `2 != 99`.

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

Arrays progress: `ubyteArrayIndexWrite` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. This required
narrow indexed assignment for local array variables by replacing one
`Value.arrayValue` element and writing the updated value back to the local;
slices, append, ref parameter mutation, and bounds diagnostics remain
unpromoted.

Arrays progress: `ubyteArrayIndexWriteFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. No production
change was required; signal was verified by temporarily mutating indexed array
assignment writeback, which changed the promoted failure message from
`42 != 43` to `0 != 43`.

Arrays progress: `ubyteArrayIndexWriteFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. No production
change was required; signal was verified by temporarily mutating indexed array
assignment writeback, which made the promoted test fail because the expected
assertion exception was no longer thrown.

Arrays progress: `ubyteArrayAppendAssign` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. This required
narrow `concatenateElemAssign` handling for appending one evaluated element to
a local dynamic array value; slices, ref parameter mutation, append-array, and
bounds diagnostics remain unpromoted.

Arrays progress: `ubyteArrayAppendAssignFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. No production
change was required; signal was verified by temporarily mutating the local
dynamic array append handler, which made this promoted failure-message test and
the existing positive append test fail.

Arrays progress: `ubyteArrayAppendAssignFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. No production
change was required; signal was verified by temporarily mutating the local
dynamic array append handler, which changed the promoted failure message from
`3 != 4` to `1 != 4`.

Arrays progress: `arrayEqualTrue` in `tests/ut/backends/lang/arrays.d`
now runs on `Interpreter`. It was already green through existing slice
evaluation and `Value.arrayValue` equality; signal was verified by temporarily
mutating `Array.opEquals`, which failed the promoted Interpreter test with
`[1, 2, 3] != [1, 2, 3]`.

Arrays progress: `arrayEqualTrueFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing slice equality and generic equality assertion message
formatting; signal was verified by temporarily mutating the Interpreter
equality operand formatter, which changed the promoted failure message to
`<mutated> != <mutated>`.

Arrays progress: `arrayEqualTrueFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing slice equality and array assertion message formatting;
signal was verified by temporarily mutating `Array.opEquals` to ignore length
differences, which made the promoted test fail because the expected assertion
exception was no longer thrown.

Arrays progress: `arrayEqualFalse` in `tests/ut/backends/lang/arrays.d`
now runs on `Interpreter`. It was already green through existing slice
equality and generic array assertion message formatting; signal was verified
by temporarily making Interpreter equality always report success, which made
the promoted fixture stop throwing the expected `[1, 2, 3] != [1, 2, 4]`
assertion message.

REPL progress:
`repl.backend.multilineStructDeclarationsBufferUntilComplete` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through existing frontend REPL buffering and eval-cell expression execution;
signal was verified by temporarily mutating the Interpreter integer literal
handler, which changed the displayed result from `42` to `41`.

REPL progress:
`repl.backend.failedBufferedDeclarationDoesNotPoisonSession` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through the shared buffered-input error recovery path; signal was verified by
temporarily removing the pending-input clear after a failed buffered
declaration, which made the final `42` submission return `void`.

REPL progress:
`repl.backend.commandsDoNotAbandonPendingInput` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through the shared pending-command guard and existing function declaration
execution; signal was verified by temporarily disabling the guard, which made
the focused test fail because `:q` no longer threw while input was pending.

REPL progress:
`repl.backend.importDeclarationsPersistWithoutDisplay` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This required narrow
REPL eval support for DMD conditional expressions and numeric comparisons,
which is the AST produced for the imported `std.algorithm.min(3, 1)` call.

REPL progress:
`repl.backend.displaysUndisplayablePlaceholderForFunctionLiterals` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This required narrow
REPL eval support for DMD function-literal expressions by returning the
existing `<undisplayable>` value.

REPL progress:
`repl.backend.displaysNestedArrayResults` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This required narrow
REPL eval support for DMD array-literal expressions by recursively evaluating
their elements into existing `Value.arrayValue` values.

REPL progress:
`repl.backend.displaysStaticStringArrayResults` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through existing REPL local declaration, string-literal, and array display
support; signal was verified by temporarily mutating the Interpreter string
literal helper, which changed the displayed result from `["a", "b"]` to
`["b", "c"]`.

REPL progress:
`repl.backend.displaysNestedEmptyStringValues` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. This required
preserving string display metadata for empty D string literals by constructing
interpreter string values through `Value.stringValue`.

REPL progress:
`repl.backend.displaysWideStringValues` in `tests/ut/backends/api/repl.d` now
runs on `Interpreter`. This required encoding DMD wide string-literal code
units as UTF-8 before constructing interpreter string values.

REPL progress:
`repl.backend.displaysWideCharacterArrayValues` in
`tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already green
through existing REPL string display for character arrays and UTF-8 conversion
for wide character values; signal was verified by temporarily mutating the
`wchar` conversion path, which changed the first displayed result from `"ab"`
to `"bc"`.

Arrays/structs/exceptions status probe:
In the current checkout, `tests/ut/backends/runner/ct/arrays.d`,
`tests/ut/backends/runner/ct/structs.d`, and
`tests/ut/backends/runner/ct/exceptions.d` already have their current
oracle-backed backend-matrix tests covered by `Interpreter`. The focused
exceptions run passed: 26 run, 0 failed.

Cerealed promotion probe:
All current oracle-backed backend-matrix tests in
`tests/ut/backends/runner/ct/cerealed.d` were promoted to also run on
`Interpreter` in branch `interpreter-ct-cerealed-module`. CTFE-only
characterization blocks stayed CTFE-only; compiled-behaviour diagnostic and
class-registry blocks now include `Interpreter`, keeping `SystemLinker` as the
oracle.

Running only the cerealed Interpreter tests with
`bin/ut $(bin/ut -l | rg
'^ut\.backends\.runner\.ct\.cerealed\..*Interpreter$')` ran 23 cases: 9
passed and 14 failed. Passing promoted surface includes struct method array
append, `ref` cursor advancement, post-increment array indexing, template
length-prefix writes, bool round trips, float bit reinterpretation, protocol
unit round trip, and ubyte array round trip.

Failure causes from the first focused run:

- Array equality can report false negatives where both rendered operands are
  identical, e.g. `[211, 254] != [211, 254]`,
  `[0, 0, 0, 3, 255, 240, 189, 192] != ...`, and `[8, 13] != [8, 13]`.
  Failing tests include `bitPackedStructHeaderRoundTrip`,
  `encodeIntWritesBigEndianBytes`, `exampleFooRoundTripBytes`,
  `multidimensionalArrayWritesNestedLengths`,
  `resetReaderRestoresOriginalOrNewBytes`, `roundTripEnumBytes`, and
  `staticArrayRoundTripOmitsLengthPrefix`.
- The promoted compiled-oracle bounds diagnostics still report CTFE-style
  text from the interpreter: `array index N is out of bounds `[0..M]`` instead
  of `index [N] is out of bounds for array of length M`. Failing tests are
  the three exhaustion diagnostics.
- `classSerialisationReadsStaticChildRegistry` fails during static
  associative-array delegate field initialization with
  `Unsupported DMD default value`. The slice needs enough interpreter support
  for the static child-writer registry fixture, not a CTFE characterization.
- `pointerToIntWritesPointeeBytes` remains a pointer/new/dereference gap in
  the promoted project-shaped fixture.

Cerealed completion:
The focused cerealed Interpreter-only run now passes: 23 run, 0 failed. The
slice added recursive array equality, enum numeric scalar equality, `ref`
array-element write-through, compiled-style bounds diagnostics while running
called functions, static delegate and associative-array defaults, static
class-registry support for stored function literals, classinfo name reads,
ordinary pointer-element write-through, `_d_aaApply2` associative-array
iteration, captured-local writeback for lowered foreach delegates, and
struct-literal associative-array default handling.

Cerealed verification regression:
The first broad `bin/ut --random` after the cerealed slice exposed
`arrays.dynamicArray.postIncrementIndex.Interpreter` failing with `2 != 1`.
DMD lowers assertion operands into compiler temporaries before the `AssertExp`;
the new `ref` array-element alias recording evaluated the index expression once
to initialize the temp and a second time to remember the aliased slot. The fix
records the array index returned by `runIndexExpression` and reuses it when
installing the alias, so `index++` keeps normal single-evaluation semantics.

Cerealed live REPL example (`c ~= 42`) — IN PROGRESS (handoff):
Goal (user-directed loop): make the live interactive REPL example work end to
end, then keep analysing/testing/fixing until it does, with self-contained
tests that do NOT depend on cerealed. Repro:

```
printf 'import cerealed;\nauto c = Cerealiser();\nc ~= 42;\n' | \
  bin/qb -b interpreter -I ~/coding/d/cerealed/src -I ~/coding/d/concepts/source
```

`c ~= 42` lowers through `CerealiserImpl.opOpAssign!"~"` → `grain` →
`Appender!(ubyte[]).put` → `ensureAddable`, which under the interpreter's
CTFE-style execution runs `_data = new Data;` then `_data.arr.length = reqlen;`
(`std.array`). Each gap below was reduced to a self-contained
struct/array/`new` fixture (no cerealed) in
`tests/ut/backends/runner/ct/expressions.d`, backend matrix
`AliasSeq!(Ctfe, Interpreter, SystemLinker, LLVMJit)`, `SystemLinker` oracle.

Diagnosis technique (for the next agent): the REPL/backend swallows the
exception into a diagnostic string. To see the throwing line + stack, either
temporarily `stderr.writeln(exception)` in
`displayEvalResult` (`source/quickbite/backends/evaluator.d`) or tag the
candidate `throw new Exception("Expected array.")` sites in
`source/quickbite/lang/package.d`. Revert before committing.

Error chain discovered (each is the next error after the previous fix):

1. `Error: Unsupported eval expression: address` — `&` of a `ref` parameter
   (`AddrExp(VarExp)`). FIXED and MERGED to master as PR #254 (commit
   9bd36380). Test `pointer.addressOfRefParameterReadsThroughPointer`.

2. `Error: Expected array.` — a null dynamic array's `.length`. `new S` of a
   struct with an `int[]` field passes the field's `null` default initialiser
   as a positional aggregate argument; `runExpression(NullExp)` returned
   `Value.null_`, so `S(0, null)` and `.length` threw, whereas compiled D gives
   `S(0, [])` and length 0. FIXED on this branch: in `runExpression`'s
   `NullExp` branch (`impl.d` ~line 754) a `null` literal typed `Tarray` now
   returns `Value.arrayValue([])`, matching `defaultValue`. Test
   `new.heapStructArrayFieldHasZeroLength` is green on all four backends.

3. `Error: Unsupported interpreter assignment target: arrayLength` /
   `Unsupported eval expression: loweredAssignExp` — resizing an array field
   through a pointer (`_data.arr.length = reqlen`). The existing
   `runLoweredAssignExpression` only handled a plain local `VarExp` lvalue; the
   field-through-pointer lvalue was rejected. FIXED on this branch:
   `writeLocation` now delegates `ArrayLengthExp` lvalues to
   `writeArrayLengthLocation`, and `runLoweredAssignExpression` falls back to
   the same helper for non-local array-length lvalues while preserving the
   existing local dynamic-array fast path. Test
   `new.heapStructArrayFieldGrowsByLengthAssign` is green on all four
   backends.

Verification for slices 2-3:

```
ninja bin/ut
bin/ut \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldHasZeroLength.Ctfe \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldHasZeroLength.Interpreter \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldHasZeroLength.SystemLinker \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldHasZeroLength.LLVMJit \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldGrowsByLengthAssign.Ctfe \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldGrowsByLengthAssign.Interpreter \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldGrowsByLengthAssign.SystemLinker \
  ut.backends.runner.ct.expressions.new.heapStructArrayFieldGrowsByLengthAssign.LLVMJit
bin/ut --random --seed 2911382024
```

The full random run reported 2268 run, 0 failed, 5/5 expected failures.

4. `Error: Unsupported eval expression: cast_` — after rebuilding `bin/qb`,
   the live repro advances to DMD's lowering of an array field `.ptr`:
   `cast(ubyte*)(*this._data).arr`. Temporary diagnostics showed the cast
   source as `(*this._data).arr` (`dotVariable`, type `ubyte[]`) and target as
   `ubyte*`. The interpreter's `arrayPointer` helper only accepts plain local
   array variables, so it rejected this field-through-pointer array
   expression. FIXED on this branch for the read case:
   `arrayPointer` now accepts a `DotVarExp` array field by evaluating the field
   and constructing a pointer over those elements. Test
   `cast.arrayFieldPointerDereferencesFirstElement` is green on all four
   backends.

5. `Error: Unsupported eval expression: this` — after slice 4, the live repro
   advances into `std.array.Appender.put`'s generated zero-argument lambda at
   `/usr/include/dlang/dmd/std/array.d:3796`:
   `(() @trusted => _data.arr.ptr[0 .. len + 1])()`. The lambda is nested
   inside the member function and reads `_data` through the enclosing member
   `this`, but `runFunction` currently creates a child walker for nested
   functions without propagating `thisValue` / `hasThis` from the enclosing
   member call. PARTIALLY FIXED on this branch: the approved
   `function.nestedLambdaReadsEnclosingThisField` test covers a member function
   that stores a nested lambda in a local delegate and then calls it; function
   literal declarations now preserve the enclosing receiver when the literal is
   nested. That test is green on CTFE, Interpreter, SystemLinker, and LLVMJit.

   The live repro still fails at the same diagnostic because `Appender.put`
   uses the direct IIFE shape above. That path calls the `FuncExp` directly
   instead of going through a stored local delegate, so it still bypasses the
   receiver-preserving runtime delegate.

Next step: get approval for a direct nested-lambda IIFE test, then repeat the
RED→GREEN loop. Commit this stored-lambda slice first, then make the direct
IIFE fix as a separate slice. Run `ci.sh` before the PR.

Diagnostics promotion probe:
All current CTFE-backed backend-matrix tests in
`tests/ut/backends/runner/ct/diagnostics.d` were promoted to also run on
`Interpreter` in branch `interpreter-ct-diagnostics`. The focused
Interpreter-only diagnostics module run left exactly one failing promoted test:

- `nullClassNotIdentityUsesNotEqualPolarity.Interpreter`: the interpreter
  reports `false != true` for `assert(thing !is null)` when `thing` is a null
  class reference, while the CTFE oracle reports `` `null` is `null` ``.

Failure cause: the interpreter currently treats the lowered `!is` assertion as
a generic boolean equality assertion and formats the generated helper result.
It needs to preserve the identity expression's null-class diagnostic polarity
for this DMD assertion shape, matching the existing CTFE-backed test without
adding broad class identity semantics beyond the promoted case.

Resolution: assertion formatting now recognizes DMD-lowered identity
expressions, follows the generated helper variable back to its initializer, and
formats failed class-null identity with the original `is`/`!is` polarity. The
full focused `diagnostics.d` Interpreter-only run now passes: 31 run, 0 failed.

Math promotion probe:
In branch `interpreter-ct-math-module`, the current
`tests/ut/backends/runner/ct/math.d` matrix already had every current math test
covered by `Interpreter`; there were no CTFE-backed math tests left to promote.
The focused Interpreter-only math module run passed: 57 run, 0 failed. No
production failure causes were found, so no subagent fix slices were needed for
this module.

Exceptions promotion probe:
All current SystemLinker-backed backend-matrix tests in
`tests/ut/backends/runner/ct/exceptions.d` were promoted to also run on
`Interpreter` in branch `interpreter-ct-exceptions`. CTFE-only characterization
blocks stayed CTFE-only; the split compiled-behavior blocks now include
`Interpreter`, keeping `SystemLinker` as the oracle.

Running only the exceptions Interpreter tests with
`bin/ut $(bin/ut -l | rg
'^ut\.backends\.runner\.ct\.exceptions\..*Interpreter$')` ran 26 cases: 11
passed and 15 failed. Passing promoted surface includes uncaught throw message
reporting, basic catch execution, throw from a directly called function, a
runtime branch throw from a directly called function, simple `try`/`finally`,
`goto` through `finally`, and `goto` inside/leaving a catch handler.

Failure causes from the first focused run:

- Interpreted thrown exceptions carry only a message. Catch variables therefore
  bind as `null`, dynamic catch selection always uses the first catch clause,
  casts to class types report `Unsupported cast target: Tclass`, and derived
  fields cannot be read through a caught base reference. Failures include
  `catchExceptionBindsCaughtObject`, `catchSkipsNonMatchingSiblingException`,
  `catchByBaseReadsDerivedField`, `multipleCatchClausesSelectByDynamicType`,
  `finally.runsFinalbodyBeforeCatch`, and `finally.throwChainsBodyException`.
- Throw propagation across nested interpreted calls is incomplete. A callee
  throw after a side effect can be swallowed or followed by later caller
  statements, so ref side effects end as the non-throw path value. Failures
  include `catchThrowAfterCalleeSideEffect`,
  `catchNestedBranchThrowFromCalledFunction`,
  `throwAfterRuntimeBranchPreservesRefSideEffect`,
  `throwExpressionInConditionalIsCaught`, and `rethrowPropagatesToOuterHandler`.
- `try`/`finally` runs the final body for normal fallthrough, but return-state
  handling is too narrow. Returns from inside the try body are not finalized
  before the caller observes ref side effects or the pre-finally return value.
  Failures include `finally.runsAfterReturn`,
  `finally.returnCapturesValueBeforeFinally`, and
  `finally.branchReturnsCaptureValueBeforeFinally`.
- The compiled-oracle promotion for
  `catchExceptionDoesNotCatchAssertFailure` expects the SystemLinker
  `_d_unittest` message `unittest failure`, while the interpreter currently
  reports the CTFE-style `` `assert(false)` failed ``. The fix is a runner
  boundary diagnostic choice for literal unittest assertion failures, not catch
  semantics: the catch already does not swallow the assertion.

Exception-object progress:
The first exceptions worker added narrow interpreted class-object values,
class-backed `throw new Exception(...)` / subclass construction, dynamic catch
selection, catch-variable binding, class casts, and promoted class field
reads/writes. The focused exceptions Interpreter-only run now reports 26 run
and 9 failed. The former catch-object/type-selection failures now pass,
including `catchExceptionBindsCaughtObject`,
`catchSkipsNonMatchingSiblingException`, `catchByBaseReadsDerivedField`,
`multipleCatchClausesSelectByDynamicType`, and
`errorIsNotCaughtByExceptionHandler`.
Remaining failures are callee throw/ref propagation, `try`/`finally` return and
throw state, one exception chaining expression shape, and the compiled-oracle
literal `assert(false)` message.

Handoff:
The worktree was interrupted after the exceptions module reached 24 passing
and 2 failing Interpreter cases. The remaining red tests at the handoff point
are:

- `exception.catchExceptionDoesNotCatchAssertFailure.Interpreter`
- `finally.throwChainsBodyException.Interpreter`

The control-flow and class-object slices are already committed in the working
tree state for the current session. The next pass should treat the two failures
as separate, narrow fixes: one runner-diagnostic policy slice for literal
`assert(false)` in unittest bodies, and one exception-chaining expression-shape
slice for the `.next` access in the `finally` test.

Handoff resolution:
On resuming, `finally.throwChainsBodyException.Interpreter` was already green in
the working tree (the exception-chaining slice had landed), leaving only
`exception.catchExceptionDoesNotCatchAssertFailure.Interpreter` red. That test
expects the compiled `_d_unittest` message `unittest failure` for a literal
`assert(false)` directly in a unittest body, while the interpreter reported the
CTFE-style `` `assert(false)` failed ``.

Fix: the `Walker` now carries an `inUnitTest` flag, set in `Interpreter.eval`
from `function_.isUnitTestDeclaration !is null` and naturally false in the
freshly-constructed child walkers used for called functions. When a literal
`assert(false)`/`assert(0)` (no custom message) fails directly in a unittest
body, `assertFailureMessage` returns `unittest failure`, matching the
SystemLinker oracle; called-function asserts keep the existing CTFE-style
wording because their child walker has `inUnitTest == false`. This is the
Interpreter making itself oracle-correct for one cross-cutting behavior, not new
module coverage.

Because the literal-`assert(false)`-in-unittest message is pinned identically in
three modules, making the Interpreter oracle-correct required moving it out of
the CTFE characterization block and into the SystemLinker-oracle block in the
two sibling modules as well (user-approved as the oracle-correct resolution):

- `tests/ut/backends/runner/ct/diagnostics.d` `literalFalseAssertionMatchesDmd`:
  Interpreter moved from the `Ctfe, Bytecode, IR` (``assert(false)` failed`)
  block to the `Interpreter, SystemLinker` (`unittest failure`) block.
- `tests/ut/backends/runner/ct/control_flow.d`
  `function.structMethodReturnDoesNotSkipCallerStatements`: Interpreter moved
  from the `Ctfe` block to the `Interpreter, SystemLinker` block. The test still
  verifies that a struct method's `return;` does not skip the caller's following
  `assert(false)`; only the asserted message text changed to the oracle wording.

`Bytecode` and `IR` stay on the CTFE-style `` `assert(false)` failed `` wording;
only the Interpreter is being driven to oracle parity. The focused exceptions
Interpreter run is now 26 run, 0 failed, and `bin/ut --random` is green (1718
run, 0 failed, 4/4 `@ShouldFail` expected).

REPL promotion probe:
All remaining CTFE-backed backend-matrix tests in
`tests/ut/backends/api/repl.d` were promoted to also run on `Interpreter` in
branch `interpreter-api-repl-plan`. The two previously split Interpreter-only
copies of `importDeclarationsPersistWithoutDisplay` and
`displaysUndisplayablePlaceholderForFunctionLiterals` were folded back into the
shared matrix to avoid duplicate test names.

The promoted suite was run with `dub test -- --random`; the failing seed was
`963603312`. Re-running with `dub test -- --seed 963603312` left exactly these
new Interpreter failures:

- `importStdExposesPhobosSymbols`: `Unsupported eval statement: UnrolledLoop`.
- `displaysFiniteRangeResults`: `Unsupported DMD default value`.
- `displaysFilteredArrayResults`: `Unsupported eval statement: If`.
- `displaysAssocArrayResults`: `Unsupported eval expression:
  assocArrayLiteral`.
- `displaysEnumValues`: displayed `["7", "[7, 8]", "7"]` instead of
  `["E.a", "[E.a, E.b]", "7"]`.
- `runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState`: reported
  `Unsupported eval call.` instead of the no-available-source `malloc`
  diagnostic.
- `expressionCtfeErrorsReportDiagnostics`: reported `Unsupported eval
  expression: index` instead of the array-bounds diagnostic.
- `diagnosticsHideSyntheticWrapperNames`: reported `Unsupported eval
  expression: assert_` instead of evaluating the explicit `__FUNCTION__`
  assertion message to `<repl>`.

The remaining promoted Interpreter cases were already green:
`displaysStringValues`, `specialTokenValuesHideWrapperInternals`,
`numericScalarDisplayUsesDLiteralSuffixes`, `noDisplayCellsReturnVoid`,
`runLoadedUnittestBlocks`, `runLoadedTestsWithNothingLoadedReturnsVoid`,
`loadedUnittestFailuresReportReplLocation`,
`laterLoadedUnittestFailuresReportReplLocation`,
`runLoadedTestsReportsEveryFailedUnittest`, `runLoadedFileUnittestBlocks`,
`loadedSourceDoesNotAdvanceTypedReplLocations`,
`loadedFileUnittestFailuresReportFileLocation`,
`loadModuleFileErrorsHideSyntheticNames`,
`duplicateDeclarationsHideSyntheticNames`,
`failedModuleNoDisplayCellsDoNotPoisonSession`,
`syntaxErrorsHideWrapperInternals`,
`functionCallMismatchShowsCandidateSignature`, and
`functionCallMismatchShowsOverloadSignatures`.

Fix plan for the failing REPL probe:

1. Start with the narrow REPL walker parity cases before Phobos ranges. Add
   `EvalFunctionWalker` support for `AssertExp`, using the existing module
   interpreter assertion-message helpers as the reference but only for the
   explicit-message REPL shape required by
   `diagnosticsHideSyntheticWrapperNames`. This should evaluate
   `assert(false, __FUNCTION__)` to the sanitized `<repl>` message.

2. Add `EvalFunctionWalker` external-source call diagnostics to match
   `EvalModuleInterpreter.runCallExpression`: when a resolved `call.f` has no
   body, report the mechanically-derived no-available-source message before
   falling through to generic unsupported-call diagnostics. This should make
   the `malloc` REPL cell fail with the CTFE-compatible diagnostic while
   preserving session state.

3. Add read-only REPL `IndexExp` support for local and literal dynamic arrays,
   including DMD-compatible bounds messages for the two promoted REPL shapes:
   literal `[1, 2, 3][10]` and local `arr[99]`. Reuse `Value` array indexing
   where it already reports the desired diagnostic; otherwise add a small
   helper that formats the existing CTFE messages without adding writes,
   slices, or pointer indexing.

4. Add REPL `AssocArrayLiteralExp` support by evaluating DMD literal keys and
   values into `Value.assocArrayValue`. Keep this literal-only and display-only
   for `displaysAssocArrayResults`; do not add associative-array indexing,
   mutation, `.keys`, `.values`, or runtime druntime hooks until a promoted
   test requires them.

5. Preserve enum display metadata in REPL expression evaluation. When DMD
   represents an enum member as an `IntegerExp` with enum type, construct
   `Value.enumValue` from the original expression spelling, matching the CTFE
   backend's `ctfeValue` behavior. Ensure casts to integral types still discard
   the enum display wrapper so `cast(int) E.a` remains `7`.

6. Tackle Phobos range expressions last. First add `UnrolledLoopStatement`
   sequencing and the narrow `IfStatement` behavior observed in the lowered
   `std`/`std.algorithm` template bodies. Then inspect the
   `Unsupported DMD default value` path from `displaysFiniteRangeResults`;
   likely fixes are limited default-value support for the Phobos range wrapper
   types or returning an undisplayable/default display value for fields that
   cannot be materialized. Do not implement a broad range engine or generic
   Phobos interpreter without another promoted red test forcing each step.

REPL promotion probe (2026-06-10, branch `interpreter-bin-repl`):
The REPL test module now lives at `tests/ut/bin/repl.d`. All 29 remaining
CTFE-only backend-matrix blocks were promoted to `AliasSeq!(Ctfe,
Interpreter)`. Two leftover CTFE-only duplicate blocks
(`importDeclarationsPersistWithoutDisplay` and
`displaysUndisplayablePlaceholderForFunctionLiterals`) were left unpromoted:
their tests already run on `Interpreter` via the shared three-backend blocks,
and promoting the duplicates would create colliding `.Interpreter` test names.
Those duplicate CTFE-only blocks look like leftovers that should be folded
away in a separate approved test cleanup.

23 promotions passed and were kept; `bin/ut --random` is green (905 tests, 0
failed). Six promotions failed and were reverted to CTFE-only:

- `importStdExposesPhobosSymbols`: `Unsupported eval statement: UnrolledLoop`
  (unchanged from the previous probe).
- `displaysFiniteRangeResults`: now also `Unsupported eval statement:
  UnrolledLoop`; the previous `Unsupported DMD default value` failure point
  has moved.
- `displaysFilteredArrayResults`: now `Unsupported eval expression:
  structLiteral`; the previous `Unsupported eval statement: If` failure point
  has moved deeper into the lowered Phobos range wrapper.
- `displaysAssocArrayResults`: `Unsupported eval expression:
  assocArrayLiteral` (unchanged).
- `displaysEnumValues`: displayed `["7", "[7, 8]", "7"]` instead of
  `["E.a", "[E.a, E.b]", "7"]` (unchanged); enum display metadata is lost.
- `expressionCtfeErrorsReportDiagnostics`: REPL `IndexExp` reads now exist but
  have no bounds check, so `arr[99]` escapes as a host
  `core.exception.ArrayIndexError` (`index [99] is out of bounds for array of
  length 3`) instead of the CTFE diagnostic
  "array index 99 is out of bounds \`[0..3]\`". This is a crash-class escape,
  not just a missing feature; the bounds-message half of fix-plan item 3 is
  still open.

Relative to the previous probe's fix plan: item 1 (`AssertExp`,
`diagnosticsHideSyntheticWrapperNames`) and item 2 (no-available-source call
diagnostics, `runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState`) are
done — both tests now pass on `Interpreter` and were kept. Item 3 is half
done (reads work, bounds diagnostics missing). Items 4 (assoc array
literals), 5 (enum display metadata), and 6 (Phobos ranges, now blocked on
`UnrolledLoop` sequencing and `structLiteral` evaluation) remain open.

Newly kept promotions beyond the previous probe's green list:
`typeofCellsDisplayTypeName`, `typeAliasCellsDisplayTypeName`,
`runtimeErrorsReportOneDiagnostic`,
`runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState`, and
`diagnosticsHideSyntheticWrapperNames`. The kept promotions passed without
production changes in this probe; per-test mutation signal verification was
not performed and remains required before any kept promotion is accepted as a
completed slice.

REPL probe resolution (2026-06-11, branch `interpreter-bin-repl`):
all six reverted probe failures were re-promoted and fixed in serial
subagent slices, one commit each. The two duplicate CTFE-only blocks were
folded into the shared matrix (approved test cleanup). Every backend-matrix
block in `tests/ut/bin/repl.d` now includes `Interpreter`.

REPL progress: `repl.backend.expressionCtfeErrorsReportDiagnostics` now runs
on `Interpreter`. The eval walker's `IndexExp` read had no bounds check, so
`arr[99]` on a local escaped as a host `core.exception.ArrayIndexError`.
Indexing now goes through `runIndexExpression`, which throws the CTFE-parity
message via a new `indexOutOfBoundsMessage` helper in
`backends/interpreter/messages.d`. The literal-receiver path
(`[1, 2, 3][10]`) was already covered and did not regress.

REPL progress: `repl.backend.displaysAssocArrayResults` now runs on
`Interpreter`. The walker evaluates `AssocArrayLiteralExp` keys and values
recursively into `Value.assocArrayValue`, the same constructor the CTFE
backend uses, so display matches by construction. Literal-only: no
assoc-array indexing, mutation, `.keys`/`.values`, or druntime hooks.

REPL progress: `repl.backend.displaysEnumValues` now runs on `Interpreter`.
Enum-typed `IntegerExp` values (checked via `type.ty == TY.Tenum` on the
non-basetype, mirroring CTFE) construct `Value.enumValue` from DMD's rendered
member spelling. Casts to integral types still discard the display wrapper.

REPL progress: `repl.backend.importStdExposesPhobosSymbols` now runs on
`Interpreter`. Clearing the failure chain for
`[1, 2, 3].map!(a => a * 2).array` required: `UnrolledLoopStatement` and
`ForStatement` sequencing with a `returned` early-return flag,
`StructLiteralExp` → `Value.structValue`, `ConstructExp`/`BlitExp` routed
through assignment, a general `writeLocation` lvalue writer (VarExp / ThisExp
/ recursive DotVarExp), member-function calls with receiver binding and
lvalue-only `this` writeback, ref-argument writeback generalized to arbitrary
writable lvalues, `DotVarExp` struct field reads, the magic `__ctfe` variable
evaluating to `true` (identified via `ident is Id.ctfe`, matching DMD's own
interpreter and avoiding the runtime GC/asm path in `std.array.array`), and
binding DMD's `lengthVar` so `$` resolves in slice and index expressions.
`Value` gained `structFieldAt` and `withStructField`.

REPL progress: `repl.backend.displaysFilteredArrayResults` now runs on
`Interpreter`. `iota(5).filter!(x => x % 2 == 0).array` additionally needed
`DoStatement` sequencing, `ModExp` via a new `%` case in `Value.opBinary`,
and rewriting the add-assign handler as a read-modify-write through
`writeLocation` so struct-field targets (`this.current += step` in `iota`)
work and the increment honours the right-hand side instead of hardcoding 1.

REPL progress: `repl.backend.displaysFiniteRangeResults` now runs on
`Interpreter`. It was already green through the struct-literal, member-call,
and lvalue machinery from the two Phobos pipeline slices; the unconsumed
`MapResult` displays through the generic `Value` struct rendering (no Phobos
symbol names appear in production code). Signal was verified by temporarily
mutating the interpreter struct-literal name, which failed the focused test;
the mutation was reverted before committing.

With this, the previous probe's fix plan is fully discharged: items 1-6 are
all done. No CTFE-only backend-matrix blocks remain in
`tests/ut/bin/repl.d`.

Expressions promotion probe:
All current SystemLinker-oracle backend-matrix tests in
`tests/ut/backends/runner/ct/expressions.d` were promoted to also run on
`Interpreter` in branch `interpreter-ct-expressions`. CTFE-only
characterization blocks stayed CTFE-only; the split compiled-behavior blocks
now include `Interpreter`, keeping `SystemLinker` as the oracle.

Running only the expressions Interpreter tests with
`bin/ut $(bin/ut -l | rg
'^ut\.backends\.runner\.ct\.expressions\..*Interpreter$')` ran 49 cases: 30
passed and 19 failed. Passing promoted surface includes relational assertion
diagnostics, ordinary arithmetic and bitwise basics already supported by the
walker, signed modulo behavior, several integer width/cast/comparison cases,
basic floating `pow`/numeric casts, comma expressions, conditional
non-null-pointer truthiness, and many existing class/pointer-adjacent cases.

Failure causes from the first focused run:

- Pointer and pointer-cast values are still too narrow. Failures include
  `cast.sliceToPointerDereferencesFirstElement`,
  `cast.arrayPointerRoundTripsThroughVoidPointer`,
  `cast.arrayElementAddressToStaticArrayPointer`,
  `cast.expTypePaintedSliceFromVoidPointer`,
  `cast.pointerToBoolReflectsNullness`,
  `new.scalarPointerDereferencesRuntimeValue`,
  `pointer.runtimeOffsetReadsElement`, and
  `pointer.runtimeDifferenceReadsElement`. The common gaps are preserving
  pointers to array elements/slices through `void*` casts, static-array pointer
  views, pointer arithmetic/dereference, pointer-to-bool casts, and scalar
  `new int(seed)` allocation/deref/write. The desired slice is interpreter
  memory-value semantics, not host memory.
- Class and interface dispatch are incomplete for expression-module shapes.
  `class.virtualCallUsesDynamicClass` escapes as an array bounds error while
  writing a derived class field through the class object, and
  `interface.virtualCallUsesRuntimeDispatch` needs the same dynamic-dispatch
  machinery through an interface reference. The likely fix is class field
  layout/indexing across inheritance plus virtual/interface call resolution,
  not a fixture-name special case.
- Delegate values are not modeled broadly enough for `.ptr`, `.funcptr`,
  captured nested calls, and struct-member delegate receivers. Failures include
  `delegate.ptrPropertyReturnsClosureContext`,
  `delegate.funcptrPropertyReturnsFunctionPointer`,
  `delegate.nestedCallUsesCapturedValue`, and
  `delegate.structMemberCallUsesReceiver`. The interpreter needs real delegate
  value construction with context, function pointer identity, and call dispatch.
- Remaining scalar expression gaps include compound assignment and wrapping
  stores (`int.assignmentOperators`, `integer.ubyteAddAssignWrapsOnStore`),
  unary bit complement/logical/negative variants (`int.unaryOperators`),
  unsigned right shift (`int.unsignedRightShiftZeroFills`), integer power
  lowering (`int.powerOperatorRaisesRuntimeIntegers`), `ulong` to `real`
  precision (`floating.ulongToRealCastPreservesRealPrecision`), and complex
  values with runtime parts (`complex.literalWithRuntimeParts`).
- Type and vector expression handling is still partial.
  `typeid.classReferenceUsesDynamicClass` reports unsupported typeid for class
  references, `typeid.typeNameReturnsIdentifier` returns a name that does not
  contain the expected identifier, and
  `vector.scalarCastSplatsToStaticArray` reaches DMD's `vector` expression
  without an interpreter value for the SSE2 splat/static-array `.array` view.

Expressions module resolution:
Five serial worker slices fixed the failure groups above. Pointer work added
interpreter memory-value semantics for pointers to array elements/slices,
`void*` round trips, pointer arithmetic/dereference, pointer-to-bool casts,
static-array pointer views, and scalar `new int(seed)` allocation. Class work
made class field reads/writes use runtime class layout, represented interface
membership on class values, and resolved member calls through the runtime
class implementation. Delegate work added delegate values with context,
function-pointer ids, `.ptr`, `.funcptr`, and delegate-call dispatch for
captured nested calls and struct-member receivers. Scalar work added compound
assignment, wrapping stores, unary complement, unsigned right shift, integer
power, `ulong` to `real`, and imaginary/complex scalar values. Type/vector
work added dynamic class `typeid`, `typeid(...).name`, qualified type names,
and the SSE2 vector splat/static-array `.array` view.

The `floating.ulongToRealCastPreservesRealPrecision` matrix is split so the
existing CTFE/SystemLinker `@ShouldFail` remains in place, while `Interpreter`
gets a passing copy. The fixture body is unchanged.

The focused expressions Interpreter run now passes: 49 run, 0 failed.

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

Arrays progress: `ubyteArrayIndexReadFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing read-only array indexing and equality assertion message
support; signal was verified by temporarily mutating the Interpreter
`IndexExp` handler.

Arrays progress: `refUbyteArrayParameterAppend` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing direct free-function call dispatch, `ref` parameter
writeback, local dynamic array append, length, and index-read support; signal
was verified by temporarily mutating Interpreter `ref` parameter writeback.

Arrays progress: `refUbyteArrayParameterAppendFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing direct free-function call dispatch, `ref` parameter
writeback, local dynamic array append, length, and equality assertion message
support; signal was verified by temporarily mutating the Interpreter array
append handler.

Arrays progress: `refUbyteArrayParameterAppendFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing direct free-function call dispatch, `ref` parameter
writeback, local dynamic array append, index-read, and equality assertion
message support; signal was verified by temporarily mutating the Interpreter
array append handler.

Arrays progress: `localDynamicArrayAppend` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. This required
only treating a null-initialized dynamic array local as an empty array value
when executing the declaration, so existing append, length, and index-read
support can handle the fixture.

Arrays progress: `localDynamicArrayAppendFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing null dynamic array, append, length, and equality
assertion message support; signal was verified by temporarily mutating the
Interpreter array append handler.

Arrays progress: `localDynamicArrayAppendFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing null dynamic array, append, index-read, and equality
assertion message support; signal was verified by temporarily mutating the
Interpreter array append handler.

Arrays progress: `nestedSliceWritesPropagateToOriginalArray` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. This required
narrow `SliceExp` evaluation for dynamic array values plus local slice-alias
writeback so an indexed write through a nested slice updates the original
array local.

Arrays progress: `nestedSliceAppendKeepsOriginalArrayTail` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing nested-slice evaluation and local array append
detachment; signal was verified by temporarily mutating the fixture's expected
tail value.

Arrays progress:
`nestedSliceAppendKeepsOriginalArrayTailFailureMessage.0` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing nested-slice evaluation, local array append detachment,
index-read, and equality assertion message support; signal was verified by
temporarily mutating the Interpreter `IndexExp` handler, which made the
promoted fixture stop throwing the expected `3 != 4` message.

Arrays progress:
`nestedSliceAppendKeepsOriginalArrayTailFailureMessage.1` in
`tests/ut/backends/lang/arrays.d` now runs on `Interpreter`. It was already
green through existing nested-slice evaluation, local array append detachment,
index-read, and equality assertion message support; signal was verified by
temporarily mutating the append handler to write through the slice alias, which
made the promoted fixture fail before the expected `4 != 5` assertion message.

Arrays promotion probe:
`assocArray.insertionGrowsAndOverwrites` in
`tests/ut/backends/runner/ct/arrays.d` was promoted to also run on
`Interpreter` in branch `interpreter-ct-diagnostics`. The focused
Interpreter-only arrays module run left exactly one failing promoted test:

- `assocArray.insertionGrowsAndOverwrites.Interpreter`: assigning
  `values[first] = first + 30` into a default-initialized `int[int]` local
  reports `Expected associative array.`

Failure cause: the interpreter's associative-array index assignment path
expects an existing AA value and does not treat a null/default-initialized
associative-array local as an empty AA that can accept first insertion. The
fix should be limited to local AA insertion/overwrite for the promoted shape;
existing missing-key read diagnostics should remain unchanged.

Resolution: default-initialized and explicit-null associative-array locals now
materialize as empty AA values in the interpreter, allowing first insertion and
overwrite while preserving missing-key read diagnostics. The focused promoted
test and the missing-key regression both pass.

Arrays promotion probe:
`dynamicArray.jaggedRowsKeepIndependentLengths` in
`tests/ut/backends/runner/ct/arrays.d` was promoted to also run on
`Interpreter` in branch `interpreter-ct-diagnostics`. The focused
Interpreter-only arrays module run left exactly one failing promoted test:

- `dynamicArray.jaggedRowsKeepIndependentLengths.Interpreter`: appending
  `first + 4` to `rows[1]` reports
  `Unsupported interpreter array append target.`

Failure cause: the interpreter already evaluates nested dynamic array literals,
lengths, and nested index reads for this fixture, but its append-assignment
target handling only supports local/ref-style array targets and does not write
an appended nested row back through an indexed array element target. The fix
should be limited to appending one element to a dynamic-array element selected
from a local nested dynamic array; the test also guards that sibling row
lengths stay independent.

Resolution: append-assignment now supports an indexed local dynamic-array
target for the promoted nested-row shape by appending to the selected row and
writing that row back into the outer array. The focused promoted test passes.

Structs promotion probe:
`with.structLocalGotoRestartsInsideBody` in
`tests/ut/backends/runner/ct/structs.d` was promoted to also run on
`Interpreter` in branch `interpreter-ct-diagnostics`. The focused
Interpreter-only structs module run left exactly one failing promoted test:

- `with.structLocalGotoRestartsInsideBody.Interpreter`: the interpreter reports
  `Unsupported eval statement: Goto` for a `goto target;` inside an otherwise
  supported `with (point)` body.

Failure cause: the interpreter's module-backed statement walker does not
handle DMD `GotoStatement`/label flow for the simple intra-block shape used by
the promoted struct `with` fixture. Existing `with` field access and mutation
already work; the missing behavior is restarting execution at a later label
inside the same body without running skipped statements.

Resolution: the statement walker now tracks a pending goto target while
iterating compound and unrolled statement lists, skips statements until the
matching label target, and executes label bodies normally. The focused promoted
test passes.

Structs progress: `struct.opAssignFromScalar` in
`tests/ut/backends/runner/ct/structs.d` now runs on `Interpreter`. It was
already green through existing struct assignment/operator handling; signal was
verified by temporarily changing the promoted fixture's expected value from
`42` to `43`, which failed the focused Interpreter test with `42 != 43`.

Structs operator/postblit promotion probe:
All remaining backend-matrix blocks in
`tests/ut/backends/runner/ct/structs.d` were promoted to also run on
`Interpreter` in branch `interpreter-ct-structs-operators`. Four newly
promoted operator-overload tests passed immediately and should remain promoted:

- `struct.opCmpOrdersValues.Interpreter`
- `struct.opBinaryAddsOperands.Interpreter`
- `struct.opIndexSelectsElement.Interpreter`
- `struct.opUnaryNegatesValue.Interpreter`

Running only the structs Interpreter tests left exactly one failing promoted
test:

- `struct.staticArrayCopyRunsPostblitAndDtors.Interpreter`: the interpreter
  reports `Unsupported eval statement: TryFinally`.

Failure cause: DMD lowers the fixture's scoped block with static-array copy,
postblit calls, and destructor cleanup into `TryFinally`, `memcpy`,
array-conformance helper, pointer-field, post-increment/decrement, and
`__ArrayDtor` shapes that the interpreter did not yet cover. The first missing
node was `TryFinally`; after that, the copy/postblit path needed local-pointer
values for `&postblits`/`&dtors`, whole-allocation pointer copy for the lowered
`memcpy`, dereferenced-pointer post-increment for `++*postblits`, and
compiler-generated post-decrement for destructor loops.

Resolution: the interpreter now runs `TryFinally` final bodies on normal
completion, models local pointers and writes through them, copies whole pointer
allocations for lowered `memcpy`, skips the lowered
`enforceRawArraysConformableNogc` conformance check, supports pointer
post-increment and scalar post-decrement, and runs the missing copied-from
static-array destructor pass for the lowered static-array copy cleanup. The
focused structs Interpreter module run passes: 43 run, 0 failed.

REPL progress: `repl.backend.multilineFunctionDeclarationsBufferUntilComplete`
in `tests/ut/backends/api/repl.d` now runs on `Interpreter`. It was already
green through the backend-agnostic `pendingInput` buffering in `frontend.cell`
(`isIncompleteCell`) plus the existing direct free-function call dispatch and
`isMulExp` handler; signal was verified by temporarily changing the
`EvalFunctionWalker` `isMulExp` handler from multiply to add, which failed the
focused test with `["17"]` instead of `["42"]`, then reverting the mutation. The
two remaining CTFE-only tests in `repl.d`
(`multilineStructDeclarationsBufferUntilComplete` and
`failedBufferedDeclarationDoesNotPoisonSession`) are deferred: the first needs
struct support and the second needs buffered-declaration error recovery, both
larger than the next available slice.

### CT Arrays Promotion Probe

All 48 backend-matrix blocks in `tests/ut/backends/runner/ct/arrays.d` (the
current home of the former `lang/arrays.d` coverage) were promoted from
`AliasSeq!(Ctfe)` to `AliasSeq!(Ctfe, Interpreter)` in branch
`interpreter-ct-arrays`. 20 promotions passed immediately; the other 28
were implemented as per-category slices in the same branch (see below).
The full suite is green with `bin/ut --random`.

Kept (already green on `Interpreter`, no production change):
`assertDiagnostic.integerEquality`, `assertDiagnostic.booleanEquality`,
`assertDiagnostic.arrayElementMismatch`,
`assertDiagnostic.arrayLengthMismatch`, `dynamicArray.lengthCases`,
`dynamicArray.literalElements`, `dynamicArray.ubyteLiteralTruncatesElements`,
`dynamicArray.indexReadWrite`, `dynamicArray.postIncrementIndex`,
`dynamicArray.mutableStringLiteralCopiesDoNotShareWrites`,
`dynamicArray.localAppend`, `dynamicArray.appendToNonEmptyArray`,
`dynamicArray.refParameterAppend`, `dynamicArray.sliceFromRuntimeBounds`,
`dynamicArray.nullZeroLengthSlice`,
`dynamicArray.nestedSliceWritesPropagateToOriginalArray`,
`dynamicArray.nestedSliceAppendKeepsOriginalArrayTail`,
`dynamicArray.returnValue`, `dynamicArray.sliceReturnValue`, and
`dynamicArray.indexesCallResult`. These were bulk promotions; none has had
individual mutation-based signal verification yet, so treat each as
needing signal verification before relying on it as a regression guard.

The 28 initially-failing promotions were then re-promoted and implemented
in the same branch, one commit per failure category. All 48 blocks in
`runner/ct/arrays.d` now run on `Interpreter`. What each category
required:

- Bounds diagnostics (`indexPastLengthDiagnostic`,
  `sliceIndexPastLengthDiagnostic`): `IndexExp` reads are bounds-checked
  before touching the host array, reporting `index N exceeds array
  length L` for slice values and ``array index N is out of bounds
  `[0..L]` `` otherwise. The previous behaviour was a host
  `ArrayIndexError` escaping `Value.opIndex` — a robustness bug, fixed.
- `assertDiagnostic.characterEquality`: the bool/integer
  assertion-message shortcut declines char-typed operands so they reach
  the full formatter's existing char display path (`'e' != 'f'`).
- Concatenation: `CatExp` evaluates each operand into a fresh element
  list (arrays expand, scalars become one element) — array~array,
  element~array, array~element.
- `new`: `NewExp` for dynamic arrays evaluates runtime lengths and
  builds default-filled values, recursing per row so multidimensional
  new gets distinct inner arrays; `defaultValue` gained a `Type`
  overload. Nested `values[i][j]` writes got one level of index-assign
  writeback.
- Length resize: `LoweredAssignExp` whose original LHS is an
  `ArrayLengthExp` over a local dynamic array resizes the value
  directly; the `_d_arraysetlengthT` lowering is not executed.
- Slice assignment: `SliceExp` LHS over a local array writes RHS
  elements into [lower, upper); block-repeat is classified by the RHS
  type equalling the slice's element type, copying a fresh row per
  outer element. Same-variable overlapping slice assignment reports the
  CTFE diagnostic. Static array locals materialise `defaultValue` at
  declaration (DMD's `BlitExp` `var[] = 0` shape), with `Tsarray`
  support in `defaultValue`.
- Array operations: DMD lowers `sums[] = left[] + right[]` to a druntime
  `core.internal.array.operations.arrayOp` call. The "+"/"="
  instantiation is recognised via its template arguments and interpreted
  element-wise at the call site; the druntime body is never executed.
- `staticArray.copyFromRuntimeArrayUsesArrayCtor`: test-only promotion;
  covered by the static-array `BlitExp` materialisation. Signal verified
  against the pre-slice interpreter ("Expected array."). Note: a
  temporary independence probe showed real DMD CTFE *aliases* `copy`
  and `source` in this shape while compiled code copies independently
  (the Interpreter matches compiled code) — a `Ctfe` characterization
  divergence: `SystemLinker` (compiled D) is the oracle and the Interpreter
  agrees with it; `Ctfe`'s aliasing is pinned as what `Ctfe` does, not as
  truth (`ai/plans/single-oracle.md`).
- Associative arrays (all 8): DMD lowers AA operations to
  `core.internal.newaa` and `object` template hooks (`_d_aaLen`,
  `_d_aaGetRvalueX`, `_d_aaGetY`, `_d_aaIn`, `_d_aaDel`, `_d_aaEqual`,
  `object.keys/values/dup`); the interpreter handles the semantics at
  the call site. AA literals keep the last duplicate key; equality is
  insertion-order-independent; missing-key reads use the source
  spellings (``key `absent` not found in associative array `values` ``).
  `aa[key] = v` writes through a recorded `_d_aaGetY` slot alias. `in`
  yields a narrow single-target `Pointer` value (dereference and null
  comparison only). `foreach` over `.keys`/`.values` needed a narrow
  `ForStatement` runner (init/condition/body/increment, no
  break/continue). Also fixed a real pre-existing bug: `+=` added a
  hardcoded 1 instead of the RHS.
- Pointers (all 6): the lang `Pointer` value gained an opaque allocation
  id and element offset over a copy-on-write snapshot of the array
  elements. `&values[i]` and the `cast(T*)` lowering of `.ptr` build
  array pointers; pointer arithmetic is byte-scaled by DMD semantic and
  converted through the element size; `p - q` returns the byte
  difference so the lowered `/stride` division yields the element count;
  ordered comparisons across unrelated allocations are false both ways
  (CTFE semantics); pointer slices bounds-check against the allocated
  block with the CTFE diagnostic. `castTarget` in
  `source/quickbite/backends/casts.d` now throws an unsupported-cast
  diagnostic instead of `assert(0)` — the second probe crash bug, fixed.
  Known staleness limits of the snapshot model (no fixture exercises
  them): reads through a pointer do not see later writes to the array
  local, and pointer writes (`*p = x`) remain unsupported diagnostics.

### CT Structs Promotion

`tests/ut/backends/runner/ct/structs.d` was promoted in branch
`interpreter-ct-structs`. A bulk probe promoted all 38 backend-matrix
blocks; one was already green and kept immediately, while the remaining
passing promotions were implemented as per-category slices. The full
suite is green with `bin/ut --random`.

Kept from the probe (already green on `Interpreter`, no production
change): `struct.literalDefaultsMissingFieldToZero`. This was a bulk
promotion and has not had individual mutation-based signal verification.

The implemented categories were:

- Struct-typed local default initialization: DMD lowers `Value v;` to
  a `BlitExp` assigning `0`; `defaultValue` now handles `Tstruct`, and
  the interpreter materializes struct defaults instead of storing a
  scalar zero.
- Dynamic array fields default to empty arrays: `defaultValue` handles
  `Tarray` so struct fields like `ubyte[] bytes;` start as `[]`.
- Struct field post-increment: `DotVarExp` post-increment targets use
  the normal lvalue writer to update the receiver field.
- Constructor calls on default-initialized receivers: constructor member
  walkers seed `this` from the struct default when DMD has blitted the
  receiver to scalar zero before the call.
- Dynamic array field append and indexed writes: `DotVarExp` array
  append and `IndexExp`-on-`DotVarExp` writes update the containing
  struct and write it back. By-value struct arguments copy array-field
  element writes back up to the original slice length, matching D slice
  descriptor semantics for the promoted tests.
- `new T(...)` for struct pointers: struct allocation builds a struct
  value, runs positional initialization or the user constructor, and
  wraps the result in `Value.pointerValue`; `*ptr = value` writes update
  the pointer target.
- `with`: `WithStatement` seeds DMD's `wthis` temporary for struct
  receivers and writes the pointer target back to the original receiver
  after the body. Enum `with` bodies run directly because semantic
  analysis has already resolved the member references.
- Static-array struct literal fields from scalar initializers: when a
  struct literal field is a static array and DMD provides a scalar
  initializer, the interpreter repeats that value to the static length.
- Nested struct methods reading captured locals: member-function walkers
  inherit the caller locals so nested struct methods can read enclosing
  locals captured through semantic lowering. Captured-local mutation is
  not implemented by this slice.
- Narrow destructor expressions: `DtorExpStatement` evaluates DMD's
  synthesized destructor expression. The promoted fixture also needed
  narrow dynamic-array field alias tracking for `S(sink)` so
  `this.sink[index] += value` in the destructor updates the original
  local array backing value. This is not general lifetime support.

Deferred:

- `with.structLocalGotoRestartsInsideBody`: the first red failure is
  `Unsupported eval statement: Goto`. The interpreter has no
  `GotoStatement` or `LabelStatement` machinery yet, and the general
  goto coverage in `ct/control_flow.d` is still outside `Interpreter`.
- `struct.staticArrayCopyRunsPostblitAndDtors`: a narrow `TryFinally`
  handler reaches the next missing piece, `symbolOffset`, and the test
  then needs location-backed pointers stored in struct fields so
  postblit/destructor calls can mutate original locals. This is broader
  pointer/write-back semantics, not a small CT structs slice.

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
- Use `ai/plans/backend-test-modules-order.md` to choose post-`eval` targets
  by required D language features, not by file length or coverage counts.
  `SystemLinker` is the oracle (`ai/plans/single-oracle.md`).
- After each slice, run `ninja bin/ut` and `bin/ut --random` to catch
  regressions.

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
