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
yet know which backend will work best.

### Input Scope

One module (one source string) at a time. DMD resolves imports via
configured import paths. The architecture must not close the door on a
future delta mode where only changed files are re-processed.

Dependency-triggered test selection (running only the tests affected by
a change) is deferred. When it is added, the guiding principle is that
uncertainty must over-run tests, not under-run them: an unknown affected
set runs a safe superset.

## Dependencies and Runtime

Dub dependencies and the D runtime are pre-compiled native code. We reuse
dub's compiled output. The executor does not re-compile them.

### Native Call Bridging (open problem)

When the interpreter calls a function from a dependency or the D runtime
it must cross the ABI boundary from the interpreter's value representation
into the native calling convention. Two mechanisms are viable:

- libffi: dynamic call construction, portable, overhead per call
- JIT-compiled stubs: a small native thunk per function, compiled once at
  session start, zero per-call overhead thereafter

This decision is left open. The initial implementation only needs to run
self-contained tests. Until bridging exists, the lowerer must explicitly
reject any call to external native code rather than silently skipping it.
Add bridging when the first test that calls a dependency needs to run.
The JIT backend may sidestep this problem if the chosen library handles
calling convention and symbol resolution (native code calls native code).

## Common Interface

    module quickbite.executor;

    interface Executor {
        void runTests(in string source);
    }

The public API accepts source text; the DMD frontend (parse + semantic
analysis) runs once internally, and the result is dispatched to the
backend. Benchmarks measure the full runTests() call so the irreducible
DMD cost is visible; the optimization target is the post-DMD portion.

Public APIs and `quickbite.*` modules must not expose `dmd.*` types.
Backend implementations may carry DMD-backed details internally, but
that coupling must not cross the public module boundary.

## Backends

### 1. IrInterpreterExecutor (exists today)

Pipeline: DMD → lower to IR → execute IR with long[] temporaries.

The current implementation. Wrap behind Executor. No other changes yet.

### 2. TreeWalkingExecutor

Pipeline: DMD → walk the semantically-analysed AST → execute directly.

No lowering step, no IR. Eliminates one pipeline stage. Simplest to
implement; likely the winner for small test bodies. When it encounters
a call to native code it will need ABI bridging (see above), but that
is not needed for the initial self-contained slice.

### 3. BytecodeExecutor

Pipeline: DMD → lower to IR → encode to compact byte[] → switch-dispatch VM.

Shares the lowering pass with IrInterpreterExecutor. Adds one encoding
step. Potential advantage: better cache locality in the dispatch loop.
Requires explicit Return in the IR (see ai/plans/ir.md).

### 4. JitExecutor (deferred)

Pipeline: DMD → lower to IR → JIT compile to native code → execute.

ABI bridging may not be needed if the chosen library handles calling
convention and symbol resolution. Library TBD;
MIR is the leading candidate for its low startup overhead and suitability
for language-runtime use. Only pursue if the interpreter benchmarks leave
meaningful headroom.

## Implementation Phases

1. Add Executor interface; wrap current code as IrInterpreterExecutor.
2. Expand pure-value language coverage before adding comparison backends,
   in this order: locals and variable reads; integer arithmetic; simple
   function parameters; boolean comparisons beyond ==; if/else and early
   returns; loops; simple structs by value. Keep dub test green after
   each slice.
3. Implement TreeWalkingExecutor.
4. Build benchmarking harness; run tree-walker vs IR interpreter.
5. Extend IR with explicit Return (see ai/plans/ir.md); implement BytecodeExecutor.
6. Three-way benchmark.
7. Spike native call bridging (libffi vs JIT stubs) when the first test
   that calls a dependency needs to run.
8. Decide on JitExecutor based on benchmark results.

## Test Plan

For every new D language feature, add three fixtures:

- one passing unittest source that exercises the feature
- one that triggers an assertion failure (tests the failure path)
- one or more that exercise unsupported constructs and must produce an
  explicit diagnostic rather than silently misbehaving

Once multiple backends exist, add backend parity tests: same analyzed
execution unit, same pass/fail result, same user-facing diagnostic
category across all backends.

## Benchmarking Harness

- Measure wall time of the re-parse + re-execute path (the hot loop).
- Measure DMD frontend alone separately to expose the irreducible floor.
- Inputs: current tiny test suite; larger suites as language coverage grows.
- Metric: min / p50 / p95 / max over ≥200 runs per executor per input.
- Lives in tests/bench/; excluded from dub test.
- Once multiple backends exist, add parity tests: same selected unittest
  must produce the same pass/fail result and the same user-facing
  diagnostic category across all backends.
