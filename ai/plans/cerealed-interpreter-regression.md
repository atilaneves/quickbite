# Cerealed interpreter regression handoff

## Goal

Make this exact command succeed without skipped rows or backend disagreement:

```sh
./bin/bench.sh -b interpreter -b system-linker --dub cerealed -w 0 -r 1
```

The expected successful shape is a `cerealed interpreter 156/156` row and a
`cerealed system-linker 156/156` row. Around 12 seconds and 8 GiB of
interpreter allocation are established normal behaviour for this benchmark;
do not pursue a performance or GC-policy change as part of this fix.

## Bisect

Direct runs of the exact command established this boundary:

| Revision | Result |
| --- | --- |
| `02c0c9b5` `Remove Interpreter host display model` | passes: 156/156 on both backends |
| `efefe6475` `Remove Interpreter mirrored local storage` | fails: Cerealed is skipped |

`efefe6475` is the first bad commit. It removes the interpreter's mirrored
local-value tables and replaces `nativeRefLocalAddresses` with the single
`thisAddress` field in `Walker`.

## Observed failure

At `efefe6475`, the interpreter and SystemLinker disagree on Cerealed's
property tests `__unittest_L12_C1_1` through `__unittest_L12_C1_20` and
`__unittest_L18_C7`. The interpreter's result is:

```text
Unsupported eval expression: address of this_
```

The good revision completes all 156 tests, so use `02c0c9b5` as the semantic
oracle for the interpreter implementation, alongside SystemLinker for D
behaviour. Do not retain the old mirrored-local design wholesale: identify the
specific receiver-address lifetime that it preserved and express that through
the post-migration frame/place model.

The relevant transition is in
`source/quickbite/backends/interpreter/impl.d`:

- `bindThisReferenceAddress` changes a per-`vthis`
  `nativeRefLocalAddresses` mapping into `Walker.thisAddress` plus a frame
  reference slot.
- Member-function receiver rebinding switches its `this` expression address
  lookup from `bindingPointerValue(currentFunction.vthis)` to `thisAddress`.
- Function-entry code stops copying `locals`, so any replacement must retain
  the authoritative caller receiver place across nested calls without reviving
  a detached value copy.

Compare those sections directly between `02c0c9b5` and `efefe6475` before
changing code.

## Scope guardrails

- Do not change `benchmarks/harness.d`, benchmark GC policy, benchmark sample
  counts, or Cerealed's property-test count. None caused this regression.
- Do not mask failures with omissions or skips; both backends must report the
  same passing test set.
- Add a focused language-surface regression test only after first proving it
  fails on the current interpreter and passes on SystemLinker, per `AGENTS.md`.
- Run the exact command after the fix. A focused unittest alone is insufficient
  evidence.
