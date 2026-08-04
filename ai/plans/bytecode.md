# Bytecode VM Architecture Plan

## Summary
Continue building the bytecode VM for D behind the existing
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
  for byte, following `dmd-backend.md`'s `SystemLinker` contract.
- `Ctfe` is not an oracle. Where `Ctfe` diverges from `SystemLinker` (e.g.
  the static-array-copy aliasing quirk), the VM produces the
  compiled-D result and the divergence is characterized against `Ctfe`,
  not emulated.
- Re-entrancy (keeping the deferred CTFE swap possible): the VM core is
  re-entrant with no global mutable state, entry is per-`FuncDeclaration`
  rather than per-module, and results are reachable as raw memory plus a
  static type, so they can be reified as a DMD `Expression` just as well as
  a `quickbite.lang.Value`.

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
- Pointer metadata keeps opcode scalar type and native element byte stride as
  separate facts. Aggregate pointees use the non-scalar opcode marker, but
  stepping and slicing still use DMD's size of the immediate pointed-at type
  (`int[]*` advances by a slice descriptor and `S*` by `S.sizeof`). Never infer
  byte stride from the scalar opcode type.
- Known native-layout violation to fix: the VM's slice descriptor
  (`writeSliceDescriptor`) is `{ptr, length}`, but compiled D lays a slice out
  as `{length, ptr}` (length at offset 0). The FFI bridge already matches real
  D and word-swaps at the boundary (`readResult`/`fillArgument`). Flip the VM
  descriptor to native order and delete both swaps; until then, any pointer to
  a descriptor crossing the bridge unswapped (`int[]*`, a struct with a slice
  field passed by reference) reads ptr-as-length on the native side. The flip
  touches every descriptor read/write site (`subSlice*`, `indexLoad*`, bounds
  checks) and needs a bridge round-trip test of a struct containing a slice
  field.
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

### Strings are ordinary arrays

A `string`-typed frame slot is a normal 16-byte native-order slice
descriptor, identical to every other `T[]`. What is special about strings is
only their backing storage: literal content lives in its own stable,
read-only `Program.literalBlocks` entry, stored at the declared element
width (`char`/`wchar`/`dchar` code units, not unconditionally UTF-8), one
block per literal so a block never moves once allocated. A literal's
`literalBlocks` index appears in exactly one place — constant-pool-like
operands (`Op.loadDataPointer`/`Op.loadStringLiteral`) — and is materialised
into a real pointer by a single literal-load instruction at descriptor
construction. Frames, fields, and the FFI bridge only ever see real
pointers. Specialness lives in storage, never in the frame — the same
asymmetry compiled D gives string literals (`.rodata` placement, merged and
deduped, with no descriptor-shape difference).

Consequences, all by construction: sub-slices, indexing, `.ptr`, assignment,
bounds checks, copying, and truthiness (`if (s)` / `assert(s)` compile as the
ordinary `ptr !is null` pointer test — `null` and `""` are distinguishable by
the pointer word) reuse the generic dynamic-array paths with zero
string-specific opcodes; heap-backed strings (`.idup`, appends) are not a
second representation, just a different pointee, so no provenance predicate
or compile-time rebinding exists; `wstring`/`dstring` need no gates because
storage matches stride. Type never selects a representation; nothing
inspects a value's origin to decide its shape.

Not in scope: value interning — D strings are slices with observable `.ptr`
identity and memory-sharing sub-slices, so canonical-object interning
contradicts the compiled-D oracle; deduplicating identical literal bytes
across `literalBlocks` entries is storage-side, invisible, and compatible.

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

Exposing test (compiled oracle): a module containing
`int counter; static this() { counter = 40; }` and
`int bump() { return counter += 2; }`, with a unittest asserting
`bump() == 42`. This forces segment storage, constructor-before-first-access
ordering, and function-level rather than unittest-body visibility of the
global.

### No universal runtime value type
- `quickbite.lang.Value` must not appear in the bytecode compiler, the
  bytecode format, or the VM. Every operand's type is static; the compiler
  selects type-specialised opcodes at emit time from the semantic type, and
  no handler dispatches on a runtime tag.
- `Value` is constructed in exactly one place: the `Evaluator` boundary,
  where the final result is reified from frame memory plus its static type,
  the way a debugger renders memory using type metadata. `Runner` needs no
  `Value` at all — pass/fail plus diagnostic strings.
- `ai/plans/value.md` defines the `Evaluator` contract as a rendered display
  string. Boundary reification is private interim scaffolding to delete once
  this backend executes the in-program formatter prelude.

