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
- Existing CTFE-passing tests are pre-approved for IR promotion. Do not stop
  for test-change approval when only adding the IR backend to an existing test.
- Do not weaken or replace the CTFE tests to satisfy the IR backend. The tests
  define the target behavior.
- Prefer public backend behavior tests over implementation-detail tests.
  Add IR-specific tests only for IR-native contracts such as operand typing,
  block/CFG invariants, or explicitly unsupported features.
- When a behavior is already covered by CTFE, treat CTFE as the oracle for
  language-surface behavior unless compiled D code proves otherwise.
- After each slice, run the focused promoted tests and then `dub test --
  --random`.

## Assumptions
- AST-first lowering is acceptable; direct parser-to-IR generation is out of
  scope.
- The first IR backend should optimize for unittest latency, not throughput of
  long-running programs.
- The initial IR does not need to be a universal compiler IR for every future
  backend; it only needs to support the first approved behaviors cleanly.
- Existing CTFE parity tests are the canonical driver for implementation
  sequencing until the IR backend has its own stronger evidence.
