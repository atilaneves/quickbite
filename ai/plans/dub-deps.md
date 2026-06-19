# Dub Dependencies

Goal: per-edit work should scale with the project under test, not with
its dependency tree. The driving metric is save-to-test-results latency.
We do not yet know what dominates that latency for real dub projects;
every step beyond the next one is data-directed, not assumed.

## Guiding principle

Prefer caches keyed on content/identity at module (or function)
granularity over a first-class "dependency" concept. Dependencies are
the modules that usually don't change, so they fall out as the entries
that never miss. This holds for the hot per-edit module cache and for
the interpreter family, which never links anything.

It does **not** hold for the native family (SystemLinker, LLVMJit). They
must turn the whole transitive dependency closure into native code and
link it, exactly as `dub build` does, so for them "dependency" is a
first-class, unavoidable concept. The native dependency image (one
`lib<pkg>_dub_deps.so` per package, §"The build model" below) is the
shared form that concept takes. It is no longer deferred: LLVMJit cannot
benchmark any real dub package without it.

Caching addresses lowering/compiling only, never execution. Whether
dependencies "live" as .a/.so libraries or as cached bytecode is per
backend: the native family has no alternative to the dependency image;
for the VM backends FFI and interpreted bytecode must both be tried and
measured. FFI is needed regardless for `fbody is null` leaves (C/C++/Rust,
closed source) — see ffi.md §21.

## The build model: cold dependency image, hot project

There is no single "build a dub project" step. A dub project's build
decomposes into a **cold** dependency-preparation step, whose output form
is backend-family-specific, and a **hot** per-edit step over the project,
whose shape is the same for every backend. Only the project is timed; the
cold step runs once per `dub.selections.json` change.

```text
cold (once per dub.selections change):
  dub build --config=unittest         -> dependency .a's
  link dependency .a's into one .so   -> lib<pkg>_dub_deps.so   (dlopen once)

hot (every edit), per backend family:
  SystemLinker: codegen project .o -> dmd -shared against the .so
  LLVMJit:      codegen project .o -> ORC link, deps resolved from the .so
  Interpreter:  interpret project + dependency *source*; the .so only
                serves body-less native leaves
```

The dependency closure form each family needs:

- **SystemLinker** — deps as native code on a link line. Hot: codegen the
  project's objects, `dmd -shared` against the `.so`.
- **LLVMJit** — deps as native code resolvable in-process. Hot: codegen the
  project's objects, ORC link; deps come from the dlopen'd `.so`.
- **Interpreter / Bytecode** — deps as D source on the import path, plus
  native leaves loaded. Hot: interpret/lower the project and dependency
  source; dlsym the body-less leaves.

### The project is never in the dependency image

The image holds only the transitive **dependencies'** concrete native
code. The project under test is the volatile part: it is codegen'd or
interpreted fresh on every edit and resolved *against* the image. Putting
the project in the image would mean an edit never recompiles it — the
benchmark would time nothing. This matches PR #215, which already stopped
prepending the root package's own `bin/lib<name>.a`; `dub describe
--data=linker-files` lists only dependency archives, never the root's own.

Two consequences hold the line on what the image contains:

- It holds only **concrete** dependency code. A dependency template
  instantiated with a *project* type (`Decerealiser.value!ProjectType`,
  `xs.map!(lambda)`) has no body in any dependency `.a`, so it is not in
  the image; it is codegen'd with the project every edit. This is the
  existing per-fixture instance-homing problem below, neither fixed nor
  worsened by the image.
- Phobos is not bundled. The cold link uses `-defaultlib=libphobos2.so`
  so phobos stays a `NEEDED` shared dependency, resolved against the
  host's already-resident phobos at dlopen time (one GC, one DSO
  registry).

### Cold step: build the dependency image (a link, not codegen)

dub already ran the compiler over every transitive dependency. Collapsing
its `.a`s into the image is a pure link; Quickbite's DMD-as-library
codegen path (`emitObjectFilesForLink`) never sees dependency source.

```d
// Cold path, once per dub.selections change. dub already compiled the
// dependency objects; this only collapses its .a's into one shared object
// the hot path resolves against.
string buildDubDependencyImage(
    in string packageName,          // "cerealed" -> libcerealed_dub_deps.so
    in string[] dependencyArchives, // dub describe --data=linker-files
    in string outDir,
);  // spawns: dmd -shared -defaultlib=libphobos2.so
    //   -L=--whole-archive <archives> -L=--no-whole-archive
    //   -of=<outDir>/lib<packageName>_dub_deps.so