### Display-scaffolding deletion inventory
The interim display scaffolding below is scheduled for deletion when the
prelude formatter lands on this backend (`ai/plans/value.md` decisions 3/4).
Do not add cases, types, or metadata to any of it.
If a test can only pass by extending one of these, the test waits for
formatter execution rather than growing the scaffolding.

- `source/quickbite/backends/evaluator.d`: the shared
  `displayString(Value, ...)` interim renderer — deleted with the formatter
  wiring (`value.md` remaining-work item 2).
- `source/quickbite/backends/bytecode/core/compiler.d`:
  `structDisplayField` display metadata (nullable pointer / delegate /
  class-reference field kinds) and the `ResultType` enum value-name maps.
- `source/quickbite/backends/bytecode/core/reify.d`: display-only `Value`
  construction — `Value.structDisplayValue`, `Value.enumValue`, the
  `Value.stringValue` width variants, and nullable-field `Value.null_` /
  `Value.undisplayable` rendering.

Reification itself — reading frame bytes at a static type at the
`Evaluator` boundary — is not deprecated; it remains a debugging instrument.
What is deprecated is growing its *display* vocabulary: any
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
- Native argument slot stride is an addressing contract only: it is wide
  enough for the widest bridge value, but every emitter and marshaller reads
  or writes the argument's actual ABI width. Scalar constant loads must never
  use the stride as their copy width; for example, a null pointer writes
  `size_t.sizeof` bytes while an array descriptor writes two native words.
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
- Multi-thread execution is implemented when a compiled-D behaviour requires
  simultaneous threads. Host runtime calls and single-thread concurrency
  state reached before then are ordinary VM implementation work. Keep the
  design ready: no module-level mutable VM state, one machine instantiable per
  thread, and heap and provenance structures designed to become shared-capable.
- Known exception to "no shared mutable state": the compile-on-first-call
  function cache is per-machine shared mutable state and needs a lock or
  per-thread compilation when threads arrive.
- Until then the VM executes single-threaded; TLS and `__gshared` coincide
  (see Module-level state).

### Boundaries
- DMD AST and semantic types are visible only to the compiler module; the
  bytecode format and VM consume bytecode-native ids and metadata only.
- Backends remain isolated from each other; the bytecode core shares nothing
  with the Interpreter or IR backends.

## Implementation Direction

The current `Bytecode` backend is the typed-frame, native-layout VM. Extend
that backend directly. There is no narrow promotion frontier: the product
target is arbitrary D code reached from real unittest blocks.

### Immediate gate: complete the existing Bytecode baseline

Before looking for gaps in an external project, make every applicable existing
in-repo `SystemLinker`-oracle test include `Bytecode` and pass. In particular:

- Every `Omit!(Bytecode, Because.unconfirmed, ...)` is implementation work in
  the current queue. It is not evidence that the useful promotion frontier has
  ended, nor permission to move on to an external benchmark.
- Promote one existing `SystemLinker`-backed row by deleting its Bytecode
  `Because.unconfirmed` omission. This matrix promotion is pre-approved.
  Observe the concrete red failure, implement the smallest general D semantic
  that makes the row pass, verify the suite, and repeat.
- The cerealed exception-message row remains paused until its wrong-result
  cause is isolated; do not re-enable it on presumed exception or formatting
  support.
- Phobos, druntime, `File`, `Random`, `Concurrency`, lazy structs,
  archive-backed imports, and FFI are normal ways arbitrary D unittest code
  reaches the VM. Unsupported constructs on those paths are expected VM work.
  A broad dependency path may be decomposed into bounded language or runtime
  semantics, but it must not be dismissed as speculative merely because it is
  broad.
- Keep every enabled Bytecode row green. `ninja bin/ut` and repeated
  `bin/ut --random` runs must be green and stable. An order-dependent crash or
  hang is a blocker to reproduce with the reported seed and fix; it is not
  acceptable handoff noise.
- A regression in an enabled row blocks the next promotion. Diagnose it from
  the semantic AST shape and restore the general compiler path before taking
  another queue item.
- Do not run `bench.sh --dub cerealed` to discover the next gap until this
  complete existing Bytecode baseline is enabled and green. Once the baseline
  is complete, Cerealed is the next real-project gate. Distil each benchmark
  failure into the smallest D-language fixture backed by `SystemLinker`, then
  follow the normal approval rule before adding or changing that test.

