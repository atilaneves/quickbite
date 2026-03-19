# D Bytecode VM Plan

## Objective

Build an independent DUB project that executes D `unittest` blocks via a
custom bytecode VM, using DMD only as a frontend library dependency
while insulating the rest of the codebase from DMD internals.

The first priority is latency of the edit-to-unittest loop. The first
vertical slice must therefore compile one selected `unittest` plus only
the code that unittest directly or transitively depends on. Everything
else is secondary.

The implementation must not wait for ongoing DMD decoupling work.
Instead, it will define a stable project-local API and use
`dmd.frontend` only inside a narrow adapter layer.

## Non-Goals

- Do not modify the DMD repository as part of the VM project.
- Do not depend on DMD backend code generation.
- Do not expose `dmd.*` types outside the adapter package.
- Do not attempt full-language coverage in the first milestones.
- Do not build a general whole-module compiler before the unittest
  execution loop exists.
- Do not assume DMD is thread-safe or supports multiple concurrent
  frontend sessions.

## Constraints And Assumptions

- The project is a separate DUB project, not another package inside
  this repository.
- The DUB project depends on DMD as a library through a pinned checkout.
- DMD is used only for lexing, parsing, import resolution, and semantic
  analysis.
- Compilation is single-threaded inside one process for now.
- Parallel builds, if needed later, use subprocess isolation rather than
  shared in-process compiler sessions.
- Early milestones optimize for reproducible tests and small compile
  scope, not broad language coverage.

## Guiding Principles

- Make one selected `unittest` executable end to end as early as
  possible.
- Lower out of DMD immediately into project-owned data structures.
- Keep the adapter boundary narrow and explicit.
- Grow support in tiny semantic slices validated by execution tests.
- Treat infrastructure work as supporting work, not the main milestone.

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

Initial package layout:

```text
source/dlang_bytecode/
  api/
    compiler.d
    diagnostics.d
    options.d
    package.d
  frontend/
    dmd_session.d
    dmd_loader.d
    dmd_diagnostics.d
    dmd_lowering.d
    package.d
  ir/
    module.d
    function.d
    test.d
    block.d
    instruction.d
    type.d
    package.d
  vm/
    bytecode_writer.d
    opcode.d
    machine.d
    package.d
  support/
    scope_exit.d
    asserts.d
    ids.d
```

For the early milestones, `frontend/dmd_lowering.d` owns all inspection
of DMD AST and semantic nodes. Do not introduce a second lowering layer
that also reads `dmd.*` until the first end-to-end slice is proven.

Project-owned stable boundary:

- `CompilerSession`
- `CompileOptions`
- `CompileRequest`
- `CompileResult`
- `Diagnostic`
- `Module`
- `Function`
- `Test`
- `BytecodeProgram`

Forbidden outside `frontend/`:

- `import dmd.*`
- direct references to `Module`, `Expression`, `Statement`, `Type`,
  `Dsymbol`, or other DMD semantic node types

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

struct CompileRequest
{
    CompileInput input;
    size_t unittestIndex;
}

