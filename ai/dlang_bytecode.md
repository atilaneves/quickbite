# D Bytecode VM Plan

## Objective

Build an independent DUB project that compiles a controlled subset of D
into a custom bytecode format, using DMD as a frontend library dependency
today while insulating the rest of the codebase from DMD internals.

The implementation must not wait for ongoing DMD decoupling work.
Instead, it will define a stable project-local API and use
`dmd.frontend` only inside a narrow adapter layer.

## Non-Goals

- Do not modify the DMD repository as part of the VM project.
- Do not depend on DMD backend code generation.
- Do not expose `dmd.*` types outside the adapter package.
- Do not attempt full-language coverage in the first milestones.
- Do not assume DMD is thread-safe or supports multiple concurrent
  frontend sessions.

## Constraints And Assumptions

- The project is a separate DUB project, not another package inside this
  repository.
- The DUB project depends on DMD as a library through a pinned checkout.
- DMD is used only for lexing, parsing, import resolution, and semantic
  analysis.
- Compilation is single-threaded inside one process for now.
- Parallel builds, if needed later, use subprocess isolation rather than
  shared in-process compiler sessions.

## Pinned Dependency Strategy

Use a vendored DMD checkout pinned to a specific commit.

Recommended layout:

```text
my-d-bytecode-vm/
  dub.sdl
  source/
  test/
  vendor/
    dmd/        <- git submodule or pinned checkout
```

Recommended pinning method:

1. Add `vendor/dmd` as a git submodule.
2. Check out the exact commit you validated against.
3. Record the commit hash in:
   - `README.md`
   - `docs/architecture.md`
   - CI logs or a lock file if you create one
4. Point the DUB dependency at the local path instead of relying on the
   package registry.

Reasoning:

- This is more reproducible than relying on registry metadata.
- It keeps DMD upgrades explicit.
- It lets the VM project patch around DMD behavior changes without
  blocking on upstream work.

Example `dub.sdl` fragment:

```sdl
name "dlang-bytecode"
targetType "library"

dependency "dmd" path="vendor/dmd"
```

The current DMD tree already exposes a `frontend` subpackage and example
consumer code through `dlang/dmd/dub.sdl` and
`dlang/dmd/compiler/test/dub_package/frontend.d`. The VM project should
consume only that library-facing surface at first.

## Top-Level Architecture

The core design rule is:

Lower out of DMD immediately into project-owned data structures.

Target package layout:

```text
source/dlang_bytecode/
  api/
    compiler.d
    diagnostics.d
    options.d
    package.d
  driver/
    session.d
    pipeline.d
  frontend/
    dmd_session.d
    dmd_loader.d
    dmd_lowering.d
    dmd_diagnostics.d
    package.d
  ir/
    module.d
    function.d
    type.d
    instruction.d
    constant.d
    symbol.d
    package.d
  lower/
    module_lowerer.d
    stmt_lowerer.d
    expr_lowerer.d
    type_lowerer.d
  vm/
    bytecode_writer.d
    opcode.d
    package.d
  support/
    scope_exit.d
    asserts.d
    ids.d
```

Project-owned stable boundary:

- `CompilerSession`
- `CompileOptions`
- `CompileResult`
- `Diagnostic`
- `IrModule`
- `IrFunction`
- `IrType`
- `BytecodeModule`

Forbidden outside `frontend/`:

- `import dmd.*`
- direct references to `Module`, `Expression`, `Statement`, `Type`, `Dsymbol`

## Stable Project API

Another agent should start by implementing this surface first.

```d
module dlang_bytecode.api.compiler;

struct CompileOptions
{
    string[] importPaths;
    string[] stringImportPaths;
    string[] versionIdentifiers;
    bool dumpIr = false;
    bool dumpBytecode = false;
}

struct CompileInput
{
    string filename;
    string code;
}

struct CompileResult
{
    Diagnostic[] diagnostics;
    IrModule ir;
    ubyte[] bytecode;

    @property bool success() const
    {
        return diagnostics.count!(
            d => d.severity == DiagnosticSeverity.error
        ) == 0;
    }
}

interface CompilerSession
{
    CompileResult compile(CompileInput input, CompileOptions options);
}
```

