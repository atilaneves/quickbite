# Building `--dub` Targets via a Custom Reggae Build

**Superseded (2026-07-06 note).** The problem below was solved differently:
`--dub` preparation now captures dub's flags via `dub describe`
(dflags/versions/string-import-paths/source-files/linker-files; the old
compiler shim is deleted), and the template-emission failures were fixed by
the `DubMode` split (bench.md "Squash Template-Emission Link Failures").
None of the four sequencing steps below were implemented and none should be
picked up. Kept because its core argument — re-derive nothing; reggae
handles dub dialects canonically — remains the fallback direction if the
describe-based path ever proves incomplete for a corpus package.

## Goal

`bin/bench.sh --dub <pkg>` must benchmark the package's real unittest
configuration. Today it silently skips: `automem` reports
`discovered 11 / prepared 0 / skipped 11 — undefined identifier TestAllocator`,
and the post-parse table is empty.

The frontend we time is the DMD frontend running parse + semantic. It cannot
resolve `import test_allocator` without the dependency's import path, and it
compiles *different code* without the right compiler session state. So import
paths and compiler settings are not optional: they are intrinsic inputs to the
thing we measure. The bug is not that we need them - it is *how* we obtain
them.

## The principle: re-derive nothing

Every approach that has quickbite *compute* the build is a partial
reimplementation of a build system, and each fails on its own terms:

- **`dub describe` (today).** Incomplete. Quickbite needs the effective dub
  compiler session, not a hand-picked subset of describe fields. The current
  describe-fed path leaves the session boundary implicit and is the wrong shape
  for a long-lived runner.
- **dub-as-a-library inside quickbite.** Correct data, but it means owning the
  interop tax — cached `PackageManager`, TLS compiler registration, hand-kept
  linker-flag massaging, recipe-config bug workarounds — i.e. re-implementing,
  in quickbite, code reggae already maintains.
- **A compiler-arg shim.** Capturing the argv dub passes to the compiler only
  *relocates* dub's per-compiler flag knowledge into a reverse-parser in
  quickbite (`-version=` vs `-d-version=`, which spelling maps to `useDIP1000`).
  Worse, learning the flags by *compiling the root* parses the main project once
  for dub and again for the benchmark — a double parse of the exact code we
  measure.

