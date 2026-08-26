# Test-suite latency

## Goal

Cut `bin/ut` wall time massively without losing oracle coverage. The
suite's cost is scaffolding, not tests: actual unittest bodies execute in
sub-millisecond time, and almost all wall time is per-fixture native
compile/link/load machinery.

## Measured baseline (2026-08; re-measure, never trust recorded numbers)

Do not re-measure by running the suite. Take the numbers from the CI log
of a recent PR (the `bin/ut --random ~@LLVMJit ~@Ctfe` step), or run one
module: `bin/ut -c <tag filters> ut.backends.runner.lang.<module>` and
aggregate each test's chrono duration by its trailing `.Backend` tag.
`bin/ut` is single-threaded (`versions "unitUnthreaded"` in dub.sdl), so
summed per-test durations equal wall time.

Cost classes, largest first:

1. The native backends, SystemLinker and LLVMJit, take nearly all suite
   time. Per fixture in one representative module, SystemLinker is ~20x
   the frontend cache-miss leg; the Interpreter/Bytecode bodies
   themselves are microseconds, so the non-native legs' cost is the
   frontend, not the backend. The ci.sh gate is SystemLinker-bound.
2. The cost is broad-based across the fixture corpus, not a few slow
   outliers. Known exception to investigate:
   `struct.returnedNestedStructWithoutCapturesLeavesCallerLocalsInPlace.Interpreter`
   takes seconds on its own (a bug, not scaffolding).
3. Per-test native cost grows through a run (quartile means rise within
   a single module). Candidates: GC heap (per-test `GC.collect`, fork page
   tables), DMD's module tables, and `snapshotInlineAsmInstructions`
   (`frontend/dmd/functions.d`), which walks every module in
   `Module.amodules` on every fixture parse — quadratic in fixture count.
4. Phase split of one native test: frontend semantic analysis (on a
   parse-cache miss), `Runtime.loadLibrary`, the external `dmd -shared`
   link chain, the codegen fork, and `GC.collect` + unload. Parse and the
   unittest body are negligible. The parse cache shares one parse+sema
   across all backend legs of a fixture (first leg misses, the rest hit).

## Decisions

1. **SystemLinker is an oracle in `bin/ut` and a product in the benchmark
   binary** (maintainer, 2026-08-17). In the unit suite, per-fixture
   codegen + link + load exists only to produce the native answer, so it
   may be replaced by any equally-real native execution of the same
   fixture. The benchmark keeps exercising the full pipeline as a
   product, and its cross-backend pass counts are the check on it.
2. **Polymorphic fixtures, via a template parameter.** The fixture
   string becomes a template argument:
   `runBackendSourceFixtureTests!(backend, q{...})`. One template serves
   both legs: for the oracle it `mixin`s the string into its own
   instantiation scope and invokes the unittests it finds there; for every
   other backend it passes the string as today. The native leg is compiled
   once by ninja, in parallel and incrementally, and answers at
   function-call cost. The matrix (`Matrix!`/`Omit!`) does not change: the
   oracle column moves, it does not disappear. The conversion is one
   scripted pass over the corpus, not a file-by-file campaign.
3. **The string-only residue stays string-based**: fixtures asserting
   compile-time refusals, runtime-built sources (sandbox paths, generated
   import modules, `Evaluator.eval`), the dependency-image/FFI corpus,
   the pollution tests, custom `FrontendFlags` sites, `Because.unassertable`
   pins, and `Because.diverges` pins.
4. **A thin SystemLinker machinery test set stays in `bin/ut`** so a
   broken link path is caught before the benchmark run.
5. **Serial execution is not a goal.** `unitUnthreaded` exists only
   because the DMD frontend is on every test's path and the backends call
   into DMD at run time. Once the frontend is off the run path (batch
   sema, item 4) and the backends' remaining DMD calls are locked
   (item 5), `unitUnthreaded` is deleted and unit-threaded runs tests in
   threads. No process-sharding wrapper; parallelism is unit-threaded's.
6. **Ctfe stays serial** under the compiler mutex it already takes.
7. **Snippet-path native coverage after the swap** comes from the REPL
   test with `system-linker` selected, a string-oracle mode of the same
   template run on a schedule or on merge to master (not per PR), and
   LLVMJit back in the gate once its cost allows.

## Contracts and invariants the work depends on

- DMD's backend is strictly once-per-process; codegen always forks
  (codegen.d). This fork cost is structural for any in-process object
  emission.
- Unloading a fixture `.so` is the documented hazard (GC-held vptrs into
  unmapped code). Whether one process can safely load many snippet
  `.so`s, or one ORC JITDylib can hold many fixtures' objects, is
  unproven either way. Settle by experiment before any batching design.
- `GroupedRunner.runTests(Module[])` (runner.d) batches N modules into
  one artifact, one load, one run. Only the benchmark uses it.
- Fixture census: 1341 of 1384 `runBackendSourceFixtureTests` sites pass
  a bare `q{}` literal (re-run:
  `grep -rnE 'runBackendSourceFixtureTests!\w+\(q\{' --include='*.d'
  tests` versus the same grep without `q{`); 43 pass a named string or
  `text(...)`. Named sites whose string is a compile-time constant
  convert too. 182 sites use `shouldThrow*` and need a wrapper, not
  exclusion. Fixture bodies reuse type names (`S`, `C`, `Holder`, ...)
  freely, so each mixin needs its own scope.
- The run path never takes the compiler mutex today (`withCompilerLock`
  is used by the REPL and Ctfe only); the serial guarantee is
  `unitUnthreaded` alone.
