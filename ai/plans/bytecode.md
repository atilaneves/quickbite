# Bytecode VM Architecture Plan

## Summary
Design and build, from scratch, a bytecode VM for D behind the existing
`Bytecode` backend. The VM compiles semantically analyzed D ASTs into an
internal bytecode artifact and executes it in-process, with no object files
and no linker on the hot path.

Product goal:

1. Minimise the latency from an edit in the project under test (not
   necessarily in its dub dependencies) to a yes/no "did the relevant tests
   pass?" answer. Parse and semantic analysis are fixed costs. This plan
   covers the execution engine only: compiling from the AST and running.
   Bytecode artifact caching and affected-test selection are separate, later
   plans; this design must not preclude them but does not deliver them.

The VM targets all of D and is held to one oracle: compiled D.

**Deferred (out of scope):** serving as a replacement for the DMD CTFE
engine. That goal implied a per-backend CTFE-only/full-D mode and a second
(CTFE) oracle; both are dropped (`ai/plans/single-oracle.md`). Revisit only
if the current CTFE engine is actually replaced, at which point a
CTFE-faithful mode and its legality/diagnostics matching can be re-specified
from scratch. The design must not *preclude* that swap (see "Re-entrancy"
below), but it is not built for now.

Correctness overrides the goal: the VM must have the same observable
semantics as if the source had been compiled to native code and run. Fast
but wrong is worthless.

## Oracle
- The single oracle is really-compiled code, via `SystemLinker`
  (`ai/plans/single-oracle.md`). The arbiter for any observable behaviour,
  including failure message text, is a real
  `dmd -unittest -checkaction=context` compile-and-run of the fixture, byte
  for byte — the same discipline `dmd-backend.md` established for
  `SystemLinker`.
- `Ctfe` is not an oracle. Where `Ctfe` diverges from `SystemLinker` (e.g.
  the static-array-copy aliasing quirk), the VM produces the
  compiled-D result and the divergence is characterized against `Ctfe`,
  not emulated.
- Re-entrancy (keeping the deferred CTFE swap possible): the VM core is
  re-entrant with no global mutable state, entry is per-`FuncDeclaration`
  rather than per-module, and results are reachable as raw memory plus a
  static type, so they can be reified as a DMD `Expression` just as well as
  a `quickbite.lang.Value`. This costs nothing now and leaves the door open.

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
- Heap: interpreted data structures are native data structures
  and the host GC owns the heap. The druntime lowering hooks are templates
  (`_d_newclassT!T`, `_d_arrayappendT`, `_d_aaGetY`) instantiated into the
  project's compilation, so the VM executes their bodies like any other
  available source; only the leaves (`GC.malloc` and friends) are native
  calls, and those leaves consume runtime type metadata for VM-compiled
  types — see below. VM stack memory is registered with the host GC so
  references held in frames keep objects alive; conservative scanning of
  large frame regions (false-pointer pinning) and `addRange`/`removeRange`
  churn are known costs the bench checkpoints must watch.

### Runtime type metadata
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

So the VM synthesizes native `TypeInfo`/`TypeInfo_Class` instances,
init blobs, and vtables for VM-compiled types, with function-pointer slots
(dtor, postblit, copy ctor, toHash, opEquals) filled by inbound VM entry
thunks. "The real runtime manipulates the real heap" holds without this
metadata only for POD element/key types. Because GC finalization can fire
long after the allocating call, thunk lifetime is tied to the VM session,
not the call.

Exposing tests (compiled oracle): append to an array of a
struct with a postblit; `new` a class with `~this()`, drop the reference,
`GC.collect()`, assert the dtor ran; an AA keyed on a struct with a custom
`toHash`.

### Module-level state
- Each module gets a VM-owned data segment with native layout — sizes,
  alignments, and offsets from DMD, the same authority as frames. Segments
  are GC-registered like stack chunks.
