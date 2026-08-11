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
   destination-passing evaluation, beginning with the no-result statement
   path (`value.md` item 8).
3. Execute the formatter in every remaining backend and delete the shared
   `quickbite.lang.Value`.
4. Expand the Interpreter language surface beyond the subset the Cerealed
   gate required.

The compositional Bytecode refactor and the new native-layout FFI are a
parallel lane. They may proceed concurrently when their work is file-disjoint
from a higher-priority Interpreter item. Priority 1 wins any resource or shared
file conflict. Within `source/quickbite/backends/bytecode/core/**`, work remains
serial because the compiler, program, and machine changes converge.

With the module split established, the most parallel workflow is:

1. The Interpreter agent owns `backends/interpreter/**` and the necessary
   FFI correctness work until Cerealed is green.
2. The Bytecode agent exclusively owns `backends/bytecode/core/**`, continuing
   the compositional refactor and native slice-layout correction.
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
  truth (`single-oracle.md`).
- `Interpreter` — tree-walking AST interpreter. Current centre of
  gravity: execute Cerealed completely (`interpreter.md`).
- `Bytecode` — first-generation bytecode VM (legacy core), being
  strangler-replaced by the typed-frame new core behind the
  `BytecodeNewCore` handle (`bytecode.md`).
- `IR` — lower-to-IR interpreter (`ir.md`).
- `SystemLinker` — DMD codegen + real link + dlopen. The single
  behaviour oracle for every backend except `Ctfe`
  (`single-oracle.md`).
- `LLVMJit` — in-process ORC JIT over DMD codegen (`llvm-jit.md`).

## Plan Index

Live plans:

- `interpreter.md` — make the default LDC-hosted Interpreter run the package
  gates through package-independent D semantics, then hand off to the
  destination-passing cleanup.
- `ffi.md` — `quickbite.ffi.ffi`, the address-only native-call mechanism every
  backend calls native leaves through.
- `value.md` — Interpreter native storage, prelude display formatting, and
  shared `Value` deletion.
- `RESEARCH.md` — pinned primary-source survey supporting the value-carrier,
  destination-passing, FFI-cache, and callback decisions owned normatively by
  `value.md` and `ffi.md`.
- `bytecode.md` — typed-frame bytecode VM. The new core became the `Bytecode`
  default on 2026-07-09; the plan now owns post-flip coverage, REPL formatter,
  native-runtime, and benchmark follow-up work.
- `ir.md` — IR backend promotion; next module `arrays.d`; known
  semantic divergences listed there.
- `dmd-backend.md` — native-backend loading mechanics (slices 1–3
  landed). Open: the lesson-20 rod-imports-phobos correctness fix.
- `repl.md` — REPL redesign; slices 1–4 and 6–7 done, 5 and 8 partial,
  9 (native session) not started.
- `bench.md` — the edit-test latency benchmark. Open: per-package fork
  fix for multi-`--dub`, bench-scoped GC lever.
- `llvm-jit.md` — mostly an outcome log (backend live; full matrix +
  LDC bench parity done, parity slices 1–4 complete). The
  `backends/ffi/dependency_image.d` `--random` RTLD_GLOBAL-collision flake is
  fixed
  (per-backend unique module names). Open: two upstream JITLink minimal
  repros (duplicate-`UND`; hidden-weak `DW.ref.*`), both worked around in
  `orc/elf.d`, neither filed.
- `dub-deps.md` — dub dependency images. Open: per-fixture completeness
  (unblocked since 2026-06-19).
- `coverage.md` — corpus semantic-density process; the generative
  mechanisms (mutation ledger, spec walk, dmd-suite mining) are not yet
  started.
- `single-oracle.md` — the testing constitution: `SystemLinker` is the
  single oracle; `ct/` vs `rt/` split; promotion rules.
- `backend-test-modules-order.md` — shared module ordering for backend
  promotion work.

Deleted plans whose conclusions were folded into their owning plans:
`dub-build-via-reggae.md` (superseded by the `dub describe` flag path;
fallback argument folded into bench.md's template-emission section),
`mini-linker.md` (rejected in favour of LLVM JITLink; decision folded
into llvm-jit.md's Scope section), and `example-corpus.md` (queue fully
landed in `tests/example.d`; the policy note moved to a doc comment
there, and the bugs found along the way folded into bytecode.md's and
interpreter.md's own gap queues).

## Testing Rules

AGENTS.md and `single-oracle.md` govern. In brief: strict TDD; no test
additions or behaviour changes without approval; promoting an existing
oracle-backed matrix test to another backend is pre-approved; language
-surface tests must match compiled-D behaviour with `SystemLinker` as
oracle; backend-specific regression tests are named and scoped as such,
outside the language-surface matrix.

## Benchmarking

Lives in `benchmarks/`, driven by `bin/bench.sh` (reggae-built optimised
LDC host; see `bench.md`). Excluded from `dub test`.
