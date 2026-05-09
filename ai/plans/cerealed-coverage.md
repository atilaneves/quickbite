# Plan: Run Cerealed Tests Through DMD Import Resolution

## Summary

The cerealed coverage work must compile the real vendored library and
test files with the DMD frontend.  DMD should receive a real root file
and explicit import paths, chase imports normally, run semantic analysis,
and hand the resulting AST to quickbite's backends.

There must be no vendor patching, source stripping, synthetic source
assembly, druntime patching, fake runtime hooks, or other workarounds.
If DMD produces an AST that a backend cannot handle, the backend grows
support for that AST.

Continue work on the existing `ir-cerealed` and `tw-cerealed` branches,
undoing workaround commits as needed.

All changes live exclusively in the worktrees.  Nothing is committed to
`master`.

---

## What Was Wrong

The previous plan treated frontend failures as things to avoid by
changing the input.  That is the wrong direction for this project.

- Patching files under `vendor/` invalidates cerealed as a real-world
  target.
- Concatenating files into one string prevents DMD from exercising normal
  module and import resolution.
- Stripping module declarations, imports, attributes, or selected source
  constructs changes the program under test.
- Patching `object.d`, adding custom druntime paths, or defining fake
  runtime hooks hides frontend/environment problems instead of fixing
  them.

The correct model is simple: configure DMD correctly, give it real files,
and make quickbite execute the AST DMD gives back.

---

## Public API

Extend the existing string-based API with an import-paths parameter:

```d
// compiler.d — extended entry point
ParsedModule parseModule(string source, in string[] importPaths);

// package.d — new runTests overload
void runTests(string source, in string[] importPaths, ExecutorBackend backend);
```

`parseModule(source, importPaths)` adds the given import paths then parses and
semantically analyses the source.  `runTests(source, importPaths, backend)` calls
`parseModule` then dispatches to the selected backend.

Keep `runTests(string source, ExecutorBackend backend)` (no import paths) for
small synthetic language fixtures that need no external imports.

For each cerealed test case the caller reads the test file and passes its content:

```d
runTests(readText(testFile), cerealImportPaths, backend);
```

Import paths include `vendor/cerealed/src` and the path that provides
`unit_threaded`.

### Module-collision handling via ParsedModule cache

Running the same source against three backends must not parse it three times,
and must not require stripping its `module` declaration.

`Compiler` holds a `ParsedModule[string]` cache keyed by source content.
`parseModule(source, importPaths)` checks the cache first; on a miss it calls
`dmdParseModule` + `fullSemantic`, stores the result, and returns it.
Subsequent calls with the same source return the cached module.
Each backend receives the identical, immutable AST.

---

## Frontend Requirements

- Upgrade `dmd:frontend` to an aligned DMD version, preferably
  `~>2.112.1`, which is already cached locally and matches the installed
  compiler family.
- Use the aligned DMD frontend/compiler environment for standard library
  and runtime import paths.
- Add project import paths explicitly instead of rewriting source.
- Let DMD own module declarations, import chasing, template
  instantiation, CTFE during semantic analysis, and AST shape.
- Do not patch or shadow druntime, Phobos, `object.d`, or cerealed.

Repeated runs of the same source must not be handled by stripping module
declarations.  The `ParsedModule` cache in `Compiler` ensures each unique
source is compiled exactly once; the same semantic module is reused across
backends.

---

## Backend-Specific Test Files

Each worktree may create a backend-specific test module
(`tests/ut/language_ir.d`, `tests/ut/language_tw.d`).  These files are
worktree-only by construction: just work in the worktree and they will
never appear on `master`.  After both PRs are merged, the
backend-specific tests are folded into `tests/ut/language.d` and the
separate files are deleted.

---

## Branch Cleanup

Continue on `worktrees/ir-cerealed` and `worktrees/tw-cerealed`.

Before any new backend feature work, each branch must:

1. Upgrade `dmd:frontend` to `~>2.112.1` in `dub.sdl` as the first
   commit.  Verify `dub test -- -s` passes clean before proceeding.
2. Delete from `compiler.d`: `patchedDruntimePath()`, `dmdDruntimeSrcPath()`,
   and the `addImport(patchedDruntimePath)` call in `Compiler.this`.
3. Rewrite `tests/ut/cerealed.d`: remove `makeCerealSource`, `processFile`,
   `processLibraryFile`, `patchCerealSource`, `patchTestSource`,
   `stripAaGrainOverloads`, `stripUnittestBlocks`, `stripPureFromUnittest`,
   `braceDelta`, `statementEnds`, `isAaGrainSignature`, and the inline
   `unitThreadedStub` string.  Replace with `cerealImportPaths` + calls to
   `runTests(readText(testFile), cerealImportPaths, backend)`.
4. Mark all cerealed tests `@ShouldFail` and remove only those whose test
   file now compiles and runs successfully on unmodified source.
5. `dub test -- -s` clean.

`git diff -- vendor/` must stay empty.

---

## unit_threaded Boundary

The current `vendor/ut_stubs/unit_threaded.d` is a test dependency
boundary, not a workaround for cerealed or DMD.  It may remain only as a
temporary replacement for the external test framework while quickbite is
focused on cerealed itself.

The stub must be imported as a normal module through DMD import
resolution.  It must not be injected into generated source.

Once cerealed coverage is stable, replace the stub by compiling the real
`unit_threaded` dependency the same way: root file plus import paths.

---

## Feature Roadmap

Use strict TDD for frontend, harness, and backend features.  For the
new `parseModule(source, importPaths)` path, first add a failing test that
compiles real source with its module declaration and an imported dependency,
confirm it fails, and stop for feedback on the test before changing production
code.  For backend work, add one failing language test, confirm it
fails, make the smallest backend change that passes, then triangulate
and refactor.

When a cerealed test passes against unmodified source, remove its
`@ShouldFail` in a separate commit.

Initial backend areas remain:

- struct declarations and field access,
- method calls and operator overloads such as `opOpAssign` and
  `opEquals`,
- exception support,
- strings and `char`,
- floating point and casts,
- associative arrays,
- classes, interfaces, and virtual dispatch,
- pointers,
- `scope(exit)` and `with`.

The exact next feature is determined by the first unsupported AST node
seen after the real file frontend path is in place.

---

## Verification

- Cerealed tests call `runTests(readText(testFile), cerealImportPaths, backend)`.
- `tests/ut/cerealed.d` contains no string-building or source-transformation helpers.
- Passing the same source for two different backends does not call
  `dmdParseModule` twice (the cache returns the first result).
- DMD import paths include `vendor/cerealed/src` and the `unit_threaded` path.
- `git diff -- vendor/` is empty in both worktrees.
- No `@ShouldFail` is removed until the unmodified test file compiles and
  executes on the relevant backend.
- `dub test -- -s` after each editing session.

---

## Critical Files

| File | Role |
|------|------|
| `vendor/cerealed/src/cerealed/*.d` | Upstream originals, read-only |
| `vendor/cerealed/tests/*.d` | Real cerealed test roots |
| `vendor/ut_stubs/unit_threaded.d` | Temporary imported test stub |
| `tests/ut/cerealed.d` | Cerealed test driver (`readText` + `runTests`) |
| `dub.sdl` | Aligned `dmd:frontend` dependency |
| `source/quickbite/frontend/compiler.d` | DMD-as-library wrapper |
| `source/quickbite/backends/ir.d` | IR executor |
| `source/quickbite/backends/tree_walking.d` | Tree-walking backend |
| `source/quickbite/backends/dmd_ctfe.d` | DMD CTFE backend |
| `source/quickbite/frontend/lowering.d` | IR lowering |
