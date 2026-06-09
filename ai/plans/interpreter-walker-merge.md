# Plan: Merge EvalFunctionWalker and EvalModuleInterpreter

## Summary

`source/quickbite/backends/interpreter/impl.d` contains two AST-walking
structs whose logic is heavily duplicated:

- `EvalFunctionWalker` — driven by `evalFunction`, called from
  `Interpreter.eval` and `Interpreter.evalRepl`.
- `EvalModuleInterpreter` — driven by the three `runTests*` methods.

The goal is to merge them into a single `Evaluator` struct, then switch to
per-call-frame `Evaluator` instances (eliminating the manual save/restore
pattern in `runFunction`/`runDirectFunctionCall`), then extract the
assert-message formatting helpers into a separate file
`interpreter/messages.d` and demote stateless helpers to free functions.

Every phase is behaviour-preserving. The early-return-in-compound-statement
bug (both walkers iterate all sibling statements even after a `return`) is
explicitly **out of scope** until there is an approved failing test for it.

One commit per phase. Run `dub test -- --random` after each phase. Run
`ci.sh` before the PR.

---

## Audit Findings

### Difference Inventory

The two walkers diverge in the following concrete ways.

#### 1. Statement support

`EvalFunctionWalker.runStatement` handles:

- `CompoundDeclarationStatement`
- `CompoundStatement`
- `ScopeStatement` (via `isScopeStatement`)
- `ImportStatement`
- `ExpStatement`
- `ReturnStatement`

`EvalModuleInterpreter.runStatement` handles all of the above **except
`ScopeStatement`**, and additionally handles:

- `IfStatement`
- `ThrowStatement`

The missing `ScopeStatement` support in `EvalModuleInterpreter` is
accidental drift. `ScopeStatement` is a DMD AST wrapper that can appear
around any statement; omitting it would cause `assert(0)` on any scoped
compound body in a unittest. No test explicitly exercises this path from the
module interpreter, so it is currently undetected. The merged walker must
include `ScopeStatement`.

The missing `IfStatement` and `ThrowStatement` support in
`EvalFunctionWalker` is intentional: plain `eval` does not support control
flow, and the unsupported-statement diagnostic on `if` is tested directly.

**Load-bearing differences:**

- `IfStatement` absent from `EvalFunctionWalker` — pinned by
  `ifStatementReportsUnsupportedEvalStatement.Interpreter` in
  `tests/ut/backends/interpreter.d`.
- `ThrowStatement` absent from `EvalFunctionWalker` — no explicit test, but
  the merged walker must not add `ThrowStatement` support to the eval path or
  the if-statement test would need to be revisited.

#### 2. Expression support

`EvalFunctionWalker.runExpression` handles:

- `IntegerExp`, `RealExp`, `StringExp`
- `CastExp`
- `PostExp` (postfix `++`)
- `AddAssignExp` (prefix `++` via lowering)
- `AddExp`, `MinExp`, `MulExp`, `NegExp`
- `CallExp`
- `DeclarationExp`
- `VarExp`

`EvalModuleInterpreter.runExpression` handles all shared cases plus:

- `NullExp`
- `ArrayLiteralExp`
- `AssertExp`
- `NotExp`
- `LogicalExp` (&&, ||)
- `EqualExp`
- `IdentityExp`
- `CmpExp` (comparisons)
- `AssignExp`
- `concatenateElemAssign` (array append `~=`)
- `OrExp` (bitwise or)
- `CommaExp`
- `ArrayLengthExp`
- `IndexExp`
- `DotVarExp` (null-dereference diagnostic)
- `TypeidExp` (null-dereference diagnostic)

`EvalModuleInterpreter` **lacks** `MinExp`, `MulExp`, `NegExp`, and
`PostExp`, and `AddAssignExp` — all of which exist in
`EvalFunctionWalker`.

These absences in `EvalModuleInterpreter` are accidental drift. The math
tests (promoted to `Interpreter`) run through the module interpreter and
exercise `MulExp` (e.g., `thrice(14)` in a REPL slice) and `NegExp`
indirectly. The merge must include all expression types from both walkers.

