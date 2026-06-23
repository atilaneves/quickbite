# Building `--dub` Targets via a Custom Reggae Build

## Goal

`bin/bench.sh --dub <pkg>` must benchmark the package's real unittest
configuration. Today it silently skips: `automem` reports
`discovered 11 / prepared 0 / skipped 11 — undefined identifier TestAllocator`,
and the post-parse table is empty.

The frontend we time is the DMD frontend running parse + semantic. It cannot
resolve `import test_allocator` without the dependency's import path, and it
compiles *different code* without `-preview=dip1000`. So import paths and flags
are not optional: they are intrinsic inputs to the thing we measure. The bug is
not that we need them — it is *how* we obtain them.

## The principle: re-derive nothing

Every approach that has quickbite *compute* the build is a partial
reimplementation of a build system, and each fails on its own terms:

- **`dub describe` (today).** Incomplete. `versions`/`debug-versions`/
  `string-import-paths` are structured, but preview flags are not a data kind —
  they live only as raw strings inside `dflags`, the field that proved
  unreliable. This is the actual cause of the `automem` skip.
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

The conclusion: quickbite should not derive flags at all. dub already holds the
structured, compiler-normalized build settings; reggae already wraps dub as a
library (it is quickbite's own build system, see `reggaefile.d`). We reuse that
single seam.

## The design: a reggaefile that builds *other* dub projects our way

We add a generic reggaefile whose job is not to build quickbite, but to build an
arbitrary external dub package in exactly the shape the benchmark needs. Given a
package directory + the `unittest` config, it produces three outputs and makes
one deliberate omission:

1. **Build all transitive dependencies** (reggae targets, incremental via
   ninja, invalidated on source / `dub.selections.json` changes).
2. **Convert them `.a` → `.so`** — one combined `lib<pkg>_dub_deps.so` the
   SystemLinker backend can `dlopen` (today's `buildDubDependencyImage`,
   expressed as a reggae rule).
3. **Emit every flag required to compile the root** — import paths, version
   identifiers, debug identifiers, string-import paths, and preview flags — read
   from reggae's `DubInfo`/`BuildSettings` for the root package, already
   normalized by dub for the target compiler.
4. **Never compile the root.** The root is what the benchmark parses, once. No
   build target produces it, so the double parse is gone by construction. (The
   dependencies are still parsed twice — by dub to make their `.a`, and by the
   frontend reading their source during semantic — but those are two different,
   both-necessary jobs. The root is the only one that was parsed twice for
   nothing.)

This is one seam (reggae's dub interop), no dub-extraction code in quickbite, no
double parse, incremental dependency builds, and compiler-dialect differences
handled upstream.

## Prerequisite reggae feature: decouple the reggaefile location

reggae binds both the project directory and the reggaefile location to a single
`projectPath` (`payload/reggae/options.d:380`; the reggaefile path is hard-coded
to `<projectPath>/reggaefile.d` at `options.d:128-141`). Its dub-as-library side
already uses `projectPath` as the package root (`dub/interop/dublib.d:63`,
`fullDub`), so pointing it at `~/.dub/packages/automem/.../automem` resolves that
package correctly. The only missing piece is the ability to supply *our*
reggaefile while building *their* package.

Add a small, contained option in `payload/reggae/options.d`:

- a field `string reggaefileDir;` (empty ⇒ defaults to `projectPath`);
- a getopt flag `--reggaefile-dir`;
- route the per-language accessors (`dlangFile` et al., `options.d:143-160`)
  through a helper `reggaefileBase()` returning `reggaefileDir` when set, else
  `projectPath`.

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
   - for each **dependency** package: emit its archive target and add it to the
     combined `.so` link;
   - for the **root** package: emit a generated D module
     (`dub_build_flags.d`) holding its flags as typed manifest constants;
   - emit the `lib<pkg>_dub_deps.so` target from the dependency archives.
   The root gets no compile target.

2. **Flags artifact = generated D module** (decision #3). Because the flags are
   compiled in rather than parsed at runtime, the `--dub` benchmark for a package
   becomes a **reggae-built target**: the reggae build emits `dub_build_flags.d`
   and links it with the quickbite bench library into a per-package bench
   executable that depends on the `.so`. `bin/bench.sh --dub <pkg>` drives that
   reggae build, then runs the resulting target. The generic `bin/bench` for
   ad-hoc file fixtures (`tests/example.d`, explicit module paths) is unchanged.

3. **Frontend application** — `source/quickbite/frontend/compiler.d`. At the two
   injection sites, `parseSourceLocked` (`compiler.d:504`) and
   `parseRootModulesLocked` (`compiler.d:318`), apply the flags beside the
   existing import-path push, each with save/push/restore on scope exit:
   - `versions` → `VersionCondition.addGlobalIdent`, restore `global.versionids`;
   - `debugVersions` → `DebugCondition.addGlobalIdent`, restore `global.debugids`;
   - `stringImportPaths` → `addStringImport`, restore `global.filePath` (confirm
     the helper targets `global.filePath`, the array queried during semantic, not
     only `global.params.fileImppath`);
   - preview flags → the `global.params` fields (`useDIP1000`, `ehnogc`, …),
     restored individually.
   Widen `parseModule` / `parseRootModules` / `parseSnippetUncached` to carry the
   new settings.

4. **Deletions** — `dubDescribe`, `dubInfoFromDescribeData`, `dubImportPaths`,
   the runtime `dub build --config=unittest`, and the describe-fed inputs to
   `buildDubDependencyImage` (its whole-archive logic moves into the reggaefile
   rule). `DubInfo`/`BackendEnv` widen to carry the new flag fields.

## Edge cases

- **Root vs dependency split.** reggae's `DubInfo.packages` separates the root
  from its dependencies; the reggaefile builds the latter and reads flags from
  the former.
- **Unmappable dflags** (`-mcpu`, `-O`, `-g`, `-conf`, link-only flags) have no
  frontend sink and are dropped on purpose — they do not affect frontend
  semantics.
- **Compiler choice.** The reference compiler handed to reggae/dub determines the
  dflags variant; pick the one whose dialect matches what we apply (the frontend
  is DMD's), so dub reduces preview flags to a single dialect for us.

## Sequencing

1. Land `--reggaefile-dir` in reggae; bump quickbite's reggae requirement.
2. Add `benchmarks/dubdeps/reggaefile.d` producing the `.so` and the generated
   flags module, deps-only.
3. Thread the new flags into the two frontend sinks.
4. Switch `bin/bench.sh --dub` to drive the reggae build and run the per-package
   target; delete the describe path.
5. Verify: `bin/bench.sh --dub automem` benchmarks all 11 fixtures instead of
   skipping them; existing `tests/ut/bin` benchmark tests stay green.
