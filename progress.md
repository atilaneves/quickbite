# Backend Progress

This file summarizes the current state after running two subagents in
parallel: one for the IR backend and one for the tree-walking backend.
Future agents can read this file, `AGENTS.md`, `ai/mistakes.md`, and
`ai/plans/*`, then spawn the same two backend-focused subagents again.

## Current Verification

The latest full suite run passed:

```text
dub test
180 test(s) run, 0 failed.
```

## TDD Process Used

All new behavior was developed in strict TDD style:

- propose exactly one test per backend
- stop for user approval before editing tests
- add the approved test
- run a focused red test
- implement the minimum production change
- run focused green verification
- coordinate one final `dub test`

One approved tree-walker wrapper test was already green, so it added
coverage but did not drive production code. One approved IR offset decode
test was also already green and only added coverage.

## Shared Files Changed

- `ai/mistakes.md`
- `source/quickbite/backends/ir.d`
- `source/quickbite/backends/tree_walking.d`
- `source/quickbite/frontend/lowering.d`
- `source/quickbite/ir/instruction.d`
- `tests/ut/ir.d`
- `tests/ut/tree_walking.d`

## IR Backend Progress

The IR backend moved substantially closer to running the minicereal
wrapper and its byte-buffer checks.

### Tests Added

New IR tests in `tests/ut/ir.d` cover:

- signed `decode!int` for `0xffffffff` yielding `-1`
- default `Minicereal.bytes` length
- direct append to `Minicereal.bytes`
- `Minicereal.put` for `ubyte`
- array equality for `Minicereal.bytes`
- multiple `put` template instantiations in one module
- `put` of an inferred `int` and full-slice byte equality
- bounded slice equality for `ushort` bytes in the middle of a buffer
- `$` slice bounds for tail bytes
- `Minicereal` `ubyte` round trip through `put` and `get`
- high-bit `ulong` round trip and unsigned `>` comparison
- decode from a nonzero `size_t pos` offset
- unsigned `<` comparison for a high-bit `ulong`
- unsigned `<=` comparison for a high-bit `ulong`
- unsigned `>=` comparison for a high-bit `ulong`

### Production Support Added

IR production changes include:

- dynamic-array fields default to empty arrays when a struct is created
- struct method calls pass the receiver as a hidden ref parameter
- `this` field reads and assignments in lowered struct methods
- direct append to struct array fields
- compound assignment stores are cast back to the LHS integer type
- DMD `orAssign`/cast-wrapped compound-assignment shapes are handled
- function keys use `mangleExact`, so template instantiations do not
  collide as plain names like `put` or `encode`
- `ArrayEqual` IR instruction compares array contents, not handles
- full array slices lower by reusing the existing array value
- bounded array slices lower to a new `ArraySlice` IR instruction
- `$` in slice bounds lowers to the current sliced array length
- unsigned `>` lowers to `Operation.unsignedGreaterThan` when either
  operand has unsigned integer type
- unsigned `<` lowers to `Operation.unsignedLessThan` when either
  operand has unsigned integer type
- unsigned `<=` lowers to `Operation.unsignedLessOrEqual` when either
  operand has unsigned integer type
- unsigned `>=` lowers to `Operation.unsignedGreaterOrEqual` when either
  operand has unsigned integer type

### Important IR Notes

Array equality is currently implemented for DMD's generated `__equals`
array equality call shape.

`ArraySlice` copies the requested subrange into a new IR array handle.
This is enough for the currently approved slice-equality tests.

Unsigned comparison support currently covers `>`, `<`, `<=`, and `>=`.

## Tree-Walking Backend Progress

The tree walker is ahead on wrapper and struct-method behavior, and now
covers several serializer-adjacent operations.

### Tests Added

New tree-walking tests in `tests/ut/tree_walking.d` cover:

- `Minicereal` wrapper int round trip
- known-byte decode through `Minicereal.bytes`
- direct append to `Minicereal.bytes`
- known-value encode through `Minicereal.put`
- bitwise `&`, `^`, and unary `~`
- unsigned `<` comparison for a high-bit `ulong`
- unsigned `>` comparison for a high-bit `ulong`
- direct index write to `Minicereal.bytes`
- bounded slice equality for `Minicereal.bytes`
- index write to an array field inside a struct method
- post-increment of a `size_t` field inside a struct method
- reading `this.bytes[this.pos++]` inside a struct method
- appending to `this.bytes` inside a struct method

