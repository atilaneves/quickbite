# Project Plan Overview

## Goal

Minimise the latency of the repeated edit-run loop: from a code change to
"all tests pass" / "at least one failed". DMD parsing and semantic analysis
are fixed costs. Everything after that is our target.

## Current Architecture

The live design is `source/quickbite/backends/` behind the frontend in
`source/quickbite/frontend/` (dmd-as-a-library; public `quickbite.*` APIs
must not expose `dmd.*` types). The old `quickbite.executor` /
`quickbite.ir` layer remains coupled to the first-generation IR/bytecode
internals and dies with them.

A backend must not fall back to another backend for execution or
diagnostics: unsupported behaviour must be reported as an explicit
unsupported diagnostic from that backend.

Backends:

- `Ctfe` — DMD's built-in CTFE engine. Correctness reference and
  convenient real-D fixture source; NOT the oracle. Where it diverges
  from `SystemLinker` its behaviour is characterized, not treated as
  truth (`AGENTS.md`, Testing).
- `Interpreter` — tree-walking AST interpreter. Current centre of
  gravity: execute real packages through native typed places and ordinary D
  runtime semantics (`interpreter.md`).
- `Bytecode` — bytecode VM compiled lazily per function from the
  analysed AST, values in native D layout throughout (`bytecode.md`).
- `IR` — lower-to-IR interpreter (`ir.md`).
- `SystemLinker` — DMD codegen + real link + dlopen. The single
  behaviour oracle for every backend except `Ctfe` (`CONTEXT.md`).
- `LLVMJit` — in-process ORC JIT over DMD codegen.

## Testing Rules

AGENTS.md governs, with the testing vocabulary in `CONTEXT.md` and the
matrix mechanics enforced in `tests/ut/backends/package.d`. In brief:
strict TDD; no test additions or behaviour changes without approval;
promoting an existing oracle-backed matrix test to another backend is
pre-approved; language-surface tests must match compiled-D behaviour with
`SystemLinker` as
oracle; backend-specific regression tests are named and scoped as such,
outside the language-surface matrix.

## Benchmarking

Lives in `benchmarks/`, driven by `bin/bench.sh` (reggae-built optimised
LDC host). Excluded from `dub test`.

Measurement contract for backend acceptance timings:

- The gate command is the plan-owned `bin/bench.sh` invocation for the
  driving package (`interpreter.md` §10, `bytecode.md` milestone 1).
- Official timings run with garbage collection enabled. The harness
  currently disables the GC for the timed loop (`benchmarks/harness.d`);
  until it grows a lever, GC-disabled numbers are diagnostics, not
  acceptance results.
- No fixed multiplier target. Every landed slice must reduce the
  backend-to-`SystemLinker` post-parse ratio, re-measured with the gate
  command; the expected destination is beating the `SystemLinker` row,
  since interpretation must out-run compile+link+run per verdict to
  justify itself.
- The corpus grows by code.dlang.org popularity plus the maintainer's
  own packages, so selection stays external and cannot be gerrymandered
  toward what already passes. Registry-latest resolution, with a
  local-path checkout where the published release diverges; no version
  pinning.
