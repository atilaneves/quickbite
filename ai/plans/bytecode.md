# Bytecode VM Architecture Plan

## Summary
Design a new bytecode VM for D that minimizes unittest latency from an edit to
an ok/fail result. The system should compile from semantically analyzed D ASTs
into an internal bytecode artifact, execute that artifact in-process, and avoid
object files and linker involvement on the hot path.

The architecture should borrow the useful parts of LuaJIT: compact bytecode,
explicit operand domains, a small interpreter core, deterministic emission, and
strong separation between compiler and VM. It should not borrow the JIT or the
Lua-specific bytecode shape.

## Core Architecture
- Keep the bytecode format compact and rigid, with a small set of opcodes and
  typed operand kinds such as function reference, local slot, constant index,
  comparison kind, and jump target.
- Make the compiled artifact closed over the code selected for the current
  unittest slice, not over every transitive dependency. Code stream, constant
  pool, function table, frame metadata, and debug or line info live together but
  are logically separate. Function references may point to local bytecode,
  cached dependency bytecode, or native-call bridge entries through
  bytecode-native ids.
- Keep the frontend and VM boundary hard. AST and semantic lookup belong in the
  compiler layer; the VM should consume only bytecode-native ids and metadata.
- Make bytecode deterministic to emit and easy to disassemble so test failures
  and cache behavior are reproducible.
- Keep the interpreter small and direct. Prefer a minimal dispatch loop and
  explicit frame bookkeeping over a deep abstraction stack.
- Compute max value-stack depth at compile time and store it in the function
  table entry. Allocate call frames from VM-owned storage, using
  `std.experimental.allocator` to avoid per-call GC allocation. Inline storage
  for the common shallow unittest case is fine, but the policy must either grow
  through the allocator or report a deterministic bytecode call-stack
  exhaustion diagnostic. Each frame holds: a function reference, an instruction
  pointer, and a base pointer into the value stack.
- Start the dispatch loop with `final switch` over the opcode enum. The end
  goal is direct-threaded dispatch: computed goto (GCC/Clang labels-as-values
  extension or equivalent C), inline assembly, or a function-pointer table —
  whatever is viable in D and measurably fastest on the target. The direct
  threading experiment must name the chosen route and keep the `final switch`
  interpreter as the portable fallback. Keep the opcode enum and handler
  boundaries interchangeable between the two so the upgrade path requires no
  structural change to the VM.

## Implementation Direction
- Start with the smallest useful `eval` slice that can make exactly one
  approved behavior test fail.
- Promote CTFE-backed test modules in the order documented by
  `ai/plans/backend-test-modules-order.md`. Within each module, start with the
  smallest named unittest that the current bytecode surface can honestly make
  red and then green.
- Treat the selected module, not a single template instantiation, as the unit
  of migration. Before editing, inventory every backend-matrix unittest in the
  module and classify each test family as already covered by `Bytecode`,
  blocked by an expected missing feature, or ready to promote.
- Do not count repeated instantiations of the same parametrized unittest, such
  as one `static foreach` body over several integral types, as independent
  migration slices when one instantiation already proves the behavior. Promote
  the whole test family when it is already green, then move to the next distinct
  named behavior in the module.
- When orchestrating subagents, assign work by remaining named test behavior or
  test family in the selected module. A worker should not spend a full slice on
  another type-width variant of a behavior that has already passed for
  `Bytecode` unless that variant is expected to expose a different missing VM
  feature.
- Before promoting a named test mentioned by this plan or a review note,
  verify in the current checkout that its enclosing backend matrix still
  excludes `Bytecode`. If it already uses `backendsWith!Bytecode`, treat the
  note as stale and choose the next smallest current CTFE-only candidate.
- If the slice needs unittest blocks, integer literals, equality, calls,
  returns, and assert handling all at once, the test is too broad; pick a
  smaller test.
- Add locals, branches, and broader expression support only when a test forces
  the next slice.
- Keep unsupported behavior explicit and diagnostic rather than silently
  lowering or guessing.