There is no ordered starter queue anymore. Continue by searching all backend
matrices and characterization pins for remaining Bytecode exclusions.
Preserve only exclusions that are genuine oracle characterizations or
architectural non-goals with an explicit reason. An unsupported
implementation is not, by itself, a permanent divergence from the compiled-D
oracle.

Current Bytecode support boundary -- a starting point for finding the next
row, not a guarantee. Reconfirm against the source before relying on it.

- Associative arrays. Keys: scalar, `string`, and struct. A struct key with at
  least one top-level `string` field compares structurally, field by field and
  `string` fields by content, via `structKeyFieldLayoutOrNull` and a
  `Program.assocArrayKeyLayouts` side table, in any combination, count, or
  order of `string` and scalar fields; an all-scalar struct key compares as raw
  bytes. A struct key with no top-level `string` field but some array-typed
  field (including through a nested struct) throws, as do `wstring`/`dstring`
  keys and a nested-struct or `wstring` field inside an otherwise structural
  key. Values: scalar, dynamic array, struct, static array, delegate.
  `find`/`insert`/`remove` are a linear scan over `keysEqual`, not a hash
  table, so there is no hash to keep consistent with equality.
- Module-level (`__gshared`/`static`) variables: scalar, struct, dynamic
  array, scalar-element static array, pointer, associative array, delegate,
  and `cdouble`. Dynamic-array literal initializers cover constant scalar and
  struct elements at any nesting depth, plus `[]`; the other kinds take only
  their default initializer, and a struct/array/delegate/complex *element* of a
  module static array declines. Field and element access materialises a block
  and writes back only the bytes it touched. `Ctfe` cannot read or write
  dataseg storage at all; `Interpreter` has a separate pre-existing gap where a
  write through a pointer into dataseg storage does not mirror back.
- Delegates and closures: see the Closures section.

Known blocked rows, stated as the blocker rather than the symptom:

- `concurrency.thisTid.Bytecode` (`sys/concurrency.d`). `Scheduler.thisInfo`'s
  `atomicLoad(scheduler)` (an 8-byte reference) is usually the supported
  `RDX`/`RAX` atomic-load inline-asm shape (`tryCompileAtomicLoadAsm`), but
  order-dependently (seed 543485028) the same call site compiles to a second
  shape using 32-bit `EDX`/`EAX` value registers. Why the same load takes
  either shape is not characterized. Do not add a matching `EDX`/`EAX` opcode
  without first confirming, against a disassembled `SystemLinker` build of this
  exact fixture, that a 4-byte-wide atomic read is the correct oracle behaviour
  here rather than a truncation of the real 8-byte reference.
- `file.createWriteRead.Bytecode` (`sys/file.d`). `std.stdio.File`'s
  refcounting is `shared`, and DMD's `core.atomic` lowers `atomicOp!"+="` on
  this platform to inline x86 asm (`lock xchg` then a plain store) rather than
  a compiler intrinsic; the bytecode core has no inline-asm support. Either
  implement that specific `lock`-prefixed read-modify-write/store sequence, or
  recognise `atomicOp`/`atomicLoad`/`atomicStore` by symbol (as the `std.math`
  builtins already are) and lower them to dedicated VM atomic ops.
- `refArgument.templateRefSharedParameterMutatesAndPreservesAddress` and
  `refArgument.templateRefSharedForwardsThroughNestedFunction`
  (`expressions.d`) assert `&value == expected` across a `ref` call boundary.
  Both are blocked on the ref calling convention below, not on
  template/`shared` specifics, so neither is a bounded single-commit row.

Ref calling convention -- the largest known correctness hazard in the current
core, and the blocker for the rows above. A scalar `ref` argument is passed as
a value mirrored into a fresh frame slot and written back after the callee
returns, not as a pointer the callee dereferences. Every ref-argument kind
that binds non-frame-resident storage (`emitModuleScalarRefArgument`,
`emitStructPointerRefArgument`, `emitStructPointerFieldRefArgument`,
`emitClassFieldRefArgument`, `emitRefLocalPointerArgument`,
`emitPointerDereferenceRefArgument`) shares one hazard: if the callee also
reaches that same storage by another path during the call, the post-call
writeback clobbers the direct write regardless of program order. Real ABI
`ref` has no such race. `referenceOffset`'s ordinary `_locals` path has it
too, so `&value` inside a callee never equals the caller's `&value`.
Reordering cannot fix it, because the callee never reaches the real address
through the parameter at all. A real fix makes a scalar `ref` parameter a
pointer the callee dereferences on every access, bound directly to the real
address (e.g. via `Op.moduleAddress`), dropping the mirror/writeback pair
entirely -- a change to the convention every ref-argument kind shares, not a
narrow field-offset fix.

