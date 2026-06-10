# Backend Interfaces

## Summary

Split backend capabilities into two interfaces:

- one interface for interactive evaluation that returns a displayable
  `quickbite.lang.Value`;
- one interface for executing D code that does not expose `Value` as
  part of the normal execution contract, and reports failure as a
  diagnostic string rather than by throwing.

The goal is to keep `Value` at REPL and expression-result
boundaries. Real code execution should run D declarations and report
completion or failure without materialising every runtime value as a
public display value.

## Status (June 2026)

**Decision (June 2026): one execution primitive, failure-as-data.**
The execution surface collapses to a single backend method —
`EvalResult eval(FuncDeclaration)`. `EvalResult` is a sum type,
`SumType!(Value, EvalResult.Diagnostic)` — the nested `Diagnostic`
wraps the failure message, which only means anything as part of a
result — so the "value and error message at once" state is
unrepresentable. It exposes `failed`, `value` (`Value.void_` on failure
or for a statement that produces nothing), and `diagnostic` (null on
success) accessors. `eval(string)`, `eval(Cell)`, and `runTests` are
`final` adapters over it. The earlier `eval` / `evalCell` / `runCell` /
`runUnitTest` quartet is gone. See `PLAN.md` at the repo root for the
implementation slices (1–3 now complete). The REPL cell type `EvalCell`
was renamed to `Cell`, with its kind enum nested as `Cell.Kind`.

