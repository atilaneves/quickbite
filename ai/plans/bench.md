# Benchmark Driver: Stop Special-Casing SystemLinker

## Summary

The benchmark binary (`benchmarks/cli.d`) has absorbed SystemLinker's
compilation model into the CLI layer. There is no `cast(SystemLinker)` or
`if (name == "system-linker")` branch, but everything touching
`dubLinkFiles`, `dubArchiveImportPaths`, and
`includeDefaultImportsForTemplateCodegen` exists solely to feed SystemLinker;
`Ctfe` (`new Ctfe`, `cli.d:76`) ignores all of it. The driver therefore
carries a second compilation pipeline that only one backend reads.

Goal: the benchmark binary depends only on the `Runner` interface and hands
every backend the same generic inputs. Each backend uses what it needs.
Backend-specific policy moves into the backend so it "just works".

Non-goal: making SystemLinker resolve its own dependencies. The dub
pre-resolution in `resolveDubPkg` (running `dub build` / `dub describe` once)
is correct and stays in the driver — it deliberately mirrors `dub test` (deps
from prebuilt archives, only the project codegen'd per run) for benchmark
fidelity. The backend has no business shelling out to dub. We move *policy*
into the backend (items 1–2) and make the *driver* uniform (items 3–4).

## Current Status

As of 2026-06-17, item 3 is complete. The benchmark driver constructs
backends through `benchmarks.backends`, and the registry includes `ctfe`,
`interpreter`, `system-linker`, and `llvmjit`. Default benchmark runs now use
that same four-backend set:

```
ctfe, interpreter, system-linker, llvmjit
```

`--backend=interpreter` is selectable in the same path as the other backends.
Future benchmark-backend additions should extend the registry and, if they
belong in ordinary runs, `defaultBackendNames`.

## Current shape (for reference)

- `cli.d:7` — concrete import `SystemLinker, SystemLinkerInputs`.
- `cli.d:52-53` — `dubLinkFiles`, `dubArchiveImportPaths` locals (SystemLinker
  only).
- `cli.d:79-86` — bespoke `SystemLinker` construction; `Ctfe` is `new Ctfe`.
- `cli.d:84` — `includeDefaultImportsForTemplateCodegen = dubPkg.length > 0`.
- `cli.d:130-154` — per-module run loop over `fixtureRuns`.
- `cli.d:156-193` — separate grouped run loop over `dubRuns`.
- `cli.d:389-400` — `resolveDubPkg` derives `archiveImportPaths` by filtering
  import paths not under the package root.
- `runner.d:17` — free `runTests(Runner, Module[])` already dispatches a batch
  to `GroupedRunner` and loops for everyone else.

## Work items (priority order)

### 1. Delete the template-codegen flag; derive it inside SystemLinker

`cli.d:84` makes correctness depend on the caller flipping a flag based on
"did the user pass `--dub`". A backend that just works derives this from the
modules it is handed, not from how it was invoked.

- In SystemLinker, determine the need for druntime/phobos template-instance
  codegen from the modules / their instantiations, always doing the right
  thing regardless of caller.
- Remove `includeDefaultImportsForTemplateCodegen` from `SystemLinkerInputs`
  (`source/quickbite/backends/native/system_linker.d:67-75`).

Verify: existing `--dub` benchmark of a real package still passes the
correctness check (`checkRunnerResults`) and produces the same test count as
before; a non-dub single-file benchmark still works.

### 2. Move the codegen-vs-archive split into SystemLinker

`resolveDubPkg` (`cli.d:389-400`) decides which import paths are
archive-backed by filtering paths not under the package root. That is linker
policy ("what is already compiled vs. what I codegen per run") living in the
benchmark.

- Hand SystemLinker the raw `dub describe` output (link files + package root)
  and let it derive `archiveImportPaths` internally.
- Drop the `archiveImportPaths` filtering from `resolveDubPkg`; the driver
  forwards what dub reported rather than interpreting it.

Verify: per-run codegen still covers only the project under test (not
dependencies) — confirm by timing parity with the pre-refactor numbers and by
the correctness check passing.

### 3. Construct backends through a name→Runner factory — complete

`cli.d:7` imports the concrete type; `cli.d:79-86` hand-assemble its
constructor while `Ctfe` is `new Ctfe`.

- Add a small registry/factory (e.g. `benchmarks.backends` or in the backends
  package) keyed by backend name, taking one generic env struct: import paths,
  link files, package root. Each backend's factory ignores fields it does not
  need.
- The CLI body then depends only on `Runner`; remove the `SystemLinker` /
  `SystemLinkerInputs` import and the two SystemLinker-only locals.

Side benefit: adding `bytecode` / `ir` to the matrix becomes a one-line
registry entry instead of a driver edit. `interpreter` has already been added
and is part of the default benchmark set.

Verify: `--backend=ctfe` and `--backend=system-linker` select correctly;
`--backend=interpreter` selects correctly; the `unknown backend` error path
still fires.

### 4. Collapse the two run loops into one over "benchmark units"

`fixtureRuns` runs per-module (`cli.d:130-154`); `dubRuns` runs grouped
(`156-193`). The grouping is legitimate modeling — a dub package's modules
form one program — but it is not a SystemLinker API requirement:
`runTests(Runner, Module[])` (`runner.d:17`) already handles both shapes.

- Model a benchmark unit as `Module[]`: length 1 for a standalone fixture, N
  for a dub package.
- Always execute via the grouped free function `runTests(runner, unit)`.
- Remove the `dubRuns` branch; one loop covers all units.

Verify: standalone fixtures still timed individually (one row each); a dub
package still timed as a single grouped row; output layout unchanged.

## Net effect

`cli.d` loses its `SystemLinker` import, the two SystemLinker-only locals, the
flag heuristic, the archive-path filtering, and one of its two run loops.
Adding a third backend becomes a one-line registry entry.

## Sequencing & testing

Items are independent but ordered by value. Each is a self-contained change
with its own verification above. After each: rebuild the optimised benchmark
config and run a known fixture plus one `--dub` package, confirming the
correctness check passes and timings are in line with pre-refactor numbers
(this is a refactor — no behaviour change intended). Per AGENTS.md, run
`ninja bin/ut` then `bin/ut --random` after editing.
