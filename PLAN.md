# Pure Backend Test Package Handoff

The pure language-surface tests have been moved under
`tests/ut/backends/pure_/` on branch `pure-test-package`.

Commits so far:

- `eb3305c` Move eval tests under pure backend package
- `afe6a4a` Move project cerealed tests under pure backend package
- `ed6ab95` Move pure backend parity tests into package

Earlier verification:

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

Handoff rule:

- Every `pure_` language-surface test should run with
  `ExecutorBackend.dmdCtfe`.
- If a `pure_` test does not pass with CTFE, first assume either Quickbite is
  invoking DMD CTFE incorrectly or the test expectation is wrong.
- If CTFE disagrees with another backend, CTFE is canonical until the completed
  dmd codegen backend demonstrates that compiled D code behaves differently.
- Backend-specific tests are allowed only when they do not contradict D
  language behaviour; otherwise mark the backend deficient or fix it.

CTFE coverage audit:

- Added `ExecutorBackend.dmdCtfe` coverage for
  `diagnostics.refParameterOops`, `diagnostics.inFunctionParametersOops`,
  `diagnostics.refSizeTParameterOops`, and
  `control_flow.structMethodReturnDoesNotSkipCallerStatements`.
- Tried `arrays.nestedSliceAppendWritesThroughOuterSliceToOriginalArray` with
  `ExecutorBackend.dmdCtfe`; it fails the fixture assertion, so that test
  is not a valid `pure_` language-surface expectation as written.
- Re-ran the pure-test audit. The only remaining pure test without CTFE
  coverage is the nested-slice append write-through test in
  `tests/ut/backends/pure_/arrays.d`.
- Follow-up research showed this fixture contradicts both DMD CTFE and compiled
  D behaviour: `s2 ~= 99` does not write `99` into `a[3]`. The fixture appears
  to encode an IR aliasing implementation detail, not D language semantics.

Next-agent plan:

1. Ask approval to change the test expectation before editing tests.
2. Convert `nestedSliceAppendWritesThroughOuterSliceToOriginalArray` into a
   CTFE-backed language test that asserts the canonical D behaviour:
   `a[3] == 3` after appending to `s2`.
3. Run the focused test against `ExecutorBackend.dmdCtfe` and confirm it is
   green.
4. Add the same test to the full pure backend matrix. The IR backend should
   fail red if it still propagates the append into the original array.
5. Decide one of these two outcomes:
   - Fix IR slice append alias handling so appending to a nested slice follows
     D semantics while direct element writes through slices still propagate.
   - If the fix is out of scope, mark IR as deficient for this CTFE-canonical
     behaviour and exclude only IR from that test with a clear note.
6. Re-run the pure-test backend-suffix audit and verify CTFE covers every
   `pure_` language-surface test.
7. Run `dub test`.

Verification after CTFE audit:

- `dub test -- ...` for the four focused CTFE tests listed above
- `./bin/ut -l` plus pure-test backend-suffix audit
- `dub test`
