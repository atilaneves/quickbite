# Project Plan Overview

Rewritten 2026-07-06 to match the `source/quickbite/backends/` architecture;
the previous version described the deleted `quickbite.executor` layer.

## Goal

Minimise the latency of the repeated edit-run loop: from a code change to
"all tests pass" / "at least one failed". DMD parsing and semantic analysis
are fixed costs. Everything after that is our target.

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
`quickbite.ir` / `executors/` layer survives only as glue for the
first-generation IR/bytecode internals and dies with them.

A backend must not fall back to another backend for execution or
diagnostics: unsupported behaviour must be reported as an explicit
unsupported diagnostic from that backend.

Backends:

- `Ctfe` — DMD's built-in CTFE engine. Correctness reference and
  convenient real-D fixture source; NOT the oracle. Where it diverges
  from `SystemLinker` its behaviour is characterized, not treated as
  truth (`single-oracle.md`).
- `Interpreter` — tree-walking AST interpreter. Current centre of
  gravity: execute real dub packages (`interpreter.md`), calling
  compiled dependency leaves natively over FFI (`ffi.md`).
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

- `interpreter.md` — make the Interpreter execute a real dub package
  (cerealed first): phase 0 diagnostic fix, then six gap rungs.
- `ffi.md` — the native-leaf bridge. The §34 ladder is landed with
  tracked residuals (GC-rooted class handles §34.12, generic-marshaller
  audit §34.3.1); the terminal goal is gated on `interpreter.md`.
- `value.md` — Track B: prelude display formatter and its wiring, shared
  `Value` removal, boxed-vs-native representation experiment.
- `bytecode.md` — new-core rewrite; test modules 1–13 promoted; the
  default flip is blocked on REPL oracle policy and both cores being
  unbenchmarked.
- `ir.md` — IR backend promotion; next module `arrays.d`; known
  semantic divergences listed there.
- `dmd-backend.md` — native-backend loading mechanics (slices 1–3
  landed). Open: the lesson-20 rod-imports-phobos correctness fix.
- `repl.md` — REPL redesign; slices 1–4 and 6–7 done, 5 and 8 partial,
  9 (native session) not started.
- `bench.md` — the edit-test latency benchmark. Open: per-package fork
  fix for multi-`--dub`, bench-scoped GC lever.
- `dub-deps.md` — dub dependency images. Open: per-fixture completeness
  (unblocked since 2026-06-19).
- `coverage.md` — corpus semantic-density process; the generative
  mechanisms (mutation ledger, spec walk, dmd-suite mining) are not yet
  started.
- `single-oracle.md` — the testing constitution: `SystemLinker` is the
  single oracle; `ct/` vs `rt/` split; promotion rules.
- `backend-test-modules-order.md` — shared module ordering for backend
  promotion work.

Parked / historical:

- `dmd-compiled-fixture-sentinel.md` — parked design, unstarted.
- `dub-build-via-reggae.md` — superseded by the `dub describe` flag
  path; kept as the fallback direction.
- `llvm-jit.md` — outcome log; backend live, plan complete except the
  upstream JITLink repro item.
- `mini-linker.md` — archived exploration; its conclusion (use LLVM
  JITLink) was adopted.

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