No test pins the absence of these operators in `EvalModuleInterpreter`:
the module tests that exercise multiplication, subtraction, etc. all pass
because those expressions are evaluated inside called functions (handled by
the same struct's `runFunction`), or they happen to not reach those code
paths yet.

#### 3. `allowZeroArgumentCalls` flag

`EvalFunctionWalker` has a `bool allowZeroArgumentCalls` field.  When
`false` (the default, used by plain `eval`), a zero-argument call throws
`"Unsupported eval call argument count."`. When `true` (set by
`evalRepl`), zero-argument calls are allowed and dispatched normally.

`EvalModuleInterpreter` has no such gate: zero-argument calls always work.

**Load-bearing:**

- The false-by-default gate is pinned by
  `zeroArgumentCallReportsArgumentCount.Interpreter` in
  `tests/ut/backends/interpreter.d` (expects the message
  `"Unsupported eval call argument count."`).
- The `true` path is needed by
  `repl.backend.userDefinedFunctionDoesNotCollideWithWrapper.Interpreter`
  in `tests/ut/backends/api/repl.d` (calls `f()` from the REPL).

The merged walker must keep this flag. It is the only boolean the merge
introduces; every other per-call-mode difference reduces to it or to the
statement-set choice.

#### 4. `sqrt` builtin fall-through

In `EvalFunctionWalker.runCallExpression`, the `case sqrt: break;` inside
the builtin dispatch causes `sqrt` to fall through to the zero-argument
count check, then ultimately to the unsupported-call path.  This makes
`sqrt` unreachable through `eval`.

In `EvalModuleInterpreter.runCallExpression`, `sqrt` is handled as a
first-class builtin (`unaryBuiltinCall`).

**Load-bearing?** No explicit test asserts that `eval("sqrt(…)")` throws or
is unsupported. The `evaluatesRuntimeSqrtInput` family of tests all goes
through `runBackendSourceFixtureTests`, which uses the module interpreter
path. The fall-through is therefore **not tested** and is accidental drift.

The merged walker should evaluate `sqrt` as a builtin unconditionally
(matching the module interpreter).

#### 5. Builtin argument-count enforcement

`EvalFunctionWalker` explicitly checks that the argument count matches
`interpreterBuiltinArgumentCount` and throws `"Unsupported eval call
argument count."` if it does not, for `fabs`, `isInfinity`, `signbit`, and
`pow`.

`EvalModuleInterpreter` uses a short-circuit condition
(`call.arguments !is null && call.arguments.length ==
interpreterBuiltinArgumentCount(builtin)`) so a mismatched count silently
falls through to the general `runFunction` path.

**Load-bearing?** No test asserts on a wrong-argument-count builtin call.
The difference is therefore not load-bearing. The merged walker can adopt
whichever behaviour is cleaner; the module-interpreter silent-fallthrough
style is simpler and matches how DMD already prevents impossible argument
counts during semantic analysis.

#### 6. Diagnostic message text: "eval" vs "interpreter"

`EvalFunctionWalker` uses `"Unsupported eval …"` prefixes.
`EvalModuleInterpreter` uses `"Unsupported interpreter …"` prefixes.

**Load-bearing:**

- `"Unsupported eval call argument count."` — pinned by
  `zeroArgumentCallReportsArgumentCount.Interpreter`.
- `"Unsupported eval statement: If"` — pinned by
  `ifStatementReportsUnsupportedEvalStatement.Interpreter`.

All other `"Unsupported eval …"` and `"Unsupported interpreter …"` strings
are not tested. The merged walker must keep the two pinned messages exactly
as-is, and can rationalise the rest.

The `"no available source code"` diagnostic and the uninitialized-variable
message (`"cannot read uninitialized variable …"`) are tested:

- `malloc` test in `tests/ut/backends/runtime/cstdlib.d` and
  `tests/ut/backends/api/repl.d` pin `"cannot be interpreted at compile
  time, because it has no available source code"`.
- `voidInitializedScalarReadReportsUninitialized.Interpreter` in
  `tests/ut/backends/lang/diagnostics.d` pins `"cannot read uninitialized
  variable \`."` and `".answer.value\` in ctfe"`.

These come only from `EvalModuleInterpreter` and must be preserved verbatim.

#### 7. `uninitializedLocals` tracking

`EvalModuleInterpreter` has a `bool[VarDeclaration] uninitializedLocals`
map. Reads of uninitialised variables throw a diagnostic; the declaration
handler populates this map for `void`-initialised locals.

`EvalFunctionWalker` has no such map.

**Load-bearing:** `voidInitializedScalarReadReportsUninitialized.Interpreter`
pins this behaviour. The merged walker must include `uninitializedLocals`.
In the eval path it is always empty (eval cells do not produce
void-initialised locals), so the cost is negligible.

#### 8. `runningCalledFunction` and `currentFunction` tracking

`EvalModuleInterpreter` sets `runningCalledFunction = true` in `runFunction`
and uses it in `assertFailureMessage` to distinguish `assert(0)` inside a
called function from the top-level case.

`currentFunction` is used in `uninitializedVariableMessage` to embed the
function name in the diagnostic.

`EvalFunctionWalker` has neither field.

**Load-bearing:**

- `voidFunctionOops.Interpreter` and
  `logicalAndCallShortCircuitFailureMessage.1.Interpreter` both expect
  `` `assert(0)` failed `` for `assert(0)` inside a called function, which
  requires `runningCalledFunction == true`.
- `voidInitializedScalarReadReportsUninitialized.Interpreter` expects the
  function name in the diagnostic, which requires `currentFunction`.

Both fields must be preserved.

#### 9. Ref parameter write-back

`EvalModuleInterpreter.runFunction` calls `writeBackRefParameters` to
propagate mutations of `ref` parameters back to the caller's locals.

`EvalFunctionWalker.runDirectFunctionCall` does not do this.

**Load-bearing:** `refUbyteArrayParameterAppend.Interpreter` and its
failure-message variants pin ref write-back.  These tests use the module
interpreter path. The eval path currently never encounters `ref` parameters,
so there is no test pinning the absence of write-back in the eval path.

The merged walker must include write-back, unconditionally (it is a
correctness requirement for D semantics).

#### 10. `result` save/restore in function calls

`EvalFunctionWalker.runDirectFunctionCall` saves and restores `result`.
`EvalModuleInterpreter.runFunction` saves and restores `result` via
`savedResult`. Both walkers use the same pattern.

This is identical behaviour; not a difference.

#### 11. Null-expression `runStatement` guard

`EvalFunctionWalker.runStatement` starts with `if (statement is null)
return;`. `EvalModuleInterpreter.runStatement` has no such guard; a null
statement would `assert(0)`.

The guard is defensive. No test exercises null-statement behaviour. The
merged walker should include the null guard.

#### 12. DeclarationExp: `Value(false)` vs `Value(cast(int) 0)` for
non-variable declarations

`EvalFunctionWalker.runDeclarationExpression` returns `Value(cast(int) 0)`
for non-variable declarations. `EvalModuleInterpreter.runDeclarationExpression`
returns `Value(false)`. Both are effectively the same value (integer 0).
Not load-bearing; use `Value(false)` (module interpreter convention).

#### 13. DeclarationExp: void-initializer handling

`EvalModuleInterpreter.runDeclarationExpression` handles
`void`-initialisers (both `isVoidInitializer` and `isVoidInitExp`) by
inserting the variable into `uninitializedLocals`.

`EvalFunctionWalker.runDeclarationExpression` does not handle void
initialisers.

**Load-bearing:** pinned by `voidInitializedScalarReadReportsUninitialized`.
Must be in the merged walker.

#### 14. DeclarationExp: null dynamic-array initialisation

`EvalModuleInterpreter.runDeclarationExpression` treats a null-initialised
dynamic array local as an empty `Value.arrayValue([])` so subsequent append
operations work.

`EvalFunctionWalker` does not do this.

**Load-bearing:** `localDynamicArrayAppend.Interpreter` and variants pin
this. The merged walker must include it.

### Chosen Mode Flags

The merged `Evaluator` struct needs exactly **two** boolean mode flags:

```d
private bool allowZeroArgumentCalls;
private bool allowControlFlow;
```

A single flag cannot work: once the merged walker handles `IfStatement`
for the module path, plain `eval` of an `if` would no longer throw, and
`ifStatementReportsUnsupportedEvalStatement.Interpreter` pins that it must
throw `"Unsupported eval statement: If"`. Nor can `allowZeroArgumentCalls`
double as the gate, because the REPL sets it to `true` yet currently also
rejects `if` (it walks via `EvalFunctionWalker`, which has no `if`
support). The flags per entry point:

| Entry point  | `allowZeroArgumentCalls` | `allowControlFlow` |
|--------------|--------------------------|--------------------|
| `eval`       | `false`                  | `false`            |
| `evalRepl`   | `true`                   | `false`            |
| module tests | `true`                   | `true`             |

When `allowControlFlow` is `false`, `runStatement` must reject
`IfStatement` and `ThrowStatement` through the existing fall-through
diagnostic, preserving the pinned message text
`"Unsupported eval statement: If"` exactly.

All other differences reduce to: (a) include all features from both walkers
in the single merged struct, or (b) drop the `sqrt` fall-through in favour
of treating `sqrt` as a full builtin.

---

## Phase Breakdown

### Phase 2 — Merge the two walkers into `Evaluator`

Single commit: `interpreter: merge EvalFunctionWalker and
EvalModuleInterpreter into Evaluator`

- Rename `EvalFunctionWalker` to `Evaluator`.
- Absorb all fields and methods from `EvalModuleInterpreter` into
  `Evaluator`: `uninitializedLocals`, `runningCalledFunction`,
  `currentFunction`, `bindFunctionParameters`, `writeBackRefParameters`,
  `runFunction`, `runLogicalAndExpression`, `runLogicalOrExpression`,
  `runComparisonExpression`, `runIdentityExpression`, `runEqualExpression`,
  `runBitwiseOrExpression`, `runDotVarExpression`, `runTypeidExpression`,
  `runAssignExpression`, `runIndexAssignExpression`,
  `runArrayAppendAssignExpression`, `argumentVariable`, `arrayValue`,
  `assertFailureMessage` and all its helpers, `thrownExceptionMessage`,
  `uninitializedVariableMessage`, `isTruthy`, `receiverName`,
  `isClassExpression`, `noAvailableSourceMessage`, `hasNoAvailableSource`,
  `dmdAssertFailMessage`, `dmdAssertFailBoolMessage`,
  `invertedEqualityOperator`, `equalityOperandMessage`, `assertMessage`,
  `isCharExpression`, `isUnsignedLongExpression`, `isBoolValue`,
  `isBoolExpression`, `isLogicalNotExpression`, `isLogicalExpression`,
  `isVariableMessage`, `equalFailureMessage`.
- Add `IfStatement` and `ThrowStatement` to `runStatement`, gated by
  `allowControlFlow`. When the flag is `false` they fall through to the
  unsupported-statement throw, preserving the pinned
  `"Unsupported eval statement: If"` message.
- Add `ScopeStatement` to `EvalModuleInterpreter`'s statement list (it was
  absent; now unified).