```

`--whole-archive` is load-bearing: nothing references the deps at this
link, so without it the linker drops every member and the image is
near-empty. The fresh project link then resolves against the populated
image.

### Hot step: codegen the whole project is the existing path

`emitObjectFilesForLink(rootModules, dir, CodegenInputs(archiveImportPaths))`
already *is* the whole-project codegen API. Its classification does the
right thing: `archiveImportPathsUnder(importPaths, packageRoot)` splits
imports so that paths **under the package root are codegen'd fresh** (the
whole project) and paths **outside are archive imports** (the deps, now
the one `.so`); `userImportedModules` transitively pulls in every project
module the roots reach. "Codegen for a whole dub project" is therefore
only a matter of feeding it the **whole-project root set** — every package
source file as a root, matching `dmd -unittest source/**/*.d` — instead of
just the discovered test modules. That root set is exactly what the
deferred `parseRootModules` produces, so the two open items compose:

```d
const projectModules = parseRootModules(packageSourceFiles, importPaths);
const objs = emitObjectFilesForLink(
    projectModules,
    dir,
    CodegenInputs(depImportPaths),   // deps -> resolved from the .so
);
```

### Changes to existing types

- `SystemLinkerInputs.linkFiles` carries the single `lib<pkg>_dub_deps.so`
  instead of the `.a` list. `linkSharedLibrary` then drops the
  `--start-group`/`--end-group` wrap (one `.so`, transitively resolved),
  directly shrinking the link inputs `dmd-backend.md` lesson 14 flagged as
  SystemLinker's dominant cost.
- LLVMJit gains a session-level step: `dlopen(lib<pkg>_dub_deps.so)` once
  before any test, so its symbols are in-process and ORC's
  process-symbol generator resolves them. ORC still links only the fresh
  project objects — no per-test dependency work. This closes LLVMJit's
  dependency gap: `llvm-jit.md`'s assumption that "after codegen the only
  undefined symbols are ones `libphobos2.so` exports" holds only for
  zero-dependency fixtures; a real package's dependency symbols live in
  `.a`s absent from the process until the image is dlopen'd.
- The interpreter family is unchanged on the D side (it interprets project
  and dependency *source*); the same `.so` is what its body-less native
  leaves dlsym against, so the image does double duty.

## Done

PR #215 (2026-06-12): SystemLinker links dub-built dependency archives
instead of codegen'ing dependency modules per run, matching `dub test`.

- `SystemLinker` takes `linkFiles` and `archiveImportPaths`; modules
  under the latter skip root promotion (no per-run semantic3) and
  codegen, and stay in the link set so the rod prune doesn't treat
  their types as foreign. Archives are group-wrapped on the link line.
- The bench builds the dub package first (`dub describe` reports
  archive paths whether or not they exist), classifies import paths
  outside the package dir as dependency paths, and no longer prepends
  the root package's own `bin/lib<name>.a` (the project under test is
  compiled fresh; only dependencies are prebuilt).
- Verified: dub-built `.a`s are PIC-clean on Linux x86_64 (no TEXTREL,
  loads under `-z defs`). `dub describe --data=linker-files` lists only
  dependency archives, never the root package's own.

Bench fixture-skip fix (2026-06-12): module-declared fixtures used to
be dropped entirely — the per-iteration frontend measurement
(`parseSnippetUncached`) re-parses the fixture, which collides with the
first parse's entry in DMD's package symbol table (dmodule.d, failed
`dst.insert`; no eviction in the load path), and the single try/catch
in `prepareFixtureRuns` took the whole fixture with it.
`prepareFixtureRuns` now separates the one-time parse failure (still
skips the fixture) from the frontend-measure failure, which only marks
the run `frontendUnmeasurable`; the frontend row prints "unmeasurable
(module declaration)" and `runTests` proceeds on the cached module.
Covered by the `moduleDeclarationFixtureIsNotSkipped` bench-behaviour
test.

Dub fixture-group link fix (2026-06-12): `--dub cerealed -b
system-linker` now links and measures the whole cerealed test suite
instead of reporting "skipping cerealed system-linker".

- `SystemLinker` has a multi-module `runTests` path so a dub package's
  fixture modules are codegen'd into one shared library for the timed
  group run.
- Archive-backed and default-path imports still avoid normal dependency
  codegen. For dub links only, their member lists are pruned to
  template/TypeInfo members before object emission, giving DMD a place
  to emit template instances borrowed by the current fixture group while
  leaving ordinary dependency declarations to the dub-built archives.
- Verified: `bin/bench --dub cerealed -b system-linker` reports a
  `cerealed system-linker` row (median 975.745 ms on the verification
  run), not a skip.

`symbolIsForeign` member-instance fix (2026-06-15): the rod prune
dropped a template instance whose argument type *is* emitted in this
link but reports `needsCodegen == false`. The victim was the `new`
lowering `core.lifetime._d_newitemT!(std.random.MersenneTwisterEngine!
(...))`: the engine struct instance is reference-pulled into the object
by the sibling `std.random.uniform!(...)` instances that use it, so it
is defined, but `needsCodegen` on it is false, and `symbolIsForeign`
used `instance.inst !in memberInstances || !needsCodegen(instance.inst)`
— the second clause marked the argument foreign, so the `_d_newitemT`
instance was pruned and the link/load failed with an undefined symbol.
Fix: membership in a codegen'd module's members array, not
`needsCodegen`, settles foreignness (`(instance.inst in memberInstances)
is null`). A member instance is emitted from that array regardless of
`needsCodegen`. Also: `loadSharedLibrary` now appends the real
`dlerror()` to its exception instead of swallowing it — the only way the
actual missing symbol was visible. Full `bin/ut` suite green.

Fixture discovery from dub, not a `tests/` glob (2026-06-15): `--dub`
used to hardcode `buildPath(pkgDir, "tests")` and depth-glob `*.d`
under it. That threw outright on packages with no `tests/` dir (their
unittests live in `source/`, e.g. concepts) and swept in
intentionally-failing example modules dub leaves out of the unittest
build (unit-threaded's `tests/examples/fail/`). Replaced with
`dub describe --config=unittest --data=source-files`, the authoritative
list of what `dub test` compiles, run through a new pure
`discoverFixtures(pkgDir, sourceFiles)` that keeps files under `pkgDir`
(dropping the generated `dub_test_root.d` in the cache and dependency
sources that leak into the list) minus runner/`package.d` files.
Covered by `discoverFixturesKeepsInPackageTestModules`. cerealed
regression-free (still rows; library modules now harmlessly
conflict-skip — DMD sees them loaded both as fixtures and as
imports-by-name, and they're still exercised via the importing tests).
Full `bin/ut --random` green.

File-backed fixture parsing (2026-06-17): benchmark fixture preparation
now parses source files through the frontend's file-backed `parseModule`
path instead of the in-memory `parseSnippet` path. This removed the old
cerealed DMD module-table conflicts caused by parsing a module-declared
source file under a synthetic `snippet_N.d` identity.

This is the right foundation but does **not** by itself land a new
corpus entry: it moved concepts and unit-threaded *past* the discovery
failure into distinct downstream blockers (see "Next" item 1).

## Open: parse dub packages as root module sets

The current `--dub` preparation still parses discovered package source
files one at a time. That is not equivalent to what dub hands to DMD:

```text
dmd -unittest <all package source files> -I <import paths>
```

In a real dub unittest build, the package's source and test modules are
root modules before import traversal can parse any of them as ordinary
imports. Quickbite's one-file-at-a-time path can instead parse
`cerealed.range` first, let it import `cerealed.scopebuffer`, and later
reuse that already-loaded `scopebuffer` module as a fixture.

DMD intentionally skips unittest bodies in non-root imported modules and
leaves bodyless `UnitTestDeclaration` placeholders. That is why:

```text
./bin/bench.sh -b ctfe --dub cerealed
```

can report that `__unittest_L302_C1` has no available source code even
though `src/cerealed/scopebuffer.d` has a real unittest at that line.
Running `scopebuffer.d` as a standalone root reaches the expected CTFE
limitation instead: `realloc` cannot be interpreted at compile time.

Fix this at the frontend boundary, not with package-specific ordering or
diagnostic workarounds. Add:

```d
ModuleParseResult[] parseRootModules(
    in string[] filePaths,
    in string[] importPaths,
);
```

The API should establish every `filePaths` entry as a root before any
source content is parsed, run the same parse/import/semantic phases over
that root set, and return modules in input order. It should preserve
file identity and reject reuse of a previously-loaded non-root module as
a runnable root fixture.

`--dub` should prepare its grouped benchmark unit through
`parseRootModules` once. Standalone fixture benchmarks should keep the
existing `parseModule` path.

## Open: per-fixture completeness (cross-fixture instance homing)

`bin/bench --dub cerealed -b system-linker` produces a row because a dub
package is timed as one **grouped** compile (all fixture modules in one
shared library — every instance is in-link, so nothing is missing). The
single-backend path also sets `skipCheck`, so correctness is not
verified there. The unsolved problem is the **per-fixture** path
(`checkRunnerResults`, used by any multi-backend cross-check): each
fixture is compiled as its own link, and that exposes a completeness
gap.

Root cause: DMD homes a template instance on the members of the *first*
root module that instantiates it (its `minst`); a root module's
`importedFrom` is itself, so the instance does **not** funnel to the
rod. In a persistent process every fixture is its own root, and all
fixtures are parsed up front, so an instance like
`cerealed.decerealiser.Decerealiser.value!int` (a method-template
instance, nested in the `Decerealiser` struct) is claimed by whichever
fixture used it first. A later fixture's separate link references the
same cached instance but finds it homed on a module not in *its* link,
so nothing emits it — undefined symbol under `-z defs`.

Started but **not** banked (it over-reaches): `adoptForeignInstances`,
which re-homes foreign-module template instances onto the rod in the
fork child (mirroring `adoptTypeInfos`), then lets `pruneForeignMembers`
drop the foreign-arg ones. It fixes the `value!int` class, but because
adoption is static and broad it also pulls in instances claimed by
*unrelated* fixtures, and arg-based pruning cannot detect an instance
with innocent args whose *body* references another fixture's type
(`tests.structs.CustomStruct`, `tests.range.MyInputRange.empty`) — those
references then go undefined and break the link. Mechanism and the
robust shape are documented in dmd-backend.md lesson 16.

Robust fix (deferred): adopt only the instances **actually referenced**
by this link. The linker already computes that set — so the shape is a
reference-driven loop in the fork child: emit, attempt link, parse the
undefined symbols, adopt only the foreign instances matching those
symbols, re-emit the rod and relink, to fixpoint. Needs a
mangled-symbol -> `TemplateInstance` map and multi-pass linking. A
cheaper alternative that sidesteps the whole problem: validate a dub
package as one group (matching how it is timed) rather than per fixture
— but that changes `checkRunnerResults` behaviour and needs sign-off.

Do not prioritize this before `parseRootModules`. A per-fixture link
model is still useful for standalone fixtures, but a dub package's
correctness check should first use the same grouped root-set unit that
will be timed. Otherwise the checker is debugging an artifact of
Quickbite's preparation model rather than a behaviour dub itself would
compile.

## Next, in order

1. Implement `parseRootModules` and route `--dub` preparation through it.
   Verify with a package-shaped sandbox test where one root imports
   another root whose unittest must still have a runnable body. Then run
   `./bin/bench.sh -b ctfe --dub cerealed` to confirm the misleading
   bodyless-unittest failure is gone; a CTFE failure on `realloc` is an
   honest backend limitation and should be reported as such.
2. Build the cold dependency image (§"The build model"). Add
   `buildDubDependencyImage` and have the `--dub` cold path link dub's
   dependency archives into one `lib<pkg>_dub_deps.so`. Point
   `SystemLinkerInputs.linkFiles` at that single `.so` (drop the
   group-wrap) and add LLVMJit's session-level `dlopen` of the image.
   cerealed is a weak test here — its only native leaves are libc
   (`mkdtemp`/`isatty`), so its image is near-empty and the native
   backends already link without one; the image's payoff and LLVMJit's
   need for it only appear on a corpus package with real D dependencies,
   so land this alongside the first such package (item 3).
3. Grow the corpus past cerealed. Fixture discovery is now layout-robust
   (Done, 2026-06-15), but discovery was only the first gate; each new
   package hits a distinct downstream blocker, in rough order of effort:
   - **concepts** (closest to a 2nd row): discovery works, but the
     SystemLinker link fails with `unrecognized file extension`. concepts
     is template-only so its `linkFiles` is **empty** — this is a
     SystemLinker degenerate-link bug (empty/odd object set), not a
     layout issue, and likely affects any zero-dependency package. Two
     of its three modules are negative-compile tests
     (`static assert(!__traits(compiles, ...))`) that skip when compiled
     in isolation. Fix the empty-link path first.
   - **unit-threaded** (the "meatier" target): its test modules
     **import each other by short name** (`unable to read module
     'normal'`) and the library `should` module collides with a fixture
     of the same name. Its suite is not structured for per-module
     benchmarking; it needs the nested `tests/.../` dirs added as import
     roots and a module-name-collision policy. Reassess whether it is
     the right "meatier" entry or pick a package with concrete-code deps
     and standalone test modules instead.
   - Environment robustness (separate from layout): `findPkgDir`
     hardcodes `~/.dub/packages` (ignores `DUB_HOME`) and sorts versions
     lexically (so the git-hash dir wins over 0.6.8) — switch to dub's
     own path resolution when this bites.
4. Instrument the bench with a per-phase breakdown of the edit cycle:
   one-time cold dependency parse+sema (currently in no measurement
   window at all), then per-edit root parse+sema, semantic3 of imports,
   codegen split by project vs dependency source path, link, fork,
   execution. For VM backends: lowering vs execution split, execution
   time attributed by the module the executing function came from.
5. Pick the next lever from the data, one at a time:
   - VM lowering dominates -> in-process bytecode cache keyed on
     function identity (falls out of the warm process; unchanged
     modules keep their AST objects).
   - Dependency execution dominates -> FFI / native image discussion,
     gated on a microbenchmark of boundary cost (libffi call vs
     interpreting the body).
   - Link dominates (known true for SystemLinker today: ~30ms of ~43ms
     median is the spawned `dmd -shared`, see dmd-backend.md lesson
     14) -> shrink link inputs, cache unchanged-module objects,
     faster linker.
   - Project-module re-sema dominates on multi-module projects -> the
     fork-for-sema extension (see dmd-backend.md); only then is the
     same-FQN reload problem worth attacking.

## Non-resident native dependencies (anticipated, data-gated)

This section is about the **interpreter family's** native leaves. The VM
backends execute dependency D *source*, so most dub deps need no native
loading — they compile transitively like project code. The native family
does not reach these populations the same way: its dependency D code is
already concrete native code in the dependency image, so populations 2/3
below become libraries on the **cold image's** link line (the same
`libs`/`lflags` extraction, fed to `buildDubDependencyImage` instead of to
a per-run `dlopen`). The leaves discussed here are the interpreter family's
`fbody is null` surface, in three populations:

1. Resident — libc, druntime, Phobos, already mapped into `bin/ut`;
   resolved by `dlsym(RTLD_DEFAULT, mangleExact(f))` (ffi.md §21/§22).
   cerealed bottoms out here and only here — its sole `extern(C)` leaves
   are `mkdtemp`/`isatty` from libc — so it needs none of the below.
   This is why cerealed is the right first target: it exercises the
   whole dub-project path with zero native-loading work.
2. Non-resident but installed — a package-manager `.so` a dep binds
   (sqlite3, ssl, pq, ...). Present on the system, absent from the
   process. The general case for real projects, but not cerealed.
3. Static-only `.a` with no `.so` — rare in the popular ecosystem (the
   common binders all ship `.so`s); deferred to the native-image /
   mini-linker track (ffi.md §3-§20).

Anticipated mechanism for (2), not built until a corpus project needs
it: the driver extracts each dep's `libs`/`lflags` from `dub describe`,
unioned across the closure, resolves names to sonames via
pkg-config/ldconfig, and eagerly `dlopen(RTLD_GLOBAL)`s them before the
run — so the uniform `dlsym(RTLD_DEFAULT)` resolver finds population 2
exactly like population 1 and stays load-free and backend-neutral. Eager
rather than lazy because a failed `dlsym` names a symbol with no
owning-library provenance, and because eager matches the oracle's
module-ctor ordering. `SystemLinker` itself needs the matching `-l` on
its link line — a slot `SystemLinkerInputs` lacks today — fed from the
same extraction step. `pragma(lib)` is a second, rare declaration site
(dropped at lowering today); deferred.

(2) splits by how the binding is declared: link-time binders
(`libs`/`lflags`, linker-resolved) need the eager load; runtime-loader
binders (bindbc-*, derelict-*-dynamic, gtk-d) declare nothing to dub and
`dlopen` themselves, so executing their D loads the lib via the resident
`dlopen` and they cost nothing extra.

None of this is built speculatively: it waits for the first corpus
project that fails to measure because a leaf resolves to a non-resident
library. Priority stays cerealed (above) -> grow the corpus (Next item
3) -> native loading only when a measured project demands it.
