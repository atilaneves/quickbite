# Value Representation

## Status

This plan owns the tree-walking Interpreter's value representation and
native-call adapter, and the retirement of the shared `quickbite.lang.Value`.
The goal is the prime directive plus simplicity: minimal incremental
edit-to-test-verdict latency, with no machinery that does not pay for itself.
A universal value carrier is condemned by its costs — per-expression boxing
and allocation, tag dispatch between the static type and the bytes, value
conversion at the FFI boundary — not by name. Decisions 15-19 commit the end
state: native-layout storage as the only value authority, destination-passing
evaluation (decision 7), no result materialization on the unittest path, and
an FFI boundary that sees only typed addresses.

The precedent survey and primary-source evidence for these decisions live in
`ai/research/interpreter.md`. This plan is the normative contract when the
survey describes an alternative or hypothesis rather than a settled choice.

`ExpressionResult` (a 25-alternative `SumType`) is still the Interpreter's
universal expression currency: every recursive expression evaluation returns
it, an assignment round-trips its right-hand side through the carrier before
the place write, and the native-call adapter's request/result structs carry
it in both directions. Deleting `expression_result.d` is the Interpreter-side completion
marker (items 8-10). Deleting the shared `Value` is a separate marker gated
by the IR and Bytecode formatter migrations; neither marker waits for the
other. Production Interpreter optimisation waits for the carrier deletion;
broader language expansion may proceed independently. The Bytecode refactor
and its address-only FFI migration proceed in a file-disjoint parallel lane.
Current capabilities:

- `EvalResult` carries a display `string` or `Diagnostic`, and `:t` is
  frontend-answered. CTFE and Interpreter execute every semantically valid
  expression display through the prelude formatter and execute unittests
  without rendering. The Interpreter consumes the guest-produced string
  directly and has no host-side display model; the IR and Bytecode paths still
  use interim `Value` display scaffolding.
- `NativeBlock`/`NativeArray`/`NativeStruct` compose structs, static arrays,
  slices, and their elements using DMD layout. They own real GC storage,
  growth, slice headers, and the interpreter side of the FFI seam.
- Native frame, module, class-body, and borrowed reference places provide
  authoritative reads, writes, whole-value reconstruction, and addresses.
  Views compose by DMD offsets and strides; direct, nested, indexed, sliced,
  `ref`, and cross-frame access share storage rather than copies.
- Class identity is the host body address. VM-created objects retain a native
  aggregate owner; borrowed host `Throwable`s retain the host address and keep
  interpreter-visible native-layout metadata keyed by that same address.
  Union storage observes overlapping DMD offsets and first-member default
  initialization for the supported recursively scalar-field shapes.
- Rebinding stores a new value or address in the binding place; same-storage
  mutation updates the existing bytes. Casts and slices retain their native
  backing and compose from its address across bindings and calls.
- Raw addresses produced by an expression retain their owning blocks only for
  that recursive expression walk. Once stored, conservative scanning of the
  native destination keeps the allocation live; no allocation-identity root
  registry crosses calls or activations.
- `ExpressionResult`'s sole aggregate arm owns or borrows typed native
  DMD-layout storage, and its sole data-pointer arm is a host address. It has
  no structural array, struct, associative-array, entry, class-object,
  undisplayable, formatting, or string-display-metadata arms. Aggregate
  construction always has a DMD type, and aggregate place writes copy the
  complete typed byte span. `ExpressionResult` is never local, alias, or
  cross-frame storage authority. Diagnostics and the temporary
  `std.conv.text` interceptor render from the expression's DMD type and typed
  scalar accessors at their consumer sites.
- The Interpreter native-call adapter has one preparation path and one
  execution path calling the address-only `quickbite.ffi.ffi` bridge.
  Preparation reuses an operand's existing native address when one matches;
  an address-less operand is materialized through the carrier, and every
  native result is still read back into it — both remaining carrier
  crossings are queue work (item 10). Callback lifetime and re-entry and
  native exception translation stay adapter-owned because they are
  Interpreter mechanics, not value conversion.

