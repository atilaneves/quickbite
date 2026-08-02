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

`AssocArray` (`machine.d`) now stores `V[K]`'s value side as `ubyte[]`
packed at a caller-supplied stride (`assocArrayValueWidth`, `compiler.d`),
reusing `dynamicArrayElementSize`/`dynamicArrayElementType` the same way a
dynamic array carries its own element size; the key side is still a
hard-coded `int[]` (`AssocArray.keys`, `find`/`insert`/`remove` all take a
plain `int`). The remaining row,
`assocArray.structKeyWithStringMemberComparesStructurally`
(`tests/ut/backends/runner/lang/arrays.d`), confirmed still red via a real
`bin/ut` run ("Unsupported variable in bytecode core: __aakey3"): DMD's
`InExp`/index lowering hoists a non-trivial key expression into a synthesized
temporary (`extractSideEffect`, `__aakeyN`, an ordinary struct-typed local,
not a hash/compare function) and passes it to the already-recognised
`_d_aaIn`/`_d_aaGetY` hooks; `compileAssocArrayHook` resolves that key
argument via the generic `compileExpression`, whose `VarExp` handling never
consults `_structLocals` (unlike `structBaseOffsetOrMaterialise`, which
does), so *any* struct-typed key -- even one with only scalar fields --
throws there before reaching the key-storage question at all. Fixing that
alone is not enough to close this row: a struct key with a string member
also needs `AssocArray`'s key side widened (mirroring the value-side
`ubyte[]`/stride work above) and structural, not raw-byte, comparison for
the string member specifically (two equal-content strings from different
calls have different slice-descriptor bytes). Both pieces are needed
together and are a genuinely separate, harder problem than the value-width
work; still not bounded for one commit.

An AA value's storage width now accounts for a dynamic-array-typed value
(`int[][int]`, sized as its own 16-byte slice descriptor via
`arrayElementIsArray`), and `dynamicArrayDescriptorOrNull` (`compiler.d`)
resolves DMD's associative-array rvalue-read lowering (`p[0]`, an `IndexExp`
over the `_d_aaGetRvalueX` pointer result) the same way it already resolved
the `*p` `PtrExp` shape, so `a[k]`'s `.length`/indexing/assignment-from all
materialise the value's descriptor correctly.

A struct-typed AA value's field now reads and writes
(`Point[int] a; a[1].x` / `a[1].x = 5`): `structBaseOffsetOrMaterialise`
gained the `IndexExp`-over-pointer-to-`Tstruct` counterpart of the
array-descriptor branch above, and field write-back gained a
`writeBackThroughPointer` path (`StructField`'s
`pointerBaseSlot`/`pointerIndexSlot`/`pointerStructSize`, mirroring the
existing `viaModule` plumbing) that copies the whole struct block back to
`pointer + index * structSize`.

A *call* through that same AA-value struct receiver now writes its mutation
back too (`Point[int] a; a[1].bump();`): `methodReceiver` gained the
`IndexExp`-over-pointer-to-`Tstruct` receiver branch, reusing
`structBaseOffsetOrMaterialise`'s `viaPointer` output and writing the
(possibly mutated) copy back through `pointerBaseSlot + pointerIndexSlot *
structSize` the same way `writeBackStructField` does for the field case.
`Interpreter` segfaults on the identical shape (`Omit!(Interpreter,
Because.unconfirmed)`, `arrays.d`). Two sibling gaps surfaced by real
`bin/ut` testing (not the `methodReceiver`/receiver-call shape the plan
previously assumed) are fixed alongside it: a struct-typed AA value with a
user-defined `opAssign`, inserted from a literal (`a[1] = Setting(2)`),
lowers to a `ConstructExp` over an `IndexExp` lvalue (DMD blits directly
into the fresh slot; `opAssign` is never called for this shape) --
`compileExpression`'s `ConstructExp` dispatch now also recognises an
`IndexExp` lvalue. Overwriting an *existing* AA entry from another struct
value (`a[1] = existingVar;`, any struct, `opAssign` or not) lowers through
the `_d_aaGetY` slot-pointer write shape (`tryPointerElementAssign` /
`storeThroughPointer`), which only materialised its rhs via
`compileExpression` -- fine for a struct rvalue (literal/constructor call)
but not a struct lvalue; `storeThroughPointer` now routes a struct-typed rhs
through `structOperandOffset` instead.

