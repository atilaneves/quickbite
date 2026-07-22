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
   metadata. That expression currency is distinct from the authoritative
   storage of an addressable guest value — it is a return type, never an
   authority (decision 15). The earlier claim that a boxed tagged union
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
    Boxed values survive only as the walker's transient rvalue
    expression currency (decisions 7/11), never as storage authority.

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
      independently green preparation slices with authority unchanged
      — per-activation frame blocks plumbed in, lvalue evaluation
      returning places (addresses), loads and stores routed through
      them — followed by ONE small global authority switch, then
      deletion of the machinery the switch killed. Not a monolithic
      rewrite verified only at the end, and not per-shape authority
      flips (mixed-shape values recreate the two-world coherence seams
      this redesign exists to kill): preparation changes the behavior
      of nothing, and the switch is small because everything is
      already in place. The track rebases onto master as workingness
      PRs land and absorbs their fixtures as its acceptance tests; the
      tracks converge when the native-layout authority passes the
      working interpreter's matrix.

    Activation storage: one frame block per activation. Contiguous
    activation storage is field-universal (CPython's fast-locals
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
  `staticArrayLength`, `classInstanceByteSize`. Every number is DMD's own,
  verbatim; the interpreter must not grow a second set of D layout rules.
  A class body's byte size is always `classInstanceByteSize` (DMD's own
  `structsize`, including the vtable/monitor header and tail padding),
  never a hand-summed `fieldByteOffset(field) + typeByteSize(field.type)`
  over `classFields` — that sum omits the header and can under-count a
  field-less class down to 0.
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
- `native_scalar` deliberately excludes `real` (`Tfloat80`) because
  `ffi_marshal` shares that codec for its exact-size scalar arms, and
  widening it would change shipping FFI behaviour — out of scope for the
  place-composition layer. `real` IS otherwise `place_value.
  isPlaceComposable`, through its own leaf codec there
  (`readRealBits`/`writeRealBits`): decision 15 makes host layout the spec
  on THIS host, not a hazard to refuse, so `layout.typeByteSize`'s own
  answer for `Tfloat80` (16 bytes on x86-64, DMD's `Target.realsize`) is
  as authoritative as any other type's. The one real hazard is padding
  determinism: an x87 extended-precision store only touches the
  significant bytes (10 of 16 here), so a write must zero the whole slot
  first or the verified frame mirror's whole-slot byte comparison sees
  nondeterministic trailing bytes and asserts.
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
- Recursive activations of one function share one cell (all cell maps
  key on `VarDeclaration`) — a real divergence.
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
  shared object identity is mutated through a different alias or a
  deep field-chain write (`a.b.c.value = x`) reached via another
  variable, so reading the stale alias returns the WRONG boxed value —
  a real bug in the boxed authority itself. The frame mirror
  (`classIdentityAliasedByAnotherBinding`, `impl.d`) declines to mirror
  or verify a class local whenever another live binding boxes the same
  identity, so this surfaces as an ordinary wrong-value divergence
  rather than the mirror's own internal assert; closing the underlying
  staleness generally needs every class-typed read to consult
  identity-keyed storage instead of a per-variable copy, i.e. the
  authority switch itself
  (`classField.deepChainWriteThroughOneAliasVisibleThroughAnother`).
- Union residuals: aggregate members beyond plain structs, promotion
  for unions with non-scalar members, and default-init first members or
  siblings outside the supported recursively scalar shapes.

### Unions

Durable DMD facts:

- DMD reports a union as a `TypeStruct` whose `sym` is a
  `UnionDeclaration`; every top-level member's offset is 0, and an
  anonymous union's members are flattened into the parent's fields at
  overlapping offsets. The offsets themselves are the aliasing truth;
  DMD's `overlapped` flag is a derived fact about them, not a second
  source of truth to consume.
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

3. Remove the *shared* `quickbite.lang.Value` (decision 7): once no
   backend depends on it as a cross-backend type, relocate the tree-
   walking interpreter's execution-result carrier to its package, then
   delete the shared struct and its unit tests together. Do not reproduce
   a display-oriented general-purpose `Value` privately: the carrier
   exists only for recursive expression/function execution and uses
   immediate scalar results plus the native handles, locations,
   callables, and metadata that execution actually requires. This
   deletion is decision 15's completion signal.

4. **Workingness track (leads).** Keep the shipping boxed interpreter
   advancing toward the cerealed/dub goal: one language-surface fix plus
   its oracle-backed fixture per small, short-lived PR, merged
   continuously. Correctness fixes to boxed machinery are in order; only
   new FFI marshalling rungs and new representation-ceiling machinery
   are frozen (decision 17) — a project blocked on those gets a gap
   fixture and re-earns when the switch lands. `interpreter.md` §8
   triage is the partition.

5. **Representation track (parallel).** Implement decision 15 in
   bounded, independently green slices, then one small authority switch
   (decision 17):
   - Preparation, behavior-neutral, each slice green on its own:
     - Per-activation frame blocks: one GC block per activation, DMD's
       own closure model, with slot offsets assigned by
       `frame_layout.computeFrameLayout` from DMD's own per-type size and
       alignment, and the block itself allocated by
       `frame_block.FrameBlock` with a scan policy chosen from
       `layout.typeHasPointers` over each slotted local's type —
       allocated per activation, including the top-level walker running
       a unittest/REPL body, and held on `Walker._activationFrame`, with
       authority still in `locals`/cells until reads route through it. A
       non-address-taken local whose type is place-composable
       (`place_value.isPlaceComposable`: a native scalar, a struct or
       union all of whose own fields/members are themselves
       place-composable, or a static array of composable elements) has
       its frame slot kept as a verified shadow, mirrored by `setLocal`
       and
       checked against the boxed value on every read; a slice local's
       slot instead holds a `{length, ptr}` header mirror (from the
       boxed value's stable native backing) verified the same way. A
       class local's slot holds a real reference (address) into an
       object body owned by `object_table.ObjectTable`, keyed by
       object identity rather than any one variable binding so two
       bindings to the same object resolve to one body
       (`mirrorToFrame`'s `mirrorClassToFrame`/`assertFrameMirror`'s
       `assertClassFrameMirror`, verifying both the stored reference
       and the body's own fields); the table is allocated once per
       root `Walker` and shared — by pointer, not by value — into
       every forked child (`forkPerFrameCellsInto`), since an
       identity-keyed table needs no per-frame divergence the way a
       variable-keyed cell does. `Value.null_` mirrors as a plain
       `null` reference; a `classIdentity` of 0 or a class whose
       fields are not `place_value.isClassBodyComposable` is left
       unmirrored, matching every other decline case above. Module-level
       guest state (`VarDeclaration.isDataseg`: module-level, `__gshared`,
       or `static`) owns no frame slot at all — `frame_layout.
       isAliasingLocal` excludes it from `computeFrameLayout` on purpose,
       "it lives in the module table instead" — so it gets the identical
       verified-mirror treatment routed to its own block in
       `module_table.ModuleTable` instead of a frame slot
       (`mirrorToFrame`/`assertFrameMirror`'s shared `hasMirrorSlot`/
       `mirrorAddress` resolving which storage a variable mirrors into);
       the table follows `object_table.ObjectTable`'s identical
       once-per-root-`Walker`, shared-by-pointer lifetime, so two frames
       touching the same module variable resolve to the same block. A
       dataseg variable bound to an extern host address (`ffi.md` §35.2)
       never reaches the mirror at all: it never enters `locals` in the
       first place (`writeLocation`'s extern arm writes straight through
       the resolved address and returns before ever calling `setLocal`,
       this mirror's only caller), so the exclusion needs no separate
       check.
     - Lvalue evaluation yielding places: a `place.Place` is an address
       plus its static type; `field`/`index` compose another place by
       DMD offsets/strides — `index` on a pointer or slice place follows
       the place's own stored pointer (or the slice header's `ptr`)
       rather than indexing inline, `deref` follows a pointer or class
       place's own stored pointer/reference to the pointee/object body
       (keeping the class type, so a following `field` composes at the
       DMD class field offset) so pointer-deref and class-field lvalues
       can compose — and scalar load/store routes through the
       `native_scalar` codec. `lvalue_place.placeOfLvalue` composes a
       place for the variable, `this`, struct- and class-field, index,
       pointer-deref, and DMD's constant-offset address-of (`SymOffExp`,
       e.g. `&local`/`&arr[2]`) lvalue shapes from a caller-supplied
       base-address resolver and index evaluator (`a[i]` =
       `placeOfLvalue(a).index(evalIndex(i))`, uniform over a
       static-array, pointer, or slice base; a class receiver's field,
       `*p`, and a class `this` all compose through `Place.deref` — a
       struct `this` instead resolves like a bare variable straight onto
       the receiver's own storage, needing no `deref`; a `SymOffExp`
       applies DMD's own byte offset directly onto its variable's address
       rather than re-deriving it as an element index, landing on the
       pointee its own type names a pointer to). Still refuses anything
       else — e.g. `SliceExp` as an assignment target, or a `SymOffExp`
       naming a function rather than a variable.
     - `ref`/`out` parameter reference slots: `frame_layout.
       computeFrameLayout` gives every `ref`/`out` PARAMETER (not yet a
       `ref` body local — out of this slice's scope) a pointer-width
       REFERENCE slot (`FrameLayout.Slot.Kind.reference`, sized/aligned
       from the host pointer rather than the parameter's own declared
       type), packed into the same encounter-order cursor as every
       owning slot around it and scanned conservatively regardless of
       the parameter's own type — distinguishable from an owning slot
       (`FrameBlock.hasOwningSlot`/`hasReferenceSlot`/`referenceSlotValue`/
       `setReferenceSlot`) so the verified mirror above (gated on
       `hasOwningSlot`, not `hasSlot`) never treats a stored address as
       inline storage of the parameter's own type. At a call,
       `impl.d`'s `bindReferenceSlot` composes the caller-side `Place` of each
       `ref`/`out` argument via `placeOfLvalue`, using `callerReferenceBase` as
       `resolveBase` (the caller's own owning slot, the shared `moduleTable` for
       a dataseg variable, or — reading THROUGH an already-filled reference slot
       — the caller's own forwarded `ref` parameter, so forwarding survives
       several activations including recursion) and `constantIndex` as
       `evalIndex` (DMD's own already-folded integer constant only, never a
       runtime evaluation: the boxed argument snapshot has already evaluated the
       argument expression, including any index, exactly once, and evaluating a
       runtime index again risks firing a side-effecting index a second time).
       Declines silently rather than guessing — never throws past
       this boundary — whenever the shape does not compose, the base is
       not mirrored, an eligible-but-never-filled reference slot (its
       zero-initialised default) is read through, or the composed
       address is itself `null` (an `interpreter.md` §9.10-shimmed
       call's own synthesized, non-source-derived argument expressions
       can compose a spurious, non-throwing address). Verified only at
       BIND time (`assertReferenceBind`): the composed address's bytes
       must equal the just-bound boxed value's bytes, for a
       `place_value.isPlaceComposable` parameter type only, and skipped
       entirely when the base resolved THROUGH another reference slot —
       that storage is allowed to legitimately lag the forwarding
       activation's own boxed mutation until its OWN writeback runs at
       return (recursion mutating its `ref` parameter before recursing
       is the simplest case), so comparing there would false-positive on
       a correct program. This is a deliberate, one-time weakening of
       the mirror's usual "verified on every read" contract: a `ref`
       parameter's boxed authority is a COPY the callee mutates for the
       rest of the call with reconciliation deferred to the existing
       parameter writeback at return (see Cell coherence's own
       "Parameter writeback" bullet below), so caller and callee bytes
       legitimately diverge from the first mutating statement onward —
       checking on every read would fail correct programs, and no cheap,
       provably order-independent RETURN-time check exists either, since
       the writeback's own named residuals (rebind-vs-mutation
       heuristics, the recursive-parameter residual) do not guarantee a
       return-time equality even on already-correct paths. Authority
       stays boxed throughout: nothing reads this slot yet.
     - Captured-variable reference slots: a nested `FuncDeclaration`
       gets one more pointer-width REFERENCE slot per enclosing local it
       captures (`frame_layout.capturedVariables`, added to its own
       layout alongside its `ref`/`out` parameter slots), reading DMD's
       own `FuncDeclaration.outerVars` — populated by the frontend's own
       nested-reference analysis, never re-derived by walking a
       function's body here. `impl.d`'s `bindCapturedReferenceSlots`
       fills each such slot, at every `isNested`-gated call site that
       already boxes the capture via `locals.dup`, with THIS (calling)
       activation's own address for that variable — reusing
       `callerReferenceBase` exactly as the `ref`/`out` parameter slice
       does, so a captured variable that is itself a `ref`/`out`
       parameter, or itself a capture forwarded from a still-further-out
       activation (a doubly-nested function directly naming a
       grandparent's local — DMD's own `outerVars` already flattens that
       far), resolves the same way a forwarded `ref` argument does.
       Declines silently through the identical conditions: no mirrored
       caller-side storage, an eligible-but-never-filled reference slot,
       or a composed address of `null`. One topology it cannot yet
       resolve: a capture relayed through an intermediate activation
       that never itself references the variable, since that
       activation's own frame carries no slot for it at all — a real
       compiled closure walks a static-link chain through every
       intermediate frame regardless of what it references itself; this
       shadow has none yet, so that case declines rather than guesses.
       Verification reuses `assertReferenceBind` unchanged (bind-time
       only, skipped when resolved through forwarding, silently declined
       for a captured shape `place_value.isPlaceComposable` does not
       compose). Authority stays boxed throughout: nothing reads this
       slot yet. What the authority switch will still owe here: a
       delegate can outlive the activation it was created in (the boxed
       world already allows this, since it copies rather than
       references); once native storage is the sole authority, a
       reference slot's address must stay valid for as long as
       something can still call through it, which is exactly why
       decision 17 makes the frame block a GC allocation — the same
       answer DMD's own compiled closure frame gives.
     - Loads/stores routed through places: whole-aggregate read/write composed
       over places down to scalar leaves by `place_value.readValue`/`writeValue`
       (native scalar leaves via `Place.loadScalar`/`storeScalar`; non-union
       struct and static-array shapes recurse field-by-field/element-by-element
       via `Place.field`/`index`). A slice composes symmetrically: `readValue`
       reconstructs one from its native `{length, ptr}` header and elements;
       `writeValue` (`place_value.writeSliceValue`) allocates NEW backing
       storage sized to the value's own length
       (`native_array.NativeArray.allocate`, scan policy chosen once from
       `layout.typeHasPointers` over the element type, per the Containers
       contract), writes every element through the same `Place.index`
       composition the read side uses, and writes the `{length, ptr}` header
       into the destination place LAST, so an element type `writeValue` cannot
       compose refuses the whole write before the destination is ever touched.
       The allocated storage stays reachable only via that header; the write
       throws rather than silently under-protecting it when the destination is
       not GC-scanned (the `writeSliceHeader` check, reached through a
       raw-address overload since a `Place` has no `NativeArray` handle of its
       own — see `native_array.d`'s header comment on that overload). This does
       not change `isPlaceComposable`'s verdict for a slice (still `false`):
       that predicate gates the verified frame mirror, which still mirrors a
       slice local by header alone (`impl.d`'s `mirrorSliceToFrame`), not by
       this full place composition.
     - An enum leaf reads back tagged per the Display format spec rather than as
       the plain integral value `native_scalar.readScalar` alone gives it:
       `readValue` resolves the qualified member name (or the non-member
       `cast(E)N` form) from DMD's own member declarations via
       `layout.enumMemberQualifiedName`; `writeValue` already stores an enum's
       bits correctly through the same scalar path, since `Value.asLong` already
       unwraps an `EnumValue`.
     - A pointer is a composable LEAF, not a recursion: its own bytes ARE the
       host address (decision 15), so `readValue` reads it back via
       `Place.deref.address` (`Place.deref`'s existing pointer arm), boxing a
       `null` address as `Value.null_` (the same value `impl.d` gives a `null`
       pointer literal) and any other address as `Value.nativePointerValue`.
       `writeValue` stores a boxed value's own host address through
       `Place.storeReference` (`place.d`, shared between a pointer and a class
       place). This refusal is VALUE-dependent, unlike every type-shape refusal
       elsewhere in this codec: the pointer TYPE is always accepted, and
       `writeValue` refuses only a `value` that is not itself a host address —
       `isLocalPointer`'s allocation-id carrier, the struct-shaped `Pointer`, a
       function pointer's minted id — since none of those boxed-era stand-ins IS
       the address decision 15 requires, and this codec has no address to invent
       for them.
     - Every mirror-side scratch allocation (`impl.d`'s `assertFrameMirror`/
       `assertClassFrameMirror`/`assertClassReferenceMirror`) chooses its scan
       policy mechanically: `layout.typeHasPointers` over the
       type being composed for the generic composable path, and an explicit
       `Scan.conservative` (never derived, matching
       `object_table.allocateBlock`'s own reasoning) for a class body's or a
       bare reference's scratch, both of which always carry a pointer-shaped
       fact regardless of one field's own type. `isPlaceComposable` answers
       `true` for a pointer unconditionally: the type-shape question, matching
       `readValue`/`writeValue`'s own leaf.
     - The pointer refusal above is VALUE-dependent, so it must hold on the
       mirror's write and verify sides too: `impl.d`'s `placeShapeMatches` (the
       single function both `mirrorToFrame` and `assertFrameMirror` call before
       ever reaching `writeValue`) has a pointer arm matching `writeValue`'s own
       condition (`value.isNativePointer || value == Value.null_`), so a `value`
       this gate declines is skipped identically on both sides — for a bare
       pointer local and for a pointer FIELD nested in an otherwise-composable
       struct/union/array reached through the same recursive check.
     - Class body storage: a dynamic-array local holds a real `{length, ptr}`
       slice header; a class variable holds a reference (address) to an object
       body owned by object identity and stored in `object_table.ObjectTable`,
       keyed on that identity rather than any one variable binding, and composed
       field-by-field the same way a struct is. `readValue` follows a class
       place's stored reference via `Place.deref` (a null reference reads back
       as `Value.null_`) and recurses one `readValue` per `layout.classFields`
       field (base-to-derived, inherited fields included), naming the class and
       its inheritance chain from the `ClassDeclaration` itself
       (`layout.classQualifiedName`/`classHierarchyNames`); the boxed `Value`'s
       `classIdentity` is the body's own address, not a minted counter.
     - `place_value.writeClassBody` is the write-side mirror for a body whose
       address is already known (an `ObjectTable` lookup), recursing
       `writeValue` per field; `writeValue` itself still refuses a class-typed
       place — it would have to store a reference, and the address for a given
       identity is only known to whoever owns the `ObjectTable` (`impl.d`'s
       `classObjectTable`, wired into the verified frame mirror but not into
       this generic per-place dispatch) — so that arm stays deferred until the
       authority switch supplies one.
     - A class-typed FIELD composes too, an object GRAPH and not only a single
       object: `writeClassBody` takes an explicit `resolveObjectBody` capability
       (identity-to-address, the same caller-supplied-policy shape
       `lvalue_place.placeOfLvalue`'s `resolveBase`/`evalIndex` use; `impl.d`
       satisfies it from `classObjectTable`) and recurses into a nested field's
       own body once that address is resolved. `readValue`'s class arm
       (`place_value.readClassValue`) composes a nested class field with no
       changes needed, since a field's place is shaped identically to the
       top-level one.
     - Cycle policy: both `readClassValue` and `writeClassBody` thread a DFS
       "currently on this reference chain" identity set (removed on backtrack,
       so two SIBLING fields sharing one identity — a DAG, not a cycle — still
       compose independently) and THROW, declining rather than recursing forever
       or silently truncating, the moment an identity reappears on the path.
       `place_value.isClassBodyComposable` answers `true` unconditionally for a
       class-typed field (a TYPE-shape question; recursing into the referenced
       class's own fields would have no well-founded base case for a
       self-referencing declaration like `class Node { Node next; }`) rather
       than recursing the `isPlaceComposable` check it uses for every other
       field type.
     - The VALUE-level questions `isClassBodyComposable` cannot ask — an
       unresolvable identity, a live cycle, or a nested object whose OTHER field
       is itself not composable — are `impl.d`'s `classBodyShapeMatches`:
       - It threads the identical identity-keyed DFS guard, recursing into a
         class-typed field's own value before
         `mirrorClassToFrame`/`assertClassFrameMirror` ever reach
         `writeClassBody`, so a cycle declines there deterministically rather
         than by throwing out of `writeClassBody`'s own recursion (this codebase
         avoids exceptions for control flow). The DFS set is seeded with the
         ROOT object's own identity before the walk starts: a field's boxed
         `Value` is a snapshot taken at assignment time, so a direct
         self-reference (`n.next = n`) reads back `null` one field further in
         and would otherwise never re-trip the guard, even though
         `writeClassBody` resolves that field to the SAME real address as the
         root and throws on it — seeding the root keeps this gate and
         `writeClassBody`'s own address-keyed guard agreeing regardless of how
         the boxed snapshot happens to truncate.
       - It declines whenever a nested identity is present in `classObjectCells`
         (the boxed-era promoted-cell table): `locals[]` caches one boxed copy
         of an object graph PER VARIABLE that references it, and neither a write
         through an independently promoted cell for a shared identity nor a deep
         field-chain assignment (`a.b.c.value = x`) propagates into every OTHER
         variable's own cached copy of that identity. `assertFrameMirror`'s own
         caller-level guard already skips this exact staleness for a DIRECTLY
         promoted variable (`variable in classCells`); a class-typed field has
         no variable of its own to gate on, so this repeats that protection one
         level down.
       - A plain top-level class LOCAL has the same gap one level UP: `auto
         aliasLeaf = mid.leaf;` aliases through a `DotVarExp`, not the bare
         `VarExp` `registerClassAliasIfPlainVar` requires to promote a cell, so
         `classObjectCells` never learns about it either.
         `classBodyShapeMatches` therefore also declines whenever the variable's
         own identity is currently boxed by ANOTHER live variable (`impl.d`'s
         `classIdentityAliasedByAnotherBinding`, scanning `locals` for a match)
         — the top-level counterpart of the nested-field decline, evaluated by
         the same shared gate so `mirrorClassToFrame` and
         `assertClassFrameMirror` stay symmetric. Both declines are deliberately
         coarse — an unmirrored local costs nothing while authority stays boxed,
         while a false negative here would re-crash the interpreter — so each
         declines a shared identity outright rather than proving a stale read is
         actually imminent.
       - It declines whenever a `value`'s own dynamic class name
         (`Value.classTypeName`, set once at `new` from the constructed type and
         never revised) disagrees with `layout.classQualifiedName(class_)` for
         `class_` — the variable's (or a class-typed field's) own STATIC type,
         not necessarily the object's dynamic one, since a `Base`-typed local
         can box a `Derived` instance. This guards against a real silent GC-heap
         corruption: `object_table.ObjectTable.storageFor` sizes an identity's
         body from whichever caller's `class_` reaches it FIRST and returns that
         SAME block to every later caller unchanged, so a `Base`-typed mirror
         allocating first and a `Derived`-typed mirror for the SAME identity
         following it would get that same too-small block back, and
         `writeClassBody` would write `Derived`'s wider field layout through it
         with no bounds check of its own (`place.Place` has none). Declining on
         a static/dynamic name mismatch — rather than resolving the object's
         actual dynamic `ClassDeclaration` to size against — costs only mirror
         coverage for a polymorphic binding: `Value` carries no
         `ClassDeclaration`, only a name, and a name-to-declaration search
         (`classDeclarationByQualifiedName`) is not the same guarantee as the
         exact symbol DMD bound this object's construction to.
         `ObjectTable.storageFor` also carries its own defense-in-depth check —
         not the primary guard, since `classBodyShapeMatches` above is what
         keeps every caller's `class_` for a given identity equal to that
         identity's own dynamic class — throwing (not an `in` contract, which
         `-release` strips) if a cache-hit's block size ever disagrees with the
         requested class's own instance size, so a future caller bug of the
         identical shape is loud rather than silently corrupting.
     - The mirror's own object-body comparison (`impl.d`'s
       `assertClassBodyValue`) is a DEDICATED recursive function, not a call to
       `writeClassBody`: `writeClassBody`'s resolver writes into the REAL nested
       body (correct for `mirrorClassToFrame`, wrong for an assertion, which
       must never mutate the body it is comparing against), so
       `assertClassBodyValue` builds one scratch per graph level and compares
       each against `classObjectTable`'s own entry instead.
     - CONTRACT — write/verify TIME symmetry: the verify side
       (`assertClassFrameMirror`) must never re-derive a decline condition that
       reads mutable walker state; it must be conditioned on what the write side
       (`mirrorClassToFrame`) actually did for the binding's CURRENT value, not
       on a fresh re-run of the same predicate. A shared predicate is symmetric
       with the write only at the INSTANT the write ran —
       `classIdentityAliasedByAnotherBinding` is TIME-VARYING (another binding's
       own later rebind or null can flip its verdict), so re-running it at read
       time could proceed where the write declined, comparing a frame slot or
       `ObjectTable` body `mirrorClassToFrame` never wrote against a freshly
       composed non-zero expectation — a guaranteed internal `AssertError` on a
       correct guest program (e.g. a `Base`/`Derived` alias whose OTHER binding
       is nulled between the write and a later read). `impl.d`'s
       `classMirrorEstablished`, a per-variable flag only `mirrorClassToFrame`
       ever writes (`true` right after an actual write, including a `null`
       reference; `false` on every decline, via `scope(exit)`), is what
       `assertClassFrameMirror` consults FIRST instead of re-deriving anything;
       it needs no separate rebind invalidation, since `locals[variable] =
       value` is written only by `setLocal`, which calls `mirrorClassToFrame`
       with that SAME value immediately after for every write this walker has,
       so the flag is always freshly overwritten by the write that changes a
       binding, and a fresh activation's own frame starts with no entry —
       correctly "not yet established", the same way its frame slots start
       GC-zeroed.
     - The premise above -- `classMirrorEstablished[variable]` only ever
       changes alongside `locals[variable]`, because both are written by the
       SAME `setLocal` call -- holds for every ordinary write, but not
       across the one seam that runs `setLocal` against SOMEONE ELSE's
       `locals`: a `lazy` argument's thunk. `runLazyArgument` runs the
       thunk on the callee's own `Walker`, with `locals`/`_activationFrame`
       swapped to the CALLER's live storage so a mutation inside the thunk
       (e.g. rebinding a class-typed caller local) is visible to the caller
       immediately (`bindLazyFunctionParameter`'s own header). A `setLocal`
       reached from inside the thunk still calls `mirrorClassToFrame` on
       `this` -- the CALLEE -- so its write/decline decision would land in
       the callee's own `classMirrorEstablished`/`classMirrorGenerations`
       unless those are swapped too, leaving the CALLER's map holding
       whatever decision it recorded before the call while its real bytes
       were just mutated underneath it: the same unsafe direction the
       CONTRACT above forbids, reached through a decline instead of a
       re-derived predicate. `runLazyArgument`/`bindLazyFunctionParameter`
       therefore swap `classMirrorEstablished`/`classMirrorGenerations`
       exactly like `locals`/`_activationFrame`, through captured POINTERS
       to the caller's fields (`lazyArgumentClassMirrorEstablished`/
       `lazyArgumentClassMirrorGenerations`) rather than the AA values
       themselves -- an empty `bool[VarDeclaration]`/
       `size_t[size_t][VarDeclaration]` is `null`, so a value copy would not
       alias the caller's storage the way `Value[VarDeclaration]` aliasing
       for `locals` relies on -- writing back through those pointers when
       the thunk returns, and forwarding them the same way
       `lazyArgumentLocals`/`lazyArgumentFrames` already do when a `lazy`
       argument is itself re-forwarded into another `lazy` parameter.
     - One decline condition is a proven EXCEPTION to this contract, safe to
       re-derive at verify time: `identity in classObjectCells`
       (`classBodyShapeMatchesImpl`'s nested-field decline) is MONOTONIC — an
       identity, once cell-promoted, never leaves `classObjectCells` (only the
       per-variable `classCells` cache is dropped, on rebind) — so re-checking
       it at verify time can only ADD a decline over what the write saw, never
       accept a genuine divergence as a match. `assertClassBodyValue`'s own
       nested-field recursion re-derives exactly this one condition, closing a
       DIFFERENT staleness a frozen top-level flag cannot see on its own: a
       nested field's identity promoted into `classObjectCells`, and mutated
       through that separate, `ObjectTable`-independent storage by an entirely
       different alias, strictly AFTER the owning variable's own mirror last
       established (e.g. a `Parent`/`Child` fixture whose `&child.x` promotes
       and mutates exactly such an identity).
       This contract also retired the all-zero skip
       (`isZeroFilled`, deleted) `assertClassBodyValue`/
       `assertClassReferenceMirror` used to carry: once the verify side
       trusts what the write already decided, the storage it goes on to
       compare was genuinely written by that SAME write, closing the
       "never established, reads as zero" ambiguity the skip existed to
       resolve. A real divergence is not the only way the two sides can
       still disagree, though: the SAME shared, identity-keyed body can
       be legitimately rewritten by a DIFFERENT binding's own mirror
       write after this write ran — a sibling top-level local, a
       `DotVarExp` alias, or a callee's own parameter mirror in another
       activation, since `ObjectTable` is one instance for the whole
       execution. `impl.d`'s `classMirrorGenerations` closes that gap: a
       per-variable snapshot of `ObjectTable.generation` for every
       identity the write composed, taken right after it ran.
       `assertClassBodyValue` checks each identity's CURRENT generation
       against its recorded snapshot before touching its bytes, and
       skips the comparison — never recursing into that identity's own
       fields either — the moment it is stale, rather than asserting on
       bytes the write never actually vouched for. The verify path
       itself performs no writes of its own: it reads `ObjectTable`
       state with `has`/`opIndex`, never `storageFor` (which allocates a
       fresh block on a miss) — a verify step must never mutate the
       shared table it is checking.
     - Residual, NOT fixed by this slice (out of scope — authority stays boxed):
       the `classObjectCells`/`classIdentityAliasedByAnotherBinding` declines
       above only paper over the symptom for the mirror — an internal assert
       must never be the reason a program that used to run instead crashes — not
       the underlying boxed-authority staleness itself. A write through one
       alias of a shared object graph does not propagate into every other
       alias's own cached copy in `locals[]`, a real, pre-existing gap: mutating
       a linked-list node through a SEPARATE local aliasing an interior node, or
       a deep field-chain write through one top-level alias, then reading it
       back through a DIFFERENT binding, reads stale.
     - Union composition: a union composes as what it actually is — overlapping
       bytes at DMD's own offsets, with no union-specific arithmetic anywhere.
       `readValue`/`writeValue` recurse a union's `layout.structFields` exactly
       as they do a plain struct's (`place_value.structValueAt`, shared by both
       arms) — every member's `Place.field` already lands at the union's own
       (overlapping) offset, so reading every member independently is
       reinterpretation with no reconciliation step, matching the boxed walker's
       own struct-shaped union `Value` (`impl.d`'s `withUnionFieldWrite`).
       Writing a whole union `Value` (`place_value.writeUnionValue`) writes only
       the WIDEST declared member's bytes, covering the union's full live extent
       in one shot — exact given the incoming value's members already agree
       bit-for-bit, true of every union `Value` this codebase ever constructs,
       but not a claim about a hypothetically inconsistent one.
     - `isPlaceComposable` recurses a union's own fields exactly like a struct's
       (`allFieldsComposable`, shared between the two arms), so a union with a
       slice/class/pointer/`real` member refuses the whole union, matching
       `isClassBodyComposable`'s one-bad-field-refuses-the-body rule. A
       composable union local is therefore eligible for the verified frame
       mirror above; the mirror stays symmetric with no extra gating because
       `mirrorToFrame` and `assertFrameMirror` both call the identical
       deterministic `writeValue` on the identical boxed value, so the two sides
       can never disagree with each other — independently of whether that boxed
       value itself agrees with `SystemLinker` (the union default-value gap the
       Unions contract below still documents).
   - The authority switch: native storage becomes the sole authority
     for all bindings. Merge gate: no new red rows (decision 17).
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
