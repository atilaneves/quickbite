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

## Current state (2026-06-11)

`source/quickbite/backends/native/system_linker.d` implements
`quickbite.backends.runner.Runner.runTests`:

1. Caller parses the module with checkaction=context — **uncached**
   (`parseModuleWithCheckActionContextUncached` in
   `source/quickbite/frontend/compiler.d`; see "Lessons" for why). This
   requirement is **superseded** by the lightning-rod + fork design in
   Slice 1 — once that lands the backend can use the normal parse cache.
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
1 fails dlsym lookup. Details below; fixing the first category is Slice 1.

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

- `SystemLinker` currently codegens only a **freshly parsed** module. The
  ut harness enforces this via a `static if (is(T == SystemLinker))` in
  `tests/ut/backends/package.d`. This requirement is **removed** by the
  fork design in Slice 1 — the parent never codegens, so parse-cache reuse
  is safe. Until then, the fresh-parse rule stands.
- `removeForeignTemplateInstances` in system_linker.d prunes members whose
  `minst`/declaring module isn't this module before codegen — belt and
  braces; it was **not sufficient alone** (adopted instances slipped
  through).
- `global.params.allInst = true` is **active** (`compiler.d:178`,
  unconditionally, since the early dynamic-library commits). With allInst
  on, `appendToModuleMember` (`templatesem.d:1233`) always routes non-root
  template instances via `importedFrom` to the first root module parsed.
  This is the mechanism that makes the lightning-rod design work (lesson 8)
  — it is NOT a trap if the first root module is one we control.

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

**This lesson is superseded for `SystemLinker` by the fork design (lesson
9):** the parent's `PASS.obj` / minst state is never set, so every child
sees a fresh emission slate regardless of parse history.

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
repeatedly codegen'ing the same module. As of 2026-06-10
`bin/bench.sh -b system-linker` passes the correctness check (first
codegen: compile, link, load, run all fixture tests, agree with ctfe) and
skips the timed loop with the message above.

**This lesson is dissolved by the fork design (lesson 9):** the parent
never codegens, so every child's module is at `semantic3done` and emits
fully. This unblocks the benchmark timed loop as a side-effect of Slice 1.

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
druntime/phobos instantiation that happens later. This is the mechanism
that the lightning-rod design (Slice 1) deliberately exploits.

### 9. Fork-based codegen isolation is safe and dissolves lessons 6 and 7 (2026-06-11)

`fork()` before `generateCodeAndWrite` gives the child a copy-on-write
snapshot of the full dmd AST and process globals. The child runs codegen,
links the `.so`, writes it to `/tmp`, then `_exit`. The parent's state
— `PASS.obj` marks, `csym` populated by `toSymbol`, ELF segment tables —
is never mutated.

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

**What fork does NOT fix:** `minst` ownership is set during semantic
analysis in the parent. Each child inherits the accumulated instance
topology. The lightning rod (lesson 8) is what ensures druntime/phobos
instances are owned by the right module before the fork.

**Error transport:** the child cannot throw across the fork boundary. Exit
code + an optional pipe for error text; the `.so` path is computed by the
parent before forking. This requires restructuring `emitObjectFile`'s
error handling from exceptions to exit-code + pipe writes in the child.

## The work, in order

### Slice 1 — lightning rod + fork (the big one)

Success criterion: re-add `SystemLinker` to a value-reporting block (e.g.
`diagnostics.oops`, fixture `assert(answer == 43)` needing
`_d_assert_fail!int`) and have it pass **stably under `--random`** including
with both historical repro seeds. As a side-effect the benchmark's timed
system-linker loop should run instead of being skipped.

#### Design

Two cooperating changes eliminate lessons 6 and 7 and fix ownership:

**A. Lightning rod module** — parse a small controlled module as the very
first root module in the process (at the end of `initializeDmdState` in
`compiler.d`). With `allInst=true` already active, `appendToModuleMember`
routes every druntime/phobos lowering template instance via `importedFrom`
into this module's members from that point on. The lightning rod should
contain explicit instantiations for all lowering templates over built-in
types so it becomes the first instantiator and therefore the owner:

