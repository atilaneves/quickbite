# Bytecode VM Architecture Plan

## Summary
Design a new bytecode VM for D that minimizes unittest latency from an edit to
an ok/fail result. The system should compile from semantically analyzed D ASTs
into an internal bytecode artifact, execute that artifact in-process, and avoid
object files and linker involvement on the hot path.

The architecture should borrow the useful parts of LuaJIT: compact bytecode,
explicit operand domains, a small interpreter core, deterministic emission, and
strong separation between compiler and VM. It should not borrow the JIT or the
Lua-specific bytecode shape.

## Core Architecture
- Use a register-oriented VM model rather than a pure stack VM, so temporaries,
  call setup, and nested expressions stay explicit and cheap.
- Keep the bytecode format compact and rigid, with a small set of opcodes and
  typed operand kinds such as function reference, local slot, constant index,
  comparison kind, and jump target.
- Make the compiled artifact self-contained: code stream, constant pool,
  function table, frame metadata, and debug or line info live together but are
  logically separate.
- Keep the frontend and VM boundary hard. AST and semantic lookup belong in the
  compiler layer; the VM should consume only bytecode-native ids and metadata.
- Make bytecode deterministic to emit and easy to disassemble so test failures
  and cache behavior are reproducible.
- Keep the interpreter small and direct. Prefer a minimal dispatch loop and
  explicit frame bookkeeping over a deep abstraction stack.

## Implementation Direction
- Start with the smallest useful slice: unittest blocks, integer literals,
  equality and comparison, simple calls, returns, and assert handling.
- Add locals, branches, and broader expression support only when a test forces
  the next slice.
- Keep unsupported behavior explicit and diagnostic rather than silently
  lowering or guessing.
- Preserve a strict compile-AST-then-execute-bytecode pipeline; do not route
  the new VM through existing lowering machinery as the baseline design.
- Treat bytecode as an internal artifact, not a public interchange format or a
  serialization compatibility promise.

## Test Plan
- Use public behavior tests only for language semantics and backend parity.
- Add focused VM contract tests only for bytecode-specific properties such as
  operand typing, frame behavior, and diagnostic boundaries.
- Keep unsupported-slice tests narrow and behavior-driven, not layout-driven.
- Prefer parity with compiled D behavior or canonical frontend semantics when a
  language-surface question is involved.
- Verify each new slice before expanding scope: red test, minimal
  implementation, green suite, then the next slice.

## Assumptions
- Direct parser-to-bytecode generation is out of scope; AST-first lowering is
  the right starting point.
- The bytecode VM is optimized for unittest latency, not long-running execution
  throughput.
- JIT compilation is a future experiment, not a requirement for the first
  design.
- The VM should remain independent of DMD internals except at the compiler
  boundary.
