# IR Specification

## Purpose

Project-owned intermediate representation used by IrInterpreterExecutor
and BytecodeExecutor. The TreeWalkingExecutor does not use this IR.

No dmd.* types appear anywhere in ir.*. The lowering layer
(quickbite.frontend.lowering) is the only code that reads DMD AST nodes
and writes IR nodes.

## Supported D Constructs

### Statements
- Compound / scope
- Expression statement
- Return (void and value)
- If / else
- For loop
- Throw (lowered to assert false)
- Import (ignored)

### Expressions
- Integer literals
- Arithmetic: `+` `-` `*` `/` `%`
- Bitwise: `&` `|` `^` `<<` `>>`
- Comparison: `==` `!=` `<` `<=` `>` `>=` (signed and unsigned)
- Logical: `&&` `||`
- Unary: `-` `!` `~`
- Integer casts
- Function calls
- Assert
- Variable declarations and assignments
- Compound assignment: `+=` `-=` `|=`
- Post-increment: `i++`
- Array literals, slice, length (`$`), index, append (`~=`), equality
- Struct field read and write

## Lowering Contract

The lowerer reads semantically-analysed DMD nodes, emits IR, and rejects
unsupported constructs with explicit diagnostics. It must not crash or
silently skip unhandled forms.
