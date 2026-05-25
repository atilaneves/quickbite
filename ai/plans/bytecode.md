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
- The focused public behaviour is covered by `ut.language.ok.bytecode`.

The first slice deliberately keeps the bytecode representation simple. It still
writes `Instruction` values directly while the opcode set is tiny; introduce an
emitter when the next behaviours make raw writes start spreading.

## Remaining Work

Grow bytecode by moving one approved behaviour at a time into parity coverage:

- add bytecode to the shared backend lists only when the currently selected
  behaviour is supported
- implement unsupported statements one by one, starting with the next fixture
  needed for parity
- implement local variables, assignment, branches, loops, and non-equality
  integer operators
- add call arguments and a real frame model for locals and parameters
- support void functions and explicit bare returns
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
