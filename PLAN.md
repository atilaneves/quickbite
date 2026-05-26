# Pure Backend Test Package Handoff

The pure language-surface tests have been moved under
`tests/ut/backends/pure_/` on branch `pure-test-package`.

Commits so far:

- `eb3305c` Move eval tests under pure backend package
- `afe6a4a` Move project cerealed tests under pure backend package
- `ed6ab95` Move pure backend parity tests into package

Verification already run:

- `dub test -- ut.backends.pure_.arrays ut.backends.pure_.control_flow
  ut.backends.pure_.diagnostics ut.backends.pure_.eval
  ut.backends.pure_.expressions ut.backends.pure_.logic
  ut.backends.pure_.structs ut.backends.pure_.minicereal
  ut.backends.pure_.projects.cerealed ut.backends.minicereal`
- `dub test`
- `./bin/ut -l`

The moved tests preserve their original backend matrices. That means many
`pure_` tests already run with `ExecutorBackend.dmdCtfe`, but not every
individual `pure_` test currently has a CTFE variant.

Next step: try out every test in `pure_` with CTFE. The next agent must audit
all `tests/ut/backends/pure_/**/*.d` modules, identify tests that do not
currently run under `ExecutorBackend.dmdCtfe`, and try adding CTFE coverage for
each one. Preserve existing behaviour for backends that cannot support a test;
do not weaken or delete tests to make the suite pass.
