# Minimal IR Plan

## Goal

Define the smallest project-owned IR that is sufficient to represent
this program after DMD parsing and semantic analysis:

```d
int foo() {
    return 42;
}

unittest {
    assert(foo() == 42);
}
```

This document is intentionally narrow. It is not a general IR design
for the whole D language. It is an implementation target for the first
vertical slice only.

For the early VM roadmap, treat this document as authoritative for the
first end-to-end implementation. Do not add locals, branching, source
locations, symbol tables, or broader type machinery until this slice
parses, lowers, encodes, and executes successfully.

## Non-Goals

Do not design for:

- full-language coverage
- optimization
- bytecode generation
- SSA
- local variables
- control flow beyond straight-line execution
- function parameters
- overload resolution outside whatever DMD semantic analysis has already
  resolved
- preserving DMD nodes in the IR

The point of this IR is to establish a project-owned boundary
immediately after semantic analysis.

## Compilation Scope

This IR exists to support compiling one selected `unittest` plus only
the free functions that unittest directly needs for the first slice.

That means:

- the compilation driver selects one `unittest`
- the lowerer emits one `Test` for that selected body
- only directly referenced zero-argument free functions are lowered
- unrelated top-level declarations are ignored for this slice

This is a latency optimization, not just a simplification.

## Design Constraints

- No `dmd.*` types may appear in `ir.*`.
- The IR must be simple enough to construct in strict TDD style.
- The IR must be close to execution semantics, not source syntax.
- The IR must be narrow enough that unsupported constructs can be
  rejected explicitly.
- Naming should rely on package/module namespacing, not `Ir` prefixes.

## Package Layout

Only create the modules needed for this slice:

```text
source/ir/
  module.d
  function.d
  test.d
  block.d
  instruction.d
  type.d
  package.d
```

Do not add `symbol.d`, `constant.d`, or anything else yet unless
implementation friction forces it.

## Representation Overview

Use a very small typed, register-like IR:

- `Module` owns top-level functions and unittest bodies.
- `Function` owns exactly one entry block.
- `Test` owns exactly one entry block.
- `Block` is a linear list of instructions plus a terminator.
- Instructions write results into numbered temporaries when needed.
- Terminators end blocks.

For this first slice, there is no branching and no multiple blocks per
body. Still use `Block` now so the shape does not need to be
reinvented when control flow is added later.

Do not add placeholder fields for future features. Add structure only
when a supported slice requires it.

## Type Model

Create `source/ir/type.d`.

Define the minimal type enum needed for the sample:

```d
module ir.type;

enum Kind
{
    int32,
    bool_,
    void_
}

struct Type
{
    Kind kind;
}
```

Notes:

- Use `bool_` instead of `bool` because `bool` is a keyword-like
  builtin type name in D code and is awkward as an enum member.
- `void_` is needed because `assert` does not produce a value and tests
  do not return a user-visible value.
- Do not add widths, qualifiers, signedness flags, or aggregate types yet.

## Value Model

Do not create a separate `Value` type yet.

Use temporary ids directly in instructions:

- temporaries are numbered `uint`
- every instruction that produces a result writes to one temporary id
- instructions that consume values refer to source temporary ids

Constants are introduced by dedicated instructions such as `ConstInt`.

This is enough for the current slice and avoids inventing an
abstraction too early.

## Instruction Set

Create `source/ir/instruction.d`.

Use a tagged union or sum-type style struct layout. The implementation
can choose the exact D encoding, but the semantics must match this
model.

### `ConstInt`

Produces one temporary of type `int32`.

Fields:

- `uint destination`
- `int value`

Example:

`%0 = const_int 42`

### `Call`

Produces one temporary of the callee return type.

Fields:

- `uint destination`
- `string calleeName`

For this slice:

- only zero-argument calls are supported
- only direct calls by name are supported

Do not add argument arrays yet.

Example:

`%0 = call foo`

### `Equal`

Produces one temporary of type `bool`.

Fields:

- `uint destination`
- `uint left`
- `uint right`

For this slice:

- only `int32 == int32` is supported

Example:

`%2 = equal %0, %1`

### `Assert`

