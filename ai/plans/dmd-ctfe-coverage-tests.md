# DMD CTFE Coverage-Driven Tests

## Goal

Use DMD coverage data to find untested methods in the CTFE engine and turn
every reachable method-level gap into a focused Quickbite test.

The primary target is DMD's CTFE interpreter:

- `dmd.dinterpret`
- local source path from `dub.selections.json`:
  `/home/atila/.dub/packages/dmd/2.112.0/dmd/compiler/src/dmd/dinterpret.d`

Whole uncovered visitor methods for expression or statement AST nodes are the
highest-priority gaps. Method coverage is the goal; line hits matter only as
evidence that a method is now reached.

## Status

The coverage workflow described below now exists in repository-owned scripts.
The remaining work is to keep expanding the pure-backend CTFE test suite while
maintaining an up-to-date method coverage audit.

## Historical Baseline

Quickbite already has a `unittest-cov` configuration in `dub.sdl`. Before the
repository-owned coverage scripts existed, a local probe paired it with
`--build=unittest-cov`, which causes DUB/DMD to build with coverage enabled.

A local probe of:

```sh
dub test --build=unittest-cov -- \
    ut.backends.pure_.lang.expressions.intAddition.Ctfe
```

failed at link time while building instrumented DMD frontend libraries:

```text
undefined symbol: ModuleInfo for dmd.link
undefined symbol: dmd.link.runPreprocessor(...)
```

Both unresolved symbols were referenced from `dmd.cpreprocess`. Treat this as
a coverage-workflow issue to investigate before relying on fresh coverage
output. Do not edit files under `~/.dub/packages` directly to fix it.

The repository root still contains historical DMD coverage `.lst` files from
older runs and package versions. Treat them as format examples only.
Regenerate coverage before choosing the next test target.

## Coverage Workflow

Create a repo-owned way to generate CTFE coverage without modifying vendored or
DUB package files in place.

The workflow should:

- build and run the Quickbite CTFE backend tests with DMD coverage enabled;
- include coverage for dependency source modules, especially `dmd.dinterpret`;
- write generated `.lst` coverage files to a predictable ignored location or
  document the existing DMD output location clearly;
- avoid running coverage in parallel with normal `dub test` in the same
  checkout;
- keep the ordinary `dub test` path unchanged.

If the `dmd.cpreprocess`/`dmd.link` linker failure still reproduces, fix the
coverage workflow in Quickbite-owned code or scripts. A likely route is a
temporary DUB package/build setup that includes the DMD frontend source needed
for the instrumented build, without changing the checked-in dependency package.

After the workflow runs, parse the `dmd.dinterpret` `.lst` file and group
`0000000|` lines by enclosing function or visitor method. The useful report is
method-centric. It should separate:

- wholly uncovered `interpretStatement` statement visitor methods;
- wholly uncovered `Interpreter.visit(...)` expression visitor methods;
- partially covered visitor methods with important branch gaps;
- CTFE helper functions not tied to one AST node;
- lines that are defensive, impossible, or not reachable from semantic D code.

The current implementation is intentionally lightweight:

- `scripts/dmd-ctfe-coverage.sh` runs the coverage build, copies the newest
  `dmd.dinterpret` `.lst` file into `tmp/dmd-ctfe-coverage/`, and writes the
  audit report there.
- `scripts/report-dmd-ctfe-coverage.sh` buckets the current coverage output by
  the CTFE visitor and helper signatures it recognizes today.
- If the audit taxonomy needs to expand beyond those signature forms, update
  the script and this plan together.

## Test Selection

Add tests one behaviour at a time. Approval is required before adding a new
test or modifying test behaviour. The only approval exception is adding a
backend to an existing backend-matrix test. A test is good for this work when
all of the following are true:

- it passes normally;
- it fails when the expected result or diagnostic is deliberately poked;
- focused CTFE coverage shows the intended `dmd.dinterpret` method or branch
  is newly covered;
- the slice has no production-code changes.

For each uncovered method group:

1. Identify the smallest D source fixture that should reach the uncovered CTFE
   code through normal semantic analysis.
2. Check whether the fixture represents valid D language behaviour. For
   `pure_` tests, DMD CTFE is the canonical oracle unless completed DMD codegen
   proves compiled D differs.
3. Prefer a normal passing behaviour test. Use a diagnostic test only when the
   uncovered path is genuinely an error path.
4. Add the test under the closest existing backend pure-test module, such as
   `tests/ut/backends/pure_/lang/expressions.d`,
   `tests/ut/backends/pure_/lang/control_flow.d`,
   `tests/ut/backends/pure_/lang/arrays.d`,
   `tests/ut/backends/pure_/lang/structs.d`, or
   `tests/ut/backends/pure_/lang/exceptions.d`.
5. Run the focused test, then regenerate CTFE coverage and confirm the intended
   `dmd.dinterpret` lines changed from uncovered to covered in the same method.

Avoid all-literal fixtures unless constant folding itself is the target. Use
runtime-shaped values such as mutable locals or helper calls so DMD does not
fold away the AST node before CTFE interprets it.

Do not add tests for internal assertions, compiler consistency checks, frontend
states that semantic analysis rewrites away, or impossible AST shapes. Record
those gaps with the exact line or method and a short reason.

### Known Unreachable Targets

The following methods must not be proposed as test targets. The D frontend
rewrites or rejects the surface syntax before CTFE is invoked, so no valid D
fixture can cover these lines:

| Method | Reason |
| --- | --- |
| `visitWhile` | Rewritten to `ForStatement` by semantic analysis |
| `visitForeach` / `visitForeachRange` | Rewritten to `ForStatement` by semantic analysis |
| `visitScopeGuard` | Lowered to try-finally by semantic analysis |
| `visit(VoidInitExp)` | Internal uninitialized-variable marker; never re-interpreted |
| `visit(ThrownExceptionExp)` | Internal already-processed exception; never re-entered |
| `visit(DeleteExp)` | DMD 2.112 rejects `delete` in semantic analysis before CTFE |
| `visitTryFinally` | Semantic analysis lowers fall-through `try/finally` to `CompoundStatement`; two independent probes left the whole method uncovered |
| `visit(DotTypeExp)` | Property accesses (`.sizeof`, `.alignof`, etc.) are constant-folded at semantic time before CTFE; two independent probes confirmed no valid D fixture reaches this visitor |

Before proposing any target, the explorer subagent must check whether the
method body contains `assert(0)` or a comment like "rewritten to X". If so,
record it in the Audit Log as "Not reachable / semantic rewrite" and move on.

## PR Coverage Report

When creating a PR from this plan, report the CTFE method coverage delta in the
PR. Line coverage deltas are optional context, not the success metric.

Use the same broad coverage target at the branch's starting commit and at the
final PR branch commit. For the current plan, the broad target is:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

Create the worktree, record the starting commit SHA, and calculate the baseline
coverage before making the first work commit. Do not calculate the baseline
from moving `master` after work has started. Use the starting-commit baseline
for the whole PR, even if `master` changes or merges happen while the branch is
in progress.

Calculate method coverage from executable entries in
`tmp/dmd-ctfe-coverage/dmd-dinterpret.lst` for the starting commit and final
PR commit. Do not use the final DMD footer line; it rounds to a whole
percentage and can hide small PR deltas.

Executable entries are `.lst` lines whose seven-character counter prefix is
either a run count or `0000000`. Count `0000000` as uncovered, and count any
positive run count as covered. Roll those lines up by method and report:

- the starting commit SHA and baseline method coverage;
- the final PR branch commit SHA and method coverage;
- the method-coverage delta;
- the method-level coverage change that motivated the test, such as a visitor
  moving from wholly uncovered to partially covered.

Operationally, the orchestrator should:

1. Create the git worktree.
2. Immediately record the starting commit SHA and run the broad coverage
   target to capture the baseline coverage percentage for that exact
   worktree-start commit.
3. Keep that baseline fixed for the whole branch.
4. Right before creating the PR, rerun the same broad coverage target at the
   branch head, compare it with the recorded baseline, and show the delta in
   the PR body.

This matches the earlier CTFE PR summaries, which reported the branch-start
baseline, the final branch-head coverage, and the difference between them.

Do not compare a focused single-test coverage run against the broad baseline.
Focused runs are useful for proving that a specific fixture hits the intended
method, but their percentages are not comparable to the full
`ut.backends.pure_` coverage percentage.

## Audit Log

Keep an audit table in this plan or in a sibling coverage audit file. Each row
should track one uncovered CTFE method or coherent branch group.

Suggested columns:

| DMD CTFE area | Coverage status | Test or reason | Notes |
| --- | --- | --- | --- |
| `visit(FooExp)` | Needs triage | Pending | Whole method |
| `visitBar` line N | Covered | `test.name.Ctfe` | Focused fixture |
| `visitBaz` assertion | Not reachable | Semantic rewrite | No test |

Update the table as tests are added or targets are rejected. Do not leave
uncovered reachable methods as undocumented backlog.

## Subagent Workflow

For future PR slices on this plan, the main agent should orchestrate only:

Spawn all explorer and worker subagents for this plan with
`gpt-5.3-codex-spark`.

1. Ask an explorer subagent to inspect the fresh coverage audit, DMD CTFE
   source, and nearby tests, then recommend the next reachable additive test
   target. The explorer must verify the candidate method does not appear in
   the Known Unreachable Targets table and does not contain `assert(0)` or a
   "rewritten to X" comment in `dmd.dinterpret`.
