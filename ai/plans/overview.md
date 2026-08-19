# Project Plan Overview

Rewritten 2026-07-06 to match the `source/quickbite/backends/` architecture;
the previous version described the deleted `quickbite.executor` layer.

## Goal

Minimise the latency of the repeated edit-run loop: from a code change to
"all tests pass" / "at least one failed". DMD parsing and semantic analysis
are fixed costs. Everything after that is our target.

## Priority

The product work order is:

1. Make the Interpreter run every Cerealed and automem unittest and agree with
   `SystemLinker`, using only ordinary D semantics. The default LDC-hosted
   benchmark is the acceptance command; packages are feature-discovery and
   integration workloads, never sources of package-specific behavior.
2. Delete the Interpreter's universal expression carrier through
   destination-passing evaluation (`value.md` items 8-10).
3. Execute the formatter in every remaining backend and delete the shared
   `quickbite.lang.Value`.
4. Expand the Interpreter language surface beyond the subset the Cerealed
   gate required.

The Bytecode VM (`bytecode.md`) and the native-layout FFI are a parallel
lane. They may proceed concurrently when their work is file-disjoint
from a higher-priority Interpreter item. Priority 1 wins any resource or shared
file conflict. Within `source/quickbite/backends/bytecode/core/**`, work remains
serial because the compiler, program, and machine changes converge.

With the module split established, the most parallel workflow is:

1. The Interpreter agent owns `backends/interpreter/**` and the necessary
   FFI correctness work until Cerealed is green.
2. The Bytecode agent exclusively owns `backends/bytecode/core/**`
   (`bytecode.md` milestones).
3. The FFI agent exclusively owns `quickbite.ffi.ffi` and does not edit a
   backend.

## Process Model

The tool runs as a long-lived process. The user edits code; the tool
re-parses the changed file and re-executes its tests. One-time startup
costs (loading shared libraries, compiling call stubs) are amortised
across many runs. The benchmarking target is the hot-path latency, not
cold start. We don't yet know which backend will work best, and we do not
commit to one backend or dependency strategy up front.

Dependency-triggered test selection (running only the tests affected by
a change) is deferred. When it is added, the guiding principle is that
uncertainty must over-run tests, not under-run them: an unknown affected
set runs a safe superset.

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
  gravity: execute Cerealed completely (`interpreter.md`).
- `Bytecode` — bytecode VM compiled lazily per function from the
  analysed AST, values in native D layout throughout (`bytecode.md`).
- `IR` — lower-to-IR interpreter (`ir.md`).
- `SystemLinker` — DMD codegen + real link + dlopen. The single
  behaviour oracle for every backend except `Ctfe` (`CONTEXT.md`).
- `LLVMJit` — in-process ORC JIT over DMD codegen.

## Plan Index

Live plans:

- `interpreter.md` — make the default LDC-hosted Interpreter run the package
  gates through package-independent D semantics, then hand off to the
  destination-passing cleanup.
- `ffi.md` — `quickbite.ffi.ffi`, the address-only native-call mechanism every
  backend calls native leaves through.
- `value.md` — Interpreter native storage, prelude display formatting, and
  shared `Value` deletion.
- `bytecode.md` — the bytecode VM: cerealed green, druntime-first
  convergence, coverage, then performance.
- `ir.md` — IR backend promotion; known semantic divergences listed
  there.
- `repl.md` — REPL redesign.
- `backend-test-modules-order.md` — shared module ordering for backend
  promotion work.

The primary-source surveys behind the value-representation, FFI, and
VM-design decisions live in `ai/research/` (`interpreter.md`,
`bytecode.md`, `druntime-reuse.md`). Deleted plans' conclusions live in
their owning plans and git history.

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
