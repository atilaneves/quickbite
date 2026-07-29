# LLVM ORC JIT Native Backend: `LLVMJit`

## Current state / next action

The backend works and is promoted alongside `SystemLinker` across the whole
`SystemLinker`-oracle matrix, including `lang/archive.d` archive-backed imports.
Archive link files are split by shape: shared images are still `dlopen`'d into
the process, while static archives are attached to the ORC object layer with
`LLVMOrcCreateStaticLibrarySearchGeneratorForPath` and lazily searched for
referenced members. The duplicate-`UND`-symbol → zero-GOT-stub defect is fixed
by the ELF normalizer. `bin/ut @LLVMJit` and the full `bin/ut --random` are
green (0 failed is the invariant; totals rot and are deliberately not
recorded in this file).

Everything below is kept as an outcome log; the interposition (Step 1), fork
fix (Step 4), and ELF normalizer writeups are the load-bearing history. Original
goal was a POC viability gate; that was met at Step 1/3 and the goal has since
moved to full-matrix + benchmark parity.

**Agent entry point.** The critique execution plan (slices A→F) and parity
slices 1–4 are ✅ done: the full SystemLinker-oracle matrix runs `LLVMJit`, the
LDC-built bench runs it via the `bench-exec` ORC path, and the
`backends/ffi/dependency_image.d` `--random` isolation flake is fixed with
per-backend unique module names (see Slice 4, 2026-07-14). The only remaining
work is two **upstream JITLink minimal repros** (duplicate-`UND` zero-GOT-stub;
hidden-weak `DW.ref.*` cross-graph externalization, both worked around in
`orc/elf.d`, neither filed). Two unrelated pre-existing suite flakes surfaced
during the Slice 4 gate (environmental `liblto_plugin.so`; a Bytecode
`cerealed` flake) — neither is LLVMJit's, both out of scope here.

## Scope

(Provenance: a hand-written in-memory linker was explored as the alternative
load step and rejected — ELF linking semantics are too deep to re-implement;
JITLink/ORC is battle-tested and already solves it, including static archives.
That conclusion, from the deleted `mini-linker.md` exploration, is settled:
do not revisit hand-rolling a linker.)

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

> **Postmortem (after Steps 1 & 4):** this predicted risk came back YES
> immediately and cheaply — a null builder gave automatic `__register_frame`
> with no work. The risks that actually consumed the project were all
> *emergent* and none were foreseen here: weak-symbol stub shadowing (Step 1),
> the dispose-then-collect segfault (Step 4 fork fix), and the duplicate-`UND`
> zero-GOT-stub (Step 4 residual / Next fix). Calibrate accordingly: the scary
> upfront unwinding question was not where the bodies were buried.

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
`ct/` blocks (**superseded in Step 4 — this was over-conservative; `LLVMJit`
belongs in `ct/` wherever `SystemLinker` does**), so after the merge it is
promoted into the only surviving `rt/` SystemLinker-oracle block:

- `tests/ut/backends/runner/rt/cstdlib.d` — the `malloc.` block (a real
  runtime libc `malloc` call through the in-process JIT).

The Step 1 gate proofs in `tests/ut/backends/native/llvm_jit.d`
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
Each backend confirmed PASS before timing. Two full repeats; the *gap* is
stable. Per-run SystemLinker timings swing up to ~50% under `powersave`
(fixture 2: 33.5 vs 50.7 ms) — well inside the 5–7× margin, but the
absolute numbers are noisy, not the speedup.

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

## Step 4 — full SystemLinker matrix promotion ✅ DONE

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

### Archive-backed imports DONE

`runTests.archiveBackedImportLinksFromArchive` is promoted to `LLVMJit`. The
`SystemLinker(string[] linkFiles, string[] importPaths)` constructor shape is
mirrored: `.so` link files remain cold dependency images loaded with
`dlopen(RTLD_GLOBAL)`, and non-`.so` link files are treated as static archives.
Each static archive installs an ORC static-library search generator on the
LLJIT object layer, so only referenced archive members are linked into the main
`JITDylib`.

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
slot holding 0, while the symbol *does* otherwise resolve via
`LLVMOrcLLJITLookup`).
GNU ld (SystemLinker's `dmd -shared`) coalesces duplicate undefined symbols by
name and never hits this — same shared codegen, identical object bytes, only the
loader differs.

Caveat: "under accumulated process-global DMD state" is *when* the duplicate
appears, not *why*. The mechanism by which accumulated dmd state writes the same
`UND GLOBAL` to the symtab twice is uncharacterized. So the normalizer below is
a **defense against an uncharacterized emitter**, not a fix for a known one —
which is why it ships with a "reject unsupported shapes" guard rather than
assuming the only malformation is duplicate `UND` (accumulated state could in
principle produce others). Duplicate `UND GLOBAL` is valid ELF that ld
coalesces, so the standards-conformant reading is that **JITLink is strict
where ld is lenient** — i.e. this is plausibly an upstream JITLink bug worth a
minimal repro + report, with the in-loader normalizer as the bridge we control.

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
errors). The fix below uses ELF symtab/relocation surgery on the object buffer
before `LLVMOrcLLJITAddObjectFile`.

### Duplicate undefined ELF normalizer ✅ DONE

`bin/bench.sh --dub cerealed -b llvmjit` exposed the same defect at package
scale. The JIT child crashed in JIT'd
`core.internal.array.capacity._d_arrayshrinkfitH!(ubyte[], ubyte)`: the object
called `gc_shrinkArrayUsed`, ORC created an indirect stub for that call, and the
stub's GOT slot contained `0`, so execution jumped to address zero. The symbol
was present in the benchmark process, and `SystemLinker` passed the same
package (`156/156`), so this was another duplicate-undefined-global instance,
not a cerealed or shared-codegen failure.

Layer decision (which of three fixes): (a) **fix dmd codegen** to not emit the
duplicate — touches the `SystemLinker`-shared path, and the cause is
uncharacterized (above), so high-risk for the whole backend family; (b) **wait
on an upstream JITLink fix** — not actionable on our timeline, and unconfirmed
as a bug; (c) **normalize the object in our loader** before `AddObjectFile` —
contained to `LLVMJit`, deterministic, reversible. We picked (c) as the bridge
and should still file the upstream repro for (b) — **this plan's one open
item (2026-07-06): build a minimal two-duplicate-UND-symbol object repro and
file it against JITLink; unowned until a session picks it up**. Revisit (a)
only if the
normalizer proves insufficient or the uncharacterized emitter starts producing
other malformations.

Implementation approach decision (given (c), D vs C++): keep this PR D-only.
The normalizer is Quickbite-owned backend code, not a new build-system feature.
Investigation of calling LLVM's C++ ELF reader found it would reduce some
parsing boilerplate but would not remove the byte patching: LLVM exposes
relocations over the object's bytes, and the shim would still have to compute
the `r_info` offset and mutate the buffer. It would also add a new C++
compile/link path that this repo does not currently have: `dub.sdl` and the
generated Reggae/Ninja build only compile D sources for Quickbite, and a Dub
mixed-source probe rejected `.cpp` source files. The LLVM C object API is
read-oriented here and has no relocation symbol-index setter. A C++ shim is
worth revisiting only if Quickbite grows first-class C++ build support or the
ELF helper expands beyond this narrow normalization job.

