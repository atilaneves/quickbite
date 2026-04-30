# IR Specification

## Purpose

Project-owned intermediate representation used by IrInterpreterExecutor
and BytecodeExecutor. The TreeWalkingExecutor does not use this IR.

No dmd.* types appear anywhere in ir.*. The lowering layer
(quickbite.frontend.lowering) is the only code that reads DMD AST nodes
and writes IR nodes.

## Current State

The following already exist and are not changed by this spec:

    quickbite.ir.instruction  — ConstInt, Call, Equal, Assert_  (SumType)
    quickbite.ir.function_    — Function { name, instructions[], returnValue, numTemporaries }
    quickbite.ir.test         — Test { instructions[], numTemporaries }
    quickbite.ir.module_      — Module { functions[], tests[] }

## Required Addition: Explicit Return

Function encodes its return value as a uint field rather than an
instruction. That works for the IR interpreter but makes bytecode
encoding awkward: the encoder must special-case return instead of
iterating a uniform instruction stream.

Add to the instruction SumType:

    struct ReturnValue { uint value; }   // function returning int
    struct ReturnVoid  {}                // unittest body

    alias Instruction = SumType!(ConstInt, Call, Equal, Assert_, ReturnValue, ReturnVoid);

Update Function: remove returnValue field; emit ReturnValue as the last
instruction of the body. Update Test: emit ReturnVoid as the last
instruction. Update lowering and both executors to match.

This change is required before implementing BytecodeExecutor but not
before TreeWalkingExecutor.

## No Blocks Yet

Basic blocks with branch terminators are not needed until we add control
flow. The existing flat instruction list per Function/Test is sufficient.
Do not add blocks until a supported language slice requires branching.

## Supported Instructions

    ConstInt    — %dst = const_int <value>       produces int32 temporary
    Call        — %dst = call <name>             produces callee-return-type temporary
    Equal       — %dst = equal %left, %right     produces bool temporary (int32 == int32 only)
    Assert_     — assert %cond                   consumes bool, no result
    ReturnValue — return %value                  terminates function body
    ReturnVoid  — return                         terminates test body

## Temporary Numbering

Sequential per body starting at 0. Already implemented.

## Types

No explicit type nodes yet. DMD has already resolved types; instruction
choice encodes semantics implicitly. Add a Type node when implicit
encoding becomes ambiguous (e.g. float equality, pointer comparisons).

## Lowering Contract

The lowerer reads semantically-analysed DMD nodes, emits only the
instructions above, and rejects unsupported constructs with explicit
diagnostics. It must not crash or silently skip unhandled forms.