- Preserve a strict compile-AST-then-execute-bytecode pipeline; do not route
  the new VM through existing lowering machinery as the baseline design.
- Treat bytecode as an internal artifact, not a public interchange format or a
  serialization compatibility promise.

## Current Coverage State
- `tests/ut/backends/lang/eval.d` now covers `Bytecode` for every eval
  candidate previously listed for promotion: `multiCell`,
  `preservesScalarValueTypes`, `castsFloatingValueNumerically`,
  `castsRuntimeValuesToIntegerTypes`,
  `floatingSubtractionUsesNumericValues`,
  `floatingUnaryMinusUsesNumericValue`, `fabsFloatPreservesReturnType`, and
  `powFloatDoesNotReturnDoubleValue`.
- Those promotions were stale coverage gaps. The bytecode backend already
  supported them through its existing eval compiler, VM local/value-stack
  operations, scalar casts, floating arithmetic, and narrow `std.math`
  builtin bridge.
- `tests/ut/backends/lang/integrals.d` now covers `Bytecode` for
  every integral type behavior test from `type.byte` through `type.ulong`.
  These are one parametrized behavior family, not eight meaningful migration
  slices. The `byte` slice added the first module-backed `Bytecode.runTests`
  path, compiling each unittest block to bytecode and executing its
  directly-called module functions through bytecode call frames. The remaining
  type-width variants passed without production changes and should have been
  promoted together once that was known. The implementation is deliberately
  narrow: equality assertions are enough for the passing behavior.
- `typeFailureMessage.byte.0` now covers `Bytecode`. This promoted the first
  integral assertion-diagnostic case and taught the bytecode VM to report
  failed equality assertions from the runtime operands, producing
  `-126 != 130` for a narrowed `byte` value.
- `tests/ut/backends/lang/integrals.d` is now complete for `Bytecode`.
  `typeFailureMessage.ubyte.0` and `typeFailureMessage.uint.0` were promoted
  together as the remaining integral assertion-diagnostic family. They passed
  with the existing equality diagnostic support and did not require distinct
  VM feature work.
- `runTests.runsAttributedUnittests` in
  `tests/ut/backends/api/runner.d` now covers `Bytecode`. The promotion
  exposed DMD constant-folded assert diagnostics: `assert(1 == 2)` reaches
  bytecode as a false assertion with a structured `_d_assert_fail("==", 1, 2)`
  message payload. Bytecode now lowers that equality payload through the
  existing assertion-compare opcode so the runner reports `1 != 2`.
- `runTests.runsAttributedThrowingUnittests` in
  `tests/ut/backends/api/runner.d` now covers `Bytecode`. The promotion
  exposed missing `throw` statement support for `throw new Exception(message)`.
  Bytecode now lowers the exception constructor message to a value-stack
  operand and the VM throws that message through a narrow `throw_` opcode.
- `runTests.importPathsRetryAfterFailure` in
  `tests/ut/backends/api/runner.d` now covers `Bytecode`. This was a stale
  coverage gap: the shared source-fixture parse path already passed import
  paths to DMD, and the existing bytecode enum/function/assert support could
  execute the imported assertion without production changes.
- `runTestSummary.countsAttributedPassingAndFailingUnittests` in
  `tests/ut/backends/api/runner.d` now covers `Bytecode`. The promotion
  exposed the missing bytecode backend summary API, not missing VM semantics.
  Bytecode now compiles and executes each unittest declaration through the
  existing bytecode path and records total, passed, and failed counts.
- `runTestSummary.countsAllPassingUnittests` in
  `tests/ut/backends/api/runner.d` now covers `Bytecode`. This was a stale
  coverage gap after the summary API slice: the existing bytecode summary path
  already counted all-passing unittest declarations correctly.
- `runTestSummary.countsAssertErrorsAsFailures` in
  `tests/ut/backends/api/runner.d` now covers `Bytecode`. This was a stale
  coverage gap after the summary API and narrow throw-expression slices: the
  existing summary path already counts thrown `AssertError` instances as
  failures.
