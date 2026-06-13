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
`this(ExecutionMode)`) are stood up. `runTests`:

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

Add `LLVMJit` to `tests/ut/backends/package.d` exports and to the
`AliasSeq` of one or a few `rt/` blocks whose oracle is SystemLinker
(pre-approved per `AGENTS.md`). Tag `@Tags("LLVMJit")` so it is
opt-out-able like SystemLinker. Gate: those blocks green solo, then under
repeated `--random`, then both historical seeds.

### Step 3 — measure (GC registration already resolved in Step 1)

Time `LLVMJit` vs `SystemLinker` on the same fixtures (reuse the bench
harness / `ci.sh` bench row). Report median per-test latency; the POC is
justified only if it beats SystemLinker.

The GC-registration question this step originally deferred is settled in
Step 1: allocation from JIT'd code works once weak-symbol interposition is
replicated, and `_d_dso_registry`-style registration is neither needed (the
host GC is functional and the fixtures root nothing in JIT data) nor
feasible via the LLVM 22 C API. The only remaining GC work is a confirmatory
**GC-stress probe** as a promoted matrix test (allocate, collect, read back),
beyond the throwaway probe already run by hand in Step 1. Adopt it on
evidence if a future allocating fixture in the matrix misbehaves; otherwise
no further registration mechanism is warranted.

## Build wiring

Add to the `unittest` config in `dub.sdl` (and `qb` only if the REPL ever
selects this backend): `libs "LLVM"`. If the bare `libLLVM.so` symlink is
absent (only the versioned runtime is installed), link the soname
explicitly (`lflags "-L-l:libLLVM.so.22.1"` or a full path) — resolve at
implementation. Regenerate with `dub run reggae --compiler=ldc -- -b
ninja`.

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
- `source/quickbite/backends/runner.d` — `GroupedRunner`, `ExecutionMode`
- `tests/ut/backends/package.d` — `newBackend`, backend exports
- `ai/plans/dmd-backend.md` — Scope stage 3 (load in parent) and the
  `DmdCodegenRam` druntime-registration warning (the central risk here)