```d
// lightning_rod.d (internal, never shown to users)
import core.internal.dassert;
import core.lifetime;
alias _lr_int    = _d_assert_fail!int;
alias _lr_bool   = _d_assert_fail!bool;
alias _lr_char   = _d_assert_fail!char;
// ... ubyte, uint, long, ulong, double, float, string, ubyte[], int[]
```

After this, druntime/phobos instances for built-in types are owned by the
lightning rod; snippet-local types (user structs, user exceptions) are owned
by the snippet that defines them (their `_d_assert_fail!UserType` instance
is first created during that snippet's semantic).

**B. Fork before codegen** — in `compileToSharedLibrary`, compute the `.so`
path, then `fork()`. The child:

1. Generates **two** object files: one for the lightning rod (pruned — see
   below), one for the snippet.
2. Spawns `dmd -shared` linking both into the `.so`.
3. `_exit(0)` on success, `_exit(1)` on failure (write error text to a
   pipe opened before the fork).

The parent waits for the child, reads the pipe if exit ≠ 0, then dlopens
and dlsyms as today. The parent's `PASS.obj` / `csym` / ELF state is
never mutated — lessons 6 and 7 dissolve, uncached-parse requirement
removed, benchmark timed loop unblocked.

**Lightning rod pruning in the child:** the lightning rod's members
accumulate instances over *all* snippets' user types (because
`appendToModuleMember` routes them there via `importedFrom`). Codegen'ing
those instances in the child would pull in TypeInfo from *other* snippets,
creating dangling references under `-z defs`. Prune the lightning rod's
members in the child before codegen: keep only instances whose type
arguments are "globally available" — i.e., every type arg's `getModule()`
returns a non-root module (druntime/phobos) or null. Snippet-defined types
are root modules; they fail this check and are excluded. The current
`removeForeignTemplateInstances` is a related but different filter
(min-ownership-based); replace or extend it.

#### Implementation order

1. Fork only (no lightning rod yet): fork + codegen as today with
   `removeForeignTemplateInstances` in the child. Verify the 14 currently-
   green blocks still pass, verify the benchmark timed loop now runs, verify
   `--random` stability. This validates fork mechanics with no new frontend
   logic and is independently shippable.
2. Add the lightning rod module: parse it in `initializeDmdState`, add the
   explicit aliases. Verify it becomes snippet_0 and takes ownership of
   built-in-type instances (check `minst` in a debug build).
3. Generate the lightning rod object in the child (with pruning), add it to
   the `dmd -shared` invocation. Re-add `SystemLinker` to a single
   value-reporting block (`diagnostics.oops`), confirm it passes under
   `--random` with both repro seeds.
4. Sweep: re-add to every previously-failing block, keep what passes 10+
   `--random` runs.
5. Remove `parseModuleWithCheckActionContextUncached` call in the runner
   path; replace with the normal cached parse. Remove the fresh-parse
   `static if` in `tests/ut/backends/package.d`.

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
`eval`/`evalRepl`/`runTestSummary` so `SystemLinker` becomes a full
`Backend`. No fresh-parse requirement once Slice 1 lands (the fork design
uses the cache). Per-call compile+link+load+fork latency makes this
unsuitable for the REPL hot path until measured — benchmark before
promoting anywhere.

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
bin/ut @DynamicLibrary                # just the native-backend matrix
./ci.sh
```

## Key reference files

- `source/quickbite/backends/native/system_linker.d` — the backend
- `source/quickbite/frontend/compiler.d` — parse cache, `initializeDmdState`
  (lightning rod insertion point at end of this function), `allInst=true` at :178
- `source/quickbite/frontend/util.d` — index-based unittest walk
- `tests/ut/backends/package.d` — fresh-parse `static if` (to be removed in Slice 1 step 5)
- dmd (dub, 2.112.0): `templatesem.d` (`appendToModuleMember` :1233,
  `needsCodegen` :2778), `typinf.d` (`getTypeInfoType`),
  `dmd/glue/toobj.d` (`visit(TemplateInstance)` :701, instance emission),
  `dmd/glue/package.d` (`FuncDeclaration_toObjFile` :434 skip guard,
  `generateCodeAndWrite`),
  `core/internal/dassert.d` (`_d_assert_fail` unary :38, binary :63,
  `miniFormat` :176), `core/lifetime.d` (`_d_newThrowable` :2669,
  `_d_newclassT` :2729)
