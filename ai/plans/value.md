# Value Representation

## Status

Decision 2026-06-12: this plan now records the *removal* of
`quickbite.lang.Value`, reversing the earlier direction (expanding it to
losslessly store any D runtime value — see git history for that version
of this file). The trigger: the bytecode rewrite removed `Value` from its
VM, prompting an audit of what still needs the struct. Answer: nothing
structural in production code. What can be deleted, should.

Decision 2026-06-13: the display principle is reversed from "injective per
static type" to "round-trips as valid D". REPL output must be parseable D
that evaluates back to the value; it is no longer the channel for telling
the user a value's type. Type queries move to `typeof`/`it.typeof`
(`ai/plans/repl.md`). This drops the invented `: type` annotations the
2026-06-12 spec introduced; see the rewritten "Display format spec" and
"Test strategy" below. `EvalResult` stays a display `string` or a
`Diagnostic` — carrying a separate static type alongside it was considered
and rejected this session: the type is resolved by semantic analysis
(including `auto`-deduced return types) before any backend runs and is
identical across backends, so it belongs to the frontend, not the eval
result. A backend cannot produce a different *type* for an expression,
only different runtime *bits* — which the value digits and behavioural
probes catch (see "Test strategy").

Decision 2026-06-13 (implemented): the `EvalResult` contract now carries
the rendered display `string` (or a `Diagnostic`), completing decision 1.
`EvalResult._payload` is `SumType!(string, Diagnostic)`; `value()` is
replaced by `display()`. The `Value -> display-string` rendering moved to
the per-backend `eval(FuncDeclaration)` boundary via a single shared helper
`displayString(Value, FuncDeclaration)` in
`source/quickbite/backends/evaluator.d`, so every backend and the
`eval(Cell)`/`eval(string)` paths render identically: `void` -> `""`, a
character-array return -> the quoted string with its width suffix,
everything else -> `Value.toString`. Per decision 4 this is interim: each
backend keeps its private reify -> `Value` -> `toString` scaffolding behind
the string-returning interface, to be deleted per backend as it learns to
execute the prelude formatter. `Value`, `value.d`, `asCharArrayString`,
`stringTypeAnnotation` and `dText` are unchanged. The REPL
(`source/quickbite/repl.d`) keeps the synthetic-name scrubbing
(`userDiagnostic`/`userValueString`), now applied to the display string
carried by `EvalResult`; `Repl.submit` returns the display `string`.

Decision 2026-06-17: the endgame is narrowed from "delete the struct
entirely" to "remove the *shared, cross-backend* value type". The
tree-walking interpreter's *internal* runtime representation is
legitimately a boxed tagged union: that is the natural form for a
recursive AST walker, and re-expressing structs/classes/closures as raw
bytes would duplicate the bytecode VM's hardest work inside the backend
whose whole value is simplicity. So decisions 1-5 stand for the
`Evaluator` contract and the display path — the reify → `Value` →
`toString` scaffolding still goes, replaced by the decision-3 prelude
formatter — but the interpreter keeps a boxed value type for its own
evaluation. The change is one of *ownership*: that type becomes
interpreter-package-private (under `backends/interpreter/`) rather than
the shared `quickbite.lang.Value` that other backends and `EvalResult`
no longer touch. The bytecode and IR cores stay native-layout and never
reintroduce a boxed value (their cores already exclude it by design;
`ai/plans/bytecode.md` "No universal runtime value type"). This narrows
the deletion target only — both backends have identical DMD type info,
so this is not about capability. If the tree-walking interpreter is
itself later retired in favour of the VM, its private boxed type dies
with it, but that is a separate decision not taken here. (Superseded in
part by 2026-06-23: the "boxed tagged union is the natural form" claim is
downgraded from a settled decision to the *current implementation* of one
seam endpoint — see below.)

Decision 2026-06-23: this plan is now the **Track B charter** — the
interpreter's value representation — companion to the FFI bridge plan
(`ai/plans/ffi.md` §5/§6). The two are worked in parallel and meet only at
the FFI seam.

- The seam (`ffi.md` §5) is `materialize(value, Type) -> ABI bytes` and
  `reify(Type, ABI bytes) -> value`. The interpreter **owns its
  materialize/reify implementation**; the FFI bridge core never sees `Value`.
  Today that implementation is the boxed-aggregate marshalling currently in
  `backends/ffi.d` (`marshalArgument`/`unmarshalValue`), which moves to the
  interpreter side of the seam. The `ffi.md` §34.3 "Track B" / `B*` ladder
  rungs (typed slices, struct returns, nested slices, mutable-slice and
  receiver writeback) are this plan's, not the bridge's.