2. Spawn a worker subagent for the chosen target. The worker must follow a
   probe-first workflow:
   a. Write the minimal behavior test only (no failure-message tests yet).
   b. Run `scripts/dmd-ctfe-coverage.sh <test-name>` immediately and check
      whether the targeted method or branch shows new hits in the `.lst`.
   c. If coverage moved: write the failure-message tests, poke-check, and
      prepare the full commit.
   d. If coverage did not move: discard the probe, record the target as
      "Diagnostic fires before target logic" in the Audit Log, and report
      back to the orchestrator to pick a new target. Do not write
      failure-message tests for a fixture that does not hit the intended lines.
3. Review the worker diff, verify, update this plan if needed, and commit.

Do not choose the next CTFE target locally before the explorer has reported.
Use medium reasoning for routine explorer and worker subagents unless a slice
has a specific complexity that justifies a higher setting.
Create one git worktree at the start of the orchestration session and keep it
for the entire session. All workers operate inside that same worktree. Do not
create a new worktree per worker or per target. The worktree is created once
(step 1 of the PR Coverage Report section), all commits land on that branch,
and the PR is opened from it at the end.
Create the PR once coverage improvement starts moving only incrementally
despite valid additive slices; do not grind indefinitely chasing a large delta.

## 2026-06-02 Research Findings

A four-subagent research session audited the remaining uncovered methods in
`dmd.dinterpret` and produced the candidate list above. Key findings:

**Confirmed unreachable (added to Known Unreachable Targets):**

- `visitTryFinally` — semantic analysis lowers fall-through `try/finally` to a
  plain `CompoundStatement` before CTFE runs. Two independent probes (Worker 5
  of dmd-ctfe-coverage-tests-6 and a second probe in this session) left the
  whole method uncovered with passing fixtures.
- `visit(DotTypeExp)` — property accesses such as `.sizeof` and `.alignof` are
  constant-folded to `IntegerExp` at semantic analysis time and never create a
  `DotTypeExp` node. Two independent probes confirmed no valid D fixture reaches
  this visitor.

**Coverage data staleness warning:**

The `tmp/dmd-ctfe-coverage/` files are from a previous run and do not reflect
recent PRs. One subagent reported `interpret_dup` as uncovered, but the plan
archive confirms it was covered in Worker 7 of dmd-ctfe-coverage-tests-11.
Regenerate coverage with `scripts/dmd-ctfe-coverage.sh ut.backends.pure_`
before starting the next worker session and before triaging any Pending entry
in the Audit Log.

**Unconfirmed coverage from PR #11 workers:**

Workers 5 and 6 of dmd-ctfe-coverage-tests-11 added tests that passed but did
not run the coverage script to confirm the target methods moved. Both are
marked "Coverage unconfirmed" in the Audit Log. Re-verify as part of the next
broad coverage run.

**Why PR #106 produced zero coverage gain:**

The `assocArrayForeachAccumulatesRuntimePairs` fixture exercised
`interpret_aaApply`, but the paths it hit were already covered by earlier tests.
The probe-first rule (run focused coverage before keeping any test) was not
enforced. That rule is a hard gate, not advisory.

## Archive

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 1

Branch `dmd-ctfe-coverage-tests-11` started from:

```text
928d84fe72bc8c957dbf7de4e750ed1346ee2220
```

Starting broad coverage for:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

was 2210/3760 executable entries, or 58.78%.

The current test-selection workflow requires approval before adding or
modifying tests. For this coverage work, a proposed test is accepted when it
passes normally, fails when poked, increases focused CTFE coverage for the
target, and changes no production code.

Explorer recommendation 1 targeted the whole-method uncovered
`interpret_aaIn` helper, reached through normal associative-array
`key in aa` syntax.

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.arrays.assocArrayInFindsRuntimeKey.Ctfe
```

Coverage effect: focused coverage moved `interpret_aaIn` from whole-method
uncovered to partially covered. The focused `.lst` showed two hook calls, one
found-key path returning `pointerToAAValue`, and one missing-key path returning
`NullExp`.

Poke result: changing the behavior assertion from `40` to `41` failed the
focused CTFE test with `40 != 41`; the temporary poke was reverted and the
focused test was rerun green.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.arrays.assocArrayInFindsRuntimeKey.Ctfe` passed.
- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.arrays.assocArrayInFindsRuntimeKey.Ctfe` passed.
- A post-slice broad coverage run passed with 2225/3760 executable entries,
  or 59.18%.
- `dub test -- --random` passed with 1453 tests run, 0 failed, and 28/28
  failing as expected.
- The slice changed only test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 2

Explorer recommendation 2 targeted the reachable associative-array equality
helper `interpret_aaEqual`, reached through normal `==` and `!=`
associative-array comparisons with runtime-shaped keys and values.

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.arrays.assocArrayEqualityComparesRuntimeEntries.Ctfe
```

Coverage effect: focused coverage hit the `_d_aaEqual` dispatch twice and
`interpret_aaEqual` twice. The focused `.lst` showed both operand
interpretations, the `ctfeEqual` call, and the boolean result path covered.

Poke result: changing the inequality assertion to
`assert(left == different);` failed the focused CTFE test with
`[10: 40, 11: 41] != [10: 40, 11: 42]`; the temporary poke was reverted and
the focused test was rerun green.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.arrays.assocArrayEqualityComparesRuntimeEntries.Ctfe`
  passed.
- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.arrays.assocArrayEqualityComparesRuntimeEntries.Ctfe`
  passed after sandbox escalation because DUB needed to update generated files
  under `~/.dub`.
- A post-slice broad coverage run passed with 2232/3760 executable entries,
  or 59.36%.
- `dub test -- --random` passed with 1454 tests run, 0 failed, and 28/28
  failing as expected.
- The slice changed only test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 3

Explorer target: `foreachApplyUtf` helper in `dmd.dinterpret`, reached via
`foreach (dchar c; s)` over a multi-byte UTF-8 `string`.

Added pure-backend CTFE tests:

```text
ut.backends.pure_.lang.control_flow.foreachUtf8String.Ctfe
ut.backends.pure_.lang.control_flow.foreachUtf8StringFailureMessage.0.Ctfe
ut.backends.pure_.lang.control_flow.foreachUtf8StringFailureMessage.1.Ctfe
```

The behavior test builds a two-character UTF-8 string (`'a'` + U+00E9
as a 2-byte sequence) with mutable `char[]` locals and verifies CTFE
decodes it to two `dchar` values. Failure-message tests poke the length
assertion and the character value.

Coverage effect: `foreachApplyUtf` moved from whole-method uncovered to
partially covered; the broad `.lst` shows the function's first executable
lines hit 3 times.

Broad coverage command:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

Executable-entry coverage from
`tmp/dmd-ctfe-coverage/dmd-dinterpret.lst`:

| Checkout | Covered | Total | Coverage |
| --- | ---: | ---: | ---: |
| Worker 2 end (baseline) | 2232 | 3760 | 59.36% |
| Worker 3 final | 2307 | 3765 | 61.28% |

Delta: +1.92 percentage points.

Verification notes:

- `dub test` passed with 1458 tests run, 0 failed, 28/28 failing as
  expected.
- `scripts/dmd-ctfe-coverage.sh ut.backends.pure_` passed with 726
  tests run, 0 failed, 28/28 failing as expected.
- The slice changed only test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 4

Explorer target: `visit(CastExp)` pointer-painting branch for runtime-cast
`void*` values.

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.expressions.castExpTypePaintedSliceFromVoidPointer.Ctfe
```

Coverage effect: focused run covered the runtime pointer paint in `visit(CastExp)`
and removed part of the previously unresolved type-painting gap.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.expressions.castExpTypePaintedSliceFromVoidPointer.Ctfe`
  passed.
- The slice changed only the plan file.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 5

Explorer target: `visit(ComplexExp)` through runtime-shaped complex literals.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.expressions.complexLiteralWithRuntimeParts.Ctfe
ut.backends.pure_.lang.expressions.complexLiteralWithRuntimePartsFailureMessage.Ctfe
```

The behavior test builds a runtime integer and casts it to `cdouble`,
then adds a `1.0i` literal.

Focused coverage expectation: `visit(ComplexExp)` should be covered by this fixture
through the complex-literal node produced by `1.0i`.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.expressions.complexLiteralWithRuntimeParts.Ctfe`
  passed.
- `dub test -- --random
  ut.backends.pure_.lang.expressions.complexLiteralWithRuntimePartsFailureMessage.Ctfe`
  passed.
- The slice changed only the test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 6

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.expressions.interfaceVirtualCallUsesRuntimeDispatch.Ctfe
```

Coverage intent: cover interface-dispatch call behavior through an interface
typed value constructed from a runtime class instance.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.expressions.interfaceVirtualCallUsesRuntimeDispatch.Ctfe`
  passed.
- The slice changed only the test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 7

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.arrays.assocArrayDupCopiesEntries.Ctfe
```

Coverage intent: cover `interpret_dup` through runtime associative-array
duplication.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.arrays.assocArrayDupCopiesEntries.Ctfe`
  passed.
- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.arrays.assocArrayDupCopiesEntries.Ctfe`
  passed.
- Focused coverage hit `interpret_dup`: argument interpretation, literal copy,
  key/value postblit checks, mutable AA type repaint, and return.
- The slice changed only the test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 8

Probe discarded. The candidate fixture:

```text
ut.backends.pure_.lang.expressions.dotTypePropertySizeofUsesRuntimeSeed.Ctfe
```

was intended to cover `visit(DotTypeExp)` through a type-property path
(`int.sizeof`) from a runtime-shaped local expression.

Verification notes:

- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.expressions.dotTypePropertySizeofUsesRuntimeSeed.Ctfe`
  passed.
- Focused coverage showed all executable lines in `visit(DotTypeExp)` still
  uncovered, so the probe did not hit the intended target logic.
- No test was kept for this target.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 9

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.expressions.runtimePointerOffsetReadsElement.Ctfe
```

Coverage intent: exercise runtime pointer-offset access through a local
`int*` created from a dynamic array.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.expressions.runtimePointerOffsetReadsElement.Ctfe`
  passed.
- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.expressions.runtimePointerOffsetReadsElement.Ctfe`
  passed.
- Focused coverage hit the `BinExp` pointer-plus-integral branch and the
  `pointerArithmetic` result path.
- The slice changed only the test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 10

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.expressions.runtimePointerDifferenceReadsElement.Ctfe
```

Coverage intent: exercise runtime pointer subtraction (`-` with integer offset)
followed by indirect element access.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.expressions.runtimePointerDifferenceReadsElement.Ctfe`
  passed.
- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.expressions.runtimePointerDifferenceReadsElement.Ctfe`
  passed.
- Focused coverage hit the `BinExp` pointer-minus-integral branch and the
  `pointerArithmetic` result path.
- The slice changed only the test and plan files.

### 2026-05-28 Workflow Slice