`tryDynamicArrayElementAssign`'s main branch and
`compileStaticArrayElementAssign` (`compiler.d`) had the identical
`compileExpression`-only-handles-a-struct-rvalue gap `storeThroughPointer`
lost earlier: `arr[i] = existingVar;` for a plain dynamic array of structs,
and the same shape for a compile-time-indexed static array of structs, threw
"Unsupported variable in bytecode core: existingVar" on `Bytecode` while
`SystemLinker` ran both fine. Both now route a struct-typed rhs through
`structOperandOffset`. The other `compileExpression(rhs)`-based assignment
sites in the file (`tryStaticArrayRuntimeElementAssign`,
`tryClassStaticArrayFieldElementAssign`) already went through
`storeThroughPointer` and needed no change.

Writing a struct-typed field of a struct reached through a *dynamic*-array
index (`arr[i].structField = rhs`) now works: `storeArrayElementFieldPointer`
gained a `Tstruct` branch mirroring `storeThroughPointer`'s -- `rhs` routes
through `structOperandOffset` (handling both a constructor-call rvalue and
an existing struct lvalue) and the whole field block is stored through the
pointer at `staticArraySize(fieldType)` bytes instead of a scalar width.
Since `storeArrayElementFieldPointer` also serves the class-array-field case
(`c.arr[i].field = rhs`, `tryClassArrayFieldElementFieldPointer`), the same
fix closes that shape too. `Interpreter` throws "Expected class object." on
`c.arr[i].field = rhs` even for a plain scalar field, unrelated to this fix
and left `Omit!(Interpreter, Because.unconfirmed)`.

A dynamic-array-of-structs element whose field is itself a static array now
writes as a whole value through an array-element pointer
(`arr[i].fixedField = [x, y, z]` and `arr[i].fixedField = existingVar;`,
e.g. `struct Outer { int[3] vals; int tag; } Outer[] arr =
[Outer([1, 2, 3], 10)]; arr[0].vals = [7, 8, 9];`): `storeArrayElementFieldPointer`
gained a `Tsarray` branch that materialises the rhs via
`compileStaticArrayValueInto` (already resolving both an array literal and
an existing array lvalue) into a fresh slot, then block-stores it through
the pointer, mirroring the function's own `Tstruct` branch. Since the same
function also serves the class-array-field case, `c.arr[i].fixedField = rhs`
is fixed too (`Interpreter` still throws "Expected class object." on that
receiver shape, the pre-existing gap noted above, confirmed unchanged).

An *indexed* write into that same static-array field
(`arr[i].fixedField[j] = value`, e.g. continuing the `Outer` example above,
`arr[0].vals[1] = 99;`) was a silent-corruption bug, not a thrown
"unsupported" diagnostic: `staticArrayBaseOffset` resolved
`arr[i].fixedField`'s base offset through `tryStructField`, which for a
dynamic-array-of-structs element (`structBaseOffsetOrMaterialise`'s
`dynamicArrayDescriptorOrNull` branch) returns a throwaway copy of the whole
element with no writeback wiring at all -- unlike the module-struct and
AA-value-struct branches beside it, each of which tracks how to write a
field back to its real storage -- so the indexed write silently landed on
that scratch copy. Fixed generally: `tryArrayElementFieldIndexAssign`
(`compiler.d`) resolves the field's own real runtime pointer the same way
the whole-field-write case does (`tryClassArrayFieldElementFieldPointer` /
`tryStructSliceFieldElementFieldPointer`, so this covers any field-chain
nesting depth and both the struct- and class-array-field receivers) and
advances it by the index via `advanceStaticArrayPointer` (bounds-checked,
and handling a runtime as well as a compile-time index), checked ahead of
`tryStaticArrayElement`/`tryStaticArrayRuntimeElementAssign` in the
`AssignExp` dispatch so neither ever folds an index into the throwaway copy.

