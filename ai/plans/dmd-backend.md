# Plan: dmd-backend

## Goal

Add `ExecutorBackend.dmdBackend` as a first-class backend that drives
DMD's native code generation pipeline in-process, emits machine code
into RAM, and executes unittest blocks from there. Replace the
subprocess `dmd -run` benchmark row with this backend.

## Benchmark changes

The benchmark becomes one section only (post-parse). All four backends
are measured via `runParsedTests(module_)`. Remove `runDmd()`, the
`--no-dmd` flag, and the "full edit-to-result" section.

## Execution model (phase 1)

All code generation runs under the same compiler lock as frontend
operations. DMD's backend has C-level global state equivalent to the
frontend's `__gshared` state. Whether the lock is strictly required for
code generation is an open question; assume it is, verify during
implementation, and document the finding in a comment in
`dmd_backend.d`.

1. Drive DMD's glue layer: `obj_start` → `genObjFile` → `obj_end`.
   ELF bytes accumulate in an `OutBuffer` (already in RAM).
2. `memfd_create("quickbite-dmd-backend", MFD_CLOEXEC)` — anonymous
   in-kernel fd, no disk.
3. Write the ELF bytes to the memfd.
4. Run `ld -shared /proc/self/fd/N -o /proc/self/fd/M` to produce a
   `.so` in a second memfd. The linker resolves druntime symbols
   against the running process.
5. `rt_loadLibrary("/proc/self/fd/M")` — use the D runtime's own
   dynamic loading wrapper rather than raw `dlopen`. This triggers the
   D runtime's standard module registration and unittest discovery
   machinery, keeping the backend stable against future druntime
   changes. If `rt_loadLibrary` proves to have unacceptable overhead,
   fall back to raw `dlopen` + locating the mangled `ModuleInfo` symbol
   directly.
6. Call the registered unittest function via the standard druntime
   unittest runner for the loaded module.

The backend generates position-independent code (`driverParams.pic =
PIC.pic`) so the `.so` can be loaded at an arbitrary address.

Phase 2 (separate task): replace the linker subprocess with a custom
x86-64 ELF section loader (`mmap` + relocation patching via `dlsym`).

## Vendoring

`dmd:frontend` is compiled with `version(NoBackend)`, excluding
`compiler/src/dmd/backend/*` and `dmsc.d`. `libdmd_frontend.a` already
contains the glue layer with undefined backend symbol references — we
only need to compile the backend source and link it in.

Files to vendor (tied to the `dmd:frontend` version in `dub.sdl`):

- `compiler/src/dmd/backend/` → `vendor/dmd-backend/dmd/backend/`
- `compiler/src/dmd/dmsc.d`   → `vendor/dmd-backend/dmd/dmsc.d`

Add `scripts/vendor-dmd-backend.sh`: reads the `dmd` version from
`dub.selections.json`, copies the paths above from the matching dub
cache entry. Re-run this script whenever `dmd:frontend` is bumped.
Document this requirement in a comment in `dub.sdl` next to the
dependency line.

## Dub configuration

Add a local sub-package to `dub.sdl`:

```sdl
subPackage {
    name "dmd-backend-vendor"
    targetType "library"
    sourcePaths "vendor/dmd-backend"
    importPaths "vendor/dmd-backend"
    dependency "dmd:frontend" version="~>2.112.1"
}
```

All three configurations (`unittest`, `unittest-cov`, `benchmark`) gain:

```sdl
dependency ":dmd-backend-vendor" version="*"
```

## Backend initialisation

`dmsc.backend_init(params, driverParams, target)` initialises DMD's
code generation globals. Do **not** put this in `compiler.d` — that
module manages only the DMD frontend. Instead, initialise lazily in
`DmdBackend.runParsedTests`: on the first call, acquire the compiler
lock via `withCompilerLock`, check a `__gshared bool _backendInit`
flag, and call `backend_init` if not yet done. The frontend is
guaranteed to already be initialised by this point, since a parsed
module must exist before `runParsedTests` can be called.

Key settings:

- `driverParams.pic = PIC.pic` — position-independent code.
- `params.useUnitTests = true` — preserve unittest declarations.

## Files to create/modify

| File | Change |
|------|--------|
| `dub.sdl` | Add `:dmd-backend-vendor` sub-package; add dep to all configs; add vendor comment |
| `scripts/vendor-dmd-backend.sh` | New: copies backend from dub cache |
| `vendor/dmd-backend/` | New vendored tree |
| `source/quickbite/frontend/compiler.d` | Call `backend_init` in constructor |
| `source/quickbite/backends/dmd_backend.d` | New: `DmdBackend : Executor` |
| `source/quickbite/package.d` | Add `ExecutorBackend.dmdBackend`; switch cases |
| `benchmarks/main.d` | Remove `runDmd()`/`--no-dmd`/full-edit section; add `"dmd-backend"` |

## Verification

Run `benchmarks/run.sh` and confirm:

1. Only one benchmark section is printed.
2. A `dmd-backend` row appears alongside `ir`, `treeWalking`, `dmd-ctfe`.
3. Numbers are plausible (dominated by linker time, ~5–50 ms).
4. No `dmd -run` subprocess is spawned.
5. `dub test` passes.
