# Spike findings: the embedded frontend's gap to distro `dmd` is the GC

Toolchain: distro `dmd` 2.112.0, `ldc2` 1.42.0 (LLVM 21.1.8, DMD 2.112.1
frontend), `dmd:frontend` 2.112.0 — the embedded frontend and the distro
binary share the *same frontend version*, so any speed difference is build
config, allocation strategy, or measurement scope, never frontend code. Host:
Intel Core Ultra X7 358H, `powersave` governor (heavily thermally throttled
during this session — read absolute ms as a band and trust the *interleaved*
deltas and the thermal-independent GC counters). The spike was throwaway; its
reproducers are inlined so this write-up is self-contained.

## The question

`bench.md`'s "Caveat for readers of the numbers" records that even an LDC-built,
`-O` embedded frontend stays ~1.6× a distro `dmd` doing the same cerealed
parse+semantic (~1052 ms vs ~650 ms), and pins the residual on **PGO** as "the
remaining lever". This spike set out to either land PGO or find the real cause.

It found the real cause, and it is not PGO.

## Dead end 1 — PGO is marginal (~5%)

A full two-phase LDC PGO build of `bin/bench` (instrument → train on the
cerealed frontend parse → `ldc-profdata merge` → `-fprofile-use`) builds and
runs correctly (156/156), and the profile genuinely covers the hot dependency
code (28 501 functions, `_D3dmd…typesem/stringtable/…` all present — so the
instrumentation reaches `dmd:frontend`, not just the root). Measured
interleaved (alternating launches, same thermal state) against a same-config
non-PGO baseline:

| cerealed frontend (n=25 each) | baseline LDC `-O` | PGO `-fprofile-use` | delta |
| ----------------------------- | ----------------- | ------------------- | ----- |
| min (throttle-robust)         | 1292 ms           | 1246 ms             | −3.5% |
| median                        | 1705 ms           | 1599 ms             | −6.2% |

A consistent ~5% shift across the whole distribution — real, but tiny, and
nowhere near the ~400 ms gap to distro `dmd`. This matches `bench.md`'s own
recurring finding that this pointer-chasing tree walker barely responds to
backend optimisation ("DMD's optimiser barely helps", "ThinLTO ruled out").
PGO+ThinLTO was also built (LDC `-flto=thin -linker=lld`) on the same premise;
it was abandoned once the GC finding below made it moot. **Do not productise
PGO for the frontend number — it optimises the ~10% that is actually frontend
code.**

## The real cause — the AST is GC-allocated

Profiling the parse (`perf record -F 1999 -g`) shows where the time goes:

    63.7%  core.internal.spinlock.SpinLock.lock
    16.3%  core.internal.gc.bits.GCBits.setLocked
     9.5%  core.internal.gc.impl.conservative … mark
     ~2%   _D3dmd… (actual frontend code barely registers)

~90% of *samples* are druntime GC. The spinlock share is inflated by LDC's
parallel-mark worker threads spin-waiting (CPU%, not wall-clock), but
druntime's own GC profiler confirms the wall-clock cost is real and large.
`--DRT-gcopt=profile:1` on one cerealed parse:

    Number of collections:  8
    Total mark time:       255 ms
    Grand total GC time:   284 ms
    GC summary:  376 MB,  8 GC,  284 ms

**376 MB of AST allocated through `GC.malloc`, 8 collections, 284 ms in
collection alone** — plus the per-allocation GC-lock overhead on every one of
millions of AST nodes, which is *mutator* time not counted in the 284 ms.

### Why: the library defaults to GC, the binary does not

