# Bytecode VM Architecture Plan

## Summary
Design and build, from scratch, a bytecode VM for D behind the existing
`Bytecode` backend. The VM compiles semantically analyzed D ASTs into an
internal bytecode artifact and executes it in-process, with no object files
and no linker on the hot path.

Two product goals, in priority order:

1. Minimise the latency from an edit in the project under test (not
   necessarily in its dub dependencies) to a yes/no "did the relevant tests
   pass?" answer. Parse and semantic analysis are fixed costs. This plan
   covers the execution engine only: compiling from the AST and running.
   Bytecode artifact caching and affected-test selection are separate, later
   plans; this design must not preclude them but does not deliver them.
2. Serve as a replacement for the DMD CTFE engine, for performance. Backends
   take a construction-time mode parameter: in CTFE-only mode the VM limits
   itself to what D allows at compile time and matches DMD CTFE's legality
   and diagnostics exactly (value semantics follow the two-tier oracle
   below); otherwise it targets all of D.

Correctness overrides both goals: the VM must have the same observable
semantics as if the source had been compiled to native code and run. Fast
but wrong is worthless.

## Modes and Oracles
- The mode is a constructor parameter on the backend. It selects bytecode
  emission (checked vs unchecked opcodes), the native-call policy, and the
  diagnostic flavour.
- Full-D mode oracle: really-compiled code. The arbiter for any observable
  behaviour, including failure message text, is a real
  `dmd -unittest -checkaction=context` compile-and-run of the fixture, byte
  for byte — the same discipline `dmd-backend.md` established for
  `SystemLinker`.
- CTFE-only mode oracle: DMD CTFE (`dmd.dinterpret`), in two tiers:
  - Legality and diagnostics: binding. Accept exactly what dinterpret
    accepts, reject exactly what it rejects, with byte-identical
    diagnostics.
  - Value semantics: correct (compiled) semantics win. Where dinterpret
    computes a wrong value for a program it accepts (e.g. the known
    static-array-copy aliasing quirk), the VM produces the correct value
    and the divergence is documented with a test asserting the correct
    result — never emulated. If replacing dinterpret inside DMD ever
    demands bug compatibility for a specific quirk, that is an explicit
    per-quirk decision recorded at that time, not a blanket rule.
    (Precedent: `dmd-backend.md`'s oracle lesson exists because CTFE
    expectations may themselves encode CTFE quirks; the resolution there
    was per-backend expectation splits, never quirk emulation.)
