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

What we expect *not* to need for the POC, and must confirm we don't:
`ModuleInfo`/module-ctor registration and GC scan-range registration. A
unittest that only does `assert(...)` runs no module ctor and roots no GC
memory in its own data segment, so a no-DSO-registry load should suffice.
A fixture that GC-allocates is the next probe (deferred — see Step 3).

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

Pull the fork + `emitObjectFiles` flow (and its prep: rod-root assertion,
user-import promotion, child-side prune, `adoptTypeInfos`) out of
`system_linker.d` into a package-private `native/codegen.d` that returns
the emitted object-file paths to the parent. `SystemLinker` calls it, then
does its `dmd -shared` + `loadSharedLibrary` as today. Gate: full
SystemLinker matrix stays green under `--random` and both historical seeds
(`2828407573`, `3516581215`) — this step must be behavior-preserving.

### Step 1 — minimal end-to-end proof (the gate)

Stand up `native/llvm_orc.d` (bindings + `pragma(lib)`/`libs`) and
`native/llvm_jit.d` (`LLVMJit : GroupedRunner`, no-mode constructor like
`SystemLinker` — native is inherently runtime, see
`ai/plans/single-oracle.md`).
`runTests`:

1. call `native/codegen.d` to get object paths (child emits, no link);
2. parent: create LLJIT, add process-symbol generator, `AddObjectFile`
   each `.o` (rod, snippet, imports) into the main `JITDylib`;
3. per unittest: `lookup(mangleExact(decl))`, cast to `void function()`,
   call inside `try/catch (Throwable)` — identical result handling to
   SystemLinker's `runUnitTest`.

Prove on two hand-written fixtures (not yet the matrix): one passing, one
whose `assert(a == b)` fails. **Pass criterion: the failing fixture's
`Throwable` is caught and its message byte-matches SystemLinker's** (this
is the eh_frame/unwinding gate). **Fallback: if unwinding through JIT'd
frames does not work, stop and determine whether forcing the JITLink
`ObjectLinkingLayer` + explicit `EHFrameRegistrationPlugin` fixes it
before writing any more — a backend that can't catch assert failures
cannot enter the matrix, exactly as `DmdCodegenRam` could not.**

### Step 2 — promote into the matrix

Add `LLVMJit` to `tests/ut/backends/package.d` exports and to the
`AliasSeq` of one or a few `rt/` blocks whose oracle is SystemLinker
(pre-approved per `AGENTS.md`). Tag `@Tags("LLVMJit")` so it is
opt-out-able like SystemLinker. Gate: those blocks green solo, then under
repeated `--random`, then both historical seeds.

### Step 3 — measure, and probe GC

Time `LLVMJit` vs `SystemLinker` on the same fixtures (reuse the bench
harness / `ci.sh` bench row). Report median per-test latency; the POC is
justified only if it beats SystemLinker. Then add a fixture that
GC-allocates to find out whether missing DSO/GC-range registration bites;
if it does, that becomes the exposing test for a future
druntime-registration step (out of POC scope, noted here so it is adopted
on evidence, not speculatively).

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
- `source/quickbite/backends/runner.d` — `GroupedRunner`
- `tests/ut/backends/package.d` — `newBackend`, backend exports
- `ai/plans/dmd-backend.md` — Scope stage 3 (load in parent) and the
  `DmdCodegenRam` druntime-registration warning (the central risk here)
