# Plan: Bytecode VM Backend

## Context

The latency target is the gap between receiving a semantically analysed DMD AST
and returning ok/fail for the selected unittest blocks.

The bytecode backend must therefore avoid the IR backend's lowering cost on the
hot path. Reusing IR lowering is acceptable only as a later experiment or
parity spike; it is not the intended baseline architecture.

Pipeline:

```text
DMD AST -> direct unittest bytecode emission -> bytecode execution -> ok/fail
```

The first useful result is not a complete VM. It is the narrowest
AST-to-bytecode slice that can join the existing backend parity matrix for the
first approved behaviour.

Quickbite is not committing to bytecode as the final answer. The project is
measuring execution strategies and may choose different strategies for
different project shapes. Bytecode is one experiment in that portfolio.

## Near-Term Shape

Keep the first version deliberately small:

- emit bytecode directly from the analysed AST
- use the simplest stack VM that can pass the next approved behaviour
- initially handle all code in the analysed execution scope
- walk DMD AST nodes directly inside the backend
- prefer a D executor first unless the benchmark shows dispatch is the current
  bottleneck

The bytecode representation must be easy to change. Keep direct writes to the
physical stream behind a tiny emitter API so instruction layout, operand width,
constant pools, or dispatch strategy can change without rewriting the AST walk.
Do not build a large abstraction up front; just avoid spreading raw `code ~=`
encoding across the compiler.

## First Slice

The first slice should answer one question:

> Can direct AST-to-bytecode execution run the first approved parity fixture?

Done means bytecode is wired into the existing backend parity matrix as early
as possible. Fixtures that bytecode cannot yet run should exclude bytecode
using the same mechanism currently used for the new tree walker. Remove those
exclusions one behaviour at a time.

When a bytecode-only test starts passing because bytecode now implements the
required public behaviour, migrate that test into `tests/ut/backends/parity.d`
in the same change. Keep bytecode-specific tests only for bytecode-only
diagnostics, VM contracts, or known limitations.

Implementation should be the dumbest green step:

1. find unittest blocks in the analysed module
2. emit stack bytecode for the first approved parity fixture
3. execute that bytecode with the simplest frame model that passes the fixture
4. add the bytecode backend to parity coverage for that fixture

Do not generalise from nearby D constructs until a test forces the next case.

Tests should exercise bytecode through public backend behaviour. Do not write
tests that assert bytecode layout, opcode streams, frame internals, or other
private implementation details.

## Current Status

PR 23 adds the first bytecode backend slice:

- `ExecutorBackend.bytecode` is wired into the public executor factory.
- The backend finds unittest blocks in a parsed DMD module.
- The compiler emits stack bytecode directly from DMD AST nodes for the first
  fixture shape: integer literals, equality, assertions, zero-argument function
  calls, and returns.
- The executor runs the bytecode with a simple value stack, return-address
  stack, and halt instruction.
- Unsupported statements and expressions now fail with diagnostics instead of
  being silently ignored.
- `runTestSummary` counts bytecode unittest blocks by compiling and executing
  each block independently.
- The focused public behaviour is covered through `ut.backends.parity`.

The first slice deliberately keeps the bytecode representation simple. It still
writes `Instruction` values directly while the opcode set is tiny; introduce an
emitter when the next behaviours make raw writes start spreading.

## Handoff: Integer Binary Operations

Branch `bytecode-int-addition` grows the bytecode backend through the covered
integer binary-op parity fixtures:

- addition: `ut.backends.parity.intAddition.bytecode`
- subtraction: `ut.backends.parity.intSubtraction.bytecode`
- multiplication: `ut.backends.parity.intMultiplication.bytecode`
- division: `ut.backends.parity.intDivision.bytecode`
- modulo: `ut.backends.parity.intModulo.bytecode`
- right shift: `ut.backends.parity.intShiftRight.bytecode`
- left shift: `ut.backends.parity.intShiftLeft.bytecode`
- bitwise OR: `ut.backends.parity.intBitwiseOr.bytecode`
- bitwise AND: `ut.backends.parity.intBitwiseAnd.bytecode`
- bitwise XOR: `ut.backends.parity.intBitwiseXor.bytecode`
- less than: `ut.backends.parity.intLessThan.bytecode`
- less or equal: `ut.backends.parity.intLessOrEqual.bytecode`
- greater than: `ut.backends.parity.intGreaterThan.bytecode`
- greater or equal: `ut.backends.parity.intGreaterOrEqual.bytecode`
- not equal: `ut.backends.parity.intNotEqual.bytecode`