- Absorb all expression types from both walkers into one `runExpression`.
  Fix the `sqrt` fall-through: treat `sqrt` as a full builtin.
- Replace `runDirectFunctionCall` with `runFunction` (the richer version
  from `EvalModuleInterpreter`), which includes ref write-back and
  `runningCalledFunction` tracking.
- Delete `EvalModuleInterpreter`.
- Update `evalFunction` to create an `Evaluator` with the given
  `allowZeroArgumentCalls` flag and `allowControlFlow = false`.
- Update `runTests`, `runTestResults`, `runTestSummary` to use `Evaluator`
  instead of `EvalModuleInterpreter`.
- Run `dub test -- --random`.

### Phase 3 — Per-call-frame `Evaluator` instances

Single commit: `interpreter: use per-call-frame Evaluator instances`

Currently `runFunction` manually saves and restores `locals`,
`uninitializedLocals`, `result`, `runningCalledFunction`, and
`currentFunction` on every call. This is fragile and prevents recursive
functions from being correct.

Replace the save/restore pattern with a recursive `Evaluator` value
constructed for each call frame:

- At each function call, construct a fresh `Evaluator` with
  `runningCalledFunction = true`, inheriting `allowZeroArgumentCalls` and
  `allowControlFlow` from the caller frame (today's single-instance walker
  applies the same gates to nested calls, and the refactor must preserve
  that).