## Audit findings (June 2026)

Retained only as the justification for decision 1: nothing structural in
production consumes `quickbite.lang.Value`. The REPL consumes only display
strings and never feeds a `Value` into later evaluation (session state is
replayed from source); benchmarks compare strings; the bytecode and IR
cores exclude a universal runtime value type by design
(`ai/plans/bytecode.md` "No universal runtime value type";
`ai/plans/ir.md`). The struct's remaining customers are its own unit tests
and the IR and Bytecode backends' formatting scaffolding. The Interpreter no
longer imports or aliases it.

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
   with `static if` introspection. For a formatter-capable backend, the frontend
   synthesizes every semantically valid expression cell as
   `__quickbiteFormat(expr)`; semantic analysis — shared by all backends —
   instantiates the template against the real static type, so
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
   applies to every semantically valid expression consumed by a backend that
   can execute it. A cell that already fails semantic analysis retains its
   unwrapped source solely to preserve the primary diagnostic; no value path
   can execute it.

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

7. **Destination-passing evaluation replaces the expression-result
   carrier** (August 2026; supersedes this decision's earlier "a private
   carrier may remain" form). Four language situations are distinct
   evaluator operations, committed as semantic distinctions — the names,
   signatures, and construction-state encoding are implementation, owned by
   item 8:

   - no-result execution: statements and unittest bodies produce nothing;
   - place evaluation: an lvalue yields an address plus its static type;
   - construction: an rvalue is constructed into a fresh caller-provided
     typed destination whose construction state the evaluator tracks — a
     function call receives its caller's destination, a return statement
     writes there, and a void call has none;
   - assignment: a live place receives a value through D's defined
     assign/move/postblit/destruction semantics; the live lvalue is never
     handed out as arbitrary result storage for the right-hand side, since
     that could expose a partially constructed value through aliases.
     Direct construction into final storage is allowed only where D
     semantics permit it.

   Scalar-only work uses statically typed host locals inside type-specific
   helpers selected from the statically typed AST — ordinary implementation
   data, not a guest-value currency; the DMD frontend stamps a static
   `Type` on every node, so no runtime tag is needed for type safety. A
   universal carrier — one host type through which statically unrelated
   guest values pass — may not return under any name; that is how the
   boxed era grew.

8. This plan owns the Interpreter's value representation and native-call
   adapter. `quickbite.ffi.ffi` is designed independently for native-layout
   backends and never sees `ExpressionResult`: the Interpreter hands it typed
   argument and result addresses without compatibility methods or a legacy
   fallback.

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

11. **Scalar rvalues are host locals, not boxes** (August 2026; supersedes
    "boxed scalars stay"). A scalar intermediate lives in a statically
    typed host local until it is stored, passed, or needs an address; then
    it is written into its typed destination or a typed native temporary
    (decision 19). Every lvalue, scalar included, is an address from the
    moment it is bound (decision 15); there is no lazy promotion and no
    snapshot reconciliation — promotion machinery is a second world with a
    trigger-detection seam, and that seam is where the boxed era's bug
    population lived. The FFI bridge receives addresses; it does not
    request or perform a value conversion.

12. Execution and display are separate consumers of expression evaluation.
    Top-level unittest execution needs only success or a diagnostic and
    must not render or materialize the walker's final result;
    expression-display entry points synthesize `__quickbiteFormat(expr)`
    and return that guest-produced string through `EvalResult`. The public
    `Evaluator` contract exposes nothing else: a package-private
    Interpreter-test helper may take an explicit DMD type and a native
    destination, layered over decision 7's construction operation, but it
    never becomes the public contract. Existing `eval` tests are
    classified by behaviour: D-language behaviour moves to runner/oracle
    fixtures; a test whose only contract is returning a boxed host value
    is deleted with the carrier.

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
    handles are separate non-data categories. Transient rvalues are host
    locals or fresh typed destinations (decisions 7/11); nothing boxed
    acts as storage authority.

    An owning block used only to produce a transient raw pointer remains
    reachable through a lexically scoped owner until that pointer is stored in
    a conservatively scanned frame, module, object, or aggregate block. Do not
    retain an execution-wide address-to-block map as substitute storage
    authority. Such a map is an allocation-identity registry and violates the
    end-state criterion below even when introduced only to keep the host GC
    from collecting an otherwise unreachable block.

    A symbolic `TypeInfo` for an interpreted-only guest type, an interpreted
    delegate, or an interpreted function pointer has no resident native
    callable/object address, so its null ABI slot is accompanied by
    interpreter-owned metadata keyed by that slot's real address. Typed value
    copies preserve every metadata entry in the copied byte range without
    consuming the source. A write clears every entry whose slot overlaps the
    written bytes before registering the new value; this applies equally to
    union members and aggregates containing several metadata kinds.

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

    End-state criteria are cost-shaped, not identity-shaped:

    - unittest execution materializes no expression results; the
      statement path produces nothing to discard;
    - no per-expression boxing or heap allocation on execution paths:
      scalars are statically typed host locals, aggregates never leave
      native-layout storage;
    - nothing crosses the FFI boundary but typed addresses — no
      conversion, reconstruction, or writeback in either direction;
    - one storage authority per binding and one data-pointer
      representation, the host address; no data-pointer kind predicate,
      counter identity namespace, or identity-to-body allocation table in
      the execution path. Address-keyed dynamic-type, ownership, and
      exception metadata do not replace the address as guest identity.

    A 25-alternative carrier cannot satisfy these criteria, so the
    deletions are their verification markers, not goals in themselves:
    `expression_result.d` deleted is the Interpreter-side marker (items
    8-10), the shared `quickbite.lang.Value` deleted (items 2-3) the
    shared one, and neither waits for the other. Any reintroduced
    universal carrier or wrapper around addresses is the regression —
    that is how the boxed era grew: never "a second pointer type", always
    "a carrier for a shape the current one can't express".

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
    today the address-only bridge stays owned by `quickbite.ffi.ffi`, backend
    adapters own their callback and exception mechanics, and a memory
    container knows nothing about libffi. The walker uses
    `native_block.d`/`native_array.d`/
    `native_struct.d`/`layout.d` where they already live, inside the
    interpreter package.

17. **Migration rule: preserve one working storage world.** Representation
    changes land as coherent, oracle-backed slices. A slice may add native
    composition before it selects that storage as authority, but it may not
    leave a cell, alias table, or return-time reconciliation path competing
    with an authoritative native place. Each activation owns one fresh frame
    block, including an activation whose layout has no slots; captures and
    calls retain typed addresses into the owning frame. The merge gate is no
    new red rows relative to the documented baseline. The expression-currency
    migration (items 8-10) only ever removes carrier arms; a slice may not
    add one, and a temporary carrier fallback may not cross the FFI boundary
    or become storage authority.

18. **FFI end state: no marshalling.** This is a structural guarantee:
    an aggregate argument's bytes already sit at a real address and a native
    return is written straight into typed result storage. A small backend
    adapter hands argument and result addresses to `quickbite.ffi.ffi`, which
    owns ABI descriptors, CIF construction, and calls.
    Adapter-owned callback lifetime/re-entry and native exception translation
    remain only where demanded by supported Interpreter behavior. That is call
    plumbing, not marshalling debt; the irreducible remainder (`ffi_call`
    dispatch) only a JIT removes.

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

    The Interpreter adapter has one typed-address preparation path and one
    execution path. Preparation reuses an operand's existing native address;
    an address-less scalar rvalue is written into typed scratch storage
    first. At the endpoint a native result is written into caller-provided
    typed result storage and consumed through it — reading results back
    into an expression carrier is queue work (item 10), not endpoint. No
    `ExpressionResult` crosses the bridge itself, and no buffer-based
    aggregate reconstruction or post-call writeback path exists. The libffi
    descriptor, argument-address array, scalar scratch, and symbol
    resolution remain bridge plumbing; callback lifetime/re-entry and
    native exception translation remain Interpreter-adapter plumbing.

19. **Addressable expression temporaries have activation-scoped storage.**
    Item 8 must choose per-activation typed frame offsets vs segmented aligned
    scratch; the frame-layout cache lasts one Interpreter root execution, not
    across roots, so neither gets reuse credit. Both must satisfy the
    expression-temporary destruction contract (below), GC visibility while
    live, and stable addresses under recursion/callback re-entry; storage
    belongs to an activation, not an AST node; ties go to the smaller mechanism.

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
- `place_value.valueMatchesPlace` is the scalar compatibility gate for whether
  a non-aggregate transient execution value can enter the place writer. Typed
  native aggregates bypass it and copy their complete byte span.
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
- A raw address whose owner has not yet reached native storage has an owner in
  the current recursive expression scope. Callees share that lexical scope so
  returned addresses remain live; the outer expression releases it after the
  address reaches a conservatively scanned frame, module, object, aggregate,
  or native-call scratch block. No address-to-allocation registry participates.
- Native class references carry only their body address. VM-owned allocations
  retain their native aggregate in an ownership table. A borrowed native
  exception keeps a separate native-layout metadata aggregate keyed by its
  real host object address; its dynamic type is keyed by that address too.
  Ordinary fields are hydrated from the host body, while runtime-owned `msg`
  and chain state come from the captured exception record. The metadata never
  crosses a native boundary or replaces the host address as identity.
- A field slice borrows bytes composed from its receiver place; an aggregate
  expression snapshot is never the backing storage for an lvalue-derived view.
- `ExpressionResult.NativeAggregate` owns or borrows DMD-layout bytes for a
  transient aggregate result. Once stored, the destination place is
  authoritative.
- Constructing a value into storage an activation has already used clears that
  whole byte span first. Padding and the bytes of an unwritten union sibling
  are part of the value: D's own struct hashing and by-value ABI copies read
  them, and freshly allocated storage would have read zero there.
- `ExpressionResult.Pointer` contains only a host address. Pointer arithmetic
  and subtraction, equality, and relational comparison operate on that
  address; no
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

### Expression temporary destruction

- A declared variable's `edtor` arms once its `DeclarationExp` initializer
  succeeds; `nodtor` marks when DMD destroys it via `DtorExpStatement` instead.
- A constructor-call receiver's declaration is only a placeholder: DMD lowers
  it to `((S __t = <placeholder>;) , __t).__ctor(args)`, a shape an already-
  complete value also produces, so only the call site (which knows its callee
  is a constructor) can tell them apart. It pops the premature arming and
  requeues only on constructor success, at both receiver-resolution paths; a
  throwing constructor arms nothing, matching compiled D.
- Destructors run in reverse construction order at every full-expression
  boundary and on unwind; the evaluated right-hand side of `&&`/`||` is the only
  expression-internal boundary (`?:` gets none).
- The queue is per-walker: a call is a full-expression boundary for the callee.

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
7. `void` results display nothing (REPL suppression). Functions, delegates,
   pointers, behaviour-bearing template results, and other values with no D
   expression form cannot round-trip; there is no contract to honour, so
   render whatever is most useful to the reader. Non-null callables render
   `<undisplayable>` and null callables render `null`. A template result whose
   behaviour cannot be reconstructed from a D expression renders its template
   struct name and declared state, such as `MapResult([1, 2, 3])`; this is an
   inspection form, not a constructor expression. Pointer display is otherwise
   unspecified until pointers become a displayable feature — spec it then.

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

The native authority switch is a standing contract, not pending work. The
remaining value-track work is the destination-passing migration and carrier
deletion (items 8-10), the IR and Bytecode formatter migration followed by
shared-`Value` deletion (items 2-3), and the language-surface tasks below.
Item numbers remain stable for existing cross-references. Production
Interpreter optimisation begins only after item 10 deletes the carrier;
timings follow `overview.md`'s measurement contract.

### Item 8 — Destination-passing construction

Decision 7's no-result operation, place evaluation, and construction into an
already-existing destination (e.g. a declaration initialising its own
storage) are landed; a no-result arm is worth writing only where a whole
sub-walk's discarded value was the point, so the carrier's per-expression
materialization retires with construction, not more arms. Remaining: decision
19's addressable temporaries -- measure fixed frame offsets against segmented
scratch on the gate corpus (`overview.md`'s measurement contract); this slice
then owns the storage choice and construction-state encoding.

### Item 9 — Assignment through construction

A live lvalue's assignment still round-trips its right-hand side through the
carrier before the place write (`x = f()`). The live target may not itself be
that right-hand side's destination: D evaluates the right-hand side first, so
an alias could observe a partially constructed value. This therefore waits on
item 8's addressable temporaries, then applies D-defined
assign/move/postblit/destruction semantics per decision 7.

### Item 10 — Carrier deletion

The carrier's footprint is two unequal halves that retire differently;
re-measure with `grep -c ExpressionResult
source/quickbite/backends/interpreter/*.d`.

Aggregate positions convert family by family onto the construction and place
operations, ordered by what the gate corpus actually hits: calls with
caller-provided destinations, indexing, casts, builtins, aggregate
reconstruction (`aggregate_value.d`), the native-call request/result carrier
fields, and retirement of the `std.conv.text` interceptor. Slice invariants
per decision 17.

Scalar positions cannot retire family by family: most of the carrier's arms
are scalar, and every scalar flows through the walk's one universal return.
They retire together, in one flip of the recursive walk onto decision 11's
statically typed host locals — type-specific evaluation helpers selected from
the statically typed AST. Building those helpers is its own work item, not a
by-product of any family conversion.

The flip and the family conversions are otherwise independent, but both
bottom out in one shared bottleneck: the call/return channel
(`Walker._returnValue`), which is carrier-typed — a scalar helper recursing
into an interpreted call reads it, and every aggregate-returning call writes
it. Converting that channel to decision 7's caller-provided destinations is
the first item-10 step, and it needs item 8's temporaries, because a call in
an rvalue position (an argument, an operand) has no destination without one.

Deleting `expression_result.d` ends the item. Includes an inventory of real
corpus crossings that need an interpreted callable or `TypeInfo` to escape to
native code — decision 15's refusal stance holds, and no trampoline or proxy
is designed, until a real crossing exists.

### Item 4 — Workingness track

Keep the Interpreter language surface advancing without regressing the
Cerealed/dub gate: one language-surface fix plus its oracle-backed fixture
per small, short-lived PR, native storage and calls staying the ordinary
execution path -- no marshalling, cell families, alias maps, or name-based
shims -- per `interpreter.md` §8 triage.

A destructor throwing at the outermost full-expression boundary drops the
remaining armed destructors; compiled D chains it and still runs every one.

Pointer-slice formation past an allocation remains unchecked when its result
is not dereferenced, matching compiled D's contract; the allocated-block
diagnostic is CTFE-only, so the Interpreter belongs in the
compiled-behaviour matrix -- do not restore a boxed-storage bounds
diagnostic for this operation.

A whole-aggregate copy whose source is a pointer dereference stays on the
value path, so a null pointer is one failed unittest rather than a fault:
composing and reading that address would fault like compiled D, but a fault
ends the run before any assertion can observe it (`lang/diagnostics.d`'s
null-dereference block is pinnable; `Because.unassertable` covers the faulting
ones). These shapes appear nowhere in the corpus -- do not trade report for
fault.

Dynamic-array truthiness is the native slice header's pointer, not its length:
a zero-length interior slice with a non-null pointer is true, while a default
null slice is false.

An indexed array-of-arrays element is its own addressed slice header. Slice
assignment through that element writes the row's native elements in place;
rebuilding the enclosing array would reintroduce boxed storage authority.

A doubly-indexed receiver's evaluation-order contract only covers a static-
array row (`m[outer][inner]` where `m[outer]` is a fixed-size array, e.g.
`P[2][3]`). A dynamic-array row (e.g. `int[][3] m`) is a distinct,
unimplemented case, not just the pre-existing fallback order: confirmed
against `SystemLinker` (`bin/qb` probe, both a struct method-call receiver and
a plain scalar read), compiled D calls the first bracket's index expression
*twice* while still calling the second bracket's once, first. Neither this
fix's fast path nor the old fallback reproduces that.

The temporary `std.conv.text` character-array path reads the authoritative
native slice header, including its retained backing address, not a transient
aggregate handle -- slice execution, not a formatter-specific storage shim.
Retiring the interceptor is item 10 queue work.

An associative-array `ref` parameter reads the caller's typed handle place,
like other native-layout reference values; autovivifying a null handle
writes it through the referenced binding before inserting, so the caller
retains both the allocation and later mutations.

A method call chained off an assign/construct/blit whose target is itself a
side-effecting `PtrExp`/`IndexExp` (`(*next() = value).bump()`) has no
address to rebind `this` to without re-running that side effect a second
time: `assignmentTarget`'s peel only trusts a `VarExp` or a `this`-rooted
`DotVarExp` chain as safe to re-address, so `runMemberFunction` refuses the
`PtrExp`/`IndexExp` shape outright (fixture:
`struct.methodCallThroughAssignmentChainedPtrExpReceiverEvaluatesOnce`).
Lifting the refusal needs the assignment's own write to hand back the
address it used, the same way the receiver-level
`precomputedReceiverPointerAddress` precompute does for a bare
`PtrExp`/`IndexExp` *receiver* -- not yet threaded through for a target
recovered by peeling.

### Druntime-first backlog (AGENTS.md rule)

- Array append/growth: execute druntime's real append/allocation
  templates; `native_array.d`'s hand-rolled grow/copy paths retire with
  the switch.
- Demand-driven, when a corpus fixture forces the area: exception
  chaining through `Throwable`'s real code instead of direct
  `_nextInChainPtr` writes; real `TypeInfo` objects where `TypeName`
  display tags fall short.

### Item 2 — Unittest/expression split

All four tree-node backends execute unittest bodies directly and return only
success/diagnostic; their unittest paths neither reify nor render a result.
The Interpreter's REPL and direct-expression convenience API execute the
prelude formatter and consume its guest-produced string without a host-side
display model. IR and Bytecode still need their backend-owned formatter
execution slices before their expression paths can complete the split. As each
gains the formatter, delete its private reify -> `Value` -> `toString`
scaffolding (decision 4). Do not retain `Value` or render a dummy `void` result
just to reuse the evaluator path.

### Item 3 — Delete the shared value

Delete the shared `quickbite.lang.Value` and its unit tests once per-backend
formatter migrations leave no consumers. This is the shared-side marker of
decision 15; IR and Bytecode formatter execution are its remaining
prerequisites, and the Interpreter-side carrier deletion (items 8-10)
proceeds independently. The Interpreter no longer consumes or aliases the
shared type. `FrameBlock`, `ModuleTable`, and typed `Place` composition are
the binding authority. Address-keyed callable and symbolic-reference
metadata may accompany native byte ranges, but may not become a second
binding store. A class expression is only a native aggregate owner or its
object-body address.

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