`dmd/root/rmem.d` (the frontend's allocator) gates every `xmalloc`/`xrealloc`/
`xfree` on one flag:

    __gshared bool _isGCEnabled = true;   // rmem.d:118 — library default
    static void disableGC() { _isGCEnabled = false; }   // -> malloc bump arena

The **`dmd` binary** calls `mem.disableGC()` at startup (the non-`-lowmem`
default), so AST nodes come from a malloc bump arena that is never individually
freed — ideal for a short-lived compile that frees everything at process exit.
The **library** ships `_isGCEnabled = true` so long-lived tool/IDE users get
GC-reclaimed memory. **Quickbite never calls `disableGC`**, so the embedded
frontend pays full GC cost the distro binary does not. That is the ~1.6×.

## Confirming the cause — switch to the arena

Disabling the GC for the AST recovers almost the entire gap. Measured
interleaved, same-config builds, same thermal state:

| cerealed frontend (n=12 each)        | min     | median  |
| ------------------------------------ | ------- | ------- |
| GC-on (current)                      | 1055 ms | 1064 ms |
| malloc arena + no GC collections     | 761 ms  | 766 ms  |
| **delta**                            | **−27.8%** | **−28%** |

761 ms vs distro `dmd`'s ~650 ms: the GC was essentially the whole gap; the
residual ~110 ms is PGO (~5%) + measurement scope + malloc-vs-pure-bump. The
arena build is also far more *deterministic* (no GC pauses): median sits 5 ms
off the min instead of 9+. GC profiler on the arena build: 1 collection,
117 MB, 22 ms — versus 8 / 376 MB / 284 ms.

## Why it is not a one-line fix — two integration hazards

Naively flipping `disableGC` globally does **not** work; both hazards below are
why the productised fix needs care (and its own slice), not why the diagnosis
is in doubt.

1. **Ordering.** Calling `disableGC` inside quickbite's `Compiler` init aborts
   with `realloc(): invalid pointer`: dmd's *module constructors* populate the
   identifier `StringTable` with the GC on *before* that init runs, then the
   parse `xrealloc`s those GC blocks via C `realloc`. The flag must be set
   before any dmd module ctor — a `pragma(crt_constructor)` (ELF init, before
   druntime's module-ctor pass) does that and removes the abort.

2. **GC-referenced-from-arena.** With the arena on but the GC still
   *collecting*, the parse segfaults in `dmd.typesem.merge`: dmd stores
   pointers to GC-allocated strings (`idup`s) inside malloc'd AST nodes the GC
   never scans, so a collection frees them, dangling. The distro binary avoids
   this because it effectively never collects. Adding `--DRT-gcopt=disable:1`
   (no collections) fixes it and yields the 761 ms above. So the arena needs
   **both** the malloc switch **and** collections suppressed for the arena's
   lifetime.

3. **Backend scope.** Even with both, a *global* arena segfaults the native
   codegen backend (`-b system-linker`, `exit 139`): the dmd backend also
   allocates through `mem` and does not tolerate the arena/no-collect regime
   the parse does. So the switch must be scoped to the frontend parse, or the
   codegen path kept on the GC.

4. **Not for `bin/ut`.** The fix must not touch the shared frontend
   unconditionally: `bin/ut` parses thousands of snippets in one long-lived
   process, where a never-freeing arena would grow without bound. This is
   exactly why the library defaults to GC-on. Any productised arena is
   bench-scoped (or per-compile-reset), never a blanket global.

## Reproduce

Profile the GC cost of the current (GC-on) bench on the cerealed frontend:

```sh
./bin/bench.sh --DRT-gcopt=profile:1 -w 0 -r 1 -b ctfe --dub cerealed 2>&1 \
  | grep -iE "collections|GC summary"
# -> 8 collections, 376 MB, 284 ms
```

Demonstrate the arena win (throwaway edit, reverted — not in this PR):

```d
// quickbite/frontend/compiler.d, above `shared static this()`:
pragma(crt_constructor)
extern(C) void _qbDisableDmdGc() {
    import dmd.root.rmem: mem;
    mem.disableGC();
}
```

```sh
dub build -c benchmark-ldc -b benchmark-opt --compiler=ldc2
./bin/bench --DRT-gcopt=disable:1 -w 0 -r 1 -b ctfe --dub cerealed
# frontend row ~761 ms vs ~1055 ms unmodified; crashes without disable:1
# (segfault) and crashes under -b system-linker (codegen backend, exit 139).
```

## Consequence

- **For the benchmark:** the frontend row currently measures
  GC-allocation-bound performance the distro `dmd` does not exhibit. A
  bench-scoped arena would make the number trustworthy/comparable and cut it
  ~28%. PGO would add ~5% on top; not worth its checked-in-profile maintenance
  on its own.
- **For the product:** the core goal is minimising unittest latency from any
  edit, and ~28% of every frontend parse is GC overhead the REPL/`ut` loop also
  pays. A per-compile malloc arena (reset between edits, like the dmd binary
  per invocation) is a far larger latency lever than any backend tuning — but a
  separate, careful undertaking (lifetime/reset design, all backends, broad
  testing), out of scope here.
