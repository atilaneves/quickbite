# DMD CTFE Coverage-Driven Tests

## Goal

Use DMD coverage data to find untested paths in the CTFE engine and turn every
reachable gap into a focused Quickbite test.

The primary target is DMD's CTFE interpreter:

- `dmd.dinterpret`
- local source path from `dub.selections.json`:
  `/home/atila/.dub/packages/dmd/2.112.0/dmd/compiler/src/dmd/dinterpret.d`

Whole uncovered visitor methods for expression or statement AST nodes should be
treated as the highest-priority gaps. Isolated uncovered lines should still be
triaged, but only reachable D semantics should become tests.

## Current Baseline

Quickbite already has a `unittest-cov` configuration in `dub.sdl`. It is meant
to be paired with `--build=unittest-cov`, which causes DUB/DMD to build with
coverage enabled.

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

Both unresolved symbols were referenced from `dmd.cpreprocess`. Treat this as a
coverage-workflow issue to investigate before relying on fresh coverage output.
Do not edit files under `~/.dub/packages` directly to fix it.

There are also stale DMD coverage `.lst` files in the repository root from an
older DMD package version. They are useful only as examples of DMD's coverage
file format; regenerate coverage before choosing tests.

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
`0000000|` lines by enclosing function or visitor method. The first useful
report should separate:

- wholly uncovered `interpretStatement` statement visitor methods;
- wholly uncovered `Interpreter.visit(...)` expression visitor methods;
- partially covered visitor methods with important branch gaps;
- CTFE helper functions not tied to one AST node;
- lines that are defensive, impossible, or not reachable from semantic D code.

## Test Selection

Add tests one behaviour at a time. Before adding or modifying any test, show the
exact proposed test body and wait for approval.

For each uncovered group:

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
   `dmd.dinterpret` lines changed from uncovered to covered.

Avoid all-literal fixtures unless constant folding itself is the target. Use
runtime-shaped values such as mutable locals or helper calls so DMD does not
fold away the AST node before CTFE interprets it.

Do not add tests for internal assertions, compiler consistency checks, frontend
states that semantic analysis rewrites away, or impossible AST shapes. Record
those gaps with the exact line or method and a short reason.

## PR Coverage Report

When creating a PR from this plan, report the `dmd.dinterpret` coverage
percentage delta in the PR.

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

Calculate the percentage from executable entries in
`tmp/dmd-ctfe-coverage/dmd-dinterpret.lst` for the starting commit and final PR
commit. Do not use the final DMD footer line; it rounds to a whole percentage
and can hide small PR deltas.

Executable entries are `.lst` lines whose seven-character counter prefix is
either a run count or `0000000`. Count `0000000` as uncovered, and count any
positive run count as covered. Report:

- the starting commit SHA and baseline percentage;
- the final PR branch commit SHA and percentage;
- the percentage-point delta;
- all percentages and deltas with two digits after the decimal point;
- the method-level coverage change that motivated the test, such as a visitor
  moving from wholly uncovered to partially covered.

Do not compare a focused single-test coverage run against the broad baseline.
Focused runs are useful for proving that a specific fixture hits the intended
lines, but their percentages are not comparable to the full `ut.backends.pure_`
coverage percentage.

## Audit Log

Keep an audit table in this plan or in a sibling coverage audit file. Each row
should track one uncovered method or coherent branch group.

Suggested columns:

| DMD CTFE area | Coverage status | Test or reason | Notes |
| --- | --- | --- | --- |
| `visit(FooExp)` | Needs triage | Pending | Whole method |
| `visitBar` line N | Covered | `test.name.Ctfe` | Focused fixture |
| `visitBaz` assertion | Not reachable | Semantic rewrite | No test |

Update the table as tests are approved and added. Do not leave uncovered
reachable methods as undocumented backlog.

## Subagent Workflow

For future PR slices on this plan, the main agent should orchestrate only:

1. Ask an explorer subagent to inspect the fresh coverage audit, DMD CTFE
   source, and nearby tests, then recommend the next reachable additive test
   target.
2. Spawn a worker subagent for the chosen commit-sized test slice.
3. Review the worker diff, verify, update this plan if needed, and commit.

Do not choose the next CTFE target locally before the explorer has reported.

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
| `visit(GotoCaseStatement)` | Covered | Worker 1 slice | Now partial. |
| `visit(GotoDefaultStatement)` | Covered | Worker 1 slice | Now partial. |
| `visitDo(DoStatement)` paths | Covered | Worker 1 slice | Fewer gaps. |
| `visitWith(WithStatement)` | Covered | Worker 2 slice | Now partial. |
| `visitUnrolledLoop` | Covered | Worker 3 slice | Now partial. |
| `visit(CommaExp)` | Covered | Worker 4 slice | Now partial. |
| `visitTryCatch` catch var binding | Covered | Worker 6 slice | See below. |
| `visitWith(WithStatement)` enum body | Covered | Worker 7 slice | See below. |

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
