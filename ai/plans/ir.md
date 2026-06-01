# Plan: IR Backend From CTFE Parity

## Summary
Build a new IR backend from scratch and use the existing tests that already
pass under CTFE as the implementation driver. The goal is to reach a fast
compiler pipeline that can turn a semantically analysed D AST into IR and run
selected unittest blocks without object files or linker involvement on the hot
path.

The test strategy is semi-TDD: pick an existing CTFE-passing behavior, make it
red for the IR backend, implement the smallest IR change that makes it green,
then move on. Do not invent a separate test suite unless a behavior is not yet
covered anywhere in the current CTFE-backed language tests.

## Minimum Implementation Rule
- Minimum means deletion-minimum, not architecture-minimum. After the promoted
  test passes, audit every added line with this question: if this line is
  deleted, does the promoted test still pass? If yes, delete it.
- Minimum still has to be honest. Do not pick a test whose already-analysed DMD
  AST has folded away the behavior named by the test, then implement only the
  folded result. If the source expression is `1 + 2`, compiling an
  `IntegerLiteral(3)` is not an IR implementation of addition.
- Keep the first green slice deliberately embarrassing. Do not add support for
  a language construct, diagnostic path, summary path, helper abstraction, id
  table, error message, or invariant until the single promoted test fails
  without it.
- The required shape is still three backend-local modules: pure IR, compiler,
  and executor. Their contents must be only what the promoted test forces.
  Empty or nearly empty modules are acceptable if the test does not force more.
- Name the IR node after the AST value it actually represents. If the compiler
  consumes an arbitrary integer expression, the result is not an
  `IntegerLiteral` unless the compiler has verified that the input is an
  integer literal.

## IR Shape
- Make the IR typed and explicit. Scalar values should use SSA-style names;
  memory effects, mutable places, and call-by-reference behavior should be
  explicit instead of hidden in the value graph.
- Keep control flow explicit with basic blocks and terminators. Prefer a form
  that is easy to rewrite locally and does not depend on AST shape.
- Make function ids, block ids, value ids, and constant references IR-native.
  The IR should not depend on DMD declaration identity at execution time.
- Keep the in-memory IR rewrite-friendly and separate from any serialized or
  cached form. If a compact binary form is added later, treat it as a separate
  layer, not the core representation.
- Keep the compiler/IR boundary hard. DMD AST and semantic lookup belong in the
  frontend or lowering layer; the IR executor should consume only IR-native
  structures.
- Build the backend IR pipeline from scratch. Existing modules such as
  `quickbite.ir`, `quickbite.frontend.lowering`, and `quickbite.executors.ir`
  may be read for context, but the new backend must not route through them or
  reuse them as its implementation.
- Keep the first backend modules under `quickbite.backends.ir`: a pure IR data
  module, a compiler module that lowers DMD AST to that IR, and an executor
  module that runs only that IR. Prefer `compiler` for the lowering module name
  because the module's public job is compiling parsed D into backend IR; use
  small private helpers inside it rather than exposing a generic lowering API.

## Slice Plan
- Start with the narrowest behavior already covered by CTFE parity tests:
  integer literals, simple arithmetic, comparisons, boolean expressions, and
  assertions.
- Promote existing tests from `tests/ut/executors/pure_/lang/expressions.d`
  first, because they already exercise many simple scalar behaviors without
  needing new fixtures.
- Add locals, parameters, returns, and direct calls next, using the existing
  CTFE-passing tests in `control_flow.d` and the function-call cases already in
  the suite.
- Add branches and loops after the scalar and call model is stable. Use the
  current `control_flow.d` coverage as the source of truth for what must work.
- Add arrays, structs, mutation, and reference-like behaviors only when the
  existing CTFE tests in `arrays.d` and `structs.d` force those slices.
- Add exceptions and diagnostics last, because they require the IR to model
  control flow and failure propagation explicitly.
- Keep each slice small enough that one promoted test or one small family of
  tests can verify it. If a behavior needs more than one independent change,
  split it into multiple slices.

## Test Strategy
- Use existing CTFE-passing tests as the acceptance matrix. The test-first step
  is to select a current test, make it fail against the IR backend, then make
  the smallest production change that makes it pass.
- Adding the IR backend to an existing CTFE-passing test is pre-approved: the
  test already exists, so do not stop for approval before making that backend
  promotion.
- Choose the promoted test by expected implementation size. The first PR
  should pick the already-written CTFE-passing test that can be made green with
  the least production code while still entering through the required parsed
  module path and exercising honest IR lowering/execution.
- The first PR should promote a parsed-module backend test that enters through
  `runParsedTests`, not a REPL or `eval` test. Do not implement `eval` or
  `evalRepl` for the first IR backend slice unless that entry point is
  explicitly requested.
- Do not weaken or replace the CTFE tests to satisfy the IR backend. The tests
  define the target behavior.
- Before implementing, inspect the DMD AST that reaches the IR compiler for the
  chosen test. The selected test must force the intended IR operation after
  semantic analysis. If DMD constant-folds the operation away, choose or approve
  a runtime-shaped fixture that prevents folding.
- Prefer public backend behavior tests over implementation-detail tests.
  Add IR-specific tests only for IR-native contracts such as operand typing,
  block/CFG invariants, or explicitly unsupported features.
- When a behavior is already covered by CTFE, treat CTFE as the oracle for
  language-surface behavior unless compiled D code proves otherwise.
- After each slice, run the focused promoted tests and then `dub test --
  --random`.

## Do Not Repeat From PR 98
- Do not make the IR backend recover by reparsing `Module.src` or any other
  source text from the already parsed module. The backend entry point already
  receives a semantically analysed `Module`; reparsing loses the point of the
  pipeline and hides problems in the real IR input.
- Do not keep helper code whose only purpose is to support that reparsing path,
  such as converting a DMD `Module` back into source text for the IR backend.
- Do not paper over failures from `checkaction=context` assert lowering with a
  backend-specific workaround. If promoting a CTFE-passing assertion test causes
  the IR lowerer to encounter DMD-generated assertion machinery, either lower
  the already parsed AST shape deliberately or choose the next smallest approved
  slice that can run from the existing parsed module without reparsing.
- Do not let the first IR promotion depend on a private backend escape hatch.
  The first green test should prove that the IR backend can consume the same
  parsed module pipeline used by the rest of Quickbite.

## Do Not Repeat From Failed PR 103
- Failed PR 103 promoted `tests/ut/backends/pure_/lang/eval.d` and implemented
  `Backend.eval`. That was the wrong first backend slice because it exercised a
  REPL/eval path instead of the parsed-module unittest path.
- Do not implement `Backend.eval` by reparsing a synthetic function such as
  `auto f() { return expr; }`. That does not prove the IR backend can consume
  the already parsed module supplied to `runParsedTests`.
- Do not treat DMD constant folding as successful IR lowering. If the source
  behavior is addition, the compiler must lower an addition-shaped AST to
  addition-shaped IR; returning the folded integer literal is cheating.
- Do not define IR types that overclaim what the compiler has checked. A
  function that accepts any DMD integer expression must not return an
  `IntegerLiteral` unless it first proves the expression is actually a literal.

## Assumptions
- AST-first lowering is acceptable; direct parser-to-IR generation is out of
  scope.
- The first IR backend should optimize for unittest latency, not throughput of
  long-running programs.
- The initial IR does not need to be a universal compiler IR for every future
  backend; it only needs to support the first approved behaviors cleanly.
- Existing CTFE parity tests are the canonical driver for implementation
  sequencing until the IR backend has its own stronger evidence.
