# Single Oracle: SystemLinker

## Decision (2026-06-13)

There is one behaviour oracle: `SystemLinker` (compiled, linked, executed
native D). It is the oracle for every backend except `Ctfe`:
`Interpreter`, `Bytecode`, `IR`, and any future native backend
(`ai/plans/llvm-jit.md`). Compiled D is what these backends must
reproduce, byte for byte, including assertion-failure and diagnostic text.

`Ctfe` is **not** an oracle. It wraps DMD's `dmd.dinterpret` and is weird
in places (CTFE-only legality, value quirks such as static-array-copy
aliasing, `<double not supported>` float-failure formatting). Where `Ctfe`
diverges from `SystemLinker`, the divergence is *characterized*, not
treated as truth: a test pins what `Ctfe` actually does, and `SystemLinker`
remains the statement of what the behaviour *should* be. `Ctfe` stays
useful as a real-D fixture source (a fixture written for CTFE is real D and
runs by construction) and as a fast, dependency-free check — but it never
arbitrates correctness.

This replaces the earlier two-oracle model (CTFE for compile-time
behaviour, SystemLinker for runtime behaviour) and the per-backend
compile-time/runtime mode that model implied. Reintroducing a CTFE-faithful
mode is deferred until and unless the current CTFE engine is actually
replaced; see the deferred goal in `ai/plans/bytecode.md`.

## Test layout: `ct/` and `rt/`

The `ct/`/`rt/` split survives, redefined by *what the behaviour needs*,
not by which oracle governs (the oracle is always `SystemLinker`):

- `rt/` holds behaviour that needs the runtime environment — libc/OS calls,
  anything that cannot exist except at program runtime. Today the only such
  module is `tests/ut/backends/runner/rt/cstdlib.d`.
- `ct/` holds everything else: the bulk of the language surface, expressible
  as compile-time-checkable behaviour even when `Ctfe` itself cannot execute
  the mechanism (e.g. archive linking).

In a `ct/` block, `static foreach (backend; AliasSeq!(...))` lists `Ctfe`
only where `Ctfe` agrees with `SystemLinker`. Where `Ctfe` diverges, drop
it from that block and add a separate, plain `Ctfe`-tagged unittest in the
same `ct/` file that pins `Ctfe`'s actual behaviour, with a comment naming
the divergence. There is no special directory or label for these
characterization tests — they are ordinary `Ctfe` tests asserting what is,
not what should be.

## Task: remove `ExecutionMode`

Status: done (2026-06-13)

The `ExecutionMode` enum (added 2026-06-11) is dormant scaffolding — the
interpretation backends store `_mode` but never read it — and encodes the
abandoned dual-mode model. Remove it:

- delete the `ExecutionMode` enum from `source/quickbite/backends/runner.d`;
- delete the `_mode` field and its constructor from `TreeNodeBackend`
  (`source/quickbite/backends/package.d`);
- drop the `ExecutionMode` constructor parameter from every backend
  (`ctfe/dmd_ctfe.d`, `native/system_linker.d`, `interpreter/impl.d`,
  `bytecode/impl.d`, `ir/impl.d`) and from the test factory
  (`newBackend`/`runBackend*Fixture*` in `tests/ut/backends/package.d`);
- update the one explicit caller
  (`tests/ut/backends/runner/rt/archive.d`).

`Ctfe` stays inherently compile-time and `SystemLinker` inherently runtime
by virtue of what they are — by class, not by a parameter.

## Task: migrate `rt/` tests to `ct/`

Under the redefinition above, every current `rt/` module except
`cstdlib.d` is misfiled. Move each into `ct/`, applying the
Ctfe-divergence exclusion rule per block:

- `arrays.d` ✓ (done), `control_flow.d` ✓ (done), `expressions.d` ✓ (done),
  `exceptions.d` ✓ (done), `logic.d` ✓ (done), `cerealed.d` ✓ (done),
  `diagnostics.d` ✓ (done), `archive.d` → `ct/`
  (merging into the existing `ct/` file of the same name where one exists).
- `cstdlib.d` stays in `rt/`.

Each moved block keeps `SystemLinker` and whatever other backends already
pass it; `Ctfe` joins only where it agrees, with divergences characterized
per the layout rules above. Test moves and matrix changes still go through
the normal approval gate (AGENTS.md).