The repository now has `scripts/dmd-ctfe-coverage.sh` for generating fresh
`dmd.dinterpret` coverage without editing files under `~/.dub/packages`.
Run it from any directory in the checkout, passing optional unit-threaded test
names as script arguments, for example:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.expressions.intAddition.Ctfe
```

The script forces the `unittest-cov` build so dependency coverage is rebuilt,
runs the selected CTFE backend tests, copies the newest non-empty
`dmd.dinterpret` `.lst` file to `tmp/dmd-ctfe-coverage/dmd-dinterpret.lst`,
and writes an initial uncovered visitor report to
`tmp/dmd-ctfe-coverage/dmd-dinterpret-audit.md`.

The previous `dmd.cpreprocess`/`dmd.link` linker failure was caused by
`dmd:frontend` compiling `dmd.cpreprocess` while excluding `dmd.link`.  The
`unittest-cov` configuration now includes a coverage-only Quickbite-owned
`dmd.link` shim under `tests/coverage`; ordinary `dub test` does not compile
that shim.

| DMD CTFE area | Coverage status | Test or reason | Notes |
| --- | --- | --- | --- |
| Coverage workflow | Covered | Script smoke test | Fresh coverage works. |
| `visit(CatExp)` | Covered | Array concatenation test | Was whole method. |
| `visit(CatExp)` elem paths | Covered | Worker 1 slice | See details below. |
| `visit(CatExp)` array wrap | Unsupported | Worker 1 | See below. |
| `visit(AssocArrayLiteralExp)` | Covered | Worker 1 slice | Now partial. |
| `interpret_aaIn` found/missing | Covered | `ut.backends.pure_.lang.arrays.assocArrayInFindsRuntimeKey.Ctfe` | Runtime key `in` returns pointer/null. |
| `interpret_aaEqual` equality/inequality | Covered | `ut.backends.pure_.lang.arrays.assocArrayEqualityComparesRuntimeEntries.Ctfe` | Runtime-shaped AA keys and values cover `_d_aaEqual` dispatch. |
| `visit(GotoCaseStatement)` | Covered | Worker 1 slice | Now partial. |
| `visit(GotoDefaultStatement)` | Covered | Worker 1 slice | Now partial. |
| `visitDo(DoStatement)` paths | Covered | Worker 1 slice | Fewer gaps. |
| `visitWith(WithStatement)` | Covered | Worker 2 slice | Now partial. |
| `visitUnrolledLoop` | Covered | Worker 3 slice | Now partial. |
| `visit(CommaExp)` | Covered | Worker 4 slice | Now partial. |
| `visit(StructLiteralExp)` | Covered | `ut.backends.pure_.lang.structs.structLiteralDefaultsMissingFieldToZero.Ctfe` | Missing field default-init path now covered. |
| `visitTryCatch` catch var binding | Covered | Worker 6 slice | See below. |
| `visitTryCatch` handler local goto | Covered | Worker 1 slice | Restart path covered. |
| `visitTryFinally` body local goto | Covered | Worker 1 slice | Finalbody runs once. |
| `visitWith(WithStatement)` enum body | Covered | Worker 7 slice | See below. |
| `visit(VectorExp)` scalar splat | Covered | dmd-ctfe-coverage-tests-5 Worker 2 | See below. |
| `visit(VectorArrayExp)` vector to array | Covered | dmd-ctfe-coverage-tests-5 Worker 2 | See below. |
| Non-array control/exception/delegate/typeid branches | Covered | dmd-ctfe-coverage-tests-5 Worker 10 | See below. |
| `visitContinue` labeled continue | Covered | dmd-ctfe-coverage-tests-5 Worker 9 | `labeledContinueSkipsToOuterForIncrement.Ctfe`; hits outer continue propagation through `visitFor`. |
| `visit(NewExp)` class allocation and `visit(CallExp)` virtual call | Covered | dmd-ctfe-coverage-tests-5 Worker 9 | `classVirtualCallUsesDynamicClass.Ctfe`; dynamic override dispatch uses constructor-derived field. |
| `visit(TypeidExp)` type form and `DotVarExp.name` | Covered | dmd-ctfe-coverage-tests-5 Worker 9 | `typeidTypeNameReturnsIdentifier.Ctfe`; DMD CTFE name is `Widget`. |
| `visit(CallExp)` null class method call | Covered | dmd-ctfe-coverage-tests-5 Worker 9 | `nullClassMethodCallReportsDiagnostic.Ctfe`; exact diagnostic includes `` `null` ``. |
| `visit(DotVarExp)` null class field read | Covered | dmd-ctfe-coverage-tests-5 Worker 9 | `nullClassFieldReadReportsDiagnostic.Ctfe`; exact diagnostic includes `` `null` ``. |
| `DeclarationExp` void init and `getVarExp` uninitialized read | Covered | dmd-ctfe-coverage-tests-5 Worker 9 | `voidInitializedScalarReadReportsUninitialized.Ctfe`; generated snippet counter is order-dependent, so the test checks stable DMD diagnostic parts. |
| `visit(StructLiteralExp)` static array fill | Covered | dmd-ctfe-coverage-tests-5 Worker 7 | Scalar struct literal field fill. |
| `recursivelyCreateArrayLiteral` nested arrays | Covered | dmd-ctfe-coverage-tests-5 Worker 7 | Runtime multidimensional `new`. |
| `visit(NewExp)` scalar allocation | Covered | dmd-ctfe-coverage-tests-5 Worker 7 | Runtime scalar pointer value. |
| `visitFor` labeled outer break | Covered | dmd-ctfe-coverage-tests-5 Worker 7 | Break bubbles out of inner loop. |
| `visit(SliceExp)` null zero-length slice | Covered | Worker 5 slice | See below. |
| `resolveIndexing(IndexExp)` slice OOB diagnostic | Covered | Worker 5 slice | See below. |
| `visit(DelegatePtrExp)` diagnostic | Covered | dmd-ctfe-coverage-tests-5 Worker 3 | `dg.ptr` CTFE rejection. |
| `visit(DelegateFuncptrExp)` diagnostic | Covered | dmd-ctfe-coverage-tests-5 Worker 3 | `dg.funcptr` CTFE rejection. |
| `visitWith(WithStatement)` local goto restart | Covered | dmd-ctfe-coverage-tests-5 Worker 4 | `with` body `goto` restart. |
| `visit(DeleteExp)` | Unsupported | dmd-ctfe-coverage-tests-5 Worker 6 | `delete` rejected by DMD 2.112 semantic analysis. |
| Pointer relation across unrelated arrays | Covered | dmd-ctfe-coverage-tests-5 Worker 8 | Four-pointer false relation. |
| Dynamic array length assignment | Covered | dmd-ctfe-coverage-tests-5 Worker 8 | Grow, preserve, zero-fill, shrink. |
| Static multidimensional slice block assignment | Covered | dmd-ctfe-coverage-tests-5 Worker 8 | Recursive row repeat path. |
| Slice overlap and pointer-slice diagnostics | Covered | dmd-ctfe-coverage-tests-5 Worker 8 | DMD CTFE diagnostic substrings. |
| Hex-string array cast | Behavior covered | dmd-ctfe-coverage-tests-5 Worker 8 | DMD semantic cast path handled before `dinterpret`. |
| `interpret_dup` AA duplication | Covered | `ut.backends.pure_.lang.arrays.assocArrayDupCopiesEntries.Ctfe` | Runtime associative-array `.dup` covers literal copy, key/value postblit checks, type repaint, and return. |
| `visit(NewExp)` struct allocation | Covered | dmd-ctfe-coverage-tests-6 Worker 1 | `newStructAllocatesMutableInstance.Ctfe`; hits non-constructor `new Struct(args)` allocation and mutable pointer use. |
| `visit(ArrayLiteralExp)` omitted element copy | Not reachable | dmd-ctfe-coverage-tests-6 Worker 2 | Indexed array initializers are densified by semantic lowering before CTFE; range basis spelling rejected by DMD 2.112. |
| `visit(CondExp)` pointer condition | Covered | dmd-ctfe-coverage-tests-6 Worker 3 | `conditionalExpressionTreatsNonNullPointerAsTrue.Ctfe`; non-null pointer condition normalized to true. |
| `visitTryCatch` non-matching catch skip | Covered | dmd-ctfe-coverage-tests-6 Worker 4 | `catchSkipsNonMatchingSiblingException.Ctfe`; skips sibling handler and binds base catch variable. |
| `visitTryFinally` | Not reachable | Semantic rewrite | Semantic analysis lowers fall-through `try/finally` to `CompoundStatement`; two independent probes left whole-method uncovered. |
| `visitDtorExp(DtorExpStatement)` | Covered | dmd-ctfe-coverage-tests-6 Worker 6 | `scopeDestructorRunsAtCtfe.Ctfe`; scope-exit struct destructor mutates dynamic array state. |
| `visitDefault(DefaultStatement)` | Covered | dmd-ctfe-coverage-tests-6 Worker 7 | `switchFallsThroughToDefault.Ctfe`; normal switch default execution, not `goto default`. |
| `recursivelyCreateArrayLiteral` char dynamic array | Covered | dmd-ctfe-coverage-tests-6 Worker 8 | `newCharArrayUsesRuntimeLengthAndDefaultFill.Ctfe`; runtime `new char[]` default fill uses string-literal block path. |
| `resolveIndexing(IndexExp)` direct array OOB | Covered | dmd-ctfe-coverage-tests-6 Worker 9 | `dynamicArrayIndexPastLengthDiagnostic.Ctfe`; direct dynamic-array indexing, distinct from slice-index diagnostic. |
| `foreachApplyUtf` whole method | Covered | `foreachUtf8String.Ctfe` | 2-byte UTF-8 sequence via `foreach (dchar c; s)` with `bytes.idup`. Method now partially covered. |
| `visit(CastExp)` type-painting path | Covered | `ut.backends.pure_.lang.expressions.castExpTypePaintedSliceFromVoidPointer.Ctfe` | Runtime `void*` to array cast path now covers the pointer-painting branch in `visit(CastExp)` and closes part of the uncovered gap. |
| `visit(DotTypeExp)` | Not reachable | Semantic rewrite | Property accesses constant-folded before CTFE; two independent probes confirmed no valid D fixture reaches this visitor. |
| `BinExp` pointer-plus-integral branch | Covered | `ut.backends.pure_.lang.expressions.runtimePointerOffsetReadsElement.Ctfe` | Runtime `values.ptr + 1` hits the pointer arithmetic result path. |
| `BinExp` pointer-minus-integral branch | Covered | `ut.backends.pure_.lang.expressions.runtimePointerDifferenceReadsElement.Ctfe` | Runtime `tail - 1` hits the pointer arithmetic result path. |
| `interpret_aaGetRvalueX` missing key | Covered | `ut.backends.pure_.lang.arrays.assocArrayReadMissingKeyThrowsDiagnostic.Ctfe` | Missing runtime key hits the DMD CTFE diagnostic branch for AA reads. |
| `visit(PostExp)` postfix increment | Covered | `ut.backends.pure_.lang.expressions.postIncrementUsesRuntimeSeed.Ctfe` | Runtime `value++` hits `EXP.plusPlus` and `interpretAssignCommon` with post mode. |
| `visit(ComplexExp)` | Coverage unconfirmed | `complexLiteralWithRuntimeParts.Ctfe` added | Worker 5 (dmd-ctfe-coverage-tests-11) added tests and they passed, but the coverage script was not run to confirm the method moved; re-verify before marking covered. |
| `interfaceVirtualCallUsesRuntimeDispatch` | Coverage unconfirmed | `interfaceVirtualCallUsesRuntimeDispatch.Ctfe` added | Worker 6 (dmd-ctfe-coverage-tests-11) added test and it passed, but coverage was not confirmed; re-verify before marking covered. |
| `visitSwitch` no-default-no-match | Needs triage | Pending | `switch (seed) { case 1: ... }` where runtime seed matches no case and there is no default; should hit error path at dinterpret.d ~line 1289. High confidence. |
| `visitReturn` closure error path | Needs triage | Pending | Return a delegate that closes over a local variable; should hit "closures are not yet supported in CTFE" diagnostic at dinterpret.d ~lines 1008–1015. High confidence. |
| `visitUnrolledLoop` exception path | Needs triage | Pending | Throw inside an `AliasSeq`/expression-tuple unrolled loop body; hits `exceptionOrCant` return path at dinterpret.d ~lines 890, 900. High confidence. |
| `interpret_aaApply` empty AA | Needs triage | Pending | `foreach` over `(int[int]).init`; hits early-return at dinterpret.d ~line 7128 before any delegate call. High confidence. |
| `interpret_keys` null AA | Needs triage | Pending | `.keys` on a null AA in CTFE; hits null-AA early return at dinterpret.d ~lines 6862–6865. High confidence. |
| `interpret_values` null AA | Needs triage | Pending | `.values` on a null AA in CTFE; hits null-AA early return at dinterpret.d ~lines 6887–6890. High confidence. |
| `foreachApplyUtf` UTF-16 path | Needs triage | Pending | `foreach (dchar c; wstr)` over a runtime-shaped `wstring`; hits case 2 at dinterpret.d ~lines 7272–7286. High confidence. |
| `foreachApplyUtf` UTF-32 / reverse | Needs triage | Pending | `foreach (dchar c; dstr)` over a runtime-shaped `dstring`, or `foreach_reverse` over a string; hits case 4 or reverse path at dinterpret.d ~lines 7288–7297. High confidence. |
| `visitTryCatch` unmatched propagation | Needs triage | Pending | Throw an exception type that matches no catch handler; exception propagates uncaught out of the CTFE call, hitting the no-match path at dinterpret.d ~lines 1443–1444. High confidence. |
| `interpret_aaDel` null AA | Needs triage | Pending | `.remove` on a null AA in CTFE; hits null-AA early return at dinterpret.d ~line 6912. Medium confidence — semantic analysis may intercept. |
| `visit(CommaExp)` nested chain | Needs triage | Pending | Nested comma expression such as `(a += 1, b += 2, c)` to trigger the `firstComma` inner loop at dinterpret.d ~line 4860. Medium confidence. |

Coverage workflow details:

- Test command:
  `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.expressions.intAddition.Ctfe`
- Fresh non-empty `dmd.dinterpret` coverage can be generated and copied to
  `tmp/dmd-ctfe-coverage`.

`visit(CatExp)` details:

- Test:
  `ut.backends.pure_.lang.arrays.dynamicArrayConcatenation.Ctfe`
- Binary dynamic-array concatenation covers the previously wholly uncovered
  visitor.
- Remaining uncovered lines in the method are branch-specific error, copy, and
  `elem ~ array` paths.

### 2026-05-28 Worker 1 CTFE Slice

Added a focused pure-backend CTFE coverage slice for branch gaps in
`dmd.dinterpret`:

- `ut.backends.pure_.lang.arrays.arrayElementConcatenatesWithDynamicArray.Ctfe`
  covers scalar `elem ~ array` and `array ~ elem` `CatExp` paths with
  runtime-shaped operands.
- The associative-array literal test covers `visit(AssocArrayLiteralExp)` with
  mutable keys and values.
- `ut.backends.pure_.lang.control_flow.supportsGotoCase.Ctfe` covers
  `visit(GotoCaseStatement)`.
- `ut.backends.pure_.lang.control_flow.supportsGotoDefault.Ctfe` covers
  `visit(GotoDefaultStatement)`.
- `ut.backends.pure_.lang.control_flow.supportsDoWhileBreakAndContinue.Ctfe`
  covers `visitDo(DoStatement)` break and continue paths.

Broad coverage command:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

Executable-entry coverage from `tmp/dmd-ctfe-coverage/dmd-dinterpret.lst`:

| Checkout | Covered | Total | Coverage |
| --- | ---: | ---: | ---: |
| Pre-slice broad baseline | 1519 | 3764 | 40.36% |
| Worker 1 slice | 1637 | 3764 | 43.49% |

Delta: +3.13 percentage points.

Method-level changes in the fresh audit:

- `visit(AssocArrayLiteralExp)` moved from whole method uncovered to partially
  covered with 17 uncovered executable lines remaining.
- `visit(GotoCaseStatement)` moved from whole method uncovered to partially
  covered with only the resume-target branch uncovered.
- `visit(GotoDefaultStatement)` moved from whole method uncovered to partially
  covered with only the resume-target branch uncovered.
- `visitDo(DoStatement)` dropped from 16 to 10 uncovered executable lines.
- `visit(CatExp)` dropped from 9 to 8 uncovered executable lines.

Unsupported target:

- `int[] row; int[][] rows; row ~ rows` and the equivalent static-row variant
  both reach DMD CTFE's ``cannot be interpreted at compile time`` diagnostic.
  No passing behavior test was kept for the array-of-arrays operand-wrapping
  branch.

### 2026-05-28 Worker 2 CTFE Slice

Added a focused pure-backend CTFE coverage slice for a whole uncovered
statement visitor in `dmd.dinterpret`:

- Test:

```text
ut.backends.pure_.lang.structs.withStructInstanceUsesRuntimeShapedFields.Ctfe
```

- The test covers valid `with (structInstance)` behavior with mutable struct
  fields and a mutable local value so the field updates are interpreted at
  CTFE.
- The paired failure-message tests cover the same behavior through the local
  assertion diagnostic pattern.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
ut.backends.pure_.lang.structs.withStructInstanceUsesRuntimeShapedFields.Ctfe
```