Fixed in the loader, not with a GC-symbol list. `orc/elf.d` (originally
`native/elf.d`; moved by parity slice 2) parses the
Quickbite-supported object shape (little-endian ELF64 `ET_REL`, one
`SHT_SYMTAB`, `SHT_RELA` relocation sections), coalesces duplicate
`UND GLOBAL` symbol-table entries by name, and rewrites relocation `r_info`
symbol indices to the first canonical entry. It leaves section-local, defined,
weak-COMDAT, and file symbols untouched, and keeps `defineHostSymbols`
conceptually separate: host-symbol interposition still handles weak
druntime/phobos definitions, while the ELF normalizer handles duplicate
undefined globals that JITLink would otherwise lower to zero-valued stubs.

The previously excluded fixtures are promoted to `LLVMJit`, and focused
minimal-object tests cover the relocation rewrite and the no-duplicate no-op
case. The orphan duplicate `UND` entry can remain in the symbol table:
redirecting all relocations away from it is sufficient; JITLink does not
materialize a zero-valued call stub for an unreferenced undefined symbol.

Verified:

```sh
ninja bin/ut
bin/ut
bin/ut --random
bin/ut --random --seed 2828407573
bin/ut --random --seed 3516581215
bin/ut @LLVMJit
bin/bench.sh --dub cerealed -b llvmjit
bin/bench.sh --dub cerealed -b system-linker
```

`cerealed llvmjit` now reports a timed `156/156` row instead of
`JIT child died`, and the implementation remains mechanically derived from ELF
symbol tables and relocations rather than hardcoded runtime symbol names.

### Reproduction

```sh
bin/ut @LLVMJit                 # full promoted LLVMJit matrix — 0 failed
bin/ut                          # full suite — 0 failed
bin/ut --random
bin/ut --random --seed 2828407573
bin/ut --random --seed 3516581215
```

## Build wiring

Add `libs "LLVM"` to the `unittest` config in `dub.sdl`. Step 3 found it is
also required for the `benchmark` and `qb` configs: both link the `native`
package via `source/`, and that package re-exports `LLVMJit` unconditionally,
so the ORC symbols are referenced even though the bench and REPL never select
the backend. Without it, `ci.sh`'s `bin/bench.sh` and `ninja bin/qb` steps
fail to link (undefined `LLVMOrc*` symbols). Locally, the global bare
`libLLVM.so` symlink may let the canonical plain `-lLLVM` resolve it; LLVM 21
is the minimum supported version. Ubuntu CI installs pinned LLVM 21.1.8 into
the runner temporary directory and exports its `lib` directory for both link
and runtime lookup. Regenerate with
`dub run reggae --compiler=ldc -- -b ninja`.

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

## Open questions from Step 1 — both answered

- LLJIT defaults to the JITLink `ObjectLinkingLayer` on this host (null
  builder), so eh_frame registers automatically — no
  `LLVMOrcLLJITBuilderSetObjectLinkingLayerCreator` needed. See Step 1.
- The installed `libLLVM.so` exposes a linkable bare soname (`-lLLVM`
  resolves it). See Step 1 / Build wiring.

## Key reference files

- `source/quickbite/backends/native/system_linker.d` — the loader to
  fork-and-emit out of (Step 0) and the `runUnitTest` shape to mirror
- `source/quickbite/backends/native/package.d` — re-export point for both
  backends
- `source/quickbite/backends/runner.d` — `GroupedRunner`
- `tests/ut/backends/package.d` — `newBackend`, backend exports
- `ai/plans/dmd-backend.md` — Scope stage 3 (load in parent) and the
  `DmdCodegenRam` druntime-registration warning (the central risk here)

# SystemLinker-peer parity plan (2026-07-06)

Everything above is the outcome log of the original POC-to-matrix plan. This
section is a live plan: make `LLVMJit` a full `SystemLinker` peer. Today it is
not one in two ways:

1. **The LDC-built bench cannot run it at all.** `makeRunners` in
   `benchmarks/backends.d` skips constructing the runner under
   `version (LDC)` (the constructor `dlopen`s DMD-compiled dependency images
   whose module ctors would execute DMD-codegen'd code against the LDC host's
   druntime), and `withoutUnavailableBackends` in `benchmarks/cli.d` filters
   it from the defaults / rejects an
   explicit `-b llvmjit`. `bench.md` records this as "Phase 2′'s LLVMJit
   clause is intentionally not met". Since `bin/bench.sh` builds the host
   with LDC (commit `84650dbe`), the standard benchmark path cannot measure
   the backend whose whole point is latency.
2. **Two `rt/` matrix gaps.** ✅ RESOLVED by slice 1: `malloc.pointerRoundTrip`
   (`rt/cstdlib.d`) and the inline-asm rejection pin
   (`backends/native/inline_asm.d`) both run `LLVMJit` now. (Broader matrix
   gaps found later are slice E of the critique execution plan.)

## Design: extend the executor model, don't fight it

The `bench-exec` process boundary exists because DMD-codegen'd code cannot
execute in an LDC host (ABI/EH). `SystemLinker` crosses it by handing a `.so`
to the DMD-built `bench-exec`. `LLVMJit` has no `.so` — so hand over the
*object files* and let `bench-exec` do the ORC link in-process.

This works because the frontend/frontend-free split inside `llvm_jit.d` is
already clean. Frontend-dependent stages: codegen
(`emitObjectFilesForLink`, `codegen.d`) and unittest discovery + mangling
(`foreachUnitTestDeclaration`, `dmd.mangle.mangleExact`) — both of which the
LDC host already performs for `SystemLinker`'s executor path
(`runTestsViaExecutor` in `system_linker.d`). Frontend-free stages: X86
target init, LLJIT creation, process-symbol + static-library generators, ELF
duplicate-`UND` normalization (`orc/elf.d`), host-symbol interposition
(`defineHostSymbols`, `orc/loader.d`), object addition, symbol lookup,
execution, and result encoding — all operate on file paths, C strings, and
addresses only (slice 2 completed this extraction into `orc/`).

So: extract the frontend-free half into a loader that `bench-exec` (DMD-built,
no dmd-frontend imports, matching druntime) can compile, extend the
`run_wire.d` request with an ORC mode, and un-gate the bench CLI. A fresh
`bench-exec` process per `runTests` preserves the PR #243 isolation property
(JIT-resident metadata dies with the process) by construction.

Timing semantics stay honest: the `llvmjit` LDC row measures codegen + exec of
`bench-exec` + dep-image `dlopen` + in-process ORC link + run; the
`system-linker` row already pays the same executor spawn and image `dlopen`
plus the `dmd -shared` spawn/link. The cross-backend delta therefore still
isolates link strategy, which is the quantity of interest. The DMD-host bench
config keeps the pure in-process number. `testResultsMismatch`
(`benchmarks/cli.d`) is backend-agnostic and covers `llvmjit`
automatically once the runner is constructed.

## Slices

### Slice 1: `bin/ut` matrix parity (pre-approved promotions) ✅ DONE

Both promotions are in the tree: `malloc.pointerRoundTrip` (`rt/cstdlib.d`)
runs `AliasSeq!(Interpreter, SystemLinker, LLVMJit)` and the inline-asm
rejection pin (`backends/native/inline_asm.d`) runs
`AliasSeq!(SystemLinker, LLVMJit)` with the shared-codegen comment.