Live hazards and divergences to reconfirm against current source when a row
reaches them:

- A `T[N][]`'s rows are separately heap-allocated inner descriptors, so a
  pointer taken into one row (`&outer[i][j]`) is valid within that row, but a
  flat pointer walk across rows diverges from compiled D's contiguous layout.
- `arr[0][0]` on a `T[N][]` throws "Unsupported static array access": the
  `Tarray`-gated `tryDynamicArrayIndex`/`indexedArrayDescriptor` decline a
  `Tsarray` sub-expression, so compilation falls through to the
  static-array-chain path, which has no notion of a dynamic-array base. A
  clean diagnostic, not a wrong answer.
- Static arrays of dynamic arrays copy each element's full 16-byte slice
  descriptor; nested mutation and general stale-cell reconciliation remain
  incomplete.
- Captured array support does not yet cover every read, write, slice, append,
  view-preservation, and closure combination.
- A broadcast fill (`arr[0 .. 2] = value;`) declines when the destination
  element is itself a heap-allocated row descriptor (`T[N][]`/`T[][]`):
  broadcasting into it needs a fresh row allocation per element, not a byte
  copy.
- Dynamic-array and string sub-slices bounds-check both ends
  (`validateSubSlice`, `machine.d`). A raw pointer slice performs no check at
  all -- confirmed correct, not a gap: compiled D's own `p[lo .. hi]` on a bare
  `T*` has no runtime bounds check either (verified against `dmd`, including
  `-boundscheck=on` and `-release`; a raw pointer carries no length metadata to
  check against). Do not add one; it would diverge from the oracle.
- A struct-receiver method delegate cannot be called through a delegate
  parameter: its context is a caller-frame-relative offset into a receiver
  block, not the single pointer word a lambda or nested function carries, so
  `Op.callIndirectDynamic` rejects it on `CompiledFunction.hasThis`
  (`delegate.structReceiverPassedAsParameterIsRejected`). Making it callable
  needs the receiver encoded frame-independently -- a real pointer to the
  receiver block -- which changes how every struct method receives `this`.
- The static-delegate-registry hack (`_staticDelegateAssocArrays`,
  `tryStaticDelegateAssocArrayAssign`, `tryStaticDelegateAssocArrayCall`,
  `staticDelegateAssocArrayDeclaration`, `compiler.d`) exists to pass one
  `cerealed.d` row (`classSerialisationReadsStaticChildRegistry`,
  `Writer.childWriters`, a `Taarray`-of-delegate static struct field). It
  matches any module/static `Taarray`-of-delegate declaration, ignores the key
  (one global slot per declaration, last-write-wins), and falls back to a
  cross-call-site global (`_latestStaticDelegateAssocArrayFunction`). The
  general delegate-AA path is confirmed NOT yet a superset of it -- forcing
  both entry points to decline still fails that row -- so do not remove or
  narrow it without a real fix backing it, and note that any change to how a
  delegate-typed store resolves can starve that fallback and break the row.

Next candidate. Every remaining `Omit!(Bytecode, ...)` row is one of the
blocked rows above, so a matrix search will not surface a bounded one. No
named closure-escape gap remains in the Closures section either -- the
class-field/array-element further-mutation question is now a confirmed and
declined shape (`delegate.classFieldEscapingCaptureDeclines`,
`delegate.arrayElementEscapingCaptureDeclines`), not an open question. Find a
fresh row through `bin/qb` exploration of read-modify-write and mirror paths,
take the "Structural consolidation queue" width-authority item (still open:
generalising `dynamicArrayElementSize`/`pointerElementMetadata` into one width
authority), or take an "Architecture work forced by the baseline" front.

### TDD and handoff discipline

- Promote one named existing oracle-backed row, or one tightly related family,
  at a time. A new test or a change to test behaviour still requires approval
  before editing the test.
- Start from the row's observed failure, not a predicted implementation. Make
  the smallest honest implementation that expresses the required D semantic;
  do not add backend-specific fixture workarounds.
- Broad library paths should be reduced into sequential semantic rungs. Use
  the candidate promotion as an uncommitted red integration target. If it
  cannot turn green in one bounded change, leave its matrix omission in place
  while approved smaller fixtures force reusable prerequisites, then promote
  the integration row in the commit that makes it green.