### Production Support Added

Tree-walking production changes include:

- comma-expression evaluation for DMD-generated array literal forms
- general array literal expression evaluation
- full-slice reads of struct array fields
- direct `~=` support for local struct array fields
- `this.field ~= value` support inside struct methods
- direct index writes to local struct array fields
- index writes to `this` array fields inside struct methods
- reads from `this` array fields inside struct methods
- post-increment on `this` scalar fields
- bounded slices copy the requested dynamic-array range into a new
  mutable array value
- unsigned `<` compares integer operands as `ulong` when either operand
  has unsigned integer type
- unsigned `>` compares integer operands as `ulong` when either operand
  has unsigned integer type
- bitwise `&`, `^`, and unary `~`

### Important Tree-Walker Notes

Several `this` and local-owner field paths are implemented separately.
There may be duplication that should be refactored only after additional
tests force stable behavior.

The tree walker still has an existing test named
`treeWalking.structPassedToFunction` that expects an unsupported
diagnostic. Struct value passing remains intentionally unsupported there.

## New Mistake Recorded

`ai/mistakes.md` now includes:

```text
- When adding a sibling branch under `if (auto x = ...)`, use braces if
  both branches need `x`; otherwise the second branch is outside scope.

- Do not add helper functions to test fixtures just to avoid constant
  folding unless the function has a clear purpose. If a helper function
  is needed, add a comment explaining why; otherwise use the smallest
  direct runtime expression, such as a mutable local when mutation or
  non-const evaluation is needed.

- When the user asks for subagents to continue backend work, do not only
  spawn read-only explorers and then implement everything in the main
  thread. After test approval, delegate bounded implementation work to
  worker agents with disjoint file ownership.
```

The first came from a tree-walker edit around sibling branches under an
`if (auto index = ...)` expression. The second came from an overbuilt IR
test proposal that added a helper function with no fixture-level
explanation. The third came from using subagents only for test proposals
instead of assigning implementation work to worker agents after approval.

## Suggested Next Session Setup

Start by reading:

- `AGENTS.md`
- `ai/mistakes.md`
- `ai/plans/overview.md`
- `ai/plans/ir.md`
- this `progress.md`

Then run:

```text
dub test
```

The baseline should be green. If it is not green, stop and fix or report
the baseline before proposing new tests.

Spawn two workers:

- IR worker: owns `tests/ut/ir.d`, `source/quickbite/ir/*`,
  `source/quickbite/frontend/lowering.d`, and
  `source/quickbite/backends/ir.d`
- tree-walking worker: owns `tests/ut/tree_walking.d` and
  `source/quickbite/backends/tree_walking.d`

Both workers must use strict TDD and stop before each test edit. They
should propose exact test code and explain why the test is the next
smallest useful slice.

## Good Next IR Test Directions

Likely useful next IR slices:

- `Minicereal` round trips for `ushort`, `uint`, `int`, and `ulong`
- signed high-bit or negative wrapper round trips beyond the existing
  negative `int` free-function decode
- array inequality/failure-path tests once array equality has more
  coverage
- unsupported diagnostics for partial slices such as `array[1 .. $]`
  or `array[$ - 1 .. ]`, if they are not meant to work yet
- struct method or array-field operations that still only work in the
  tree walker

Keep each test to one behavior. Avoid adding a full minicereal suite in
one step.

## Good Next Tree-Walker Test Directions

Likely useful next tree-walker slices:

- direct wrapper tests for additional integral widths
- reader/writer structs that combine `this.bytes`, `this.pos`, and
  multiple operations in a minimal way
- unsigned comparison semantics other than `<` and `>` for high-bit
  unsigned values
- struct value passing, if the existing unsupported expectation is ready
  to be replaced by supported behavior

Do not change the existing unsupported `structPassedToFunction` test
without proposing and getting approval for that test change first.

## Stop Conditions

During a future session, stop at user approval boundaries for tests.
After implementation batches, run focused tests and then one coordinated
`dub test`. If the user says to stop after a batch, do not request the
next proposal round.
