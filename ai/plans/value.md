# Value Representation

## Status

This plan records the removal of the shared `quickbite.lang.Value` and the
tree-walking interpreter's move to native-layout storage. Decisions 15-18
(July 2026) commit the end state — native-layout storage, one data-pointer
representation (the host address), no FFI marshalling — with deleting
`Value` as the completion signal. Priority order, which governs all
sequencing here: **working interpreter first**; improvements (including
simplification) after; de-duplicating the bytecode/interpreter
native-layout code ranks below finishing the bytecode VM. Current
capabilities:

- `EvalResult` carries a display `string` or `Diagnostic`, and `:t` is
  frontend-answered. CTFE and Interpreter execute formatter-wrapped expression
  cells and unittests without rendering; range/template structs and the IR and
  Bytecode paths still use interim `Value` display scaffolding.
- `NativeBlock`/`NativeArray`/`NativeStruct` compose structs, static arrays,
  slices, and their elements using DMD layout. They own real GC storage,
  growth, slice headers, and the interpreter side of the FFI seam.
- Native frame, module, object-body, and borrowed reference places provide
  authoritative reads, writes, whole-value reconstruction, and addresses.
  Views compose by DMD offsets and strides; direct, nested, indexed, sliced,
  `ref`, and cross-frame access share storage rather than copies.
- Class bodies are owned by their host address, not a variable binding.
  Union storage observes overlapping DMD offsets and first-member default
  initialization for the supported recursively scalar-field shapes.
- Rebinding stores a new value or address in the binding place; same-storage
  mutation updates the existing bytes. Casts and slices retain their native
  backing and compose from its address across bindings and calls.
- `RuntimeValue` is transient expression currency. Its aggregate arm owns or
  borrows native DMD-layout storage, and its sole data-pointer arm is a host
  address. It is never local, alias, or cross-frame storage authority.
- The native-call adapter has direct-address argument and result paths, but
  still accepts `RuntimeValue` inputs and retains buffer-based materialize,
  reify, and writeback fallbacks. Decision 18's no-marshalling end state is
  therefore not complete; Remaining-work item 5 owns deleting those fallbacks.

## Audit findings (June 2026)

Retained only as the justification for decision 1: nothing structural in
production consumes `quickbite.lang.Value`. The REPL consumes only display
strings and never feeds a `Value` into later evaluation (session state is
replayed from source); benchmarks compare strings; the bytecode and IR
cores exclude a universal runtime value type by design
(`ai/plans/bytecode.md` "No universal runtime value type";
`ai/plans/ir.md`). The struct's remaining customers are its own unit tests
and the interpreter's internal execution scaffolding, both scheduled for
deletion (items 2-3).

## Approved decisions

1. `quickbite.lang.Value` leaves the `Evaluator` contract: `EvalResult`
   carries the rendered display `string` (or a `Diagnostic`). The struct
   is deleted entirely once no backend needs it internally. The contract
   flip is implemented; the struct survives only as private per-backend
   scaffolding per decision 4.

2. Display round-trips as valid D: every rendering is a D expression that
   parses and evaluates back to an equal value (Python's `repr`
   principle). Display is *not* the channel for revealing a value's
   static type: where D has no literal form, the rendering's static type
   widens on re-parse and the user reaches for `typeof`/`it.typeof`
   (`ai/plans/repl.md`). `EvalResult` carries no separate static type:
   the type is resolved by semantic analysis (including `auto`-deduced
   returns) before any backend runs and is identical across backends — a
   backend can only differ in runtime *bits*, which the value digits and
   behavioural probes catch (see "Test strategy").

3. The canonical formatter's end state is an in-program prelude template,
   `string __quickbiteFormat(T)(T value)`, written once in ordinary D
   with `static if` introspection. The frontend synthesizes expression
   cells as `__quickbiteFormat(expr)`; semantic analysis — shared by all
   backends — instantiates the template against the real static type, so
   type-directed dispatch is resolved before any backend runs and
   backends only execute code. Consistency across backends by
   construction; the native backend ships a plain `string` across the
   dlsym boundary.

4. Interim: the contract changes first. Host backends keep their existing
   reify -> `Value` -> `toString` chains as *private* formatting
   scaffolding behind the string-returning interface, deleted per backend
   as each becomes able to execute the prelude formatter. The formatter
   is an early, demanding test program for the bytecode and IR cores, not
   a new requirement. During the interim the formatter-wrapped synthesis
   applies only to views consumed by backends that can execute it.

5. REPL mechanics survive without `Value`: void suppression is decided at
   synthesis time (the frontend knows when `typeof(expr)` is `void`, and
   `Cell.Kind.noDisplay` exists), `:t` is frontend-answered from the DMD
   AST for latency (never routed through a backend), and string quoting
   moves into the formatter. Type disambiguation of display output is an
   explicit user action, `typeof`/`it.typeof`.

6. The native backend (`SystemLinker`) is the single behaviour oracle in
   the absence of a formal language specification. CTFE is not an oracle;
   where it diverges, its behaviour is characterized, not treated as
   truth (`ai/plans/single-oracle.md`).