- `runTestResults.reportsDmdUnittestSymbolNames` and
  `runTestResults.reportsFileBackedUnittestLocations` in
  `tests/ut/backends/api/runner.d` now cover `Bytecode`. The promotion exposed
  the missing bytecode `runTestResults` API. Bytecode now reuses the existing
  compile/execute path to build a `TestRunResult` with per-case
  `TestOutcome`, the DMD unittest symbol name (`ident.toChars`), and the source
  location (`loc.toChars`), reporting names such as `__unittest_L2_C13` and
  file-backed locations such as `path(1)`.
- `runModulesTests.runsBothModules` in `tests/ut/backends/api/runner.d` now
  covers `Bytecode`. This was a stale coverage gap: `runModulesTests` just calls
  `backend.runTests` on each module, and the existing `Bytecode.runTests` path
  plus its `throw`-expression support already ran both modules and propagated
  the second module's thrown message without production changes.
- `runBackendSourceFixtureTests.withImportPaths` and
  `runBackendFileFixtureTests.withImportPaths` in
  `tests/ut/backends/api/runner.d` now cover `Bytecode`. This was a stale
  coverage gap: DMD semantic analysis resolves the imported module function as
  a `FuncDeclaration` with a populated `fbody`, so the existing `compileCall`
  path emitted the ordinary `Op.call` and the VM executed the call frame and
  returned `int` without production changes. The import-path plumbing already
  flowed through the shared fixture parse helpers.
- `malloc` in `tests/ut/backends/runtime/cstdlib.d` now covers `Bytecode`,
  completing that module. The promotion exposed the missing
  no-available-source diagnostic: `malloc` resolves to a `FuncDeclaration`
  with a null `fbody` and is not an implemented builtin, so `compileCall` now
  reports `` `malloc` cannot be interpreted at compile time, because it has no
  available source code `` instead of the generic unsupported-call-target
  message. The pointer casts, indexing, and `scope(exit)` in the source are
  never reached, matching the CTFE and tree-walker oracles.
- `assertNonzeroIntCondition`, `assertNonzeroIntConditionFailureMessage.0`,
  and `assertNonzeroIntConditionFailureMessage.1` in
  `tests/ut/backends/lang/logic.d` now cover `Bytecode`. The promotion exposed
  missing bitwise-or expression support for `40 | mask()`, so bytecode now
  lowers DMD `OrExp` to a narrow `bitOr` opcode and preserves the existing
  assertion truthiness and equality diagnostics.
- `logicalNot`, `logicalNotCall`, `logicalNotFailureMessage.0`,
  `logicalNotFailureMessage.1`, `logicalNotCallFailureMessage.0`, and
  `logicalNotCallFailureMessage.1` in `tests/ut/backends/lang/logic.d` now
  cover `Bytecode`. The promotion exposed missing DMD `NotExp` lowering, so
  bytecode now lowers logical not to a unary opcode using VM truthiness and
  reports failed bool equality assertions as `true`/`false`.
- `logicalAnd`, `logicalAndFailureMessage.0`,
  `logicalAndFailureMessage.1`, `logicalAndCall`,
  `logicalAndCallFailureMessage.0`, `logicalAndCallFailureMessage.1`,
  `logicalAndShortCircuit`, `logicalAndShortCircuitFailureMessage.0`,
  `logicalAndShortCircuitFailureMessage.1`,
  `logicalAndCallShortCircuit`,
  `logicalAndCallShortCircuitFailureMessage.0`, and
  `logicalAndCallShortCircuitFailureMessage.1` in
  `tests/ut/backends/lang/logic.d` now cover `Bytecode`. The promotion
  exposed missing DMD `LogicalExp` `&&` lowering, so bytecode now emits narrow
  jump/pop control flow for short-circuit evaluation, normalizes both paths to
  bool, and preserves plain assertion text for failed truth assertions.
