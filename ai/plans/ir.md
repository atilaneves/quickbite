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
  `IntegerLiteral(3)` is not an IR implementation of addition. This does not
  forbid consuming DMD's already-folded AST when the promoted behavior is the
  resulting value or when folding is incidental to a larger behavior; it only
  forbids claiming coverage for an IR operation that the selected AST no
  longer contains.
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
  explicit instead of hidden in the value graph. Use a hybrid mutation model:
  SSA values for scalars and pure computation; a separate typed place-reference
  namespace for mutable memory (`ref` parameters, array elements, struct
  fields, slices). Mutation goes through `load`/`store` on place references,
  not through handles in a side table and not through ordinary SSA pointer
  values. This handles D's aliasing naturally, keeps CTFE viable (a CTFE
  interpreter evaluates load/store directly), and makes ownership analysis on
  place references tractable in SSA. The legacy IR's `ArrayAlias` side-table is
  the specific anti-pattern this replaces.
- Every IR value carries an explicit type at its definition site (e.g., `i32`,
  `i64`, `f32`, `f64`). The executor selects the operation from the
  instruction's declared type, not from a runtime tag on the value. D language
  types are mapped to the cheapest IR representation that preserves enough
  D-visible scalar semantics for direct execution and final result conversion.
  The IR does not represent D's full type hierarchy, but the VM must not need
  DMD lookups or `quickbite.lang.Value` dispatch to recover signedness,
  character-ness, float width, or result category. This can be represented
  with D-aware scalar types or with LLVM-style width types plus explicit
  signedness/category on operations, casts, comparisons, and return/result
  metadata; choose the representation that best serves edit-to-test-result
  latency for the current slice. Never dispatch on `value.isFloating` or an
  equivalent runtime check — that is the legacy IR's central mistake and the
  root cause of its inconsistent arithmetic handling.
- Keep control flow explicit with basic blocks and terminators. Prefer a form
  that is easy to rewrite locally and does not depend on AST shape. Each basic
  block carries an optional exception successor (the landing pad block). All
  potentially throwing instructions in that block unwind to that successor;
  lowering must split blocks when exception scope changes. Blocks that cannot
  throw leave it empty; blocks inside a try body name the landing pad. Do not
  attach exception handlers to ordinary branch terminators, because branches do
  not throw. Do not encode exception scope as inline instruction counts — that
  is the legacy IR's `TryCatch` anti-pattern and requires two-pass patching to
  emit.
- Make function ids, block ids, value ids, and constant references IR-native.
  The IR should not depend on DMD declaration identity at execution time. This
  applies equally to struct field access: field names are resolved by the
  compiler during lowering and emitted as numeric indices into a per-type
  layout table. IR instructions for field reads and writes carry the index, not
  the name string. The executor never compares strings during normal execution.
- Module-level and `static` local variables are entries in a per-module
  variable table, identified by integer index and typed at definition time.
  The executor allocates the table on module load. Do not use string-keyed
  maps for static state — the legacy IR's `StaticArray`/`StaticInt` collision
  (both keyed into the same `string → Value` map) is the specific anti-pattern
  this avoids.
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
- The IR shape is CFG + basic blocks + block parameters from the first slice.
  A single-block function with no branches is trivially SSA — no block
  parameters are needed until a test requires a control-flow join, but the
  structure must accommodate them from the start. Do not build a linear
  bytecode array; build a block list where the first block happens to have no
  successors yet. Converting a flat bytecode IR to SSA later is a full
  structural rewrite, not an incremental step.

## Current Implementation State