7. The deletion target is the *shared, cross-backend* value type, not
   every box. The tree walker keeps an interpreter-package-private
   carrier for recursive expression results — the uniform D type returned
   by evaluating an expression: immediate scalar results, native
   aggregate handles, locations/references, callables, and interpreter
   metadata. `RuntimeValue` has one `NativeAggregate` arm for aggregate
   expression results and one `Pointer` arm holding a host address.
   `AggregateValue` is the typed boundary for aggregate operations. Function
   and delegate handles remain separate non-data categories. The expression
   currency is a return type, never an authority (decision 15).
   The earlier claim that a boxed tagged union
   is "the natural form" for a tree walker was downgraded: it argues
   against *reimplementing* layout, not against *reusing* it. It is
   **recursive aggregate boxing** (`Struct = Value[] fields`,
   `Array = Value[] elements`) — not boxing per se — that forces per-call
   marshalling and cannot pass the correctness ceiling. The Lox-derived
   runtime type tag is redundant for type safety here: the DMD frontend
   stamps a static `Type` on every node.

8. Track B charter: this plan owns the interpreter's value
   representation, companion to the FFI bridge plan (`ai/plans/ffi.md`
   §5/§6). The bridge core never sees `RuntimeValue`; the interpreter's
   native-call adapter can hand argument and result addresses to
   `quickbite.ffi`, which keeps owning ABI descriptors and call plumbing. The
   adapter still has a buffer fallback for `RuntimeValue` inputs; item 5
   removes it by making typed addresses the ordinary call-site contract.

9. FFI-crossing and addressable aggregates live in native ABI layout
   behind a thin handle reusing DMD's own offsets. A cross-language
   survey showed this is the **universal** shape, not an invention:
   every boxed-value runtime that does FFI well keeps its box for
   scalars/host convenience but holds aggregates in native layout behind
   a handle, never as a recursive tree of boxes (CPython `ctypes` cdata,
   Ruby `Fiddle`/`FFI::AbstractMemory`, LuaJIT `GCcdata`, the JVM's
   Panama `MemorySegment`, .NET blittable types). The opaque handle
   (never read through the pointer) and the transparent native-layout
   representation (read/write fields at DMD offsets) are the same idea at
   two transparency settings; the rejected recursive-boxing design sat
   between them and paid a per-crossing materialize/reify. Native layout is a
   **correctness win first, latency second**: runtime discriminants are
   needed only for GC tracing and union/variant dispatch, and the
   correctness ceiling (`&local`, unions, reinterpret casts, slices into
   locals) is passed by construction under native layout and by no amount
   of speed under recursive boxing. Latency caveat: native layout removes
   per-aggregate marshalling + GC alloc + tag dispatch, but **not** the
   libffi `ffi_call` dispatch cost — only a JIT erases that. The
   interpreter's edge stays no-emit, not fast calls. Representation and
   execution strategy are orthogonal: a native-layout interpreter still
   walks the AST and adds no emit latency; the experiment compares two
   *no-emit* interpreters, not interpreter-vs-VM.

10. `std.variant.Variant` was considered and rejected as a replacement
    for the `SumType`-based `Value`: a heavier box for the same strategy,
    not a different strategy. It still recursively boxes guest aggregates
    (a *guest* `struct Point` is a DMD AST type, not a host D type, so it
    becomes `Variant[]` exactly as it is `Value[]` today), reintroduces
    the runtime `TypeInfo` dispatch the static frontend makes redundant,
    heap-allocates past its inline buffer, and drops `match`
    exhaustiveness. It moves the wrong way along the axis; the fix moves
    toward native bytes behind a handle.

11. "Boxed scalars stay" means **immediate scalar expression results**
    only — the walker's transient rvalue currency. Every lvalue, scalar
    included, is an address from the moment it is bound (decision 15);
    there is no lazy promotion and no snapshot reconciliation. The
    earlier framing — eager slots vs measured lazy promotion — is
    settled by decision 15: promotion machinery is a second world with
    a trigger-detection seam ("identity observed" is far broader than
    `&x` — `ref` parameters, casts, slice sharing, cross-frame
    aliasing), and that seam is where the boxed era's bug population
    lived. A scalar rvalue passed to libffi may still need one
    fixed-width leaf copy into an ABI cell; that is calling-convention
    plumbing, not marshalling.

12. Execution and display are separate consumers of expression
    evaluation. The walker needs a recursive expression-result operation
    (unittests execute expressions; nested calls return results), but its
    carrier is interpreter-private execution machinery, not a display
    value — `RuntimeValue` is a descriptive name, not a prescribed shared
    type. Top-level unittest execution needs only success or a diagnostic
    and must not render the walker's final result; the REPL expression
    path synthesizes `__quickbiteFormat(expr)` and returns that
    guest-produced string through `EvalResult`. Replace the interim
    `runUnitTest -> eval(FuncDeclaration) -> displayString` bridge with a
    direct unittest execution entry point plus a separate REPL evaluation
    entry point: display work leaves the latency-critical unittest path.