- Bind arguments into the fresh walker's `locals`.
- Execute the body in the fresh walker.
- After execution, write back `ref` parameters from the inner walker to the
  outer walker's `locals`.
- Return `inner.result`.

The outer `Evaluator` state (locals, result) is untouched during the call.
No save/restore needed.

`currentFunction` moves to a constructor parameter or is set immediately
after construction.

Run `dub test -- --random`.

### Phase 4 — File split: extract messages and free functions

Single commit: `interpreter: extract assert messages to messages.d`

- Create `source/quickbite/backends/interpreter/messages.d`.
- Move all assert-message formatting helpers (`assertFailureMessage`,
  `equalFailureMessage`, `dmdAssertFailMessage`, `dmdAssertFailBoolMessage`,
  `invertedEqualityOperator`, `equalityOperandMessage`, `assertMessage`,
  `isBoolValue`, `isBoolExpression`, `isLogicalNotExpression`,
  `isLogicalExpression`, `isVariableMessage`, `isCharExpression`,
  `isUnsignedLongExpression`) to free functions in `messages.d`. Pass
  `isTruthy` and `runExpression` as parameters where needed, or make those
  free functions take a `ref Evaluator` argument.
- Move `thrownExceptionMessage`, `uninitializedVariableMessage`,
  `noAvailableSourceMessage`, `receiverName`, `isClassExpression` to
  `messages.d` as free functions.
- Demote other stateless helpers (`isTruthy`, `isTransparentArrayCastTarget`,
  `typeIsDynamicArray`, `symbolName`, `locChars`) to module-level free
  functions in `impl.d` or `messages.d` as appropriate.
- `impl.d` retains only `Interpreter`, `Evaluator`, and module-top helpers
  that depend on walker state.
- Run `dub test -- --random`.

Run `ci.sh` before opening the PR.
