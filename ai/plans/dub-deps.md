# Dub Dependencies

Goal: per-edit work should scale with the project under test, not with
its dependency tree. The driving metric is save-to-test-results latency.
We do not yet know what dominates that latency for real dub projects;
every step beyond the next one is data-directed, not assumed.

## Guiding principle

Prefer caches keyed on content/identity at module (or function)
granularity over a first-class "dependency" concept. Dependencies are
the modules that usually don't change, so they fall out as the entries
that never miss. The two places "dependency" is forced to be a real
concept: delegating to dub-built artifacts (dub owns invalidation), and
a possible future native dependency image (ffi.md §3-§20, deferred).

Caching addresses lowering/compiling only, never execution. Whether
dependencies "live" as .a/.so libraries or as cached bytecode is per
backend and to be explored later: SystemLinker has no alternative to
libraries; for the VM backends FFI and interpreted bytecode must both
be tried and measured. FFI is needed regardless for `fbody is null`
leaves (C/C++/Rust, closed source) — see ffi.md §21.

## Done

PR #215 (2026-06-12): SystemLinker links dub-built dependency archives
instead of codegen'ing dependency modules per run, matching `dub test`.

- `SystemLinker` takes `linkFiles` and `archiveImportPaths`; modules
  under the latter skip root promotion (no per-run semantic3) and
  codegen, and stay in the link set so the rod prune doesn't treat
  their types as foreign. Archives are group-wrapped on the link line.
- The bench builds the dub package first (`dub describe` reports
  archive paths whether or not they exist), classifies import paths
  outside the package dir as dependency paths, and no longer prepends
  the root package's own `bin/lib<name>.a` (the project under test is
  compiled fresh; only dependencies are prebuilt).
- Verified: dub-built `.a`s are PIC-clean on Linux x86_64 (no TEXTREL,
  loads under `-z defs`). `dub describe --data=linker-files` lists only
  dependency archives, never the root package's own.

## Next: make --dub actually measure (blocks everything below)

`bin/bench --dub=<pkg>` currently skips every fixture that has a
`module` declaration: the per-iteration frontend measurement
(`parseModuleUncached`) re-parses the fixture, which collides with the
first parse's entry in DMD's package symbol table. DMD emits "conflicts
with another module" and hands back the old module (dmodule.d, failed
`dst.insert`; there is no eviction or overwrite in the load path).
`prepareFixtureRuns` wraps parse and measurement in one try/catch, so
the whole fixture drops out and the post-parse sections never run.
Real packages' fixtures are module-declared, so --dub measures nothing.

Fix: separate the frontend-measure failure from the parse failure so
`runTests` timings still happen on the cached module; report the
frontend row as unmeasurable for module-declared fixtures instead of
dropping the fixture. Needs a bench-behaviour test (approval gate).

## Then, in order

1. Benchmark random dub projects: make `--dub` robust across package
   layouts and grow the corpus. Known-good simple entry: cerealed
   git-hash (0.6.12) -> concepts (one dep; concepts is template-only so
   its archive is nearly empty — proves plumbing, not savings).
   Meatier: unit-threaded 2.2.3 (8 concrete-code dep archives). Note
   `findPkgDir` sorts versions lexically and picks the last, so the
   git-hash dir wins over 0.6.8.
2. Instrument the bench with a per-phase breakdown of the edit cycle:
   one-time cold dependency parse+sema (currently in no measurement
   window at all), then per-edit root parse+sema, semantic3 of imports,
   codegen split by project vs dependency source path, link, fork,
   execution. For VM backends: lowering vs execution split, execution
   time attributed by the module the executing function came from.
3. Pick the next lever from the data, one at a time:
   - VM lowering dominates -> in-process bytecode cache keyed on
     function identity (falls out of the warm process; unchanged
     modules keep their AST objects).
   - Dependency execution dominates -> FFI / native image discussion,
     gated on a microbenchmark of boundary cost (libffi call vs
     interpreting the body).
   - Link dominates (known true for SystemLinker today: ~30ms of ~43ms
     median is the spawned `dmd -shared`, see dmd-backend.md lesson
     14) -> shrink link inputs, cache unchanged-module objects,
     faster linker.
   - Project-module re-sema dominates on multi-module projects -> the
     fork-for-sema extension (see dmd-backend.md); only then is the
     same-FQN reload problem worth attacking.