Each fixture keeps one operand runtime-shaped with a zero-argument helper
function so DMD does not constant-fold the target expression before bytecode
sees it.

Implementation notes:

- binary expression emission is shared through `compileBinaryExpression`
- binary execution is shared through `executeBinaryOperation`
- the value stack is still integer-only (`long[]`)
- equality is intentionally still separate from arithmetic execution

Verification on this branch:

- focused binary-op set:
  `dub test -- ut.backends.parity.intAddition.bytecode
  ut.backends.parity.intSubtraction.bytecode
  ut.backends.parity.intMultiplication.bytecode
  ut.backends.parity.intDivision.bytecode
  ut.backends.parity.intModulo.bytecode
  ut.backends.parity.intShiftRight.bytecode
  ut.backends.parity.intShiftLeft.bytecode
  ut.backends.parity.intBitwiseOr.bytecode
  ut.backends.parity.intBitwiseAnd.bytecode
  ut.backends.parity.intBitwiseXor.bytecode
  ut.backends.parity.intLessThan.bytecode
  ut.backends.parity.intLessOrEqual.bytecode
  ut.backends.parity.intGreaterThan.bytecode
  ut.backends.parity.intGreaterOrEqual.bytecode
  ut.backends.parity.intNotEqual.bytecode`
- full suite: `dub test`

Next recommended slice: integer unary operations. Start with one approved
fixture, such as `ut.backends.parity.intUnaryMinus.bytecode`, and keep
unary complement separate unless it is explicitly approved. Stop before
locals, parameters, branches, or typed values unless those behaviours are
explicitly approved.

## Design Constraints From Review

Keep review feedback aligned with the staged plan. The integer-only `long[]`
value stack is an accepted current shortcut; do not treat boolean/integer
separation as a blocker until the typed-value slice is approved.

The bytecode artifact should not depend on DMD declaration identity at
execution time. DMD AST and `FuncDeclaration` lookup belong in the compiler;
compiled bytecode should expose bytecode-native function ids, entry offsets, or
patched call targets to the executor.

Make this boundary structural for the VM artifact and VM execution core.
Bytecode representation modules, such as `opcode.d`, `module_.d`, and any
future executor core that consumes compiled bytecode, must not import `dmd.*` or
`imported!"dmd.*"`. The compiler and current public `BytecodeExecutor` adapter
may depend on DMD until an explicit interface-split slice removes that need. Add
a compile-time string-import guard over the VM-only modules so future changes
fail during compilation if that boundary is crossed.

The stack, call, and frame convention must be explicit before growing calls
further. Bytecode already has narrow void-return-to-caller coverage in the early
scalar parity group. Parameter, multiple-parameter, void-return, and failure
fixtures exist for other backends; promote those fixtures to bytecode when their
behaviour becomes the approved slice instead of adding duplicate scalar identity
tests. Add narrower bytecode tests only for missing frame behaviours such as
caller locals or temporaries surviving nested calls.

Typed values must come with typed VM semantics. If a branch such as PR 42 moves
bytecode storage from `long[]` to `Value[]`, arithmetic, comparisons,
assertions, and constants must not merely project values through `asLong`.
Either keep bytecode honestly scalar-long until the typed-value slice, or make
typed operation semantics explicit through typed opcodes or compact type and
operator metadata.

Explicit assert messages must belong to the assert operation that owns them.
Ambient VM-wide assert-message state is incorrect: an outer
`assert(inner(), "outer")` currently leaks `"outer"` into an inner failing
`assert(1 == 2)`. The red test should expect the inner failure context
`"1 != 2"` and currently gets `"outer"`. Model assert messages as operands of
`assertTrue`/`assertCompare`, or as scoped state saved and restored across
condition evaluation and calls.

Instruction operands must be domain typed. A function id, assert-message id,
comparison operator, local slot, and literal value are different domains and
should not all be accepted as plain `long` operands. Future typed bytecode must
make invalid instruction construction fail at compile time instead of relying
on opcode convention.

## Review Red Tests

