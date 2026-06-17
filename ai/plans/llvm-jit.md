# LLVM ORC JIT Native Backend: `LLVMJit`

## Scope

A second native backend that **reuses SystemLinker's object production
verbatim** and replaces only the load step: instead of spawning
`dmd -shared` (~30 ms) and `dlopen`ing the result, link the same `.o`
files in-process with LLVM's ORC JIT. The goal is to kill the ~30 ms
linker spawn that dominates each SystemLinker test (lesson 14 in
`dmd-backend.md`: ~43 ms median per test, ~30 ms of it the link).

This is the separate backend foreseen by `dmd-backend.md` (Scope stage 3
decision 2026-06-12, and Slice 4): "If latency demands more than this
pipeline can give, the answer is a new backend (e.g. LLVM JIT in the
`native` package), not a faster loader inside SystemLinker." SystemLinker
is not touched except to extract the shared codegen path; its loader is
permanent.

POC success criterion: an `rt/` fixture that **passes** and one whose
`assert` **fails with the SystemLinker-matching message** both run
through `LLVMJit`, and the per-test latency is measurably below
SystemLinker's. The eval/`Value` path is out of scope (slice-4 territory,
same as SystemLinker).

> **Shared defect (diagnosed 2026-06-17):** because `LLVMJit` reuses
> SystemLinker's `emitObjectFilesForLink` verbatim, it inherits the
> `3.iota` template-stranding bug — iota's Voldemort `Result` homes on a
> module the codegen walk never visits, so ORC's symbol lookup fails just
> as SystemLinker's `-z defs` link does. Not an LLVMJit bug; full
> mechanism, fix, and cleanup direction in `ai/plans/dmd-backend.md`
> lessons 17–20. Whatever fixes it for SystemLinker fixes it here.

## The one question that decides viability

dmd's `.o` references druntime/phobos symbols and the synthesized
exception machinery. SystemLinker gets full druntime integration for free
because `Runtime.loadLibrary` (dlopen) runs druntime's DSO registry:
`ModuleInfo`, GC scan ranges, module ctors, `.eh_frame`. **ORC will not do
any of that automatically.** The legacy `DmdCodegenRam` loader is the
documented precedent that a loader missing this *cannot pass the matrix*,
because catching an assert `Throwable` requires the unwinder to walk
`.eh_frame` for the generated frames.

So the gate is: **does a `Throwable` thrown inside ORC-linked code unwind
correctly up into the host `catch (Throwable)` in the runner?** This works
only if ORC registers the JIT'd `.eh_frame` (its `EHFrameRegistrationPlugin`
calls `__register_frame` — present with the JITLink `ObjectLinkingLayer`,
*not* guaranteed with the older `RTDyldObjectLinkingLayer`). Everything
else (symbol resolution, calling the function) is routine; this is the
risk. The proof bar is built to fail loudly here rather than ship a
backend that silently can't catch assertion failures.

What we expected *not* to need for the POC: `ModuleInfo`/module-ctor
registration and GC scan-range registration via `_d_dso_registry`. Confirmed
in Step 1 — a unittest that only `assert`s (or even one that GC-allocates and
collects) runs no module ctor and roots no GC memory in its own data segment,
so a no-DSO-registry load suffices. The allocation that *does* happen
(formatting the failing assert) works once weak-symbol interposition is
replicated; see Step 1 for the full root-cause analysis. Running
`_d_dso_registry` is moreover infeasible here (no LLVM 22 C API to run
`.init_array`; the shared-druntime path would crash on JIT mmap'd code) — see
Step 1.

## Why object production needs no new work

SystemLinker's slice-2 machinery (lightning rod, child-side prune,
`adoptTypeInfos`, `-z defs`) exists to make each emitted object
**self-contained**: after it runs, the only undefined symbols are ones
`libphobos2.so` exports. That property is exactly what ORC needs:

- The host `bin/ut` links `-defaultlib=libphobos2.so`, so every such
  undefined symbol is already in the running process. ORC resolves them
  with a process-symbol generator
  (`LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess`).