### Slice 2: extract the frontend-free ORC loader (pure refactor) ✅ DONE

Landed as commit `65f4a82e`: `orc/bindings.d`, `orc/elf.d`, `orc/loader.d`
exist as designed below; `bin/ut @LLVMJit` unchanged, `--random` + historical
seeds green.

Original design (kept for reference):

- New top-level `orc/` source directory (module namespace `orc.*`), following
  the `bench-exec/run_wire.d` shared-module precedent:
  - `orc/bindings.d` — moved from `backends/native/llvm_orc.d` (extern(C)
    decls only, already frontend-free).
  - `orc/elf.d` — moved from `backends/native/elf.d`.
  - `orc/loader.d` — new: create LLJIT + generators, normalize + interpose +
    add objects, look up mangled names, run, catch `Throwable`, return plain
    results. Input is plain data: object paths, archive paths, mangled test
    symbols (dep images are the caller's job to `dlopen`).
- `llvm_jit.d` keeps codegen, discovery/mangling, fork/pipe, and calls the
  loader. No `dmd.*` import may appear under `orc/`.
- Build wiring: add `orc` to `sourcePaths`/`importPaths` of the configs that
  compile the native package (unittest, benchmark, qb — they already link
  `libs "LLVM"`).
- The focused ELF normalizer tests change imports only, not behaviour. No new
  tests.
- Verify: `ninja bin/ut`, `bin/ut @LLVMJit` (0 failed, unchanged),
  `bin/ut --random` + historical seeds `2828407573`, `3516581215`.

### Slice 3: `bench-exec` ORC mode + un-gate the LDC bench

- `bench-exec/run_wire.d`: `RunRequest` gains a `kind`
  (`sharedLibrary` | `orcObjects`), `objectFiles` (string[]) and `archives`
  (string[]) fields. Both ends build from the same source in the same repo
  state; no wire compatibility shims.
- `bench-exec` subPackage: add `sourcePaths`/`importPaths` `"orc"` and
  `libs "LLVM" platform="linux"` (the subPackage block in `dub.sdl`);
  `main.d` dispatches on
  `kind` — `orcObjects` = `dlopen` dep images `RTLD_NOW | RTLD_GLOBAL`
  (existing code), then `orc.loader` link-and-run instead of
  `Runtime.loadLibrary` + `dlsym`.
- `llvm_jit.d` under `version (LDC)`:
  - the non-default constructors store dependency-image paths instead of
    `dlopen`ing them (`loadDependencyImages`) — this is what unblocks
    removing the `makeRunners` construction skip;
  - `runTests` mirrors `runTestsViaExecutor` (`system_linker.d`):
    emit objects in the host, split `linkFiles` into `.so` dep images vs
    archives (as `sharedLibrariesOf` does), collect mangled symbols, write
    the request, spawn, decode. Hoist `runExecutor`/`executorPath` from
    `system_linker.d` into a shared native-package module
    (intra-package imports are fine; the backend-to-backend import ban is
    about *different* backends).
  - Object temp-dir lifetime: today `jitForObjects` deletes the emit dir
    once buffers are read in-process; the executor path
    must keep it alive until results are read, like `SystemLinker`'s request
    dir.
  - `eval` throws under `version (LDC)` with the same wording pattern as
    `SystemLinker.eval`'s LDC guard (in-process execution is exactly the
    unsound thing).
- Un-gate: delete the `makeRunners` `version (LDC)` skip; reduce
  `withoutUnavailableBackends` (`benchmarks/cli.d`) to the identity so
  `llvmjit` stays in the defaults and `-b llvmjit` is accepted.
- Verify: `bin/bench.sh` (defaults include llvmjit, self-check green),
  `bin/bench.sh -b llvmjit`, `bin/bench.sh --dub cerealed -b llvmjit`
  (archives + dep image over the wire), DMD-host benchmark config unchanged,
  `ninja bin/ut` + `bin/ut --random` untouched.

### Slice 4: `ci.sh` gate + bookkeeping ✅ DONE (bench + dep-image flake fix)

- `./ci.sh` end-to-end: llvmjit rows render timed results in corpus and
  `--dub` modes, restoring the AGENTS.md "benchmarks run properly for every
  backend" invariant.
- Update `bench.md`'s "LLVMJit stays unavailable under the LDC build"
  section and `overview.md`'s parked-status line.

**Bench + docs done (2026-07-14).** Both `bench.md`'s stale "unavailable under
the LDC build" paragraph and `overview.md`'s parity-plan line are rewritten to
record that LLVMJit runs under the LDC bench via the `bench-exec` ORC path.
Measured the two timed rows directly (LDC `-O`, executor path): corpus
(`example`) llvmjit `46/46 ~38.0 ms` vs system-linker `46/46 ~77.2 ms`; `--dub
cerealed` llvmjit `156/156 ~1264 ms` vs system-linker `156/156 ~1013 ms`. The
direction flips by fixture shape (corpus favors LLVMJit's killed-spawn; the
single big cerealed link favors system-linker) — both correct, no "JIT child
died".

**Gate finding — `backends/ffi/dependency_image.d` `--random` isolation flake
(found 2026-07-14, seed `1126153379`) — FIXED.** The first `ci.sh` was red: 8
fixtures in `backends/ffi/dependency_image.d` failed (`passed` asserts `true`,
gets `false`) — 6
`LLVMJit`, 2 `Interpreter`. Root cause: every fixture builds a distinct
dependency-image `.so` but the `LLVMJit` and `Interpreter` variants of one
fixture reused the *same* module name and symbol names, loaded
`dlopen(RTLD_GLOBAL)`. One variant's native writeback leaks its mutated,
un-unloaded image into the long-lived `bin/ut` parent; under `--random` a later
same-named load (or an `LLVMJit` fork child inheriting the parent) binds to that
stale image (RTLD_GLOBAL first-loaded wins) and reads the wrong value. Slice E's
"run `LLVMJit` before `Interpreter`" mitigation is *source-order only* and
`--random` defeats it. This reproduced on master (PR #416 validated only seed
`55736904`).

