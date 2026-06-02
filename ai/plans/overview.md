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

Dependency handling is part of the experiment. The simplest first approach
may compile everything it sees. Later variants should measure whether
precompiled dependency bytecode, native dependency calls, or another strategy
is faster for the average dub project.

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

Pipeline: DMD → lower to IR → execute IR.

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

### 4. BytecodeExecutor

Pipeline: DMD → emit bytecode directly from the analysed AST →
interpret bytecode.

Wrapped as `ExecutorBackend.bytecode`.

### 5. DMD Codegen Backends (deferred)

Pipeline: DMD frontend → DMD native codegen → execute native code through
either a shared-library baseline or an in-process RAM codegen path.

These backends are still planned, but they are likely to come after the
tree-walking, IR, and bytecode backends have matured enough to provide useful
comparison points. Pull them forward only when a specific benchmark or
correctness question needs native-codegen data.

### 6. JitExecutor (deferred)

Pipeline: DMD → lower to IR → JIT compile to native code → execute.

Only pursue when measurements justify the spike.

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
4. Add `tests/minicereal.d` unittest blocks. (Done.)
5. Add backend-parity tests for shared supported behaviour. (Done.)
6. Build benchmarking harness. (Done.)
7. Add DmdCtfe backend. (Done.)
8. Run real cerealed tests. (Done.)
9. Continue maturing the tree-walking, IR, and bytecode backends in parallel,
   adding each backend to existing backend-parity tests as soon as it supports
   the covered behaviour.
10. Measure tree-walking, IR, and bytecode against comparable supported
    language slices.
11. Add the DMD codegen shared-library baseline and RAM codegen experiment
    after those backends have useful comparison coverage, unless an earlier
    benchmark needs native-codegen data.
12. Spike dependency strategies such as cached dependency bytecode and native
    calls when benchmarks show dependency handling matters.
13. Decide whether JIT work is justified based on benchmark results.

## Test Plan

For every new D language feature, add three fixtures:

- one passing unittest source that exercises the feature
- one that triggers an assertion failure (tests the failure path)
- one or more that exercise unsupported constructs and must produce an
  explicit diagnostic rather than silently misbehaving

Once multiple backends exist, add backend parity tests: same analyzed
execution unit, same pass/fail result, same user-facing diagnostic
category across all backends.

Adding a backend to an existing backend-parity test does not require a fresh
test-approval stop. Adding a new test or modifying existing test behaviour
still requires approval before editing the test.

Do not add language-surface tests whose expected result differs from CTFE or
compiled D behaviour. Backend-specific regression tests may cover internal
mechanics only when they do not contradict D semantics, and they must be named
and scoped as backend-specific implementation tests rather than placed in the
pure language-surface matrix.

## Benchmarking Harness

Lives in `benchmarks/`; excluded from `dub test`.