The first CFG/value reset is complete for the already-promoted eval slices.
`language.d` now defines backend-local typed values, result categories,
instructions, terminators, blocks, and functions. Functions carry their SSA
value count and local count so the VM can size storage once before execution.
`compiler.d` lowers eval source through the existing frontend eval-cell parser,
walks the single eval function body, and supports integer literals, `float` and
`double` literals, simple arithmetic expressions, local scalar declarations with
expression initializers, local loads, the DMD semantic increment shape used by
`++x`, and the narrow runtime cast shapes currently covered by
`castsFloatingValueNumerically.IR` (`f64` to `i32`) and
`castsRuntimeValuesToIntegerTypes.IR` (`i32` to `i8`, `i16`, `i32`, and `i64`
storage, with result category preserving signedness). The promoted
`defaultUintPreservesScalarType.IR` test passed without new production code:
the existing default local initialization path already lowers `uint value` as
an `i32` local with `uint_` result metadata, and the VM's boundary conversion
preserves the public `uint` result. The promoted
`floatingSubtractionUsesNumericValues.IR` test added only the VM support needed
to execute an already-lowered `BinaryOperation.subtract` on `f64` operands and
store the raw `double` result bits. The promoted
`floatingUnaryMinusUsesNumericValue.IR` test added the backend-local
`UnaryOperation.negate` instruction shape, compiler lowering for DMD `NegExp`,
and VM execution for `f64` negation. The promoted
`fabsFloatPreservesReturnType.IR` test added no-op import statement handling,
narrow call lowering for one-argument `fabs`, the backend-local
`UnaryOperation.fabs` instruction shape, `f32` value-type mapping and local
storage, and VM execution for `f32` `fabs` while preserving the public `float`
result. The promoted `powFloatDoesNotReturnDoubleValue.IR` test added narrow
two-argument `pow` call lowering to a typed `BinaryOperation.pow` instruction
and VM execution for `f32` operands while preserving the public `float` result.
IR values carry both an operation type (`i32`, `f32`, and so on) and a
D-visible scalar result category so the VM can keep arithmetic dispatch typed
while preserving the public eval result type. `vm.d` executes the single entry
block directly before converting the returned IR value to `quickbite.lang.Value`
at the backend boundary.

The current mutation support is intentionally narrow. Locals are identified by
compiler-assigned integer indices, and `Load`/`Store` operate on those local
slots for the promoted scalar eval slices. The compiler preserves each local's
IR scalar type and result category for later loads, but this is not yet the
full typed place-reference model needed for refs, fields, array elements,
slices, or aliases.

The currently covered IR backend eval tests are:

- `literal.IR`
- `add.int.0.IR`
- `add.int.1.IR`
- `add.int.2.IR`
- `add.float.IR`
- `arithmetic.IR`
- `multiCell.IR`
- `preservesScalarValueTypes.IR`
- `castsFloatingValueNumerically.IR`
- `castsRuntimeValuesToIntegerTypes.IR`
- `defaultUintPreservesScalarType.IR`
- `floatingSubtractionUsesNumericValues.IR`
- `floatingUnaryMinusUsesNumericValue.IR`
- `fabsFloatPreservesReturnType.IR`
- `powFloatDoesNotReturnDoubleValue.IR`

The next implementation slice should pick the next smallest current
CTFE-backed eval behavior that still excludes `IR`, promote the existing
backend matrix, and run the focused test. If it is red, verify it is red for
the expected missing behavior. If it is green, verify the greenness by
temporarily mutating the promoted test or relevant production code, confirming
the focused test fails, and restoring the mutation. Inspect the DMD AST that
reaches the IR compiler, then add only the IR shape and VM support required by
that behavior. Verify the current checkout before editing because backend
progress notes can go stale.

### Next Slice Handoff

Start with `tests/ut/backends/lang/eval.d`. Verify that
`floatingSubtractionUsesNumericValues` includes `IR`; if it does not, treat
this handoff as stale and restore the completed promotion before moving on.
Then choose the next smallest eval behavior that still excludes `IR`.

The completed cast slices promoted only existing backend matrices and added a
backend-local `Cast` instruction plus VM support for the observed `f64` to
`i32` runtime cast and `i32` runtime casts to the integer storage widths needed
by `castsRuntimeValuesToIntegerTypes.IR`. They also made initialized scalar
locals preserve their IR type/result metadata so `double input = 7.75` loads as
`f64` instead of the earlier integer-only local shape. This is not general cast
support yet.

### Target shape for the three backend-local modules

**`language.d`** defines the IR data types:

- `Type` enum: `i1`, `i8`, `i16`, `i32`, `i64`, `f32`, `f64`, `ptr`. D source
  scalar and pointer values are mapped to these by the compiler; the IR does
  not represent D's type hierarchy. `ptr` represents D pointer values, not
  mutable places. Add a separate `Place` or `PlaceId` representation when
  `Alloca`, `Load`, and `Store` are promoted.