Consumes one boolean temporary and does not produce a value.

Fields:

- `uint condition`

Example:

`assert %2`

## Terminators

Also define terminators in `source/ir/instruction.d` unless a separate
module becomes clearly necessary.

Only one terminator is needed now.

### `Return`

Fields:

- `bool hasValue`
- `uint value` when `hasValue` is `true`

Semantics:

- functions returning `int32` use `hasValue == true`
- unittest bodies use `hasValue == false`

This is slightly clumsy, but it avoids premature abstraction. If
desired, the implementation may instead use separate `ReturnValue` and
`ReturnVoid` variants.

## Block

Create `source/ir/block.d`.

Suggested shape:

```d
module ir.block;

struct Block
{
    Instruction[] instructions;
    Terminator terminator;
}
```

Requirements:

- instructions execute in order
- a block always has exactly one terminator
- for this slice there is exactly one block per function/test body

Do not add labels, predecessors, successors, or block ids yet.

## Function

Create `source/ir/function.d`.

Suggested shape:

```d
module ir.function;

struct Function
{
    string name;
    Type returnType;
    Block entry;
}
```

Requirements:

- only free functions are supported
- only zero-argument functions are supported
- only one function body shape is supported:

```d
return <int literal>;
```

The lowered `foo` body for the sample program should be:

1. `ConstInt(destination: 0, value: 42)`
2. `Return(hasValue: true, value: 0)`

## Test

Create `source/ir/test.d`.

Suggested shape:

```d
module ir.test;

struct Test
{
    Block entry;
}
```

Do not add names, ids, source locations, or attributes yet.

There is only one supported unittest body shape:

```d
assert(<zero-arg function call> == <int literal>);
```

The lowered unittest body for the sample program should be:

1. `Call(destination: 0, calleeName: "foo")`
2. `ConstInt(destination: 1, value: 42)`
3. `Equal(destination: 2, left: 0, right: 1)`
4. `Assert(condition: 2)`
5. `Return(hasValue: false)`

## Module

Create `source/ir/module.d`.

Suggested shape:

```d
module ir.module;

struct Module
{
    string name;
    Function[] functions;
    Test[] tests;
}
```

Requirements:

- `name` may be the parsed module name or a filename-derived fallback
- the module contains only top-level declarations needed for the
  selected unittest slice
- no globals, imports, aliases, enums, structs, or classes yet

For the sample program:

- `functions.length == 1`
- `functions[0].name == "foo"`
- `tests.length == 1`

## Package Module

Create `source/ir/package.d` that publicly imports:

- `ir.block`
- `ir.function`
- `ir.instruction`
- `ir.module`
- `ir.test`
- `ir.type`

The goal is to make tests and lowerers import `ir` package surface
instead of many individual modules.

## Supported Source Forms

The lowering layer only needs to support the following semantically
analyzed constructs.

### Top Level

- one or more free functions
- one or more `unittest` blocks
- deterministic selection of one `unittest` body for lowering

### Function Body

Exactly:

- a compound statement containing a single `return`
- that return expression is an integer literal

### Unittest Body

Exactly:

- a compound statement containing a single `assert`
- the assert expression is equality
- the left-hand side is a direct zero-argument function call
- the right-hand side is an integer literal

Everything else must produce an explicit unsupported diagnostic or test failure.

## Lowering Contract

The DMD adapter is responsible for:

- parsing source
- import resolution
- semantic analysis
- handing the lowering layer semantically analyzed declarations/expressions

The IR lowerer is responsible for:

- rejecting unsupported shapes
- constructing only project-owned `ir.*` types
- not storing `dmd.*` pointers or references

The lowering pipeline for this slice is:

1. parse source with DMD
2. run semantic analysis
3. enumerate top-level declarations
4. select one `unittest` deterministically
5. lower supported free functions needed by that `unittest` into
   `Function`
6. lower the selected `unittest` block into `Test`
7. assemble `Module`

Do not lower every `unittest` in the module in the first slice.

## Temporary Numbering Rules

To keep tests deterministic, use simple sequential numbering per body:

- start at `0` for each `Function`
- start at `0` for each `Test`
- assign temporaries in instruction order