13. Ownership split with the bytecode rewrite (`ai/plans/bytecode.md`),
    so the two tracks can run in parallel without one building what the
    other deletes. This plan's formatter track owns the frontend gate
    (`frontend/cell.d`), the prelude (`source/quickbite/repl_prelude.d`),
    and the opted-in backends (`Ctfe`, `Interpreter`) including their
    interim-scaffolding deletion; it does not touch
    `backends/bytecode/**`. The bytecode backends opt in through their
    own plan's "Prelude formatter execution" slice, and until then their
    `repl.d` display rows are frozen. Matrix rule: display tests
    parameterize over formatter-capable backends only; when a formatter
    change collides with a bytecode-pinned row, drop that engine from the
    block and record the pending re-earn — never implement matching
    `Value` scaffolding on the bytecode side (omit-don't-pin).

14. The representation decision is **decided** and un-gated from the
    latency measurement. The correctness ceiling was empirically
    confirmed by the interpreter cerealed frontier: nearly all of its
    frontier advances were representation-induced shims sitting exactly
    on the ceiling list (float/double pointer reinterpret loads,
    `emplaceRef`'s `cast(S*) &chunk` aliasing intercepted by name,
    class-references-passed-by-value writeback, pointer-slice allocation
    identity, `gc_*` array-capacity hooks stubbed because boxed arrays
    are not addressable GC blocks). Recursive aggregate boxing cannot
    reach `interpreter.md`'s terminal goal without accumulating
    name-based shims and per-case writeback side tables; the shims are
    why the native-storage contract forbids restoring such shims. The unit of
    representation change is interpreter-wide — not a bolt-on marshaller
    (decision 18's measured result), and not a VM rewrite (`bytecode.md` is
    unaffected and remains the native-layout *execution* track).

15. **One storage world** (July 2026; supersedes the lazy-promotion
    architecture). Every lvalue is an address with a static type:

    - a local binds Quickbite-owned, GC-backed storage allocated at
      binding (a per-activation frame block, decision 17);
    - an extern global binds its resolved host address;
    - a `ref` parameter binds the address its caller supplied;
    - module-level guest state binds blocks in a module table, per the
      existing extern-data rules.

    An uninitialized module-level or static associative array materializes
    its native handle exactly once on first read and retains it in that
    storage; a fresh default handle per read would discard every mutation.

    Loads and stores operate at those addresses directly. There is
    exactly one data-pointer representation — the host address — and
    taking an address reads a number; there is nothing to promote. A
    *place* is an address plus its static type, nothing more: field
    access and indexing compute another address. GC rooting and
    ownership are private lifetime properties of some addressed memory,
    kept alive by ordinary scanning of the frames and blocks that
    reference it; they never participate in guest identity or address
    arithmetic. A storage-identity-plus-offset coordinate system would
    recreate the rejected pointer-provenance split. Function and delegate
    handles are separate non-data categories. Boxed values survive only as
    transient rvalues (decisions 7/11), never as storage authority.

    Rationale: simplicity motivates the design. Boxing earns its keep
    only where the frontend cannot type values (Lox, Python — the
    runtime tag is the type system) or where evaluation must be
    host-independent (DMD's own CTFE, notoriously slow for it); neither
    applies to a statically typed guest whose correctness bar is
    agreement with compiled D on this host, where host layout is the
    spec, not a hazard. Survey: every interpreter whose bar is agreeing
    with compiled host code — Cling, GraalVM Sulong's native mode,
    Julia for concrete types, LuaJIT's FFI — uses host layout and raw
    addresses; dual data-pointer representations (`alloc-id + offset`)
    appear only where the goal is provenance/UB detection against an
    abstract machine (Miri), bought with orders-of-magnitude slowdown.
    The old simplicity-vs-latency framing was a fake trade-off: host
    layout is simultaneously the simplest and the measured-faster
    representation (decision 18's ~26x), so the standing invariant is
    that wasted cycles need justification — never quote "simplicity
    first" to license the cycle-wasting option. Latency *improvement*
    over the boxed baseline is a hoped-for result that must be
    measured, not assumed.

    Root cause, recorded so the lesson is not relearned: the cell
    families' fork/merge/drop obligations, the alias tables, the rebind
    markers, and the recursive-activation divergence are all
    consequences of *variable-keyed identity with boxed authority*.
    Family consolidation would not have fixed them — one unified family
    keyed by `VarDeclaration` still forks, merges, and shares cells
    across recursive activations. Address-based identity dissolves
    them: each activation binds fresh storage, and identity is the
    address. The former consolidation-debt migration onto a common
    `(root, PATH)` key is therefore cancelled — those families are
    deleted with their world, not migrated.

    End-state criteria, strongest first:

    - the shared `quickbite.lang.Value` is deleted (items 1-3) — the
      completion signal;
    - structurally, the walker's expression currency has exactly one
      pointer arm and that arm holds a host address; any new arm,
      carrier, or wrapper around addresses is the regression (that is
      how the boxed era grew — never "a second pointer type", always
      "a carrier for a shape the current one can't express");
    - no data-pointer kind predicate or declaration/allocation identity map
      exists in the interpreter execution path.

16. **Walker role; no shared substrate.** The walker is not a stepping
    stone: its own terminal goal is running arbitrary D projects' unit
    tests (`interpreter.md`) at minimal edit-to-test-result latency
    (AGENTS.md's prime directive), which makes FFI to libc and compiled
    dub dependencies the hot path, not a corner — decision 18 sits on
    that path. It also stays the semantics vanguard: extending an AST
    walker per language feature is cheaper than a compiler+VM slice,
    and its oracle-backed fixtures ratchet the bytecode track.

    A shared guest-memory substrate (a `quickbite.native` package
    absorbing the containers and a port of the bytecode core's memory
    internals) was considered and **rejected for now**. Native layout
    is a semantic property, not a shared-code requirement: the two
    backends' storage needs genuinely differ (independently allocated
    typed blocks vs compiler-addressed contiguous frames, where
    `bytecode.md` requires no abstraction stack between the dispatch
    loop and memory), and drift on anything observable is already
    policed by something stronger than shared code — the oracle
    matrix. De-duplicating the two native-layout implementations ranks
    below finishing the bytecode VM and is not this plan's to
    schedule. If sharing is ever actually wanted, extraction is a
    behavior-neutral move to do then, and that is when the AGENTS.md
    ownership question and the libffi-plumbing home get answered —
    today the plumbing stays owned by `quickbite.ffi` (`ffi.md` §5)
    and a memory container knows nothing about libffi. The walker
    rewire consumes `native_block.d`/`native_array.d`/
    `native_struct.d`/`layout.d` where they already live, inside the
    interpreter package.

17. **Migration rule: preserve one working storage world.** Representation
    changes land as coherent, oracle-backed slices. A slice may add native
    composition before it selects that storage as authority, but it may not
    leave a cell, alias table, or return-time reconciliation path competing
    with an authoritative native place. Each activation owns one fresh frame
    block, including an activation whose layout has no slots; captures and
    calls retain typed addresses into the owning frame. The merge gate is no
    new red rows relative to the documented baseline.

18. **FFI end state: no marshalling.** This is a structural guarantee:
    an aggregate argument's bytes already sit at a real address and a native
    return is written straight into typed result storage. A small backend
    adapter hands argument and result addresses to `quickbite.ffi`, which
    keeps owning ABI
    descriptors, CIF caching, calls, callbacks, and native exception
    handling (`ffi.md` §5) — that is call plumbing, not marshalling
    debt; the irreducible remainder (`ffi_call` dispatch) only a JIT
    removes. The `ffi.md` §34.3 `B*` marshalling rungs are cancelled;
    recording the cancellation inside `ffi.md` belongs to that plan's
    own track (cross-track rule) and is requested here so an ffi-track
    agent does not build frozen machinery from a stale work order.

    Preserved evidence (do not re-litigate): a bolt-on native-layout
    marshaller was measured to be the wrong unit of change — its
    inputs and outputs are boxed `Value`s either way, so it boxes on
    the way in and out and only adds blob bookkeeping; the benchmark
    suite never crosses the seam (`bin/bench` fixtures have no native
    dependency; only the `sys/` dependency-image suite exercises it);
    and the real gap (a boxed 4-long struct at ~26x a native byte
    layout to construct and read back, a boxed 16-long slice at ~27x —
    boxing's GC alloc + `SumType` tag dispatch) is realizable only
    when aggregates are never boxed.

    This paragraph specifies the target, not master’s present completion
    status. `backends/interpreter/native_call_adapter.d` still contains the
    transitional `RuntimeValue` -> ABI-buffer and ABI-buffer -> `RuntimeValue`
    fallbacks, including aggregate reconstruction and post-call writeback.
    Item 5 is complete only when those paths are unreachable and deleted. The
    libffi descriptor, address-array, callback-lifetime, scalar scratch, symbol
    resolution, and exception machinery remains call plumbing under this
    decision.

## Contracts

Invariants a change can silently break. Each was earned by a real bug or a
checked fact; do not relearn them.

### Layout authority

- `layout.d` is the only place the interpreter package reads DMD layout:
  `typeByteSize`, `fieldByteOffset`, `structFields`, `classFields`,
  `staticArrayLength`, `classInstanceByteSize`. Every number is DMD's
  own, verbatim; the interpreter must not grow a second set of D layout
  rules. A class body's byte size is always the latter (DMD's own
  `structsize`), never a hand-summed per-field total, which omits the
  vtable/monitor header and can under-count a field-less class to 0.
- `structFields` forces struct layout (via `typeByteSize`) before reading
  fields — `sym.fields` and field offsets are meaningless before DMD's
  own `determineSize` has run. Class fields need no forcing (populated by
  semantic analysis).
- A static array's element count comes from `TypeSArray.dim` — the DMD
  field that IS the fact — never re-derived by dividing byte sizes.
- A vector wrapper and its embedded static array are typed views over the same
  DMD-layout bytes; converting through `.array` changes the view, not storage.
- One deliberate scalar-codec split remains at the libffi seam: a direct
  native return / closure-result buffer is widened to at least `ffi_arg`
  and requires a sign/zero-extended whole-buffer splat that a
  fixed-width leaf codec must not absorb. That is an ABI-width concern
  specific to libffi's calling convention, not a second set of layout
  rules.
- `native_scalar` deliberately excludes `real` (`Tfloat80`). `real` is
  otherwise `place_value.
  isPlaceComposable` via its own leaf codec (`readRealBits`/
  `writeRealBits`); a write composes into a zero-initialised local and
  copies the whole slot, making `real`'s padding deterministic.
- `place_value.valueMatchesPlace` is the recursive gate for whether a
  transient execution value can enter the place writer. It includes both
  type composability and value shape.
- Integer offsetting of a pointer preserves its host address and applies the
  byte delta already scaled from the expression's static pointer type.
- Nested indexing into a native array composes offsets one level at a time:
  the outer index uses the immediate aggregate element's stride, then the
  scalar-leaf index uses the leaf type's stride. Do not flatten both indices
  against the leaf size.
- A constant-index address into a static-array local may arrive as a DMD
  `SymOffExp`; its DMD-provided byte offset applies directly to the binding
  address rather than being re-derived as an element index.
- Subtracting two pointers computes their byte-address difference; DMD's
  surrounding element-size division converts that to D's element distance.

### Containers (`NativeBlock`/`NativeArray`/`NativeStruct`)

- `Ownership` answers exactly "may we reallocate/extend this block?"
  (`owned` = yes, `borrowed` = no). Whether an address is GC-visible is a
  separate, mechanical fact read from `core.memory.GC.addrOf`, never
  inferred from `Ownership`. `borrowed` honestly covers two different
  things — genuinely non-GC foreign memory, and an interior sub-range
  view of a live GC allocation — and no code may assume those are the
  same case. (Every guard once keyed on `borrowed` as a proxy for "not GC
  memory" was wrong the moment sub-range views existed.)
- A block's scan policy is chosen once, at allocation, from
  `typeHasPointers` over the whole type, and the parameter takes no
  default: under-scanning is the unsafe direction, so a forgotten
  argument must never silently choose it. The attribute covers the whole
  byte range; for a union it therefore rounds conservative — over-
  retention is wasteful but sound, while `NO_SCAN` with a live pointer
  member is a use-after-free.
- `writeSliceHeader` refuses to write a GC-owned address into a
  destination block the collector never scans. Legal despite an
  unscanned destination: a null block address (a zero-length array) and
  a genuinely non-GC source address.
- `reserve`/`setLength` refuse every growth of a `borrowed` handle
  (shrink stays legal and storage-free). A handle has no "am I the current
  tail owner" bookkeeping, so it cannot soundly decide which of several live
  views over one block may grow. One narrower operation exists: when
  druntime's real `gc_expandArrayUsed` accepts that exact view, the runtime
  has proved it is the current tail owner and the borrowed view may widen
  without reallocating. The current slice header, not a retained lifetime
  handle, supplies that view; retention never proves allocation identity or
  append capacity. Failure leaves the view unchanged; ordinary growth still
  allocates an owned array and rebinds at the call site.
- Pointer casts, slices, and `void[]` reinterprets preserve the source address
  and express length in the destination element type.
- `setLength`'s grow path zeroes every newly exposed byte
  unconditionally, including bytes re-exposed by shrink-then-grow.
  Compiled D gates its memset on `__traits(isZeroInit, T)` and emplaces
  `T.init` otherwise (`char` 0xFF, `float` NaN); interpreter array growth
  evaluates DMD's `defaultInitLiteral` for every new element.
  Native-container call sites must preserve that distinction rather than
  treating `NativeArray.setLength`'s zeroing as guest initialization.
- A written slice header is a snapshot of `{length, ptr}`; it goes stale
  when the array reallocates, exactly as a compiled-D slice does. Keeping
  a header in sync is the call site's problem.
- A same-width native-scalar dynamic-array cast is another typed view over
  the source array's existing block, never an element-converted copy. Each
  binding reads and writes those shared bytes through its own element type.
  Slice offsets, including a zero-length slice's one-past-the-end address,
  compose directly from the retained source block and survive calls.
- Index bounds checks run before any offset arithmetic, and every
  construction path routes `length * stride` through checked
  multiplication — which is what makes subsequent `index * stride`
  provably wrap-free. Container failures throw `Exception`; whether a
  guest-facing call site should surface `RangeError` for compiled-D
  parity is that call site's decision.
- Do not write `GC.collect`-survival tests for scan policy: conservative
  stack/register scanning makes them pass even with a wrong policy.
  Assert the scan attribute directly.

### Native storage authority

- Every binding has one typed native place: an owning frame or module slot,
  an extern address, or a borrowed `ref`/`out`/capture address. Reads, writes,
  address-taking, indexing, and field access compose from that place.
- Each activation owns a fresh frame block. Captures and calls borrow addresses;
  they do not copy storage authority into a child or reconcile it on return.
- Native class references carry only their body address. VM-owned allocations
  retain their storage in an ownership table; borrowed native exceptions keep
  their hydrated `Throwable` metadata in a separate table keyed by object
  address. A catch's static view may replace exception metadata, but never an
  ordinary class allocation root.
- A field slice borrows bytes composed from its receiver place; an aggregate
  expression snapshot is never the backing storage for an lvalue-derived view.
- `RuntimeValue.NativeAggregate` owns or borrows DMD-layout bytes for a
  transient aggregate result. Once stored, the destination place is
  authoritative.
- `RuntimeValue.Pointer` contains only a host address. Pointer arithmetic and
  subtraction, equality, and relational comparison operate on that address; no
  allocation identity, declaration identity, or pointer-kind predicate
  participates in execution.
- Class identity is the object-body address. All aliases, fields, casts, member
  calls, and exception paths retain that address and observe the same body.
- Native class type membership includes implemented and inherited interfaces;
  the concrete dynamic class still owns object-body layout.
- Caches keyed by DMD declaration identity are scoped to one root evaluation;
  AST arena addresses may be reused by a later fixture compilation.
- Native calls consume argument places or fixed-width scalar scratch cells and
  write returns into typed native storage. There is no recursive aggregate
  marshalling or post-call aggregate reconstruction.
- Native and inline-asm `ref`/`out` ABI formals come from the canonical
  `TypeFunction.parameterList`, not `FuncDeclaration.parameters`; the CIF
  formal is a pointer and its argument slot holds the caller's authoritative
  pointee address. Interpreted-call classification remains declaration-driven.
- Native `ref`/`out` argument evaluation may borrow only an established place:
  a direct local uses its binding address, while a backend without an
  authoritative address refuses the call. It never manufactures a copied
  pointee or a post-call writeback authority.
- A native `typeid(T)` argument is the resolved host address of `T.vtinfo`.
  The interpreter's `TypeName` is display metadata and never an ABI operand.

### Unions

Durable DMD facts:

- DMD reports a union as a `TypeStruct` whose `sym` is a
  `UnionDeclaration`; every top-level member's offset is 0, and an
  anonymous union's members are flattened into the parent's fields at
  overlapping offsets — so a plain `StructDeclaration`'s (or a class's)
  own fields are not necessarily disjoint, and any path that walks them
  "one field each, in declaration order" must first check that they are.
  The offsets themselves are the aliasing truth; DMD's `overlapped` flag
  is a derived fact about them, not a second source of truth to consume.
- D zero-initializes a union from its FIRST declared member's default
  value: the whole block carries the first member's bits, and an
  untouched sibling reads those bits reinterpreted. Computing each
  member's default independently diverges from compiled D.
- DMD's own CTFE engine refuses reinterpretation through overlapped union
  fields (its own diagnostic, not ours), so `Ctfe` is legitimately
  omitted from union-reinterpret test matrices; that divergence is not
  this repo's to fix.

### Backend scope

- The representation is interpreter-internal. It must not force
  `Bytecode`, `LLVMJit`, `SystemLinker`, or `Ctfe` to share a value type
  or import interpreter packages: a promoted fixture proves the same
  D-language result, not a shared runtime value model.

## Display format spec

Principle: every rendering is valid D that parses and evaluates to a
value equal to the original (round-trip / Python-`repr`). Rendering is
*not* required to be injective per type — where D has no literal form for
a type, the rendering's static type widens on re-parse (the value
round-trips, the type does not) and `typeof`/`it.typeof` disambiguates.
Conventions, in order:

1. D literal (or literal-like) syntax where it exists, round-tripping
   both value and type: `42`, `42u`, `42L`, `42UL`, `3.0`, `3.0f`, `3.0L`
   (real — the `L` float suffix round-trips), `true`/`false`, `'a'`,
   `"text"`, `"text"w` (wstring), `"text"d` (dstring), `null`, `[1, 2]`,
   `[1:10, 2:20]`.
2. Types with no D literal form render in their natural bare/literal
   form, accepting that the static type widens on re-parse:
   - `byte`/`ubyte`/`short`/`ushort` -> `42` (re-parses as `int`).
   - `char`/`wchar`/`dchar` -> `'a'` (re-parses as `char`).
   `typeof`/`it.typeof` disambiguates. Invented `: type` annotations are
   not parseable D and are out. (A round-tripping `cast(wchar)'a'` form
   is available if exact-type round-trip is later wanted, but bare +
   `typeof` is the default.)
3. Floating values always include a decimal point or exponent: `3.0`,
   `3.0f`, `3.0L` — never a bare `3` that re-parses as `int`.
4. Aggregates round-trip element-wise: each element/key/value renders in
   its own round-tripping form, so the aggregate self-identifies without
   an annotation. `[1, 2]` is `int[]`; `[1L, 2L]` is `long[]`; `[1:10]`
   is `int[int]`. Aggregates whose element type has no literal form stay
   ambiguous (`[1, 2]` could be `ubyte[]`) — `typeof` disambiguates, same
   as the scalar case. No element-type metadata is needed on any value
   carrier.
5. Structs and enums round-trip via their rendered names (`Point(1, 2)`,
   `E.a`). Struct rendering walks declared fields only; compiler-synthesized
   context storage is never part of the display. Enum members render qualified
   (`E.b`) — a bare member name is not round-trippable D. Multi-entry AA
   rendering order is unpinned (D AA iteration order is unspecified;
   round-trip validity does not depend on it), as are non-member enum values
   (`cast(E)5`).
6. Width round-trips for strings via the literal suffix (`"x"w`, `"x"d`);
   for characters it does not (all widths render `'a'`, disambiguated by
   `typeof`). Type qualifiers (`const`/`immutable`) and mutability are
   not displayed.
7. `void` results display nothing (REPL suppression). Functions,
   delegates, pointers, and other values with no D expression form cannot
   round-trip; there is no contract to honour, so render whatever is most
   useful to the reader (e.g. `<function int(int)>`, `&name`, `null` for
   null callables) — optimise for convenience, not parseability. Pointer
   display is otherwise unspecified until pointers become a displayable
   feature — spec it then.

## Test strategy

Three layers replace structural `Value` assertions:

1. Differential tests against the native oracle: run the same cell on the
   oracle and on the backend under test, assert identical display
   strings. No hand-maintained expected values; enforces formatter
   consistency as a side effect. Slow — a matrix job, not the inner loop.
2. Hand-written text expectations for the fast hermetic suite. One
   display string carries two distinct assertions, and tests must keep
   them straight:
   - The **suffix** witnesses the **static type** — but only where D has
     a literal form (`3u`, `42L`, `3.0f`, `'a'`, `"x"w`). That is a
     frontend fact, identical on every backend, so a suffix assertion
     pins semantic analysis, not backend behaviour. Types with no literal
     form carry no suffix and cannot be pinned this way — by design.
   - The **value digits** witness the **backend's runtime behaviour**.
     Narrowing/widening/signedness are caught here, by constructing
     expressions where the bug changes observable digits: drive the
     static type with an explicit `cast` so the formatter renders at the
     narrow type, and pick operands where truncation, wrap-around, or
     sign flips the result — e.g. `cast(ubyte)(255 + 1)` -> `"0"`,
     `cast(byte)(byte.max + 1)` -> `"-128"`, `-1 / 2u` ->
     `"2147483647u"`, `-8 >> 1` -> `"-4"`.
   Where a test must pin a no-literal subtype, it asserts a
   value-observable behaviour (this layer) or queries `typeof` (a
   frontend fact), never the bare display.
3. Behavioural probes for runtime semantics display cannot reveal:
   wrap-around, truncation, signed/unsigned comparison and division,
   float-width effects. These test execution, not formatting — and they
   are the *only* layer that exercises a backend's runtime type handling.
   The boundary: a width/storage difference that never changes an
   observable value is untestable through the string, but also
   unobservable to any program — not a bug that can matter.

The `Value` struct's own equality/rendering tests are deleted together
with the struct. Do not pin a backend's runtime type via
`typeof(expr).stringof` or any static-type channel: those are computed by
the shared frontend and pass even when a backend widens a value at
runtime.

Conventions for representation fixtures: seed every value from a runtime
function call so DMD cannot constant-fold the scenario away; scope
aliasing fixtures to the backends where the behaviour is confirmed and
omit the rest (omit-don't-pin — never pin an in-development backend's
refusal).

All test additions/changes require approval first (AGENTS.md).

## Remaining work

The native authority switch is the standing interpreter contract, not pending
work. The remaining value-track work begins with the language-surface and
display tasks below. Item numbers remain stable for existing cross-references.

### Item 4 — Workingness track

Keep the interpreter advancing toward the cerealed/dub goal: one
language-surface fix plus its oracle-backed fixture per small, short-lived PR.
Native storage and calls remain the ordinary execution path; do not restore
marshalling, cell families, alias maps, or name-based representation shims.
`interpreter.md` §8 triage remains the partition.

Pointer-slice formation past an allocation remains unchecked when its result is
not dereferenced: this is compiled D's contract and the Interpreter's
native-pointer path matches it. The allocated-block diagnostic is a CTFE-only
characterization, so the Interpreter belongs in the compiled-behaviour matrix;
do not restore a boxed-storage bounds diagnostic for this operation.

Dynamic-array truthiness is the native slice header's pointer, not its length:
a zero-length interior slice with a non-null pointer is true, while a default
null slice is false.

An indexed array-of-arrays element is its own addressed slice header. Slice
assignment through that element writes the row's native elements in place;
rebuilding the enclosing array would reintroduce boxed storage authority.

The temporary `std.conv.text` character-array path reads the authoritative
native slice header, including its retained backing address, rather than a
transient aggregate handle. This is slice execution, not a formatter-specific
storage shim; the interceptor remains temporary per item 1.

Runtime Interpreter evaluation of `__ctfe` must match compiled D and therefore
produce `false`; `Ctfe` alone observes `true`. Cover both frontend shapes before
changing the walker: an ordinary runtime function currently leaves `__ctfe` as
an `IdentifierExp`, while DMD-generated support code can present the magic
variable as a `VarExp`. The oracle-backed runtime fixture must be green on
`SystemLinker`, and the `Ctfe` divergence must remain omitted or characterized
separately rather than becoming Interpreter behavior.

An associative-array binding has no native-place encoding yet. Preserve the
boxed reference path until it does: passing a direct local `int[int]` by `ref`
and inserting through the parameter must mutate the caller, as `SystemLinker`
does. The Interpreter currently routes the parameter read into native storage
and fails with `Expected associative array`; adding an address for the binding
must not bypass the boxed authority before an AA place exists.

An associative array's dynamic-array-typed VALUE (e.g. `int[][int]`) writes
through `native_call_adapter.marshalNative`'s legacy boxed `marshalArgument`
fallback rather than its direct `place_value.writeValue` path, because
`isPlaceComposable` has no `Tarray` arm; the stored slice header comes out
wrong. Struct- and static-array-typed AA values already compose correctly.
Extending `isPlaceComposable`/`valueMatchesComposablePlace` to a `Tarray` arm
is item 5's fallback-deletion scope, not a standalone language-surface fix.

### Item 5 — Delete Interpreter FFI marshalling fallbacks

Finish decision 18 after the language-surface critical path. Normal outbound
calls recognize scalar `&local`/`SymOffExp` operands and direct local/ref
`VarExp` receivers and fields as authoritative places. Native `ref`/`out`
formals use pointer CIF entries and direct local binding addresses; native
`typeid(T)` operands use the resolved host `TypeInfo` address. The adapter's
public entry points still accept `RuntimeValue` arguments and return
reconstructed values and writeback arrays. Consequently it retains
`marshalArgument`, `unmarshalValue`, receiver buffers, mutable-slice
copy/writeback storage, and the remaining `out`-cell reification.

`PtrExp` `ref`/`out` operands, native class-array argument and receiver places,
and `reserve`/growth call routes remain pending. Each must expose its ordinary
typed place before it can bypass a fallback; safe refusal is preferable to a
copied pointee or an invented writeback path.

Make each ordinary native call consume typed argument, receiver, `ref`, and
`out` places, using a fixed-width native scratch cell only for an rvalue that
has no existing address. Allocate typed result storage before the call and
hand its address to `quickbite.ffi`; bind or load that storage afterward rather
than reconstructing an aggregate. A native callee writes through the caller's
supplied `ref`/`out` address, so no return-time aggregate reconciliation or
writeback array remains.

Callbacks obey the same representation rule: their ABI buffers are borrowed
typed places while the callback runs, and their result is written to libffi's
typed result address. Callback registration, roots, closure lifetime, and ABI
scalar widening remain in the adapter because they are call plumbing, not
representation conversion.

Completion requires all of the following:

- normal outbound arguments and results cross through addresses;
- receivers and `ref`/`out` parameters use their authoritative places;
- no recursive aggregate materialize/reify or post-call reconstruction path
  exists;
- the buffer fallback methods may be removed from the Interpreter adapter,
  with any shared-interface simplification coordinated through `ffi.md`; and
- the adapter that remains contains only address selection, ABI-required
  scalar scratch, callback lifetime/re-entry, and native exception plumbing.

Do not delete `quickbite.ffi`, CIF construction, `ffi_call`, the ABI argument
address array, or callback trampolines: decision 18 explicitly retains them.

### Item 1 — Prelude formatter wiring

Complete the prelude formatter wiring (decision 3) after the cerealed critical
path. The formatter surface covers scalars, arrays, structs, enums, AAs, plain
template structs, and context-free range results. `std.algorithm.map`'s nested
`MapResult` remains excluded because its behavior-bearing private state cannot
be reconstructibly displayed. Define the prelude contract for behavior-bearing
templates before admitting them. Then expand the gate per backend (decision 4)
until every REPL expression is formatter-wrapped and the unformatted evaluator
paths can be deleted. The interpreter's `std.conv.text` hook is temporary
formatter scaffolding, not a general Phobos builtin: remove it once the
formatter no longer needs that escape hatch.

### Item 2 — Unittest/expression split

Complete the unittest/expression split for IR and Bytecode (decision 12) after
their formatter wiring. CTFE and Interpreter already execute unittest bodies
directly and return only success/diagnostic. Delete the private reify ->
`Value` -> `toString` scaffolding per backend (decision 4) as each gains the
formatter. Only a REPL expression cell executes the prelude formatter and
consumes its returned string. Do not retain `Value` or render a dummy `void`
result just to reuse the evaluator path.

### Item 3 — Delete the shared value

Delete the shared `quickbite.lang.Value` and its unit tests once per-backend
formatter migrations leave no consumers. This deletion is decision 15's
completion signal.

### Item 6 — Open design questions

Determine the lifetime contracts for blocks borrowed from arbitrary C owners,
what a guest pointer into a grown array should observe, and whether that
deserves a diagnostic rather than compiled D's silent staleness.

## Out of scope

`quickbite.executor.Value` (the legacy executor type) is unaffected, as
before; it dies with the legacy executors. Bytecode/interpreter
native-layout deduplication and any shared-substrate extraction are out
of scope (decision 16): later, if ever, and subordinate to finishing the
bytecode VM.

Restructuring the Walker's mirror/writeback machinery behind an internal
seam (for example, funnelling all mirror access through the binding
helpers) is likewise out of scope until the mirrored `Value` storage is
gone: a clean, tested interface would entrench machinery scheduled for
deletion.

## Guardrails

- The display format spec above is the contract: no formatter or
  test-migration work may diverge from it without updating it first.
- Display renderings must round-trip as valid D (decision 2): a rendering
  that cannot be parsed back and evaluated to an equal value is a spec
  violation, except for the no-D-expression values of rule 7.
- Do not use string heuristics in REPL/frontend code to classify D
  source.
- Do not use failed evaluation as REPL control flow.
- Keep backend-specific DMD conversion inside backend adapters while the
  interim scaffolding lives.
- Formatter-track changes must not touch `backends/bytecode/**`; bytecode
  display parity goes through `bytecode.md` slice 11 (decision 13). When
  a display change collides with a bytecode-pinned row, apply the matrix
  rule (drop the engine from that block, record the pending re-earn)
  rather than extending bytecode display scaffolding.
- Do not restore FFI marshalling, cell families, alias maps, pointer-kind
  predicates, or name-based representation shims. A blocked project gets an
  oracle-backed gap fixture and a native-storage fix.
- DMD-derived layout facts stay the source of truth, cached on the
  handle; the interpreter must not grow a second set of D layout rules
  (see Contracts).
