# DMD Codegen Backends: `quickbite.backends.codegen`

## Context

The project needs two DMD codegen backends implementing the modern `Backend`
interface (`eval`, `evalRepl`, `runTests`, `runTestSummary`).
One compiles to a shared library and loads it via `dlopen`/`dlsym`; the
other emits object code into `mmap`'d RAM and relocates it in-process. Both
live in a new `quickbite.backends.codegen` package. The architecture rule
forbids backends from importing each other.

These backends are wanted, but they are not the near-term latency roadmap.
Build them after the tree-walking, IR, and bytecode backends have enough
coverage to make native-codegen comparisons useful, unless an earlier
benchmark or correctness question specifically needs DMD codegen data.

The shared-library backend deliberately pays filesystem, linker, and dynamic
loader costs. It exists as a correctness and performance baseline, not as the
hot-path latency design. The RAM backend should be treated as a native-codegen
experiment: DMD's backend emits section bytes plus symbolic references and
fixups, so in-RAM execution still needs linker-like relocation work. Prefer a
measured path such as DMD object emission plus LLVM JITLink, or a DMD
`Obj`-to-RAM backend that records and patches fixups directly, before
considering a custom object-file linker.

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
public class SharedLib : imported!"quickbite.backends".Backend { ... }
public class Ram       : imported!"quickbite.backends".Backend { ... }
```

All four interface methods implemented from the start, driven by tests.

## TDD Slice Order

Do not start these slices until the current backend roadmap has enough
tree-walking, IR, and bytecode coverage to compare against, unless the slice is
explicitly pulled forward for benchmarking.

When a codegen backend is ready to join the shared backend language matrix,
follow the same module order as the active latency backends, documented in
`ai/plans/backend-test-modules-order.md`. Within each module, start with the
smallest named unittest before taking broader call-based, control-flow,
aggregate, diagnostic, or integration cases.

1. `SharedLib.eval`
2. `SharedLib.runTests` / `runTestSummary`
3. `SharedLib.evalRepl`
4. Decide the RAM strategy from measurements and available DMD backend hooks:
   JITLink/object emission, a custom `Obj`-to-RAM backend, or a narrower
   custom relocator.
5. `Ram.eval`
6. `Ram.runTests` / `runTestSummary`
7. `Ram.evalRepl`

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