- The 2026-06-17 reasoning ("re-expressing aggregates as raw bytes duplicates
  the VM's hardest work") is reconsidered: it argues against *reimplementing*
  layout, not against *reusing* it. It is **recursive aggregate boxing**
  (`Struct = Value[] fields`, `Array = Value[] elements`) — not boxing per
  se — that forces per-call marshalling. Holding FFI-crossing aggregates in
  native layout *behind the handle* (reusing DMD offsets) would collapse the
  `B*` rungs; whether to do so is an **open empirical question**, not a
  settled decision.
- Why empirical: the point of multiple backends is to try representations and
  measure which is fastest (the project goal is latency). We do not yet know
  whether boxed `Value` or native-layout aggregates is faster in the
  interpreter — and we **cannot measure until FFI works**, because measuring
  means running real dub projects' unittests, which need the bridge. So the
  ordering is: carve the seam, keep the boxed `materialize` working so FFI and
  real tests run, *then* try native-layout aggregates behind the same
  interface and measure. Do not climb the `B*` rungs as ever-more boxed
  marshalling on the assumption boxing stays.
- Native layout in the interpreter is **not** a compile step and does not cost
  emit latency. Representation (boxed vs native) and execution strategy (walk
  the AST vs lower to bytecode) are orthogonal: the no-emit advantage is the
  *tree-walker vs VM* axis and survives either representation. A native-layout
  interpreter still walks the AST; it only reads/writes native frame memory at
  DMD offsets instead of boxed `Value`s. So the experiment compares two
  *no-emit* interpreters, not interpreter-vs-VM.
- What to measure, then, are the real run-time cost axes (none is compile):
  boxing's per-aggregate GC allocation + tag dispatch + per-crossing FFI
  marshalling, *versus* native layout's GC-root bookkeeping
  (`addRange`/`removeRange`, conservative frame scanning) + runtime
  type-metadata synthesis for druntime leaves (`bytecode.md`). Plus the
  correctness ceiling boxing cannot pass at any speed (`&local`, unions,
  reinterpret casts, slices into locals) — which may decide the question
  independent of latency.
- `Value` is a Lox-derived tagged union (Crafting Interpreters). It exists to
  carry a runtime type tag that a *dynamically typed* interpreter needs;
  Quickbite's DMD frontend stamps a static `Type` on every node, so the tag
  is redundant. The box's only remaining benefit is host-language
  convenience (a uniform D type to return from `eval(Expr)`); that benefit is
  what is paid back at the seam.

Decision 2026-06-23 (research validation + reframe): a cross-language survey
(LuaJIT, CPython, Ruby MRI, the JVM, .NET, Go; plus the static-language
interpreters OCaml/GHCi/JVM/MLton and the CTFE engines of Clang/D/Zig) settles
two things bearing on the open question above.

- The boxed-leaves + native-layout-aggregates-behind-a-handle shape is the
  **universal** answer, not a Quickbite invention. Every boxed-value runtime that
  does FFI well keeps its box for scalars / host convenience but holds
  FFI-crossing aggregates in native ABI layout behind a thin handle, never as a
  recursive tree of boxed values: CPython `ctypes`/`cffi` `cdata`, Ruby
  `Fiddle::Pointer` / `FFI::AbstractMemory`, LuaJIT `GCcdata`, the JVM's
  `MemorySegment`+`VarHandle` (Panama) versus boxed-object JNI, and .NET
  *blittable* types (identical bit layout → pinned, not marshalled). The handle
  and the native-layout representation are the **same idea at two transparency
  settings** — opaque (never read through the pointer; the `ffi.md` §11.3 escape
  hatch) versus transparent (read/write fields at DMD offsets; the native-layout
  interpreter). The boxed interpreter sits between them, paying a per-crossing
  materialize/reify.
- The reframe: moving aggregates to native layout is a **correctness win first,
  latency second** — which dissolves the "worse interpreter to save FFI work"
  framing. The static-language survey confirms the Lox type *tag* is redundant
  for type-safety (the JVM operand stack carries none; MLton is fully unboxed;
  OCaml's tag exists for the GC and separate-compilation polymorphism, not
  types). But runtime discriminants are still required for GC pointer-tracing and
  for sum-type/union/variant dispatch — exactly the correctness ceiling
  (`&local`, unions, reinterpret casts, slices into locals) that *recursive
  aggregate boxing* cannot pass at any speed. Native layout passes it by
  construction. This is the decider already named in the 2026-06-23 measured
  result below; the survey corroborates it.
- Latency caveat, to keep expectations honest: native layout removes
  per-aggregate marshalling + GC alloc + tag dispatch (the measured ~26x), but
  **not** the libffi `ffi_call` dispatch cost — only a JIT erases that, which a
  tree-walker does not have. So native layout makes interpreter FFI *correct and
  marshalling-free*, not *fast in absolute terms*; the interpreter's edge stays
  no-emit (the orthogonality argument above), not fast calls.
- `std.variant.Variant` considered and rejected as a replacement for the current
  `SumType` `Value`. It is a heavier box for the same strategy, not a different
  strategy: it still recursively boxes aggregates (a *guest* `struct Point` is a
  DMD AST type, not a host D type, so it cannot be stored in a `Variant` at its
  native type — it becomes `Variant[]`, exactly as it is `Value[]` today), it
  reintroduces the runtime `TypeInfo` dispatch the static frontend makes
  redundant, it heap-allocates past its inline buffer, and it drops `match`
  exhaustiveness. It moves the representation the wrong way along the axis above
  (toward a worse box); the fix moves the other way (toward native bytes behind a
  handle).

Progress 2026-06-19: the prelude formatter now owns the scalar literal
suffix cases that were previously only pinned through `Value.toString`:
`uint`, `long`, `ulong`, `float`, and `real` render as D literals with
`u`, `L`, `UL`, `f`, and `L` suffixes respectively, and the whole-floating
decimal-point rule is shared across `float`, `double`, and `real`. This is
still a prelude-surface slice only: expression cells are not yet synthesized
as `__quickbiteFormat(expr)`, and the interim backend `Value` rendering
path remains in place.

Progress 2026-06-19: the prelude formatter now owns the character-width and
string-width display rules: `char`/`wchar`/`dchar` render as character
literals, and `wstring`/`dstring` render as string literals with `w`/`d`
suffixes. This is still a prelude-surface slice only; the interim backend
`Value` rendering path remains in place.

Progress 2026-06-19: the prelude formatter now owns array element rendering
for dynamic and static arrays, so aggregate elements carry their own literal
suffixes (`[1u, 2u]`, `[1L, 2L]`, `["a"w, "b"w`) instead of relying on
`std.conv.text`'s widened element rendering. This is still a prelude-surface
slice only; expression cells are not yet synthesized as
`__quickbiteFormat(expr)`.

Progress 2026-07-06: the prelude formatter now owns struct, enum, and
associative-array rendering, closing the `text(value)` catch-all for the
aggregate cases: enums render as qualified members (`E.b` — diverging
from the interim `Value` path's bare member name, which is not
round-trippable D), structs render `Name(field, ...)` with each field in
its own round-tripping form (`Point(1, 2L)`, quoted string fields), and
AAs render `[key:value]` with element-wise literal suffixes. Multi-entry
AA rendering order is left unpinned (D AA iteration order is
unspecified; round-trip validity does not depend on it). Non-member enum
values (`cast(E)5`) are also unpinned. This completes the formatter half
of remaining-work item 1; the wiring half is untouched and every REPL
display still runs through the interim `displayString`/`Value.toString`
scaffolding.

Progress 2026-07-06: selected expression cells now synthesize
`__quickbiteFormat(expr)` instead of displaying the backend `Value`
directly. `Ctfe` and `Interpreter` opt in through a backend capability; the
frontend imports `quickbite.repl_prelude`, rewrites struct expression cells
that need 64-bit integer suffixes, and unwraps the formatter's returned string
at the evaluator boundary. The gate is intentionally narrow so existing range,
delegate, null-field, function-diagnostic, enum, and scalar displays keep their
current contracts while the `long`/`ulong` struct-field fallback moves out of
`Value.toString`.

Progress 2026-07-06: the formatter gate now covers struct expression cells
with function-pointer and delegate fields, so CTFE and Interpreter render null
callable fields through the prelude instead of diverging through the interim
`Value.toString` scaffolding (`Callbacks(7, null)`, `Handler(9, null)`). The
prelude has a callable branch that renders null function pointers and delegates
as `null`; the Interpreter preserves null through pointer/delegate casts needed
by DMD's lowering.

Progress 2026-07-06: the formatter gate now also covers struct expression
cells with class-reference fields, moving null class fields (`Node(5, null)`)
onto the prelude path for CTFE and Interpreter. The display text is unchanged;
the frontend now proves these expressions synthesize `__quickbiteFormat(expr)`
instead of falling back to the interim `Value.toString` scaffolding.

Progress 2026-07-06: the formatter gate now covers struct expression cells
with `long[]`/`ulong[]` fields, moving array element suffix rendering
(`Bag([1L, 2L])`) onto the prelude path for CTFE and Interpreter. The gate is
still narrower than all array fields: Phobos range structs with plain `int[]`
state keep the existing `Value.toString` display contract until range displays
are deliberately moved.

Progress 2026-07-06: the formatter gate now covers struct expression cells
with enum fields and enum-array fields. These need the prelude because enum
members render as qualified D expressions there (`Box(E.b)`,
`Box([E.a, E.b])`), unlike the interim `Value.toString` scaffolding's bare
member names.

Progress 2026-07-07: the formatter gate now covers struct expression cells
with character-array fields (`string`/`wstring`/`dstring`) and associative
array fields. CTFE and Interpreter therefore render string-width suffixes and
AA element suffixes through the prelude path (`Person("Bob", "wide"w)`,
`Lookup(["answer":42L])`) instead of relying on the interim
`Value.toString` scaffolding.

Progress 2026-07-07: the formatter gate now covers struct expression cells
with ordinary pointer fields. Null pointer fields (`Link(4, null)`) therefore
use the prelude path for CTFE and Interpreter, matching the existing callable,
delegate, and class-reference null-field cases without relying on the interim
`Value.toString` scaffolding.

Progress 2026-07-07: the formatter gate now covers direct expression cells
whose return type is an enum, selected dynamic/static arrays, or an
associative array. Direct enum expressions and enum arrays therefore use the
prelude's qualified member rendering (`E.b`, `[E.a, E.b]`), and direct
suffix-sensitive arrays/AAs use element-wise literal rendering (`[1L, 2L]`,
`["answer":42L]`) instead of the interim `Value.toString` scaffolding. The
prelude enum formatter now returns named members through generated literal
strings so the Interpreter can execute the direct enum path without falling
through `std.conv.text`'s enum formatting.

Progress 2026-07-07: the formatter gate now covers direct expression cells
whose return type is suffix/width-sensitive scalar display (`uint`, `long`,
`ulong`, `char`/`wchar`/`dchar`, `float`, `double`, `real`). CTFE and
Interpreter therefore render those direct scalar cells through
`__quickbiteFormat` instead of the interim `Value.toString` display path. The
Interpreter also gained the small `std.conv.text` builtin needed to execute the
formatter's scalar conversion path, and the prelude now appends scalar suffixes
without binary string concatenation. Bytecode engines remain on their frozen
display rows for slice-11 re-earn; no bytecode files were touched.

Progress 2026-07-07: the formatter gate now covers direct expression cells
whose return type is an ordinary non-template struct with no synthetic context
field, plus dynamic/static arrays of those structs. Plain struct values
(`Point(1, 2)`) and struct arrays (`[Point(1, 2)]`) therefore synthesize
`__quickbiteFormat(expr)` for CTFE and Interpreter instead of relying on the
interim `Value.toString` scaffolding, while nested-context structs and Phobos
range structs stay on their existing display path.

Progress 2026-07-07: the formatter-gate test debt is cleaned up. Tests no
longer assert that expression cells contain `__quickbiteFormat`; the surviving
coverage now runs formatter-capable backends and asserts user-visible display.

Progress 2026-07-08: the formatter gate now covers direct expression cells
whose return type is any primitive D-literal scalar already handled by the
prelude (`bool`, character widths, integral widths, and floating widths), plus
dynamic/static arrays whose element type can itself use the prelude. CTFE and
Interpreter therefore render ordinary scalar cells and ordinary/nested array
cells through `__quickbiteFormat` instead of the interim `Value.toString`
display path. CTFE also gained a REPL-session fast path for formatter-wrapped
cells: it extracts the formatter's returned string directly from DMD CTFE
results (`StringExp` or char-array literal), so those CTFE REPL displays no
longer pass through `ctfeValue`/`displayString`. The old CTFE reifier remains
for unformatted evaluator calls and still-ungated REPL cases such as
range/template structs and nested-context structs.

Decision 2026-07-07: ownership split with the bytecode rewrite
(`ai/plans/bytecode.md`), so the two tracks can run in parallel without one
building what the other deletes.

- This plan's formatter track owns the frontend gate (`frontend/cell.d`),
  the prelude (`source/quickbite/repl_prelude.d`), and the opted-in
  backends (`Ctfe`, `Interpreter`) including their interim-scaffolding
  deletion. It does not touch `backends/bytecode/**`.
- The bytecode backends opt in through their own plan's slice 11 ("Prelude
  formatter execution", `bytecode.md`): the new core earns display by
  executing `__quickbiteFormat`, then deletes its display scaffolding (the
  deletion inventory in `bytecode.md`). Until then, `repl.d` display-string
  tests are frozen for `Bytecode`/`BytecodeNewCore`.
- Matrix rule: new or changed display tests are parameterized over
  formatter-capable backends only (today `Ctfe`, `Interpreter`);
  `Bytecode`/`BytecodeNewCore` join a display test's `AliasSeq` when they
  opt in. If a formatter change alters an expected display string that an
  existing test row pins on a bytecode engine through the interim
  `Value.toString` path, drop that engine from the block's `AliasSeq` and
  record it as a pending slice-11 re-earn — do not implement matching
  `Value` scaffolding on the bytecode side. (This is the existing
  omit-don't-pin fixture convention applied to display rows.)

Decision 2026-07-09: the correctness ceiling is empirically confirmed and
the representation decision is **un-gated** from the latency measurement.
The 2026-06-23 open question was gated on "cannot measure until real dub
suites run"; that gate applies only to the latency A/B. The same decision
text already named the real decider — the correctness ceiling (`&local`,
unions, reinterpret casts, slices into locals) "which may decide the
question independent of latency" — and PR #386 (the interpreter cerealed
frontier) has now supplied the empirical confirmation: of its frontier
advances, all but the lazy-parameter thunks and the exception-hierarchy
classification were representation-induced shims sitting exactly on that
ceiling list — float/double pointer reinterpret loads, `emplaceRef`'s
`cast(S*) &chunk` aliasing (intercepted by name despite having D source),
class-references-passed-by-value writeback, pointer-slice allocation
identity, and the `gc_*` array-capacity hooks stubbed because boxed
interpreter arrays are not addressable GC blocks. Consequences:

- The decision is decided: recursive aggregate boxing cannot reach
  `interpreter.md`'s terminal goal without accumulating name-based shims
  and per-case writeback side-tables (the child `Walker` now duplicates
  ~ten aliasing maps per call). The shims are inventoried as this track's
  deletion obligations in `interpreter.md` §9.10.
- Ordering correction (mirrored in `interpreter.md` §1/§4/§8): this track
  no longer waits on cerealed-green to act. `interpreter.md` triages each
  frontier class as language-surface (fixed there) vs representation-
  ceiling (red fixture with Interpreter omitted, root deferred here);
  cerealed's remaining ceiling classes wait on this plan, not the other
  way around.
- The unit of change stands per the 2026-06-23 measured result: not a
  bolt-on marshaller, and not a VM rewrite (`bytecode.md` is unaffected
  and remains the native-layout *execution* track). The experiment is the
  survey's universal shape inside the tree-walker: boxed scalars,
  native-layout aggregates/arrays behind a handle reusing DMD offsets.
  See remaining-work item 7.

Progress 2026-07-09: item 7's "Next PR" list is started with an
interpreter-internal native-layout array skeleton, landed but not wired
into anything else. `native_block.d`'s `NativeBlock` is a stable,
non-moving byte range: a nested `Ownership` enum (`owned`/`borrowed`), an
`allocate` factory that zeroes the range via `GC.calloc` under an explicit,
never-defaulted `Scan` policy (`no`/`conservative`), a `borrow` factory for
memory owned elsewhere, and an `address` accessor that is the only place a
raw `void*` escapes -- `borrow` is `@system`, not `@safe`, since it
fabricates a slice from a caller-supplied pointer/length it cannot itself
verify; that `@trusted` boundary belongs to whichever future FFI seam
vouches for the pointer, not to the block. `layout.d` adds `typeByteSize`
and `typeHasPointers`, thin `@safe` wrappers over DMD's own
`dmd.typesem.size`/`dmd.typesem.hasPointers` behind small `@trusted`
boundaries -- the module computes nothing itself, every number is DMD's
own verbatim. (Alignment is not exported yet -- it has no reader until the
struct phase lays out fields, so it is added when that reader exists, not
before.) `native_array.d`'s `NativeArray` combines a
block with the DMD element `Type`, a length, and a stride cached once from
`layout.typeByteSize`; `element` returns an interior `ubyte[]` view with
ordinary D slice bounds checking, and `writeSliceHeader` materialises a
real D dynamic-array slice header (`{ size_t length; void* ptr; }`) into a
caller-supplied destination, aliasing the element block rather than
snapshotting it. A `static assert` pins only the total header size
(`2 * size_t` bytes); field order (`length` first, `ptr` second) is
pinned separately, at runtime, by the `writeSliceHeader` tests, which
write a header and read it back against the host compiler's own slice
layout. The block (and so the
array handle) now records its scan policy, making the handle
self-describing rather than requiring a question to the GC.

One real bug was fixed on the way: `new ubyte[](n)` is always `NO_SCAN`, so
a block holding guest pointers would have been invisible to the GC and its
targets collectible out from under it. Blocks are now allocated with an
explicit scan policy chosen from `layout.typeHasPointers` on the element
type, and the parameter takes no default -- under-scanning is the unsafe
direction, so a forgotten argument must never silently choose it. An
overflowing `length * stride` product (checked with `core.checkedint.
mulu`) is rejected at allocation rather than wrapping to a too-small
block, so a handle's `length` is always consistent with its block.

None of this is wired in yet: no `impl.d`/`Walker`/`Value` integration, no
display change, no FFI change, no `interpreter.md` §9.10 shim retired, no
capacity/growth, no struct field offsets, no class objects. The
interpreter still boxes arrays exactly as before. Per the "Next PR" list,
still owed: capacity through real storage, then the struct phase, then
class objects -- and the actual interpreter call site that gives any of
these types somewhere to be used.

Progress 2026-07-09 (post-merge review fix): the paragraph above's claim
that `element` fails an out-of-range index via "ordinary D slice bounds
checking" was wrong. `index * stride` is computed before slicing, and
that multiply is itself unchecked -- a large enough `index` (verified
with the same `size_t.max / 8 + 2` shape as the `allocate` overflow
regression test) wraps the product back inside the block and returns a
different, real element's bytes instead of failing. `element` now checks
`index < length` first and throws `Exception` on failure, matching
`allocate`/`byteLength`/`typeByteSize`'s existing failure style. That
check is also what makes the subsequent multiply provably wrap-free:
`allocate` already rejected any `length * stride` that overflows
`size_t`, so once `index < length` holds, `index * stride < length *
stride` can't overflow either -- no second `mulu` needed. Whether the
eventual Walker call site should re-throw this as a `RangeError` for
compiled-D parity (`arr[i]` throws `core.exception.RangeError`, an
`Error`, not an `Exception`) is that call site's decision when it wires
up, not this container's. `layout.d` also now asserts a 64-bit host at
compile time, since DMD reports type sizes as 64-bit `uinteger_t`
values that the module narrows to `size_t`.

Progress 2026-07-09 (capacity through real storage): an array's element
capacity is now read from the GC rather than tracked in a field of our
own. `NativeBlock` gains `trueByteSize`, which returns `core.memory.GC.
sizeOf` on the block's address -- the GC's own bin size for the
allocation, not a number this module invents or caches. A *borrowed*
block honestly reports 0 (it is never GC memory), and a *zero-length*
block also reports 0 (its address is null); both are real, expected
zeros per `GC.sizeOf`'s own contract, not something papered over.
`NativeArray` gains `capacity`, derived as `block.trueByteSize / stride`
-- again derived, not stored -- so an owned array's capacity is `>=
length` (the GC's bin size rounds up from the requested bytes) and a
borrowed or zero-length array's capacity is 0. This is the first step
toward retiring `interpreter.md` §9.10's `gc_*` capacity-hook shims
(`tryGCArrayHook`/`runGCArrayHookCall`/`lastGCArrayUsedAllocation`),
which exist only because boxed interpreter arrays were never
addressable GC blocks; now that a block is a real allocation, no shim
is retired yet and nothing is wired in -- this is only the fact
becoming readable.

Progress 2026-07-09 (grow through real storage): `NativeArray` gains
`reserve(n)`, guaranteeing capacity for at least `n` elements exactly
like compiled D's `arr.reserve(n)`. `n <= capacity` is a no-op: no
address change, no byte touched. Otherwise `NativeBlock` gained
`tryExtendTo(newByteLength)`, which tries `core.memory.GC.extend` to
grow the existing GC allocation in place -- verified against the local
druntime (`core/memory.d` ~line 603): it returns the extended block's
byte size, or zero on failure. Correction to an earlier draft of this
note: `p` is not required to be "the block's own base pointer, which
`_block.address` always is here" -- druntime documents `p` as "a
pointer to the root of a valid memory block or to null", and a null
`p` (this block's own zero-length case, since `GC.calloc(0, ...)`
returns null) just makes `findPool(null)` report "cannot extend"
rather than misbehave. On success, `tryExtendTo` re-slices the block
over `newByteLength` bytes and zeroes the newly available tail, since
`GC.extend` itself leaves extension bytes uninitialised (druntime
`WARN_UNINITIALIZED`). If `GC.extend` fails, `reserve` allocates a
fresh block of the required byte length with the *same*
`NativeBlock.Scan` policy already recorded on the old block (never
recomputed), copies the live `length * stride` bytes across with a
`@safe` slice copy, and adopts the new block -- the address
legitimately changes here. Per the Address-stability bullet above,
that is correct: stale pointers into the old block go stale exactly as
compiled D loses append capacity on reallocation, and nothing is ever
copied back to the old address.

Unified post-condition: both paths leave `reserve` in exactly the same
observable state -- `block.byteLength == n * stride`, every byte beyond
the live `length * stride` is zero, `length` is unchanged, and element
values survive. Whether the allocator could extend in place, or had to
reallocate, is no longer observable: an extended block is
indistinguishable from a freshly allocated one of the same size. No
borrowed-block guard was added: a borrowed block cannot legitimately be
reallocated, but `NativeArray` has no borrow constructor yet, so that
path is unreachable from any test today. Owed contract: once a borrow
constructor exists, `reserve` must throw loudly on a borrowed block
instead of silently detaching the handle from memory its owner still
holds. Paid below (Progress 2026-07-09, borrowed-block guard).

Progress 2026-07-09 (strideless-handle fix): `NativeArray.init` (no
element type, zero stride) is a legal value -- reachable the moment this
handle is put in a field or array slot -- so `capacity` now returns 0
for it instead of dividing by zero, and `reserve` throws on it instead
of silently returning with capacity 0 short of what was requested.

Review nit fix (2026-07-09): `tryExtendTo` now only ever grows a block --
a request that does not grow it returns `false` before subtracting -- so
its `@trusted` re-slice is provable locally, without appealing to
allocator internals.

Progress 2026-07-09 (borrowed-block guard): the owed contract above is
paid. `NativeArray` gains a `borrow` factory, wrapping memory owned
elsewhere through `NativeBlock.borrow` -- it computes `stride` from
`elementType` and checks `length * stride` for overflow exactly as
`allocate` does, and is `@system` for the same unverifiable-
pointer/length reason `NativeBlock.borrow` is. `reserve` now throws if
it would reach the reallocating path with `_block.ownership ==
borrowed`: reaching that path would silently detach the handle from
memory its owner still holds, while that owner keeps reading and
writing the original address. The new guard sits after the existing
`n <= capacity` no-op, not before it: `reserve(0)` (or any `n` already
within capacity) is a legitimate no-op on any array, borrowed or not,
mirroring compiled D's `arr.reserve(n)`, which never touches storage it
doesn't need to grow. A borrowed block's `capacity` is always 0, so
that no-op is reached for a borrowed array only when `n == 0`; any
`n >= 1` falls through to the borrowed guard, which is the right place
for it, since only then is a reallocation actually being requested. The
borrowed guard is checked after the pre-existing `_stride == 0` guard:
a strideless handle is not even a properly constructed array, a more
fundamental defect than an otherwise-valid borrowed one -- though in
practice the two conditions never overlap on a reachable handle, since
`borrow` always computes a real, non-zero stride. `NativeArray.borrow`
has no caller yet -- no interpreter wiring, no FFI seam use -- so this
remains skeleton work exactly like the rest of item 7's block handle;
nothing observes a borrowed `NativeArray` outside its own unit tests.

Progress 2026-07-09 (scanned-destination contract): `writeSliceHeader`'s
destination is no longer a bare `ubyte[]`; it is a `(NativeBlock,
byteOffset)` pair, since a slice header's real destination is often a
*field* inside a larger block (a struct's `T[]` field), not the whole
block. Two invariants now hold, each its own thrown `Exception`:
bounds -- `byteOffset + sliceHeaderByteLength` must fit within
`dest.byteLength`, checked with `core.checkedint.addu` so a
caller-supplied `byteOffset` near `size_t.max` cannot wrap the sum back
into range -- and a scanned destination -- writing this array's block
address into a destination the GC never scans (`Scan.no`, or borrowed
non-GC memory) would make the element block invisible to the collector,
which could then free it while the guest's `T[]` variable still points
at it, exactly the hazard `NativeBlock.Scan` exists to avoid for the
block itself. That second check fires exactly when this array's own
block is `owned`, its address is non-null, and `dest.scan !=
Scan.conservative`; it stays silent for two cases that are not this
function's hazard: a zero-length array's block address is `null`
(`GC.calloc(0, ...)` returns `null`), so writing it into an unscanned
destination loses nothing, and a *borrowed* source array's address is
not GC memory the collector tracks in the first place, so `dest`'s scan
policy cannot make it more or less visible -- `NativeBlock.borrow`
already puts keeping that memory alive on the borrower/owner, not on
wherever the address is later written (a borrowed block could still
wrap GC memory one layer further out; if so, it is the borrow
precondition -- the owner outlives every derived handle -- that keeps it
alive, not this destination's scan policy). `writeSliceHeader` still has
no caller in production code; this closes the open question from item
7 below without wiring anything in yet.

Progress 2026-07-09 (struct phase: native block + DMD field offsets):
item 7's migration order moves to its second phase -- "a struct is one
block laid out with DMD field offsets" -- reusing the array phase's
block/offset machinery rather than growing a parallel set of layout
rules. `layout.d` gains `structFields`, which returns a `TypeStruct`'s
fields, in declaration order, as DMD's own `VarDeclaration`s
(`TypeStruct.sym.fields`, sliced to a plain array), and
`fieldByteOffset`, which returns one field's byte offset verbatim from
DMD's own `VarDeclaration.offset`. Both take DMD's own node types
(`TypeStruct`, `VarDeclaration`) rather than a bare `Type` cast at the
call site, so the type system -- not a runtime check -- rejects a
non-struct caller. The layout-forcing subtlety: `sym.fields` and every
field's `offset` are only meaningful once DMD has laid the struct out
(`determineSize`/`finalizeSize`), and can be empty or meaningless
before that. `structFields` forces that layout by calling the
already-existing `typeByteSize` first -- `Type.size` on a `Tstruct`
calls `aggregateDeclSize`, which calls `determineSize` ->
`determineFields` + `finalizeSize` -- reusing DMD's own layout pass
rather than duplicating it, and inheriting `typeByteSize`'s existing
`SIZE_INVALID` guard for free. `typeAlignment` is still not exported:
DMD hands us field offsets directly and `structsize` already includes
padding, so there is still no reader that would need it.

A new module, `native_struct.d`, adds `NativeStruct`: one `NativeBlock`
plus the DMD `TypeStruct`, mirroring `NativeArray`'s shape. `allocate`
sizes the block from `layout.typeByteSize(type)` -- DMD's own
`structsize`, padding included, never summed from field sizes -- and
picks the block's scan policy from `layout.typeHasPointers(type)`
exactly as `NativeArray.allocate` does from the element type: a struct
with any pointer/slice/class/AA field gets a conservatively scanned
block, since a block's scan policy is one attribute for its whole byte
range, not per field. `borrow` wraps memory owned elsewhere through
`NativeBlock.borrow`, under the same caller-enforced, unverifiable
precondition as `NativeBlock.borrow`/`NativeArray.borrow`. `fieldCount`
and `fieldDeclaration` expose the underlying `VarDeclaration`s;
`field(index)` returns the interior `ubyte[]` view of field `index`,
spanning `offset .. offset + typeByteSize(fieldType)`. `index` is
bounds-checked against `fieldCount` first, before any offset or size is
read, mirroring `NativeArray.element`'s discipline of failing on a bad
index before any arithmetic runs on it. Unlike `NativeArray.element`,
there is no overflow to guard in the arithmetic itself -- `offset` and
`fieldByteSize` are both DMD's own numbers, not a product of two
caller-controlled values -- so `field` relies on, rather than
re-derives, DMD's own guarantee that every field lies fully within
`structsize`.

None of this is wired in yet: no `impl.d`/`Walker`/`Value` integration,
no `interpreter.md` §9.10 shim retired, no nested-struct or
array-typed field *composition* (only the raw byte view of one field
at a time), no class objects, and no writes beyond that raw byte view.
Alignment remains unexported, per the paragraph above.

Progress 2026-07-09 (array/struct composition): `NativeStruct` and
`NativeArray` have now been composed for the first time. `NativeStruct`
gains `fieldByteOffset(index)` -- the DMD byte offset of field `index`,
bounds-checked against `fieldCount` exactly like `field`/
`fieldDeclaration`, and returned as `size_t` so it plugs directly into
`writeSliceHeader`'s `byteOffset` parameter with no cast at the call
site. No other production surface was added: the composition itself is
expressed at the call site, `array.writeSliceHeader(s.block,
s.fieldByteOffset(i))`, not behind a new "write this array into that
field" convenience method.

This is now true: a dynamic-array field of a native struct is a real D
slice header (`ptr`, `length`) over a separately tracked element block,
verified against the host compiler's own struct layout by reinterpreting
the struct's block bytes as the host's own equivalent `struct { ...
T[] xs; }` and reading `.xs` back. A second case pins this at a
non-zero offset (`struct Header { long tag; int[] xs; }`), confirming
`fieldByteOffset` is exercised for real and that the header write does
not disturb a sibling field. And the struct's scan policy -- chosen
from `layout.typeHasPointers(type)` at `allocate` time, per the struct
phase above -- is exactly what makes that header write legal:
`writeSliceHeader`'s scanned-destination contract throws unless the
destination block is `Scan.conservative`, and a struct with a slice
field gets exactly that, while an all-scalar struct gets `Scan.no` and
writing a slice header into one of its fields throws with
`writeSliceHeader`'s own "dest is not scanned by the GC" message. The
two contracts -- `NativeStruct.allocate`'s scan-policy choice and
`NativeArray.writeSliceHeader`'s scanned-destination check -- were
written independently, in separate PRs, and this composition is where
they are shown to fit rather than merely asserted to.

Still not done: no `impl.d`/`Walker`/`Value` wiring, no `interpreter.md`
§9.10 shim retired, no nested *struct*-in-struct field views, no
static-array-inline field, no class objects. The interpreter still
boxes everything; none of this native storage has a caller yet.

## Audit findings (June 2026)

- At audit time the REPL used `Value`'s structure only for
  display/control decisions: void suppression (`== Value.void_`), `:t`
  cells (`Value.typeName(asCharArrayString)`), string quoting, and
  success/failure gating (the `Diagnostic` arm of `EvalResult`, not
  `Value`). No `Value` ever feeds a later evaluation — session state is
  replayed from source. Since implemented away on this branch: void
  suppression is now an empty-display-string check and `:t` is
  frontend-answered (see decision 5 Progress and the Status "implemented"
  paragraph).
- `repl/main.d` consumes only `submitDisplay` (a string). Benchmarks
  compare `TestResult[]` (strings). `Runner` never touches `Value`.
- The execution cores already exclude it by design (`ai/plans/bytecode.md`
  "No universal runtime value type"; `ai/plans/ir.md`); the interpreter's
  internal use is first-generation scaffolding.
- The remaining customers of the structure (post-implementation): the
  EvalResult-contract assertions in `eval.d`/`repl.d` have been migrated
  to display strings, so what is left is
  `tests/ut/backends/evaluator/value.d` (`Value`'s own equality/rendering)
  plus the interpreter's internal `Value`-based execution scaffolding —
  both addressed below.

## Approved decisions

1. `quickbite.lang.Value` leaves the `Evaluator` contract: `EvalResult`
   carries the rendered display `string` (or a `Diagnostic`). The struct
   is deleted entirely once no backend needs it internally.

   Done 2026-06-13: the contract flip is implemented; see the Status
   "implemented" paragraph. The struct itself is NOT yet deleted — it
   survives as private per-backend scaffolding per decision 4.
2. Display round-trips as valid D: every rendering is a D expression that
   parses and evaluates to a value equal to the original (Python's `repr`
   principle). It is *not* the channel for revealing a value's static
   type. Where D has no literal form for a type, the rendering's static
   type widens on re-parse (the *value* round-trips, the type does not)
   and the user reaches for `typeof`/`it.typeof` instead. The spec was
   reversed on 2026-06-13 (it required injectivity per type on
   2026-06-12); see "Display format spec" below. The change is small in
   practice: the literal-suffix renderings (`3u`, `42L`, `3.0f`, `3.0L`,
   `"x"w`) already round-trip *and* reveal type; only the invented
   `: type` annotations (former rules 2 and 4) are dropped. The formatter
   and the migrated tests are both downstream of it.
3. The canonical formatter's end state is an in-program prelude template,
   `string __quickbiteFormat(T)(T value)`, written once in ordinary D
   with `static if` introspection. The frontend synthesizes expression
   cells as `__quickbiteFormat(expr)`; semantic analysis — shared by all
   backends — instantiates the template against the real static type
   (the type is encoded in the AST), so type-directed dispatch is
   resolved before any backend runs and backends only execute code.
   Consistency across backends by construction; the native backend ships
   a plain `string` across the dlsym boundary. The TLV serialization of
   `Value` variants in earlier drafts of `ai/plans/repl.md` is dead.
4. Interim: the contract changes first. Host backends (CTFE, interpreter,
   bytecode, IR) keep their existing reify → `Value` → `toString` chains
   as *private* formatting scaffolding behind the string-returning
   interface, deleted per backend as each becomes able to execute the
   prelude formatter. That is expected to happen: the bytecode and IR
   cores are headed for full D, so the formatter is an early, demanding
   test program for them, not a new requirement. During the interim the
   formatter-wrapped synthesis applies only to views consumed by backends
   that can execute it (see the snapshot/delta views in
   `ai/plans/repl.md`).
5. REPL mechanics survive without `Value`: void suppression is decided at
   synthesis time (the frontend knows when `typeof(expr)` is `void`, and
   `Cell.Kind.noDisplay` already exists), `:t` already round-trips
   `.stringof` as a string, and string quoting moves into the formatter.
   Type disambiguation of display output is now an explicit user action —
   `typeof`/`it.typeof` (`ai/plans/repl.md`) — since display no longer
   encodes type for no-literal types (decision 2); `:t` stays
   frontend-answered for latency, not routed through a backend.

   Progress 2026-06-13: `:t`/type-expression cells are now actually
   frontend-answered. `EvalSession.typeExpressionName` resolves the type
   from the DMD AST (the alias-probe type's `Type.toChars`, which DMD also
   uses to compute a type's `.stringof`, so the rendering is byte-for-byte
   identical) and `ReplSession.submit` records it on the `ReplCell`. The
   REPL short-circuits these cells, displaying the name bare without
   calling `backend.eval`, `Value.asCharArrayString`, or `Value.typeName`.
   The old `.stringof`-via-backend path remains only as a fallback for
   inputs the frontend cannot resolve.
6. The native backend (`SystemLinker`) is the single behaviour oracle in the
   absence of a formal, machine-verifiable language specification (it remains
   one option among many for benchmarking). CTFE is not an oracle; where it
   diverges, its behaviour is characterized, not treated as truth
   (`ai/plans/single-oracle.md`).

## Display format spec (agreed 2026-06-12; principle reversed 2026-06-13)

Principle: every rendering is valid D that parses and evaluates to a value
equal to the original (round-trip / Python-`repr`). Rendering is *not*
required to be injective per type — where D has no literal form for a type,
the rendering's static type widens on re-parse (the value round-trips, the
type does not) and `typeof`/`it.typeof` disambiguates. Conventions, in
order:

1. D literal (or literal-like) syntax where it exists, round-tripping both
   value and type: `42`, `42u`, `42L`, `42UL`, `3.0`, `3.0f`, `3.0L`
   (real — the `L` float suffix round-trips), `true`/`false`, `'a'`,
   `"text"`, `"text"w` (wstring), `"text"d` (dstring), `null`, `[1, 2]`,
   `[1:10, 2:20]`. The suffix convention was already pinned by
   `repl.backend.numericScalarDisplayUsesDLiteralSuffixes`,
   tests/ut/bin/repl.d.
2. Types with no D literal form render in their natural bare/literal form,
   accepting that the static type widens on re-parse:
   - `byte`/`ubyte`/`short`/`ushort` → `42` (re-parses as `int`).
   - `char`/`wchar`/`dchar` → `'a'` (re-parses as `char`).
   `typeof`/`it.typeof` disambiguates. The former `: type` annotations
   (`42: byte`, `'a': wchar`) are dropped — they are not parseable D. (A
   round-tripping `cast(wchar)'a'` form is available if exact-type
   round-trip is later wanted, but bare + `typeof` is the default.)
3. Floating values always include a decimal point or exponent: `3.0`,
   `3.0f`, `3.0L` — never a bare `3` that re-parses as `int`. (Now a
   round-trip requirement, not an injectivity one.)
4. Aggregates round-trip element-wise: each element/key/value renders in
   its own round-tripping form, so the aggregate self-identifies without
   an annotation. `[1, 2]` is `int[]`; `[1L, 2L]` is `long[]`; `[1:10]`
   is `int[int]`. Aggregates whose element type has no literal form stay
   ambiguous (`[1, 2]` could be `ubyte[]`) — `typeof` disambiguates, same
   as the scalar case. The former trailing `: long[]` annotation is gone,
   and with it the need for element-type metadata on `Value.Array`.
5. Structs and enums round-trip via their rendered names (`Point(1, 2)`,
   `E.a`); unchanged.
6. Width round-trips for strings via the literal suffix (`"x"w`, `"x"d`);
   for characters it does not (all widths render `'a'`, disambiguated by
   `typeof`). Type qualifiers (`const`/`immutable`) and mutability are not
   displayed.
7. `void` results display nothing (REPL suppression). Functions,
   delegates, pointers, and other values with no D expression form cannot
   round-trip; there is no contract to honour, so render whatever is most
   useful to the reader (e.g. `<function int(int)>`, `&name`) — optimise
   for convenience, not parseability. Pointer display is otherwise
   unspecified until pointers become a displayable feature — spec it then.

Deltas from current behaviour (June 2026 audit):

- `char`/`wchar`/`dchar` scalars render bare and unquoted today (`a` —
  colliding with ints and each other); unpinned by tests, free to fix.
  Target: `'a'` for all three (the wide ones re-parse as `char`; `typeof`
  disambiguates).
- Whole-number doubles render `3` today, colliding with `int 3`;
  unpinned at the `Value.toString` level (only `3.8` is pinned). Target:
  `3.0`.
- Wide strings: done — `displaysWideStringValues` and
  `displaysWideCharacterArrayValues` (tests/ut/bin/repl.d) now assert
  `"wide"w`/`"wide"d` per the round-trip spec (approved and green). Note
  they pass today via the interim `Value.toString` path
  (`stringTypeAnnotation`), not the prelude formatter — see remaining-work
  item 1.
- Aggregates of non-default element type need no annotation under the
  round-trip spec: the elements carry their own suffixes (`[1L, 2L]`), so
  the aggregate self-identifies and `Value.Array` needs no element-type
  metadata. The former rule 4 (a trailing `: long[]` annotation) is gone;
  nothing to defer. Aggregates whose element type has no literal form
  (`ubyte[]`) stay ambiguous by design — `typeof` disambiguates.
- `bool`, `null`, and empty arrays conform today but are unpinned.
- The Interpreter keeps null function-pointer/delegate struct fields
  that the CTFE marshaling omits (`Callbacks(7, null)` vs
  `Callbacks(7)`); found by the Tier 4 coverage fixtures
  (`repl.backend.nullFunctionPointerFieldIsOmitted` /
  `nullDelegateFieldIsOmitted`, Ctfe-only pending resolution). The
  prelude formatter makes the policy question moot — one formatter,
  one rendering — but the interim scaffolding diverges today.

## Test strategy

Three layers replace structural `Value` assertions:

1. Differential tests against the native oracle: run the same cell on the
   oracle and on the backend under test, assert identical display
   strings. No hand-maintained expected values; enforces formatter
   consistency as a side effect. Slow (~43 ms per native call, see
   `ai/plans/dmd-backend.md`) — a matrix job, not the inner loop.
2. Hand-written text expectations for the fast hermetic suite:
   `tests/ut/backends/evaluator/eval.d` has migrated (done 2026-06-13)
   from `.should == Value(3u)` to `.should == "3u"`;
   `tests/ut/backends/evaluator/value.d` is still present, to be deleted
   with the struct. One display string now
   carries two distinct assertions, and the migration must keep them
   straight:
   - The **suffix** witnesses the **static type** — but only where D has a
     literal form (`3u`, `42L`, `3.0f`, `'a'`, `"x"w`). That is a frontend
     fact, identical on every backend, so a suffix assertion pins semantic
     analysis, not backend behaviour. Types with no literal form (`byte`,
     `wchar`) carry no suffix and cannot be pinned this way — by design;
     the round-trip spec dropped the annotations that used to.
   - The **value digits** witness the **backend's runtime behaviour**.
     Narrowing/widening/signedness are caught here, not by the suffix, by
     constructing expressions where the bug changes observable digits:
     drive the static type with an explicit `cast` so the formatter
     renders at the narrow type, and pick operands where truncation,
     wrap-around, or sign flips the result — e.g.
     `cast(ubyte)(255 + 1)` → `"0"`, `cast(byte)(byte.max + 1)` →
     `"-128"`, `-1 / 2u` → `"2147483647u"`, `-8 >> 1` → `"-4"`.
   The migration is no longer "lossless because injective per type" (the
   2026-06-12 framing): a bare `42` no longer pins `int` vs `byte`. Where a
   test must pin a no-literal subtype, it asserts a value-observable
   behaviour (this layer) or queries `typeof` (a frontend fact), not the
   bare display.
3. Behavioural probes for runtime semantics display cannot reveal:
   wrap-around, truncation, signed/unsigned comparison and division,
   float-width effects. These test execution, not formatting — and, per
   layer 2, they are the *only* layer that exercises a backend's runtime
   type handling. The boundary: a width/storage difference that never
   changes an observable value is untestable through the string, but also
   unobservable to any program — not a bug that can matter.

`tests/ut/backends/evaluator/value.d` (15 blocks testing `Value`'s own
equality and rendering) is deleted together with the struct. Do not pin a
backend's runtime type via `typeof(expr).stringof` or any static-type
channel: those are computed by the shared frontend and pass even when a
backend widens a value at runtime — that is what layer 2's digit
assertions and layer 3 are for.

All test additions/changes require approval first (AGENTS.md).

## Remaining work

The contract flip (decision 1) and frontend-answered `:t` (decision 5)
are done; what is still pending, in order:

1. Complete the prelude formatter `string __quickbiteFormat(T)(T value)`
   (decision 3): the formatter surface is done as of 2026-07-06 — structs,
   enums, and AAs now render per the round-trip spec (see Progress above)
   and the `text(value)` catch-all covers only the rule-7 no-contract
   values. What remains is completing the incremental wiring: expression
   cells are now synthesized as `__quickbiteFormat(expr)` for selected
   return types when the backend opts into the prelude formatter, but many
   expression displays still run through the interim
   `displayString`/`Value.toString` scaffolding. Keep expanding the gate per
   backend (decision 4: only views consumed by backends that can execute it)
   until the display spec is no longer enforced by the path scheduled for
   deletion. Items 2 and 3 below are blocked until this wiring lands.
   The interpreter's `std.conv.text` hook is temporary formatter scaffolding,
   not a general Phobos builtin: remove it once the formatter no longer needs
   that escape hatch to execute direct scalar display cells.
2. Delete the private reify → `Value` → `toString` scaffolding per
   backend (decision 4) as each gains the formatter.
3. Remove the *shared* `quickbite.lang.Value` (decision 2026-06-17):
   once no backend depends on it as a cross-backend type, relocate the
   tree-walking interpreter's internal boxed representation to an
   interpreter-package-private type, then delete the shared struct and
   `tests/ut/backends/evaluator/value.d` together. Only the shared type is
   deleted; the interpreter keeps an internal value type whose *shape* is the
   2026-06-23 open question.

Track B (FFI seam) work, parallel to the bridge track in `ffi.md` §6:

4. Done 2026-07-08: carve the seam. The boxed `Value <-> ABI bytes`
   marshalling now lives in
   `source/quickbite/backends/interpreter/ffi_marshal.d` as the interpreter's
   `materialize`/`reify` implementation behind the `ffi.md` §5
   `NativeMarshaller` interface. The backend-neutral bridge core lives under
   `source/quickbite/ffi/` and never names `Value`. This unblocks the two
   parallel tracks; future Track B work stays behind the same seam.
5. Own the `ffi.md` §34.3 `B*` rungs (boxed-slice/struct/nested/writeback
   marshalling) as the interpreter's `materialize`/`reify`, keeping FFI working
   so real dub tests can run.
6. Experiment (do not pre-commit): hold FFI-crossing aggregates in native
   layout behind the handle (reuse DMD offsets), measure latency against the
   boxed implementation across the benchmark suite, and keep whichever wins.
   Several `B*` rungs collapse to the identity under native layout.

   Result 2026-06-23 (measured): a *bolt-on* native-layout `NativeMarshaller`
   is the wrong unit of change — keep the boxed marshaller for now. Evidence:
   - The benchmark suite never crosses the FFI seam: `bin/bench`'s fixtures
     (`tests/example.d`, dub projects) have no native dependency, so the
     interpreter row is frontend + tree-walking with zero marshalling. A
     marshaller swap is invisible to `ci.sh`/`bin/bench`; only the `rt/`
     dependency-image suite exercises the seam.
   - The representation gap is real but lives off the seam. Construct +
     read-back micro-benchmark (1M iters): a boxed 4-long struct is ~26x a
     native byte layout (1049 ns vs 40 ns); a boxed 16-long slice ~27x
     (2220 ns vs 81 ns) — i.e. boxing's GC alloc + `SumType` tag dispatch.
   - A native-layout marshaller cannot capture that gap while the interpreter
     stays boxed: its inputs are already-boxed `Value`s and its output must be
     a boxed `Value`, so it boxes on the way in and out regardless and only
     adds blob bookkeeping. The 26x is realizable only when aggregates are
     never boxed — the interpreter-wide native representation (decision 2026-
     06-23, remaining-work item 3), where the seam collapses to identity.
   - The decider is the correctness ceiling (`&local`, unions, reinterpret
     casts, slices into locals), not latency; it lands with the
     representation change, not a marshaller swap.

   Conclusion: defer native layout to the interpreter-representation track and
   measure it on the tree-walker hot path, not the FFI seam. The `B*` rungs
   (§34.9/§34.10/§34.11) are landed as boxed marshalling, which is correct and
   keeps real dub tests runnable in the meantime.

7. (2026-07-09, un-gated by the correctness-ceiling decision above.) Run the
   native-layout-aggregates experiment in the tree-walker: boxed scalars stay,
   aggregates/arrays live in native ABI layout behind a handle reusing DMD's
   own field offsets; pointers become real addresses into that storage. This
   is the interpreter-wide representation change the 2026-06-23 measured
   result deferred to — the right unit of change, unlike the rejected bolt-on
   marshaller. Success criteria, in order:
   - the `interpreter.md` §9.10 shims are deleted one by one, each deletion
     proven by its ratchet fixtures staying green through the real path
     (`emplaceRef` executes its actual body; `memcpy` and the `gc_*` hooks
     route through ordinary FFI);
   - the parked representation-ceiling gap fixtures (§9.10 "gap fixtures")
     re-earn `Interpreter` in their matrices;
   - the cerealed frontier resumes on the new representation, and the
     latency A/B (item 6's original question) is finally measured on real
     suites once they run.
   Design sketch 2026-07-09 (the "plan before code" session; no code, no
   fixtures, no shim deletion). A *native block* is a stable byte range laid
   out with DMD's own offsets, stride, and alignment; a *handle* is the
   interpreter-owned metadata for one block — `Type*`, byte length, ownership,
   mutability, and its GC root-registration token. Interior addresses are views
   over a block plus an offset; a raw `void*` is produced only at the last step
   before FFI or an intrinsic, and is never the ownership token.

   - **Storage shape.** Scalars stay boxed: integral, floating, enum, null, and
     pointer leaves keep expression evaluation direct. Recursive aggregate
     boxes collapse to one aggregate-handle arm. A static array is one inline
     block; a dynamic array is a real D slice header (`ptr`, `length`) over a
     separately tracked element block; a struct is one block laid out with DMD
     field offsets. Class references keep the boxed object representation until
     the class phase.
   - **Address stability.** Every address reachable through `&local`,
     `array.ptr`, slice construction, pointer arithmetic, `memcpy`, or FFI
     points into a native block, never into a boxed snapshot. Blocks must not
     move while an interpreter pointer can reach them; when array growth
     reallocates, the owning slice header is updated and stale addresses go
     stale exactly as compiled D loses append capacity — no boxed value is ever
     copied back as the authority.
   - **GC roots.** (Corrected 2026-07-09 -- see Status.) An owned block is
     a GC allocation whose scan attribute (`NO_SCAN` vs conservatively
     scanned) is chosen once, at allocation, from whether the element type
     carries pointers. `NativeBlock` is a value struct copied freely --
     copies share one address but have no single owner -- so there is no
     registration token and no destruction hook to get wrong: an
     allocation attribute cannot be double-freed or unregistered out from
     under a still-live copy. The GC then conservatively scans the whole
     byte range for exactly as long as the block is reachable, which is
     the conservative policy this item asks for. Precise pointer-bearing
     subranges are a later optimization, not a prerequisite. `GC.addRange`
     is reserved for memory the GC does not own: handles that borrow FFI
     or host memory register nothing; they only keep a Quickbite-owned
     source owner live for the duration of the borrow.
   - **Ownership and writeback.** Whether a block is owned or borrowed, and
     whether writes through it reach an external owner, is explicit metadata on
     the handle. It is never inferred by diffing a pre-call boxed aggregate
     against a post-call one. Class-reference identity is not by-value
     writeback: one object body is shared by every reference to it, which is
     why `writeBackByValueClassArguments` cannot be retired by the array or
     struct phases.
   - **Migration order.** Arrays first: the smallest surface that exercises
     stable element addresses, slices into locals, capacity hooks, `memcpy`,
     and array-pointer FFI without needing object identity. Structs second,
     reusing the same block/offset machinery. Class objects third — they need
     native object identity, vptr/monitor layout, and constructor lifetime, and
     delaying them keeps the array/struct proof off the hardest object-model
     questions. Invert only if a red fixture proves a struct or object root is
     needed to make the array step observable.
   - **Shim deletion path**, mapping §9.10's inventory onto the phases above.
     Array-native storage retires the `gc_*` capacity hook stubs and the
     `lastGCArrayUsedAllocation` side channel, by making druntime's capacity
     helpers ordinary body-less FFI over real addressable blocks, and reduces
     `runMemcpyCall` to the plain FFI or intrinsic byte copy once both
     endpoints are native ranges. Struct-native storage retires
     `runEmplaceRefCall`/`isEmplaceRef`, by letting the real
     `core.internal.lifetime.emplaceRef` body write through the destination
     address, and retires
     `reinterpretLocalPointerLoad`/`floatBits`/`doubleBits`, by making
     `*cast(T*) &local` a load of the same bytes at a different static type
     rather than a name match. Class-object storage retires
     `writeBackByValueClassArguments`. Each deletion lands with its §9.10
     ratchet fixtures green through the real path, per the success criteria
     above.

   The representation is interpreter-internal. It must not force `Bytecode`,
   `LLVMJit`, `SystemLinker`, or `Ctfe` to share a `Value` type or import
   interpreter packages: a promoted fixture proves the same D-language result,
   not a shared runtime value model. DMD-derived layout facts stay the source
   of truth, cached on the handle; the interpreter must not grow a second set
   of D layout rules.

   Open questions for the first implementation slice: lifetime contracts for
   blocks borrowed from arbitrary C owners; what a guest pointer into a grown
   array should observe, and whether that deserves a diagnostic rather than
   compiled D's silent staleness; unions and overlapping fields, which the
   conservative whole-range root policy handles but the layout model does not
   yet describe; and class object bodies, deferred wholesale.
   `writeSliceHeader`'s scanned-destination contract is no longer open:
   `dest` is now a `(NativeBlock, byteOffset)` pair, and the function
   throws before writing a GC-owned pointer into a destination the
   collector never scans (see Status's "scanned-destination contract"
   note above for the exact rule and the cases -- a zero-length array's
   null pointer, a borrowed source address -- that stay legal despite an
   unscanned destination).

   Progress against the "Next PR" list below: the array-native block handle
   skeleton is done (`NativeArray`: stable block, `Type`, length, stride,
   ownership, scan policy); capacity and growth through real storage are done
   (`capacity`, `reserve`, extending in place or reallocating, per the
   `NativeBlock.tryExtendTo`/GC-realloc progress notes above); a borrowed-block
   guard on `reserve` is done; `writeSliceHeader`'s scanned-destination
   contract is done (see above); and the struct phase (`NativeStruct`: one
   block sized and laid out with DMD's own `structsize`/field offsets, the
   same conservative-vs-no-scan choice `NativeArray.allocate` makes) is done.
   Most recently, the two have been composed: a struct's `T[]` field now
   carries a real slice header written by `NativeArray.writeSliceHeader` at
   `NativeStruct.fieldByteOffset`, verified against the host compiler's own
   layout, proving the scan-policy and scanned-destination contracts were
   designed to fit together. None of this has a user-visible display or FFI
   change yet, and no shim is retired yet. What remains: nested aggregate
   field views (a struct field that is itself a struct, or a static array
   inline field — the "no nested-struct or array-typed field composition"
   gaps noted above), then the interpreter call site (`impl.d`/`Walker`/
   `Value`) that actually gives these types somewhere to be used instead of
   sitting unwired, and only after that, shim retirement one `interpreter.md`
   §9.10 entry at a time, each proven by its ratchet fixtures staying green
   through the real path. Class objects stay third in the migration order,
   per the "Migration order" bullet above. Latency is measured only once the
   array and struct correctness gates are green and a real suite actually
   reaches native storage; item 6 already showed the benchmark suite never
   crossed the old marshaller seam. Until then, native layout is justified by
   the correctness ceiling (`&local`, unions, reinterpret casts, slices into
   locals), not by a benchmark.

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
  display parity goes through `bytecode.md` slice 11 (decision 2026-07-07).
  When a display change collides with a bytecode-pinned row, apply the
  matrix rule (drop the engine from that block, record the pending re-earn)
  rather than extending bytecode display scaffolding.
