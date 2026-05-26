# Project Plan

## Goal

Minimise the latency of the repeated edit-run loop: from a code change to
"all tests pass" / "at least one failed". DMD parsing and semantic analysis
are fixed costs. Everything after that is our target.

## Process Model

The tool runs as a long-lived process. The user edits code; the tool
re-parses the changed file and re-executes its tests. One-time startup
costs (loading shared libraries, compiling call stubs) are amortised
across many runs. The benchmarking target is the hot-path latency, not
cold start. This is the end goal, but for most of development we will
simply benchmark running all unittest blocks from one module. We don't
yet know which backend will work best, and we do not commit to one
backend or dependency strategy up front.

### Input Scope

One module (one source string) at a time. DMD resolves imports via
configured import paths. The architecture must not close the door on a
future delta mode where only changed files are re-processed.

Dependency-triggered test selection (running only the tests affected by
a change) is deferred. When it is added, the guiding principle is that
uncertainty must over-run tests, not under-run them: an unknown affected
set runs a safe superset.

## Dependencies and Runtime

Dependency handling is part of the experiment. The simplest first bytecode
approach may compile everything it sees. Later variants should measure whether
precompiled dependency bytecode, native dependency calls, or another strategy is
faster for the average dub project.

### Native Call Bridging (open problem)

When the interpreter calls a function from a dependency or the D runtime
it must cross the ABI boundary from the interpreter's value representation
into the native calling convention. Two mechanisms are viable:

- libffi: dynamic call construction, portable, overhead per call
- JIT-compiled stubs: a small native thunk per function, compiled once at
  session start, zero per-call overhead thereafter

This decision is left open. Native calls are one possible dependency strategy,
not an assumed end state. The JIT backend may sidestep this problem if the
chosen library handles calling convention and symbol resolution (native code
calls native code).

## Common Interface

    module quickbite.executor;

    interface Executor {
        void runTests(in string source);
        void runTests(in string source, in string[] importPaths);
    }

The public API accepts source text; the DMD frontend (parse + semantic
analysis) runs once internally, and the result is dispatched to the
backend. Benchmarks measure the full runTests() call so the irreducible
DMD cost is visible; the optimization target is the post-DMD portion.

Public APIs and `quickbite.*` modules must not expose `dmd.*` types.
Backend implementations may carry DMD-backed details internally, but
that coupling must not cross the public module boundary.

## Backends

Backends are independent implementations behind the common interface. A backend
must not fall back to another backend for execution or diagnostics: unsupported
behaviour must be reported as an explicit unsupported diagnostic from that
backend, not hidden by delegating to a different executor.

### 1. IrInterpreterExecutor

Pipeline: DMD → lower to IR → execute IR with long[] temporaries.

Wrapped behind Executor as `ExecutorBackend.ir`.

### 2. TreeWalkingExecutor

Pipeline: DMD → walk the semantically-analysed AST → execute directly.

No lowering step, no IR. Wrapped as `ExecutorBackend.treeWalking`.

### 3. DmdCtfe

Pipeline: delegate execution directly to DMD's built-in CTFE interpreter.

Wrapped as `ExecutorBackend.dmdCtfe`. Serves as a correctness reference
and a ceiling on what the DMD frontend alone can do.
For `pure_` language-surface tests, CTFE is the canonical oracle for supported
behaviour unless the completed dmd codegen backend demonstrates that compiled
D code behaves differently.

### 4. BytecodeExecutor (not yet implemented)

Pipeline: DMD → emit stack bytecode directly from the analysed AST →
switch-dispatch VM.

The baseline avoids the IR lowering pass. An IR-to-bytecode variant may be
measured later, but it is not the initial architecture.

### 5. JitExecutor (deferred)

Pipeline: DMD → lower to IR → JIT compile to native code → execute.

ABI bridging may not be needed if the chosen library handles calling
convention and symbol resolution. Library TBD;
MIR is the leading candidate for its low startup overhead and suitability
for language-runtime use. Only pursue when measurements justify the spike.

## Toy Serialization Library

`tests/minicereal.d` is a minimal integer serializer whose unittest
blocks serve as the concrete language-coverage target. It is D source
but is NOT a dub test target — quickbite compiles and executes it.

