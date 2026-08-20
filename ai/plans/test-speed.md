# Test-suite latency

## Goal

Cut `bin/ut` wall time massively without losing oracle coverage. The
suite's cost is scaffolding, not tests: actual unittest bodies execute in
sub-millisecond time, and almost all wall time is per-fixture native
compile/link/load machinery.

## Measured baseline (2026-08; re-measure, never trust recorded numbers)

Re-measure with: `ninja bin/ut && bin/ut -c`, then aggregate each test's
chrono duration by its trailing `.Backend` tag. `bin/ut` is single-threaded
by design (`versions "unitUnthreaded"` in dub.sdl, because DMD owns
process-global compiler state), so summed per-test durations equal wall
time and are the true split.

Cost classes found, largest first:

1. The two native backends, SystemLinker and LLVMJit, take nearly all
   suite time between them; Ctfe, Interpreter, Bytecode and the untagged
   infra tests together are a small fraction. The ci.sh gate
   (`bin/ut --random ~@LLVMJit ~@Ctfe`) is therefore SystemLinker-bound.
2. The cost is broad-based across the fixture corpus, not a few slow
   outliers.
3. Per-test native-backend cost grows through a run (last quartile of the
   log is markedly slower than the first). Both native backends fork per
   test and the SystemLinker path runs `GC.collect` per test; both costs
   scale with accumulated process state, so the suite slows superlinearly
   as fixtures are added. Re-measure: quartile-average the `-c` log in
   file order per backend tag.
4. Phase split of one native test (gdb timestamps cross-checked with
   `strace -T` on single-test runs; `strace -f` inflates child timings,
   do not use it for magnitudes): the big per-test phases are frontend
   semantic analysis (on a parse-cache miss), `Runtime.loadLibrary` of
   the fixture `.so`, the external `dmd -shared` link chain, the codegen
   fork, and `GC.collect` + unload. Parse itself and the unittest body
   are negligible. The parse cache verifiably shares one parse+sema
   across all backend legs of a fixture in one process (first leg
   misses, the rest hit).

## Decisions

1. **SystemLinker is an oracle in `bin/ut` and a product in the benchmark
   binary** (maintainer, 2026-08-17). In the unit suite, per-fixture
   codegen + link + load exists only to produce the native answer, so it
   may be replaced by any equally-real native execution of the same
   fixture. The benchmark keeps exercising the full
   codegen-object-link-load pipeline as a product.
2. **Polymorphic fixtures.** One `q{}` token string, two instantiations:
   mixed into the DMD-built test binary as real code (the native oracle
   leg, compiled once at build time by ninja, parallel and incremental)
   and passed as a string to the backends under test (unchanged). The
   native leg answers at function-call cost. `bin/ut` and SystemLinker
   both use the DMD backend, so the oracle's compiler family does not
   change.
3. **The string-only residue stays string-based**: fixtures asserting
   compile-time refusals, runtime-built sources (sandbox paths, generated
   import modules), the dependency-image/FFI corpus, the pollution tests
   (per-snippet isolation is their point), `Because.unassertable` pins,
   and `Because.diverges` pins (one fixture text with per-backend
   expected outcomes cannot be one mixin).
4. **A thin SystemLinker machinery test set stays in `bin/ut`** so a
   broken link path is caught before the benchmark run, after fixtures
   stop exercising it per test.
5. **Serial in-process execution stays.** `unitUnthreaded` is deliberate.
   Any parallelism comes from fork/process boundaries; test distribution
   belongs to unit-threaded, and no process-sharding mechanism exists
   today — one would have to be built there, not scripted around the
   binary. Do not evaluate sharding before the oracle swap lands; the
   residue it would parallelise may be small.

## Contracts and invariants the work depends on

- DMD's backend is strictly once-per-process; codegen always forks
  (codegen.d). This fork cost is structural for any path that emits
  objects in-process.
- Unloading a fixture `.so` is the documented hazard (GC-held vptrs into
  unmapped code). Whether one process can safely *load* many snippet
  `.so`s, or one ORC JITDylib can hold many fixtures' objects, is
  unproven either way: every snippet carries the same lightning-rod
  module, and duplicate-ModuleInfo/duplicate-symbol behaviour is not
  stated in code. Settle by experiment before any batching design.
- `GroupedRunner.runTests(Module[])` (runner.d) already batches N modules
  into one artifact, one load, one run. Only the benchmark uses it; the
  unit suite always passes a single module.
- The fixture census (grep patterns recorded in the conversion item
  below) found: the large majority of fixture call sites are single pure
  `q{}` literals expecting success; the next-largest group expects a
  runtime throw (`.shouldThrow*`) and needs a wrapper, not exclusion;
  small fixed sets are compile-refusal, runtime-built, custom
  `FrontendFlags`, or helper-body sites. Fixture bodies reuse type names
  (`S`, `C`, `Holder`, ...) freely, so each mixin needs its own scope.

## Remaining work, in order

1. **Conversion spike.** Convert one representative test module to
   polymorphic fixtures end to end: settle the per-fixture scoping
   pattern (own template/struct scope per mixin to avoid type-name
   collisions), the expected-runtime-failure wrapper (mixin into a
   callable run under `shouldThrow*`, not a bare unittest), and how a
   fixture's matrix drops the SystemLinker leg while gaining the native
   leg without weakening `Omit!` discipline (the oracle column moves,
   it does not silently disappear). The census is re-runnable with:
   `grep -rnE 'runBackendSourceFixtureTests!\w+\(q\{' --include='*.d'
   tests` versus the same grep without the `q{` suffix, plus
   `grep -rn ShouldFail\|shouldThrow\|FrontendFlags`.
2. **Corpus conversion.** Convert the pure-`q{}` success fixtures and the
   `.shouldThrow*` fixtures file by file, deleting each converted
   file's per-fixture SystemLinker executions as it lands. Acceptance
   per file: the gate command's wall time drops; the native leg runs the
   same fixture text. Compile-refusal, runtime-built, FFI, pollution,
   diverges and unassertable sites are out of scope (decision 3).
3. **LLVMJit cost.** The oracle swap does not touch LLVMJit (a product
   backend, though the ci.sh gate already omits it). Experiments before
   any design: (a) how much of its per-test cost is the state-growth
   class (fork of a growing heap) versus JIT work — measure fork cost
   against heap size across a run; (b) grouped execution of N fixtures
   per child via the existing `GroupedRunner` — blocked on the
   duplicate-symbol experiment above; (c) overlapping forked test
   children (each child is a copy-on-write snapshot, so parent-side
   frontend work on the next fixture cannot corrupt a running child) —
   prototype before believing it.
4. **State growth.** Identify which accumulated state makes per-test cost
   grow: GC heap (per-test `GC.collect` and fork page tables), DMD's
   module tables (`_moduleCounter` growth is a known, commented concern
   in compiler.d), loaded-image registries. The oracle swap removes the
   per-test `GC.collect`+unload for converted fixtures; measure what
   growth remains for the string legs and whether periodic process
   recycling is worth building.