Method-level change in the fresh focused audit:

- `visitWith(WithStatement)` moved from whole method uncovered to partially
  covered. The focused run leaves 17 uncovered executable lines, including
  resume-target handling, `with(Enum)` or `with(Type)` body execution, and
  exceptional-expression paths.

### 2026-05-28 Worker 3 CTFE Slice

Added a focused pure-backend CTFE coverage slice for a whole uncovered
statement visitor in `dmd.dinterpret`:

- Test:

```text
ut.backends.pure_.lang.control_flow.foreachExpressionTupleBreakAndContinue.Ctfe
```

- The test covers valid non-static `foreach` over an expression tuple built
  from mutable locals via `AliasSeq`, with local `continue` and `break`
  handling in the unrolled loop body.
- The paired failure-message tests cover the same behavior through the local
  assertion diagnostic pattern.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
ut.backends.pure_.lang.control_flow.foreachExpressionTupleBreakAndContinue.Ctfe
```

Method-level change in the fresh focused audit:

- `visitUnrolledLoop(UnrolledLoopStatement)` moved from whole method uncovered
  to partially covered. The focused run leaves 8 uncovered executable lines,
  including resume-target handling, exceptional-expression paths, and the
  return/thrown-expression forwarding path.

Verification notes:

- Focused tests passed for the behavior test and both failure-message tests.
- The assertion poke failed with the expected `2 != 3` diagnostic, then the
  focused tests passed again after reverting the poke.
- At the time of this focused slice, `dub test` had an unrelated
  order-sensitive failure in `ut.executors.deps.cerealed.cerealed.decode.d.ir`;
  the final branch verification below passed after restoring DMD 2.112.0 while
  keeping unit-threaded 2.2.4.

### 2026-05-28 Worker 4 CTFE Slice

Added a focused pure-backend CTFE coverage slice for a whole uncovered
expression visitor in `dmd.dinterpret`:

- Test:

```text
ut.backends.pure_.lang.expressions.commaExpressionSequencesOperands.Ctfe
```

- The test covers valid D comma expression-statement behavior with a mutable
  local initialized from a helper function, sequencing `+=` and `++` side
  effects before returning the final local value.
- The paired failure-message tests cover the same behavior through the local
  assertion diagnostic pattern.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
ut.backends.pure_.lang.expressions.commaExpressionSequencesOperands.Ctfe
```

Method-level change in the fresh focused audit:

- `visit(CommaExp)` moved from whole method uncovered to partially covered.
  The focused run leaves 22 uncovered executable lines, including declaration
  stack-frame handling, temporary-variable/lvalue handling, and
  exceptional-expression paths.

Verification notes:

- Focused tests passed for the behavior test and both failure-message tests.
- The assertion poke failed with the expected `6 != 7` diagnostic, then the
  focused tests passed again after reverting the poke.
- At the time of this focused slice, `dub test` had an unrelated
  order-sensitive failure in `ut.executors.deps.cerealed.cerealed.decode.d.ir`,
  reporting `No function body to execute: gc_inFinalizer`; the final branch
  verification below passed after restoring DMD 2.112.0 while keeping
  unit-threaded 2.2.4.

### 2026-05-28 Worker 5 CTFE Slice

Added a focused pure-backend CTFE coverage slice for direct `goto` to a label:

- Tests:

```text
ut.backends.pure_.lang.control_flow.supportsDirectGotoLabel.Ctfe
ut.backends.pure_.lang.control_flow.supportsDirectGotoLabelFailureMessage.0.Ctfe
ut.backends.pure_.lang.control_flow.supportsDirectGotoLabelFailureMessage.1.Ctfe
```

- The behavior test uses a helper and mutable local values so DMD CTFE executes
  a direct `GotoStatement` and the target `LabelStatement` body instead of
  relying on all-literal folding.
- Intended DMD CTFE methods: `visitGoto(GotoStatement)` and
  `visitLabel(LabelStatement)`.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
ut.backends.pure_.lang.control_flow.supportsDirectGotoLabel.Ctfe
```

Method-level change in the fresh focused audit:

- `visitGoto(GotoStatement)` moved from whole method uncovered to partially
  covered, with only the resume-target branch left uncovered.
- `visitLabel(LabelStatement)` no longer appears in the uncovered audit table;
  the focused `.lst` shows all executable lines in that method covered.

Verification notes:

- Focused tests passed for the behavior test and both failure-message tests.
- The assertion poke failed with the expected `8 != 9` diagnostic, then the
  focused tests passed again after reverting the poke.

### 2026-05-28 Worker 6 CTFE Slice

Explorer recommendation 1 targeted `visitTryCatch(TryCatchStatement)` in
`dmd.dinterpret`, specifically the catch-variable binding branch:
`ctfeGlobals.stack.push(ca.var); setValue(ca.var, ex.thrown);`.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.exceptions.catchExceptionBindsCaughtObject.Ctfe
ut.backends.pure_.lang.exceptions.catchExceptionBindsCaughtObjectFailureMessage.0.Ctfe
ut.backends.pure_.lang.exceptions.catchExceptionBindsCaughtObjectFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.exceptions.catchExceptionBindsCaughtObject.Ctfe
```

Coverage effect: focused coverage marked both target executable lines as hit
once:

- `ctfeGlobals.stack.push(ca.var);`
- `setValue(ca.var, ex.thrown);`

Poke result: changing the behavior test assertion from `8` to `9` failed the
focused CTFE test with `8 != 9`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-28 Worker 7 CTFE Slice

Explorer recommendation 2 targeted `visitWith(WithStatement)` in
`dmd.dinterpret`, specifically `with (Enum)` body execution through
`if (s.exp.op == EXP.scope_ || s.exp.op == EXP.type)`.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.structs.withEnumExecutesBody.Ctfe
ut.backends.pure_.lang.structs.withEnumExecutesBodyFailureMessage.0.Ctfe
ut.backends.pure_.lang.structs.withEnumExecutesBodyFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.structs.withEnumExecutesBody.Ctfe
```

Coverage effect: focused coverage marked the target `with (Enum)` body
execution line as hit:

- `result = interpretStatement(pue, s._body, istate);`

Poke result: changing the behavior test assertion from `10` to `11` failed the
focused CTFE test with `10 != 11`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-28 Worker 8 CTFE Slice

Explorer recommendation 1 targeted `visit(TypeidExp)` in `dmd.dinterpret`,
specifically the class-reference path that interprets the operand and rebuilds
`typeid` from the dynamic class.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.expressions.typeidClassReferenceUsesDynamicClass.Ctfe
ut.backends.pure_.lang.expressions.typeidClassReferenceUsesDynamicClassFailureMessage.0.Ctfe
ut.backends.pure_.lang.expressions.typeidClassReferenceUsesDynamicClassFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.expressions.typeidClassReferenceUsesDynamicClass.Ctfe
```

Coverage effect: focused coverage moved `visit(TypeidExp)` from whole-method
uncovered to partially covered, with the dynamic class-reference path hit once.
The focused audit reports 8 uncovered executable lines remaining for null,
internal-error, exception, and fallback paths.

Poke result: changing the behavior test assertion from `7` to `8` failed the
focused CTFE test with `7 != 8`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-28 Final PR Broad Coverage Summary

Broad coverage command:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

Executable-entry coverage from `tmp/dmd-ctfe-coverage/dmd-dinterpret.lst`:

| Checkout | Covered | Total | Coverage |
| --- | ---: | ---: | ---: |
| Master broad baseline | 1688 | 3764 | 44.85% |
| Final branch broad coverage | 1715 | 3764 | 45.56% |

Delta: +0.72 percentage points.

Method-level changes from the five new test slices:

- `visitGoto(GotoStatement)` moved from whole method uncovered to partially
  covered with only the resume-target branch remaining uncovered.
- `visitLabel(LabelStatement)` no longer appears in the uncovered audit table.
- `visitTryCatch(TryCatchStatement)` has the catch-variable binding branch
  covered and is partially covered with 21 uncovered executable lines
  remaining in the final broad audit.
- `visitWith(WithStatement)` has the `with (Enum)` body branch covered and is
  partially covered with 15 uncovered executable lines remaining in the final
  broad audit.
- `visit(TypeidExp)` moved from whole method uncovered to partially covered
  with 8 uncovered executable lines remaining in the final broad audit.

Verification notes:

- Focused tests passed for the added behavior tests and paired failure-message
  tests.
- Assertion poke checks failed with the expected diagnostics.
- Final selections used `dmd` 2.112.0 and `unit-threaded` 2.2.4.
- `dub test -- --random` passed with 1445 tests run, 0 failed, and 31/31
  failing as expected. Seed: `669684322`.