- Inter-object references (snippet -> instances parked on the rod) resolve
  *within* ORC: add `rod.o`, `snippet.o`, and the imported-module objects
  to the same `JITDylib`; ORC's linker resolves across them. Template
  COMDATs are weak symbols, which JITLink handles.
- `-z defs`'s role (turn missing symbols into a link error, not a
  call-time crash) is served by ORC `lookup` failing loudly when a symbol
  is unresolved.

Therefore `LLVMJit` and `SystemLinker` share the entire fork + emit half
and differ only after the objects exist on disk. Per the clarified import
rule (`AGENTS.md`), both live in `native/` and share this via
package-private code — no duplication, no cross-backend import.

## Object hand-off: easiest viable

Decided: keep writing the `.o` to disk exactly as SystemLinker does. The
fork child already emits to known temp-dir paths via `emitObjectFiles`;
keep that untouched, **drop the `linkSharedLibrary` call**, and `_exit(0)`.
In the parent, read each `.o` with
`LLVMCreateMemoryBufferWithContentsOfFile` and hand it to ORC. The
existing `scope(exit) rmdirRecurse(dir)` cleanup stays; the parent reads
the objects before cleanup, exactly as SystemLinker reads its `.so`.

The disk file is already a working child->parent transport and its bytes
are tiny next to the 30 ms we remove, so memfd/tmpfs/pipe transports are
explicitly *not* POC scope (optimize only if a measurement says the file
read is visible, which it won't be).

## Bindings

Hand-written `extern(C)` declarations for the ~8 ORC-V2 / Core functions
needed — no `llvm-d`/`bindbc` dependency, no LLVM dev headers required
(`libLLVM.so` is installed; we declare the prototypes ourselves):

- `LLVMOrcCreateLLJIT(&jit, builder /*null = host defaults*/)`
- `LLVMOrcLLJITGetMainJITDylib(jit)`
- `LLVMOrcLLJITGetGlobalPrefix(jit)`
- `LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(&gen, prefix,
  filter, ctx)` + `LLVMOrcJITDylibAddGenerator(dylib, gen)`
- `LLVMCreateMemoryBufferWithContentsOfFile(path, &buf, &err)` (Core)
- `LLVMOrcLLJITAddObjectFile(jit, dylib, buf)` (takes buffer ownership)
- `LLVMOrcLLJITLookup(jit, &addr, name)` -> `LLVMErrorRef`, `addr` is a
  `ulong` executor address; cast to `void function()`
- `LLVMOrcDisposeLLJIT(jit)`, `LLVMGetErrorMessage(err)`

On Linux x86-64 ELF the global prefix is empty, so `lookup` takes the dmd
mangled name as-is — the same `mangleExact(unitTest)` SystemLinker passes
to `dlsym`. If the host triple's prefix is non-empty, prepend it.

## The work, in order

### Step 0 — extract the shared codegen path (refactor, no behavior change)

✅ DONE. Extracted the fork + `emitObjectFiles` flow and its prep (rod-root
assertion, user-import promotion, child-side prune, `adoptTypeInfos`) into the
package-private `native/codegen.d` module, exposing `CodegenInputs` and
`string[] emitObjectFilesForLink(Module[], string dir, CodegenInputs)`. The
fork child emits objects to disk and exits; the parent gets the paths back.
`SystemLinker` now calls it and continues with its own `linkSharedLibrary`
(`dmd -shared`) + `loadSharedLibrary` as before. Gate met:
`bin/ut @SystemLinker` (403 tests, 0 failed), `bin/ut --random`, and both
historical seeds (`2828407573`, `3516581215`) all green — behavior preserved.

Pull the fork + `emitObjectFiles` flow (and its prep: rod-root assertion,
user-import promotion, child-side prune, `adoptTypeInfos`) out of
`system_linker.d` into a package-private `native/codegen.d` that returns
the emitted object-file paths to the parent. `SystemLinker` calls it, then
does its `dmd -shared` + `loadSharedLibrary` as today. Gate: full
SystemLinker matrix stays green under `--random` and both historical seeds
(`2828407573`, `3516581215`) — this step must be behavior-preserving.

### Step 1 — minimal end-to-end proof (the gate)

✅ DONE. `native/llvm_orc.d` (hand-written ORC-V2 / Core / Object bindings +
`pragma(lib)`/`libs`) and `native/llvm_jit.d` (`LLVMJit : GroupedRunner`,
no-mode constructor like `SystemLinker` — native is inherently runtime, see
`ai/plans/single-oracle.md`) are stood up. `runTests`:

1. calls `native/codegen.d` to get object paths (child emits, no link);
2. parent: creates LLJIT (null builder → host-default JITLink
   `ObjectLinkingLayer`), adds a process-symbol generator, and for each `.o`
   (rod, snippet, imports) pre-seeds host symbols (see below) then
   `AddObjectFile`s it into the main `JITDylib`;
3. per unittest: `lookup(mangleExact(decl))`, casts to `void function()`,
   calls inside `try/catch (Throwable)` — identical result handling to
   SystemLinker's `runUnitTest`.

**Gate met.** Three proofs, all green under `./bin/ut @LLVMJit`:

- `ehFrameProofNonAllocatingAssert`: a JIT'd `assert(0)` (static-string
  message, no allocation) is caught and byte-matches SystemLinker.