- Work serially in `source/quickbite/backends/bytecode/core/**`; adjacent
  features converge on the compiler, machine, and program modules. Parallel
  work belongs only to file-disjoint tracks such as `ai/plans/value.md` and
  `ai/plans/ffi.md`.
- After each editing session, run the repository-mandated
  `ninja bin/ut` and `bin/ut --random`. Replay a failing random order with its
  `--seed` before deciding whether the failure is related.
- A plan update names the next concrete failing row or semantic so another
  implementer does not duplicate work. Remove resolved queue entries instead
  of recording what prior changes did. Git history is that record.
  Do not make a plan-only boundary commit to avoid implementation work.

### Architecture work forced by the baseline

The row-driven loop determines the exact order, but the remaining dependency
paths are expected to exercise these architectural fronts:

1. Complete arrays, pointers, capacity, and lifetime semantics using real
   native-layout storage and aliases.
2. Execute available Phobos and druntime source, including templates,
   delegates, closures, classes, exceptions, and module initialization.
3. Widen the outbound native bridge for body-less leaves, aggregate returns,
   host resources, and archive symbols. Keep the bytecode-owned work in this
   plan and coordinate shared FFI seam work through `ai/plans/ffi.md`.
4. Synthesize runtime type metadata and inbound VM entry thunks when druntime,
   callbacks, finalizers, associative-array methods, or virtual dispatch force
   them.
5. Support the host-facing runtime needed by `File`, entropy, and concurrency
   while keeping the VM core re-entrant and free of module-level mutable state.

These are implementation areas, not reasons to postpone a promoted row. A
broad row may require several prerequisite commits, each ending with a green
enabled matrix and a forward-looking next-row update.

### Structural consolidation queue

Approved deepening work, distinct from the row-driven queue: each item lands
as bounded, behaviour-preserving ride-along commits on the serial bytecode
track, with the enabled matrix green after each commit. Order: width first,
place second.

1. **One width authority.** Element/operand byte width is hand-derived at
   dozens of emit sites, and `ScalarType.void_` (size 0) doubles as the
   aggregate sentinel, so an omitted width becomes a silent zero-byte copy
   instead of a compile error. Two sub-pieces.

   Still open: generalise `dynamicArrayElementSize`/`pointerElementMetadata`
   into the single width authority every emit site's width *computation* goes
   through. Each site still derives its own width today
   (`dynamicArrayElementSize`, `staticArraySize`, `size(scalarType)`, ...).

   Done: every width-suffixed opcode family (`indexLoad*`/`indexStore*`,
   `pointerLoad*`/`pointerStore*`/`pointerSlice*`, `subSlice*`,
   `appendElement*`, `dupArray*`, `concatArrays*`, and
   `sliceCopy*`/`sliceFill*`/`sliceEqual*`) is emitted only through a
   per-family `emit*` helper in `compiler.d` that takes width as a required
   parameter and builds the `Instruction` itself, so an `*N` instruction can no
   longer be constructed with a silently-defaulted-to-zero width operand. The
   three slice families needed separate helpers rather than one shared helper:
   `sliceCopy` covers 1/2/4/8/16 plus `N`, `sliceFill` covers 1/2/4/8 plus `N`
   (its broadcast source is a scalar, never a descriptor element), and
   `sliceEqual` covers only 1/2/4/8 with no `N` variant at all.
   `Op.sliceEqualNested` is a genuinely different opcode with its own
   depth/element-width operands and keeps its own `emitNestedArrayEqual`
   construction site.

2. **One place resolver.** Lvalue addressing is enumerated per shape: the
   `emit*RefArgument` chain with its comment-encoded decline order,
   `referenceOffsetOrNull`, the `*Offset`/`*Address` helpers, and three
   writeback-mirror mechanisms (module, frame, pointer) with per-shape flush
   loops. Consolidate on the compose-per-hop model that
   `structBaseOffsetOrMaterialise`, `capturedFrameIndex`, and the
   class/struct static-array chain plumbing already use: one place value
   (base, hop chain, width, writeback rule) returned by one resolver,
   consumed by emit sites and a single flush path. A new language-surface
   shape extends the resolver, never adds a sibling emitter.

Reviewed and declined (2026-08): a bytecode-core disassembler with
instruction-level emission pins — not worth tackling; do not re-propose.

### REPL and formatter ownership

`tests/ut/bin/repl.d` is parity work against the existing interactive backend
behaviour and currently has no `SystemLinker` rows. It does not take precedence
over the baseline gate above.