Fix (test-only, this PR): the `uniqueDepModule` helper suffixes each fixture's
dependency-image **module name** with `backend.stringof`, so every
`(fixture, backend)` module — and every D-mangled symbol under it — is globally
unique and no leaked image can collide on them. The two `extern(C)`
ctor-ordering globals (`seedBase`, `dtNeededSeed`) are unmangled, so they are
suffixed with a second `uniqueDepModule` call to keep their variants isolated
too (otherwise the ctor-ordering fixtures could false-pass against a stale
already-initialized image rather than exercise the backend's own ctor). The
remaining shared-named `extern(C)` functions are stateless and identical across
variants, so they carry no stale state. Verified: the original failing seed
`1126153379` now passes, and across 8 full-suite orderings (3 historical/known
seeds + 5 fresh `--random`) there were **zero** dependency-image collision
failures. The only failures observed were two unrelated pre-existing flakes,
neither in this PR's surface: (1) an environmental `cc: '-fuse-linker-plugin',
liblto_plugin.so not found` link error in the `SystemLinker` oracle
(toolchain/LTO-plugin, machine-level), and (2)
`ct.cerealed.dynamicArrayTruthinessControlsEnforceFallback.Bytecode` (`130 !=
3`, a Bytecode backend flake; `dependency_image.d` never runs Bytecode).

After Slice 4 the plan's only other open items are those two unrelated
pre-existing flakes (out of scope here) and the two upstream JITLink minimal
repros (duplicate-`UND`; hidden-weak `DW.ref.*` cross-graph externalization),
both worked around in `orc/elf.d` and neither yet filed.

## Risks / watch items

- **EH across the new boundary**: JIT'd DMD code unwinding into the DMD-built
  `bench-exec` catch is the same `__register_frame` path proven in the
  `bin/ut` child (Step 1); expected to transfer, verify early in slice 3
  with a deliberately failing fixture through the self-check path.
- **GC**: JIT'd code allocating via `bench-exec`'s DMD druntime matches the
  `bin/ut` child pattern (Step 3 probe: no misbehavior). Per the
  adopt-on-evidence rule, no speculative GC-stress test — but if the bench
  self-check ever disagrees only under ORC mode, look here first.
- **Timing comparability**: both native rows now include executor spawn; note
  it in `bench.md` when flipping the Phase 2′ clause so nobody reads the LDC
  rows as pure link cost.
- **eh_frame Delta32 range** (pre-existing, found during slice 2): a
  `bin/ut --random` flake — JITLink rejects the object with "section
  .eh_frame: relocation target (DW.ref.__dmd_personality_v0) is out of range
  of Delta32 fixup". Address-space roulette, not order-determinism: seed
  660421069 failed once and passed on same-seed re-run; always
  `staticArrayCopyRunsPostblitAndDtors.LLVMJit` so far. **Resolved
  (2026-07-09) — see slice A below.** The original guess recorded here (that
  *host-symbol interposition* substitutes a far-away copy of the cell) was
  wrong: `DW.ref.*` is `STV_HIDDEN`, is in no `.dynsym`, and `dlsym` never
  finds it, so `defineHostSymbols` cannot interpose it. The real cause is
  cross-*object* weak-definition externalization inside JITLink.

## Non-goals

- `eval()` return-type coverage: `native/evaluator.d` is shared, so `LLVMJit`
  already has exact parity with `SystemLinker` (scalars only); widening it is
  REPL work, not peer parity. **Caveat (2026-07-07):** parity holds for return
  types only, not lifecycle — see slice C of the critique execution plan below.
- Non-x86-64 targets: the DMD codegen both backends share is x86-64-only.
- The upstream JITLink duplicate-`UND` repro stays the separate open item
  recorded above.

## Success criteria

- Every `SystemLinker`-oracle matrix block in `ct/` and `rt/` includes
  `LLVMJit`.
- LDC bench: `llvmjit` in the default backend set, `-b llvmjit` accepted,
  timed rows with green self-check in both corpus and `--dub` modes.
- `./ci.sh` green; `bin/ut --random` green including historical seeds.

# Critique execution plan (2026-07-07)

A spec + implementation critique session (2026-07-07) produced eight
findings; this section converts them into an ordered, decision-complete plan.
Where a design decision was open, it is now made and marked **Decision**;
points where the agent must stop and ask are marked **STOP**. The tests
specified here are approved to add as written; a test that needs a different
shape than specified is a STOP.

## How to work this plan

- One slice per branch/PR, in order A → F. Each slice is independently
  verifiable and leaves the suite green. Do not batch slices.
- Gate for every slice: `ninja bin/ut`; `bin/ut`; `bin/ut --random`;
  `bin/ut --random --seed 2828407573`; `bin/ut --random --seed 3516581215`;
  `bin/ut @LLVMJit`; `./ci.sh` before the PR. Report "0 failed" — never
  record test totals in this file or in PR text; totals rot silently.
- New tests land in the same PR as the change that turns them green; a test
  written to expose a defect must be observed red before the fix (note the
  red output in the PR description).
- `AGENTS.md` rules apply throughout (tests run serially; no per-test process
  spawning beyond the existing forks; oracle-backed matrix promotions are
  pre-approved).
- After slice F, resume the "SystemLinker-peer parity plan" above at slice 3
  (bench-exec ORC mode). The upstream JITLink duplicate-`UND` repro remains a
  separate open item.

## Slice A — keep hidden unwind cells in their own graph ✅ DONE

**Why first:** every later slice's gate includes `bin/ut --random`, and the
eh_frame Delta32 flake fails it about 1 run in 4 on master — every subsequent
gate is untrustworthy until this lands. Measured on `1a430048`: 2 of 8 isolated
full-suite `--random` runs red, every failure the same test,
`ct.structs.struct.staticArrayCopyRunsPostblitAndDtors.LLVMJit`. The
`Failed to materialize symbols` wall of text is the downstream cascade of the
one `JIT session error`, not a second flake.

**The original diagnosis in this slice was wrong** (recorded so nobody
re-derives it). It blamed `defineHostSymbols` for interposing
`DW.ref.__dmd_personality_v0` with a far-away host address, and prescribed a
`shouldInterpose` predicate excluding `DW.ref.*`. But that symbol is
`STV_HIDDEN`: it appears in the `.dynsym` of neither `bin/ut` nor
`libphobos2.so`, so `dlsym(RTLD_DEFAULT, "DW.ref.__dmd_personality_v0")`
returns null and the interposition loop skips it. The exclusion would have been
a no-op that looked like a fix.

**Actual cause** (`readelf` on the emitted `obj_0.o` / `obj_1.o` of the failing
fixture). Every object dmd emits defines `DW.ref.__dmd_personality_v0` as a
`WEAK HIDDEN OBJECT` in its own `.data.DW.ref.*` section, and references it
from `.eh_frame` with `R_X86_64_PC32`. JITLink admits the first object's copy
into the JITDylib and **externalizes every later object's duplicate weak
definition**, so `obj_1`'s `.eh_frame` fixup targets `obj_0`'s slab. When the
two slabs land more than 2 GiB apart the Delta32 fixup overflows (observed
distance: 2.05 GiB). `SystemLinker` never hits it because `dmd -shared` merges
everything into one image first.

**Decision.** Fix it in the ELF surgery that already exists for JITLink's other
strictness (`orc/elf.d`), not in the interposition policy: repoint each
relocation naming a defined `DW.ref.*` symbol at the defining section's
local `SECTION` symbol, moving the symbol's value into the addend. Section
symbols cannot be externalized, so the edge can never leave its own graph.

Note what the justification is *not*. Resolving object B's reference to object
A's hidden weak definition is legal ELF: `STV_HIDDEN` bounds visibility at the
linked component, not at the object, which is exactly why the same dedup is
right for hidden COMDAT template bodies. What makes it wrong here is only the
distance — `ld` resolves it inside one image, JITLink across two mmap'd slabs.
Repointing is safe because every object's `DW.ref.*` cell is content-identical
(one 64-bit relocation to the same personality symbol), so the local copy holds
the same value at a reachable address. Scope therefore stays at `DW.ref.*` per
adopt-on-evidence; widening it to every hidden symbol would suppress the COMDAT
dedup, whose copies are not interchangeable this way.

Rejected alternative: `oneobj = true` in `generateCodeAndWrite` (one object per
link, hence one graph, hence no cross-graph dedup at all). It kills the whole
class rather than one symbol, but it changes the codegen path `SystemLinker`
shares, and dmd's `oneobj` branch skips `obj_write_deferred`. Worth revisiting
on its own merits (fewer objects, less link work), not as a flake fix.

The other critique concerns (hardcoded `callable` flag on data symbols, TLS
symbols, `UND` interposition pre-empting the static-archive generator,
duplicate pairs in one `AbsoluteSymbols` unit, unmeasured `dlsym` sweep cost)
remain **watch items**, parked per adopt-on-evidence — their exposing tests are
recorded at the end of this slice for when evidence arrives. Note that the
Delta32 flake is no longer evidence for any of them.

**Upstream.** JITLink exporting and then externalizing a hidden weak definition
across graphs looks like an LLVM bug: hidden visibility should keep the
definition graph-local. Worth a minimal repro and report, alongside the
existing duplicate-`UND` upstream item.

**Work (landed).**

1. `orc/elf.d`: `localizeUnwindCellReferences`, called from
   `normalizeObjectFile` alongside the duplicate-`UND` coalescer (the
   file-level entry point was renamed from
   `normalizeDuplicateUndefinedGlobalsInFile`, which now does two transforms
   rather than one).
2. Deterministic pin: `elf.unwindCellRelocationsUseSectionSymbol` in
   `tests/ut/orc/elf.d` — a synthetic object whose `.rela` entry
   names a `DW.ref.*`; after the transform the entry must name the local
   `SECTION` symbol with the addend shifted by the symbol's value and the
   relocation type intact, while an undefined global and a hidden non-cell
   symbol are both left untouched. Observed red before the fix.

   The predicate gates on the name, not on `STV_HIDDEN`: dmd emits these cells
   hidden, but a non-hidden one would be externalized across graphs just the
   same, and repointing is address-preserving either way — so a visibility gate
   would be a branch no object can exercise.
3. End-to-end anchor: `staticArrayCopyRunsPostblitAndDtors.LLVMJit` — the
   fixture that carried every observed occurrence — stays green, and its
   dtor/postblit unwinding still byte-matches `SystemLinker`.

**Verify:** the standard gate, plus `bin/ut --random` repeated — flake absence
is only demonstrable statistically; the unit test is the deterministic pin.
Measured: master 2 red in 8 runs; with the fix, 0 red in 32 runs.

**Superseded work item (do not implement).** A `shouldInterpose` predicate in
`orc/loader.d` excluding `DW.ref.*` from `defineHostSymbols`, with an
`interpose.excludesEhFrameIndirectionCells` unit test. `dlsym` never returns
those hidden symbols, so the predicate would exclude something the loop already
skips.

**Watch items (parked; do not implement without evidence).**

- Flags should derive from the object symbol's category instead of the
  hardcoded `exported|weak|callable`; TLS symbols should not be interposable
  at all (`dlsym` returns one thread's copy). Exposing test for when this
  graduates:

```d
@("interpose.flagsDeriveFromSymbolCategory")
unittest {
    import orc.loader: interpositionFlagsFor, shouldInterpose, SymbolCategory;
    interpositionFlagsFor(SymbolCategory.function_).callable.should == true;
    interpositionFlagsFor(SymbolCategory.data).callable.should == false;
    shouldInterpose("any_tls_symbol", SymbolCategory.tls).should == false;
}
```

- `UND` interposition pre-empts the static-archive search generator when the
  host also exports the symbol; under archive-vs-host version skew the
  backends could diverge. The oracle pin below is **added now** (it asserts
  backend agreement, not a winner, so it is evidence-gathering rather than a
  behaviour change — scaffolding per `ct/archive.d`'s archive/dep-image build
  pattern). **STOP if it is red**: that means the backends already disagree
  and this watch item graduates to a defect needing its own design.

```d
@("archiveVsHostSymbolResolutionMatchesSystemLinker")
unittest {
    with(immutable Sandbox()) {
        // build libprobe.a: qbProbe() => 42, qbSibling() => 1
        // build libdep.so:  qbProbe() => 41
        // fixture: unittest { assert(qbProbe() + qbSibling() == EXPECTED); }
        const linkFiles = [
            inSandboxPath("libdep.so"),
            inSandboxPath("libprobe.a"),
        ];
        const jit    = runResultsWith!LLVMJit(fixture, linkFiles, importPaths);
        const linker = runResultsWith!SystemLinker(fixture, linkFiles, importPaths);
        jit.length.should == linker.length;
        jit[0].passed.should == linker[0].passed;
        jit[0].message.should == linker[0].message; // byte-for-byte, oracle rule
    }
}
```

- The per-object `dlsym` sweep's share of the ~5–9 ms per-test latency is
  unmeasured; measure with a bench probe before considering a once-per-child
  process-export cache.

## Slice B — ELF normalizer: coalesce all undefined duplicates, test the guard ✅ DONE

**Context.** The normalizer (see "Duplicate undefined ELF normalizer" above)
is a defense against an uncharacterized emitter, but it coalesces only
duplicate `UND GLOBAL` entries: a duplicate `UND WEAK` pair, or a mixed
`GLOBAL`+`WEAK` pair with the same name, passes through silently and JITLink
would zero-stub the referenced duplicate exactly as before (`rip = 0x0` in
the JIT child, at package scale). GNU ld coalesces undefined weaks by name
just as it does globals. Separately: the wrapper production actually calls
(`normalizeObjectFile`) and all rejection paths are
untested, and a rejection throws inside the JIT child, failing the whole
`runTests` group — blast radius that deserves pins.

**Decision.** Coalesce duplicate `UND` symbols of *any* binding by name, with
the canonical entry preferring `GLOBAL` over `WEAK`. Rationale: the
normalizer's design principle is "replicate what ld tolerates", and rejecting
instead would turn a plausible emitter variant into a hard backend failure. (A
legitimately unresolved weak undef resolving to 0 is unaffected:
name-coalescing only prevents the two-entries-one-zeroed split.)

**Work.**

1. `orc/elf.d`: widen the coalescing loop's binding filter to
   `global || weak`; when both bindings appear for one name, make the
   `GLOBAL` entry canonical.
2. Fix `singleSectionOfType`'s error messages to derive from its `type`
   parameter (they hardcode "SHT_SYMTAB").
3. Tests in `orc/elf.d`, reusing its synthetic builder (`writeSymbol(object,
   index, name, symbolInfo(binding, type), sectionIndex)`; binding 1 =
   GLOBAL, 2 = WEAK). The first two must be observed red before the fix:

```d
@("elf.duplicateUndefinedWeakRelocationsUseFirstSymbol")
unittest {
    // Same shape as the GLOBAL-duplicate test, weak binding: ld coalesces
    // undefined weaks by name too, so the normalizer must as well or the
    // zero-GOT-stub defect recurs under a weak-emitting variant of the
    // uncharacterized emitter.
    auto object = emptyObject;
    writeSymbol(object, 1, 1, symbolInfo(2, 0), 0); // UND WEAK "dup"
    writeSymbol(object, 2, 1, symbolInfo(2, 0), 0); // UND WEAK "dup" again
    writeSymbol(object, 3, 5, symbolInfo(1, 0), 0); // UND GLOBAL "other"
    writeRelocation(object, 0, 2, 42);
    writeRelocation(object, 1, 3, 17);

    normalizeDuplicateUndefinedGlobals(object).should == true;
    relocationSymbolIndex(object, 0).should == 1;
    relocationSymbolIndex(object, 1).should == 3;
}

@("elf.mixedBindingDuplicateCoalescesToGlobal")
unittest {
    auto object = emptyObject;
    writeSymbol(object, 1, 1, symbolInfo(1, 0), 0); // UND GLOBAL "dup"
    writeSymbol(object, 2, 1, symbolInfo(2, 0), 0); // UND WEAK   "dup"
    writeRelocation(object, 0, 2, 42);

    normalizeDuplicateUndefinedGlobals(object).should == true;
    relocationSymbolIndex(object, 0).should == 1;   // canonical: the GLOBAL
}

@("elf.normalizeInFileRewritesAndReportsChange")
unittest {
    with(immutable Sandbox()) {
        writeFile("dup.o", cast(const(char)[]) duplicateUndefinedGlobalObject);
        normalizeObjectFile(inSandboxPath("dup.o"))
            .should == true;
        // second pass: already canonical, must be a no-op
        normalizeObjectFile(inSandboxPath("dup.o"))
            .should == false;
    }
}

@("elf.unsupportedShapesAreRejectedLoudly")
unittest {
    static ubyte[] withByte(size_t offset, ubyte value) {
        auto object = uniqueUndefinedGlobalObject;
        object[offset] = value;
        return object;
    }
    normalizeDuplicateUndefinedGlobals(new ubyte[](8))
        .shouldThrowWithMessage("ELF object is too small");
    normalizeDuplicateUndefinedGlobals(withByte(5, 2))       // big-endian
        .shouldThrowWithMessage("ELF object is not little-endian");
    normalizeDuplicateUndefinedGlobals(withByte(16, 2))      // ET_EXEC
        .shouldThrowWithMessage("ELF object is not relocatable");
}
```

**Verify:** standard gate, plus `bin/bench.sh --dub cerealed -b llvmjit`
(the package-scale surface that exposed the original defect).

**Progress (2026-07-13).** Completed the two-pass canonicalization: every
duplicate undefined `GLOBAL` or `WEAK` name now rewrites to the first `GLOBAL`
entry when one exists, otherwise the first `WEAK`. Focused synthetic-object
tests cover a duplicate weak relocation, global-over-weak canonicalization,
file-wrapper idempotence, and malformed-header diagnostics. `ninja bin/ut`
and the four focused tests passed. Slice B's implementation is complete. The
package-scale `bin/bench.sh --dub cerealed -b llvmjit` verification remains
pending: its optimized build stalled before the benchmark could run.

## Slice C — `eval` isolation: fork-and-report

**Context.** `LLVMJit.eval` (`llvm_jit.d`) stands up an LLJIT via
`jitForObjects` *in the long-lived parent* and executes the JIT'd function
there, and nothing ever calls `LLVMOrcDisposeLLJIT` — the exact configuration
Step 4's "Rejected alternatives" names ("never disposing the LLJIT in the
long-lived parent — leaks unbounded and still risks a mid-run collect"). Each
`eval` permanently leaks a full LLJIT. Reachable surfaces: the REPL
(`qb --backend llvmjit`; `bin/qb` is DMD-built, so this runs today — one
leaked LLJIT per evaluated line) and `bin/ut`'s `LLVMJit` eval block in
`tests/ut/backends/evaluator/eval.d`. The Step-4 crash does not recur only
*because* nothing is unmapped.

**Decision.** Run `eval` through the same fork-and-report pattern as
`runTests`. The alternative (accept and document the leak) contradicts the
backend's own Step-4 rationale and leaves the REPL leaking per line.

**Work.**

1. `llvm_jit.d`: `eval` forks; the child JITs, calls the function via the
   shared evaluator, writes the result over the pipe, and `_exit`s without
   disposing (same reasoning as `runTestsInChild`). Extend the frame protocol
   with an eval frame kind alongside the existing results/error kinds, and
   encode `EvalResult`'s fields the way `TestResult`'s are encoded
   (length-prefixed strings, same-process endianness). **STOP** if
   `EvalResult` turns out not to be plain marshallable data.
2. Leak test in `tests/ut/backends/evaluator/eval.d` — red today, green
   after:

```d
@("eval.doesNotLeakJitMappings.LLVMJit")
@Tags("LLVMJit")
unittest {
    static size_t anonymousExecutableMappings() {
        import std.algorithm.iteration: filter;
        import std.algorithm.searching: canFind;
        import std.file: readText;
        import std.range: walkLength;
        import std.string: lineSplitter;
        return "/proc/self/maps"
            .readText
            .lineSplitter
            .filter!(line => line.canFind("r-xp") && !line.canFind("/"))
            .walkLength;
    }

    auto backend = newBackend!LLVMJit;
    backend.eval("1 + 2").should == "3"; // first eval pays one-time setup
    const before = anonymousExecutableMappings;
    foreach (i; 0 .. 8)
        backend.eval("1 + 2").should == "3";
    const after = anonymousExecutableMappings;
    // Un-forked, undisposed evals grow this by >= 1 mapping each; the
    // fork-and-report implementation adds none in the parent.
    (after - before).should.be < 8;
}
```

3. GC-invisibility probe — **evidence probe, not fixed by this slice**: JIT
   `.data`/`.bss` is never GC-registered (no DSO registry, Step 1), so a GC
   pointer whose only reference lives in a JIT-resident `__gshared` is
   invisible to the collector — inside the fork child too, for `runTests`
   fixtures as much as for `eval`. Add the test; `SystemLinker` is the oracle
   (its `.so` data segment is a registered GC range). **STOP if the `LLVMJit`
   row is red**: that is a deeper shared gap (GC-range registration for JIT'd
   data) needing its own design — record the failure here, do not attempt
   `GC.addRange` plumbing inside this slice. A pass is weak evidence only
   (reclaim-and-reuse is not guaranteed), which is acceptable for a parked
   hazard.

```d
static foreach (backend; AliasSeq!(SystemLinker, LLVMJit)) {
    @("gcSeesJitResidentGlobals." ~ backend.stringof)
    unittest {
        enum expression = q{
            () {
                import core.memory: GC;
                // JIT .bss: the only reference to the array after clobber().
                __gshared int[] cache;
                static void clobber(int depth) {
                    int[64] junk = void;
                    junk[] = 0x7fff_fff0;
                    if (depth) clobber(depth - 1);
                }
                cache = new int[](1024);
                cache[0] = 42;
                cache[$ - 1] = 43;
                clobber(16);       // overwrite stale stack copies of the pointer
                GC.collect;        // host GC: cannot see JIT-resident `cache`
                auto probe = new int[](1024); // encourage reuse of a freed block
                probe[] = -1;
                return cache[0] + cache[$ - 1]; // 85 iff `cache` survived
            }()
        };
        newBackend!backend.eval(expression).should == "85";
    }
}
```

**Verify:** standard gate, plus a manual `bin/qb --backend llvmjit` smoke —
a few evals including one that throws, confirming message parity with
`--backend system-linker`.

**Progress (2026-07-13).** `LLVMJit.eval` now executes the full
create/load/call cycle in a forked child and reports its `EvalResult` through
the existing pipe protocol's new eval frame kind. The child exits without
disposing its LLJIT, so the parent receives only copied strings and cannot
retain JIT mappings. The approved mapping test was red before this change
(eight evals grew anonymous executable mappings) and green afterwards. The
GC-resident-global evidence probe passed for both `SystemLinker` and
`LLVMJit`; as expected, that is weak evidence only and does not graduate the
parked GC-range hazard. Focused tests and the standard gate passed with random
seed `1032394620`.

## Slice D — `--dub` object-production parity (`DubPackage` mirroring)

**Context.** In `--dub` bench mode the environment carries `DubPackage.yes`
(`benchmarks/cli.d`). `makeSystemLinker` forwards it and `SystemLinker`
dispatches on it (`emitObjectFilesForDubPackage` vs `emitObjectFilesForLink`);
`makeLLVMJit` cannot — `LLVMJit` has no `DubPackage` parameter and
`jitForObjects` hardwires `emitObjectFilesForLink`. So `--dub` codegens the
same package two different ways, which (a) falsifies this plan's "reuses
object production verbatim" claim and the "identical object bytes, only the
loader differs" diagnostic axiom exactly where the backends are compared,
(b) means the bench's cross-backend delta is not pure link strategy in
`--dub` mode, and (c) runs the snippet apparatus (rod/prune/adoption) against
dub-parsed roots — the regime `emitObjectFilesForDubPackage` exists to avoid.
Cerealed passing shows the mismatch is survivable, not sound.

**Decision.** Mirror the flag and hoist the dispatch so "verbatim" is true by
construction.

**Work.**

1. `LLVMJitInputs` gains a `dubPackage` field; `LLVMJit` gains the
   constructor shape matching `SystemLinker`'s (`linkFiles, importPaths,
   packageRoot, frontendFlags, dubPackage`); `makeLLVMJit` forwards
   `env.dubPackage`.
2. Hoist the two-way dispatch (`dubPackage ? emitObjectFilesForDubPackage :
   emitObjectFilesForLink`) into `native/codegen.d` as the single entry point
   both backends call.
3. Construction pin in `ut.bin.benchmarks` (fails to compile today):

```d
@("makeRunners.llvmjitReceivesDubPackage")
unittest {
    import quickbite.backends.native: DubPackage, LLVMJit;
    import quickbite.frontend.compiler: FrontendFlags;

    static assert(__traits(compiles,
        new LLVMJit(
            cast(const string[]) [],
            cast(const string[]) [],
            "",
            FrontendFlags.init,
            DubPackage.yes,
        )));
}
```

4. Object-production parity test — the diagnostic axiom pinned. Compare
   defined-global symbol sets per object rather than raw bytes (robust
   against benign emission nondeterminism); `definedGlobalSymbolNames` is a
   small helper over `orc.elf`'s symtab parsing. Red before the fix (extra
   rod object / prune-adopted symbols on the LLVMJit side); after the fix,
   drive `LLVMJit`'s build half with `DubPackage.yes` inputs instead of the
   raw `emitObjectFilesForLink` call so the test pins the backend plumbing,
   not just the codegen functions:

```d
@("dubPackage.objectProductionMatchesSystemLinker")
unittest {
    import quickbite.backends.native.codegen:
        CodegenInputs, emitObjectFilesForDubPackage, emitObjectFilesForLink;
    import quickbite.frontend.compiler: parseRootModules, withCompilerLock;
    import std.algorithm.iteration: map;
    import std.array: array;

    with(immutable Sandbox()) {
        writeFile("pkg/mod.d", q{
            module pkg.mod;
            uint hashed(int x) { return hashOf(&x); } // homes a druntime
            unittest { assert(hashed(3) == hashed(3)); } // instance on the root
        });
        auto modules = parseRootModules(
            [inSandboxPath("pkg/mod.d")],
            [inSandboxPath("pkg")],
        ).map!(result => result.module_).array;

        string[] linkerObjs, jitObjs;
        withCompilerLock(() {
            linkerObjs = emitObjectFilesForDubPackage(
                modules, inSandboxPath("linker"), CodegenInputs.init);
            jitObjs = emitObjectFilesForLink(
                modules, inSandboxPath("jit"), CodegenInputs.init);
        });

        jitObjs.length.should == linkerObjs.length;
        foreach (i, jitObj; jitObjs)
            definedGlobalSymbolNames(jitObj)
                .should == definedGlobalSymbolNames(linkerObjs[i]);
    }
}
```

**Verify:** standard gate, plus `bin/bench.sh --dub cerealed -b llvmjit` and
`bin/bench.sh --dub cerealed -b system-linker`.

**Progress (2026-07-13).** `LLVMJitInputs` now carries `DubPackage`, its
benchmark constructor mirrors `SystemLinker`, and `makeLLVMJit` forwards the
benchmark environment's flag. Both native loaders call the same
`emitObjectFilesForBackend` dispatch, so the `--dub` choice cannot drift
between their object-production paths. The approved construction pin was red
before the constructor change and green afterwards. The standard unit-test
gate is green; the requested optimized `cerealed` benchmark build was still
not complete when this increment was committed.

## Slice E — matrix promotions

**Context.** Step 4's "every SystemLinker-oracle block" claim has uncommented
gaps, and `backends/ffi/dependency_image.d` — the one file exercising
extern-D/extern-C calls into a prebuilt dependency image — has no `LLVMJit`
coverage at all, despite `LLVMJit` shipping dedicated dep-image machinery
(`loadDependencyImages`, the shared/static `linkFiles` split) with
JIT-specific semantics: an `RTLD_GLOBAL` dep image's symbols participate in
weak interposition over the JIT objects, a binding regime `SystemLinker`'s
link never goes through.

**Work** (all oracle-backed, pre-approved per `AGENTS.md`):

1. Add `LLVMJit` to the uncommented SystemLinker-bearing blocks:
   `ct/structs.d` (`tupleofForeachRefReadsAndWritesFields`,
   `templatedConstructorPreservesDynamicArrayField`,
   `voidInitialisedFieldSliceAssignment`), `ct/arrays.d`
   (`pointer.indexAssignmentWritesArrayStorage`), `ct/expressions.d`
   (`struct.defaultInitPreservesExplicitFieldInitializers`), `rt/cstdlib.d`
   (`strlen.localBuffer`), `rt/file.d` (the whole
   `AliasSeq!(Interpreter, SystemLinker)` block), and the four consecutive
   "Oops" diagnostic blocks in `ct/diagnostics.d` that omit it while the
   adjacent `refParameterOops` block includes it:

```d
// ct/diagnostics.d — match the adjacent refParameterOops block:
static foreach (backend; AliasSeq!(
    Ctfe, Interpreter, Bytecode, BytecodeNewCore, IR, SystemLinker, LLVMJit,
)) {
```

2. Promote `backends/ffi/dependency_image.d`'s fixtures:

```d
// every extern-D/extern-C fixture also runs through the JIT's dep-image +
// interposition regime; the SystemLinker-oracle expected values already
// computed in this file stay the oracle:
static foreach (backend; AliasSeq!(Interpreter, LLVMJit)) {
```

3. **STOP per red promotion**: a red is a backend bug found — report the
   failing fixture and the message diff against the oracle before attempting
   a fix; do not exclude-and-comment to get green without approval. Any block
   that turns out to be *deliberately* excluded gets a one-line comment
   pointing here (`ct/math.d`'s pow block shows the convention).

**Verify:** standard gate.

**Progress (2026-07-13).** Promoted the first named set of uncommented
SystemLinker-oracle rows: the three struct fixtures, pointer index assignment,
explicit struct-field initialization, local-buffer `strlen`, file I/O, and the
four adjacent parameter/control-flow diagnostics. All 11 new `LLVMJit` rows
passed in a focused serial run. Converted `backends/ffi/dependency_image.d`
mechanically to the `Interpreter`/`LLVMJit` matrix. Its two TLS rows exposed the
parked interposition hazard: defining dlsym's per-thread TLS instance as an ORC
absolute symbol breaks the TLSGD protocol. LLVMJit now rewrites resolved TLSGD
sequences in the child object to return that instance directly, removing the
TLSGD and `__tls_get_addr` relocations before JITLink loads the object. The
historical seed `4286332873` and the standard randomized gate (seed
`55736904`) are green.

**Matrix correction (2026-07-13).** `externCAssocArrayRejected` is an
Interpreter-only FFI characterization: its expected rejection is not
SystemLinker-oracle behavior, and both native backends support the crossing.
It therefore remains only in the Interpreter expansion. The remaining shared
dependency-image fixtures run `LLVMJit` before `Interpreter`; this avoids the
Interpreter's native writeback leaking into the long-lived parent process
before the JIT child loads the same dependency image. This is test isolation,
not an LLVMJit support regression.

## Slice F — diagnostics and hygiene

**Work.**

1. **Pipe error reporting** (`llvm_jit.d`): make `writeAll` report failure
   (throw) instead of silently returning on non-EINTR errors, so the child
   `_exit`s nonzero and the parent's "JIT child died" path carries the real
   errno instead of decoding a truncated frame; make the parent's read loop
   throw on non-EINTR errors instead of decoding partial data; in
   `runChildAndReport`'s catch-all, send `throwable.toString` (matching the
   codegen fork) with the existing guarded fallback to `msg` if `toString`
   itself throws. Test:

```d
@("jitPipe.writeFailureIsReportedNotSwallowed")
unittest {
    import core.sys.posix.signal: SIG_IGN, SIGPIPE, signal;
    import core.sys.posix.unistd: close, pipe;

    int[2] fds;
    pipe(fds).should == 0;
    close(fds[0]);                 // reader gone: writes fail with EPIPE
    signal(SIGPIPE, SIG_IGN);      // surface EPIPE instead of dying

    writeResults(fds[1], [TestResult(true, "t", "loc", "")])
        .shouldThrowWithMessage("write to result pipe failed");
}
```

2. **Deduplicate the diverged helpers**: `archiveImportPathsUnder` exists in
   both `system_linker.d` and `llvm_jit.d` and the copies already disagree
   (LLVMJit's early-returns `[]` for empty `packageRoot`; SystemLinker's
   normalizes `""` to the cwd). `isSharedLibraryPath` is duplicated too.
   Hoist both into one package-private native module; the empty-root
   semantics is LLVMJit's (no package root ⇒ no "under the package"
   distinction ⇒ nothing archive-backed). Pin:

```d
@("archiveImportPathsUnder.emptyPackageRootClassifiesNothing")
unittest {
    // Pinned so the two backends cannot diverge again: one shared helper,
    // not parallel maintenance.
    archiveImportPathsUnder(["/somewhere/else/src"], "").should == [];
}
```

3. **Consistency and comments** (no tests; comment/deletion fixes):
   - `orc/bindings.d`: mark `LLVMOrcDisposeLLJIT` "intentionally unused —
     the JIT child `_exit`s instead of disposing; re-adding a dispose call in
     the child recreates the Step-4 munmap-then-collect crash". Delete
     `LLVMOrcReleaseSymbolStringPoolEntry` (never called, no such guard
     value). Fix the `LLVMInitializeX86*` comment ("each returns nonzero on
     failure" — they are `void`).
   - Serial contract: `runTestsInChild` forks and then takes
     `withCompilerLock` *inside the child*; only the suite's serial execution
     (`AGENTS.md`) prevents inheriting a locked mutex and deadlocking. Say so
     in a comment at the fork site, and make `_nativeTargetInitialised`
     (`orc/loader.d`) and `_jitCounter` (`llvm_jit.d`) consistent with that
     contract (plain `__gshared` for both; the atomic implies a concurrency
     support that does not exist).
   - `codegen.d`'s header comment still says "the *future* LLVMJit".

**Verify:** standard gate.

**Progress (2026-07-13).** Completed item 3's comment and declaration
hygiene: recorded the intentional no-dispose child lifetime, removed the
unused string-pool release declaration, corrected the void target-init
comment, documented the serial fork/lock contract, and made the JIT counter
plain `__gshared` like the target-init flag. Standard gate green.

**Progress (2026-07-13).** Completed items 1–2: result-pipe writes and reads
now throw on non-EINTR errors, and child infrastructure frames use
`Throwable.toString` with a guarded `msg` fallback. The static/shared-library
and archive-import-path classifiers now share `native/link_files.d`; an empty
package root classifies no archive paths for both native backends. The approved
pipe regression was red before error propagation and both approved focused
tests are green afterwards.

**Progress (2026-07-13).** The pipe-write regression now restores its prior
`SIGPIPE` handler and closes its write descriptor during cleanup, preventing
test-local process-state and descriptor leaks.

**Progress (2026-07-13).** Parent-side result-pipe failures now close the
read end, kill the still-running JIT child, and reap it before propagating the
read error. This prevents a blocked writer or zombie on either the test or
eval child path.

## SystemLinker-peer parity Slice 3 — `bench-exec` ORC mode + LDC bench

**Progress (2026-07-13).** Added the ORC object request mode to the shared
executor wire protocol. Under LDC, LLVMJit now emits objects in the host and
sends them, static archives, dependency images, and discovered unittest symbols
to the DMD-built executor; that executor loads images before creating its ORC
JIT and returns the normal result frame. Dependency images are no longer
`dlopen`'d in the LDC host. The executor spawn helper is shared by both native
backends; `llvmjit` is restored to LDC benchmark defaults and explicit
selection. `bench-exec` now builds the frontend-free `orc` package and links
LLVM. DMD `ninja bin/ut` passed.

**Verified (2026-07-14).** The three Slice-3 benchmark commands now run green
against the optimized LDC build: `bin/bench.sh -b llvmjit -b system-linker`
(corpus, both render timed rows — llvmjit `46/46 ~38.0 ms`, system-linker
`46/46 ~77.2 ms`) and `bin/bench.sh --dub cerealed -b llvmjit -b system-linker`
(archives + dep image over the wire — llvmjit `156/156 ~1264 ms`,
system-linker `156/156 ~1013 ms`). `llvmjit` is accepted both in the defaults
and via explicit `-b llvmjit`. Slice 3 is ✅ done; see Slice 4 for the `ci.sh`
gate and doc bookkeeping.
