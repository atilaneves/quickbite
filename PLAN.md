# Review-Response Plan — PR #15

Enable cerealed tests across VM backends.
Approved changes in response to the agent code-review comment.

## TDD rule for this plan

For behavior changes, stop and ask approval before adding or modifying the
test. The approved test must fail first, then the implementation should make
the smallest green step.

Mechanical review fixes such as visibility annotations, comments, attributes,
and enum refactors do not need a red behavior test. Validate them with
compilation and `dub test`.

## 1. Explicit `private` on new unlabelled free functions in `ir.d`

Complete.

`source/quickbite/backends/ir.d` — add `private` keyword to every new
free function that lacks an explicit access annotation. The module has
`private:` at top but AGENTS.md requires both. Functions to check
include: `executeFunction`, `executeFunctionPointer`,
`executeFunctionBody`, `executeInstructions`, `reserveNullStructHandle`,
`reserveNullArrayHandle`, `arrayCanFind`, `enforceNonZeroDivisor`,
`arraysEqual`, `assocArrayIndex`, `assocArrayValue`,
`writeAssocArrayValue`, `appendArrayValues`, `appendArrayValue`,
`updateSliceArrayAlias`, `writeArrayValue`, `updateArrayAlias`, and any
others added by this PR without an explicit access keyword.

## 2. `IntBinaryOp` enum + `final switch` in `runIntegerBinaryOperation`

Complete.

`source/quickbite/backends/tree_walking.d` — replace the `char`-based
`switch`/`assert(false)` with:

```d
private enum IntBinaryOp : char {
    add    = '+',
    sub    = '-',
    mul    = '*',
    shl    = '<',
    bitAnd = '&',
    bitXor = '^',
    bitOr  = '|',
}
```

Change the `op` parameter type to `IntBinaryOp` and use `final switch`.
Update call sites to pass the enum member instead of a char literal.

## 3. Safety attributes in `dmd_ctfe.d`

Blocked. `runCtfe` and `ctfeFailed` cross the
`@safe`/`@system` `ctfeFailureMessage` boundary, and the plan explicitly says
not to add `@trusted` to `ctfeFailureMessage`,
`directThrownExceptionMessage`, or `newExceptionMessage`. No changes were left
for this item.

`source/quickbite/backends/dmd_ctfe.d`:
- `runCtfe` → add `@safe`
- `ctfeFailed` → add `@safe`
- Do NOT add `@trusted` to `ctfeFailureMessage`,
  `directThrownExceptionMessage`, or `newExceptionMessage`.

## 4. IR catch across function calls

Complete in recent commit `a9319d5` (`Support IR try/catch around calls`).

Before editing tests, ask approval for an IR-only regression in
`tests/ut/language.d` where `try { f(); } catch (Exception) { ... }` catches an
exception thrown by `f`.

Make the approved test fail first. Then implement real IR catch propagation
across function calls instead of only handling a direct `throw` in the `try`
body.

## 5. IR `finally` return ordering

Complete in recent commit `7b379e1` (`Support IR finally return ordering`).

Before editing tests, ask approval for a regression where the return expression
is evaluated before the `finally` body mutates state used by that expression.

Make the approved test fail first. Then fix lowering so the return value is
captured before the `finally` body runs.

## 6. Real math and runtime lowering

Complete in recent commit `7cc2417` (`Support IR runtime math intrinsics`).
The commit covers tests and production code in `tests/ut/language.d`,
`source/quickbite/ir/instruction.d`, `source/quickbite/frontend/lowering.d`,
and `source/quickbite/backends/ir.d`.

Verification reported for this item:
- `dub test`: 499 passed.
- Focused item 6 plus item 4/5 checks: 10 passed.
- `git diff --check`: passed.

Before editing tests, ask approval for runtime-input regressions covering
`isNaN`, `isInfinity`, `signbit`, `fabs`, `sqrt`, and non-literal `pow`.

Make the approved tests fail first. Then implement real behavior for these
operations instead of lowering them as constants or no-ops.

## 7. Collision-free IR function pointer identity

Remaining.

Before editing tests, ask approval for an internal lowering regression proving
function pointer values are collision-free IDs, not hashes of names.

Make the approved test fail first. Then assign function IDs during lowering and
use those IDs in IR indirect-call dispatch.

## 8. Nested slice alias writeback

Remaining.

Before editing tests, ask approval for a slice-of-slice writeback regression if
the current test is insufficient.

Make the approved test fail first. Then update alias writeback so writes
through nested slice chains propagate to the original backing array.

## 9. Cerealed length-width handling

Remaining.

Before editing tests, ask approval for regressions showing that `grain` length
type comes from the second template argument and that decode reads that exact
width.

Make the approved tests fail first. Then read the second template argument when
present, default to `ushort`, and thread `lengthTypeByteCount` through decode.

## 10. Temporary `ref` writeback

Remaining.

Before editing tests, ask approval for a regression where a locals byte-array
field is passed by `ref` and the callee's mutation is written back to the
owner.

Make the approved test fail first. Then carry owner and byte-offset metadata
through call-argument propagation and write modified values back after calls.

## 11. Guard and semantic cleanup

Remaining cleanup.

These are review fixes that do not need new red behavior tests unless the
implementer discovers an observable failing case:

- Guard `isGroupedCerealArrayElementType` so `type !is null` is checked before
  scalar-byte-count calls.
- Guard nested struct map propagation with an `in` lookup before reading
  `structFields[sourceOwner]`.
- Tighten no-argument `opSlice()` redirection to known input-range receivers.
- Replace fragile `expressionChars` name dispatch with declaration/type-based
  semantic checks where supported, or explicit unsupported diagnostics.
- Add a helper for template-argument extraction and guard `call.f` before use
  in `tryRunArrayDecerealiseGrain`.

## 12. Documentation comments

Remaining comments.

Add short code comments for:

- The nested struct-copy invariant: nested field maps are propagated only for
  plain struct copies, not fresh literals or decerealise results.
- `tryReadOutputRangePayload` returning `false` on truncation as an intentional
  best-effort fallback.
- Byte-offset packing being tied to `structLiteralCerealBytes` field order and
  encoding.
- Why `foreachUnitTestDeclaration`'s visitor cannot be `nothrow`.

## 13. Deferred follow-up

Split broad removal of cerealed and unit-threaded tree-walking shortcuts into a
dedicated follow-up PR. Do not let that larger cleanup block this review
response.

## Remaining handoff

The next agents should continue with items 7, 8, 9, and 10 under the same TDD
approval rule. Item 3 remains blocked by the explicit no-`@trusted` constraint.
Item 11 is partially done: the null/type guard, struct-map `in` lookup,
`opSlice` receiver check, and `call.f` guard are present, while the broader
`expressionChars` semantic cleanup still needs review. Item 12 is partially
done: comments exist for the nested struct-copy invariant and truncated
payload fallback, while the byte-offset packing and
`foreachUnitTestDeclaration` `nothrow` comments are still missing.

After the remaining behavior items and cleanup, run final `dub test` and
`benchmarks/run.sh` before opening or updating the PR.

## Verification

For behavior items, run the focused approved test red before implementation and
green after implementation. After each editing session, run `dub test` in this
worktree.