- `logicalOr`, `logicalOrBoolResult`,
  `logicalOrBoolResultFailureMessage.0`,
  `logicalOrBoolResultFailureMessage.1`, `logicalOrFailureMessage.0`,
  `logicalOrFailureMessage.1`, `logicalOrOops`, `logicalOrShortCircuit`,
  `logicalOrShortCircuitFailureMessage.0`, and
  `logicalOrShortCircuitFailureMessage.1` in
  `tests/ut/backends/lang/logic.d` now cover `Bytecode`. The promotion
  exposed missing DMD `LogicalExp` `||` lowering, so bytecode now emits narrow
  jump/pop control flow for short-circuit evaluation, normalizes both paths to
  bool, and reports failed `assert(!condition)` diagnostics such as
  `true == true`.
- `logicalAndComparisonOperands`,
  `logicalAndComparisonOperandsFailureMessage.0`, and
  `logicalAndComparisonOperandsFailureMessage.1` in
  `tests/ut/backends/lang/logic.d` now cover `Bytecode`, completing the module.
  The promotion exposed missing DMD `CmpExp` lowering for comparison operands
  inside logical expressions, so bytecode now lowers the required integer `<`
  and `>` comparisons to bool results while preserving bool equality assertion
  diagnostics such as `true != false` and `false != true`.
- `voidFunctionReturnsToCaller` in
  `tests/ut/backends/lang/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: the existing bytecode module test path already handled a
  called `void` function returning to its unittest caller before reporting the
  following failed integer equality assertion as `1 != 2`.
- `intLessThanOops` in `tests/ut/backends/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing bytecode assertion diagnostics for
  failed `<` assertions: bytecode now tags assertion comparisons with the
  comparison operation and reports the inverse failed relation, such as
  `42 >= 42`, instead of a generic failed assertion string.
- `intLessOrEqualOops` in `tests/ut/backends/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `<=` lowering in bytecode, so
  the VM now evaluates a narrow `lessOrEqual` opcode and formats failed
  assertion diagnostics with the inverse operator, such as `43 > 42`.
- `intGreaterThanOops` in `tests/ut/backends/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed that `>` expression execution already
  existed, but assertion-specific comparison lowering did not tag failed `>`
  assertions. Bytecode now emits `Op.greaterThan` for that path and reports the
  inverse failed relation, such as `42 <= 42`.
- `intGreaterOrEqualOops` in `tests/ut/backends/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `>=` lowering in bytecode, so
  the VM now evaluates a narrow `greaterOrEqual` opcode and formats failed
  assertion diagnostics with the inverse operator, such as `41 < 42`.
- `intNotEqualOops` in `tests/ut/backends/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed that DMD `EqualExp` lowering did not yet
  distinguish `!=` from `==`, so bytecode now emits and evaluates a `notEqual`
  opcode and reports failed `!=` assertions with the inverse operator, such as
  `42 == 42`.
- `ok` in `tests/ut/backends/lang/diagnostics.d` now covers `Bytecode`. This
  was a stale coverage gap: the existing bytecode function-call, return, and
  equality assertion path already handled the passing assertion.

## Current Next Step
Continue with `tests/ut/backends/lang/diagnostics.d`, the next module in
`ai/plans/backend-test-modules-order.md`.

Do not return to `tests/ut/backends/lang/integrals.d`,
`tests/ut/backends/api/runner.d`, `tests/ut/backends/runtime/cstdlib.d`, or
`tests/ut/backends/lang/logic.d` unless new tests are added there. Their
current backend-matrix test families all include `Bytecode`.

## Test Plan
- Use public behavior tests only for language semantics and backend parity.
- Add focused VM contract tests only for bytecode-specific properties such as
  operand typing, frame behavior, and diagnostic boundaries.
- Keep unsupported-slice tests narrow and behavior-driven, not layout-driven.
- For backend language-surface tests, treat CTFE as the canonical oracle for
  supported behaviour unless the completed DMD codegen backend demonstrates
  that compiled D code behaves differently.