The library encodes and decodes all eight integral types little-endian
using `static foreach` and `T.sizeof`, which DMD resolves before the
lowerer sees the AST.

A `Minicereal` struct wrapper with `put`/`get` methods is also covered.
All minicereal unittest blocks pass on all three current backends.

## Real Cerealed Tests

`tests/ut/backends/deps/cerealed.d` runs all 19 cerealed test files against
every `ExecutorBackend` member. The benchmarking harness lives in `benchmarks/`
and accepts `--import-path` flags so cerealed tests can be timed.

## Implementation Phases

1. Add Executor interface; wrap current code as IrInterpreterExecutor.
   (Done.)
2. Implement TreeWalkingExecutor. (Done.)
3. Finish IR language coverage: bit ops, compound assignment, dynamic
   arrays, structs. (Done.)
4. Add `tests/minicereal.d` unittest blocks. (Done; all pass on all
   backends.)
5. Add backend-parity tests for shared supported behaviour. (Done.)
6. Build benchmarking harness; run tree-walker vs IR interpreter on the
   full minicereal test suite. (Done; harness in `benchmarks/`.)
7. Add DmdCtfe backend. (Done.)
8. Run real cerealed tests: all 19 files exercised on all three backends.
   (Done.)
9. Implement the first direct AST-to-stack-bytecode slice and add it to the
   backend parity matrix as soon as it supports the first approved behaviour.
10. Measure bytecode against comparable existing backends.
11. Spike dependency strategies such as cached dependency bytecode and native
    calls when benchmarks show dependency handling matters.
12. Decide whether JIT work is justified based on benchmark results.

## Test Plan

For every new D language feature, add three fixtures:

- one passing unittest source that exercises the feature
- one that triggers an assertion failure (tests the failure path)
- one or more that exercise unsupported constructs and must produce an
  explicit diagnostic rather than silently misbehaving

Once multiple backends exist, add backend parity tests: same analyzed
execution unit, same pass/fail result, same user-facing diagnostic
category across all backends.

Do not add language-surface tests whose expected result differs from CTFE or
compiled D behaviour. Backend-specific regression tests may cover internal
mechanics only when they do not contradict D semantics, and they must be named
and scoped as backend-specific implementation tests rather than placed in the
pure language-surface matrix.

## Future Enhancements

IR currently stores most runtime values as `long`, which is not rich enough to
format every DMD-compatible assertion-context message.  To include IR in the
array-comparison and boolean-comparison diagnostic parity tests, carry enough D
value type information through lowering and execution to distinguish bool,
char, high-bit unsigned values, arrays, and other non-`long` values.

## Known PR 36 Follow-Ups

The contextual unittest assertion diagnostics added in PR 36 are being merged
with known follow-up work:

- `DmdCtfe` reconstructs contextual assertion messages from the last statement
  in a compound block only. If the failing assertion is followed by another
  statement, it reports DMD's generic `Unittest assertion failed.` message.
- `treeWalkingOld` can re-evaluate failed comparison assertion operands while
  formatting the diagnostic. Side effects in operands can change the reported
  values.
- `BytecodeExecutor` stores an explicit assertion message before evaluating the
  assertion condition. If the condition calls code that fails an assertion, the
  outer explicit message can leak into the inner failure.

Fix these with backend-local implementations. If a backend cannot honestly
support a diagnostic behaviour yet, exclude it from that behaviour's tests
rather than adding a fallback path.

## Benchmarking Harness

- Measure wall time of the re-parse + re-execute path (the hot loop).
- Measure DMD frontend alone separately to expose the irreducible floor.
- Inputs: current tiny test suite; larger suites as language coverage grows.
- Metric: min / p50 / p95 / max over ≥200 runs per executor per input.
- Lives in `benchmarks/`; excluded from dub test.
- Backend parity: same selected unittest must produce the same pass/fail
  result and the same user-facing diagnostic category across all backends.

### Known issue: `-inline` disabled

DMD's inliner hangs (>60 s, killed) when compiling `lowering.d` with
`-inline` because the file is large (~8500 lines) and contains deep
mutual recursion between `lowerExpression` and `lowerStatement`.  The
benchmark build type `benchmark-opt` therefore omits `-inline`.  The
fix is to split `lowering.d` into smaller modules; restore `-inline`
(or switch back to `-b release`) once that is done.