The compound-assignment sibling of the fix above
(`arr[i].fixedField[j] += value`) had the identical silent-corruption shape:
`compileAddAssignExpression`'s `IndexExp` handling
(`tryStaticArrayElementAddAssign`) is a separate dispatch from
`compileAssignExpression` and still resolved the field's base through the
same throwaway `tryStructField` copy, silently discarding the increment
instead of throwing. Fixed the same way: `tryArrayElementFieldIndexAddAssign`
(`compiler.d`) resolves the field's real runtime pointer, advances it by the
index via `advanceStaticArrayPointer`, and reads/adds/stores back through
that real address, checked ahead of `tryStaticArrayElementAddAssign` in
`compileAddAssignExpression`. Confirmed via real `bin/ut` that no sibling gap
remains in this family: the other compound-assignment operators
(`-=`/`*=`/`<<=`/`>>=`/`|=`/`&=`/`^=`) still route through
`compileLocalIntegerCompoundAssign`, which throws cleanly for this receiver
shape (`arr[0].vals[1] -= 1;` throws "Unsupported compound assignment in
bytecode core"); a nested field-chain depth (`arr[i].outer.fixedField[j] +=
value`) and a class-array-field receiver (`c.arr[i].fixedField[j] += value`)
both resolve correctly through the same fix.

A *further*-nested index into a multi-dimensional static-array field
(`arr[i].fixedField[j][k] = value` / `+= value`, e.g. `int[2][3] vals;
arr[0].vals[1][0] = 99;`) had the identical silent-corruption shape one
dimension deeper: `arr[i].fixedField[j]` is itself an `IndexExp`, not the
`DotVarExp` the two fixes above pattern-matched on directly, so it fell
through to the general nested-static-array resolver
(`locateStaticArrayElement`/`staticArrayBaseOffset`), which still bottoms
out on `tryStructField`'s throwaway copy for this receiver. Fixed by
generalising both fixes' dot-detection into one recursive helper,
`arrayElementFieldPointer`: it peels `IndexExp` layers one at a time ahead
of the `DotVarExp` base, advancing the field's own real pointer one
dimension via `advanceStaticArrayPointer` per layer, so it subsumes the
single-index case (unchanged behaviour, still any field-chain depth and
either receiver kind) and extends to any dimension count. Confirmed via real
`bin/ut` that a sibling shape is a clean diagnostic refusal, not corruption,
and left unfixed: a *dynamic*-array-typed field indexed through the same
receiver (`arr[i].matrixField[j][k] = v` where the field is `int[][]`)
throws "Unsupported assignment in bytecode core", since
`arrayElementFieldPointer` only resolves a `Tsarray` dimension. Also
confirmed via real `bin/ut`, with no bug found: `p.field += rhs` through a
struct pointer (`tryStructPointerField`/`storeStructPointerField`) and
`c.field += rhs` through a class reference (`tryClassPointerField`/
`storeClassPointerField`) both already write back through the field's real
address.

Next candidate: the dynamic-array-of-dynamic-arrays field indexed write
noted above (`arr[i].matrixField[j][k] = value`, a `Tarray`-typed field
dimension) -- extending `arrayElementFieldPointer` to also resolve a
`Tarray` field/dimension (its `{pointer, length}` descriptor, indexed at the
runtime length rather than `advanceStaticArrayPointer`'s fixed
compile-time-length stride) looks like the same bounded shape as the
static-array generalisation just landed.
`assocArray.structKeyWithStringMemberComparesStructurally` (described
above) remains open and still not bounded for one commit: even after fixing
`compileAssocArrayHook`'s struct-typed-key gap, a string-member key still
needs the wider key-storage-plus-structural-comparison work.

Every `Omit!(Bytecode, ...)` row left in `tests/ut/backends/runner/**` is one
of the already-documented not-bounded rows above (`file.d:14`,
`concurrency.d:24`, the cerealed exception-message row, the three
`expressions.d` ref-calling-convention rows, the one remaining `arrays.d`
assoc-array row, and the four `archive.d` rows); re-search before assuming
otherwise.
A module-level struct's own nested struct field (`go.inner.x`, `struct Inner
{ int x; } struct Outer { Inner inner; } Outer go;`) now reads and writes
correctly, including a nested array field (`go.inner.arr ~= ...`):
`structBaseOffsetOrMaterialise` materialises a bare module-struct `VarExp`
into a frame block the same way `tryStructField`'s single-dot-level branch
already did, reporting the module offset back up through its `outer.inner`
recursion so a field at any nesting depth writes back to its own real slot.

Every currently-known Bytecode gap in `tests/ut/backends/runner/**` is one
of the already-documented not-bounded rows listed above. Finding the next
candidate requires fresh `bin/qb` exploration (read-modify-write/mirror
paths, the live aggregate limitations below, or the "Architecture work
forced by the baseline" fronts) rather than a matrix search.

Reconfirm these live aggregate limitations against the current source when a
row reaches them:

- Every array/pointer opcode family that supports a fixed-width fast path
  (`Op.subSliceN`/`sliceCopyN`/`appendElementN`/`indexLoadN`/`indexStoreN`/
  `concatArraysN`/`pointerSliceN`/`pointerLoadN`/`pointerStoreN`) now covers
  1, 2, 4, 8, and 16 bytes via dedicated opcodes and any other width via an
  `N`-variant that carries the byte width as an explicit instruction operand,
  the same way `Op.copy` already carries an arbitrary block width, instead of
  encoding the width in the opcode or deriving it from a `ScalarType` tag
  that resolves to 0 for a struct/static-array element. Every ref-argument
  mirror/writeback call site that binds non-frame-resident storage
  (`emitStructPointerRefArgument`, `emitStructPointerFieldRefArgument`,
  `emitClassFieldRefArgument`, `emitPointerDereferenceRefArgument`,
  `emitDynamicArrayRefArgument`/`emitDynamicArrayElementRefArgument`,
  `emitRefReturnedDynamicArrayElementArgument`,
  `compileClassStaticArrayAsDynamicInto`) now sizes its `pointerLoadOp`/
  `pointerStoreOp`/`indexLoadOp`/`indexStoreOp` pair from the pointee's real
  byte width and passes that width as the `N`-variant's explicit operand,
  instead of declining a non-scalar element or a struct/static-array field.
  `emitConditionalRefArgument` already handled a struct-typed branch
  correctly via the generic, width-agnostic `referenceOffsetOrNull`, needing
  no change. `Op.sliceCopy*` and `Op.sliceFill*` (the single-value
  broadcast-fill path used by `arr[0 .. 2] = value;`) both carry a
  fixed-width opcode set plus an `N`-variant fallback with an explicit
  byte-width operand, so a struct/static-array-typed broadcast source fills
  at any width, not just a basic-type scalar. A destination element that is
  itself a heap-allocated row descriptor (`T[N][]`/`T[][]`, `elementIsArray`)
  still declines the fill path: broadcasting into it needs a fresh row
  allocation per element, not a byte copy. A ref argument bound to
  a ref-returning wrapper's
  returned array element still loses the writeback on `Interpreter`
  regardless of element width (confirmed via `bin/qb` with a plain scalar
  element too), so that row stays `Omit!(Interpreter, Because.diverges,
  ...)` independent of the Bytecode fix.
  `loadStructPointerField`/`storeStructPointerField` (`compiler.d`) --
  the plain (non-ref-argument) read/write path for a field reached through
  `tryStructPointerField` -- now handle a `Tstruct`/`Tsarray` field the same
  way the ref-argument path above does.
- Dynamic-array and string sub-slices reject an upper bound beyond the source
  length and a lower bound greater than the upper bound; pointer-slice bounds
  remain unchecked.
- Captured array support does not yet cover every read, write, slice, append,
  view-preservation, and closure combination.
- `Interpreter` declines an indexed write through a dereferenced
  static-array pointer (`(*p)[i] = v`, e.g. a class field's whole-array
  pointer indexed and written) with "Unsupported interpreter assignment
  target"; `Omit!(Interpreter, Because.unconfirmed)` on that row
  (`pointer.classStaticArrayFieldElementWrittenThroughWholeFieldPointerIsVisibleDirectly`,
  `expressions.d`).
- Static arrays of dynamic arrays copy each element's full 16-byte slice
  descriptor; nested mutation and general stale-cell reconciliation remain
  incomplete.
- Also open, architectural rather than boundable in one commit: a `T[N][]`'s
  rows are materialised as separately
  heap-allocated inner descriptors, so a pointer taken into one row
  (`&outer[i][j]`) is valid within that row, but a flat pointer walk across
  rows diverges from compiled D's contiguous layout. Reconfirmed current:
  `&outer[0][0]` then indexing past row 0's own two elements reads unrelated
  heap bytes instead of row 1, where `SystemLinker`'s contiguous backing
  store reads the next row.
  Appending a row (`outer ~= [a, b]`) now builds that row's own heap block
  and 16-byte descriptor before appending it (`compileAppendElement`'s new
  `descriptor.elementIsArray` branch, `compiler.d`), matching what an
  array-of-arrays literal already builds per element; previously this both
  used the wrong element width (`appendElementOp`/`appendElementSize` only
  distinguished 1, 2, or default-4 bytes, so an 8-byte row or descriptor
  silently truncated to 4 bytes copied) and appended the row's raw value
  instead of a descriptor, corrupting the backing store and segfaulting on
  a later indexed read. `appendElementOp` now covers 8 and 16 bytes
  (`Op.appendElement8`/`Op.appendElement16`) and throws instead of silently
  mis-sizing any other width.
- `compileConcatenationAssign` (`outer ~= otherOuter`, whole-array
  concatenation of a `T[N][]`/`T[][]`) now builds its `elementIsArray`
  operand size the same way `compileAppendElement` does
  (`dynamicArrayElementSize(..., descriptor.elementIsArray)`), and
  `concatArraysOp`/`concatElementSize` add an `Op.concatArrays16` variant, so
  the right-hand array's rows copy as whole 16-byte descriptors instead of
  truncating to 4 bytes.
- A `__gshared`/`static` module-level dynamic-array variable
  (`moduleDynamicArrayVariableOrNull`, `compiler.d`) with a non-null
  initializer now has real storage when the initializer is a non-empty array
  literal of constant scalar elements (`int[] arr = [1, 2, 3];`); still
  declines registration (same as the default-initializer case) for an
  array-of-arrays element, a struct/static-array element, an empty literal
  (`[]`), or any non-constant element (e.g. a function call). A module-level
  struct variable (`ModuleStructVariable`) is supported for the
  default-initialized case:
  field access materialises the whole block
  via `Op.loadModule` but writes back only the touched field's own bytes via
  `Op.storeModule` (`tryStructField`/`writeBackStructField`), so a sibling
  field written in between (e.g. by a right-hand-side call) survives; a `ref`
  argument bound to such a field, at any nesting depth (`go.x` or
  `go.inner.x`), mirrors just that field into its own fresh slot with its own
  writeback (`emitModuleStructFieldRefArgument`, resolving the field's dataseg
  offset through `moduleStructFieldOffsetOrNull`'s `DotVarExp`-chain
  arithmetic) rather than reusing the whole-block copy `tryStructField`
  materialises for plain field access. A non-default struct initializer still
  falls through to
  "Unsupported variable in bytecode core". Module-level
  `Tsarray`/`Taarray`/`Tdelegate` variables and pointer/complex-double dataseg
  variables remain entirely unsupported (`moduleScalarVariableOrNull` still
  declines them).
- A module-struct field's compound assignment (`gp.x += rhs`) now compiles
  `rhs` before `tryStructField` materialises the field's whole-block copy,
  the same reordering the module-array `~=` fix below applies: `rhs` may
  itself write that exact field by name (`gp.x += f()` where `f` writes
  `gp.x` directly), and the direct write must land in real module storage
  before the copy this read-modify-write reads from is taken, or the
  post-op `Op.storeModule` writeback clobbers it with a stale sum. The
  identical shape through a class reference (`gc.x += f()`,
  `tryClassPointerField`) is fixed the same way: the field load is now
  compiled after the rhs, so a heap object needs no whole-block-copy
  narrowing the way module storage does -- there is no copy, just a load
  ordered to run after whatever the rhs already wrote directly.
- A module-level dynamic array's single-element `~=` (`compileAppendElement`)
  and whole-array `~=` (`compileConcatenationAssign`) both now compile the
  appended value/right-hand array before materialising the target's
  descriptor when the target is a module variable, so a reentrant append
  inside that value's own evaluation (`ga ~= f()` where `f` itself does
  `ga ~= x`) lands in the descriptor instead of being overwritten by the
  post-call writeback of a stale pre-call snapshot.
- A scalar `ref` argument bound to module storage
  (`emitModuleScalarRefArgument`/`emitModuleStructFieldRefArgument`) mirrors
  the module value into a fresh frame slot for the call and writes it back
  through `Op.storeModule` only after the callee returns. If the callee also
  writes that same module variable directly by name during the call (a
  `ref int x` bound to `counter` in `weird(ref int x) { x = 5; counter =
  100; }`), the direct write is unconditionally clobbered by the post-call
  mirror writeback regardless of which write is later in the callee's
  program order -- real `ref`-to-global aliasing has no such race, since a
  genuine ABI `ref` is the same storage, not a copy. Reordering cannot fix
  this the way it fixed the append case above: nothing inside the callee's
  body ever reaches the module address through the ref parameter itself,
  because the parameter is an ordinary value living in its own frame slot,
  not a pointer the callee dereferences. Every other ref-argument kind that
  mirrors non-frame-resident storage into a fresh slot and writes it back
  afterward (`emitStructPointerRefArgument`,
  `emitStructPointerFieldRefArgument`, `emitClassFieldRefArgument`,
  `emitRefLocalPointerArgument`, `emitPointerDereferenceRefArgument`)
  shares the identical latent hazard
  whenever the callee reaches the aliased storage by another path during
  the same call. A real fix needs a scalar `ref` parameter to be a pointer
  the callee dereferences on every read/write of it, so a call can bind it
  directly to the real address (e.g. via `Op.moduleAddress`) and skip the
  mirror/writeback pair entirely -- a change to the calling convention
  shared by every ref-argument kind, not a narrow field-offset fix. This
  also covers the plain-local case, not just module/struct/class-backed
  storage: `referenceOffset`'s ordinary `_locals` path passes the same
  caller-frame-offset-mirrored-into-a-fresh-slot value for any `ref`
  parameter, confirmed via `bin/qb` for a bare `ref int` parameter with no
  module or aggregate involved at all (`&value` inside the callee never
  equals the caller's `&value`). `expressions.d`'s
  `refArgument.templateRefSharedParameterMutatesAndPreservesAddress`,
  `refArgument.templateRefSharedForwardsThroughNestedFunction`, and
  `delegate.captureIsNotParameterReference` (still
  `Omit!(Bytecode, Because.unconfirmed)`, ~line 8024) all assert `&value ==
  expected` across a `ref`/captured-local call boundary and are blocked on
  this same calling-convention change, not on template/`shared`/closure
  specifics; they are not a bounded single-commit family until the ref
  calling convention above is redesigned.

`concurrency.thisTid.Bytecode` (`tests/ut/backends/runner/sys/concurrency.d`)
stays `Omit!(Bytecode, Because.unconfirmed, ...)`. `Scheduler.thisInfo`'s
`atomicLoad(scheduler)` (an 8-byte `Scheduler` reference) is usually served
by the already-supported `RDX`/`RAX` atomic-load inline-asm shape
(`tryCompileAtomicLoadAsm`, `compiler.d`), but order-dependently -- confirmed
with `bin/ut --seed 543485028` -- the same call site is sometimes compiled
with a second, distinct shape using 32-bit `EDX`/`EAX` value registers
instead, which the bytecode core does not recognise. Why the same 8-byte
load takes either shape is not yet characterized; do not add a same-shaped
`EDX`/`EAX` opcode without first confirming (e.g. against a disassembled
`SystemLinker` build of this exact fixture) that a 4-byte-wide native atomic
read is actually the correct oracle behaviour for this call, rather than a
truncation of the real 8-byte reference.

`file.createWriteRead.Bytecode` (`tests/ut/backends/runner/sys/file.d`) stays
`Omit!(Bytecode, Because.refusal, "Unsupported inline asm instruction
sequence: ...")`. `atomicOp!"+="(_p.refs, 1)` passes `_p.refs` (a field
reached by dereferencing the pointer field `File.Impl* _p`) as a `ref`
argument; `emitStructPointerFieldRefArgument` (`compiler.d`) now resolves
that shape. The remaining blocker: `std.stdio.File`'s refcounting is
`shared`, and DMD's `core.atomic` lowers `atomicOp!"+="` on this platform to
inline x86 asm (`lock xchg` followed by a plain store) rather than a
compiler intrinsic; the bytecode core has no inline-asm support at all.
Candidate fixes: implement the specific `lock`-prefixed read-modify-write/
store instruction sequence `core.atomic` emits, or recognise `atomicOp`/
`atomicLoad`/`atomicStore` by symbol (like the `std.math` builtins) and
lower them to dedicated VM atomic ops instead of compiling the inline asm
body.

A delegate-typed PARAMETER is an ordinary 16-byte `{functionIndex, context}`
by-value parameter; a call through one (`Op.callIndirectDynamic`) builds its
argument area from the delegate's declared type alone, since there is no
statically known `FuncDeclaration` behind it. This is sound for a nested
function/lambda, whose context is always one pointer-sized word matching the
delegate pair's own context word. A struct-receiver method's context is
instead a caller-frame-relative offset into a whole receiver block, so
`callIndirectDynamic` checks the resolved callee's `CompiledFunction.hasThis`
at run time and rejects it with a diagnostic rather than misreading the
context word (`delegate.structReceiverPassedAsParameterIsRejected.Bytecode`,
`tests/ut/backends/runner/lang/expressions.d`). A class-method delegate
should carry the same single-word context as a lambda/nested function, but
that shape is not yet verified through this mechanism: `auto d = &c.m; d()`
already fails earlier with a pre-existing, unrelated `class this is null`
error even as a plain local, before reaching a dynamic parameter call at
all. Making the struct-receiver shape callable needs the receiver encoded as
something frame-independent -- a real pointer to the receiver block rather
than a frame-relative offset -- which changes how every struct method
receives `this`, not just this call path.

`compileIndirectCall` (`compiler.d`) now builds its argument area from the
callee's function-pointer type alone (the same run-time-declared-type
approach `compileDynamicDelegateCall` uses for a delegate parameter, minus
the context word), so a plain `R function(Args...)` call with arguments
works. A value loaded through a pointer dereference or index (`*p`, `p[i]`)
whose static type is itself a pointer now carries `isPointer` (`compiler.d`'s
`asPointerValue`), so a function pointer reached that way is an ordinary
callable pointer local, the same as one bound directly from `&f`.

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
  `nestedContextOffset` within the frame just reached, still live on the
  stack as the current call's transitive caller. `_capturedOwners` records,
  per captured `VarDeclaration`, the function whose frame its offset is
  relative to, so the read site knows how many hops to walk.
- A nested function that reads its enclosing struct method's `this` (a
  capturing lambda literal, e.g. `() => this.field`, or a plain nested named
  function, e.g. `auto helper() { return this.field; }`) needs a hidden
  `this` receiver, not a captured-locals environment: DMD gives both shapes
  an identical `vthis` context pointer (`FuncDeclaration.isNested`, set for
  any non-`static` function whose `toParent2` is a function, regardless of
  whether it is a `FuncLiteralDeclaration`), and `ThisExp` resolution inside
  either one resolves to the nearest enclosing method's own `vthis`
  (`hasThis(sc)` walking up through nested scopes). The compiler recognises
  this case (`capturedThisStructDeclaration`) for both shapes, keyed only on
  `vthis` plus the enclosing parent being a struct method, and only when the
  enclosing struct itself is not function-nested: a struct declared inside a
  function (a voldemort type) appends an extra hidden context-pointer field
  after its declared fields (`AggregateDeclaration.isNested`), which the
  frame layout this path builds does not account for, so a function-nested
  struct falls back to the plain "unsupported" diagnostic instead of
  resolving `this.field`. A direct unqualified call to such a named nested
  function gets a call-site receiver branch in `methodReceiverOffset` for the
  plain `VarExp` callee shape, alongside the `DotVarExp`/`FuncExp` shapes.
  This is a `this`-receiver question, not the captured-locals-environment
  work above, and does not by itself require a closure environment. A lambda
  that captures a plain
  enclosing *local* (not `this`) remains unmodelled and does need the
  captured-locals environment described above; an immediately-invoked void
  lambda whose body is a single expression statement can avoid needing that
  environment by inlining the statement into the caller the same way a
  single-`return`-expression IIFE already inlines.
- The captured-parent materialisation is only for such nested functions. A
  nested struct method's own `this` remains its current receiver, even when
  that receiver also carries a context pointer.
- `capturedThisStructDeclaration` declines the `this`-receiver shape whenever
  the nested function also has a captured local (`hasCapturedOuterLocal`),
  even though `vthis` is set: the function instead gets an ordinary nested
  frame/closure context, and `vthis` is registered into that same captured-
  offsets map alongside the captured locals, so `this.field` resolves through
  the closure environment like any other captured variable. This covers both
  a nested function that reads an enclosing local and `this.field` together
  and a pure-local capture with no `this` use at all.

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