- `scripts/dmd-ctfe-coverage.sh ut.backends.pure_` passed for the final broad
  audit with 614 tests run, 0 failed, and 31/31 failing as expected.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 1

Explorer recommendation 1 targeted `visit(NewExp)` in `dmd.dinterpret`,
specifically the non-constructor struct allocation path for `new Struct(args)`.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.structs.newStructAllocatesMutableInstance.Ctfe
ut.backends.pure_.lang.structs.newStructAllocatesMutableInstanceFailureMessage.0.Ctfe
ut.backends.pure_.lang.structs.newStructAllocatesMutableInstanceFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.structs.newStructAllocatesMutableInstance.Ctfe
```

Coverage effect: focused coverage marked the `visit(NewExp)` struct allocation
branch as hit, including argument interpretation, struct literal construction,
and address creation for the allocated CTFE value.

Poke result: changing the behavior assertion from `seed * 4 + 3` to
`seed * 4 + 4` failed the focused CTFE test with `83 != 84`; the temporary
poke was reverted and the focused tests were rerun green.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 2

Explorer recommendation 2 targeted the omitted-element copy branch in
`visit(ArrayLiteralExp)`.

No test was kept. The candidate indexed initializer:

```d
int[4] values = [1: seed, 3: seed + 2];
```

is valid D, but DMD lowers it through `ArrayInitializer::toExpression` and
fills omitted entries with `defaultInit` before CTFE sees the
`ArrayLiteralExp`. The focused coverage run still left
`ex = copyLiteral(basis).copy();` uncovered. The apparent range-basis spelling
`[0 .. 4: 0, 1: seed, 3: seed + 2]` is rejected by DMD 2.112, so this target
is recorded as not reachable through normal D syntax.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 3

Explorer recommendation 3 targeted the pointer-condition normalization path in
`visit(CondExp)`.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.expressions.conditionalExpressionTreatsNonNullPointerAsTrue.Ctfe
ut.backends.pure_.lang.expressions.conditionalExpressionTreatsNonNullPointerAsTrueFailureMessage.0.Ctfe
ut.backends.pure_.lang.expressions.conditionalExpressionTreatsNonNullPointerAsTrueFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.expressions.conditionalExpressionTreatsNonNullPointerAsTrue.Ctfe
```

Coverage effect: focused coverage marked the pointer branch in
`visit(CondExp)` as hit, including `isPointer(e.econd.type)`,
`econd.op != EXP.null_`, and `IntegerExp.createBool(true)`.

Poke result: changing the behavior assertion from `42` to `43` failed the
focused CTFE test with `42 != 43`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 4

Explorer recommendation 4 targeted `visitTryCatch(TryCatchStatement)`,
specifically skipping a non-matching sibling catch before binding a base
`Exception` catch variable.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.exceptions.catchSkipsNonMatchingSiblingException.Ctfe
ut.backends.pure_.lang.exceptions.catchSkipsNonMatchingSiblingExceptionFailureMessage.0.Ctfe
ut.backends.pure_.lang.exceptions.catchSkipsNonMatchingSiblingExceptionFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.exceptions.catchSkipsNonMatchingSiblingException.Ctfe
```

Coverage effect: focused coverage marked the non-matching catch `continue`
branch as hit, then covered catch-variable stack binding for the base handler.

Poke result: changing the behavior assertion from `9` to `10` failed the
focused CTFE test with `9 != 10`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 5

Explorer recommendation 5 targeted `visitTryFinally(TryFinallyStatement)`,
specifically a normal body followed by a throwing `finally` block.

No test was kept. The candidate behavior was valid D and was poke-checked:
changing the expected assertion from `10` to `11` failed with `10 != 11`.
However, focused coverage for the candidate left `visitTryFinally` whole-method
uncovered, including `Expression ey = interpretStatement(s.finalbody, istate);`
and the `ey.isThrownExceptionExp()` branch. The temporary additive tests were
reverted.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 6

Explorer recommendation 6 targeted the wholly uncovered
`visitDtorExp(DtorExpStatement)` visitor.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.structs.scopeDestructorRunsAtCtfe.Ctfe
ut.backends.pure_.lang.structs.scopeDestructorRunsAtCtfeFailureMessage.0.Ctfe
ut.backends.pure_.lang.structs.scopeDestructorRunsAtCtfeFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.structs.scopeDestructorRunsAtCtfe.Ctfe
```

Coverage effect: focused coverage marked `visitDtorExp(DtorExpStatement)` as
hit once through a scope-exit struct destructor that mutates dynamic array
state.

Poke result: changing the behavior assertion from `7` to `8` failed the
focused CTFE test with `7 != 8`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 7

Explorer recommendation 7 targeted the wholly uncovered
`visitDefault(DefaultStatement)` visitor through normal switch default
execution.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.control_flow.switchFallsThroughToDefault.Ctfe
ut.backends.pure_.lang.control_flow.switchFallsThroughToDefaultFailureMessage.0.Ctfe
ut.backends.pure_.lang.control_flow.switchFallsThroughToDefaultFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.control_flow.switchFallsThroughToDefault.Ctfe
```

Coverage effect: focused coverage marked `visitDefault(DefaultStatement)` as
hit through a non-matching `switch` case falling through to `default`.

Poke result: changing the behavior assertion from `12` to `13` failed the
focused CTFE test with `12 != 13`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 8

Explorer recommendation 8 targeted the char-element branch in
`recursivelyCreateArrayLiteral` through runtime-length dynamic array
allocation.

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.arrays.newCharArrayUsesRuntimeLengthAndDefaultFill.Ctfe
ut.backends.pure_.lang.arrays.newCharArrayUsesRuntimeLengthAndDefaultFillFailureMessage.0.Ctfe
ut.backends.pure_.lang.arrays.newCharArrayUsesRuntimeLengthAndDefaultFillFailureMessage.1.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.arrays.newCharArrayUsesRuntimeLengthAndDefaultFill.Ctfe
```

Coverage effect: focused coverage marked the `elemType.ty.isSomeChar` branch
and `createBlockDuplicatedStringLiteral` return as hit for `new char[](len)`.
The test uses `char.init` for the default element value to match DMD CTFE and
compiled D behavior.

Poke result: changing the behavior assertion from `'e'` to `'f'` failed the
focused CTFE test with `'e' != 'f'`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Worker 9

Explorer recommendation 9 targeted the direct dynamic-array out-of-bounds
diagnostic in `resolveIndexing(IndexExp)`.

Added a focused pure-backend CTFE diagnostic test:

```text
ut.backends.pure_.lang.arrays.dynamicArrayIndexPastLengthDiagnostic.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.arrays.dynamicArrayIndexPastLengthDiagnostic.Ctfe
```

Coverage effect: focused coverage marked the non-slice indexing path and
direct array out-of-bounds diagnostic as hit. The slice-index out-of-bounds
branch remained untouched, confirming this test is distinct from the existing
slice diagnostic.

Poke result: changing the expected diagnostic substring from array index `3`
to `2` failed the focused test with the expected diagnostic mismatch; the
temporary poke was reverted and the focused test was rerun green.

### 2026-05-29 dmd-ctfe-coverage-tests-6 Final Summary

Branch `dmd-ctfe-coverage-tests-6` started from:

```text
e030826e6c945a439782e005071b453c3c8556ef
```

Broad coverage command:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

Executable-entry coverage from `tmp/dmd-ctfe-coverage/dmd-dinterpret.lst`:

| Checkout | Covered | Total | Coverage |
| --- | ---: | ---: | ---: |
| Starting commit broad baseline | 2126 | 3764 | 56.48% |
| Final branch broad coverage | 2134 | 3764 | 56.70% |

Delta: +0.21 percentage points.

Method-level changes from the kept test slices:

- `visit(NewExp)` struct allocation branch covered by
  `newStructAllocatesMutableInstance.Ctfe`.
- `visit(CondExp)` pointer-condition normalization covered by
  `conditionalExpressionTreatsNonNullPointerAsTrue.Ctfe`.
- `visitTryCatch(TryCatchStatement)` non-matching catch skip covered by
  `catchSkipsNonMatchingSiblingException.Ctfe`.
- `visitDtorExp(DtorExpStatement)` moved from whole-method uncovered to
  covered by `scopeDestructorRunsAtCtfe.Ctfe`.
- `visitDefault(DefaultStatement)` moved from whole-method uncovered to
  covered by `switchFallsThroughToDefault.Ctfe`.
- `recursivelyCreateArrayLiteral` char dynamic-array branch covered by
  `newCharArrayUsesRuntimeLengthAndDefaultFill.Ctfe`.
- `resolveIndexing(IndexExp)` direct dynamic-array out-of-bounds diagnostic
  covered by `dynamicArrayIndexPastLengthDiagnostic.Ctfe`.

Rejected or not-kept targets:

- `visit(ArrayLiteralExp)` omitted-element copy is not reachable through the
  indexed initializer spelling because semantic lowering densifies the
  initializer before CTFE.
- A valid `try`/`finally` throwing-finally fixture was poke-checked but did not
  hit `visitTryFinally`; the temporary tests were reverted.

Verification notes:

- Each kept additive behavior or diagnostic test was poke-checked and restored
  before commit.
- `dub test -- --random` passed after the final additive diagnostic slice with
  1601 tests run, 0 failed, and 28/28 failing as expected. Seed:
  `1659556447`.