- `failingFixtureMessageMatchesSystemLinker`: `assert(twice(n)==41)`
  (runtime ints) → caught `Throwable`, message `"42 != 41"`, byte-identical
  to SystemLinker's (whose formatting allocates).
- `passingFixtureRuns`: a passing fixture reports PASS.

Full suite green under `--random` (1588 tests, 0 failed) and both historical
seeds `2828407573` / `3516581215`.

#### Open questions, answered

- **JITLink default + automatic eh_frame.** Yes: a null builder
  (`LLVMOrcCreateLLJIT(&jit, null)`) gives the JITLink `ObjectLinkingLayer`
  on this host, whose `EHFrameRegistrationPlugin` calls `__register_frame`
  automatically. No `LLVMOrcLLJITBuilderSetObjectLinkingLayerCreator` was
  needed. Proof: a non-allocating JIT'd `assert(0)` unwinds into the host
  `catch (Throwable)` and byte-matches SystemLinker.
- **Bare `libLLVM.so`.** Present (`/usr/lib/libLLVM.so` → `libLLVM.so.22.1`,
  LLVM 22). The plain `-lLLVM` from `dub.sdl`'s `libs "LLVM"` resolves it.

#### The GC/allocation defect and its real root cause (pulled into Step 1)

The user pulled the GC/DSO-registration work forward from Step 3 because the
failing-assert gate itself allocates (formatting runtime ints via
`_d_assert_fail` → `idup`). Initial symptom: every GC allocation from JIT'd
code returned `"Memory allocation failed"`.

Investigation (readelf/objdump of the emitted objects + gdb of the running
JIT) showed the cause was **not** missing DSO/GC-range registration — the
host GC was always functional (host stacks are scanned normally; a direct
JIT call to host `gc_malloc` succeeds). The cause was **weak-symbol
shadowing**: dmd emits many druntime/phobos template instances and TypeInfos
into the rod object as weak (COMDAT) definitions, and some bodies are
*degenerate stubs* — e.g. `core.checkedint.mulu` in the rod is a 10-byte
`xor eax,eax; … ret` that returns 0, so `__arrayAlloc`'s size computation
collapses to 0 and the array path falls into `onOutOfMemoryError`. The real
bodies live in the host's `libphobos2.so`.

SystemLinker never hits this: it `dmd -shared` + `dlopen`s, and ELF symbol
interposition binds those in-`.so` calls to libphobos2's correct copies
(the host is earlier in the global symbol scope). ORC has no interposition —
a symbol the added object defines (even weakly) is "resolved" within the
`JITDylib`, so the process-symbol generator (which only fills *unresolved*
symbols) never overrides it and the broken stub runs.

