# Phase 0 spike findings: LDC-built bench, in-process DMD-codegen execution

Run `./run.sh` to reproduce. Toolchain: dmd 2.112.0, ldc2 1.42.0 (LLVM 21, DMD
2.112.1 frontend), LDC shared druntime `libdruntime-ldc-shared.so.112.1`.

The plan asked whether an LDC-built `bin/bench` can `dlopen` a DMD-codegen `.so`
and run it **in-process**, sharing the host's single LDC druntime/GC, given a
small "C-ABI firewall" plus shims for a handful of DMD-only EH symbols.

Phase 0's job was to settle that fork before committing to an architecture. It
is settled: **in-process execution of DMD-codegen'd code on an LDC host is not
viable.** Three findings, in increasing order of severity.

## Finding 1 — the EH symbol gap is exactly what the plan predicted

A DMD-codegen `fixture.o`, linked into a `.so` **without** DMD's libphobos2
(`cc -shared`, druntime symbols left undefined), has its entire undefined set
satisfied by LDC's shared druntime **except three symbols**:

    __dmd_personality_v0   _d_throwdwarf   __dmd_begin_catch

(transitively also the rest of `rt.dwarfeh`: `__dmd_end_catch`, `scanLSDA`,
`ExceptionHeader`, …). GC (`gc_malloc`), bounds/assert helpers,
`object.Exception`/`Throwable` ClassInfo, and even `_d_dso_registry` are present
**by name**. So the plan's "category 1 is the same druntime, same mangled names"
claim is true *at the symbol-name level*. The trouble is everything below.

## Finding 2 — `_d_dso_registry` ABI diverges (category 3 is NOT free)

The DMD `.so` self-registers from its `.init_array` by calling `_d_dso_registry`
with **DMD-format** DSO data. Resolved to LDC's identically-named registry, the
process aborts at load:

    Aborting from rt/sections_elf_shared.d(915) DSO already registered.

DMD and LDC use different DSO-registration data layouts behind the same symbol.
Linking any DMD-compiled object that self-registers into an LDC host triggers
the same abort at host startup. This is survivable in principle — SystemLinker
never iterates `ModuleInfo` (it `dlsym`s the unittest and DWARF unwinding finds
`.eh_frame` via `.eh_frame_hdr`/`dl_iterate_phdr`, not the druntime registry),
so the generated `.so` simply must not self-register — but it shows category 3
is divergent, contrary to the plan.

## Finding 3 — `extern(D)` calling convention diverges (decisive)

This kills the in-process approach. An LDC host calling a DMD-compiled function
of the same signature prints:

    extern(C) DMD-fn from LDC host: got 1234  expected 1234  -> OK
    extern(D) DMD-fn from LDC host: got 4321  expected 1234  -> ABI MISMATCH

For inputs `(1,2,3,4)` the `extern(D)` result is `4321`: **DMD and LDC pass
`extern(D)` parameters in opposite orders.** They are not ABI-compatible.

This is not a corner case. DMD-codegen'd test code calls `extern(D)` druntime
and phobos functions constantly — `object.Exception.__ctor`, array runtime
helpers, formatting, etc. If those functions are the host's single LDC-compiled
druntime, every such call scrambles its arguments. Observed directly: a bare
`new Exception("x")` from a DMD `.so` crashes inside LDC's `Exception.__ctor` →
`Throwable.next` because the constructor's arguments (including `this`) arrive
in the wrong registers.

The "C-ABI firewall" only guards two surfaces — the host→generated entry point,
and exceptions unwinding back out. It does nothing for the thousands of
`extern(D)` calls the generated code makes *inward* into druntime. There is no
LDC flag to emit DMD's `extern(D)` ABI, and the embedded dmd-backend emits DMD's
ABI by definition (that is the codegen under test). So a single shared druntime
cannot serve both an LDC host and DMD-codegen guests.

## Consequence for the plan

The boldest form ("LDC-compiled DMD codegen, then jump in-process to the
generated code") cannot work. The fork the plan left open — *how far in-process
we get* — resolves to: **not at all for execution.** But the split is clean:

- **Frontend rows (parse + semantic) — the big, safe win.** These execute **no**
  generated code; they only parse/analyze. Building `bin/bench` with LDC roughly
  halves them (plan table: ~1798 ms → ~1066 ms) with zero ABI exposure. This is
  the headline number and it is free of every problem above.
- **Post-parse rows (codegen + link + run).** Codegen (the embedded dmd-backend,
  the part we want fast) can be LDC-built. But the `dlopen`+run step must run in
  **DMD-compiled** code so `extern(D)` matches the generated `.so`. That is
  the plan's own fallback rung: *exec a tiny DMD-compiled executor for the run
  step.* Execution crosses a **process** boundary, not an **ABI** boundary. Note
  this must be `exec` of a separate DMD-built binary — a `fork` of the LDC host
  is still LDC code and still mismatches.

Recommended pivot (supersedes the plan's Phase 1 EH-shim / Phase 2 in-process
firewall): build the tool with LDC for the frontend/codegen win, and run
generated tests through a small DMD-compiled executor subprocess. Phases 1–2 as
written (EH shims, in-process firewall) are obviated by Finding 3.