struct CompileResult
{
    Diagnostic[] diagnostics;
    Module ir;
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
    CompileResult compile(CompileRequest request, CompileOptions options);
}
```

Initial concrete implementation:

- `DmdCompilerSession : CompilerSession`

Nothing else in the project should know that DMD is being used.

## Early Vertical Slice

The first supported source slice is defined by
`ai/ir.md`. Treat that document as authoritative for the first end-to-
end implementation. Do not expand the IR or supported language forms
past that document until the slice executes in the VM.

The first successful demo should be:

1. Parse and semantically analyze a module containing one or more
   top-level functions and one or more `unittest` blocks.
2. Select one `unittest` by index.
3. Lower only the selected `unittest` and the directly called free
   functions needed by it.
4. Encode that slice to bytecode.
5. Execute it in the VM.

## Phases

## Phase 0: Bootstrap The Independent Project

### Goal

Create the smallest standalone repository that proves `dmd.frontend`
can be consumed reproducibly.

### Tasks

1. Create a new repository for the VM project.
2. Add `vendor/dmd` as a pinned submodule or equivalent pinned checkout.
3. Create `dub.sdl` with a path dependency on `vendor/dmd`.
4. Add a tiny library target `dlang-bytecode`.
5. Implement a smoke test that:
   - creates a DMD session
   - adds import paths
   - parses an in-memory module
   - runs semantic analysis
   - reports diagnostics
6. Document the pinned DMD commit.

### Deliverables

- `dub.sdl`
- `source/dlang_bytecode/api/*.d`
- `source/dlang_bytecode/frontend/dmd_session.d`
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
- Do not add a CLI target yet unless a test proves it is needed.

## Phase 1: Discover And Select One Unittest Slice

### Goal

Make the project unittest-driven before introducing general-purpose
compiler surfaces.

### Tasks

1. Define `CompileRequest` with explicit unittest selection.
2. Parse and semantically analyze one in-memory module.
3. Enumerate top-level `unittest` blocks deterministically.
4. Select one unittest by index.
5. Add diagnostics for invalid or missing unittest selection.
6. Add tests for:
   - one unittest
   - multiple unittests
   - invalid unittest index

### Acceptance Criteria

- Project code can ask to compile one selected unittest.
- Unittest selection is deterministic.
- Failures are reported as project diagnostics.

## Phase 2: Define The Minimal Project-Owned IR Shell

### Goal

Establish the smallest stable internal data structures needed for the
first vertical slice.

### Scope

This phase is intentionally limited to the IR described in `ai/ir.md`.
Do not add locals, branching metadata, symbol tables, source locations,
or richer type machinery yet unless that document is updated first.

### Tasks

1. Define a project-local `Diagnostic` type.
2. Define `Module`, `Function`, `Test`, `Block`, `Instruction`, and
   `Type` exactly as described in `ai/ir.md`.
3. Add text dump helpers for all IR nodes.
4. Add invariants for IR validity.
5. Add snapshot-style tests for IR dumps.

### Deliverables

- `source/dlang_bytecode/ir/*.d`
- `source/dlang_bytecode/api/diagnostics.d`
- `test/ir/*.d`

### Acceptance Criteria

- The IR package builds independently of the DMD adapter.
- IR dumps are deterministic.
- The IR matches the exact source forms and examples in `ai/ir.md`.

## Phase 3: Lower The First Supported Source Slice

### Goal

Support one end-to-end lowering slice for the narrow sample program from
`ai/ir.md`.

### Initial Supported Subset

- top-level free functions
- `unittest` blocks
- zero-argument direct calls
- integer literals
- `==` inside `assert`
- `return` of an integer literal

### Explicitly Unsupported In This Phase

- local variables
- assignment
- arithmetic beyond integer literals
- branching
- loops
- parameters
- arrays
- templates
- CTFE-dependent execution
- exceptions
- classes, structs, delegates, and closures

### Tasks

1. Implement `frontend/dmd_lowering.d`.
2. Lower only semantically resolved nodes.
3. Reject unsupported shapes with clear project diagnostics.
4. Add fixture tests with source input and expected IR dumps.
5. Verify that only the selected unittest and its directly needed free
   functions are lowered.

### Acceptance Criteria

- The exact sample from `ai/ir.md` compiles to IR.
- Unsupported constructs fail with project diagnostics, not crashes.
- Lowering does not leak `dmd.*` types outside `frontend/`.

## Phase 4: Define The Minimal Bytecode Format And Encoder

### Goal

Encode the phase-3 IR without designing for unsupported language
features.

### Tasks

1. Define opcode enumeration for the first slice only.
2. Define a minimal function table and constant representation.
3. Define how one selected unittest becomes the bytecode entrypoint.
4. Implement `bytecode_writer.d`.
5. Add a human-readable bytecode disassembler.
6. Add round-trip tests:
   - IR -> bytecode -> disassembly

### Initial Opcode Set

- `const_i32`
- `call`
- `equal_i32`
- `assert`
- `ret`

### Acceptance Criteria

- Phase-3 IR can be encoded without placeholder opcodes for unsupported
  features.
- Bytecode dumps are deterministic.
- The selected unittest entrypoint is explicit in the encoded program.

## Phase 5: Implement The VM For The First Slice

### Goal

Execute the selected unittest bytecode for the supported subset.

### Tasks

1. Implement the VM value representation needed for `int32`, `bool`,
   and `void`.
2. Implement call frames.
3. Implement the instruction dispatch loop.
4. Implement assertion failure reporting.
5. Add executable tests for the first supported source slice.

### Acceptance Criteria

- The sample from `ai/ir.md` executes correctly.
- Assertion failures surface as VM diagnostics, not undefined behavior.
- The end-to-end test path is `source -> DMD semantic analysis -> IR ->
  bytecode -> VM`.

## Phase 6: Expand Language Coverage In Tiny Slices

### Goal

Grow capability while keeping each addition reviewable, executable, and
cheap to validate.

### Recommended Order

1. integer arithmetic in expressions
2. local variables
3. simple function parameters
4. conditionals
5. loops
6. short-circuit boolean ops
7. casts
8. simple structs by value
9. static arrays
10. string literals
11. basic templates through monomorphized lowering

For each slice:

- document supported semantics
- add source fixtures
- add expected IR dumps
- add execution tests
- add explicit unsupported diagnostics for edge cases not handled yet
- keep compile scope centered on selected unittests

## Phase 7: Harden The Adapter Boundary

### Goal

Prepare for DMD upgrades without widespread refactoring.

### Tasks

1. Add contract tests around the DMD adapter.
2. Add golden tests that compile representative source files and
   compare:
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

## Phase 8: Promote Process Isolation When Needed

### Goal

Remove the operational risk of in-process DMD global state once it
starts hurting the unittest loop.

### Trigger Conditions

Move this work forward immediately if any of these show up:

- test contamination between sessions
- crashes inside DMD poisoning the process
- need for parallel compilation
- unstable repeated test runs inside one process
- desire for a stable serialized boundary independent of D ABI changes

### Tasks

1. Create `dlang-bytecode-frontend-worker`.
2. Move DMD adapter code into that worker.
3. Serialize project-owned diagnostics and IR over stdin/stdout.
4. Keep the same `CompilerSession` API in the main library.
5. Swap implementation from in-process to subprocess behind the
   interface.

### Acceptance Criteria

- The main process survives frontend crashes.
- Repeated unittest execution remains deterministic across sessions.