- CTFE coverage reports do not rank Quickbite test modules by simplicity. All
  backend language modules run against CTFE, so use
  `ai/plans/backend-test-modules-order.md` to choose post-`eval` targets by
  required D language features, not by file length or coverage counts.
- Verify each new slice before expanding scope: red test, minimal
  implementation, green suite, then the next slice.
- Do not trust backend progress text as an edit target without checking the
  test file. A stale plan should trigger current-test discovery, not a broad
  promotion.
- Do not add unsupported-diagnostic paths unless a test verifies the exact
  diagnostic behavior.

## PR 97 Review Lessons
- Before coding a bytecode slice, ask what is the smallest behavior that should
  fail and what code may be deleted while that test still passes.
- Delete speculative opcodes, operands, frame fields, helper functions, and
  public APIs. If a first test does not need calls, locals, returns, or a halt
  instruction, do not add them yet.
- Keep the DMD dependency only in the compiler module. The bytecode program
  representation and VM must not import DMD AST or declaration types.
- Keep modules separate from the start: backend adapter, compiler, bytecode
  program representation, and VM. Do not hide all bytecode logic in the backend
  adapter.
- Use the existing runtime `Value` type as the first implementation stack slot
  type. Its size and GC semantics are accepted costs for now. Architecturally,
  VM stack slots are private execution values that convert to and from
  `quickbite.lang.Value` at backend/API boundaries; the private slot type may
  initially alias `Value`. If benchmarks show slot size or copying hurts
  edit-to-test-result latency, investigate a narrower VM slot representation
  such as NaN-boxing for the numeric subset (collapses all values to 8 bytes,
  type check becomes 1–2 bitwise ops); however NaN-boxing may not be viable for
  D given the breadth of scalar types and the need to represent structs. Do not
  invent int-only stack or operand types as a first step.
- Make operands earn their shape. Avoid a generic `long` operand, ad hoc
  integer-specialized operands, or a half-built sum type unless the current test
  proves that shape is needed.
- Do not split one language operation into one opcode per scalar type unless
  the VM semantics genuinely differ. Prefer one opcode with a typed operand
  domain, for example a cast opcode plus a target-type operand, before adding
  `castInt`, `castFloat`, or similar families.
- Exception: for arithmetic and comparison opcodes, the compiler should select
  a type-tagged variant at emit time using the operand types from the semantic
  layer. This eliminates a runtime type-dispatch branch in the handler body
  without requiring runtime specialization. This is distinct from the
  cast-family anti-pattern — it applies only where the handler would otherwise
  branch on type and the compiler's static knowledge makes that branch
  unnecessary.
- Do not add module-level helpers that only wrap a single call unless they make
  an active test simpler. Prefer inlining or overloading when that is clearer.
- Keep names precise and conventional: use "variables" for variable metadata,
  "indices" as the plural of index, and avoid names such as
  `bytecode.bytecode`.
- Preserve the repo's formatting style before asking for review. Formatting
  churn distracts from the design slice.

## PR 123 Review Lessons
- Do not derive eval structure by inspecting source text in any layer. Splits
  on newlines, semicolons, braces, or keywords are parser bugs waiting to
  happen. Ask the frontend for a structured cell, DMD module, function
  declaration, statement, or expression instead.
- Do not paper over that rule by moving source splitting into
  `quickbite.frontend.cell`. A helper that loops over `source.lineSplitter`,
  feeds each line to the REPL cell classifier, then returns a wrapper function
  is still source-text protocol, not a structured frontend API.
- Do not mark the eval-source review comments addressed while
  `parseEvalFunction` still exists as "turn source into `auto f() { ... }`,
  parse a module, then find function `f`". That is the abstraction the review
  rejected.
- Do not add or keep a "find function by name in module" helper for eval. If a
  backend needs a function declaration, the frontend should hand back the
  declaration as part of a named cell/result type, not require callers
  to know about the synthetic wrapper name.
- Do not add a special `parseEvalFunction`-style API if it only synthesizes a
  wrapper function and looks up `f`. Either reuse the existing REPL cell
  frontend path, or expose a frontend API named for the AST/domain object the
  backend actually needs.
