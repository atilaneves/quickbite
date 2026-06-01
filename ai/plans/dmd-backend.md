# DMD Codegen Backends: `quickbite.backends.codegen`

## Context

The project needs two DMD codegen backends implementing the modern `Backend`
interface (`eval`, `evalRepl`, `runParsedTests`, `runParsedTestSummary`).
One compiles to a shared library and loads it via `dlopen`/`dlsym`; the
other emits object code into `mmap`'d RAM and relocates it in-process. Both
live in a new `quickbite.backends.codegen` package. The architecture rule
forbids backends from importing each other.

A `BackendName` enum and factory are out of scope — deferred until
benchmarks and REPL backend selection require them.

## New Package Structure

```
source/quickbite/backends/codegen/
    package.d       — re-exports SharedLib, Ram
    shared_lib.d    — SharedLib : Backend  (dlopen/dlsym strategy)
    ram.d           — Ram : Backend        (mmap/relocate strategy)
```

## Two Backend Classes

```d
public class SharedLib : imported!"quickbite.backend".Backend { ... }
public class Ram       : imported!"quickbite.backend".Backend { ... }
```

All four interface methods implemented from the start, driven by tests.

## TDD Slice Order

1. `SharedLib.eval`
2. `Ram.eval`
3. `SharedLib.evalRepl`
4. `Ram.evalRepl`
5. `SharedLib.runParsedTests` / `runParsedTestSummary`
6. `Ram.runParsedTests` / `runParsedTestSummary`

Each slice: one failing test → dumbest green code → ask before the next
test.

## Tests

New backends get their own test files under `tests/ut/backends/codegen/`.
They are NOT added to the `backends` alias in `tests/ut/backends/package.d`
until they pass all tests (same gate as IR, bytecode, and every other
backend).

## Key Reference Files

- `source/quickbite/backends/ctfe/dmd_ctfe.d` — pattern for all four
  Backend methods
- `source/quickbite/backend.d` — interface to implement
- `source/quickbite/backends/ctfe/package.d` — re-export pattern
- `tests/ut/backends/package.d` — test infrastructure and `backends` alias

## Verification

```sh
dub test -- --random
```

Both backends agree with the CTFE oracle on all currently supported
language features before being added to the `backends` alias.