Rendered-value REPL rows are earned by executing
`__quickbiteFormat` (`quickbite.repl_prelude`) as ordinary D, not by extending
the interim `Value` display vocabulary. `ai/plans/value.md` owns the shared
formatter contract and the non-bytecode formatter wiring. This plan owns the D
semantics needed for the bytecode VM to execute that formatter. Non-display
REPL behaviour remains ordinary bytecode work once the oracle-backed baseline
and Cerealed gate no longer expose earlier gaps.

### General implementation constraints

- Keep DMD AST and semantic types in the compiler boundary. The bytecode
  program representation and machine must use bytecode-native ids and
  metadata.
- Keep the backend adapter, compiler, program representation, and machine
  separate. Do not hide bytecode logic in the adapter.
- Preserve a strict semantic-AST-to-bytecode-to-execution pipeline. Do not add
  an IR pass; unittest compilation latency is on the hot path.
- Keep unsupported behaviour explicit and diagnostic while it is outside the
  currently promoted row. Never silently lower, guess, or emulate `Ctfe` when
  it differs from compiled D.
- Admit an inline-asm subset only from a frontend-preserved stream containing
  every token's kind and spelling, with exact whole-instruction-sequence
  validation. Punctuation, size qualifiers, memory operands, literals, and
  extra instructions must not collapse into a supported identifier shape.
- Do not infer code structure from source text. Ask the frontend for structured
  cells, declarations, statements, and expressions.
- Make opcodes and metadata earn their shape from a behaviour. Prefer existing
  typed operations over one-off language-operation opcodes when their
  semantics are identical.
- Arithmetic and comparison handlers may use compiler-selected typed opcode
  variants where static selection removes runtime type dispatch.
- Derive builtin identity mechanically from DMD's semantic classification;
  do not duplicate mangling conventions or maintain a list of guessed symbol
  spellings.
- Treat bytecode as an internal artifact, not a public serialization format or
  compatibility promise.
- Preserve the architecture's explicit CTFE-engine-replacement deferral,
  AST/compiler boundary, native-layout model, backend isolation, and
  measurement-driven optimization rules. Do not invent a narrow-slice product
  boundary that conflicts with running arbitrary D unittest code.

## Verification

- Use public behaviour tests for D semantics and backend parity.
- Use focused VM contract tests only for bytecode-specific properties such as
  operand typing, frame behaviour, and diagnostic boundaries.
- Compare language behaviour and diagnostic text with `SystemLinker`, byte for
  byte. Characterize `Ctfe` separately when it diverges.
- Verify a promoted row red before production changes and green afterward.
- Run `ninja bin/ut`, then `bin/ut --random`, after each editing session. Use
  the reported seed for any failure investigation.
- Run `ci.sh` before creating a PR. Do not accept a benchmark failure merely
  because the current PR advances only part of the full VM.

## Performance

- Correctness and baseline stability precede optimization.
- Measure post-parse execution against `SystemLinker` and the project
  benchmarks at meaningful semantic checkpoints.
- Optional bytecode peephole optimization is the first optimization candidate
  after measurement justifies it. Keep it runtime-togglable so the same body
  of D code can compare optimized and unoptimized bytecode.
- Do not seal or hash emitted bytecode before an optional optimization pass can
  run.
- Keep the interpreter dispatch compatible with a measurement-driven switch
  from `final switch` to direct threading without requiring a bytecode-format
  rewrite.

## Builtins and Native Calls

- Builtin parity (`sqrt`, `fabs`, and similar operations) stays mechanically
  tied to DMD's builtin classification and is executed by the VM.
- Druntime lowerings with available source execute as D bytecode. Body-less
  leaves use the native bridge.
- Native-layout values cross the bridge unchanged. Cached libffi descriptors
  perform the call; bridge entries cache typed signatures, CIFs, and symbol
  resolution.
- Native `Throwable`s crossing the boundary are converted to VM unwinding, and
  VM exceptions crossing an inbound thunk become native unwinding.

## Exception Handling

- Each compiled function artifact carries a handler table.
- Handler records include their protected range, kind, optional caught type,
  optional catch-binding slot, catch order, and enough continuation metadata
  for `finally` to resume throw, return, branch, or normal fallthrough.
- The VM selects a handler or unwinds the frame on throw and assert failure. D
  exceptions must not propagate silently through every interpreter frame.
