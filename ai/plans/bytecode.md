# Plan: Bytecode VM Backend

## Context

The latency target is the gap between receiving a semantically analysed DMD AST
and returning ok/fail for the selected unittest blocks.

The bytecode backend must therefore avoid the IR backend's lowering cost on the
hot path. Reusing IR lowering is acceptable only as a temporary spike for
learning or parity checks; it is not the intended architecture.

Pipeline:

```text
DMD AST -> direct unittest bytecode emission -> bytecode execution -> ok/fail
```

The first useful result is not a complete VM. It is a narrow AST-to-bytecode
slice that can run minicereal-level tests faster than, or at least near, the IR
backend while preserving the path to broader language coverage.

## Near-Term Shape

Keep the first version deliberately small:

- emit bytecode directly from the analysed AST
- emit only selected unittest bodies and their transitive local dependencies
- walk DMD AST nodes directly inside the backend
- support only the constructs needed by the approved minicereal slice
- fail during emission for unsupported constructs
- prefer a D executor first unless the benchmark shows dispatch is the current
  bottleneck

The bytecode representation must be easy to change. Keep direct writes to the
physical stream behind a tiny emitter API so instruction layout, operand width,
constant pools, or dispatch strategy can change without rewriting the AST walk.
Do not build a large abstraction up front; just avoid spreading raw `code ~=`
encoding across the compiler.

## First Slice

The first slice should answer one question:

> Can direct AST-to-bytecode execution beat the current post-AST IR path for
> the full minicereal suite?

Done means: `benchmarks/run.sh` (which runs minicerealed by default) shows
timings for the bytecode backend alongside `ir` and `treeWalking`.

Implementation should be the dumbest green step:

1. find unittest blocks in the analysed module
2. emit bytecode for each test body and its transitive module-local
   dependencies
3. throw a clear unsupported-bytecode diagnostic for anything not yet
   supported
4. execute that bytecode with the simplest frame model that passes the suite
5. verify timings via `benchmarks/run.sh`

Do not generalise from nearby D constructs until a test forces the next case.

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

## Open Questions

- Is per-unittest dependency discovery needed in the first slice, or is
  module-local function lookup enough?

## Verification

After each editing session:

1. `dub test`

For bytecode-specific work:

1. run the approved focused unittest
2. run `QUICKBITE_EXPERIMENTAL_BACKEND_TESTS=1 dub test`
3. run the post-parse benchmark against `ir` and `treeWalking`