- Treat review comments like "Why does this exist?" and "?" as a demand to
  justify ownership and abstraction. If the helper only moves the same opaque
  operation elsewhere, delete it or inline it until a real boundary emerges.
- Do not put new shared frontend helpers in vague catch-all modules such as
  `util.d`. If the helper is worth sharing, name the module after the domain
  concept it exposes.
- Do not create a tiny bytecode compiler helper just to hide four emitted
  instructions. Inline the lowering until a second behaviour makes the
  abstraction earn its name and shape.
- Do not add or keep a special VM opcode for a language operation that is just
  existing bytecode plus typed operands. `++x` should lower through `add`
  unless VM semantics genuinely differ.
- Do not infer bytecode call support from CTFE success. CTFE delegates execution
  to DMD's interpreter, so `std.math.fabs`/`pow` working there does not mean the
  bytecode VM can execute those calls without either general D call support or a
  deliberately scoped native-call bridge.
- Do not clone DMD builtin-detection internals such as mangle prefixes. If the
  bytecode backend needs CTFE builtin parity, use DMD's builtin classification
  or a project-owned semantic wrapper around it, then keep bytecode execution
  scoped to the implemented builtin subset.
- Do not answer "use introspection on std.math" with a hand-maintained
  duplicate of DMD's entire builtin enum plus string mixins. If only `fabs` and
  `pow` are implemented, keep the implemented surface small, explicit, and
  mechanically connected to DMD's builtin classification.
- Do not use `static foreach` plus string `mixin` to hide tiny two-case
  dispatch. The review explicitly called out mixin use here; prefer ordinary
  `final switch` cases until real duplication justifies compile-time
  generation.
- Do not emit untyped convenience literals such as `Value(1)` when lowering a
  typed language operation. Either derive the literal from the D type or make
  assignment/storage perform the required D conversion.
- Do not treat "move this to common frontend code" as permission to relocate
  opaque wrappers unchanged. Name the frontend API for the AST structure the
  backend needs, and leave source-shaping details behind that API.
- When extracting shared DMD symbol lookup, check nearby callers for duplicate
  local implementations and move them together if the ownership boundary is
  the same.
- Do not mark a PR review checklist item complete just because the offending
  code moved. Before checking it off, `rg` for the rejected names/patterns and
  verify the new code no longer does the rejected behaviour.

## PR 123 Remaining Cleanup
- [x] Remove `parseEvalFunction` as a source-to-wrapper-function API. Replace
  it with a frontend-owned eval cell/result that exposes the structured
  AST object the backends actually need.
- [x] Remove line-by-line eval parsing from `frontend.cell`; eval source should
  not be decomposed by newline boundaries.
- [x] Remove synthetic-wrapper-name lookup from eval/repl paths. The wrapper
  may exist as frontend implementation detail, but callers should not know or
  search for `f`.
- [x] Revisit bytecode builtin support after removing the mixin-generated
  duplicate builtin enum mapping. Keep only the implemented native-call bridge
  surface unless a test forces broader builtin metadata.

## PR 114 Review Follow-up
- [x] Explain or remove the `compileEvalSource` wrapper around eval input.
- [x] Justify or remove import-statement skipping in bytecode statement
  compilation.
- [x] Refactor duplicated binary-expression compilation.
- [x] Remove all non-module-scope `imported!"..."` usages from bytecode
  compiler helpers.
- [x] Make `castTarget` return the operand type expected by bytecode
  instructions.
- [x] Remove direct `pow` function-name special-casing from bytecode call
  compilation.
- [x] Remove direct `fabs` function-name special-casing from bytecode call
  compilation.
- [x] Decide whether integer casts need broader tests before broadening
  support.
- [x] Stop inspecting eval source text in the bytecode backend; rely on a
  frontend-provided structure instead.
- [x] Remove eval source string splitting from shared frontend code; drive eval
  through parser-backed REPL/frontend classification instead.
- [x] Remove or replace `parseEvalFunction` if it remains only a wrapper-source
  synthesizer plus `f` lookup.
