# Wasm benchmark backend (dmd PR #23584)

## Goal

Add a benchmark row that measures dmd PR #23584 — dkorpel's WebAssembly
codegen branch (`dkorpel/dmd:wasm-backend3`, `dmd -mwasm32 -os=wasm`) —
as an external whole-compiler baseline: full wasm-dmd compile of the
fixture plus a wasmtime run, per timed iteration.

## Decisions

- **Subprocess, not in-process.** quickbite links `dmd:frontend
  ~>2.112.0` in-process and the PR changes dmd's frontend glue
  (e2ir/s2ir/tocsym) on top of master. Two dmd frontends cannot coexist
  in one process, so the backend drives a separately built compiler
  binary from the branch. Rejected: vendoring the branch's backend the
  way `vendor/dmd-backend/` does — its glue-layer changes make the
  frontend part of the delta, so the vendor trick does not apply.
- **Opt-in.** Registered in the bench registry, selected with
  `-b wasm`. Not in `defaultBackendNames`, not in `ci.sh`, not in
  GitHub CI. CI must not depend on a draft PR branch staying buildable.
- **Pinned SHA.** The branch is a cleaned-up draft and may be
  force-pushed; the setup script clones a recorded commit, not the
  branch tip.
- **Runner-only class.** The bench registry needs only `Runner`, so the
  class implements `GroupedRunner` and skips `Backend`/`Evaluator`
  entirely. No REPL wiring (`ReplBackendName`) is touched.
- **Per-test results via a generated runner main.** The bench
  correctness gate compares per-test names and outcomes across
  backends, so the default druntime unittest runner's aggregate output
  is not enough. A generated D main iterates
  `__traits(getUnitTests, ...)`, catches `Throwable` per test, and
  prints one machine-readable line per test.
- **Single PR**, no staging across branches.

## Contracts

- Test names and locations must byte-match the other backends':
  `unitTest.ident.toChars` / `unitTest.loc.toChars` from the in-process
  AST, as `SystemLinker.runUnitTest` produces them. The wasm side is
  joined to that enumeration by the `__unittest_L*_C*` identifier,
  which both frontends derive from source positions.
- The constructor must be cheap and must not throw: `makeRunners`
  constructs every registered runner even when the backend is not
  selected. Toolchain lookup (`QUICKBITE_WASM_DMD`, defaulting to
  `vendor/wasm-dmd/`) and validation happen lazily in `runTests`, and
  a missing toolchain fails with a message naming the setup script and
  the environment variable.
- Dub-package groups (`--dub`) are unsupported: `runTests` throws a
  clear message. Building dub dependencies for wasm32 is out of scope.
- The wasm post-parse row includes the external compiler's own
  parse+semantic — a whole-pipeline cost, unlike every other backend.
  The registry entry's comment must say so.

## Work queue

### 1. Toolchain spike + `scripts/setup-wasm-dmd.sh` (go/no-go gate)

Model on `scripts/vendor-dmd-backend.sh`. Clone the pinned SHA, build
the compiler with the host D compiler, build the wasm druntime/phobos.
The druntime/phobos-for-wasm build process is undocumented in the PR;
discover it from the branch's CI config, makefiles, and `rt/wasm`
layout. Install into gitignored `vendor/wasm-dmd/` (compiler, libs,
`dmd.conf` with its `[Environmentwasm32]` section). Preflight-check
`wasmtime` and `wasm-ld`. The script's acceptance step compiles and
runs a unittest-bearing hello-world through the installed toolchain.

If the toolchain cannot be built outside the author's setup, stop and
report; everything below depends on it.

### 2. Backend class, TDD

New package `source/quickbite/backends/wasm/` (`package.d` publicly
imports `impl.d`). `final class Wasm: GroupedRunner`; `runTests`:

1. Enumerate unittests via `foreachUnitTestDeclaration` (names and
   locations per the contract above).
2. Write a runner-main module to a temp dir: import the fixture module
   (name from `module_.ident`), run each unittest, print
   `identifier<TAB>pass|fail<TAB>message` lines.
3. Invoke `<wasm-dmd> -mwasm32 -os=wasm -unittest -of=<tmp>/out.wasm`
   on `module_.srcfile` plus the runner main, with `-I` for the env
   import paths.
4. Run `wasmtime` on the result, parse the protocol lines, join by
   identifier to produce `TestResult[]`.

Tests, written red-first:

- A pure unit test for the protocol-line parser (no toolchain needed).
- One integration test running a small source fixture through `Wasm`,
  tagged `Wasm`; when the toolchain is absent it reports the skip and
  passes so `bin/ut` stays green on machines without the toolchain.
  Register the new test module in `tests/main.d`.

### 3. Benchmark registry

Add `makeWasm` and a `"wasm"` entry in `benchmarks/backends.d` with
the whole-pipeline comment. `defaultBackendNames`, its pinning test,
and `ci.sh` stay untouched.

### Verification

- `scripts/setup-wasm-dmd.sh` ends green (hello-world unittest under
  wasmtime).
- `ninja bin/ut`, then focused runs of the new tests.
- `bin/bench.sh -b ctfe -b wasm`: the default fixture gets a `wasm`
  row and the harness's correctness gate confirms wasm's per-test
  outcomes match `ctfe`'s.
- `ci.sh` before the PR; it needs no wasm toolchain since the backend
  is opt-in.

## Open caveats

- Wasm maps `real` to `double` and lacks sockets and multi-level
  exception chaining; a fixture relying on those will diverge from the
  oracle and surface via the bench correctness gate. Handle divergence
  per AGENTS.md when it appears — no pre-emptive omissions.
