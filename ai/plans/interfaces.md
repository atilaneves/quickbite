# Backend Interfaces

## Summary

Replace the single `Backend` interface with two capability interfaces:

- `Evaluator` — interactive evaluation returning `EvalResult`; used by
  the REPL and ad-hoc expression callers.
- `Runner` — test execution for a whole `Module`, returning
  `TestResult[]`; the contract is wide enough for backends that compile
  an entire module at once (dmd codegen) and those that run tests
  one-by-one.

`Backend` is gone. Call sites hold `Evaluator`, `Runner`, or both,
depending on what they need.

## Status (June 2026)

The single `EvalResult eval(FuncDeclaration)` primitive on `Backend`
is already in place (slices 1–3 in `PLAN.md`), with `eval(string)` and
`eval(Cell)` as `final` adapters, and failure carried as data
(`EvalResult.Diagnostic`).

The current `runTests` adapter on `Backend` is the direct predecessor
of `Runner.runTests`; the module-level signature is the only change
needed there.

The next step is to introduce `Evaluator` and `Runner`, delete
`Backend`, and wire the three existing backends to both. The dmd
codegen backend (not yet started) will implement `Runner` only.

## Target Shape

```d
public interface Evaluator {
    import dmd.declaration: FuncDeclaration;
    import quickbite.eval: EvalResult;

    public EvalResult eval(in FuncDeclaration function_);

    // Final adapters — not overridden by backends.
    public final EvalResult eval(in string expr) { ... }
    public final EvalResult eval(in Cell cell) { ... }
}

public interface Runner {
    import dmd.dmodule: Module;
    import quickbite.eval: TestResult;

    public TestResult[] runTests(in Module module_);
}
```

`ASTRunner` is an abstract class that implements `Runner` for backends
whose execution unit is a single `FuncDeclaration`. It iterates the
unit-test declarations in the module and delegates to a backend-supplied
`runUnitTest`:

```d
public abstract class ASTRunner : Runner {
    import dmd.dmodule: Module;
    import dmd.declaration: UnitTestDeclaration;
    import quickbite.eval: TestResult;

    public final override TestResult[] runTests(in Module module_) {
        // iterate UnitTestDeclarations in module_, call runUnitTest each
    }

    protected abstract TestResult runUnitTest(
        in UnitTestDeclaration test);
}
```

The three existing backends extend `ASTRunner` and implement
`Evaluator`. Their `runUnitTest` override delegates to `eval`, since
they already hold the execution machinery there:

```d
class InterpreterBackend : ASTRunner, Evaluator { ... }
class BytecodeBackend    : ASTRunner, Evaluator { ... }
class IrVmBackend        : ASTRunner, Evaluator { ... }
```

The dmd codegen backend compiles the whole module to an object file and
runs the resulting test binary; it cannot run individual unit tests in
isolation. It therefore implements `Runner` directly without going
through `ASTRunner` or `Evaluator`:

```d
class DmdCodegenBackend : Runner { ... }
```

## Boundary Rules

- `quickbite.lang.Value` is the public value returned by `Evaluator`
  (inside `EvalResult`). `Runner` and `ASTRunner` must not require
  `Value` for ordinary execution.
- Diagnostics that render runtime operands produce a `string` at the
  point of failure; they do not need `Value`.
- DMD frontend objects stay behind compiler boundaries. `ASTRunner`
  takes `UnitTestDeclaration` (a DMD type) because the AST-walking loop
  is its job; backends should not leak DMD types further into the VM
  hot paths.
- Backends must not import each other.

## Migration Plan

1. ~~Hoist REPL-cell dispatch out of the backends~~ (done).
2. ~~Make test failure data, not exceptions~~ (done).
3. ~~Collapse execution surface to one primitive~~ (done —
   `EvalResult eval(FuncDeclaration)` on `Backend`).
4. **Introduce `Evaluator`, `Runner`, and `ASTRunner`.**  Add the two
   interfaces and the abstract class. Migrate the three existing
   backends to `extend ASTRunner, Evaluator`. Update `runTests` to
   accept `Module` instead of operating on individual declarations.
   Delete `Backend`. Update all call sites to hold the narrower type.
5. **dmd codegen backend.** Implement `Runner` directly; no `Evaluator`
   needed.
6. **(Deferred) Private execution-slot type.** Replace direct VM use of
   `quickbite.lang.Value` with a private slot type in the interpreter
   and bytecode VMs (the IR VM already has one). Only then does
   `Runner` fully avoid materialising `Value` on the test-execution
   path.

## Non-Goals

- Do not redesign `quickbite.lang.Value` as part of this split.
- Do not change REPL display behaviour unless an approved behaviour
  test requires it.
- Do not add new test behaviour without explicit approval.
