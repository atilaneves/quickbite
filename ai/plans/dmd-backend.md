# DMD Native Backend: `DynamicLibrary`

> Naming note: the backend has since been renamed `SystemLinker`
> (`source/quickbite/backends/native/system_linker.d`). Mentions of
> `DynamicLibrary` and `dynamic.d` below refer to it.

## Scope

Get the dynamic-library-based dmd backend fully working first. A mini
in-process linker (JITLink-style relocation loading) and ORC JIT are
**completely out of scope** for now: if compile → system link → `dlopen`
cannot be made correct, nothing fancier will be either. Everything here is
about making `DynamicLibrary` pass the whole runner test matrix.

## Current state (2026-06-11, slice 1 done)

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

**Passing:** 336 runner matrix blocks include `SystemLinker` (was 14
before slice 1), each tagged `@Tags(backend.stringof)` so
`bin/ut '~@SystemLinker'` skips them (they are slow: compile+link+load per
test) and `bin/ut @SystemLinker` runs exactly them. The old slice-3 dlsym
miss (`reportsAssertFailureMessages`) is in the matrix and passing.

**Still out of the matrix** (23 blocks), by category:

- **CTFE-flavoured expectations** (compiled code runs fine but reports
  runtime texts; slice-2-style arbitration would change the *expectation*,
  which needs approval): bounds/missing-key/overlapping-slice diagnostics
  (5 in arrays.d, 4 in cerealed.d), `uncaughtThrow*` in exceptions.d
  ("uncaught CTFE exception ..." vs the plain message),
  `delegate.(func)ptrPropertyIsRejectedAtCtfe`,
  `typeid.typeNameReturnsIdentifier` (compiled gives `snippet_N.Widget`,
  CTFE gives `Widget`), `rt.cstdlib.malloc` (runs fine compiled),
  `intToFloatCastUsesFloatPrecision` (its @ShouldFail encodes a
  CTFE-formatter limitation; SystemLinker genuinely passes — needs a
  per-backend ShouldFail split).
- **Slice-2 message texts** (plain `_d_assert`/`_d_unittest` hook texts):
  `literalFalseAssertionMatchesDmd`, `voidFunctionOops`,
  `structMethodReturnDoesNotSkipCallerStatements`,
  `catchExceptionDoesNotCatchAssertFailure`,
  `logicalAndCallShortCircuitFailureMessage.1`.
- **Imported user modules**:
  `runBackend{File,Source}FixtureTests.withImportPaths` — the snippet
  imports a module from importPaths whose functions are compiled nowhere;
  needs multi-object compilation of imported modules.
- **Fatal by design in-process**: the three null-class-dereference
  diagnostics blocks (compiled null deref is a real SIGSEGV that kills the
  test runner) and `voidInitializedScalarReadReportsUninitialized`
  (CTFE-only diagnostic).

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
module and re-emitted.

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

### 10. Adoption loop: undefined ELF symbols are the discovery mechanism (slice 1)

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

### 11. The written-state to reset for re-emission (slice 1 / lesson 7 fix)

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
copy primitives out, so none do today.

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

### Slice 2 — message mismatches (3 tests)

- `literalFalseAssertionMatchesDmd` (`assert(false)`) → backend said
  "unittest failure"; `voidFunctionOops` (`assert(0)` in a called function)
  → "Assertion failure". These are plain druntime `_d_assert`/`_d_unittest`
  hook texts. Per the oracle rule: compile each fixture with real dmd, run
  it, and arbitrate. If real compiled output matches the backend, the *test
  expectation* is CTFE-flavoured and the fixture/expectation needs the
  "runtime-shaped" treatment instead.
- `voidInitializedScalarReadReportsUninitialized` expects a CTFE
  diagnostic ("cannot read uninitialized variable ... in ctfe") that
  compiled code cannot produce — likely permanently CTFE-only; exclude
  deliberately, with a comment.

### Slice 3 — the dlsym miss (1 test) — RESOLVED with slice 1

`reportsAssertFailureMessages` is in the matrix and passing; the miss was
another symptom of the ownership/written-state problem.

### Slice 3b — imported user modules (2 tests)

`withImportPaths` fixtures import a module from importPaths; its functions
are compiled into no object. Compile imported non-druntime modules into
the link as well (walk `module_.aimports` for modules under the given
import paths, emit each, pass all objects to the link).

### Slice 4 — Evaluator interface

Only after the runner matrix is healthy: implement
`eval`/`evalRepl`/`runTestSummary` so `SystemLinker` becomes a full
`Backend`. The fresh-parse requirement still applies (the adoption loop
did not remove it). Per-call compile+link+load latency makes this
unsuitable for the REPL hot path until measured — benchmark before
promoting anywhere. Adopting the fork design (lesson 9) at this point
would remove the fresh-parse requirement and is worth considering then.

## Test discipline

- A backend joins a `static foreach (backend; backendsWith!(...))` block
  only when the test passes repeatedly under `--random` (not just solo) —
  order-dependence is the failure mode here.
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
- dmd (dub, 2.112.0): `templatesem.d` (`appendToModuleMember` :1233,
  `needsCodegen` :2778), `typinf.d` (`getTypeInfoType`),
  `dmd/glue/toobj.d` (`visit(TemplateInstance)` :701, instance emission),
  `dmd/glue/package.d` (`FuncDeclaration_toObjFile` :434 skip guard,
  `generateCodeAndWrite`),
  `core/internal/dassert.d` (`_d_assert_fail` unary :38, binary :63,
  `miniFormat` :176), `core/lifetime.d` (`_d_newThrowable` :2669,
  `_d_newclassT` :2729)