**Mechanism implemented (strategy: replicate ELF interposition, not run
`.init_array`).** Before `AddObjectFile`, `defineHostSymbols` parses the
object via the LLVM Object C API (`LLVMCreateBinary` +
`LLVMObjectFileCopySymbolIterator`/`LLVMGetSymbolName`), and for every symbol
name the running process already exports (`dlsym(RTLD_DEFAULT, name)` hits),
defines the host's address as a **weak absolute symbol**
(`LLVMOrcAbsoluteSymbols` + `LLVMOrcJITDylibDefine`,
flags `Exported|Callable|Weak`). ORC then discards the object's weak
definition in favour of ours; a symbol unique to the object (the unittest
function, the module's own `ModuleInfo`) is not in the host, so `dlsym`
misses it and the object keeps providing it. Weak flags mean a strong object
definition, if any, still wins — exactly ELF semantics. No hardcoded symbol
list: the set is derived mechanically from each object's symtab ∩ the
process's exports.

**Why this is sufficient (no `_d_dso_registry` needed for the POC, and why
it can't be run anyway).** The LLVM 22 C API has **no** entry point to run
an added image's `.init_array` / install an ORC platform (no
`LLVMOrcLLJITRunConstructors`/`*Initialize`/`*Platform*`); running it is
C++-only. And running dmd's emitted DSO ctor would crash regardless: with
shared druntime the `version(Shared)` `_d_dso_registry` path calls
`findForAddress`/`handleForAddr`/`getDependencies`, which use
`dl_iterate_phdr`/`dladdr`/`dlopen(RTLD_NOLOAD)` to locate the image in the
dynamic loader's link map — JIT'd code lives in anonymous `mmap`, has no
link-map entry, and would fail those `safeAssert`s. For the gate fixtures
none of that is needed: the host GC works, JIT'd frames unwind, and the
fixtures root no GC pointers in their own data segment and run no module
ctor. Verified beyond the gate with a throwaway probe (not committed): JIT'd
code does `new int[](5)`, fills it, runs `GC.collect`, and reads back the
correct sum — allocation and a mid-test collection both behave.

### Step 2 — promote into the matrix

✅ DONE. `LLVMJit` is re-exported through `native/package.d` (reachable from
test modules via `import ut.backends;`, no change needed in
`tests/ut/backends/package.d`). It is promoted alongside `SystemLinker` (its
single behaviour oracle) — pre-approved per `AGENTS.md` — in the
`@Tags(backend.stringof)` `rt/` block carrying it, so `LLVMJit` is opt-out-able
exactly like `SystemLinker`.

The original four promotion targets (`rt/{control_flow,exceptions,expressions,
logic}.d`) no longer exist: master's single-oracle migration
(`ai/plans/single-oracle.md`) moved every language-surface `rt/` module into
`ct/`, redefining `rt/` as behaviour that needs the runtime environment.
`LLVMJit` is an `rt/` backend (oracle = `SystemLinker`) and must not appear in
`ct/` blocks, so after the merge it is promoted into the only surviving `rt/`
SystemLinker-oracle block:

- `tests/ut/backends/runner/rt/cstdlib.d` — the `malloc.` block (a real
  runtime libc `malloc` call through the in-process JIT).

The Step 1 gate proofs in `tests/ut/backends/runner/rt/llvm_jit.d`
(`passingFixtureRuns`, `failingFixtureMessageMatchesSystemLinker`,
`ehFrameProofNonAllocatingAssert`) remain `LLVMJit`-tagged and provide the
core matrix coverage.

Gate met: `./bin/ut -l` shows the `LLVMJit` instances; `./bin/ut @LLVMJit`
green solo, `./bin/ut @SystemLinker` still green, and `./bin/ut --random` plus
both historical seeds (`2828407573`, `3516581215`) all green.

### Step 3 — measure (GC registration already resolved in Step 1) ✅ DONE

**POC success criterion MET: `LLVMJit` per-test latency is ~5–7× below
`SystemLinker`'s.** Killing the ~30 ms `dmd -shared` link spawn is exactly
the win the plan predicted.

**Method.** A throwaway probe (`tests/ut/zzz_bench_probe.d`, not committed)
drove the real benchmark harness (`benchmarks.harness.measure`: 2 warmup +
21 timed iterations, GC disabled during the timed loop, single-sample
median) over the four single-unittest fixtures below, calling each backend's
`runTests` on the *same* parsed `Module` so only the post-parse load path is
timed. One fixture per measurement ⇒ median per-fixture == median per-test.
Each backend confirmed PASS before timing. Two full repeats; numbers stable.

Fixtures: (0) passing `twice()` int assert (the Step 1 passing fixture);
(1) `cast(float)` precision (`rt/expressions.d`); (2) delegate `funcptr`
(`rt/expressions.d`); (3) a GC-allocating fixture (`int[] ~= …` 1000×, read
back) — the deferred GC probe.

Median per-test latency (two runs; governor `powersave`, LLVM 22):

| fixture | SystemLinker median | LLVMJit median | speedup |
|---------|---------------------|----------------|---------|
| 0 twice() assert     | 35.1 / 34.9 ms | 5.0 / 4.8 ms | ~7.0× |
| 1 float cast         | 35.6 / 34.0 ms | 5.8 / 6.2 ms | ~5.8× |
| 2 delegate funcptr   | 33.5 / 50.7 ms | 7.0 / 7.2 ms | ~5–7× |
| 3 GC-allocating      | 38.2 / 45.5 ms | 7.5 / 8.6 ms | ~5.1× |

SystemLinker sits at ~33–51 ms/test (the documented ~30 ms link spawn plus
codegen); LLVMJit at ~5–9 ms/test. The win holds across all four fixtures.

**GC-stress probe: no misbehavior observed.** The GC-allocating fixture (3)
passed on *both* backends and was timed cleanly — no GC-range/DSO-registration
defect surfaced, consistent with Step 1's finding that allocation from JIT'd
code works once weak-symbol interposition is replicated. Per the
adopt-on-evidence rule, **no speculative GC-stress matrix test was added.**

**`ci.sh` result.** Green except for one pre-existing, unrelated REPL test
failure: `tests/run_repl.py::test_interactive_error_label_is_red` expects the
old `<repl>(1)` label, but the REPL now emits `<repl cell 1>(1)`. Master fixed
the expectation in commit `c9f5b9f3` ("Update REPL CLI diagnostic
expectation"), which is **not on this branch** (it post-dates the merge-base
`45f0ee48`). It is a stale test expectation, not a Step 3 regression; left
unchanged because fixing it is out of scope and changing a test needs
approval. All other ci.sh steps pass: `bin/ut` (1597 tests, 0 failed, 4/4
expected failures), `tests/example.d`, `bin/bench`, `bin/qb`, and the other
14 REPL tests.

## Step 4 — promote the full SystemLinker matrix to LLVMJit ✅ DONE (with a documented residual)

**Goal.** Promote every `SystemLinker`-tagged matrix block to also run on
`LLVMJit`. `SystemLinker` is `LLVMJit`'s single behaviour oracle
(`ai/plans/single-oracle.md`), so this is pre-approved per `AGENTS.md`
("Promoting an already-existing backend-matrix test to another backend is
pre-approved when the test is backed by that oracle"). `LLVMJit` reuses
`SystemLinker`'s object production verbatim and differs only in the load step,
so in principle it should pass everything `SystemLinker` passes. The `ct/`/`rt/`
split is by *what the behaviour needs*, not by backend — `SystemLinker` (also a
native runtime backend) appears throughout `ct/`, so `LLVMJit` belongs there
too; the earlier "LLVMJit must not appear in `ct/` blocks" note from Step 2 was
over-conservative and is superseded here.

**Outcome.** The cumulative-segfault blocker is **fixed** (see "The fork fix"
below): `LLVMJit` is now promoted alongside `SystemLinker` in every
SystemLinker-oracle matrix block across `ct/{arrays,cerealed,control_flow,
diagnostics,exceptions,expressions,integrals,logic,math,pollution,structs}.d`
and `results.d` — including the `AliasSeq!(SystemLinker)`-only characterization
blocks, whose assertion/diagnostic text `LLVMJit` reproduces byte-for-byte. Two
sets are *not* promoted: `ct/archive.d` (structurally unsupported, below) and
**5 array fixtures** that hit a second, distinct backend defect (the duplicate-
undefined-symbol issue, below). Result: `bin/ut @LLVMJit` is 395/0; the full
`bin/ut` is 2021/0 and **stable** across `--random` (5 runs) and both historical
seeds (`2828407573`, `3516581215`).

### The fork fix (resolves the cumulative dangling-metadata segfault)

The original blocker: `LLVMJit.runTests` ran one
create→load→execute→`LLVMOrcDisposeLLJIT` cycle per fixture *in the long-lived
parent*. Disposal `munmap`s the JIT code/data while GC-heap objects created
during the test (user `ClassInfo`/vtables, the module's own `TypeInfo`,
Throwable subtypes — metadata unique to the JIT object, which weak-symbol
interposition does not redirect to the host) are still live and point into that
memory. A later collection (or the `gc_term` teardown sweep) dereferenced a
dangling `ClassInfo`/vtable and crashed (`bin/ut` exit 139, no summary).

The fix, as foreseen: **run the whole `runTests` create→load→execute cycle in a
forked child that `_exit`s when done** (`runTestsInChild` in
`native/llvm_jit.d`). The long-lived parent never touches LLVM, never executes
JIT code, never GC-allocates JIT-resident metadata, and never outlives a
disposed LLJIT. The child builds the JIT, runs the unittests, writes a
length-prefixed result frame (per-test pass/fail + name + location + message, or
an error frame for an infrastructure failure) over a pipe, and `_exit`s — taking
all JIT-tainted heap and eh_frame state with it. The child does **not** call
`LLVMOrcDisposeLLJIT`: `_exit` reclaims the mapping without the munmap-then-
collect that caused the crash. This mirrors the codegen fork the child itself
then performs (`native/codegen.d`). Cost: one extra `fork`+IPC per `runTests`
group, cheap next to the codegen child already spawned and far below the
`dmd -shared` spawn this backend exists to kill. `disposeJit` was removed.

(Rejected alternatives, unchanged: manual `__deregister_frame` — deregistration
already happens and is balanced, and does not touch the live GC survivors; never
disposing the LLJIT in the long-lived parent — leaks unbounded and still risks a
mid-run collect.)

### Not promotable at all — `ct/archive.d`

`runTests.archiveBackedImport*` constructs `new backend([archivePath],
[importPath])`, i.e. the `SystemLinker(string[] linkFiles, string[]
importPaths)` constructor. `LLVMJitInputs` has **no `linkFiles` field** and the
ORC loader resolves only druntime/phobos *process* symbols, not external `.a`
archive symbols (an explicit non-goal in `LLVMJitInputs`' comment). Archive
linking through the in-process JIT is unimplemented; this test cannot compile
under `LLVMJit`. Left unpromoted, unchanged.

### Residual defect — duplicate undefined symbol → JITLink resolves it to 0

Five array fixtures crash their JIT child even after the fork fix, due to a
**second, distinct** backend defect (the fork fix newly *exposes* it — it was
previously masked by the cumulative segfault). They are excluded from `LLVMJit`
(each block carries a one-line comment pointing here):

- `ct/arrays.d`: `dynamicArray.lengthAssignmentResizesArray`,
  `dynamicArray.nestedSliceAppendKeepsOriginalArrayTail`,
  `dynamicArray.jaggedRowsKeepIndependentLengths`
- `ct/cerealed.d`: `projects.cerealed.protocolUnitLengthFieldRoundTrip`
- `ct/control_flow.d`: `foreach.reverseIntArrayVisitsBackToFront`

**Root cause** (gdb on the built binary + `readelf`/`objdump` of the emitted
objects): under accumulated process-global DMD state, dmd emits the rod object
with a **duplicate undefined symbol** — e.g. `gc_expandArrayUsed` appears
*twice* as `UND GLOBAL` in one `.o` (the alone, passing case has it once). When
the JIT'd array-append worker (`_d_arrayappendcTX_`) calls `gc_expandArrayUsed`
via the PLT/GOT, **JITLink resolves the extra symbol's GOT slot to `0`** and the
JIT'd code calls a null pointer (`rip = 0x0`, faulting `call` goes through a GOT
slot holding 0, while the symbol *does* otherwise resolve via `LLVMOrcLLJITLookup`).
GNU ld (SystemLinker's `dmd -shared`) coalesces duplicate undefined symbols by
name and never hits this — same shared codegen, identical object bytes, only the
loader differs.

This is **codegen-deterministic, not GC-timing-dependent**, so unlike the
original crash it does **not** scatter under `--random`: across 6 full-suite
orderings (3 random + 2 fixed seeds + the no-seed default) exactly the same
single fixture (`jaggedRows...`) surfaced beyond the four found in the
`@LLVMJit`-only run. The full suite is maximum accumulation, so the excluded set
is stable.

Levers ruled out (none fix it; documented so a future attempt does not repeat
them): deduplicating the names fed to `LLVMOrcAbsoluteSymbols` in
`defineHostSymbols` (the duplicate is in the *object's* symtab, not our map);
defining the host interposition as a strong rather than weak absolute (breaks
the legitimate cross-object duplicate-weak dedup with "duplicate definition"
errors). A robust fix needs either ELF symtab/relocation surgery on the object
buffer before `LLVMOrcLLJITAddObjectFile` (coalesce duplicate undefined globals)
or a dmd codegen change (which touches the SystemLinker-shared path) — both out
of scope here; the affected fixtures stay on `SystemLinker` only.

### Reproduction

```sh
bin/ut @LLVMJit                 # 395/0 — promoted matrix is green in isolation
bin/ut                          # 2021/0 — full suite green, stable under --random
bin/ut --random --seed 2828407573
bin/ut --random --seed 3516581215
```

## Build wiring

Add `libs "LLVM"` to the `unittest` config in `dub.sdl`. Step 3 found it is
also required for the `benchmark` and `qb` configs: both link the `native`
package via `source/`, and that package re-exports `LLVMJit` unconditionally,
so the ORC symbols are referenced even though the bench and REPL never select
the backend. Without it, `ci.sh`'s `bin/bench.sh` and `ninja bin/qb` steps
fail to link (undefined `LLVMOrc*` symbols). The bare `libLLVM.so` symlink is
present (→ `libLLVM.so.22.1`), so plain `-lLLVM` resolves it; if only the
versioned runtime were installed, link the soname explicitly
(`lflags "-L-l:libLLVM.so.22.1"` or a full path). Regenerate with `dub run
reggae --compiler=ldc -- -b ninja`.

## Verification

```sh
ninja -C <build> bin/ut
bin/ut --random                       # repeat; order-dependence is the enemy
bin/ut --random --seed 2828407573     # historical link-failure order
bin/ut --random --seed 3516581215     # historical segfault order
bin/ut @SystemLinker                # shared codegen path unchanged (Step 0)
bin/ut @LLVMJit                     # the new backend's matrix blocks
./ci.sh                               # includes the latency bench row
```

## Open questions to settle in Step 1

- Does LLJIT default to the JITLink `ObjectLinkingLayer` on this host (the
  one with automatic eh_frame registration), or must we force it via
  `LLVMOrcLLJITBuilderSetObjectLinkingLayerCreator`? This is the first
  thing to determine empirically.
- Does the installed `libLLVM.so` expose a linkable bare soname, or only
  the versioned one?

## Key reference files

- `source/quickbite/backends/native/system_linker.d` — the loader to
  fork-and-emit out of (Step 0) and the `runUnitTest` shape to mirror
- `source/quickbite/backends/native/package.d` — re-export point for both
  backends
- `source/quickbite/backends/runner.d` — `GroupedRunner`
- `tests/ut/backends/package.d` — `newBackend`, backend exports
- `ai/plans/dmd-backend.md` — Scope stage 3 (load in parent) and the
  `DmdCodegenRam` druntime-registration warning (the central risk here)
