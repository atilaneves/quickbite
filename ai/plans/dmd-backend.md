# DMD Codegen Backend: `quickbite.backends.codegen`

## Context

The project needs DMD codegen backends implementing the modern `Backend`
interface (`eval`, `evalRepl`, `runTests`, `runTestSummary`). Two strategies
are worth implementing and benchmarking:

- **`InProcess`**: compile to `OutBuffer`, apply ELF relocations in-process
  (no external linker, no process spawn — the approach LLVM JITLink takes).
- **`SystemLinker`**: compile to `OutBuffer`, write object to a `memfd_create`
  file descriptor, invoke the system linker to produce a `.so` in another
  `memfd`, load with `dlopen("/proc/self/fd/N")`.

The empirical question — which is faster for the project's use case — can only
be answered by benchmarking both. The system linker gives full correctness for
free; the in-process loader eliminates linker process overhead entirely. One
may dominate in practice; both may be useful for different cases.

This lives in a new `quickbite.backends.codegen` package.

### In-process loading

The in-process loader does what LLVM JITLink does: map the object writable,
apply relocations against symbols resolved from the host process, then switch
the mapping to executable. No external process, no temp files, everything in
RAM.

D-specific concerns the loader must handle:

- **TypeInfo**: `typeid(T)` and dynamic casts require `TypeInfo_*` symbols
  from the host druntime; resolve via `dlopen(null)` + `dlsym`.
- **Module constructors**: each D module has a `__ModuleInfoZ` symbol; call
  module constructors before any code in that module runs.
- **druntime entry points**: GC allocation (`_d_allocmemory`, `_d_newclass`),
  array operations, exception throwing (`_d_throwdwarf`), and other runtime
  helpers resolve against the host process's druntime via `dlsym`.
- **`.eh_frame` registration**: D uses DWARF-based stack unwinding; register
  the exception frame with `__register_frame` so D exceptions propagate
  correctly across JIT'd call frames.
- **TLS**: D's `__thread` variables require per-module TLS block
  initialisation; handle via the TLS segment in the object.
- **GOT/PLT**: position-independent code references globals and external
  functions through the GOT and PLT; synthesise these tables in the mapped
  region and patch the references.

The old `source/quickbite/executors/dmd_codegen.d` contains a working
reference for all of this — the RAM loader there proves it is doable for DMD's
actual output. Study it for the relocation types DMD emits, the symbol
resolution strategy, the accumulation strategy, and the D-specific setup
sequence.

LLVM JITLink documentation and design is the production-quality reference:
GOT/PLT synthesis, TLS models, `.eh_frame` registration, the full x86-64
relocation set, and how to handle the JIT boundary correctly. Ideas only —
not code.

### System linker loading

`SystemLinker` compiles to `OutBuffer`, writes the object bytes into a
`memfd_create` file descriptor, invokes the system linker (e.g. `mold` for
speed) passing `/proc/self/fd/N` as input and another `memfd` path as output,
then `dlopen`s the resulting `.so`. All D-specific concerns (TypeInfo, module
constructors, druntime entry points, `.eh_frame`, TLS, GOT/PLT) are handled by
the system linker and dynamic loader at no extra implementation cost.

### W^X

For `InProcess`: map writable first (`PROT_READ | PROT_WRITE`), apply all
relocations and patches, then switch to executable (`mprotect` to
`PROT_READ | PROT_EXEC`). Never have a page writable and executable
simultaneously.

## New Package Structure

```
source/quickbite/backends/codegen/
    package.d         — re-exports InProcess and SystemLinker
    in_process.d      — InProcess : Backend  (in-process ELF loader)
    system_linker.d   — SystemLinker : Backend  (memfd_create + system linker)
```

## Backend Classes

```d
public class InProcess    : imported!"quickbite.backends".Backend { ... }
public class SystemLinker : imported!"quickbite.backends".Backend { ... }
```

All interface methods implemented from the start, driven by tests.

## Implementation Strategy

### InProcess

1. Use DMD-as-a-library to compile the D module to ELF object bytes in an
   `OutBuffer` (in-memory, no disk write).
2. `mmap` a writable region and copy the object sections into it.
3. Resolve external symbols against the host process via `dlopen(null)` +
   `dlsym`; synthesise GOT/PLT entries in the mapped region.