- Thrown objects are real `Throwable` instances on the host heap.
- At the evaluator boundary, every uncaught D `Throwable` becomes the
  observable diagnostic message; `Error` subclasses are unittest failures,
  not host-harness escapes.

## Debug Information

Maintain bytecode-offset-to-source-line mappings sufficient for compiled-D
assertion diagnostics. Add variable-name tables only when an active debugger
or REPL behaviour requires them.

## Constant Pool

Deduplicate constants within the VM session, compilation batch, or artifact
cache generation. Give the intern table allocator-owned lifetime plus explicit
reset or invalidation. Cross-artifact interning must use the same key and
lifetime as the dependency bytecode cache.

## Closures

- Captured variables live in a GC-heap closure environment addressed through
  an environment pointer, matching DMD's computed capture set and native
  layout. Non-captured locals remain frame slots.
- Do not add dynamic open/closed-upvalue machinery; DMD semantic analysis has
  already determined `needsClosure()` and `closureVars`.
- Native callbacks that receive delegates use the inbound trampoline described
  under Native bridge.
- A call site handing a callee its nested-function context always passes its
  own live frame (`Op.frameBaseIndex`), matching real D: a nested function's
  context is its immediate enclosing function's frame, never a further
  ancestor's, so the call site never needs to know or forward anything about
  what the callee (transitively) captures. Reading a captured variable owned
  further up the enclosing-function chain than one level
  (`capturedFrameIndex`, `compiler.d`) walks the remaining hops itself: each
  intermediate ancestor's own received context lives at that ancestor's own
  `nestedContextOffset` within the frame just reached, still live on the stack
  as the current call's transitive caller. `_capturedOwners` records, per
  captured `VarDeclaration`, the function whose frame its offset is relative
  to, so the read site knows how many hops to walk.
- A nested function that reads its enclosing struct method's `this` (a
  capturing lambda literal, `() => this.field`, or a plain nested named
  function) needs a hidden `this` receiver, not a captured-locals environment:
  DMD gives both shapes an identical `vthis` context pointer
  (`FuncDeclaration.isNested`), and `ThisExp` resolution inside either resolves
  to the nearest enclosing method's own `vthis`. `capturedThisStructDeclaration`
  recognises this, keyed on `vthis` plus the enclosing parent being a struct
  method, and only when the enclosing struct is not itself function-nested: a
  struct declared inside a function appends an extra hidden context-pointer
  field after its declared fields (`AggregateDeclaration.isNested`) that this
  path's frame layout does not account for, so a function-nested struct falls
  back to the plain unsupported diagnostic. A direct unqualified call to such a
  nested function gets a call-site receiver branch in `methodReceiverOffset`
  for the plain `VarExp` callee shape. This is a `this`-receiver question, not
  captured-locals-environment work, and needs no closure environment.