Why one, not two-or-more (correcting the prior "two primitives, not
one" rationale):

- The bytecode "`eval` requires exactly one stack value; a statement
  cell leaves zero" difference is a **post-run assertion**, not a second
  primitive. A single `eval` returning `Value.void_` for an empty stack
  (and the produced value otherwise) subsumes both; the kind-aware
  `eval(Cell)` dispatcher discards the value for `noDisplay` cells.
- `eval` and `evalCell` were byte-for-byte identical in bytecode, and
  the interpreter's `eval`-vs-`evalCell` difference
  (`allowZeroArgumentCalls`, `allowControlFlow`) only kept the bare
  `eval(string)` path artificially weaker than the REPL/unittest paths.
  Real D and CTFE (the oracle) accept bare zero-argument calls and
  control flow, so the restriction encoded incompleteness, not a
  contract. The two interpreter tests pinning it
  (`zeroArgumentCallReportsArgumentCount`,
  `ifStatementReportsUnsupportedEvalStatement`) were removed with
  approval; the matrix already covers those capabilities via
  `runUnitTest`.
- Failure is reported as **data** on every path, including the REPL.
  The REPL's accept-on-success rollback becomes an explicit branch
  (`session.accept` only when the diagnostic is empty), replacing the
  earlier reliance on exception unwinding — which was the
  no-exceptions-for-control-flow anti-pattern. Throwing survives only
  at terminal boundaries (`eval(string)` for a single ad-hoc
  expression; `incomplete` reaching the backend, a programming error)
  and for genuinely exceptional conditions inside backends.

The Evaluator/Runner two-interface split below is **deferred**, not
abandoned: it is only worth doing once the VMs adopt a private
execution-slot type so the test-running path can avoid materialising
`Value`. Until then one primitive returning `EvalResult` is simpler and
costs nothing (the interpreter and bytecode VMs already use `Value` as
their runtime representation).

Research findings that motivated the failure-as-data decision (June 2026
review of all four backends):

- No part of the test-running contract needs `Value`. Failure
  diagnostics do render runtime operands ("1 != 2" — pinned by the
  test matrix and matching compiled-D `-checkaction=context` output),
  but rendering needs only a string produced at the point of failure
  from whatever internal representation the backend has. The IR VM
  proves it (renders from raw `ulong` registers), as does CTFE
  (verbatim dmd diagnostic strings).
- `quickbite.lang.Value` is repl-shaped: its variant set includes
  display-only kinds (`TypeName`, `EnumValue`, `Undisplayable`, the
  string-display flag on arrays) and the full `toString` apparatus.
  The interpreter and bytecode backends nevertheless use it as their
  runtime representation (locals, operand stack, instruction
  literals); the IR VM already uses a private representation and
  converts only at the `eval` boundary. That confirms the Boundary
  Rules below rather than changing them.

## Motivation

The deferred Evaluator/Runner split is motivated by two jobs that have
different *runtime* needs (the single `eval` primitive serves both today
because the VMs still use `Value` as their runtime representation):

- expression-like input that returns `Value` for inspection and display;
- D code executed for effect (statements, unittests) that only needs
  completion, failure, and diagnostics — no `Value`.

Those jobs have different runtime needs. The REPL needs a lossless
enough value representation for display. The VM hot path should be
free to use a private slot representation optimized for execution
latency.

## Target Shape

**Deferred target** (see Status — the current shape is a single
`EvalResult eval(FuncDeclaration)` on `Backend`, with failure carried
by the nested `EvalResult.Diagnostic`). Use capability
interfaces with concrete current execution units. Do not invent an
abstract entry-point type before a test forces it. The split below is
only worth doing alongside the private execution-slot type (Migration
Plan step 6), which lets `Runner` avoid `Value` entirely.

```d
public interface Evaluator {
    import quickbite.lang: Value;

    public Value eval(in string expr);
    public ReplSession createReplSession();  // see ai/plans/repl.md
}

public interface Runner {
    import dmd.declaration: FuncDeclaration;

    // Empty result means success; non-empty is the failure
    // diagnostic, rendered at the point of failure.
    public string run(FuncDeclaration function_);
}
```

Unittest execution remains a frontend/API layer over `Runner`:

```d
foreachUnitTestDeclaration(module_, (unitTest) {
    const message = runner.run(unitTest);
    ...
});
```

`compileUnitTest` and `compileFunction` are already identical in the
bytecode and IR backends (`UnitTestDeclaration` is a
`FuncDeclaration`), so a single execution method covers unittests with
no test-shaped knowledge in the backend. The cell-vs-unittest
restrictions that once differed per entry point (the interpreter's
`allowZeroArgumentCalls`/`allowControlFlow` flags) have been removed —
all execution now allows the same D surface — so the collapse into one
`eval` is already done; a future `Runner.run` would just be the
`Value`-free view of it.

Test-result aggregation stays a thin `final` adapter (today's
`runTests`), not a core backend capability. Implementations must be
able to run all supported D code, not just tests.

## Boundary Rules

- `quickbite.lang.Value` is the public value returned by `Evaluator`.
- `Runner` must not require `Value` for ordinary execution.
- VM stacks, locals, constants, and call frames should eventually use
  a VM-private representation (the IR VM already does; the
  interpreter and bytecode VMs do not yet).
- Conversion from VM-private values to `quickbite.lang.Value` happens
  only at `Evaluator` result boundaries. Diagnostics that need
  rendered runtime operands render to `string` at the point of
  failure; they do not need `Value` either.
- DMD frontend objects stay behind frontend/compiler
  boundaries. Bytecode and VM artifacts should consume Quickbite-owned
  ids and metadata.

## Migration Plan

1. ~~Hoist REPL-cell dispatch out of the backends~~ (done — `final
   Backend.eval(Cell)` owns the dispatch).
2. ~~Make test failure data, not exceptions~~ (done for the test path —
   `runUnitTest` returned `string`, `runTests` is the adapter).
3. ~~**Collapse the execution surface to one primitive**~~ (done —
   slices 1–3 in `PLAN.md`): replaced `eval`/`evalCell`/`runCell`/
   `runUnitTest` with `EvalResult eval(FuncDeclaration)`;
   `eval(string)`/`eval(Cell)`/`runTests` are `final` adapters; failure
   is data on every path, including the REPL (explicit
   accept-on-success rollback). Removed the interpreter's
   `allowZeroArgumentCalls`/`allowControlFlow` flags and the two tests
   that pinned the artificial `eval(string)` weakness.
4. **(Deferred) Introduce `Evaluator` and `Runner`** next to `Backend`.
   `eval` is Evaluator-shaped; the test/effect path is Runner-shaped.
   Motivated only by Value-confinement (below), so it waits for step 6.
   The REPL session capability (`createReplSession`) grows out of
   `Evaluator` per `ai/plans/repl.md`.
5. **(Deferred)** Move REPL call sites to `Evaluator` and
   module/unittest execution to `Runner` once those interfaces exist.
6. **(Deferred) Private execution-slot type.** Replace direct VM use of
   `quickbite.lang.Value` with a private slot type. This is what makes
   the Evaluator/Runner split pay off: the `Runner` path can then avoid
   materialising `Value` at all. The private type may initially wrap or
   alias `Value`. Until this lands, the single `EvalResult` primitive is
   the right shape.

## Non-Goals

- Do not redesign `quickbite.lang.Value` as part of this interface
  split.
- Do not change REPL display behavior unless an approved behavior test
  requires it.
- Do not add new test behavior without explicit approval.