Initial concrete implementation:

- `DmdCompilerSession : CompilerSession`

Nothing else in the project should know that DMD is being used.

## Phases

## Phase 0: Bootstrap The Independent Project

### Goal

Create a standalone repository that builds against a pinned local DMD
checkout and proves that `dmd.frontend` can be consumed reproducibly.

### Tasks

1. Create a new repository for the VM project.
2. Add `vendor/dmd` as a pinned submodule or equivalent pinned checkout.
3. Create `dub.sdl` with a path dependency on `vendor/dmd`.
4. Add a tiny executable target `dlang-bytecode-cli`.
5. Add a tiny library target `dlang-bytecode`.
6. Implement a smoke test that:
   - creates a DMD session
   - adds import paths
   - parses an in-memory module
   - runs semantic analysis
   - reports diagnostics
7. Add CI that builds this smoke test on one platform first.

### Deliverables

- `dub.sdl`
- `source/dlang_bytecode/api/*.d`
- `source/dlang_bytecode/frontend/dmd_session.d`
- `source/app.d` or `source/dlang_bytecode_cli/main.d`
- `test/smoke/frontend_smoke.d`

### Acceptance Criteria

- `dub test` succeeds.
- A single in-memory module can be parsed and semantically analyzed.
- No code outside `frontend/` imports `dmd.*`.
- The pinned DMD commit is documented.

### Suggested Implementation Notes

- Start from the pattern in
  `dlang/dmd/compiler/test/dub_package/frontend.d`.
- Use `initDMD`, `addImport`, `addStringImport`, `parseModule`,
  `fullSemantic`, and `deinitializeDMD`.
- Wrap `deinitializeDMD` in a scope guard.
- Do not keep DMD objects alive after session teardown.

## Phase 1: Define Project-Owned Diagnostics, Types, And IR Shell

### Goal

Establish stable internal data structures so the lowering work can
proceed without leaking DMD internals.

### Tasks

1. Define a project-local `Diagnostic` type.
2. Define a project-local source location type.
3. Define `IrModule`, `IrFunction`, `IrBlock`, `IrInstruction`,
   `IrType`, and `IrConstant`.
4. Add text dump helpers for all IR nodes.
5. Add invariants for IR validity.
6. Add snapshot-style tests for IR dumps.

### Minimum IR Requirements

- module name
- function symbol table
- local variable table
- basic blocks
- typed instructions
- source location on instructions when available
- constants
- function signature metadata

### Deliverables

- `source/dlang_bytecode/ir/*.d`
- `source/dlang_bytecode/api/diagnostics.d`
- `test/ir/*.d`

### Acceptance Criteria

- The IR package builds independently of the DMD adapter.
- IR dumps are deterministic.
- The IR is expressive enough for:
  - integer arithmetic
  - local variables
  - branching
  - returns
  - direct function calls

## Phase 2: Build The DMD Session Adapter

### Goal

Centralize all DMD lifecycle and configuration logic in one place.

### Tasks

1. Implement `DmdCompilerSession`.
2. Map `CompileOptions` to DMD initialization and import configuration.
3. Implement a single public compile pipeline:
   - initialize DMD
   - add import paths
   - parse module
   - collect parse diagnostics
   - if parse succeeded, run semantic analysis
   - collect semantic diagnostics
   - return either diagnostics-only or lowered IR
4. Add translation from DMD diagnostics to project diagnostics.
5. Add tests for:
   - syntax errors
   - semantic errors
   - import path resolution
   - custom version identifiers

### Important Design Rules

- `frontend/dmd_session.d` owns all calls to `initDMD` and `deinitializeDMD`.
- `frontend/dmd_diagnostics.d` owns all diagnostic conversion.
- `frontend/dmd_loader.d` owns module loading and option mapping.
- `frontend/dmd_lowering.d` is the only place allowed to inspect DMD
  AST/semantic nodes.