- `static this()` runs before the first access to the module's state,
  ordered by druntime's cycle-checked import-graph semantics. This is an
  eager per-module obligation layered on lazy per-function compilation: the
  first call into a module triggers its (and its imports') constructors
  before the called function body runs.
- TLS: the VM executes single-threaded for now, so TLS and `__gshared`
  coincide. This is an explicit assumption, recorded with the
  concurrency-readiness constraints.

Exposing test (compiled oracle): a module with
`int counter; static this() { counter = 40; } int bump() { return counter += 2; }`
and a unittest asserting `bump() == 42` — forces segment storage,
ctor-before-first-access ordering, and function-level (not unittest-body)
visibility of the global.

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
- Decision update (2026-06-12, `ai/plans/value.md`): the `Evaluator`
  contract itself drops `Value` for a rendered display string. The
  boundary reification above becomes private interim scaffolding, deleted
  once this core can execute the in-program formatter prelude — expected,
  since the core is headed for full D.

### Deletion inventory (do not extend; added 2026-07-07)
The interim display scaffolding below is scheduled for deletion when the
prelude formatter lands on this backend (`ai/plans/value.md` decisions 3/4;
slice 11 in the roadmap). Do not add cases, types, or metadata to any of it.
If a test can only pass by extending one of these, the test waits for
slice 11.

- `source/quickbite/backends/evaluator.d`: the shared
  `displayString(Value, ...)` interim renderer — deleted with the formatter
  wiring (`value.md` remaining-work item 2).
- `source/quickbite/backends/bytecode/compiler.d` (legacy core): enum
  member-name detection emitting `Value.enumValue`, and struct-literal
  display via `Value.structDisplayValue`.
- `source/quickbite/backends/bytecode/core/compiler.d`:
  `structDisplayField` display metadata (nullable pointer / delegate /
  class-reference field kinds) and the `ResultType` enum value-name maps.
- `source/quickbite/backends/bytecode/core/reify.d`: display-only `Value`
  construction — `Value.structDisplayValue`, `Value.enumValue`, the
  `Value.stringValue` width variants, and nullable-field `Value.null_` /
  `Value.undisplayable` rendering.

Reification itself — reading frame bytes at a static type at the
`Evaluator` boundary — is not deprecated; it is the slice-1 debugging
instrument. What is deprecated is growing its *display* vocabulary: any
rendering knowledge beyond "these bytes at this type".

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

### Native bridge
- The boundary is the body-less leaf, not package ownership: native means
  `fbody is null` — C libraries and separately compiled extern symbols.
  Everything with available source is executed by the VM, including
  druntime and Phobos template bodies instantiated with project types
  (`xs.map!(x => x * 2)` has no precompiled body anywhere). Stated plainly:
  the VM will interpret large swaths of Phobos, which raises the feature
  floor for the latency goal — ranges, capturing lambdas, classes, and
  exceptions arrive with the first `std.algorithm`-using test, regardless of
  slice order.
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
  fixtures (matching the compiled oracle's `real` precision).
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
- The inbound trampoline is not a boxed marshalling layer. Native layout can
  let the trampoline bind native arguments directly to bytecode frame slots,
  hand existing slot addresses to the callee, and write the result straight
  back to the ABI return location. The trampoline is still required because
  native code can only call an executable address with the host ABI, while a
  bytecode callback is a VM callable plus context, frame setup, lifetime
  state, and re-entry rules. The trampoline supplies that native-callable
  address, recovers the callback identity, enters the bytecode machine, and
  handles ABI details such as hidden context/receiver/sret slots, argument
  order, narrow returns, and out/ref parameters.
- Exposing tests for the call mechanism (compiled oracle, byte
  for byte): call a precompiled extern function taking a 24-byte struct by
  value and returning one (forces memory-class classification and `sret`);
  the same with `real` in the signature.

### CTFE legality checking (deferred)
The checked-opcode / provenance-table machinery that made the VM match DMD
CTFE's legality and diagnostics existed only for the deferred CTFE-engine
replacement goal (`ai/plans/single-oracle.md`). It is out of scope: the VM
targets full D, emits unchecked operations, and `__ctfe` evaluates to
`false`. Re-specify checked execution from scratch if the CTFE-replacement
goal is ever revived.

### Concurrency readiness
- Threads, `synchronized`, atomics, and fibers are out of scope until a test
  forces them, with an explicit unsupported diagnostic. The design must not
  preclude them: no
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

### REPL parity continuation (re-scoped 2026-07-07)
REPL promotion is parity work against the existing `Interpreter` behaviour,
not `SystemLinker` enablement. Do not add `SystemLinker` to
`tests/ut/bin/repl.d` as part of this plan. The REPL still uses template code
emission paths that are separate from the bytecode backend parity work; proving
or fixing those paths belongs in a later plan.

Decision 2026-07-07: `repl.d` promotion is split into two kinds of behaviour
with different rules, so this track and the `ai/plans/value.md` formatter
track can proceed in parallel without one building what the other deletes.

- **Display-string tests are frozen for both bytecode engines.** Any
  `repl.d` test whose assertion is a rendered value display (`displays*`,
  literal suffixes, struct/enum/AA/range rendering) is not promoted further
  to `Bytecode` or `BytecodeNewCore`, and no new display metadata is added
  to serve one (see "Deletion inventory" under Core Architecture). These
  tests are re-earned in one deliberate slice — "Prelude formatter
  execution" (slice 11) — by executing `__quickbiteFormat` for real, not by
  extending `Value` reification. Already-green display rows stay green (they
  are part of the ratchet) but are maintained, not extended.
- **Non-display behaviours remain promotable, to `BytecodeNewCore` only:**
  session state, rebinding, buffering, imports, commands, loaded-unittest
  execution, and diagnostics hygiene. If a promoted block fails, stop the
  promotion worker there. Use one subagent to investigate and record the
  concrete missing bytecode behaviour, then a separate subagent to implement
  the minimal production fix. If the missing behaviour turns out to be
  display formatting, the block is frozen per the rule above, not fixed.
- **The legacy `Bytecode` engine is frozen** except for regressions in
  already-green behaviour. It is deleted wholesale at the default flip;
  teaching it new display behaviour is written off twice — once at the
  flip, and again when `value.md` deletes the `Value` display path.

Every non-refactor PR that changes production bytecode code must include a
visible behavioural test delta in the same PR. A plan update is not a test
delta. If merging or rebasing against `master` removes the test diff because
equivalent promotions landed elsewhere, the PR is no longer valid as-is:
either add or promote another relevant test from this track's backlog in
that PR, or drop the production change.

Before creating or handing off a PR, check the PR diff against `master`.
Production bytecode changes must be paired with relevant `tests/` changes,
and the production-code diff should stay below 200 changed lines. If the diff
is too small and still under that limit, continue with another block from
this track's backlog (see "Post-Flip Backlog") — not with `repl.d` display
promotion — instead of opening a tiny PR.

### Slice roadmap
Earn the design back test-first, in this order. Each slice follows the
existing discipline: red test (or an already-green matrix behaviour moved to
the new core), minimal implementation, green suite, benchmark checkpoint.

**Superseded as a work order (2026-07-09).** The slices below record the
design, not what to do next. The pre-flip diagnostic and `pow` intrinsic
items were completed before the default flip; every remaining slice now lives
in "Post-Flip Backlog".

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
2. (Removed.) Was CTFE provenance / checked opcodes — deferred with the
   CTFE-replacement goal (see Oracle). The slice number is kept so later
   cross-references hold.
3. Control flow completion: the `control_flow.d` surface (currently
   `SystemLinker`, plus `Ctfe` where it agrees).
4. Structs with native layout: field offsets from DMD, by-value copies,
   methods, constructors — the `structs.d` surface.
5. Arrays, slices, and pointers with true aliasing: real addresses into
   frame and VM-heap memory, slice write-through, pointer arithmetic — the
   `arrays.d` surface, including the cases a snapshot model can never pass.
6. Exceptions: handler tables, throw/catch/finally/scope(exit) — the
   `exceptions.d` surface.
7. Associative arrays and druntime lowerings via call-site interception
   against VM-owned memory (the technique the Interpreter backend proved
   out).
8. Native runtime: outbound native bridge, real druntime heap, host GC
   integration, compiled-output diagnostics. This slice also
   synthesizes runtime type metadata and decides the inbound trampoline
   mechanism — GC finalizers and AA key methods force thunks before classes
   do (see Runtime type metadata). If the slice ships POD-only element/key
   support first, that scoping is recorded in the matrix exclusions, not
   silent.
9. Classes: native object layout, vtables, virtual dispatch, built on the
   trampoline mechanism slice 8 established.
10. REPL session state. (`Value` reification does not live here; it starts
    in slice 1 and grows per slice.)
11. Prelude formatter execution (added 2026-07-07): the new core runs
    `string __quickbiteFormat(T)(T value)` (`quickbite.repl_prelude`) as an
    ordinary interpreted template — `static if` introspection, string
    building, and whatever Phobos surface the formatter's body demands.
    Entry criteria (sharpened 2026-07-07): at minimum, associative arrays
    (slice 7) and the Phobos string-building surface the formatter's body
    uses must execute on the new core — i.e. the post-flip associative-array
    backlog item is closed. Starting before the FFI bridge and classes is a
    judgment call on what the formatter body actually demands; starting
    before associative arrays is not. Exit criteria: `BytecodeNewCore`
    overrides
    `supportsReplPreludeFormatter()` to `true`, the frozen `repl.d` display
    rows are re-earned through the formatter, and the deletion inventory
    (Core Architecture) is deleted in the same slice. This is the only
    sanctioned path to further `repl.d` display coverage, and it is
    `value.md` decision 4's per-backend scaffolding deletion applied to
    this backend. Until this slice, the `value.md` formatter track owns
    `frontend/`, `repl_prelude.d`, and the opted-in `Ctfe`/`Interpreter`
    backends and does not touch `backends/bytecode/**`; this track does not
    touch the formatter gate. The two proceed in parallel with disjoint
    files.

### Discipline (from the first generation unless dated)
- Start each slice with the smallest behaviour that can honestly fail. If a
  slice needs unittest blocks, literals, equality, calls, returns, and
  assert handling all at once, it is too broad; pick a smaller test.
- Promote test modules in the order documented by
  `ai/plans/backend-test-modules-order.md`. Treat the module, not a single
  template instantiation, as the unit of migration; promote whole test
  families once one instantiation proves the behaviour.
- When orchestrating subagents, assign work by remaining named test
  behaviour or test family. A worker should not spend a slice on another
  type-width variant of an already-passing behaviour unless it is expected
  to expose a different missing VM feature.
- Rungs within this track are serial (added 2026-07-07): run one production
  worker at a time in `backends/bytecode/core/**`. Adjacent backlog items
  (e.g. module-level state and `ref` arguments) land in the same
  compiler/machine modules and will conflict. Cross-track parallelism (the
  `value.md` formatter track, the interpreter FFI track) is file-disjoint
  and safe; within-track parallelism is not.
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
  must beat the old core, and targets beating `SystemLinker`'s measured
  ~43 ms median per test by an order of magnitude on the bench fixtures.
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
- `evaluatesRuntimeSqrtInput` in `tests/ut/backends/runner/lang/math.d` now covers
  `Bytecode`. The promotion exposed missing unary `std.math.sqrt` builtin
  support, so bytecode now recognizes DMD's `sqrt` builtin and executes it
  through the existing unary native-call path.
- `evaluatesDifferentRuntimeSqrtInput` in `tests/ut/backends/runner/lang/math.d`
  now covers `Bytecode`. This was a stale coverage gap after the runtime
  `sqrt` builtin slice: the existing bytecode unary native-call path already
  executed a different runtime `sqrt` input correctly.
- `evaluatesDifferentRuntimeSqrtInputFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `4 != 5`.
- `evaluatesDifferentRuntimeSqrtInputFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `6 != 7`.
- `evaluatesRuntimeNonIntegerSqrtInput` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` builtin slice: the existing bytecode
  unary native-call path already executed the non-integer runtime `sqrt` input
  correctly.
- `evaluatesRuntimeNonIntegerSqrtInputFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `1.5 != 2.5`.
- `evaluatesRuntimeNonIntegerSqrtInputFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `2.5 != 3.5`.
- `evaluatesRuntimeNonPerfectSqrtInput` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` builtin slice: the existing bytecode
  unary native-call path already executed the non-perfect runtime `sqrt` input
  and comparison assertions correctly.
- `evaluatesRuntimeFabsDoubleInput` in `tests/ut/backends/runner/lang/math.d` now
  covers `Bytecode`. This was a stale coverage gap: the existing bytecode
  unary native-call path already recognizes and executes DMD's `fabs` builtin
  for negative runtime `double` inputs.
- `evaluatesRuntimeFabsPositiveDoubleInput` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
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
  symbols and literal expressions without adding a VM opcode.
- Handoff, 2026-07-07 (abandoned later the same day — do not pick this up):
  the legacy `Bytecode` engine is frozen per the re-scoped "REPL parity
  continuation" section, and display promotion waits for slice 11. The
  branch's display block is written off. Historical record follows.
  `bytecode-repl-continue` contains an uncommitted
  REPL scalar/type/no-display `Bytecode` promotion block in
  `tests/ut/bin/repl.d`, plus a partial narrow legacy bytecode fix. The
  original red failures were
  `repl.backend.displaysEnumValues.Bytecode` displaying enum values as
  integers, and `repl.backend.expressionCellsUsePreludeFormatter.Bytecode`
  rejecting `Point(1, 2L)` as an unsupported struct literal expression. The
  partial implementation preserves enum member display identity for
  enum-typed integer expressions and emits simple literal struct display values
  directly, without adding legacy VM opcodes. Focused runs passed for
  `displaysEnumValues.Bytecode`,
  `expressionCellsUsePreludeFormatter.Bytecode`, and
  `numericScalarDisplayUsesDLiteralSuffixes.Bytecode`. The production diff is
  intentionally kept under the 200-line PR cap by leaving non-literal struct
  construction and direct field reads unsupported in legacy `Bytecode`.
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
- The adjacent REPL string-display family now covers `BytecodeNewCore`:
  `repl.backend.displaysStaticStringArrayResults`,
  `repl.backend.displaysNestedEmptyStringValues`,
  `repl.backend.displaysWideStringValues`, and
  `repl.backend.displaysWideCharacterArrayValues`. This was implementation
  work, not stale coverage: the new core now reifies dynamic and static array
  results with character-array display metadata, preserves wide string result
  suffixes through result-type element metadata, and handles static string
  array result bytes.
- `evaluatesRuntimeIsNaNDoubleInput` in `tests/ut/backends/runner/lang/math.d` now
  covers `Bytecode`. The promotion exposed missing `std.math.isNaN` builtin
  support, so bytecode now recognizes DMD's `isnan` builtin and executes it
  through the existing unary native-call path.
- `evaluatesRuntimeIsNaNDoubleInputFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isNaN` builtin slice: the existing bytecode
  logical-not and bool equality assertion diagnostics already report
  `true == true`.
- `evaluatesRuntimeIsNaNDoubleInputFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isNaN` builtin slice: the existing bytecode
  `isNaN` builtin and bool equality assertion diagnostics already report
  `false != true`.
- `doesNotTreatUserNamedIsNaNAsMathIntrinsic` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap: bytecode already calls the user-defined `isNaN` function
  instead of treating it as the `std.math.isNaN` builtin.
- `doesNotTreatUserNamedPowAsMathIntrinsic` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap: bytecode already calls the user-defined `pow` function instead
  of treating it as the `std.math.pow` builtin.
- `evaluatesRuntimePowDoubleInputsFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. The promotion exposed
  bytecode assertion diagnostics formatting floating operands through integer
  scalar access. Bytecode now keeps existing integer-compatible assertion
  messages but renders floating operands through `Value` so runtime `pow`
  equality failures report `16 != 17`.
- `evaluatesRuntimePowDoubleInputsFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `pow` and floating assertion-diagnostic
  slices: the existing bytecode binary native-call path and comparison
  assertion diagnostics already report `3 <= 3.001`.
- `doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the user-defined `pow` and floating equality-diagnostic
  slices: bytecode already calls the user-defined function and reports
  `6 != 7`.
- `doesNotTreatUserNamedPowAsMathIntrinsicFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the user-defined `pow` and floating equality-diagnostic
  slices: bytecode already calls the user-defined function and reports
  `7 != 8`.
- `evaluatesRuntimeSqrtInputFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `3 != 4`.
- `evaluatesRuntimeSqrtInputFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `sqrt` and floating equality-diagnostic
  slices: the existing bytecode unary native-call path and assertion
  diagnostics already report `5 != 6`.
- `evaluatesRuntimeIsInfinityDoubleInput` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. The promotion exposed
  missing `std.math.isInfinity` builtin support and non-runtime declaration
  expressions in the fixture, so bytecode now treats non-var declarations as
  no-ops and executes `isInfinity` through the existing unary native-call path.
- `evaluatesRuntimeIsInfinityDoubleInputFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isInfinity` builtin slice: the existing
  bytecode logical-not and bool equality assertion diagnostics already report
  `true == true`.
- `evaluatesRuntimeIsInfinityDoubleInputFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `isInfinity` builtin slice: the existing
  bytecode `isInfinity` builtin and bool equality assertion diagnostics
  already report `false != true`.
- `evaluatesRuntimeSignbitDoubleInput` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. The promotion exposed
  missing `std.math.signbit` builtin support, so bytecode now recognizes
  DMD's `signbit` helper by identifier and executes it through the existing
  unary native-call path.
- `evaluatesRuntimeSignbitDoubleInputFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  integer equality assertion diagnostics already report `1 != 0` for negative
  zero.
- `evaluatesRuntimeSignbitDoubleInputFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  integer equality assertion diagnostics already report `0 == 0` for positive
  zero.
- `evaluatesRuntimeSignbitNanInput` in `tests/ut/backends/runner/lang/math.d` now
  covers `Bytecode`. This was a stale coverage gap after the runtime `signbit`
  builtin slice: the existing bytecode unary native-call path already preserves
  sign bits for positive and negative NaN inputs.
- `evaluatesRuntimeSignbitNanInputFailureMessage.0` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  `signbit` builtin and integer equality assertion diagnostics already report
  `1 != 0` for a negative NaN input.
- `evaluatesRuntimeSignbitNanInputFailureMessage.1` in
  `tests/ut/backends/runner/lang/math.d` now covers `Bytecode`. This was a stale
  coverage gap after the runtime `signbit` builtin slice: the existing bytecode
  `signbit` builtin and integer equality assertion diagnostics already report
  `0 == 0` for a positive NaN input.
- `tests/ut/backends/runner/lang/integrals.d` now covers `Bytecode` for
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
- `tests/ut/backends/runner/lang/integrals.d` is now complete for `Bytecode`.
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
- `malloc` in `tests/ut/backends/runner/sys/cstdlib.d` now covers `Bytecode`,
  completing that module. The promotion exposed the missing
  no-available-source diagnostic: `malloc` resolves to a `FuncDeclaration`
  with a null `fbody` and is not an implemented builtin, so `compileCall` now
  reports `` `malloc` cannot be interpreted at compile time, because it has no
  available source code `` instead of the generic unsupported-call-target
  message. The pointer casts, indexing, and `scope(exit)` in the source are
  never reached, matching the CTFE and tree-walker oracles.
- `assertNonzeroIntCondition`, `assertNonzeroIntConditionFailureMessage.0`,
  and `assertNonzeroIntConditionFailureMessage.1` in
  `tests/ut/backends/runner/lang/logic.d` now cover `Bytecode`. The promotion exposed
  missing bitwise-or expression support for `40 | mask()`, so bytecode now
  lowers DMD `OrExp` to a narrow `bitOr` opcode and preserves the existing
  assertion truthiness and equality diagnostics.
- `logicalNot`, `logicalNotCall`, `logicalNotFailureMessage.0`,
  `logicalNotFailureMessage.1`, `logicalNotCallFailureMessage.0`, and
  `logicalNotCallFailureMessage.1` in `tests/ut/backends/runner/lang/logic.d` now
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
  `tests/ut/backends/runner/lang/logic.d` now cover `Bytecode`. The promotion
  exposed missing DMD `LogicalExp` `&&` lowering, so bytecode now emits narrow
  jump/pop control flow for short-circuit evaluation, normalizes both paths to
  bool, and preserves plain assertion text for failed truth assertions.
- `logicalOr`, `logicalOrBoolResult`,
  `logicalOrBoolResultFailureMessage.0`,
  `logicalOrBoolResultFailureMessage.1`, `logicalOrFailureMessage.0`,
  `logicalOrFailureMessage.1`, `logicalOrOops`, `logicalOrShortCircuit`,
  `logicalOrShortCircuitFailureMessage.0`, and
  `logicalOrShortCircuitFailureMessage.1` in
  `tests/ut/backends/runner/lang/logic.d` now cover `Bytecode`. The promotion
  exposed missing DMD `LogicalExp` `||` lowering, so bytecode now emits narrow
  jump/pop control flow for short-circuit evaluation, normalizes both paths to
  bool, and reports failed `assert(!condition)` diagnostics such as
  `true == true`.
- `logicalAndComparisonOperands`,
  `logicalAndComparisonOperandsFailureMessage.0`, and
  `logicalAndComparisonOperandsFailureMessage.1` in
  `tests/ut/backends/runner/lang/logic.d` now cover `Bytecode`, completing the module.
  The promotion exposed missing DMD `CmpExp` lowering for comparison operands
  inside logical expressions, so bytecode now lowers the required integer `<`
  and `>` comparisons to bool results while preserving bool equality assertion
  diagnostics such as `true != false` and `false != true`.
- `voidFunctionReturnsToCaller` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: the existing bytecode module test path already handled a
  called `void` function returning to its unittest caller before reporting the
  following failed integer equality assertion as `1 != 2`.
- `intLessThanOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing bytecode assertion diagnostics for
  failed `<` assertions: bytecode now tags assertion comparisons with the
  comparison operation and reports the inverse failed relation, such as
  `42 >= 42`, instead of a generic failed assertion string.
- `intLessOrEqualOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `<=` lowering in bytecode, so
  the VM now evaluates a narrow `lessOrEqual` opcode and formats failed
  assertion diagnostics with the inverse operator, such as `43 > 42`.
- `intGreaterThanOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed that `>` expression execution already
  existed, but assertion-specific comparison lowering did not tag failed `>`
  assertions. Bytecode now emits `Op.greaterThan` for that path and reports the
  inverse failed relation, such as `42 <= 42`.
- `intGreaterOrEqualOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `>=` lowering in bytecode, so
  the VM now evaluates a narrow `greaterOrEqual` opcode and formats failed
  assertion diagnostics with the inverse operator, such as `41 < 42`.
- `intNotEqualOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed that DMD `EqualExp` lowering did not yet
  distinguish `!=` from `==`, so bytecode now emits and evaluates a `notEqual`
  opcode and reports failed `!=` assertions with the inverse operator, such as
  `42 == 42`.
- `ok` in `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. This
  was a stale coverage gap: the existing bytecode function-call, return, and
  equality assertion path already handled the passing assertion.
- `oops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. This
  was a stale coverage gap: the existing bytecode equality assertion diagnostic
  path already reported the failed function-return comparison as `42 != 43`.
- `okFailureMessage.0` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode equality
  assertion diagnostic path already reported the failed function-return
  comparison as `7 != 8`.
- `localIntReturnOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode local
  declaration, load, function-return, and equality assertion diagnostic path
  already reported the failed comparison as `42 != 43`.
- `voidFunctionOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode call-frame
  and integer assertion-failure path already propagated the failure from a
  called `void` function as `` `assert(0)` failed ``.
- `functionParametersOops` in `tests/ut/backends/runner/lang/diagnostics.d` now
  covers `Bytecode`. This was a stale coverage gap: the existing bytecode
  parameter binding, integer addition, return, and equality assertion
  diagnostic path already reported the failed comparison as `43 != 42`.
- `tenFunctionParametersOops` in `tests/ut/backends/runner/lang/diagnostics.d` now
  covers `Bytecode`. This was a stale coverage gap: the existing bytecode call
  frame parameter binding handled the wider ten-argument call and reported the
  failed summed comparison as `56 != 42`.
- `functionParameterOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing bytecode single
  parameter binding, integer addition, return, and equality assertion
  diagnostic path already reported the failed comparison as `42 != 43`.
- `ifElseOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing DMD `IfStatement` lowering in the
  bytecode compiler, so bytecode now emits narrow branch control flow using the
  existing jump opcodes and reports the selected branch result as `43 != 42`.
- `refParameterOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. The promotion exposed missing local assignment lowering and
  scalar local `ref` argument writeback. Bytecode now lowers simple local
  assignment, records local reference arguments for calls, writes ref parameter
  locals back to caller locals on return, and reports the final failed
  comparison as `42 != 43`.
- `inFunctionParametersOops` in `tests/ut/backends/runner/lang/diagnostics.d` now
  covers `Bytecode`. This was a stale coverage gap: bytecode already treats
  `in int` parameters as value parameters, evaluates the integer addition in
  the callee, and reports the failed equality assertion as `43 != 42`.
- `refSizeTParameterOops` in `tests/ut/backends/runner/lang/diagnostics.d` now covers
  `Bytecode`. This was a stale coverage gap: the existing scalar `ref`
  parameter writeback path already handles `size_t`, so bytecode increments
  the caller local and reports the final failed comparison as `42 != 43`.
- `explicitAssertMessageOverridesContext` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: bytecode already gives an explicit assertion message
  priority over generated comparison context, so `assert(1 == 2, "oops")`
  reports `oops`.
- `literalFalseAssertionMatchesDmd` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: bytecode already reports a literal false assertion as
  `` `assert(false)` failed ``.
- `runtimeBoolAssertionContextMatchesDmd` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. The promotion
  exposed that DMD lowers runtime truth assertions through an internal
  assertion temporary. Bytecode now suppresses that lowered temp text for
  runtime truth assertions and reports the failed bool relation as
  `false != true`, while preserving explicit assertion messages and literal
  `assert(false)` diagnostics.
- `boolAssertionContextMatchesDmd` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. This was a
  stale coverage gap: bytecode already preserves bool operands in equality
  assertion diagnostics and reports `true != false`.
- `charAssertionContextMatchesDmd` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. The promotion
  exposed that bytecode assertion diagnostics rendered char operands as their
  integer code units. Bytecode now formats comparisons between two char
  operands as D char literals, such as `'a' != 'b'`.
- `dynamicAssertMessageMatchesDmd` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing dynamic assertion-message handling: bytecode now evaluates a
  variable assertion message only on the failing branch, unwraps DMD's cast
  wrapper around that message expression, and throws the evaluated string
  `oops`.
- `nullClassMethodCallReportsDiagnostic` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing `null` expression support and missing receiver diagnostics
  for dot-call class methods. Bytecode now lowers DMD `null` to `Value.null_`
  and checks the dot-call receiver before emitting the function call, reporting
  `function call through null class reference `null``.
- `nullClassFieldReadReportsDiagnostic` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing DMD `DotVarExp` lowering for class field reads. Bytecode now
  evaluates the field receiver and reports the null-receiver diagnostic
  `` class `thing` is `null` and cannot be dereferenced `` before leaving
  non-null class field reads unsupported.
- `typeidNullClassReferenceReportsDiagnostic` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`. The promotion
  exposed missing DMD `TypeidExp` and `IdentityExp` lowering for this
  diagnostic path. Bytecode now evaluates expression-backed `typeid`, reports
  `` null pointer dereference evaluating typeid. `thing` is `null` `` for a
  null class reference, and keeps general TypeInfo behavior outside this
  slice.
- `voidInitializedScalarReadReportsUninitialized` in
  `tests/ut/backends/runner/lang/diagnostics.d` now covers `Bytecode`, completing the
  module. The promotion exposed missing `= void` local tracking. Bytecode now
  marks void-initialized scalar locals with `Value.void_` and reports CTFE-style
  uninitialized-read diagnostics such as
  `` cannot read uninitialized variable `.answer.value` in ctfe `` when the
  local is loaded.
- `evaluatesRuntimePowDoubleInputs` in `tests/ut/backends/runner/lang/math.d` now
  covers `Bytecode`. The promotion exposed that bytecode assertion comparisons
  only accepted integer-compatible operands; bytecode now compares numeric
  operands through `Value.asReal`, allowing the existing `std.math.pow` builtin
  bridge to handle runtime `double` inputs and fractional bounds.

## Rewrite Coverage State
Matrix behaviours re-earned on the new typed-frame core, which the test
matrix names `BytecodeNewCore` (the strangler-pattern handle on the engine
switch; `Bytecode` still defaults to the old core):

- `literal` in `tests/ut/backends/evaluator/eval.d`: the first eval scalar
  block. Stood up the new core end to end: fixed-width instructions with
  16-bit operands, a raw-bits constant pool, typed frame slots, and scalar
  `Value` reification at the `Evaluator` boundary
  (`backends/bytecode/core/{program,compiler,machine,reify}.d`).
- `type.*` (all eight integral widths) in
  `tests/ut/backends/runner/lang/integrals.d`: native-layout locals and
  parameters at DMD-computed sizes and alignments, lazy per-function
  compilation through a machine callback, calls with contiguous argument
  areas, truncating and sign-extending casts, comma expressions, and the
  `-checkaction=context` lowered equality assert compiled as a width-tagged
  compare plus an assert-diagnostic record.
- `typeFailureMessage.{byte,ubyte,uint}.0` in the same module, completing
  `integrals.d` on the new core: the lowered `_d_assert_fail` operands keep
  their unpromoted source types, so the compiler replicates D's integer
  promotions at emit time (sign/zero-extension opcodes shared with the cast
  path) and failed equality asserts render both operands from frame bytes
  at the comparison width.
- `signedUnsignedComparisonIsUnsigned` and `wraparoundAtTypeBoundaries` in
  `tests/ut/backends/runner/lang/integrals.d` now cover `BytecodeNewCore`.
  `signedUnsignedComparisonIsUnsigned` was a stale coverage gap: existing
  integer promotions and unsigned-comparison opcodes already matched the
  `SystemLinker` oracle. `wraparoundAtTypeBoundaries` exposed missing
  unsigned 4-byte subtraction lowering; `compileSubtractExpression` now uses
  the existing 4-byte integer helper so `uint - uint` wraps through
  `Op.subInt4` and stores a `uint` result.
- All remaining `tests/ut/backends/evaluator/eval.d` blocks, completing
  `eval.d` (module order 1) on the new core. Earned in four slices:
  (a) compound assignment — `++x` lowers to `x += 1` through the existing
  `addInt4` writing back into the lvalue's own slot, no increment opcode
  (`multiCell`); (b) floating-point scalars — `float_`/`double_` `ScalarType`s,
  `RealExp` literals into the constant pool, type-tagged float/double add,
  subtract, and negate opcodes, double->int numeric-truncation cast, and
  float/double reification (`add.float`, `castsFloatingValueNumerically`,
  `floatingSubtractionUsesNumericValues`, `floatingUnaryMinusUsesNumericValue`,
  and the `1.25` case in `preservesScalarValueTypes`); (c) `std.math` float
  builtins — `fabs`/`pow` recognised via DMD's `isBuiltin` classification and
  executed as VM intrinsics typed by the call's static return type, preserving
  the `float` result (`fabsFloatPreservesReturnType`,
  `powFloatDoesNotReturnDoubleValue`); (d) string literals — a `StringExp`
  result lowers to a slice descriptor into a read-only `Program.data` segment,
  reified at the boundary, with a `ResultType` distinguishing the non-scalar
  string from the scalar path (`stringLiteralIsArray`). The string slice is
  the leading edge of the later arrays slice; only literals are supported.
- All `tests/ut/backends/runner/lang/logic.d` blocks, completing `logic.d`
  (module order 4) on the new core. Earned in three slices (the four-root-cause
  analysis below predicted four subagents; `&&` and `||` share one
  short-circuit lowering, so the third slice greened both): (a) bitwise-OR —
  an `OrExp` branch emitting a single `bitOrInt4` opcode, plus the `""`
  truth-assert form `_d_assert_fail("", intExpr)` via `assertNonzeroInt4`
  (`assertNonzeroIntCondition*`); (b) logical-NOT — a `NotExp` branch emitting
  one `notBool` opcode, the `_d_assert_fail("!", expr)` operator rendered as
  `<value> == true`, and the equality forms reusing the existing `"=="` path
  once `!x` yields a `bool_` (`logicalNot*`); (c) logical-AND/OR short-circuit
  — one `compileLogicalExpression` for both `andAnd` and `orOr` using
  `jumpIfFalse`/`jumpIfTrue` and `normaliseBool` into a single `bool_` result
  slot, integer comparison operands (`lessThan4`/`greaterThan4`, plus `divInt4`
  for the short-circuited `42 / zero` RHS that still compiles), a verbatim
  `StringExp` assert (`assertTrueVerbatim`) for plain-truth `&&`/`||` failures,
  and an unconditional `halt` for literal-false `assert(0)` (null msg) throwing
  the compiled-D `"Assertion failure"` (`logicalAnd*`, `logicalOr*`). The
  `assert(0)` divergence is why `BytecodeNewCore` joins the
  `SystemLinker`/`LLVMJit` group for `logicalAndCallShortCircuitFailureMessage.1`
  rather than the CTFE group.
- All `tests/ut/backends/runner/results.d` blocks, completing `results.d`
  (module order 5) on the new core. 10 of 12 passed unchanged after promotion;
  the remaining two needed narrow `ThrowStatement` lowering for
  `throw new Exception(<string expression>)`. The new core now compiles the
  constructor message through the existing string-slice path and executes a
  `throwString` opcode that reports the rendered message through the runner.
  DMD-folded `assert(true)` emits no code, matching compiled output.
- All promotable `tests/ut/backends/runner/lang/diagnostics.d` blocks,
  completing `diagnostics.d` (module order 6) on the new core. 13 of 26
  promoted tests passed unchanged; the other 13 were earned in six slices
  (see the diagnostics analysis section): comparison-assert operators
  (`<`/`<=`/`>`/`>=`/`!=` plus unsigned `>=`, four new opcodes), scalar
  ref-parameter writeback (caller-slot offset passing plus on-`ret`
  writeback), accepting a `bool_` operand in the `""` truth assert (with a
  width-aware zero-slot read), explicit/dynamic string assert messages
  through the existing `throwString` path, an `Op.haltUnittest` that emits
  `"unittest failure"` for a literal-false assert lexically inside a unittest
  body (distinct from a callee's `"Assertion failure"`), and a
  literal-true-skips-dead-message fix plus a `_d_assert_fail` arity guard.
  Group C (`nullClass*`, `typeidNull*`, `nullClassNotIdentity`,
  `voidInitializedScalarRead`) was deliberately not promoted: CTFE-only
  characterization diagnostics with no `SystemLinker` oracle that require
  class support (slice 9) or test CTFE-only divergence the new core will not
  emulate.
- All SystemLinker-backed `tests/ut/backends/runner/lang/math.d` blocks,
  completing `math.d` (module order 7) on the new core. 13 of 56 promoted
  tests passed unchanged; the remaining 43 were earned in three sequential
  slices (see the math analysis section): `real` scalar storage/reification,
  direct `std.math` intrinsic lowering for `fabs`, `pow`, `sqrt`, `isNaN`,
  `isInfinity`, and `signbit`, and typed floating comparison/assert
  diagnostics for `float`, `double`, and `real`. The
  `evaluatesRuntimePowFloatInputs` block was deliberately not promoted
  because it lacks a `SystemLinker` oracle due to the dmd-as-a-library
  template-emission issue recorded in `ai/plans/dmd-backend.md`.
- All SystemLinker-backed `tests/ut/backends/runner/lang/arrays.d` blocks,
  completing `arrays.d` (module order 8) on the new core (53/53 promoted,
  see the arrays analysis section). This is the native-layout memory model
  realised: dynamic arrays as `{ptr, length}` slice descriptors over GC-heap
  blocks with real element addresses, static-array inline storage, slices and
  pointers with true write-through aliasing (the cases a snapshot model cannot
  pass), append/concat/`dup`/`new`/resize/element-wise ops, and `int[int]`
  associative arrays via druntime-hook call-site interception against a
  VM-owned map table. The 5 `Ctfe, Interpreter`-only CTFE-divergence blocks
  remain unpromoted (no `SystemLinker` oracle).
- All `tests/ut/backends/runner/lang/structs.d` blocks, completing `structs.d`
  (module order 9) on the new core (43/43 promoted, see the structs analysis
  section). This is slice 4 (structs with native layout) realised on top of
  the array memory model: structs are `Type.size()` inline frame blocks with
  fields at DMD-computed offsets, by-value copy semantics, methods with a
  hidden ref `this`, `new Struct` GC-heap allocation with constructors and
  field-through-pointer access, dynamic-array field returns, `with`/`goto`/
  labels, struct-by-value returns, operator overloads via DMD's lowered
  method calls, field-wise POD default equality, struct-typed field chains,
  nested-struct enclosing-local capture through a stack-base-index context
  pointer, and scope-exit destructor / static-array postblit insertion. All
  43 blocks are SystemLinker-oracle-backed; none were withheld.
- All `tests/ut/backends/runner/lang/control_flow.d` blocks, completing
  `control_flow.d` (module order 10) on the new core (67/67 promoted, see
  the control-flow analysis section). This is slice 3 realised on top of the
  earlier scalar, array, and struct machinery: free calls, `if`/loops,
  `break`/`continue`, labels, `switch`/`goto case`, function pointers,
  nested-lambda `this` capture, UTF string `foreach`, and the narrow
  try/catch/finally-on-goto surface needed by the module. All blocks are
  SystemLinker-oracle-backed; none were withheld.
- All SystemLinker-backed `tests/ut/backends/runner/lang/exceptions.d`
  blocks, completing `exceptions.d` (module order 11) on the new core
  (26/26 promoted, see the exceptions analysis section). This covers class
  exception construction, throw statements and expressions, uncaught-exception
  reporting, catch matching and binding, propagation across calls and
  branches, unwinding, `finally` ordering, return capture before `finally`,
  `goto` through exception scopes, and exception chaining.
- All SystemLinker-backed `tests/ut/backends/runner/lang/expressions.d`
  blocks, completing `expressions.d` (module order 12) on the new core
  (55/55 promoted, see the expressions analysis section). This covers the
  remaining broad expression surface: integer operators, mixed numeric
  conversions and comparisons, expression-level pointer/slice/cast support,
  heap aggregate allocation, class/interface dispatch, `typeid`, delegates,
  complex literals, vector splats, and integer `^^` lowering. CTFE-only
  characterization tests remain CTFE-only.
- All SystemLinker-backed `tests/ut/backends/runner/lang/cerealed.d` blocks,
  completing `cerealed.d` (module order 13) on the new core (23/23 promoted,
  see the cerealed analysis section). The last two promoted cases were the
  AA-shaped `nestedStructWritesAssociativeArrayChild` and
  `classSerialisationReadsStaticChildRegistry` fixtures, which added narrow
  support for associative-array literals with struct values, static
  associative-array storage, and delegate-valued AA lookup/invocation.
- `tests/ut/backends/runner/sys/cstdlib.d` (module order 2) is reconciled on
  the new core. The flipped `Bytecode` backend now runs the scalar/pointer
  libc value rows recorded in the Current Coverage State below, including
  `calloc.multiArg.zeroedNativeMemory`,
  `realloc.null.pointerArgPointerReturn`, and
  `realloc.grow.preservesNativeMemory`. Remaining native-runtime refusals are
  the rows whose ABI/value shape is still outside the bridge, such as
  `malloc.pointerReturn.nativeMemory` and the `div`/`ldiv` struct returns.
- `repl.backend.localDeclarationsCanRebindNames` and
  `repl.backend.localRebindingPreservesInterveningReferences` in
  `tests/ut/bin/repl.d` now cover `BytecodeNewCore`. The focused promotion
  exposed that REPL expression history inserts the compile-time-only
  `alias it = __quickbite_repl_value_N;` declaration into eval function
  bodies. The new core now treats function-body alias declarations like other
  semantic-only declarations and emits no bytecode for them.
- `repl.backend.evaluatesExpressionCellsUntilQuit`,
  `repl.backend.skipsCommentOnlyLines`, and
  `repl.backend.evaluatesStandaloneMixinExpression` in
  `tests/ut/bin/repl.d` now cover `BytecodeNewCore`. These were stale coverage
  gaps: focused promotion runs passed unchanged because the shared REPL loop
  already skips comment-only lines, classifies standalone mixin expressions,
  and sends expression cells through the existing new-core `evalRepl` path.
- `repl.backend.lastValueBindingDisplaysLatestExpressionValue` in
  `tests/ut/bin/repl.d` now covers `BytecodeNewCore`. This was a stale
  coverage gap: the focused promotion run passed unchanged because the shared
  REPL session history already updates and exposes the `it` binding through
  the existing new-core eval path.
- `repl.backend.failedExpressionDoesNotAdvanceLastValueBinding` and
  `repl.backend.declarationCellsPersistWithoutDisplay` in
  `tests/ut/bin/repl.d` now cover `BytecodeNewCore`. These were stale
  coverage gaps: focused promotion runs passed unchanged because failed REPL
  expression cells already leave the previous `it` binding intact, and
  declaration cells already persist into later expression cells without
  producing display output.
- `repl.backend.expressionSideEffectsPersist` and
  `repl.backend.statementsExecuteImmediately` in `tests/ut/bin/repl.d` now
  cover `BytecodeNewCore`. These were stale coverage gaps: focused promotion
  runs passed unchanged because REPL declaration state already persists across
  side-effecting expression and statement cells on the new core.
- The next small REPL function-declaration family in `tests/ut/bin/repl.d`
  now covers `BytecodeNewCore`: `functionDeclarationsPersistWithoutSemicolon`,
  `replacesSameSignatureFunctionDeclarations`, `preservesFunctionOverloads`,
  and `userDefinedFunctionDoesNotCollideWithWrapper`. These were stale
  coverage gaps: focused promotion runs passed unchanged because queued REPL
  function declarations, replacement, overload resolution, and wrapper-name
  separation already work through the existing new-core eval path.
- The next REPL declaration-buffering family in `tests/ut/bin/repl.d` now
  covers `BytecodeNewCore`:
  `templateFunctionDeclarationsPersistWithoutDisplay`,
  `multilineFunctionDeclarationsBufferUntilComplete`,
  `multilineStructDeclarationsBufferUntilComplete`,
  `failedBufferedDeclarationDoesNotPoisonSession`, and
  `commandsDoNotAbandonPendingInput`. These were stale coverage gaps: focused
  promotion runs passed unchanged because templated declarations, multiline
  declaration buffering, failed-buffer recovery, and command rejection while
  input is pending already work through the existing new-core REPL path.
- `repl.backend.importDeclarationsPersistWithoutDisplay` in
  `tests/ut/bin/repl.d` now covers `BytecodeNewCore`. This was a stale
  coverage gap: the focused promotion run passed unchanged because REPL import
  declarations already persist into later expression cells on the new-core
  eval path. The adjacent display tests were tried next because they still
  needed non-trivial display/value work: delegate placeholders, nested/static
  array literal display, wide-string suffix preservation, and wide-character
  array rendering.
- `repl.backend.displaysUndisplayablePlaceholderForFunctionLiterals` in
  `tests/ut/bin/repl.d` now covers `BytecodeNewCore`. This was not stale:
  the focused promotion exposed that delegate-valued REPL expression results
  reached the new-core scalar result-type path and failed as an unsupported
  type. The new core now has a narrow undisplayable result kind for function
  and delegate result types, so display-only function literals reify as the
  established `<undisplayable>` placeholder without adding general delegate
  execution support.
- `repl.backend.displaysNestedArrayResults` in `tests/ut/bin/repl.d` now
  covers `BytecodeNewCore`. This was not stale: the focused promotion exposed
  that array-literal REPL expression results did not materialise dynamic-array
  descriptors on the new core, and nested-array results needed heap roots plus
  array-aware reification at the evaluator boundary. The new core now renders
  nested scalar dynamic-array results such as `int[][]`.
- `repl.backend.runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState` in
  `tests/ut/bin/repl.d` now covers `BytecodeNewCore`. This was a stale
  coverage gap: the focused promotion run passed unchanged because the
  new-core REPL path already reports the no-available-source `malloc`
  diagnostic and leaves earlier REPL state usable. This is diagnostic/session
  preservation only; resident libc calls remain deferred to the native-runtime
  slice.

The engine switch is an internal constructor parameter on `Bytecode`
defaulting to the old core. There is no CTFE-only/full-D mode parameter: the
dual-mode model and the `ExecutionMode` enum have been removed
(`ai/plans/single-oracle.md`); the VM targets full D against the
`SystemLinker` oracle.

## Completed Default Flip

Re-scoped 2026-07-09.

Completed 2026-07-09.

**Historical status:** this section records the pre-flip decision and work
order that led to deleting the old core. It is no longer the current next
step; remaining live work is tracked in "Post-Flip Backlog" below.

The overriding goal of this project is unittest latency (`AGENTS.md`). The
old core buys none of it and costs a second engine to keep green. The
"Rewrite strategy" section already states the endgame: *when the entire
matrix passes on the new core, flip the default and delete the old core in
the same change.* Measured on 2026-07-09, that is nearly true, and the work
order had drifted away from it.

Measured state (`bin/ut -l`, 2026-07-09): the new core carries far more
matrix rows than the old core. Exactly four `Bytecode` rows have no
`BytecodeNewCore` counterpart, and all four are behaviours:

1. `lang/diagnostics.d`: `nullClassFieldReadReportsDiagnostic`,
   `nullClassMethodCallReportsDiagnostic`, and
   `typeidNullClassReferenceReportsDiagnostic`. The new core already has
   native object layout, vtables, virtual dispatch, and `typeid`
   (`expressions.class.virtualCallUsesDynamicClass`,
   `expressions.typeid.classReferenceUsesDynamicClass`). What it lacks is a
   null-reference *diagnostic* on field read, method call, and `typeid`.
   This is much smaller than slice 9 as written.
2. `lang/math.d`: `evaluatesRuntimePowFloatInputs`. The new core recognises no
   math intrinsics at all (`compiler.d` matches only `classinfo` and
   `emplace` by identifier), so `pow` on float inputs needs intrinsic
   lowering.

Two additional stale-row cases are not behaviours and need no new-core
implementation:

- `lang/diagnostics.d`: `voidInitializedScalarReadReportsUninitialized`. See
  "The `= void` row is a fossil" below — narrow it, do not implement it.
- `sys/cstdlib.d`: `malloc.pointerReturn.nativeMemory` is not a behaviour the
  old core performed. It is simply unpromoted in this incremental PR, not
  blocked on a current native-memory indexing gap.

### The `= void` row is a fossil

`voidInitializedScalarReadReportsUninitialized` (`lang/diagnostics.d`) asserts
that reading an `int value = void;` local throws
`cannot read uninitialized variable ... in ctfe`, on `Ctfe`, `Interpreter`,
`Bytecode`, and `IR`. It was added 2026-05-28 ("Add non-array CTFE coverage
tests"), under the **two-oracle model** in which `Ctfe` was the oracle for
compile-time behaviour. `ai/plans/single-oracle.md` (2026-06-13) replaced
that model: `SystemLinker` is the oracle for `Interpreter`, `Bytecode`, and
`IR`, and compiled code just reads the slot. The test's own comment concedes
this. It makes three backends *emulate* a CTFE quirk that this plan's Oracle
section says to *characterize, not emulate*, and its expected message pins
DMD's CTFE wording rather than any quickbite diagnostic.

The old core only satisfies it because its locals are tagged `Value`s and
every `loadLocal` compares against `Value.void_` (`bytecode/vm.d`) — that
is, because of the universal runtime value type this rewrite exists to
delete ("No universal runtime value type", Core Architecture). Reproducing
it on native-layout frames means per-slot initialization state and a checked
load on the hot path. Removed slice 2 was exactly that machinery, and it was
removed with the CTFE-replacement goal.

**Completed action:** the block was narrowed to `AliasSeq!(Ctfe)`, with a
comment naming the divergence, per `single-oracle.md`'s explicit rule for
divergent rows. The fixture body did not change. No uninitialized-read
detection was added to the new core to satisfy it.

Owner decision (2026-07-09): quickbite's value proposition is speed, not UB
detection. If a definite-assignment lint is ever wanted it is a compile-time
check applied uniformly across every backend, with its own plan entry — not
runtime tagging in one engine, and not a reason to delay the flip.

### Completed Work Order

1. Null-class-reference diagnostics on the new core (3 rows).
2. `pow` float intrinsic on the new core (1 row).
3. Narrow the `= void` row to `AliasSeq!(Ctfe)`.
4. **The flip, one change**: `Bytecode`'s default constructor selected
   `Engine.typedFrames`; the `BytecodeNewCore` handle class was deleted; the
   old core (`backends/bytecode/{compiler,vm,builtins,instructions}.d`) was
   deleted; `malloc.pointerReturn.nativeMemory` stayed unpromoted while the
   promoted `sys/cstdlib.d` native-memory rows stayed covered; the
   `.BytecodeNewCore` matrix rows were renamed to `.Bytecode`. The
   legacy-core entry in the Deletion Inventory (enum member-name and
   struct-literal display in `bytecode/compiler.d`) died here too.

Nothing else gated the flip. The old core had **no production consumers**:
outside its own package, only the separately-doomed `executors/` tree named
`Bytecode`, and `Bytecode()` was constructed only by the test matrix.

### Moved To Post-Flip Backlog

None of these were behaviours the old core had, so none of them shortened the
path to deleting it. They now remain in the post-flip backlog:

- The rest of slice 8 (indexing through a returned pointer and `div`/`ldiv`
  struct returns). These are *refusals* on the old core.
- Slice 9 beyond the three null-reference diagnostics.
- Slice 11, prelude formatter execution. The `repl.d` display rows it
  governs are frozen for **both** engines, so deleting the old core costs
  nothing there.
- Slice 10, REPL session state.

Risk accepted: "the entire matrix passes" is this plan's definition of
parity, not a proof of it. Row-name parity is not behaviour parity, and the
old core is deleted on the strength of its matrix rows alone. Given zero
production consumers, the blast radius is tests.

## Post-Flip Backlog

Everything below was deferred until the old core was deleted. It records what
the new core has already re-earned, and what comes after the flip. It is the
live backlog for future bytecode work.

`eval.d` (module order 1), `sys/cstdlib.d` (2), `integrals.d` (3),
`logic.d` (4), `results.d` (5), `diagnostics.d` (6), `math.d` (7),
`arrays.d` (8), `structs.d` (9), `control_flow.d` (10), `exceptions.d` (11),
`expressions.d` (12), and `cerealed.d` (13) are now complete or explicitly
reconciled on the new core (see Rewrite Coverage State).

`sys/cstdlib.d` has promoted `atoi.value`, `strtol.endptr`,
`free.null.voidReturn`, `malloc.pointerRoundTrip`, `abs.scalar`,
`labs.widerScalar`, `ctype.toupperTolower`, `atof.floatReturn`,
`strtod.floatReturn.endptr`, `calloc.multiArg.zeroedNativeMemory`,
`realloc.null.pointerArgPointerReturn`, and
`realloc.grow.preservesNativeMemory` to the flipped `Bytecode` backend
(across #383 and this branch) now that the outbound native libc-call bridge
covers arity-N arguments, out-parameter write-back, void returns, pointer
returns, and these native-memory value rows. Still deferred on `Bytecode`:
`div.structReturn` and `ldiv.structReturn.longArgs` keep their own pinned
no-source-diagnostic refusal row (struct returns stay excluded from the
return-type gate).

The next concrete module candidate per
`ai/plans/backend-test-modules-order.md` remains `tests/ut/bin/repl.d`
(module order 14). The first tight REPL rebinding family and the adjacent
expression-loop basics now cover `BytecodeNewCore`:
`repl.backend.localDeclarationsCanRebindNames`,
`repl.backend.localRebindingPreservesInterveningReferences`,
`repl.backend.evaluatesExpressionCellsUntilQuit`,
`repl.backend.skipsCommentOnlyLines`,
`repl.backend.evaluatesStandaloneMixinExpression`, and
`repl.backend.lastValueBindingDisplaysLatestExpressionValue`,
`repl.backend.failedExpressionDoesNotAdvanceLastValueBinding`, and
`repl.backend.declarationCellsPersistWithoutDisplay`,
`repl.backend.expressionSideEffectsPersist`, and
`repl.backend.statementsExecuteImmediately`,
`repl.backend.functionDeclarationsPersistWithoutSemicolon`,
`repl.backend.replacesSameSignatureFunctionDeclarations`,
`repl.backend.preservesFunctionOverloads`, and
`repl.backend.userDefinedFunctionDoesNotCollideWithWrapper`,
`repl.backend.templateFunctionDeclarationsPersistWithoutDisplay`,
`repl.backend.multilineFunctionDeclarationsBufferUntilComplete`,
`repl.backend.multilineStructDeclarationsBufferUntilComplete`,
`repl.backend.failedBufferedDeclarationDoesNotPoisonSession`, and
`repl.backend.commandsDoNotAbandonPendingInput`, and
`repl.backend.importDeclarationsPersistWithoutDisplay`, and
`repl.backend.displaysUndisplayablePlaceholderForFunctionLiterals`, and
`repl.backend.displaysNestedArrayResults`,
`repl.backend.displaysStaticStringArrayResults`,
`repl.backend.displaysNestedEmptyStringValues`,
`repl.backend.displaysWideStringValues`, and
`repl.backend.displaysWideCharacterArrayValues`, and
`repl.backend.runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState`. The
runtime-only cell promotion is no-source diagnostic/session preservation only;
it does not promote resident libc calls to `BytecodeNewCore`. The
string-display family was implementation work, not stale coverage:
static/string array result reification and wide-string suffix preservation
needed new-core result metadata and reification support.
`repl.backend.displaysEnumValues` now also covers `BytecodeNewCore`. The
promotion exposed a display-only metadata gap: bytecode already executed enum
values as their base scalar slots, so `E.a`, `[E.a, E.b]`, and `cast(int) E.a`
all computed the right bits, but reification only saw `int` storage and
rendered `"7"` / `"[7, 8]"`. `ResultType` now carries enum value-name maps for
scalar results and scalar array elements; the compiler builds those maps from
DMD `EnumDeclaration.members`, and `reify.d` converts matching scalar bytes
back to `Value.enumValue`. Cast results keep their cast type, so
`cast(int) E.a` still renders `"7"`. Verification for this promotion passed:

- `ninja bin/ut`
- `bin/ut ut.bin.repl.repl.backend.displaysEnumValues.BytecodeNewCore`
- `bin/ut --random`

The random run used seed `992721697` and reported `2783 test(s) run,
0 failed, 6/6 failing as expected`.

Re-scoped 2026-07-07 (see "REPL parity continuation"): `repl.d`
display-string promotion is frozen pending slice 11 (prelude formatter
execution). The current backlog for this track, in order:

1. Remaining language-feature gaps exposed by the `repl.d` sweep that are
   not display formatting are now re-verified green on current master:
   module-level variable assignment
   (`moduleLevelVariablesAreVisibleToFunctions`), Phobos range and
   `ref`-argument execution (`importStdExposesPhobosSymbols`), and the
   promoted associative-array execution rows in `arrays.d` (slice 7).
2. Slice 8, native runtime: continue widening the outbound host FFI bridge,
   which unblocks the deferred `sys/cstdlib.d` runtime rows above. The first
   promoted runtime row, `atoi.value.BytecodeNewCore`, is green via the shared
   `quickbite.ffi.callNative` path — the buffer-copy path, which taxes the
   native-layout frame with per-argument copies. When this slice's FFI
   *latency* (or exception fidelity) becomes the active work, that is when
   `ffi.md` rungs 24–25 (§35.1 seam v2 pointer-handing + CIF cache, §35.3
   Throwable crossing) are climbed — they are ordered behind ffi.md's
   Interpreter dub-coverage items until then (ffi.md §34.3 work order).
   Until they land, correctness rows keep using the buffer path and no
   boxed-vs-native FFI latency claim is valid. The native-call bridge and its
   call-site acceptance gate (`tryCompileNativeCall`) are both arity-general
   now: a per-argument shape whitelist and a return-type gate, each
   accepting a growing set of shapes as later rungs earn them. Rather than
   enumerate them here — this bullet's own enumeration has already gone
   stale twice on this branch — see the per-rung narrative entries below
   for what each shape covers, and `tryCompileNativeCall` in `compiler.d`
   for the authoritative current list. The `strtod.floatReturn.endptr`,
   `strtol.endptr`, and `free.null.voidReturn` rows are promoted to
   `BytecodeNewCore`. `free.null.voidReturn` needed a void-return-shaped
   rung of its own: `tryCompileNativeCall`'s return-type gate now admits
   `TY.Tvoid`, `machine.d`'s `nativeResultSize` gained a `Tvoid` case, and
   `quickbite.ffi.callNative` (`callNativeImpl`) turned out to call
   `readResult` unconditionally even for a void-returning callee — not the
   dead-code case this plan previously left unestablished.
   `malloc.pointerRoundTrip` (a bare `void*` return, a `size_t` argument,
   and a pointer local passed by value into `free`) turned out to be a
   rung after all, not the larger slice this plan predicted — see the
   entry below. What remains genuinely larger: fixtures that index
   through returned native memory (`ptr[0] = ...`) and `div`/`ldiv`
   struct returns.
3. Slice 9, classes.
4. Slice 11, prelude formatter execution — which re-earns the frozen
   `repl.d` display rows and deletes the interim display scaffolding
   (deletion inventory, Core Architecture).

Remaining non-display `repl.d` behaviours stay promotable to
`BytecodeNewCore` per the re-scoped REPL parity section. No block in
`tests/ut/bin/repl.d` currently includes `SystemLinker`, and none is added
as part of this plan.

First-rung investigation, 2026-07-07:
`repl.backend.moduleLevelVariablesAreVisibleToFunctions` now includes
`BytecodeNewCore` and fails red at `counter = 5` with `Unsupported assignment
in bytecode core: counter = 5`. The missing production behaviour is module
data-segment storage for mutable module-level `VarDeclaration`s: the new-core
assignment path only stores to frame locals, captured locals, fields, array
elements, pointers, and AA elements, while the `VarExp` read path similarly
resolves only local/captured storage or immutable initializers. A module
variable such as `counter` is neither registered as frame-local state nor
addressable as a VM-owned module slot, so direct module-level scalar assignment
falls through to the unsupported-assignment diagnostic before `get()` can read
the updated value.

Second-rung investigation, 2026-07-07:
`repl.backend.importStdExposesPhobosSymbols` now includes `BytecodeNewCore`
and fails red while evaluating `[1, 2, 3].map!(a => a * 2).array` with
`Unsupported ref argument in bytecode core: result[cnt]`. The missing
production behaviour is passing a mutable array element lvalue as a `ref`
argument through Phobos range materialisation: the new core reaches
`std.array.array`'s result-buffer write path, but cannot lower an indexed
array element target into the addressable storage required by a `ref`
parameter.

Second-rung implementation, 2026-07-07:
`BytecodeNewCore` now lowers the Phobos `emplaceRef(result[cnt], e)` path to
a dynamic-array element store, with the narrow array-allocation and descriptor
materialisation support needed by `std.array.array`. This is not a general
`ref` argument ABI. Verification passed with `ninja bin/ut`, the focused
`importStdExposesPhobosSymbols.BytecodeNewCore` test, and `bin/ut --random`
(seed `3117469833`, `2874 test(s) run, 0 failed, 6/6 failing as expected`).

Promotion of further test modules onto the old core stops; new surface area
(`exceptions.d` and later modules) is earned directly on the new core per the
slice roadmap.

## sys/cstdlib.d Reconciliation Analysis (BytecodeNewCore)

The module mixes three kinds of coverage: CTFE no-source diagnostics, real
runtime libc calls (`Interpreter`, `SystemLinker`, `LLVMJit`), and old
Bytecode/IR design-driving diagnostics for the future host FFI bridge. The
new core currently has no outbound host FFI bridge, so the honest promotion is
the third group only.

Seven existing diagnostic tests now include `BytecodeNewCore`:
`free.null.voidReturn`, `malloc.pointerReturn.nativeMemory`,
`calloc.multiArg.zeroedNativeMemory`, `realloc.null.pointerArgPointerReturn`,
`realloc.grow.preservesNativeMemory`, `div.structReturn`, and
`ldiv.structReturn.longArgs`. The focused red run covered those seven tests
and failed only on diagnostic text: the new core reported
`Unsupported call in bytecode core: ...` instead of the established no-source
message. The implementation fix is deliberately limited to named functions
with no available body, preserving the runtime deferral while producing the
same diagnostic shape as the existing design-driving tests.

At the time no real libc value tests were promoted. That analysis has since
been superseded by the native-runtime slice and the Current Coverage State:
scalar calls, pointer/out-parameter calls, `free`, `malloc`,
`calloc.multiArg.zeroedNativeMemory`,
`realloc.null.pointerArgPointerReturn`, and
`realloc.grow.preservesNativeMemory` now have real `Bytecode` rows.
Struct-return calls (`div`, `ldiv`) remain deferred.

## math.d Promotion Analysis (BytecodeNewCore)

All SystemLinker-backed tests from `tests/ut/backends/runner/lang/math.d`
have been promoted to include `BytecodeNewCore` in their `AliasSeq` blocks
and were run in isolation with the full unit-threaded names matching
`ut.backends.runner.lang.math.*.BytecodeNewCore`. The one
`evaluatesRuntimePowFloatInputs` block is deliberately not promoted because
it omits `SystemLinker` for a known dmd-as-a-library/linking issue, so the
promotion is not oracle-backed under `ai/plans/single-oracle.md`.

The first focused run covered 56 promoted `BytecodeNewCore` tests. 13 pass
unchanged: all user-defined `pow`, `sqrt`, `fabs`, and `isNaN` shadowing
tests, plus `evaluatesRuntimeFabsFloatInput`. The remaining 43 failures group
into three root-cause failure modes.

### Failure mode 1: `real` is not a scalar type in the new core

**Root cause:** `scalarType` maps `float` and `double` but rejects D
`real` with `Unsupported type in bytecode core: real`. This appears directly
in all explicit `real` tests and also in the `pow(double, double)` tests:
D's `std.math.pow` overload used here has a `real` static result before the
fixture assigns or compares it. The new core therefore fails before it can
exercise the intrinsic or assertion logic.

**Failing tests (6 directly, plus 3 pow-double tests blocked here):**
`evaluatesRuntimeSqrtRealInput`, `evaluatesRuntimeFabsRealInput`,
`evaluatesRuntimePowRealInputs`, `evaluatesRuntimeIsNaNRealInput`,
`evaluatesRuntimeIsInfinityRealInput`, `evaluatesRuntimeSignbitRealInput`,
and the three `evaluatesRuntimePowDoubleInputs*` tests.

**Required implementation:** Add `ScalarType.real_` and carry it through
`program.d`, `compiler.d`, `machine.d`, and `reify.d`: native size/alignment
(`real.sizeof`), `RealExp` constants, loads/stores, assignments, negation if
needed by `-real.infinity`/`-real.nan`, result reification, and diagnostic
rendering. Any equality for `real` must compare numeric `real` values rather
than raw 16-byte storage, because padding bytes are not part of D's value
semantics.

### Failure mode 2: math intrinsics fall through to ordinary-call lowering

**Root cause:** `compileBuiltinCall` only emits `fabsFloat` and `powFloat`,
the small set needed by `eval.d`. For `sqrt` and `fabs(double)`, DMD reports
a builtin function with no ordinary parameter layout; after the builtin branch
returns `null`, `compileCall` treats it like a regular function and crashes at
`layout.offsets[argumentIndex]` with an `ArrayIndexError`. For `isNaN`,
`isInfinity`, and `signbit`, the new core reaches Phobos implementation
details instead of treating the call as an intrinsic: representative failures
are `Unsupported equality in bytecode core: x != x`, `Unsupported declaration
in bytecode core: alias F = floatTraits!double;`, and `Unsupported variable in
bytecode core: __ctfe`.

**Failing tests:** all `sqrt` double/float tests, `fabs` double tests,
`isNaN` double/float tests, `isInfinity` double/float tests, and `signbit`
double/float tests. The corresponding real tests are also blocked by failure
mode 1 until `real_` exists.

**Required implementation:** Expand intrinsic lowering for the new core,
preferably sharing the existing old-core classification rules in
`quickbite.backends.bytecode.builtins`: recognize DMD builtins for `fabs`,
`pow`, `sqrt`, `isnan`, and `isinfinity`, and recognize `signbit` by
identifier as the old core does. Emit typed VM intrinsic opcodes for
float/double/real unary calls and `pow` calls, with bool/int return opcodes for
`isNaN`, `isInfinity`, and `signbit`. The compiler must not fall through to
ordinary-call lowering for a recognized intrinsic shape.

### Failure mode 3: floating comparison asserts still use integer opcodes

**Root cause:** `compileLoweredComparisonAssert` and
`compileComparisonExpression` route `<`, `<=`, `>`, `>=`, and `!=` through
the integer comparison opcodes (`lessThan4`, `greaterThan4`, etc.). That was
enough for `diagnostics.d` and `logic.d`, but `math.d` asserts compare
floating results, e.g. `sqrt(2.0) > 1.414` and `pow(9.0, 0.5) < 3.001`. Once
the intrinsic calls compile, these comparisons need typed float/double/real
semantics and failure-message rendering such as `1.41421 <= 1.415`.

**Failing tests blocked by earlier modes:** non-perfect `sqrt` success and
failure-message tests, fractional `pow` bounds, and any real equality or
ordering assertion once `real_` exists.

**Required implementation:** Add typed floating comparison opcodes and
selection logic for `float_`, `double_`, and `real_`: equality, inequality,
and ordered comparisons used by lowered assertion context and ordinary
comparison expressions. Diagnostics should continue to use
`AssertDiagnostic`/`operandText`, extended for `real_`, so messages match the
compiled-code oracle.

### Subagent partition (dependency-ordered, sequential)

The implementation work touches the same core files
(`source/quickbite/backends/bytecode/core/{program,compiler,machine,reify}.d`),
so subagents should run sequentially in this worktree and build on the prior
state:

1. **Real scalar plumbing** (failure mode 1). Add `ScalarType.real_` and
   basic storage/reification/rendering so real-typed expressions can compile.
2. **Math intrinsic lowering** (failure mode 2). Add direct VM intrinsic
   lowering/execution for `sqrt`, `fabs`, `pow`, `isNaN`, `isInfinity`, and
   `signbit` over the scalar types available after step 1.
3. **Floating comparison asserts** (failure mode 3). Add typed comparison
   opcodes and assertion-diagnostic selection for float/double/real.

After each subagent, rerun only
`ut.backends.runner.lang.math.*.BytecodeNewCore`; leave any passing promoted
tests in place.

**Completed implementation:** The new core now supports D `real` as a native
scalar (`ScalarType.real_`), including 16-byte literal storage, frame
copying, negation, reification, and assertion rendering. It recognizes the
math intrinsics directly rather than falling into Phobos or DMD builtin
declarations: `fabs`, `pow`, `sqrt`, `isNaN`, `isInfinity`, and `signbit`
lower to typed VM opcodes for the scalar widths the promoted tests exercise.
Floating comparisons and lowered assertion-context diagnostics now dispatch
to numeric `float`, `double`, and `real` comparison opcodes instead of the
integer comparison family. The focused run passes with 56 tests run and 0
failures:

```sh
./bin/ut $(./bin/ut -l | \
    rg '^ut\\.backends\\.runner\\.ct\\.math\\..*\\.BytecodeNewCore$')
```

## results.d Promotion Analysis (BytecodeNewCore)

All 12 tests from `tests/ut/backends/runner/results.d` have been promoted to
include `BytecodeNewCore` in their `AliasSeq` and were run in isolation by
their full unit-threaded names. 10 pass unchanged:
`runBackendSourceFixtureTests.throwsOnUnittestFailure`,
`runTests.reportsAssertFailureMessages`,
`runBackendSourceFixtureTests.importPathsRetryAfterFailure`,
`runTests.countsAttributedPassingAndFailingUnittests`,
`runTests.countsAllPassingUnittests`,
`runTests.countsAssertErrorsAsFailures`,
`runTests.reportsDmdUnittestSymbolNames`,
`runTests.reportsFileBackedUnittestLocations`,
`runBackendSourceFixtureTests.withImportPaths`, and
`runBackendFileFixtureTests.withImportPaths`.

The two failures share one root cause: the new core does not lower
`ThrowStatement`. `runTests.reportsThrownExceptionMessages` reports the
unsupported-statement diagnostic `Unsupported statement in bytecode core:
Throw` instead of the thrown `Exception` message, and
`runTests.runsTestsInEachModule` fails after the backend instance has observed a
throwing module. The old core already has a narrow implementation for
`throw new Exception(message)`; the new core needs the same behaviour through
its typed-frame pipeline.

### Failure mode: narrow throw-statement lowering missing

**Failing tests (2):** `runTests.reportsThrownExceptionMessages` and
`runTests.runsTestsInEachModule`.

**Oracle behavior:** `throw new Exception("message")` inside a unittest is
reported as a failed test whose message contains the constructor string. A
passing module run before a later throwing module must still report its own
unittest as passing when the same backend instance runs both modules.

**Required implementation:** Add a `ThrowStatement` branch in
`source/quickbite/backends/bytecode/core/compiler.d` that supports the narrow
slice `throw new Exception(<string expression>)`, matching the old-core
behaviour without adding general class allocation. Lower the message
expression to the typed-frame/string-literal representation the new core
already uses, add a bytecode operation that throws the rendered string, and
handle it in `source/quickbite/backends/bytecode/core/machine.d`. If the
message expression is outside this narrow form, keep an explicit unsupported
diagnostic.

**Completed implementation:** The new core now recognises the narrow
`throw new Exception(<string expression>)` slice, compiles the message as a
string-slice operand, and executes `Op.throwString` by rendering the slice from
`Program.data`. Unsupported throw forms still produce explicit diagnostics.
After the implementation, all 12 `results.d` tests pass on `BytecodeNewCore`.

## eval.d Completion Analysis (2026-06-15)
All `eval.d` blocks were promoted to `BytecodeNewCore` and run in isolation.
8 of 17 passed unchanged: the literal-arithmetic blocks (`add.int.*`,
`arithmetic`, `integerLikeBinaryOperands`) pass because DMD constant-folds
all-literal arithmetic to a single `IntegerExp` before the compiler sees it,
and `castsRuntimeValuesToIntegerTypes` / `defaultUintPreservesScalarType`
pass because the existing scalar cast, extend, and default-`T.init`
declaration-initializer paths already cover them.

The 9 failures group into four root causes:

1. **Floating-point scalars** (`add.float`, `castsFloatingValueNumerically`,
   `floatingSubtractionUsesNumericValues`,
   `floatingUnaryMinusUsesNumericValue`, the `1.25` case in
   `preservesScalarValueTypes`). `ScalarType` has no `float_`/`double_`, so
   `scalarType` throws `Unsupported type in bytecode core: float`/`double`.
   Needs: float/double `ScalarType`s and sizes, `RealExp` literal lowering
   into the constant pool, type-tagged floating add/subtract opcodes, unary
   minus, int↔float and float↔float casts, and float/double reification plus
   operand display.
2. **`std.math` builtins returning float** (`fabsFloatPreservesReturnType`,
   `powFloatDoesNotReturnDoubleValue`). Depends on cause 1, then needs the VM
   to recognise DMD's `fabs`/`pow` builtin classification and execute them as
   VM intrinsics (per "Builtins and Native Calls": builtin parity stays
   mechanically tied to DMD's builtin classification and is executed by the
   VM), preserving the `float` return type.
3. **Compound assignment / pre-increment** (`multiCell`). `++x` lowers to a
   `+= 1` (`x += 1`) expression the compiler does not handle; it throws
   `Unsupported expression in bytecode core: x += 1`. Needs lvalue
   compound-assignment lowering through the existing `add` opcode (no new
   increment opcode, per the PR-123 lesson).
4. **String literals as arrays** (`stringLiteralIsArray`). `"abc"` has type
   `string`, which `scalarType` rejects. Needs minimal array-slice support:
   store literal bytes in the constant pool, produce a slice descriptor, and
   reify/display it as `"abc"`. This is the leading edge of slice 5 pulled in
   to finish the module.

Each cause is fixed by a dedicated subagent in dependency order
(3 → 1 → 2 → 4), sequentially in this worktree so each builds on the
previous committed state, since all touch the shared core modules
(`compiler.d`, `program.d`, `machine.d`, `reify.d`).

## logic.d Completion Analysis (BytecodeNewCore)

All 34 tests from `tests/ut/backends/runner/lang/logic.d` have been promoted to
include `BytecodeNewCore` in their `AliasSeq`. 3 pass unchanged
(`logicalOrBoolResult`, `logicalOrBoolResultFailureMessage.0`,
`logicalOrBoolResultFailureMessage.1`) because DMD constant-folds `2 || false`
to the literal `true` before the compiler sees it, so only an `IntegerExp`
reaches `compileExpression` and the existing bool-equality assertion path
handles the rest. The remaining 31 failures group into 4 root-cause failure
modes. Causes 2–4 share a prerequisite: `compileLoweredComparisonAssert` in
`source/quickbite/backends/bytecode/core/compiler.d` must be extended to
recognise the `_d_assert_fail("!", <expr>)` 3-arg call (the `"!"` operator) in
addition to `"=="`. Cause 3 additionally requires integer comparison
expressions (`CmpExp` `<`/`>`), which appear only as `&&` operands and are
therefore a sub-dependency of that cause, not a separate root cause.

All four failure modes touch the same shared files (`compiler.d`, `machine.d`,
`program.d`, `reify.d`). Subagents **must run sequentially**, each building on
the previous committed state. The recommended dependency order is 1 → 2 → 3 → 4.

### Failure mode 1: Bitwise-OR expression lowering missing (`OrExp`)

**Root cause:** `compileExpression` falls through to the generic "Unsupported
expression" throw on an `OrExp` node (`40 | mask()`); no `isOrExp` branch
exists in the new core's `compileExpression`.

**Failing tests (3):** `assertNonzeroIntCondition`,
`assertNonzeroIntConditionFailureMessage.0`,
`assertNonzeroIntConditionFailureMessage.1`.

**Oracle behavior:** `0x28 | mask` evaluates the int bitwise-or; failures report
`"42 != 43"` / `"41 != 42"`.

**Required implementation:** Add an `isOrExp` branch in `compileExpression`
parallel to `isAddExp`. Emit a single `bitOrInt4` opcode (int only — D has no
float bitwise or) selected at emit time, add it to `Op` in `program.d` and a
handler in `machine.d`. No `reify.d` change (plain `int` result).

### Failure mode 2: Logical-NOT expression lowering missing (`NotExp`)

**Root cause:** `compileExpression` has no `isNotExp` branch; `compileAssert`
reaches the "Unsupported assert" throw when the condition is a `NotExp`. Also
`compileLoweredComparisonAssert` only recognises `"=="`; it must also recognise
the `"!"` operator that `-checkaction=context` emits for `assert(!expr)` on a
runtime bool.

**Failing tests (6):** `logicalNot`, `logicalNotCall`,
`logicalNotCallFailureMessage.0`, `logicalNotCallFailureMessage.1`,
`logicalNotFailureMessage.0`, `logicalNotFailureMessage.1`.

**Oracle behavior:** `!bool` produces a bool; equality-context failures report
`"true != false"` / `"false != true"`; the `"!"` diagnostic renders as
`"<value> == true"`.

**Required implementation:** (1) `isNotExp` branch emitting a single `notBool`
opcode (`inner == 0 ? 1 : 0`). (2) Extend `compileLoweredComparisonAssert` to
accept `"!"`: compile the inner condition, emit an assert diagnostic tagged
`"!"` rendering as `"<value> == true"`; add `"!"` → `"=="` to `invertedOperator`
in `machine.d`. (3) Extend `compileAssert` to handle a `NotExp` condition with a
plain string message. (4) Add `Op.notBool` to `program.d` and its `machine.d`
handler.

### Failure mode 3: Logical-AND short-circuit lowering missing (`LogicalExp &&`)

**Root cause:** `compileExpression` has no `isLogicalExp` branch for `&&`;
`compileAssert` has no handler for a `LogicalExp &&` condition (the lowered
`assert(left && right, "`assert(left && right)` failed")` form throws because
the msg is a string literal, not a `_d_assert_fail` call). Comparison operands
(`CmpExp` `<`/`>`) inside `&&` are a sub-dependency. This cause also covers the
divergent `logicalAndCallShortCircuitFailureMessage.1` (`assert(0)` in a
non-unittest callee must abort with `"Assertion failure"`, the compiled-D
result; `"`assert(0)` failed"` is CTFE-only).

**Failing tests (15):** `logicalAnd`, `logicalAndCall`,
`logicalAndCallFailureMessage.0/1`, `logicalAndCallShortCircuit`,
`logicalAndCallShortCircuitFailureMessage.0/1`, `logicalAndComparisonOperands`,
`logicalAndComparisonOperandsFailureMessage.0/1`,
`logicalAndFailureMessage.0/1`, `logicalAndShortCircuit`,
`logicalAndShortCircuitFailureMessage.0/1`.

**Oracle behavior:** short-circuit `&&` with bool result; plain-truth failures
throw the verbatim `` `assert(left && right)` failed `` string; equality-context
failures report `"true != false"` / `"false != true"`; the divergent case
throws `"Assertion failure"`.

**Required implementation:** (1) `lessThan4` / `greaterThan4` opcodes plus an
`isCmpExp` branch for `<`/`>`. (2) `isLogicalExp &&` branch with a typed-frame
short-circuit pattern writing a `bool_` result slot on both paths. (3) Extend
`compileAssert` to throw the verbatim string for a `LogicalExp &&` condition
with a string message. (4) Add `Op.halt` (throws `"Assertion failure"`) and emit
it for `assert(0)` (literal-false, null msg) in non-unittest context. Placing
`BytecodeNewCore` with the `SystemLinker`/`LLVMJit` group for this divergent
test is correct: the new core compiles callee bodies eagerly, so `assert(0)`
becomes a `halt` and yields the compiled-D message.

### Failure mode 4: Logical-OR short-circuit lowering missing (`LogicalExp ||`)

**Root cause:** `compileExpression` has no `isLogicalExp` branch for `||`;
`compileAssert` falls through for `||` conditions. The `"!"` operator needed for
`assert(!(left || ...))` is added in failure mode 2.

**Failing tests (7):** `logicalOr`, `logicalOrFailureMessage.0/1`,
`logicalOrOops`, `logicalOrShortCircuit`,
`logicalOrShortCircuitFailureMessage.0/1`.

**Oracle behavior:** short-circuit `||` with bool result; `logicalOrOops` throws
the verbatim `` `assert(left || right)` failed ``; equality-context failures
report `"true != false"` / `"false != true"`;
`logicalOrShortCircuitFailureMessage.1` uses the `"!"` diagnostic and reports
`"true == true"`.

**Required implementation:** (1) `isLogicalExp ||` branch with the typed-frame
short-circuit pattern. (2) Extend `compileAssert` to throw the verbatim string
for a `LogicalExp ||` condition with a string message. The `"!"` operator
(failure mode 2) already covers `logicalOrShortCircuitFailureMessage.1`.

### Subagent partition (dependency-ordered, sequential)

All four items touch `compiler.d`, `machine.d`, and/or `program.d`; no
parallelism is possible. Each subagent commits in this worktree before the next
begins. `reify.d` needs no changes (`bool_`/`int_` results are already
reifiable).

1. **Bitwise-OR (`OrExp`)** — fixes 3 tests. No prerequisites.
2. **Logical-NOT (`NotExp`) + `"!"` assert operator** — fixes 6 tests. After 1.
3. **Logical-AND (`LogicalExp &&`) + `CmpExp` + literal-false `halt`** — fixes 15
   tests including the divergent `"Assertion failure"`. After 2.
4. **Logical-OR (`LogicalExp ||`)** — fixes 7 tests. After 3; reuses the `"!"`
   operator from item 2.

After all four items, `logic.d` is complete on `BytecodeNewCore` (34/34).

## Test Plan
- Use public behavior tests only for language semantics and backend parity.
- Add focused VM contract tests only for bytecode-specific properties such as
  operand typing, frame behavior, and diagnostic boundaries.
- Keep unsupported-slice tests narrow and behavior-driven, not layout-driven.
- One oracle: really-compiled `dmd -unittest -checkaction=context` output
  via `SystemLinker`, byte for byte (see Oracle). `Ctfe` is not an oracle;
  where it diverges, its behaviour is characterized, not pinned as truth.
- Use `ai/plans/backend-test-modules-order.md` to choose post-`eval` targets
  by required D language features, not by file length or coverage counts.
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
- [x] Include bool and character value kinds in integer-like binary operations
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
- Builtin parity (`sqrt`, `fabs`, ...) stays mechanically tied to DMD's
  builtin classification and is executed by the VM; druntime lowerings are
  intercepted at the call site and applied to VM-owned memory.
- The native bridge (see Core Architecture) is the general mechanism for
  body-less leaves: values cross unchanged because VM memory is
  native-layout, and
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
- Thrown objects are real `Throwable` instances on the host heap; the bridge
  converts between native unwinding and VM unwinding at boundary crossings.

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
  Phobos-using test (see Native bridge) and are common in plain
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

## diagnostics.d Promotion Analysis (BytecodeNewCore)

All 26 tests from `tests/ut/backends/runner/lang/diagnostics.d` have been
promoted to include `BytecodeNewCore` in their `AliasSeq` blocks. 13 pass
unchanged: `voidFunctionReturnsToCaller`, `ok`, `oops`,
`okFailureMessage.0`, `localIntReturnOops`, `voidFunctionOops`,
`functionParametersOops`, `tenFunctionParametersOops`,
`functionParameterOops`, `ifElseOops`, `inFunctionParametersOops`,
`boolAssertionContextMatchesDmd`, and `charAssertionContextMatchesDmd`.
Group C tests (`nullClassMethodCallReportsDiagnostic`,
`nullClassFieldReadReportsDiagnostic`,
`typeidNullClassReferenceReportsDiagnostic`,
`nullClassNotIdentityUsesNotEqualPolarity`, and
`voidInitializedScalarReadReportsUninitialized`) are deliberately not
promoted: the first four require class-reference support (slice 9) and the
last is a CTFE-only diagnostic (`= void` uninitialized-read) that the new
core — targeting the SystemLinker oracle — will never emit. The remaining
13 failures group into 6 root-cause failure modes.

All six failure modes touch the shared core modules (`compiler.d`,
`machine.d`, `program.d`). Subagents **must run sequentially**, each
building on the previous committed state. `reify.d` requires no changes
(all new result types are already reifiable scalar or string results).

### Failure mode 1: Comparison-assert operators `<`, `<=`, `>`, `>=`,
`!=` and unsigned `>=` not recognised

**Root cause:** `compileLoweredComparisonAssert` in `compiler.d` (line
840) gates on `operatorText(operator) != "=="` and returns `false` for
every other 3-argument `_d_assert_fail` form. All five comparison-assert
tests hit this gate and fall through to the "Unsupported assert" throw.
`uintGreaterOrEqualUsesUnsignedComparison` hits the same gate: DMD lowers
`assert(uint.max >= 0u)` to `assert(__assertOp71 >= 0u, _d_assert_fail(">=",
__assertOp71, 0u))` and because `">="` fails the gate, the assert throws
instead of passing silently. Both `uint.max` and `0u` are `uint` (`Tuns32`),
which `scalarType` maps to `ScalarType.uint_`, and `uint.max >= 0u` is true
under unsigned semantics — the only requirement is that the new comparison
opcodes use the correct signed/unsigned comparison.

`logic.d` already contributed `Op.lessThan4` and `Op.greaterThan4` with
signed `int` semantics (machine.d lines 135–146). Those two are reused
as-is for `"<"` and `">"`. The required delta is four new opcodes:
`lessOrEqual4`, `greaterOrEqual4`, `greaterOrEqualUnsigned4` (for `uint`
operands), and `notEqual4`. `invertedOperator` in `machine.d` currently
maps only `"=="` → `"!="` (line 399–403); it must be extended with
`"<"` → `">="`, `"<="` → `">"`, `">"` → `"<="`, `">="` → `"<"`, and
`"!="` → `"=="`.

The unsigned variant (`uintGreaterOrEqualUsesUnsignedComparison`) must
evaluate true and not throw: emit `greaterOrEqualUnsigned4` when the
operand `ScalarType` is `uint_` (or any unsigned type), `greaterOrEqual4`
(signed) otherwise. Rendering in `operandText` already handles unsigned
types correctly (the `!isSigned` branch, line 431).

**Failing tests (6):** `intLessThanOops`, `intLessOrEqualOops`,
`intGreaterThanOops`, `intGreaterOrEqualOops`, `intNotEqualOops`,
`uintGreaterOrEqualUsesUnsignedComparison`.

**Oracle behavior:** Failed `<` → `"42 >= 42"`, `<=` → `"43 > 42"`,
`>` → `"42 <= 42"`, `>=` → `"41 < 42"`, `!=` → `"42 == 42"`. The
unsigned `>= 0u` assert passes silently (no throw).

**Required implementation:**
- `compiler.d` — extend `compileLoweredComparisonAssert` beyond the
  `"=="` gate to also dispatch `"<"`, `"<="`, `">"`, `">="`, `"!="`,
  selecting a signed or unsigned opcode based on the operand `ScalarType`.
  Extend `compileIntBinaryResult` or add a parallel helper that accepts
  `uint_`/`ulong_` operand types without rejecting them.
- `program.d` — add `Op.lessOrEqual4`, `Op.greaterOrEqual4`,
  `Op.greaterOrEqualUnsigned4`, `Op.notEqual4`.
- `machine.d` — add handlers for the four new opcodes; extend
  `invertedOperator` with the five missing operator strings listed above.

### Failure mode 2: Ref-parameter writeback missing

**Root cause:** `parameterLayout` in `compiler.d` (lines 956–958) throws
unconditionally when `parameter.isReference` is true:
`"Unsupported ref parameter in bytecode core"`. Both `refParameterOops`
(`ref int`) and `refSizeTParameterOops` (`ref size_t`) hit this path
immediately during compilation of the callee. The old core already
implements scalar ref writeback (recorded in the Current Coverage State log:
the `Bytecode` entry for `refParameterOops` notes "scalar local `ref`
argument writeback"). The new core needs the same narrow slice.

The mechanism is: pass a ref parameter as its caller-frame slot offset (a
pointer into the caller's frame), compile the callee body treating the
parameter as a load/store through that offset, and on `ret` write the final
value back to the caller slot. Concretely: `parameterLayout` must accept
`isReference` parameters and record them separately; `compileCall` must
pass the caller-frame offset of the argument variable rather than copying
its value; and the `ret` handler (or a pre-`ret` writeback sequence) must
copy the callee's parameter slot back to the caller offset.

**Failing tests (2):** `refParameterOops`, `refSizeTParameterOops`.

**Oracle behavior:** After `addOne(value)` (ref int), the caller's `value`
is incremented and the final failed equality reports `"42 != 43"`. Same
pattern for `size_t`.

**Required implementation:**
- `compiler.d` — in `parameterLayout`, record ref parameters with their
  size/type (the referenced type, not a pointer type) and mark them as
  pass-by-reference. In `compileCall`, detect ref arguments and instead
  of emitting a `copy` into the argument area, emit the caller-slot offset
  as the argument word. In the callee body, load/store through the passed
  offset rather than a private slot. On `ret`, write each ref-parameter slot
  back to the provided caller offset.
- `machine.d` — the `call` handler must distinguish ref-parameter
  argument words (offsets into caller frame) from value words; the `ret`
  handler must perform writebacks for ref parameters before returning to
  the caller frame.
- `program.d` — `CompiledFunction` or `parameterBytes` metadata may need
  a ref-parameter descriptor so the machine knows which argument words are
  offsets and which are values.

### Failure mode 3: Runtime-bool truth assert (`""` operator on
`bool_` operand) not handled

**Root cause:** DMD with `-checkaction=context` lowers `assert(nope())`
(where `nope()` returns `bool`) to
`assert(__assertOp69, _d_assert_fail("", __assertOp69))`. The `__assertOp69`
temp is a `bool` local. In `compileLoweredComparisonAssert`, the 2-argument
`""` operator branch delegates to `compileNonzeroAssert` (line 831). Inside
`compileNonzeroAssert` (line 878), the compiled operand has type
`ScalarType.bool_`, but the check `operand.type != ScalarType.int_` rejects
it with `"Unsupported truth assert in bytecode core: __assertOp69"`.

The fix is narrow: relax `compileNonzeroAssert` to accept `bool_` in
addition to `int_`. The existing `assertNonzeroInt4` opcode operates on a
frame byte and compares to zero, which is correct for a `bool_` slot
(stored as one byte, 0 or 1). Alternatively, use a direct
`Op.assertTrue`/`jumpIfFalse` pattern with a `bool_` diagnostic, since the
existing `assertTrue` opcode already handles single-byte condition slots.
The `assertMessage` in `machine.d` for operator `""` renders
`"<value> != true"`, which for a `bool_` operand (via `operandText`) renders
`"false != true"` — matching the oracle.

**Failing tests (1):** `runtimeBoolAssertionContextMatchesDmd`.

**Oracle behavior:** `"false != true"`.

**Required implementation:**
- `compiler.d` — in `compileNonzeroAssert`, accept `ScalarType.bool_` in
  addition to `ScalarType.int_`. The existing `assertNonzeroInt4` opcode
  is byte-correct for `bool_` (1-byte frame slot). No new opcode needed.

### Failure mode 4: Explicit string assert messages not handled

**Root cause:** Two tests involve asserts with an explicit string message.
They share a common gap: no branch in `compileAssert` handles the case
where `assert_.msg` is a non-null expression that is not a
`_d_assert_fail` call.

`explicitAssertMessageOverridesContext`: `assert(1 == 2, "oops")` is
constant-folded by DMD to `assert(false, "oops")` (an `IntegerExp(0)` with
a `StringExp` message). `compileLiteralFalseAssert` returns `false` when
`assert_.msg != null` (line 768). `compileLoweredComparisonAssert` checks
`call = assert_.msg.isCallExp` — a `StringExp` is not a `CallExp`, so it
returns `false`. `compileVerbatimStringAssert` requires `assert_.e1` to be
a `LogicalExp` or `NotExp`, but the condition is `IntegerExp(0)`, so it
returns `false`. Falls through to "Unsupported assert".

`dynamicAssertMessageMatchesDmd`: `assert(false, msg)` where `msg` is a
`string` local variable. The message expression is a `VarExp`, not a
`StringExp`. Same chain of misses. Reaches "Unsupported type: string"
because `scalarType` is called on the `string` type of the local, and
`string` (`Tarray` of `Tchar`) has no `ScalarType` entry.

Both require a new `compileExplicitMessageAssert` branch in `compileAssert`
that fires when `assert_.msg` is present and is neither a `_d_assert_fail`
call nor a verbatim logical-expression string. The branch should:
(1) compile the condition to a bool, jumping past the message if true; (2)
on failure, evaluate the message expression (which may be a `StringExp`
literal or a `VarExp` for a local `string` variable — already a
string-slice in the frame from `compileStringLiteral` or the variable's
slot); (3) throw via `Op.throwString`.

The `string` local (`VarExp` of type `string`) is already stored in the
frame as a string-slice descriptor (8 bytes: data offset + length) by
`compileVariableDeclaration` → `compileStringLiteral`. The `Op.throwString`
opcode already reads such a descriptor (machine.d line 304). So the only
new compiler logic needed is recognising the message-bearing assert forms
and emitting a conditional branch over a `throwString`.

For `explicitAssertMessageOverridesContext` the message is a `StringExp`
literal; `compileStringLiteral` produces the slice descriptor. For
`dynamicAssertMessageMatchesDmd` the message is a cast-wrapped `VarExp`
over a `string` local; the old core's `compileDynamicAssertMessage` (line
936 of bytecode/compiler.d) and `compileAssertMessageExpression` (line 967)
show the pattern: unwrap any `CastExp` wrapper, compile the inner `VarExp`
to get its slot offset, emit a conditional throw.

**Failing tests (2):** `explicitAssertMessageOverridesContext`,
`dynamicAssertMessageMatchesDmd`.

**Oracle behavior:** Both throw `"oops"` — the message string, not a
generated comparison context.

**Required implementation:**
- `compiler.d` — add a `compileExplicitMessageAssert` helper that fires
  when `assert_.msg` is not null, is not a `_d_assert_fail` call, and is
  not the verbatim-logical-expression string form. Compile `assert_.e1` to
  a condition bool. If false (using `jumpIfFalse`), evaluate `assert_.msg`
  — either a `StringExp` literal via `compileStringLiteral`, or a
  cast-unwrapped `VarExp` whose slot is already a string-slice descriptor —
  and emit `Op.throwString` on the message slot. Also extend
  `compileLiteralFalseAssert` (or the new branch) to handle
  `assert(false, "oops")` / `assert(0, msg)` where the condition is
  already a compile-time zero (skip the condition compilation, just compile
  the message and emit `throwString` unconditionally).
- No new opcodes needed (`Op.throwString` already exists).

### Failure mode 5: Literal-false assert in unittest body emits wrong
message

**Root cause:** `compileLiteralFalseAssert` (compiler.d line 775) always
emits `Op.halt`, which the machine throws as `"Assertion failure"`. But
compiled D uses the `_d_unittest` hook for `assert(false)` (and `assert(0)`)
directly inside a unittest body, which throws `"unittest failure"`. The
existing `voidFunctionOops` test correctly uses `"Assertion failure"` for
`assert(0)` inside a *called* non-unittest function — that is the right
compiled-D behaviour for a non-unittest caller. `literalFalseAssertionMatchesDmd`
has `assert(false)` directly in the unittest body and expects
`"unittest failure"`.

The distinction is whether `assert_.e1` is a literal zero (constant false)
inside the *entry function* (a `UnitTestDeclaration`) versus inside a callee.
The new-core `compile(entry)` function (compiler.d line 17) receives the
entry `FuncDeclaration`; `entry.isUnitTestDeclaration` returns non-null when
it is a unittest block. The compiler currently has no `_inUnittest` flag.

The smallest fix: track whether the current function being compiled is the
entry `UnitTestDeclaration` (not a lazily-compiled callee), and in
`compileLiteralFalseAssert`, emit `Op.haltUnittest` (throwing
`"unittest failure"`) when inside the unittest entry, `Op.halt` otherwise.
Only the entry function body is a unittest; callees are always
`isUnitTestDeclaration == null` in the new core's lazy-compilation model.
`Op.haltUnittest` is a new one-byte opcode with no operands, analogous to
`Op.halt`.

Note: `assert(false)` is represented as `IntegerExp(0)` in the DMD AST
after semantic analysis, identical to `assert(0)`. The distinction is
purely contextual (entry unittest body vs. callee).

**Failing tests (1):** `literalFalseAssertionMatchesDmd`.

**Oracle behavior:** `"unittest failure"`.

**Required implementation:**
- `compiler.d` — add a `_inUnittestEntry` bool field to `Compiler`,
  set to `entry.isUnitTestDeclaration !is null` in `compile()` before
  calling `compileFunctionBody(0)`, and cleared to `false` in
  `compileFunctionBody` before compiling any callee (index > 0). In
  `compileLiteralFalseAssert`, emit `Op.haltUnittest` when `_inUnittestEntry`
  is true, `Op.halt` when false.
- `program.d` — add `Op.haltUnittest`.
- `machine.d` — add a handler that throws `"unittest failure"`.

### Failure mode 6: `compileLoweredComparisonAssert` ArrayIndexError on
`assert(true, message)` where message is a `CallExp`

**Root cause:** `assertMessageDoesNotEvaluateOnSuccess` contains
`assert(true, message)` where `message()` has `assert(0)`. The condition is
the literal `true`, so the message is dead code that must never be evaluated.
`assert(true, message)` with a non-null message reaches
`compileLiteralTrueAssert` which returns `false`
when `assert_.msg != null` (line 755). It then falls through to
`compileLoweredComparisonAssert` (line 816). There, `assert_.msg` is not
null; `call = assert_.msg.isCallExp` succeeds because the message
expression is the `CallExp` `message()`. Then `call.arguments` is the
argument list of the `message()` call — which has no arguments, so
`call.arguments.length == 0`. Line 824 then executes
`(*call.arguments)[0].isStringExp`, indexing an empty array, causing the
`ArrayIndexError` crash.

The fix is a guard in `compileLoweredComparisonAssert`: after confirming
`call.arguments` is not null, check `call.arguments.length >= 1` before
accessing `(*call.arguments)[0]`. If the call has no arguments, it is not a
`_d_assert_fail` shape; return `false` immediately.

Additionally, `compileLiteralTrueAssert` should be extended to accept
`assert(true, message)` — the message must not be evaluated because the
condition is statically true, exactly as compiled code does (the message
expression is dead code). Extend `compileLiteralTrueAssert` to return `true`
(emit no code) for any `assert(nonzero_integer, ...)` regardless of
`assert_.msg`.

**Failing tests (1):** `assertMessageDoesNotEvaluateOnSuccess`.

**Oracle behavior:** The assert passes silently; `message()` is never
called; no throw.

**Required implementation:**
- `compiler.d` — (a) In `compileLiteralTrueAssert` (line 754), remove the
  `assert_.msg !is null` early return so that `assert(nonzero, anything)`
  is recognized as a literal-true assert and emits no code. (b) In
  `compileLoweredComparisonAssert` (line 816), add a guard after
  `call.arguments` null check: if `call.arguments.length == 0` return
  `false`. These two changes together fix the crash and the silent-pass
  contract.
- No machine or program changes needed.

### Subagent partition (dependency-ordered, sequential)

All six items touch `compiler.d` and/or `machine.d`/`program.d`; no
parallelism is possible. Each subagent commits in this worktree before the
next begins. The recommended order is:

1. **Comparison-assert operators** (failure mode 1) — fixes 6 tests. No
   prerequisites. Adds `lessOrEqual4`, `greaterOrEqual4`,
   `greaterOrEqualUnsigned4`, `notEqual4` opcodes; extends
   `compileLoweredComparisonAssert` and `invertedOperator`.
2. **Ref-parameter writeback** (failure mode 2) — fixes 2 tests. No
   prerequisites; logically independent of mode 1 but runs after it to
   avoid merge conflicts in shared files.
3. **Runtime-bool truth assert** (failure mode 3) — fixes 1 test. After
   mode 1 (mode 1 already extends `compileLoweredComparisonAssert`; the
   bool fix is a one-line relaxation in `compileNonzeroAssert`).
4. **Explicit string assert messages** (failure mode 4) — fixes 2 tests.
   After mode 3 (shares `compileAssert` dispatch logic; no opcode
   dependency).
5. **Literal-false assert in unittest body** (failure mode 5) — fixes 1
   test. After mode 4 (adds `Op.haltUnittest`; independent of modes 2–4
   but keeps commits small).
6. **`compileLoweredComparisonAssert` ArrayIndex guard + literal-true
   with message** (failure mode 6) — fixes 1 test. After mode 4 (the
   `compileLiteralTrueAssert` change interacts with the new explicit-
   message branch added in mode 4; running last avoids re-editing the
   same function twice).

After all six items, `diagnostics.d` is complete on `BytecodeNewCore`
(26/26, modulo the deliberately deferred Group C tests).

## arrays.d Promotion Analysis (BytecodeNewCore)

All SystemLinker-oracle-backed blocks in
`tests/ut/backends/runner/lang/arrays.d` have been promoted to include
`BytecodeNewCore` in their `AliasSeq`. 53 `BytecodeNewCore` tests now
exist. 3 pass unchanged:
`assertDiagnostic.integerEquality`,
`assertDiagnostic.characterEquality`, and
`assertDiagnostic.booleanEquality`. These exercise only scalar
`assert(42 == 43)` / `assert('e' == 'f')` / `assert(true == false)`
forms that the new core already handles via its typed scalar comparison
and assertion-diagnostic paths — no array types appear in them.

The remaining 50 failures group into 4 root-cause failure modes. The
blocking site in all non-AA cases is `scalarType()` in `compiler.d`,
which has no branch for `Tarray`, `Tsarray`, or `Taarray` and throws
`"Unsupported type in bytecode core: T"` at the first array-typed
local, parameter, or expression. The AA failures hit the same gate
for `Taarray`.

All four modes touch the same shared files
(`source/quickbite/backends/bytecode/core/{program,compiler,machine,
reify}.d`). Subagents **must run sequentially**, each building on the
previous committed state.

### Failure mode 1: Dynamic-array slice descriptor missing

**Root cause:** `scalarType()` in `compiler.d` has no `Tarray` case.
A dynamic array is a `{void* ptr, size_t length}` slice descriptor in
native frame memory — 16 bytes on x86-64 (two `size_t` words). Until
`ResultType` and the frame-allocation path recognise slice descriptors,
every `T[]` local, parameter, return type, or expression sub-result
immediately throws. This single gate blocks 36 tests.

Within the slice-descriptor type, the required expressions are built up
in dependency order: the simplest (array literals → heap allocation +
descriptor write) must exist before indexing, and indexing before
slicing and pointer arithmetic. The three tests that specifically
motivated the native-layout memory model appear here:
`dynamicArray.nestedSliceWritesPropagateToOriginalArray` (a nested
slice `s2[0] = 99` must propagate to the original `a[1]` through
shared real memory — a snapshot model can never pass this),
`dynamicArray.nestedSliceAppendKeepsOriginalArrayTail` (slice append
must leave original array tail intact via real GC heap addresses), and
`pointer.arithmeticOverDynamicArray` (pointer arithmetic over
`&values[0]` requires a real address into VM-owned heap memory).

**Failing tests (36):**
`assertDiagnostic.arrayElementMismatch`,
`assertDiagnostic.arrayLengthMismatch`,
`dynamicArray.lengthCases`,
`dynamicArray.literalElements`,
`dynamicArray.ubyteLiteralTruncatesElements`,
`dynamicArray.indexReadWrite`,
`dynamicArray.postIncrementIndex`,
`dynamicArray.localAppend`,
`dynamicArray.appendToNonEmptyArray`,
`dynamicArray.refParameterAppend`,
`dynamicArray.concatenation`,
`dynamicArray.elementConcatenatesWithArray`,
`dynamicArray.sliceFromRuntimeBounds`,
`dynamicArray.nullZeroLengthSlice`,
`dynamicArray.nestedSliceWritesPropagateToOriginalArray`,
`dynamicArray.nestedSliceAppendKeepsOriginalArrayTail`,
`dynamicArray.sliceAssignmentUpdatesArray`,
`dynamicArray.overlappingSliceAssignmentDiagnostic`,
`dynamicArray.sliceIndexPastLengthDiagnostic`,
`dynamicArray.indexPastLengthDiagnostic`,
`dynamicArray.returnValue`,
`dynamicArray.sliceReturnValue`,
`dynamicArray.indexesCallResult`,
`dynamicArray.newCharArrayUsesRuntimeLengthAndDefaultFill`,
`dynamicArray.dupDetachesCopyFromOriginal`,
`dynamicArray.idupFreezesIndependentCopy`,
`dynamicArray.ptrPointsAtFirstElement`,
`dynamicArray.jaggedRowsKeepIndependentLengths`,
`dynamicArray.lengthAssignmentResizesArray`,
`dynamicArray.arrayOperationAddsRuntimeElements`,
`pointer.arithmeticOverDynamicArray`,
`pointer.indexReadsDynamicArray`,
`pointer.comparisonWithinArray`,
`pointer.relationsAcrossArraysReturnFalse`,
`pointer.sliceFromDynamicArray`,
`pointer.slicePastAllocatedBlockDiagnostic`.

**Oracle behavior:** Dynamic arrays allocate on the GC heap; slice
descriptors share the same backing memory, so writes through one slice
propagate to all aliases. `.length` reads the descriptor length word.
Indexing bounds-checks via druntime and throws `"index [N] is out of
bounds for array of length M"` (the compiled-D `ArrayIndexError` text,
not the CTFE wording). Overlapping slice assignment throws `"Range
violation"`. Appending through `~=` calls `_d_arrayappendT`; `~`
concatenation calls `_d_arraycatT`. Pointer arithmetic is plain
machine arithmetic over `void*`; slicing from a pointer is
unchecked (the allocated-block diagnostic is CTFE-only, so
`pointer.slicePastAllocatedBlockDiagnostic` is a passing-fixture test
for `BytecodeNewCore`).

**Required implementation:** This mode drives the largest share of the
slice-5 design. In dependency order within the mode:

- `program.d` — extend `ResultType` with a slice-descriptor kind
  (element `ScalarType` plus a dynamic-array tag); add
  `sliceDescriptorSize = 2 * size_t.sizeof` (16 bytes). No new
  `ScalarType` enum member: the descriptor is a composite, not a
  scalar. Add opcodes for slice descriptor operations: `loadSlice`
  (write `{ptr, length}` to a frame slot from a heap pointer and
  length), `indexLoad` (typed element read from `ptr + index *
  elemSize`), `indexStore` (typed element write), `sliceLength` (read
  the length word), `slicePtr` (read the ptr word), `subSlice` (form
  a new descriptor `{ptr + lo*elemSize, hi - lo}`), `appendElement`
  (call druntime lowering and update the descriptor in the caller's
  frame), `concatSlices` / `concatElement` (druntime concat),
  `dupSlice` / `idupSlice` (copy + freeze), `setLength` (resize via
  druntime), `sliceRangeAssign` (mem-copy with overlap check at
  runtime → `"Range violation"`), `arrayOpAdd` (element-wise
  addition for `sums[] = left[] + right[]`).
- `compiler.d` — add a `sliceType()` helper parallel to `scalarType()`
  mapping `Tarray T` to `(element ScalarType, isDynamic=true)`; add
  `Tarray` handling in `compileVariableDeclaration` (allocate 16
  bytes for the descriptor; compile an `ArrayLiteralExp` initializer
  to heap-allocate and write the descriptor), `compileExpression`
  (handle `ArrayLiteralExp`, `SliceExp`, `IndexExp`, `PtrExp`,
  `CatExp`, `CatAssignExp`, `DotExp.length`, `DotExp.ptr`,
  `AddressExp` over an indexed element, `NewExp` for `new T[](n)`,
  `DotExp.dup`/`.idup`), and `compileAssert` (extend to recognise
  slice-equality comparison in `_d_assert_fail` context for the
  `[1,2,3] != [1,2,4]` diagnostic). Parameters of slice type pass the
  16-byte descriptor by value (copy both words into the argument
  area); `ref T[]` parameters pass the caller-frame offset of the
  descriptor (extending the existing scalar ref-param mechanism to
  16-byte composite descriptors).
- `machine.d` — add handlers for each new opcode. The `call` handler
  already copies `parameterBytes` into the callee frame; no change
  needed for value slice parameters once the descriptor size is
  correct. The ref-param writeback path extends to copy 16 bytes
  back. Bounds-check handlers for `indexLoad`/`indexStore` throw a
  native `ArrayIndexError` through the existing exception path.
  Overlap-check in `sliceRangeAssign` throws `"Range violation"`.
  Pointer arithmetic opcodes read the `ptr` word, add
  `offset * elemSize`, write a new `ptr` word.
- `reify.d` — extend `reify()` to handle a slice-descriptor
  `ResultType`: read `{ptr, length}` from frame bytes, render elements
  as a `Value` array for the `Evaluator` boundary display.

### Failure mode 2: Static-array inline storage missing

**Root cause:** `scalarType()` has no `Tsarray` case. A static array
`T[N]` lives entirely in the frame at its DMD-computed offset and size
(`N * T.sizeof`, aligned per DMD's `VarDeclaration.offset`); no heap
allocation occurs. `char[2] first = "ab"` allocates 2 bytes inline in
the frame and copies the string bytes in. The existing string-literal
path (`loadStringSlice`) stores a slice descriptor (heap pointer +
length), which is the wrong representation for a static array: static
arrays are value types with no indirection, so writes to `first[0]`
must not affect any other variable.

**Failing tests (3):**
`dynamicArray.mutableStringLiteralCopiesDoNotShareWrites`
(`char[2] first = "ab"; first[0] = 'z';`),
`staticArray.copyFromRuntimeArrayUsesArrayCtor` (`int[2] copy =
source;`),
`staticArray.multidimensionalSliceBlockAssignRepeatsRow` (`int[2][2]
matrix;`).

**Oracle behavior:** `char[2] first = "ab"; first[0] = 'z';` must not
affect a later `char[2] second = "ab"` — each declaration copies the
literal bytes into its own private inline frame storage. `int[2] copy
= source` copies all `N * sizeof(T)` bytes from source into the
destination frame slot (`_d_arraycopy` semantics, but for value-type
static arrays this is a plain `memcpy`). `matrix[] = [first, first+1]`
broadcasts a one-dimensional literal to each row of a
two-dimensional static array in place.

**Required implementation:**
- `program.d` — add opcodes `loadStaticArray` (copy `N * elemSize`
  bytes from a constant-pool entry or another frame slot into the
  destination frame slot), `indexLoadStatic` / `indexStoreStatic`
  (read/write an element at compile-time-known or runtime `index *
  elemSize` offset within the inline block), `broadcastRow` (for
  `matrix[] = [elem, elem+1]` — copy a row literal `N` times into
  the inline block). Static arrays have no pointer/length words; the
  type carries `N` and the element `ScalarType`.
- `compiler.d` — add a `staticArrayType()` helper for `Tsarray`,
  returning `(element ScalarType, length uint)`; handle it in
  `compileVariableDeclaration` (reserve `N * elemSize` frame bytes),
  `ArrayLiteralExp` when the target is a `Tsarray` (emit element
  stores into the frame slot), `IndexExp` over a static-array local
  (emit `indexLoadStatic`/`indexStoreStatic`), and the `T[N]
  dest = src` assignment path (emit a block `copy` of `N * elemSize`
  bytes). Initializing a `char[N]` from a `StringExp` literal copies
  the string bytes directly (no slice descriptor).
- `machine.d` — add handlers for `indexLoadStatic`,
  `indexStoreStatic`, `broadcastRow`. These are direct frame-offset
  arithmetic — no heap involvement.
- `reify.d` — extend to handle a static-array `ResultType` if any
  test exercises it as an eval result (none currently, but add a
  stub).

### Failure mode 3: `size_t` compound assignment not supported

**Root cause:** `compileAddAssignExpression` in `compiler.d` (lines
607–614) checks `lhs.type != ScalarType.int_ || rhs.type !=
ScalarType.int_` and throws `"Unsupported compound assignment in
bytecode core"` for any non-`int_` type. On x86-64 `size_t` is
`ulong`, so `++len` lowers to `len += 1LU` where both sides have
`ScalarType.ulong_`. The existing `addInt8` opcode (added for `long_`
arithmetic) already handles 8-byte integer addition in `machine.d`;
this mode requires only relaxing the gate in `compiler.d`.

**Failing tests (2):**
`dynamicArray.newUsesRuntimeLength` (`size_t len = 1; ++len;`
before `new int[](len)`) and
`dynamicArray.newMultidimensionalUsesRuntimeLengths`
(`size_t rows = 1; ++rows;` before `new int[][](rows, cols)`).

Note: both tests also require mode-1 array support to reach
completion, so they are blocked first by this mode and then by mode 1.

**Oracle behavior:** `++len` on a `size_t` local increments it from 1
to 2; the resulting value is passed as the `new int[]` length.

**Required implementation:**
- `compiler.d` — in `compileAddAssignExpression`, relax the
  scalar-type check to also accept `ScalarType.ulong_` (the
  `size_t`-width case on x86-64). Emit `Op.addInt8` when the type is
  `ulong_` (or `long_`), `Op.addInt4` when `int_` (or `uint_`). No
  new opcodes; `addInt8` already exists in `program.d` and
  `machine.d`. If the compound-assign lvalue type is `uint_`, it
  should also be accepted (emitting `addInt4`).
- No `program.d` or `machine.d` changes needed.

### Failure mode 4: Associative-array type not recognised

**Root cause:** `scalarType()` has no `Taarray` case. Every test in
the `assocArray.*` group uses a local of type `int[int]`, causing an
immediate throw before any AA operation can be attempted. The
`Interpreter` backend handles AAs via call-site interception against
its own managed map structure; for the new core, the same druntime
AA runtime (`_d_aaGetY`, `_d_aaLen`, `_d_aaGetRvalue`, `_d_aaDelX`,
`_d_aaDup`, the `in` operator via `_d_aaInX`) is the correct target.
Per the design, the druntime templates whose bodies are available as
source are executed by the VM; for POD key/value types (all tests here
use `int`) the AA leaves bottom out in `GC.malloc` and related
primitives, which go through the native bridge.

**Failing tests (9):**
`assocArray.literalKeepsRuntimeKeysAndValues`,
`assocArray.literalKeepsLastDuplicateRuntimeKey`,
`assocArray.keysAndValuesUseRuntimeLiteral`,
`assocArray.inFindsRuntimeKey`,
`assocArray.equalityComparesRuntimeEntries`,
`assocArray.removeRuntimeKey`,
`assocArray.dupCopiesEntries`,
`assocArray.insertionGrowsAndOverwrites`,
`assocArray.readMissingKeyThrowsDiagnostic`.

**Oracle behavior:** `int[int] values = [k1: v1, k2: v2]` builds a
live AA; `values[k]` reads a value (throwing `"Range violation"` for
missing keys — the compiled-D druntime text, not the CTFE key-name
wording); `k in values` returns a pointer or null; `values.remove(k)`
removes and returns bool; `values.dup` copies entries; `values.keys`
and `values.values` return slices; `values == same` compares entry
sets.

**Required implementation:** AAs are the most complex feature here
because they require both a type-descriptor representation and
call-site interception. In the native-layout model, a `T[K]` local is
a single `void*` (the druntime `AA` handle — 8 bytes on x86-64). The
VM stores this pointer in a frame slot, passes it to druntime AA
functions, and reads the handle back from the same slot.

- `program.d` — add an `AssocArrayType` descriptor (key `ScalarType`,
  value `ScalarType`); add opcodes for each AA operation:
  `aaLiteral` (build from key-value pairs), `aaIndex` (lookup,
  throws on miss), `aaIn` (lookup, returns nullable pointer),
  `aaRemove`, `aaLength`, `aaKeys`, `aaValues`, `aaDup`, `aaEqual`,
  `aaAssign` (insert/overwrite). Alternatively — and more consistent
  with the plan's call-site-interception approach — compile each AA
  operation as a `call` to the appropriate druntime template function
  (`_d_aaGetY` etc.) once those templates are in scope. The simpler
  initial approach is direct VM opcode interception.
- `compiler.d` — add `Taarray` handling in `scalarType()` (or a
  parallel `aaType()` helper), reserve 8 bytes (one pointer) in the
  frame for an AA local, compile `AssocArrayLiteralExp`, `IndexExp`
  over an AA, `InExp`, dot-call expressions for `.remove`,
  `.length`, `.keys`, `.values`, `.dup`, and `EqualExp` over two AAs.
- `machine.d` — add handlers for each AA opcode (or route through
  the native bridge to druntime).
- `reify.d` — stub or full AA reification for the `Evaluator`
  boundary (no `assocArray.*` test exercises the eval surface, so a
  minimal stub that renders `"int[int]"` is acceptable for now).

### Subagent partition (dependency-ordered, sequential)

All four modes touch the same shared core files
(`source/quickbite/backends/bytecode/core/{program,compiler,machine,
reify}.d`). No parallelism is possible: each subagent must commit
before the next begins. The recommended dependency order is
3 → 2 → 1 → 4 (simplest fix first, deepest work last):

1. **`size_t` compound assignment** (failure mode 3) — fixes 2 tests,
   zero new opcodes, one relaxed gate. Run first: it is logically
   independent but both tests also need mode-1 array support; fixing
   this early keeps the delta for later commits small.
2. **Static-array inline storage** (failure mode 2) — fixes 3 tests.
   Static arrays are simpler than dynamic: no heap, no descriptor,
   no druntime calls. They are blocked by mode 3 in the
   `mutableStringLiteralCopiesDoNotShareWrites` test (which uses a
   `char[2]` local, not a compound assignment — mode 3 doesn't block
   it), so this can run right after step 1. Implement `Tsarray` frame
   allocation, inline element read/write, and string-to-char-array
   initialisation.
3. **Dynamic-array slice descriptor + all expressions** (failure mode
   1) — fixes 36 tests. This is the bulk of slice-5 and should be
   implemented in internal sub-slices within one subagent, each
   committed separately: (a) slice descriptor type + array-literal
   heap allocation + index read + `.length` (basic: fixes
   `lengthCases`, `literalElements`, `ubyteLiteralTruncatesElements`,
   `indexReadWrite`, `postIncrementIndex` and the two
   `assertDiagnostic` tests); (b) slices and aliasing (`SliceExp`,
   range-assignment, overlap check — fixes `sliceFromRuntimeBounds`,
   `nullZeroLengthSlice`, `nestedSliceWritesPropagateToOriginalArray`,
   `sliceAssignmentUpdatesArray`, `overlappingSliceAssignmentDiagnostic`,
   bounds-error diagnostics); (c) append and concatenation
   (`~=`, `~`, `dup`, `idup` — fixes `localAppend`,
   `appendToNonEmptyArray`, `refParameterAppend`, `concatenation`,
   `elementConcatenatesWithArray`, `dupDetachesCopyFromOriginal`,
   `idupFreezesIndependentCopy`, `nestedSliceAppendKeepsOriginalArrayTail`);
   (d) `new T[](n)`, `.length = n`, element-wise array ops,
   jagged / multidimensional arrays, return values, function
   parameters, `.ptr` and pointer arithmetic (fixes remaining).
4. **Associative arrays** (failure mode 4) — fixes 9 tests. Runs
   last: AAs depend on having a working GC heap and druntime
   interception path that mode 1 establishes first.

The following 5 blocks remain out of scope for `BytecodeNewCore` and
are **not promoted**:

- `dynamicArray.overlappingSliceAssignmentIsRejectedAtCtfe`
  (`Ctfe, Interpreter` only) — the CTFE-specific `"overlapping slice
  assignment [1..3] = [0..2]"` diagnostic text is not produced by
  compiled D; `BytecodeNewCore` targets the `SystemLinker` oracle.
- `dynamicArray.sliceIndexPastLengthDiagnostic` (CTFE variant,
  `Ctfe, Interpreter` only) — `"index 3 exceeds array length 2"` is
  CTFE wording; the compiled form `"index [3] is out of bounds for
  array of length 2"` is already in the promoted set above.
- `dynamicArray.indexPastLengthDiagnostic` (CTFE variant, same
  reason).
- `assocArray.readMissingKeyThrowsDiagnostic` (CTFE variant,
  `Ctfe, Interpreter` only) — the `"key \`absent\` not found"` text
  is CTFE-only; the `SystemLinker` form is in the promoted set.
- `pointer.slicePastAllocatedBlockDiagnostic` (CTFE variant, same
  block structure as above — the compiled fixture passes silently and
  is already in the promoted set).

Note: the blocks listed as out-of-scope above are the `Ctfe,
Interpreter`-only instantiations; the `BytecodeNewCore, SystemLinker,
LLVMJit` instantiations of the same fixture are already promoted and
are included in the failing-test counts above.

**Completed implementation:** All 53 promoted `arrays.d` tests pass on
`BytecodeNewCore` (focused run `53 test(s) run, 0 failed`; full suite green
under `--random`). The new core now models dynamic arrays as native
`{void* ptr, size_t length}` slice descriptors (16 bytes) in frame memory
backed by GC heap blocks rooted in the machine's `heap` table, with element
addresses computed as real `ptr + index*elemSize` so slice/pointer aliasing
and write-through are real memory by construction. Earned in dependency-ordered
sub-slices, each committed green: static-array inline storage; `size_t`
compound assignment; dynamic-array descriptor + literals + index + `.length`;
sub-slicing + aliasing + bounds diagnostics; slice range-assignment + overlap
(`"Range violation"`) + array `==` operand rendering; array returns,
parameters, and call-result indexing; element append `~=` (reallocating, with
`ref T[]` writeback); concat `~` and `.dup`/`.idup`; `new T[](n)`,
multidimensional `new`, jagged rows, `.length =` resize, and element-wise
`dest[] = a[] + b[]`; `.ptr`/`&arr[i]`, deref, pointer arithmetic (DMD
pre-scales the integer operand), pointer indexing/slicing, and pointer
comparisons/relations; and associative arrays (`int[int]`) via call-site
interception of the druntime AA hooks (`_d_aaGetY`, `_d_aaGetRvalueX`,
`_d_aaIn`, `_d_aaDel`, `_d_aaLen`, `_d_aaEqual`, `object.dup`/`keys`/`values`)
against a VM-owned map table referenced by an 8-byte handle. The 5 `Ctfe,
Interpreter`-only CTFE-divergence blocks remain unpromoted (no `SystemLinker`
oracle).

## structs.d Promotion Analysis (BytecodeNewCore)

All 43 SystemLinker-backed blocks in
`tests/ut/backends/runner/lang/structs.d` have been promoted to include
`BytecodeNewCore` in their `AliasSeq`. Every block's `AliasSeq` is
`(Ctfe, Interpreter, BytecodeNewCore, SystemLinker, LLVMJit)`, so all 43
are SystemLinker-oracle-backed and all 43 are in scope; none are
CTFE-only divergence blocks. The two lifetime tests called out for care
— `struct.scopeDestructorRunsAtCtfe` and
`struct.staticArrayCopyRunsPostblitAndDtors` — both include
`SystemLinker` and assert observable side effects (`sink[0] += 3` through
a `~this()`, and postblit/dtor counters through `int*`) that compiled D
reproduces identically, so they are real-compiled-D-backed, not
CTFE-only. All 43 currently fail.

The dominant first diagnostic is `Unsupported type in bytecode core:
<StructName>`: `scalarType()` in `compiler.d` (line 3621) has no
`Tstruct` branch and throws at the `default:` case (line 3658) for the
first struct-typed local, parameter, field-bearing declaration, or
expression. Because this gate fires before method, `new`, operator, and
`with` lowering, the deeper diagnostics each test would hit are masked.
The masked diagnostics, confirmed by reading the code paths, are: no
`DotVarExp`/field-access handler anywhere in `compileExpression` (every
local is a flat `VarDeclaration`-keyed frame slot — there is no aggregate
or field concept); no `ThisExp` or implicit-`this` mechanism, so methods
cannot resolve `value`/`bytes`/`pos`; no `Tstruct` case in
`compileVariableDeclaration`, `parameterLayout`, or `resultType`; no
`StructLiteralExp` handler; no struct-typed `NewExp` (`compileNew`
handles only array `new` and exception `new`); no `WithStatement`,
`GotoStatement`, or `LabelStatement` in `compileStatement`; and no
operator-overload (`opEquals`/`opCmp`/`opBinary`/`opIndex`/`opUnary`/
`opAssign`) rewrite path.

The native-layout precedent from slice-5 (`arrays.d`) is the model: a
struct occupies `Type.size()` inline frame bytes at its DMD-computed
alignment, and each field lives at its DMD-computed
`VarDeclaration.offset` within that block — exactly as static arrays
already use `staticArraySize`/`staticArrayAlign` and inline element
offsets. Dynamic-array fields are 16-byte `{ptr, length}` slice
descriptors embedded in the struct block, reusing the existing
`DynamicArrayLocal` machinery and slice opcodes; pointer fields are
8-byte address words; scalar fields are their native widths. No struct
value ever needs a tag at runtime; the compiler resolves every field
access to a `(baseOffset + fieldOffset, fieldType)` frame reference at
emit time.

All seven modes touch the same shared core files
(`source/quickbite/backends/bytecode/core/{program,compiler,machine,
reify}.d`). Subagents **must run sequentially**, each building on the
previous committed state. The modes are presented in dependency order:
each later mode assumes the struct frame-layout and field-access
machinery of mode 1.

### Failure mode 1: Struct native-layout locals, fields, and by-value copy

**Root cause:** `scalarType()` has no `Tstruct` case, so the first
struct-typed local (`Value wrapper;`), parameter (`int read(Value
wrapper)`), or struct literal (`Pair(seed)`) throws immediately. Even
once the type is accepted, there is no field-access path: `wrapper.value
= 42` is a `DotVarExp` assignment target, and `compileExpression` /
`compileAssign` have no `DotVarExp` handler — the model keys every value
on a flat `VarDeclaration`, with no notion of a base aggregate plus a
field offset. A struct must become an inline frame block (like a static
array), with each field resolved to `baseOffset + field.offset` and the
field's own scalar/slice/pointer type. By-value semantics fall out of
this: passing a struct copies all its bytes into the argument area, so a
callee's `p.x = 99` mutates only its private copy
(`byValueScalarFieldMutationDoesNotLeak`); a dynamic-array field copies
its 16-byte descriptor by value, so an append inside the callee
reallocates the callee's descriptor and does not leak
(`byValueArrayDescriptorMutationDoesNotLeak`), while an element write
`buffer.bytes[0] = 99` goes through the shared backing pointer and *does*
leak (`byValueArrayElementMutationLeaksThroughSlice`) — both behaviours
are automatic once the descriptor is copied by value and element access
reuses the existing slice opcodes. Struct literals `Pair(seed)` and
`S(seed)` initialise leading fields from the given arguments and
default-init the rest (zero for `int`, an empty descriptor for `ubyte[]`,
a scalar-broadcast for the `int[3]` static-array field of `S`).

**Failing tests (11; passing once this mode is done):**
`struct.scalarFieldReadWrite`,
`struct.multipleScalarFields`,
`struct.scalarFieldsDefaultToZero`,
`struct.arrayFieldDefaultsToEmpty`,
`struct.literalDefaultsMissingFieldToZero`,
`struct.literalFillsStaticArrayFieldFromScalar`,
`struct.scalarStructPassedToFunction`,
`struct.multiFieldStructPassedToFunction`,
`struct.byValueScalarFieldMutationDoesNotLeak`,
`struct.byValueArrayDescriptorMutationDoesNotLeak`,
`struct.byValueArrayElementMutationLeaksThroughSlice`.

**Oracle behavior:** A struct is a value type laid out at its
DMD-computed field offsets; default-init zeroes scalars and leaves
dynamic-array fields as empty `{null, 0}` descriptors. `Pair(seed)`
constructs with `first = seed, second = 0`; `S(seed)` broadcasts the
scalar into all three elements of the `int[3]` field. Passing a struct by
value copies the whole block; mutations to scalar or descriptor fields
stay local to the callee, but element writes through a shared
dynamic-array backing pointer propagate to the caller.

**Required implementation:**
- `program.d` — no new opcodes are strictly required for scalar-field
  structs: `copy` already does block byte copies. A struct frame block is
  copied with a single `copy` of `Type.size()` bytes (value-parameter
  passing, literal/default assignment). Dynamic-array fields reuse the
  slice opcodes; static-array fields reuse `loadStaticArray` and the
  inline index opcodes. (A struct-typed `ResultType` for mode 4/6 returns
  is added later.)
- `compiler.d` — add a `Tstruct` branch to `compileVariableDeclaration`
  that reserves `staticArraySize`-style inline bytes
  (`variable.type.size`, `variable.type.alignsize`) and records the base
  offset in a new `_structLocals[VarDeclaration] = (offset, StructType)`
  map (parallel to `_staticArrayLocals`); a `StructType` descriptor
  holding each field's `(offset, kind, elementType)`. Add `Tstruct`
  handling to `parameterLayout` and the `compileFunctionBody` parameter
  loop (a by-value struct parameter is a block in the argument area; no
  ref unless `ref`). Add a `DotVarExp` handler that resolves
  `base.field` to a frame reference `(baseOffset + field.offset,
  fieldType)` — used as an rvalue in `compileExpression`, an lvalue in
  `compileAssign`/`compileAddAssign`, a slice base in the dynamic-array
  paths, and a static-array base in the inline-index paths. Add a
  `StructLiteralExp` handler that emits per-field stores into the inline
  block (zero/empty default for omitted trailing fields, scalar broadcast
  for a static-array field initialised from a scalar). Default-init of a
  bare `Struct s;` emits nothing beyond the zeroed frame for scalar
  fields and an empty descriptor for dynamic-array fields.
- `machine.d` — no new handlers for scalar/descriptor field structs;
  block `copy` and the existing slice/static-array opcodes already
  execute. (Result-passing handlers come with mode 4/6.)
- `reify.d` — no change for this mode (no struct is an eval result yet;
  these tests assert scalar/length values).

### Failure mode 2: Struct methods, implicit `this`, and field ref-passing

**Root cause:** A method `int get() { return value; }` is a
`FuncDeclaration` with an implicit `this` parameter and an unqualified
field reference `value` that DMD resolves to `this.value` (a `DotVarExp`
over a `ThisExp`, or a bare `VarExp` of the field whose `var` is a struct
member). The new core has no `this` mechanism: `registerFunction` /
`parameterLayout` build the argument block from `function_.parameters`
only, never adding a `this` slot, and there is no `ThisExp` handler. A
call `box.get` is a `DotVarExp`/`CallExp` whose `e1` is the receiver;
`compileCall` (line 2528) only handles `VarExp`-callee free functions via
`callFunction` (line 4292) and has no method-receiver path. So every
method body fails to resolve its fields, and every method call fails to
pass the receiver. Field ref-passing (`append42(bytes)` /
`append42(buffer.bytes)`) additionally needs a `ref T[]` argument whose
referenced object is a *field* slot inside a struct block rather than a
standalone local — the existing ref-param writeback keys on a local's
frame offset and must accept `baseOffset + field.offset`.

**Failing tests (12; passing once this mode is done, given mode 1):**
`struct.methodReadsField`,
`struct.methodPostIncrementsSizeTField`,
`struct.methodPostIncrementsRuntimeSizeTField`,
`struct.methodReadsArrayFieldAtPostIncrementedField`,
`struct.methodReadsArrayFieldAtRuntimePostIncrementedField`,
`struct.methodIndexWritesArrayField`,
`struct.methodAppendsArrayField`,
`struct.methodCallsStructMethod`,
`struct.arrayFieldPassedByRef`,
`struct.methodPassesFieldByRef`,
`struct.templateMethodPassesFieldByRef`,
`struct.constructorStoresDynamicArrayParameter`.

**Oracle behavior:** A method receives `this` as a hidden `ref`-like
pointer to the receiver block; field reads/writes go through it, so
`box.value = 42; box.get == 42` reads the live field, `cursor.next`
returns the pre-increment `pos` and leaves `pos == 1`, and
`writer.put(42)` appends through the receiver's `bytes` descriptor,
reallocating and writing the descriptor back into the caller's struct.
Calling another method (`write` → `append`) forwards the same receiver.
`append42(buffer.bytes)` binds a `ref ubyte[]` to the field's descriptor
slot; the reallocated descriptor is written back into the field.
`constructorStoresDynamicArrayParameter` runs `this(int[] input) {
store(input); }` which forwards through a second method to assign the
field.

**Required implementation:**
- `program.d` — extend `RefParameter` usage so the receiver block is
  passed by reference (the method mutates the caller's struct in place,
  matching D's `ref this`). No new opcode if the existing ref mechanism
  is generalised to a block of `Type.size()` bytes written back on
  return; `methodAppendsArrayField` and friends require the receiver's
  descriptor field to be written back, so a 16-byte (or whole-block)
  writeback is needed.
- `compiler.d` — in `parameterLayout`/`compileFunctionBody`, prepend a
  hidden `this` parameter for a `FuncDeclaration` whose `isThis()`
  aggregate is a struct: reserve a receiver reference (frame slot bound to
  the receiver block) and record the struct type so unqualified field
  references resolve against it. Add a `ThisExp` handler and make the
  `DotVarExp` handler (from mode 1) and the bare-field `VarExp` case
  resolve a member `VarDeclaration` to `thisBase + field.offset`. In
  `compileCall`, add a method-receiver path: when the callee is a
  `DotVarExp` whose `var` is a struct method, compile the receiver to its
  block offset and pass it as the hidden `this` argument, then the
  ordinary arguments. Generalise the ref-param writeback so a `ref`
  argument can name a field slot (`baseOffset + field.offset`), used both
  for the receiver and for `append42(field)`. Template methods
  (`append(T)(T)`) are ordinary `FuncDeclaration`s post-instantiation, so
  no extra work beyond method support.
- `machine.d` — extend the ref-param entry/return path to dereference and
  write back the receiver block (or its mutated descriptor field) of the
  required width.
- `reify.d` — no change (these tests assert scalar/length results).

### Failure mode 3: `new Struct` heap allocation, pointers, and constructors

**Root cause:** `new Pair(seed, seed + 1)` and `new Box(seed)` are
struct-typed `NewExp`s; `compileNew` (line 1059) handles only array
`new` and plain-exception `new` (`isPlainExceptionNew`, line 3786), so a
struct `new` falls through to `"Unsupported expression in bytecode core:
new Pair(...)"`. The result is a `Pair*` pointer local — a struct pointer
— which the pointer machinery (`_pointerLocals`, `pointerLoad`/`Store`)
currently models only for scalar-element pointers, not for a pointer to a
multi-field aggregate where `p.a`/`p.b` are field accesses through the
address. Member access through a struct pointer (`p.a += p.b`,
`p.b = next(p.a)`) is a `DotVarExp` over a dereferenced pointer.

**Failing tests (3; passing once this mode is done, given modes 1–2):**
`struct.newPointerInitializesFields`,
`struct.newPointerAllocatesMutableInstance`,
`struct.newPointerRunsConstructor`.

**Oracle behavior:** `new Pair(a, b)` allocates a struct block on the GC
heap, runs the field-wise constructor (or `this(seed)` running `value =
seed + 2`), and yields a pointer to it; `p.a`/`p.b` read and write the
heap fields through the pointer, with mutations visible across reads
(`p.a += p.b; p.b = next(p.a)`).

**Required implementation:**
- `program.d` — reuse `allocArray`-style heap allocation for a single
  struct block (a fixed `Type.size()` byte block rooted in `heap`),
  yielding a raw `size_t` pointer; add struct-field load/store through a
  pointer if not already expressible via the existing
  `pointerLoad`/`pointerStore` with a field-offset addend (a
  `pointerLoadN`/`pointerStoreN` at `ptr + fieldOffset` for the field's
  width).
- `compiler.d` — add a struct branch to `compileNew`: allocate the block,
  run the constructor (the `this(...)` `FuncDeclaration` from mode 2, with
  the heap pointer as the receiver) or do field-wise init for a
  bare-field literal `new Pair(a, b)`, and yield a struct-pointer
  `Operand`. Record a `_structPointerLocals[VarDeclaration] = StructType`
  so `DotVarExp` over the pointer resolves a field to `ptr + field.offset`
  with the field's width. Member-assignment through the pointer routes to
  the pointer-store path.
- `machine.d` — add the struct-block allocation and field-through-pointer
  load/store handlers (offset addend within a heap block).
- `reify.d` — no change (these tests assert scalar field results).

### Failure mode 4: Struct dynamic-array field return values

**Root cause:** A method `ubyte[] get() { return values; }` returns a
dynamic-array *field*; the existing array-return path (`resultType` +
`arrayDescriptorOffset`, lines 165–169) expects the returned expression
to resolve to a dynamic-array local, not a `DotVarExp` field of the
receiver. Assigning the call result back to a field
(`values = identity(input)`) and indexing the call result
(`box.get[1]`) likewise need the field/method machinery from modes 1–2 to
interoperate with the array-return descriptor handling.

**Failing tests (3; passing once this mode is done, given modes 1–2):**
`struct.dynamicArrayFieldReturnValue`,
`struct.dynamicArrayReturnValueAssignsField`,
`struct.dynamicArrayFieldReturnValueIndexesCallResult`.

**Oracle behavior:** `box.get` returns the field's `{ptr, length}`
descriptor (sharing the backing block); `result.length == 2` and indexing
read through it. `box.set(replacement)` assigns the field from a free
function's array return. `box.get[1]` indexes the returned descriptor.

**Required implementation:**
- `compiler.d` — extend `arrayDescriptorOffset` (and the return path) to
  accept a `DotVarExp` field whose type is a dynamic array, resolving it
  to the field's descriptor slot. Ensure assigning a dynamic-array call
  result into a struct field reuses the field-as-descriptor-slot lvalue
  from mode 1, and that indexing a call result (`box.get[1]`) over a
  struct method works through the existing call-result index path.
- `program.d`/`machine.d`/`reify.d` — no new opcodes; the slice
  descriptor return mechanism from slice-5 already carries the bytes.

### Failure mode 5: `with` statement, labels/`goto`, and `with(enum)`

**Root cause:** `compileStatement` has no `WithStatement`,
`GotoStatement`, or `LabelStatement` branch (confirmed by absence
anywhere in the core), so all three `with` tests die with `"Unsupported
statement in bytecode core: With"` (after mode 1 admits the struct
type). `with (point) { x += scale; ... }` introduces the struct's fields
as unqualified names referring to the `point` instance — each becomes a
`DotVarExp`/member `VarExp` over the `with` subject, resolvable with the
mode-1 field machinery once the subject's base offset is in scope.
`with (point) { goto target; ... target: x += 1; }` additionally needs
`LabelStatement` and forward `GotoStatement` (a `jump` to a patched
label). `with (Mode) { total += cast(int) on; ... }` is an enum `with`:
its body references enum members, which DMD has already folded to integer
constants, so the body lowers to ordinary `int` compound assignments — it
needs only the `WithStatement` wrapper to compile its body (no struct
subject at all).

**Failing tests (3; passing once this mode is done — the enum one needs
only `WithStatement`, the struct ones also need mode 1):**
`with.structInstanceUsesRuntimeShapedFields`,
`with.structLocalGotoRestartsInsideBody`,
`with.enumExecutesBody`.

**Oracle behavior:** `total(point)` mutates the `with` subject's fields
in place (`x += scale; y += x; return x + y` → 15 for `x=3, y=5,
scale=2`). The `goto` skips the `x += 100` step and lands at `target`,
yielding `41 + 1 = 42`. The enum `with` adds `on (5)` and `off (2)` to
the seed `3`, giving `10`.

**Required implementation:**
- `program.d` — no new opcode; labels and `goto` reuse the existing
  `jump` with a patched target index (the same patch mechanism
  `compileIfStatement`/`compileForStatement` already use).
- `compiler.d` — add `WithStatement` to `compileStatement`: bind the
  subject expression (a struct lvalue → its base offset; an enum/type →
  no runtime binding) so that unqualified field references inside the body
  resolve to the subject's block, then compile the body. Add
  `LabelStatement` (record the instruction index, resolving any pending
  forward jumps) and `GotoStatement` (emit a `jump`, patched to the
  label's index — supporting forward references via a fixup list). The
  enum `with` requires only that `WithStatement` compile its body, since
  the enum members are already constant-folded.
- `machine.d`/`reify.d` — no change.

### Failure mode 6: Operator overloads, default equality, nested structs, and struct-by-value returns

**Root cause:** This mode collects the remaining surface that requires
struct *values* to flow as call arguments, return values, and comparison
operands, plus rewrites of operator syntax to method calls and the two
lifetime tests. DMD lowers `a == b` on a struct to `a.opEquals(b)` (or a
field-wise `__equals` for default equality), `a < b` to `a.opCmp(b) < 0`,
`a + b` to `a.opBinary!"+"(b)`, `a[i]` to `a.opIndex(i)`, `-a` to
`a.opUnary!"-"()`, and `s = v` to `s.opAssign(v)`. Each is a method call
on a struct receiver returning a scalar or a struct value — so they all
depend on mode-2 method support plus a struct-typed `ResultType` (a
function/method returning `Money`/`Score`/`Pair`/`Outer` by value, which
`resultType` currently cannot express). `make(3) == make(3)` calls a
free function returning a struct by value, then compares; the masked
diagnostics `make(7).opUnary().value`, `make(40).opBinary(make(2)).cents`
confirm these are method calls on struct rvalues whose result is a struct
value indexed for a field. Nested structs need a struct-typed *field*
(`Outer.inner`) and a nested struct capturing an enclosing local
(`Inner.readBase` reads `seed` by reference to the enclosing frame — a
closure-context capture). The two lifetime tests need
destructor/postblit insertion: `~this()` at scope exit
(`scopeDestructorRunsAtCtfe`) and `this(this)` + `~this()` on a
static-array copy (`staticArrayCopyRunsPostblitAndDtors`, four dtors at
block exit, two postblits on the `Tracker[2] copy = source` blit).

**Failing tests (11; grouped sub-dependencies noted):**
struct-by-value returns + default/custom equality + ordering:
`struct.defaultEqualityComparesFields`,
`struct.customOpEquals`,
`struct.opCmpOrdersValues`;
operator overloads returning structs:
`struct.opBinaryAddsOperands`,
`struct.opIndexSelectsElement`,
`struct.opUnaryNegatesValue`,
`struct.opAssignFromScalar`;
nested / chained struct fields:
`struct.nestedReadsCapturedLocalThroughDefaultInit`,
`struct.fieldChainReadsInnerStructMember`;
lifetime effects:
`struct.scopeDestructorRunsAtCtfe`,
`struct.staticArrayCopyRunsPostblitAndDtors`.

**Oracle behavior:** Default `==`/`!=` compares fields member-wise
(`make(3) == make(3)`, `make(3) != make(4)`); `opEquals`/`opCmp`/
`opBinary`/`opIndex`/`opUnary`/`opAssign` run the user method and yield
its scalar or struct result. A struct-typed field
(`Outer.inner.v`) reads through nested offsets;
`make(40).inner.v == 42`. A nested struct's method reads the captured
enclosing local by reference, so a later `seed += bump` is visible
(`inner.readBase == 42`). `scopeDestructorRunsAtCtfe` runs `~this()` at
the inner scope's close, mutating `sink[0]` from 4 to 7.
`staticArrayCopyRunsPostblitAndDtors` runs two postblits on the
element-wise static-array copy and four destructors (both arrays) at
block exit, observed through `int*` counters.

**Required implementation:**
- `program.d` — add a struct `ResultType` kind (a block of `Type.size()`
  bytes with the struct's field layout) so a function/method can return a
  struct by value; the caller receives the block (NRVO-style copy into a
  destination slot). No new arithmetic opcodes — operator bodies are
  ordinary method calls.
- `compiler.d` — (a) extend `resultType` to a struct-block kind and the
  return path to copy a struct value into the result area; (b) add the
  operator-lowering recognition so DMD's already-lowered `opEquals`/
  `opCmp`/`opBinary`/`opIndex`/`opUnary`/`opAssign` calls (they arrive as
  `CallExp`/`DotVarExp` after semantic, or as `EqualExp`/`CmpExp` that
  must be routed to the method) compile through the mode-2 method path;
  (c) add default-equality lowering (field-wise compare when no
  `opEquals` exists — DMD emits `__equals`/`TypeInfo` compare, which the
  core should special-case to a sequence of per-field scalar compares
  combined with `&&`); (d) add a struct-typed *field* to the field
  machinery (a `DotVarExp` whose field is itself a struct, enabling the
  `Outer.inner.v` chain — resolve nested `baseOffset + inner.offset +
  v.offset`); (e) add nested-struct enclosing-local capture (the nested
  `struct Inner` method reads `seed` from the enclosing unittest frame —
  this requires passing a context pointer / frame reference, the one
  genuinely new mechanism here); (f) insert destructor calls at scope
  exit for struct locals with `~this()`, and postblit calls on
  static-array element copies with `this(this)` — DMD's
  `dtorExp`/`postblit` hooks identify these; the core must emit the method
  calls at the lowered points.
- `machine.d` — struct-value return (block copy into the caller's
  destination), field-through-context-pointer access for the nested
  capture, and the dtor/postblit calls execute as ordinary calls; no new
  opcode families beyond block copy and a context-pointer load.
- `reify.d` — extend `reify()` to render a struct `ResultType` (read the
  field bytes per the layout) for any eval-boundary struct result; the
  promoted tests assert scalar fields of struct results
  (`(make(40) + make(2)).cents`), so a field-projection at the assert
  site may suffice, but a struct reification stub keeps the
  `Evaluator` boundary consistent.

### Subagent partition (dependency-ordered, sequential)

All modes touch the same shared core files
(`source/quickbite/backends/bytecode/core/{program,compiler,machine,
reify}.d`). No parallelism is possible: each subagent must commit before
the next begins. The dependency order is 1 → 2 → 3 → 4 → 5 → 6 (struct
layout first, the deepest value-flow / operator / lifetime work last).
After each subagent, rerun only
`ut.backends.runner.lang.structs.*.BytecodeNewCore` and leave passing
promoted tests in place.

1. **Struct native-layout locals, fields, and by-value copy** (failure
   mode 1) — fixes 11 tests. Add the `Tstruct` frame block, the
   `StructType`/field-offset descriptor, the `DotVarExp` field
   rvalue/lvalue path, by-value struct parameters, struct literals, and
   default-init. This is the foundation every later mode builds on.
2. **Struct methods, implicit `this`, and field ref-passing** (failure
   mode 2) — fixes 12 tests. Add the hidden `this` receiver, `ThisExp`
   and bare-field resolution, the method-receiver call path, and
   field-slot ref-parameter writeback.
3. **`new Struct`, struct pointers, and constructors** (failure mode 3) —
   fixes 3 tests. Add struct-block heap allocation, constructor running on
   the heap receiver, and field-through-pointer access.
4. **Struct dynamic-array field return values** (failure mode 4) — fixes
   3 tests. Extend the array-return descriptor path to field receivers and
   call-result indexing/assignment into fields.
5. **`with`, labels/`goto`, and `with(enum)`** (failure mode 5) — fixes 3
   tests. Add `WithStatement`, `LabelStatement`, and `GotoStatement`
   (forward-jump fixups), binding struct/enum `with` subjects.
6. **Operator overloads, default equality, nested structs, and
   struct-by-value returns** (failure mode 6) — fixes 11 tests. Add the
   struct-typed `ResultType`, operator-method lowering, field-wise default
   equality, struct-typed fields and chains, nested-struct enclosing-local
   capture, and destructor/postblit insertion. The deepest mode; split
   into committed sub-slices (value returns + equality/ordering; the
   remaining operator overloads; nested/chained fields; lifetime
   effects).

All 43 blocks are SystemLinker-oracle-backed and in scope; none are
withheld from promotion.

**Completed implementation:** All six failure modes were earned in seven
sequential commits (mode 6 split into four sub-slices), each building on
the prior committed state. `structs.d` (module order 9) is now complete on
the new core: 43/43 promoted `BytecodeNewCore` blocks pass and the full
suite is green under multiple random seeds. The new core gained struct
native-layout frame blocks at DMD-computed field offsets, by-value copy
semantics (scalar/descriptor mutations stay local while shared
backing-pointer element writes leak), methods with a hidden ref `this`,
`new Struct` GC-heap allocation with constructors and field-through-pointer
access, dynamic-array field returns, `with`/`goto`/labels (forward-jump
fixups), struct-by-value `ResultType` returns (NRVO-style copy), operator
overloads through DMD's lowered method calls, field-wise POD default
equality, struct-typed fields and chains, nested-struct enclosing-local
capture via a stack-base-index context pointer (`frameBaseIndex`/
`frameLoad`), and scope-exit destructor / static-array postblit insertion
intercepting `_d_arrayctor`/`__ArrayDtor`. The static-array postblit/dtor
slice required raw `&local` addresses to stay valid across frame growth, so
the VM now reserves a fixed stack capacity up front; deep recursion beyond
that reserve could reallocate and invalidate live `&local` pointers, a
case no current test exercises and a future bench/feature checkpoint
should revisit.

## control_flow.d Promotion Analysis (BytecodeNewCore)

All SystemLinker-backed tests from
`tests/ut/backends/runner/lang/control_flow.d` have been promoted to include
`BytecodeNewCore` in their `AliasSeq` blocks and were run in isolation with
the full unit-threaded names matching
`ut.backends.runner.lang.control_flow.*.BytecodeNewCore`. 67 tests were
promoted. 31 pass unchanged: all `while.*`, `if.*`,
`function.*` (except `nestedLambda*` and `overloadResolutionBySignature`),
`goto.directLabel`, `goto.restartsCompoundStatement`,
`goto.restartsExpressionStatement`, `foreach.array`,
`foreach.arrayWithIndex`, `foreach.emptyArray`, and `foreach.range`. The
remaining 36 failures group into 9 root-cause failure modes.

All failure modes touch the shared core files
(`source/quickbite/backends/bytecode/core/{compiler,machine,program,reify}.d`).
Subagents must run sequentially; parallelism is not possible.

### Failure mode 1: `break` and `continue` statements not lowered (7 tests)

**Root cause:** `compileStatement` in `compiler.d` has no branch for
`BreakStatement` or `ContinueStatement`. Any loop body (or label target)
containing a `break` or `continue` falls through to the generic unsupported
throw: `Unsupported statement in bytecode core: Break` /
`Unsupported statement in bytecode core: Continue`.

**Failing tests (7):**
- `goto.restartsBreakStatement` — `for` body: `goto stop; ... stop: break;`
- `goto.restartsContinueStatement` — `for` body:
  `goto skip; ... skip: continue;`
- `for.continue` — `for (int i = 0; i < 4; ++i) { if (i == 2) continue; }`
- `doWhile.breakAndContinue` — `do { ++i; if (i==2) continue;
  if (i==5) break; sum += i; } while (i < 6);`
- `labeledBreak.exitsOuterForLoop` — `break outer;` inside nested loops
- `labeledContinue.skipsToOuterForIncrement` — `continue outer;` inside
  nested loops
- `foreach.expressionTupleBreakAndContinue` — `UnrolledLoop` with `break`
  and `continue` inside each iteration (see also mode 2)

**Oracle behavior:** `break` exits the nearest enclosing breakable statement
(loop or switch); `continue` jumps to the loop's increment/condition;
labeled `break label` / `continue label` target the named outer loop.

**Required implementation (small — two new jump-target opcodes):** Add a
`BreakStatement` branch and a `ContinueStatement` branch in
`compileStatement`. The compiler must maintain a per-loop break-target and
continue-target (two stacks of patch lists, one entry per nested loop). For
`break`, emit `Op.jump` and push the index into the break-target patch list;
for `continue`, emit `Op.jump` and push into the continue-target patch list.
Patch both lists when the loop exits: break-targets patch to the instruction
after the loop, continue-targets patch to the increment (for `for` and
`while`) or condition (for `do/while`). Labeled `break`/`continue` require
associating each labeled loop with its patch lists by `Identifier*`. The
existing `Op.jump` instruction is sufficient; no new VM opcode is needed.
`BreakStatement` inside a `SwitchStatement` body uses the same mechanism but
targets the end of the switch (mode 3).

**Dependency:** None — this is the prerequisite for modes 3 and 4.

**DONE (5/7):** Added `BreakStatement`/`ContinueStatement` branches to
`compileStatement` plus a `LoopContext[] _loopStack` (per-loop break/continue
`jump`-index patch lists and the enclosing `label:` ident). `compileForStatement`
pushes a context, patches continue-jumps to the increment point and break-jumps
to past the loop, then pops. `compileLabelStatement` hands a wrapping label's
ident to the loop it governs (via `_pendingLoopLabel`, detected with a recursive
`containsLoop` through `Scope`/`Compound`, since DMD wraps a labeled `for` as
`label: { init; for }`); `break`/`continue` resolve their target loop by
innermost (unlabeled) or matching `Identifier*` (labeled). No new VM opcode —
reuses `Op.jump`. Greened `for.continue`, `labeledBreak.exitsOuterForLoop`,
`labeledContinue.skipsToOuterForIncrement`, `goto.restartsBreakStatement`,
`goto.restartsContinueStatement`. The other 2 mode-1 tests
(`doWhile.breakAndContinue`, `foreach.expressionTupleBreakAndContinue`) still
fail on mode 2's `Do`/`UnrolledLoop` gate before reaching break/continue; their
loop-back/unrolled break/continue lowering is left for mode 2.

### Failure mode 2: `Do` and `UnrolledLoop` statements not lowered (2 tests)

**Root cause:** `compileStatement` has no branch for `DoStatement` (the AST
node for `do { body } while (cond);`) or for `UnrolledLoopStatement` (the AST
node DMD emits for `foreach` over a compile-time expression tuple).

**Failing tests (2):**
- `doWhile.breakAndContinue` — errors with `Unsupported statement: Do`
- `foreach.expressionTupleBreakAndContinue` — errors with
  `Unsupported statement: UnrolledLoop`

Note: `doWhile.breakAndContinue` is already counted in mode 1 (the error it
hits first is `Do`); `foreach.expressionTupleBreakAndContinue` hits
`UnrolledLoop` before reaching any `break`/`continue`.

**Required implementation:**

- `DoStatement`: emit the body first, then the condition test. The pattern is
  `[body][conditionTest → exit jump back to body start]`. Break/continue use
  the same patch-list mechanism as mode 1.
- `UnrolledLoopStatement`: each unrolled iteration is a statement in the
  `statements` array; `foreach` over a tuple is fully unrolled at compile
  time. Compile each statement in order. `break` inside an unrolled loop body
  must jump past all remaining iterations; `continue` must jump to the next
  iteration's start — the compiler must handle these as special cases of the
  break/continue target stacks, since an `UnrolledLoopStatement` does not
  have a runtime loop-back target.

**Dependency:** Mode 1 (break/continue patch lists) must land first.

**DONE (2/2):** Added `DoStatement`/`UnrolledLoopStatement` branches to
`compileStatement` with `compileDoStatement`/`compileUnrolledLoopStatement`.
`DoStatement` records the body start, pushes a `LoopContext`, compiles the body,
patches continue-jumps to the condition test (`Op.jumpIfTrue` back to body
start), patches break-jumps past the loop, then pops. `UnrolledLoopStatement`
pushes a context and compiles each `statements` element in order; before each
iteration it patches the prior iteration's continue-jumps to that iteration's
start (then clears them), and at the end patches the final iteration's
continue-jumps and all break-jumps past the whole block. No new VM opcode —
reuses `Op.jump`/`Op.jumpIfTrue`. Greened `doWhile.breakAndContinue` and
`foreach.expressionTupleBreakAndContinue`, the 2 tests mode 1 deferred on the
`Do`/`UnrolledLoop` gate. control_flow failures: 30 → 28.

### Failure mode 3: `Switch` statement not lowered (11 tests)

**Root cause:** `compileStatement` has no branch for `SwitchStatement`. All
`switch(...)` statements — including `final switch` on enums, `goto case`,
`goto default`, and `break` inside a case — fall through to the generic
throw: `Unsupported statement in bytecode core: Switch`.

**Failing tests (11):** `switch.caseMatch`, `switch.defaultCase`,
`switch.gotoCase`, `switch.gotoDefault`, `switch.gotoCaseUsesRuntimeSelector`,
`switch.gotoDefaultUsesRuntimeSelector`,
`switch.finalSwitchOnEnumCoversAllMembers`,
`switch.caseRangesAndMultiValueCases`, `switch.breaksOuterLoop`,
`goto.restartsGotoCaseStatementInTryFinally`,
`goto.restartsGotoDefaultStatementInTryFinally`.

Note: `switch.stringCases` fails with a string-type error (mode 5) before
the switch body is even compiled; it is counted in mode 5, not here.

**Oracle behavior:** Integer/enum switch with case match, default,
multi-value cases (`case 5, 7:`), case ranges (`case 0: .. case 3:`),
`goto case N`, `goto default`, `break` inside a case body. The `finalSwitch`
variant omits the default handler.

**Required implementation (large — new statement family):** Add a
`SwitchStatement` branch in `compileStatement`. The minimal approach for
integer/enum selectors is an if-chain of equality or range comparisons
(linear scan) — correct, simple, and sufficient for the test surface. Each
`CaseStatement` is one or more values (multi-value case) or a range; emit a
jump-chain testing the selector against each case value or range, falling
through to `default`. `GotoCaseStatement` and `GotoDefaultStatement` are
label-like jumps emitted as `Op.jump` with the target case's instruction
index. `BreakStatement` inside a switch body uses the break-target patch
list from mode 1, with the switch as the enclosing breakable statement.
`final switch` on an enum needs no default handler in the emitted code (all
values are covered). The switch body (`switch_.cases`) is a `Statements*`
of `CaseStatement`/`CaseRangeStatement`/`DefaultStatement` nodes, each
wrapping its statement subtree. All sub-statements are compiled with
`compileStatement` after the case dispatch is emitted.

**Dependency:** Mode 1 (break inside case bodies). Mode 2 is independent.

**DONE (9/9 integer/enum):** Added `SwitchStatement` plus `CaseStatement`/
`DefaultStatement`/`GotoCaseStatement`/`GotoDefaultStatement` branches to
`compileStatement` (`SwitchErrorStatement` emits nothing — a `final switch` is
exhaustive so its appended runtime guard is unreachable). `compileSwitchStatement`
compiles the selector, emits `Op.jump` over the body to a trailing linear
dispatch chain, pushes a `LoopContext{isSwitch:true}` (break target, not a
continue target) and a `SwitchContext`, compiles the body (each case/default
records its body's instruction index), then emits the dispatch: per case an
`equalOp(selectorSize)` compare + `Op.jumpIfTrue` to the body, falling through
to a `goto` to the default (omitted for `final switch`); the body's tail
`Op.jump` skips the dispatch to the exit. `goto case`/`goto default` emit
`Op.jump`s recorded against the resolved target (`GotoCaseStatement.cs` /
default) and patched once body/default indices are known — runtime selectors
need no re-match since DMD pre-resolves `.cs`. `CaseRangeStatement` and
multi-value `case a, b:` are already expanded into `CaseStatement` chains by
semantic, so only `CaseStatement` is seen. `targetLoopIndex` now takes a
`forContinue` flag so unlabeled `continue` skips switch contexts (targets the
enclosing loop) while unlabeled `break` stops at the innermost switch. No new VM
opcode — reuses `Op.jump`/`Op.jumpIfTrue`/`Op.equal{1,2,4,8}`. Greened all 9:
`switch.caseMatch`, `switch.defaultCase`, `switch.gotoCase`, `switch.gotoDefault`,
`switch.gotoCaseUsesRuntimeSelector`, `switch.gotoDefaultUsesRuntimeSelector`,
`switch.finalSwitchOnEnumCoversAllMembers`,
`switch.caseRangesAndMultiValueCases`, `switch.breaksOuterLoop` (plus the two
`goto.restartsGotoCase/DefaultStatementInTryFinally` tests, which only needed
switch lowering). control_flow failures: 28 → 17. `switch.stringCases` (mode 5)
still gated on string selectors.

### Failure mode 4: `TryCatch` statement not lowered (3 tests) and
`TryFinally` finally-on-goto not enforced (1 test)

**Root cause — TryCatch (3 tests):** `compileStatement` has no branch for
`TryCatchStatement`. The three `catch.*` tests use `try { } catch (Exception)
{ goto label; ... label: break/continue/goto; }` — they reach the
"Unsupported statement: TryCatch" throw before executing any catch body.

**Root cause — TryFinally finally-on-goto (1 test):**
`goto.restartsGotoStatementInTryFinally` does NOT throw the unsupported
diagnostic (it has a `TryFinallyStatement`, not a `TryCatchStatement`, which
the new core handles naively). It compiles and executes, but the goto that
exits the try block (`resumed: goto outside;`) bypasses the finally block,
yielding `total = 2` instead of `total = 1 + 2 = 3`. The current naive
implementation just sequences body then finally; it does not insert finally
code on goto-exit paths.

**Failing tests (4 primary; 2 secondary after mode 1):**
- `catch.gotoRestartsBreakStatement` — TryCatch unsupported
- `catch.gotoRestartsContinueStatement` — TryCatch unsupported
- `catch.gotoRestartsGotoStatement` — TryCatch unsupported
- `goto.restartsGotoStatementInTryFinally` — finally not run on goto-exit
  (reports `2 != 3`)

Secondary: `goto.restartsBreakStatementInTryFinally` and
`goto.restartsContinueStatementInTryFinally` currently fail on
`Unsupported statement: Break/Continue` (mode 1), but once break/continue
land, these tests will also require the finally block to fire when
`break`/`continue` exits the try body. They will be unmasked by mode 1 and
will need the finally-on-jump fix from this mode.

**Assessment of the exception-machinery question:** The three `catch.*` tests
genuinely require `throw new Exception("expected")` inside the try block to be
caught. This is not a finally-only concern; it needs catch clause dispatch.
However, the test fixtures use `throw new Exception(string)` which the new
core already lowers via `Op.throwString`. The machinery needed is:

1. A compile-time try/catch handler record in the compiled function's handler
   table (just a `(start_pc, end_pc, handler_pc)` triple per catch clause).
2. On `Op.throwString` (or any future throw-like opcode), the VM searches the
   handler table and jumps to the catch body's first instruction, binding the
   exception message to the catch variable if named (these tests use unnamed
   `catch (Exception)`).
3. For the finally-on-goto fix: the compiler must detect when a `goto`
   crosses a `TryFinally` boundary and emit the finally block inline on that
   path before the jump.

This is a narrower surface than full exception-handler tables: only
`Op.throwString` is thrown, only `Exception` is caught (no class hierarchy
dispatch), and the catch variable is unnamed. Full exception machinery (slice
6) is not required; a narrow handler table with a single try-region type is
sufficient.

**Dependency:** Mode 1 (break/continue inside catch bodies). Mode 3 is
independent. The `goto`-crosses-`TryFinally` fix touches the existing
`compileGotoStatement` and requires the compiler to know which try-finally
region the goto originates in.

**DONE (6/6):** Implemented the narrow try/catch/finally control-flow surface
these tests need; deliberately did NOT build general exception unwinding
(module 11). A compile-time `_tryFinallyStack` records each `try`/`finally`
scope active while its try body compiles, holding the `finally` AST, the set of
label idents defined in the try body, and the `_loopStack` depth at push. On
each exit edge that leaves a try body the finally is re-emitted inline
(`runExitedFinally`), innermost-first, with the exited scopes temporarily
removed from the stack: the fall-through edge (in `compileTryFinallyStatement`),
a `goto` whose target label is outside the scope (`compileGotoStatement`
counts scopes whose try-body label set lacks the target — `goto_.tf`/`tryBody`
were observed null here, so the label set is the reliable signal), and a
`break`/`continue` to a loop enclosing the try (`finallyScopesInsideLoop`
counts scopes pushed inside the target loop). `collectLabels` recurses through
every nested statement container (compound/scope/if/for/while/do/switch/case/
default/with/unrolled/try) so a label inside a switch within the try is found
(fixed a regression where `goto resumed` inside a `switch` inside a
`try`/`finally` wrongly ran the finally). `TryCatchStatement`
(`compileTryCatchStatement`, scoped to a single `catch (Exception)` with an
unnamed variable) emits a runtime handler table: `Op.pushHandler` at try entry
records the catch body's instruction index and frame, the try body compiles,
then `Op.popHandler` + a jump-over-catch on normal completion, then the catch
handler body. The machine keeps a `Handler[]` stack; `throwString` with a
handler active pops it, restores the recorded frame (`functionIndex`/`base`/
frame depth), and jumps to the catch body, else throws the host exception as
before (uncaught throws and synthesised assert diagnostics unchanged). New
opcodes `pushHandler`/`popHandler` (justified: the existing throw machinery had
no in-VM catch redirect — `throwString` always escaped as a host exception;
these are the minimal pair to register/retire a catch region and are reused by
nothing else). Deliberately scoped out: cross-frame unwinding beyond restoring
the recorded handler frame, class-hierarchy catch matching, named catch
variables, multiple catch clauses, and `finally` execution on the throw edge
(no test throws across a `try`/`finally`). All six tests
(`catch.gotoRestarts{Break,Continue,Goto}Statement`,
`goto.restarts{Break,Continue,Goto}StatementInTryFinally`) pass; control_flow
BytecodeNewCore is 0 failed; full `bin/ut --random` shows no regressions.

### Failure mode 5: `string` switch selector not supported (1 test)

**Root cause:** `switch.stringCases` uses `switch (s)` where `s` has type
`string`. The `Switch` statement lowering (mode 3) will need to evaluate the
selector expression; `string` as a local type is not yet a tracked local
kind in the new core (`Unsupported type in bytecode core: string`). The
selector reaches the type check before the `SwitchStatement` branch is even
reached.

**Failing test (1):** `switch.stringCases` — uses `string pick(int n)`
returning a string literal, passed as the switch selector.

**Oracle behavior:** D string switch compiles to a hash-based dispatch;
the VM must implement string equality matching across the case literals.

**Required implementation:** After mode 3 lands for integer/enum selectors,
add a string selector path: the selector is a `string` local (a slice
descriptor with string metadata), and each case is a string literal. The
dispatch emits a linear string-equality chain (`Op.stringEqual` or equivalent)
checking the selector against each case literal. The `string` local type is
already present in the arrays machinery (slice descriptors for string literals
passed to functions); tracking a `string` function parameter as a
dynamic-array-descriptor local in the `string` case is the minimal extension.

**Dependency:** Mode 3 (SwitchStatement framework). The string-local
infrastructure already exists for array slices.

**DONE (1/1):** DMD's lowering differed from the analysis's guess. With
codegen on, DMD rewrites a string `switch (s)` into
`object.__switch!(char, "s0", "s1", ...)(s)` — a call returning the matched
case's index in the (sorted, source-order-as-passed) string table or -1 — and
overwrites each `CaseStatement.exp` with the corresponding `IntegerExp` index.
So `switch_.condition` is a `CallExp`, the cases are integers, and there are no
`StringExp` cases left to compare. `compileSwitchStatement` now detects this
via `stringSwitchSelector` (condition is a `CallExp` whose `e1` resolves to a
`FuncDeclaration` whose parent `TemplateInstance.name is Id.__switch`) and
lowers the selector itself with `compileStringSwitchSelector`: load -1 into an
`int` slot, compile the runtime selector string, then for each `StringExp`
template arg (skipping the leading element-type arg) emit
`Op.stringSliceEqual` against that case literal and, on a match, store the
arg's index and jump to the chain end. The existing integer dispatch then
matches that `int` against the cases' integer indices unchanged. Two
supporting gaps were filled so a `string` parameter is tracked at all: a
`string` parameter now gets an 8-byte slice-descriptor slot in
`parameterLayout` and a `_stringLocals` entry in the frame-binding loop
(previously it fell through to the scalar path and threw "Unsupported type ...:
string"); and `emitCallArgument` now copies the full 8-byte string descriptor
for a `string` argument instead of a single scalar byte. New VM opcode
`Op.stringSliceEqual` (justified): the existing `Op.sliceEqual{1,4}` compares
the 16-byte native-pointer descriptor used by dynamic arrays and dereferences
the first word as a host address, but a string descriptor is the 8-byte
`{uint dataOffset, uint length}` form into the read-only data segment, so the
two layouts are incompatible; `stringSliceEqual` compares two such descriptors
against `program.data`. Greened `switch.stringCases`. control_flow failures:
17 → 16. No regressions across the full `bin/ut --random` suite.

### Failure mode 6: function-pointer `&f` address expression and
static-local declaration not lowered (3 tests)

**Root cause — `& first` / `& bAB` (2 tests):** `callCanEnterFunctionWithCallee`
and `dispatchesToDistinctCallees` use `int function() fp = &first;` where
`first` is a free function. `compileExpression` has no branch for `AddrExp`
whose operand is a free function (only `tryAddressOfElement` and
`tryAddressOfLocal` are attempted, both returning `null` for a function
reference, and `tryAddressOfSymbol` handles `SymOffExp` but not a plain
function variable). The error is `Unsupported expression in bytecode core:
& first`.

**Root cause — static nested function (`hashCollisionUsesCorrectCallee`):**
The fixture declares `static int bAB() { ... }` and `static int a_a() { ...
}` inside the unittest body. DMD lowers these as nested functions with
`isStatic` set. The compiler encounters the `FuncDeclaration` as a
declaration statement in the function body and throws
`Unsupported declaration in bytecode core: static pure nothrow @nogc @safe
int bAB() { ... }`.

**Failing tests (3):**
- `functionPointer.callCanEnterFunctionWithCallee` — `& first`
- `functionPointer.dispatchesToDistinctCallees` — `& bAB`
- `functionPointer.hashCollisionUsesCorrectCallee` — static nested function
  declaration

**Oracle behavior:** `int function() fp = &f;` stores a callable function
pointer; `fp()` dispatches through it. The VM dispatches correctly when two
function pointers hash to the same slot.

**Required implementation (medium — new local kind):** Three sub-items:

1. **Static nested function declarations:** Add a
   `DeclarationStatement` branch (or extend the existing one) to handle nested
   `FuncDeclaration` nodes with `isStatic`. Register the function in the
   compiler's function table (as `registerFunction` does for callees) so
   subsequent `&f` and `f()` calls can resolve it. No closure environment
   needed (static nested functions don't capture).
2. **`&f` function address expression:** Extend `compileExpression` to
   handle `AddrExp` of a `FuncDeclaration` operand (or a `VarExp` holding a
   function symbol). Emit a new frame slot holding a function-pointer value: a
   `size_t`-wide slot storing the VM function index (or a sentinel for the
   dispatch table). Add `ScalarType.funcPtr_` or reuse `ulong_` with a
   function-pointer local registry, whichever is simpler.
3. **Indirect call dispatch:** Extend `compileCall` to handle a `CallExp`
   whose target is a function-pointer local (or variable) rather than a named
   `FuncDeclaration`. The VM opcode for indirect call must look up the callee
   by the stored function index; the hash-collision test verifies that two
   distinct function pointers with the same Bernstein hash dispatch to different
   callees.

**Dependency:** None (independent of modes 1–5).

**DONE:** `&f` (`AddrExp`/`SymOffExp` over a `FuncDeclaration`) compiles to a
size_t slot holding the callee's VM function index (`functionPointer` registers
the function for lazy compilation). A `int function()` local takes the existing
pointer-declaration path. Static nested `FuncDeclaration`s in a `DeclarationExp`
are a codegen no-op (body compiled lazily on first `&f`/call). DMD lowers `fp()`
as `(*fp)()`; `compileIndirectCall` reads the index from the pointer slot and
emits the new `callIndirect` opcode (justified: `call` hard-codes the callee
index in the operand, so run-time dispatch needs a variant that reads it from a
frame slot; the machine shares the `call` body via the resolved index).
Function-pointer calls with arguments are rejected (no test; layout is only
known at run time). All 3 tests pass; control_flow BytecodeNewCore failures
13→ remaining belong to other modes (try-catch/finally goto, utf string
decode, mode-7 lambdas/cast). No regressions under `bin/ut --random`.

### Failure mode 7: delegate/closure and `this.field` capture not supported
(2 tests) and int-to-float cast from call result missing (1 test)

**Root cause — `nestedLambdaReadsEnclosingThisField` (1 test):** The struct
method `readThroughNestedLambda` declares `auto nested = () => value;` where
`value` is `this.value`. The lambda captures `this` by reference (DMD lowers
it as a delegate with an environment pointer). The compiler hits
`Unsupported type in bytecode core: int delegate() pure nothrow @nogc @safe`
when trying to declare the `nested` local.

**Root cause — `nestedLambdaIifeReadsEnclosingThisField` (1 test):** The
IIFE form `(() => value)()` is called immediately. The compiler does not
encounter the delegate local but compiles the nested lambda body, which
accesses `this.value` via a `DotVarExp` on an implicit `ThisExp`. It throws
`Unsupported expression in bytecode core: this.value`.

**Root cause — `overloadResolutionBySignature` (1 test):** The fixture calls
`double d = seed;` where `seed()` returns `int`. DMD inserts
`cast(double)seed()`. The new core's numeric cast handler only handles
scalar-to-scalar integer widening/truncation and int/float literal paths; a
`CastExp` whose sub-expression is a `CallExp` returning `int` is rejected as
`Unsupported numeric cast in bytecode core: cast(double)seed()`. This is a
narrow missing case in the existing cast lowering, not a new feature area.

**Failing tests (3):**
- `function.nestedLambdaReadsEnclosingThisField` — delegate type unsupported
- `function.nestedLambdaIifeReadsEnclosingThisField` — `this.value` in
  nested lambda body
- `function.overloadResolutionBySignature` — `cast(double)callResult()`

**Required implementation:**

- **`cast(double)intExpr` where `intExpr` is a call result (small):** Extend
  the numeric cast path to allow any int-typed expression as the source, not
  just scalar locals. The operand from `compileExpression(cast_.e1)` already
  carries its `ScalarType`; the cast dispatch just needs to accept non-local
  operands (call result temporaries) as the source.
- **Nested lambda / delegate and `this.value` access (large):** Full closure
  support requires: (a) the delegate local type (`ScalarType.delegate_` or a
  new tracked local kind holding a `{funcPtr, envPtr}` pair); (b) emitting the
  lambda body as a compiled function capturing `this` via the environment
  pointer; (c) lowering `this.field` inside the nested lambda body through the
  captured `this` pointer. This is the leading edge of the Closures section in
  the plan (see "## Closures"). The IIFE form additionally needs the compiler
  to recognize and immediately call an inline delegate literal, which exercises
  the same machinery.

**Dependency:** The `cast(double)callResult()` fix is independent and small
(sub-item of the cast path). The delegate/closure items depend on
the struct field-through-pointer machinery already present for `new Struct`
heap pointers.

**DONE (mode 7).** All 3 green; control_flow failures 13 → 10 (remaining are
mode 4 catch/try-finally and mode 9 utf foreach only).

- `cast(double)intExpr` (`overloadResolutionBySignature`): the cast path already
  materialised any rvalue (call result) into a temp via `compileExpression`; the
  real gap was no int→double conversion opcode (the task's "scalar-local-only"
  framing was inaccurate — only `double→int` existed). Added `convertIntToDouble`
  (a: dest double, b: source int, c: source byte width OR'd with
  `unsignedConvertFlag` for unsigned sources) and an `integerToDouble` machine
  helper dispatching on width and signedness, so e.g. a `uint` with the high bit
  set converts to a positive double. New cast branch fires on
  `!isFloating(source) && target==double_`.
- Delegate/closure (`nestedLambda*`). DMD lowering, verified live: the lambda is
  a `FuncLiteralDeclaration` (tok `delegate_`, isNested), `vthis=__capture` typed
  `void*`, no explicit parameters. Inside the body `this.value` is a `DotVarExp`
  over a bare `ThisExp` whose `.var` is identity-equal to the ENCLOSING method's
  `vthis` (DMD resolves the captured field to the enclosing `this`, not to
  `__capture`). The only captured entity is the enclosing `this`, so the
  delegate context pointer is simply the enclosing `Holder` address — there is no
  intermediate closure/frame struct, despite `__capture` being typed `void*`.
  The named init is a `FuncExp` (op `function_`), NOT a `DelegateExp`.
- Implementation: model the capturing lambda as if it were a method of the
  enclosing struct. `thisStructDeclaration` now returns the enclosing struct for
  such a lambda (`capturedThisStructDeclaration` via `toParent2().isThis()`), so
  `parameterLayout`/`compileFunctionBody` give it the ordinary hidden `this`-block
  ref-parameter and `this.field` resolves through the existing `_thisLocal`
  receiver path — no new ThisExp handling needed. The delegate value is a 16-byte
  `{functionIndex, context}` pair (`DelegateLocal`); context is the enclosing
  method's `this` receiver frame offset. `nested()` dispatches via the existing
  `callIndirect` (index word) after copying the context word into the lambda's
  `this`-block slot, so the machine's ref-parameter loop carries `this` in/out
  unchanged. The IIFE `(() => this.f)()` needs no delegate value: `call.f` is the
  lambda, so it flows through the normal direct-call path; only
  `methodReceiverOffset` gained a FuncExp branch yielding the enclosing
  `_thisLocal.offset`. No new opcode for the delegate path (reuses `callIndirect`
  and the receiver/ref ABI); Mode 9's inline-delegate call can reuse
  `compileDelegateCall`.

### Failure mode 8: `foreach_reverse` over a dynamic array has an
off-by-one in the loop counter (1 test)

**Root cause:** `foreach.reverseIntArrayVisitsBackToFront` iterates
`foreach_reverse (x; arr)` where `arr = [1,2,3]`. DMD lowers this to a
`ForStatement` whose condition uses the post-decrement `arr.length--`-style
pattern (the loop variable is initialized to `arr.length` and the condition
checks `i-- > 0` with the post-decrement as a `PostExp` whose `e2` is `-1`).
The `compilePostIncrement` handler in `compiler.d` always uses `Op.addInt4`
(or `addInt8`) applied with the `post.e2` operand. For `i--`, `post.e2` is
`-1` as a signed literal. The add with `-1` is correct for signed types but
the loop counter is `size_t` (ulong). The emitted comparison
(`i-- > 0` on a `ulong_` slot) has an off-by-one: on the iteration where
the post-decrement returns `0` before decrementing to `ulong.max`, the loop
exits correctly; but the array index used *inside* the body is the
*post-decremented* counter value (the pre-decrement value was 0, so the
decremented slot is now `ulong.max`, which wraps to a huge index). The
runtime reports `index [4] is out of bounds for array of length 3` because
the wrapped counter reads an out-of-range slot in the visited array during
`visited ~= x`.

The fix is narrow: the post-decrement path in `compilePostIncrement` should
use `Op.subInt8` (not `Op.addInt8`) when `post.e2` is the literal `-1`
(or equivalently, detect `TOK.minusMinus` and emit subtract-1). Alternatively,
confirm the exact DMD lowering and fix the comparison/index pair. This is a
single-opcode selection fix with no new VM opcode needed.

**Failing test (1):** `foreach.reverseIntArrayVisitsBackToFront`

**Required implementation (small — opcode selection fix):** In
`compilePostIncrement`, detect when `post.op == TOK.minusMinus` (or when
`post.e2` is a negative constant) and emit `Op.subInt8`/`Op.subInt4` instead
of `addInt8`/`addInt4`. Alternatively, separate `compilePostDecrement` as a
mirror of `compilePostIncrement` with the subtract opcodes.

**Dependency:** None (independent, self-contained fix).

- DONE: `PostExp.e2` is always literal `1` (not `-1` as analysis guessed);
  `post.op` is what distinguishes `++`/`--`. Fixed `compilePostIncrement` to
  emit `subInt8`/`subInt4` when `post.op == EXP.minusMinus`, else
  `addInt8`/`addInt4`. `reverseIntArrayVisitsBackToFront` green; control_flow
  31→30 failures, no regressions across full suite.

### Failure mode 9: `_aApply*` druntime UTF-string iteration lowering not
supported (4 tests)

**Root cause:** `foreach` over a UTF string (`string`, `wstring`, or
`dstring`) where the loop variable has a different code-unit width is lowered
by DMD to a `_aApplycd1`/`_aApplydc1`/`_aApplywd1`/`_aApplyRwd1` druntime
call (the `foreach`/`foreach_reverse` aggregate-apply family). These are
external native functions (no available source body), so `compileCall`
reports `Unsupported call in bytecode core: _aApplywd1(...)`.

**Failing tests (4):**
- `foreach.utf8StringDecodesDchars` — `_aApplycd1` (char→dchar)
- `foreach.utf32StringEncodesAsUtf8WhenIteratingChar` — `_aApplydc1`
  (dchar→char)
- `foreach.reverseUtf16String` — `_aApplyRwd1` (wchar→dchar, reverse)
- `foreach.utf16StringDecodesDchars` — `_aApplywd1` (wchar→dchar)

**Oracle behavior:** Iterating a UTF string with mismatched element/variable
widths decodes code points via druntime's `_aApply*` family, passing a
delegate for each decoded character. The VM must execute the loop body via
the delegate on each call.

**Required implementation (medium — druntime hook interception):** Intercept
the `_aApply*` call family at the `compileCall` level (matching by mangled
prefix or by `FuncDeclaration.ident.toString`). Implement each variant as a
VM-native loop: iterate the source string's code units, decode to the target
width (UTF-8/16/32 decode), call the delegate (the `CallExp`'s last argument)
with the decoded value, and stop if the delegate returns non-zero. The
delegate argument is a literal inline closure whose body is the `foreach`
loop body; the compiler must already be able to emit and call a simple
no-capture delegate body (this is adjacent to mode 7 but requires only a
one-shot call, not a stored delegate local).

**Dependency:** Partial dependency on mode 7 (delegate call mechanism). The
`_aApply*` delegate is always an inline literal, not a stored variable, so
a simplified inline-delegate-call path may be sufficient without full closure
support.

- DONE: the delegate is a real nested `__foreachbody_*` FuncDeclaration with a
  `__capture` `vthis` capturing the body's enclosing local (`chars`), not a bare
  no-capture lambda — so the delegate was *inlined* at the apply site rather than
  called: its single `ref` param is bound to a fresh frame slot the body reads as
  an ordinary local, and the captured local resolves to the enclosing local
  directly (same VarDeclaration). Top-level `return` in the inlined body becomes a
  conditional loop exit (nonzero = `break`), tracked via `_applyBodyExits`.
  `compileStringForeachApply` emits a new `transcodeUtf` opcode (mode in operand
  b: `utf8ToDchar`/`utf16ToDchar`/`dcharToUtf8`/`utf16ToDcharReverse`) that decodes
  the source slice into a fresh heap dchar/char block mirroring the interpreter's
  helpers byte-for-byte, then a `for (i; i < len; ++i)` loop loading each element
  and running the inlined body. Three representation gaps surfaced and were fixed:
  (1) runtime heap strings — a `string`/`wstring`/`dstring` initialised from
  `.idup`/`.dup` is a 16-byte `{ptr,length}` heap descriptor, not an 8-byte
  data-segment slice, so such locals are now stored as dynamic-array locals (char/
  wchar/dchar element); (2) `wchar` (2-byte) array elements were mapped to the
  4-byte append/dup opcodes, so `appendElement2`/`dupArray2` were added to pack
  them correctly; (3) `zeroExtend2to4` was added for `wchar`->`dchar` widening (a
  `'é'`-style wchar literal compared against a `dchar`). A latent bug was
  also fixed: `allocateBytes` with alignment 0 (a `cast(void)expr` result slot,
  which the foreach lowering emits to discard the apply's int result) masked
  `_frameOffset` to 0 via `& ~(alignment-1)`, rewinding the frame over live
  locals; alignment 0 is now clamped to 1 and `frameSize` derives from a peak
  high-water mark. New opcodes: `transcodeUtf`, `appendElement2`, `dupArray2`,
  `zeroExtend2to4` (each justified by a concrete fixture need above). All 4 tests
  green; control_flow 10->6 failures (only the Mode 4 try-catch tests remain); no
  regressions across the full suite (2572 run, 6 failed = the expected Mode 4
  set) under random ordering.

### Summary and dependency order

The 36 failures map to 9 failure modes (one mode per concern). Implementation
order respects dependencies:

1. **Break/Continue lowering** (mode 1) — 7 tests, small. Prerequisite for
   modes 2 and 3.
2. **Do/UnrolledLoop lowering** (mode 2) — 2 tests (overlap with mode 1),
   small. After mode 1.
3. **SwitchStatement lowering** (mode 3) — 11 tests, large. After mode 1.
4. **TryCatch + finally-on-goto** (mode 4) — 4 tests, medium. After modes 1
   and 3.
5. **String switch selector** (mode 5) — 1 test, small. After mode 3.
6. **Function-pointer `&f` and static nested functions** (mode 6) — 3 tests,
   medium. Independent (no prior-mode dependency).
7. **Delegate/closure + `this.field` capture; int-to-float call-result cast**
   (mode 7) — 3 tests (2 large/closure, 1 small/cast). The cast fix is
   independent; the closure items depend on the struct heap-pointer machinery
   already present.
8. **`foreach_reverse` post-decrement off-by-one** (mode 8) — 1 test, small.
   Independent.
9. **`_aApply*` UTF string iteration** (mode 9) — 4 tests, medium. Partial
   dependency on mode 7 (delegate call mechanism).

**Size classification:**
- Small (single opcode / narrow compiler fix): modes 1, 2, 5, 8; cast
  sub-item of mode 7.
- Medium (new call-site interception or pointer machinery): modes 4, 6, 9.
- Large (new statement family): mode 3; closure sub-items of mode 7.

All 9 modes are implemented. The focused run passes with 67 tests run and 0
failures:

```sh
./bin/ut $(./bin/ut -l | \
    rg '^ut\\.backends\\.runner\\.ct\\.control_flow\\..*\\.BytecodeNewCore$')
```

## exceptions.d Promotion Analysis (BytecodeNewCore)

All SystemLinker-backed tests from
`tests/ut/backends/runner/lang/exceptions.d` have been promoted to include
`BytecodeNewCore` in their `AliasSeq` blocks. The Ctfe-only characterization
tests remain Ctfe-only because their diagnostic text intentionally diverges
from compiled-code behaviour.

The first focused BytecodeNewCore-only run covered 26 promoted tests. Eleven
already passed. The remaining failures grouped into these implementation
gaps:

1. Named catch variables did not expose `msg` or chained `next.msg`.
2. Throws only supported `throw new Exception("literal")`; `throw e`, derived
   exception classes, `Error`, and constructor-backed objects were missing.
3. Catch handling assumed a single catch clause and did not match by dynamic
   class.
4. Exception unwinding discarded intermediate frames without scalar `ref`
   parameter writeback.
5. Explicit `return` skipped active `finally` bodies and did not snapshot the
   return value before the finalbody could mutate referenced state.
6. Throw exits from a `try/finally` body skipped the finalbody, and finalbody
   throws did not preserve D's body-exception chaining order.

The new core now records class metadata and catch clauses in `Program`, lowers
try/catch as handler groups, matches thrown dynamic classes through their base
chain, and supports `throwObject` for rethrow and constructed class objects.
Named catch variables bind a lightweight object pointer plus compact bytecode
string descriptors for `msg` and `next.msg`, matching the backend's existing
string ABI. Object throws reuse the same compact descriptors, so `e.msg`,
`e.msg.length`, and `e.msg == "literal"` agree with compiled D behaviour.

Unwinding now writes back discarded frames' scalar `ref` parameters before
resuming at a handler. Return lowering materialises and snapshots non-void
results before running active finalbodies, then returns the saved slot.
Throw lowering re-emits active finalbodies on throw exits; if a finalbody throws
while an existing body throw is pending, the body exception remains the caught
exception and the finalbody message is chained as `next`, matching
`SystemLinker`.

Final focused verification:

```sh
ninja bin/ut
bin/ut $(bin/ut -l | \
    rg '^ut\\.backends\\.runner\\.ct\\.exceptions\\..*\\.BytecodeNewCore$')
```

Result: 26 tests run, 0 failed.

## expressions.d Promotion Analysis (BytecodeNewCore)

All SystemLinker-backed tests from
`tests/ut/backends/runner/lang/expressions.d` have been promoted to include
`BytecodeNewCore` in their `AliasSeq` blocks. CTFE-only characterization
tests remain CTFE-only.

Focused verification was run with:

```sh
ninja bin/ut
bin/ut $(bin/ut -l | \
    rg '^ut\\.backends\\.runner\\.ct\\.expressions\\..*\\.BytecodeNewCore$')
```

The first focused run covered 55 promoted tests. Twenty tests already pass,
one test is an expected failure, and 35 fail. The failures group into these
implementation gaps:

1. Integer expression coverage is incomplete: `%`, `&`, `^`, `~`, `>>`,
   `>>>`, `|=`, and cast-shaped compound assignment on a narrow integer are
   not lowered by the new core. The integer power test also fails before the
   lowered helper body can run.
2. Mixed numeric conversion and comparison semantics are incomplete: runtime
   `int` to `float`, high-bit `ulong` to `double` comparison, integer/floating
   equality, and 64-bit integer literal/sign handling do not yet match
   compiled D.
3. Pointer, slice, and hex-string casts need expression-level support:
   address-of dynamic-array elements, `$` in slice bounds, slice-to-pointer,
   array pointer round trips through `void*`, pointer-to-bool truth, void
   pointer storage, and `x"..."` to `ushort[]`.
4. Heap allocation and dynamic-array fields need pointer-shaped aggregate
   support: `new int(seed)`, `Holder*` locals, `ubyte[]`/`int[]` fields in
   heap structs, and dynamic-array field length/ptr-slice operations.
5. Runtime class and interface behaviour is still incomplete for this module:
   virtual dispatch currently calls the base method, interface dispatch is
   unsupported, expression `typeid(value) is typeid(Child)` is unsupported,
   and `typeid(T).name` reaches a string equality assertion that the scalar
   compare path cannot lower.
6. Delegates and function pointers are not expression-complete: nested
   delegate initialization, struct-member delegate initialization, `dg.ptr`,
   and `dg.funcptr` all fail before matching compiled-D behaviour.
7. Complex and vector expressions remain unsupported: `cdouble` values,
   vector scalar splat reification through `vector.array`, and the integer
   `^^` lowering need dedicated support.

Worker assignments should keep the promoted tests in place, make the smallest
honest backend changes, and rerun only
`ut.backends.runner.lang.expressions.*.BytecodeNewCore` after each fix.

Completed implementation:

- Integer expressions now cover signed remainder, shifts including `>>>`,
  bitwise `&`/`^`/`~`, local integer compound assignments including narrow
  store wraparound, and the integer helper lowering behind `^^`.
- Numeric conversion/comparison now covers runtime `int` to `float`,
  high-bit `ulong` to `double`, integer/floating equality by numeric value,
  and 64-bit integer literal/sign handling.
- Pointer, slice, and heap aggregate support now covers address-of dynamic
  array elements, `$` slice bounds, slice-to-pointer, `void*` round trips,
  pointer-to-bool diagnostics, hex-string-to-`ushort[]`, `new int(seed)`, and
  heap struct dynamic-array fields.
- Class/interface/typeid support now covers dynamic virtual dispatch,
  interface dispatch, expression `typeid` dynamic-class identity, and
  compiled-D `typeid(T).name` behaviour.
- Delegate support now covers nested function delegates with captured locals,
  struct member delegates with receiver context, `dg.ptr`, and `dg.funcptr`.
- Complex/vector support now covers the promoted `cdouble` literal/addition
  and `.re`/`.im` reads, plus scalar splat to `__vector(int[4])` and
  `.array` as an inline static-array block.

Final focused verification:

```sh
ninja bin/ut
bin/ut $(bin/ut -l | \
    rg '^ut\\.backends\\.runner\\.ct\\.expressions\\..*\\.BytecodeNewCore$')
```

Result: 55 tests run, 0 failed, 1/1 failing as expected.

## cerealed.d Promotion Analysis (BytecodeNewCore)

All SystemLinker-backed tests from
`tests/ut/backends/runner/lang/cerealed.d` were evaluated for promotion to
`BytecodeNewCore`. All 23 SystemLinker-backed promotion candidates now include
`BytecodeNewCore` in their `AliasSeq` blocks. CTFE-only characterization tests
remain CTFE-only.

Focused verification was run with:

```sh
ninja bin/ut
bin/ut $(bin/ut -l | \
    rg '^ut\\.backends\\.runner\\.ct\\.cerealed\\..*\\.BytecodeNewCore$')
```

The first focused run covered 23 promoted tests. Eight tests already pass:
`dynamicArrayAppenderPreservesRuntimeByte`, `refCursorReadAdvancesPosition`,
`postIncrementCursorReadAdvancesPosition`, `decodeBoolReadsSequentialBytes`,
`roundTripBoolBytes`, `roundTripBoolExhaustionReportsBoundsDiagnostic`,
`decodeBoolExhaustionReportsBoundsDiagnostic`, and
`templateLengthPrefixUsesRequestedWidth`. The remaining 15 failures group into
these implementation gaps:

1. Function returns and assertion operands do not yet materialize every
   aggregate-shaped local needed by project-shaped fixtures. This shows up as
   unsupported variables such as `encoded`, `bytes`, and DMD-generated
   `__assertOp*` temporaries in array-return and equality checks.
2. Dynamic and static array types are not accepted in all call signatures,
   local declarations, and return-value paths used by this module. Failures
   report unsupported `ubyte[]` and `int[2]` types even though narrower array
   behaviours from `arrays.d` already pass.
3. Compound shift assignment is missing for the decoder accumulation pattern:
   `intValue <<= 8` currently fails before the promoted bounds diagnostic can
   reach the compiled-oracle `ArrayIndexError` text.
4. Nested aggregate and associative-array shapes remain incomplete:
   recursive `Nested[int]`, `Unit[]` packet fields, and AA-backed static class
   registries fail as unsupported aggregate or AA operands.
5. The project-shaped class registry test needs static AA storage, classinfo
   name lookup, delegate values stored in an AA, and invocation of the stored
   delegate with a `ref` struct receiver.

Worker assignments should keep the promoted tests in place, make the smallest
honest backend changes, and rerun only
`ut.backends.runner.lang.cerealed.*.BytecodeNewCore` after each fix.

Current focused checkpoint after the static child-registry slice:

- 22 `BytecodeNewCore` promotion candidates were run; 22 pass and remain
  promoted. `nestedStructWritesAssociativeArrayChild` was promoted after
  confirming it was SystemLinker-backed and excluded only `BytecodeNewCore`.
- The required red focused run for
  `nestedStructWritesAssociativeArrayChild.BytecodeNewCore` failed with
  `Unsupported expression in bytecode core: [7:Nested(null)]`.
- Aggregate-shaped returns, dynamic-array descriptors, static-array by-value
  parameters, and compound shift assignment are partially implemented.
- `inputRangeWritesLengthAndValues` now passes after reserving enough hidden
  struct-receiver argument bytes for small receivers and supporting DMD's
  casted narrow-field compound assignment form, `cast(int)this.current += 1`.
- `staticArrayRoundTripOmitsLengthPrefix` now passes after ordinary
  dynamic-array descriptor paths learned to materialize static arrays, including
  `foreach (ref value; values)` write-back through DMD-generated slice temps.
- `protocolUnitLengthFieldRoundTrip` now passes after struct identity learned
  descriptor-based comparison for dynamic-array fields and dynamic-array
  struct elements were materialized consistently.
- `nestedStructWritesAssociativeArrayChild` now passes after the compiler
  learned to materialize AA literals as handle operands, initialize AA fields in
  struct literals, treat AA field expressions as handle-typed operands, and
  inline DMD's `_d_aaApply2` lowering for `foreach (key, value; aa)` over the
  VM-owned AA maps. The machine remains on the narrow existing `int[int]`
  storage shape; for this recursive `Nested[int]` case the stored value is the
  child AA handle.
- `classSerialisationReadsStaticChildRegistry` was promoted after confirming it
  was SystemLinker-backed and excluded only `BytecodeNewCore`. The required red
  focused run failed with
  `Unsupported associative array operand in bytecode core: childWriters`.
  The new core now recognizes the static `childWriters` registry shape used by
  the fixture, records the delegate literal assigned into it, invokes the
  recorded delegate for `childWriters[key](this, object)`, accepts class
  parameters as pointer-shaped values, tolerates the `object.classinfo.name`
  string-key path needed by this registry lookup, preserves class object
  pointers through DMD's lowered class-cast dereference, and writes back `ref`
  struct parameters so the delegate mutation of `Writer.bytes` reaches the
  caller.
- `tests/ut/backends/runner/lang/cerealed.d` is now complete on
  `BytecodeNewCore`: the focused run covers 23 tests with 0 failures.

Focused command:

```sh
bin/ut $(bin/ut -l | \
    rg '^ut\\.backends\\.runner\\.ct\\.cerealed\\..*\\.BytecodeNewCore$')
```

## repl.d Promotion Checkpoint (BytecodeNewCore)

The existing `repl.backend.characterScalarDisplayCollapsesToCharLiteral`
backend-matrix family now includes `BytecodeNewCore`. This was a stale
coverage promotion from old `Bytecode`; no production changes were needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.\
characterScalarDisplayCollapsesToCharLiteral.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The adjacent nullable-field struct-display REPL family now includes
`BytecodeNewCore`:

- `nullFunctionPointerFieldRendersAsNull`
- `nullDelegateFieldRendersAsNull`
- `nullClassFieldRendersAsNull`
- `nullPointerFieldRendersAsNull`
- `nestedStructOmitsSyntheticContextField`

This was not stale coverage. The promotion exposed that struct display metadata
treated every non-scalar field as making the whole struct undisplayable, and
that null delegate fields in struct literals still fell through to unsupported
scalar lowering. `BytecodeNewCore` now records scalar fields, nullable one-word
fields (raw pointers, function pointers, and class references), and nullable
delegate fields separately. Reification renders only all-zero nullable fields
as `null`; non-null nullable fields remain `<undisplayable>` until pointer,
class, function-pointer, and delegate value display is implemented. DMD's
synthetic nested-struct context field is omitted from display metadata.

Review follow-up for PR #343: replace the new enum-reification `ResultType`
literals with named factories on `ResultType`, and generate the scalar enum
lookup switch arms from D type names with string mixins. This keeps the
metadata intent visible at the call sites while preserving the promoted REPL
enum-display behaviour.

All remaining narrow `tests/ut/bin/repl.d` backend rows were attempted on
`BytecodeNewCore` in one sweep. The passing promotions retained in the matrix
are:

- `numericScalarDisplayUsesDLiteralSuffixes`
- `runLoadedUnittestBlocks`
- `runLoadedTestsWithNothingLoadedReturnsVoid`
- `loadedUnittestFailuresReportReplLocation`
- `laterLoadedUnittestFailuresReportReplLocation`
- `runLoadedTestsReportsEveryFailedUnittest`
- `runLoadedFileUnittestBlocks`
- `loadedSourceDoesNotAdvanceTypedReplLocations`
- `loadedFileUnittestFailuresReportFileLocation`
- `loadModuleFileErrorsHideSyntheticNames`
- `runtimeErrorsReportOneDiagnostic`
- `duplicateDeclarationsHideSyntheticNames`
- `failedModuleNoDisplayCellsDoNotPoisonSession`
- `syntaxErrorsHideWrapperInternals`
- `diagnosticsHideSyntheticWrapperNames`
- `functionCallMismatchShowsCandidateSignature`
- `functionCallMismatchShowsOverloadSignatures`

No production changes were needed. The focused `BytecodeNewCore` REPL run now
covers 50 tests:

```sh
ninja bin/ut
bin/ut $(bin/ut -l | \
    rg '^ut\\.bin\\.repl\\..*\\.BytecodeNewCore$')
```

Result: 50 tests run, 0 failed.

The full attempted sweep initially ran 67 `BytecodeNewCore` REPL tests and
exposed 17 failures. These were investigated and left unpromoted because they
require broader backend work:

- `moduleLevelVariablesAreVisibleToFunctions` fails on assignment to a
  module-level variable (`Unsupported assignment in bytecode core`).
- `importStdExposesPhobosSymbols`, `displaysFiniteRangeResults`, and
  `displaysFilteredArrayResults` require broader Phobos range/ref-argument
  support.
- `displaysAssocArrayResults` and `assocArrayWithStructValuesRendersEntries`
  need associative-array result reification for display.
- `displaysEnumValues` currently reifies enum values as their underlying
  integers, not qualified enum member names.
- `expressionCtfeErrorsReportDiagnostics` expects the CTFE/Interpreter
  bounds diagnostic; `BytecodeNewCore` reports the VM bounds diagnostic.
- `runtimeOnlyCellsUseResidentNativeCalls` and
  `runtimeOnlyFileOpenReportsNativeBoundary` are Interpreter-native-boundary
  behaviours; `BytecodeNewCore` still reports missing CTFE/native support in
  this REPL path.
- The struct display family (`structValueRendersTypeNameAndFields`,
  `arrayOfStructsRendersEachElement`, `nullFunctionPointerFieldIsOmitted`,
  `nullDelegateFieldIsOmitted`, `nullClassFieldRendersAsNull`,
  `nullPointerFieldRendersAsNull`, `nestedStructOmitsSyntheticContextField`)
  needs richer struct result metadata/reification before the display renderer
  can produce field-level output.

The existing `repl.backend.wholeFloatingScalarDisplayKeepsDecimalPoint`
backend-matrix family now includes `BytecodeNewCore`. This was the adjacent
stale scalar-display promotion from old `Bytecode`; no production changes were
needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.\
wholeFloatingScalarDisplayKeepsDecimalPoint.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The existing `repl.backend.runLoadedTestsWithNothingLoadedReturnsVoid`
backend-matrix family now includes `BytecodeNewCore`. This was the next narrow
REPL test-command promotion after no-display cells; no production changes were
needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.\
runLoadedTestsWithNothingLoadedReturnsVoid.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The existing `repl.backend.displaysStringValues` backend-matrix family now
includes `BytecodeNewCore`. This was the adjacent narrow string-display
promotion after the scalar display rows; no production changes were needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.displaysStringValues.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The existing `repl.backend.typeofCellsDisplayTypeName` backend-matrix family
now includes `BytecodeNewCore`. This was the next narrow display-family
promotion after the string display row; no production changes were needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.\
typeofCellsDisplayTypeName.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The existing `repl.backend.typeAliasCellsDisplayTypeName` backend-matrix
family now includes `BytecodeNewCore`. This was the adjacent narrow type-cell
display promotion after `typeofCellsDisplayTypeName`; no production changes
were needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.\
typeAliasCellsDisplayTypeName.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The existing `repl.backend.specialTokenValuesHideWrapperInternals`
backend-matrix family now includes `BytecodeNewCore`. This was the next narrow
REPL display hygiene promotion after the type-cell display rows; no production
changes were needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.\
specialTokenValuesHideWrapperInternals.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The existing `repl.backend.noDisplayCellsReturnVoid` backend-matrix family now
includes `BytecodeNewCore`. This was the next narrow REPL no-display-cell
promotion after display hygiene; no production changes were needed.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.noDisplayCellsReturnVoid.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

The coherent Phobos/range REPL block was attempted on `BytecodeNewCore` and
left unpromoted:
`repl.backend.importStdExposesPhobosSymbols`,
`repl.backend.displaysFiniteRangeResults`, and
`repl.backend.displaysFilteredArrayResults`. The red promotion confirms the
range/ref-argument gap is still real. `importStdExposesPhobosSymbols` fails in
the bytecode REPL path with `Unsupported ref argument in bytecode core:
result[cnt]`, `displaysFilteredArrayResults` fails with `Unsupported type in
bytecode core: Result`, and `displaysFiniteRangeResults` produces no display
output instead of `MapResult([1, 2, 3])`.

The smaller associative-array display REPL block was also attempted on
`BytecodeNewCore` and left unpromoted:
`repl.backend.displaysAssocArrayResults`. The red promotion shows that the
backend currently reifies/displays only the first key as `1UL`, producing
`["1UL"]` instead of the oracle output `["[1:10, 2:20]"]`.

The existing `repl.backend.expressionCellsUsePreludeFormatter` backend-matrix
family was attempted on `BytecodeNewCore` and left unpromoted. The red
promotion confirms the struct display gap is still real in this row too:
`Point(1, 2)` produces no REPL output (`[]`) instead of the oracle display
`["Point(1, 2L)"]`.

The minimal simple-struct display slice is now implemented for
`BytecodeNewCore`: struct result metadata records the struct type name plus
scalar field offsets/types, and reification builds the existing
struct `Value` shape from the returned byte block, using D-literal field
display for REPL output. Non-scalar fields intentionally do not get display
metadata in this slice. The existing
`repl.backend.expressionCellsUsePreludeFormatter` and
`repl.backend.structValueRendersTypeNameAndFields` rows now include
`BytecodeNewCore`.

The existing `repl.backend.arrayOfStructsRendersEachElement` backend-matrix
family now includes `BytecodeNewCore`. This focused REPL promotion extends the
simple-struct display slice to dynamic-array elements: result metadata records
scalar-field display information for struct element types, and reification
renders each element from its native-layout byte block.

Focused verification was run with:

```sh
ninja bin/ut
test_name=ut.bin.repl.repl.backend.\
arrayOfStructsRendersEachElement.BytecodeNewCore
bin/ut "$test_name"
```

Result: 1 test run, 0 failed.

Checkpoint close-out, 2026-07-07: display-row promotion in this checkpoint
is paused per the re-scoped "REPL parity continuation" section. The rows
promoted above stay green as part of the ratchet, but the unpromoted
display rows (`displaysFiniteRangeResults`, `displaysFilteredArrayResults`,
`displaysAssocArrayResults`, and the remaining struct/enum display gaps)
are re-earned in slice 11 by executing the prelude formatter, not by
extending `ResultType`/`reify.d` display metadata. The non-display failures
from the sweep (`moduleLevelVariablesAreVisibleToFunctions`, Phobos
import/range/`ref`-argument execution) are this track's language-feature
backlog — see "Post-Flip Backlog".

Module-level scalar assignment first rung, 2026-07-07: the new core now
allocates VM-owned mutable module data for scalar `VarDeclaration`s, emits
module load/store bytecode for direct reads and writes, and keeps non-scalar
module storage unsupported. The promoted
`repl.backend.moduleLevelVariablesAreVisibleToFunctions.BytecodeNewCore`
row is green, as are `ninja bin/ut` and `bin/ut --random` with seed
`2143207206`.

Diagnostics-hygiene probe, 2026-07-07:
`repl.backend.expressionCtfeErrorsReportDiagnostics` now covers
`BytecodeNewCore` with compiled-style array bounds text. The prior probe
showed the existing `Ctfe`/`Interpreter` row expects `array index 99 is out of
bounds` with `[0..3]`, while `BytecodeNewCore` reports `index [99] is out of
bounds for array of length 3`. That wording matches the
`SystemLinker`/compiled-D array diagnostic style already pinned in
`tests/ut/backends/runner/lang/arrays.d`, so the CTFE wording stays as a
CTFE/tree-walker characterization and the new-core row uses the compiled
oracle text. No production change was needed.

Slice 8 native-runtime first rung, 2026-07-08: current-master frontier
verification found backlog item 1 already green (`moduleLevelVariables...`,
`importStdExposesPhobosSymbols`, and the promoted `int[int]` AA execution
family), so the next red rung was `sys/cstdlib.d`'s existing
SystemLinker-backed `atoi.value` row on `BytecodeNewCore`. The red diagnostic
was `` `atoi` cannot be interpreted at compile time, because it has no
available source code ``. The new core now compiles `atoi("literal")` to a
narrow VM native call: a NUL-terminated literal in `Program.data`, a data
pointer argument slot, and a native-call table entry. Execution delegates
symbol lookup and ABI invocation to `quickbite.ffi.callNative` through a small
`NativeMarshaller`; the bytecode backend does not call `dlsym` directly. This
is not a general native ABI, and the adjacent `free`/`malloc` no-source rows
remain green. Focused verification covered `atoi.value.BytecodeNewCore`,
`free.null.voidReturn.BytecodeNewCore`, and
`malloc.pointerReturn.nativeMemory.BytecodeNewCore`; `ninja bin/ut` and full
random runs with seeds `496789113` and `1909046720` reported the invariant
`0 failed, 6/6 failing as expected`.

REPL promotion audit, 2026-07-08: no new `tests/ut/bin/repl.d`
`BytecodeNewCore` promotion was made in this pass. The next unpromoted
coherent blocks are display-only or interpreter-native rows:
`displaysFiniteRangeResults`, `displaysFilteredArrayResults`,
`displaysAssocArrayResults`, `stringFieldsRenderWithLiteralSuffixes`,
`assocArrayFieldsRenderElementSuffixes`,
`assocArrayWithStructValuesRendersEntries`, and the
`runtimeOnlyCellsUseResidentNativeCalls` / `runtimeFileOpenSucceeds`
interpreter-native pair. Per the re-scoped REPL parity continuation, the
display rows stay frozen until slice 11's prelude formatter execution path,
and the interpreter-native rows are not `BytecodeNewCore` promotion
candidates without separate runtime/native-boundary design work. No production
change was needed.

REPL native-runtime red probe, 2026-07-08: temporarily adding
`BytecodeNewCore` to the interpreter-native
`runtimeOnlyCellsUseResidentNativeCalls` / `runtimeFileOpenSucceeds` pair
confirms both rows stay unpromoted.
`runtimeOnlyCellsUseResidentNativeCalls.BytecodeNewCore` fails on
`free(malloc(42))` with `` `free` cannot be interpreted at compile time,
because it has no available source code ``. The narrow `atoi` native-call rung
above does not yet cover general resident libc calls: runtime calls to
resident libc leaves must cross into native code instead of being treated as
source-less CTFE calls.
`runtimeFileOpenSucceeds.BytecodeNewCore` gets into the `std.stdio.File`
construction path and then throws
`ArrayIndexError` at `source/quickbite/backends/bytecode/core/compiler.d:7277`
while indexing `layout.offsets[0]` for a call whose parameter layout has no
ordinary argument slots. Before this row can promote, the backend needs the
native-runtime bridge plus a guarded/implemented call-lowering path for the
Phobos `File` construction stack instead of the unchecked parameter-layout
assumption. The temporary test edit was reverted; no production change was
made.

REPL native-runtime implementation decision, 2026-07-08: no production change
was made for the native-runtime pair in this slice. Making
`runtimeOnlyCellsUseResidentNativeCalls.BytecodeNewCore` pass honestly requires
the general outbound resident-native bridge beyond the narrow `atoi` rung.
The `runtimeFileOpenSucceeds.BytecodeNewCore` crash can be prevented only as a
diagnostic guard on the mismatched argument-layout path, but that guard would
not make the approved REPL behaviour pass and there is no approved existing
test delta here to cover the improved diagnostic. Leave both REPL rows
unpromoted until the native bridge is extended by the runtime/FFI track or a
separate approved diagnostic test is added.

Slice 8 native scalar-int argument, 2026-07-08: promoted `sys/cstdlib.d`'s
existing SystemLinker-backed `abs.scalar` row to `BytecodeNewCore`. The red
diagnostic was `` `abs` cannot be interpreted at compile time, because it has
no available source code ``. The production change generalises the narrow
`atoi` native-call chokepoint rather than adding a parallel path.
`tryCompileNativeCall`
(`source/quickbite/backends/bytecode/core/compiler.d`) now also accepts a
single scalar `int` argument passed by value: it evaluates the argument into an
int-sized argument slot via the ordinary `emitCallArgument` path and records
the argument's basetype in the `NativeCall`. The shared table-entry/instruction
tail is factored into a small `emitNativeCall` helper used by both the string
and scalar shapes. Also fixed a latent size bug in
`BytecodeNativeMarshaller.fillArgument`
(`source/quickbite/backends/bytecode/core/machine.d`): it copied a fixed
`size_t.sizeof` (8) bytes into a buffer that is only `int.sizeof` (4) wide for
an `int` argument; it now copies exactly the buffer's native ABI width.
`canRepresent` already allowed `Tint32`. Verification: `ninja bin/ut`, focused
`abs.scalar.BytecodeNewCore` green, with `atoi.value.BytecodeNewCore` still
green and the `free`/`malloc` no-source rows still red-as-expected; `bin/ut
--random` with seed `2087389007` reported the invariant `0 failed, 6/6 failing
as expected`.

Slice 8 native wider-scalar call, 2026-07-08: promoted `sys/cstdlib.d`'s
existing SystemLinker-backed `labs.widerScalar` row (`long labs(long)` on a
runtime `long negative = -5_000_000_000L`) to `BytecodeNewCore`. The red
diagnostic was `` `labs` cannot be interpreted at compile time, because it has
no available source code `` — the native chokepoint's return-type gate hard-
required `Tint32`, so `labs` fell through to the no-source throw. The
production change generalises the same `abs`/`atoi` native-call chokepoint
rather than adding a parallel path. `tryCompileNativeCall`
(`source/quickbite/backends/bytecode/core/compiler.d`) now accepts a `Tint32`
or `Tint64` return, and a single scalar `int`/`long` argument passed by value:
it sizes the argument slot to the argument's native width (4 or 8) via the
ordinary `emitCallArgument` path. `emitNativeCall` now derives the result slot
scalar (and returned `Operand`) from the function's actual return type via
`scalarType`, replacing the hard-wired `ScalarType.int_`, so the destination is
8 bytes for a `long` return. In `BytecodeNativeMarshaller`
(`source/quickbite/backends/bytecode/core/machine.d`), `canRepresent` now also
allows `Tint64`, and `readResult` writes exactly the return type's native size
(4 for `int`, 8 for `long`) via a small `nativeResultSize` helper instead of a
fixed `int.sizeof`, mirroring the earlier `fillArgument` width fix (the ffi
return buffer is padded to at least 8 bytes, so its length is not the true
result width). Verification: `ninja bin/ut`, focused
`labs.widerScalar.BytecodeNewCore` green, with `abs.scalar.BytecodeNewCore` and
`atoi.value.BytecodeNewCore` still green; `bin/ut --random` with seed
`3078925616` reported the invariant `0 failed, 6/6 failing as expected`.

Slice 8 native ctype toupper/tolower calls, 2026-07-08: promoted
`sys/cstdlib.d`'s existing SystemLinker-backed `ctype.toupperTolower` row to
`BytecodeNewCore`. The fixture imports a second module (`core.stdc.ctype`) and
makes two native calls in one unittest — `toupper(int)` and `tolower(int)`,
both `int(int)`. No production change was needed: this is stale coverage. Both
calls already fall in the widened `int(int)` shape the native chokepoint
(`tryCompileNativeCall`/`emitNativeCall` in
`source/quickbite/backends/bytecode/core/compiler.d`) accepts from the `abs`
rung, each emits its own `NativeCall` table entry, and `callNative` resolves
the symbol per entry at VM runtime regardless of the callee's declaring
module, so two calls and the second module needed no new machinery. The
promotion passed on the first run (no RED). Verification: `ninja bin/ut`,
focused `ctype.toupperTolower.BytecodeNewCore` green, with
`abs.scalar`/`labs.widerScalar`/`atoi.value` `.BytecodeNewCore` still green;
`bin/ut --random` with seed `3779664640` reported the invariant `0 failed,
6/6 failing as expected`.

Slice 8 native atof double-return call, 2026-07-08: promoted `sys/cstdlib.d`'s
existing SystemLinker-backed `atof.floatReturn` row (`double atof(const char*)`
on `atof("3.5".ptr)`, asserting `value == 3.5`) to `BytecodeNewCore`. The RED
diagnostic was `` `atof` cannot be interpreted at compile time, because it has
no available source code `` — the native chokepoint's return-type gate accepted
only `Tint32`/`Tint64`, so a `Tfloat64` return fell through to the no-source
throw. This is the first floating-point return through the native bridge; the
argument is the existing `char*`-string-literal shape, so no arg-side work was
needed. The production change adds `Tfloat64` to that return-type gate in
`tryCompileNativeCall` (`source/quickbite/backends/bytecode/core/compiler.d`);
`scalarType(Tfloat64)` already maps to the 8-byte `double_` scalar that
`emitNativeCall` uses for the destination slot and result `Operand`. In the
`BytecodeNativeMarshaller`
(`source/quickbite/backends/bytecode/core/machine.d`), `canRepresent` also
accepts `Tfloat64` and `nativeResultSize` returns `double.sizeof` for it. No
libffi-float subtlety: `ffiTypeFor` already maps `Tfloat64` to
`ffi_type_double`, libffi writes the 8-byte double at the start of the return
buffer (proven by the Interpreter's own `readResult`), and the marshaller
copies exactly those 8 bytes, so the bit pattern matches the SystemLinker
oracle. Verification: `ninja bin/ut`, focused
`atof.floatReturn.BytecodeNewCore` green, with
`abs.scalar`/`labs.widerScalar`/`ctype.toupperTolower`/`atoi.value`
`.BytecodeNewCore` still green; `bin/ut --random` with seed `1023230401`
reported the invariant `0 failed, 6/6 failing as expected`.

Slice 8 native-call bridge made arity-general, 2026-07-09: pure refactor, no
new test, no behaviour change. `strtod`/`strtol`'s `endptr` out-parameter
rungs need more than one native-call argument; the bytecode-side plumbing was
hardcoded to exactly one. `NativeCall`
(`source/quickbite/backends/bytecode/core/program.d`) now carries
`Type[] argumentTypes` instead of a single `argumentType`. The compiler
(`compiler.d`) allocates a contiguous argument area of N fixed-stride slots via
a new `allocateNativeArgumentArea`, each slot `nativeArgumentSlotSize`
(`size_t.sizeof`, a new `program.d` constant) bytes and aligned to that stride
regardless of the argument's own native width — argument `index` lives at
`argumentArea + index * nativeArgumentSlotSize`. `emitNativeCall` now takes
`Type[] argumentTypes`. `machine.d`'s `nativeCall` case passes
`native.argumentTypes` straight to `quickbite.ffi.callNative` instead of
wrapping a single type in a literal array. `BytecodeNativeMarshaller
.fillArgument` now reads argument `index`'s slot (`_argument + index *
nativeArgumentSlotSize`) instead of always reading from `_argument`, still
copying exactly `buffer.length` bytes (the width-honesty fix from the `abs`
rung). `tryCompileNativeCall`'s acceptance gate is unchanged and still bails
out on `arguments.length != 1` — arity-general call-site acceptance is earned
by the `strtod`/`strtol` out-parameter rung, not this commit. Verification:
`ninja bin/ut`, focused `atoi.value`/`abs.scalar`/`labs.widerScalar`
/`ctype.toupperTolower`/`atof.floatReturn` `.BytecodeNewCore` green, plus the
remaining `cstdlib` `.BytecodeNewCore` rows (`free`, `malloc`, `calloc`,
`realloc`, `div`, `ldiv`) also green (12 tests, 0 failed). `bin/ut --random`
was not run for this refactor; the orchestrator runs the long suite.

`strtod.floatReturn.endptr` promoted to `BytecodeNewCore`, 2026-07-09:
pre-approved `SystemLinker`-oracle promotion
(`tests/ut/backends/runner/sys/cstdlib.d`). Red diagnostic before any
production change, verbatim:

    object.Exception: `strtod` cannot be interpreted at compile time,
    because it has no available source code

`tryCompileNativeCall` (`compiler.d`) refused any call site with
`arguments.length != 1`, so the fixture's two-argument
`strtod("3.5xyz".ptr, &endptr)` fell straight through to the
no-available-source diagnostic without ever reaching the native-call
bridge. Getting to green needed two missing behaviours, not one:

`const(char)* endptr;` has no initializer, so `compilePointerDeclaration`
threw "Unsupported initializer in bytecode core" for it (and would have for
`T* p = null` too — `NullExp`'s own type is `typeof(null)`, not `T*`,
so a `null` initializer can't be read as a pointer-valued expression
either). Fixed: both shapes now allocate a zeroed native-word slot and take
the pointed-at element scalar from the declared type (`variable.type`, not
an initializer operand) via the existing `pointerElementScalar`.

`tryCompileNativeCall`'s arity gate rejected `arguments.length == 2`
outright. Added a narrowly-gated `tryCompileNativeCallOutParameter`,
reached only for exactly this shape: argument 0 a string-literal
`const(char)*` (reusing the single-argument string-literal path), argument 1
a `&local` whose pointed-to local is a tracked pointer local. `&endptr`
arrives as a `SymOffExp` (symbol plus byte offset), not an `AddrExp` —
matching the existing comment on the scalar `&local` path a few hundred
lines up — so the gate matches `isSymOffExp` with a zero symbol offset, not
`isAddrExp`. libc's `char**` parameter type is unconditionally an
out-parameter to `quickbite.ffi.callNative` (ffi.md §34.8's
pointer-to-pointer case), regardless of any `addressOfLocalArguments` flag,
so argument 1's slot in the VM argument area is never read by
`fillArgument` — only its frame offset (for the out-cell writeback) and its
type (for the argument count) matter. `NativeCall` (`program.d`) gained
`ushort[] outParameterOffsets` (sentinel `noOutParameterOffset` for a
non-out argument) and `BytecodeNativeMarshaller` (`machine.d`) gained a
`_base`/`_outParameterOffsets` pair so `fillOutParameterCell` can seed the
cell with `endptr`'s current (null, pre-call) value and `writeOutParameter`
can write the callee's written pointer back into `endptr`'s own frame slot.
`canRepresentOutCell`/`canRepresent` needed no change — both already accept
`Tpointer` in both directions. The pointer-dereference lowering
(`pointerLoad1` reading through a raw host address via
`readHeapElement`/`cast(const(ubyte)*)`) already handles dereferencing a
genuine host pointer for `*endptr`, since `loadDataPointer` already writes
real host addresses (`program.data.ptr + offset`) into pointer-local frame
slots; no change needed there. Verification: `ninja bin/ut`, focused
`strtod.floatReturn.endptr.BytecodeNewCore` green, the 12 other
`cstdlib.*.BytecodeNewCore` rows still green (13 tests, 0 failed), all 35
`BytecodeNewCore` pointer/null-rendering rows across `lang/expressions`,
`lang/arrays`, `lang/control_flow`, `lang/structs`, `lang/cerealed`, and `bin/repl`
still green, and the full `sys/cstdlib.d` module across every backend green
(88 tests, 0 failed). `bin/ut --random` was not run; the orchestrator runs
the long suite. Production diff for the whole branch vs `master`
(`source/`) is 192 changed lines. Next rung, `strtol.endptr`: a
three-argument call (`strtol(s, &endptr, base)`) — the second `int` argument
reuses the existing scalar-argument path, and `strtol`'s `endptr` parameter
is the identical `char**` out-parameter shape, so
`tryCompileNativeCallOutParameter`-style handling generalises rather than
needing a new shape; the gate widens from exactly 2 arguments to the
(string-literal, out-pointer, scalar) triple.

`strtol.endptr` promoted to `BytecodeNewCore`, 2026-07-09: pre-approved
`SystemLinker`-oracle promotion (`tests/ut/backends/runner/sys/cstdlib.d`). Red
diagnostic before any production change, verbatim:

    object.Exception: `strtol` cannot be interpreted at compile time,
    because it has no available source code

The fixture's `strtol("123xyz".ptr, &endptr, 10)` is a three-argument call:
string literal, `&endptr` out-parameter, scalar `int` base. The prior rung's
`tryCompileNativeCallOutParameter` was narrowly gated to exactly
`arguments.length == 2` in the (string-literal, out-pointer) shape, so the
three-argument call fell straight through to the no-available-source
diagnostic. Generalised the gate to arbitrary N by folding
`tryCompileNativeCall`'s old single-argument special case and
`tryCompileNativeCallOutParameter`'s two-argument special case into one
function: a single loop over `call.arguments` classifies and emits each
argument in turn as one of three whitelisted shapes — scalar `int`/`long` by
value (`emitCallArgument`, unchanged), string-literal `const(char)*` (now
`emitStringLiteralArgument`, extracted so the string-literal-argument bytes
+ NUL + `loadDataPointer` sequence exists in exactly one place), or `&local`
(`SymOffExp` with zero offset onto a tracked pointer local) as an out
parameter, recording only its frame offset in `outParameterOffsets` — its
argument-area slot is never read (ffi.md §34.8: the parameter type is
unconditionally an out parameter). Any other shape returns `null`, falling
through to the existing diagnostic; a comment on `tryCompileNativeCall`
records why it is safe to have already emitted earlier arguments' code by
that point — a `null` return here always falls through to the call site's
unconditional no-available-source throw, never a different successful path,
so partial emission is never reached at run time. Argument `index` lives at
argument-area slot `index` (`argumentArea + index * nativeArgumentSlotSize`,
unchanged from the arity-general refactor). Correctness guard: `machine.d`'s
`BytecodeNativeMarshaller.writeOutParameter`/`fillOutParameterCell` indexed
`_outParameterOffsets[index]` unconditionally; today no reachable call site
hits the `noOutParameterOffset` sentinel, but used as a frame offset it
would silently corrupt the stack at `base + 65535`. Added a private
`outParameterOffset` accessor that rejects the sentinel explicitly (the
existing `unsupportedNativeCall` diagnostic) instead of indexing past it.
Verification: `ninja bin/ut`; focused run of every `cstdlib.*.BytecodeNewCore`
row plus `strtol.endptr` on `Interpreter`/`SystemLinker`/`LLVMJit` (17 tests,
0 failed); the `BytecodeNewCore` rows of `lang/expressions`, `lang/arrays`, and
`lang/structs` as a regression check on the shared native-call path (152
tests, 0 failed, 1 failing as expected). `bin/ut --random` was not run; the
orchestrator runs the long suite. Production diff for the whole branch vs
`master` (`source/`) is 197 changed lines, under the 200-line cap.
`free.null.voidReturn.BytecodeNewCore` (a void-returning native call) is not
a small follow-on: `tryCompileNativeCall`'s return-type gate excludes
`TY.Tvoid` outright, and even granting it entry, `machine.d`'s
`nativeResultSize` has no `Tvoid` case (it throws "Unsupported native result
type"), and it is not established whether `quickbite.ffi.callNative` calls
`readResult` at all for a void-returning callee. That is a real, if modest,
slice of its own — return-side plumbing that the argument-side generalisation
here does not touch.

`free.null.voidReturn` promoted to `BytecodeNewCore`, 2026-07-09: the
`free.null.voidReturn` block (`tests/ut/backends/runner/sys/cstdlib.d`) ran
on `Interpreter` only, so it was not yet `SystemLinker`-oracle-backed.
Added `SystemLinker` to that block's `AliasSeq` first and confirmed it
passed unmodified — `free(null); assert(true);` is genuine compiled-D
behaviour, no fixture change needed. Only then added `BytecodeNewCore`.
Red diagnostic before any production change, verbatim:

    object.Exception: `free` cannot be interpreted at compile time,
    because it has no available source code

Two independent gaps, both confirmed by reading the code rather than
assumed: `tryCompileNativeCall`'s return-type gate
(`source/quickbite/backends/bytecode/core/compiler.d`) excluded
`TY.Tvoid` outright, so the compiler never reached the argument loop for
`free`; and `free(null)`'s single argument is a `NullExp`, which (like
`compilePointerDeclaration`'s `= null` case from the `strtod` rung) keeps
its own `typeof(null)` static type rather than the declared `void*`
parameter type, so it matched none of the three whitelisted argument
shapes even once the return-type gate opened.

Fix: widened the return-type gate to admit `TY.Tvoid`. Added a fourth
argument shape — a `NullExp` argument takes its type from the callee's
own declared parameter (`function_.type.toBasetype.isTypeFunction
.parameterList[index].type`, refused unless that declared type is
`TY.Tpointer`) and emits a zeroed argument slot, mirroring
`compilePointerDeclaration`'s existing zero-slot-for-null handling for
locals. `emitNativeCall`'s `allocate(returnScalar)` needed no change:
`scalarType(Tvoid)` already returns `ScalarType.void_`, and `allocate`
already handles a zero-size, zero-alignment allocation (the existing
`cast(void)expr`-discarded-result comment on `allocateBytes` covers
exactly this case) — the plan's assumption of a gap there was wrong.

Two runtime-side gaps surfaced once the compile-time gate opened.
`BytecodeNativeMarshaller.canRepresent` (`machine.d`) — consulted by
`quickbite.ffi.core.canRepresentCall` *before* the native call runs —
did not accept `TY.Tvoid` for the return type, so the compiled call would
still have failed at run time with the identical no-available-source
message. Fixed narrowly: `TY.Tvoid` is representable only in the
`fromNative` (return) direction, never `toNative` (argument/receiver),
since no real D or C argument is void-typed. Established, not assumed:
`quickbite.ffi.core.callNativeImpl` calls `marshaller.readResult(
returnType, returnBuffer)` unconditionally on every non-ref-return call,
void or not (the `returnsRef` branch is the only fork, and `free` takes
neither branch's ref path) — so `readResult`/`nativeResultSize` needed a
real `Tvoid` case, not a dead one; the plan's prior "not established"
bullet was wrong in the direction of assuming it might be dead code.
Added `case Tvoid: return 0;` to `nativeResultSize`, making the
subsequent `_stack[...0] = buffer[0..0]` copy a correct no-op.

The pre-existing `free.null.voidReturn.Bytecode`/`.IR`/`.BytecodeNewCore`
design-driving no-source rows (same file, a separate block) asserted the
opposite of the new behaviour for `BytecodeNewCore` and shared the exact
`@()` test name with the newly-promoted row — not a compile error (D
tolerates duplicate unittest names), but a real behavioural contradiction
once `BytecodeNewCore` stopped throwing. Split that block in two:
`free.null.voidReturn`'s no-source `AliasSeq` narrows to `Bytecode, IR`
(with a comment pointing at the new real row); `malloc.pointerReturn
.nativeMemory` (the block's other fixture, still unsupported on
`BytecodeNewCore`) keeps `Bytecode, BytecodeNewCore, IR`. No fixture body
changed in either block.

Verification: `ninja bin/ut`; the full `sys/cstdlib.d` module (90 tests, 0
failed); a focused run of `free.null.voidReturn` on every backend, every
other `cstdlib.*.BytecodeNewCore` row, and `strtod.floatReturn.endptr`/
`strtol.endptr` on `Interpreter`/`SystemLinker`/`LLVMJit`/`BytecodeNewCore`
(24 tests, 0 failed). `bin/ut --random` was not run; the orchestrator runs
the long suite. Production diff for the whole branch vs `master`
(`source/`) is 228 changed lines — over the 200-line cap, continued past
it on explicit user direction rather than contorting the code to stay
under it.

`malloc.pointerRoundTrip` promoted to `BytecodeNewCore`, 2026-07-09:
pre-approved `SystemLinker`-oracle-backed promotion of an existing
`Interpreter`/`SystemLinker`/`LLVMJit` matrix row. Fixture: `auto ptr =
malloc(8); assert(ptr !is null); free(ptr);` — a bare `void*` return, a
`size_t` argument, and (new) a pointer local passed by value into a
second native call.

Consistency check first, before any production change: the negative
`malloc.pointerReturn.nativeMemory` block (same file) still listed
`BytecodeNewCore`. Its fixture differs in shape from the promoted one —
`cast(ubyte*) malloc(8)`, a mid-block `scope(exit) free(ptr)`, and
indexed writes/reads through the returned pointer (`ptr[0] = 0x11`) —
so it was read, not assumed, to still exercise a genuinely different
(and still unsupported) path.

Red diagnostics, in the order hit:

    object.Exception: `malloc` cannot be interpreted at compile time,
    because it has no available source code

Two independent compile-time gate gaps, both confirmed by reverting each
production change individually and re-running the focused test:
`tryCompileNativeCall`'s return-type gate (`compiler.d`) excluded
`TY.Tpointer`, and its scalar-argument whitelist excluded `TY.Tuns64` —
the literal `8` marshals as `size_t` for `malloc`'s parameter, not
`int`/`long`. Widened both.

    object.Exception: `free` cannot be interpreted at compile time,
    because it has no available source code

With `malloc`'s own gates open, `free(ptr)` exposed a fifth argument
shape: `ptr` is a pointer *local* passed by value, distinct from the
existing `&local` shape (which records an out-parameter frame offset,
never reading the slot itself). Added a shape matching a bare `VarExp`
of a declaration already tracked in `_pointerLocals`, reusing the
existing `emitCallArgument` fallback (`compileExpression` + copy) to
load the local's own 8-byte value — no new codegen needed, since a
pointer local's `VarExp` operand already yields its frame offset holding
the raw pointer value, established by reading `compileExpression`'s
existing `_pointerLocals` case rather than assumed.

    object.Exception: Unsupported pointer initializer in bytecode core:
    ptr

With both call sites compiling, `auto ptr = malloc(8);` still failed:
`emitNativeCall` returned a plain scalar `Operand` for every native call,
never setting `isPointer`/`pointerElement`, so
`compilePointerDeclaration`'s `if (!pointer.isPointer) throw` rejected a
native call's return value even though it now held a real pointer
value. Fixed: `emitNativeCall` marks the returned `Operand` as a pointer
(matching every other pointer-valued operand's shape) whenever the
callee's return type is `TY.Tpointer`, using the existing
`pointerElementScalar` helper for the stride metadata.

    object.Exception: `malloc` cannot be interpreted at compile time,
    because it has no available source code

A fourth, runtime-side gap surfaced once all three compile-time gates
were open: `BytecodeNativeMarshaller.canRepresent` (`machine.d`) — which
`quickbite.ffi.core` consults before running the call — did not accept
`TY.Tuns64`, so the compiled call still failed at VM execution time with
the identical no-available-source message (thrown from the `nativeCall`
opcode handler, not `tryCompileNativeCall`). Widened narrowly to admit
`TY.Tuns64` in both directions; `nativeResultSize` and libffi's own
`ffiTypeFor` already had `Tuns64`/`Tpointer` cases (established by
reading `quickbite/ffi/core.d`, not touched).

With all four gaps closed, `malloc.pointerRoundTrip.BytecodeNewCore`
went green. Confirming the returned pointer is a real host address, not
a VM-heap offset, needed no change: the bytecode core's pointer operand
representation is already a raw `size_t` value regardless of origin, so
storing a genuine `malloc` address in a frame slot and comparing it
against a zeroed slot (`assert(ptr !is null)`, an existing generic
pointer-identity path) worked unmodified.

Rerunning `malloc.pointerReturn.nativeMemory.BytecodeNewCore` after the
above (the consistency check) crashed the whole test binary — `SIGSEGV`,
not a clean exception. Root cause (found via `gdb`, not guessed):
`malloc`/`free` now compile far enough to reach `scope(exit) free(ptr);`
followed by more statements. DMD's `scope(exit)` lowering
(`Statement.scopeCode` in `dmd/statementsem.d`) rewrites the *original*
scope-exit statement's slot in its enclosing `CompoundStatement` to
`null`, moving its content into a `TryFinallyStatement` appended right
after — a documented no-op placeholder, not an error. No BytecodeNewCore
fixture had ever reached a mid-block `scope(exit)` before (every such
fixture failed earlier, at the native-call gate), so `compileStatement`'s
unconditional `compileStatement(child)` over a `CompoundStatement`'s
children had never been handed that placeholder. Fixed with a one-line
null guard at the top of `compileStatement`, matching the convention
every other caller of it already follows (`tryFinally._body`/
`finalbody` are null-checked before the call). This is a general
statement-compilation fix, not a native-memory one — confirmed by
`lang/arrays` and `lang/expressions`, whose `BytecodeNewCore` rows are
unaffected.

With the crash fixed, `malloc.pointerReturn.nativeMemory.BytecodeNewCore`
still failed in that rung, but now on a different, later diagnostic:
`` `free` cannot be interpreted... `` instead of `` `malloc` ``. At the
time, its `free(ptr)` argument's implicit `ubyte*` -> `void*` conversion
was an unimplemented `CastExp` wrapper. Later FFI-track promotions covered
the returned-pointer cast/indexing shapes through the `calloc` and `realloc`
rows, so this is no longer the current reason
`malloc.pointerReturn.nativeMemory` lacks a `Bytecode` row; it is simply
unpromoted in this incremental PR. The pinned `` `malloc` `` diagnostic was
therefore false for `BytecodeNewCore` then (malloc genuinely had available
source); narrowed that block's `AliasSeq` from
`Bytecode, BytecodeNewCore, IR` to `Bytecode, IR`, per the
`free.null.voidReturn` precedent.

The same shape collision — a `void*`/`size_t` return-and-argument shape
identical to `malloc`/`free`'s — invalidated two more negative blocks
that happen to share it: `calloc(size_t, size_t) -> void*` and
`realloc(void*, size_t) -> void*`. This was superseded by the 2026-07-09
FFI-track promotions: `calloc.multiArg.zeroedNativeMemory`,
`realloc.null.pointerArgPointerReturn`, and
`realloc.grow.preservesNativeMemory` now have real `Bytecode` rows.
`div`/`ldiv`'s struct-return negative block was confirmed unaffected
(struct returns stay excluded from the return-type gate) by running it
unchanged.

No production code changed to chase the remaining negative blocks further.
Later FFI-track promotions covered native-memory indexing in the `calloc` and
`realloc` rows, so `malloc.pointerReturn.nativeMemory` is simply unpromoted in
this incremental PR rather than blocked on that old gap.

Verification: `ninja bin/ut`; the full `sys/cstdlib.d` module (87 tests, 0
failed); the `BytecodeNewCore` rows of `lang/arrays` (289 tests, 0 failed)
and `lang/expressions` (297 tests, 0 failed, 5 failing as expected) as a
regression check on the shared `compileStatement`/native-call path.
`bin/ut --random` was not run; the orchestrator runs the long suite.
Production diff for this rung (`source/`) is 56 changed lines;
for the whole branch vs `master` (`source/`), 276 changed lines — over
the 200-line cap, continued past it on explicit user direction rather
than contorting the code to stay under it.

`lang/diagnostics.d` null-class diagnostics promoted to `BytecodeNewCore`,
2026-07-09: pre-approved `SystemLinker`-oracle-backed promotion of
`nullClassFieldReadReportsDiagnostic`,
`nullClassMethodCallReportsDiagnostic`, and
`typeidNullClassReferenceReportsDiagnostic`. The red focused run exited
139 before production changes, confirming the new core was reaching raw
class-pointer operations for null receivers. Added a single
`throwIfNullClassReference` VM guard and emitted it only for class field
read, class method receiver dispatch, and expression-backed `typeid`.
Also taught lowered scalar identity asserts (`is`/`!is`) to compare the
compiled operands so `typeid(thing) is typeid(Thing)` reaches the guarded
`typeid(thing)` operand. Focused verification: the three promoted
`.BytecodeNewCore` rows pass; all 29 `lang/diagnostics.d`
`.BytecodeNewCore` rows pass. Remaining pre-flip behaviours are the
`pow` float intrinsic and the separately approved `= void` narrowing.

## Coverage loss: runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState

The full `bin/ut --random` suite (not the focused per-rung runs above)
caught a regression this branch's `malloc.pointerRoundTrip` promotion
introduced: `repl.backend.runtimeOnlyCtfeCellsReportDiagnosticsAndPreserveState`
in `tests/ut/bin/repl.d` submits `auto ptr = malloc(42);` and asserts it
throws the no-available-source diagnostic. Once `malloc` compiled and ran
natively on `BytecodeNewCore`, that cell stopped throwing, so the pinned
refusal was false. Per the omit-don't-pin convention already applied four
times to `sys/cstdlib.d`'s negative blocks in this branch, that block's
`AliasSeq` was narrowed from `Ctfe, BytecodeNewCore` to `Ctfe`, leaving the
fixture body and expected message untouched — `malloc` is still genuinely
refused on `Ctfe`.

Consequence: no `BytecodeNewCore` row currently covers "a failed REPL cell
reports a diagnostic and preserves session state." Re-earning that
coverage on the new core is owed future work, using a cell the new core
still genuinely cannot execute — e.g. a `div`/`ldiv` struct return, per
the still-deferred rows above — rather than `malloc`.

`voidInitializedScalarReadReportsUninitialized` narrowed to `Ctfe` only,
2026-07-09: completed work-order item 3. The fixture body and CTFE
diagnostic assertion are unchanged; the row now characterizes the
`Ctfe`/`SystemLinker` compiled-D divergence instead of requiring
`Interpreter`, `Bytecode`, or `IR` to emulate CTFE uninitialized-read
tracking. No `BytecodeNewCore` uninitialized-read detection was added.

Default flip completed, 2026-07-09: `Bytecode` now runs the typed-frame
core directly, the `BytecodeNewCore` handle is deleted, and the legacy
top-level bytecode core (`compiler`, `vm`, `instructions`, and legacy
`builtins`) is gone. The builtin recognizer needed by the typed-frame
compiler moved under `bytecode/core`. Test matrices now name `Bytecode`;
the old `sys/cstdlib.d` refusal rows that only pinned legacy-core absence
were narrowed off `Bytecode`; duplicate/differing legacy assertion-message
rows were collapsed onto the compiled-oracle `Bytecode` expectation. Focused
stale-name scans found no `BytecodeNewCore` references in `source/` or
`tests/`, no duplicate generated test names remained, and
`bin/ut --random` passed.

`malloc.pointerReturn.nativeMemory` promoted to `SystemLinker` and
`Bytecode`, 2026-07-10: pre-approved promotion of the existing positive
runtime matrix fixture. The exact fixture had only an `Interpreter` row, so
`SystemLinker` was added and run first to establish the direct compiled-D
oracle; it passed unchanged. Adding `Bytecode` then passed on its first red
candidate run, with no production changes. The fixture exercises a
`malloc(8)` return cast to `ubyte*`, scoped `free`, non-null check, and
indexed native-memory writes and reads. The separate IR-only no-source block
above it is intentionally unchanged. Verification: `ninja bin/ut` passed and
`bin/ut --random` passed with seed `2640497437`.

`realloc.sliceAssignWritesNativeMemory` promoted to `Bytecode`, 2026-07-10:
pre-approved promotion of the existing direct-SystemLinker-backed runtime
fixture. The first Bytecode run was red: the raw-pointer destination slice
wrote `8` where the fixture expected `'a'`. The minimal lowering change lets
the existing dynamic-slice assignment path accept a raw-pointer base, obtain
its element type from the result slice, and reuse the existing pointer-slice
descriptor plus `sliceCopy` write-through instructions. No fixture body or
other behaviour changed. Also removed the immediately stale Post-Flip Backlog
claim that `malloc.pointerReturn.nativeMemory` lacked a `Bytecode` row;
`cee09a4f` had already promoted it. Verification: focused red then green for
this Bytecode row; `ninja bin/ut` and `bin/ut --random` passed with seed
`543446273`.

`dynamicArray.localConcatenationAssignment` promoted to `Bytecode`,
2026-07-10: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time matrix fixture. The focused Bytecode run was red with
`Unsupported expression in bytecode core: values ~= chunk`. The minimal
lowering recognizes DMD's distinct `CatAssignExp` node for whole-array
`arr ~= other`, reuses the existing descriptor materialization and
`concatArrays` opcode, writes the fresh descriptor back to the local, and
yields that descriptor as the expression result. Element append and all other
concatenation forms are unchanged. Verification: focused red then green for
this Bytecode row; `ninja bin/ut` passed. The orchestrator owns the required
full randomized verification.

`dynamicArray.fieldConcatenationAssignment` promoted to `Bytecode`,
2026-07-10: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time matrix fixture. The first Bytecode candidate run passed without
production changes. The fixture appends a dynamic `ubyte[]` to a struct field,
confirming the existing `CatAssignExp` descriptor write-back through a field.
Verification: focused Bytecode row, `ninja bin/ut`, and `bin/ut --random`
passed (seed `4115980552`).

`struct.staticCharArrayFieldDefaultInit` promoted to `Bytecode`, 2026-07-10:
pre-approved promotion of the existing direct-SystemLinker-backed compile-time
fixture. The focused Bytecode row was red with `Unsupported struct initializer
in bytecode core: b`. DMD lowers this default struct initializer through an
init-symbol `VarExp`; the `char[16]` field's logical initializer is a sparse
`ArrayLiteralExp` with `char.init` as its basis. The narrowly scoped fallback
uses DMD's field offset and static-array size to write that basis into inline
`char` fields. It does not add pointer, general-array, FFI, formatter, or
reification support. Verification: focused red then green; `ninja bin/ut` and
`bin/ut --random` passed (seed `2579798018`).

`struct.defaultInitPreservesExplicitFieldInitializers` promoted to `Bytecode`,
2026-07-10: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The focused Bytecode row passed on its first candidate
run, so no production fallback was needed. The fixture verifies that
`Header.init` retains explicit `ubyte` and `int` field initializers at DMD's
field offsets. Verification: `ninja bin/ut` and focused Bytecode row passed;
`bin/ut --random` passed (seed `1914209150`).

Reviewer fix, 2026-07-10:
`struct.defaultInitPreservesStaticCharArrayAndScalarFieldDefaults` adds the
missing direct SystemLinker-backed check for `Header header;` when `Header` has
both `char[2] label = "OK"` and `int revision = 42`. Its Bytecode row was red
(`'\xff' != 'O'`). The init-symbol fallback now materialises each field's own
explicit initializer at its DMD field offset, retains the prior implicit
`char.init` handling, and leaves implicit zero-valued scalar fields in the
zeroed frame. This is limited to this struct-default-init path; it does not add
general struct initialization, pointer, FFI, or display work. Verification:
focused red then green; `ninja bin/ut` and `bin/ut --random` passed (seed
`1598476746`).

`strlen.localBuffer` promoted to `Bytecode`, 2026-07-10: pre-approved
promotion of the existing direct-SystemLinker-backed runtime fixture. The
focused Bytecode row was red with the no-available-source diagnostic. The
native-call gate lacked `size_t` results and admitted `char*` arguments only
when they were string literals; DMD lowers `&buf[0]` here to its
symbol-offset form over the inline static-array local. The narrow change adds
the existing `ulong` result shape, passes supported non-literal `char*`
operands through the native argument slot, and takes the frame address of the
static-array symbol. This does not add struct returns, arbitrary native
marshalling, or formatter work. Verification: focused red then green and
`ninja bin/ut` passed; `bin/ut --random` passed (seed `1104894086`).

`struct.templatedConstructorPreservesDynamicArrayField` promoted to
`Bytecode`, 2026-07-10: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row passed on
its first candidate run, so no production change was needed. The fixture
instantiates a templated struct constructor, stores a dynamic-array parameter
in a field, and reads the field back through the constructed value. This is a
stale coverage gap after the existing struct constructor, template, dynamic
array descriptor, and field-read paths. Verification: focused Bytecode row,
`ninja bin/ut`, and `bin/ut --random` passed (seed `2694263265`).

`malloc` promoted to `Bytecode`, 2026-07-10: pre-approved promotion of the
existing direct-SystemLinker-backed runtime fixture. The focused Bytecode row
passed on its first candidate run, so no production change was needed. The
fixture calls `malloc`, casts its result to `ubyte*`, writes and reads native
memory, and frees it through `scope(exit)`. This is a stale coverage gap after
the existing native-call and raw-pointer paths. Verification: focused Bytecode
row, `ninja bin/ut`, and `bin/ut --random` passed (seed `1522907379`).

`voidInitializedStructReturnedWholeIsUsable` promoted to `Bytecode`,
2026-07-10: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The focused Bytecode row passed on its first candidate
run, so no production change was needed. The fixture returns a whole
`= void`-initialized struct, assigns every field in the caller, and reads the
initialized fields; this records that Bytecode already matches compiled D's
field-granular void-initialization semantics on this path. Verification:
focused Bytecode row, `ninja bin/ut`, and `bin/ut --random` passed (seed
`720749549`).

`staticArrayCopyRunsPostblitAndDtors` promoted to `Bytecode`, 2026-07-10:
pre-approved promotion of the existing direct-SystemLinker-backed compile-time
fixture. The focused Bytecode row passed on its first candidate run, so no
production change was needed. The fixture copies a two-element static array of
structs, checks that each element's postblit runs once, and confirms that both
source and copy elements run their destructors at scope exit. This is a stale
coverage gap after the existing static-array copy, postblit, and destructor
lowering. Verification: focused Bytecode row, `ninja bin/ut`, and
`bin/ut --random` passed (seed `3793348702`).

`dynamicArrayTruthinessControlsEnforceFallback` promoted to `Bytecode`,
2026-07-10: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The focused Bytecode row passed on its first candidate
run, so no production change was needed. The fixture verifies null and
zero-length dynamic arrays are false in `if`, `!`, and conditional-expression
contexts, while a non-empty array is true. This is a stale coverage gap after
the existing dynamic-array length and truthiness lowering. Verification:
focused Bytecode row, `ninja bin/ut`, and `bin/ut --random` passed (seed
`3227994507`).

`grainBitsBoolWritesScalar` promoted to `Bytecode`, 2026-07-10: pre-approved
promotion of the existing direct-SystemLinker-backed compile-time fixture. The
first Bytecode run was red with `Unsupported ref argument in bytecode core:
reader`: `reader` is a struct local passed as the template's `ref C` argument,
but ref-argument lowering recognized only scalar and dynamic-array locals.
The minimal fix reuses the existing struct-base lookup, allowing a struct
lvalue's inline frame offset to be passed to the normal ref copy-in/write-back
path. No fixture body changed. The fixture verifies a ref struct receiver
writes a `uint` temporary that is converted back through a ref `bool` argument.
Verification: focused red then green and `ninja bin/ut` passed. The required
`bin/ut --random` run (seed `4122028987`) instead found the pre-existing
`pointer.sliceAssignmentWritesArrayStorage.Bytecode` diagnostic row failing
because it did not throw. The same focused failure reproduced with this rung's
struct-ref lookup temporarily removed, so it is unrelated and remains outside
this no-pointer-slice commit.

`struct.tupleofAssignmentCopiesFields` promoted to `Bytecode`, 2026-07-10:
pre-approved promotion of the existing direct-SystemLinker-backed compile-time
fixture. The first Bytecode run was red with `Unsupported expression in
bytecode core: AliasSeq!(target.head = source.head, target.tail = source.tail)`:
DMD lowers this `.tupleof` assignment to a `TupleExp` containing the two
already-supported scalar field assignments. The minimal compiler support runs
the optional tuple side-effect expression, then each tuple element in order,
returning the final element's operand. No fixture body changed. This covers
the generic sequence form while relying on the existing field write path for
the actual copies. Verification: focused red then green, `ninja bin/ut`, and
`bin/ut --random` passed (seed `1010252269`). The known unrelated pointer-slice
diagnostic row is left unchanged.

`pointer.indexAssignmentWritesArrayStorage` promoted to `Bytecode`,
2026-07-10: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The first Bytecode candidate run was red (`'\0' != 'x'`).
The constructor correctly retained its `char*` field and emitted the pointer
store, but materialising its static-array slice argument made an independent
VM heap copy. The minimal call-argument lowering now passes a descriptor with
the frame address and element count; general static-array materialisation stays
copying so result bytes can outlive the VM stack. No fixture body changed.
Verification: focused red then green, `ninja bin/ut`, and `bin/ut --random`
passed (seed `4022505703`).

`classReferencePassedByValueMutatesObject` promoted to `Bytecode`,
2026-07-13: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The focused Bytecode row was red with `Unsupported
assignment in bytecode core: box.value = 42`. The typed-frame core already
resolved class field addresses for reads (including the null-reference guard),
so the narrow completion writes a scalar rhs through that same address and
returns the assigned operand. It does not add class allocation, dynamic-array
class fields, general object layout, or formatter support. Verification:
focused red then green; `ninja bin/ut` and `bin/ut --random` passed (seed
`1711526885`).

`struct.tupleConstructionFromLocals` promoted to `Bytecode`, 2026-07-13:
pre-approved promotion of the existing direct-SystemLinker-backed compile-time
fixture. The focused Bytecode row was red because DMD lowers `Tuple`'s field
initialization to a `TupleExp`, which the typed-frame compiler did not handle.
The narrow lowering evaluates its optional prefix and each element in source
order, returning the final element value; each element is already an ordinary
supported assignment. This does not add tuple representation, generic tuple
operations, or formatter support. Verification: focused red then green;
`ninja bin/ut` and `bin/ut --random` passed (seed `3349317244`).

`pointer.dcharCompoundAssignThroughUintPointerIsIntegerCompatible` promoted
to `Bytecode`, 2026-07-13: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported compound assignment in bytecode core: *p >>= 1`. The
typed-frame core already reinterpreted same-size pointer loads and could store
through those pointers; the narrow completion lowers right-shift compound
assignment by loading the pointed-to integer, applying the existing integer
opcode with normal width checks, and storing the result through the same
pointer. It does not add pointer arithmetic, non-integer compound operations,
or new pointer representations. Verification: focused red then green;
`ninja bin/ut` and `bin/ut --random` passed (seed `951890973`).

Reviewer fix, 2026-07-13: `pointer.uintCompoundRightShiftIsLogical` adds a
direct SystemLinker-backed regression for `uint value = 0x8000_0000;` reached
through a `uint*` and shifted with `*p >>= 1`. Bytecode was red, producing
`0xC000_0000` from the signed shift opcode. Pointer compound right-shift
lowering now chooses the existing unsigned opcode from the loaded pointee's
type, matching ordinary shift lowering before its normal `int` promotion.
Focused Bytecode and SystemLinker rows passed; `ninja bin/ut` and
`bin/ut --random` passed (seed `1474536093`).

`pointer.sliceAssignmentWritesArrayStorage` promoted to `Bytecode`,
2026-07-13: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The typed-frame core now handles the fixture unchanged,
including taking the address of the inline static array and writing its slice
through the derived pointer. The stale Bytecode-only expected-diagnostic block
was removed; no production change was needed. Verification: focused Bytecode
row, `ninja bin/ut`, and `bin/ut --random`.

Merge resolution, 2026-07-13: retained the independently landed July 10
Bytecode promotions and their implementation notes alongside this branch's
later promotions. The duplicate static-array-copy ledger entry is represented
once by the landed entry; no behavior was dropped.

`struct.staticArrayCopyRunsPostblitAndDtors` Bytecode promotion reverted,
2026-07-13: although the focused row passed, randomized execution exposed
unsafe lifetime ordering that can corrupt the process during static-array
postblit/destructor handling. Bytecode is removed from this matrix row until
that lifetime path is safe under randomized suite ordering. No production
change is included; compiled-oracle coverage remains on Ctfe, Interpreter,
SystemLinker, and LLVMJit.

`pointer.indexAssignmentWritesVoidInitialisedArray` promoted to `Bytecode`,
2026-07-13: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The fixture writes `p[0]` through a pointer derived from
a `char[8] = void` local, then reads the written element. The initial Bytecode
run was red with `Unsupported initializer in bytecode core: tmp`: DMD exposes
this initializer as `VoidInitializer`, before the static-array
`ExpInitializer` path. The narrow compiler change allocates and tracks the
inline static-array slot, then leaves a `VoidInitializer` unmaterialised. It
does not change static-array copies, postblits, destructors, or lifetime
handling. Verification: focused red then green; `ninja bin/ut`; and
`bin/ut --random` (seed `4201158653`). Commit: dad0c0ec.

`pointer.emptySliceAssignmentThroughNullPointerIsNoOp` promoted to `Bytecode`,
2026-07-13: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The focused Bytecode row was first red with `Unsupported
dynamic array initializer in bytecode core: cast(const(char)[])empty`: DMD
passes the fixture's default `string` as a `const(char)[]` view. Bytecode now
expands its compact program-data string descriptor into the existing native
dynamic-array descriptor without copying nonempty bytes. The next operation is
the intended zero-length pointer-slice assignment: `copySlice` now returns
after confirming equal zero lengths and before constructing slices from either
pointer. This preserves nonempty copies and their existing overlap and length
diagnostics. It does not add writable string views, general string mutation,
or static-array lifetime work. Verification: focused red then green; `ninja
bin/ut`; and `bin/ut --random` passed (seed `260515522`).

Benchmark integration, 2026-07-13: added `Bytecode` to the benchmark runner
registry and the default backend selection, so the benchmark binary now times
the bytecode backend for every default fixture and `--dub` package run.

Reviewer fix, 2026-07-13: added the direct SystemLinker-backed
`emplaceRefDefaultInitializesWcharArrayElement` regression. It resizes a
`wchar[]`, overwrites its element with `'x'`, then calls the zero-argument
`emplaceRef` and expects `wchar.init` (`0xFFFF`). Bytecode was red with
`0 != 65535`: its zero-argument indexed-element path materialised every type
except `char` as zero. The narrow change materialises `wchar.init` there and
also gives `wchar` the existing all-ones default fill used for dynamic-array
allocation and growth. This does not add general non-uniform scalar init
handling. Focused Ctfe, Bytecode, SystemLinker, and LLVMJit rows passed;
`ninja bin/ut` passed; `bin/ut --random` reported its six expected failures
(seed `1782332219`), and the mandated `bin/ut --seed 1782332219` replay
passed: 3064 tests, 0 unexpected failures.

`emplaceRefWritesArrayElement` promoted to `Bytecode`, 2026-07-13:
pre-approved promotion of the existing SystemLinker-backed Cerealed fixture.
The focused Bytecode row was red with `Unsupported comparison assert in
bytecode core: _d_assert_fail("==", message, "ok")`. The typed-frame core now
admits mixed mutable-character-array/string-literal assertion operands through
the existing native slice-comparison path, while retaining compact string
descriptors and their diagnostics when both operands are immutable strings.
This does not add `emplaceRef` handling, lazy thunks, multi-argument
constructors, or general string mutation. Verification: focused red then
green; `ninja bin/ut`; and `bin/ut --random` passed (seed `605411570`).

`emplaceRefRefusesZeroArgDefaultInit` promoted to `Bytecode`, 2026-07-13:
pre-approved SystemLinker-backed Cerealed fixture. Bytecode was red with
`Unsupported ref argument in bytecode core: message[0]`. Its existing
`emplaceRef` interception now handles only the one-argument form whose target
is an indexed dynamic-array element: it materializes the scalar default value
(`char.init` remains `0xFF`) and uses the existing statically sized indexed
store. It deliberately excludes struct/array elements, postblits, general ref
arguments, and multi-argument constructors. Matrix check: Ctfe, Bytecode,
SystemLinker, and LLVMJit pass; Interpreter remains excluded after an empirical
focused red with its documented `Unsupported eval call.` shim limitation.
Verification: focused Bytecode red then green; passing focused four-backend
matrix; `ninja bin/ut`; and `bin/ut --random` passed (seed `1911983078`).

`emplaceRefRefusesMultiArgConstructor` promoted to `Bytecode`, 2026-07-13:
pre-approved SystemLinker-backed Cerealed fixture. The focused Bytecode row
was red as a SIGSEGV (exit code 139). Its `emplaceRef` interception now handles
only a small struct in an indexed dynamic-array element: it default-initializes
an inline temporary, forwards the supplied arguments to the struct's selected
constructor, then copies the resulting small block to the indexed element.
This deliberately excludes overloaded-constructor resolution, structs larger
than eight bytes, postblits, destructors, array elements, general `ref`
arguments, and other lifetime semantics. Ctfe, Bytecode, SystemLinker, and
LLVMJit pass the focused matrix. Interpreter remains excluded by its documented
`Unsupported eval call.` `emplaceRef` shim; no Interpreter instance exists for
this fixture to run. Verification: focused Bytecode red then green; passing
focused matrix; `ninja bin/ut`; and `bin/ut --random` passed.

`emplaceRefSkipsPostblitForStructElement` promoted to `Bytecode`, 2026-07-13:
pre-approved SystemLinker-backed Cerealed fixture. The focused Bytecode row
was red as a SIGSEGV (exit code 139): resizing `Counter[]` encoded the
`void` scalar sentinel's zero width, leaving no backing storage for the
indexed store. Array-length resize now carries the DMD-derived element width
when it differs from the scalar representation. The narrow `emplaceRef`
interception copies an eight-byte struct source into a frame block, runs its
postblit once, then stores that completed block at the indexed dynamic-array
element. This does not add larger aggregate support, postblit/destructor
lifetime management, general `ref` arguments, or aggregate array operations.
Ctfe, Bytecode, SystemLinker, and LLVMJit pass the focused matrix; Interpreter
remains excluded for its documented missing postblit. Verification: focused
Bytecode red then green; passing focused matrix; `ninja bin/ut`; and
`bin/ut --random` passed (seed `2678926982`).

`dynamicArray.lengthAssignmentDefaultInitializesStructElements` promoted to
Bytecode, 2026-07-13: new direct SystemLinker-backed regression for resizing
`Marked[]`, where `Marked.value = 42`. Bytecode was red with `0 != 42` because
`setArrayLength` repeated one default-init byte, which cannot represent a
non-uniform `T.init` block. Struct-array growth now materializes DMD's
`defaultInitLiteral` into an inline frame block and copies that block into each
new element; scalar-array growth keeps its existing uniform-fill opcode. This
does not broaden aggregate-array operations, postblit/destructor lifetimes, or
array construction. Ctfe, Bytecode, SystemLinker, and LLVMJit pass the focused
matrix. Interpreter is excluded after its empirical focused red (`0 != 42`).
Verification: focused SystemLinker green; focused Bytecode red (`0 != 42`) then
green; the passing four-backend matrix; `ninja bin/ut`; and `bin/ut --random`.

Reviewer follow-up, 2026-07-13: removed the stale
`emplaceRefWritesArrayElement` comment that said Bytecode was omitted for its
`char[]`-literal assertion. Bytecode is in that fixture's matrix and now runs
the assertion after the mixed comparison support landed.

`pointer.uintBitsWrittenThroughPointerReadBackAsFloat` promoted to Bytecode,
2026-07-13: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The row writes the bit pattern for `1.0f` through a
`uint*` reinterpreting a local `float`, then reads that local directly. The
focused Bytecode row passed on its first candidate run, so no production change
was needed. LLVMJit and Ctfe remain excluded under the existing
omit-don't-pin convention. Verification: focused Bytecode row; `ninja bin/ut`;
and `bin/ut --random` passed (seed `3645436118`).

`pointer.directWriteToAddressTakenScalarUpdatesCell` promoted to Bytecode,
2026-07-13: pre-approved promotion of the existing direct-SystemLinker-backed
compile-time fixture. The row takes a `uint*` view of a local `float`, directly
reassigns the `float`, then verifies both the scalar read and the raw pointer
bits. The focused Bytecode row passed on its first candidate run, confirming
the typed-frame local remains authoritative after a direct scalar assignment.
No production change was needed. Ctfe and LLVMJit remain excluded under the
existing omit-don't-pin convention. Verification: focused Bytecode row;
`ninja bin/ut`; and `bin/ut --random` passed (seed `790590047`).

`pointer.subWordReinterpretWriteThroughPointerWritesLowByte` promoted to
Bytecode, 2026-07-13: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The row writes `0xAB` through a
`ubyte*` reinterpreting a `uint` local, then verifies the native scalar reads
back as `0xAB`. The focused Bytecode row passed on its first candidate run, so
no production change was needed. This advances subword native-layout coverage
without adding broader pointer or aggregate semantics. Verification: focused
Bytecode row; `ninja bin/ut`; and `bin/ut --random`.

`pointer.dereferencedPointerPostIncrementUsesPromotedScalarCell` promoted to
Bytecode, 2026-07-13: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported post-increment in bytecode core: (*p)++`. The compiler now
loads an `int*` pointee through the existing pointer-load opcode, preserves the
old value, applies the existing integer increment opcode, and writes the value
back through the existing pointer-store opcode. This is limited to the core's
already-supported four- and eight-byte integer scalars; it does not add
pointer arithmetic, non-integer post-increment, or a general lvalue layer.
Verification: focused Bytecode red then green; `ninja bin/ut`; and
`bin/ut --random`.

`pointer.addressOfDatasegGlobalDoesNotShadowInitializer` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported expression in bytecode core: & gValue`. The typed-frame
core now materializes a scalar module-data address for both DMD address forms
(`AddrExp` and `SymOffExp`), and seeds an integer scalar module initializer in
the existing mutable module-data segment. This does not add aggregate module
storage, dynamic module initializers, module constructors, or general module
lifetime semantics. Verification: focused Bytecode red then green; `ninja
bin/ut`; and `bin/ut --random` passed (seed `3623415330`).

`pointer.crossFrameUintBitsWrittenThroughPointerReadBackAsFloat` promoted to
Bytecode, 2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The row writes `1.0f`'s raw bits to
a caller's `float` local through a `uint*` passed to a normal callee, then
reads the caller's local after return. The focused Bytecode row passed on its
first candidate run, confirming the existing addressable scalar slot crosses
the ordinary call boundary without a production change. Ctfe and LLVMJit
remain omitted under the existing omit-don't-pin convention. Verification:
focused Bytecode row; `ninja bin/ut`; and `bin/ut --random`.

`pointer.addressOfStructFieldIsDistinctAcrossInstances` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct SystemLinker-backed
compile-time fixture. The row takes the addresses of identically initialized
scalar fields from two local struct instances, requires distinct addresses,
and reads both pointees. The focused Bytecode row passed on its first candidate
run, confirming the existing inline struct-field offset and frame-address
paths already match compiled D. This adds no broader aggregate-address or
heap-struct semantics. Verification: focused Bytecode row; `ninja bin/ut`;
and `bin/ut --random` attempted with seed `874019670`, which failed in the
concurrently modified `dynamicArrayTruthinessControlsEnforceFallback.Bytecode`
row (`130 != 3`), outside this rung's files.

Reviewer fix, 2026-07-14: the running machine now uses the program's live
module-data segment rather than a startup copy. The compiler reserves every
16-bit-addressable module-data byte when it creates the program, so a lazily
compiled callee can grow the segment without invalidating raw module addresses
already handed to bytecode. No new language surface or tests were added.

Reviewer fix, 2026-07-14: scalar module slots now validate their initializer
before becoming addressable. Integer literals retain the existing native-byte
initialization, while `float`, `double`, and `real` literals use the same raw
IEEE/native-real bytes as frame literals. Other initializer expressions fail
deterministically instead of exposing a silently zero-initialized module slot.
No tests were changed.

`dynamicArray.dollarReflectsLengthAfterInPlaceGrowth` promoted to Bytecode,
2026-07-14: pre-approved SystemLinker-backed matrix promotion. DMD lowers the
assertion's indexed operand into a `ref` temporary, so obtaining the element
address compiles the `$ - 1` index before the ordinary array-load path. The
compiler now makes the current descriptor length available while compiling
both dynamic-array load indices and dynamic-element address indices. This
keeps `$` scoped to an individual index expression and reflects the descriptor
after the preceding `length++`; it does not add slice bounds, writes through
indexed `ref` arguments, or general `$` support. Verification: focused
Bytecode row red (`Unsupported variable in bytecode core: $`) then green; full
`ninja bin/ut`; and `bin/ut --random` passed (seed `3470295131`).

`struct.voidInitialisedFieldSliceAssignment` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct SystemLinker-backed
compile-time fixture. The focused Bytecode row was red first because a static
array field could not become a slice view; after that narrow support it exposed
the string parameter's compact descriptor and a runtime static-array index.
Static-array field offsets now feed the existing slice-view materialization;
string slicing converts the compact descriptor to the existing native one; and
only constant static-array indices retain the direct inline-offset path, with
runtime indices using the existing slice descriptor. This does not add bounds
checks, struct default initialization, or general static-array lifetime work.
Verification: focused Bytecode red then green; `ninja bin/ut`; and
`bin/ut --random` reproduced the pre-existing
`dynamicArrayTruthinessControlsEnforceFallback.Bytecode` failure; mandated
`bin/ut --seed 3353579115 --quiet` replay also exposed pre-existing
SystemLinker temporary-library races.

Regression fix, 2026-07-14: the existing direct SystemLinker-backed
`dynamicArrayTruthinessControlsEnforceFallback.Bytecode` row had treated the
first byte of a dynamic-array descriptor as its condition, so a nonempty
array could follow a false branch. Dynamic-array conditions now read the
descriptor length, covering `if`, `for`, `do`, ternary, `!`, and short-circuit
logical expressions through the shared condition compiler. This does not add
array comparisons, bounds checks, or array values beyond the existing
descriptor support. No test body changed. Verification: focused SystemLinker
and Bytecode rows (Bytecode red `130 != 3`, then green); `ninja bin/ut`; and
`bin/ut --random` plus the requested seed replays.

`refArgument.floatWriteBackSkipComparesBitPatternNotEquality` promoted to
Bytecode, 2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. Its focused Bytecode row was red
with `Unsupported division in bytecode core: 1.0 / d`. The typed-frame core
now emits and executes a `double` division instruction, allowing the fixture
to distinguish positive from negative zero after a `ref` write-back. This does
not add float or real division, division-by-zero diagnostics, or broader
floating arithmetic. Verification: focused Bytecode red then green; `ninja
bin/ut`; and `bin/ut --random` initially hit an unrelated LLVMJit
`dependencyImage.externDStructDestructor` assertion failure, while the
required `bin/ut --seed 2107431968 --quiet` replay passed.

`pointer.addressOfStructFieldIsStableAcrossReEvaluation` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct SystemLinker-backed
compile-time fixture. The focused Bytecode row passed on its first candidate
run, confirming that repeated `&localStruct.field` evaluation reuses the
typed-frame address identity, complementing the preceding distinct-instances
promotion. This adds no field write-through, heap-struct, or aggregate-address
semantics. Verification: focused Bytecode row; `ninja bin/ut`; and
`bin/ut --random` failed in the unrelated SystemLinker
`refCursorReadAdvancesPosition` row; the mandated `--seed 3463408491 --quiet`
replay reproduced its temporary-library link failure.

`pointer.addressOfStructFieldWriteThroughUpdatesField` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row passed on
its first candidate run, confirming that the existing typed-frame field
address remains a live alias for a subsequent scalar pointer store. No
production change was needed. This does not add aggregate writes, heap
structs, or general lvalue support. Verification: focused Bytecode row;
`ninja bin/ut`; and `bin/ut --random`.

`pointer.reinterpretWriteThroughRefParameterPointerReachesCaller` promoted to
Bytecode, 2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The row passes a caller `float`
through a `ref` parameter, takes a same-size `uint*` view in the callee, and
writes raw bits that the caller then reads as `1.0f`. The focused Bytecode row
passed on its first candidate run, confirming that the existing typed-frame
`ref` binding preserves the caller's live scalar storage across the ordinary
call boundary. No production change was needed. This adds no general pointer
or aggregate alias semantics. Verification: focused Bytecode row; `ninja
bin/ut`; and `bin/ut --random`.

`staticArray.foreachRefWritesVoidInitialisedElements` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct SystemLinker-backed
compile-time fixture. The focused Bytecode row was red (`0 != 34`) because a
`ref int[2]` parameter was treated as a by-value static-array block. Static
array parameter layout now passes a caller-frame offset for `ref` parameters,
records the block-size write-back, and accepts static-array locals as ref
arguments. The existing frame copy/write-back mechanism then preserves the
loop's element writes in the caller's `= void` array. This does not add general
foreach lowering, aggregate lifetime handling, or static-array copies.
Verification: focused Bytecode red then green; `ninja bin/ut`; and
`bin/ut --random`.

`pointer.recursiveDeclarationDropsStaleScalarCell` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct SystemLinker-backed
compile-time fixture. The row recursively takes the address of a same-AST
local at two call depths, requiring each call frame to retain distinct native
storage. The focused Bytecode row passed on its first candidate run, confirming
that its typed-frame slots do not inherit stale local state across recursion.
No production change was needed. This does not add general recursive aggregate
or pointer lifetime semantics. Verification: focused Bytecode row; `ninja
bin/ut`; and `bin/ut --random`.

`dynamicArray.ptrPointsAtFirstElement` promoted to Bytecode, 2026-07-14:
pre-approved promotion of the existing direct SystemLinker-backed compile-time
fixture. The row compares `values.ptr` to `&values[0]`, dereferences it, and
uses pointer indexing. The focused Bytecode row passed on its first candidate
run, confirming the existing dynamic-array descriptor pointer and pointer-load
paths already agree. No production change was needed. This does not add array
reserve, capacity, or interior-slice append semantics. Verification: passing
focused five-backend matrix; `ninja bin/ut`; and `bin/ut --random`.

`refCall.assignmentToRefReturningCallWritesArgument` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported assignment in bytecode core: self(i) = 42`. The typed-frame
core now accepts an assignment through a direct `ref`-returning call when its
sole return is a `ref` parameter: it executes the callee (including its
existing ref-parameter writeback), then stores through that parameter's
original caller slot. This deliberately does not add branch-dependent ref
returns, ref returns of fields or globals, or member ref returns. Verification:
focused Bytecode red then green; passing focused five-backend matrix; `ninja
bin/ut`; and `bin/ut --random`.

`dynamicArray.refParamWriteBackThroughIndexArgument` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported ref argument in bytecode core: arr[1]`. A scalar dynamic
array element passed by `ref` now materializes in one call-local slot, uses the
existing ref-parameter copy/writeback path during the call, and stores that
slot back through the same already-evaluated descriptor and index after a
normal return. This deliberately excludes aggregate elements, unknown array
expressions, and exception-path writeback. Verification: focused Bytecode red
then green; passing focused five-backend matrix; `ninja bin/ut`; and
`bin/ut --random` passed (seed `3598663860`).

`pointer.newStructPointersWithEqualContentAreDistinct` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported struct value in bytecode core: *a`. A dereference of a
pointer to a 1-, 2-, 4-, 8-, or 16-byte struct now loads its complete block
into an inline frame slot before the existing field-wise struct equality path
compares it. This deliberately does not support larger struct loads, struct
pointer assignment, or general pointer-based aggregate operations.
Verification: focused Bytecode red then green; `ninja bin/ut`; and
`bin/ut --random` plus replay with seed `2456686981` passed.

`pointer.addressOfRefReturningCallAliasesArgument` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported expression in bytecode core: &self(i)`. A direct scalar
`ref` return that returns one `ref` parameter now executes normally, then
forms a typed-frame address of that parameter's original caller lvalue. This
does not add branch-dependent ref returns, ref returns of fields or globals,
or member ref returns. Verification: focused Bytecode red then green;
`ninja bin/ut`; and `bin/ut --random` encountered an unrelated LLVMJit
symbol-materialization failure, while the required
`bin/ut --seed 1147723882 --quiet` replay passed.

`pointer.loopRedeclaredLocalDropsStaleScalarCell` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The row takes the address of a
fresh loop-local scalar on each `foreach` iteration and reads it through that
pointer. The focused Bytecode row passed on its first candidate run,
confirming typed-frame local storage is fresh for each loop iteration. No
production change was needed. This does not add loop-scoped aggregate
lifetimes, general lvalue support, or pointer arithmetic. Verification:
focused Bytecode row; `ninja bin/ut`; and `bin/ut --random`.

`pointer.postIncrementReadsPromotedScalarCell` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The row writes a local through a
pointer in a callee, then post-increments and reads the local in its caller.
The focused Bytecode row passed on its first candidate run, confirming the
typed-frame scalar slot remains authoritative for a direct post-increment
after a cross-frame pointer write. No production change was needed. This does
not add pointer arithmetic, aggregate pointer writes, or general lvalue
post-increment semantics. Verification: focused Bytecode row; `ninja bin/ut`;
and `bin/ut --random`.

`struct.staticArrayCopyRunsPostblitAndDtors` promoted to Bytecode,
2026-07-14: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The row copies a static array of
structs with postblits and destructors, then verifies the corresponding
lifetime effects. The focused Bytecode row passed on its first candidate run,
confirming the existing aggregate copy and lifetime paths match compiled D.
No production change was needed. This does not add dynamic-array lifetime,
class lifetime, or general aggregate assignment semantics. Verification:
focused Bytecode row and `ninja bin/ut` passed. `bin/ut --random` failed in
the unrelated Interpreter `dependencyImage.externDRefReturn` row (seed
`610107794`); its mandated replay instead exposed pre-existing SystemLinker
temporary-library races.

`struct.staticArrayCopyRunsPostblitAndDtors` Bytecode row reverted, 2026-07-15:
the prior day's promotion was premature. Running the full suite in isolation
(`bin/ut -s ut.backends.runner.lang.structs`) crashes the Bytecode row with a
null dereference in `readHeapElement` at
`source/quickbite/backends/bytecode/core/machine.d:2396`, not a passing
result. The focused single-row run in the prior entry did not exercise the
same static-array-of-structs postblit/dtor path in full and missed the crash.
Bytecode has been removed from this fixture's `AliasSeq` per the
omit-don't-pin convention (a backend that cannot run a test is left out of
its matrix, not pinned to a known-bad result). Re-add Bytecode once the VM's
`readHeapElement` handles static-array-of-structs postblit/dtor heap element
copies.

`struct.dollarInIndexAssignReflectsFieldLengthAfterGrowth` promoted to
Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported variable in bytecode core: $` because dynamic-array element
assignment compiled its index without exposing the target descriptor's current
length. The assignment path now scopes the existing active-dollar length slot
around the index expression, matching the dynamic-array read and address paths.
This does not add `$` outside array indices or change array-resize semantics.
Verification: focused Bytecode red then green; `ninja bin/ut`; and
`bin/ut --random` (seed `3401576571`).

`struct.postfixLengthIncrementGrowsRefParamArrayField` promoted to Bytecode,
2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
because dmd lowers postfix `.length++` through a synthetic `ref T[]` local,
which the core copied into an independent descriptor; resizing it therefore
left the original struct field empty. Ref dynamic-array locals now reuse the
initializer's existing descriptor, preserving the lvalue alias and its
pointer writeback metadata. This does not add general ref-local aliases or
ref aliases of array elements. Verification: focused Bytecode red then green
and `ninja bin/ut` passed. `bin/ut --random` exited with signal 11 under seed
`1923927317`; the required replay reproduced the crash after the complete
promoted backend matrix row had passed.

`struct.foreachRefOverFieldArrayPersistsElementWrites` promoted to Bytecode,
2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
because the foreach-lowered `ref Item` local was not represented as a pointer
into the dynamic array's backing block, and forwarding that local to another
`ref` parameter could not use the frame-offset call ABI directly. Struct
element ref locals now retain their backing pointer; a forwarded ref call
copies the struct to a frame temporary and writes it through the pointer after
return. This does not add ref aliases of static-array elements, non-local ref
returns, or structs larger than the VM's existing pointer load/store widths.
Verification: focused Bytecode red then green, focused five-backend matrix,
and `ninja bin/ut` passed. `bin/ut --random` exited with signal 11 under seed
`1300728544` after this promoted row had passed. Before this promotion,
replaying seed `1923927317` reproduced the recorded signal 11 only after the
promoted row and multiple subsequent
struct matrices; a focused sequence from that row through the crash-boundary
matrix passed, so no causal link to commit `1ae75308` was established.

`pointer.refTernaryReturnLowersToAddressOfCall` promoted to Bytecode,
2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row passed on
the rebased upstream at `dd977275`, confirming the existing ref-return call
and conditional-pointer paths already preserve the selected caller lvalue.
No production change was needed. This does not add assignment through a
ternary ref return, member ref returns, or broader ref-return lowering.

`refCall.assignmentToRefTernaryReturnWritesChosenBranch` promoted to
Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported assignment in bytecode core: pick(false, x, y) = 42`.
Assignment through a ref-returning call now recognizes the lowered single
ternary return, traces each branch through a direct ref parameter or a simple
ref-forwarding call, executes the callee, and writes the result to the caller
slot selected by the fixture's literal condition. This does not add runtime
conditions, member or global ref returns, nested conditionals, or general
lvalue-return lowering. Verification: focused Bytecode red then green; passing
focused five-backend matrix; `ninja bin/ut`; and `bin/ut --random` (seed
`2550343385`).

`refCall.assignmentToMemberRefReturnRunsCalleeBody` promoted to Bytecode,
2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed compile-time fixture. The focused Bytecode row was red
with `Unsupported assignment in bytecode core: counter.slot() = 42`. A
ref-returning struct method whose final statement returns a scalar field now
executes the complete method body, including receiver side effects, before
writing the assignment value into that field of the caller's receiver. This
does not add conditional or early member ref returns, non-scalar fields,
class methods, or general lvalue-return lowering. Verification: focused
Bytecode red then green; passing focused five-backend matrix; `ninja bin/ut`;
and `bin/ut --random` (seed `2688354283`).

Review finding 1, member ref-return assignment base, 2026-07-15: the
`tryMemberRefCallAssign` slice above always added the returned field offset to
the method receiver, even when the returned `DotVarExp` was based on a `ref`
parameter. The approved direct SystemLinker/Bytecode regression
`refCall.assignmentToMemberRefReturnUsesReturnedBase` proved compiled D writes
`other.value` for `receiver.slot(other) = 42`; Bytecode was red with
`42 != 0` because it wrote `receiver.value`. Member ref-return assignment now
uses the caller lvalue of a returned ref-parameter base, while implicit
`this`/`super` fields retain receiver-relative lowering and other bases decline
this specialized path. This does not add value-parameter bases, nested field
bases, pointers, conditionals, early returns, or general lvalue-return
lowering. Verification: focused SystemLinker oracle green and Bytecode red;
focused Bytecode/SystemLinker regression green; the prior member ref-return
Bytecode row green; `ninja bin/ut`; and `bin/ut --random` (seed `233816370`,
3389 tests, 0 failed, 6/6 failing as expected).

Review finding 2, conditional member ref return, 2026-07-15: the specialized
member ref-return assignment path trusted the textually final return even when
an earlier conditional return selected a different field. The approved direct
SystemLinker/Bytecode regression
`refCall.assignmentToConditionalMemberRefReturn` proved compiled D writes
`other.value` for `receiver.slot(true, other) = 42`; Bytecode was red with
`42 != 0` because it wrote `receiver.value`. The specialized path now
recognizes the exact `if (parameter) return field; return field;` shape when
the caller condition is a literal, executes the callee, and writes through the
selected return base. Its ordinary final-return path now accepts only
expression-statement prefixes, so unproved control flow declines instead of
silently selecting the final return. This does not add runtime conditions,
`else` returns, nested conditionals, loops, or general lvalue-return lowering.
Verification: focused SystemLinker oracle green and Bytecode red; focused
Bytecode/SystemLinker regression green; and both prior member ref-return
Bytecode regressions green; `ninja bin/ut`; and `bin/ut --random` (seed
`2831149159`, 3391 tests, 0 failed, 6/6 failing as expected).

Review finding 3, repeated ref-foreach argument alias, 2026-07-15: forwarding
one ref-foreach struct local to two `ref` parameters materialized independent
caller temporaries, so their post-call pointer stores competed and the final
store erased the first parameter's field mutation. The approved direct
SystemLinker/Bytecode regression
`struct.foreachRefRepeatedArgumentPreservesAlias` proved compiled D preserves
both writes to the shared array element; Bytecode was red with `0 != 1`.
Repeated forwarding of the same struct-pointer local now reuses one caller
temporary, and the machine keeps callee parameter slots that name the same
caller storage coherent between instructions. Distinct caller offsets remain
separate. This does not add ref-foreach over static arrays, general aggregate
lvalues, or structs beyond the existing pointer load/store widths.
Verification: focused SystemLinker oracle green and Bytecode red; focused
Bytecode/SystemLinker regression green; seven relevant Bytecode ref and
ref-foreach rows green; `ninja bin/ut`; and `bin/ut --random` (seed
`1286042481`, 3393 tests, 0 failed, 6/6 failing as expected).

Review finding 4, member ref-return receiver evaluation, 2026-07-15: the
specialized member ref-return assignment path evaluated a nontrivial receiver
once while reconstructing the returned field destination and again while
emitting the method call's hidden `this` argument. The reviewer's comma
expression fixture was invalid compiled D, so the approved direct
SystemLinker/Bytecode regression
`refCall.assignmentToMemberRefReturnEvaluatesReceiverOnce` uses a
ref-returning receiver helper with the same observable evaluation count.
SystemLinker evaluated the receiver helper once; Bytecode was red with
`2 != 1`. The specialized path now passes its already-evaluated receiver into
call emission. A receiver returned directly from one of its helper call's
`ref` parameters executes that helper once and reuses the original caller
slot, preserving both receiver identity and the outer method's writeback.
This does not add conditional receiver ref returns, non-parameter receiver ref
returns, class receivers, or general ref-return lowering. Verification:
focused SystemLinker oracle green and Bytecode red; focused
Bytecode/SystemLinker regression green; and the three prior member ref-return
Bytecode regressions green; `ninja bin/ut`; and `bin/ut --random` (seed
`1377337795`, 3395 tests, 0 failed, 6/6 failing as expected).

Review finding 5, forwarded receiver argument evaluation, 2026-07-15: caller
offset recovery for a ref-returning receiver executed its selected `ref`
argument again after emitting the receiver call. The approved direct
SystemLinker/Bytecode regression
`refCall.assignmentToMemberRefReturnEvaluatesRefArgumentOnce` forwards
`*pointed(counter, evaluations)` through a ref-returning receiver helper.
SystemLinker evaluated `pointed` once; Bytecode was red while trying to load
the complete `Counter` through its returned pointer. Caller-offset recovery
now follows direct ref-parameter forwarding recursively, including a pointer
returned as `&parameter`, and supplies each recovered offset to call emission
so the corresponding argument is not recompiled. Addressing an inline struct
slot is supported as an opaque struct pointer so the forwarding helper's body
can execute. This does not add conditional forwarding, non-parameter pointer
returns, pointer field access, or general ref-return lowering. Verification:
focused SystemLinker oracle green and Bytecode red; focused
Bytecode/SystemLinker regression green; and all four prior member ref-return
Bytecode regressions green; `ninja bin/ut`; and `bin/ut --random` (seed
`463451710`, 3397 tests, 0 failed, 6/6 failing as expected).

`pointer.arrayAppendRefreshesStaleCellAfterAddressOf` promoted to Bytecode,
2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row passed on its first
candidate run, confirming that appending after taking an element address does
not leave the typed-frame array descriptor stale for a subsequent direct
index write and read. No production change was needed. This does not add
capacity guarantees, pointer validity across reallocation, or broader stale
cell reconciliation. Verification: passing baseline `ninja bin/ut` and
`bin/ut --random` (seed `2372427440`), then the focused Bytecode row and
`ninja bin/ut` passed after promotion. The final `bin/ut --random` passed
with seed `2248053155` (3398 tests, 0 failed, 6/6 failing as expected).

`pointer.boundedSliceAssignmentWritesThroughAddressOfPromotedCell` promoted
to Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row was red with
`Unsupported slice-assignment source in bytecode core: ninetyNine()` because
the core treated every dynamic-array slice assignment as a slice-to-slice
copy. A 4-byte scalar slice-fill opcode now evaluates the right-hand side once
and fills the bounded destination's native backing memory, preserving the
address-taken element alias. This does not add scalar fills for other element
widths, aggregate elements, or static-array slice fills. Verification:
passing baseline `ninja bin/ut` and `bin/ut --random` (seed `4251602219`),
focused Bytecode red then green, passing focused five-backend matrix,
`ninja bin/ut`, and final `bin/ut --random` (seed `3366125856`, 3399 tests,
0 failed, 6/6 failing as expected).

`pointer.sliceParameterWriteThroughRefreshesSourceCellAfterAddressOf` promoted
to Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row passed on its first
candidate run, confirming that a scalar write through a slice parameter
refreshes the caller's address-promoted dynamic-array cell before a subsequent
direct element read. No production change was needed. This does not add slice
parameter rebinding, slice-fill assignment through parameters, or broader
cross-frame cell reconciliation. Verification: passing baseline
`ninja bin/ut` and `bin/ut --random` (seed `1075057334`), then the focused
Bytecode row passed after promotion. Final verification: `ninja bin/ut` and
`bin/ut --random` (seed `2098875150`, 3400 tests, 0 failed, 6/6 failing as
expected).

`pointer.structFieldPointerCompoundIncrementWritesThroughCell` promoted to
Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row passed on its first
candidate run, confirming that compound increment through a pointer to a
struct field writes the updated scalar through the field's promoted native
cell. No production change was needed. This does not add compound assignment
for wider field types, nested struct fields, or broader struct-cell
reconciliation. Verification: passing baseline `ninja bin/ut` and
`bin/ut --random` (seed `3963106144`), then the focused Bytecode row and final
`ninja bin/ut` passed after promotion. Final `bin/ut --random` passed with seed
`2838625850` (3401 tests, 0 failed, 6/6 failing as expected).

`pointer.structFieldRefLocalWriteThroughRefreshesCellAfterAddressOf` promoted
to Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row was red with `1 != 99`
because a scalar `ref` local initialized from a struct field received a copied
slot rather than aliasing the field's inline frame storage. Ref-local lowering
now reuses a resolvable struct field's frame offset, so assignment through the
ref is visible through an earlier pointer to that field. This does not add ref
aliases to heap struct fields, pointer-receiver fields, or broader ref-lvalue
forms. Verification: focused Bytecode red then green, final `ninja bin/ut`,
and `bin/ut --random` (seed `310765499`, 3402 tests, 0 failed, 6/6 failing as
expected).

`pointer.wholeStructAssignmentVisibleThroughEarlierFieldPointer` promoted to
Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row was red with
`Unsupported assignment in bytecode core: s = S(eight(), nine())`. Assignment
to an existing struct local now materialises a supported struct-valued right
hand side and copies the complete native-layout block into the local's existing
frame storage, so an earlier pointer to one of its fields observes the new
bytes. This does not add captured-struct assignment, assignment through struct
pointers or ref-returning lvalues, or postblit/opAssign semantics. Verification:
passing baseline `ninja bin/ut` and `bin/ut --random` (seed `392088283`),
focused Bytecode red then green, final `ninja bin/ut`, and
`bin/ut --random` (seed `3662766452`, 3403 tests, 0 failed, 6/6 failing as
expected).

`pointer.structArrayFieldRefLocalWriteDoesNotDisturbScalarFieldCell` promoted
to Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row passed on its first
candidate run, confirming that rebinding a `ref` local to a non-scalar struct
field leaves an address-promoted scalar sibling cell undisturbed. No production
change was needed. This does not add native-cell representation for dynamic
array fields, ref aliases to heap struct fields, or broader non-scalar struct
field reconciliation. Verification: focused Bytecode row, `ninja bin/ut`, and
`bin/ut --random` (seed `3663640261`, 3404 tests, 0 failed, 6/6 failing as
expected).

`pointer.arrayPointerTakenBeforePlainRebindKeepsPreRebindValue` promoted to
Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row passed on its first
candidate run, confirming that a pointer into a dynamic array retains the
pre-rebind allocation's value after the array variable is rebound and a new
element pointer is taken. No production change was needed. This does not add
pointer validity across append reallocation, shorter-array rebound coverage,
or broader stale-allocation reconciliation. Verification: passing baseline
`ninja bin/ut` and `bin/ut --random` (seed `1658998645`), focused Bytecode row,
final `ninja bin/ut`, and `bin/ut --random` (seed `4232171985`, 3405 tests,
0 failed, 6/6 failing as expected).

`pointer.arrayPointerTakenBeforePlainRebindToShorterArrayDoesNotCrash`
promoted to Bytecode, 2026-07-15: pre-approved promotion of the existing
direct SystemLinker-backed fixture. The focused Bytecode row passed on its
first candidate run, confirming that a pointer into the original dynamic
array remains readable after the array variable is rebound to a shorter
allocation, even when the pointer's original index is past the rebound
array's end. No production change was needed. This does not add pointer
validity across append reallocation, writes through the retained pointer, or
broader stale-allocation reconciliation. Verification: passing baseline
`ninja bin/ut` and `bin/ut --random` (seed `2492861490`), focused Bytecode row,
final `ninja bin/ut`, and `bin/ut --random` passed (seed `843184053`, 3406
tests, 0 failed, 6/6 failing as expected).

`pointer.arrayPointerTakenBeforeAppendKeepsPreAppendValue` promoted to
Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row passed on its first
candidate run, confirming that a pointer into an array's pre-append allocation
retains its original value after a reallocating append, a new pointer into the
post-append allocation, and a write through that new pointer. No production
change was needed. This does not add append capacity guarantees, writes through
the retained pointer, or broader stale-allocation reconciliation.
Verification: passing baseline `ninja bin/ut` and `bin/ut --random` (seed
`1860012521`), focused Bytecode row, final `ninja bin/ut`, and
`bin/ut --random` (seed `3092187886`, 3407 tests, 0 failed, 6/6 failing as
expected).

`pointer.arrayElementWrittenDirectlyIsVisibleThroughEarlierPointer` promoted
to Bytecode, 2026-07-15: pre-approved promotion of the existing direct
SystemLinker-backed fixture. The focused Bytecode row passed on its first
candidate run, confirming that a direct element assignment updates the
dynamic array's native backing storage observed through an earlier pointer.
No production change was needed. This does not add writes through pointers,
cross-frame array pointer aliases, or broader array-cell reconciliation.
Verification: focused Bytecode row, `ninja bin/ut`, and `bin/ut --random`
(seed `803268194`).

`pointer.childMintedArrayIdEscapingUpwardDoesNotResolveThroughParentCell`
promoted to Bytecode, 2026-07-15: pre-approved promotion of the existing
direct SystemLinker-backed fixture. The focused Bytecode row passed on its
first candidate run, confirming that a pointer escaping from a recursive
child frame continues to name the child's dynamic-array allocation rather
than resolving through the parent's same-declaration cell. No production
change was needed. This does not add writes through escaped pointers,
cross-frame array rebinding, or broader allocation-identity reconciliation.
Verification: passing baseline `ninja bin/ut` and `bin/ut --random` (seed
`3491366481`), then the focused Bytecode row and final `ninja bin/ut` passed
after promotion. Final `bin/ut --random` passed with seed `2435388898` (3409
tests, 0 failed, 6/6 failing as expected).
