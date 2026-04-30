# Quickbite Forward Plan

## Summary

Prioritize language coverage for pure value-oriented D code before serious
benchmarking. Keep the existing green baseline: DMD parses and semantically
analyzes, Quickbite lowers a narrow slice, and execution currently happens
through a direct IR interpreter.

The public API may keep accepting source strings, but backend comparison must
not use source strings as the backend boundary. The backend boundary starts
after DMD has parsed and semantically analyzed the edited module.

The eventual comparison matrix is:

- DMD semantic tree walker
- project IR interpreter
- bytecode VM
- JIT backends via JIT libraries, possibly multiple libraries

## Process Model

The target workflow is a long-lived process. The user edits code; Quickbite
re-parses the changed module and re-executes the relevant tests. One-time
startup costs such as loading shared libraries or compiling native call stubs
are amortized across many runs.

The initial input scope is one edited module at a time. DMD resolves imports
through configured import paths. The architecture must not close the door on a
future delta mode where only changed files are re-processed.

The benchmarking target is the hot-path latency, not
cold start. This is the end goal, but for most of development we will
simply benchmark running all unittest blocks from one module. We don't
yet know which backend will work best.

## Key Interfaces

Keep public APIs free of `dmd.*` types.

The public convenience layer owns:

- source input
- DMD parsing and semantic analysis
- conversion to an internal analyzed execution unit
- dispatch to the selected backend

The internal backend interface owns only execution:

- input: one analyzed module execution unit for the edited module
- behavior: run the unittests represented by that unit
- failure mode: preserve current exception-based behavior for now
- timing boundary: post-DMD only

The exact D type for the analyzed execution unit is part of the backend
interface work. It must not expose `dmd.*` through public modules. It may carry
DMD-backed implementation details for the tree walker behind that boundary.

Keep project-owned IR as the stable boundary for IR, bytecode, and future JIT
backends. DMD-coupled tree walking is allowed as a backend implementation, but
its DMD coupling must stay out of public APIs and `quickbite.ir.*`.

Dependency-triggered test selection is future work. The principle is that
uncertainty must over-run tests, not under-run them, but this plan does not
design the dependency graph or change the initial input shape to edited file
paths.

## Dependencies and Runtime

Dub dependencies and the D runtime are precompiled native code. Quickbite
should reuse dub's compiled output and must not recompile dependencies as part
of the edit-run loop.

Native call bridging is deferred, but the expected options are:

- `libffi`: dynamic call construction, portable, with per-call overhead
- JIT-compiled stubs: one native thunk per function, compiled once per session

Until bridging exists, calls to external native code must fail explicitly. Add
bridging when the first real fixture requires it. A future JIT backend may
reduce this problem if the chosen JIT library handles calling conventions and
symbol resolution well, but that is a backend-specific property, not an
assumption.

## Implementation Order

1. Stabilize the current direct IR interpreter as backend `ir`.
   Preserve current passing behavior and add the minimum backend selection
   surface needed by tests or benchmarks. Do not add a registry, CLI selector,
   or logging scheme until something consumes it.

2. Expand pure value language coverage in this order:
   locals and variable reads; integer arithmetic; simple function parameters;
   boolean comparisons beyond `==`; `if`/`else` and early returns; loops;
   simple structs by value.

3. For each language slice, write failing source-level tests first, lower only
   the code needed by the represented unittests, reject unsupported constructs
   explicitly, and keep `dub test` green after each editing session.

4. Add comparison backends after enough real code can run:
   `tree`, which directly walks semantically analyzed DMD nodes behind the
   internal boundary; `ir`, the existing project IR interpreter; `bytecode`,
   which encodes IR then executes VM bytecode; and `jit-*`, one backend per JIT
   library.

5. Before implementing `bytecode`, update the IR as described in
   `ai/plans/ir.md`: replace `Function.returnValue` with explicit
   `ReturnValue` instructions and append `ReturnVoid` to unittest bodies.

6. Add timing instrumentation only when backends are comparable. Measure DMD
   frontend, lowering, bytecode encoding, and execution separately. The
   canonical reported number is post-DMD to pass/fail. Report DMD frontend
   time separately as context, not as the backend comparison metric.

7. Defer native dependency/runtime call bridging until the first real fixture
   requires it. Compare `libffi` against JIT-compiled call stubs then.

8. Keep JIT work deferred. Choose candidate JIT libraries only after
   interpreter and bytecode measurements show meaningful headroom.

## Benchmarking

Benchmark hot-loop latency, not cold start. Use a long-lived process and
amortize one-time setup across many iterations.

Measure:

- DMD parse and semantic analysis time
- lowering time
- bytecode encoding time, where applicable
- execution time
- total post-DMD pass/fail latency
- end-to-end public API latency as context

For each executor and input, report min, p50, p95, and max over at least 200
runs. Start with smoke measurements, but delay serious conclusions until the
supported language slice is large enough to resemble useful tests.

## Test Plan

Continue using `dub test` as the required validation step.

For every new D feature, add:

- one passing unittest source fixture
- one assertion-failure fixture
- one or more unsupported-shape diagnostics

Add backend parity tests once multiple backends exist:

- same analyzed execution unit
- same observable pass/fail behavior
- same user-facing failure category or exception message where practical

Add timing smoke tests later, but do not gate correctness on timing numbers.

## Assumptions

- First target code shape is pure value code: primitives, locals, arithmetic,
  booleans, asserts, and deterministic returns.
- Backend comparisons are post-DMD. Public source-based APIs may still measure
  end-to-end latency separately.
- Dependency-triggered selection is important, but cross-module dependency
  scope is intentionally deferred.
- When Quickbite cannot prove the affected unittest set precisely, it runs a
  safe superset.
- JIT work uses JIT libraries, not hand-written machine code or shelling out
  to a native D compiler as the primary experiment.