- Mode coverage in the current matrix: of the ~153 `Bytecode` matrix
  blocks, exactly two sites assert CTFE-flavoured text — the `= void`
  uninitialized-read diagnostic in `runner/ct/diagnostics.d` and the
  `runner/rt/cstdlib.d` no-available-source family. The other ~95% assert
  `-checkaction=context`-style output that compiled code produces too, so
  the matrix is mostly mode-agnostic, not CTFE-only. The two CTFE-flavoured
  sites stay pinned to CTFE-only mode (and get full-D twins when the bridge
  lands, e.g. `malloc` succeeding, per `ffi.md`'s first runtime-mode test);
  representative mode-conditional blocks run in full-D mode from the moment
  the checked/unchecked opcode split exists (see the rewrite strategy).
- A future swap of `dmd.dinterpret` itself (semantic-time CTFE: `static if`,
  mixins, template arguments) is not a deliverable, but the design must not
  preclude it. Concretely: the VM core is re-entrant with no global mutable
  state, entry is per-`FuncDeclaration` rather than per-module, and results
  are reachable as raw memory plus a static type, so they can be reified as
  a DMD `Expression` just as well as a `quickbite.lang.Value`.

## Core Architecture

### Memory model: native layout over real memory
This is the load-bearing decision; everything else follows from it.

- The VM is a virtual CPU executing D-level operations on real host memory
  laid out exactly as compiled code would lay it out. DMD semantic analysis
  has already computed every size, alignment, and field offset
  (`Type.size()`, `Type.alignsize()`, `VarDeclaration.offset`); the bytecode
  compiler reuses those numbers and never invents its own layout.
- A call frame is a contiguous byte region. Every local lives at its native
  offset with its native size; compiler-generated temporaries are additional
  typed frame slots assigned at emit time. Instructions address frame byte
  offsets — a register machine whose registers are frame memory.
- Consequences, all by construction rather than by special cases: taking the
  address of a local yields a real pointer; pointer arithmetic, aliasing,
  slices into locals, unions, and reinterpret casts behave exactly as native
  code does. This eliminates the whole class of deviations the tree-walking
  interpreter's pointer-snapshot model is known for.
- Full-D mode heap: interpreted data structures are native data structures
  and the host GC owns the heap. The druntime lowering hooks are templates
  (`_d_newclassT!T`, `_d_arrayappendT`, `_d_aaGetY`) instantiated into the
  project's compilation, so the VM executes their bodies like any other
  available source; only the leaves (`GC.malloc` and friends) are native
  calls, and those leaves consume runtime type metadata for VM-compiled
  types — see below. VM stack memory is registered with the host GC so
  references held in frames keep objects alive; conservative scanning of
  large frame regions (false-pointer pinning) and `addRange`/`removeRange`
  churn are known costs the bench checkpoints must watch.
- CTFE-only mode heap: the VM owns all allocations and registers each one in
  a provenance table (allocation id, bounds, static type, initialization
  shadow). No native memory is reachable and no native code is called.

### Runtime type metadata (full-D mode)
Native-layout memory is not enough for the druntime leaves; they also
consume type metadata that compiled code gets from the code generator:

- `GC.malloc(size, attrs, typeid(T))` needs a live native `TypeInfo` object
  per allocated type; GC finalization reads the destructor pointer from it,
  at an arbitrary later collection point.
- `_d_newclassT!C` copies the vtable from `__traits(initSymbol, C)` — a
  static data blob that does not exist for VM-compiled classes.
- Array append calls `elem.__xpostblit()` directly; the template AA calls
  `key.toHash()`/`opEquals` directly. For VM-compiled types those function
  pointers must point at VM entry thunks.

So full-D mode synthesizes native `TypeInfo`/`TypeInfo_Class` instances,
init blobs, and vtables for VM-compiled types, with function-pointer slots
(dtor, postblit, copy ctor, toHash, opEquals) filled by inbound VM entry
thunks. "The real runtime manipulates the real heap" holds without this
metadata only for POD element/key types. Because GC finalization can fire
long after the allocating call, thunk lifetime is tied to the VM session,
not the call.

Exposing tests (full-D mode, compiled oracle): append to an array of a
struct with a postblit; `new` a class with `~this()`, drop the reference,
`GC.collect()`, assert the dtor ran; an AA keyed on a struct with a custom
`toHash`.

### Module-level state
- Each module gets a VM-owned data segment with native layout — sizes,
  alignments, and offsets from DMD, the same authority as frames. In full-D
  mode segments are GC-registered like stack chunks.
- `static this()` runs before the first access to the module's state,
  ordered by druntime's cycle-checked import-graph semantics. This is an
  eager per-module obligation layered on lazy per-function compilation: the
  first call into a module triggers its (and its imports') constructors
  before the called function body runs.
- CTFE-only mode reproduces dinterpret's global-access rules through the
  checked opcodes: reads of mutable globals are rejected with dinterpret's
  diagnostics; immutable/const-initialized globals evaluate as dinterpret
  does.
- TLS: the VM executes single-threaded for now, so TLS and `__gshared`
  coincide. This is an explicit assumption, recorded with the
  concurrency-readiness constraints.

Exposing test (full-D mode, compiled oracle): a module with
`int counter; static this() { counter = 40; } int bump() { return counter += 2; }`
and a unittest asserting `bump() == 42` — forces segment storage,
ctor-before-first-access ordering, and function-level (not unittest-body)
visibility of the global. The CTFE-only twin asserts dinterpret's
mutable-global rejection diagnostic byte for byte.

### No universal runtime value type
- `quickbite.lang.Value` must not appear in the bytecode compiler, the
  bytecode format, or the VM. Every operand's type is static; the compiler
  selects type-specialised opcodes at emit time from the semantic type, and
  no handler dispatches on a runtime tag.
- `Value` is constructed in exactly one place: the `Evaluator` boundary,
  where the final result is reified from frame memory plus its static type,
  the way a debugger renders memory using type metadata. `Runner` needs no
  `Value` at all — pass/fail plus diagnostic strings.
- This supersedes the earlier accepted-cost decision to use `Value` as the
  VM slot type (see the PR 97 lessons below); that was the first-generation
  implementation, not the target.

### Bytecode format
- Fixed-width instructions: opcode plus up to three 16-bit operands (frame
  byte offsets, constant-pool indices, function ids, jump targets). Frames
  larger than the 16-bit range get an explicit wide escape rather than a
  variable-width format.
- The constant pool holds raw bits and strings, never `Value`. Diagnostic
  strings (assert messages, uninitialized-variable names) are pool entries
  referenced by index, not instruction payloads.
- A compiled function records: code, frame size and layout, parameter
  metadata, exception handler table, and a bytecode-offset-to-source-line
  table. The artifact is deterministic to emit and easy to disassemble so
  failures and cache behaviour are reproducible.
- Functions compile lazily: a function body is compiled the first time it is
  called. An edit therefore pays compilation cost only for code the executed
  tests actually reach. The artifact stays closed over the code the current
  test slice executes, not every transitive dependency.

### Execution core
- Frames are carved from VM-owned contiguous stack chunks; max frame size is
  known at compile time. Growth goes through the allocator or reports a
  deterministic call-stack exhaustion diagnostic.
- Dispatch starts as `final switch` over the opcode enum. Handler boundaries
  stay compatible with a function-pointer table or computed-goto upgrade so
  direct threading is a measurement-driven swap, not a rewrite.
- The interpreter core stays small and direct: explicit frame bookkeeping,
  no abstraction stack between the dispatch loop and memory.

### Native bridge (full-D mode only)
- The boundary is the body-less leaf, not package ownership: native means
  `fbody is null` — C libraries and separately compiled extern symbols.
  Everything with available source is executed by the VM, including
  druntime and Phobos template bodies instantiated with project types
  (`xs.map!(x => x * 2)` has no precompiled body anywhere). Stated plainly:
  the VM will interpret large swaths of Phobos, which raises the feature
  floor for goal 1 — ranges, capturing lambdas, classes, and exceptions
  arrive with the first `std.algorithm`-using test, regardless of slice
  order.
- Reconciliation with `ffi.md`: that document prescribes wrapper thunks for
  dependency calls, classifies mixed template instantiations as
  backend-executed or separately cached, and lists direct extern(D) calls
  as a non-goal. Native layout supersedes the wrapper position for this
  backend — data crosses the boundary unchanged, so per-signature wrapper
  codegen buys nothing. `ffi.md` §23 records this amendment; the wrapper
  design stands for boxed-value backends only.
- Druntime lowering hooks (`_d_arrayappendT`, the AA runtime,
  `_d_newclassT`, ...) are templates whose bodies the VM executes; the
  native leaves they bottom out in require the runtime type metadata
  described in Core Architecture. Only POD element/key types work without
  it.
- Outbound call mechanism: layout identity removes data conversion, not the
  call itself. Invoking a native function whose signature is only known at
  VM runtime means implementing the SysV x86_64 calling convention —
  INTEGER/SSE struct classification, the hidden `sret` pointer for large
  returns, `real` via x87, variadics. The bridge builds libffi CIFs from
  DMD type signatures and caches them per bridge entry alongside symbol
  resolution. "No marshalling layer" is scoped to data representation:
  values cross unchanged; the call goes through a cached FFI descriptor.
  `real` in signatures is a known libffi hazard on x86_64 and gets explicit
  fixtures (CTFE-only mode must match dinterpret's `real` precision, full-D
  mode the compiled oracle's).
- Every outbound call carries an exception guard converting native
  `Throwable`s into VM unwinding (see Exception Handling); "pass values
  as-is" describes the arguments, not the call.
- Inbound calls (native code invoking a bytecode function: GC finalizers,
  AA key methods, vtable entries, function pointers, delegates handed to
  native APIs) need native entry points per bytecode function. Candidate
  mechanisms: a pre-generated thunk pool or libffi closures. The choice is
  forced by the druntime/AA slice — GC finalization and AA key methods need
  thunks before classes do (see Runtime type metadata) — not by the
  classes/vtable slice; the calling convention must not preclude either
  mechanism.
- Exposing tests for the call mechanism (full-D mode, compiled oracle, byte
  for byte): call a precompiled extern function taking a 24-byte struct by
  value and returning one (forces memory-class classification and `sret`);
  the same with `real` in the signature.
- CTFE-only mode has no bridge. A call to anything without available source
  keeps the existing "cannot be interpreted at compile time, because it has
  no available source code" diagnostic, and druntime lowerings are executed
  by the VM itself against VM-owned memory (the call-site interception the
  Interpreter backend already proved out).

### CTFE legality checking
- CTFE-only mode emits checked opcode variants; full-D mode emits unchecked
  ones. Full-D execution pays zero cost for CTFE support.
- Checked operations validate against the provenance table: reads of
  uninitialized memory, reads of mutable module-level state, out-of-bounds
  access, pointer comparison and subtraction across allocations,
  pointer-to-integer conversion, disallowed reinterpretation, and escaping
  CTFE-owned pointers are rejected with diagnostics byte-identical to DMD
  CTFE's.
- The provenance table and initialization shadow run on every checked load
  and store; their granularity (per-byte shadow, per-slot, per-allocation
  bitmap) is the dominant cost decision for goal 2 and is settled by
  measurement: slice 2 carries an explicit benchmark gate — checked-mode VM
  vs the `Ctfe` backend on the bench fixtures — so a losing shadow design
  is caught while it is one slice old.
- `__ctfe` evaluates to `true` in CTFE-only mode and `false` in full-D mode,
  decided at emit time.

### Concurrency readiness
- Threads, `synchronized`, atomics, and fibers are out of scope until a test
  forces them, with an explicit unsupported diagnostic (CTFE-only mode
  rejects them the way DMD CTFE does). The design must not preclude them: no
  module-level mutable VM state, one machine instantiable per thread, heap
  and provenance structures designed to become shared-capable.
- Known exception to "no shared mutable state": the compile-on-first-call
  function cache is per-machine shared mutable state and needs a lock or
  per-thread compilation when threads arrive.
- Until then the VM executes single-threaded; TLS and `__gshared` coincide
  (see Module-level state).

### Boundaries
- DMD AST and semantic types are visible only to the compiler module; the
  bytecode format and VM consume bytecode-native ids and metadata only.
- Backends remain isolated from each other; the new core shares nothing with
  the Interpreter or IR backends.

## Implementation Direction

### Rewrite strategy
The current bytecode internals (a `Value`-typed stack and locals, `Value`
embedded in every instruction, tag-dispatched arithmetic) are the
first-generation implementation and are replaced wholesale by this design.
The rewrite happens behind the existing `Bytecode` backend class, and the
backend's current green test matrix is a non-negotiable ratchet: every PR
keeps the full suite green.

- Strangler pattern: the new core (typed frames, native layout, specialised
  opcodes) grows in parallel modules inside `backends/bytecode`, behind an
  internal engine switch on the `Bytecode` class that defaults to the old
  core.
- Each slice makes a chosen set of already-green matrix behaviours pass on
  the new core. When the entire matrix passes on the new core, flip the
  default and delete the old core in the same change.
- The CTFE-only constructor parameter exists from the first slice. The
  existing matrix runs in CTFE-only mode by default, but its expectations
  are ~95% mode-agnostic (see Modes and Oracles): from slice 2 — the first
  slice where the checked/unchecked opcode split exists — every opcode
  family with mode-conditional emission or handlers gets at least one
  representative matrix block also running in full-D mode. A handful of
  blocks, not a doubled suite: enough that the unchecked path and
  `__ctfe`-conditional emission are continuously exercised rather than dark
  until the bridge slice. (In slice 1, before the split exists, both modes
  are the same code and dual runs test nothing.) The flip criterion
  includes those representative full-D blocks.

### Slice roadmap
Earn the design back test-first, in this order. Each slice follows the
existing discipline: red test (or an already-green matrix behaviour moved to
the new core), minimal implementation, green suite, benchmark checkpoint.

1. Scalar core: typed frames, specialised arithmetic/comparison opcodes,
   locals, calls, returns, assert diagnostics, and minimal scalar `Value`
   reification at the `Evaluator` boundary (read bytes at a frame offset,
   wrap per static type). Reification is a leaf, it lets `eval.d` — the
   easiest module in `backend-test-modules-order.md` — re-earn immediately,
   and it is the debugging instrument for every later slice: rendering
   frame memory through type metadata is exactly what is needed when typed
   frames misbehave. Re-earn the first `eval.d` scalar block plus
   `integrals.d`, `logic.d`, `math.d`, and `diagnostics.d` on the new core.
   Reification grows with each new type category from here on (structs at
   slice 4, arrays/slices at slice 5, class references at slice 9), so the
   eval/REPL surface re-earns incrementally instead of as a final cliff.
2. CTFE provenance: allocation table, initialization shadow, checked
   opcodes. Re-earn the uninitialized-read and `= void` diagnostics.
   Benchmark gate: checked-mode VM vs the `Ctfe` backend (see CTFE legality
   checking). Representative full-D-mode matrix blocks start here, one per
   mode-conditional opcode family.
3. Control flow completion: the `control_flow.d` surface (currently
   CTFE/SystemLinker only).
4. Structs with native layout: field offsets from DMD, by-value copies,
   methods, constructors — the `structs.d` surface.
5. Arrays, slices, and pointers with true aliasing: real addresses into
   frame and VM-heap memory, slice write-through, pointer arithmetic — the
   `arrays.d` surface, including the cases a snapshot model can never pass.
6. Exceptions: handler tables, throw/catch/finally/scope(exit) — the
   `exceptions.d` surface.
7. Associative arrays and druntime lowerings in CTFE-only mode via call-site
   interception against VM-owned memory.
8. Full-D mode: outbound native bridge, real druntime heap, host GC
   integration, compiled-output diagnostics; split per-mode message
   expectations where CTFE and compiled text differ. This slice also
   synthesizes runtime type metadata and decides the inbound trampoline
   mechanism — GC finalizers and AA key methods force thunks before classes
   do (see Runtime type metadata). If the slice ships POD-only element/key
   support first, that scoping is recorded in the matrix exclusions, not
   silent.
9. Classes: native object layout, vtables, virtual dispatch, built on the
   trampoline mechanism slice 8 established.
10. REPL session state. (`Value` reification does not live here; it starts
    in slice 1 and grows per slice.)

### Discipline (unchanged from the first generation)
- Start each slice with the smallest behaviour that can honestly fail. If a
  slice needs unittest blocks, literals, equality, calls, returns, and
  assert handling all at once, it is too broad; pick a smaller test.
- Promote CTFE-backed test modules in the order documented by
  `ai/plans/backend-test-modules-order.md`. Treat the module, not a single
  template instantiation, as the unit of migration; promote whole test
  families once one instantiation proves the behaviour.
- When orchestrating subagents, assign work by remaining named test
  behaviour or test family. A worker should not spend a slice on another
  type-width variant of an already-passing behaviour unless it is expected
  to expose a different missing VM feature.
- Before promoting a named test mentioned by this plan or a review note,
  verify in the current checkout that its enclosing backend matrix still
  excludes the target; treat stale notes as a trigger for current-test
  discovery, not broad promotion.
- Keep unsupported behaviour explicit and diagnostic rather than silently
  lowering or guessing.
- Preserve a strict compile-AST-then-execute-bytecode pipeline; no IR layer
  between AST and bytecode. Unittest code runs once, so compile speed is on
  the hot path and a separate IR pass costs latency without paying rent.
- Treat bytecode as an internal artifact, not a public interchange format or
  a serialization compatibility promise.

### Benchmarks and success criteria
- `bin/bench` post-parse comparisons at every slice checkpoint: the new core
  must beat the old core, and full-D mode targets beating `SystemLinker`'s
  measured ~43 ms median per test by an order of magnitude on the bench
  fixtures.
- CTFE-only mode targets beating the `Ctfe` backend (DMD's `ctfeInterpret`)
  on the same fixtures — that is the entire case for goal 2.
- The REPL session-depth benchmark tracks `Evaluator` latency.

## Current Coverage State
This log records matrix coverage earned by the first-generation internals.
It remains binding as the rewrite ratchet: everything below must stay green
on the new core before the engine default flips.

- `tests/ut/backends/evaluator/eval.d` now covers `Bytecode` for every eval
  candidate previously listed for promotion: `multiCell`,
  `preservesScalarValueTypes`, `castsFloatingValueNumerically`,
  `castsRuntimeValuesToIntegerTypes`,
  `floatingSubtractionUsesNumericValues`,
  `floatingUnaryMinusUsesNumericValue`, `fabsFloatPreservesReturnType`, and
  `powFloatDoesNotReturnDoubleValue`.
- Those promotions were stale coverage gaps. The bytecode backend already
  supported them through its existing eval compiler, VM local/value-stack
  operations, scalar casts, floating arithmetic, and narrow `std.math`
  builtin bridge.
- `evaluatesRuntimeSqrtInput` in `tests/ut/backends/runner/ct/math.d` now covers
  `Bytecode`. The promotion exposed missing unary `std.math.sqrt` builtin
  support, so bytecode now recognizes DMD's `sqrt` builtin and executes it
  through the existing unary native-call path.
- `evaluatesDifferentRuntimeSqrtInput` in `tests/ut/backends/runner/ct/math.d`
  now covers `Bytecode`. This was a stale coverage gap after the runtime
  `sqrt` builtin slice: the existing bytecode unary native-call path already
  executed a different runtime `sqrt` input correctly.
- `evaluatesDifferentRuntimeSqrtInputFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `4 != 5`.
- `evaluatesDifferentRuntimeSqrtInputFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `6 != 7`.
- `evaluatesRuntimeNonIntegerSqrtInput` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` builtin slice: the existing bytecode
  unary native-call path already executed the non-integer runtime `sqrt` input
  correctly.
- `evaluatesRuntimeNonIntegerSqrtInputFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `1.5 != 2.5`.
- `evaluatesRuntimeNonIntegerSqrtInputFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `2.5 != 3.5`.
- `evaluatesRuntimeNonPerfectSqrtInput` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` builtin slice: the existing bytecode
  unary native-call path already executed the non-perfect runtime `sqrt` input
  and comparison assertions correctly.
- `evaluatesRuntimeFabsDoubleInput` in `tests/ut/backends/runner/ct/math.d` now
  covers `Bytecode`. This was a stale coverage gap: the existing bytecode
  unary native-call path already recognizes and executes DMD's `fabs` builtin
  for negative runtime `double` inputs.
- `evaluatesRuntimeFabsPositiveDoubleInput` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `fabs` builtin slice: the existing bytecode
  unary native-call path already executes positive runtime `double` inputs
  correctly.
- `repl.backend.skipsCommentOnlyLines` in `tests/ut/bin/repl.d` now
  covers `Bytecode`. This was a stale coverage gap after the REPL expression
  loop slice: the shared REPL loop already skips comment-only input before
  dispatching cells to the backend.
- `repl.backend.evaluatesStandaloneMixinExpression` in
  `tests/ut/bin/repl.d` now covers `Bytecode`. This was a stale
  coverage gap: the existing REPL frontend already classifies standalone mixin
  expression statements as expression cells, and bytecode already executes the
  mixed-in expression through the existing eval path.
- `repl.backend.declarationCellsPersistWithoutDisplay` in
  `tests/ut/bin/repl.d` now covers `Bytecode`. This was a stale
  coverage gap: the existing REPL session history already preserves module
  declaration cells without display, and bytecode already evaluates the
  persisted scalar declaration through the following expression cell.
- `repl.backend.expressionSideEffectsPersist` in
  `tests/ut/bin/repl.d` now covers `Bytecode`. The promotion exposed
  missing local post-increment expression support, so bytecode now lowers
  `x++` by loading the old local value for the expression result and mutating
  the persisted local through the existing increment opcode.
- `repl.backend.statementsExecuteImmediately` in
  `tests/ut/bin/repl.d` now covers `Bytecode`. This was a stale
  coverage gap after the REPL expression-side-effects slice: bytecode already
  executes no-display statement cells immediately through the existing
  pre-increment local mutation path.
- `repl.backend.functionDeclarationsPersistWithoutSemicolon` in
  `tests/ut/bin/repl.d` now covers `Bytecode`. The promotion exposed
  missing queued function-body emission for eval/REPL bytecode programs, so
  bytecode now emits the entry body, halts, and then drains called functions for
  REPL evaluation just as it already did for unittest execution.
- `repl.backend.displaysUndisplayablePlaceholderForFunctionLiterals` in
  `tests/ut/bin/repl.d` now covers `Bytecode`. The promotion exposed
  delegate literals reaching bytecode as synthetic function-literal symbols, so
  bytecode now emits `Value.undisplayable` literals for DMD function/delegate
  literal expressions without adding a VM opcode.
- `tests/ut/bin/repl.d` is now complete for `Bytecode`. Six stale
  REPL coverage gaps were promoted without production changes:
  `userDefinedFunctionDoesNotCollideWithWrapper`,
  `templateFunctionDeclarationsPersistWithoutDisplay`,
  `multilineFunctionDeclarationsBufferUntilComplete`,
  `multilineStructDeclarationsBufferUntilComplete`,
  `failedBufferedDeclarationDoesNotPoisonSession`, and
  `commandsDoNotAbandonPendingInput`.
- The remaining REPL display and import gaps now cover `Bytecode`:
  `displaysStaticStringArrayResults`, `displaysNestedEmptyStringValues`,
  `displaysNestedArrayResults`, `displaysWideStringValues`,
  `displaysWideCharacterArrayValues`, and
  `importDeclarationsPersistWithoutDisplay`. Bytecode now lowers DMD
  `ArrayLiteralExp` to a bytecode array-literal operation, preserves string
  display metadata with `Value.stringValue`, encodes wide string code units as
  UTF-8, marks character array literals through shared DMD type helpers, treats
  array casts as transparent, and lowers DMD conditional expressions with
  branch control flow.
- `evaluatesRuntimeIsNaNDoubleInput` in `tests/ut/backends/runner/ct/math.d` now
  covers `Bytecode`. The promotion exposed missing `std.math.isNaN` builtin
  support, so bytecode now recognizes DMD's `isnan` builtin and executes it
  through the existing unary native-call path.
- `evaluatesRuntimeIsNaNDoubleInputFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isNaN` builtin slice: the existing bytecode
  logical-not and bool equality assertion diagnostics already report
  `true == true`.
- `evaluatesRuntimeIsNaNDoubleInputFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isNaN` builtin slice: the existing bytecode
  `isNaN` builtin and bool equality assertion diagnostics already report
  `false != true`.
- `doesNotTreatUserNamedIsNaNAsMathIntrinsic` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap: bytecode already calls the user-defined `isNaN` function
  instead of treating it as the `std.math.isNaN` builtin.
- `doesNotTreatUserNamedPowAsMathIntrinsic` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap: bytecode already calls the user-defined `pow` function instead
  of treating it as the `std.math.pow` builtin.
- `evaluatesRuntimePowDoubleInputsFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. The promotion exposed
  bytecode assertion diagnostics formatting floating operands through integer
  scalar access. Bytecode now keeps existing integer-compatible assertion
  messages but renders floating operands through `Value` so runtime `pow`
  equality failures report `16 != 17`.
- `evaluatesRuntimePowDoubleInputsFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `pow` and floating assertion-diagnostic
  slices: the existing bytecode binary native-call path and comparison
  assertion diagnostics already report `3 <= 3.001`.
- `doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the user-defined `pow` and floating equality-diagnostic
  slices: bytecode already calls the user-defined function and reports
  `6 != 7`.
- `doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the user-defined `pow` and floating equality-diagnostic
  slices: bytecode already calls the user-defined function and reports
  `7 != 8`.
- `evaluatesRuntimeSqrtInputFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `3 != 4`.
- `evaluatesRuntimeSqrtInputFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `5 != 6`.
- `evaluatesRuntimeIsInfinityDoubleInput` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. The promotion exposed
  missing `std.math.isInfinity` builtin support and non-runtime declaration
  expressions in the fixture, so bytecode now treats non-var declarations as
  no-ops and executes `isInfinity` through the existing unary native-call path.
- `evaluatesRuntimeIsInfinityDoubleInputFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isInfinity` builtin slice: the existing
  bytecode logical-not and bool equality assertion diagnostics already report
  `true == true`.
- `evaluatesRuntimeIsInfinityDoubleInputFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isInfinity` builtin slice: the existing
  bytecode `isInfinity` builtin and bool equality assertion diagnostics
  already report `false != true`.
- `evaluatesRuntimeSignbitDoubleInput` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. The promotion exposed
  missing `std.math.signbit` builtin support, so bytecode now recognizes
  DMD's `signbit` helper by identifier and executes it through the existing
  unary native-call path.
- `evaluatesRuntimeSignbitDoubleInputFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  integer equality assertion diagnostics already report `1 != 0` for negative
  zero.
- `evaluatesRuntimeSignbitDoubleInputFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  integer equality assertion diagnostics already report `0 == 0` for positive
  zero.
- `evaluatesRuntimeSignbitNanInput` in `tests/ut/backends/runner/ct/math.d` now
  covers `Bytecode`. This was a stale coverage gap after the runtime `signbit`
  builtin slice: the existing bytecode unary native-call path already preserves
  sign bits for positive and negative NaN inputs.
- `evaluatesRuntimeSignbitNanInputFailureMessage.0` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  `signbit` builtin and integer equality assertion diagnostics already report
  `1 != 0` for a negative NaN input.
- `evaluatesRuntimeSignbitNanInputFailureMessage.1` in
  `tests/ut/backends/runner/ct/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  `signbit` builtin and integer equality assertion diagnostics already report
  `0 == 0` for a positive NaN input.
- `tests/ut/backends/runner/ct/integrals.d` now covers `Bytecode` for
  every integral type behavior test from `type.byte` through `type.ulong`.
  These are one parametrized behavior family, not eight meaningful migration
  slices. The `byte` slice added the first module-backed `Bytecode.runTests`
  path, compiling each unittest block to bytecode and executing its
  directly-called module functions through bytecode call frames. The remaining
  type-width variants passed without production changes and should have been
  promoted together once that was known. The implementation is deliberately
  narrow: equality assertions are enough for the passing behavior.
- `typeFailureMessage.byte.0` now covers `Bytecode`. This promoted the first
  integral assertion-diagnostic case and taught the bytecode VM to report
  failed equality assertions from the runtime operands, producing
  `-126 != 130` for a narrowed `byte` value.
- `tests/ut/backends/runner/ct/integrals.d` is now complete for `Bytecode`.
  `typeFailureMessage.ubyte.0` and `typeFailureMessage.uint.0` were promoted
  together as the remaining integral assertion-diagnostic family. They passed
  with the existing equality diagnostic support and did not require distinct
  VM feature work.
- `runTests.runsAttributedUnittests` in
  `tests/ut/backends/runner/results.d` now covers `Bytecode`. The promotion
  exposed DMD constant-folded assert diagnostics: `assert(1 == 2)` reaches
  bytecode as a false assertion with a structured `_d_assert_fail("==", 1, 2)`
  message payload. Bytecode now lowers that equality payload through the
  existing assertion-compare opcode so the runner reports `1 != 2`.
- `runTests.runsAttributedThrowingUnittests` in
  `tests/ut/backends/runner/results.d` now covers `Bytecode`. The promotion
  exposed missing `throw` statement support for `throw new Exception(message)`.
  Bytecode now lowers the exception constructor message to a value-stack
  operand and the VM throws that message through a narrow `throw_` opcode.
- `runTests.importPathsRetryAfterFailure` in
  `tests/ut/backends/runner/results.d` now covers `Bytecode`. This was a stale
  coverage gap: the shared source-fixture parse path already passed import
  paths to DMD, and the existing bytecode enum/function/assert support could
  execute the imported assertion without production changes.
- `runTestSummary.countsAttributedPassingAndFailingUnittests` in
  `tests/ut/backends/runner/results.d` now covers `Bytecode`. The promotion
  exposed the missing bytecode backend summary API, not missing VM semantics.
  Bytecode now compiles and executes each unittest declaration through the
  existing bytecode path and records total, passed, and failed counts.
- `runTestSummary.countsAllPassingUnittests` in
  `tests/ut/backends/runner/results.d` now covers `Bytecode`. This was a stale
  coverage gap after the summary API slice: the existing bytecode summary path
  already counted all-passing unittest declarations correctly.
- `runTestSummary.countsAssertErrorsAsFailures` in
  `tests/ut/backends/runner/results.d` now covers `Bytecode`. This was a stale
  coverage gap after the summary API and narrow throw-expression slices: the
  existing summary path already counts thrown `AssertError` instances as
  failures.
- `runTestResults.reportsDmdUnittestSymbolNames` and
  `runTestResults.reportsFileBackedUnittestLocations` in
  `tests/ut/backends/runner/results.d` now cover `Bytecode`. The promotion exposed
  the missing bytecode `runTestResults` API. Bytecode now reuses the existing
  compile/execute path to build a `TestRunResult` with per-case
  `TestOutcome`, the DMD unittest symbol name (`ident.toChars`), and the source
  location (`loc.toChars`), reporting names such as `__unittest_L2_C13` and
  file-backed locations such as `path(1)`.
- `runModulesTests.runsBothModules` in `tests/ut/backends/runner/results.d` now
  covers `Bytecode`. This was a stale coverage gap: `runModulesTests` just calls
  `backend.runTests` on each module, and the existing `Bytecode.runTests` path
  plus its `throw`-expression support already ran both modules and propagated
  the second module's thrown message without production changes.
- `runBackendSourceFixtureTests.withImportPaths` and
  `runBackendFileFixtureTests.withImportPaths` in
  `tests/ut/backends/runner/results.d` now cover `Bytecode`. This was a stale
  coverage gap: DMD semantic analysis resolves the imported module function as
  a `FuncDeclaration` with a populated `fbody`, so the existing `compileCall`
  path emitted the ordinary `Op.call` and the VM executed the call frame and
  returned `int` without production changes. The import-path plumbing already
  flowed through the shared fixture parse helpers.
- `repl.backend.evaluatesExpressionCellsUntilQuit` in
  `tests/ut/bin/repl.d` now covers `Bytecode`. The promotion exposed
  the missing bytecode `evalRepl` API, so Bytecode now compiles an already
  parsed REPL eval cell and runs expression cells through the existing VM
  eval path.
- `malloc` in `tests/ut/backends/runner/rt/cstdlib.d` now covers `Bytecode`,
  completing that module. The promotion exposed the missing
  no-available-source diagnostic: `malloc` resolves to a `FuncDeclaration`
  with a null `fbody` and is not an implemented builtin, so `compileCall` now
  reports `` `malloc` cannot be interpreted at compile time, because it has no
  available source code `` instead of the generic unsupported-call-target
  message. The pointer casts, indexing, and `scope(exit)` in the source are
  never reached, matching the CTFE and tree-walker oracles.
- `assertNonzeroIntCondition`, `assertNonzeroIntConditionFailureMessage.0`,
  and `assertNonzeroIntConditionFailureMessage.1` in
  `tests/ut/backends/runner/ct/logic.d` now cover `Bytecode`. The promotion exposed
  missing bitwise-or expression support for `40 | mask()`, so bytecode now
  lowers DMD `OrExp` to a narrow `bitOr` opcode and preserves the existing
  assertion truthiness and equality diagnostics.
- `logicalNot`, `logicalNotCall`, `logicalNotFailureMessage.0`,
  `logicalNotFailureMessage.1`, `logicalNotCallFailureMessage.0`, and
  `logicalNotCallFailureMessage.1` in `tests/ut/backends/runner/ct/logic.d` now
  cover `Bytecode`. The promotion exposed missing DMD `NotExp` lowering, so
  bytecode now lowers logical not to a unary opcode using VM truthiness and
  reports failed bool equality assertions as `true`/`false`.
- `logicalAnd`, `logicalAndFailureMessage.0`,
  `logicalAndFailureMessage.1`, `logicalAndCall`,
  `logicalAndCallFailureMessage.0`, `logicalAndCallFailureMessage.1`,
  `logicalAndShortCircuit`, `logicalAndShortCircuitFailureMessage.0`,
  `logicalAndShortCircuitFailureMessage.1`,
  `logicalAndCallShortCircuit`,
  `logicalAndCallShortCircuitFailureMessage.0`, and
  `logicalAndCallShortCircuitFailureMessage.1` in
  `tests/ut/backends/runner/ct/logic.d` now cover `Bytecode`. The promotion
  exposed missing DMD `LogicalExp` `&&` lowering, so bytecode now emits narrow
  jump/pop control flow for short-circuit evaluation, normalizes both paths to
  bool, and preserves plain assertion text for failed truth assertions.
- `logicalOr`, `logicalOrBoolResult`,
  `logicalOrBoolResultFailureMessage.0`,
  `logicalOrBoolResultFailureMessage.1`, `logicalOrFailureMessage.0`,
  `logicalOrFailureMessage.1`, `logicalOrOops`, `logicalOrShortCircuit`,
  `logicalOrShortCircuitFailureMessage.0`, and
  `logicalOrShortCircuitFailureMessage.1` in
  `tests/ut/backends/runner/ct/logic.d` now cover `Bytecode`. The promotion
  exposed missing DMD `LogicalExp` `||` lowering, so bytecode now emits narrow
  jump/pop control flow for short-circuit evaluation, normalizes both paths to
  bool, and reports failed `assert(!condition)` diagnostics such as
  `true == true`.
- `logicalAndComparisonOperands`,
  `logicalAndComparisonOperandsFailureMessage.0`, and
  `logicalAndComparisonOperandsFailureMessage.1` in
  `tests/ut/backends/runner/ct/logic.d` now cover `Bytecode`, completing the module.
  The promotion exposed missing DMD `CmpExp` lowering for comparison operands
  inside logical expressions, so bytecode now lowers the required integer `<`
  and `>` comparisons to bool results while preserving bool equality assertion
  diagnostics such as `true != false` and `false != true`.
- `voidFunctionReturnsToCaller` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: the existing bytecode module test path already handled a
  called `void` function returning to its unittest caller before reporting the
  following failed integer equality assertion as `1 != 2`.
- `intLessThanOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing bytecode assertion diagnostics for
  failed `<` assertions: bytecode now tags assertion comparisons with the
  comparison operation and reports the inverse failed relation, such as
  `42 >= 42`, instead of a generic failed assertion string.
- `intLessOrEqualOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `<=` lowering in bytecode, so
  the VM now evaluates a narrow `lessOrEqual` opcode and formats failed
  assertion diagnostics with the inverse operator, such as `43 > 42`.
- `intGreaterThanOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. The promotion exposed that `>` expression execution already
  existed, but assertion-specific comparison lowering did not tag failed `>`
  assertions. Bytecode now emits `Op.greaterThan` for that path and reports the
  inverse failed relation, such as `42 <= 42`.
- `intGreaterOrEqualOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `>=` lowering in bytecode, so
  the VM now evaluates a narrow `greaterOrEqual` opcode and formats failed
  assertion diagnostics with the inverse operator, such as `41 < 42`.
- `intNotEqualOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. The promotion exposed that DMD `EqualExp` lowering did not yet
  distinguish `!=` from `==`, so bytecode now emits and evaluates a `notEqual`
  opcode and reports failed `!=` assertions with the inverse operator, such as
  `42 == 42`.
- `ok` in `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. This
  was a stale coverage gap: the existing bytecode function-call, return, and
  equality assertion path already handled the passing assertion.
- `oops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. This
  was a stale coverage gap: the existing bytecode equality assertion diagnostic
  path already reported the failed function-return comparison as `42 != 43`.
- `okFailureMessage.0` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode equality
  assertion diagnostic path already reported the failed function-return
  comparison as `7 != 8`.
- `localIntReturnOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode local
  declaration, load, function-return, and equality assertion diagnostic path
  already reported the failed comparison as `42 != 43`.
- `voidFunctionOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode call-frame
  and integer assertion-failure path already propagated the failure from a
  called `void` function as `` `assert(0)` failed ``.
- `functionParametersOops` in `tests/ut/backends/runner/ct/diagnostics.d` now
  covers `Bytecode`. This was a stale coverage gap: the existing bytecode
  parameter binding, integer addition, return, and equality assertion
  diagnostic path already reported the failed comparison as `43 != 42`.
- `tenFunctionParametersOops` in `tests/ut/backends/runner/ct/diagnostics.d` now
  covers `Bytecode`. This was a stale coverage gap: the existing bytecode call
  frame parameter binding handled the wider ten-argument call and reported the
  failed summed comparison as `56 != 42`.
- `functionParameterOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode single
  parameter binding, integer addition, return, and equality assertion
  diagnostic path already reported the failed comparison as `42 != 43`.
- `ifElseOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `IfStatement` lowering in the
  bytecode compiler, so bytecode now emits narrow branch control flow using the
  existing jump opcodes and reports the selected branch result as `43 != 42`.
- `refParameterOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing local assignment lowering and
  scalar local `ref` argument writeback. Bytecode now lowers simple local
  assignment, records local reference arguments for calls, writes ref parameter
  locals back to caller locals on return, and reports the final failed
  comparison as `42 != 43`.
- `inFunctionParametersOops` in `tests/ut/backends/runner/ct/diagnostics.d` now
  covers `Bytecode`. This was a stale coverage gap: bytecode already treats
  `in int` parameters as value parameters, evaluates the integer addition in
  the callee, and reports the failed equality assertion as `43 != 42`.
- `refSizeTParameterOops` in `tests/ut/backends/runner/ct/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing scalar `ref`
  parameter writeback path already handles `size_t`, so bytecode increments
  the caller local and reports the final failed comparison as `42 != 43`.
- `explicitAssertMessageOverridesContext` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: bytecode already gives an explicit assertion message
  priority over generated comparison context, so `assert(1 == 2, "oops")`
  reports `oops`.
- `literalFalseAssertionMatchesDmd` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: bytecode already reports a literal false assertion as
  `` `assert(false)` failed ``.
- `runtimeBoolAssertionContextMatchesDmd` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. The promotion
  exposed that DMD lowers runtime truth assertions through an internal
  assertion temporary. Bytecode now suppresses that lowered temp text for
  runtime truth assertions and reports the failed bool relation as
  `false != true`, while preserving explicit assertion messages and literal
  `assert(false)` diagnostics.
- `boolAssertionContextMatchesDmd` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: bytecode already preserves bool operands in equality
  assertion diagnostics and reports `true != false`.
- `charAssertionContextMatchesDmd` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. The promotion
  exposed that bytecode assertion diagnostics rendered char operands as their
  integer code units. Bytecode now formats comparisons between two char
  operands as D char literals, such as `'a' != 'b'`.
- `dynamicAssertMessageMatchesDmd` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing dynamic assertion-message handling: bytecode now evaluates a
  variable assertion message only on the failing branch, unwraps DMD's cast
  wrapper around that message expression, and throws the evaluated string
  `oops`.
- `nullClassMethodCallReportsDiagnostic` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing `null` expression support and missing receiver diagnostics
  for dot-call class methods. Bytecode now lowers DMD `null` to `Value.null_`
  and checks the dot-call receiver before emitting the function call, reporting
  `function call through null class reference `null``.
- `nullClassFieldReadReportsDiagnostic` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing DMD `DotVarExp` lowering for class field reads. Bytecode now
  evaluates the field receiver and reports the null-receiver diagnostic
  `` class `thing` is `null` and cannot be dereferenced `` before leaving
  non-null class field reads unsupported.
- `typeidNullClassReferenceReportsDiagnostic` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing DMD `TypeidExp` and `IdentityExp` lowering for this
  diagnostic path. Bytecode now evaluates expression-backed `typeid`, reports
  `` null pointer dereference evaluating typeid. `thing` is `null` `` for a
  null class reference, and keeps general TypeInfo behavior outside this
  slice.
- `voidInitializedScalarReadReportsUninitialized` in
  `tests/ut/backends/runner/ct/diagnostics.d` now covers `Bytecode`, completing the
  module. The promotion exposed missing `= void` local tracking. Bytecode now
  marks void-initialized scalar locals with `Value.void_` and reports CTFE-style
  uninitialized-read diagnostics such as
  `` cannot read uninitialized variable `.answer.value` in ctfe `` when the
  local is loaded.
- `evaluatesRuntimePowDoubleInputs` in `tests/ut/backends/runner/ct/math.d` now
  covers `Bytecode`. The promotion exposed that bytecode assertion comparisons
  only accepted integer-compatible operands; bytecode now compares numeric
  operands through `Value.asReal`, allowing the existing `std.math.pow` builtin
  bridge to handle runtime `double` inputs and fractional bounds.

## Current Next Step
Begin rewrite slice 1: stand up the new typed-frame core behind an internal
engine switch on `Bytecode` (defaulting to the old core), make the
smallest `integrals.d` behaviour pass on the new core in CTFE-only mode,
and stand up scalar `Value` reification so the first `eval.d` block
re-earns alongside it.

Promotion of further test modules onto the old core stops; new surface area
(`control_flow.d`, `structs.d`, `arrays.d`, `exceptions.d`) is earned
directly on the new core per the slice roadmap.

## Test Plan
- Use public behavior tests only for language semantics and backend parity.
- Add focused VM contract tests only for bytecode-specific properties such as
  operand typing, frame behavior, and diagnostic boundaries.
- Keep unsupported-slice tests narrow and behavior-driven, not layout-driven.
- Oracles are per mode: in CTFE-only mode DMD CTFE is canonical for
  legality and diagnostics (value semantics defer to compiled correctness —
  see Modes and Oracles); in full-D mode really-compiled
  `dmd -unittest -checkaction=context` output is, byte for byte. Where the
  two disagree, the test carries per-mode expectations.
- CTFE coverage reports do not rank Quickbite test modules by simplicity. All
  backend language modules run against CTFE, so use
  `ai/plans/backend-test-modules-order.md` to choose post-`eval` targets by
  required D language features, not by file length or coverage counts.
- Verify each new slice before expanding scope: red test, minimal
  implementation, green suite, then the next slice.
- Do not trust backend progress text as an edit target without checking the
  test file. A stale plan should trigger current-test discovery, not a broad
  promotion.
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
- [Superseded by the native-layout memory model above.] The first
  implementation used `Value` as the stack slot type as an accepted cost.
  The rewrite removes `Value` from the VM entirely; slots are typed frame
  memory and conversion happens only at the `Evaluator` boundary.
- Make operands earn their shape. Avoid a generic `long` operand, ad hoc
  integer-specialized operands, or a half-built sum type unless the current test
  proves that shape is needed.
- Do not split one language operation into one opcode per scalar type unless
  the VM semantics genuinely differ. Prefer one opcode with a typed operand
  domain, for example a cast opcode plus a target-type operand, before adding
  `castInt`, `castFloat`, or similar families.
- Exception: for arithmetic and comparison opcodes, the compiler should select
  a type-tagged variant at emit time using the operand types from the semantic
  layer. This eliminates a runtime type-dispatch branch in the handler body
  without requiring runtime specialization. This is distinct from the
  cast-family anti-pattern — it applies only where the handler would otherwise
  branch on type and the compiler's static knowledge makes that branch
  unnecessary.
- Do not add module-level helpers that only wrap a single call unless they make
  an active test simpler. Prefer inlining or overloading when that is clearer.
- Keep names precise and conventional: use "variables" for variable metadata,
  "indices" as the plural of index, and avoid names such as
  `bytecode.bytecode`.
- Preserve the repo's formatting style before asking for review. Formatting
  churn distracts from the design slice.

## PR 123 Review Lessons
- Do not derive eval structure by inspecting source text in any layer. Splits
  on newlines, semicolons, braces, or keywords are parser bugs waiting to
  happen. Ask the frontend for a structured cell, DMD module, function
  declaration, statement, or expression instead.
- Do not paper over that rule by moving source splitting into
  `quickbite.frontend.cell`. A helper that loops over `source.lineSplitter`,
  feeds each line to the REPL cell classifier, then returns a wrapper function
  is still source-text protocol, not a structured frontend API.
- Do not mark the eval-source review comments addressed while
  `parseEvalFunction` still exists as "turn source into `auto f() { ... }`,
  parse a module, then find function `f`". That is the abstraction the review
  rejected.
- Do not add or keep a "find function by name in module" helper for eval. If a
  backend needs a function declaration, the frontend should hand back the
  declaration as part of a named cell/result type, not require callers
  to know about the synthetic wrapper name.
- Do not add a special `parseEvalFunction`-style API if it only synthesizes a
  wrapper function and looks up `f`. Either reuse the existing REPL cell
  frontend path, or expose a frontend API named for the AST/domain object the
  backend actually needs.
- Treat review comments like "Why does this exist?" and "?" as a demand to
  justify ownership and abstraction. If the helper only moves the same opaque
  operation elsewhere, delete it or inline it until a real boundary emerges.
- Do not put new shared frontend helpers in vague catch-all modules such as
  `util.d`. If the helper is worth sharing, name the module after the domain
  concept it exposes.
- Do not create a tiny bytecode compiler helper just to hide four emitted
  instructions. Inline the lowering until a second behaviour makes the
  abstraction earn its name and shape.
- Do not add or keep a special VM opcode for a language operation that is just
  existing bytecode plus typed operands. `++x` should lower through `add`
  unless VM semantics genuinely differ.
- Do not infer bytecode call support from CTFE success. CTFE delegates execution
  to DMD's interpreter, so `std.math.fabs`/`pow` working there does not mean the
  bytecode VM can execute those calls without either general D call support or a
  deliberately scoped native-call bridge.
- Do not clone DMD builtin-detection internals such as mangle prefixes. If the
  bytecode backend needs CTFE builtin parity, use DMD's builtin classification
  or a project-owned semantic wrapper around it, then keep bytecode execution
  scoped to the implemented builtin subset.
- Do not answer "use introspection on std.math" with a hand-maintained
  duplicate of DMD's entire builtin enum plus string mixins. If only `fabs` and
  `pow` are implemented, keep the implemented surface small, explicit, and
  mechanically connected to DMD's builtin classification.
- Do not use `static foreach` plus string `mixin` to hide tiny two-case
  dispatch. The review explicitly called out mixin use here; prefer ordinary
  `final switch` cases until real duplication justifies compile-time
  generation.
- Do not emit untyped convenience literals such as `Value(1)` when lowering a
  typed language operation. Either derive the literal from the D type or make
  assignment/storage perform the required D conversion.
- Do not treat "move this to common frontend code" as permission to relocate
  opaque wrappers unchanged. Name the frontend API for the AST structure the
  backend needs, and leave source-shaping details behind that API.
- When extracting shared DMD symbol lookup, check nearby callers for duplicate
  local implementations and move them together if the ownership boundary is
  the same.
- Do not mark a PR review checklist item complete just because the offending
  code moved. Before checking it off, `rg` for the rejected names/patterns and
  verify the new code no longer does the rejected behaviour.

## PR 123 Remaining Cleanup
- [x] Remove `parseEvalFunction` as a source-to-wrapper-function API. Replace
  it with a frontend-owned eval cell/result that exposes the structured
  AST object the backends actually need.
- [x] Remove line-by-line eval parsing from `frontend.cell`; eval source should
  not be decomposed by newline boundaries.
- [x] Remove synthetic-wrapper-name lookup from eval/repl paths. The wrapper
  may exist as frontend implementation detail, but callers should not know or
  search for `f`.
- [x] Revisit bytecode builtin support after removing the mixin-generated
  duplicate builtin enum mapping. Keep only the implemented native-call bridge
  surface unless a test forces broader builtin metadata.

## PR 114 Review Follow-up
- [x] Explain or remove the `compileEvalSource` wrapper around eval input.
- [x] Justify or remove import-statement skipping in bytecode statement
  compilation.
- [x] Refactor duplicated binary-expression compilation.
- [x] Remove all non-module-scope `imported!"..."` usages from bytecode
  compiler helpers.
- [x] Make `castTarget` return the operand type expected by bytecode
  instructions.
- [x] Remove direct `pow` function-name special-casing from bytecode call
  compilation.
- [x] Remove direct `fabs` function-name special-casing from bytecode call
  compilation.
- [x] Decide whether integer casts need broader tests before broadening
  support.
- [x] Stop inspecting eval source text in the bytecode backend; rely on a
  frontend-provided structure instead.
- [x] Remove eval source string splitting from shared frontend code; drive eval
  through parser-backed REPL/frontend classification instead.
- [x] Remove or replace `parseEvalFunction` if it remains only a wrapper-source
  synthesizer plus `f` lookup.
- [x] Replace hand-written default scalar values with a type-to-D-value mapping
  based on `T.init`.
- [x] Replace manual string code-unit conversion with DMD literal slice
  support; no `std.utf`/`std.uni` helper is needed for the current AST node.
- [ ] Include bool and character value kinds in integer-like binary operations
  if DMD treats them that way.
- [x] Decide whether `incrementLocal` should remain distinct from `add`.
- [x] Clarify or remove the `CastTarget` enum if the current operand shape is
  not earning its keep.
- [x] Remove one-off `Value.fabs` API growth or justify it with a more general
  native-call design.
- [x] Remove one-off `Value.pow` API growth or justify it with a more general
  native-call design.

## Peephole Optimisation
- Optional bytecode-level optimisations, such as peephole passes over the
  emitted instruction stream, are the first optimisation step after correctness
  is established.
- The pass must be optional and togglable at runtime so it can be benchmarked
  against a large body of D code with and without. The artifact format must not
  preclude it (do not seal or hash bytecode arrays before the pass runs).
- Do not add the pass until a benchmark justifies it.

## Builtins and Native Calls
- CTFE-only mode never calls native code. CTFE builtin parity (`sqrt`,
  `fabs`, ...) stays mechanically tied to DMD's builtin classification and
  is executed by the VM; druntime lowerings are intercepted at the call site
  and applied to VM-owned memory.
- In full-D mode the native bridge (see Core Architecture) is the general
  mechanism: values cross unchanged because VM memory is native-layout, and
  the call itself goes through the bridge's cached libffi descriptors.
  Bridge entries carry typed signatures, the cached CIF, and cached symbol
  resolution; D exceptions crossing the boundary are converted between
  native and VM unwinding at the bridge.

## Exception Handling
- Each compiled function artifact includes a handler table. For unittest blocks
  the minimum is a sorted array of `(start_pc, end_pc, handler_pc)` triples with
  one try-region covering the whole block body.
- Once bytecode supports D `try`/`catch`/`finally`, handler entries become typed
  records instead of bare triples. They must include the handler kind, optional
  caught class/type id, optional catch-binding local slot, catch ordering, and
  enough continuation metadata for `finally` to resume the pending action:
  throw, return, break/continue/goto, or normal fallthrough.
- On `throw` or assert failure the VM binary-searches the handler table and
  either jumps to the handler PC or unwinds the frame and propagates to the
  caller.
- D exceptions must not propagate silently through every C interpreter frame;
  the VM owns the decision of how test failures are caught and reported.
- In full-D mode thrown objects are real `Throwable` instances on the host
  heap; the bridge converts between native unwinding and VM unwinding at
  boundary crossings. In CTFE-only mode uncaught exceptions report DMD's
  "uncaught CTFE exception" text.

## Debug Info
- The minimum required is bytecode-offset-to-source-line mapping, sufficient
  for "assert failed at line N" messages. Variable name tables are useful for
  REPL display but are not required for test pass/fail output and should not
  be added until the REPL needs them.

## Constant Pool
- Deduplicate constants (strings, numbers) at generation time using an intern
  table scoped to the VM session, compilation batch, or artifact cache
  generation. The table must have allocator-owned lifetime and an explicit
  reset or invalidation path. D test code repeats the same string literals
  across functions (type names, `__traits(identifier)` results); per-function
  undeduped pools waste memory and add cache pressure. If cross-artifact
  interning is needed for cached dependency bytecode, tie the intern table to
  the same cache key and lifetime as the dependency artifact.

## Closures
- Representation is decided now; implementation is deferred until a test
  forces it. Captured variables live in a GC-heap closure environment
  addressed through an environment pointer — exactly the layout DMD codegen
  produces — and everything else stays a plain frame slot. DMD semantic
  analysis has already computed the capture set
  (`FuncDeclaration.needsClosure()`, `closureVars`); the bytecode compiler
  consumes it the same way it consumes `Type.size()` and
  `VarDeclaration.offset`. No upvalue machinery: open/closed upvalue chains
  exist for languages that discover capture dynamically, and D is not one
  of them.
- The slice-1 frame layout encodes one rule at zero implementation cost:
  closure variables are not frame slots. That removes the retrofit risk
  entirely.
- The deferral horizon is short: capturing lambdas arrive with the first
  Phobos-using full-D test (see Native bridge) and are common in plain
  project test code.
- Exposing test: `int local = 1; auto f = () => local; local = 2;
  assert(f() == 2);` — write-through visibility after capture; any
  copy/snapshot representation of capture fails it.

## Assumptions
- Direct parser-to-bytecode generation is out of scope; AST-first lowering
  from semantically analyzed DMD ASTs is the starting point, and DMD's
  computed layout information is authoritative.
- The bytecode VM is optimized for unittest latency, not long-running
  execution throughput. JIT compilation remains a future experiment.
- Linux x86_64 first, matching `SystemLinker`'s existing platform
  assumptions; other targets follow the host ABI through the same layout
  queries.
- The VM should remain independent of DMD internals except at the compiler
  boundary.