- `Value` struct: `uint id`, `Type type`, and `ResultType resultType`. Every
  SSA value declares its operation type at the single definition site. The
  executor never inspects a runtime tag to decide which arithmetic path to
  take; the result category is used only for D-visible boundary conversion.
- Instructions as a `SumType`. Start with `Const` (typed constant scalar,
  raw bits + destination `Value`) and `BinaryOp` (typed binary op, operation
  enum + lhs/rhs value ids + destination `Value`). Add `Alloca`, `Load`, and
  `Store` when mutation tests are promoted; `Load` and `Store` consume typed
  place references, not ordinary `ptr` SSA values. Do not store
  `quickbite.lang.Value` inside IR instructions; convert to that public API
  type only at backend boundaries.
- Terminators as a `SumType`: `Branch` (unconditional jump to a target block
  id with positional args), `CondBranch` (conditional jump with args for both
  successors), `ReturnValue` (return a value id), `ReturnVoid`.
- `Block` struct: `uint id`, `Value[] params` (block parameters — SSA values
  defined on entry, supplied positionally by predecessor branch args),
  `Instruction[] instructions`, `Terminator terminator`, and an explicit
  optional exception successor. Do not use block id `0` as a sentinel;
  `blocks[0]` is the entry block.
- `Function` struct for the eval-only slice: `Block[] blocks` (`blocks[0]` is
  the entry block; its params are the function parameters when parameters are
  first promoted) plus return type/result metadata and the SSA value count
  needed to size VM value storage once per function execution.
- Add function ids, debug names, module function tables, and `StaticVar` tables
  only when direct calls, module-backed tests, or static variables are the
  promoted red behavior. Module-level and `static` local variables must be
  identified by integer index and typed at definition time when they are added.
  No string keys.

**`compiler.d`** lowers a DMD expression to a `Function` containing a single
`Block`. `eval("42")` emits `Const` + `ReturnValue`. `eval("1 + 2")` emits
two `Const` instructions + `BinaryOp(add, i32)` + `ReturnValue`. The
single-block case requires no block parameters and no `Branch`/`CondBranch`;
it still ends with a `ReturnValue` or `ReturnVoid` terminator. The structure is
correct for CFG+SSA and accommodates joins as soon as a test requires one.

**`vm.d`** walks `Block.instructions` in order and evaluates the `Terminator`.
For the initial single-block case this degenerates to a linear walk ending at
`ReturnValue`. The block-dispatch loop that handles `Branch` and `CondBranch`
is added when a test requires control flow.

## Slice Plan
- Continue with the narrowest behavior already covered by the existing backend
  `eval` tests that still excludes `IR`. Integer literals and simple integer
  addition are already covered by the CFG/value IR slice; prefer the next eval
  behavior with the fewest required D language features.
- Promote CTFE-backed test modules in the order documented by
  `ai/plans/backend-test-modules-order.md`. Start with
  `tests/ut/backends/lang/eval.d`, because the bytecode backend already
  proved that path can drive a tiny backend-local compiler/language/VM slice.
- Before promoting a named test mentioned by this plan or a review note,
  verify in the current checkout that its enclosing backend matrix still
  excludes `IR`. If it already uses `backendsWith!IR`, treat the note as
  stale and choose the next smallest current CTFE-only candidate.
- `IR.eval` is the only implemented IR backend entry point. Leave `evalRepl`,
  `runTests`, and `runTestSummary` unimplemented until an approved test
  specifically requires one of those entry points.
- Within each module, start with the simplest individual test before taking
  call-based, short-circuit, aggregate, diagnostic, or integration cases.
- Add locals, parameters, returns, and direct calls only after `eval.d` and the
  early `logic.d` tests have forced enough support to make those features the
  next smallest step.
- Add branches and loops after the scalar and call model is stable. Use the
  current `control_flow.d` coverage as the source of truth for what must work.
- Add arrays, structs, mutation, and reference-like behaviors only when the
  existing CTFE tests in `arrays.d` and `structs.d` force those slices.
- Add minimal mechanically-derived unsupported-feature diagnostics as soon as a
  promoted test reaches an unsupported AST or IR shape. Defer rich language
  diagnostics, assertion formatting, exception diagnostics, and source-location
  polish until `diagnostics.d`, exceptions, or another specific promoted test
  requires them.
- Keep each slice small enough that one promoted test or one small family of
  tests can verify it. If a behavior needs more than one independent change,
  split it into multiple slices.

