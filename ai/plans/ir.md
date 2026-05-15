# IR Specification

## Purpose

Project-owned intermediate representation used by IrInterpreterExecutor
and BytecodeExecutor. The TreeWalkingExecutor does not use this IR.

No dmd.* types appear anywhere in ir.*. The lowering layer
(quickbite.frontend.lowering) is the only code that reads DMD AST nodes
and writes IR nodes.

## Lowering Contract

The lowerer reads semantically-analysed DMD nodes, emits IR, and rejects
unsupported constructs with explicit diagnostics. It must not crash or
silently skip unhandled forms.
