# Plan: IR Backend From Eval Parity

## Summary
Build a new IR backend from scratch by copying the way the bytecode backend
started, not the final structure of bytecode itself. The first implementation
should be tiny: a compiler that lowers one expression shape, a backend-local IR
language file, and a VM that executes that language.

The long-term goal is still a proper IR backend: typed, explicit, independent
from DMD at execution time, and able to grow toward SSA-style values, explicit
control flow, and rewrite-friendly representation. The bytecode backend is only
the example for how to begin without overbuilding.

The test strategy is semi-TDD: pick an existing CTFE-passing `eval` behavior,
make it red for the IR backend, implement the smallest IR change that makes it
green, then move on. Do not invent a separate test suite unless a behavior is
not yet covered anywhere in the current CTFE-backed language tests.

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
- The required starting shape is three backend-local modules: compiler,
  language, and VM. Their contents must be only what the promoted test forces.
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
  language module, a compiler module that lowers DMD expressions to that IR,
  and a VM module that runs only that IR. Prefer `compiler.d`, `language.d`,
  and `vm.d` for the initial module names.
- The initial language may be linear and bytecode-like if that is all the
  promoted `eval` test requires. Do not add SSA, basic blocks, terminators, or
  rewrite machinery until an approved test slice forces them.

## Slice Plan
- Start with the narrowest behavior already covered by the existing backend
  `eval` tests. Prefer integer literals first, then simple arithmetic, then the
  next behavior with the fewest required D language features.
- Promote CTFE-backed test modules in the order documented by
  `ai/plans/backend-test-modules-order.md`. Start with
  `tests/ut/backends/lang/eval.d`, because the bytecode backend already
  proved that path can drive a tiny backend-local compiler/language/VM slice.
- Implement `IR.eval` first. Leave `evalRepl`, `runTests`, and
  `runTestSummary` unimplemented until an approved test specifically
  requires one of those entry points.
- Within each module, start with the simplest individual test before taking
  call-based, short-circuit, aggregate, diagnostic, or integration cases.
- Add locals, parameters, returns, and direct calls only after `eval.d` and the
  early `logic.d` tests have forced enough support to make those features the
  next smallest step.
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
  promotion. This exception only covers adding the backend to an existing
  backend-matrix test; adding a new test or modifying test behaviour still
  requires approval before editing the test.
- Choose the promoted test by expected implementation size. The first PR
  should pick the already-written `eval` test that can be made green with the
  least production code while still exercising honest IR lowering/execution.
- Integer literal support eventually needs explicit coverage for every D
  integer type, not only the default `int` literals in the first eval slice.
  Promote or add coverage for `byte`, `ubyte`, `short`, `ushort`, `int`,
  `uint`, `long`, and `ulong` before relying on literal lowering more broadly.
- The first PR should enter through `Backend.eval`, mirroring the successful
  bytecode backend start. Do not promote module-backed unittest execution for
  the first IR backend slice.
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
- CTFE coverage reports do not rank Quickbite test modules by simplicity. All
  backend language modules run against CTFE, so use
  `ai/plans/backend-test-modules-order.md` to choose post-`eval` targets by
  required D language features, not by file length or coverage counts.
- After each slice, run the focused promoted tests and then `dub test --
  --random`.

## Do Not Repeat From PR 98
- Do not make the IR backend recover by reparsing `Module.src` or any other
  source text from the existing DMD module. The backend entry point already
  receives a semantically analysed `Module`; reparsing loses the point of the
  pipeline and hides problems in the real IR input.
- Do not keep helper code whose only purpose is to support that reparsing path,
  such as converting a DMD `Module` back into source text for the IR backend.
- Do not paper over failures from `checkaction=context` assert lowering with a
  backend-specific workaround. If promoting a CTFE-passing assertion test causes
  the IR lowerer to encounter DMD-generated assertion machinery, either lower
  the existing DMD AST shape deliberately or choose the next smallest approved
  slice that can run from the existing DMD module without reparsing.
- Do not let the first IR promotion depend on a private backend escape hatch.
  The first green test should prove that the IR backend can consume the same
  module pipeline used by the rest of Quickbite.

## Do Not Repeat From Failed PR 103
- `Backend.eval` is now the correct first entry point, but do not implement it
  by reparsing a synthetic function such as `auto f() { return expr; }`.
  Compile the expression through the same frontend expression path used by the
  bytecode backend.
- Do not treat DMD constant folding as successful IR lowering. If the source
  behavior is addition, the compiler must lower an addition-shaped AST to
  addition-shaped IR; returning the folded integer literal is cheating.
- Do not define IR types that overclaim what the compiler has checked. A
  function that accepts any DMD integer expression must not return an
  `IntegerLiteral` unless it first proves the expression is actually a literal.

## Do Not Repeat From Failed PR 109
- Failed PR 109 did too much for the first IR slice: module-backed unittest
  execution, module compilation, unittest discovery, function compilation,
  calls, declarations, equality, assertion handling, and test execution all
  appeared before the first tiny `eval` slice existed.
- Do not start with `compileModule`, unit test discovery, assertion lowering,
  function tables, or module-backed test execution. Start with the expression compiler,
  IR language, and VM needed by one `eval` test.
- Do not add several IR node kinds because they seem inevitable. Add one only
  when the promoted test fails without it.
- Do not confuse eventual IR shape with first PR shape. The first PR should
  look embarrassingly small, as the bytecode backend's first PR did.

## Follow-Up From PR #122 Review

1. **`integerValue` casts unconditionally to `int`** (`compiler.d`): dispatch on
   `integer.type.toBasetype.ty` and produce the correctly-typed `Value`, the
   same way `realValue` already switches on `TY`. Address before integer-type
   tests are promoted.

2. **Missing function attributes** (`compiler.d`, `vm.d`, `language.d`): add
   `@safe pure nothrow` (and `@nogc` where applicable) to all IR backend
   module-scope functions and structs. Verify DMD AST methods to determine
   whether `@trusted` wrappers are needed for the compiler functions.

3. **No top-level `RealExp` branch in `compileExpression`** (`compiler.d`):
   `eval("3.75f")` would assert, and a DMD version that constant-folds
   `1.5f + 2.25f` to a `RealExp` would silently break the float add test. Add
   a top-level `isRealExp` branch mirroring the existing `isIntegerExp` branch.

## Assumptions
- AST-first lowering is acceptable; direct parser-to-IR generation is out of
  scope.
- The first IR backend should optimize for unittest latency, not throughput of
  long-running programs.
- The initial IR does not need to be a universal compiler IR for every future
  backend; it only needs to support the first approved behaviors cleanly.
- Existing CTFE parity tests are the canonical driver for implementation
  sequencing until the IR backend has its own stronger evidence.