- Final broad coverage passed with 766 tests run, 0 failed, and 28/28 failing
  as expected.

### 2026-05-28 dmd-ctfe-coverage-tests-4 Summary

Branch `dmd-ctfe-coverage-tests-4` added additive CTFE coverage tests in eight
commits after `master`:

1. `throwExpressionInConditionalIsCaught` covers `visit(ThrowExp)` and the
   `interpretThrow` class-reference path for a throw expression in a
   conditional that is caught.
2. `pointerArithmeticOverDynamicArray`, `pointerComparisonWithinArray`, and
   `pointerSliceFromDynamicArray` cover pointer arithmetic and difference,
   pointer comparison, and pointer slicing over dynamic arrays. The
   left-integral `n + p` form remains normalized before CTFE.
3. `assocArrayLiteralKeepsLastDuplicateRuntimeKey`,
   `assocArrayKeysAndValuesUseRuntimeLiteral`,
   `assocArrayRemoveRuntimeKey`, and `arrayOperationAddsRuntimeElements` add
   associative-array helper and array-operation behavior coverage. The first
   three hit the target helper branches; the array-operation test is valid
   additive behavior but did not hit the expected
   `interpretCommon.evaluate` array branch.
4. `newDynamicArrayUsesRuntimeLength` and
   `sliceAssignmentFromStringUpdatesArray` cover dynamic array `NewExp`
   allocation and `interpretAssignToSlice` paths.
5. `nestedDelegateCallUsesCapturedValue` and
   `arrayPointerCastDereferencesFirstElement` cover delegate and pointer-cast
   expressions. `typeidNameReadsTypeName` was rejected because DMD CTFE and
   semantic analysis reject that fixture.
6. `tryFinallyRunsFinalbody` and `tryFinallyRunsFinalbodyBeforeCatch` cover
   `visitTryFinally` normal execution, finalbody execution, and result
   propagation paths.
7. `newStructPointerInitializesFields` and `newStructPointerRunsConstructor`
   cover `visit(NewExp)` struct pointer field initialization and constructor
   paths.
8. `leftIntegralAddsToPointer`, `pointerIndexReadsDynamicArray`,
   `fourPointerRelationAcrossArraysReturnsFalse`,
   `sliceCastToPointerDereferencesFirstElement`, and
   `pointerCastToBoolReflectsNullness` add pointer and cast extras. The
   left-integral branch remains normalized before CTFE; the other tests hit
   their intended pointer index, four-pointer relation, slice-to-pointer cast,
   and pointer-to-bool cast paths.

Every added behavior test was assertion-poked and failed with the expected
assertion diagnostics, then the poke was reverted and the tests were rerun
green.

Final verification:

- `dub test -- --random` passed with 1509 tests run, 0 failed, and 31/31
  failing as expected. Seed: `1510666851`.
- `scripts/dmd-ctfe-coverage.sh ut.backends.pure_` passed with 677 tests run,
  0 failed, and 31/31 failing as expected.

Executable-entry coverage from `tmp/dmd-ctfe-coverage/dmd-dinterpret.lst`:

| Checkout | Covered | Total | Coverage |
| --- | ---: | ---: | ---: |
| Recorded master baseline | 1715 | 3764 | 45.56% |
| Final branch broad coverage | 1950 | 3764 | 51.81% |

Delta against the recorded baseline: +6.25 percentage points. A pre-merge
attempt to rerun `master` coverage failed twice with linker error
`SHT_SYMTAB_SHNDX has 0 entries, but the symbol table associated has 80532`.
After PR #70 was merged, a fresh `master` coverage run completed cleanly with
677 tests run, 0 failed, 28/28 failing as expected, and
1950/3764 = 51.81% executable-entry coverage. The delta is larger than the
prior PR delta, but still short of the requested 10-point aim.

### 2026-05-28 dmd-ctfe-coverage-tests-5 Worker 2 Slice

Added focused pure-backend CTFE tests for vector expressions:

```text
ut.backends.pure_.lang.expressions.vectorScalarCastSplatsToStaticArray.Ctfe
ut.backends.pure_.lang.expressions.vectorScalarCastSplatsToStaticArrayFailureMessage.0.Ctfe
ut.backends.pure_.lang.expressions.vectorScalarCastSplatsToStaticArrayFailureMessage.1.Ctfe
```

The behavior test uses a mutable scalar from a helper call, casts it to
`__vector(int[4])`, then reads the vector's `.array` property and verifies all
lanes. This targets DMD CTFE's scalar `visit(VectorExp)` path and the
`visit(VectorArrayExp)` vector-to-array conversion path.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.expressions.vectorScalarCastSplatsToStaticArray.Ctfe
```

Coverage effect: focused coverage moved `visit(VectorExp)` and
`visit(VectorArrayExp)` to partially covered. The `.lst` showed the scalar
splat path, `interpretVectorToArray`, and the `VectorArrayExp` return path hit.

Poke result: changing the behavior test assertion from `7` to `8` failed the
focused CTFE test with `7 != 8`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-28 dmd-ctfe-coverage-tests-5 Worker 4 Slice

Added focused pure-backend CTFE tests for `with` body local-goto restart:

```text
ut.backends.pure_.lang.structs.withStructLocalGotoRestartsInsideBody.Ctfe
ut.backends.pure_.lang.structs.withStructLocalGotoRestartsInsideBodyFailureMessage.0.Ctfe
ut.backends.pure_.lang.structs.withStructLocalGotoRestartsInsideBodyFailureMessage.1.Ctfe
```

The behavior test uses a mutable local struct field initialized from a function
argument, enters `with (point)`, and jumps to a label inside the same body. The
fixture proves CTFE resumes inside the `with` body and skips the statement
between `goto` and the target label.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.structs.withStructLocalGotoRestartsInsideBody.Ctfe
```

Coverage effect: focused coverage hit the `visitWith(WithStatement)` local-goto
restart loop around the `CTFEExp.isGotoExp(e)` branch.

Poke result: changing the behavior test assertion from `42` to `43` failed the
focused CTFE test with `42 != 43`; the temporary poke was reverted and the
focused tests were rerun green.

### 2026-05-28 dmd-ctfe-coverage-tests-5 Worker 5 Slice

Added focused pure-backend CTFE tests for dynamic-array slice/index gaps:

```text
ut.backends.pure_.lang.arrays.nullDynamicArrayZeroLengthSlice.Ctfe
ut.backends.pure_.lang.arrays.nullDynamicArrayZeroLengthSliceFailureMessage.0.Ctfe
ut.backends.pure_.lang.arrays.nullDynamicArrayZeroLengthSliceFailureMessage.1.Ctfe
ut.backends.pure_.lang.arrays.sliceIndexPastLengthDiagnostic.Ctfe
```

The zero-length slice fixture slices an uninitialized dynamic array with
runtime-shaped equal bounds from `values.length`. The diagnostic fixture builds
a runtime-shaped slice from a small array, then indexes past the slice length
and verifies DMD CTFE's `index 3 exceeds array length 2` diagnostic.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.arrays.nullDynamicArrayZeroLengthSlice.Ctfe \
    ut.backends.pure_.lang.arrays.sliceIndexPastLengthDiagnostic.Ctfe
```

Coverage effect: focused coverage hit the `visit(SliceExp)` `e1.op ==
EXP.null_` zero-length return branch and the `resolveIndexing(IndexExp)`
slice-index diagnostic branch.

Poke result: changing the zero-length behavior assertion from `0` to `1`
failed the focused CTFE test with `0 != 1`; changing the diagnostic expected
substring to `index 2 exceeds array length 2` failed with the actual message
`index 3 exceeds array length 2`. Both temporary pokes were reverted and the
focused tests were rerun green.

### 2026-05-28 dmd-ctfe-coverage-tests-5 Worker 6 Slice

Explorer recommendation targeted the whole uncovered
`Interpreter.visit(DeleteExp)` method in `dmd.dinterpret`.

No test was kept. DMD 2.112 rejects the proposed surface-language fixture before
CTFE or semantic interpretation can reach `DeleteExp`:

```text
/tmp/quickbite_delete_ctfe.d(14): Error: undefined identifier `delete`
/tmp/quickbite_delete_ctfe.d(14): Error: declaration
`quickbite_delete_ctfe.bumpViaDelete.box` is already defined
```

Rejected fixture shape:

```d
class Box {
    int[] sink;

    ~this() {
        sink[0] += 1;
    }
}

int bumpViaDelete(int seed) {
    int[] values = [seed];
    auto box = new Box;
    box.sink = values;
    delete box;
    return values[0];
}
```

Because DMD rejects `delete` during ordinary compilation, the uncovered CTFE
visitor is not reachable from valid D source in this compiler version.

### 2026-05-28 dmd-ctfe-coverage-tests-5 Worker 8 Array/Cast Slice

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.arrays.fourPointerRelationAcrossUnrelatedArraysReturnsFalse.Ctfe
ut.backends.pure_.lang.arrays.dynamicArrayLengthAssignmentResizesArray.Ctfe
ut.backends.pure_.lang.arrays.multidimensionalStaticArraySliceBlockAssignRepeatsRow.Ctfe
ut.backends.pure_.lang.arrays.overlappingSliceAssignmentIsRejectedAtCtfe.Ctfe
ut.backends.pure_.lang.arrays.pointerSlicePastAllocatedBlockDiagnostic.Ctfe
ut.backends.pure_.lang.expressions.hexStringCastToUshortArrayUsesBigEndianWords.Ctfe
```

