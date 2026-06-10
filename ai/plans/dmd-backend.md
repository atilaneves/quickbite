# DMD Native Backend: `DynamicLibrary`

## Scope

Get the dynamic-library-based dmd backend fully working first. A mini
in-process linker (JITLink-style relocation loading) and ORC JIT are
**completely out of scope** for now: if compile → system link → `dlopen`
cannot be made correct, nothing fancier will be either. Everything here is
about making `DynamicLibrary` pass the whole runner test matrix.

## Current state (2026-06-10)

`source/quickbite/backends/native/dynamic.d` implements
`quickbite.backends.runner.Runner.runTests`:

1. Caller parses the module with checkaction=context — **uncached**
   (`parseModuleWithCheckActionContextUncached` in
   `source/quickbite/frontend/compiler.d`; see "Lessons" for why).
2. `emitObjectFile`: `dmd.glue.generateCodeAndWrite` writes one object file
   to a unique temp dir. Backend initialised once per process with
   `PIC.pic`. Runs under the compiler lock.
3. `linkSharedLibrary`: spawns `dmd -shared -defaultlib=libphobos2.so
   -L=-z -L=defs`. `-z defs` deliberately turns every missing symbol into a
   link error instead of a load-time or call-time failure — keep it; it is
   what makes failures diagnosable.
4. `Runtime.loadLibrary` (registers module ctors/GC with host druntime —
   requires the host to link shared druntime).
5. Per unittest: `dlsym(mangleExact(unitTestDecl))`, call, catch `Throwable`.
   Per-test results come from enumerating the AST with
   `foreachUnitTestDeclaration`, not from druntime's `__modtest`.

**Passing:** 14 runner test blocks include `DynamicLibrary`
(logic.d ||/&& fixtures, explicit/dynamic assert messages in diagnostics.d,
4 results.d tests). Each is tagged `@Tags(backend.stringof)` so
`bin/ut '~@DynamicLibrary'` skips them (they are slow: compile+link+load per
test) and `bin/ut @DynamicLibrary` runs exactly them.

**Failing (not in the matrix):** everything else — 93 of the 113 candidate
blocks fail with undefined `_d_assert_fail!T` (or
`_d_newclassT!(AssertError)`) at link time, 3 fail on message mismatches,
1 fails dlsym lookup. Details below; fixing the first category is the core
of this plan.

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
  must do the same.
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

## The work, in order

### Slice 1 — make template-instance fixtures link (the big one)

Success criterion: re-add `DynamicLibrary` to a value-reporting block (e.g.
`diagnostics.oops`, fixture `assert(answer == 43)` needing
`_d_assert_fail!int`) and have it pass **stably under `--random`**, i.e.
also when another compilation in the same process instantiated the template
first. That ordering *is* the exposing test — no new test design needed,
just the matrix line.

Investigation order:

1. **Re-home instead of prune.** In `removeForeignTemplateInstances`'s
   place (or alongside it), find the instances *this* module needs but does
   not own, and force them to be emitted into this object: set
   `minst`/emission bookkeeping so `needsCodegen()` says yes for this
   module. Template symbols are COMDATs, and each test `.so` is an
   independent link, so duplicate emission across objects is safe by
   construction. Read `TemplateInstance.needsCodegen` and the
   instance-emission path in `dmd/glue/toobj.d` first; the answer lives in
   exactly which flag makes the glue skip an already-written instance.
2. **If re-homing one flag isn't enough**, consider compiling the snippet
   in a fresh semantic pass so its instances are genuinely its own — but
   note this collides with quickbite's single long-lived dmd instance and
   the other backends sharing it. Measure before committing.
3. **Fallback (pragmatic, partial):** pre-link a support library exporting
   the common instantiations (`_d_assert_fail!int/!bool/!char/...`,
   `_d_newclassT!AssertError`). Unblocks the assert fixtures but does not
   scale to user templates; only acceptable as a stopgap with the limitation
   documented.

After it works, sweep: re-add `DynamicLibrary` to every previously-failing
block, keep what passes 10+ `--random` runs plus both repro seeds.

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

### Slice 3 — the dlsym miss (1 test)

`reportsAssertFailureMessages` links and loads but
`dlsym(mangleExact(unitTest))` returns null. Undiagnosed. Check whether the
mangled name in the `.so` (`nm -D`) differs from `mangleExact` of the AST
node — likely interaction with how that fixture declares its unittests.

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
- Every kept block carries `@Tags(backend.stringof)` so DynamicLibrary
  variants stay opt-out-able: `bin/ut '~@DynamicLibrary'`.
- Every fault found must pair with a test that exposes it; for ownership
  bugs the exposing test is usually "this fixture, after any other
  compilation, under --random".

## Verification

```sh
ninja -C <build> bin/ut
bin/ut --random                       # repeat; order-dependence is the enemy
bin/ut --random --seed 2828407573     # historical link-failure order
bin/ut --random --seed 3516581215     # historical segfault order
bin/ut @DynamicLibrary                # just the native-backend matrix
./ci.sh
```

## Key reference files

- `source/quickbite/backends/native/dynamic.d` — the backend
- `source/quickbite/frontend/compiler.d` — uncached parse entry point
- `source/quickbite/frontend/util.d` — index-based unittest walk
- `tests/ut/backends/package.d` — fresh-parse `static if` for DynamicLibrary
- dmd (dub, 2.112.0): `templatesem.d` (`appendToModuleMember`),
  `typinf.d` (`getTypeInfoType`), `dmd/glue/toobj.d` (instance/TypeInfo
  emission), `dmd/glue/package.d` (`generateCodeAndWrite`)
