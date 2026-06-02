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
- Start with the smallest useful `eval` slice that can make exactly one
  approved behavior test fail.
- After `tests/ut/backends/pure_/lang/eval.d`, target
  `tests/ut/backends/pure_/lang/logic.d` as the first parsed-module test
  module. Start with `logicalNot`, then plain `&&` and `||` cases before
  call-based or short-circuit cases.
- If the slice needs unittest blocks, integer literals, equality, calls,
  returns, and assert handling all at once, the test is too broad; pick a
  smaller test.
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
- For `pure_` language-surface tests, treat CTFE as the canonical oracle for
  supported behaviour unless the completed DMD codegen backend demonstrates
  that compiled D code behaves differently.
- CTFE coverage reports do not rank Quickbite test modules by simplicity. All
  backend `pure_` language modules run against CTFE, so choose post-`eval`
  targets by required D language features, not by file length or coverage
  counts.
- Verify each new slice before expanding scope: red test, minimal
  implementation, green suite, then the next slice.
- Do not add unsupported-diagnostic paths unless a test verifies the exact
  diagnostic behavior.

## PR 97 Review Lessons
- Before coding a bytecode slice, ask what is the smallest behavior that should
  fail and what code may be deleted while that test still passes.
- Delete speculative opcodes, operands, frame fields, helper functions, and
  public APIs. If a first test does not need calls, locals, returns, or a halt
  instruction, do not add them yet.
- Keep the DMD dependency only in the compiler module. The bytecode program
  representation and VM must not import DMD AST or declaration types.
- Keep modules separate from the start: backend adapter, compiler, bytecode
  program representation, and VM. Do not hide all bytecode logic in the backend
  adapter.
- Use the existing runtime `Value` type unless a test forces a bytecode-specific
  value representation. Do not invent int-only stack or operand types as a first
  step.
- Make operands earn their shape. Avoid a generic `long` operand, ad hoc
  integer-specialized operands, or a half-built sum type unless the current test
  proves that shape is needed.
- Do not split one language operation into one opcode per scalar type unless
  the VM semantics genuinely differ. Prefer one opcode with a typed operand
  domain, for example a cast opcode plus a target-type operand, before adding
  `castInt`, `castFloat`, or similar families.
- Do not add module-level helpers that only wrap a single call unless they make
  an active test simpler. Prefer inlining or overloading when that is clearer.
- Keep names precise and conventional: use "variables" for variable metadata,
  "indices" as the plural of index, and avoid names such as
  `bytecode.bytecode`.
- Preserve the repo's formatting style before asking for review. Formatting
  churn distracts from the design slice.

## Assumptions
- Direct parser-to-bytecode generation is out of scope; AST-first lowering is
  the right starting point.
- The bytecode VM is optimized for unittest latency, not long-running execution
  throughput.
- JIT compilation is a future experiment, not a requirement for the first
  design.
- The VM should remain independent of DMD internals except at the compiler
  boundary.