The conclusion: quickbite should not derive settings at all. dub already holds
the effective compiler session for a build; reggae already wraps dub as a
library (it is quickbite's own build system, see `reggaefile.d`). We reuse that
single seam.

## The design: a reggaefile that builds *other* dub projects our way

We add a generic reggaefile whose job is not to build quickbite, but to build an
arbitrary external dub package in exactly the shape the runner needs. Given a
package directory plus the resolved test configuration/build type, it produces
the session snapshot and dependency image that the native backends need.

1. **Build all transitive dependencies** through reggae's existing dub
   integration, with reggae/ninja handling invalidation for the resolved build
   graph.
2. **Produce a dependency image** the native backends can load (`.so` for
   SystemLinker/LLVMJit), built from the non-root dependency outputs in the
   resolved dub graph.
3. **Emit the effective compiler session snapshot** for the root unittest build
   rather than a curated flag list. This snapshot carries every compiler input
   Quickbite needs to parse, semantically analyze, and codegen the package the
   same way dub would.
4. **Never compile the root in the dependency build.** The root is what
   Quickbite parses and runs; the build target should produce the inputs and
   dependency image, not a second copy of the root itself.

This is one seam (reggae's dub interop), no dub-extraction code in quickbite, no
double parse, incremental dependency builds, and compiler-dialect differences
handled upstream.

## Prerequisite reggae feature: decouple the reggaefile location

reggae binds both the project directory and the reggaefile location to a single
`projectPath` (`payload/reggae/options.d:380`; the reggaefile path is hard-coded
to `<projectPath>/reggaefile.d` at `options.d:128-141`). Its dub-as-library side
already uses `projectPath` as the package root (`dub/interop/dublib.d:63`,
`fullDub`), so pointing it at `~/.dub/packages/automem/.../automem` resolves that
package correctly. The missing pieces are the ability to supply *our*
reggaefile while building *their* package and to build from a Quickbite-owned
working directory.

Add a small, contained option in `payload/reggae/options.d`:

- a field `string reggaefileDir;` (empty ⇒ defaults to `projectPath`);
- a getopt flag `--reggaefile-dir`;
- route the per-language accessors (`dlangFile` et al., `options.d:143-160`)
  through a helper `reggaefileBase()` returning `reggaefileDir` when set, else
  `projectPath`;
- build into a Quickbite-owned working directory, not the user package dir.

Everything downstream funnels through `options.reggaeFilePath()`, so no other
reggae file changes. After it:

```sh
reggae --reggaefile-dir=<quickbite>/benchmarks/dubdeps <pkgdir>
```

This lands in the reggae repo (`~/coding/d/reggae`) first; quickbite then depends
on a reggae new enough to have it.

## Components and changes (quickbite)

1. **Generic reggaefile** — `benchmarks/dubdeps/reggaefile.d`. Imports reggae,
   reads the target package from `options.projectPath`, and from reggae's
   `DubInfo`:
   - for each **dependency** package: emit the outputs needed to build the
     dependency image and keep the package out of fresh root codegen;
   - for the **root** package: emit the effective compiler session snapshot for
     Quickbite to consume;
   - emit the `lib<pkg>_dub_deps.so` target from the dependency outputs.
   The root gets no compile target in the dependency build.

2. **Session artifact** — the `--dub` path becomes a reggae-built target that
   produces the session snapshot and dependency image, then runs the existing
   Quickbite benchmark/runner path against them. `bin/bench.sh --dub <pkg>`
   drives that reggae build. The generic `bin/bench` for ad-hoc file fixtures
   (`tests/example.d`, explicit module paths) is unchanged.

3. **Frontend application** — `source/quickbite/frontend/compiler.d`. At the two
   injection sites, `parseSourceLocked` (`compiler.d:504`) and
   `parseRootModulesLocked` (`compiler.d:318`), apply the effective compiler
   session beside the existing import-path push. The session includes every
   compiler input that can affect parse, semantic, lowering, diagnostics, or
   codegen. Widen the frontend APIs to take that session object rather than a
   few individual lists.

4. **Deletions** — `dubDescribe`, `dubInfoFromDescribeData`, `dubImportPaths`,
   the runtime `dub build --config=unittest`, and the describe-fed inputs to
   `buildDubDependencyImage` (its whole-archive logic moves into the reggaefile
   rule). `DubInfo`/`BackendEnv` widen to carry the new flag fields.

## Edge cases

- **Root vs dependency split.** reggae's `DubInfo.packages` separates the root
  from its dependencies; the reggaefile builds the latter and emits the
  effective session snapshot from the former.
- **Unsupported settings.** If a dub setting cannot be represented in the
  Quickbite session, it must be called out explicitly rather than silently
  dropped.
- **Compiler choice.** The reference compiler handed to reggae/dub determines
  the effective session. Use the DMD compiler for the dubdeps build so the
  emitted session matches the frontend Quickbite runs.

## Sequencing

1. Land `--reggaefile-dir` and deps-only dub target support in reggae; bump
   quickbite's reggae requirement.
2. Add `benchmarks/dubdeps/reggaefile.d` producing the dependency image and the
   effective compiler session snapshot, deps-only, in a Quickbite-owned build
   directory.
3. Thread the session snapshot into the frontend/compiler/session boundary and
   keep it live for parse, semantic, and codegen.
4. Switch `bin/bench.sh --dub` to drive the reggae build and run the existing
   Quickbite package path against the resulting session and dependency image;
   delete the describe path.
5. Verify: `bin/bench.sh --dub automem` benchmarks all 11 fixtures instead of
   skipping them; existing `tests/ut/bin` benchmark tests stay green.