Before changing bytecode design for these findings, add or promote focused
tests that fail for the expected reason. Do not add duplicate coverage.

- DMD-free bytecode artifact: add a compile-time string-import guard over the
  bytecode representation modules and any VM execution core that consumes
  compiled bytecode. It should fail if those files contain `import dmd.` or
  `imported!"dmd.`. Do not include the current public `BytecodeExecutor` adapter
  until an interface-split slice removes its `runParsedTests` dependency on DMD.
- Call and frame convention: reuse existing bytecode parity tests for
  parameters and returns instead of adding another scalar `identity` test.
  Add a new red test only for an uncovered frame property, such as caller
  locals or temporaries surviving a nested call.
- Typed VM semantics: when moving bytecode to typed `Value` storage, promote
  existing non-bytecode parity tests instead of inventing duplicates. Good
  candidates are the dynamic array return/value tests around
  `dynamicArrayReturnValue` and the integral type matrix.
- Assert message scoping: add a bytecode red test equivalent to:

  ```d
  int one() {
      return 1;
  }

  bool inner() {
      // Keep one operand runtime-shaped so DMD does not constant-fold
      // the inner assertion before bytecode sees it.
      assert(one == 2);
      return true;
  }

  unittest {
      // The explicit outer message must not leak into the inner failure.
      assert(inner(), "outer");
  }
  ```

  It must expect the inner assertion context `"1 != 2"` and currently fails
  with `"outer"`.
- Instruction operand domains: add a VM contract test in
  `tests/ut/backends/bytecode.d` that rejects plain integer operands for
  opcodes whose operand domains are not integer literals:

  ```d
  static assert(!__traits(compiles, Instruction(OpCode.call, 0L)));
  static assert(!__traits(compiles,
      Instruction(OpCode.setAssertMessage, 0L)));
  static assert(!__traits(compiles, Instruction(OpCode.assertCompare, 0L)));
  ```

  It currently fails at compile time because those invalid constructions
  compile.

## Remaining Work

Grow bytecode by moving one approved behaviour at a time into parity coverage:

- add bytecode to the shared backend lists only when the currently selected
  behaviour is supported
- implement unsupported statements one by one, starting with the next fixture
  needed for parity
- implement integer unary operators, local variables, assignment, branches, and
  loops
- remove DMD declaration identity from executed bytecode before dependency
  bytecode caching or cross-module bytecode execution work
- replace the current call implementation with an explicit bytecode ABI for
  function ids, argument layout, frame bases, local slots, return arity, and
  expression-statement discard; keep the existing parameter and void-return
  parity coverage green while doing so
- extend return coverage only when tests require new behaviours such as
  non-trailing returns or returns through branch/loop control flow
- replace the current integer-only value stack with typed values, first for
  booleans and integers, then for all D types needed by covered behaviours
- support module state, struct values, arrays, slices, and references as tests
  demand them
- keep dependency and imported-module behaviour behind the existing
  dmd-as-library frontend boundary
- benchmark direct AST-to-bytecode emission before considering native dispatch
  or dependency bytecode caches

## Later Strategy Experiments

The baseline may pay too much emission cost by handling everything. That is
acceptable for the first implementation. Later experiments should measure
whether the average dub project benefits from more specialised strategies:

- precompile dependencies to bytecode and cache them until dependency inputs
  change
- keep project modules in bytecode while jumping to native machine code for
  dependency calls
- compare dependency-bytecode and native-call variants per project shape

Do not assume any one variant is the final strategy. Measure before choosing.

## Files

Expected files, subject to change as the slice teaches us more:

- `source/quickbite/backends/bytecode/opcode.d`
- `source/quickbite/backends/bytecode/module_.d`
- `source/quickbite/backends/bytecode/compiler.d`
- `source/quickbite/backends/bytecode/executor.d`
- `source/quickbite/backends/bytecode/package.d`

Avoid C computed-goto until there is evidence that D dispatch is the limiting
cost. The main risk is extra compilation/emission work, not interpreter branch
prediction.

## Verification

After each editing session:

1. `dub test`

For bytecode-specific work:

1. run the approved focused unittest
2. run `QUICKBITE_EXPERIMENTAL_BACKEND_TESTS=1 dub test`
3. run the relevant post-parse benchmark against comparable backends