4. Apply x86-64 relocations (the set DMD actually emits).
5. Register `.eh_frame` with `__register_frame`.
6. Call module constructors (`__ModuleInfoZ`).
7. `mprotect` to `PROT_READ | PROT_EXEC`.
8. Call unittest entry points directly via function pointer.

### SystemLinker

1. Use DMD-as-a-library to compile the D module to ELF object bytes in an
   `OutBuffer` (in-memory, no disk write).
2. Write object bytes into a `memfd_create` file descriptor.
3. Invoke system linker (prefer `mold`) with `/proc/self/fd/N` as input,
   writing the `.so` output to another `memfd`.
4. `dlopen("/proc/self/fd/M")` the in-memory `.so`.
5. Call unittest entry points via `dlsym`.

### Per-unittest results

druntime's `__modtest` runs all unittests in a module sequentially and aborts
on first failure, giving only module-level pass/fail. Since we have the AST
before compilation, enumerate unittest declarations with
`foreachUnitTestDeclaration`, collect their mangled symbol names, then after
loading call each one individually via function pointer or `dlsym`. This gives
per-test outcomes, names, and failure messages without any druntime changes.

### Parallelism considerations

The backend runs tests serially (project-wide constraint), but compilation and
loading are independent of that constraint. Worth thinking about:

- Can multiple modules be compiled in parallel before any loading begins?
- Can the DMD compilation step and the loading/relocation step for one module
  overlap with compilation of the next?
- mold's design — maximising parallelism within relocation application and
  symbol resolution — may inform whether these steps are bottlenecks worth
  parallelising.

No `synchronized` per project style; any parallelism must use message-passing
or ownership transfer, not shared mutable state.

## TDD Slice Order

Do not start these slices until the current backend roadmap has enough
tree-walking, IR, and bytecode coverage to compare against, unless the slice
is explicitly pulled forward for benchmarking.

When the codegen backend is ready to join the shared backend language matrix,
follow the same module order as the active latency backends, documented in
`ai/plans/backend-test-modules-order.md`. Within each module, start with the
smallest named unittest before taking broader call-based, control-flow,
aggregate, diagnostic, or integration cases.

Before promoting a named test from any copied backend plan or review note,
verify in the current checkout that its enclosing backend matrix still excludes
the codegen backend under work. If it is already covered, treat the note as
stale and choose the next smallest current candidate.

Implement `SystemLinker` first — it is simpler and establishes the test
baseline. Then implement `InProcess`. Benchmark both before deciding which to
promote.

1. `SystemLinker.runTests` / `runTestSummary`
2. `SystemLinker.eval`
3. `SystemLinker.evalRepl`
4. `InProcess.runTests` / `runTestSummary`
5. `InProcess.eval`
6. `InProcess.evalRepl`
7. Benchmark both; promote the faster one to the `backends` alias.

Each slice: one failing test → dumbest green code → ask before the next test.

## Tests

The new backend gets its own test file under `tests/ut/backends/codegen/`.
Neither class is added to the `backends` alias in `tests/ut/backends/package.d`
until it passes all tests and the benchmark decision is made (same gate as IR,
bytecode, and every other backend).

## Key Reference Files

- `source/quickbite/backends/ctfe/dmd_ctfe.d` — pattern for all Backend
  methods
- `source/quickbite/backend.d` — interface to implement
- `source/quickbite/backends/ctfe/package.d` — re-export pattern
- `tests/ut/backends/package.d` — test infrastructure and `backends` alias
- `source/quickbite/executors/dmd_codegen.d` — working reference for both
  the DMD compilation steps and the in-process ELF loader: relocation types
  DMD emits, symbol resolution, accumulation strategy, D-specific setup
  sequence (study and reuse the approach; do not copy wholesale)
- LLVM JITLink documentation and design — production reference for in-process
  object loading: GOT/PLT synthesis, TLS models, `.eh_frame` registration,
  x86-64 relocation set (ideas only, not code)
- lld and mold design documentation — reference for relocation parallelism
  and identifying the minimum work required (ideas only, not code)

## Verification

```sh
dub test -- --random
```

The promoted backend agrees with the CTFE oracle on all currently supported
language features before being added to the `backends` alias.
