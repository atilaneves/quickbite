# Backend Interfaces

## Summary

Split backend capabilities into two interfaces:

- one interface for interactive evaluation that returns a displayable
  `quickbite.lang.Value`;
- one interface for executing D code that does not expose `Value` as part of
  the normal execution contract.

The goal is to keep `Value` at REPL and expression-result boundaries. Real code
execution should run D declarations and report completion or failure without
materialising every runtime value as a public display value.

## Motivation

The current `Backend` interface mixes two different jobs:

- `eval` and `evalRepl` run expression-like input and return `Value` for
  inspection and display;
- `runTests`, `runTestResults`, and `runTestSummary` execute D unittest code
  and only need completion, failure, and diagnostics.

Those jobs have different runtime needs. The REPL needs a lossless enough value
representation for display. The VM hot path should be free to use a private
slot representation optimized for execution latency.

## Target Shape

Use capability interfaces with concrete current execution units. Do not invent
an abstract entry-point type before a test forces it.

```d
public interface Evaluator {
    import quickbite.frontend.cell: EvalCell;
    import quickbite.lang: Value;

    public Value eval(in string expr);
    public Value evalRepl(EvalCell cell);
}

public interface Executor {
    import dmd.declaration: FuncDeclaration;

    public void run(FuncDeclaration function_);
}
```

Unittest execution remains a frontend/API layer over `Executor`:

```d
foreachUnitTestDeclaration(module_, (unitTest) {
    executor.run(unitTest);
});
```

Test-result aggregation can remain as convenience functions or a thin adapter,
but it should not be the core backend capability. Implementations must be able
to run all supported D code, not just tests.

`runTests` should go away during the split. It does not provide behaviour that
the more specialised APIs cannot cover:

- callers that only need pass/fail counts can use `runTestSummary`;
- callers that need diagnostics can use `runTestResults`;
- callers that want fail-fast execution can use `Executor` directly while
  iterating discovered unittest declarations.

## Boundary Rules

- `quickbite.lang.Value` is the public value returned by `Evaluator`.
- `Executor` must not require `Value` for ordinary execution.
- VM stacks, locals, constants, and call frames should eventually use a
  VM-private representation.
- Conversion from VM-private values to `quickbite.lang.Value` happens only at
  `Evaluator` result boundaries or when a diagnostic genuinely needs rendered
  runtime operands.
- DMD frontend objects stay behind frontend/compiler boundaries. Bytecode and
  VM artifacts should consume Quickbite-owned ids and metadata.

## Migration Plan

1. Introduce `Evaluator` and `Executor` next to the existing `Backend`
   interface.
2. Move REPL call sites to depend on `Evaluator`, plus whatever test-running
   adapter is needed for REPL commands such as `:t`.
3. Move module/unittest execution paths to depend on `Executor`,
   `runTestSummary`, or `runTestResults`, depending on the information the
   caller needs.
4. Delete `runTests` once its callers have moved to one of those more specific
   paths.
5. Keep the existing `Backend` interface temporarily as a compatibility
   aggregate if that makes the migration smaller.
6. Once call sites no longer need the aggregate, remove or shrink `Backend`.
7. In later bytecode slices, replace direct VM use of `quickbite.lang.Value`
   with a private execution-slot type. The private type may initially wrap or
   alias `Value` while call sites move to the new interfaces.

## Non-Goals

- Do not add an `EntryPoint` abstraction yet. The current concrete executable
  unit is a DMD function-like declaration.
- Do not redesign `quickbite.lang.Value` as part of this interface split.
- Do not change REPL display behavior unless an approved behavior test requires
  it.
- Do not add new test behavior without explicit approval.