Example for `foo`:

- `%0 = const_int 42`
- `return %0`

Example for the unittest:

- `%0 = call foo`
- `%1 = const_int 42`
- `%2 = equal %0, %1`
- `assert %2`

## Equality And Comparison Semantics

For this slice:

- `Equal` on `int32` returns `bool`
- no implicit conversions need to be modeled in IR
- DMD semantic analysis should already have resolved the expression types

If a semantically analyzed expression is not exactly supported by this
slice, reject it instead of attempting coercions.

## Assertions

Model `assert` as an explicit IR instruction, not as a call.

Reason:

- it is a core language/runtime operation
- it preserves intent better than lowering immediately to a runtime helper
- later bytecode generation can decide how to encode assertion failure

Do not add custom assertion messages yet.

## Diagnostics Policy

Unsupported constructs must fail explicitly.

At minimum, the lowerer should distinguish:

- unsupported top-level declaration
- unsupported function signature
- unsupported function body
- unsupported unittest body
- unsupported expression kind

The exact diagnostics API is outside this document, but the
implementation must not silently skip declarations.

## Testing Plan

Write tests before each implementation step.

### 1. IR Data Shape Tests

Create unit tests that construct IR objects directly and verify:

- `Module` contains functions and tests
- `Function` stores name, return type, and entry block
- `Test` stores entry block
- instructions and terminators preserve field values

These tests lock down the pure data model.

### 2. Expected Sample IR Test

Create a unit test that manually constructs the exact expected IR for
the sample source.

Expected function body:

```text
Function foo
  entry:
    %0 = const_int 42
    return %0
```

Expected unittest body:

```text
Test
  entry:
    %0 = call foo
    %1 = const_int 42
    %2 = equal %0, %1
    assert %2
    return
```

This test is the canonical description of the first supported slice.

### 3. Frontend Smoke Test

Create a test that proves DMD can parse and semantically analyze the
sample source. Do not lower anything yet.

### 4. Function Lowering Test

Given the semantically analyzed sample source, verify that `foo` lowers to:

- one `ConstInt`
- one `Return`

### 5. Unittest Lowering Test

Given the semantically analyzed sample source, verify that the unittest
lowers to:

- `Call`
- `ConstInt`
- `Equal`
- `Assert`
- `Return`

### 6. End-To-End Module Lowering Test

Given the whole sample source, verify the resulting `Module` contains exactly:

- one function named `foo`
- one test
- the expected instruction sequences

### 7. Negative Tests

Add failing tests for unsupported constructs:

- function with parameters
- non-`int` return type
- function body with multiple statements
- function body returning a non-literal
- unittest with multiple statements
- unittest using anything other than `assert(call() == intLiteral)`

The implementation should fail clearly for each case.

## Suggested Implementation Order

1. Implement `ir.type`
2. Implement `ir.instruction`
3. Implement `ir.block`
4. Implement `ir.function`
5. Implement `ir.test`
6. Implement `ir.module`
7. Implement `ir.package`
8. Write the manual expected-IR test
9. Implement the minimal lowerer for `foo`
10. Implement the minimal lowerer for the unittest
11. Implement end-to-end module lowering
12. Add negative-path diagnostics and tests

## What To Keep Out For Now

Do not add any of the following until the first slice is passing:

- source ranges
- symbol tables
- generic operand/value abstractions
- constant pools
- metadata attributes
- multiple blocks
- branches
- locals
- parameters
- globals
- field access
- arrays
- string literals
- runtime helper calls
- bytecode writer

Every one of these expands the surface area without helping support the
sample program.

## Acceptance Criteria

This IR implementation is complete for the first slice when:

1. The IR modules exist under `source/ir/`.
2. No `ir.*` type depends on `dmd.*`.
3. A test can lower the sample source into project-owned IR.
4. The resulting IR exactly matches:

```text
Module
  functions:
    foo -> int32
      entry:
        %0 = const_int 42
        return %0
  tests:
    entry:
      %0 = call foo
      %1 = const_int 42
      %2 = equal %0, %1
      assert %2
      return
```

5. Unsupported constructs are rejected explicitly rather than ignored.