- Both string backends call into DMD at run time, and batch sema of the
  fixture roots does not remove this because druntime/phobos bodies are
  only analysed when first called:
  - lazy `functionSemantic3` + `runDeferredSemantic3`
    (`frontend/dmd/functions.d` `ensureFunctionBodySemantic`): Interpreter
    `impl.d:110, 3528, 3680, 5011, 5434` plus raw calls at `9741, 9800`;
    Bytecode `core/compiler.d:589-591`. Cached after first reach, so the
    contention is warm-up, not permanent.
  - `semantic2` on non-root variables through the `__gshared Scope`
    freelist: Interpreter `impl.d:3027-3046`, Bytecode
    `core/compiler.d:10997-11014`.
  - `Type.merge` via `mutableOf`/`unSharedOf`/`pointerTo` (writes
    `__gshared Type.stringtable`): Interpreter `impl.d:5517, 11288, 12939`,
    `place.d:450-470`, `native_call_adapter.d:739, 795`.
  - Bytecode compile-time `expressionSemantic` (`core/compiler.d:11628`)
    and `parseSnippet` (`core/compiler.d:12622`).
  - write-once caches on shared nodes (`mangleString`, `builtin`,
    `isabstract`, `requiresClosure`, `getConstInitializer` -> `global.gag`).
- The backends' own state is TLS or per-instance (no `__gshared` under
  `backends/interpreter`, `backends/bytecode`, `backends/ir`; IR is
  threadable as-is). Exception: `ffi.d:24-35` dependency-image ABI tables
  are TLS filled only by the backend constructor, so a worker thread
  falls back to the host ABI.
- DMD's CTFE engine is one `__gshared` arena and stack
  (`dinterpret.d` `ctfeGlobals`) that writes stack slots into the AST
  (`VarDeclaration.ctfeAdrOnStack`). It cannot be threaded.
- `parseRootModulesLocked` (`compiler.d`) already parses N roots as one
  set, phase by phase, with one deferred drain, one flag apply, one
  stderr capture, one inline-asm snapshot. Gaps for fixtures: it reads
  files from disk (no string-source overload), one failing module aborts
  the whole set, and it does not set `checkAction=context`.
- Per-parse overhead `parseSnippet` pays that a batch pays once: mutex,
  `global.path` push/pop, ~20 `global.params` writes for flags, `dup2` of
  fd 2, three `runDeferred*` drains, `snapshotInlineAsmInstructions`.
- Fixture classes that cannot share a batch: compile-refusal (the failed
  `Module` stays registered and its leftovers in `Module.deferred*` drain
  into the next parse), `FrontendFlags` (process-wide `global.params`,
  part of the cache key), pollution (the ordering is the test),
  runtime-built sources and `Evaluator.eval` (source exists only inside
  the test body), and any fixture depending on an import path being
  absent (batch import paths are a union on `global.path`).
- Non-DMD serial assumptions: `llvm_jit.d:131-133` and
  `codegen.d:258-262` fork assuming no other thread holds the compiler
  mutex (a locked mutex copied into the child deadlocks it);
  `compiler.d` `capturedStderr` swaps fd 2 process-wide during parse.

## Remaining work, in order

1. **Conversion spike.** Convert one representative module to the
   template-parameter form end to end. Settle: unittests nested in a
   template-instance scope (`__traits(getUnitTests)` on the
   instantiation); assertion/diagnostic text that carries `file:line`
   (`diagnostics.d`); the `shouldThrow*` wrapper (mixin into a callable
   run under `shouldThrow*`, not a bare unittest); module-level state and
   module ctors (`module_state.d`), which are likely residue.
2. **Corpus conversion.** One scripted pass over the bare-`q{}` sites and
   the compile-time named-constant sites; delete the per-fixture
   SystemLinker string legs it replaces. Acceptance: the gate's wall time
   in the CI log drops; the native leg runs the same fixture text.
   Residue per decision 3 is out of scope.
3. **Snippet-path coverage** (decision 7): make `tests/run_repl.py` cover
   `system-linker` if it does not; add the string-oracle mode and a
   scheduled or merge-to-master run of it.
4. **Batch sema.** String-source overload of `parseRootModulesLocked`
   naming modules `snippet_N` and pre-populating `sourceCache` with the
   harness's key (`checkaction=context` salt + flags) so existing call
   sites hit. Collect the fixture strings from the template
   instantiations at startup. Residue classes stay per-test under the
   lock. Acceptance: no per-fixture `snapshotInlineAsmInstructions` walk
   in the batched path.
5. **Threads.** Route the run-time DMD calls listed above through the
   compiler mutex (Interpreter: the lazy-sema entries and `Type.merge`
   users, or structural comparison as `sameBaseType` already does;
   Bytecode: `withCompilerLock` around `compileFunctionBody`/`compile` so
   only `run` is concurrent, and pre-warm the `parseSnippet` at
   `core/compiler.d:12622`). Make `ffi.d:24-35` `__gshared` behind the
   same mutex. One backend instance per thread. Fix fork-under-lock in
   `llvm_jit.d`/`codegen.d`. Then delete `versions "unitUnthreaded"`.
6. **LLVMJit cost.** Experiments before any design: (a) how much of its
   per-test cost is state growth (fork of a growing heap) versus JIT
   work; (b) grouped execution of N fixtures per child via
   `GroupedRunner` — blocked on the duplicate-symbol experiment above;
   (c) overlapping forked test children — prototype before believing it.
7. **State growth.** After items 2 and 4, measure what growth remains for
   the string legs and whether periodic process recycling is worth
   building. File the slow-Interpreter-test outlier from cost class 2 as
   its own issue.
