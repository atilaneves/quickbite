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
   via `Runtime.loadLibrary`). Decision (2026-06-12): there will be
   **no loader swap** — this is SystemLinker's loader, permanently. If
   LLVM JIT is ever pursued it will be a *separate backend* (in the
   `native` package), not a stage-3 swap inside SystemLinker. Fork
   composes regardless: the child's product is an object file, and
   loading must happen in the parent (results, exceptions, GC).

`source/quickbite/executors/` (including the `DmdCodegenRam` hand-rolled
ELF loader in `dmd_codegen.d`) is legacy reference code kept as
inspiration; it will be deleted. Two facts worth keeping from it for any
future stage-3 work: its RAM loader registered nothing with druntime —
no `.eh_frame`, GC ranges, or module ctors — and a loader without those
cannot pass the runner matrix (catching assert `Throwable`s requires
unwinding through generated frames); and its ~3000-line hand-enumerated
`pragma(mangle)` support shim existed precisely because its input objects
were not self-contained — the ownership problem slice 2 solves upstream.

## Current state (2026-06-11, slice 2: fork + lightning rod)

Slices 1-3 are done. Slice 2 replaced slice 1's adoption loop, reset
walker, and fresh-parse workarounds with fork + lightning rod
(lessons 8-9, 13-14): cached (stale) parses are now codegen'd freely,
and the only custom machinery left is the child-side prune plus the
TypeInfo re-homing (lesson 15).

**Resolved by slice 2:** the open bench bug
(`bin/bench --backend=system-linker` skipped every fixture at the
correctness gate with "unittest symbol not found in shared library").
The bench runs `runTests` repeatedly on the same cached module
(correctness gate, then warmup + N timed iterations) — exactly the
repeated-codegen-of-one-AST case fork isolates. ci.sh's bench now times
the system-linker row (~59 ms median on `tests/example.d`) with zero
skips.

How it works now:

1. `initializeDmdState` (compiler.d) parses the **lightning rod**
   (`quickbite_rod.d`, an empty module) as the very first root module in
   the process and sets `Module.rootModule` to it — dmd.frontend never
   sets `rootModule`; only dmd's own main.d does. ~~All druntime/phobos
   template instances and TypeInfos funnel to the rod from then on
   (lesson 8).~~ **CORRECTION (2026-06-17): this is false for phobos.**
   An *empty* rod only owns the `importedFrom` of modules in its own
   import closure (`object.d` and the universally-imported `core.*`
   machinery), so druntime built-in instances funnel correctly but
   phobos instances do not — the rod never imports `std.range`, so
   `std.range.importedFrom` is claimed by the first transient parse that
   does, and instances like `std.range.iota`'s Voldemort `Result` strand
   at link. This is the `3.iota` bug. See lessons 17–20. Callers parse
   snippets with the normal **cached** checkaction=context parse;
   `parseModuleWithCheckActionContextUncached` is gone.
2. `buildSharedLibrary` (system_linker.d), under the compiler lock:
   asserts `Module.rootModule is lightningRod`, collects the snippet's
   transitive user-imported modules (everything whose source is outside
   the process-default import paths), promotes them to root the way
   `dmd -i` does (`importedFrom = module_` — codegen skips function
   bodies of non-root modules, glue package.d:485 `inNonRoot`) and runs
   their `semantic2`/`semantic3` parent-side. Then `fork()`.
3. The child prunes the rod's and the user imports' members against the
   link set (lesson 13), re-homes cached TypeInfos onto the rod
   (lesson 15), emits one object per module (snippet first, rod last) via
   one `generateCodeAndWrite` call, spawns
   `dmd -shared -defaultlib=libphobos2.so -L=-z -L=defs`, and `_exit`s.
   Errors travel through a pipe and re-throw in the parent. `-z defs`
   deliberately turns every missing symbol into a link error instead of a
   load-time or call-time failure — keep it; it is what makes failures
   diagnosable.
4. Parent: `Runtime.loadLibrary` (registers module ctors/GC with host
   druntime — requires the host to link shared druntime).
5. Per unittest: `dlsym(mangleExact(unitTestDecl))`, call, catch `Throwable`.
   Per-test results come from enumerating the AST with
   `foreachUnitTestDeclaration`, not from druntime's `__modtest`.
6. `GC.collect` before `Runtime.unloadLibrary` (lesson 12).