- [x] Replace hand-written default scalar values with a type-to-D-value mapping
  based on `T.init`.
- [x] Replace manual string code-unit conversion with DMD literal slice
  support; no `std.utf`/`std.uni` helper is needed for the current AST node.
- [ ] Include bool and character value kinds in integer-like binary operations
  if DMD treats them that way.
- [x] Decide whether `incrementLocal` should remain distinct from `add`.
- [x] Clarify or remove the `CastTarget` enum if the current operand shape is
  not earning its keep.
- [x] Remove one-off `Value.fabs` API growth or justify it with a more general
  native-call design.
- [x] Remove one-off `Value.pow` API growth or justify it with a more general
  native-call design.

## Peephole Optimisation
- Optional bytecode-level optimisations, such as peephole passes over the
  emitted instruction stream, are the first optimisation step after correctness
  is established.
- The pass must be optional and togglable at runtime so it can be benchmarked
  against a large body of D code with and without. The artifact format must not
  preclude it (do not seal or hash bytecode arrays before the pass runs).
- Do not add the pass until a benchmark justifies it.

## Builtins and Native Calls
- CTFE builtin support exists only for feature parity with DMD CTFE. Keep it
  narrow, mechanically tied to DMD builtin classification, and scoped to the
  implemented builtin subset. Do not let CTFE builtin handling become the
  general native-call mechanism.
- The native-code bridge is a separate VM subsystem for code that should not be
  re-emitted as bytecode. It needs typed bridge entries, cached resolution,
  VM-slot/native argument and return marshalling, ownership and lifetime rules
  for aggregate values, GC interaction policy, and explicit D exception
  propagation into VM unwinding.

## Exception Handling
- Each compiled function artifact includes a handler table. For unittest blocks
  the minimum is a sorted array of `(start_pc, end_pc, handler_pc)` triples with
  one try-region covering the whole block body.
- Once bytecode supports D `try`/`catch`/`finally`, handler entries become typed
  records instead of bare triples. They must include the handler kind, optional
  caught class/type id, optional catch-binding local slot, catch ordering, and
  enough continuation metadata for `finally` to resume the pending action:
  throw, return, break/continue/goto, or normal fallthrough.
- On `throw` or assert failure the VM binary-searches the handler table and
  either jumps to the handler PC or unwinds the frame and propagates to the
  caller.
- D exceptions must not propagate silently through every C interpreter frame;
  the VM owns the decision of how test failures are caught and reported.

## Debug Info
- The minimum required is bytecode-offset-to-source-line mapping, sufficient
  for "assert failed at line N" messages. Variable name tables are useful for
  REPL display but are not required for test pass/fail output and should not
  be added until the REPL needs them.

## Constant Pool
- Deduplicate constants (strings, numbers) at generation time using an intern
  table scoped to the VM session, compilation batch, or artifact cache
  generation. The table must have allocator-owned lifetime and an explicit
  reset or invalidation path. D test code repeats the same string literals
  across functions (type names, `__traits(identifier)` results); per-function
  undeduped pools waste memory and add cache pressure. If cross-artifact
  interning is needed for cached dependency bytecode, tie the intern table to
  the same cache key and lifetime as the dependency artifact.

## Closures
- D `unittest` blocks can contain lambdas that capture locals. Closure support
  (open/closed upvalue chains) adds non-trivial complexity to both the compiler
  and the VM, and retrofitting captured variable storage after locals are
  assumed to be plain frame slots is painful. Closures are out of scope for the
  initial implementation. The plan should be revisited when a test forces
  closure support; at that point the frame layout must account for explicit
  environment or upvalue storage from the start.

## Assumptions
- Direct parser-to-bytecode generation is out of scope; AST-first lowering is
  the right starting point.
- The bytecode VM is optimized for unittest latency, not long-running execution
  throughput.
- JIT compilation is a future experiment, not a requirement for the first
  design.
- The VM should remain independent of DMD internals except at the compiler
  boundary.