### Acceptance Criteria

- One function call from project code can compile a module to either
  diagnostics or IR.
- DMD failures do not leave the process in a poisoned state for the next test.
- No DMD symbols appear in `api/`, `ir/`, `lower/`, or `vm/`.

## Phase 3: Implement Lowering For A Minimal Useful D Subset

### Goal

Support enough D to exercise the full pipeline into custom IR and then bytecode.

### Initial Supported Subset

- top-level functions
- integer literals
- boolean literals
- local variable declarations
- assignment
- arithmetic: `+`, `-`, `*`, `/`
- comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`
- `if`
- `while`
- block statements
- `return`
- direct calls to known functions

### Explicitly Unsupported In This Phase

- classes
- structs beyond trivial handling
- exceptions
- closures
- delegates
- templates other than already-instantiated forms
- arrays
- foreach lowering
- CTFE-dependent execution
- inline asm
- `scope(exit)`

### Tasks

1. Write a `ModuleLowerer`.
2. Write a `StmtLowerer`.
3. Write an `ExprLowerer`.
4. Write a `TypeLowerer`.
5. Decide the exact mapping from resolved D types to `IrType`.
6. Normalize or reject unsupported constructs early with clear diagnostics.
7. Add fixture tests with source input and expected IR dumps.

### Implementation Notes

- Lower only semantically resolved nodes.
- Prefer reading stable fields over calling many helper methods.
- Copy needed information into project-owned structs immediately.
- Do not store raw DMD node references in IR.

### Acceptance Criteria

- A small arithmetic function compiles to IR.
- A conditional function compiles to IR.
- Unsupported constructs fail with project diagnostics, not crashes.

## Phase 4: Define The Bytecode Format And Encoder

### Goal

Turn the IR into a bytecode representation stable enough for a first VM.

### Tasks

1. Define opcode enumeration.
2. Define constant pool layout.
3. Define function table layout.
4. Define local slot model.
5. Define branch target encoding.
6. Implement `bytecode_writer.d`.
7. Add a human-readable bytecode disassembler.
8. Add round-trip tests:
   - IR -> bytecode -> disassembly

### Initial Opcode Set

- `load_const`
- `load_local`
- `store_local`
- `add_i32`
- `sub_i32`
- `mul_i32`
- `div_i32`
- `cmp_eq_i32`
- `cmp_lt_i32`
- `jump`
- `jump_if_false`
- `call`
- `ret`

### Acceptance Criteria

- IR lowering output can be encoded without backend-specific hacks.
- Bytecode dumps are deterministic.
- Branch fixups are correct.

## Phase 5: Implement The VM

### Goal

Execute the generated bytecode for the supported subset.

### Tasks

1. Implement VM value representation.
2. Implement call frames.
3. Implement local slots.
4. Implement instruction dispatch loop.
5. Implement an entrypoint convention.
6. Add a minimal runtime surface for printing or returning values.
7. Add executable tests for arithmetic, control flow, and direct calls.

### Acceptance Criteria

- Compiled bytecode for the phase-3 subset executes correctly.
- Runtime errors surface as VM diagnostics, not undefined behavior.

## Phase 6: Harden The Adapter Boundary

### Goal

Prepare for DMD upgrades without widespread refactoring.

### Tasks

1. Add contract tests around the DMD adapter.
2. Add golden tests that compile representative source files and compare:
   - diagnostics
   - IR dump
   - bytecode dump
3. Add a single file listing all DMD modules imported by the adapter.
4. Add an upgrade guide:
   - update submodule commit
   - rebuild
   - fix adapter only
   - rerun goldens
5. Add CI jobs for:
   - pinned version
   - optional canary branch against a newer DMD commit

### Acceptance Criteria

- Upgrading DMD requires touching only `frontend/` in the normal case.
- Regressions are caught by adapter and golden tests.

## Phase 7: Expand Language Coverage In Deliberate Slices

### Goal

Grow capability while keeping each addition reviewable and testable.

### Recommended Order

1. unary operators
2. short-circuit boolean ops
3. casts
4. simple structs by value
5. static arrays
6. string literals
7. function pointers
8. basic templates through monomorphized lowering
9. limited `foreach` after inspecting DMD’s lowered representation

For each slice:

- document supported semantics
- add source fixtures
- add expected IR dumps
- add execution tests
- add explicit unsupported diagnostics for edge cases not handled yet

## Phase 8: Optional Process Isolation Layer

### Goal

Remove the main operational risk of in-process DMD global state without
blocking the earlier phases.

### When To Do This

Do this only if one of these becomes painful:

- test contamination between sessions
- need for parallel compilation
- crashes inside DMD poisoning the main process
- desire for a stable serialized interface independent of D ABI changes

### Tasks

1. Create `dlang-bytecode-frontend-worker`.
2. Move DMD adapter code into that worker.
3. Serialize project-owned diagnostics and IR over stdin/stdout.
4. Keep the same `CompilerSession` API in the main library.
5. Swap implementation from in-process to subprocess behind the interface.

### Acceptance Criteria

- Main compiler library no longer links DMD directly when subprocess
  mode is enabled.
- The rest of the codebase is unchanged.

## Immediate File Creation Plan

Another agent can start implementation in this order:

1. Create the new repository and add `vendor/dmd`.
2. Write `dub.sdl` with:
   - library target
   - cli target
   - local dependency `path="vendor/dmd"`
3. Add:
   - `source/dlang_bytecode/api/options.d`
   - `source/dlang_bytecode/api/diagnostics.d`
   - `source/dlang_bytecode/api/compiler.d`
4. Add:
   - `source/dlang_bytecode/frontend/dmd_session.d`
   - `source/dlang_bytecode/frontend/dmd_diagnostics.d`
5. Add:
   - `test/smoke/frontend_smoke.d`
6. Make the smoke test compile this source:

```d
int add(int a, int b)
{
    return a + b;
}
```

7. Return project diagnostics only at first.
8. After that passes, add the IR package.
9. After the IR package exists, implement minimal lowering for:
   - integer literals
   - local variables
   - binary arithmetic
   - return

## Test Matrix

Minimum tests required before moving between phases:

- parse success
- parse syntax failure
- semantic failure
- import path success
- version identifier success
- deterministic IR dump
- deterministic bytecode dump
- VM execution of arithmetic
- VM execution of branch
- unsupported feature diagnostic

## Operational Rules For Implementers

- Every new public type must be project-owned.
- Every new `dmd.*` import must live under `source/dlang_bytecode/frontend/`.
- Do not store DMD node references in long-lived structs.
- Do not try to support concurrency inside the DMD adapter.
- Reject unsupported language constructs explicitly and early.
- Add a test for every newly supported construct before moving on.
- Pin DMD upgrades to separate commits from VM feature work.

## Risks And Mitigations

### Risk: DMD API churn

Mitigation:

- pin the vendored commit
- isolate all DMD imports
- add adapter contract tests

### Risk: Hidden dependence on global compiler state

Mitigation:

- enforce one session at a time
- teardown after each compile in tests
- optionally move to subprocess mode later

### Risk: Lowering depends on unstable AST helper behavior

Mitigation:

- lower only from semantically resolved nodes
- read fields conservatively
- copy required facts into project-owned IR immediately

### Risk: Scope creep from full-language ambitions

Mitigation:

- define supported subset per phase
- reject everything else with explicit diagnostics

## Definition Of Success

The plan succeeds when:

1. The VM project builds as an independent DUB project.
2. It depends on a pinned local DMD checkout as a library.
3. The project exposes a stable local API that does not leak DMD internals.
4. A small D subset can be compiled into project-owned IR and bytecode.
5. The bytecode executes on a project-owned VM.
6. Future DMD upgrades are isolated to the adapter layer.
