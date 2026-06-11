# DMD Native Backend: `DynamicLibrary`

> Naming note: the backend has since been renamed `SystemLinker`
> (`source/quickbite/backends/native/system_linker.d`). Mentions of
> `DynamicLibrary` and `dynamic.d` below refer to it.

## Scope

The goal is to **use and re-use dmd's codegen backend in-process**.
Spawning a whole `dmd -unittest -shared` per fixture already works and is
the null hypothesis; any design here must beat it by sharing the
in-process frontend AST (the multi-backend matrix and the REPL endgame
both depend on that). Test every design choice against this criterion.

The pipeline has three stages — keep them separate when reasoning:

1. **Ownership** (semantic time): which module's members hold which
   template instances/TypeInfos. Solved by the lightning rod + child-side
   prune (slice 2, lessons 8-9, 13).
2. **Codegen re-use**: dmd's backend has a strictly one-shot,
   once-per-process contract (`backend_init` once, `PASS.obj`/`csym`
   marks, `deferToObj`, enum/TypeInfo gates) — dmd itself inits, emits
   each module once, and exits. Solved by `fork()`: each codegen gets a
   disposable copy of the process image, i.e. the backend is used exactly
   the way dmd uses it. Manually un-writing the state (the slice-1 reset
   walker) works but is a shadow copy of dmd-internals knowledge that
   must be re-learned on every dmd upgrade.
3. **Loading**: object file → running code in this process. Today:
   spawned `dmd -shared` + `dlopen` (~30 ms, full druntime integration
   via `Runtime.loadLibrary`). A mini in-process linker or LLVM
   ORC/JITLink (`ObjectLinkingLayer` accepts precompiled ELF objects —
   no LLVM IR involved) are stage-3 **swaps only**: out of scope until
   the matrix is healthy on the dlopen loader, and localized to
   `linkSharedLibrary`/`loadSharedLibrary` (~50 lines) when they happen.
   If compile → system link → `dlopen` cannot be made correct, nothing
   fancier will be either. Fork composes with all loaders: the child's
   product is an object file, and loading must happen in the parent
   regardless (results, exceptions, GC).

`source/quickbite/executors/` (including the `DmdCodegenRam` hand-rolled
ELF loader in `dmd_codegen.d`) is legacy reference code kept as
inspiration; it will be deleted. Two facts worth keeping from it for any
future stage-3 work: its RAM loader registered nothing with druntime —
no `.eh_frame`, GC ranges, or module ctors — and a loader without those
cannot pass the runner matrix (catching assert `Throwable`s requires
unwinding through generated frames); and its ~3000-line hand-enumerated
`pragma(mangle)` support shim existed precisely because its input objects
were not self-contained — the ownership problem slice 2 solves upstream.

## Current state (2026-06-11, slice 1 merged as PR #205)

**Direction (agreed 2026-06-11):** slice 1's machinery works, but it is
~380 of system_linker.d's 611 lines of custom code that drives dmd
differently from how dmd drives itself, and it forces fresh parses.
Slice 2 replaces it with fork + lightning rod (lessons 8-9, 13-14),
deleting the adoption loop, the written-state reset walker, the
foreign-member pruning, and every fresh-parse workaround.

**Open bug (found 2026-06-11, investigate independently of slice 2):**
`bin/bench --backend=system-linker` skips every fixture at the
correctness gate (`checkRunnerResults`, benchmarks/cli.d:89) with
"unittest symbol not found in shared library", even freshly built. The
ut path drives SystemLinker fine; the bench's standalone-fixture path
(module naming or parse order) does not line up.

`source/quickbite/backends/native/system_linker.d` implements
`quickbite.backends.runner.Runner.runTests`:

1. Caller parses the module with checkaction=context — **uncached**
   (`parseModuleWithCheckActionContextUncached` in
   `source/quickbite/frontend/compiler.d`; see "Lessons" for why).
2. `emitObjectFile`: reset codegen written-state (lesson 11), prune foreign
   members, `dmd.glue.generateCodeAndWrite` writes one object file to a
   unique temp dir, then the adoption loop (lesson 10) re-emits until the
   object contains every instance/TypeInfo symbol it references. Backend
   initialised once per process with `PIC.pic`. Runs under the compiler
   lock.
