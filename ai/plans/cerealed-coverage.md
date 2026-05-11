# Plan: Run Cerealed Tests Through the VM

## Status: DONE

All 19 cerealed test files run through the IR, tree-walking, and dmdCtfe
backends.  Three dmdCtfe tests are `@ShouldFail` due to unit_threaded stub
limitations.  36/57 backend×file combinations pass outright; the 3 that
remain `@ShouldFail` are documented below.

## Goal

Run each of the 19 cerealed test files through quickbite's IR and
tree-walking backends.  The `tests/ut/cerealed.d` harness passes each
file's raw source text plus explicit import paths to `runTests`; the
VM resolves `import cerealed;` and `import unit_threaded;` from those
paths and executes the unittest blocks.

No source patching, module-declaration stripping, or vendor modification
is ever acceptable.  If a test file fails, mark it `@ShouldFail` and
fix the backend.

## Approach (as implemented)

cerealed is a proper dub dependency (not vendored).  Its source path is
resolved at test runtime from `dub describe --data=import-paths --data-list`.
The `concepts` transitive dependency is resolved from the same DUB import
path list.
`unit_threaded` is still satisfied by the stub in `vendor/ut_stubs/` to
avoid the VM having to execute the real unit-threaded library.

Helper module `tests/ut/dub_paths.d` provides `cerealImportPaths()`,
`cerealSrcDir()`, and `cerealTestsDir()` for use by both the cerealed
harness and `tests/ut/compiler_api.d`.

`vendor/cerealed/` has been removed entirely from the repository.

## What the branches showed

The `ir-cerealed` and `tw-cerealed` branches (reference only) established:

- All 19 cerealed tests pass on the IR backend once the import-path
  API is in place and the `ParsedModule` source cache prevents
  double-parsing.
- Passing `["vendor/cerealed/src", "vendor/ut_stubs"]` as import paths
  is sufficient for all IR tests.
- `vendor/ut_stubs/unit_threaded.d` must be renamed to
  `vendor/ut_stubs/unit_threaded/package.d` for DMD module resolution
  to work correctly alongside the installed unit-threaded dub package.
- The `addImportPath` public function in `compiler.d` should be removed;
  import paths belong to individual `parseModule` calls, not to global
  DMD state.

## Changes made on master

### 1. `source/quickbite/frontend/compiler.d`

- Added `parseModule(in string source, in string[] importPaths)` overload.
  It calls `addImport` for each path, then parses and runs full
  semantic analysis.
- Added a `ParsedModule[string]` source-content cache inside `Compiler`
  (keyed by source string).  On a cache hit return immediately without
  re-registering the module in DMD's global table.  Cache on parse,
  before semantic, so a semantic failure does not leave the module
  unregistered on a second call.
- Removed the `public void addImportPath(in string path)` free function.
  Import paths must not leak into global DMD state across test calls.
- Delegated the single-arg `parseModule(source)` to
  `parseModule(source, [])`.

### 2. `source/quickbite/package.d`

- Added `runTests(in string source, in string[] importPaths,
  in ExecutorBackend backend)` overload that dispatches to the matching
  backend's `runTests(source, importPaths)` method.
- Kept the existing `runTests(source, backend)` single-arg overload.

### 3. Backend `runTests` signatures

Each backend (`ir.d`, `tree_walking.d`, `dmd_ctfe.d`) now has a
`runTests(in string source, in string[] importPaths)` method that
calls `parseModule(source, importPaths)` then executes.

### 4. `vendor/ut_stubs/unit_threaded/package.d`

Renamed `vendor/ut_stubs/unit_threaded.d` →
`vendor/ut_stubs/unit_threaded/package.d`.  Content unchanged.

### 5. `dub.sdl`

Added `dependency "cerealed" version="~>0.6.11"` to the `unittest`
and `unittest-cov` configurations.  This makes dub resolve cerealed
as a proper dependency; its source path is then used as an explicit
import path when calling `parseModule`.

### 6. `vendor/cerealed/` removed

Both `vendor/cerealed/src/` and `vendor/cerealed/tests/` were removed
from the repository.  Test files are now read from the dub package cache
at runtime.

### 7. `tests/ut/dub_paths.d` (new)

Provides `cerealImportPaths()` (cerealed src + concepts src +
vendor/ut_stubs), `cerealSrcDir()`, and `cerealTestsDir()`.
Reads import paths once per test process from `dub describe
--config=unittest --data=import-paths --data-list` and derives the
cerealed package root from the reported `cerealed/src` path.

### 8. `tests/ut/compiler_api.d` (new)

TDD entry point: a focused test that calls
`parseModule(source, importPaths)` with a real cerealed test file.

### 9. `tests/ut/cerealed.d`

Complete rewrite.  57 tests (19 files × 3 backends).
- All 19 IR tests pass.
- All 19 tree-walking tests pass.
- 16/19 dmdCtfe tests pass; 3 are `@ShouldFail` (see below).

## Known failures (keep @ShouldFail)

All three are dmdCtfe only; the unit_threaded stub lacks the APIs that
dmdCtfe's CTFE-based execution exposes.

| File | Backend | Reason |
|------|---------|--------|
| `bugs.d` | dmdCtfe | Uses `.should` fluent property, not in stub |
| `cerealiser_impl.d` | dmdCtfe | `shouldNotThrow` can't handle template type |
| `encode.d` | dmdCtfe | `shouldNotThrow`/`shouldThrow` on void |

The stub can be extended to fix these when needed; these are not VM
correctness issues.

## Critical files

| File | Role |
|------|------|
| `source/quickbite/frontend/compiler.d` | Overload + source cache |
| `source/quickbite/package.d` | importPaths overload |
| `source/quickbite/backends/ir.d` | importPaths runTests |
| `source/quickbite/backends/tree_walking.d` | importPaths runTests |
| `source/quickbite/backends/dmd_ctfe.d` | importPaths runTests |
| `tests/ut/cerealed.d` | Harness (57 tests) |
| `tests/ut/dub_paths.d` | Dub path helpers |
| `tests/ut/compiler_api.d` | TDD parseModule test |
| `vendor/ut_stubs/unit_threaded/package.d` | Renamed stub |
