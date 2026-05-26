# Plan: IR Language Design Follow-Ups

## Context

The current IR has been useful for interpreter coverage, but the review found
several language-design issues that will make future bytecode, JIT, caching,
and richer D semantics harder. This plan records those findings as independent
implementation items.

Each item below is at most one PR. Do not combine two findings in one PR. If an
item turns out to be too large for one coherent PR, stop after the smallest
green TDD slice and update this plan with the remaining work.

Use strict TDD for every item:

1. Start from a green baseline.
2. Propose the next failing behaviour test and wait for approval before adding
   or modifying it.
3. Add the smallest failing test for the behaviour.
4. Make the dumbest implementation change that turns it green.
5. Run the focused test and `dub test`.
6. Refactor only while the suite is green.
7. Ask for feedback after the refactoring step.

## Items

### 1. Add an explicit IR value and type model

PR goal: make value categories part of the IR language instead of recovering
them from producer and consumer conventions.

PR 42 improves scalar storage by moving toward `Value`, but the IR still lacks
declared temporary or result types. A future implementation should add an
IR-level type model for scalar values and handles. The design should make
integer width, signedness, bool, floating-point values, aggregate handles,
function references, and null/reference categories explicit enough for
validation and later code generation.

Drive this with behaviour tests that fail because the current IR cannot
distinguish value categories reliably, such as currently excluded assertion
diagnostics for bools or chars, or operations involving high-bit unsigned
values. Keep the first PR narrow: one visible behaviour, the minimum type
representation needed for it, and no speculative full D type system.

### 2. Replace string and order based symbol identity

PR goal: introduce stable IR identities for symbols instead of using names and
array position as semantic identity.

Calls currently refer to callee names, and function pointer values depend on
`module.functions` order. The first PR for this item should introduce IR-owned
ids for functions only. Executor-friendly dense indices may still be produced
as a layout step, but they should not be the language-level identity.

Globals/statics, fields, and types also use string or structural conventions
today. Treat each of those as a separate follow-up item when a failing
behaviour needs it; do not fold them into the first function-identity PR.

Drive this with a test where function name or order based identity is ambiguous
or fragile, such as same-named functions in different scopes, reordered lowered
functions, or function pointer equality/dispatch that should not depend on
incidental array order.

### 3. Add first-class lvalues or places

PR goal: model D locations directly instead of relying on copy-in/copy-out
`ref` parameter writeback and special lowering-side writeback conventions.

The IR should be able to represent locations such as local slots, globals,
struct fields, array elements, and associative-array entries. Loads, stores,
and call-by-reference should operate on those places. This should make aliasing,
mutation order, `ref` parameters, `out` parameters, ref returns, and field or
element references part of the IR language rather than executor conventions.

No concrete red-test candidate is currently known. Do not start this item from
the representation change. First identify a small dependency-free behaviour
test that fails today because the current copy-in/copy-out model cannot express
the required aliasing or mutation order. If no such failing behaviour exists,
leave first-class places deferred.

### 4. Generalise bit-pattern operations

PR goal: replace source-pattern-specific bit operations with a general IR
concept for reinterpretation.

Double bit reinterpretation is currently an executor-side convention of
double-specific operations and helper functions. A future implementation may
model this as a general `Bitcast`/`Reinterpret` operation with explicit source
and destination types, or as typed memory access through the place model if the
source D construct is memory-based.

No concrete red-test candidate is currently known. Do not start from the
representation change. First identify a behaviour test that fails today and
requires bit reinterpretation without hardcoding one recognised source pattern.
If no such failing behaviour exists, leave this item deferred.

### 5. Move exception handling out of counted instruction slices

PR goal: make exception handling an explicit control-flow property instead of
`TryCatch(bodyLength, handlerLength)` over the following instructions.

A future implementation should represent protected regions, handlers, caught
types, exception values, and cleanup edges as validated IR structure. Prefer a
smaller exception table over the existing linear stream for the first PR if it
removes counted inline slices as the semantic contract. Do not introduce a
general block-based IR in this item unless the approved failing exception test
cannot be fixed coherently without it.

Drive this with a nested or transformed exception-control-flow behaviour that
is fragile under counted ranges. Do not attempt complete D exception semantics
in one PR; start with one typed catch or one nested protected-region case.

### 6. Add explicit function signatures and call result shapes

PR goal: make function and call contracts part of the IR language.

Functions and call sites should describe parameter types, passing modes, return
type or return arity, calling convention, and whether a result is produced.
Void calls should not manufacture a meaningful value. Aggregate returns,
reference returns, delegates, and native calls should have a place to express
their shape before those behaviours are implemented broadly.

Drive this with one behaviour where the current `hasReturnValue`,
`numParameters`, and `refParameters` metadata is insufficient, such as a
reference-shaped return, delegate call, native call, or aggregate return that
requires hidden result storage rather than a single temporary handle. Keep the
first PR to the signature information needed for that behaviour.

### 7. Move IR control flow toward explicit blocks

PR goal: avoid making relative instruction offsets the IR language's primary
control-flow model.

Relative offsets are fine as a compact executor encoding, but the IR should be
validated in terms of explicit targets and successors. A future implementation
should introduce basic blocks with terminators, or another explicit target
model, then lower that structure to linear offsets for execution if that
remains the fastest encoding.

Drive this with a test or validation case that benefits from explicit control
flow, such as rejecting an invalid jump target, preserving control flow during
instruction insertion, or preventing jumps into protected exception regions.
Start this only after the exception-handling item has either stayed on a linear
stream plus metadata or explicitly chosen blocks for a proven exception case.
Keep this separate from exception handling unless that earlier item already
forced a block representation as its single coherent change.

## Verification

Every PR from this plan must run:

1. The approved focused behaviour test.
2. `dub test`.
3. `benchmarks/run.sh` before opening the PR.

For PRs that change runtime representation or dispatch strategy, call out the
benchmark result explicitly in the PR notes.