The array fixtures use runtime-shaped seeds and bounds. The hex-string fixture
uses a literal because the literal cast is the behavior under test.

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.arrays.fourPointerRelationAcrossUnrelatedArraysReturnsFalse.Ctfe \
    ut.backends.pure_.lang.arrays.dynamicArrayLengthAssignmentResizesArray.Ctfe \
    ut.backends.pure_.lang.arrays.multidimensionalStaticArraySliceBlockAssignRepeatsRow.Ctfe \
    ut.backends.pure_.lang.arrays.overlappingSliceAssignmentIsRejectedAtCtfe.Ctfe \
    ut.backends.pure_.lang.arrays.pointerSlicePastAllocatedBlockDiagnostic.Ctfe \
    ut.backends.pure_.lang.expressions.hexStringCastToUshortArrayUsesBigEndianWords.Ctfe
```

Coverage effect: focused coverage hit `interpretFourPointerRelation`, the
dynamic-array length assignment branch in `interpretAssignCommon`, the
recursive static-array block assignment path in `interpretAssignToSlice`, the
array-overlap diagnostic, and the pointer-slice allocated-block diagnostic.
The hex-string behavior test passes, but DMD 2.112 semantic cast handling
normalizes this fixture before `dinterpret` reaches the hex-string array-cast
branch, so those `visit(CastExp)` lines remained uncovered in this run.

Poke results:

- Changing the unrelated-array relation expectation failed with
  `false != true`.
- Changing the dynamic-array length expectation failed with `4 != 3`.
- Changing the repeated-row expectation failed with `11 != 10`.
- Changing the overlap diagnostic substring reported the actual
  `overlapping slice assignment \`[1..3] = [0..2]\`` diagnostic.
- Changing the pointer-slice diagnostic substring reported the actual
  `pointer slice \`[1..3]\` exceeds allocated memory block \`[0..2]\``
  diagnostic.
- Changing the hex-string word expectation failed with `4660 != 13330`.

Verification notes:

- Focused behavior and paired failure-message tests passed.
- `scripts/dmd-ctfe-coverage.sh` passed for the focused primary tests.
- `dub test -- --random` passed with 1552 tests run, 0 failed, and 28/28
  failing as expected. Seed: `1355646905`.

### 2026-05-28 dmd-ctfe-coverage-tests-5 Worker 10 Non-Array Slice

Added focused pure-backend CTFE tests:

```text
ut.backends.pure_.lang.exceptions.tryFinallyGotoOutOfBodyRunsFinally.Ctfe
ut.backends.pure_.lang.exceptions.catchHandlerGotoLeavesHandler.Ctfe
ut.backends.pure_.lang.exceptions.finallyThrowChainsBodyException.Ctfe
ut.backends.pure_.lang.control_flow.switchBreaksOuterLoop.Ctfe
ut.backends.pure_.lang.expressions.structMemberDelegateCallUsesReceiver.Ctfe
ut.backends.pure_.lang.diagnostics.typeidNullClassReferenceReportsDiagnostic.Ctfe
```

Focused coverage command:

```sh
scripts/dmd-ctfe-coverage.sh \
    ut.backends.pure_.lang.exceptions.tryFinallyGotoOutOfBodyRunsFinally.Ctfe \
    ut.backends.pure_.lang.exceptions.catchHandlerGotoLeavesHandler.Ctfe \
    ut.backends.pure_.lang.exceptions.finallyThrowChainsBodyException.Ctfe \
    ut.backends.pure_.lang.control_flow.switchBreaksOuterLoop.Ctfe \
    ut.backends.pure_.lang.expressions.structMemberDelegateCallUsesReceiver.Ctfe \
    ut.backends.pure_.lang.diagnostics.typeidNullClassReferenceReportsDiagnostic.Ctfe
```

Coverage effect: focused coverage hit the catch-handler goto target-outside
branch, try/finally body goto target-outside branch, finalbody exception
chaining, switch break propagation above the switch, delegate receiver
interpretation and `DelegateExp` reconstruction, and the null class-reference
`typeid` diagnostic. Local DMD CTFE chains a finally-thrown exception behind
the body exception, so the encoded assertion is `47`.

Poke results:

- Changing the try/finally external-goto expectation failed with `14 != 15`.
- Changing the catch-handler external-goto expectation failed with `9 != 10`.
- Changing the finally/body exception-chain expectation failed with `47 != 48`.
- Changing the switch outer-break expectation failed with `14 != 15`.
- Changing the struct member delegate expectation failed with `10 != 11`.
- Changing the null `typeid` diagnostic substring reported the actual
  `null pointer dereference evaluating typeid. \`thing\` is \`null\``
  diagnostic.

Verification notes:

- Focused behavior and paired failure-message tests passed.
- `scripts/dmd-ctfe-coverage.sh` passed for the focused primary tests.

### 2026-05-28 dmd-ctfe-coverage-tests-5 Final Summary

Branch `dmd-ctfe-coverage-tests-5` added additive CTFE coverage tests across
arrays, control flow, exceptions, diagnostics, structs, class dispatch,
delegates, vectors, and typeid behavior. Every kept behavior or diagnostic
test was poked to prove it failed for the expected reason, then reverted and
rerun green. The `DeleteExp` target was documented as unreachable because DMD
2.112 rejects the surface-language `delete` fixture before CTFE.

Broad coverage command:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

Executable-entry coverage from `tmp/dmd-ctfe-coverage/dmd-dinterpret.lst`:

| Checkout | Covered | Total | Coverage |
| --- | ---: | ---: | ---: |
| Recorded branch baseline | 1950 | 3764 | 51.81% |
| Final branch broad coverage | 2126 | 3764 | 56.48% |

Delta against the recorded baseline: +4.67 percentage points. The branch did
not reach the 10-point aim; after multiple valid additive slices the broad
coverage gains were moving incrementally, so this slice should be sent as a PR
instead of grinding indefinitely.

Final broad coverage verification:

- `scripts/dmd-ctfe-coverage.sh ut.backends.pure_` passed with 747 tests run,
  0 failed, and 28/28 failing as expected.

### 2026-06-01 master-pr-ready PR Coverage Report

Starting broad coverage target:

```sh
scripts/dmd-ctfe-coverage.sh ut.backends.pure_
```

Starting commit:

```text
235dde61508b48403e25cb5a8fbd84f2fdffb6ff
```

Starting coverage:

```text
2306/3764 executable entries, or 61.26%
```

Branch-head coverage before adding this report:

```text
2340/3764 executable entries, or 62.17%
```

Coverage delta:

```text
+34 executable entries, or +0.91 percentage points
```

Method-level coverage changes:

- `interpret_dup` is covered through runtime associative-array `.dup`.
- `BinExp` pointer-plus-integral and pointer-minus-integral branches are
  covered by runtime pointer offset tests.
- `interpret_aaGetRvalueX` missing-key diagnostics are covered.
- `visit(PostExp)` postfix increment is covered through runtime `value++`.
- `visit(DotTypeExp)` was probed but did not move coverage, so the probe was
  discarded and recorded as not reaching target logic.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 11

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.arrays.assocArrayReadMissingKeyThrowsDiagnostic.Ctfe
```

Coverage intent: cover missing-key associative-array reads that surface the
expected runtime diagnostic in D's frontend/CTFE pipeline.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.arrays.assocArrayReadMissingKeyThrowsDiagnostic.Ctfe`
  passed.
- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.arrays.assocArrayReadMissingKeyThrowsDiagnostic.Ctfe`
  passed.
- Focused coverage hit `interpret_aaGetRvalueX`: AA/key interpretation,
  literal validation, failed key lookup, and missing-key diagnostic return.
- The slice changed only the test and plan files.

### 2026-06-01 dmd-ctfe-coverage-tests-11 Worker 12

Added focused pure-backend CTFE test:

```text
ut.backends.pure_.lang.expressions.postIncrementUsesRuntimeSeed.Ctfe
```

Coverage intent: cover runtime postfix-increment behavior through a mutable local
seed and verify both the expression result and updated variable value.

Verification notes:

- `dub test -- --random
  ut.backends.pure_.lang.expressions.postIncrementUsesRuntimeSeed.Ctfe` passed.
- `scripts/dmd-ctfe-coverage.sh
  ut.backends.pure_.lang.expressions.postIncrementUsesRuntimeSeed.Ctfe` passed.
- Focused coverage hit `visit(PostExp)` through the `EXP.plusPlus` branch and
  `interpretAssignCommon` with post mode.
- The slice changed only the test and plan files.

## Acceptance Criteria

- Fresh coverage for `dmd.dinterpret` can be generated from this repository.
- Every new test maps to at least one previously uncovered CTFE line or method.
- Reachable whole-method gaps for CTFE AST-node visitors are covered by focused
  tests.
- Remaining uncovered CTFE lines are explicitly classified as unreachable,
  defensive, unsupported, or pending.
- Final verification includes focused tests for each added fixture and a full
  `dub test`.
- PR reporting includes the starting commit SHA, final PR branch commit SHA,
  and `dmd.dinterpret` coverage percentages from the same broad coverage
  target.
