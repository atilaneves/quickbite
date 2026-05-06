# IR Specification

## Purpose

Project-owned intermediate representation used by IrInterpreterExecutor
and BytecodeExecutor. The TreeWalkingExecutor does not use this IR.

No dmd.* types appear anywhere in ir.*. The lowering layer
(quickbite.frontend.lowering) is the only code that reads DMD AST nodes
and writes IR nodes.

## Current State

The following IR modules exist:

    quickbite.ir.instruction  — Instruction SumType and instruction structs
    quickbite.ir.function_    — Function metadata and instruction stream
    quickbite.ir.test         — Test { instructions[], numTemporaries }
    quickbite.ir.module_      — Module { functions[], tests[] }

Function returns are already explicit: `ReturnValue` is an instruction
in the function body. `Function` no longer has a separate `returnValue`
field.

Unittest bodies currently terminate by reaching the end of their
instruction stream. Before bytecode encoding, add an explicit void
terminator so tests and functions both have uniform terminators:

    struct ReturnVoid {}

    alias Instruction = SumType!(
        ConstInt, Call, BinaryOp, UnaryOp, Select, JumpIfFalse,
        JumpIfTrue, Copy, CastInt, Assert_, ReturnValue, ReturnVoid,
    );

Emit `ReturnVoid` as the last instruction of each lowered test body.
Update IrExecutor to treat it as successful test termination.

## No Blocks Yet

Basic blocks are still not needed. Control flow is represented by a flat
instruction list plus relative jumps. Do not add blocks until a supported
language slice makes the flat representation materially harder to encode
or execute.

## Supported Instructions

    ConstInt    — %dst = const_int <value>       produces int32 temporary
    Call        — %dst = call <name>             produces callee return value
    BinaryOp    — %dst = binary %left, %right    arithmetic/comparison
    UnaryOp     — %dst = unary %source           integer/bool unary ops
    Select      — %dst = select %cond, %a, %b    conditional value
    JumpIfFalse — jump unless %condition
    JumpIfTrue  — jump if %condition
    Copy        — %dst = copy %source
    CastInt     — %dst = cast_int %source        integer truncation/sign
    Assert_     — assert %cond                   consumes bool, no result
    ReturnValue — return %value                  terminates function body

## Temporary Numbering

Sequential per body starting at 0. Already implemented.

## Types

There is no general Type node. DMD has already resolved types; most
instruction choices encode semantics implicitly. Integer casts carry an
`IntegerType` target. Add broader type nodes only when implicit encoding
becomes ambiguous, such as float equality or pointer comparisons.

## Lowering Contract

The lowerer reads semantically-analysed DMD nodes, emits only the
instructions above, and rejects unsupported constructs with explicit
diagnostics. It must not crash or silently skip unhandled forms.
