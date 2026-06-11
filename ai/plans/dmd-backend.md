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
2. `emitObjectFile`: reset codegen written-state (lesson 9), prune foreign
   members, `dmd.glue.generateCodeAndWrite` writes one object file to a
   unique temp dir, then the adoption loop (lesson 8) re-emits until the
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
6. `GC.collect` before `Runtime.unloadLibrary` (lesson 10).

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

- `DynamicLibrary` must only ever codegen a **freshly parsed** module. The
  ut harness does this via a `static if (is(T == DynamicLibrary))` in
  `tests/ut/backends/package.d`. Any future caller (benchmark harness, REPL)
  must do the same — but a fresh parse is *not sufficient* if the same
  source was already parsed earlier in the process; see lesson 6.
- `removeForeignTemplateInstances` in dynamic.d prunes members whose
  `minst`/declaring module isn't this module before codegen — belt and
  braces; it was **not sufficient alone** (adopted instances slipped
  through).
- `global.params.allInst = true` is a trap: it does *not* force re-emission
  of instances already written once per process, but *does* emit foreign
  junk. It was tried and removed.

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

### 7. Codegen of the same module AST twice emits an empty object (2026-06-10)

`generateCodeAndWrite` on a module already codegen'd in this process
writes an object with no function symbols: the glue marks functions as
written and skips them on the second pass. The resulting `.so` links
(nothing is undefined in an empty library) and every `dlsym` then misses,
reported as "unittest symbol not found in shared library: <mangled name>".
This blocks the benchmark's timed loop for `SystemLinker` — 1 warmup +
N iterations means repeatedly codegen'ing the same module. As of
2026-06-10 `bin/bench.sh -b system-linker` passes the correctness check
(first codegen: compile, link, load, run all fixture tests, agree with
ctfe) and skips the timed loop with the message above. Unblocking the
timed loop is Slice-1 territory: the emission bookkeeping that re-homes
foreign instances must also allow re-emission of an already-written
module — a fresh parse per iteration is no escape because of lesson 6.

### 8. Adoption loop: undefined ELF symbols are the discovery mechanism (slice 1)

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

### 9. The written-state to reset for re-emission (slice 1 / lesson 7 fix)

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

### 10. dlclose + GC heap = dangling vptrs (slice 1)

Dead-but-uncollected objects of classes the fixture defines carry vptrs
into the test's `.so`. After `Runtime.unloadLibrary`, ANY later finalizer
sweep (`rt_hasFinalizerInSegment`) dereferences unmapped memory — the
crash surfaces tests later, far from the cause. Fix: `GC.collect` right
before each unload, while the library is still mapped. Fixtures whose
*reachable* objects survive the collect would still be landmines; results
copy primitives out, so none do today.

## The work, in order

### Slice 1 — make template-instance fixtures link — DONE (2026-06-11)

Done on branch `dmd-backend-slice1`; mechanism in lessons 8-10. The sweep
promoted every block that passes; `diagnostics.oops` (the success
criterion) and the rest are stable under `--random` and both repro seeds.
The same reset machinery unblocks repeated codegen of one module
(lesson 7), which the benchmark's timed system-linker loop needs.

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
`eval`/`evalRepl`/`runTestSummary` so `DynamicLibrary` becomes a full
`Backend`. Same fresh-parse requirement applies. Per-call compile+link+load
latency makes this unsuitable for the REPL hot path until measured —
benchmark before promoting anywhere.

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

- `source/quickbite/backends/native/dynamic.d` — the backend
- `source/quickbite/frontend/compiler.d` — uncached parse entry point
- `source/quickbite/frontend/util.d` — index-based unittest walk
- `tests/ut/backends/package.d` — fresh-parse `static if` for SystemLinker
- dmd (dub, 2.112.0): `templatesem.d` (`appendToModuleMember`),
  `typinf.d` (`getTypeInfoType`), `dmd/glue/toobj.d` (instance/TypeInfo
  emission), `dmd/glue/package.d` (`generateCodeAndWrite`)