**Passing:** 360 runner matrix blocks include `SystemLinker` (14 → 336
slice 1 → 357 slice 3/PR #206 → 360 slice 2: the two `withImportPaths`
blocks and the pollution regression test), each tagged
`@Tags(backend.stringof)` so `bin/ut '~@SystemLinker'` skips them (they
are slow: compile+link+load per test) and `bin/ut @SystemLinker` runs
exactly them.

**Still out of the matrix**, by category:

- **Fatal by design in-process**: the three null-class-dereference
  diagnostics blocks (compiled null deref is a real SIGSEGV that kills the
  test runner) and `voidInitializedScalarReadReportsUninitialized`
  (CTFE-only diagnostic). Both excluded with comments in the test files,
  and they stay excluded (decision 2026-06-12): a SystemLinker variant of
  the null-deref blocks would only assert "compiled null deref
  segfaults" — testing dmd and the MMU, not quickbite — and compiled
  code passes the void-init fixture regardless. Forking the *execution*
  step is a runner-robustness measure, not a promotion vehicle: any
  runtime crash in compiled fixture code kills `bin/ut` mid-sweep today
  (lesson 5's `stdbuf` archaeology), and a per-test execution fork would
  turn that whole failure class into one red test reporting a signal.
  Adopt it on evidence — the first time a runtime crash actually kills a
  `--random` sweep — not speculatively; the null-deref blocks then
  graduate as the exposing tests for crash detection. Note it can never
  apply to the slice-4 eval path, where cell N+1 depends on process
  state mutated by cell N: it is runner-path hardening only.
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

Another exposing case from the coverage stream (2026-06-12):
`evaluatesRuntimePowFloatInputs` in
`tests/ut/backends/runner/ct/math.d` — `std.math` `pow!(float, float)`
is not exported by libphobos2.so, so the fixture links solo but fails
under the full suite once an earlier test owns the instance. The block
omits `SystemLinker` until instance ownership is solved; re-add it
then.

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
- Fork dissolves the first two adoption-loop candidate sources (lesson
  10): codegen-driven instantiations and codegen-time TypeInfos happen
  fresh in every child, because the parent never trips the
  once-per-process gates. It does NOT dissolve the third —
  semantic-time TypeInfos created in the parent during an earlier
  *snippet's* semantic are appended to that snippet, not the rod, and
  never re-created. See lesson 15 for the fix (found in slice 2's
  implementation, not the spike).
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

**Implementation findings (slice 2, 2026-06-11):** the criterion that
survived the matrix and full-suite `--random` is link-set based, not
just root-module based: foreign = references a module that is neither in
the link (snippet + its user imports + rod) nor under the
process-default import paths (druntime/phobos). Three refinements the
simple arg walk missed, each found by a real link failure:

- A symbol nested in a template instance is judged by the **instance**,
  not its declaring module: `core.internal.newaa.Impl!(int,
  snippetA.Nested)` is declared in druntime but foreign to every link
  except snippetA's (its TypeInfo on the rod referenced the pruned
  instance's `__xopEquals`).
- A **nested instance** whose own args are innocent
  (`Impl!(int, snippetA.Nested).findSlotLookup!int`) is foreign whenever
  an enclosing instance is — walk `parent` up to the nearest
  TemplateInstance.
- An instance with innocent args can still be **unemittable**: a
  speculative instantiation by unrelated in-process code
  (`std.array.Appender!(int[])`, instantiated by a repl test's
  evaluation) lands in **no members array**, so nothing ever emits its
  synthesized members — yet TypeInfos and instances referencing it sit
  on the rod and would inject dangling references into every later
  link. A referenced instance is keepable iff it is a member of an
  in-link module (collect the member-instance set pre-prune): the
  speculative `Appender!(int[])` lands in **no** members array, so this
  single membership test already excludes it. This surfaced only under
  full-suite `--random` (~200-320 failures, all one cause), never in
  the SystemLinker-only matrix: the polluting instantiations come from
  *other* tests sharing the process.
  **Correction (2026-06-15):** this check originally also required
  `needsCodegen(inst)` to be true, but that over-prunes. A member
  instance is emitted from its members array even when `needsCodegen` is
  false — e.g. `core.lifetime._d_newitemT!(MersenneTwisterEngine!(...))`,
  whose engine-struct argument is reference-pulled into the object by the
  sibling `uniform!(...)` instances that use it, so it is defined though
  `needsCodegen` on it is false. The old `needsCodegen` clause marked
  such an argument foreign and pruned the `_d_newitemT` instance, failing
  `--dub cerealed -b system-linker` at load. Membership alone is the
  criterion; full `--random` stays green without `needsCodegen` (the
  membership test, not `needsCodegen`, is what excluded the speculative
  case all along).

User-import modules must be **promoted to root** (`importedFrom = the
module itself`, like dmd -i's checkCompiledImport) or codegen silently
skips their function bodies (`inNonRoot`, glue package.d:485) — and once
root, they accumulate instances exactly like the rod, so the child
prunes them with the same criterion.

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

### 15. TypeInfos are once-per-process and land on the *creating snippet*, not the rod (slice 2, 2026-06-11)

`getTypeInfoType` (typinf.d:112) appends a freshly created
TypeInfoDeclaration to `sc._module.importedFrom` — and for a **root**
snippet that is the snippet itself, not the rod (importedFrom of a root
module is the module). `genTypeInfo` reports needs-codegen only on
`vtinfo` *creation*, once per process. So when snippet_K's semantic
creates `TypeInfo_xAi` (`const(int[])`), it becomes a member of
snippet_K only; a later snippet using the same type gets the cached
vtinfo, no member append happens anywhere in its link, and its
synthesized `__xtoHash` referencing that TypeInfo fails the `-z defs`
link. Order-dependent: only the 320th-ish fixture in a full matrix run
trips it.

Fix (`adoptTypeInfos`, child-side): walk `Type.stringtable`, push every
cached `vtinfo` for an **aggregate-free** type (builtin compositions
only — no struct/class/enum anywhere in the type) onto the rod's
members, where they emit as COMDATs — duplicate emission across links is
safe, and such TypeInfos reference nothing but other builtin-composition
TypeInfos and druntime vtables. Gates, each one earned:

- aggregate-free only: a TypeInfo involving an aggregate references its
  synthesized members (`__xtoHash`/`__xopEquals`/`__init`), which
  resolve only if the aggregate's declaration or instance emits in this
  link — and then the TypeInfo is already a member of an in-link
  module. Adopting them indiscriminately injected
  `std.array.Appender!(int[]).Data`'s TypeInfo (created by unrelated
  in-process code; that instance's `needsCodegen` is false, so nothing
  ever emits its methods) into every link and failed ~200 random-order
  tests. (Unqualified class TypeInfos are doubly excluded: a standalone
  ClassInfo also hits `assert(0)` in todt.d:1599.)
- skip `builtinTypeInfo` types (typinf.d:94's own gate) — druntime
  exports those;
- skip TypeInfos already members of any module **in this link** —
  emitting the same Dsymbol from two modules in one process trips
  symbol_add's `Ssymnum == SYMIDX.max` assert (same assert as
  lesson 11, different cause).

This is lesson 10's third candidate source surviving fork; the spike
missed it because its fixtures used distinct types, so every TypeInfo
was created (and owned) by the snippet that used it.

### 16. Cross-fixture instance homing: per-fixture dub links are incomplete (2026-06-15)

A template instance is homed on the members of the **first root module**
that instantiates it (its `minst`); a root module's `importedFrom` is
itself, so the instance does **not** funnel to the rod (contrast lesson
8: that funneling is what catches instances from *non-root* imports).
The bench parses every fixture up front and shares one process, so an
instance like `cerealed.decerealiser.Decerealiser.value!int` (a
method-template instance nested in the `Decerealiser` struct) is claimed
by whichever fixture used it first. A *later* fixture compiled as its own
link references the same cached instance, finds it homed on a module not
in that link, and emits nothing — undefined symbol under `-z defs`.

This does **not** affect `--dub <pkg> -b system-linker`: a dub package is
timed as one **grouped** compile (all fixture modules in one link, every
instance in-link), and the single-backend path sets `skipCheck`. It
**does** affect the per-fixture correctness path (`checkRunnerResults`,
used by any multi-backend cross-check), where each fixture is its own
link.

Not yet fixed. A broad static fix (re-home every foreign-module instance
onto the rod in the child, like `adoptTypeInfos`) over-prunes the wrong
way: it adopts instances claimed by *unrelated* fixtures, and the
arg-based foreignness check (lesson 13) cannot see that an
innocent-argument instance's **body** references another fixture's type
(`tests.structs.CustomStruct`, `tests.range.MyInputRange.empty`) — those
go undefined. The robust shape is reference-driven: adopt only the
instances the link actually references, which the linker already computes
(emit, link, parse undefined symbols, adopt the matching foreign
instances, relink to fixpoint — lesson 10's discovery mechanism, applied
to instance homing rather than ELF-symbol ownership). See
`ai/plans/dub-deps.md` "Open: per-fixture completeness".

### 17. Why `3.iota` strands: the codegen walk only visits the roots it is handed (2026-06-17)

Diagnosis session 2026-06-17, "why does `3.iota` fail in `system-linker`
and `llvmjit`". The headline: **the break is not in `needsCodegen`, and
fork is not the problem.** `needsCodegen` returns `true` for the iota
instance; fork faithfully preserves the (already-broken) parent topology.
The defect is one layer below — *where the instance is homed* vs. *which
modules the codegen walk visits*.

Two DMD facts collide:

1. **The codegen walk is rooted at the modules you hand it.**
   `generateCodeAndWrite` only visits the root modules in its argument
   list and walks *their* members (`glue/package.d` `genObjFile` iterates
   `module.members`). An instance is emitted only if it is reachable as a
   member of one of those roots.
2. **A template instance homes onto its *declaring* module's
   `importedFrom` owner — not onto your snippet.**
   `appendToModuleMember` (templatesem.d ~1757–1830), under `allInst`,
   retargets `mi = ti.tempdecl.getModule()` (the **declaring** module,
   e.g. `std.range`, line ~1789), then chases `mi.importedFrom`
   (~1792–1794) and appends the instance to *that* module's members.

In plain `dmd -shared one_file.d` there is exactly one root,
`importedFrom` resolves back to it, the instance lands on it, the walk
visits it, `Result` emits. **The whole scheme silently assumes one root
module per process.** Quickbite has many roots (the rod, every snippet,
*and* every transient cell-classification module — lesson 18), so
`importedFrom` ownership of a phobos module goes to whichever root
imported it first. For `std.range`, that is never the empty rod (it never
imports `std.range`) — so iota's instance homes on a module that is not in
the link set `[snippet, rod]`. Undefined symbol under `-z defs`
(SystemLinker) / ORC lookup failure (LLVMJit).

`allInst` is **not** what's broken: the gate at templatesem.d ~1768 passes
for a root snippet via `minst.isRoot()` regardless; `allInst` only forces
the funnel branch for instances instantiated by *non-root* modules, plus
switches `needsCodegen` to `needsCodegenAllInst` (link-maximizing). The
broken thing is the `importedFrom` *owner*, which lesson 20 fixes.

### 18. Cell-classification parses steal phobos `importedFrom` before the snippet exists (2026-06-17)

The cold trigger. `EvalSession.submit` classifies each REPL line by
*parsing and running `fullSemantic`* on throwaway `eval_cell_N` modules —
`isIncompleteCell`/`isModuleDeclarationCell` (cell.d ~976–1003, ~1162–1182)
go through `parseModuleLocked` (compiler.d ~396–400), which calls
`fullSemantic` on every classification parse. So when the user types
`import std;`, the classification module `eval_cell_0` becomes the **first
root to import `std.range`**, permanently setting
`std.range.importedFrom = eval_cell_0` (first-importer-wins, dsymbolsem.d
~8686 guard `!imp.mod.importedFrom`). The real snippet, synthesized later,
inherits the cached iota instance already homed on `eval_cell_0.members` —
a module in neither object file.

Consequence: `3.iota` fails **cold** — the very first time it is used,
with *no* prior native compilation, purely because a classification parse
ran `fullSemantic` first. (Bare `3.iota` with no import in scope fails at
*semantic* instead — undefined `iota` — not at link; the link failure
needs the phobos import to have happened in a transient module first.)
This is the same `importedFrom`-theft mechanism as lessons 1/2/8, but the
thief is the REPL's own classification probing, not another backend.

### 19. Non-codegen backends: interpreter/VM are read-only; CTFE mutates the parent (2026-06-17)

Audited per the design claim "only the dmd-codegen backends should mutate
`Module` further; if the interpreter or bytecode VM are mutating, we've
done something wrong." Result:

- **Interpreter** (`backends/interpreter/impl.d`) and **bytecode VM**
  (`backends/bytecode/impl.d`): run in-parent (no fork) but are strictly
  **read-only** over the already-analyzed AST. No sema pass, no template
  instantiation, no TypeInfo creation. The only DMD call is
  `dmd.typesem.size` on fully-resolved types — a computed query with no
  side effects. They mutate nothing; the design claim holds for them.
- **CTFE** (`backends/ctfe/dmd_ctfe.d`): runs in-parent and **does**
  mutate shared semantic state. `Ctfe.eval` → `ctfeInterpret` →
  `interpretFunction` → `functionSemantic3` → `semantic3` runs real
  analysis: it instantiates templates (→ `appendToModuleMember`, homing
  onto the rod/snippet), creates TypeInfos (→ `getTypeInfoType`,
  typinf.d ~112 — lesson 15's mechanism), and advances
  `FuncDeclaration.semanticRun` to `semantic3done` process-globally. It
  *must*, to interpret — but it does so in the long-lived parent, at an
  arbitrary point before a later backend's codegen fork snapshots it.

So lesson 1's "CTFE-only runs by other backends" pollution has a concrete
call chain: **a CTFE line mutates the shared instance/TypeInfo topology
that a subsequent native fork inherits.** CTFE is not "doing something
wrong" the way a mutating interpreter would be — semantic3 is intrinsic to
interpretation — but for ownership purposes it must be treated as a
mutator, not a read-only backend, and its ordering relative to codegen
backends matters.

### 20. The rod was *designed* to import everything but never did; the verified fix and its cost (2026-06-17)

History (git + plan archaeology):

- **2026-06-11 14:12 (`6af470b1`)** — the plan specified the rod importing
  `core.internal.dassert` + `core.lifetime` and pre-instantiating the
  built-in-type templates (`alias _lr_int = _d_assert_fail!int`, …), so
  every druntime/phobos instance would be owned by the rod.
- **2026-06-11 ~23:25 (`6ed736db`)** — the code shipped the rod as the
  bare string `"module quickbite_rod;\n"`. **The import design was never
  written.**
- **2026-06-11 23:50 (`601817bd`)** — the spike rationale for dropping the
  imports: *"an empty rod works — every module's semantic pulls in
  `object.d` first, so the import chains bottom out at the rod."*

**That spike conclusion is overgeneralized, and that is the defect.** It
holds only for templates declared in modules the rod transitively pulls in
— `object.d` and the universally-imported `core.*` machinery — for which
`object.importedFrom = rod`. It does **not** hold for phobos: the rod never
imports `std.range`, so `std.range.importedFrom` is not the rod (lesson 17).
The empty rod was validated on the druntime built-in instances the spike
happened to exercise and was never sufficient for phobos Voldemort types.

**Verified fix (rewire the rod to import phobos, e.g. `import std;`).**
Mechanically validated against DMD source end-to-end:

- `import std;` propagates `importedFrom` to `std.range` via a 2-hop chain
  through `std/package.d`'s unconditional `public import`s: rod imports
  `std` → `std.importedFrom = rod`; `std`'s `importAll` then loads each
  submodule with `sc._module = std` (dsymbolsem.d ~8510, ~8538) whose
  `importedFrom` is already the rod → `std.range.importedFrom = rod`
  (assignment at ~8686–8687). Confirmed against the real phobos
  `std/package.d` (publicly imports `std.range`).
- **First-importer-wins is permanent** (the `!imp.mod.importedFrom`
  guard). Parsing the rod first with `import std;` claims phobos
  ownership at init — so it also **kills the classification-theft of
  lesson 18** (no later `eval_cell_N` can steal what the rod already
  owns).
- The iota instance then homes on `rod.members` (templatesem.d ~1789–94),
  `needsCodegen` is `yes` (~3371–72), and the walk visits the rod (it is
  in every link set) → `Result` emits and links.

**The string attached: this completes the funnel, it does not remove it.**
With the rod owning `importedFrom` for all of phobos, every snippet's
phobos instances accumulate on `rod.members` across the whole session
(cross-snippet, unbounded in the long-lived parent). `pruneForeignMembers`
(codegen.d ~259) and `adoptTypeInfos` stay load-bearing — they drop the
cross-snippet junk per-link in the child. So the fix vindicates the
original design and gets `3.iota` working, but it is the opposite of
deleting the red-flag machinery.

**Decision (2026-06-17): fix-now, clean-up-later.** Land the minimal
rod-imports-phobos fix for correctness first (matches the original
design + kills the classification-theft), *then* pursue the ground-up
cleanup (next section). No code was written in the diagnosis session — it
was planning/diagnosis only.

### Next: snippet-owns-its-instances (the cleanup that deletes the machinery)

The funnel (rod + `allInst` + `pruneForeignMembers` + `adoptTypeInfos`) is
all downstream compensation for instances landing on a root the codegen
walk does not visit. The ground-up alternative is to make each snippet
**self-contained**: drive emission from the snippet's own *transitive
instance set* (reference-driven, exactly the fixpoint shape lesson 16 and
`dub-deps.md` arrive at — emit, link, read undefined symbols, adopt the
matching instances, relink) rather than relying on `importedFrom` member
homing to deposit them somewhere a walk happens to reach. If emission is
rooted at what the snippet actually references, instances need not be
funneled to a shared root at all, and `allInst`, the rod, the prune, and
the TypeInfo adoption can all be deleted. This is the "use dmd's backend
on a module that was already parsed and analysed, without the template
problems" goal stated at the top of this session. Scope it as its own
slice; gate it on the same runner matrix.

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

### Slice 2 — fork + lightning rod: delete the custom machinery — DONE (2026-06-11)

Goal: replace the adoption loop, written-state reset walker, and
foreign-member pruning with fork-based codegen isolation and a
lightning-rod module, removing the fresh-parse requirement so cached
modules can be codegen'd.

**Spike results (step 0, all criteria passed first run):** fixtures A
and B linked under `-z defs` and reported the exact
checkaction=context messages (`1 != 2` / `3 != 4`); B was codegen'd
from a stale parse with A's compilation in between; the same AST
re-codegen'd cleanly twice (lesson 7 dissolved by fork); `GC.collect`
and throw/catch worked in every child; growth over 100 fixtures was
flat (rod.o ~22.9 KB constant, emit 3.9→4.3 ms — the prune bounds the
emitted rod even as the parent-side rod accumulates). Negative control:
disabling the prune made even fixture A's link fail with undefined
references to B's class symbols — the prune is load-bearing, the pass
is not vacuous. The fallback rule never triggered. Spike-confirmed
detail: an *empty* rod works — every module's semantic pulls in
`object.d` first, so the import chains bottom out at the rod.

**Implementation deltas vs the step-1 sketch below (see lessons 13/15):**
the prune criterion is link-set based; user-import modules are promoted
to root and pruned too; `adoptTypeInfos` re-homes cached TypeInfos onto
the rod (lesson 15 — the one failure the spike did not predict, found
by the matrix at fixture ~320). Final state: 360 matrix blocks, `-z
defs` clean under repeated `--random` and both historical seeds.

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
(tests/ut/backends/runner/results.d) and closes the prune edge case
where fixtures share an importPaths module.

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
diagnostic / real SIGSEGV). See "Still out of the matrix" above for the
forked-execution decision (2026-06-12): a robustness measure to adopt
on evidence, not a way to promote these blocks.

### Slice 4 — Evaluator interface

Only after the runner matrix is healthy. The live contract is
`Evaluator.eval(FuncDeclaration)` (source/quickbite/backends/evaluator.d:18)
— the single required primitive; `eval(string)`/`eval(Cell)` are final
dispatchers on it. (An earlier draft of this plan said
`eval`/`evalRepl`/`runTestSummary`; that predates the interfaces.md
migration.) Missing pieces: result transport from machine code back to
the host (does not exist; per the 2026-06-12 decision in
`ai/plans/value.md` it is a rendered display string produced in-fixture
by the formatter prelude — see `ai/plans/repl.md` Target Design 5 — not
a `quickbite.lang.Value`), and latency — per-call
compile+link+load is ~43 ms today (lesson 14); benchmark before promoting
anywhere near the REPL hot path (ai/plans/repl.md puts a native session
at step 9 of 9). With slice 2 done the fresh-parse caveat is gone.
There is no loader-swap latency lever (Scope, decision 2026-06-12): if
latency demands more than this pipeline can give, the answer is a new
backend (e.g. LLVM JIT in the `native` package), not a faster loader
inside SystemLinker.

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
- `tests/ut/backends/runner/ct/pollution.d` — the lesson-13 exposing
  test (graduated spike scenario)
- `source/quickbite/backends/evaluator.d` — the live Evaluator interface
  (slice 4)
- `benchmarks/cli.d` — bench harness; correctness gate
  (`checkRunnerResults`)
- dmd (dub, 2.112.0): `templatesem.d` (`appendToModuleMember` :1233,
  `needsCodegen` :2778), `typinf.d` (`getTypeInfoType`),
  `dmd/glue/toobj.d` (`visit(TemplateInstance)` :701, instance emission),
  `dmd/glue/package.d` (`FuncDeclaration_toObjFile` :434 skip guard,
  `generateCodeAndWrite`),
  `core/internal/dassert.d` (`_d_assert_fail` unary :38, binary :63,
  `miniFormat` :176), `core/lifetime.d` (`_d_newThrowable` :2669,
  `_d_newclassT` :2729)
