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
- Promoted cells provide authoritative reads, writes, whole-value
  reconstruction, and addresses for supported scalar, struct, class, static-
  array, and dynamic-array storage. Views compose by DMD offsets and strides;
  direct, nested, indexed, sliced, `ref`, and cross-frame access share the
  underlying storage identity rather than copies.
- Class bodies are owned by stable object identity, not a variable binding.
  Union storage observes overlapping DMD offsets and first-member default
  initialization for the supported recursively scalar-field shapes.
- Rebinding detaches a binding's cell and pointer memo; same-storage mutation
  updates the existing authority. Cast and slice carriers preserve allocation
  identity, absolute byte offset, and native address across bindings and calls.
- Boxed locals remain the general authority in the shipping walker, with
  residual unsupported promotion shapes. That architecture — boxed
  authority, lazy promotion, shape-keyed cell families, two pointer
  carriers — is interim by decision: decisions 15-18 replace it via the
  two-track migration in decision 17.

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
   metadata. The extracted `RuntimeValue` carrier's `Array`, `Struct`, and
   `ClassObject` expression aggregates remain recursive boxed trees.
   `AggregateValue` is their complete common visitor/reconstruction and
   mutation boundary, consumed by every aggregate operation in `impl` and
   `ffi_marshal`; its signatures are still `RuntimeValue`-typed. The next
   valid operation is one atomic carrier-boundary migration: change every
   `AggregateValue` consumer and its signatures to native typed-address
   aggregate handles, including whole-value reconstruction. A handle with no
   consumer is equally speculative. `RuntimeValue.Array` owns recursive
   elements for both static and dynamic arrays; its `nativeAddress` is an FFI
   shortcut, not a category boundary. Static/dynamic slicing of this migration
   is forbidden because it would create a second authority. The common
   boundary preserves the no-two-world invariant while its representation
   changes.
   This is a prerequisite to, not part of, the one atomic migration of the
   carrier's three interim data-pointer arms and local/frame/ref/capture/
   cross-frame authority to one host-address arm. Function and delegate
   handles are separate, non-data categories. That expression currency is
   distinct from the authoritative storage of an addressable guest value — it
   is a return type, never an authority (decision 15).
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
   §5/§6). The seam is `materialize(value, Type) -> ABI bytes` and
   `reify(Type, ABI bytes) -> value`; the interpreter owns its
   materialize/reify implementation and the bridge core never sees
   `Value`. The `ffi.md` §34.3 `B*` ladder rungs are this plan's, not the
   bridge's. End state (decision 18): with guest storage native,
   materialize/reify collapse to identity; a small backend adapter hands
   argument and result addresses to `quickbite.ffi`, which keeps owning
   ABI descriptors and call plumbing.

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
   two transparency settings; the boxed interpreter sits between them,
   paying a per-crossing materialize/reify. Moving to native layout is a
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
    there is no lazy promotion and no boxed-snapshot writeback. The
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
    inventoried as this track's deletion obligations in `interpreter.md`
    §9.10. Ordering: this track does not wait on cerealed-green;
    `interpreter.md` triages each frontier class as language-surface
    (fixed there) vs representation-ceiling (deferred here). The unit of
    change is the interpreter-wide representation — not a bolt-on
    marshaller (decision 18's measured result), and not a VM rewrite
    (`bytecode.md` is unaffected and remains the native-layout
    *execution* track).

15. **One storage world** (July 2026; supersedes the lazy-promotion
    architecture). Every lvalue is an address with a static type:

    - a local binds Quickbite-owned, GC-backed storage allocated at
      binding (a per-activation frame block, decision 17);
    - an extern global binds its resolved host address;
    - a `ref` parameter binds the address its caller supplied;
    - module-level guest state binds blocks in a module table, per the
      existing extern-data rules.

    Loads and stores operate at those addresses directly. There is
    exactly one data-pointer representation — the host address — and
    taking an address reads a number; there is nothing to promote. A
    *place* is an address plus its static type, nothing more: field
    access and indexing compute another address. GC rooting and
    ownership are private lifetime properties of some addressed memory,
    kept alive by ordinary scanning of the frames and blocks that
    reference it; they never participate in guest identity or address
    arithmetic. (A storage-identity-plus-offset coordinate system would
    recreate the provenance split that produced `isNativePointer`.)
    The authority switch replaces the expression currency's three
    data-pointer arms with its one host-address arm at the same time as it
    makes this storage rule authoritative; function and delegate handles are
    separate non-data categories. Boxed values survive only as transient
    rvalues (decisions 7/11), never as storage authority.

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
    - as the migration's done-marker, grep for today's pointer-kind
      predicates (`isNativePointer`, `isLocalPointer`) goes quiet.

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

17. **Migration: a working interpreter first; the representation lands
    beside it in green slices.** Priority order: working >
    representation purity > dedup. Dependency, stated plainly so the
    ladder is not misread as "representation later": the workingness
    goal itself — cerealed green — is ceiling-blocked at the head of
    its queue (the signed-byte reinterpret frontier,
    `interpreter.md` §10), so the authority switch is ON the critical
    path to the top priority. "Working first" therefore means both
    tracks run now: workingness leads on language-surface classes, and
    the representation track races to the switch because the last
    stretch of "working" is unreachable without it. Two parallel
    tracks, each in its own worktree:

    - The **workingness track** keeps the shipping boxed interpreter
      advancing toward the cerealed/dub goal: small short-lived
      branches, one language-surface fix plus its oracle-backed
      fixture per PR, merged to master continuously. Correctness fixes
      to boxed machinery are always in order — a working interpreter
      improved later beats purity now. Exactly two things stay frozen,
      and the tie-breaker is decided (do not re-decide it mid-triage):
      no new FFI marshalling rungs, and no new representation-ceiling
      machinery (cell families, alias maps, name-based shims). A
      project blocked on those gets a gap fixture and re-earns its row
      when the authority switch lands. `interpreter.md` §8 triage is
      the partition: language-surface → fix now; representation-
      ceiling → wait.
    - The **representation track** implements decision 15 in bounded,
      independently green preparation slices. Frame and place mirrors do
      not make an authority switch ready: the one coherent switch must
      replace all three data-pointer arms together with boxed-local
      authority, pointer identity and dereference, `ref`/`out`/capture
      binding, and cross-frame writes. `scalarCells` and alias maps cannot
      remain an authority behind native frame bytes. Not a monolithic rewrite
      verified only at the end, and not per-shape authority flips
      (mixed-shape values recreate the two-world coherence seams this
      redesign exists to kill): replace the whole local-storage path
      coherently, then delete the machinery it made dead. The track rebases
      onto master as workingness PRs land and absorbs their fixtures as its
      acceptance tests; the tracks converge when the native-layout authority
      passes the working interpreter's matrix.

    Activation storage: every activation allocates one frame block, including
    an activation whose layout has no slots. Contiguous activation storage is
    field-universal (CPython's fast-locals
    array, JVM/CLR frames, Lua's value stack), and the oracle compiler
    itself is precedent — DMD allocates one GC-heap closure frame per
    activation for captured locals. Per-local blocks are the fallback
    that needs a measured justification (e.g. scan-precision cost).
    Escaping locals stay alive because the frame block is a GC
    allocation; recursion is correct by construction because each
    activation allocates a fresh frame.

    Merge gate for the authority switch: **no new red rows** — green
    modulo the recorded known-red rows and pending re-earns. ("Full
    matrix green" is unsatisfiable while master ships a known red
    baseline row.)

    A from-scratch walker-v2 stays rejected: the expression-walking
    logic is representation-independent and survives; only storage
    access is rewired.

18. **FFI end state: no marshalling.** A goal and the completion
    signal, not the motivation (simplicity is, decision 15) — and a
    structural guarantee: whether FFI dominates a profile is unknown,
    but boundary crossing must not be slow *by design*. With guest
    storage native, an argument's bytes already sit at a real address
    and a native return is written straight into the result's storage:
    `materialize`/`reify` collapse to identity and `ffi_marshal.d` is
    a deletion target. A small backend adapter still hands argument
    and result addresses to `quickbite.ffi`, which keeps owning ABI
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

## Contracts

Invariants a change can silently break. Each was earned by a real bug or
a checked fact; do not relearn them. Classification: "Layout authority",
"Containers", the union DMD facts, and "Backend scope" are durable.
Everything that names cells, carriers, alias tables, or writeback is
boxed-era interim — **binding on every change to the shipping walker
until the authority switch (decision 17) deletes that machinery, and
deleted with it, not before**. The interim contracts are removed by the
change that makes them false, never prospectively.

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
- The FFI marshaller's shape *predicates* (`isOpaqueUnionOutCell`,
  `canMarshalToNative`, `canReifyFromNative`) deliberately read
  `sym.fields` directly: they must be able to answer `false` for a type
  DMD cannot lay out, whereas `structFields` throws for exactly such a
  type. Do not "consolidate" them.
- A static array's element count comes from `TypeSArray.dim` — the DMD
  field that IS the fact — never re-derived by dividing byte sizes.
- One deliberate scalar-codec split remains at the libffi seam: a direct
  native return / closure-result buffer is widened to at least `ffi_arg`
  and requires a sign/zero-extended whole-buffer splat that a
  fixed-width leaf codec must not absorb. That is an ABI-width concern
  specific to libffi's calling convention, not a second set of layout
  rules.
- `native_scalar` deliberately excludes `real` (`Tfloat80`): `ffi_marshal`
  shares that codec for its exact-size scalar arms, and widening it would
  change shipping FFI behaviour. `real` IS otherwise `place_value.
  isPlaceComposable` via its own leaf codec (`readRealBits`/
  `writeRealBits`); a write composes into a zero-initialised local and
  copies the WHOLE slot, making `real`'s padding deterministic for the
  verified mirror's raw-byte comparison.
- `place_value.valueMatchesPlace` is the recursive gate for whether a
  boxed execution value can enter the place writer. It includes both
  type composability and value shape, so mirror writes and scratch-byte
  verification cannot route a type/value pair differently.
- Integer offsetting of a native pointer preserves the native-pointer carrier
  and applies the byte delta already scaled from the expression's static
  pointer type. Do not route it through the boxed pointer's allocation id or
  element snapshot.
- Nested indexing into a native array composes offsets one level at a time:
  the outer index uses the immediate aggregate element's stride, then the
  scalar-leaf index uses the leaf type's stride. Do not flatten both indices
  against the leaf size.
- A constant-index address into a static-array local may arrive as a DMD
  `SymOffExp`; once that local has a native cell, its DMD-provided byte offset
  applies directly to the cell address rather than being re-derived as an
  element index.
- Subtracting two native pointers computes their byte-address difference;
  DMD's surrounding element-size division converts that to D's element
  distance. The boxed carrier instead stores element offsets and must scale
  its difference to bytes before the same division.

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
  without reallocating. Failure leaves the view unchanged; ordinary growth
  still allocates an owned array and rebinds at the call site.
- Reconstructing a promoted scalar-element array cell as a whole value keeps
  the cell's native address. Pointer casts, slices, and `void[]` reinterprets
  preserve that address and express length in the destination element type;
  dropping either fact recreates a boxed snapshot before the FFI seam.
- `setLength`'s grow path zeroes every newly exposed byte
  unconditionally, including bytes re-exposed by shrink-then-grow.
  Compiled D gates its memset on `__traits(isZeroInit, T)` and emplaces
  `T.init` otherwise (`char` 0xFF, `float` NaN); the walker's boxed array
  growth evaluates DMD's `defaultInitLiteral` for every new element.
  Native-container call sites must preserve that distinction rather than
  treating `NativeArray.setLength`'s zeroing as guest initialization.
- A written slice header is a snapshot of `{length, ptr}`; it goes stale
  when the array reallocates, exactly as a compiled-D slice does. Keeping
  a header in sync is the call site's problem.
- A same-width native-scalar dynamic-array cast is another typed view over
  the source array's existing block, never an element-converted copy. Each
  binding, whether introduced by a declaration or a later assignment, reads
  and writes those shared bytes through its own element type. Binding from an
  evaluated value recovers storage from a carrier keyed by the value's own
  allocation identity. One identity always names the allocation's root cell,
  never a frame-relative interior view; every slice offset, including a
  nested or zero-length slice's one-past-the-end offset, is absolute in that
  root coordinate. The first cast upgrades its source binding to carry that
  identity and absolute offset too, so a later slice or forwarded cast cannot
  fall back to a root-relative boxed snapshot. Binding derives a
  bounds-validated subview from that absolute offset and the value's length
  before reinterpreting its element type. It does not recover from the RHS
  syntax or a reverse lookup of the source variable. Rebinding any derived
  view drops that variable's alias id
  before a later cast can reuse it, but retains the id-keyed carrier for other
  live values. Rebinding the source similarly invalidates that variable's maps
  but cannot invalidate an earlier derived binding's carrier. Carriers fork
  and merge with call frames so identity, interior offsets, and zero-length
  views survive function boundaries. An unbound direct-cast expression still
  needs its syntax-specific source recovery until every cast result carries
  identity.
- Index bounds checks run before any offset arithmetic, and every
  construction path routes `length * stride` through checked
  multiplication — which is what makes subsequent `index * stride`
  provably wrap-free. Container failures throw `Exception`; whether a
  guest-facing call site should surface `RangeError` for compiled-D
  parity is that call site's decision.
- Do not write `GC.collect`-survival tests for scan policy: conservative
  stack/register scanning makes them pass even with a wrong policy.
  Assert the scan attribute directly.

### Cell coherence (boxed-era interim)

Binding until the authority switch deletes this machinery; deleted with
it (see the Contracts preamble).

- Cell and boxed-local state belongs to one execution, not to the reusable
  `Interpreter` adapter. Running a module parsed before an earlier module's
  execution must start from fresh value state; frontend AST age is not a
  reason to retain or replay a prior walker's cells.
- Every cell family must honour three obligations — dup on frame fork,
  merge on return, drop on rebind — and a missed one is invisible until
  it corrupts.
- Field-address allocation identity is keyed by an immutable
  `(root VarDeclaration, DMD field-index path)` value for direct and
  one-level-nested fields. Struct and class roots occupy the same key space
  because a declaration's static type fixes how its indices are interpreted.
  Fork, merge, and rebind invalidation operate on that key as a whole;
  extending a path must not introduce another allocation memo family.
- Reads consult the cell first and never the alias tables. Therefore
  every write path that reaches storage only through an alias table
  (slice alias, array-element alias, struct-field alias, `this` alias)
  must independently refresh the ultimate target variable's cell.
- Promoted-cell and allocation-identity routing admits only the boxed-pointer
  predicate. Local pointers resolve through their local binding and native
  pointers through their host address; neither may enter identity-map routing.
  Direct dereference and compound-assignment/atomic reads and writes share
  their respective ordered promoted-cell routes, so they cannot choose
  different interim authorities.
- One guest storage location has one identity across bindings, call frames,
  repeated `ref` arguments, and source/alias pairs. A promoted aggregate alias
  shares the caller's memoized pointer id and cell; a field alias shares the
  root-plus-path allocation id and the corresponding native subrange. Taking
  either address must recover that identity, and every read or write must use
  its authority. Boxed writeback remains only for shapes without a cell.
- Aggregate views compose from the authoritative root using DMD field offsets
  and immediate element strides. This covers fields and scalar leaves inside
  indexed structs, static arrays, and slice-backed dynamic arrays, including
  class roots owned by object identity. Inline storage stays inline; slice
  fields store a header in the root and address elements in their referenced
  `NativeArray`. A composed view never earns a shape-specific cell, pointer
  map, or reverse lookup.
- Rebind vs mutation: a cross-frame writeback refreshes a cell's bytes in
  place only for a same-storage mutation and must DROP the cell on a
  rebind. An in-place refresh after a rebind writes the new binding's
  bytes into storage a still-live alias reads — real corruption, found
  independently for arrays and for classes. Rebind markers
  (`arrayRebinds`/`classRebinds`) are set by the write path itself and
  read by the writeback, cascading correctly through nested frames.
- A class-typed plain-variable assignment is ALWAYS a reference rebind in
  D (classes have no `opAssign`), independent of the assigned value's
  kind — including `null`. Mark the rebind unconditionally: a null
  intermediate must not launder a later rebind into a "mutation".
- Class cells are sized from the STATIC class of the variable that
  promoted them. A base-typed receiver's cell is smaller than a derived
  method's `vthis` layout, so aliasing a base-sized cell to a
  derived-typed `this` reads out of bounds (a real bug under virtual
  dispatch). Skip `this`-aliasing on any static-class mismatch; the
  override body falls back to its boxed receiver.
- A promoted class body is keyed by the stable identity carried by every
  boxed reference to that object. Variable-keyed class-cell entries are only
  binding caches; fork and merge preserve the identity-owned table, while a
  rebind detaches only the cache. A scalar class-field pointer records the
  object's identity under its allocation id, so rebinding the variable used
  to obtain it does not invalidate the pointer. The variable remains
  reverse-lookup metadata, not the pointer's storage authority.
- Scalar, struct, and class cells belong only to true stack locals. A
  dynamic-array dataseg variable may gain a cell only after its lazily
  materialized current value is present in `locals`; seeding it from a
  default value would shadow its initializer and the extern data-symbol
  read/write paths. Promotion requested before materialization is a no-op.
  Slice-local promotion may initiate promotion after materialization;
  unsupported element shapes still remain on boxed aliasing paths.
- `object_table.ObjectTable`'s "stable identity ... minted once per
  boxed class object" premise needs `impl.d`'s `nextClassObjectId`
  counter single-valued across every child `Walker` that mints one. A
  heap-struct constructor and a class constructor each run the
  constructed type's body on a CHILD `Walker` of their own; a
  destructor is an ordinary member call and rides that call's own
  write-back. All of them merge the counter back into the caller on
  every path, an exception unwinding out of the body included, or the
  caller's next `new` can re-mint an identity the child already handed
  out.
  `storageFor` sizes a body from whichever caller's class reaches an
  identity first and reuses that block after, so every caller sharing
  an identity must agree on its dynamic class or corrupt memory writing
  through it — `place.Place` has no bounds check of its own.
- Fresh bindings (a declaration re-executed by a loop, recursion reusing
  the same AST `VarDeclaration`, parameter binding) must drop both the
  cell AND the pointer-id memo, so the next address-of mints a fresh id.
  A stale id must *decline* — falling back to the pointer's frozen boxed
  snapshot — rather than resolve into a later, unrelated binding's cell.
  Fresh-id-per-binding was chosen over a separate generation tag because
  the allocation id already travels inside the pointer value and needs no
  schema change. Residual: the frozen-snapshot fallback is correct only
  while nothing mutates the outer binding's storage between its
  address-of and the inner rebind — a real, open gap.
- Map merges on return: forward (variable-keyed) id memos merge with the
  merging frame's own entry winning; reverse (id-keyed) maps skip a child
  entry whose variable this frame binds to a DIFFERENT id (same
  `VarDeclaration`, different binding). A plain-union reverse merge is
  safe only while ids are never memoized for that shape — re-check that
  premise whenever a memo is added. When an array carrier escapes, merge
  exactly the newly promoted source cell named by that carrier after its id
  maps; never copy the child's whole cell table or overwrite this frame's
  existing cell for a reused `VarDeclaration`.
- Parameter writeback: only a genuine function parameter
  (`STC.parameter`) reconciles a cell across a return; a plain local that
  merely shares its AST node across recursion depths must not. This is a
  heuristic with a named residual: a recursive call passing an
  actually-different same-length array through the same formal parameter
  would still wrongly reconcile — closing it needs storage-identity
  tracking through parameter binding.
- Every whole read of promoted storage reconstructs all supported fields or
  elements from the cell before the value escapes through a return, argument,
  comparison, or display. This applies equally through a plain `ref` alias.
  Class assignment through such an alias rebinds its source; static-array
  assignment mutates the existing same-length storage and preserves interior
  pointer identity. Whole-array and element addresses remain distinct views of
  that same authority.
- The verified frame/object-body mirror's verify side must never
  re-derive a decline condition from mutable walker state — it must
  consult what the write side decided for the CURRENT value (a
  per-variable flag set right after each write), or a stale re-check
  can assert on bytes the write never wrote. It must never mutate the
  shared object table either: a per-write generation snapshot, not a
  fresh read, detects a later write to the same identity from a
  different binding. It also declines any object identity reachable more
  than once from one composed graph (sibling fields, cousins, a cycle
  alike): `locals[]` snapshots one boxed copy per REFERENCE, so those
  copies can legitimately contradict each other, and one shared body
  written once per reference then makes the byte comparison assert on a
  program the oracle runs.

Known gaps in this interim machinery — recorded so `interpreter.md` §8
triage recognizes them instead of re-investigating each as a new bug;
they die with the machinery at the authority switch:

- Unequal-width dynamic-array casts (byte-stream length and element
  regrouping) are unsupported; same-width casts share storage per the
  Containers contract.
- `out`-parameter initialization recognizes only the zero-memset
  `BlitExp`-with-integer shape DMD synthesizes for zero-init structs;
  the non-zero-init shapes (a real construct/call) are untried.
- Interior-slice `assumeSafeAppend` loses the capacity of the
  zero-length descriptor returned by `reserve` while rebinding it into
  the caller.
- Aggregate nesting deeper than one level has no promotion,
  write-through, or pointer-identity support.
- Reinterpreting promoted cells is unsupported for pointers, `real`,
  widening loads, and aggregates that do not fit; non-fitting writes
  must fail rather than corrupt adjacent storage.
- Postblit execution is an interpreter expression-execution gap.
- Recursive activations reuse each local declaration's `VarDeclaration`,
  while boxed cell maps key authority by that declaration.  A pointer saved
  by an outer activation can therefore resolve to an inner activation's
  fresh binding rather than the storage it named; only address-keyed native
  authority removes that ambiguity.
- Nested-struct and static-array class-field pointers follow the
  variable slot after a reference rebind rather than retaining object
  identity; `ref`-parameter address identity holds only for the
  supported repeated plain-variable and direct-field shapes, with
  non-plain-variable aggregate arguments still boxed copies plus
  end-of-call writeback.
- Class-typed fields and dynamic-array fields whose element is neither
  a native scalar nor a supported non-union struct have no cell support
  on either the read or write side.
- A class-typed local's own `locals[]` copy is never refreshed when a
  shared object identity is mutated through a different alias or a deep
  field-chain write (`a.b.c.value = x`) reached via another variable, so
  reading the stale alias returns the WRONG boxed value — a real bug in
  the boxed authority itself (the mirror merely declines to verify such
  a local, so this surfaces as a wrong-value divergence, not an assert).
  Closing it needs every class-typed read to consult identity-keyed
  storage instead of a per-variable copy, i.e. the authority switch.
- Union residuals: aggregate members beyond plain structs, promotion
  for unions with non-scalar members, and default-init first members or
  siblings outside the supported recursively scalar shapes.
- `promoteStructCell` guards only union-DECLARED types, so a plain
  struct bearing an anonymous union is promoted and its overlapping
  fields seeded last-wins into a cell — which, unlike the mirror, is
  authority once present.

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

Boxed-era interim (overlay reconciliation; binding until the authority
switch, under which a union becomes overlapping bytes and the last write
wins by construction):

- The per-field cell overlay writes every field at its own offset, so for
  a union the last field written wins. That is sound only when every
  field's boxed value already agrees bit-for-bit — which the union write
  path guarantees by re-deriving every sibling from the just-written
  member's bytes first. Consequently a union with any member the overlay
  cannot express (dynamic array, class, non-scalar-element static array,
  nested union) must decline cell promotion entirely.
- A transient union overlay must seed the whole cell from the union's
  CURRENT boxed state before writing the new member's bytes, or a sibling
  wider than the written member reads back zeros in its tail.
- Scalar, plain-struct, scalar-leaf-static-array, and scalar-field
  nested-union siblings are reconstructed from scalar, plain-struct,
  scalar-leaf-static-array, and scalar-field nested-union first members,
  plus static arrays of scalar-field plain structs at any depth as first
  members and one level as siblings, through one transient native block.

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

The contract flip (decision 1) and frontend-answered `:t` (decision 5)
are done. Ordering below follows the priority ladder in Status: the
workingness track (item 4) leads; the representation track (item 5) runs
in parallel and never blocks it.

1. Complete the prelude formatter wiring (decision 3). The formatter
   *surface* is done — scalars, arrays, structs, enums, AAs render per
   the round-trip spec, and the `text(value)` catch-all covers only the
   rule-7 no-contract values. Expression cells are synthesized as
   `__quickbiteFormat(expr)` for a broad set of return types when the
   backend opts in (`Ctfe`, `Interpreter`). The remaining gate exclusions are
   range and template structs, which still run through the interim
   `displayString`/`Value.toString` scaffolding. Keep expanding the gate per
   backend (decision 4) until every REPL expression is
   formatter-wrapped and the unformatted evaluator paths can be deleted.
   Items 2 and 3 are blocked until this wiring lands. The interpreter's
   `std.conv.text` hook is temporary formatter scaffolding, not a general
   Phobos builtin: remove it once the formatter no longer needs that escape
   hatch.

2. Complete the unittest/expression split for IR and Bytecode (decision 12).
   CTFE and Interpreter already execute unittest bodies directly and return
   only success/diagnostic. Then delete the private reify -> `Value` ->
   `toString` scaffolding per backend (decision 4) as each gains the
   formatter. Only a REPL expression cell executes the prelude formatter and
   consumes its returned string. Do not retain `Value` or render a dummy
   `void` result just to reuse the evaluator path.

3. Complete the interpreter-private `RuntimeValue` carrier's expression-only
   aggregate path before the authority switch. The common `AggregateValue`
   boundary is complete but remains `RuntimeValue`-typed. Its next operation
   is atomic: migrate every consumer and boundary signature to native
   typed-address aggregate handles and supply their whole-value reconstruction
   APIs. Do not introduce a handle separately, retain a `Value` aggregate path,
   or split static from dynamic arrays: `RuntimeValue.Array` owns recursive
   elements for both, and `nativeAddress` is only an FFI shortcut. The one
   migration replaces the boundary's recursively boxed `Array`, `Struct`, and
   `ClassObject` rvalues without relaxing the no-two-world invariant. Then
   replace its three data-pointer arms with one host-address
   arm in the same atomic migration that replaces local/frame,
   `ref`/`out`/capture, pointer-dereference, and cross-frame-write authority,
   and delete cells and aliases. Function and delegate handles remain separate
   non-data categories. Expression results need immediate scalars, native
   handles, locations, callables, and execution metadata only. Once no backend
   depends on `quickbite.lang.Value` as a cross-backend type, delete the shared
   struct and its unit tests together. This deletion is decision 15's
   completion signal.

4. **Workingness track (leads).** Keep the shipping boxed interpreter
   advancing toward the cerealed/dub goal: one language-surface fix plus
   its oracle-backed fixture per small, short-lived PR, merged
   continuously. Correctness fixes to boxed machinery are in order; only
   new FFI marshalling rungs and new representation-ceiling machinery
   are frozen (decision 17) — a project blocked on those gets a gap
   fixture and re-earns when the switch lands. `interpreter.md` §8
   triage is the partition.

5. **Representation track (parallel).** Implement decision 15 in
   bounded, independently green slices, then replace boxed local authority
   coherently (decision 17):
   - Frame and place mirrors exist: per-activation frame blocks whose binding
     address decoder is the single mechanical boundary between inline and
     reference slots, including frame-backed `Place` construction and mirror
     storage routing; lvalue
     places
     composing through a variable, fields, indexing, pointer/class
     dereference, and address-of — `this` has an arm but no reachable
     caller, since DMD slots `vthis` as neither a parameter nor a body
     local and `resolveBase` therefore always declines it; `ref`/`out`
     and captured-variable reference slots; and load/store through places
     for scalars, enums, pointers, `real`, structs, unions, slices,
     class object bodies, and dataseg storage, each verified against
     the still-authoritative boxed value on write. Composition gaps
     carried to the switch: `placeOfLvalue` refuses a `SliceExp`
     assignment target and a `SymOffExp` naming a function; a
     captured-variable slot cannot resolve a relay through a
     non-referencing intermediate activation.
   - The authority switch is item 3's one atomic migration: every
     data-pointer producer and consumer changes to the carrier's one
     host-address arm while pointer creation and dereference change to frame
     bytes, `ref`/`out` and captured bindings carry addresses, and cross-frame
     mutation writes those addresses directly. Function/delegate handles stay
     separate non-data categories. Do not retain `scalarCells`, other cell
     families, or alias/reverse maps as an authority behind the frames: a
     mirror plus any of those authorities is still two storage worlds.
   - `object_table.ObjectTable` never evicts: every class identity the
     mirror touches keeps its body pinned for the whole execution,
     because liveness lives in `impl.d`'s boxed copies and nothing
     reports it back, and a wrong eviction silently splits one object
     into two bodies. Nothing to do before the switch, which dissolves
     the question instead of answering it: once a native block IS the
     object, its lifetime is the collector's and no identity-keyed pin
     exists.
   - The authority switch: native storage becomes the sole authority
     for all bindings as part of that coherent path replacement. Merge gate:
     no new red rows (decision 17).
   - Deletions once dead, checked by grep going quiet: `scalarCells`/
     `arrayCells`/`structCells`/`classCells`/`classObjectCells` and
     every alias/reverse map, `arrayRebinds`/`classRebinds`,
     `forkPerFrameCellsInto`/`mergePerFrameCellsFrom` and the rest of
     the cell lifecycle dispatch, parameter writeback, `ffi_marshal.d`,
     and the pointer-kind predicates (`isNativePointer`,
     `isLocalPointer`) — plus the interim contract sections above.
   Success criteria, in order:
   - the `interpreter.md` §9.10 shims are deleted one by one, each
     deletion proven by its ratchet fixtures staying green through the
     real path (`emplaceRef` executes its actual body; `memcpy` and
     the `gc_*` hooks route through ordinary FFI);
   - the parked representation-ceiling gap fixtures (§9.10 "gap
     fixtures") re-earn `Interpreter` in their matrices;
   - the cerealed frontier resumes on the new representation, and the
     latency A/B against the boxed baseline is measured on real suites
     once they run — a hoped-for improvement, not an assumed one.

6. Open design questions carried forward: lifetime contracts for
   blocks borrowed from arbitrary C owners; what a guest pointer into
   a grown array should observe, and whether that deserves a
   diagnostic rather than compiled D's silent staleness.

## Out of scope

`quickbite.executor.Value` (the legacy executor type) is unaffected, as
before; it dies with the legacy executors. Bytecode/interpreter
native-layout deduplication and any shared-substrate extraction are out
of scope (decision 16): later, if ever, and subordinate to finishing the
bytecode VM.

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
- Correctness fixes to the shipping boxed interpreter are always in
  order (working first). Frozen until the authority switch: new FFI
  marshalling rungs and new representation-ceiling machinery (cell
  families, alias maps, name-based shims). The tie-breaker is decided
  (decision 17): a blocked project waits with a gap fixture; do not
  re-decide this mid-triage.
- DMD-derived layout facts stay the source of truth, cached on the
  handle; the interpreter must not grow a second set of D layout rules
  (see Contracts).
