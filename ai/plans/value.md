# Value Representation

## Status

This plan records the removal of the shared `quickbite.lang.Value` and the
tree-walking interpreter's move to native-layout storage. Current capabilities:

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
- Boxed locals remain the general authority. Unsupported cases include deeper
  aggregate paths, unpromoted element/member shapes, incomplete `ref` argument
  identities, unequal-width array casts, and the residual gaps in item 7.

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
   storage of an addressable guest value. The earlier claim that a boxed
   tagged union is "the natural form" for a tree walker was downgraded:
   it argues against *reimplementing* layout, not against *reusing* it.
   It is **recursive aggregate boxing** (`Struct = Value[] fields`,
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
   bridge's.

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

11. "Boxed scalars stay" means **immediate scalar expression results**,
    not boxed-only scalar lvalue storage. Forcing every transient
    arithmetic result through a native block would add loads, stores, and
    bookkeeping. Addressable storage has a different contract: once
    `&local` or another operation makes a scalar location observable, it
    must have one stable native cell that is authoritative for direct
    reads and writes, pointer dereferences, byte reinterpretation,
    `memcpy`, and FFI. Never create a boxed snapshot and reconcile it
    through writeback. Whether every scalar local starts in a native slot
    or is promoted when its address becomes observable is an empirical
    latency choice: prefer the simpler eager-slot design unless a
    measurement justifies lazy promotion; if promotion is used, every
    subsequent direct or indirect access must use the promoted cell. A
    scalar rvalue passed to libffi may still need one fixed-width leaf
    copy into an ABI cell; that is not recursive aggregate marshalling.

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
    change is the interpreter-wide representation (item 7) — not a
    bolt-on marshaller (item 6's measured result), and not a VM rewrite
    (`bytecode.md` is unaffected and remains the native-layout
    *execution* track).

## Contracts

Invariants a change can silently break. Each was earned by a real bug or
a checked fact; do not relearn them.

### Layout authority

- `layout.d` is the only place the interpreter package reads DMD layout:
  `typeByteSize`, `fieldByteOffset`, `structFields`, `classFields`,
  `staticArrayLength`. Every number is DMD's own, verbatim; the
  interpreter must not grow a second set of D layout rules.
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
- `native_scalar` deliberately excludes `real` (`Tfloat80`): its 80-bit
  padded layout is host- and ABI-specific, not a portable native scalar.
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

### Cell coherence (guest-visible native cells)

- Cell and boxed-local state belongs to one execution, not to the reusable
  `Interpreter` adapter. Running a module parsed before an earlier module's
  execution must start from fresh value state; frontend AST age is not a
  reason to retain or replay a prior walker's cells.
- Every cell family must honour three obligations — dup on frame fork,
  merge on return, drop on rebind — and a missed one is invisible until
  it corrupts. (See item 7's consolidation debt before adding a family.)
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

### Unions

- DMD reports a union as a `TypeStruct` whose `sym` is a
  `UnionDeclaration`; every top-level member's offset is 0, and an
  anonymous union's members are flattened into the parent's fields at
  overlapping offsets. The offsets themselves are the aliasing truth;
  DMD's `overlapped` flag is a derived fact about them, not a second
  source of truth to consume.
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
- D zero-initializes a union from its FIRST declared member's default
  value: the whole block carries the first member's bits, and an
  untouched sibling reads those bits reinterpreted. Scalar, plain-struct,
  scalar-leaf-static-array, and scalar-field nested-union siblings are
  reconstructed from scalar, plain-struct, scalar-leaf-static-array, and
  scalar-field nested-union first members, plus static arrays of scalar-field
  plain structs at any depth as first members and one level as siblings,
  through one transient native block. Computing each member's default
  independently diverges from compiled D.
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

The contract flip (decision 1) and frontend-answered `:t` (decision 5)
are done; what is still pending, in order:

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
   callables, and metadata that execution actually requires.

Track B (FFI seam) work, parallel to the bridge track in `ffi.md` §6:

4. Done: the seam is carved. The boxed `Value <-> ABI bytes` marshalling
   lives in `source/quickbite/backends/interpreter/ffi_marshal.d` as the
   interpreter's `materialize`/`reify` implementation behind the `ffi.md`
   §5 `NativeMarshaller` interface; the backend-neutral bridge core lives
   under `source/quickbite/ffi/` and never names `Value`. Future Track B
   work stays behind the same seam.

5. Own the `ffi.md` §34.3 `B*` rungs (boxed-slice/struct/nested/writeback
   marshalling) as the interpreter's `materialize`/`reify`, keeping FFI
   working so real dub tests can run.

6. Experiment (do not pre-commit): hold FFI-crossing aggregates in native
   layout behind the handle, measure latency against the boxed
   implementation, and keep whichever wins.

   Measured result: a *bolt-on* native-layout `NativeMarshaller` is the
   wrong unit of change — keep the boxed marshaller until the
   representation itself changes. Evidence, preserved so this is not
   re-litigated:
   - The benchmark suite never crosses the FFI seam: `bin/bench`'s
     fixtures have no native dependency, so a marshaller swap is
     invisible to it; only the `sys/` dependency-image suite exercises
     the seam.
   - The representation gap is real but lives off the seam. A
     construct-plus-read-back micro-benchmark showed a boxed 4-long
     struct at ~26x a native byte layout, and a boxed 16-long slice at
     ~27x — boxing's GC alloc + `SumType` tag dispatch.
   - A native-layout marshaller cannot capture that gap while the
     interpreter stays boxed: its inputs and outputs are boxed `Value`s,
     so it boxes on the way in and out regardless and only adds blob
     bookkeeping. The ~26x is realizable only when aggregates are never
     boxed — the interpreter-wide representation, where the seam
     collapses to identity.
   - The decider is the correctness ceiling, not latency; it lands with
     the representation change, not a marshaller swap.

7. Run the native-layout experiment in the tree walker: immediate scalar
   expression results may stay boxed, addressable scalar locations use
   stable native cells, aggregates/arrays live in native ABI layout
   behind a handle reusing DMD's own field offsets, and pointers become
   real addresses into that storage. This is the interpreter-wide
   representation change item 6's measured result deferred to. Success
   criteria, in order:

   - the `interpreter.md` §9.10 shims are deleted one by one, each
     deletion proven by its ratchet fixtures staying green through the
     real path (`emplaceRef` executes its actual body; `memcpy` and the
     `gc_*` hooks route through ordinary FFI);
   - the parked representation-ceiling gap fixtures (§9.10 "gap
     fixtures") re-earn `Interpreter` in their matrices;
   - the cerealed frontier resumes on the new representation, and the
     latency A/B (item 6's original question) is finally measured on real
     suites once they run.

   **Consolidation debt** (pay this down before widening the matrix
   further). Shape-specific promotion, lookup, read, write, writeback, merge,
   and drop families duplicate storage-identity mechanics. That is a
   correctness risk because each family must independently fork, merge, and
   detach cells. Replace the families with composed views and common lifecycle
   dispatch rather than extending them.
   - Do NOT add an eleventh family. Direct and one-level-nested struct/class
     field allocation identity and scalar-field reverse lookup use the common
     `(root variable, field PATH)` key. Migrate the remaining reverse
     lookup/read/write/writeback families onto that key and composed native
     views. Paths such as `a[i].inner.x` must be data, not bespoke map
     families, so promote/read/write/merge/writeback/drop each ultimately
     exist once.
   - Per-frame cell state is forked in one place
     (`Walker.forkPerFrameCellsInto`), and field-pointer registry families
     merge through the common return-side cell dispatcher
     (`Walker.mergePerFrameCellsFrom`). Fresh-binding drops shared by locals
     and parameters dispatch through `Walker.dropNonClassCells`; declarations
     dispatch all families through `Walker.dropDeclarationCells`, preserving
     class cells only for parameter aliasing.
   **Design sketch** (the frame for all of this work). A *native block*
   is a stable byte range laid out with DMD's own offsets, stride, and
   alignment; a *handle* is the interpreter-owned metadata for one block
   — `Type*`, byte length, ownership, and scan policy. Interior addresses
   are views over a block plus an offset; a raw `void*` is produced only
   at the last step before FFI or an intrinsic, and is never the
   ownership token.

   - **Storage shape.** Integral, floating, enum, null, and pointer
     rvalues keep expression evaluation direct through immediate scalar
     arms. This does not make a box the authority for an addressable
     scalar local: use either an eager native local slot or measured lazy
     promotion to one (decision 11). Recursive aggregate boxes collapse
     to one aggregate-handle arm. A static array is one inline block; a
     dynamic array is a real D slice header (`ptr`, `length`) over a
     separately tracked element block; a struct is one block laid out
     with DMD field offsets. Class references need native object
     identity in the end state.
   - **Address stability.** Every address reachable through `&local`,
     `array.ptr`, slice construction, pointer arithmetic, `memcpy`, or
     FFI points into a native block, never into a boxed snapshot. Direct
     access to an addressable scalar local reads and writes that same
     cell. Blocks must not move while an interpreter pointer can reach
     them; when array growth reallocates, the owning slice header is
     updated and stale addresses go stale exactly as compiled D loses
     append capacity — no boxed value is ever copied back as the
     authority.
   - **GC roots.** An owned block is a GC allocation whose scan attribute
     is chosen once, at allocation, from whether the type carries
     pointers (see Contracts). `NativeBlock` is a value struct copied
     freely — copies share one address but have no single owner — so
     there is no registration token and no destruction hook to get wrong.
     Precise pointer-bearing subranges are a later optimization, not a
     prerequisite. `GC.addRange` is reserved for memory the GC does not
     own; handles that borrow FFI or host memory register nothing and
     only keep a Quickbite-owned source alive for the borrow's duration.
   - **Ownership and writeback.** Whether a block is owned or borrowed,
     and whether writes through it reach an external owner, is explicit
     metadata on the handle. It is never inferred by diffing a pre-call
     boxed aggregate against a post-call one. Class-reference identity is
     not by-value writeback: one object body is shared by every reference
     to it. By-value class parameters share the caller's class cell when
     their argument is a plain variable; rebinding the parameter remains
     local to the callee and must never write a replacement reference
     back to the caller.
   **Current frontier** — what remains, given the Status section's
   covered shapes:

   - Authoritative storage: `locals[VarDeclaration]` is still
     `Value`-keyed. Cells exist only for the aliased/address-taken shapes
     in Status; the end state is native storage as the authority, with
     the boxed mirror gone rather than synchronized.
   - Reinterpreting promoted cells remains unsupported for pointers, `real`,
     widening loads, and aggregates that do not fit. Non-fitting writes must
     fail rather than corrupt adjacent storage. Postblit execution remains an
     interpreter expression-execution gap.
   - Structural gaps needing a design, not surgery: per-activation cell
     keying (all cell maps key on `VarDeclaration`, so recursive
     activations of the same function share one cell — a real
     divergence); nested-struct and static-array class-field pointers still
     follow the variable slot after a reference rebind rather than retaining
     object identity; and `ref`-parameter address
     identity outside repeated plain-variable `ref` aggregate arguments
     (structs, classes, and static arrays) and direct scalar aggregate fields
     reached repeatedly or through a struct source/ref alias, which share
     mutation authority and direct parameter addresses.
     Non-plain-variable aggregate arguments
     remain boxed copies plus end-of-call writeback.
   - Field-path generalization: the common root-plus-path key handles
     allocation identity for direct and one-level-nested struct/class fields
     and reverse lookup for direct and one-level-nested scalar struct/class
     fields. The other shape-specific reverse lookup/
     read/write/writeback families still need migration. Nesting deeper than
     one level has no promotion, write-through, or pointer-identity support.
     Extend the common mechanism, never add another family.
   - Widening not yet done: class-typed fields and dynamic-array fields whose
     element is neither a native scalar nor a supported non-union struct have
     no cell support on either the read or write side; same-width
     native-scalar dynamic-array casts share backing storage through bindings,
     direct slice arguments, and function returns, while unequal-width casts
     still need byte-stream length and element regrouping;
     `out`-parameter initialization only recognizes the zero-memset
     `BlitExp`-with-integer shape DMD synthesizes for zero-init structs —
     the non-zero-init shapes (a real construct/call) are untried; and
     the union residuals in Contracts (aggregate members beyond plain structs,
     promotion for unions with non-scalar members, and default-init first
     members or siblings outside native scalars, recursively scalar-field
     structs/unions, scalar-leaf static arrays, and static arrays of scalar-
     field plain structs (any depth as first members, one level as siblings),
     including class and dynamic array members).
   - Native-pointer arithmetic: integer offsetting and pointer difference walk
     raw native buffers (including `GC.malloc` storage). Array pointers into a
     promoted cell cross ordinary body-less FFI as native addresses; native
     slice reads, casts, and slices retain that address. Interior-slice
     `assumeSafeAppend` still loses the capacity of the zero-length descriptor
     returned by `reserve` while rebinding it into the caller. Ordering and
     mixed native/boxed-pointer operations remain modelled only for the boxed
     carrier.
   - Open questions from the design sketch: lifetime contracts for blocks
     borrowed from arbitrary C owners; what a guest pointer into a grown
     array should observe, and whether that deserves a diagnostic rather
     than compiled D's silent staleness.
   - Latency is measured only once the correctness gates are green and a
     real suite actually reaches native storage; the benchmark suite
     never crossed the old marshaller seam. Until then, native layout is
     justified by the correctness ceiling, not a benchmark.

## Out of scope

`quickbite.executor.Value` (the legacy executor type) is unaffected, as
before; it dies with the legacy executors.

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
- DMD-derived layout facts stay the source of truth, cached on the
  handle; the interpreter must not grow a second set of D layout rules
  (see Contracts).