- Frame-escaping capture. A delegate that captures a local and outlives the
  declaring frame needs a real GC-heap environment, since the frame-relative
  mechanism above addresses a live stack frame.
  `heapClosureContextOrNull` (`compiler.d`) provides one for a narrow shape:
  one or two captured locals, each scalar- or pointer-typed, captured one level
  up from a non-`this`-receiving function, escaping either as a direct
  `return dg;` (`compileDelegateReturn`) or as a top-level delegate field of a
  directly returned struct literal (`structLiteralReturnOffset`). Each capture
  gets a full machine-word slot regardless of its own narrower width, so the
  `pointer + index * width` addressing divides exactly for every scalar width.
  Everything outside that shape -- three or more captures, a
  non-scalar/non-pointer capture, a multi-level capture, a capture combined
  with `this` -- declines through `throwFrameEscapingDelegateDiagnostic`.

  Soundness rests on the escape site being the last thing its function
  executes, so the frame slots and the heap snapshot cannot diverge. That holds
  for a `return`. It does NOT hold for a mid-function site, which is why an
  `out`/`ref`-parameter assignment declines a capturing rhs unconditionally
  (`refEscapingDelegateOperandOffset`) rather than heap-escaping it. Preserve
  that invariant when widening: a new escape site must either be its function's
  last act, or move the variable to the heap from declaration onward.

  A capturing delegate assigned into a class field
  (`tryClassPointerField`'s `Tdelegate` branch) or a dynamic-array element
  (`tryDynamicArrayElementAssign`'s `Tdelegate` branch) now routes through
  `heapEscapingDelegateOperandOffset`, the same heap-box-or-decline treatment
  `compileDelegateReturn` and `structLiteralReturnOffset` already gave a direct
  `return dg;` or a struct literal's delegate field
  (`delegate.functionReturningClassWithCapturingDelegateFieldIsCallable`,
  `delegate.functionReturningArrayWithCapturingDelegateElementIsCallable`).
  `structLiteralReturnOffset`'s `isReturnEscaping` flag forwards through every
  nested `Tstruct` field regardless of depth
  (`delegate.functionReturningNestedStructWithCapturingDelegateFieldIsCallable`),
  so a capturing delegate field nested arbitrarily deep inside a directly
  returned struct literal gets the same heap-box-or-decline treatment as a
  top-level one. Unlike `compileDelegateReturn`'s `return`-based sites, a
  class-field/array-element write is not itself the function's last act, so a
  further same-function mutation of the captured locals between the write and
  the aggregate's actual escape can diverge from the heap snapshot taken at
  the write -- confirmed (not hypothetical): before the gate below existed,
  `int total = 40; c.next = () => total + 2; total = 100; return c;` silently
  returned 42 instead of SystemLinker's 102, the same silent-wrong-answer
  shape `delegate.outParameterEscapingCaptureDeclines` documents for the
  `ref`/`out`-parameter escape site. `heapEscapingDelegateOperandOffset` now
  takes a `mayMutateAfterHeapBox` flag, set at exactly these two call sites,
  that runs `capturedLocalsMayBeMutatedInCurrentFunction` (`compiler.d`) --
  an order-insensitive scan (`CapturedLocalMutationScanner`, a
  `SemanticTimeTransitiveVisitor`) for any write to, or address-of on, one of
  the captured locals anywhere in the enclosing function, including inside
  further nested function bodies -- and declines
  (`delegate.classFieldEscapingCaptureDeclines`,
  `delegate.arrayElementEscapingCaptureDeclines`) rather than risk it. Being
  order-insensitive and whole-function it over-declines two provably-safe
  shapes it cannot yet be told apart from the unsound one: a mutation
  strictly BEFORE the heap-box write (harmless -- the snapshot already
  reflects it), and a mutation inside the escaping lambda's own body (already
  heap-relative once boxed). Narrowing that needs either control-flow-
  sensitive write-site dataflow or moving the captured locals to the heap
  from declaration onward; neither is attempted here.

  The eventual right design point is DMD's own per-function `needsClosure()`/
  `closureVars` decision -- every closure-needing variable heap-allocated from
  declaration onward, since `needsClosure()` is typically true for any lambda
  whose address is taken at all. Adopting it means moving every
  `capturedFrameIndex` call site (struct and array captures, multi-level
  ancestor chains, `this`-combined captures) onto heap-pointer addressing
  together, not one slice at a time. An immediately-invoked void lambda whose
  body is a single expression statement can avoid needing an environment at all
  by inlining the statement into the caller, the way a single-`return` IIFE
  already does.
- The captured-parent materialisation is only for such nested functions. A
  nested struct method's own `this` remains its current receiver, even when
  that receiver also carries a context pointer.
- `capturedThisStructDeclaration` declines the `this`-receiver shape whenever
  the nested function also has a captured local (`hasCapturedOuterLocal`), even
  though `vthis` is set: the function instead gets an ordinary nested
  frame/closure context, and `vthis` is registered into that same
  captured-offsets map alongside the captured locals, so `this.field` resolves
  through the closure environment like any other captured variable. This covers
  both a nested function that reads an enclosing local and `this.field`
  together, and a pure-local capture with no `this` use at all.

The compiled-D exposing behaviour is:

```d
int local = 1;
auto f = () => local;
local = 2;
assert(f() == 2);
```

Any copy or snapshot representation of the captured local fails this
behaviour.

## Assumptions and Explicit Deferrals

- AST-first lowering from semantically analysed DMD ASTs remains the starting
  point. Direct parser-to-bytecode generation is out of scope.
- The VM is optimized for unittest latency, not long-running throughput. JIT
  compilation remains a future experiment because its compile cost works
  against this goal.
- Linux x86_64 is the first host target. Other targets follow the host ABI
  through the same DMD layout queries and bridge abstraction.
- Replacing DMD's CTFE engine remains out of scope. Checked CTFE legality,
  CTFE-specific diagnostics, and a second execution mode are not part of this
  VM.
- Multi-thread execution may remain deferred until a compiled-D behaviour
  requires multiple simultaneous threads. Host runtime calls and single-thread
  concurrency state already reached by existing rows are not covered by that
  deferral.