3. `linkSharedLibrary`: spawns `dmd -shared -defaultlib=libphobos2.so
   -L=-z -L=defs`. `-z defs` deliberately turns every missing symbol into a
   link error instead of a load-time or call-time failure — keep it; it is
   what makes failures diagnosable.
4. `Runtime.loadLibrary` (registers module ctors/GC with host druntime —
   requires the host to link shared druntime).
5. Per unittest: `dlsym(mangleExact(unitTestDecl))`, call, catch `Throwable`.
   Per-test results come from enumerating the AST with
   `foreachUnitTestDeclaration`, not from druntime's `__modtest`.
6. `GC.collect` before `Runtime.unloadLibrary` (lesson 12).

**Passing:** 357 runner matrix blocks include `SystemLinker` (was 14
before slice 1, 336 before slice 3 — PR #206), each tagged
`@Tags(backend.stringof)` so `bin/ut '~@SystemLinker'` skips them (they
are slow: compile+link+load per test) and `bin/ut @SystemLinker` runs
exactly them. The old slice-3 dlsym miss (`reportsAssertFailureMessages`)
is in the matrix and passing. Slice 3 oracle-arbitrated and promoted all
the CTFE-flavoured and message-text blocks; the verdicts are in its DONE
section below.

**Still out of the matrix**, by category:

- **Imported user modules**:
  `runBackend{File,Source}FixtureTests.withImportPaths` — the snippet
  imports a module from importPaths whose functions are compiled nowhere;
  needs multi-object compilation of imported modules.
- **Fatal by design in-process**: the three null-class-dereference
  diagnostics blocks (compiled null deref is a real SIGSEGV that kills the
  test runner) and `voidInitializedScalarReadReportsUninitialized`
  (CTFE-only diagnostic). Both excluded with comments in the test files.
- **FFI-bridge design tests** (added after the slice-3 enumeration):
  rt/cstdlib.d's `noSource`/bridge blocks encode interpreter-backend
  expectations; compiled code would pass those fixtures, so SystemLinker
  variants belong with any future FFI-bridge work, not the matrix sweep.

Build-layout note: dmd 2.112's glue layer (`dmd/glue/` package) compiles
inside the dub `dmd:frontend` dependency; only `backend/*` + `dmsc.d` are
excluded there and vendored via `scripts/vendor-dmd-backend.sh`.

## Lessons learned (hard-won, do not relearn)

### 1. DMD pollutes the first root module parsed in the process

`TemplateInstance.appendToModuleMember` (templatesem.d) and
`typinf.getTypeInfoType` (typinf.d ~:118) both redirect non-root modules
through `importedFrom`, so the first root module ever parsed (snippet_0)
accumulates speculative template instances and TypeInfoDeclarations from
*every later compilation in the process* — including CTFE-only runs by other
backends. Codegen of such a module emits dangling references to other
snippets' symbols. Consequences already baked in:

- `SystemLinker` must only ever codegen a **freshly parsed** module. The
  ut harness enforces this via a `static if (is(T == SystemLinker))` in
  `tests/ut/backends/package.d`. Any future caller (benchmark harness, REPL)
  must do the same.
- `removeForeignTemplateInstances` in system_linker.d prunes members whose
  `minst`/declaring module isn't this module before codegen — belt and
  braces; it was **not sufficient alone** (adopted instances slipped
  through).
- `global.params.allInst = true` is **active** (`compiler.d:178`,
  unconditionally, since the early dynamic-library commits). With allInst
  on, `appendToModuleMember` (`templatesem.d:1233`) always routes non-root
  template instances via `importedFrom` to the first root module parsed.
  Slice 1 worked around this via the ELF adoption loop (lesson 10) rather
  than controlling ownership upfront. See lesson 8 for why it is not a trap
  if the first root module is one we control.

### 2. Template instances are emitted once per process, owned by the first instantiator

This is the blocking correctness problem. DMD caches template
instantiations process-wide; an instance's `minst` is whichever root module
instantiated it first. The glue layer emits the instance only into *that*
module's object. Every later object that uses the instance references the
symbol without containing it → with `-z defs`, a link error; without it, a
load/call-time failure.

This bites every checkaction=context fixture that reports values:
`assert(a == b)` lowers to `_d_assert_fail!int(...)` — a druntime
*template*, not exported by libphobos2.so. Same story for
`_d_newclassT!(AssertError)`. The failures are **order-dependent**: a
fixture passes if it happens to be the first in the process to instantiate
the template. That is why `boolAssertionContextMatchesDmd` passed solo and
flaked under `--random`, and why the stable keep-set is exactly the
fixtures needing no template instances beyond what libphobos2.so happens to
export (`||`/`&&` asserts, explicit-message asserts, plain
`throw new Exception` via the exported `_d_newclassT!Exception`).

### 3. Process-global mutation invalidates live iterators

The instance/TypeInfo appends from (1) can realloc `module_.members` while
it is being walked. `foreachUnitTestDeclaration`
(`source/quickbite/frontend/util.d`) segfaulted this way and now iterates
by index. Any new code walking dmd arrays across a point where compilation
or test execution can happen must do the same.

### 4. Message oracle

The backend's failure messages must match what really-compiled
`dmd -unittest -checkaction=context` code prints, byte for byte. When a
DynamicLibrary message disagrees with a test expectation, the arbiter is a
real dmd compile-and-run of the fixture — not the CTFE backends, whose
expectations may themselves encode CTFE quirks.

### 5. Reproducing order-dependent failures

`bin/ut --random --seed N` (both flags; `--seed` alone does **not**
randomize). Known historical repro seeds, both green now and worth keeping
in any regression loop: `2828407573` (foreign-member link failure),
`3516581215` (iterator-invalidation segv). Crashing runs need
`stdbuf -oL` to keep output.

### 6. A fresh parse cannot reclaim instance ownership (2026-06-10)

If any earlier compilation in the process already instantiated a template,
a later fresh parse of the same source gets the *cached* instance, owned
(`minst`) by the earlier module. The instance is never appended to the
fresh module's members, so its codegen emits a dangling reference and the
`-z defs` link fails. The benchmark harness hit this with
`_d_arrayliteralTX!ubyte`: its frontend timing runs warmup + N uncached
parses of the fixture, so any module parsed afterwards — fresh or not —
cannot own the fixture's instances. The empirical fix there is parse
*order*: `prepareFixtureRuns` parses the kept module before the timed
uncached parses, so it is the first instantiator and owns (and therefore
emits) its instances. Fixture-local templates are immune (each parse makes
a fresh `TemplateDeclaration` with its own instance cache); only templates
from cached imports (druntime/phobos lowering hooks) are affected.

**This lesson is dissolved for `SystemLinker` by the adoption loop (lesson
10):** owned-or-not is irrelevant once the object's ELF undefined symbols
drive instance adoption — borrowed instances are re-homed into the snippet
module and re-emitted. **Slice 2 dissolves it for all callers:** with the
rod parsed first, druntime/phobos instances never land on snippets, cached
snippets stay clean, and the benchmark's parse-order pre-parse
(benchmarks/cli.d:497-503) is deleted.

### 7. Codegen of the same module AST twice emits an empty object (2026-06-10)

`generateCodeAndWrite` on a module already codegen'd in this process
writes an object with no function symbols: the glue marks functions as
written and skips them on the second pass (`fd.semanticRun >= PASS.obj`
guard, `glue/package.d:434`). Note that the pass is *incremental*, not
fully empty: template-instance members appended *after* the first pass
(speculative instances promoted later) do emit, since their member
functions are still at `semantic3done`. But for the SystemLinker's
benchmark loop the first-pass functions are exactly the ones needed —
every subsequent pass misses them. The resulting `.so` links (nothing is
undefined in an empty library) and every `dlsym` then misses, reported as
"unittest symbol not found in shared library: <mangled name>". This
blocks the benchmark's timed loop — 1 warmup + N iterations means
repeatedly codegen'ing the same module.

**This lesson is dissolved for `SystemLinker` by the written-state reset
(lesson 11):** resetting `semanticRun` and `csym` before each re-emit
means every codegen pass sees the module as un-written. The benchmark's
timed system-linker loop is now unblocked as a side-effect of slice 1.
**Slice 2 dissolves it differently:** every fork child sees pristine
once-per-process gates, so the reset walker is deleted outright.

### 8. `allInst=true` is what concentrates instances at the first root module (2026-06-11)

`global.params.allInst = true` is set unconditionally at
`compiler.d:178` and never cleared (despite the plan's earlier "tried
and removed" note — that referred to a per-codegen toggle that was
removed, not this process-global setting). With allInst active,
`appendToModuleMember` (`templatesem.d:1233`) always takes the branch that
chases `importedFrom` on the template's declaring module. For every
druntime/phobos template (`_d_assert_fail`, `miniFormat`,
`_d_newThrowable`, etc.), `importedFrom` resolves to the first root module
ever parsed in the process. This is deterministic: whichever module the
process parses first as root becomes the accumulation point for every
druntime/phobos instantiation that happens later.

This is the mechanism that would make a **lightning-rod design** work
(see lesson 9 for the design): control the first root module and you
control instance ownership. Slice 1 took a different path (ELF adoption
loop, lesson 10) that does not require controlling the first root module,
but the lightning-rod + fork approach remains a cleaner long-term
alternative.

### 9. Fork-based codegen isolation design (alternative to adoption loop)

A future refactor could replace the adoption loop entirely:

`fork()` before `generateCodeAndWrite` gives the child a copy-on-write
snapshot of the full dmd AST and process globals. The child runs codegen,
links the `.so`, writes it to `/tmp`, then `_exit`. The parent's state
— `PASS.obj` marks, `csym` populated by `toSymbol`, ELF segment tables —
is never mutated. Combined with a **lightning rod module** (parse a small
controlled module as the very first root module in the process so it
becomes the accumulation point for all druntime/phobos instances), this
dissolves lessons 6 and 7 entirely and removes the fresh-parse requirement.

**Why it is safe here:**
- The process is single-threaded at fork time: `unitUnthreaded` forces
  sequential tests (dub.sdl:24), no D worker threads exist.
- druntime registers `pthread_atfork` handlers for the GC
  (`gc.d:1794–1797`): the prepare handler locks gcLock, the child handler
  unlocks it and resets parallel-scan-thread state. GC allocations and D
  exceptions work normally in the child.
- The conservative GC's optional `COLLECT_FORK` mode (disabled by default)
  is direct precedent for fork-without-exec running full D code.
- The child still needs to spawn `dmd -shared` (fork+exec) — fine; spawning
  from a forked child is safe on Linux.
- The parent dlopens the `.so` from a file path computed before forking; no
  codegen-time state is needed beyond mangled names derived from the parent AST.

**What fork alone does NOT fix:** `minst` ownership is set during semantic
analysis in the parent. The lightning rod is what ensures druntime/phobos
instances are owned by the right module before the fork. Without the
lightning rod, the child still needs the adoption loop or pruning.

**Error transport:** the child cannot throw across the fork boundary. Exit
code + an optional pipe for error text; the `.so` path is computed by the
parent before forking.

**Slice-2 addenda (2026-06-11):**
- Fork inside `withCompilerLock`: the child inherits the held
  `Compiler.mutex` it owns and never unlocks before `_exit`. Safe because
  everything is single-threaded — `versions "unitUnthreaded"` in dub.sdl,
  and neither the benchmark nor the repl spawn threads (verified).
- Fork also dissolves all three adoption-loop candidate sources (lesson
  10): codegen-driven instantiations and codegen-time TypeInfos happen
  fresh in every child, because the parent never trips the
  once-per-process gates.
- What fork+rod still needs that this lesson missed: the child-side prune
  of the rod's members (lesson 13). "The adoption loop or pruning" above
  understates it — the prune is mandatory, but it is ~40 lines, needs no
  restore (the child exits), and replaces ~380.

### 10. Adoption loop: undefined ELF symbols are the discovery mechanism (slice 1; deleted by slice 2 — kept as the spec the spike must match)

"Which instances does this module need but not own?" is answered exactly
by the undefined symbols of the object just written (`-z defs` checks the
same set). `emitObjectFile` loops: parse the object's ELF symtab → adopt
every cached instance/TypeInfo whose symbols match → reset written-state →
re-emit, until no new adoption. Template symbols are COMDATs and every
test `.so` links independently, so duplicate emission across objects is
safe; symbols libphobos2.so exports simply never match a candidate and the
loop terminates. Candidate sources (all three are needed):

- module members across `Module.amodules` (semantic-time instances —
  prefix match on `"_D" ~ mangleToBuffer(cast(Dsymbol) instance)`),
- `TemplateDeclaration.instances` caches (codegen-driven instantiations,
  e.g. `hashOf` for an AA TypeInfo, never reach any members array; also
  claim speculative ones — `minst = module_` — when emitted code provably
  references them),
- `Type.stringtable` → `Type.vtinfo` (TypeInfos created during codegen are
  cached only on the type; `genTypeInfo` returns needs-codegen only on
  vtinfo *creation*, once per process. A `TypeInfoDeclaration` ident is
  the complete symbol name; as a module member it emits unconditionally as
  a COMDAT via `toobj.d`).

### 11. The written-state to reset for re-emission (slice 1 / lesson 7 fix; deleted by slice 2 — fork makes it unnecessary)

Codegen marks everything written once per process. To re-emit a module
(and its adopted instances), reset, recursively over members and
everything codegen'd *with* a function rather than as a member:

- `FuncDeclaration.semanticRun` PASS.obj → PASS.semantic3done, and
  `Dsymbol.csym = null` everywhere (stale backend Symbols carry the old
  local-symtab index → `assert(s.Ssymnum == SYMIDX.max)` in symbol_add).
- Function-local state via `foreachExpAndVar`/`foreachVar` plus a
  postorder walker: parameters, `vthis`/`vresult`, body-local variables,
  nested functions/literals (`FuncLiteralDeclaration.deferToObj` is a
  once-per-process gate in e2ir!), local structs/classes, `lowering`
  fields (ArrayLiteralExp, AssocArrayLiteralExp, NewExp, CastExp,
  LoweredAssignExp, CatAssignExp, CatExp, EqualExp — the generic walkers
  skip them), and `ExpInitializer` subtrees (a Dsymbol child, also
  skipped). Nested functions referenced rather than declared (foreach
  bodies) are reachable via DelegateExp/SymOffExp/VarExp.
- `EnumDeclaration.semanticRun` (separate once-per-process gate in
  toobj.d) and the synthesized struct methods `xeq`/`xcmp`/`xhash` (hang
  off the struct, not in members; templatesem's InstMemberWalker visits
  them explicitly for the same reason).
- Do NOT walk into `TemplateDeclaration` bodies: parse-time AST,
  `foreachExpAndVar` asserts on un-lowered statements.

### 12. dlclose + GC heap = dangling vptrs (slice 1)

Dead-but-uncollected objects of classes the fixture defines carry vptrs
into the test's `.so`. After `Runtime.unloadLibrary`, ANY later finalizer
sweep (`rt_hasFinalizerInSegment`) dereferences unmapped memory — the
crash surfaces tests later, far from the cause. Fix: `GC.collect` right
before each unload, while the library is still mapped. Fixtures whose
*reachable* objects survive the collect would still be landmines; results
copy primitives out, so none do today. (This is a parent-side loader
concern; it survives slice 2 unchanged.)

### 13. The rod's object is dirty: foreign-parameterized instances (validated against dmd source, 2026-06-11)

rod.o must be in **every** link: a snippet's druntime instances are parked
on the rod (`appendToModuleMember`, templatesem.d:1233, routes via
`importedFrom` under allInst), so snippet.o alone is missing them. But the
rod also accumulates instances parameterized on *other* snippets' types
(`_d_newclassT!(snippetA.Widget)`, TypeInfos for snippetA's structs), and
codegen of the rod **emits them**:

- `needsCodegen` (templatesem.d:2818-2862) is provenance-based — true as
  soon as `minst.isRoot()`, never link-set-based. Once snippetA was a root
  module, its instances emit forever, from whichever module's members they
  sit in.
- `_d_arrayliteralTX` is emitted unconditionally (templatesem.d:2813-2816).
- TypeInfoDeclarations are gated only by `isSpeculativeType`
  (toobj.d:605), which returns false for plain non-template structs
  (typinf.d:253).

Emitted foreign instances reference snippetA's
`__ClassZ`/`__vtbl`/`__init`/`xeq`/`xcmp`/`xhash`/`toString` as
`SC.extern_` (tocsym.d:506/676/741; todt.d:1502-1560) — undefined in a
rod.o + snippetB.o link.

**Non-fixes:** `--gc-sections` is a no-op for shared libraries (all
symbols are dynamic-exported, so every section is a GC root). Dropping
`-z defs` just moves the failure to dlopen — vtable/TypeInfo *data*
relocations bind eagerly. No frontend mechanism prunes by symbol
resolvability.

**The fix: prune the rod's members in the fork child before emission** —
drop template instances whose arguments (and TypeInfos whose type) come
from a root module other than the current snippet. Sound because snippets
cannot reference each other's types; modules shared via importPaths are in
the link (slice 2 emits imported-module objects too), so their instances
survive the prune and resolve. No restore needed — the child exits. This
is the one piece of custom code that remains, and it encodes a real
invariant instead of fighting the frontend.

The rod is deliberately not "real life": it exploits the same
allInst+importedFrom funneling that causes the pollution, concentrating
the unavoidable consequence of a shared in-process frontend into one known
place with one principled filter. Fork makes each codegen look like a
fresh dmd process; the rod handles the one thing that cannot be made
fresh.

### 14. Measured fork costs (2026-06-11, this machine)

- `fork()`+waitpid: ~0.3 ms median, **flat from 100 MiB to 4 GiB parent
  RSS** (COW page-table setup scales with mappings, not bytes resident).
  A child dirtying 20 MiB of inherited pages adds nothing measurable.
- Baseline: ~43 ms median per SystemLinker test (range 36-94 ms), ~30 ms
  of which is the spawned `dmd -shared` link against shared phobos.
  Runner RSS ~40 MiB. Fork is <1% per-test overhead.
- The cost that *can* grow is not fork: it is re-emitting rod.o every
  test as the rod accumulates instances over the process lifetime.
  Measure the growth curve in the spike; watch it in the benchmark.
- Footnotes: `_exit` skips the coverage flush, so codegen-path coverage
  is lost in `-cov` builds; debugging child crashes needs gdb
  `set follow-fork-mode child`; fork is POSIX-only.

## Parallel sessions

Slices 2 and 3 are designed to run as **concurrent agent sessions**:

- Each session works in its own git worktree + branch (existing
  convention: `worktrees/<branch-name>`), e.g. `dmd-backend-slice2-fork`
  and `dmd-backend-slice3-expectations`.
- Their file sets are disjoint by the slice-3 rule (slice 2 owns
  system_linker.d, compiler.d, tests/ut/backends/package.d,
  benchmarks/cli.d; slice 3 owns tests/ut/backends/runner/ct/*), so
  merges are trivial. If slice 3 lands new matrix blocks first, slice 2
  rebases and gets a stronger gate for free.
- The slice-2 spike is throwaway: keep it in an untracked scratch dir
  (e.g. `scratch/` or /tmp), not committed; only its findings go in this
  plan and its pollution scenario graduates into the matrix as a real
  test during Step 1.
- Read the whole plan before starting either slice — the Lessons section
  exists so they are not relearned.

## The work, in order

### Slice 1 — make template-instance fixtures link — DONE (2026-06-11)

Done on branch `dmd-backend-slice1`; mechanism in lessons 10-12. The sweep
promoted every block that passes; `diagnostics.oops` (the success
criterion) and the rest are stable under `--random` and both repro seeds.
The same reset machinery unblocks repeated codegen of one module
(lesson 7), which the benchmark's timed system-linker loop needs.

A fork+lightning-rod design (lessons 8-9) would have been a cleaner
alternative — it dissolves lessons 6 and 7 and removes the fresh-parse
requirement. The adoption loop was chosen because it was incrementally
verifiable and self-contained. The fork path remains viable as a future
optimization (Slice 4 territory).

### Slice 2 — fork + lightning rod: delete the custom machinery

Goal: replace the adoption loop, written-state reset walker, and
foreign-member pruning with fork-based codegen isolation and a
lightning-rod module, removing the fresh-parse requirement so cached
modules can be codegen'd.

**Step 0 — spike (throwaway code, time-boxed, ~1 day).** The one question
dmd source cannot answer is actual linker behavior on the rod's object
(lesson 13). Standalone scratch program; do not touch system_linker.d:

1. Parse a small rod module at the end of `initializeDmdState`
   (compiler.d:106-180; it runs in `shared static this`, so the rod is
   the first root module for ut, bench, and repl alike).
2. Compile fixture A (defines a class, uses `assert(a == b)` so
   `_d_assert_fail!int` and `_d_newclassT` instantiate) → fork → child
   prunes rod members by template-arg origin (lesson 13) → emits rod.o +
   A.o → links `dmd -shared -L=-z -L=defs` → `_exit`; parent dlopens and
   runs the unittest.
3. Same for fixture B **from a cached parse** (no fresh parse — the
   scenario slice 1 could not do). The link must not reference A's
   symbols.
4. In-child sanity: `GC.collect`; throw and catch a D exception.
5. Growth curve: rod.o size and emit time over N≈100 synthetic fixtures
   (lesson 14: fork is flat; rod re-emission is the cost to watch).

Pass criteria: A and B link under `-z defs` and pass; B used a cached
parse; rod growth is acceptable. **Fallback: if the prune criterion leaks
(undefined symbols the prune should have removed), stop and reassess —
do not patch the filter until it links. A leaky prune criterion would
rebuild the adoption loop's discovery problem with less visibility; the
adoption loop stays until a sound criterion exists.**

**Step 1 — implement** (only if the spike passes):

- Rod parse in `initializeDmdState`, plus a runtime guard asserting
  `Module.rootModule` is the rod before any SystemLinker codegen — a
  pre-rod parse must be a loud assert, not a mystery link error two
  tests later.
- `emitObjectFile` → fork inside `withCompilerLock` (lesson 9 addenda).
  Child: prune rod → emit rod.o + snippet.o + imported-module objects →
  spawn `dmd -shared -z defs` → `_exit(0)`. Error transport: exit code +
  pipe for error text; `.so` path computed by the parent before forking.
- Parent: `Runtime.loadLibrary`, dlsym+run, `GC.collect` before unload —
  unchanged (lesson 12).
- Delete: adoption loop + ELF symtab parser + `mangledPrefix`
  (system_linker.d:82-93, 348-478); reset walker (:96-315); foreign
  pruning + `typeModule` (:486-520); the
  `static if (is(T == SystemLinker))` in tests/ut/backends/package.d:41-52;
  `parseModuleWithCheckActionContextUncached` (compiler.d:60-65,
  242-257); the benchmark parse-order pre-parse (benchmarks/cli.d:497-503).
  `parseModuleUncached` stays — cell.d and the bench timed loop use it
  for unrelated reasons.
- Gate: the full matrix (`bin/ut @SystemLinker`), `--random` repeatedly,
  both historical seeds, ./ci.sh. The spike's two-fixture pollution
  scenario graduates into the matrix as a permanent regression test — it
  is the exposing test for lesson 13.

**Folded in — imported user modules (was slice 3b):** multi-object
linking is native to this design. Walk `module_.aimports` for modules
under the given import paths; the child emits each and passes all objects
to the link. This promotes the two `withImportPaths` blocks
(tests/ut/backends/runner/ct/results.d:251, :280) and closes the prune
edge case where fixtures share an importPaths module.

### Slice 3 — message texts and CTFE-flavoured exclusions — DONE (2026-06-11, PR #206)

Test-side only, as planned: every candidate block was arbitrated with
the real-dmd oracle (lesson 4) and encoded by splitting the
static-foreach block per backend (the expressions.d `@ShouldFail` split
pattern; nondeterministic message parts via the existing
`collectExceptionMsg`+`canFind` pattern). 21 new `SystemLinker` blocks,
each verified solo, under repeated `--random`, and on both historical
seeds. **The backend matched the oracle on every block — nothing was
handed to slice 2.** Oracle verdicts worth keeping:

- `assert(false)`/`assert(0)` in a **unittest body** → "unittest
  failure" (`_d_unittest` hook); in a **called function** → "Assertion
  failure" (`_d_assert`). checkaction=context adds no operands for
  literal conditions; the "`assert(...)` failed" wording is CTFE-only.
- Uncaught throws report the exception's own message, not the
  "uncaught CTFE exception" wrapper.
- Bounds errors: druntime's "index [N] is out of bounds for array of
  length N"; AA missing key and overlapping slice assignment are both
  plain "Range violation".
- Compiled code genuinely passes where CTFE rejects or ShouldFails:
  pointer slicing past a block (unchecked at runtime), `dg.funcptr`,
  `malloc`, int-to-float precision, cerealed's static child registry.
- Nondeterministic compiled messages: `typeid(T).name` is
  module-qualified (`snippet_N.Widget`), `dg.ptr` is a live pointer
  value — both matched on their stable suffix.

`voidInitializedScalarReadReportsUninitialized` and the three
null-class-dereference blocks stay excluded with comments (CTFE-only
diagnostic / real SIGSEGV). Note: once slice 2's fork machinery exists,
forking the *execution* step too would make the null-deref blocks
tolerable — possible follow-on, not in scope.

### Slice 4 — Evaluator interface

Only after the runner matrix is healthy. The live contract is
`Evaluator.eval(FuncDeclaration)` (source/quickbite/backends/evaluator.d:18)
— the single required primitive; `eval(string)`/`eval(Cell)` are final
dispatchers on it. (An earlier draft of this plan said
`eval`/`evalRepl`/`runTestSummary`; that predates the interfaces.md
migration.) Missing pieces: value transport from machine code back to a
`quickbite.lang.Value` (does not exist), and latency — per-call
compile+link+load is ~43 ms today (lesson 14); benchmark before promoting
anywhere near the REPL hot path (ai/plans/repl.md puts a native session
at step 9 of 9). With slice 2 done the fresh-parse caveat is gone, and a
stage-3 loader swap (Scope) becomes the latency lever if needed.

## Test discipline

- A backend joins a `static foreach (backend; AliasSeq!(...))` block only
  when the test passes repeatedly under `--random` (not just solo) —
  order-dependence is the failure mode here. (The tests use plain
  `AliasSeq` lists; `backendsWith` appears only in older plan drafts.)
- Every kept block carries `@Tags(backend.stringof)` so SystemLinker
  variants stay opt-out-able: `bin/ut '~@SystemLinker'`.
- Every fault found must pair with a test that exposes it; for ownership
  bugs the exposing test is usually "this fixture, after any other
  compilation, under --random".

## Verification

```sh
ninja -C <build> bin/ut
bin/ut --random                       # repeat; order-dependence is the enemy
bin/ut --random --seed 2828407573     # historical link-failure order
bin/ut --random --seed 3516581215     # historical segfault order
bin/ut @SystemLinker                # just the native-backend matrix
./ci.sh
```

## Key reference files

- `source/quickbite/backends/native/system_linker.d` — the backend
- `source/quickbite/frontend/compiler.d` — parse cache, `initializeDmdState`,
  `allInst=true` at :178
- `source/quickbite/frontend/util.d` — index-based unittest walk
- `tests/ut/backends/package.d` — fresh-parse `static if` for SystemLinker
  (deleted by slice 2)
- `source/quickbite/backends/evaluator.d` — the live Evaluator interface
  (slice 4)
- `benchmarks/cli.d` — bench harness; parse-order pre-parse at :497-503
  (deleted by slice 2), correctness gate at :89 (open bug, see Current
  state)
- dmd (dub, 2.112.0): `templatesem.d` (`appendToModuleMember` :1233,
  `needsCodegen` :2778), `typinf.d` (`getTypeInfoType`),
  `dmd/glue/toobj.d` (`visit(TemplateInstance)` :701, instance emission),
  `dmd/glue/package.d` (`FuncDeclaration_toObjFile` :434 skip guard,
  `generateCodeAndWrite`),
  `core/internal/dassert.d` (`_d_assert_fail` unary :38, binary :63,
  `miniFormat` :176), `core/lifetime.d` (`_d_newThrowable` :2669,
  `_d_newclassT` :2729)