## Test Strategy
- Use existing CTFE-passing tests as the acceptance matrix. The test-first step
  is to select a current test, make it fail against the IR backend, then make
  the smallest production change that makes it pass.
- Do not trust backend progress text as an edit target without checking the
  test file. A stale plan should trigger current-test discovery, not a broad
  promotion.
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
  semantic analysis when the promoted behavior is that operation. If DMD
  constant-folds the operation away, choose or approve a runtime-shaped fixture
  that prevents folding. Already-folded AST nodes are acceptable for tests whose
  behavior is the resulting value rather than the folded-away operation.
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
- The positive rule for module-backed execution: `runTests`, `runTestResults`,
  and `runTestSummary` consume the semantically analysed DMD `Module` they
  receive. They do not construct a source string, do not call `parseModule`,
  and do not wrap code in a synthetic function. The legacy `IrExecutor.eval`
  in `quickbite.executors.ir` demonstrates the anti-pattern; the new backend
  must not copy it.
- The positive rule for `Backend.eval(string)`: parse and semantically analyse
  the expression through the frontend expression path, then lower that DMD AST
  to IR. This mirrors the bytecode backend's starting path. Do not implement
  `eval` by reparsing a synthetic function such as
  `auto f() { return expr; }`.
- Do not keep helper code whose only purpose is to support that reparsing path,
  such as converting a DMD `Module` back into source text for the IR backend.
- Do not paper over failures from `checkaction=context` assert lowering with a
  backend-specific workaround. If promoting a CTFE-passing assertion test causes
  the IR lowerer to encounter DMD-generated assertion machinery, either lower
  the existing DMD AST shape deliberately or choose the next smallest approved
  slice that can run from the existing DMD module without reparsing.
- Do not let the first IR promotion depend on a private backend escape hatch.
  The first green `eval` test should prove that the IR backend consumes the
  frontend expression pipeline used by bytecode. The first module-backed
  promotion should prove that `runTests`, `runTestResults`, or
  `runTestSummary` consumes the same module pipeline used by the rest of
  Quickbite.

## Do Not Repeat From Failed PR 103
- `Backend.eval` is now the correct first entry point, but do not implement it
  by reparsing a synthetic function such as `auto f() { return expr; }`.
  Compile the expression through the same frontend expression path used by the
  bytecode backend.
- Do not treat DMD constant folding as successful IR lowering for the operation
  being promoted. If the source behavior under test is addition, the compiler
  must lower an addition-shaped AST to addition-shaped IR; returning the folded
  integer literal is cheating. For tests whose behavior is the resulting value,
  consuming an already-folded AST is acceptable and may reduce edit-to-test
  latency.
- Do not define IR types that overclaim what the compiler has checked. A
  function that accepts any DMD integer expression must not return an
  `IntegerLiteral` unless it first proves the expression is actually a literal.

## Do Not Repeat From Failed PR 109
- Failed PR 109 did too much for the first IR slice: module-backed unittest
  execution, module compilation, unittest discovery, function compilation,
  calls, declarations, equality, assertion handling, and test execution all
  appeared before the first tiny `eval` slice existed.
- Do not start with `compileModule`, unit test discovery, assertion lowering,
  function tables, or module-backed test execution. Start with the expression
  compiler, IR language, and VM needed by one `eval` test.
- Do not add several IR node kinds because they seem inevitable. Add one only
  when the promoted test fails without it.
- Do not confuse eventual IR shape with first PR shape. The first PR should
  look embarrassingly small, as the bytecode backend's first PR did.

## Follow-Up From PR #122 Review

- **Function attributes** (`compiler.d`, `vm.d`, `language.d`): add
  `@safe pure nothrow` (and `@nogc` where applicable) to all module-scope
  functions and structs in the replacement modules. Verify DMD AST methods to
  determine whether `@trusted` wrappers are needed for the compiler functions.

## Assumptions
- AST-first lowering is acceptable; direct parser-to-IR generation is out of
  scope.
- The first IR backend should optimize for unittest latency, not throughput of
  long-running programs.
- The initial IR does not need to be a universal compiler IR for every future
  backend; it only needs to support the first approved behaviors cleanly.
- Existing CTFE parity tests are the canonical driver for implementation
  sequencing until the IR backend has its own stronger evidence.
