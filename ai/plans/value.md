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
  Quickbite's DMD frontend stamps a static `Type` on every node, so the tag is
  redundant for type safety. An interpreter-private box still has a narrower
  benefit as the uniform D type returned by `eval(Expr)`, especially for
  immediate scalar results. That expression currency is distinct from the
  authoritative storage of an addressable guest value.

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

Decision 2026-07-13: "boxed scalars stay" means **immediate scalar expression
results**, not boxed-only scalar lvalue storage. `runExpression` may keep
returning an interpreter-private uniform value with inline scalar arms: forcing
every transient arithmetic result through a native block would add loads,
stores, and bookkeeping, and the current scalar arms do not recursively box or
allocate one GC object per value. Addressable storage has a different contract.
Once `&local` or another operation makes a scalar location observable, it must
have one stable native cell that is authoritative for direct reads and writes,
pointer dereferences, byte reinterpretation, `memcpy`, and FFI. Do not create a
boxed snapshot and reconcile it through writeback.

Whether every scalar local starts in a native slot or an unaddressed scalar
local starts immediate and is promoted when its address becomes observable is
an empirical latency choice. Prefer the simpler eager-slot design unless a
measurement justifies lazy promotion; if promotion is used, every subsequent
direct or indirect access must use the promoted cell. A scalar rvalue passed to
libffi may still need one fixed-width leaf copy into an ABI cell, while a stable
scalar slot may hand over its address directly. Neither case is recursive
aggregate marshalling.

Decision 2026-07-13 (execution/display separation): do not preserve
`Value runExpression(Expression)` as an architectural contract merely because
the current tree walker has that signature. The walker does need a recursive
expression-result operation: unittests execute ordinary expressions, and
nested interpreted functions must return results to their callers. Its carrier
is interpreter-private execution machinery, not a display value. Its required
shape follows the representation: immediate scalar results, native aggregate
handles, native locations/references, callables, and the remaining interpreter
metadata. `RuntimeValue` is a descriptive name, not a prescribed new shared
type.

Top-level unittest execution and REPL evaluation are separate consumers. The
unittest path needs only success or a diagnostic and must not render the
walker's final result. The REPL expression path synthesizes
`__quickbiteFormat(expr)` and returns that guest-produced string through
`EvalResult`. The current `TreeNodeBackend.runUnitTest -> eval(FuncDeclaration)
-> displayString` bridge is interim scaffolding: replace it with a direct
unittest execution entry point while retaining a separate REPL evaluation
entry point. This removes display work from the project's latency-critical
unittest path; it does not remove expression evaluation inside a unittest.

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
  survey's universal shape inside the tree-walker: immediate boxed scalar
  expression results, native storage for addressable locations, and
  native-layout aggregates/arrays behind a handle reusing DMD offsets. See
  remaining-work item 7.

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

Correction (2026-07-09, see the "ownership vs GC-visibility" note
below): the paragraph above keyed the scanned-destination check on
this array's own block being `owned` (`Ownership`), and exempted a
*borrowed* source address on the grounds that it "is not GC memory the
collector tracks in the first place." That was false once
`NativeBlock.subRange` existed: a sub-range is `borrowed` but can still
be live GC memory (e.g. a struct's inline array field), so a borrowed
sub-range's address sailing through into an unscanned destination was
exactly the hazard this check exists to prevent. The check is now
keyed on the mechanical fact `GC.addrOf(_block.address) !is null`, not
on `Ownership`; the two cases that stay legal despite an unscanned
destination are a null block address (a zero-length array) and a
genuinely non-GC source address (`malloc`'d/FFI memory) -- a borrowed
sub-range of GC memory now throws. See the Status "ownership vs
GC-visibility" note below for the full account and the regression
tests that pin it.

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

Progress 2026-07-09 (nested aggregate field views): the two remaining
"Storage shape" gaps just above are closed for the *view* case (reading
an existing field as its own handle, not allocating new storage). Both
are proven true now: a struct-typed field (`struct Outer { int a; Inner
inner; }`) is a sub-range of `Outer`'s one block at DMD's own offset for
`inner`, laid out with `Inner`'s own field offsets relative to that
sub-range, not to `Outer`'s block from byte 0; a static-array-typed field
(`struct Holder { int[3] xs; }`) is 12 bytes inline in `Holder`'s block,
not a slice header (`Holder.sizeof == 12` is the host-compiler oracle for
that -- a slice-header field would make it 16), viewed as a `NativeArray`
over the same bytes. Both alias the parent: a write through the nested
view lands in the parent's bytes and vice versa, and neither allocates a
byte.

The new surface: `NativeBlock.subRange(byteOffset, byteLength) @safe`,
`NativeStruct.structField(index) @safe -> NativeStruct`, and
`NativeStruct.arrayField(index) @safe -> NativeArray`, plus
`layout.staticArrayLength(TypeSArray) @safe` and a new `NativeArray.
adopt(block, elementType, length) @safe` factory that wraps an existing
block instead of allocating one (needed because `arrayField` must hand
back an array *over* the struct's own sub-range, not a fresh
allocation).

`subRange` is the answer to "what does a block that is a sub-range of
another block look like": it slices `_bytes` with ordinary
bounds-checked D (no raw pointer, unlike `borrow`), and is reachable only
through this `@safe` factory, never through the `@system` raw-pointer
`borrow` path -- deriving a sub-slice of an existing `ubyte[]` needs no
unsafe cast, so routing it through `borrow` would have been a strictly
worse boundary. Its `Scan` is carried forward from the parent unchanged:
`Scan` is an attribute of the whole underlying GC allocation (whether the
collector scans it on collect at all), not of any particular sub-range
of it, so a sub-range has no legitimate way to disagree with its parent
about that. Its `Ownership` is `borrowed`: a sub-range is not an
independent allocation and cannot legitimately be grown or reallocated in
place (`GC.extend`/`GC.calloc` operate on whole allocations, not a byte
range in the middle of one), which is exactly `borrowed`'s existing
contract -- "memory owned elsewhere; the owner keeps it alive" -- with
the owner here being the parent block itself (or, one level further out,
whatever the parent itself borrowed from). Reusing `borrowed` rather than
inventing a third `Ownership` value means `NativeArray.reserve`'s existing
refusal to reallocate a borrowed block applies correctly to a sub-range
for free.

Correction (2026-07-09, see Status's "ownership vs GC-visibility" note
below): the sentence above originally claimed "every existing
borrowed-block guard ... already applies correctly to a sub-range for
free, with no new code." That was false. `reserve`'s guard was the only
one; `NativeBlock.tryExtendTo` and `trueByteSize` had none, and both had
to grow one of their own once `borrowed` covered both non-GC foreign
memory and interior views of an owned GC allocation. Worse, `writeSlice
Header`'s scanned-destination check was keyed on `Ownership` as a proxy
for "not GC memory," which a zero-offset sub-range quietly falsified. A
review (not a test) caught this; see the Status note for the full
account and the four guards it repaired.

That choice makes `trueByteSize`/`capacity` honest for an interior view
without any extra guarding: `GC.sizeOf` on an interior pointer (not the
head of an allocation) returns 0 by its own documented contract, so a
non-zero-offset `subRange`'s `trueByteSize` is pinned at 0 -- the same
honest "I don't know" a borrowed block already reports, not the parent's
true size, which would otherwise mislead a caller like `NativeArray.
capacity` (which divides `trueByteSize` by stride) into believing a
sub-range has room to grow in place when it does not. Nothing new had to
enforce that; it falls out of `Ownership.borrowed` plus `GC.sizeOf`'s own
contract.

The static array's element count comes from `TypeSArray.dim.toUInteger()`
(wrapped in a `@trusted` boundary, `Expression.toUInteger` not being
`@safe`/`pure`/`nothrow`), not from `typeByteSize(fieldType) /
typeByteSize(elementType)`. Both give the same answer for every real
static-array type (D packs array elements back-to-back with no
inter-element padding), but `dim` is the one DMD field that IS the
element count, where the division is an indirect re-derivation through
two other DMD numbers plus an assumption about packing. Reading `dim`
directly keeps DMD as the single source of truth for this fact, exactly
as `fieldByteOffset` already reads `VarDeclaration.offset` directly
rather than re-deriving it.

Test correction in the same commit: the pre-existing
`writeSliceHeaderIntoSliceFieldReinterpretsAsHostCompilerSlice` test's
`GC.collect` and nested scope are removed. D's GC conservatively scans
the stack and registers, so a collect afterwards cannot distinguish "the
element block is kept alive by the scanned struct field" (the property
under test) from "a stale pointer bit-pattern happens to still sit in an
unreused stack slot" -- it would pass even with a wrong scan policy,
proving nothing, and is flaky by construction. The real, deterministic
test of the scan policy is `allocate.pointerBearingFieldYieldsScannedBlock`,
which already asserts `Scan.conservative` directly. What remains is
honestly just a header-round-trips-as-a-host-slice test, which is what
it is now documented as. The same test's `elements.element(i)[0] = ...`
byte-0-only writes are also replaced with full 4-byte int stores, since
writing only the first byte of a 4-byte `int` is endian-dependent (and
was relying on the rest of the block already being zeroed).

Still not done: dynamic-array-field *read-back* (reading an existing
slice-header field back as a `NativeArray` over its pointed-to element
block -- distinct from writing one, which already existed, and from the
sub-range views added here, since a slice header points at a separately
tracked block rather than being inline); class objects; the interpreter
call site (`impl.d`/`Walker`/`Value`); and every `interpreter.md` §9.10
shim. The interpreter still boxes everything; none of this native
storage has a caller yet.

Progress 2026-07-09 (ownership vs GC-visibility): a review of the nested-
aggregate-field-views commit (not a test -- nothing here was caught by
the suite) found that `NativeBlock.subRange` broke an assumption every
earlier borrowed-block guard had quietly relied on. `Ownership` used to
mean two things at once: "may this block be reallocated/extended?" and,
as a proxy, "is this address memory the GC can lose track of?" Those
coincided as long as the only route to `Ownership.borrowed` was
`NativeBlock.borrow`, wrapping genuinely non-GC (FFI/host) memory.
`subRange` produces `borrowed` blocks that ARE live GC memory -- an
interior or, worse, a zero-offset (base-pointer) view into an owned
allocation -- so every guard keyed on `ownership == borrowed` as a stand-
in for "not GC memory" was now answering the wrong question for a
sub-range.

The model is resolved as: `Ownership` answers exactly "may we
reallocate/extend this block?" (`owned` = yes, `borrowed` = no). Whether
an address is GC-visible is a separate, mechanical fact, read from
`core.memory.GC.addrOf` (non-null for a pointer into any GC allocation,
including an interior pointer, which resolves to the allocation's base)
and never inferred from `Ownership`. `borrowed` now honestly covers two
different things -- genuinely non-GC foreign memory, and an interior
view of a GC allocation the view itself cannot independently grow -- and
no code may assume those are the same case.

Four guards had to be repaired, none of them caught by the existing
suite before this review:

- `NativeBlock.tryExtendTo` had no `Ownership` guard at all. `GC.extend`
  resolves a pointer via the allocator's own page lookup, not via this
  handle's `Ownership`, so it could genuinely extend a large-object
  parent through a zero-offset `subRange`, and the subsequent zeroing of
  the "new" tail would zero the parent's own live bytes. Now returns
  `false` immediately for `Ownership.borrowed`.
- `NativeArray.adopt` took a caller-supplied `length` without routing it
  through the overflow-checked `byteLength(length, stride)` helper
  `allocate`/`borrow` already use, and never checked the result fit the
  adopted block. That revived the `element` index-wrap bug fixed earlier
  (post-merge) for `allocate`: an oversized `length` let a wrapping
  `index * stride` alias a different element instead of failing. `adopt`
  now computes and checks `byteLength` itself.
- `NativeArray.writeSliceHeader`'s scanned-destination check threw only
  when the source block was `owned`; a borrowed sub-range's live GC
  address sailed through into an unscanned destination, making the
  parent block collectable while still reachable only through unscanned
  bytes. The check is now keyed on `gcAddrOf(_block.address) !is null`,
  not on `Ownership`.
- `NativeBlock.trueByteSize` relied on `GC.sizeOf` returning 0 for an
  *interior* pointer to stay honest for a borrowed sub-range -- but a
  zero-offset `subRange`'s address IS the parent's base pointer, and
  `GC.sizeOf` reports the bin size for a base pointer, not 0. That made
  `NativeArray.capacity` claim phantom growth room on a block `reserve`
  would still (correctly) refuse to grow. `trueByteSize` now returns 0
  for `Ownership.borrowed` explicitly, rather than depending on the
  interior/base distinction.

Each hole now has a regression test: `NativeBlock.tryExtendTo.
borrowedSubRangeReturnsFalseAndLeavesParentBytesUntouched`; `NativeArray.
adopt.lengthTimesStrideExceedingBlockByteLengthThrows` and `.
wrappingLengthThrowsInsteadOfRevivingElementIndexWrapBug`; `NativeArray.
writeSliceHeader.borrowedSubRangeOfGCMemoryIntoNoScanDestinationThrows`
(and `NativeStruct.arrayField.
writeSliceHeaderOfBorrowedSubRangeIntoNoScanDestinationThrows` for the
composed struct-field path); `NativeBlock.subRange.
zeroOffsetTrueByteSizeIsZero` and `NativeStruct.arrayField.
capacityIsZeroForZeroOffsetSubRangeView`. The pre-existing
`writeSliceHeader.borrowedSourceAddressIntoNoScanDestinationIsLegal` test
used `new int[3]` as its "not GC memory" fixture, which is itself GC
memory and only passed because the old check consulted `Ownership`; it
is renamed
`borrowedNonGCSourceAddressIntoNoScanDestinationIsLegal` and its fixture
switched to `malloc`/`free`, so it now pins what it always claimed to.

Two standing claims elsewhere in this plan were false and are corrected
in place rather than repeated here: the "nested aggregate field views"
progress note above no longer claims every borrowed-block guard applied
to a sub-range "for free, with no new code" (only `reserve`'s did); and
"Remaining work" item 7's "Next PR" progress paragraph no longer lists
nested aggregate field views as remaining work now that this commit
(and its predecessor) delivered them.

Progress 2026-07-10 (dynamic-array-field read-back): item 7's last named
"what remains" item -- reading an existing slice-header field back as a
`NativeArray`, distinct from writing one (`NativeArray.writeSliceHeader`)
and from the sub-range views (`NativeStruct.structField`/`arrayField`) --
is done. `NativeStruct` gains `sliceField(index) @system -> NativeArray`.
`index` is bounds-checked against `fieldCount` first, matching every other
field accessor's discipline; a field whose type is not `TypeDArray`
(`Type.isTypeDArray` returns null) throws its own message before any
header bytes are read, exactly the shape `structField`/`arrayField`
already use for their own wrong-type field.

Unlike `structField`/`arrayField`, this is NOT a `NativeBlock.subRange` of
the parent's own block: a slice header's `ptr` names a separately tracked
allocation somewhere else entirely (wherever `writeSliceHeader` last wrote
it from), so the only way to view "the elements this field currently
points at" is to read the `{ length, ptr }` bytes back out of the field
and reconstruct a handle from them -- `NativeArray.borrow`'s job, under
the same caller-enforced, unverifiable precondition `borrow` already
documents (the precondition here is vouched for by whoever last wrote a
valid header into the field, typically `writeSliceHeader` itself). That
unverifiable reconstruction is why `sliceField` is `@system`, unlike
`structField`/`arrayField`, which only ever slice an already-verified
block with ordinary bounds-checked D. The raw two-value read itself --
`memcpy`, not a pointer-typed load, for the same alignment reason
`writeSliceHeaderBytes` gives, since a field's byte offset is not
guaranteed `size_t`-aligned -- lives behind a small private helper,
`readSliceHeaderBytes`, marked `@trusted` rather than `@system`: copying
two fixed-size values out of an already bounds-checked byte range into
local storage cannot itself violate memory safety no matter what bit
pattern they contain, since it never dereferences the pointer it reads.
Only USING that pointer to reconstruct a slice (`NativeArray.borrow`) is
where the actual, unverifiable trust happens, and that call stays inside
`sliceField` itself, not the helper.

The contract, spelled out: a zero-length/null header (`{ length: 0,
ptr: null }` -- a struct's zero-initialised block before anything ever
wrote to the field) reads back as a real, empty `NativeArray`;
`NativeArray.borrow(elementType, null, 0)` is legal for the same reason
`NativeBlock.borrow`'s own null/zero-length case already is. The returned
array's `ownership` is always `borrowed` -- this field does not own the
element block, it only names it, so `reserve` on the returned handle
throws exactly as for any other borrowed array. Its `scan`/`capacity` are
`Scan.no`/`0` unconditionally, per `NativeBlock.borrow`'s own contract --
even when the pointed-to block is a real, conservatively-scanned GC
allocation the struct field itself keeps alive (per `writeSliceHeader`'s
scanned-destination contract, that is the only way the field could
legally hold a live GC pointer at all). That is not dishonest:
`NativeBlock.borrow` cannot know, from a bare pointer/length pair, that
the memory it wraps happens to be GC memory this same interpreter also
owns elsewhere -- it makes the same conservative "assume nothing" choice
for every borrowed block, GC-backed or not. Who keeps the element block
alive is unchanged by any of this: the struct field itself, via the GC's
own scan of it (or, for an unscanned struct, whatever else references
it) -- never the returned handle, which has nothing of its own to grow or
free. Finally, this aliases rather than snapshots: the returned
`NativeArray` wraps the SAME address `writeSliceHeader` wrote, so a write
through the read-back handle is visible through the original array and
vice versa, for as long as the field's header keeps pointing at that
address; nothing here re-reads the field on later access, so a read-back
handle goes stale exactly like any other stale pointer once the field is
overwritten or the element block moves.

Regression tests, in `tests/ut/backends/interpreter/native_struct.d`:
`NativeStruct.sliceField.roundTripAliasesWriteSliceHeaderSourceArray`
(write through the read-back handle observed through the original
`NativeArray`, not a copy); `.readBackArrayReportsBorrowedOwnershipAnd
NoScanRegardlessOfElementBlockScanPolicy` (the ownership/scan/capacity
honesty above, pinned directly rather than inferred from a `GC.collect`
-- per this plan's own "ownership vs GC-visibility" note, a
collect-survival test cannot distinguish a correct scan policy from a
stale stack bit pattern, so it is deliberately not used here); `.
nonZeroOffsetMatchesHostCompilerSliceLeavingSiblingFieldUntouched`
(`struct Header { long tag; int[] xs; }`, exercising `fieldByteOffset`
for real and confirming the sibling field is untouched, against the host
compiler's own `Header.xs`); `.
zeroLengthNullHeaderReadsBackAsEmptyBorrowedArray`; `.
outOfRangeIndexThrows`; and `.indexOfStaticArrayFieldThrows`.

Still not done: no `impl.d`/`Walker`/`Value` wiring, no `interpreter.md`
§9.10 shim retired, no class objects. The interpreter still boxes
everything; none of this native storage has a caller yet.

Progress 2026-07-10 (array sub-slicing): item 7's correctness-ceiling
"slices into locals" gets its handle-level expression. `NativeArray` gains
`slice(begin, end) @safe -> NativeArray`, the handle a guest `xs[1 .. 3]`
must become: a real, aliasing view over the SAME element block at `begin *
stride`, never a copy -- a write through the returned handle is visible
through the original array and vice versa, for as long as both stay live.

Unlike `NativeStruct.sliceField`, `slice` stays `@safe`. It derives a
sub-range of an existing, already-verified block with ordinary
bounds-checked D -- exactly `NativeBlock.subRange`'s own "nested aggregate
field" argument (see its comment), applied here to a sub-range of elements
rather than a sub-range of struct fields -- so it routes through
`subRange`, never through the `@system` raw-pointer `NativeBlock.borrow`
path a slice-header reconstruction like `sliceField` needs.

Bounds: `begin <= end <= length`, each its own thrown `Exception`, checked
before either is multiplied by `_stride`. No extra overflow check is
needed on `begin * stride`/`end * stride`: every construction path
(`allocate`, `borrow`, `adopt`) already routes `length * stride` through
the overflow-checked `byteLength` helper -- `element`'s own comment makes
the identical argument -- so once `end <= _length` holds, `end * _stride
<= _length * _stride` is provably wrap-free, and `begin <= end` then makes
`begin * _stride <= end * _stride` wrap-free too, bounded by that same
already-wrap-free product. `scan` is carried forward from the parent block
by `subRange` unchanged, not re-derived. The handle itself is built with
`NativeArray.adopt` over `subRange`'s block, which re-checks `length *
stride` fits, rather than constructed by hand.

The returned array is `Ownership.borrowed`: a sub-range is not an
independent allocation, so `reserve` on it throws and `capacity` is 0,
exactly as for any other borrowed array. That is the honest answer today,
and it is deliberately not modelling one thing: compiled D lets you append
to a slice (`xs[1 .. 3] ~= x`), which reallocates a NEW block for the
RESULT rather than growing `xs` in place, and leaves `xs` itself untouched.
That guest-level `~=` semantics is a question for whatever interpreter
call site eventually evaluates `~=` on a `NativeArray` handle -- build a
fresh owned array and rebind the guest variable to it, exactly as compiled
D does -- not for this container: `reserve` throwing on a borrowed handle
is the correct low-level primitive regardless of what a higher-level guest
operation later decides to do about it. There is no such call site yet.

`begin == end` (including `begin == end == length`, D's legal `xs[$ ..
$]`) is legal and returns a real zero-length array. Its block's address is
NOT null the way a zero-length *allocated* array's is (`NativeBlock.
allocate` routes through `GC.calloc(0, ...)`, which returns `null`):
`subRange` slices `_bytes`, so a zero-length sub-range's address is `begin
* stride` bytes past the array's own base -- for `begin == length`, a
past-the-end pointer, still a valid (if unused) address inside or just
past the parent's real GC allocation. Whether `core.memory.GC.addrOf` of
that address resolves as GC-visible (the fact `writeSliceHeader`'s
scanned-destination check asks, should some later caller pass this handle
to it) is not a fixed answer -- `addrOf` resolves an interior pointer to
its allocation's base, so it depends on how much slack the GC's bin
rounding left past the block's own live bytes. This was checked against
druntime rather than assumed: a small raw-`GC.calloc` probe script
(`core.memory.GC.addrOf` on the past-the-end pointer of a 12-byte and a
16-byte allocation) showed a 12-byte block's past-the-end pointer resolves
non-null -- the 16-byte bin it rounds up to leaves 4 bytes of slack -- while
an exactly-16-byte block's resolved null in that same probe run. That is
what was actually observed, not a general property of zero-slack blocks:
with no slack left, the past-the-end pointer lands exactly at the NEXT
bin's own base address, so `GC.addrOf` of it resolves non-null whenever
that neighbouring bin happens to be live, and null only because the probe's
neighbouring bin was free at the time. `slice`
itself never asks this question -- it only calls `subRange`/`adopt`,
neither of which touches `GC.addrOf` -- so this is not a decision `slice`
makes, only a fact worth pinning rather than assuming for whichever caller
later passes the resulting handle onward. Pinned directly with
`NativeArray.slice.
emptyEndSliceBlockAddressResolvesToParentBaseUnderCurrentBinSlack`, using
this test file's usual 3-`int32` fixture (12 live bytes, 16-byte bin, 4
bytes of slack).

Regression tests, in `tests/ut/backends/interpreter/native_array.d`:
`NativeArray.slice.writeThroughSliceIsVisibleReadingParentAtBegin` and `.
writeThroughParentAtBeginIsVisibleReadingSlice` (aliasing, both
directions); `.lengthIsEndMinusBegin`; `.
elementZeroSharesAddressWithParentElementAtBegin`; `.
reportsBorrowedOwnership`; `.capacityIsZero`; `.reserveNonZeroThrows`; `.
scanMatchesParentForPointerBearingElementType`; `.
beginGreaterThanEndThrows`; `.endGreaterThanLengthThrows`; `.
emptySliceAtEndOfArrayIsLegalAndZeroLength` and `.
emptySliceInMiddleOfArrayIsLegalAndZeroLength`; `.
emptyEndSliceBlockAddressResolvesToParentBaseUnderCurrentBinSlack` (the GC-
visibility fact above); and `.sliceOfSliceComposesOffsets` with `.
sliceOfSliceWriteIsVisibleInOriginalArray` (a slice of a slice: offsets
compose automatically, since `NativeBlock.subRange`'s `byteOffset` is
already relative to the calling block's own -- possibly already sliced --
`_bytes`, so no separate accumulation is needed). No test relies on `GC.
collect` to prove liveness, per this plan's own "ownership vs
GC-visibility" note: a collect-survival test cannot distinguish a correct
scan policy from a stale stack bit pattern.

Still not done: no `impl.d`/`Walker`/`Value` wiring for `slice` (no guest
`xs[1 .. 3]` expression reaches it yet), and no guest-level `~=`
reallocation semantics for a sliced array, per the "what this does NOT
model" paragraph above.

Progress 2026-07-10 (unions and overlapping fields): item 7's last named
open question for the native-layout handles -- "unions and overlapping
fields, which the conservative whole-range root policy handles but the
layout model does not yet describe" -- is closed. A D `union` is a
`TypeStruct` whose `sym` is DMD's `UnionDeclaration`
(`dmd.dstruct.UnionDeclaration extends StructDeclaration`, adding nothing
to `fields`/`structsize`/`hasPointerField`, only overriding `kind()`), so
every existing `NativeStruct` accessor (`allocate`, `field`, `structField`,
`arrayField`) already operates on it unmodified: none of them branch on
struct-vs-union, they only ever read DMD's own per-field `offset`/byte-size
for whichever index is asked for. `structTypeOf` (`tests/ut/backends/
interpreter/package.d`) also needed no change to find a top-level `union`:
its search loop's `member.isStructDeclaration` is DMD's own classifier,
and DMD defines `isStructDeclaration` to accept a `DSYM.unionDeclaration`
node too (`dsymbol.d`), so it already matched. This was verified
empirically, not assumed: see the new tests below, all green with zero
production-code changes.

What DMD actually reports, checked against `dmd.dsymbolsem`'s
`placeField`/`checkOverlappedFields` and confirmed by the tests: for a
top-level `union U { size_t i; void* p; }`, every member's
`VarDeclaration.offset` is 0 (`placeField`'s `isunion` parameter suppresses
advancing `nextoffset` after each member, so every member starts placement
from the same, unmoved offset), and `layout.typeByteSize` gives the
union's own `structsize` -- the size of its largest member, since
`placeField` still grows `aggsize` to each member's own `offset + memsize`
even though `nextoffset` itself never advances. For overlapping fields
inside an ordinary struct -- an anonymous union, `struct S { int tag;
union { int i; float f; } }` -- DMD does not nest a second `TypeStruct`:
`AnonDeclaration.setFieldOffset` recurses into the anonymous union's own
members with the SAME enclosing `ad`, resetting its own `FieldState.
offset` back to the anonymous union's own base offset after each member,
so `i` and `f` are flattened directly into `S.fields` as two more
top-level fields (`S.fields.length == 3`: `tag`, `i`, `f`), at the same
offset as each other and different from `tag`'s. The authoritative overlap
fact is DMD's own `VarDeclaration.overlapped`/`overlapUnsafe`
(`dsymbolsem.d`'s `checkOverlappedFields`, run once the aggregate's size is
finalised, comparing every field pair's own offset/size range) -- `i` and
`f` both read `overlapped == true`, `tag` reads `false`. Per item 7's
guardrail, `NativeStruct` does not consume `overlapped` itself and gains
no accessor for it: `field`/`fieldByteOffset` already return DMD's own
`offset` verbatim for whichever index is asked for, which is what makes
two fields alias in the first place -- `overlapped` is a derived fact ABOUT
those offsets, not a second, independent source of truth a correct
implementation needs to consult. Inventing an `isOverlapped` reader with no
caller would be exactly the "speculative surface" this plan's phases have
consistently avoided elsewhere.

Scan-policy rounding: a union `{ size_t i; void* p; }` has a pointer
member, so `layout.typeHasPointers` (DMD's `hasPointerField`, OR'd across
every field regardless of overlap) reports true, and `NativeStruct.
allocate` picks `Scan.conservative` -- exactly the choice it already makes
for any struct with a pointer field, with no union-specific branch. That is
the only safe rounding, reasoned from the two failure directions: scanning
`i`'s bytes as a possible pointer when `i` is really an unrelated `size_t`
is a false positive -- at worst the GC retains some address-shaped integer's
accidental target a little longer than strictly needed, which is wasteful
but never unsound. Rounding the other way -- `Scan.no`, because some member
of the union is a non-pointer scalar -- would be a false negative: whenever
`p` is the union's live member, its target becomes invisible to the
collector and can be freed while `p` still points at it, a genuine
use-after-free. A `NativeBlock`'s `Scan` attribute covers its whole byte
range, not a per-member choice, so it cannot be selectively right for both
interpretations of the same bytes at once; it must round toward the safe
failure mode (over-retain) rather than the unsafe one (collect-while-
reachable). This is exactly why the block-wide `Scan` attribute -- rather
than some future per-field scan map -- is what makes the safe rounding
automatic: there is no code path left that could pick `Scan.no` for a
pointer-bearing union member, because the attribute is decided once, at
`allocate`, from `typeHasPointers` over the whole type.

Regression tests, in `tests/ut/backends/interpreter/native_struct.d`:
`NativeStruct.allocate.unionFieldOffsetsAreAllZeroMatchingHostCompilerOffsetof`,
`.unionByteSizeMatchesHostCompilerSizeof`, and
`.unionWithPointerMemberYieldsScannedBlock` for the plain-union facts above
(oracle: a `union U { size_t i; void* p; }` declared directly in the test
module, using `U.i.offsetof`/`U.p.offsetof`/`U.sizeof` exactly as the
existing struct tests use `S.b.offsetof`/`S.sizeof`); `NativeStruct.
field.writeThroughOneUnionMemberIsVisibleThroughTheOther` for the aliasing
claim (a write through `field(0)` is visible through `field(1)`, both
being the same 8 bytes at offset 0); and, for the anonymous-union case,
`NativeStruct.allocate.
anonymousUnionMembersAreFlattenedIntoParentFieldsAtOverlappingOffsets`,
`.anonymousUnionMembersAreMarkedOverlappedByDmdItself`, and `NativeStruct.
field.
writeThroughOneAnonymousUnionMemberIsVisibleThroughTheOtherTagUntouched`
(oracle: `struct WithAnonymousUnion { int tag; union { int i; float f; } }`,
using `WithAnonymousUnion.i.offsetof`/`.f.offsetof` the same way -- D
promotes anonymous-union member names into the enclosing struct's own
scope, so the host compiler still gives a direct `.offsetof` oracle for
each). The full focused `ut.backends.interpreter` suite passes, with zero
production-code changes: this progress note only pins facts the existing
`layout.d`/`native_struct.d` code already got right.

Still open, narrower than before: a union member that is itself an
aggregate (a struct- or array-typed member of a union, viewed through
`structField`/`arrayField` on a `NativeStruct` built over the union's own
type) has no dedicated pinning test yet. By inspection `structField`/
`arrayField` have no struct-vs-union branch -- they only ever consult
`_fields[index]`'s own DMD offset and type -- so this composition is
expected to already work the same way struct-in-struct nesting does, but
it has not been exercised the way the facts above were.

Progress 2026-07-10 (array length assignment): `NativeArray` gains
`setLength(n)`, the handle-level primitive behind a guest `arr.length = n`,
built on the existing `capacity`/`reserve`/`tryExtendTo` machinery rather
than re-deriving it. This is item 7's last named container primitive for
the array phase; it is also the last thing standing between
`interpreter.md` §9.10's `gc_*` capacity-hook shims and retirement, since
those shims exist only because boxed interpreter arrays were never
addressable GC blocks.

The contract was established by reading compiled D's own
`_d_arraysetlengthT`/`_d_arraysetlengthT_` (`core/internal/array/
capacity.d`, local druntime source) and `_d_arrayappendcTX_`
(`core/internal/array/appending.d`), plus a compiled probe script, rather
than assumed. Shrink (`n <= _length`) is a pure length change: the block's
address, `capacity`, and every byte (even ones now past the new length)
are untouched -- matching `_d_arraysetlengthT_`'s own shrink path exactly
(`arr = arr[0 .. newlength]`, no GC call at all). This is also why compiled
D's `arr.length--; arr ~= x;` footgun is real: `_d_arrayappendcTX_` can
reuse that untouched tail in place via `gc_expandArrayUsed`'s "used size"
bookkeeping, with no zeroing of its own, unlike `setLength`'s own grow path.

Grow (`n > _length`) always zeroes every byte from the OLD `_length *
stride` up to the new `n * stride`, regardless of whether the block itself
needed to grow to hold them. This is NOT implied by `reserve`'s own
zeroing: `reserve` only zeroes bytes past whatever `block.byteLength` was
when IT ran, and a shrink never touches `block.byteLength` -- so a
grow-back after a shrink re-exposes stale bytes from before the shrink,
not room `reserve` ever zeroed. Compiled D's `_d_arraysetlengthT_` only
reaches this zeroing for a zero-init element type: the call is gated,
`static if (__traits(isZeroInit, T)) memset(cast(void*)
(cast(ubyte*)newdata + oldsize), 0, newsize - oldsize)`
(core/internal/array/capacity.d, local druntime source, ~line 338); a
non-zero-init `T` instead gets `T.init` emplaced (or memcpy'd) into each
new element -- e.g. `char`'s `0xFF`, `float`'s `NaN` -- never a zero
byte. `setLength`'s own grow path zeroes every new byte unconditionally,
regardless of element type: a defensible container-level choice that
matches `NativeBlock.allocate`'s own calloc-zeroed model, but it agrees
with compiled D's behaviour only for zero-init element types -- which is
every current fixture's element type. Making a guest `char[]` grow
expose `0xFF` rather than `0`, to match `SystemLinker`, is left as an
open question for whatever future interpreter call site actually wires
`setLength` up; it is not this container's job, and this PR does not
answer it. Pinned against a compiled probe on `int[]` (a zero-init
element type, so it does not exercise the non-zero-init gap above):
shrinking `[1, 2, 3, 4, 5]` to length 2 then growing back to 5 reads
back `[1, 2, 0, 0, 0]`, never the original `3, 4, 5`. `setLength.
shrinkThenGrowBackRezeroesStaleBytesWithoutReallocating` pins this without
reallocating (`_block.byteLength` already covered the regrown span).

Whether an OWNED handle's block itself needs to grow is decided by
`requiredBytes > _block.byteLength` -- deliberately NOT `n > capacity`. The
two differ exactly when it matters: after a shrink, `_block.byteLength`
still covers the pre-shrink span, so growing back within it needs no
reallocation regardless of what `capacity` (the GC's own bin size divided
by stride -- a different, unrelated bound) would say. When `_block.
byteLength` is genuinely exceeded, growth reuses `reserve`'s own
reallocating machinery, factored out into a private
`growBlockTo(requiredBytes)` shared by both callers -- a pure,
behaviour-preserving extraction; `reserve`'s own tests are unchanged.

The borrowed decision, corrected by review (2026-07-10, findings 3 and 10):
growth on a `borrowed` handle now throws unconditionally, regardless of
`_block.byteLength`. This note originally documented a different rule --
growth allowed whenever `requiredBytes <= _block.byteLength`, on the
reasoning that a `NativeArray.slice` result's own block span is bytes
`subRange` had already verified belong to the handle, so reusing them
needed no reallocation and violated no ownership claim. That reasoning was
false: `slice` is a real, bidirectional aliasing view, so growing a
SHRUNK child slice back within its own span re-zeroed bytes the PARENT (or
a sibling slice over the same block) still considered live -- exactly what
this note's own regression test demonstrated (`setLength.
onSliceGrowWithinBlockByteLengthSucceedsAndIsVisibleInParent`, since
renamed to `.onBorrowedShrinkThenGrowBackThrows` -- see below). The old
rule also directly contradicted `NativeArray.adopt`'s and `NativeStruct.
adopt`'s own documented promise that a block's slack bytes beyond what a
handle claims "are none of this factory's business": a borrowed handle
reaching into bytes beyond what it was itself given, because a DIFFERENT
handle over the same block happened to claim them first, is exactly that
promise being broken. "No byte belonging to some OTHER, uninvolved handle
is ever at risk" -- this note's own original closing claim for the old
rule -- was the false statement review caught; the shrink-then-grow-back
test is itself the counterexample.

Re-checked against compiled D rather than assumed which behaviour is
actually right: a guest `s.length = n` growing a slice does NOT reuse the
parent's storage in general. `_d_arraysetlengthT_` reaches
`gc_expandArrayUsed`, whose real implementation, `expandArrayUsed`
(`core/internal/gc/impl/conservative/gc.d`, ~line 1491), only succeeds when
the stored allocation-length matches the slice's own current length --
`__setArrayAllocLengthImpl`'s old-length comparison
(`core/internal/gc/blockmeta.d`), a CAS-style equality check against the
value already stored for that block. `reserveArrayCapacity` (same file,
~line 1605, used by `reserve`'s own capacity query rather than by
`setLength`'s grow path directly) gates on the textually clearer
`existingUsed != blockUsed` -- the same "only the block's current single
tracked tail owner is extendable in place" principle, spelled out
explicitly. Neither check lives in `core/internal/array/appending.d`,
which only declares/calls the `gc_expandArrayUsed` hook -- this note's
original citation, and a matching one in `tests/ut/backends/interpreter/
native_array.d`, both named that file and have been corrected. Confirmed
against a compiled probe (unchanged from the original check): `a[1 .. 4]`
shrunk to length 1 then grown back to 3 gets a NEW address, and `a` itself
is unchanged -- every other live slice over the same block, including one
that was just shrunk, fails the tail-owner check and gets a brand-new block
instead.

A `NativeArray` handle has no equivalent "am I the current tail owner"
bookkeeping, so it has no sound way to decide which one of potentially
several live borrowed views over the same block is safe to grow into --
meaning no call site could ever have legitimately used the old
grow-within-byteLength branch anyway. This is therefore a deliberate
narrowing of an unwired primitive with no caller, decided by review, not a
loss of any real capability: `setLength` had no call site before this
change and still has none after it (see "still not done" below, unchanged
by this narrowing). Growth-and-rebind of a borrowed handle belongs to
whatever future call site evaluates a guest `s.length = n`, exactly as
`slice`'s own comment already says `~=` does. Growth WITHIN the current
length -- i.e. a shrink, `n <= _length` -- stays legal on a borrowed handle
and remains a no-op on storage, per the shrink paragraph above; only growth
beyond the current length is affected.

Strideless (`NativeArray.init`, `_stride == 0`) mirrors `reserve`'s own
guard, in the same position: checked first, unconditionally, before even
asking whether `n` would grow or shrink anything, so `setLength(0)` on
`NativeArray.init` throws even though `0 == _length` would otherwise make
it a trivial no-op -- the identical ordering rationale `reserve` already
uses (a strideless handle is not a properly constructed array, a more
fundamental defect than any question of growing or shrinking it).
`n * stride` is computed with the existing overflow-checked `byteLength`
helper, never re-derived, and only inside the grow branch.

What this does NOT model: `~=` (append) is still a call-site operation
(allocate-and-rebind), unimplemented, with no call site yet, per the plan.
Also not modelled: keeping a previously written slice header
(`NativeArray.writeSliceHeader`) in sync with a later `setLength` that
reallocates. A header is a snapshot of `{ length, ptr }` taken at write
time, not a live view of this handle; once `setLength` reallocates, any
previously written header still names the OLD address and length, exactly
as stale as any other pointer into a moved block -- compiled D's own
slices go stale the same way once a variable's `.length` is reassigned out
from under an earlier alias. Keeping such a header in sync is the call
site's problem, the moment it rebinds the guest variable this array backs,
not this container's -- there is no such call site yet.

Regression tests, in `tests/ut/backends/interpreter/native_array.d`:
`NativeArray.setLength.growWithinAlreadyReservedCapacityLeavesAddressUnchanged`
and `.growWithinAlreadyReservedCapacityZeroesNewElements` (grow within a
block already committed by an explicit prior `reserve` call -- deliberately
not a bare post-`allocate` `capacity`, since a plain allocation's `GC.
sizeOf` bin-rounding slack is real but is not reflected in `block.
byteLength` without an explicit `reserve`/`setLength` call committing it,
and this container does not claim to use that slack for free); `.
growBeyondBlockByteLengthPreservesElementsAcrossReallocation` and `.
growBeyondBlockByteLengthTailIsZero`; `.shrinkUpdatesLength`; `.
shrinkLeavesAddressCapacityAndBytesUnchanged`; `.
shrinkThenGrowBackRezeroesStaleBytesWithoutReallocating`; `.
sameLengthIsANoOp`; `.onInitHandleZeroThrows` and `.
onInitHandleNonZeroThrows`; `.overflowingLengthTimesStrideThrows`; `.
onBorrowedShrinkSucceedsAndLeavesParentUntouched` and `.
onBorrowedShrinkThenGrowBackThrows` (the borrowed decision, both
directions -- these two supersede and merge in the original `.
onSliceGrowWithinBlockByteLengthSucceedsAndIsVisibleInParent` and `.
onSliceGrowBeyondBlockByteLengthThrows`, both of which asserted the same
throw once the borrowed decision above was corrected). The full focused
`ut.backends.interpreter` suite passes.

Still not done: no `impl.d`/`Walker`/`Value` wiring for `setLength` (no
guest `arr.length = n` reaches it yet), no `interpreter.md` §9.10 shim
retired, and `~=` remains unimplemented per the "what this does NOT model"
paragraph above.

Progress 2026-07-10 (array-of-struct element views): the composition
established for structs (`NativeStruct.structField`/`arrayField`) gets its
missing other direction. Until now a *struct* could view its aggregate
fields as handles, but an *array* could not view a struct-typed element as
one -- `NativeArray.element(index)` only ever handed back a bare `ubyte[]`,
so a guest `Point[] ps; ps[1].x = 3;` had no handle-level expression.
`NativeArray` gains `structElement(index) @safe -> NativeStruct`: element
`index` of an array whose `elementType` is a `TypeStruct`, viewed as a
`NativeStruct` over the SAME bytes, aliasing the array rather than copying
it -- a write through the returned handle is visible in this array's
`element(index)` bytes and vice versa.

`index` is bounds-checked against `length` first, before any offset
arithmetic, reusing `element`'s own wrap-free argument rather than
re-deriving it: every construction path already routes `length * stride`
through the overflow-checked `byteLength` helper, so once `index < _length`
holds, `index * _stride` is provably wrap-free (see `element`'s own
comment). A field whose `elementType` is not a struct
(`Type.isTypeStruct` returns null) throws its own message before any
sub-range is taken. `structElement` stays `@safe`, via `NativeBlock.
subRange` -- never the `@system` raw-pointer `borrow` path -- for exactly
`NativeArray.slice`'s own reason (see its comment): `index * stride ..
index * stride + stride` is a sub-range of an already-verified block,
ordinary bounds-checked D, not a pointer this code would need to
reconstruct and cannot itself verify.

The returned `NativeStruct` is `Ownership.borrowed` and carries the
parent's `Scan` unchanged, both via `adopt`'s own `subRange`-backed
construction: an array element is not an independent allocation, so its
`block.trueByteSize` is 0 and nothing about it can be grown -- correct,
since growing "one element" in place is not a meaningful operation at all;
growing the ARRAY is `NativeArray.reserve`/`setLength`'s job, not this
view's. `Scan` is an attribute of the whole underlying GC allocation, not
of any one element's view into it, so an element view has no legitimate way
to disagree with its parent about it, exactly as for `NativeStruct.
structField`/`NativeArray.slice`.

The one subtlety worth stating: the element's stride is
`typeByteSize(elementType)` -- DMD's own `structsize`, padding included,
computed once at construction and reused as `_stride` rather than
recomputed -- which is exactly why `index * stride` lands on a
correctly-aligned, correctly-sized struct element, and why D packs an array
of structs back-to-back with no inter-element padding beyond each element's
own `structsize`. This was verified against the host compiler rather than
assumed: `structElement.fieldOffsetsAreRelativeToTheElementNotTheArrayBase`
confirms a `Point[3]`'s element 2's field view sits at exactly
`2 * Point.sizeof + Point.x.offsetof` bytes past the array's own base.

Building the returned handle needed a factory `NativeStruct` did not have:
`allocate` allocates, `borrow` takes an unverifiable raw pointer, and
neither adopts an existing, already-verified block. `NativeStruct` gains
`adopt(NativeBlock block, TypeStruct type) @safe`, mirroring `NativeArray.
adopt`'s shape and its "the block already exists at a byte length this
factory did not choose, so check it fits" discipline: `block.byteLength`
must be at least `typeByteSize(type)`, checked and thrown on rather than
trusted, or a struct view over too few bytes would let a field near the end
of `structsize` read/write past the block's own real storage. A block
LARGER than `typeByteSize(type)` is accepted, exactly as `NativeArray.
adopt` accepts a block larger than `length * stride`: the extra bytes are
none of this factory's business, they belong to whatever the block's own
owner uses them for. `NativeStruct.structField` was refactored to build its
own returned handle through `adopt` too -- a genuine simplification, not a
speculative one, since `adopt` already does exactly what `structField` was
constructing by hand (check-then-build over a `subRange`); `NativeStruct.
allocate`/`borrow` were left untouched, since they choose the block's scan
policy themselves and `adopt` deliberately does not (it has no `Type` to
derive one from that isn't already implied by the caller-supplied block).

Regression tests, in `tests/ut/backends/interpreter/native_array.d`:
`NativeArray.structElement.writeThroughElementViewIsVisibleInParentElement
Bytes` and `.writeThroughParentElementBytesIsVisibleThroughElementView`
(aliasing, both directions); `.
fieldOffsetsAreRelativeToTheElementNotTheArrayBase` (the offset-and-stride
claim above, against the host compiler); `.elementTypeNotStructThrows`;
`.outOfRangeIndexThrows`; `.reportsBorrowedOwnership`; `.
blockTrueByteSizeIsZero`; `.scanMatchesParentForPointerBearingElementType`;
and, pinning the composition one level deeper, `.
structFieldViewStillWorksThroughElementView` and `.
arrayFieldViewStillWorksThroughElementView` (a struct-typed array element's
own `structField`/`arrayField` still work through the element view, with
no special case for "my block came from an array element" on either side).
In `tests/ut/backends/interpreter/native_struct.d`: `NativeStruct.adopt.
rejectsBlockSmallerThanStructsize`; `.
byteSizeMatchesHostCompilerSizeofDespitePadding`; `.
acceptsBlockLargerThanStructsize` (the oversized-block decision above,
pinned directly); and `.
viewsExistingBlockSoAFieldWriteIsVisibleAtTheBlocksOwnOffset` (aliasing).
No `GC.collect`-based liveness test was added, per this plan's own
"ownership vs GC-visibility" note. The full focused `ut.backends.
interpreter` suite passes.

Still not done: no `impl.d`/`Walker`/`Value` wiring (no guest `ps[1].x`
expression reaches `structElement` yet), no class objects, and every
`interpreter.md` §9.10 shim remains unretired. Only structs are composed
into arrays this way; the symmetric question for an array-typed array
element (`Point[][]`, or an array of static arrays) has no dedicated
accessor or test yet -- `element(index)` already hands back that element's
raw bytes, but there is no `arrayElement`/`sliceElement` counterpart to
`structElement` the way `NativeStruct` has both `structField` and
`arrayField`/`sliceField` for its own fields.

Progress 2026-07-10 (array-element aggregate views): the previous note's
own named gap is closed. `NativeArray` gains `arrayElement(index) @safe ->
NativeArray` and `sliceElement(index) @system -> NativeArray`, the
counterparts to `structElement` for an array whose `elementType` is itself
a static array (`int[3][4]`) or a dynamic array (`int[][]`), exactly
mirroring `NativeStruct.arrayField`/`sliceField` one level down: an array
element, not a struct field, is the aggregate being viewed. The
struct/array composition matrix is now symmetric on both axes -- a struct
can view any of its fields (struct, static array, or slice) as a handle,
and an array can view any of its elements (struct, static array, or slice)
as a handle, with no accessor left one-directional.

`arrayElement` stays `@safe`: this element's bytes ARE the nested array's
inline storage, `stride` bytes at `index * stride` inside this array's own
block, so it only ever slices an already-verified block via `NativeBlock.
subRange`, exactly `structElement`'s own argument. `index` is
bounds-checked against `length` first, reusing `element`'s wrap-free
argument rather than re-deriving it; an `elementType` that is not a static
array throws before any offset arithmetic runs. The returned handle's
`length` is `layout.staticArrayLength(elementType)` and its element type is
`elementType.next`, built through `NativeArray.adopt` rather than by hand.
Ownership/scan/`trueByteSize`: `Ownership.borrowed` and the parent's `Scan`
via `adopt`'s own `subRange`-backed construction, and `block.trueByteSize`
is 0 -- an array element is not an independent allocation, so nothing about
it can be grown; growing the OUTER array stays `reserve`/`setLength`'s job.

`sliceElement` is `@system`, unlike `arrayElement`: this element's bytes
are NOT inline storage, they ARE a slice header (`{ length, ptr }`) naming
a separately tracked block elsewhere, so the only way to view "the
elements this slot currently points at" is to read that header back out of
memory and reconstruct a handle via `NativeArray.borrow` -- an
unverifiable reconstruction from a pointer this code reads out of memory,
exactly `NativeStruct.sliceField`'s own reason for being `@system`. `index`
is bounds-checked first, reusing `element`'s wrap-free argument; an
`elementType` that is not a dynamic array throws before any header bytes
are read. The read-back contract is identical to `sliceField`'s: a
zero-length/null header reads back as a real, empty `NativeArray`; the
returned array's `ownership` is always `borrowed`, its `scan`/`capacity`
are `Scan.no`/`0` unconditionally per `NativeBlock.borrow`'s own contract
even when the pointed-to block is a real, conservatively-scanned GC
allocation this element keeps alive; and it aliases, not snapshots -- a
write through the returned handle is visible through any other handle over
the same block, and it goes stale exactly as any other stale pointer once
this element's header is overwritten or the pointed-to block moves.

The de-duplication the task asked for: `sliceField` and `sliceElement` both
need the exact two-value `{ length, ptr }` header read, so the helper that
does it, `readSliceHeaderBytes` (and its `SliceHeaderBytes` return type),
moved from being `native_struct.d`-private to living in `native_array.d`,
`public`, alongside `sliceHeaderByteLength`/`writeSliceHeaderBytes` -- the
other two pieces of this module's own slice-header layout. `NativeStruct.
sliceField` now imports and calls it rather than keeping a second,
driftable `memcpy` of the same two fields; its own tests were not touched
and still pass unchanged.

Regression tests, in `tests/ut/backends/interpreter/native_array.d`, using
`NativeStruct.fieldDeclaration(0).type` (an `Int3Holder`/`SliceHolder`
struct's own field type, straight from the host compiler) as each
fixture's `elementType`, exactly as `NativeStruct.arrayField`/`sliceField`
already read their own field types this way:
`NativeArray.arrayElement.lengthAndStrideMatchElementTypeAndByteLength
MatchesHostCompilerInt3x4Sizeof` (pinned against `int[3][4].sizeof`);
`.writeThroughElementViewIsVisibleInParentElementBytes` and `.
writeThroughParentElementBytesIsVisibleThroughElementView` (aliasing, both
directions); `.elementTypeNotStaticArrayThrows`; `.outOfRangeIndexThrows`;
`NativeArray.sliceElement.roundTripAliasesWriteSliceHeaderSourceArray`
(aliasing, not a snapshot); `.
zeroLengthNullHeaderReadsBackAsEmptyBorrowedArray`; `.
elementTypeNotDynamicArrayThrows`; and `.outOfRangeIndexThrows`. No
`GC.collect`-based liveness test was added, per this plan's own "ownership
vs GC-visibility" note. The full focused `ut.backends.interpreter` suite
passes.

Review (2026-07-10, finding 8) noted `arrayElement`'s documented
`Ownership.borrowed`/`trueByteSize == 0` contract had no direct test,
unlike `structElement`'s own `reportsBorrowedOwnership`/
`blockTrueByteSizeIsZero`. Closed by adding the same two assertions under
the matching names, `NativeArray.arrayElement.reportsBorrowedOwnership`
and `.blockTrueByteSizeIsZero`, using the same `Int3Holder` fixture as the
rest of this section -- both already held (no production-code change), so
this is pure coverage, mirroring `structElement`'s own tests exactly.

Still not done: no `impl.d`/`Walker`/`Value` wiring (no guest expression
reaches `arrayElement`/`sliceElement`, `structElement`, `arrayField`, or
`sliceField` yet -- there is no interpreter call site for any of this
composition), no class objects, and every `interpreter.md` §9.10 shim
remains unretired.

Progress 2026-07-10 (review: two reachable-handle safety holes closed):
review of the accumulated array/struct-handle work above found two real
bugs, both now fixed with a failing test first.

`NativeArray.slice(0, 0)` on a default-constructed `NativeArray.init`
(`_stride == 0`, `_elementType is null`) did not throw: `begin > end` and
`end > _length` both pass trivially (0, 0, 0 are all equal),
`_block.subRange(0, 0)` succeeds on the null block, and `NativeArray.adopt`
then called `typeByteSize(null)` -- `dmd.typesem.size` dereferencing a
null `Type`, segfaulting `@safe` code (confirmed: the pinning test crashed
the test process with SIGSEGV, exit 139, before the fix). `reserve` and
`setLength` already guarded this exact reachable handle with a `_stride ==
0` check; `slice` now gets the identical guard, checked first, mirroring
`reserve`'s own ordering rationale. Pinned by `NativeArray.slice.
onInitHandleThrows`. The other new accessors this note's own history
added (`structElement`, `arrayElement`, `sliceElement`, `structField`,
`arrayField`, `sliceField`) were individually re-checked rather than
assumed safe: every one of them bounds-checks its `index` against
`length`/`fieldCount` before touching `_elementType`/the field's `Type` at
all, and `NativeArray.init`/`NativeStruct.init` both report a length/
field-count of 0 -- so no index ever passes their bounds check on an
`.init` handle, and the null-`Type` arithmetic below it is never reached.
`NativeStruct.adopt`/`NativeArray.adopt` were also re-checked: every
internal caller (`structElement`, `arrayElement`, `arrayField`) only ever
passes a `Type` already proven non-null by its own `isTypeStruct`/
`isTypeSArray`/`.next` check immediately beforehand, so neither factory is
reachable with a null `Type` except by a caller passing `null` directly --
not the same "innocuous `.init` handle" shape as `slice`'s bug, so no
guard was added there.

`readSliceHeaderBytes` (`native_array.d`) is `public @trusted` and
`memcpy`s `sliceHeaderByteLength` bytes out of `src.ptr`, with its only
length enforcement an `in (src.length == ...)` contract -- stripped under
`-release`, unlike its `private` sibling `writeSliceHeaderBytes`, whose
safety comment explicitly rests on its sole caller's own prior checks. A
`public` function reachable from any `@safe` caller with a too-short slice
would read past its end. Fixed with an unconditional, un-strippable
length check that throws instead of the `in` contract; the `@trusted`
comment now states the boundary rests on that check holding, not merely on
the content of already-bounds-checked bytes. Pinned by `NativeArray.
readSliceHeaderBytes.wrongLengthThrows`.

The full focused `ut.backends.interpreter` suite passes.

Progress 2026-07-10 (first interpreter call site: reinterpreted local-pointer
loads): the native-layout container types landed a caller. A new leaf module
`source/quickbite/backends/interpreter/native_scalar.d` codes a boxed
`quickbite.lang.Value` to and from the host's native byte layout for the D
scalar types (`bool`, `char`/`wchar`/`dchar`, every integral width,
`float`/`double`; an `enum` with an integral base type dispatches through its
resolved base and so also works). `real`/`TY.Tfloat80` is deliberately
excluded: its 80-bit extended-precision layout is host- and ABI-specific
padding, not a portable byte-for-byte native scalar, and nothing needs it
yet. `writeScalar`/`readScalar` `memcpy` rather than use a pointer-typed
load/store, matching `native_array.d`'s `writeSliceHeaderBytes`/
`readSliceHeaderBytes` alignment reasoning (the destination is an interior
`NativeBlock` byte range, not guaranteed aligned), and enforce their
length contract with an unconditional throw rather than only an `in`
contract, for the same stripped-under-`-release` reason those two give.

`impl.d`'s `reinterpretLocalPointerLoad` -- the exact shim `ai/plans/
value.md` and `interpreter.md` §9.10 named as this item's next retirement --
now allocates a `NativeBlock` sized to the source local's type, `writeScalar`s
the boxed source value into it, and `readScalar`s the target type back out of
the leading bytes, taking that path only when both the source and target
types are `isNativeScalarType` AND the target is no wider than the source
(reading a wider target than the source local owns would read bytes the
local never had; that stays on the untouched passthrough path, a
pre-existing gap this call site does not attempt to close). Every other
pair -- an aggregate, a pointer, `real`, or a widening read -- returns the
boxed value unchanged exactly as before. The two previously-hardcoded pairs
(`float`->`uint`, `double`->`ulong`) now produce their pinned results
(`ut.backends.runner.lang.expressions` `pointer.
floatBitsThroughUintPointerAreRawBits`/`pointer.
doubleBitsThroughUlongPointerAreRawBits`) through real bytes instead of a
name match; both stayed green. The private `floatBits`/`doubleBits` helpers
at the bottom of `impl.d` had no other caller (confirmed by grep; the
same-named helpers in `backends/ir/bits.d` and `executor.d` are unrelated
modules, untouched) and are deleted.

One previously-unhandled pair now takes the new byte-level path where it
used to fall through unchanged: `dchar` source / `uint` target (4 bytes
each), exercised by `pointer.
dcharCompoundAssignThroughUintPointerIsIntegerCompatible.Interpreter`. This
does not change that test's outcome -- traced before changing anything: the
test's `==` goes through `impl.d`'s `equalValues`, which already compares a
character and a numeric scalar by code point regardless of which `Value`
variant is active, so the old passthrough and the new byte-reinterpreted
read agree numerically for this pair (a `dchar`'s code-point value already
equals its raw bits for values in this range). Grepped the whole test suite
for every `cast(T*) &expr` shape before writing any code (`tests/ut`, no
`tests/ct`/`tests/rt` top-level trees in this repo) and traced each hit;
`ut.backends.runner.lang.cerealed.encodeFloatReinterpretsBytes` is the other
live pointer-reinterpret fixture and is the same, already-covered
`float`->`uint` pair through a function parameter rather than a plain
local. No test pinned an old wrong answer for a newly-handled pair, so
nothing needed weakening or was left un-migrated. The strict-narrowing
case (target strictly narrower than source, e.g. a `uint` local read
through a `ushort*`) also newly takes this byte-level path rather than
the untouched passthrough -- the narrowing behaviour is correct (it reads
the leading bytes, matching compiled D) but, unlike the `dchar`/`uint`
pair above, no `lang/`/`sys/` fixture exercises a strict-narrowing
reinterpret today; it is pinned only at the codec level, by
`native_scalar.d`'s own narrowing unit test.

New unit tests in `tests/ut/backends/interpreter/native_scalar.d` (added to
`tests/main.d`'s explicit `runTests!` module list, matching how
`native_array`/`native_struct` are registered there): round-trip for every
handled width, `bool`, `char`/`wchar`/`dchar`, an enum with an integral base
(via a new `enumTypeOf` test helper in `tests/ut/backends/interpreter/
package.d`, mirroring the existing `structTypeOf`), the host compiler as an
explicit oracle (`*cast(uint*) &f`/`*cast(ulong*) &d` computed in the test
and compared against `writeScalar`+`readScalar`'s result), a wrong
`dest`/`src` length throwing, and an unsupported type (`void*`) throwing.
Focused runs, all green: `bin/ut -s ut.backends.interpreter.native_scalar`,
`bin/ut -s ut.backends.interpreter`, `bin/ut -s
ut.backends.runner.lang.expressions ut.backends.runner.lang.cerealed
ut.backends.runner.lang.structs ut.backends.evaluator.eval` (all
pre-existing `@ShouldFail` rows still fail as expected), and `bin/ut -s
ut.backends.runner.sys.cstdlib ut.backends.ffi.dependency_image`. The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

`ffi_marshal.d`'s `marshalArgument`/`unmarshalValue` already do a narrower
version of the same integral/float encode/decode for the libffi ABI seam
(~lines 645-660 and 907-923); `native_scalar.d`'s codec deliberately agrees
with it rather than diverging, but the two are not consolidated in this
commit -- `ffi_marshal.d`'s buffer is a libffi cell, not a `NativeBlock`,
and touching it was out of scope for this call site. Flagged as future
consolidation, not done.

What this commit does NOT do, to be precise about the state of item 7:
`reinterpretLocalPointerLoad` itself is not deleted -- it still exists and
is still the call site, but its body now routes through real native bytes
instead of a name/type-pair match. The local's authoritative storage is
still a boxed `Value`; this only changes what a *load through a
differently-typed pointer* produces, not where the local itself lives --
`locals[VarDeclaration]` is still `Value[VarDeclaration]`, not a
`NativeBlock`. No `interpreter.md` §9.10 shim is retired by this commit,
including this one: the `reinterpretLocalPointerLoad` +
`floatBits`/`doubleBits` entry's retirement condition is "native layout
makes ALL reinterpret loads structural", and only the two previously-
hardcoded pairs (`float`->`uint`, `double`->`ulong`) now go through real
bytes -- aggregate, pointer, `real`, and widening reinterprets still take
the untouched boxed/refused passthrough path, so the condition is unmet
and the entry stays open, merely narrowed (`floatBits`/`doubleBits`
themselves are deleted; see above). `gc_*` capacity hooks,
`runEmplaceRefCall`/`isEmplaceRef`, and `writeBackByValueClassArguments`
are all still exactly as they were. The array/struct container
composition work from the notes above still has no *other* interpreter
call site (no guest expression reaches
`arrayElement`/`sliceElement`/`structElement`/`arrayField`/`sliceField`);
this commit's call site is scoped to scalar reinterpret-loads only, the
narrowest slice of "give these types somewhere to be used" that had an
existing, exactly-named shim entry to narrow.

Progress 2026-07-10 (single scalar<->bytes authority): `impl.d` carried a
second, older scalar-byte codec alongside `native_scalar.d` -- `scalarBytes`
(splats a boxed `Value`'s bits into a `Value[]` of individually-boxed
`ubyte`s) and `scalarFromBytes` (its inverse, reassembling those boxed bytes
back into a scalar `Value` via a hand-written `switch` over `dmd.astenums.
TY`), used by `localPointerByteSlice` (`ptr[lower..upper]` byte slices
through a pointer to a scalar local) and `scalarWithByte`/
`writeThroughArrayPointer` (single-byte pointer writebacks, e.g. a native
call filling a buffer that aliases a non-array scalar local). This was
exactly item 7's "must not grow a second set of D layout rules" guardrail
being violated by the interpreter's own pre-existing code, not new code --
`native_scalar.d` already had the byte width and bit-pattern facts for
every scalar `TY` it claims; `impl.d` was re-deriving them independently.

Both helpers now delegate: `scalarBytes` allocates a `ubyte[layout.
typeByteSize(type)]`, calls `native_scalar.writeScalar` into it, and maps
each byte to `Value(ubyte)`; `scalarFromBytes` copies its `Value[]` bytes
into a `ubyte[]` and calls `native_scalar.readScalar`. Both keep their
original signatures (`Value[]` in/out) so `localPointerByteSlice`,
`scalarWithByte`, and `writeThroughArrayPointer` are unchanged.

The float/double question: the old hand-written `scalarFromBytes` `switch`
had no `Tfloat32`/`Tfloat64` case and threw "Unsupported scalar byte
writeback." for them -- but that throw was already effectively dead code
via `scalarBytes`, not `scalarFromBytes`: `scalarBytes` computed its bytes
via `value.asLong`, and `quickbite.lang.Value.asLong` itself throws
("Expected integer-compatible scalar.") for a `float`/`double`-holding
`Value`, since those are separate, non-integral `SumType` members. So a
float/double local reaching either helper already threw before ever
reaching `scalarFromBytes`'s own throw branch, just with a different
message. Grepped the whole `tests/` tree for both exact messages
("Unsupported scalar byte writeback.", "Expected integer-compatible
scalar.") and for `ptr[lower..upper]`/compound-assignment-through-scalar-
pointer fixtures exercising float/double specifically: nothing pins either
throw. Per the single-oracle rule, `SystemLinker` (real compiled D) has no
such restriction -- `*cast(ubyte*)&floatLocal` byte-slices or writes back
fine in compiled D. So this reimplementation is allowed to make float/
double succeed here, and it does: `native_scalar.writeScalar`/`readScalar`
handle `Tfloat32`/`Tfloat64` via `Value.asReal`, not `asLong`, so both
`scalarBytes` and `scalarFromBytes` now succeed for float/double locals
through this path, matching the `SystemLinker` oracle. This is verified as
*unpinned* (nothing in `tests/` depended on the old throw), not *proven* by
a new `lang/`/`sys/` fixture -- no such fixture was added, per this task's
scope (adding one needs separate TDD approval). Every other previously-
handled type (`bool`, `char`/`wchar`/`dchar`, every integral width, and an
`enum` with an integral base, which reaches the codec via `Value.EnumValue`
regardless of base type) is unchanged: `isNativeScalarType`'s case list is
a strict superset of the old `switch`'s cases, so no type the old code
handled is now unhandled.

New unit tests in `tests/ut/backends/interpreter/native_scalar.d`: a round
trip through an individually-boxed `Value[]` byte array (mirroring `impl.
d`'s new `scalarBytes`/`scalarFromBytes` composition one level below their
private, untestable-in-isolation bodies) for a 4-byte integral type, and
the same composition for `float`/`double` -- the newly-succeeding case.
Focused runs, all green with the new cases added and nothing else changed:
`bin/ut -s ut.backends.interpreter.native_scalar`, `bin/ut -s
ut.backends.interpreter`, `bin/ut -s ut.backends.runner.lang.expressions ut.
backends.runner.lang.cerealed ut.backends.runner.lang.structs ut.backends.
evaluator.eval` (identical to the pre-change baseline, pre-existing
`@ShouldFail` rows still fail as expected), and `bin/ut -s
ut.backends.runner.sys.cstdlib ut.backends.ffi.dependency_image`
(identical to baseline). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

`ffi_marshal.d`'s narrower version of the same encode/decode (noted above)
is still untouched -- out of scope here too, same reasoning as the prior
progress note.

Progress 2026-07-10 (scalar authority reaches the FFI marshaller): the
previous two notes left `ffi_marshal.d`'s own scalar encode/decode as a
deliberately-unconsolidated third copy of the same D layout rules -- exactly
item 7's "must not grow a second set of D layout rules" guardrail, this time
at the libffi ABI seam rather than in `impl.d`. `marshalArgument`'s
`Tbool`/`Tchar`/`Twchar`/`Tdchar`/every integral width arm and its
`Tfloat32`/`Tfloat64` arms, and `unmarshalValue`'s matching arms, now route
through `native_scalar.writeScalar`/`readScalar`. `Tfloat80` (`real`) and
every aggregate/pointer/class/array/struct/delegate arm are untouched, per
`native_scalar.d`'s own deliberate exclusion of `real`'s host-specific
padded layout and this task's scope.

Proving byte-for-byte preservation needed tracing, not assumption, on two
fronts:

Char/integral agreement: `ffi_marshal.d`'s local `scalarBits(type, value)`
and `native_scalar.d`'s local `scalarLong(value)` compute a `Value`'s
integer bits slightly differently in their source text (`scalarBits`
special-cases `Tchar`/`Twchar`/`Tdchar` by *type*; `scalarLong` special-cases
by whether the `Value` *itself* `isCharacter`), so they can only diverge when
the type says char but the value is not character-valued -- concretely, a
`float`/`double`-holding `Value` reaching a char-typed slot, where
`scalarBits` would truncate via `castTo!long.asLong` and `scalarLong` would
throw via a direct `asLong`. Traced whether that is reachable: every
`marshalArgument`/`unmarshalValue` `type` argument arrives already resolved
through `.toBasetype` (`quickbite.ffi.core`'s `parameterType`/the `Tarray`/
`Tstruct` recursions), and every `Value` reaching a char-typed argument
either comes from `integerValue` (an `IntegerExp` literal, which switches on
`integer.type.ty` and produces a genuinely char-typed `Value` for a
char-typed literal) or from an explicit `CastExp`, whose `castValue` routes
through `quickbite.backends.casts.castValue`'s `char_`/`wchar_`/`dchar_`
targets -- `value.castTo!char` etc. -- which also produces a genuinely
char-typed `Value` regardless of the source type. D has no implicit
narrowing conversion to `char`/`wchar`/`dchar` that would let a float reach
a char-typed argument slot uncast. So the only inputs either helper can
receive are ones where both formulas already agree (an integral/bool/char
`Value` at any of these types); the divergent float-at-char-type case is
provably unreachable, not merely unobserved.

Buffer-width agreement: unlike the container call site in the prior two
notes, `ffi_marshal.d`'s buffers are not uniformly `layout.typeByteSize
(type)`-sized, so `writeScalar`/`readScalar`'s unconditional length-match
throw needed checking against every call site, not assuming it. Traced all
of them (`quickbite.ffi.core`'s argument/receiver/ref-result/out-parameter
cell allocations, and this file's struct-field/static-array/slice-element/
pointer-element recursive slices): every one is exactly `typeByteSize(type)`
long, *except* a direct (non-ref) native return buffer and a native closure/
callback result buffer, both of which `quickbite.ffi.core` widens to at
least libffi's `ffi_arg` width (>= 8 bytes) for a narrow scalar type -- a
real, load-bearing libffi ABI convention, not an oversight. For the read
side (`unmarshalValue`), only the low `typeByteSize(type)` bytes of that
widened buffer ever mattered (the old pointer-cast read the same bytes,
oblivious to the rest of the buffer), so slicing to `buffer[0 ..
typeByteSize(type)]` before calling `readScalar` reproduces the old read
exactly for both the exact-size and the widened case. For the write side
(`marshalArgument`), the two are not equivalent: the old integral/char
arm's byte splat fills the *entire* (possibly widened) buffer with a sign-
or zero-extended copy of the value, which is what libffi's closure-result
ABI convention requires when an interpreted delegate is called back into
from native code and returns a narrow scalar (ffi.md §34.16) -- a fixed-
width `writeScalar` cannot produce that. This is the one case left
deliberately unconsolidated: `marshalArgument`'s integral/char arm checks
`buffer.length == typeByteSize(type)` first and calls `writeScalar` for the
exact-size case (every argument, receiver, ref-result, and struct/array
field -- the overwhelming majority of calls), falling back to the original
`scalarBits`-driven splat only for the widened closure-result case. The
`Tfloat32`/`Tfloat64` write arms needed no such branch: the old code already
wrote only `typeByteSize(type)` bytes via a pointer-typed store regardless
of `buffer.length`, identical to what a sliced `writeScalar` call produces,
so both consolidate unconditionally.

`scalarBits` is therefore still used (the widened-buffer fallback) and was
not deleted, per this task's "still used by a path you did not touch, leave
it" rule -- it is now a narrower, ABI-specific helper rather than the
general-purpose scalar codec it used to be. `native_scalar.writeScalar`/
`readScalar` `memcpy` into an exactly-sized slice rather than use a
pointer-typed load/store; this is strictly safer than the old direct
pointer casts (alignment-agnostic) and, on this host, produces identical
bytes -- confirmed by every focused run below staying green, not merely
argued.

No test was added or modified; the proof for this commit is the existing
FFI/runtime suites staying green end to end. Focused runs, all unchanged
from baseline: `bin/ut -s ut.backends.interpreter`, `bin/ut -s
ut.backends.interpreter.native_scalar`, `bin/ut -s ut.backends.runner.sys.
cstdlib ut.backends.ffi.dependency_image`, `bin/ut -s ut.backends.
runner.sys.concurrency ut.backends.runner.sys.file ut.backends.runner.sys.
random ut.backends.native.inline_asm ut.orc.elf ut.
backends.native.llvm_jit`, and `bin/ut -s ut.
backends.runner.lang.expressions ut.backends.runner.lang.cerealed ut.backends.
runner.lang.structs ut.backends.evaluator.eval` (identical to the pre-change
baseline, pre-existing `@ShouldFail` rows still fail as expected). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Item 7's guardrail now holds across both production scalar<->bytes call
sites the interpreter has: the reinterpret-load container path and the FFI
marshaller. The one remaining split (the widened closure-result buffer) is
not a second set of layout *rules* -- it reuses the same `scalarBits`/
`scalarLong` bit-value formula `native_scalar.d`'s header comment already
documents as kept in agreement -- it is an ABI-width concern specific to
libffi's calling convention that a fixed-width leaf codec should not absorb.

Progress 2026-07-10 (aggregate handles get their first production caller):
this is the milestone item 7's headline names -- `NativeStruct`/`NativeArray`
had container machinery (allocate/borrow/adopt, field/element views, slice
headers, growth) but no caller anywhere in the interpreter until now.
`ffi_marshal.d` was walking DMD struct/array layout by hand a fourth time
(after `impl.d`'s two retired copies and the FFI marshaller's own scalar
arms, both closed by the two progress notes above) -- `unmarshalStruct` and
`marshalArgument`'s `Tstruct` arm read/wrote `sym.fields[i].offset ..
+ size(fieldType)` directly; `unmarshalStaticArray` and `marshalArgument`'s
`Tsarray` arm did the equivalent `index * elementSize` walk. All four now
view their buffer as a `NativeStruct`/`NativeArray` and use `field(index)`/
`element(index)` for the byte sub-slice and `fieldDeclaration(index).type`/
the array's own `elementType` for the recursive dispatch type -- both the
read side (`unmarshalStruct`, `unmarshalStaticArray`) and the write side
(`marshalArgument`'s `Tstruct`/`Tsarray` arms).

Three things were proven, not assumed, before touching a line:

- Basetype dispatch. The old code recursed on `field.type.toBasetype`/
  `elementType.toBasetype`; `NativeStruct.fieldDeclaration(index).type` and
  a `NativeArray`'s `elementType` are the DECLARED type. Every new call site
  calls `.toBasetype` explicitly before recursing (for the array sites, once,
  since the same resolved `elementType` local is reused both to build the
  handle and to dispatch), reproducing the exact old dispatch. No enum-typed
  struct field or array element exists in the `sys/` FFI fixtures to exercise
  this at runtime (grepped `tests/ut/backends/runner/sys/` for a struct with
  an `enum`-typed field; none), so this is proven structurally instead: DMD's
  own `size(Type, Loc)` (`dmd/compiler/src/dmd/typesem.d`) has `case Tenum:
  return t.isTypeEnum().sym.getMemtype(loc).size(loc);` -- an enum's declared-
  type size IS its basetype's size, verbatim, so `typeByteSize` cannot
  diverge between the two for a struct field or array element regardless of
  whether a fixture exercises it.
- Offset/size identity is not merely equal, it is IDENTICAL data. `layout.
  structFields(type)` (`NativeStruct.borrow`'s field list) returns `type.sym.
  fields[]` verbatim -- the same array, same order, same `VarDeclaration`
  objects -- so `NativeStruct.fieldDeclaration(index)` for any index is
  literally the same object the old code read via `sym.fields[index]`, not a
  separately-derived equal one. `NativeStruct.field(index)`'s offset comes
  from `layout.fieldByteOffset`, which returns `field.offset` verbatim (the
  same number the old code read directly), and its size from `layout.
  typeByteSize(declaration.type)`, which -- per the basetype finding above --
  equals `size(declaration.type.toBasetype)`, the old code's own number. The
  byte range `NativeStruct.field`/`NativeArray.element` return is therefore
  byte-for-byte the same sub-slice the hand-rolled walk produced, for every
  real type, not just the ones covered by a running fixture.
- Mutability. `NativeStruct.borrow`/`NativeArray.borrow` wrap the caller's
  own buffer (`NativeBlock.borrow` stores the raw `ubyte[]` unchanged, still
  mutable); `field`/`element` are non-`const`, non-`inout`-narrowed accessors
  that return a writable `ubyte[]` when called on a non-const handle. So the
  write side (`marshalArgument`'s `Tstruct`/`Tsarray` arms, which write INTO
  the sub-slice) needed no fallback to the old hand-rolled path -- both read
  and write sides consolidate cleanly through the same handles.

`@system`: `NativeStruct.borrow`/`NativeArray.borrow` are `@system` (raw
pointer); the four call sites live in `unmarshalStruct`, `unmarshalStaticArray`,
and `marshalArgument`, none of which are `@safe`, so no `@trusted` wrapper was
needed or added. The now-unused `import dmd.typesem: size;` was removed from
`marshalArgument` and the two `unmarshal*` functions once their last direct
`size(...)`/`sym.fields[i].offset` call was replaced.

No test was added or modified; the proof is the existing FFI/runtime suites
staying green end to end, plus the structural identity arguments above (this
call site's correctness does not rest on fixture coverage the way a value
computation would -- the handle reads the exact same DMD objects and numbers
the old code did). Focused runs, all green and unchanged from baseline
except where noted: `bin/ut -s ut.backends.interpreter`, `bin/ut -s
ut.backends.interpreter.native_struct ut.backends.interpreter.native_array`,
`bin/ut -s ut.backends.runner.sys.cstdlib ut.backends.ffi.dependency_image`,
`bin/ut -s ut.backends.runner.sys.concurrency ut.
backends.runner.sys.file ut.backends.runner.sys.random
ut.backends.native.inline_asm ut.orc.elf ut.backends.native.llvm_jit`, and
`bin/ut -s ut.backends.runner.lang.expressions ut.backends.runner.lang.
cerealed ut.backends.runner.lang.structs ut.backends.evaluator.eval`
(identical to the pre-change baseline, pre-existing `@ShouldFail` rows
still fail as expected). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

To be precise about the milestone: this gives `NativeStruct`/`NativeArray` a
real production caller for the first time, closing the "somewhere to be
used" gap the item's headline names -- but it is the FFI seam, not the
interpreter's core value representation. The tree-walking Walker's locals
(`locals[VarDeclaration]`) are still `Value[VarDeclaration]`; every guest
expression that reads or writes a struct/array local still boxes. No
`interpreter.md` §9.10 shim is retired by this commit (the shims this item's
success criteria name -- `gc_*` capacity hooks, `runEmplaceRefCall`/
`isEmplaceRef`, `writeBackByValueClassArguments` -- are FFI-independent; this
caller is downstream of DMD's own libffi ABI seam, not the interpreter's own
local storage). `unmarshalSlice`'s header parsing/char fast-paths,
`marshalSliceArgument`, the scalar/pointer/class/delegate/float80 arms, the
writeback machinery, and the union paths (`isOpaqueUnionOutCell` and its
callers) were left untouched, exactly per this task's scope -- none of them
walk struct/array layout by hand the way the four consolidated sites did.
What remains, unchanged from the prior note: a guest-level `&local`/array/
struct call site for the container types themselves (not just this FFI-seam
caller) -- no guest expression yet reaches `arrayElement`/`sliceElement`/
`structElement`/`arrayField`/`sliceField`, and locals still are not stored in
native layout at all.

Progress 2026-07-10 (slice element layout joins the aggregate authority): the
previous note consolidated `unmarshalStruct`/`unmarshalStaticArray`/
`marshalArgument`'s `Tstruct`/`Tsarray` arms through `NativeStruct`/
`NativeArray`, but left two more hand-rolled element walks in
`ffi_marshal.d` untouched: `marshalSliceArgument` (write side, a dynamic
`T[]` argument) allocated its own `new ubyte[](value.length * elementSize)`
and sub-sliced it by hand; `unmarshalSlice`'s `default:` arm (read side, a
returned/callback `T[]` whose element type is not `char`/`wchar`/`dchar`)
did the matching `bytes[index * elementSize .. (index + 1) * elementSize]`
walk over the returned `{length, ptr}` header's pointee. Both now go through
`NativeArray`: `marshalSliceArgument` calls `NativeArray.allocate(
elementType, value.length)` and writes each element into `na.element(
index)`; `unmarshalSlice`'s `default:` arm calls `NativeArray.borrow(
elementType, cast(void*) data, length)` and reads each element from `na.
element(index)`. The header parse (`length`, `data`) and the `Tchar`/
`Twchar`/`Tdchar` fast-paths in `unmarshalSlice` are untouched, exactly per
this task's scope -- neither walks element layout by hand. This closes the
last two hand-rolled per-element layout walks in the FFI marshaller; every
site that sub-slices a struct/array/slice buffer by index now goes through
`NativeStruct`/`NativeArray`.

Two things were confirmed, not assumed, before touching a line:

- Basetype dispatch and stride/offset identity, same argument as the prior
  note applied to a slice's element rather than a struct's field or a static
  array's element. Both call sites resolve `elementType = type.nextOf.
  toBasetype` once and reuse it both to build the `NativeArray` handle and
  to dispatch the recursive `marshalArgument`/`unmarshalValue` call, exactly
  reproducing the old code's `elementType.toBasetype`-then-`size(
  elementType)` sequence. `NativeArray`'s `stride` is `layout.
  typeByteSize(elementType)` (`native_array.d`'s `allocate`/`borrow`, both
  called here); `layout.typeByteSize` reads `type.size` (`layout.d`'s
  `typeByteSizeImpl`), which is `dmd.mtype.Type.size`'s own property --
  DMD's `dmd.typesem.size(Type, Loc)` under the hood, the exact function the
  old code called directly as `size(elementType)`. Same DMD number, not
  merely an equal one, so `element(index)`'s `index * stride .. (index + 1)
  * stride` is byte-for-byte the same sub-slice the hand-rolled
  `index * elementSize .. (index + 1) * elementSize` produced.
- Lifetime, for the write side specifically (the read side borrows caller-
  owned native memory it never allocates, so there is no lifetime question
  on that side beyond what `unmarshalStaticArray`'s prior note already
  covered). The old `bytes = new ubyte[](value.length * elementSize)` was a
  GC-allocated, zero-initialised `ubyte[]` kept alive by two things: being
  appended to `keepAliveBuffers` (this call's own borrowed-argument
  lifetime) and being stored in `_sliceWritebacks` (`fillArgument`'s own
  field, alive for the marshaller's whole session, used to reify the
  callee's writes back into a `Value` after the call). `NativeArray.
  allocate`'s block is also GC memory (`NativeBlock.allocate` routes through
  `GC.calloc`), also zero-initialised (`GC.calloc` zeroes; verified in
  `native_block.d`'s own `allocateBytes` comment) and also a non-moving GC
  allocation, so `na.block.bytes` -- the `ubyte[]` this commit now returns
  and stores in the same two places (`keepAliveBuffers`, `_sliceWritebacks`)
  -- is kept alive and stable by the identical mechanism the old `bytes`
  local was. `NativeBlock.allocate`'s zeroing and `new ubyte[]`'s zeroing
  agree exactly (both zero every byte); there is no behavioural difference
  to note there. One incidental improvement, not requested but worth
  recording: `NativeArray.allocate` picks its block's GC scan policy from
  `typeHasPointers(elementType)` (`native_array.d`'s own doc comment), so a
  slice whose element type carries pointers now gets a conservatively
  scanned block, where the old `new ubyte[]` -- typed as `ubyte[]`, which
  itself carries no pointers -- would always have been allocated `NO_SCAN`
  regardless of what the bytes inside it actually held. No `sys/` fixture
  exercises a pointer-carrying slice element type today, so this is not
  proven by a passing test, only by reading `NativeArray.allocate`'s own
  scan-policy logic against the old `new ubyte[]`'s inferred one.

As with the prior note, this is still the FFI seam, not the tree-walker's
core value representation: locals stay boxed, and no `interpreter.md` §9.10
shim is retired by this commit -- this consolidation closes the marshaller's
own remaining hand-rolled layout walks, it does not change where a guest
local's storage lives or add a new guest-reachable call site for
`arrayElement`/`sliceElement`/`structElement`/`arrayField`/`sliceField`.

No test was added or modified; the proof is the existing FFI/runtime suites
staying green, plus the structural stride/offset-identity argument above.
Focused runs, all green and unchanged from baseline: `bin/ut -s
ut.backends.interpreter`, `bin/ut -s ut.backends.interpreter.native_array
ut.backends.interpreter.native_struct`, `bin/ut -s ut.
backends.runner.sys.cstdlib ut.backends.ffi.dependency_image ut.
backends.runner.sys.concurrency ut.backends.runner.sys.file ut.backends.
runner.sys.random ut.backends.native.inline_asm ut.orc.elf
ut.backends.native.llvm_jit`, and `bin/ut -s
ut.backends.runner.lang.expressions ut.backends.runner.lang.cerealed
ut.backends.runner.lang.structs ut.backends.evaluator.eval` (identical to
the pre-change baseline, pre-existing `@ShouldFail` rows still fail as
expected). The full `bin/ut --random` was left to the orchestrator per the
usual long-suite handoff.

Progress 2026-07-10 (single byte-size authority): the prior two notes
routed `impl.d`/`ffi_marshal.d`'s hand-rolled per-field/per-element byte
walks through `NativeStruct`/`NativeArray`, but both files still called
`dmd.typesem.size` directly at eleven remaining sites to get a bare
type's byte size, each casting DMD's `SIZE_INVALID` sentinel to
`size_t` in place -- silently, unlike `layout.typeByteSize`, which
throws instead. This commit routes every one of those sites through
`layout.typeByteSize`, completing this branch's single-layout-authority
theme: `layout.typeByteSize` is now the only place in the interpreter
package that calls `dmd.typesem.size` for a byte size, apart from
`impl.d`'s `pointerElementSize` (deliberately left; see below). Converted,
all in `ffi_marshal.d` unless noted: `InterpreterInboundTrampolineSession.
invoke`'s callback-argument size, `pointerWritebacks`'s element size,
`writeRefResult`'s ref-result size, `invokeClosure`'s callback-argument
size, `marshalPointerElements`'s element size, `unmarshalNative`'s and
`marshalNative`'s pointee size (both `public`, called from `impl.d`),
and in `impl.d`: `symbolOffsetLocalValue`'s static-array element size,
`runMemcpyCall`'s source-element size, and `loadNativePointerElement`/
`storeNativePointerElement`'s element size. Each converted call's now-
solitary `import dmd.typesem: size;` was removed and replaced with
`import quickbite.backends.interpreter.layout: typeByteSize;`; the
`cast(size_t)` these sites all wrapped `size(...)` in is gone too,
since `typeByteSize` already returns `size_t`. A couple of these sites
carried a `// hand-rolled ... size(fieldType) walk` style comment
referencing the old direct call; those were left alone where they
describe a *different*, already-converted walk (the `Tstruct`/`Tsarray`
arms noted in the 2026-07-10 "aggregate handles" note above), since
they document history, not this commit's lines.

Per-site `SIZE_INVALID`-unreachable check: every converted call sits on
a type that is actively being marshalled, indexed, or dereferenced at
that point -- a callback/argument/ref-result/receiver type mid-FFI-call,
a static array's own element type (whose enclosing static array is
already known-sized, which DMD cannot compute without first sizing the
element), a memcpy source pointer's pointee (memcpy requires a known
element stride to advance by), or a native-pointer element being read
or written through `loadNativePointerElement`/
`storeNativePointerElement` (native memory access needs a known byte
width). None of these can legitimately reach `Type.terror`/an unsized
type in practice, so replacing the silent `SIZE_INVALID`-as-huge-
`size_t` cast with `typeByteSize`'s throw is a hardening -- an
unreachable-in-practice guard becoming loud instead of silent -- not a
behaviour change.

One site was deliberately left on raw DMD access:
`impl.d`'s `pointerElementSize` (pointer-arithmetic scaling) reads
`element.size` as a property (UFCS on the same `dmd.typesem.size`, but
call-free syntax, not the `cast(size_t) size(type)` shape this task's
grep targeted) and casts the result to `long`, not `size_t`. Casting
`SIZE_INVALID` (`~cast(ulong) 0`, all bits set) to a signed `long`
reinterprets it as `-1`, and the function already throws
"Unsupported pointer element type." whenever `elementSize <= 0` -- so,
unlike the eleven converted sites, this one already turns
`SIZE_INVALID` into a loud failure by an existing, independent guard.
Converting it would still be a legitimate future cleanup, but it is a
different shape than the pattern this task scoped, so it was left
alone and is reported here rather than silently folded in.

No layout number, offset walk, or aggregate-handling behaviour changed;
this is purely internal call routing. No test was added or modified.
Focused runs, all green and unchanged from baseline: `bin/ut -s
ut.backends.interpreter`, `bin/ut -s ut.backends.interpreter.native_scalar
ut.backends.interpreter.native_array ut.backends.interpreter.native_struct
ut.backends.interpreter.layout`, `bin/ut -s ut.backends.runner.sys.cstdlib
ut.backends.ffi.dependency_image ut.backends.runner.sys.concurrency
ut.backends.runner.sys.file ut.backends.runner.sys.random ut.backends.
native.inline_asm ut.orc.elf ut.backends.native.llvm_jit`, and `bin/ut -s
ut.backends.runner.lang.expressions ut.backends.
runner.lang.cerealed ut.backends.runner.lang.structs ut.backends.
evaluator.eval` (identical to the pre-change baseline, pre-existing
`@ShouldFail` rows still fail as expected). The full `bin/ut --random` was
left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (static-array length authority): `impl.d`'s three
remaining hand-rolled static-array-length reads --
`staticArrayPointerView`, `runVectorExpression`, and
`structLiteralFieldValue`'s default-value expansion -- each computed a
`TypeSArray`'s element count as `cast(size_t) staticArray.dim.
toInteger`. This commit routes all three through the existing
`layout.staticArrayLength(TypeSArray)` helper instead, making it the
single interpreter authority for a static array's element count, the
same way the prior two notes made `layout.typeByteSize` the single
byte-size authority and `layout.fieldByteOffset` the single field-offset
authority. `layout.staticArrayLength` reads `type.dim.toUInteger` behind
a `@trusted` boundary; for any valid (non-negative) array dimension
`toInteger` and `toUInteger` produce identical `size_t` bits, so this is
behaviour-preserving, not a behaviour change. No `import` was orphaned
by this change -- each site gained a new local `import
quickbite.backends.interpreter.layout: staticArrayLength;` alongside its
existing imports, none of which referenced the removed `.dim.
toInteger` expression. No layout number, offset walk, or aggregate-
handling behaviour changed; this is purely internal call routing. No
test was added or modified. Focused run: `bin/ut -s
ut.backends.interpreter ut.backends.runner.lang.expressions
ut.backends.runner.lang.structs ut.backends.runner.lang.arrays
ut.backends.evaluator.eval` -- 1139 run, 1 failed, 5/5 failing as
expected; the 1 failure
(`ut.backends.runner.lang.arrays.pointer.sliceAssignmentWritesArrayStorage.
Bytecode`) is pre-existing and unrelated (Bytecode backend, "Expression
did not throw"), confirmed identical on a stashed pre-change rebuild.
The full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff. This is consolidation only: no new guest call site
was added, and no §9.10 shim was retired.

Progress 2026-07-13 (struct-field-list authority): `impl.d`'s two
remaining direct `TypeStruct.sym.fields` accesses --
`structFieldIndex`'s field-index search and
`runNewStructPointerExpression`'s aggregate-initialiser bound check --
now route through the existing `layout.structFields(TypeStruct)` helper
instead of reading `sym.fields` directly. As the helper's own doc
comment establishes (and the prior static-array-length note echoed for
`staticArrayLength`), `structFields` returns `type.sym.fields[]`
verbatim -- same array, same order, same `VarDeclaration` objects --
after forcing layout via `typeByteSize`, which is a no-op at both call
sites since the struct type is already fully resolved there (a
receiver's struct type mid-evaluation; a `new` target's struct type).
This is therefore an identity consolidation, not a behaviour change.
Each site gained a new local `import
quickbite.backends.interpreter.layout: structFields;` alongside its
existing imports; no import was orphaned. `structLiteralField`'s
`literal.sd.fields[index]` (~line 7161) was deliberately left alone --
it reads a `StructDeclaration`'s fields, not a `TypeStruct`'s, so
`layout.structFields` does not apply there. No test was added or
modified. Focused run: `bin/ut -s ut.backends.interpreter
ut.backends.runner.lang.expressions ut.backends.runner.lang.structs
ut.backends.runner.lang.arrays ut.backends.evaluator.eval` -- 1139 run, 1
failed, 5/5 failing as expected; the 1 failure
(`ut.backends.runner.lang.arrays.pointer.sliceAssignmentWritesArrayStorage.
Bytecode`, "Expression did not throw") is the same pre-existing,
unrelated Bytecode-track pin noted above. The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff. This is
consolidation only: no new guest call site was added, and no §9.10 shim
was retired.

Progress 2026-07-13 (class-field offset authority): `nativeClassFieldValue`
now routes its class-field byte offset through
`layout.fieldByteOffset(VarDeclaration)` instead of reading
`field.offset` directly. As `fieldByteOffset`'s own doc comment
establishes, it returns `VarDeclaration.offset` verbatim, so this is an
identity consolidation, not a behaviour change. This brings the
class-field read path onto the same layout authority the struct field
path already uses (see the struct-field-list authority note above). A
new local `import quickbite.backends.interpreter.layout:
fieldByteOffset;` was added inside `nativeClassFieldValue`, alongside
its existing local import; no import was orphaned. No test was added or
modified. Focused run: `bin/ut -s ut.backends.interpreter
ut.backends.runner.lang.expressions ut.backends.runner.lang.structs
ut.backends.evaluator.eval` (`ut.backends.runner.lang.classes` does not
exist as a suite) -- 838 run, 0 failed, 5/5 failing as expected. The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff. This is consolidation only: no new guest call site
was added, and no §9.10 shim was retired.

Progress 2026-07-13 (class-field-list authority): the module-private
`classFields(ClassDeclaration)` helper -- walking `baseClass` to collect a
class's fields in base-to-derived order -- moved from `impl.d` into
`layout.d` as public `layout.classFields`, symmetric with the existing
`layout.structFields`. The body is unchanged: same hierarchy walk, same
`foreach_reverse` over collected classes, same field order. Unlike
`structFields`, which forces struct layout via `typeByteSize` before
reading `sym.fields`, `classFields` does NOT force layout -- a class's
`fields` are populated by semantic analysis (`dsymbolsem.d`) before the
interpreter ever runs, so there is no `sizeok`-gated state to force, and
the doc comment on the new `layout.classFields` says so explicitly. All 4
`impl.d` call sites (`nativeExceptionValue`, `nativeExceptionObjectWith
ClassFields`, `classFieldIndex`, and the module-level `classDefaultValue`)
now route through it via a local `import
quickbite.backends.interpreter.layout: classFields;`, added alongside each
site's existing local imports (or as the site's first local import, where
none existed). No import was orphaned by the deletion. No test was added
or modified. Focused run: `bin/ut -s ut.backends.interpreter
ut.backends.interpreter.layout ut.backends.runner.lang.expressions
ut.backends.runner.lang.structs ut.backends.evaluator.eval` -- 838 run, 0
failed, 5/5 failing as expected (the same pre-existing expected failures
as the prior progress note's focused run). The full `bin/ut --random` was
left to the orchestrator per the usual long-suite handoff. This is
consolidation only: no new guest call site was added, and no §9.10 shim
was retired.

Progress 2026-07-13 (single byte-size authority completed): `impl.d`'s
`pointerElementSize` -- the one site the 2026-07-10 "single byte-size
authority" note deliberately left on raw `dmd.typesem.size`, because its
shape (pointer-arithmetic scaling, not a struct/field query) differed from
the eleven converted sites -- now routes through `layout.typeByteSize`
instead. `layout.typeByteSize` is therefore now the sole byte-size
authority in the interpreter package: there is no remaining direct
`dmd.typesem.size` call for a bare type's size anywhere in it. Behavior is
preserved: for a valid pointer element type, `typeByteSize` is a thin
`@safe` wrapper over DMD's own `Type.size`, so the returned `long` is
identical to before; when `pointerType` is not a pointer (`element is
null`), `elementSize` is still forced to `0`, so the existing `throw` is
unchanged. The only behavioral difference is the unreachable
`SIZE_INVALID` case: the old code cast `SIZE_INVALID` to `long` (`-1`) and
threw "Unsupported pointer element type."; `typeByteSize` instead throws
its own message when layout can't be forced. `pointerElementSize`'s only
callers (`pointerElementOffset` and pointer subtraction, both a few lines
above/below it in `impl.d`) operate on already-valid pointer types, so
`SIZE_INVALID` cannot occur in practice, and no test pins the old message
(`grep -rn "Unsupported pointer element type" tests/` found nothing). This
is the same "silent `SIZE_INVALID` cast -> loud layout throw" hardening
the 2026-07-10 note applied to the other eleven sites, not a behavior
change. No test was added or modified. Focused run: `bin/ut -s
ut.backends.interpreter ut.backends.runner.lang.expressions
ut.backends.runner.lang.structs ut.backends.runner.lang.arrays
ut.backends.evaluator.eval` -- 1139 run, 1 failed, 5/5 failing as expected;
the one failure is the known pre-existing, unrelated
`ut.backends.runner.lang.arrays.pointer.sliceAssignmentWritesArrayStorage.
Bytecode` ("Expression did not throw"), a stale bytecode-track pin on
master, not caused by this change. The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff. No §9.10 shim was
retired, and no new guest call site was added. This completes the
interpreter-wide single-layout-authority consolidation for every field-list
read that feeds layout *arithmetic* (offsets, sizes, indexing): byte sizes,
field offsets, and struct and class field lists that feed such arithmetic,
plus static-array lengths, now all flow through `layout.d`. As with
`structLiteralField` above, three sites are deliberately exempt because
forcing layout would change their behaviour rather than merely consolidate
it: `ffi_marshal.d`'s `isOpaqueUnionOutCell` (~line 1046),
`canMarshalToNative` (~line 1093), and `canReifyFromNative` (~line 1129)
each iterate `sym.fields` directly rather than through
`layout.structFields`, because they are shape *predicates* that must be
able to answer `false` for a type DMD cannot lay out, whereas
`structFields` forces layout via `typeByteSize`, which throws for exactly
such a type.

Progress 2026-07-13 (static-array length authority reaches the FFI
marshaller): the previous note's "static-array lengths" consolidation
covered `impl.d` only (commit c0748396); this extends it to
`ffi_marshal.d` -- this plan's Track B (the interpreter's
materialize/reify) -- which had two remaining hand-rolled
`cast(size_t) staticArray.dim.toInteger` reads, in the `Tsarray` marshal
arm and in `unmarshalStaticArray`. Both now call
`layout.staticArrayLength(staticArray)` instead, with a local
`import quickbite.backends.interpreter.layout: staticArrayLength, ...;`
added at each site alongside the existing `typeByteSize` import.
`layout.staticArrayLength` is therefore now the single static-array
element-count authority across the whole interpreter package (`impl.d`
and `ffi_marshal.d`). Behavior-preserving: for a valid (non-negative)
static-array dimension, `dim.toInteger` and `dim.toUInteger` yield
identical `size_t` bits, so this is a pure rename of the read, not a
behavior change. The `index * elementSize` / `new ubyte[](length *
elementSize)` element walks at both sites are deliberately left alone --
out of scope for this commit. No test was added or modified. Focused
run: `bin/ut -s ut.backends.interpreter ut.backends.runner.sys.cstdlib
ut.backends.ffi.dependency_image ut.backends.runner.lang.expressions
ut.backends.evaluator.eval` -- 746 run, 0 failed, 5/5 failing as expected
(the same pre-existing expected failures as prior progress notes). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff. No §9.10 shim was retired, and no new guest call site
was added.

Progress 2026-07-13 (pointer-element walks join the aggregate authority):
`ffi_marshal.d`'s last two hand-rolled `index * elementSize` per-element
walks -- deliberately left alone by the previous note -- now route through
`NativeArray`, mirroring the 2026-07-10 "slice element layout joins the
aggregate authority" consolidation of `marshalSliceArgument` and
`unmarshalSlice`. `marshalPointerElements` (write side) now allocates
`NativeArray.allocate(elementType, length)` and writes each element into
`na.element(index)` instead of hand-slicing a `new ubyte[](length *
elementSize)`, returning `na.block.bytes`; an element still `= void` is
`continue`d past exactly as before, and `NativeBlock.allocate`'s `GC.calloc`
zeroes it exactly as `new ubyte[]` did. `pointerWritebacks` (reify side) now
wraps the already-marshalled buffer with `NativeArray.borrow(writeback.
elementType, cast(void*) writeback.bytes.ptr, length)` and reads each
element via `na.element(index)` instead of hand-slicing `writeback.bytes`.
Behavior-identical: `NativeArray`'s stride is `layout.typeByteSize
(elementType)`, the same number the old `elementSize` used, and
`na.element(index)` returns the same `index*stride .. (index+1)*stride`
byte range the hand-rolled walk produced; `allocate` zeroes like `new
ubyte[]`, and `borrow` wraps existing bytes without copying, like the old
direct slice into `writeback.bytes`. One incidental improvement:
`NativeArray.allocate` picks its block's GC scan policy from
`typeHasPointers(elementType)`, so a pointer-carrying element type now gets
a conservatively-scanned block where the old `new ubyte[]` (typed `ubyte[]`)
was always NO_SCAN. This closes the last hand-rolled per-element layout
walk in the FFI marshaller -- the item 7 "must not grow a second set of D
layout rules" guardrail now holds with no exceptions there. `impl.d`'s
`nativeElementAddress` (~line 5767) still computes `cast(void*)
(cast(ubyte*) base + index * elementSize)` by hand for native-pointer
element indexing, at both its call sites in `loadNativePointerElement`
and `storeNativePointerElement` (~line 5735/5755). That is pure pointer
arithmetic on a caller-supplied `elementSize`, which both call sites
already obtain from `layout.typeByteSize`, not a second layout *rule* of
its own, so it does not violate the guardrail -- but it remains
hand-rolled, and routing it through `NativeArray` too is a future
cleanup, not something this commit did. No test was added or modified.
Focused run: `bin/ut -s ut.backends.interpreter
ut.backends.runner.sys.cstdlib ut.backends.ffi.dependency_image
ut.backends.runner.sys.file ut.backends.runner.sys.random
ut.backends.evaluator.eval` -- 441 run, 0 failed. The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.
Still the FFI seam, not the tree-walker's core representation: no §9.10
shim was retired, and no guest call site was added.

Progress 2026-07-13 (first guest-local native-storage slice: reinterpret
WRITE through a pointer): item 7's guest-level call site starts. `impl.d`'s
`Walker` gains `private NativeBlock[VarDeclaration] scalarCells;`, next to
`locals`, an authoritative native-byte cell for an address-taken
`native_scalar.isNativeScalarType` local. `localPointerValue` (the common
path both `&plainLocal` (`SymOffExp`, via `symbolOffsetLocalValue`) and
`&refParameter` (`AddrExp(VarExp)`) fall through to) now calls a new
`promoteScalarCell`, which allocates the cell eagerly the first time a
scalar local's address is taken, seeding it from the local's current boxed
value in `locals` (or `defaultValue` if never written) via
`native_scalar.writeScalar`. Once a cell exists, two write paths and one
read path route through it instead of the boxed `locals` map: (1)
`writeLocation`'s `PtrExp` arm (`*p = x`) -- the actual bug this slice
fixes -- derives the pointer's pointee type the same way
`reinterpretLocalPointerLoad` already did, `writeScalar`s the assigned
value's bits in as that type, then refreshes `locals[variable]` by
`readScalar`ing the local's own type back out; (2) the `VarExp` direct-read
arm returns `readScalar(variable.type, cell.bytes)` when a cell exists,
ahead of the `locals` lookup; (3) `applyNativeWritebacks` (FFI `&local`
out-parameters, e.g. `strtol`'s `endptr` or `pthread_mutexattr_gettype`'s
`int* kind`) got the same cell-then-mirror-refresh treatment -- discovered
not from the spec but because the full focused-suite pass caught
`ut.backends.runner.sys.cstdlib.pthread.mutexattr.unionOutPointer.
Interpreter` regressing from green to red (`-1 != 1`): the FFI writeback
wrote the correct value into `locals` but left the promoted cell stale,
and the new VarExp-read hook then preferred the stale cell over the fresh
mirror. `writePointerTarget` (the `atomicStore`/`atomicExchange`/
`atomicFetchAdd` and `(*p)++`/`*p += x` pointer-target write path) was
tried as a fourth hook on the same reasoning, but removing it again and
re-running every focused suite below still left all of them green, so it
was dropped -- no existing fixture exercises a compound/atomic write
through a promoted cell yet, and the brief calls for the dumbest passing
code, not defensive coverage a test doesn't demand. `locals[variable]` is
never left to drift once a cell exists: each of the three hooks above
writes the cell first and re-derives the `locals` entry from it, so it
stays a genuine, synchronously-refreshed mirror, not a second source of
truth. (Retracted 2026-07-13: this was falsified by the cross-frame slice
below, which lets the parent's `locals` mirror drift after a child's
pointer write goes through the shared cell alone -- see that note's "What
remains" for the corrected claim.) Every `Walker child` construction that
duplicates `localPointers`/
`localPointerIds` (there are seven such call sites in `impl.d`, not the
four originally scoped -- `runFunctionCall`/`runFunction`/
`runMemberFunction`/`runDestructor`/`writeRefReturningCallLocation`/
`tryAssignNativeRefReturn`/`runNewExpression`'s constructor branch) now
also does `child.scalarCells = scalarCells.dup;`, so a duped `NativeBlock`
shares its underlying bytes by reference and a nested call sees the same
cell its caller promoted. The eighth `Walker child` site
(`runNewExpression`'s aggregate-initialiser branch, ~line 6202) does not
dup `locals`/`localPointers` either, so it is left without `scalarCells`
too, consistent with the existing pattern.

New fixture (pre-approved): `tests/ut/backends/runner/lang/expressions.d`
`pointer.uintBitsWrittenThroughPointerReadBackAsFloat`, scoped to
`Interpreter`/`SystemLinker` only (Bytecode/LLVMJit/Ctfe omitted per the
omit-don't-pin convention, unconfirmed there) -- writes `0x3F800000`
through a `uint*` reinterpret of a `float` local and asserts the local
reads back as `1.0f`. Confirmed red on `Interpreter`
(`1065353216u != 1`, the pre-existing bug: the boxed value was stored
verbatim with no reinterpret) and green on `SystemLinker` before writing
any production code; green on both after.

What this commit does NOT do, to be precise about the state of item 7:
locals are still boxed everywhere else -- `scalarCells` covers only
address-taken `native_scalar.isNativeScalarType` locals, nothing else
(aggregates, pointers, non-address-taken scalars all still live solely in
`locals`). No §9.10 shim is retired: `reinterpretLocalPointerLoad` and the
now-deleted-in-name-only `floatBits`/`doubleBits` shim history are
unchanged by this commit; this slice only narrows that entry's write-side
gap (a byte-level WRITE through a differently-typed pointer now agrees
with a direct read for a SAME-WIDTH pointee, closing the asymmetry the
read-only shim left open; a narrower pointee still threw, see the review-
fix note below, and a wider pointee remains unhandled).
`localPointerTarget` (the `*p` read helper used by
`pointerTargetValue`/some call sites) still reads from `locals`, not the
cell directly -- correct only because every write hook above keeps the
`locals` mirror in sync, not because the read was migrated.

Verification surfaced two pre-existing, unrelated failures, confirmed via
`git stash` against this same worktree's baseline (both fail identically
with the stash applied, i.e. before any of this commit's changes):
`ut.backends.runner.lang.arrays.pointer.sliceAssignmentWritesArrayStorage.
Bytecode` ("Expression did not throw", already flagged by a prior progress
note above) and `ut.backends.runner.lang.structs.struct.
staticArrayCopyRunsPostblitAndDtors.Bytecode`, which segfaults
(`bin/ut -s ut.backends.runner.lang.structs` exits 139) -- a Bytecode-track
issue, not touched by or related to this Interpreter-only change. Both are
excluded from the focused runs below by naming every other test
explicitly; neither was fixed or weakened.

Focused runs, all green except the two pre-existing failures above:
`bin/ut -s ut.backends.runner.lang.expressions` (312 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`ut.backends.runner.lang.structs`/`ut.backends.runner.lang.arrays`/
`ut.backends.runner.sys.cstdlib` run explicitly by name minus the two
pre-existing failures above (631 run, 0 failed). The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (cross-frame scalar `&local`: shared cell already
coherent, redundant writeback retired): item 7's guest-level call site
continues -- the CROSS-FRAME case, where a called function writes through
a pointer to a caller's scalar local. New fixture (pre-approved):
`tests/ut/backends/runner/lang/expressions.d`
`pointer.crossFrameUintBitsWrittenThroughPointerReadBackAsFloat`, scoped
to `Interpreter`/`SystemLinker`, mirroring the prior slice's same-frame
fixture but through a helper `void writeBits(uint* p, uint bits) { *p =
bits; }` called across a real function-call boundary. It was GREEN on
Interpreter from the first run, with no production change: the previous
slice's `scalarCells` are `NativeBlock` structs whose `_bytes` is a
`ubyte[]` slice, so `child.scalarCells = scalarCells.dup` (an AA `.dup`,
copying `NativeBlock` values but not their `_bytes` payload) already gives
the child a handle onto the exact same underlying bytes as the parent;
the callee's `writeLocation` `PtrExp` write lands in that shared memory
directly, no copy-back needed for the caller to see it.

That made the genuinely-red work the removal, not the fixture:
`writeBackFunctionState`/`writeBackMemberFunctionState`'s
`writeBackLocalPointerTargets(child)` copied `child.locals[variable]` back
into the parent's `locals[variable]` for every variable in
`child.localPointers`, including ones with a promoted `scalarCells` entry.
That copy is dead for those variables: the `VarExp` direct-read arm
(`impl.d`, in `runExpression`'s `VarExp` handling) checks `variable in
scalarCells` *before* ever consulting `locals`, so once a cell exists no
read path ever looks at the boxed mirror `writeBackLocalPointerTargets`
was restoring. Added `if (variable in scalarCells) continue;` to
`writeBackLocalPointerTargets`, skipping the copy-back exactly for
scalar-celled variables; non-scalar pointer targets (aggregates, raw
pointers -- anything `promoteScalarCell` leaves untouched because
`native_scalar.isNativeScalarType` is false for them) still go through the
unchanged copy-back below it.

Safety evidence for the removal (not just "tests still pass"): with the
writeback already deleted, a temporary experiment replaced
`runFunction`'s `child.scalarCells = scalarCells.dup;` with a byte-for-byte
*deep* copy (fresh `NativeBlock.allocate` per entry, contents copied,
underlying arrays no longer aliased) to sever exactly the sharing this
argument rests on, leaving everything else (including the deleted
writeback) as committed. Under that experiment the new cross-frame fixture
went red on Interpreter (`2 != 1` -- the caller's `f` read back as the
unmodified `2.0f`'s bit-pattern-turned-int, i.e. the pointer write never
reached the caller). Reverting the experiment (restoring the shallow
`.dup`) brought it back to green with no other change. That isolates the
claim precisely: it is the shared `NativeBlock` bytes, not the writeback
this commit deletes, carrying the value across the call.

What remains, to be precise about item 7's state: locals are still boxed
everywhere else -- non-scalar aggregates and raw-pointer locals still rely
on `writeBackLocalPointerTargets`'s copy-back (untouched for them), and
non-address-taken scalars never get a cell at all. Class objects are
completely untouched by this slice. No §9.10 shim moved -- this is a
call-site coherence fix inside the existing `scalarCells`/`locals` split
from the previous slice, not a representation change; `localPointerTarget`
and the FFI `applyNativeWritebacks` path are unchanged. The known,
pre-existing `sliceAssignmentWritesArrayStorage.Bytecode` failure (see the
prior progress note) persists in `ut.backends.runner.lang.arrays` and is
untouched.

Focused runs, all green except that one known pre-existing failure:
`bin/ut -s ut.backends.runner.lang.expressions` (314 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.sys.cstdlib ut.backends.ffi.dependency_image` (148
run, 0 failed); `bin/ut -s ut.backends.runner.lang.
arrays` (302 run, 1 failed -- the known `sliceAssignmentWritesArrayStorage.
Bytecode`); `bin/ut -s ut.bin.repl` (228 run, 0 failed). The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (direct-write path made authoritative for the cell
too): item 7's guest-level call site had a genuine read/write asymmetry
left over from the same-frame and cross-frame slices above. The DIRECT-
READ arm (`runExpression`'s `VarExp` handling) already treats a promoted
`scalarCells` entry as authoritative, returning `readScalar(variable.type,
cell.bytes)` ahead of ever consulting the boxed `locals` mirror. But the
DIRECT-WRITE arm -- `writeLocation`'s `VarExp` case, for a plain `f =
newValue` reassignment (not a write through a pointer) -- only updated
`locals[variable]`, leaving the cell holding whatever bytes an earlier
`&f` had promoted. So after `&f` promotes a cell, `f = threePointZero`
updated `locals` but the stale cell value resurfaced on the next direct
read of `f`, diverging from SystemLinker.

New fixture (pre-approved): `tests/ut/backends/runner/lang/expressions.d`
`pointer.directWriteToAddressTakenScalarUpdatesCell`, scoped to
`Interpreter`/`SystemLinker`. It takes `&f` (promoting a cell), then
reassigns `f` directly to a second runtime value, and asserts both a
direct read of `f` and a read through the still-live pointer see the new
value's bits. Confirmed red on Interpreter first (`2 != 3` -- the direct
read of `f` after the reassignment still returned `twoPointZero`'s bits
instead of `threePointZero`'s), green on SystemLinker throughout.

The fix, in `writeLocation`'s `VarExp` arm: after computing
`storageValue(variable.type, value)` and storing it in `locals[variable]`
as before, if `variable in scalarCells`, also `writeScalar(variable.type,
cell.bytes, locals[variable])` to refresh the cell from the same value
just written to the mirror. This mirrors the existing `PtrExp` arm's
pattern of treating the cell as the durable copy and the `locals` entry as
a synchronized mirror kept for the paths (aliasing, uninitialized
tracking) that still read `locals` directly. No change to the read arm,
the `PtrExp` arm, or `promoteScalarCell`/`scalarCells` population.

What remains, to be precise about item 7's state: this closes the last
known read/write asymmetry for address-taken native scalars specifically
-- non-scalar aggregates and raw-pointer locals are unaffected (they never
get a `scalarCells` entry and keep using the existing
`writeBackLocalPointerTargets` copy-back path), and non-address-taken
scalars still never get a cell at all (no behavioural difference for
them, since nothing else can alias their bytes). The boxed `locals` mirror
is still populated and still authoritative for every code path that isn't
the two `VarExp` arms and the `PtrExp` write arm. Class objects are
completely untouched. No §9.10 shim moved. The known, pre-existing
`sliceAssignmentWritesArrayStorage.Bytecode` failure persists in
`ut.backends.runner.lang.arrays` and is untouched;
`staticArrayCopyRunsPostblitAndDtors.Bytecode` (segfaults) was left alone
per standing instruction.

Focused runs, all green except the one known pre-existing failure:
`bin/ut -s ut.backends.runner.lang.expressions` (316 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.sys.cstdlib` (88 run, 0 failed); `bin/ut -s ut.bin.repl`
(228 run, 0 failed). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (ref-parameter guest call site: already coherent,
characterization test only): the last named frontier for item 7's
guest-level call site was a `ref` scalar parameter -- a guest takes
`&f` of a `ref` parameter, writes reinterpreted bytes through that
pointer, and the CALLER's own variable (bound to `f`) must observe the
write after the call returns. New fixture (pre-approved): `tests/ut/
backends/runner/lang/expressions.d`
`pointer.reinterpretWriteThroughRefParameterPointerReachesCaller`,
scoped to `Interpreter`/`SystemLinker`, mirroring the surrounding
`pointer.*ThroughPointer*` fixtures' form.

Ran green on Interpreter (and SystemLinker) with no production change
first try. Rather than force a change, six further probe variants were
tried transiently (not committed) to hunt for a genuinely uncovered red
sub-case per this slice's instructions: (A) the caller also holds its
own pointer into the argument taken *before* the call; (B) the callee
reads the `ref` parameter directly (not through the pointer) after the
pointer write, before returning; (C) a `double`/`ref double`/`ulong*`
variant; (D) two pointers taken from the same `ref` parameter inside
the callee; (E) two levels of `ref` forwarding (outer forwards its own
`ref` parameter into inner, which does the reinterpret write); (F) a
direct (non-pointer) reassignment of the `ref` parameter inside the
callee, mirroring the earlier `directWriteToAddressTakenScalarUpdatesCell`
fixture but through a `ref` parameter and across the call-return
writeback. All six ran green on Interpreter (and SystemLinker) too, so
none were kept.

Why this is coherent by construction, not luck: `writeLocation`'s
`VarExp` arm (impl.d, the direct-write case) unconditionally refreshes
`scalarCells[variable]` from the value just written to the `locals`
mirror whenever that cell already exists -- this was the exact fix
landed by the previous progress note, and it is agnostic to *why* the
write is happening. `writeBackRefArguments` (impl.d) always routes a
`ref` parameter's final value back to the caller's argument expression
through this same `writeLocation`, regardless of forwarding depth or
whether the caller's argument already has its own promoted cell. So
any pre-existing or freshly-promoted cell on either side of a `ref`
call boundary is refreshed by the same generic path that same-frame
and cross-frame writes already use; there is no separate "ref
parameter" code path to fall out of sync. This is why the mechanism
generalized to probes B/C/D/E/F without any change.

What remains, to be precise about item 7's state: this is a
characterization result, not new coverage of previously-broken
behaviour -- no production code changed. Item 7's remaining named gaps
are unchanged from the previous note: non-scalar aggregates and raw-
pointer locals still rely on `writeBackLocalPointerTargets`'s copy-back,
non-address-taken scalars never get a cell, and class objects are
untouched. The known, pre-existing `sliceAssignmentWritesArrayStorage.
Bytecode` failure persists in `ut.backends.runner.lang.arrays` and is
untouched.

Focused runs, all green except the one known pre-existing failure:
`bin/ut -s ut.backends.runner.lang.expressions` (318 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.sys.cstdlib` (88 run, 0 failed); `bin/ut -s ut.bin.repl`
(228 run, 0 failed). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (correction: the cross-frame writeback removal was
unsafe, deref-reads now read the cell too): the "cross-frame scalar
`&local`" progress note above claimed the removal of
`writeBackLocalPointerTargets`'s copy-back for scalar-celled variables was
safe because "no read path ever looks at the boxed mirror" once a cell
exists. That claim was incomplete: it only checked the DIRECT-read arm
(`VarExp` in `runExpression`). The POINTER-DEREF read arm,
`runPointerExpression` (`impl.d`), still read `(*variable) in locals` --
the boxed mirror -- not the cell. With the copy-back removed, that mirror
could go stale across multiple child-walker calls that each write the
same celled local through a pointer: a later deref-read in a fresh child
duplicated the stale mirror instead of the shared cell. The deep-copy
safety experiment in that same note only severed sharing for
`runFunction`'s `scalarCells`, which the direct-read arm's cell lookup
still made pass; it never exercised the deref-read arm's separate bug, so
it validated half the claim and missed the other half.

This surfaced as a real regression in the pre-existing, already-approved
matrix test `ut.backends.runner.lang.structs.struct.
staticArrayCopyRunsPostblitAndDtors.Interpreter`: an address-taken `int
postblits` counter, incremented via `++*postblits` inside a struct's
postblit, expected `2` after a two-element static-array copy but read
back `1` -- one of the two postblit calls' increments was lost because
the second child walker's deref-read re-derived its value from the
now-stale `locals` mirror instead of the shared cell the first child's
write had already updated.

The fix, in `runPointerExpression` just before its existing `(*variable)
in locals` lookup: when `(*variable) in scalarCells`, read the pointed-to
value with `readScalar((*variable).type, cell.bytes)` instead of
consulting the mirror, mirroring the direct-read arm's existing
`scalarCells`-first check. This makes the cell the single read authority
for BOTH direct reads and deref-reads, which is what actually validates
the earlier writeback removal -- the mirror is now provably dead for
every read path a scalar cell can reach, not just the one the earlier
note checked.

(Retracted 2026-07-13: FALSE. Two more read paths that consult
`scalarCells` were still live and mirror-only at the time of this note --
`runPostIncrementExpression`'s `VarExp` arm (`i++`) and
`localPointerTarget`/`writePointerTarget` (`(*p)++`, atomics). "Provably
dead for every read path a scalar cell can reach" only held for the two
arms this note and the direct-read arm actually checked; it did not hold
for every arm. See the review-fix note below for what is now actually
verified.)

Focused runs, all green except the one known pre-existing failure:
`ut.backends.runner.lang.structs.struct.staticArrayCopyRunsPostblitAndDtors`
`.Interpreter`/`.Ctfe`/`.SystemLinker`/`.LLVMJit` (4 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.expressions` (318 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.sys.cstdlib` (88 run, 0 failed); `bin/ut -s ut.bin.repl`
(228 run, 0 failed). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (review fixes: cell invalidation on re-bind, two more
stale mirror-only read/write arms, sub-word reinterpret-write no longer
throws): a code review of the guest-level call site's four prior slices
above found four real gaps; all four are fixed by this commit, each with
its own red-then-green fixture in `tests/ut/backends/runner/lang/
expressions.d`, scoped `Interpreter`/`SystemLinker` like the surrounding
`pointer.*` fixtures.

Finding 1 (cell not invalidated on re-bind): `runDeclarationExpression`
and parameter binding wrote `locals[variable]` for a FRESH declaration/
parameter instance without ever removing a stale inherited `scalarCells`
entry for the same `VarDeclaration`. Recursion reuses the same AST
`VarDeclaration` at every call depth, and `child.scalarCells =
scalarCells.dup` hands a callee frame the caller's already-promoted cell;
a loop body re-executes the same `DeclarationExp` every iteration and hits
the same bug without recursion. Fixture `pointer.
recursiveDeclarationDropsStaleScalarCell` (a depth-1 `int x = depth; int*
p = &x;` recursion) and `pointer.loopRedeclaredLocalDropsStaleScalarCell`
(the same shape in a two-iteration `foreach`) were both red on
Interpreter, green on SystemLinker. Fix: `scalarCells.remove(variable)` at
the top of `runDeclarationExpression` (covers every one of its several
exit branches uniformly, since the whole function represents one binding
event) and in `bindFunctionParameters`/`bindLazyFunctionParameter`, right
before each writes `locals[parameter]`.

Finding 2 (`i++` read the boxed mirror): `runPostIncrementExpression`'s
`VarExp` arm did `variable in locals` directly, bypassing a promoted cell
-- stale once a cross-frame pointer write refreshes only the cell.
Fixture `pointer.postIncrementReadsPromotedScalarCell` (`i++` after a
callee writes through `&i`) was red on Interpreter, green on SystemLinker.
Fix: read via the new `readCelledLocal` helper (below) instead of the raw
`locals` lookup.

Finding 3 (`(*p)++`/atomics bypassed the cell): `localPointerTarget` and
`writePointerTarget`'s local-pointer arm only ever read/wrote `locals`,
never `scalarCells` -- the same class of bug as finding 2, for the
pointer-deref path instead of the direct-`VarExp` path. This pair also
backs the atomic hooks (`store`/`exchange`/`fetchAdd`/`fetchSub` via
`readPointerTarget`) and `localPointerByteSlice`, so fixing the pair fixed
those call sites too, with no separate fixture needed for them (per the
brief: fix the shared root, add a red test only where one was specified).
Fixture `pointer.
dereferencedPointerPostIncrementUsesPromotedScalarCell` (`(*p)++` on a
promoted `int` local) was red on Interpreter, green on SystemLinker. Fix:
`localPointerTarget` now returns `readCelledLocal(*variable)`;
`writePointerTarget`'s local-pointer arm now calls `writeCelledLocal`.

Finding 5 (sub-word reinterpret-write threw instead of narrowing):
`writeLocation`'s `PtrExp` cell arm called `writeScalar(pointeeType,
cell.bytes, value)`, which requires `cell.bytes.length ==
typeByteSize(pointeeType)` exactly and throws otherwise -- so `*cast(ubyte*)
&myUint = b` (a narrower pointee) threw, where the read side
(`reinterpretLocalPointerLoad`) already handled narrowing by slicing.
Fixture `pointer.subWordReinterpretWriteThroughPointerWritesLowByte`
(`ubyte* p = cast(ubyte*) &u; *p = oneByte;` on a `uint u`) was red on
Interpreter (threw), green on SystemLinker. Fix: when the pointee is a
NARROWER `native_scalar.isNativeScalarType` type, write into `cell.
bytes[0 .. typeByteSize(pointeeType)]` and re-derive `locals[variable]`
from the whole cell as before; when the pointee is not a native scalar
type at all, OR is a WIDER native scalar than the cell (a pre-existing
gap symmetric to `reinterpretLocalPointerLoad`'s own documented wider-read
gap, not this call site's to fix), fall through to the plain `locals[
*variable] = value;` write instead of throwing.

Shared helpers: introduced `readCelledLocal(VarDeclaration)` (cell, then
`locals`, then the type's default -- in that priority) and
`writeCelledLocal(VarDeclaration, Value)` (write the cell if one exists
and re-derive `locals` from it, else write `locals` directly), right after
`promoteScalarCell`. Every arm that reads/writes a celled local at the
variable's OWN storage type now routes through one of the two: the
`runPointerExpression` deref-read, `localPointerTarget`,
`runPostIncrementExpression`'s `VarExp` arm, `writePointerTarget`'s
local-pointer arm, `writeLocation`'s `VarExp` arm, and
`applyNativeWritebacks` (this last one was already correct before this
commit; routing it through the shared helper was a pure simplification,
no behaviour change). Two arms were deliberately NOT routed through
either helper: the `VarExp` direct-read arm in `runExpression` keeps its
own inline cell/`locals` check because it has a further data-segment/
`extern __gshared` fallback `readCelledLocal` does not (and should not)
replicate; `writeLocation`'s `PtrExp` arm keeps its own bespoke logic
because it writes at the POINTEE's type, not the variable's own type --
`writeCelledLocal`'s single-type contract does not fit a reinterpret
write.

What is verified cell-aware after this commit (precise, not a general
claim): every read of a celled `VarDeclaration` reachable through
`runExpression`'s `VarExp` arm, `runPointerExpression`'s `PtrExp` deref,
`localPointerTarget` (and therefore `pointerTargetValue`,
`readPointerTarget`, the atomic `load`/`exchange`/`fetchAdd`/`fetchSub`
hooks, and `localPointerByteSlice`), and `runPostIncrementExpression`'s
`VarExp` arm. Every write of a celled `VarDeclaration` reachable through
`writeLocation`'s `VarExp` and `PtrExp` arms (the latter for same-width or
narrower native-scalar pointees only), `writePointerTarget`'s
local-pointer arm (and therefore the same atomic/`(*p)++`/`+=` call
sites), and `applyNativeWritebacks`. Every fresh binding of a
`VarDeclaration` (`runDeclarationExpression`, `bindFunctionParameters`,
`bindLazyFunctionParameter`) now drops any stale inherited cell first.

What is STILL not verified/migrated, stated precisely so this is not
over-claimed the way the two retracted notes above were:

- `writeLocation`'s `PtrExp` arm's own fallback: when a promoted cell
  exists for `variable` but the pointee is not a native scalar type, or is
  a WIDER native scalar than the cell, the write lands only in `locals`,
  not the cell. A later DIRECT read of `variable` (which prefers the cell)
  would then see the pointer write's pre-existing stale cell bytes, not
  the value just written through `locals` -- the write-side mirror image
  of `reinterpretLocalPointerLoad`'s already-documented wider-read gap.
  No fixture reaches this (it requires a non-native-scalar or widening
  reinterpret cast of an already-cell-promoted scalar); not fixed here,
  flagged for whoever next touches this arm.
- The `arrayPointerVariable`-based pointer path (`writeThroughArrayPointer`,
  `readPointerElement`, `applyPointerElementsWritebacks`) was not audited
  for `scalarCells` coherence in this pass. It is architecturally distinct
  from the `localPointerId`/`scalarCells` mechanism these four findings
  live in (it tracks array-shaped locals via `allocationId`, not promoted
  native-byte cells), and none of the four findings' fixtures exercise it,
  but it was not positively verified either way.
- Non-scalar aggregates and raw-pointer locals still never get a
  `scalarCells` entry at all (unchanged from every prior note); they keep
  using the existing `locals`/alias-map machinery exclusively. Class
  objects remain completely untouched.

Focused runs, all green except the one known pre-existing failure: the
five new fixtures above (5/5, all confirmed red on Interpreter and green
on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (328 run, 0 failed); `bin/ut -s
ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (70 run, 0 failed); `bin/ut -s
ut.backends.runner.lang.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.sys.cstdlib ut.backends.ffi.dependency_image
ut.backends.runner.sys.concurrency` (151 run, 0 failed);
`ut.backends.runner.lang.structs.struct.staticArrayCopyRunsPostblitAndDtors`
`.Interpreter`/`.SystemLinker` (2 run, 0 failed); `bin/ut -s ut.bin.repl`
(228 run, 0 failed). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (review fixes, round 2: dataseg promotion hole,
`PtrExp` gap-(a) fallback throws instead of silently miswriting): a
follow-up re-review of the above found two more real gaps, fixed here.

Finding A (`promoteScalarCell` wrongly celled dataseg globals/statics):
`&g` on a module-level/`__gshared`/`static` variable routed through
`localPointerValue` into `promoteScalarCell`, which seeded a cell from
`defaultValue` (0) -- but a dataseg variable's real initializer is only
materialized lazily on first read, and the `VarExp` read arm already
consults a promoted cell before that lazy-initializer fallback. So
`&gValue` on `__gshared int gValue = 42;` made every later read of
`gValue` see 0 instead of 42, and also silently shadowed the
extern-data-symbol read/write arms (a native write never refreshes a
cell; a read would prefer the stale cell over the live native value).
Fixture `pointer.addressOfDatasegGlobalDoesNotShadowInitializer` was red
on Interpreter (`0 != 42`), green on SystemLinker. Fix: `promoteScalarCell`
now returns immediately when `variable.isDataseg`, before doing anything
else -- only true stack locals get cells; dataseg variables keep their
own storage/initializer/extern machinery untouched.

Finding B (the `PtrExp` gap-(a) fallback silently miswrote instead of
throwing): the previous round's note above ("What is STILL not
verified/migrated") flagged, but deliberately did not fix, that
`writeLocation`'s `PtrExp` cell arm falls through to a mirror-only
`locals` write when a promoted cell exists but the pointee is not a
native scalar (e.g. a struct) or is WIDER than the cell -- leaving the
cell stale, so a later direct read of the local (which prefers the cell)
silently returns the wrong, stale bytes. At base (before any of this
guest-scalar-cell work), the same program failed LOUDLY instead
("Expected integer-compatible scalar."), so turning that loud throw into
a silently wrong answer was a regression, not a neutral gap. Fixture
`pointer.structWriteThroughNonFittingScalarCellPointerWritesMemory`
(`S* p = cast(S*) &i; *p = S(42);` on an `int i`) pins the supported
SystemLinker oracle behavior (`i == 42`, real memory); Interpreter is
omitted from that fixture's backend matrix per the omit-don't-pin
convention, since it cannot yet model a struct-typed write into a native
scalar cell (future work). The companion fixture
`pointer.structWriteThroughNonFittingScalarCellPointerThrowsLoudly`
asserts the Interpreter-only diagnostic behavior instead: pre-fix it was
red with the silently-wrong `7 != 42` (the stale cell's old value winning
over the struct write); post-fix it throws "Unsupported interpreter
assignment target." Fix: in that same fallthrough branch, once the
narrower-native-scalar case has been ruled out, throw that message
instead of falling through to `locals[*variable] = value;`. The
non-celled fallthrough path (when no cell exists at all) is unchanged.

Full struct-into-scalar-cell support (actually writing a struct's bytes
into a promoted cell so the Interpreter matches SystemLinker rather than
throwing) remains future work; this round only replaces a silent wrong
answer with a loud, honest failure.

Focused runs for this round, all green except the two known
pre-existing failures (Bytecode's `sliceAssignmentWritesArrayStorage`
and `staticArrayCopyRunsPostblitAndDtors`, neither touched): the two new
fixtures above (confirmed red on Interpreter / green on SystemLinker
before the fix, green -- or throwing, for the diagnostic fixture -- after);
`bin/ut -s ut.backends.runner.lang.expressions`; `bin/ut -s
ut.backends.interpreter`; `bin/ut -s ut.backends.evaluator.eval`;
`bin/ut -s ut.backends.runner.lang.arrays`; `bin/ut -s
ut.backends.runner.sys.cstdlib ut.backends.ffi.dependency_image`;
`bin/ut -s ut.bin.repl`; `bin/ut -s ut.backends.runner.lang.imports
ut.backends.runner.lang.pollution`. The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (array-native storage's first guest call site: shared
element cell for `&a[i]`): item 7's "Migration order" bullet names arrays
first; this is that guest-level call site's first slice, the array
counterpart of the 2026-07-13 `scalarCells` work above. `impl.d`'s `Walker`
gains `private NativeArray[VarDeclaration] arrayCells;`, next to
`scalarCells`, an authoritative `NativeArray` cell for an address-taken
dynamic-array local whose element type is `native_scalar.
isNativeScalarType`. `arrayPointer` (the common path for `&a[i]`, called
from `addressOfExpression`'s `IndexExp` arm) now calls a new
`promoteArrayCell(source)` -- keyed by the slice-alias-resolved `source`,
matching `allocationId(source)`'s own key, so `arrayPointerVariable`'s
existing reverse lookup (`pointer.pointerAllocation in
arrayAllocationVariables`) and the new cell agree on which variable owns
the shared bytes. `promoteArrayCell` allocates the cell eagerly the first
time a qualifying array's address is taken (skipping `isDataseg` variables,
non-dynamic-array types, and non-native-scalar element types, mirroring
`promoteScalarCell`'s own guards), seeding it element-by-element from the
array's current boxed `Value` via `native_scalar.writeScalar`. Once a cell
exists, two call sites route through it instead of leaving `locals`'
`.dup`'d, detached elements as the only record: (1) `runPointerExpression`'s
array-pointer deref-read arm (`*p`, when `p` is not a `LocalPointer`) now
checks `arrayPointerVariable(value)` for a promoted `arrayCells` entry
before falling back to the boxed `pointer.pointerTarget` snapshot taken at
address-of time; (2) a new `writeThroughArrayCell(variable, index, value)`
helper, called from both `runIndexAssignExpression`'s plain-`VarExp` arm
(the actual code path for a bare `a[i] = x;` -- `runAssignExpression`
routes an `IndexExp` LHS there directly, NOT through `writeLocation`/
`writeIndexLocation`) and `writeIndexLocation`'s own plain-`VarExp` arm
(reached via `writeLocation`, e.g. a compound/nested assignment target),
`writeScalar`s the assigned value into the cell's `element(index)` bytes
whenever a cell exists, alongside each call site's pre-existing `locals`
mirror update. Every `Walker child` construction that already dupes
`scalarCells` (the same seven call sites the 2026-07-13 note counted) now
also does `child.arrayCells = arrayCells.dup;`, so a duped `NativeArray`'s
underlying bytes are shared by reference across a nested call frame,
mirroring `scalarCells`' own cross-frame sharing.

New fixture (pre-approved):
`pointer.arrayElementWrittenDirectlyIsVisibleThroughEarlierPointer` in
`tests/ut/backends/runner/lang/expressions.d`, scoped to
`Interpreter`/`SystemLinker` only (omitted elsewhere per the omit-don't-pin
convention) -- `int[] a = [one(), two()]; int* p = &a[0]; a[0] =
ninetyNine(); assert(*p == 99);`, every value seeded from a runtime function
call so DMD cannot fold it. SystemLinker's `p` aliases `a`'s real storage,
so the direct write is visible through `*p`. Confirmed red on Interpreter
before any production change (`1 != 99`: `p`'s own boxed element snapshot,
taken at address-of time, never saw the later direct write) and green on
SystemLinker; green on both after.

What this slice does NOT do, to be precise about item 7's array-phase
state: only a dynamic array whose element type is `native_scalar.
isNativeScalarType` gets a cell -- a static array, a non-scalar element
type (struct, class, nested array/slice), array growth (`~=`,
`.length = n`), and slice construction (`a[]`) are all untouched and keep
using the existing boxed/aliasing paths (`sliceAliases`,
`arrayAllocationAliases`, `writeThroughArrayPointer`'s own boxed writeback,
etc.) exactly as before. `writeIndexLocation`'s `DotVarExp` arm (a struct
field's array element) and `runIndexAssignExpression`'s `DotVarExp`/nested-
`IndexExp`/pointer-target arms do not consult `arrayCells` at all -- only
the plain-`VarExp` arm in each does. The existing boxed writeback
machinery (`arrayPointerWritebacks`, `ArrayElementAlias`,
`writeThroughArrayPointer`'s `locals`-only rewrite for a pointer-side
write, e.g. `*p = x` or `p[i] = x`) is completely unchanged -- this slice
only closes the DIRECT-write-then-pointer-read direction for a plain
scalar-element array local; a write THROUGH the pointer already reached
`locals` via the pre-existing mechanism, and a cross-frame array `&a[i]`
(the array counterpart of the 2026-07-13 cross-frame scalar fixture) has
no fixture yet, though the `child.arrayCells = arrayCells.dup` sharing
added here is expected to cover it for the same reason it did for scalars.
No `interpreter.md` §9.10 shim is retired by this slice.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (360 run, 0 failed); `bin/ut -s
ut.backends.runner.lang.arrays` (320 run, 0 failed -- the previously-known
`sliceAssignmentWritesArrayStorage.Bytecode`/
`staticArrayCopyRunsPostblitAndDtors.Bytecode` failures noted in the round
above are gone, from unrelated master merges, not this slice); `bin/ut -s
ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed); `bin/ut -s
ut.backends.runner.lang.structs` (281 run, 0 failed). The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (array-native storage's write-side closure: a write
THROUGH the pointer now also authors the shared `arrayCells` block): the
slice directly above closed the direct-write-then-pointer-read direction
(`a[0] = x; assert(*p == x);`) but left the opposite direction open --
`writeThroughArrayPointer` (the single function every `*p = x`/`p[k] = x`
write-through-pointer call site funnels through: `writeLocation`'s `PtrExp`
arm for a non-`LocalPointer` array-derived pointer, `runIndexAssignExpression`'s
two pointer-target arms, and `applyPointerElementsWritebacks`) only ever
wrote `locals`' detached, `.dup`'d array copy, never the promoted
`arrayCells` entry a deref-read (`runPointerExpression`) or a later direct
write (`writeIndexLocation`) actually consult. New fixture (pre-approved):
`pointer.arrayElementWrittenThroughPointerIsVisibleThroughSecondPointer` in
`tests/ut/backends/runner/lang/expressions.d`, scoped to
`Interpreter`/`SystemLinker` only (omitted elsewhere per the omit-don't-pin
convention) -- `int[] a = [one(), two()]; int* p = &a[0]; int* q = &a[0];
*p = ninetyNine(); assert(*q == 99);`, every value seeded from a runtime
function call so DMD cannot fold it. Confirmed red on Interpreter before any
production change (`1 != 99`: `q`'s own boxed element snapshot, taken at
address-of time, never saw the later write through `p`) and green on
SystemLinker (real aliased memory); green on both after. Fix:
`writeThroughArrayPointer`'s array-element branch (`current.isArray`) now
calls the same `writeThroughArrayCell(variable, index, value)` helper
`writeIndexLocation`/`runIndexAssignExpression`'s plain-`VarExp` write arms
already call, keyed by the same `arrayPointerVariable`-resolved variable the
pre-existing `locals` write already uses -- no new side table, one shared
`NativeArray` authority for both directions. `writeThroughArrayCell` is
already a no-op when no cell was ever promoted for the variable (a
non-native-scalar-element or static array, etc.), so this is a pure
addition alongside the existing `locals` write, not a behavior change for
anything outside item 7's narrow native-scalar-dynamic-array-element gating.
The scalar (non-array, `scalarWithByte`) branch of `writeThroughArrayPointer`
is untouched -- `arrayPointerVariable` only ever resolves to a variable
`promoteArrayCell` promoted while its boxed value was an array, so that
branch's variable never has an `arrayCells` entry to refresh.

What remains: a write through a pointer to a struct field's array element or
a nested-`IndexExp`/pointer-target write (the `DotVarExp` and other non-
plain-`VarExp` arms of `writeIndexLocation`/`runIndexAssignExpression`) still
does not consult `arrayCells` at all, matching the direct-write slice's own
scope note -- unchanged by this slice either. Array growth (`~=`, `.length =
n`) and slice construction (`a[]`) remain on the existing boxed/aliasing
paths. No `interpreter.md` §9.10 shim is retired by this slice.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (361 run, 0 failed); `bin/ut -s
ut.backends.runner.lang.arrays` (320 run, 0 failed); `bin/ut -s
ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (array-native storage extended to SLICE aliasing,
reverse direction: a write to the SOURCE is now visible through an
earlier-taken slice): the two slices above closed both directions of
POINTER aliasing (`&a[i]`); a guest `int[] s = a[];` was still handled
entirely by the pre-existing BOXED `sliceAliases`/`writeThroughSliceAlias`
machinery, which only ever propagated writes FORWARD (through `s`, into
`a`'s `locals` mirror) -- a direct write to `a` after `s` was created never
reached `s`'s own `locals` entry, a detached `.dup` snapshot taken at slice-
creation time, because a slice is not a real aliasing view in the boxed
model at all. New fixture (pre-approved):
`dynamicArray.directArrayWriteIsVisibleThroughEarlierFullSlice` in
`tests/ut/backends/runner/lang/arrays.d`, scoped to `Interpreter`/
`SystemLinker` only (omitted elsewhere per the omit-don't-pin convention)
-- `int[] a = [one(), two()]; int[] s = a[]; a[0] = ninetyNine(); assert(
s[0] == 99);`, every value seeded from a runtime function call so DMD
cannot fold it. Confirmed red on Interpreter before any production change
(`1 != 99`: `s`'s own boxed `.dup` snapshot never saw the later direct
write to `a`) and green on SystemLinker (real aliased memory); green on
both after.

Fix: two production changes in `impl.d`. (1) A new `promoteSliceArrayCell
(variable)`, called from `runDeclarationExpression`'s `SliceExp`-
initializer arm right after `recordSliceAlias` has resolved `variable`'s
own `SliceAlias`
(following any chain of nested slices to the ROOT source and the combined
lower bound, exactly as `recordSliceAlias` itself already does) -- a no-op
for a struct-field-rooted slice (`alias_.hasFieldIndex`, e.g. `val.field[]`,
out of this slice's scope) or when `promoteArrayCell(alias_.source)` itself
stays a no-op (a non-dataseg/dynamic-array/native-scalar-element guard
failure, mirroring `promoteArrayCell`'s own gating). Once the source has a
cell, `NativeArray.slice(begin, end)` -- already built for exactly this
(its own doc: "a write through the returned handle is visible through this
array and vice versa") -- gives a real, bidirectionally-aliasing sub-range
view over the SAME underlying bytes (`NativeBlock.subRange` slices the
block's own `ubyte[]`, sharing the GC allocation, not copying it); that
view becomes `arrayCells[variable]`, sized from `alias_.lower` and the
slice's own already-computed length (`locals[variable]`, the boxed dup
`runSliceExpression` just produced) -- ONE shared `NativeArray` authority
for source and slice, no new boxed reverse side-table. (2)
`runIndexExpression`'s plain-`VarExp` read arm (`a[i]`/`s[i]`, the actual
code path `index.e1.isVarExp` reaches) now checks `variable in arrayCells`
before falling back to `source[arrayIndex]` (the boxed value), reading
`readScalar(cell.elementType, cell.element(arrayIndex))` instead when a
cell exists -- mirroring the read-priority `runPointerExpression`'s deref
arm and `readCelledLocal` already give scalar cells. This was the missing
piece: before this slice, NOTHING ever consulted `arrayCells` on a whole-
array read path (only a pointer deref and the direct-write arms did), so
even giving `s` a shared cell would have been invisible to `s[0]` without
it. Confirmed the fix does not merely special-case the one fixture:
manually extended (in a scratch, uncommitted edit, reverted before this
commit) to a sub-slice (`int[] s = a[1 .. 3]; a[1] = ninetyNine();
assert(s[0] == 99);`) and a bidirectional case (`int[] s = a[]; int* p =
&a[0]; s[0] = ninetyNine(); assert(*p == 99 && a[0] == 99);`) -- both
passed on Interpreter with no further production change, confirming this
is genuine shared storage, not a snapshot patched to fit one shape.

What this slice does NOT do: a struct-field-rooted slice keeps using the
existing boxed `sliceAliases` machinery untouched, matching
`hasFieldIndex`'s existing gate elsewhere. Array growth (`~=`, `.length =
n`) on either the source or the slice remains on the existing boxed paths
-- `NativeArray.reserve`/`setLength`'s own documented reallocation
behaviour for a `borrowed` (sliced) block is "throw", so a promoted slice
cell would need a call site to rebind or fall back to boxed growth before
this slice's `arrayCells` entry could safely see `~=`/`.length =`; there is
no such call site yet. Only the plain-`VarExp` read arm of
`runIndexExpression` was extended to consult `arrayCells` -- a struct
field's array element (`DotVarExp`) and nested-`IndexExp` reads still read
the boxed value only, matching every other `arrayCells` call site's
existing plain-`VarExp`-only scope. No `interpreter.md` §9.10 shim is
retired by this slice.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (361 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.lang.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (slice-cell promotion guard: fixing a regression the
above slice introduced): the cerealed matrix test
`ut.backends.runner.lang.cerealed.multidimensionalArrayWritesNestedLengths`,
GREEN on master before the slice-aliasing work above, went RED on
Interpreter: `NativeArray.slice: end > length`, thrown from the last line of
`promoteSliceArrayCell`. Root cause: the fixture's `encode(int[][] values)`
grows a `ubyte[] bytes` local via repeated `~=` inside helper functions, and
separately does `foreach (row; values) { foreach (value; row) ... }`, whose
inner loop DMD lowers to a fresh `auto __r16 = row[];` on every OUTER
iteration. Each such re-declaration re-enters `promoteSliceArrayCell`, whose
`alias_.lower + length` (bounds computed against the CURRENT `row`) could
exceed `alias_.source`'s (`row`'s) cell length -- either because the source
had grown past its cell since the cell was promoted, or, as diagnosed here
with a temporary debug print, because `row` is the SAME `VarDeclaration`
reused every outer-loop pass, and `promoteArrayCell`'s own idempotent "already
has a cell, no-op" guard left `row`'s cell stuck at an EARLIER iteration's
(shorter) length once one had been promoted.

Fix, both in `promoteSliceArrayCell` (`impl.d`): (1) the guard the length
comparison already called for -- decline the promotion (return without
setting `arrayCells[variable]`) whenever `alias_.lower + length >
cell.length`, instead of handing that range to `NativeArray.slice`, which
throws. (2) Discovered only by testing (1) in isolation, which turned the
`end > length` throw into a DIFFERENT crash, `NativeArray.element: index out
of range`: `promoteSliceArrayCell` must also unconditionally
`arrayCells.remove(variable)` at entry, before the guard. Without it, a
declined promotion on a LATER binding of the same loop-reused `variable`
(e.g. `__r16` on the second outer-loop pass) left an EARLIER binding's
still-present, now-too-short cell in `arrayCells[variable]`, which a later
index read (`runIndexExpression`'s `arrayCells`-consulting arm) then indexed
out of range instead of falling through to the boxed `locals` value. Neither
fix touches `NativeArray.slice` or `promoteArrayCell` itself: a declined or
invalidated promotion leaves `variable` on the pre-existing boxed `locals` +
`writeThroughSliceAlias` aliasing path, exactly as it worked before this
promotion existed.

Confirmed red before the fix (`end > length`) and green after on the exact
regressed test, and confirmed slice 3's own fixture
(`dynamicArray.directArrayWriteIsVisibleThroughEarlierFullSlice`) still
green (its full-slice case has `lower == 0, length == cell.length` and still
promotes). Focused runs, all green: `bin/ut -s ut.backends.runner.lang.cerealed`
(164 run, 0 failed, 1/1 failing as expected); `bin/ut -s
ut.backends.runner.lang.arrays` (322 run, 0 failed); `bin/ut -s
ut.backends.runner.lang.expressions` (361 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The full
`bin/ut --random` was left to the orchestrator per the usual long-suite
handoff.

Progress 2026-07-14 (array-native storage's `ref`-element-alias gap: a write
through `foreach (ref e; a) e = ...;` now also authors the shared
`arrayCells` block): the four slices above closed direct-write, write-
through-pointer, and slice-aliasing paths, but left one write path
untouched: dmd lowers `foreach (ref e; a)` to a `ref` local bound to an
element of a (possibly slice-lowered) array temporary, which the
interpreter already models via `arrayElementAliases`/
`writeThroughArrayElementAlias` (`impl.d`) -- called from `writeLocation`'s
plain-`VarExp` arm whenever the written variable (`e`) is itself an
`ArrayElementAlias`. That function refreshed the alias source's `locals`
mirror and, when the source was itself slice-aliased, `sliceAliases`, but
never consulted `arrayCells` at all, so a write through `e` never reached a
cell an earlier-taken pointer's deref-read (`runPointerExpression`) actually
consults. New fixture (pre-approved):
`pointer.arrayElementWrittenByForeachRefIsVisibleThroughEarlierPointer` in
`tests/ut/backends/runner/lang/expressions.d`, scoped to
`Interpreter`/`SystemLinker` only (omitted elsewhere per the omit-don't-pin
convention) -- `int[] a = [one(), two()]; int* p = &a[0]; foreach (ref e; a)
e = e + ninetyNine(); assert(*p == 1 + 99);`, every value seeded from a
runtime function call so DMD cannot fold it. Confirmed red on Interpreter
before any production change (`1 != 100`: `p`'s cell, promoted at
address-of time, never saw the loop's writes, which only ever updated
`locals`) and green on SystemLinker (real aliased memory); green on both
after.

Fix: one production change in `impl.d`. `writeThroughArrayElementAlias` now
also calls `writeThroughArrayCell(alias_.source, alias_.index, value)` --
the same helper `writeIndexLocation`, `runIndexAssignExpression`'s plain-
`VarExp` arm, and `writeThroughArrayPointer` already call -- right after its
existing `locals`/`writeThroughSliceAlias` updates, keyed by the same
`alias_.source` (the array-typed variable `e`'s `ref` initializer indexed
into, e.g. the foreach lowering's own slice temporary) those existing
writes already use. `writeThroughArrayCell` is already a no-op when
`alias_.source` never had a cell promoted (a non-native-scalar-element or
static array, a struct-field-rooted alias, etc.), so this is a pure
addition alongside the existing `locals`/slice-alias writes, not a behavior
change outside item 7's narrow native-scalar-dynamic-array-element gating.
No new side table: `arrayElementAliases` and `arrayCells` are both existing
tables, keyed by the same `VarDeclaration`.

What remains: a `ref` alias to a struct field's array element or a nested-
index alias (anything not reaching `arrayElementAliases` in the first
place) is still untouched, matching every other `arrayCells` call site's
existing plain-`VarExp`-only scope. Array growth (`~=`, `.length = n`) and
non-full slice construction guards from the prior slices are unaffected.
Cross-frame pointer aliasing (a callee writing through a caller's `&a[i]`
pointer, or a callee taking `&a[i]` of a caller's `ref` array parameter) is
untested by this slice -- the `child.arrayCells = arrayCells.dup` sharing
already in place is expected to cover it for the same reason it does for
scalars, but no fixture yet confirms it. No `interpreter.md` §9.10 shim is
retired by this slice.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (363 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.lang.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed);
`bin/ut -s ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (array-native storage's compound/post-increment gap: a
write through `(*p)++`/`*p += x` on an array-element pointer now also
authors the shared `arrayCells` block, both ways): the five slices above
closed direct-write, write-through-pointer (`*p = x`), slice-aliasing, and
`foreach (ref e; a)` writes, but a compound or post/pre-increment write
through an array-element pointer took a wholly different code path that
never touched `arrayCells` at all, on EITHER side. `(*p)++`,
`runAddAssignExpression`'s `+=`, and the `core.internal.atomic` load/store/
exchange/fetchAdd/fetchSub hooks all read the pointer's current target via
`pointerTargetValue` and write the result back via `writePointerTarget`
(`impl.d`) -- both distinct from `writeLocation`'s own `*p = x` assignment
arm, which already called `writeThroughArrayPointer`. `pointerTargetValue`
fell straight to `pointer.pointerTarget` (the boxed snapshot taken at
address-of time) for any non-local, non-native pointer, never checking
`arrayCells` the way `runPointerExpression`'s deref-read arm already did;
`writePointerTarget`'s equivalent fallback, `writeLocation(expression,
pointer.withPointerTarget(value))` (`expression` there being the pointer
variable's OWN `VarExp`, e.g. `p`, not `*p`), only rewrote `p`'s own boxed
local value with a new embedded target -- never `a`'s `locals` mirror or
its `arrayCells` entry.

New fixture (pre-approved):
`pointer.arrayElementPostIncrementedThroughPointerIsVisibleDirectly` in
`tests/ut/backends/runner/lang/expressions.d`, scoped to `Interpreter`/
`SystemLinker` only (omitted elsewhere per the omit-don't-pin convention) --
`int[] a = [one(), two()]; int* p = &a[0]; (*p)++; assert(a[0] == 2 && *p ==
2);`, every value seeded from a runtime function call so DMD cannot fold it.
Confirmed red on Interpreter before any production change (`assert(a[0] ==
2 && (*p == 2))` failed: neither side ever moved off 1, since the increment
only ever rewrote `p`'s own boxed value, not `a`'s storage or its cell) and
green on SystemLinker (real aliased memory); green on both after.

Fix, two production changes in `impl.d`, both reusing the existing
`arrayCells`/`arrayPointerVariable`/`writeThroughArrayPointer` machinery --
no new side table. (1) A new `arrayPointerCellValue(pointer, out value)`
helper extracted from `runPointerExpression`'s array-pointer read arm
(behaviour unchanged there, now calling the shared helper); `
pointerTargetValue` calls it before falling back to `pointer.pointerTarget`,
so the read side of a compound/increment/atomic op sees the same
cell-authoritative bytes a plain `*p` deref already did. (2)
`writePointerTarget`'s array-pointer fallback now calls
`writeThroughArrayPointer(pointer, value)` first (returning immediately on
success), placed right after the existing native/local-pointer checks and
before the `AddrExp`/`CastExp`/boxed-rewrite fallback -- the same placement
`writeLocation`'s own `*p = x` arm already uses. `writeThroughArrayPointer`
already refreshes both `locals` and, when promoted, `arrayCells`, so this
closes the write side the same way the four prior slices did for their own
call sites; it is a no-op (returns `false`, unchanged behaviour) for every
pointer `arrayPointerVariable` does not resolve (a `LocalPointer`, a native
pointer, or a `&s.field` snapshot), so nothing outside item 7's narrow
native-scalar-dynamic-array-element gating changes.

Verified this is not a fixture-shaped patch: manually extended (in a
scratch, uncommitted edit, reverted before this commit) to `*p += ninetyNine
();` (`runAddAssignExpression`'s compound-assignment path, a different call
site than post-increment but funnelled through the same two functions) --
`assert(a[0] == 100 && *p == 100);` passed on Interpreter with no further
production change. The `core.internal.atomic` load/store/exchange/fetchAdd/
fetchSub hooks (`runAtomicHookCall`) funnel through the identical
`readPointerTarget`/`writePointerTarget` pair and are expected to be fixed
for the same reason, but have no fixture confirming it.

What remains: a compound/increment write through a pointer to a struct
field's array element, or one derived from a nested `IndexExp` (any pointer
`arrayPointerVariable` does not resolve to a plain array-local variable),
is untouched, matching every other `arrayCells` call site's existing
plain-variable-only scope. Cross-frame array-pointer aliasing (item 7's
"Migration order" bullet: a callee writing through a caller's `&a[i]`, or a
callee taking `&a[i]` of a caller's `ref` array parameter) remains
untested by any slice so far -- the `child.arrayCells = arrayCells.dup`
sharing already in place is expected to cover it for the same reason it
does for scalars, but still no fixture confirms it; it is the next
candidate to try. Array growth (`~=`, `.length = n`) and non-full slice
construction guards from the prior slices are untouched by THIS slice's own
change (correction, 2026-07-14 review fixes below: "unaffected" here
understated the actual risk -- once a slice or `&a[i]` had promoted a cell,
`~=` growing the same variable left that cell stranded at its old length,
a real stale-read/throw bug fixed only later, as finding 3 of that review).
No `interpreter.md` §9.10 shim is retired by this slice.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (365 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.lang.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Progress 2026-07-14 (cross-frame array-pointer aliasing: a callee taking
`&a[i]` of a caller's `ref` array parameter now refreshes the caller's own
`arrayCells` entry, closing the last untested item-7 candidate the prior
slice flagged): two candidates were tried, in order.

Candidate (a) -- a callee writes through an ordinary BY-VALUE `int*`
parameter into the caller's array element, the caller reading back both
through its own still-live pointer and directly:
`void put(int* p, int v) { *p = v; } ... int[] a = [one(), two()]; int* p =
&a[0]; put(p, ninetyNine()); assert(*p == 99 && a[0] == 99);`. Tried first
and found GREEN on Interpreter already -- a genuine characterization, not a
gap. Reasoning, confirmed by re-reading the call machinery rather than
assumed: `arrayPointerVariable(pointer)` resolves `p`'s pointer to the SAME
`VarDeclaration` (`a`) in every frame (the value carries the allocation id,
not a re-derived AST lookup); `child.arrayCells = arrayCells.dup` shares
that entry's underlying `NativeArray`/`NativeBlock` bytes by reference, so
the callee's `writeThroughArrayPointer` write lands in memory the caller's
own cell already aliases, before any writeback ever runs. `a[0]`'s direct
read (`runIndexExpression`) also turned out to prefer a promoted `arrayCells`
entry over the boxed `locals` mirror once one exists (found while
investigating this slice -- the same cell-priority discipline
`readCelledLocal` already documented for scalars, previously unnoticed for
plain array-index reads), so even a lagging boxed-`locals` writeback
(`writeBackArrayPointerTargets` copies `child.locals[variable]` back
unconditionally for a dynamic array, unlike `writeBackLocalPointerTargets`'s
explicit `scalarCells` skip) is harmless here: both `*p` and `a[0]` read the
same shared, already-current cell bytes regardless.

Candidate (b) -- a callee takes `&a[i]` of a caller's array passed by `ref`
and writes through it: `void bump(ref int[] a) { int* q = &a[0]; *q =
ninetyNine(); } ... int[] a = [one(), two()]; int* p = &a[0]; bump(a);
assert(*p == 99 && a[0] == 99);`. This one is genuinely RED on Interpreter.
Root cause, isolated by splitting the assert and by testing a plain `a[0] =
ninetyNine();` ref-parameter write with no address ever taken (green) versus
the same write with the caller having taken `&a[0]` first (red on the
DIRECT `a[0]` read alone, "1 != 99", before `*p` was even consulted): a
`ref int[]` parameter is its own, distinct `VarDeclaration` from the
caller's array, so `&a[0]` inside `bump` promotes a brand-new, unrelated
`arrayCells` entry for the PARAMETER, never touching the caller's own
already-promoted cell. `writeBackRefArguments` -- the ONLY call site that
funnels a `ref` parameter's final value back to the caller -- routes a
plain dynamic-array target through `writeLocation`'s plain-`VarExp` arm,
i.e. `writeCelledLocal`, which (until this slice) refreshed a promoted
`scalarCells` entry but had no equivalent branch for `arrayCells` at all: it
correctly updated the boxed `locals` mirror to the callee's final array
value, but left the caller's OWN `arrayCells` entry holding stale bytes --
exactly the entry both `*p`'s deref-read and (per the candidate-(a)
finding above) `a[0]`'s own direct read now prefer over `locals`. Confirmed
red on Interpreter before any production change and green on SystemLinker
(`ref` genuinely aliases the caller's storage); green on both after.

New fixture (pre-approved):
`pointer.arrayElementWrittenThroughRefParameterPointerVisibleToEarlierCallerPointer`
in `tests/ut/backends/runner/lang/expressions.d`, scoped to `Interpreter`/
`SystemLinker` only (omitted elsewhere per the omit-don't-pin convention).

Fix, one production change in `impl.d`: `writeCelledLocal` gained an
`arrayCells` branch alongside its existing `scalarCells` one, same
cell-then-mirror pattern. When `variable in arrayCells` and the incoming
value's length matches the cell's length -- the in-place-mutation case this
bug exercises -- every element's bytes are rewritten into the cell from the
incoming array value, exactly as `promoteArrayCell` seeds a fresh cell. A
length MISMATCH (a genuine rebind to differently-sized storage, which a
native cell cannot represent) instead drops the stale cell
(`arrayCells.remove(variable)`) so later reads fall back to boxed `locals`,
mirroring `promoteSliceArrayCell`'s existing decline-rather-than-corrupt
guard for a drifted length. No new side table; `writeCelledLocal` is the
same helper `writeLocation`'s `VarExp` arm already called for every direct
variable write, scalar or not, so nothing outside a variable that already
has a promoted `arrayCells`/`scalarCells` entry changes behaviour.

What remains: the same narrow scope as every other `arrayCells` call site --
only a plain array-typed local or `ref` parameter reached via a bare
`VarExp`; a struct-field-rooted or nested-index array target is untouched.
The length-mismatch drop path (a `ref` parameter wholesale-reassigned to a
different-length array while the caller's original had a promoted cell) has
no dedicated fixture of its own; only the same-length in-place path this
slice's fixture exercises is confirmed. No `interpreter.md` §9.10 shim is
retired by this slice. This closes the last cross-frame array-pointer
candidate the prior slice's "What remains" flagged as untested.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (367 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.lang.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (chained/nested slice coherence: array-cell coherence
is saturated for these cases, no gap found): the prior slices closed direct-
write, write-through-pointer, slice-aliasing (full slice only), `foreach
(ref)`, compound/atomic, and cross-frame `ref`-array writeback. This slice
tried the deeper chained/nested slice shapes item 7's migration order still
listed as untested: (a) a pointer taken into a SLICE, source write visible
through it (`int* p = &s[1]` where `s = a[]`); (b) sub-slice (non-zero lower
bound) reverse propagation (`s = a[1 .. 3]`, write to `a[2]`, read `s[1]`);
(c) slice-of-a-slice (chained, `t = s[1 .. 3]` where `s = a[1 .. 4]`),
reverse propagation through TWO aliasing hops to the root; (d) two
independent slices of the same array observing each other's writes THROUGH
one of the slices, not the root (`s[0] = x; assert(u[0] == x);` where both
`s` and `u` are `a[]`). All four were probed as scratch fixtures (built and
run, not committed) and all four came back GREEN on Interpreter (and
SystemLinker) with zero production changes -- no genuine red found.

Reasoning why, confirmed by re-reading rather than assumed: `recordSliceAlias`
already resolves every slice-of-a-slice to its ROOT source with a combined
lower bound at record time (`if (auto alias_ = source in sliceAliases)
sliceAliases[variable] = SliceAlias(alias_.source, alias_.lower + lower)`),
so a `sliceAliases` entry never nests -- (c)'s `t` points directly at `a`
with the correctly combined offset, and `promoteSliceArrayCell(t)` slices
the SAME root cell `promoteSliceArrayCell(s)` already sliced, not a view of
`s`'s own view. `arrayPointer`'s `&s[1]` (case (a)) resolves through the
same one-hop `variable in sliceAliases` lookup and promotes/reads the root's
cell using the boxed model's own `arrayAllocationOffset` bookkeeping for the
index math, which already tracked slice offsets before any of this native
work existed. Case (d) reduces to `NativeArray.slice`'s own documented
contract -- a sub-range view over the SAME underlying bytes, not a copy --
so a write through `s`'s cell view is a write to the identical bytes `u`'s
cell view (of the same root) reads. No new call site needed to consult
`arrayCells` for any of the four shapes; every one already routes through
existing cell-priority read/write arms keyed by the root-resolved variable.

Per the task's own fallback (do not fabricate a failure when saturated),
kept case (a) as a genuine characterization fixture with NO production
change: `pointer.
arrayElementWrittenDirectlyIsVisibleThroughPointerIntoEarlierSlice` in
`tests/ut/backends/runner/lang/expressions.d`, scoped to `Interpreter`/
`SystemLinker` only (omitted elsewhere per the omit-don't-pin convention) --
`int[] a = [one(), two(), three()]; int[] s = a[]; int* p = &s[1]; a[1] =
ninetyNine(); assert(*p == 99);`, every value seeded from a runtime function
call so DMD cannot fold it. Green on Interpreter and SystemLinker with no
production change, characterizing rather than exposing a gap.

What remains: array growth (`~=`, `.length = n`) on a chained/nested slice
or its root, and a struct-field-rooted slice's own chaining, are still
untouched, matching every prior slice's own scope notes -- unchanged by
this slice, which made no production changes at all. No `interpreter.md`
§9.10 shim is retired by this slice.

Focused runs, all green: the new characterization fixture (green on
Interpreter and SystemLinker, no production change); `bin/ut -s
ut.backends.runner.lang.expressions` (369 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.lang.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Progress 2026-07-14 (struct phase starts: scalar-field native cell, reverse
propagation through `&s.field`): item 7's "Migration order" bullet moves to
its second named phase -- "Structs second, reusing the same block/offset
machinery" -- now that the array phase above is saturated. This is the
FIRST struct-phase slice; it closes exactly one gap and leaves most struct
cases boxed, precisely as the array phase's own first slice did for `&a[i]`.

Confirmed red first: `struct S { int x; int y; } int f() { S s =
S(one(), two()); int* p = &s.x; s.x = ninetyNine(); return *p; }` (all three
values seeded from runtime function calls) returned `1` on the Interpreter
-- `*p` still read the boxed snapshot `&s.x` took at address-of time, not
`s`'s later direct write -- while SystemLinker's real aliasing gave `99`.
Committed as `pointer.
structFieldWrittenDirectlyIsVisibleThroughEarlierPointer` in `tests/ut/
backends/runner/lang/expressions.d`, scoped to `Interpreter`/`SystemLinker`
only.

Production change, `source/quickbite/backends/interpreter/impl.d`: a new
`NativeStruct[VarDeclaration] structCells` map, parallel to `arrayCells`,
plus a reverse lookup (`structFieldPointerVariables`/
`structFieldPointerFieldIndices`, `VarDeclaration`/`size_t` keyed by a
`&s.field` pointer's existing `fieldSnapshotAllocationId`) mirroring
`arrayAllocationVariables`. `addressOfExpression`'s `DotVarExp` arm --
exactly where `&s.field`'s read-only snapshot has always been built -- now
also calls the new `promoteStructFieldCell`: for a scalar field
(`native_scalar.isNativeScalarType`) of a plain (non-dataseg) struct
LOCAL resolved from a bare `VarExp` receiver, it promotes a `structCells`
entry (`promoteStructCell`, seeded from the struct's current boxed field
values via a new `writeStructCellScalarFields` helper that walks
`NativeStruct.fieldCount`/`fieldDeclaration`/`field` and skips non-scalar
fields) and records the pointer's id in the reverse lookup. Three read/write
call sites now consult that cell ahead of the boxed fallback, mirroring the
array phase's own three: `writeCelledLocal` (the direct-field-write path --
`s.x = v` rewrites the WHOLE struct via `writeLocation`'s `DotVarExp` arm,
which recurses into the `VarExp` arm this helper already owns, so it now
also refreshes every scalar field's bytes in the cell, or drops the cell if
the new boxed value is no longer a struct at all) and a new
`structFieldPointerCellValue` helper (the counterpart of
`arrayPointerCellValue`), consulted by both `runPointerExpression` (`*p` as
an rvalue) and `pointerTargetValue` (compound-assignment/atomic/post-
increment reads, for parity with the array cell even though no fixture in
this slice exercises that path). `child.structCells = structCells.dup;`
added at the same 7 child-frame-spawn sites that already dup
`scalarCells`/`arrayCells`, so a nested call sees the promoted cell too
(sharing its bytes by reference, exactly as `scalarCells`/`arrayCells` do --
no pop-back merge is needed or added, matching those two). Writing THROUGH
the pointer (`*p = v`) is deliberately left untouched: the id is still
recorded in `fieldSnapshotAllocationIds` exactly as before, so
`writeLocation`'s `PtrExp` arm continues to refuse it with "Unsupported
interpreter assignment target." -- the existing pinned
`pointer.addressOfStructFieldWriteThroughUpdatesField.Interpreter`
fixture is unchanged and still green.

What this slice does NOT do, to be precise about item 7's struct-phase
state: only an address-taken SCALAR field of a plain, non-dataseg struct
LOCAL gets a cell. Nested-struct fields, array fields, class fields, union
fields, and any struct reached through anything other than a bare local
variable (a class field, an array element, a `new`-allocated struct, a
dataseg/`__gshared` struct) are all untouched and stay on the pre-existing
boxed `locals` path. Writing THROUGH the pointer (`*p = v`) still throws
rather than aliasing, as it did before this slice -- only the
direct-write/reverse-read gap this slice's fixture named is closed. Cross-
frame struct-field-pointer dereference (a pointer into a caller's struct,
passed by argument into and dereferenced inside a callee) is unexercised:
`structCells` itself is duped into child frames, but the reverse-lookup
maps are not, matching the task's own bounded instruction; no fixture in
this slice needs it. No `interpreter.md` §9.10 shim is retired by this
slice.

Focused runs, all green: the new fixture (green on Interpreter and
SystemLinker); `bin/ut -s ut.backends.runner.lang.expressions` (371 run, 0
failed, 5/5 failing as expected); `bin/ut -s ut.backends.runner.lang.structs`
(281 run, 0 failed); `bin/ut -s ut.backends.runner.lang.arrays` (322 run, 0
failed); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (struct field write-through-pointer: `*p = v` through
`&s.field` now aliases via the native cell): the previous slice's own "What
this slice does NOT do" named the gap directly -- writing THROUGH a
`&s.field` pointer still threw "Unsupported interpreter assignment target."
even after that slice gave the receiver a `structCells` entry. This slice
closes exactly that gap for the same narrow, already-cell-supported case.

The existing fixture `pointer.addressOfStructFieldWriteThroughUpdatesField`
(`tests/ut/backends/runner/lang/expressions.d`) turned out to already BE that
exact case: `struct Holder { int value; }`, `auto a = Holder(seed)` (a
plain, non-dataseg struct LOCAL with one scalar field), `int* p =
&a.value;` (address-of a scalar field via a bare `VarExp` receiver) -- so
this was a promotion, not a new fixture. The two backend-split blocks (a
`SystemLinker`-only real-value assertion, and an `Interpreter`-only
`shouldThrowWithMessage("Unsupported interpreter assignment target.")`
pinning the refusal) were merged into a single `AliasSeq!(Interpreter,
SystemLinker)` block asserting the same `a.value == 5` both backends now
agree on, matching the sibling
`structFieldWrittenDirectlyIsVisibleThroughEarlierPointer` fixture's shape.
Confirmed RED first: with only the test change applied (production code
unchanged), `bin/ut -s ut.backends.runner.lang.expressions` reported exactly
one new failure, `pointer.addressOfStructFieldWriteThroughUpdatesField.
Interpreter` (still throwing, now wrongly so per the updated expectation).

Production change, `source/quickbite/backends/interpreter/impl.d`: a new
`writeThroughStructFieldPointer` helper, the write-through-pointer
counterpart of the read-side `structFieldPointerCellValue` (and the
struct-field analogue of `writeThroughArrayPointer`/`writeThroughArrayCell`
for array elements). Given the pointer value, it looks the allocation id up
in `structFieldPointerVariables`/`structFieldPointerFieldIndices` (the
reverse lookup the previous slice populated) to find the receiver's
`structCells` entry and field index; if any of that lookup misses, or the
receiver's current boxed `locals` value is no longer a struct, it returns
`false` and does nothing, leaving every other case exactly as refused as
before. On a hit, it writes the value's bytes straight into the cell's
field slice (`NativeStruct.field(index)` + `native_scalar.writeScalar`,
sized by the field's own declared type) and re-derives the boxed `locals`
mirror as `current.withStructField(index, value)`, mirroring
`writeCelledLocal`'s cell-then-mirror discipline. `writeLocation`'s
`PtrExp` arm now calls this helper right after `writeThroughArrayPointer`
and before the existing `fieldSnapshotAllocationIds` refusal check, so only
a field pointer WITHOUT a promoted cell still reaches that throw. No new
side-table, no name-based shim: the write goes through the same
block/offset machinery the previous slice already stood up.

What remains: the refusal ("Unsupported interpreter assignment target.")
still stands for every struct-field pointer without a `structCells` entry
-- a nested-struct field, an array field, a class field, a union field, or
any struct reached through anything other than a bare local variable (a
class field, an array element, a `new`-allocated struct, a
dataseg/`__gshared` struct) -- exactly item 7's struct-phase scope as
stated by the previous slice. Cross-frame struct-field-pointer dereference
(a pointer into a caller's struct, write-through-pointer from inside a
callee) remains unexercised: the reverse-lookup maps are still not duped
into child frames, matching the previous slice's own bounded instruction;
no fixture in this slice needs it. No `interpreter.md` §9.10 shim is
retired by this slice.

Focused runs, all green: `bin/ut -s ut.backends.runner.lang.expressions` (371
run, 0 failed, 5/5 failing as expected); `bin/ut -s
ut.backends.runner.lang.structs` (281 run, 0 failed); `bin/ut -s
ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (review fixes: cell invalidation on fresh binding and
array rebind): a Fable code review of the array/struct cell slices above
found two blockers, both stale-cell correctness bugs distinct from anything
those slices' own fixtures exercised.

Finding 1: the 2026-07-13 scalar slice established that a FRESH declaration/
parameter binding of a `VarDeclaration` must drop any stale cell inherited
for it -- recursion reuses the same AST `VarDeclaration` at every call
depth, a loop body re-executes the same `DeclarationExp` every iteration,
and `child.scalarCells/arrayCells/structCells = ....dup` shares a promoted
cell's underlying bytes into every child frame by reference -- but that
rule (`scalarCells.remove(variable)` at the three fresh-binding sites:
`runDeclarationExpression`, `bindFunctionParameters`, and
`bindLazyFunctionParameter`) was applied to `scalarCells` only, never
extended to the `arrayCells`/`structCells` maps the array and struct phases
added afterward. Three new fixtures exposed this for real: (1a)
`dynamicArray.nestedForeachDropsStaleArrayCellOnFreshRowBinding`
(`tests/ut/backends/runner/lang/arrays.d`) -- a nested `foreach` over an
array-of-arrays, where dmd lowers the inner loop's slice temporary to a
fresh `auto __r = row[];` every outer iteration and `promoteSliceArrayCell`
promotes `row` itself eagerly (no address-of needed at all), so the second
outer iteration's inner sum read back the first iteration's stale cell
bytes -- confirmed red on Interpreter (`4 != 6`, the reviewer's own
predicted wrong answer) and green on SystemLinker; (1b)
`pointer.recursiveArrayDeclarationDropsStaleArrayCell`
(`tests/ut/backends/runner/lang/expressions.d`) -- a recursive function
re-declaring `int[] a` and taking `&a[0]` at each depth, confirmed red
(`1001 != 1100`); (1c)
`pointer.recursiveStructDeclarationDropsStaleStructCell` (same file) -- the
struct sibling, a recursive function re-declaring `S s` and taking `&s.x` at
each depth, confirmed red (`1001 != 1100`). Fixture 1c required one design
correction found only by testing: an initial version computed `s`'s
per-depth value with a ternary directly in the struct declaration
(`S s = depth == 0 ? S(a) : S(b);`) and came back GREEN with no production
change -- not because the bug was absent, but because dmd lowers a
struct-typed ternary initializer to a default-init followed by a plain
assignment (`s = ...;`), which routes through the EXISTING
`writeLocation`/`writeCelledLocal` path and happens to refresh the stale
cell as a side effect, masking exactly the gap under test. Moving the
ternary into a plain scalar-returning helper (`valueForDepth`) so the struct
declaration itself is a straightforward call-initializer restored the red
result. Fix: `arrayCells.remove(variable)` added alongside the existing
`scalarCells.remove(variable)` at all three fresh-binding sites; for
`structCells`, a new `dropStructCell(variable)` helper (used at the same
three sites in place of a bare `structCells.remove`) additionally walks
`structFieldPointerVariables`/`structFieldPointerFieldIndices` (the `&s.
field` reverse lookup) and removes every entry that pointed at `variable`,
so a stale allocation id from a dropped cell cannot later resolve into
whatever cell a subsequent, unrelated binding of the same `VarDeclaration`
promotes next. All three fixtures confirmed green after, with no other
production change.

Finding 2: `writeCelledLocal`'s `arrayCells` branch treated ANY same-length
whole-array value as an in-place byte mutation into the cell's existing
storage -- correct for the ONE caller it was built for
(`writeBackRefArguments`'s cross-frame `ref int[]` parameter writeback,
where the callee's final value genuinely represents the SAME storage,
mutated through the alias), but `writeLocation`'s plain-`VarExp` arm routes
EVERY direct-variable write through the same helper, including a plain
source-level `s = b;`, which REBINDS `s` to `b`'s storage rather than
mutating whatever `s` used to alias. When `s` was a slice view sharing its
cell with a root array `a` (`int[] s = a[];`), the buggy in-place refresh
wrote `b`'s bytes into `a`'s own block. New fixture (confirmed red):
`dynamicArray.wholeArrayRebindDoesNotWriteThroughStaleSliceCell`
(`tests/ut/backends/runner/lang/arrays.d`) -- `int[] a = [one(), two()]; int[]
s = a[]; int[] b = [eight(), nine()]; s = b; return a[0];` -- red on
Interpreter (`8 != 1`: `a[0]` corrupted to `b`'s first element) and green on
SystemLinker (a real rebind never touches `a`'s storage). Fix:
`writeCelledLocal` gained an `arrayIsRefWriteback` parameter (default
`false`); its `arrayCells` branch now only takes the same-length in-place-
refresh path when that parameter is `true`, and drops the cell
unconditionally otherwise (no length check -- a rebind is a rebind
regardless of length). `writeLocation` gained a matching
`arrayRefWriteback` parameter (default `false`, threaded through its own
`CastExp` recursion and passed to `writeCelledLocal`), and
`writeBackRefArguments`'s general write-back call
(`writeLocation(argument, *value)`, the fallback reached for a bare
`VarExp` cross-frame `ref` array argument) now passes `true` explicitly;
every other `writeLocation` call in the codebase keeps the default `false`,
so a plain assignment's cell handling did not change. Confirmed both the
new fixture and the existing cross-frame `ref`-array fixture
(`pointer.arrayElementWrittenThroughRefParameterPointerVisibleToEarlierCallerPointer`)
are green together after the fix -- the ref-writeback path still refreshes
in place, and a plain rebind no longer corrupts an aliased source. The
STRUCT branch of `writeCelledLocal` was not touched: struct assignment
genuinely copies into the receiver's storage in D, so its existing
always-refresh-or-drop behaviour was already correct and remains unchanged.

Focused runs, all green: all four new fixtures (each confirmed red on
Interpreter / green on SystemLinker before the fix, green on both after);
`bin/ut -s ut.backends.runner.lang.expressions` (375 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.runner.lang.arrays` (326 run, 0
failed); `bin/ut -s ut.backends.runner.lang.structs` (281 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Progress 2026-07-14 (review fixes: append and slice-assign cell coherence):
a second Fable code review of the same array/struct cell slices found two
more blockers, both in the same "a promoted `arrayCells` cell is
READ-AUTHORITATIVE over the boxed `locals` mirror" family as the pair fixed
immediately above, this time on the WRITE side of the two ops that change
an array's contents wholesale rather than one element at a time.

Finding 3: `runArrayAppendAssignExpression`'s plain-`VarExp` arm (`a ~= x`)
grew `locals[variable]` (via `withAppendedArrayElement`) and dropped
`sliceAliases`, but never touched a promoted `arrayCells` entry, which stays
at its old, pre-append length -- a fixed-size `NativeArray` allocated once,
at promotion time. A cell can be promoted with NO address-of at all: `int[]
s = a[];` eagerly promotes `a`'s own cell via `promoteSliceArrayCell`. New
fixture (pre-approved, confirmed red on Interpreter / green on
SystemLinker): `dynamicArray.appendRefreshesSlicePromotedStaleCell`
(`tests/ut/backends/runner/lang/arrays.d`) -- `int[] a = [one()]; int[] s =
a[]; a ~= two(); return a[1];` -- red (`NativeArray.element: index out of
range`: the plain read of the newly-appended index went through
`readIndexExpression`'s cell arm against the stale, length-1 cell instead of
the grown `locals` mirror). A sibling fixture with an explicit `&a[0]`
address-of, `pointer.arrayAppendRefreshesStaleCellAfterAddressOf`
(`tests/ut/backends/runner/lang/expressions.d`) -- `int[] a = [one()]; auto p
= &a[0]; a ~= two(); a[1] = five(); return a[1];` -- confirmed the same
failure mode via a different promotion path. Fix: `arrayCells.remove
(variable)` added to the append arm, alongside the existing `sliceAliases.
remove(variable)` -- matching D's own "append may reallocate, old pointers
go stale" semantics (a cell cannot be resized in place; growth may have
moved the storage even in real D), and the same decline-rather-than-corrupt
choice `promoteSliceArrayCell`'s own drifted-length guard and
`writeCelledLocal`'s length-mismatch arm already make. A later read falls
through to the fresh, correctly-grown `locals` mirror.

Finding 4: `runSliceAssignExpression` (`a[] = x` and `a[i .. j] = x`) wrote
`locals[variable]` directly from a freshly-built `elements` array but never
consulted `arrayCells` at all, so a promoted cell (again reachable with no
address-of, via a slice) kept answering `readIndexExpression`'s cell-arm
reads with its pre-assignment bytes. New fixture (pre-approved, confirmed
red / green): `dynamicArray.sliceFillAssignmentWritesThroughSlicePromotedCell`
(`arrays.d`) -- `int[] a = [one(), two()]; int[] s = a[]; a[] =
ninetyNine(); return a[0];` -- master (SystemLinker) `99`; Interpreter
before any fix did not merely return the reviewer-predicted stale `1`, it
threw `Expected array.` Writing this fixture surfaced a THIRD, pre-existing
bug in the same function, not previously covered by any fixture:
`isBlockSliceAssignment`'s non-`block` branch unconditionally treated the
assignment as an array-to-array COPY (`value[index - lower]`), but a scalar
FILL assignment (`a[] = scalar;`, where `rhs`'s type equals the slice's
ELEMENT type rather than its own array type) evaluates `rhs` to a plain
scalar `Value`, which is not indexable -- `value[index - lower]` threw
"Expected array." Confirmed this crash reproduces even with NO cell
involved at all (a plain `int[] a = [1, 2]; a[] = 99;` with no
slice/pointer taken), i.e. scalar-element slice fill was never a tested,
working path before this fix, independent of cell coherence. Fix, both in
`runSliceAssignExpression`: (1) the elements loop now checks `value.isArray`
to pick between indexing into a real array-copy RHS and reusing a
scalar-fill RHS directly at every covered position, alongside the
pre-existing `block` (nested-array-element fill, e.g. `matrix[] = row;`)
branch, which is unchanged; (2) after the boxed `locals` write, a new loop
over exactly the assigned range (`lower .. upper`) calls the existing
`writeThroughArrayCell(variable, index, elements[index])` helper per index
-- a no-op when no cell was ever promoted, so this is additive outside item
7's narrow native-scalar-dynamic-array-element gating. A second fixture,
`pointer.boundedSliceAssignmentWritesThroughAddressOfPromotedCell`
(`expressions.d`) -- `int[] a = [one(), two(), three()]; int* p = &a[0];
a[0 .. 2] = ninetyNine(); return a[0] + a[1] + a[2];` -- exercises the
BOUNDED (non-full) form promoted via address-of instead of a slice, and
confirms `a[2]` (outside the assigned range) is left untouched. What
remains: `runPointerSliceAssignExpression` and `runFieldSliceAssignExpression`
share the same `block`-ternary shape and likely have the identical
scalar-fill-vs-copy bug for a pointer- or struct-field-rooted slice target,
but neither is exercised by any fixture yet -- untested, not fixed here.

Both findings share a root cause with the one immediately above them in
this file: the plan's own prior wording calling array growth (`~=`)
"exactly as before" or "unaffected" (see the correction added in-place a
few paragraphs up, at the "compound/post-increment gap" entry) undersold
the real risk once a cell existed to strand -- growth's OWN code path was
indeed unchanged by those earlier slices, but "unchanged" was not the same
as "safe" the moment array-cell promotion became reachable with no
address-of at all (a plain slice). Finding 3 above is the fix that wording
was missing.

Focused runs, all green: all four new fixtures (each confirmed red on
Interpreter / green on SystemLinker before the fix, green on both after);
`bin/ut -s ut.backends.runner.lang.expressions` (379 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.runner.lang.arrays` (330 run, 0
failed); `bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed). The full `bin/ut --random` was left to the orchestrator per the
usual long-suite handoff.

Progress 2026-07-14 (review fixes: slice-alias, struct compound-write,
struct-field-alias cell refresh): a third Fable review of the same array/
struct cell slices found three more blockers (findings 5-7), all still in
the "a promoted `arrayCells`/`structCells` cell is READ-AUTHORITATIVE over
the boxed `locals` mirror" family, this time in write paths that reach a
promoted cell only indirectly -- through a slice-parameter alias, a
compound assignment through a struct-field pointer, and a `ref`-local
struct-field alias.

Finding 5: `writeThroughSliceAlias`'s non-`hasFieldIndex` arm refreshed only
the boxed `locals` mirror for the slice's source variable, never a promoted
`arrayCells` entry the source might already have. Reachable with no cell of
`s`'s own at all: a slice-expression parameter (`void bump(int[] s) { s[0]
= ninetyNine(); }`) is bound via `recordParameterSliceAlias`, which never
calls `promoteSliceArrayCell`, so `s` itself never gets a cell; but the
caller's `a` (the slice's source, aliased via `sliceAliases`) can already
have one from an earlier `&a[0]`. New fixture (pre-approved, confirmed red
on Interpreter / green on SystemLinker):
`pointer.sliceParameterWriteThroughRefreshesSourceCellAfterAddressOf`
(`tests/ut/backends/runner/lang/expressions.d`) -- `int[] a = [one(), two()];
auto p = &a[0]; bump(a[]); return a[0];` -- SystemLinker `99`; Interpreter
returned the stale `1` (`readIndexExpression`'s cell arm answered from the
untouched cell). Fix: `writeThroughSliceAlias` now also calls
`writeThroughArrayCell(alias_.source, alias_.lower + index, value)` after
the `locals` write, exactly the treatment `writeThroughArrayElementAlias`
already got in the prior review round -- a no-op when no cell was ever
promoted for `alias_.source`.

Finding 6: `writePointerTarget` (the compound-assignment/atomic/post-
increment write-back path) called `writeThroughArrayPointer` but not
`writeThroughStructFieldPointer`, so `(*p)++`/`*p += x`/atomics through a
struct-field pointer read the promoted `structCells` entry (via
`pointerTargetValue`/`structFieldPointerCellValue`, added earlier this
session) but wrote only the pointer's own boxed snapshot back through the
generic `writeLocation(expression, pointer.withPointerTarget(value))`
fallback at the bottom. New fixture (confirmed red/green):
`pointer.structFieldPointerCompoundIncrementWritesThroughCell`
(`expressions.d`) -- `S s = S(one(), two()); auto p = &s.x; (*p)++; return
*p;` -- SystemLinker `2`; Interpreter returned the stale `1` (the increment
never reached the cell, so the next `*p` re-read it unchanged). Fix: call
`writeThroughStructFieldPointer(pointer, value)` right after
`writeThroughArrayPointer` in `writePointerTarget`, mirroring
`writeLocation`'s own `PtrExp` arm, which already calls both in that order.

Finding 7: `writeThroughStructFieldAlias` -- reached only via a `ref` LOCAL
bound directly to a struct field (`ref int r = s.x;`, recorded by
`recordStructFieldAlias`; a `ref` PARAMETER bound to `s.x` is not tracked by
this alias table at all, so the local form is the only reachable case)
-- refreshed only the boxed `locals` mirror for the receiver, never a
promoted `structCells` entry. New fixture (confirmed red/green):
`pointer.structFieldRefLocalWriteThroughRefreshesCellAfterAddressOf`
(`expressions.d`) -- `S s = S(one(), two()); auto p = &s.x; ref int r =
s.x; r = ninetyNine(); return *p;` -- SystemLinker `99`; Interpreter
returned the stale `1` (`*p` read through
`pointerTargetValue`/`structFieldPointerCellValue`, which is authoritative
over the boxed mirror `r`'s write had already updated). Fix:
`writeThroughStructFieldAlias` now also calls `writeScalar` into
`cell.field(alias_.index)` (typed via
`cell.fieldDeclaration(alias_.index).type`) when the receiver has a
`structCells` entry, mirroring `writeThroughArrayCell`'s treatment of the
array sibling -- a no-op when no cell was ever promoted for the receiver.

All three share the same root cause as every finding in this family: a
write reachable only through an ALIAS table (slice, array-element, or
struct-field) must independently remember to refresh whichever native cell
its ultimate target variable holds, because the read side always checks
the cell first and never consults the alias tables at all.

Focused runs, all green: all three new fixtures (each confirmed red on
Interpreter / green on SystemLinker before the fix, green on both after);
`bin/ut -s ut.backends.runner.lang.expressions` (385 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.runner.lang.structs` (281 run, 0
failed); `bin/ut -s ut.backends.runner.lang.arrays` (330 run, 0 failed);
`bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (struct cross-frame pointer coherence): the struct
starter slice's own scope note named this gap directly -- "cross-frame
struct-field pointer dereference... is unexercised: `structCells` itself is
duped into child frames, but the reverse-lookup maps are not". This slice
closes it for a callee that writes THROUGH a pointer a caller took before
the call.

Candidate (a) (`struct S{int x;int y;} void put(int* p,int v){ *p=v; } int
f(){ S s=S(one(),two()); int* p=&s.x; put(p, ninetyNine()); return *p +
s.x; }`, expecting `198`) was confirmed red first: the Interpreter threw
`Unsupported interpreter assignment target.` from inside `put`'s `*p = v;`
-- `writeThroughStructFieldPointer` looked `pointer.pointerAllocation` up
in ITS OWN frame's `structFieldPointerVariables`/
`structFieldPointerFieldIndices`, which the caller's `&s.x` had populated
but no child-frame spawn site ever duped (unlike `arrayAllocationVariables`,
the array phase's own reverse lookup, which every spawn site already
dupes), so the lookup missed and the write fell through to the
`fieldSnapshotAllocationIds` refusal check (which WAS duped) instead of
aliasing. SystemLinker returned `198` as expected (real aliasing). Committed
as `pointer.structFieldWriteThroughPointerInCalleeIsVisibleToCaller` in
`tests/ut/backends/runner/lang/expressions.d`, scoped to
`Interpreter`/`SystemLinker` only.

Merely duping the reverse-lookup maps turned out not to be enough on its
own, for a reason worth recording precisely: `put` is an ordinary
(non-nested, non-`ref`) free function, so its child `Walker`'s `locals`
starts as `datasegLocals` (dataseg variables only) -- `s`, a plain local of
the CALLER `f`, is never present in the callee's own `locals` at all, only
`p`/`v` (its actual parameters) are. `writeThroughStructFieldPointer`'s
existing `current = *variable in locals` guard (needed to re-derive the
boxed mirror in the SAME-frame case) would therefore still see `current is
null` and bail, even with the reverse-lookup dupe alone. Worse, unlike an
array element read (`a[i]`, which `runIndexExpression` already checks
`arrayCells` for FIRST), a direct struct-field read (`s.x`, via
`runDotVarExpression` -> generic `VarExp` handling) never consults
`structCells` at all -- only a `*pointer` deref does (`structCells` was
deliberately scoped that way from the struct phase's first slice onward).
So even a cell write with perfectly shared bytes would leave a later direct
`s.x` read in the CALLER's own frame seeing the pre-call value once `put`
returns, unless something explicitly re-syncs the caller's boxed
`locals[s]` mirror after the call.

Production changes, `source/quickbite/backends/interpreter/impl.d`:
1. `structFieldPointerVariables`/`structFieldPointerFieldIndices` are now
   duped into a child `Walker` at all 7 child-frame spawn sites (the same
   ones that already dupe `structCells`), mirroring `arrayAllocationVariables`.
2. A new `bool[VarDeclaration] structFieldPointerWritebacks` map (the
   struct counterpart of `arrayPointerWritebacks`), duped at the same 7
   sites: `writeThroughStructFieldPointer` now flags the receiver
   `variable` in it after every successful cell write, whether or not
   `variable` was present in the writing frame's own `locals`.
3. `writeThroughStructFieldPointer` no longer requires `current` (`variable
   in locals`) to be non-null to proceed -- only to decline (as before) when
   `current` IS present but is no longer a struct (a genuine rebind). When
   `current` is present it still refreshes `locals[*variable]` immediately,
   exactly as before (needed for a same-frame later direct read); when
   absent (the cross-frame case), the cell write alone is applied and the
   boxed-mirror refresh is deferred.
4. A new `writeBackStructFieldPointerTargets(ref Walker child)`, the struct
   counterpart of `writeBackArrayPointerTargets`, called from
   `writeBackFunctionState` and `writeBackMemberFunctionState` (the two
   merge points every ordinary/member call funnels through) right after
   `writeBackArrayPointerTargets`. For each `variable` in
   `child.structFieldPointerVariables` flagged in
   `child.structFieldPointerWritebacks`, it re-derives the OWNING frame's
   (here, the caller's) `locals[variable]` from the shared, already-updated
   `structCells[variable]` cell via a new `structValueFromCell(current,
   cell)` helper -- the read-side mirror of `writeStructCellScalarFields`,
   overlaying every `native_scalar.isNativeScalarType` field's cell bytes
   onto the variable's existing boxed value and leaving any non-scalar
   field exactly as it was. `structFieldPointerVariables`/
   `structFieldPointerFieldIndices`/`structFieldPointerWritebacks` are also
   merged back (plain assignment, not `.dup`) alongside
   `arrayAllocationVariables`'s own merge-back, so a NEW cell/pointer the
   callee itself promoted survives past return, matching that map's
   existing discipline.

`runDestructor` and the `new`-with-user-ctor child (the 2 of the 7 spawn
sites that do not fold into `writeBackFunctionState`/
`writeBackMemberFunctionState`, and where `arrayAllocationVariables`
itself is either not duped or not merged back through
`writeBackArrayPointerTargets` either) get the same DUPE-IN for
consistency with `structCells`'s own duping, but no merge-back wiring --
matching the array reverse-lookup's own precedent at those two sites
exactly, not a new asymmetry this slice introduces.

What this slice does NOT do: candidates (b) (`&s.x` taken INSIDE a callee
on a `ref S` parameter) and (c) (a `ref S` parameter's field written
directly, `s.x = v`, in the callee) were not exercised as new fixtures --
both route entirely through the callee's OWN frame at write time (the
`ref` parameter's address-of/write happen against the callee's own
`structCells`/`locals`, never the caller's), then rely on the PRE-EXISTING
`writeBackRefArguments` -> `writeLocation` -> `writeCelledLocal` whole-
struct writeback (which already refreshes the caller's own `structCells`
entry, per this track's 2026-07-13 review-round work) to reconcile the
caller's pointer and direct read once the `ref` argument's final value is
written back; no cross-frame reverse-lookup gap applies to either. Nested-
struct fields, array fields, class fields, union fields, and any struct
reached through anything other than a bare local variable remain exactly
as scoped by the struct phase's first slice -- unchanged by this slice.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.lang.expressions` (387 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.lang.structs` (281 run, 0 failed);
`bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (whole-struct assignment field-cell coherence):
checked whether `writeCelledLocal`'s existing struct branch (landed in the
previous slice above) already keeps a promoted `structCells` entry coherent
across a whole-struct assignment (`s = S(...)`), as opposed to only a
single-field write (`s.x = v`). Tried, in order, per the plan's candidates:
(a) `int* p = &s.x; s = S(eight(), nine()); return *p;` (expect `8`), (b)
assigning from another struct variable (`a = b;`) with a pointer into `a`
taken beforehand, and (c) two independent field pointers (`&s.x`, `&s.y`)
observing one whole-struct assignment. All three were run as fixtures
against both `Interpreter` and `SystemLinker`: every one was GREEN on both
backends already, with zero production changes -- characterization only.

Why this is coherent by construction, not luck: `s = S(...)` is a plain
`VarExp` assignment target, so `runAssignExpression` routes it through
`writeLocation`'s `VarExp` arm exactly like any other rebind, which calls
`writeCelledLocal(variable, storageValue(...), false)` unconditionally. That
helper's struct branch (`if (auto cell = variable in structCells) { if
(value.isStruct) writeStructCellScalarFields(*cell, value); ... }`) does not
distinguish a whole-struct assignment from a single-field
`DotVarExp`-triggered rewrite -- both arrive here as a full boxed struct
`Value`, and the branch refreshes every `native_scalar.isNativeScalarType`
field's cell bytes from it either way. So the SAME code path that keeps
`s.x = v` coherent (closed in the "struct field write-through-pointer"
slice) already keeps `s = S(...)` coherent for free: there is no separate
"whole-struct assignment" code path to have missed.
`structFieldPointerCellValue` (the `*p` deref-read) then reads the freshly-
written cell bytes regardless
of which assignment shape produced them. Candidate (b) (assigning from
another struct variable) and (c) (two independent field pointers) exercise
no additional machinery beyond (a): `runExpression` on `S(eight(), nine())`
or the `b` variable's boxed value both simply become the RHS `Value` handed
to the identical `writeCelledLocal` call, and `writeStructCellScalarFields`
already loops over every scalar field index, not just one.

Kept only fixture (a),
`pointer.wholeStructAssignmentVisibleThroughEarlierFieldPointer`, scoped to
`Interpreter`/`SystemLinker`, in
`tests/ut/backends/runner/lang/expressions.d` -- (b) and (c) were probed
as temporary fixtures to confirm the "all green" conclusion, observed green
with 0 failures, then removed rather than kept as duplicative coverage of
the same already-shared code path. No production change this slice. Focused
runs, all green: `bin/ut -s ut.backends.runner.lang.expressions` (389 run, 0
failed, 5/5 failing as expected); `bin/ut -s ut.backends.runner.lang.structs`
(281 run, 0 failed); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (71 run, 0 failed).

What remains: nested-struct fields, array fields, class fields, union
fields, and any struct reached through anything other than a bare local
variable remain out of `structCells`' scope entirely, unchanged by this
slice, per the struct phase's original boundary.

Progress 2026-07-14 (final-review fixes: struct-field-alias scalar guard,
member struct-array-field cell write): a final Fable review of the
arrayCells/structCells work above raised two BLOCKERs, both fixed here.

Finding 1: `recordStructFieldAlias` records ANY `DotVarExp` initializer
bound to a `ref` local, including a non-scalar (array/nested-struct) field,
but `writeThroughStructFieldAlias`'s `structCells` refresh (the "struct
field write-through-pointer" slice above) called `native_scalar.
writeScalar` unconditionally, with no scalar guard -- once `&s.x` had
promoted `s`'s cell, a later `ref int[] r = s.arr; r = [...];` reached the
same unguarded write and threw ("unsupported native scalar type"). Fix:
guard the write with `isNativeScalarType(cell.fieldDeclaration(alias_.
index).type)`, matching `writeStructCellScalarFields`'s own per-field
guard; a non-scalar aliased field now skips the cell write entirely and
falls through to the boxed mirror write just above it, unchanged.

Finding 2: once a plain array local has a promoted `arrayCells` entry
(needing no address-of at all -- `foreach (v; a)` promotes it via
`promoteSliceArrayCell`), a member-function write to that same array
reached through a struct field (`Holder(a).bump()`, funnelled through
`writeThroughThisStructArrayFieldAlias`) updated only the boxed `locals`
mirror, never the source variable's `arrayCells` entry, so a later
cell-authoritative index read kept answering with stale bytes. Fix:
`writeThroughThisStructArrayFieldAlias` now also calls
`writeThroughArrayCell(*sourceVariable, index, value)` -- the same helper
every other array-cell write-through call site already uses -- right after
its existing `locals` write. This runs in the callee's child `Walker`
frame, whose `arrayCells` was duped from the caller (`child.arrayCells =
arrayCells.dup`) sharing the same underlying `NativeArray` bytes by
reference, so the caller's own cell is refreshed with no separate
write-back needed.

New fixtures (pre-approved, one per finding): `pointer.
structArrayFieldRefLocalWriteDoesNotDisturbScalarFieldCell` in `tests/ut/
backends/runner/lang/expressions.d` and `struct.
memberFunctionArrayFieldWriteRefreshesSourceArrayCell` in `tests/ut/
backends/runner/lang/structs.d`, both scoped to `Interpreter`/`SystemLinker`
only (omit-don't-pin convention), every value seeded from a runtime
function call so DMD cannot fold it. Both confirmed red on Interpreter
before any production change (finding 1: throws "unsupported native scalar
type"; finding 2: `1 != 100`, the stale pre-`bump` value) and green on
SystemLinker; green on both after.

Focused runs, all green: `bin/ut -s ut.backends.runner.lang.expressions` (391
run, 0 failed, 5/5 failing as expected); `bin/ut -s ut.backends.runner.lang.
structs` (283 run, 0 failed); `bin/ut -s ut.backends.runner.lang.arrays` (330
run, 0 failed); `bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0
failed, 1/1 failing as expected); `bin/ut -s ut.backends.interpreter` (218
run, 0 failed). The full `bin/ut --random` was left to the orchestrator per
the usual long-suite handoff.

Progress 2026-07-14 (final-review fixes: binding-aware cell resolution
across recursion): a final Fable review of the arrayCells/structCells work
above raised one BLOCKER (finding 3) and one SHOULD-FIX (finding 4), both
fixed here.

Finding 3 (BLOCKER): `allocationId`/`fieldSnapshotAllocationId` memoize
their id per `VarDeclaration` and are never removed -- every fresh-binding
site (`runDeclarationExpression`, `bindFunctionParameters`,
`bindLazyFunctionParameter`) already drops the CELL (`scalarCells`/
`arrayCells`/`structCells`, since the review round above) but left the ID
memo (`arrayAllocations`/`arrayAllocationVariables`,
`fieldAddressAllocations`) untouched. Recursion reuses the same
`VarDeclaration` at every call depth: a pointer minted at an OUTER depth,
passed DOWN into a call that re-declares the same variable, still carries
the OLD id -- which, in the inner frame, resolves (via
`arrayAllocationVariables`/`structFieldPointerVariables`, unchanged) into
whatever cell the inner re-declaration just promoted for ITSELF, instead of
declining. Depending on the inner binding's value/length this reads the
WRONG frame's bytes or indexes past a shorter re-declared array
(`NativeArray.element: index out of range`). Three new fixtures in
`tests/ut/backends/runner/lang/expressions.d`, all scoped to
`Interpreter`/`SystemLinker` (omit-don't-pin convention), every value seeded
from a runtime function call: `pointer.
recursiveArrayPointerPassedAcrossRebindDereferencesOuterValue` (a recursive
`f(depth, p)` taking `&a[0]` at each depth and passing it down, expecting
`f(2, null) == 207`, confirmed red on Interpreter -- `107 != 207`, the inner
depth's own value -- and green on SystemLinker); the struct sibling,
`pointer.recursiveStructFieldPointerPassedAcrossRebindDereferencesOuterValue`
(`&s.x` instead of `&a[0]`, identical red/green); and the crash twin,
`pointer.recursiveArrayPointerPassedAcrossShorterRebindDoesNotCrash` (outer
`&a[3]` on a 4-element array, inner `a` re-declared with length 1 and its
own `&a[0]` taken to promote its own short cell, confirmed red on
Interpreter -- `NativeArray.element: index out of range` -- and green on
SystemLinker, expecting `4`).

Chosen fix, of the two directions the reviewer offered: mint a FRESH id per
binding (rather than tag cells/pointers with a separate generation and leave
the id memo untouched). Two new/extended helpers, called from the SAME
three fresh-binding sites that already drop the cell, right alongside the
existing `scalarCells.remove`/`dropStructCell`: (1) a new `dropArrayCell
(variable)`, the array sibling of `dropStructCell`, removes `arrayCells
[variable]` together with `arrayAllocations[variable]` and the matching
`arrayAllocationVariables[id]` reverse entry; (2) `dropStructCell` itself
gained one more line, `fieldAddressAllocations.remove(variable)` --
`fieldSnapshotAllocationId`'s own forward memo, which the existing reverse-
map cleanup never touched, so a fresh `&s.field` after a rebind was still
reusing the OLD id even after finding 1's original fix (the round-2 review
above only closed the reverse half of this same gap for structs). Once the
id memo is gone, the NEXT `&a[i]`/`&s.field` in the fresh binding mints a
genuinely new id (`++allocationCount`); a pointer already minted under the
OLD id then fails `arrayPointerVariable`/`structFieldPointerVariables`'s
reverse lookup in the rebound frame and `pointerTargetValue` falls through
to the pointer's own frozen boxed snapshot (`pointer.pointerTarget`, taken
at address-of time) -- which is exactly PRE-cell-machinery master
semantics, and provably the correct value for every fixture above: nothing
mutates the OUTER binding's storage between the outer `&a[i]`/`&s.field` and
the inner rebind, so the frozen snapshot and the outer cell's live bytes
still agree. This was chosen over a separate generation tag because it
needs no `Value`/`NativeArray`/`NativeStruct` schema change -- the
allocation id already travels inside the pointer `Value` and already serves
as the cross-frame identity token everything else keys off -- and it slots
directly into the fresh-binding-drop pattern the prior review rounds already
established, rather than adding a second, parallel invalidation mechanism.
Verified this does not regress boxed (non-celled) pointer identity: within
one still-live binding (no fresh re-declaration in between), the id is
minted once, lazily, and never touched again, so repeated `&a[i]`/`&a[j]`
calls keep returning the SAME id exactly as before -- the invalidation only
ever fires at the three fresh-binding call sites, never on an ordinary
address-of. Worth noting: this incidentally closes the identical, previously
untested latent bug in the plain BOXED reverse-lookup paths
(`readPointerElement`, `writeThroughArrayPointer`,
`canWriteThroughArrayPointer`) that share the same `arrayAllocationVariables`
map -- those never had a cell at all, but were exposed to the exact same
stale-id-resolves-into-the-wrong-frame's-`locals` bug; no separate fixture
was written for the boxed-only case since the three fixtures above already
exercise the shared reverse-lookup map, cell or not.

Finding 4 (SHOULD-FIX), and its array-symmetric risk this slice had to avoid
introducing: `structFieldPointerVariables`/`FieldIndices`/`Writebacks` were
copied back wholesale (`= child.X`) at every call-return merge point.
`dropStructCell`'s reverse-map cleanup (existing since the round-2 review)
means a callee's OWN fresh re-declaration of a shared `VarDeclaration`
removes an id->variable entry from the CALLEE's own (duped) copy -- even
when the callee never itself re-takes the field's address -- and the
wholesale replace then adopts the callee's (now-missing-the-entry) map,
discarding the CALLER's own still-live entry for the SAME id. New fixture,
`pointer.structFieldPointerWriteThroughSurvivesSiblingRecursionReturn`
(`expressions.d`, `Interpreter`/`SystemLinker`): a two-level recursion where
`f(1)` takes `&s.x`, calls `f(0)` (which re-declares its own `S s = ...;`
but never takes `&s.x`), then does `*p = 42; return *p + s.x;` after `f(0)`
returns -- confirmed red on Interpreter (`Unsupported interpreter assignment
target.`, the write silently failing to resolve) and green on SystemLinker
(`84`). Extending finding 3's id-invalidation to `arrayAllocations`/
`arrayAllocationVariables` (this slice's own new `dropArrayCell`) would
introduce the IDENTICAL class of bug for arrays' own wholesale array-map
copy-back, which had never been destructively mutated before this slice and
so never needed this treatment until now.

Fix, both struct and array: replaced every wholesale `= child.X` copy-back
of these maps with a non-destructive MERGE, via three new helpers next to
`mergeNativeThrowableRoots` (`writeBackFunctionState`,
`writeBackMemberFunctionState`, `runDestructor`'s tail, and -- for
`fieldAddressAllocations` only, matching those two sites' existing narrower
scope -- the `new`-with-user-ctor struct/class child tails).
`mergeArrayAllocationMaps`/`mergeStructFieldPointerVariableMaps` union the
REVERSE (id-keyed) maps unconditionally: every id is minted from one shared,
monotonically increasing `allocationCount` (already merged back
separately), so two frames never disagree about what a given id names --
adding every entry the callee still has can never destroy an entry only
THIS frame has, since a plain union never removes a key.
`mergeArrayAllocationMaps`/`mergeFieldAddressAllocations` also merge the
FORWARD (variable-keyed) maps, but with THIS frame's own existing entry
winning on conflict: a variable this frame already has an id for keeps it
(so a deeper frame's own rebind, which only ever mints a NEW id for ITS OWN
copy, cannot clobber this frame's mapping for the same variable); a
variable this frame has never seen adopts the callee's entry (needed for
e.g. a nested function first taking a shared enclosing local's address).
Confirmed safe for every pre-existing (already-green) fixture: before
finding 3's `dropArrayCell`, the array forward/reverse maps were NEVER
destructively mutated, so parent's and child's copies were always identical
anyway -- this merge only changes behaviour in the NEW recursion-rebind
scenario finding 3 introduced, where "this frame's own entry wins" is
exactly the derived-correct semantics.

Documented residue, precisely: (1) the frozen-boxed-snapshot fallback this
fix relies on is correct only because nothing mutates the OUTER binding's
storage between its own `&a[i]`/`&s.field` and a callee's later rebind of
the same `VarDeclaration` -- if the outer binding's own cell WERE mutated in
that window (e.g. `a[0] = x;` right before the recursive call), the frozen
snapshot the decline falls back to would not reflect that later write; no
fixture (old or new) exercises this narrower corner, and it is a real,
un-closed gap, not a hidden success. (2) `runNewClassExpression`'s child
`Walker` still neither dupes nor merges `arrayAllocations`/
`arrayAllocationVariables`/`structFieldPointerVariables`/`FieldIndices` at
all -- a pre-existing asymmetry predating this slice (noted in the "struct
cross-frame pointer coherence" progress entry above); only its
`fieldAddressAllocations` copy-back was given the same merge treatment,
matching that site's own existing narrower scope rather than introducing a
new asymmetry. (3) `promoteSliceArrayCell`'s own internal `arrayCells.remove
(variable)` (a slice-temporary's fresh binding, e.g. a `foreach` loop's
per-iteration slice) was left unchanged -- it drops `variable`'s own cell
only and never mints or memoizes an id itself (ids are minted solely by
`arrayPointer`, keyed off `source`, already covered by the three call sites
this slice changed), so there was no id memo there to invalidate.

Focused runs, all green: all four new fixtures (each confirmed red on
Interpreter / green on SystemLinker before the fix, green on both after);
`bin/ut -s ut.backends.runner.lang.expressions` (399 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.runner.lang.structs` (283 run, 0
failed); `bin/ut -s ut.backends.runner.lang.arrays` (330 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Progress 2026-07-14 (final-review nits: union guard, slice-assign range,
writeback flag clear; whole-value-read staleness documented): a further
Fable review of the arrayCells/structCells work above raised four items
(one SHOULD-FIX, three NITs); this slice addresses all four.

Finding 5 (SHOULD-FIX, documented only): after `int[] s = a[]; a[0] =
ninetyNine();`, an INDEX read `s[0]` is cell-authoritative (99), but a
WHOLE-value read of `s` (`return s;`, `s == [...]`, `s.dup`, passing `s` by
value) still reads the stale boxed `[1, 2]` mirror -- `writeCelledLocal`'s
byte write refreshes `a`'s cell (and `s`'s, sharing storage), but never
touches `s`'s own boxed `locals` entry, which whole-value reads still
consult directly instead of re-deriving from the cell. Symmetric case:
after a `ref int[]` writeback in-place-refreshes a slice-view cell, the
ROOT variable's boxed mirror is not touched either, so the root's own
whole-value reads stay stale while its index reads (which do consult the
cell) are fresh. Neither is a master regression -- master was consistently
stale for both index and whole-value reads through an aliased variable --
but the split between a fresh index read and a stale whole-value read
through the SAME variable, in the SAME statement sequence, is new,
introduced by the cell machinery's read side becoming index-read-only.
Not fixed this slice: closing it needs re-deriving the aliased variable's
boxed mirror from its cell on every reverse write (mirroring
`structValueFromCell`'s struct-side re-derivation), which is unbounded in
this narrow slice's scope -- it would need to walk every `sliceAliases`
entry (and the reverse array-cell direction) on every scalar
write-through, not just the one variable directly touched. Documented
here as the precise, known boundary instead: a whole-value read of an
aliased variable remains boxed-stale after any write reaches the SAME
storage through a DIFFERENT aliased variable's cell; only reads through
the variable whose OWN write triggered the refresh, and index reads
through any aliasing variable, are cell-fresh.

Finding 6 (NIT, fixed): `promoteStructCell` didn't exclude unions, though
an earlier "What remains" note above claimed union fields are untouched --
a `union` is itself a `TypeStruct` (`structType.sym` an
`UnionDeclaration`), so a union local would get a `structCells` entry the
same as any other struct, and `writeStructCellScalarFields` would then
seed every field at its own overlapping byte range with no
union-vs-struct branch, corrupting `&u.a`'s later deref with whatever
field was seeded last. Fix: `promoteStructCell` now declines (returns, no
cell, boxed path unchanged) when `structType.sym.isUnionDeclaration !is
null`, making the "unions untouched" claim true by construction. No
fixture: no existing suite exercises `&union.field` on Interpreter
(`ct.structs` has no union coverage at all), and the boxed fallback path
is unchanged pre-existing behaviour, so there is nothing new to
characterize.

Finding 7 (NIT, fixed): `runSliceAssignExpression`'s cell-refresh loop
indexed `lower .. upper` against `elements` (built with only
`current.length` entries) with no bounds check, so an out-of-bounds guest
`a[0 .. 5] = x` on a 2-element array indexed `elements` past its own
length and died with a HOST `core.exception.RangeError` -- even when
`variable` had no promoted cell at all, since `elements[index]` is built
as the call argument before `writeThroughArrayCell`'s own no-op check
ever runs. Fix: reject `upper > current.length` up front, before
`elements` is built or `rhs` is even evaluated (matching compiled D's own
evaluation order, verified separately), throwing the interpreter's
guest-visible `RangeError` with the exact wording druntime's
`ArraySliceError` uses for the identical slice assignment (verified
against a real compiled `int[] a = [1, 2]; a[0 .. 5] = 9;`), so
`SystemLinker` agrees exactly. New fixture (pre-approved),
`dynamicArray.sliceAssignPastLengthThrowsRangeError` in `tests/ut/
backends/runner/lang/arrays.d`, scoped to `Interpreter`/`SystemLinker`,
runtime-seeded: confirmed red on Interpreter before the fix (uncaught
host `core.exception.ArrayIndexError`, indexing `elements` itself) and
green on SystemLinker; green on both after.

Finding 8 (NIT, hardening, fixed): `structFieldPointerWritebacks` flags
were set (`writeThroughStructFieldPointer`) but never cleared, and the
map is dup'd into every further child frame and merged back wholesale --
a latent trap where a stale flag from an already-processed call could
survive into an unrelated later frame that never itself wrote through a
struct-field pointer, and get re-applied against whatever cell exists for
that variable then. Harmless today (re-deriving `locals[variable]` from a
still-current cell is idempotent), but a future missed-write path could
turn it into a stale-cell clobber. Fix: `writeBackStructFieldPointerTargets`
now removes the processed variable's entry from `child.
structFieldPointerWritebacks` right after re-deriving `locals[variable]`
from the cell, so the flag cannot outlive the writeback it was raised
for. No behavioural change today; no new fixture. Confirmed the existing
cross-frame struct fixtures (`ct.structs`, `ct.expressions`) stay green.

Focused runs, all green: `bin/ut -s ut.backends.runner.lang.expressions`
(399 run, 0 failed, 5/5 failing as expected); `bin/ut -s
ut.backends.runner.lang.structs` (283 run, 0 failed); `bin/ut -s
ut.backends.runner.lang.arrays` (332 run, 0 failed -- +2 for finding 7's new
fixture); `bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed,
1/1 failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed). The full `bin/ut --random` was left to the orchestrator per the
usual long-suite handoff.

Progress 2026-07-14 (re-review fixes: id dies with the cell at
rebind/append, wrong-frame merge guard, revert unsafe writeback-flag
clear): a further Fable review of the arrayCells/structCells work above
raised three new BLOCKERs, all introduced by the two final-review rounds
directly above; this slice fixes all three.

Finding 1 (BLOCKER, revert): the previous round's finding 8 added
`child.structFieldPointerWritebacks.remove(variable)` in
`writeBackStructFieldPointerTargets`, calling it "behaviour-neutral
hardening" for a hypothetical stale-flag hazard. It was not neutral: an
intermediate member-function frame (e.g. `Poker.poke` calling a free
function `deposit` that writes through a struct-field pointer) dups
`locals`/`structCells` from its own `this`-bound child `Walker`, passes the
writeback check at the inner call's return, and clears the flag on ITS OWN
throwaway duped copy -- so the flag never reaches the frame that actually
owns the struct local. A member-function frame has no
`writeBackNestedLocals` of its own, so the refresh died with the frame
instead of propagating up to the caller. New fixture,
`struct.memberFunctionForwardsPointerWriteToOwningFrame`
(`tests/ut/backends/runner/lang/structs.d`, `Interpreter`/`SystemLinker`):
confirmed red on Interpreter before the fix (`3 != 42`, the pre-write
value) and green on SystemLinker; green on both after. Fix: reverted the
`structFieldPointerWritebacks.remove(variable)` clear (and its comment)
entirely -- the hazard it guarded against was explicitly hypothetical, and
removing it restores the flag's cross-frame survival.

Finding 2 (BLOCKER): `writeCelledLocal`'s array rebind arm (a plain `a =
<new array>;`, no recursion involved) dropped `arrayCells[variable]` via a
bare `arrayCells.remove(variable)` but never the memoized
`arrayAllocations`/`arrayAllocationVariables` id -- the same per-binding
fresh-id principle finding 3 of the round above established for
`runDeclarationExpression`/`bindFunctionParameters`/
`bindLazyFunctionParameter`, applied incompletely to this same-frame rebind
arm. A pointer taken BEFORE the rebind kept resolving, via the still-live
reverse map, into the REBOUND array's own freshly-promoted cell instead of
declining to its own frozen snapshot. New fixture,
`pointer.arrayPointerTakenBeforePlainRebindKeepsPreRebindValue`
(`expressions.d`, `Interpreter`/`SystemLinker`): confirmed red on
Interpreter (`7 != 1`, the rebound array's own value) and green on
SystemLinker; green on both after. Crash twin,
`pointer.arrayPointerTakenBeforePlainRebindToShorterArrayDoesNotCrash`
(outer pointer at index 1, rebound array with only one element): confirmed
red on Interpreter (host `NativeArray.element: index out of range`) and
green on SystemLinker; green on both after. Fix: the rebind arm now calls
`dropArrayCell(variable)` (drops the cell AND the id together) instead of
the bare `arrayCells.remove(variable)`.

The append site (`runArrayAppendAssignExpression`'s plain-`VarExp` arm,
`~=`) had the identical drop-cell-keep-id shape, for the same reason (`a`
itself is never re-declared by an append, so nothing else invalidated its
id either). New fixture,
`pointer.arrayPointerTakenBeforeAppendKeepsPreAppendValue` (`expressions.d`,
`Interpreter`/`SystemLinker`): a three-element array literal is appended
to once (verified separately, against a standalone compiled program, that
a 3-element literal's GC block has exactly enough spare capacity for 3
elements and forces a real reallocation on a 4th), then a pointer taken
after the append writes a new value, and a pointer taken BEFORE the append
is read back; confirmed red on Interpreter (`99 != 1`, the post-append
write leaking backward through the shared stale id) and green on
SystemLinker (real reallocated storage keeps the pre-append pointer
stale); green on both after. Fix: the append site now also calls
`dropArrayCell(variable)` instead of the bare `arrayCells.remove
(variable)` -- append may reallocate, so minting a fresh id for the next
address-of is the correct D-matching choice, even though it changes `p is
q` identity for the (empirically far more common) case where the append
happens not to reallocate; declining to the pre-append frozen snapshot
still yields the correct value either way.

Finding 3 (BLOCKER): `mergeArrayAllocationMaps`'s reverse-map merge unioned
every child `arrayAllocationVariables` entry into the parent
unconditionally. A child's OWN fresh rebind of a shared `VarDeclaration`
mints a FRESH id for its own cell (finding 3 of the round above), and
dynamic-array elements are GC-allocated, so a pointer into that fresh child
cell may legally escape upward (returned from the child) -- the reverse
map is keyed by `VarDeclaration`, not by binding, so routing that
child-minted id into the PARENT frame, which holds its OWN live cell for a
DIFFERENT binding of the SAME `VarDeclaration`, resolved the escaped
pointer through the parent's bytes instead of declining to its own frozen
snapshot. New fixture,
`pointer.childMintedArrayIdEscapingUpwardDoesNotResolveThroughParentCell`
(`expressions.d`, `Interpreter`/`SystemLinker`): confirmed red on
Interpreter (`111 != 11`, the outer frame's own value instead of the
escaped pointer's inner-frame value) and green on SystemLinker; green on
both after. Fix: `mergeArrayAllocationMaps` now skips a child reverse
entry whose variable THIS frame's forward map (`arrayAllocations`) already
binds to a DIFFERENT id -- precisely the "same `VarDeclaration`, different
binding" condition -- while an entry for a variable this frame has no
binding for at all keeps merging unconditionally, since the cross-frame
writeback machinery still needs those. Applied the analogous guard to
`mergeStructFieldPointerVariableMaps`, keyed on (variable, field index)
rather than just variable since a struct can have several independently-
addressed fields; verified it does not regress any existing cross-frame
struct fixture. No fixture exercises the struct guard directly -- escaping
a pointer to a local struct field upward is UB in real D (a struct field,
unlike a dynamic array element, is not GC-allocated) -- so it is symmetric
hardening only.

Focused runs, all green: all five new fixtures (each confirmed red on
Interpreter / green on SystemLinker before the fix, green on both after);
`bin/ut -s ut.backends.runner.lang.expressions` (407 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.runner.lang.structs` (285 run, 0
failed); `bin/ut -s ut.backends.runner.lang.arrays` (332 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Progress 2026-07-14 (re-review fix: cross-frame writebacks reconcile the
parent's array cell): `runIndexExpression`'s cell arm makes a promoted
`arrayCells` entry READ-AUTHORITATIVE over the boxed `locals` mirror, but
`writeBackNestedLocals` and `writeBackArrayPointerTargets` only ever
refreshed the mirror with a bare assignment, never the parent's own cell.
A nested function mutating a captured array, or a recursive call sharing a
non-`ref` array parameter's backing storage, are both supported, tested
Interpreter features, so the parent's stale cell kept answering `a[0]`
reads with the pre-call value after `child` returned -- or, when the
callee's mutation grew the array (`~=`), indexed a too-short cell and
crashed the host with `NativeArray.element: index out of range` instead of
seeing the grown length. Three new fixtures (pre-approved, runtime-seeded
so DMD cannot fold them), all `Interpreter`/`SystemLinker` only: `pointer.
nestedFunctionArrayRebindIsVisibleThroughParentCell` (a nested function
rebinding a captured array to a same-length new array; confirmed red on
Interpreter, `1 != 7`, green on SystemLinker, before any production
change), `pointer.nestedFunctionArrayAppendGrowsArrayVisibleThroughParent
Cell` (a nested function appending to a captured array; confirmed red on
Interpreter -- the host `NativeArray.element: index out of range` crash,
not a wrong-value assertion -- green on SystemLinker), and `pointer.
recursiveArrayParameterElementWriteIsVisibleThroughCallerCell` (no
nesting: a plain, non-`ref` array parameter mutated in place one recursion
level down; confirmed red on Interpreter, `1 != 5`, green on SystemLinker).

Fix: both writeback functions now route an array-typed variable's final
value through `writeCelledLocal(variable, value, arrayIsRefWriteback:
true)` -- the same reconciliation `writeBackRefArguments` already uses for
a `ref` array parameter's callee-side mutation -- instead of a bare
`locals[variable] = value;`. `writeCelledLocal` refreshes a same-length
cell's bytes in place (the recursion/capture-mutation case) or
`dropArrayCell`s a changed-length one (the rebind/append case, so the next
read falls through to the freshly-refreshed boxed mirror instead of
indexing stale/too-short cell bytes), and is already a plain mirror write
-- unchanged from before -- for any variable with no cell at all, or a
scalar/struct variable (those reconcile through `writeCelledLocal`'s own
pre-existing, untouched `scalarCells`/`structCells` branches).

This did not apply uniformly, though, and the reason is worth recording
precisely rather than glossing over: `writeBackArrayPointerTargets` also
covers plain recursion over a LOCAL declaration reusing the same
`VarDeclaration` at every call depth (`pointer.
recursiveArrayDeclarationDropsStaleArrayCell`, an existing fixture --
depth 1's `a` is `[one(), two()]`, depth 0's fresh redeclaration of the
same AST-node `a` is the unrelated, shorter `[hundred()]`). That is NOT
aliasing -- each depth's `int[] a = ...;` is an independent array that only
coincidentally shares the AST node -- yet `bindFunctionParameters` and
`runDeclarationExpression` both call `dropArrayCell` at every depth the
exact same way a genuine recursive parameter-passthrough does, so cell/id
state alone cannot tell the two cases apart: both mint a fresh, mutually
non-matching allocation id per depth, regardless of whether the value
flowing in is really the same storage. Routing every dynamic-array
variable in `writeBackArrayPointerTargets` through `writeCelledLocal`
unconditionally (matching `writeBackNestedLocals`) made this existing
fixture red (`100100 != 1100`): the deeper, unrelated recursive
redeclaration's shorter final value caused THIS frame's own still-valid,
different-length cell to be dropped, and the already-latent (previously
harmless, because a live cell always shadowed it) bug of the bare mirror
copy-back overwriting the boxed `locals` mirror with the unrelated child's
value became directly observable once nothing masked it anymore.

The fix distinguishes the two cases the one way the language actually
does: `variable.storage_class & STC.parameter` (a new `isParameterVariable`
helper, `parameterIsLazy`'s sibling). Only a genuine function PARAMETER
routes through `writeCelledLocal`'s cell reconciliation in
`writeBackArrayPointerTargets`; every other variable (a plain local
redeclared at a deeper recursion depth) keeps the pre-existing plain
mirror copy, leaving this frame's own cell -- and its read-authoritative
answer -- untouched. `writeBackNestedLocals` needed no such gate: a
captured local is never independently redeclared inside the nested
function itself (a shadowing declaration would parse to a distinct
`VarDeclaration`), so `child.locals` containing an entry for a variable
this frame also has never represents the "same AST node, unrelated
binding" ambiguity recursion creates for `writeBackArrayPointerTargets`.

This is a heuristic, not a full fix, and the residual gap is worth naming:
a recursive call passing an actually-different array through the SAME
formal parameter (rather than forwarding the same array unchanged) would
still wrongly reconcile the cell if the two arrays' lengths happened to
match, because nothing in the current data model records array-value
provenance across a parameter rebind -- `arrayAllocationAliases`/
`sliceAliases` only ever get populated for a slice- or pointer-derived
argument, never a plain by-value array forward. No fixture in this repo
exercises that gap, and closing it for real would need genuine storage-
identity tracking through parameter binding, out of this slice's bounded
scope.

Focused runs, all green: all three new fixtures (each confirmed red on
Interpreter / green on SystemLinker before the fix, green on both after,
matching the exact failures above); `bin/ut -s
ut.backends.runner.lang.expressions` (413 run, 0 failed, 5/5 failing as
expected -- the same pre-existing `@ShouldFail` count as the 407-run
baseline before these fixtures were added, confirmed by re-running the
baseline unchanged); `bin/ut -s ut.backends.runner.lang.structs` (285 run, 0
failed); `bin/ut -s ut.backends.runner.lang.arrays` (332 run, 0 failed);
`bin/ut -s ut.backends.runner.lang.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed);
`bin/ut -s ut.bin.repl` (228 run, 0 failed). The full `bin/ut --random` was
left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (re-review fix: cross-frame whole-array rebind drops
the parent cell instead of corrupting a slice view): round 4's BLOCKER
finding 1 on the previous note's fix: `writeBackRefArguments` and
`writeBackNestedLocals` route a cross-frame array writeback through
`writeCelledLocal(..., arrayIsRefWriteback: true)`, whose same-length arm
refreshes the parent's promoted `arrayCells` entry bytes IN PLACE. That is
correct when the callee MUTATED elements of shared storage, but wrong when
the callee REBOUND its `ref int[]` parameter (or a captured array) to a
NEW same-length array: the in-place refresh then overwrites the OLD
storage's bytes, corrupting any separate, still-live alias of that OLD
storage (e.g. a slice view taken before the call) even though real D gives
the rebound variable entirely fresh storage and leaves the earlier view
untouched. Two new fixtures (pre-approved, runtime-seeded), Interpreter/
SystemLinker only: `pointer.refParameterRebindDoesNotCorruptPreexisting
SliceView` (confirmed red on Interpreter, `7 != 1`, green on SystemLinker,
before any production change) and `pointer.nestedFunctionArrayRebindDoes
NotCorruptPreexistingSliceView`, which asserts `a[0] * 10 + s[0]` rather
than either value alone -- checking only one side passes "by accident"
depending on `locals` associative-array iteration order in
`writeBackNestedLocals`'s own walk (the parent's rebound `a` and the
untouched `s` are both written back through that same walk, so whichever
is processed last currently wins the shared block's bytes); combining both
into one result exposed the corruption regardless of that order (confirmed
red, `77 != 71`, on the exact build these fixtures landed against).

Fix: a new per-frame `arrayRebinds` marker, set by `writeCelledLocal`
itself the moment it replaces a variable's array value wholesale (a plain,
non-writeback assignment, or a ref-writeback whose length changed) rather
than mutating one in place -- covering both the case where a promoted
`arrayCells` entry existed and was dropped, and the case where none existed
at all (a `ref int[]` parameter rebound without ever having its own address
taken, which promotes no cell of its own, so cell presence alone cannot
tell a rebind apart from an element-level mutation that similarly promoted
none). A new `arrayWritebackIsMutation(childVariable, child)` helper reads
the CHILD's own `arrayRebinds` entry for `childVariable` (absent means
every write the child made was a same-storage mutation, present means it
rebound at some point) and is now what `writeBackNestedLocals`,
`writeBackArrayPointerTargets`, and `writeBackRefArguments` pass to
`writeCelledLocal` instead of a hardcoded `true`: a genuine mutation still
refreshes the parent's cell in place (unchanged from the previous note's
fix), a rebind now drops it instead of corrupting it. Because the
propagating `writeCelledLocal` call itself marks `arrayRebinds` on ITS OWN
frame when it drops, the marker also cascades correctly through multiple
levels of nesting without any extra bookkeeping. The two overclaiming
comments this finding was reported against (`writeBackRefArguments`'s
"genuinely represents the SAME storage ... not a rebind" and
`writeLocation`'s matching claim about `arrayRefWriteback`) are corrected
to state the rebind case is now handled, rather than asserted away.

Reconciled with the existing `pointer.nestedFunctionArrayRebindIsVisible
ThroughParentCell` fixture (a nested rebind observed through the PARENT's
OWN `a`, not a separate view): dropping the parent's cell on rebind still
answers `a[0]` correctly, because `runIndexExpression`'s cell-priority read
falls through to the boxed `locals` mirror once no cell exists, and that
mirror is unconditionally refreshed with the rebound value at the end of
`writeCelledLocal` regardless of which branch ran. So `a` itself sees the
fresh `[7, 8, 9]` (via the mirror, cell gone) while a separate `s = a[];`
taken before the call keeps reading its own, still-present cell over the
untouched OLD block -- both verified together in the new fixture above.
Also verified unaffected: `pointer.recursiveArrayParameterElementWriteIs
VisibleThroughCallerCell`, `pointer.nestedFunctionArrayAppendGrowsArray
VisibleThroughParentCell`, `pointer.arrayElementWrittenThroughRefParameter
PointerVisibleToEarlierCallerPointer`, and the foreach-ref/post-increment
pointer fixtures -- none of these ever reach a plain whole-array
`writeCelledLocal` call for the aliased variable, so `arrayRebinds` is
never set for it and the existing in-place-refresh behaviour is untouched.

Focused runs, all green: both new fixtures (each confirmed red on
Interpreter / green on SystemLinker before the fix, green on both after);
the full set of previously-landed cross-frame array-cell fixtures named
above; `bin/ut -s ut.backends.runner.lang.expressions` (429 run, 0 failed,
5/5 failing as expected); `bin/ut -s ut.backends.runner.lang.arrays` (335
run, 0 failed); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed).
`bin/ut -s ut.backends.runner.lang.structs` still exits 139 in isolation on
this branch (the pre-existing Bytecode teardown segfault noted in the
previous session's handoff, unrelated to this change) -- every named test
case inside it ran and none failed before that teardown crash. The full
`bin/ut --random` was left to the orchestrator per the usual long-suite
handoff.

Progress 2026-07-15 (array-of-struct guest-local slice: `promoteArrayCell`
widened past scalar elements): the next frontier item after PR #421 --
`&a[i]` on a dynamic array whose element type is a struct -- stayed on the
pure boxed-snapshot path: `promoteArrayCell` early-returned on
`!isNativeScalarType(elementType)`, so no `arrayCells` entry ever backed
such a pointer, and `runPointerExpression`'s `arrayPointerCellValue` check
always missed and fell to the frozen `pointer.pointerTarget` snapshot taken
at address-of time -- a direct whole-element write after the pointer was
taken was invisible through it, even though `arrayPointer`'s VarExp branch
already mints an `arrayAllocationVariables` id for every array pointer
regardless of element type (that bookkeeping is unconditional; only the
cell itself was scalar-gated). One new fixture (pre-approved), all four
matrix backends: `pointer.
structArrayElementWrittenDirectlyIsVisibleThroughEarlierPointer`
(`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit`) -- `S[] a = [S(one()),
S(one())]; S* p = &a[0]; a[0] = S(ninetyNine()); assert((*p).x == 99);`.
Confirmed red on Interpreter before any production change (`1 != 99`,
verified via an unnamed scratch probe with the identical body before the
fixture was given its real name and committed); confirmed green on
SystemLinker throughout.

Fix, in `impl.d`: `promoteArrayCell` now also promotes a cell for a
dynamic array whose element type is a (non-union) struct, seeded field by
field through `NativeArray.structElement`/`writeStructCellScalarFields` --
reusing the exact container accessor and boxed-value-bridge helper the
struct-field-cell phase already built, not a new mechanism (`writeStruct
CellScalarFields` already existed for the top-level struct-local case;
`NativeArray.structElement` already existed in the container layer per the
"array-of-struct element views" progress note, with no interpreter call
site until now). A union element is refused with the same guard
`promoteStructCell` already uses, for the same reason (a union's
overlapping fields cannot be seeded by a per-field scalar-overlay loop
without clobbering an earlier field's bytes). Every other `arrayCells`
element read/write call site that previously called `native_scalar.
readScalar`/`writeScalar` unconditionally once a cell existed --
`writeCelledLocal`'s same-length ref-writeback refresh loop, `writeThrough
ArrayCell` (the direct `a[i] = x` write path), `runIndexExpression`'s
cell-priority read arm (the direct `a[i]` read path), and
`arrayPointerCellValue` (the pointer-deref read path) -- now route through
two new shared helpers, `writeArrayCellElement`/`readArrayCellElement`,
which branch on `cell.elementType.isTypeStruct` and dispatch to
`NativeArray.structElement` + `writeStructCellScalarFields`/`struct
ValueFromCell` for a struct element, or the pre-existing scalar path
otherwise. Touching all four was not optional: once `promoteArrayCell` can
produce a struct-element cell, every one of those call sites can now reach
it, and each previously assumed `cell.elementType` was always
`isNativeScalarType` -- left as bare `readScalar`/`writeScalar` calls, any
one of them would have crashed the first time a struct-element cell reached
it. `readArrayCellElement`'s struct branch overlays the cell's scalar
fields onto `variable`'s own current boxed element (or the element type's
default, if none) via `structValueFromCell` -- the same read-back helper
`writeBackStructFieldPointerTargets` already uses for a top-level
struct-field cell, applied here to one array element's sub-range instead of
a whole struct local -- so a struct element with a non-scalar sub-field (a
nested struct/array/slice field, out of this narrow slice's scope) keeps
whatever the boxed mirror already had for that sub-field rather than losing
it.

No `interpreter.md` §9.10 shim is retired by this slice: it widens which
arrays get a native cell, it does not touch any of the shim inventory's own
named functions (`emplaceRef`, the `gc_*` capacity stubs,
`reinterpretLocalPointerLoad`/`floatBits`/`doubleBits`,
`writeBackByValueClassArguments`). Remaining frontier after this slice,
unchanged from the item 7 framing above except this one entry moving from
boxed to native: struct fields that are themselves non-scalar (nested
struct, static array, or slice -- `&s.inner.x`, `&s.arr[i]`, `&s.slice[i]`,
none of which promote a `structCells` entry yet, since `promoteStructFieldCell`
still gates on `isNativeScalarType(dot.type)` and `arrayPointer`'s
`DotVarExp` branch still mints an unregistered, un-cell-backed pointer id
every time); non-scalar array-of-array/array-of-slice elements (only the
struct-element case was widened this slice); and class objects (still
third in the migration order). A quick empirical check (three scratch
probes, all confirmed red on Interpreter / green on SystemLinker before
being discarded down to the one fixture above) found genuine SystemLinker
divergences in both the nested-struct-field-write case (`&s.inner.x; *p =
v;` -- currently `writeLocation`'s `PtrExp` arm throws "Unsupported
interpreter assignment target" for any multi-hop `DotVarExp` chain, since
`fieldSnapshotAllocationId`/`promoteStructFieldCell` only resolve a
`dot.e1.isVarExp` receiver) and the struct-static-array-field case
(`&s.arr[i]`, addressed above by `arrayPointer`'s `array.isDotVarExp`
branch, which mints `++allocationCount` with no reverse-lookup registration
at all) -- both real next candidates, deliberately left for a follow-up
commit because closing either requires a new (receiver, field-path)
reverse-lookup generalization beyond the single (receiver, field index)
`structFieldPointerVariables`/`structFieldPointerFieldIndices` pair the
existing struct-scalar-field mechanism uses, not a same-shape widening of
an existing gate the way this slice's array-of-struct change was.

Focused runs, all green: the new fixture (all four backends); `bin/ut -s
ut.backends.runner.ct.expressions` (497 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing as
expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed);
`bin/ut -s ut.bin.repl` (228 run, 0 failed). The full `bin/ut --random` was
left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (struct-static-array-field follow-up: `&s.arr[i]` gets a
(receiver, field-path) reverse lookup): the smaller of the two candidates the
array-of-struct progress note above deliberately deferred -- `&s.arr[i]`
where `arr` is a static-array field of a plain struct local. One new
fixture, `pointer.
structStaticArrayFieldElementWrittenDirectlyIsVisibleThroughEarlierPointer`
(`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit`, matching the omit-Bytecode
convention the sibling scalar-field fixture already set): `struct S { int[3]
arr; } S s; s.arr[0] = one(); int* p = &s.arr[0]; s.arr[0] = ninetyNine();
assert(*p == 99);`. Confirmed red on Interpreter before any production
change (`1 != 99`, the pre-write snapshot); confirmed green on Ctfe,
SystemLinker, and LLVMJit throughout.

Root cause, exactly as the prior note predicted: `arrayPointer`'s
`array.isDotVarExp` branch minted a bare `++allocationCount` id for `&s.arr`/
`&s.arr[i]` with no reverse-lookup registration at all, so
`arrayPointerCellValue`/`structFieldPointerCellValue` both missed and the
deref fell to the frozen `pointer.pointerTarget` snapshot.

Fix, in `impl.d`: a new (receiver variable, field index) reverse-lookup pair,
`structArrayFieldPointerVariables`/`structArrayFieldPointerFieldIndices` --
the array-typed-field sibling of the existing scalar-field
`structFieldPointerVariables`/`structFieldPointerFieldIndices`, needed
because a static-array field's pointer carries an element offset and its
cell view is a `NativeArray` (`NativeStruct.arrayField`, already built by an
earlier progress note's composition matrix) rather than the single scalar
byte range the existing pair resolves to. `arrayPointer`'s `DotVarExp` branch
now reuses `fieldSnapshotAllocationId` (the same per-(receiver, field index)
memo `&s.field` already gets, giving `&s.arr[i]` the same real-address
identity stability) and calls the new `promoteStructArrayFieldCell(dot, id)`
-- mirroring `promoteStructFieldCell` but gated on `isStaticArrayType(dot.
type)` with a `native_scalar.isNativeScalarType` element, instead of
`isNativeScalarType(dot.type)` directly. `writeStructCellScalarFields` (both
the cell-creation seed and the whole-struct refresh `writeCelledLocal`
already calls on every direct field write) is widened to also seed/refresh a
scalar-element static-array field's bytes via `cell.arrayField(index)`, one
element at a time -- the single change that keeps a direct `s.arr[i] = x`
write visible through an earlier pointer, since that write always goes
through a whole-struct `writeLocation`/`writeCelledLocal` round trip. Two new
functions, `structArrayFieldPointerCellValue` (wired into
`pointerTargetValue` and `runPointerExpression`'s deref-read arm, alongside
the existing `arrayPointerCellValue`/`structFieldPointerCellValue` checks)
and `writeThroughStructArrayFieldPointer` (wired into `writeLocation`'s
`PtrExp` arm and `writePointerTarget`, alongside
`writeThroughStructFieldPointer`), mirror the scalar-field pair's read/write
dispatch exactly. `dropStructCell` also clears stale
`structArrayFieldPointerVariables`/`structArrayFieldPointerFieldIndices`
entries for a fresh redeclaration, mirroring its existing scalar-field
cleanup, for the same reason (a stale id resolving into a later, unrelated
binding's cell).

Scoped narrower than the scalar-field mechanism in one respect, called out
explicitly in the field declarations' own comment: `structArrayFieldPointer
Variables`/`structArrayFieldPointerFieldIndices` are NOT duplicated into
child-frame walkers the way `structFieldPointerVariables` is at every
existing dup site, so a `&s.arr[i]` pointer does not yet survive being
passed into another function call -- `writeThroughStructArrayFieldPointer`
declines (returns `false`) rather than silently losing the write when the
receiver isn't in the current frame's `locals`. The fixture above is
same-frame only (the two `one()`/`ninetyNine()` calls never touch `s` or
`p`), so this gap is untested, not closed; cross-frame propagation (the 8
existing `structFieldPointerVariables.dup`/merge/writeback call sites'
mechanical counterparts) is a real next candidate if a cross-frame fixture
is ever proposed.

No `interpreter.md` §9.10 shim is retired by this slice, matching the
array-of-struct note above: it widens which struct fields a `structCells`
entry backs, it does not touch any of the shim inventory's own named
functions.

The other deferred candidate from the array-of-struct progress note --
nested struct field write-through `&s.inner.x` (currently `writeLocation`'s
`PtrExp` arm throws "Unsupported interpreter assignment target" for any
multi-hop `DotVarExp` chain, since `fieldSnapshotAllocationId`/
`promoteStructFieldCell` only resolve a `dot.e1.isVarExp` receiver) --
remains open for a follow-up commit. It needs a genuinely different
generalization than this slice's: a field PATH (not a single field index)
resolved by walking a `DotVarExp` chain down to its root `VarExp`, plus
`writeStructCellScalarFields` recursing into nested (non-union) struct
fields via `NativeStruct.structField` the same way this slice's fix recursed
into static-array fields via `NativeStruct.arrayField` -- a similarly shaped
but distinct widening, not reachable by reusing this slice's new maps
as-is.

Focused runs, all green: the new fixture (all four backends); `bin/ut -s
ut.backends.runner.ct.expressions` (497 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing as
expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut
-s ut.bin.repl` (228 run, 0 failed). The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (nested-struct-field follow-up: `&s.inner.x` gets a
one-level (receiver, field-path) reverse lookup): the other deferred
candidate the struct-static-array-field note above left open --
`&s.inner.x` where `inner` is a (non-union) struct field of a plain struct
local and `x` is a scalar field of `inner`. One new fixture,
`pointer.addressOfNestedStructFieldWriteThroughUpdatesField`
(`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit`, omit-Bytecode convention):
`struct Inner { int x; } struct S { Inner inner; } S s = S(Inner(seed()));
int* p = &s.inner.x; *p = 5; assert(s.inner.x == 5);`. This fixture writes
THROUGH the pointer (the direction the plan note's own quoted diagnostic
names), unlike the sibling array-field fixture's write-directly/read-
through-pointer direction. Confirmed red on Interpreter before any
production change: `object.Exception: Unsupported interpreter assignment
target.`, thrown from `writeLocation`'s `PtrExp` arm's "every OTHER
`&s.field` snapshot" guard, exactly as the prior note predicted. Confirmed
green on Ctfe, SystemLinker, and LLVMJit throughout.

Fix, in `impl.d`: a new (receiver variable, outer field index, inner field
index) reverse-lookup triple, `nestedStructFieldPointerVariables`/
`nestedStructFieldPointerOuterFieldIndices`/
`nestedStructFieldPointerInnerFieldIndices` -- the one-level-nested sibling
of `structFieldPointerVariables`/`structFieldPointerFieldIndices`, needed
because the cell view is `NativeStruct.structField(outerIndex).
field(innerIndex)` -- a nested `NativeStruct` sharing the parent's block,
via the composition accessor the plan's struct phase already built -- not
the single top-level field range the existing pair resolves to.
`addressOfExpression`'s `DotVarExp` branch now also calls
`promoteNestedStructFieldCell(dot, id)` alongside the existing
`promoteStructFieldCell(dot, id)` call, reusing the SAME id
`fieldSnapshotAllocationId(dot)` already mints -- both calls are no-ops for
shapes outside their own narrow scope, exactly as `arrayPointer`'s
`DotVarExp` branch already combines `promoteStructArrayFieldCell` with the
same memoized id for `&s.arr[i]`. `promoteNestedStructFieldCell` detects
the one-level-nested shape directly (`dot.e1.isDotVarExp` whose OWN `e1` is
the root `VarExp`) rather than by extending `fieldSnapshotAllocationId`
itself; the id `addressOfExpression`'s caller passes in is therefore NOT
memoized per (receiver, field path) for this shape -- unlike the single-
level case, every `&s.inner.x` evaluation mints a fresh id via
`fieldSnapshotAllocationId`'s existing non-`VarExp`-receiver fallback (since
`dot.e1` is itself a `DotVarExp`, not a plain `VarExp`) -- a real, narrower
gap than the single-level mechanism's own identity stability, left for the
full field-PATH generalization (repeated `&s.inner.x == &s.inner.x` pointer
identity is not proven equal by this slice, though each individual pointer
still correctly aliases the cell). `writeStructCellScalarFields` is widened
to recurse one level into every (non-union) struct-typed field via
`NativeStruct.structField`'s shared-block view -- the same "seed/refresh
every scalar field's bytes on every whole-struct cell refresh" discipline
already applied to static-array fields, applied one level down; the
recursion itself is not depth-limited even though the read/write-through
pointer machinery below only resolves one level. Two new functions,
`nestedStructFieldPointerCellValue` (wired into `pointerTargetValue` and
`runPointerExpression`'s deref-read arm, alongside the existing three
pointer-cell checks) and `writeThroughNestedStructFieldPointer` (wired into
`writeLocation`'s `PtrExp` arm and `writePointerTarget`, alongside the
existing two write-through checks), mirror the sibling pairs' read/write
dispatch exactly. `dropStructCell` also clears stale
`nestedStructFieldPointerVariables`/`...OuterFieldIndices`/
`...InnerFieldIndices` entries for a fresh redeclaration, mirroring its
existing scalar-field and array-field cleanups.

Scoped narrower than even the struct-static-array-field mechanism, in the
same same-frame-only respect: `nestedStructFieldPointerVariables` and its
two index maps are NOT duplicated into child-frame walkers, so a
`&s.inner.x` pointer does not yet survive being passed into another
function call -- `writeThroughNestedStructFieldPointer` declines (returns
`false`) rather than silently losing the write when the receiver isn't in
the current frame's `locals`. The fixture above never calls into another
function after taking `&s.inner.x`, so this gap is untested, not closed.
Deeper nesting (`&s.a.b.c`, two or more levels) is also out of this slice's
scope -- `promoteNestedStructFieldCell` only recognises exactly one level
(`dot.e1.isDotVarExp` whose own `e1` is the root `VarExp`); a chain three
levels deep falls through unchanged to the generic snapshot path and keeps
throwing "Unsupported interpreter assignment target." for a write through
the pointer, exactly as before this slice. This is now the last narrow
item.7-struct-cell gap named in the array-of-struct/struct-static-array-
field notes above: the true general "(receiver, field-PATH) resolved by
walking an arbitrary-depth `DotVarExp` chain to its root `VarExp`" model
those notes called for remains a follow-up if a deeper-nesting or pointer-
identity fixture is ever proposed.

No `interpreter.md` §9.10 shim is retired by this slice, matching both
prior notes above: it widens which struct fields a `structCells` entry
backs and can be written through by pointer, it does not touch any of the
shim inventory's own named functions.

Focused runs, all green: the new fixture (all four backends); `bin/ut -s
ut.backends.runner.ct.expressions` (501 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing as
expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut
-s ut.bin.repl` (228 run, 0 failed). The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (array-of-static-array follow-up: `&a[i]` gets a cell
when the element is itself a scalar-element static array): the smallest
remaining candidate named for a follow-up -- `&a[i]` on a dynamic array
whose element type is itself a static array (`int[2][] a`), the
array-of-static-array sibling of the array-of-struct slice earlier in this
log. One new fixture, `pointer.
staticArrayElementWrittenDirectlyIsVisibleThroughEarlierPointer`
(`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit`): `int[2][] a = [[one(),
one()], [one(), one()]]; int[2]* p = &a[0]; a[0] = [ninetyNine(),
ninetyNine()]; assert((*p)[0] == 99);`. Confirmed red on Interpreter before
any production change (`1 != 99`, verified via an unnamed scratch probe
with the identical body before the fixture was given its real name and
committed); confirmed green on Ctfe, SystemLinker, and LLVMJit throughout.

Root cause, exactly the array-of-struct shape: `arrayPointer`'s VarExp
branch already calls `promoteArrayCell(source)` unconditionally, and
already mints an `arrayAllocationVariables` id regardless of element type,
but `promoteArrayCell` itself early-returned once the element type failed
both the native-scalar and (non-union) struct checks -- a static-array
element fell through both, so no `arrayCells` entry ever backed such a
pointer, and `arrayPointerCellValue` always missed, falling to the frozen
`pointer.pointerTarget` snapshot taken at address-of time.

Fix, in `impl.d`: `promoteArrayCell` now also promotes a cell for a dynamic
array whose element type is itself a static array, PROVIDED that static
array's own element type is `native_scalar.isNativeScalarType` -- no
deeper-nesting rabbit hole (array-of-array-of-struct, array-of-array-of-
array stay on the boxed path). Seeded element by element through
`NativeArray.arrayElement` (the container layer's existing inline-bytes
view over a static-array-typed element, already built per the composition
matrix, with no interpreter call site until now) and a new helper,
`writeStaticArrayCellScalarElements` -- the static-array-element sibling of
`writeStructCellScalarFields`, simpler because there is no non-scalar
sub-element case to skip (the guard above guarantees every element is
scalar). `writeArrayCellElement`/`readArrayCellElement` -- the two shared
dispatch points every `arrayCells` element read/write call site already
routes through -- each gained a `cell.elementType.isTypeSArray` branch
alongside the existing `isTypeStruct` branch: the write side calls
`writeStaticArrayCellScalarElements` directly (reused from
`promoteArrayCell`'s own seed); the read side calls a new
`arrayValueFromCell`, the static-array-element sibling of
`structValueFromCell`, simpler for the same reason (no base `Value` to
overlay onto -- every element is authoritative in the cell by
construction, so it builds a fresh `Value.arrayValue` outright). Touching
both shared dispatch functions was not optional, matching the array-of-
struct slice's own reasoning: once `promoteArrayCell` can produce a
static-array-element cell, every call site reachable through those two
functions (`writeThroughArrayCell`, `runIndexExpression`'s cell-priority
read, `arrayPointerCellValue`) can now reach it.

No `interpreter.md` §9.10 shim is retired by this slice, matching every
prior note in this log: it widens which arrays get a native cell, it does
not touch any of the shim inventory's own named functions.

This closes the item-7 "aggregates/arrays at the call site" struct/array
guest-local frontier's last openly-named same-frame gap from the array-of-
struct progress note's own framing. Remaining open items, unchanged from
the nested-struct-field note above: pointer-identity memoization for
`&s.inner.x`; deeper nesting (2+ levels, in any of the struct-field,
array-element, or now static-array-element shapes); and cross-frame
propagation of the struct-array-field/nested-field/(now)
static-array-element pointer maps -- this slice's own cell is `arrayCells`,
which already has cross-frame duplication via `child.arrayCells =
arrayCells.dup` at every existing dup site, so cross-frame propagation was
already covered for this shape by the array guest-local slice's own
original machinery, unlike the struct-field-pointer maps' same-frame-only
gap.

Focused runs, all green: the new fixture (all four backends); `bin/ut -s
ut.backends.runner.ct.expressions` (505 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing as
expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut
-s ut.bin.repl` (228 run, 0 failed). The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (struct-static-array-field cross-frame follow-up:
`&s.arr[i]` write-through survives a call into another function): of the
two remaining item-7 struct-cell gaps the array-of-static-array note above
named (both same-frame only), the smaller one -- `structArrayFieldPointer
Variables`/`structArrayFieldPointerFieldIndices` have only two maps to
propagate, versus the nested-struct-field triple. One new fixture,
`pointer.structArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller`
(`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit`, omit-Bytecode convention),
the array-typed-field sibling of the existing scalar-field cross-frame
fixture `pointer.structFieldWriteThroughPointerInCalleeIsVisibleToCaller`:
`struct S { int[3] arr; } S s; s.arr[0] = one(); int* p = &s.arr[0];
put(p, ninetyNine());` (`put` writes `*p = v;`) `return *p + s.arr[0];`,
asserting `198`. Confirmed red on Interpreter before any production
change: `object.Exception: Unsupported interpreter assignment target.`,
thrown from `writeLocation`'s `PtrExp` arm falling through
`writeThroughStructArrayFieldPointer` (its reverse-lookup maps, un-duped
into the callee's child `Walker`, missed) to the `fieldSnapshotAllocationIds`
refusal guard -- exactly the diagnostic the scalar-field cross-frame
fixture's own comment predicted for this sibling. Confirmed green on Ctfe,
SystemLinker, and LLVMJit throughout.

Fix, in `impl.d`, mirroring the scalar-field cross-frame mechanism exactly
(no new plumbing shape invented): (1) `structArrayFieldPointerVariables`/
`structArrayFieldPointerFieldIndices` are now duped into every child
`Walker` at all 7 existing scalar-field dup call sites (the same
`replace_all` edit point as `structFieldPointerVariables`'s own dup lines).
(2) A new `mergeStructArrayFieldPointerVariableMaps`, the array-field
sibling of `mergeStructFieldPointerVariableMaps`, reusing the SAME
`fieldAddressAllocations` forward map for its conflict check since both
map families mint ids through the shared `fieldSnapshotAllocationId` memo.
(3) A new `structArrayFieldPointerWritebacks` flag map (the array-field
sibling of `structFieldPointerWritebacks`), duped at the same 7 sites and
merged the same way in `writeBackFunctionState`/
`writeBackMemberFunctionState`. (4) `writeThroughStructArrayFieldPointer`
no longer requires `current !is null` (the receiver present in THIS
frame's `locals`) to proceed -- it now writes into the shared `structCells`
entry unconditionally (given a cell and reverse-lookup hit), updates the
boxed `locals` mirror only when `current` is present, and always flags
`structArrayFieldPointerWritebacks[*variable]`, mirroring
`writeThroughStructFieldPointer`'s own `current`-optional discipline. (5) A
new `writeBackStructArrayFieldPointerTargets`, the array-field sibling of
`writeBackStructFieldPointerTargets`, wired into both call sites right
after its scalar-field sibling. (6) `structValueFromCell` (until now the
scalar-only read-side mirror of `writeStructCellScalarFields`) is widened
to also overlay every scalar-element static-array field via
`NativeStruct.arrayField`, since the write-back above needs to re-derive
the OWNING frame's array field, not just its scalar fields -- the read-side
counterpart of `writeStructCellScalarFields`'s own array-field seeding,
closing a pre-existing scalar/array asymmetry in that helper as a direct
consequence of wiring this slice's writeback through it (no separate
array-only overlay function was written; the shared helper backs both the
scalar- and array-field writeback callers now).

No `interpreter.md` §9.10 shim is retired by this slice, matching every
prior note in this log: it widens which struct-cell writes survive a call
into another function, it does not touch any of the shim inventory's own
named functions.

Remaining open items, unchanged in kind from the nested-struct-field/
array-of-static-array notes above: `&s.inner.x` (nested-struct-field
pointer) is still same-frame only -- its own three-map reverse lookup
(`nestedStructFieldPointerVariables`/`...OuterFieldIndices`/
`...InnerFieldIndices`) is not yet duped into child walkers, and its own
pointer-identity memoization gap (repeated `&s.inner.x` evaluations do not
share an id) remains too; deeper nesting (2+ levels, in any of the
struct-field, array-element, or static-array-element shapes) is out of
scope everywhere. Both are real follow-up candidates, the nested-field
cross-frame gap being the more direct next slice (mirroring this one's own
recipe, but for three maps and reusing/widening `structValueFromCell`
further for the nested case).

Focused runs, all green: the new fixture (all four backends); `bin/ut -s
ut.backends.runner.ct.expressions` (509 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing as
expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut
-s ut.bin.repl` (228 run, 0 failed). The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (nested-struct-field cross-frame follow-up: `&s.inner.x`
write-through survives a call into another function): the last named
item-7 struct-cell gap the struct-static-array-field cross-frame note above
left open. One new fixture,
`pointer.nestedStructFieldWriteThroughPointerInCalleeIsVisibleToCaller`
(`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit`, omit-Bytecode convention),
the nested-field sibling of `pointer.
structArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller`: `struct
Inner { int x; } struct S { Inner inner; } S s = S(Inner(one())); int* p =
&s.inner.x; put(p, ninetyNine());` (`put` writes `*p = v;`) `return *p +
s.inner.x;`, asserting `198`. Confirmed red on Interpreter before any
production change: `object.Exception: Unsupported interpreter assignment
target.`, thrown from `writeLocation`'s `PtrExp` arm falling through
`writeThroughNestedStructFieldPointer` (its reverse-lookup maps, un-duped
into the callee's child `Walker`, missed) to the `fieldSnapshotAllocationIds`
refusal guard -- exactly the diagnostic both prior cross-frame notes
predicted for this sibling. Confirmed green on Ctfe, SystemLinker, and
LLVMJit throughout.

Fix, in `impl.d`, mirroring the struct-array-field cross-frame mechanism
exactly (no new plumbing shape invented): (1) `nestedStructFieldPointer
Variables`/`...OuterFieldIndices`/`...InnerFieldIndices` are now duped into
every child `Walker` at the same 7 dup call sites used for
`structArrayFieldPointerVariables`. (2) A new
`mergeNestedStructFieldPointerVariableMaps`, the nested-field sibling of
`mergeStructArrayFieldPointerVariableMaps` -- but simpler, since an id in
this map is NEVER memoized through `fieldAddressAllocations` (a
one-level-nested `DotVarExp`'s own `dot.e1` is itself a `DotVarExp`, so
`fieldSnapshotAllocationId` always takes its non-`VarExp`-receiver fresh-id
fallback): every id already names exactly one (variable, outer, inner)
triple, so the merge is a plain union with no (variable, field index)
conflict guard to write. (3) A new `nestedStructFieldPointerWritebacks` flag
map, duped at the same 7 sites and merged the same way in
`writeBackFunctionState`/`writeBackMemberFunctionState`. (4)
`writeThroughNestedStructFieldPointer` no longer requires `current !is null`
(the receiver present in THIS frame's `locals`) to proceed -- it now writes
into the shared `structCells` entry unconditionally (given a cell and
reverse-lookup hit), updates the boxed `locals` mirror only when `current`
is present, and always flags `nestedStructFieldPointerWritebacks[*variable]`,
mirroring `writeThroughStructArrayFieldPointer`'s own `current`-optional
discipline. (5) A new `writeBackNestedStructFieldPointerTargets`, the
nested-field sibling of `writeBackStructArrayFieldPointerTargets`, wired
into both call sites right after its array-field sibling. (6)
`structValueFromCell` (until now overlaying scalar fields and
scalar-element static-array fields only) is widened to also recurse one
level into every (non-union) struct-typed field via
`NativeStruct.structField`, mirroring `writeStructCellScalarFields`'s own
nested-field recursion -- the read-side counterpart needed so the
writeback above can re-derive the OWNING frame's nested field, not just its
top-level scalar/array fields.

No `interpreter.md` §9.10 shim is retired by this slice, matching every
prior note in this log: it widens which struct-cell writes survive a call
into another function, it does not touch any of the shim inventory's own
named functions.

Remaining open items: `nestedStructFieldPointerVariables`'s own
pointer-identity memoization gap is unchanged by this slice -- repeated
`&s.inner.x` evaluations still do not share an id, since `dot.e1` being
itself a `DotVarExp` always takes `fieldSnapshotAllocationId`'s fresh-id
fallback (each pointer still correctly aliases the cell; only identity
comparison between two separately-taken `&s.inner.x` pointers is unproven).
Deeper nesting (2+ levels, in any of the struct-field, array-element, or
static-array-element shapes) remains out of scope everywhere, as does the
full field-PATH generalization the nested-struct-field follow-up's own note
named. With this slice, every item-7 struct-cell cross-frame gap the
struct-static-array-field and array-of-static-array notes named is closed;
the largest remaining item-7 gap is CLASSES, entirely untouched by the
struct/array cell machinery above -- class objects stay third in the
migration order per the representation-change design sketch's own
"Migration order" bullet.

Focused runs, all green: the new fixture (all four backends); `bin/ut -s
ut.backends.runner.ct.expressions` (513 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing as
expected); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut
-s ut.bin.repl` (228 run, 0 failed). The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (class phase starts: scalar-field native cell, reverse
propagation through `&c.field`): item 7's "Migration order" bullet moves to
its third and last named phase -- "Class objects third -- they need native
object identity, vptr/monitor layout, and constructor lifetime" -- now that
the struct phase above is saturated. This is the FIRST class-phase slice,
mirroring the struct phase's own first slice (`structFieldWrittenDirectly
IsVisibleThroughEarlierPointer`) exactly, one field-shape narrower: only a
scalar field of a class object bound to its own plain local gets a cell.
Class REFERENCE identity (two variables aliasing the SAME object, a field
reached through `this`, a field of a `new`-returned or callee-owned object)
is untouched -- see "What this slice does NOT do" below.

Confirmed red first: `class C { int x; int y; } C c = new C(); c.x = one();
c.y = two(); int* p = &c.x; c.x = ninetyNine(); assert(*p == 99);` (every
value seeded from a runtime function call) threw on the Interpreter --
`object.Exception: Unsupported interpreter field access.` -- BEFORE any
production change, thrown from `fieldSnapshotAllocationId`'s
`structFieldIndex(dot)` call: `structFieldIndex` resolves the receiver's
type via `receiverStructType`, which returns `null` for a class receiver, so
`&c.field` could not even take an address-of snapshot, let alone alias
writes -- a real pre-existing bug in the shared address-of path, not
something the struct phase's own tests ever exercised (they only ever took
`&s.field` of a struct). SystemLinker, Ctfe, and LLVMJit all confirmed green
throughout. Committed as `pointer.
classFieldWrittenDirectlyIsVisibleThroughEarlierPointer` in `tests/ut/
backends/runner/ct/expressions.d`, scoped to `Ctfe`/`Interpreter`/
`SystemLinker`/`LLVMJit` -- `Bytecode` omitted per the same omit-don't-pin
convention the struct fixture's own backend set already uses.

Fix, in `impl.d`: (1) `fieldSnapshotAllocationId` now dispatches its
field-index computation on the receiver's own static type --
`classFieldIndex(dot)` for a class receiver (`receiverClassType(dot.e1) !is
null`), `structFieldIndex(dot)` otherwise -- fixing the throw at its root
rather than only reachable class-cell code paths. The two field-index
spaces never collide in `fieldAddressAllocations[variable]`, which is keyed
per-variable and a variable's static type never changes. (2) A new
`NativeBlock[VarDeclaration] classCells` map, parallel to `structCells`, but
built from a plain `NativeBlock` rather than `NativeStruct`: a class's own
`Type.size` is a reference's pointer width, not the object body's size, so
`NativeStruct.allocate(TypeStruct)` cannot size it. `promoteClassCell`
instead sums (`fieldByteOffset(field) + typeByteSize(field.type)`) over
`layout.classFields` -- facts this file already reads elsewhere
(`nativeClassFieldValue` already does exactly this for native exception
fields) -- rather than introducing a new raw DMD field (e.g.
`ClassDeclaration.structsize`) this codebase does not otherwise consult.
(3) A new reverse lookup, `classFieldPointerVariables`/
`classFieldPointerFieldIndices`, the class sibling of
`structFieldPointerVariables`/`structFieldPointerFieldIndices`, populated by
a new `promoteClassFieldCell` (the class sibling of
`promoteStructFieldCell`), called from `addressOfExpression`'s `DotVarExp`
arm alongside the existing struct/nested-struct promotions. (4) A new
`writeClassCellScalarFields` (the class sibling of
`writeStructCellScalarFields`), and a new `classFieldPointerCellValue` (the
class sibling of `structFieldPointerCellValue`), consulted by both
`runPointerExpression`'s deref-read arm and `pointerTargetValue`, mirroring
the three existing struct-family checks at each site. (5) `writeCelledLocal`
gained a `classCells` refresh-or-drop branch alongside its existing
`structCells` one -- `writeLocation`'s `DotVarExp` arm rewrites the WHOLE
class object the same way it does a struct, so a direct field write
refreshes every scalar field's bytes. (6) `child.classCells = classCells.
dup;` added at the same 7 child-frame-spawn sites that already dup
`structCells`, so a nested call sees the promoted cell too (sharing its
bytes by reference) -- matching the struct phase's OWN first slice, which
duped `structCells` at all 7 sites without yet duping its reverse-lookup
maps. `classFieldPointerVariables`/`classFieldPointerFieldIndices` are
similarly NOT duped into child frames in this slice, matching that same
bounded first-slice precedent; no fixture here needs cross-frame class-field
pointer dereference. Writing THROUGH the pointer (`*p = v`) is untouched:
the id stays recorded in `fieldSnapshotAllocationIds`, so `writeLocation`'s
`PtrExp` arm continues to refuse it exactly as it does for structs.

What this slice does NOT do, to be precise about item 7's class-phase
state: only an address-taken SCALAR field of a plain, non-dataseg class
local gets a cell. Class REFERENCE identity is entirely unmodeled -- a
second variable holding the SAME object (`C c2 = c;`), a field reached
through `this` inside a member function, a field of a `new`-returned
pointer never bound to a plain local, and a field reached through a
function argument all stay on the pre-existing boxed `locals`/`Value.
classValue` path, where `writeBackByValueClassArguments`'s post-call value
diffing remains the only approximation of aliasing (interpreter.md §9.10).
This slice does not touch, retire, or narrow that shim -- it widens a
DIFFERENT gap (address-of-field snapshot staleness for the single-local
case), the class-phase counterpart of what the struct phase's first slice
did before its own later cross-frame/write-through/reference-alias
follow-ups. Cross-frame class-field-pointer dereference, writing THROUGH
the pointer, nested class fields, and array/struct-typed class fields are
all unexercised and unimplemented, matching the struct phase's own
incremental history -- expect a comparable sequence of follow-up slices if
this phase proceeds the same way arrays and structs did. No
`interpreter.md` §9.10 shim is retired by this slice.

Focused runs, all green: the new fixture (all four backends); `bin/ut -s
ut.backends.runner.ct.expressions` (517 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing as
expected); `bin/ut -s ut.backends.runner.ct.exceptions` (130 run, 0 failed);
`bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.bin.repl` (228 run, 0 failed); `bin/ut -s ut.backends.evaluator.eval` (71
run, 0 failed). The full `bin/ut --random` was left to the orchestrator per
the usual long-suite handoff.

Progress 2026-07-15 (class-field write-through-pointer: `*p = v` through
`&c.field` now aliases via the native cell): the class-phase-starts slice
above named this gap directly in its own "What this slice does NOT do" --
writing THROUGH a `&c.field` pointer still threw even after that slice gave
the receiver a `classCells` entry. This slice closes exactly that gap for
the same narrow, already-cell-supported case, mirroring the struct phase's
own write-through-pointer slice (`writeThroughStructFieldPointer`).

New fixture, `pointer.classFieldWriteThroughPointerUpdatesField`
(`tests/ut/backends/runner/ct/expressions.d`), scoped to
`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit` (`Bytecode` omitted, matching
the direct-write class fixture's own backend set): `class C { int x; int
y; }`, `C c = new C(); c.x = one(); c.y = two();` (every value seeded from
a runtime function call), `int* p = &c.x; *p = ninetyNine();`, asserting
`c.x == 99` by a direct field read (the write-through counterpart of the
direct-write fixture's earlier-pointer read). Confirmed RED on Interpreter
before any production change: `object.Exception: Unsupported interpreter
assignment target.`, thrown from `writeLocation`'s `PtrExp` arm's existing
`fieldSnapshotAllocationIds` refusal guard -- `&c.x`'s id is recorded there
by `fieldSnapshotAllocationId` regardless of receiver type, and nothing yet
short-circuited that refusal for a class-field pointer, exactly the
diagnostic the struct phase's own write-through-pointer slice hit for
`&s.field` before its fix. Confirmed green on Ctfe, SystemLinker, and
LLVMJit throughout.

Fix, in `impl.d`: a new `writeThroughClassFieldPointer`, the class sibling
of `writeThroughStructFieldPointer`, built directly from facts the read-side
`classFieldPointerCellValue` already computes (a plain `NativeBlock`, not a
`NativeStruct`, so the field's byte range comes from
`classFields`/`fieldByteOffset`/`typeByteSize` rather than
`NativeStruct.field`). Given the pointer value, it looks the allocation id
up in `classFieldPointerVariables`/`classFieldPointerFieldIndices` (the
class-phase-starts slice's own reverse lookup) to find the receiver's
`classCells` entry and field index; a miss on any of the lookups, or a
receiver whose current boxed `locals` value is no longer a class object,
returns `false` and does nothing. On a hit, it writes `value`'s bytes into
`cell.bytes[offset .. offset + size]` (`native_scalar.writeScalar`, sized by
the field's own declared type) and re-derives the boxed `locals` mirror as
`current.withClassField(fieldIndex, value)`, mirroring
`writeThroughStructFieldPointer`'s cell-then-mirror discipline. Unlike the
struct sibling, there is no cross-frame writeback flag: this phase's own
`classFieldPointerVariables`/`classFieldPointerFieldIndices` are not duped
into child frames (the class-phase-starts slice's own bounded scope), so a
genuine hit always finds `variable` bound in THIS frame's own `locals` --
no separate frame can ever own it. `writeLocation`'s `PtrExp` arm now calls
this helper right after `writeThroughNestedStructFieldPointer` and before
the existing `fieldSnapshotAllocationIds` refusal check, and
`writePointerTarget` (the compound-assignment/atomic/post-increment
write-back path) calls it at the same relative position among its own
struct-family checks, mirroring both call sites' existing wiring for the
struct family exactly.

No `interpreter.md` §9.10 shim is retired by this slice, matching every
prior note in this log.

Remaining open items, unchanged from the class-phase-starts slice's own
list except for the one line this slice closes: class REFERENCE identity
(`C c2 = c;`, a field reached through `this`, a field of a `new`-returned
pointer never bound to a plain local, a field reached through a function
argument) is still entirely unmodeled; cross-frame class-field-pointer
dereference, nested class fields, and array/struct-typed class fields are
still unexercised and unimplemented. Expect a comparable sequence of
follow-up slices to the struct phase's own cross-frame/nested-field
history if this phase proceeds the same way.

Focused runs, all green: the new fixture (all four backends, `4 test(s)
run, 0 failed`); `bin/ut -s ut.backends.runner.ct.expressions` (521 run, 0
failed, 5/5 failing as expected); `bin/ut -s ut.backends.runner.ct.structs`
(291 run, 0 failed); `bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0
failed); `bin/ut -s ut.backends.runner.ct.cerealed` (164 run, 0 failed,
1/1 failing as expected); `bin/ut -s ut.backends.runner.ct.exceptions` (130
run, 0 failed); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed);
`bin/ut -s ut.bin.repl` (228 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-15 (class-field cross-frame follow-up: `&c.field`
write-through-pointer survives a call into another function): the
write-through-pointer slice above (8a392ea2) closed same-frame `*p = v`
through `&c.field` but left cross-frame propagation unmodeled, matching the
struct phase's own history before its cross-frame follow-up
(`pointer.structFieldWriteThroughPointerInCalleeIsVisibleToCaller`). This
slice closes the class-field sibling gap the same way.

New fixture,
`pointer.classFieldWriteThroughPointerInCalleeIsVisibleToCaller` (`tests/ut/
backends/runner/ct/expressions.d`), scoped to
`Ctfe`/`Interpreter`/`SystemLinker`/`LLVMJit` (`Bytecode` omitted, matching
the other class fixtures' own backend set): `class C { int x; int y; }`,
`C c = new C(); c.x = one(); c.y = two();` (every value seeded from a
runtime function call), `int* p = &c.x;` in a function `f`, then `put(p,
ninetyNine());` (`put` writes `*p = v;` in a SEPARATE function), `return *p
+ c.x;`, asserting `f() == 198` -- the class-field sibling of the existing
scalar struct-field cross-frame fixture, mirroring its exact shape.
Confirmed RED on Interpreter before any production change: `object.
Exception: Unsupported interpreter assignment target.`, thrown from
`writeLocation`'s `PtrExp` arm's existing `fieldSnapshotAllocationIds`
refusal guard -- `writeThroughClassFieldPointer`'s reverse-lookup maps
(`classFieldPointerVariables`/`classFieldPointerFieldIndices`), un-duped
into the callee's child `Walker`, missed, exactly the diagnostic the struct
phase's own cross-frame fixture predicted for this sibling. Only 1 failure
in the full `ut.backends.runner.ct.expressions` run (525 total, the other
524 including the new fixture's Ctfe/SystemLinker/LLVMJit instances all
green). Confirmed green on Ctfe, SystemLinker, and LLVMJit throughout.

Fix, in `impl.d`, mirroring the struct-field cross-frame mechanism exactly
(no new plumbing shape invented): (1) `classFieldPointerVariables`/
`classFieldPointerFieldIndices` are now duped into every child `Walker` at
the same 7 dup sites that already dupe `classCells`. (2) A new
`mergeClassFieldPointerVariableMaps`, the class sibling of
`mergeStructFieldPointerVariableMaps`, reusing the SAME
`fieldAddressAllocations` forward map for its conflict check --
`fieldSnapshotAllocationId` mints a class-field id through that same
per-(receiver, field-index) memo, only dispatching the field-INDEX
computation itself (`classFieldIndex` vs `structFieldIndex`) on receiver
kind, so the id space and its forward map are shared with the struct
family. (3) A new `classFieldPointerWritebacks` flag map (the class sibling
of `structFieldPointerWritebacks`), duped at the same 7 sites and merged the
same way in `writeBackFunctionState`/`writeBackMemberFunctionState`. (4)
`writeThroughClassFieldPointer` already tolerated `current is null` (it
never required the receiver present in this frame's own `locals` to begin
with -- an accident of the write-through-pointer slice's own cell-then-
mirror discipline, not a deliberate cross-frame design) but never flagged a
cross-frame writeback; it now sets `classFieldPointerWritebacks[*variable]
= true` unconditionally after writing the cell, mirroring
`writeThroughStructFieldPointer`'s own flagging discipline. (5) A new
`writeBackClassFieldPointerTargets`, the class sibling of
`writeBackStructFieldPointerTargets`, wired into both call sites right
after its nested-struct-field sibling. (6) A new `classValueFromCell`, the
class sibling of `structValueFromCell` (until now struct-only): re-derives
a class `Value` from a `classCells` `NativeBlock`'s scalar-field bytes via
`classFields`/`fieldByteOffset`/`typeByteSize` (a class cell is a plain
`NativeBlock`, not a `NativeStruct`, so it cannot reuse `structValueFromCell`
itself), the read-side counterpart `writeBackClassFieldPointerTargets` needs
to re-derive the OWNING frame's object from the shared cell.

`classFieldPointerCellValue` (the deref-READ side, `runPointerExpression`/
`pointerTargetValue`) needed no code change: it already looked up
`classFieldPointerVariables`/`classFieldPointerFieldIndices` and `classCells`
directly with no same-frame `locals` presence check, so duping the reverse-
lookup maps into child frames (step 1) was sufficient on its own to make a
cross-frame deref-READ through `&c.field` work too, alongside the
write-through fix above.

No `interpreter.md` §9.10 shim is retired by this slice, matching every
prior note in this log: it widens which class-cell writes survive a call
into another function, it does not touch any of the shim inventory's own
named functions. This slice also does NOT touch class REFERENCE identity in
any way -- the fixture's `int* p = &c.field` is the same raw field-pointer
shape the struct phase already handles cross-frame; a second variable
aliasing the SAME object (`C c2 = c;`), a field reached through `this`, and
a field of a `new`-returned pointer never bound to a plain local remain
entirely unmodeled, exactly as the class-phase-starts slice's own "What
this slice does NOT do" section described.

Remaining open items, unchanged from the write-through-pointer slice's own
list except for the one line this slice closes: class REFERENCE identity
(`C c2 = c;`, a field reached through `this`, a field of a `new`-returned
pointer never bound to a plain local, a field reached through a function
argument) is still entirely unmodeled; nested class fields and
array/struct-typed class fields are still unexercised and unimplemented.
Expect a comparable sequence of follow-up slices to the struct phase's own
nested-field history if this phase proceeds the same way.

Focused runs, all green: the new fixture (all four backends, folded into
the full suite run below since it added no isolated fixture-only command);
`bin/ut -s ut.backends.runner.ct.expressions` (525 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.runner.ct.structs` (291 run, 0
failed); `bin/ut -s ut.backends.runner.ct.arrays` (346 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing
as expected); `bin/ut -s ut.backends.runner.ct.exceptions` (130 run, 0
failed); `bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.bin.repl` (228 run, 0 failed); `bin/ut -s ut.backends.evaluator.eval` (71
run, 0 failed). The full `bin/ut --random` was left to the orchestrator per
the usual long-suite handoff.

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
2. Separate unittest execution from REPL evaluation, then delete the private
   reify → `Value` → `toString` scaffolding per backend (decision 4) as each
   gains the formatter. `runTests` must receive success/diagnostic directly;
   only a REPL expression cell executes the prelude formatter and consumes its
   returned string. Do not retain `Value` or render a dummy `void` result just
   to reuse the `Evaluator.eval(FuncDeclaration)` path.
3. Remove the *shared* `quickbite.lang.Value` (decision 2026-06-17):
   once no backend depends on it as a cross-backend type, relocate the
   tree-walking interpreter's execution-result carrier to its package, then
   delete the shared struct and `tests/ut/backends/evaluator/value.d`
   together. Do not reproduce a display-oriented general-purpose `Value`
   privately: the carrier exists only for recursive expression/function
   execution and uses immediate scalar results plus the native handles,
   locations, callables, and metadata that execution actually requires.

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
     marshaller swap is invisible to `ci.sh`/`bin/bench`; only the `sys/`
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

7. (2026-07-09, un-gated by the correctness-ceiling decision above; scalar
   storage clarified 2026-07-13.) Run the native-layout experiment in the
   tree-walker: immediate scalar expression results may stay boxed, addressable
   scalar locations use stable native cells, aggregates/arrays live in native
   ABI layout behind a handle reusing DMD's own field offsets, and pointers
   become real addresses into that storage. This is the interpreter-wide
   representation change the 2026-06-23 measured result deferred to — the
   right unit of change, unlike the rejected bolt-on marshaller. Success
   criteria, in order:
   - the `interpreter.md` §9.10 shims are deleted one by one, each deletion
     proven by its ratchet fixtures staying green through the real path
     (`emplaceRef` executes its actual body; `memcpy` and the `gc_*` hooks
     route through ordinary FFI);
   - the parked representation-ceiling gap fixtures (§9.10 "gap fixtures")
     re-earn `Interpreter` in their matrices;
   - the cerealed frontier resumes on the new representation, and the
     latency A/B (item 6's original question) is finally measured on real
     suites once they run.

   Consolidation debt (accrued 2026-07-15/16 landing the aggregate, class, and
   union cells; pay this down before widening the matrix further). Each new
   (receiver, field/element) shape was landed as its own red-first slice, and
   each grew a parallel family: a `promote*` entry point, a
   `*PointerVariables`/`*FieldIndices`/`*Writebacks` reverse-lookup trio, a
   `*CellValue` reader, a `writeThrough*` writer, a `merge*Maps`, a
   `writeBack*Targets`, and a `drop*Cell` obligation. There are now ~10 such
   families differing only in key shape and which `NativeStruct`/`NativeArray`
   view they compose. This duplication is not cosmetic — it has already
   produced real bugs, because every family must independently honour three
   obligations (dup on frame fork, merge on return, drop on rebind) and missing
   one is invisible until it corrupts: a `drop*Cell` site was missing for
   exactly one family (a stale `&a[i].inner.x` resolved into a later binding),
   and unifying the fork side uncovered three sites that silently duped a
   narrower field set than their siblings.
   - Do NOT add an eleventh family. The next shape that needs a cell should
     instead drive the generalization: one mechanism keyed by (root variable,
     field PATH) — `a[i].inner.x` described as a path rather than a bespoke map
     per shape — so promote/read/write/merge/writeback/drop each exist once.
   - Per-frame cell state is now forked in one place
     (`Walker.forkPerFrameCellsInto`); that is the model for the rest. Merge
     and drop should likewise become single dispatch points instead of
     per-family calls hand-wired at every site.
   - `runNewStructPointerExpression`'s fork site still duplicates a narrow
     three-field subset with no recorded rationale; confirm it is deliberate or
     fold it into the common path.

   Design sketch 2026-07-09 (the "plan before code" session; no code, no
   fixtures, no shim deletion). A *native block* is a stable byte range laid
   out with DMD's own offsets, stride, and alignment; a *handle* is the
   interpreter-owned metadata for one block — `Type*`, byte length, ownership,
   mutability, and its GC root-registration token. Interior addresses are views
   over a block plus an offset; a raw `void*` is produced only at the last step
   before FFI or an intrinsic, and is never the ownership token.

   - **Storage shape.** Integral, floating, enum, null, and pointer rvalues keep
     expression evaluation direct through immediate scalar arms. This does not
     make a box the authority for an addressable scalar local: use either an
     eager native local slot or measured lazy promotion to one, as decided
     above. Recursive aggregate boxes collapse to one aggregate-handle arm. A
     static array is one inline block; a dynamic array is a real D slice header
     (`ptr`, `length`) over a separately tracked element block; a struct is one
     block laid out with DMD field offsets. Class references keep the boxed
     object representation until the class phase.
   - **Address stability.** Every address reachable through `&local`,
     `array.ptr`, slice construction, pointer arithmetic, `memcpy`, or FFI
     points into a native block, never into a boxed snapshot. Direct access to
     an addressable scalar local reads and writes that same cell. Blocks must
     not move while an interpreter pointer can reach them; when array growth
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
   compiled D's silent staleness; and class object bodies, deferred
   wholesale. Unions and overlapping fields are no longer an open question --
   see the Status "unions and overlapping fields" progress note below for
   what DMD reports and why `NativeStruct` needed no change; the one named
   residue is a union member that is itself an aggregate (struct- or
   array-typed) handle view, which has no dedicated pinning test yet, though
   `structField`/`arrayField`'s offset-and-type-driven implementation has no
   struct-vs-union branch to get wrong and so applies to it unchanged.
   `writeSliceHeader`'s scanned-destination contract is no longer open:
   `dest` is now a `(NativeBlock, byteOffset)` pair, and the function
   throws before writing a GC-owned pointer into a destination the
   collector never scans (see Status's "ownership vs GC-visibility"
   note above for the exact rule and the cases -- a zero-length array's
   null block address, or a genuinely non-GC source address -- that
   stay legal despite an unscanned destination).

   Progress against the "Next PR" list below: the array-native block handle
   skeleton is done (`NativeArray`: stable block, `Type`, length, stride,
   ownership, scan policy); capacity and growth through real storage are done
   (`capacity`, `reserve`, extending in place or reallocating, per the
   `NativeBlock.tryExtendTo`/GC-realloc progress notes above); a borrowed-block
   guard on `reserve` is done; `writeSliceHeader`'s scanned-destination
   contract is done (see above); and the struct phase (`NativeStruct`: one
   block sized and laid out with DMD's own `structsize`/field offsets, the
   same conservative-vs-no-scan choice `NativeArray.allocate` makes) is done.
   The two have been composed: a struct's `T[]` field now carries a real
   slice header written by `NativeArray.writeSliceHeader` at
   `NativeStruct.fieldByteOffset`, verified against the host compiler's own
   layout, proving the scan-policy and scanned-destination contracts were
   designed to fit together. Nested aggregate field views (a struct field
   that is itself a struct, or a static-array inline field) are also done
   now — the "no nested-struct or array-typed field composition" gaps noted
   above are closed; see the Status "nested aggregate field views" progress
   note above for `NativeBlock.subRange`/`NativeStruct.structField`/
   `arrayField`. Dynamic-array-field read-back is also done now
   (`NativeStruct.sliceField` — reading an existing slice-header field
   back as a `NativeArray` over its pointed-to element block, distinct
   from writing one and from the sub-range views above since a slice
   header points at a separately tracked block rather than being inline;
   see the Status "dynamic-array-field read-back" progress note above for
   the `@system`/`@trusted` boundary and the ownership/scan/capacity
   contract). Array sub-slicing is also done now (`NativeArray.slice` —
   the handle-level expression of the correctness-ceiling "slices into
   locals" item: a real, aliasing, `@safe` sub-range view via `NativeBlock.
   subRange`/`NativeArray.adopt`, `borrowed` and non-growable, distinct
   from `sliceField`'s `@system` slice-header reconstruction because it
   only ever slices an already-verified block rather than reconstructing
   one from a pointer read out of memory; see the Status "array
   sub-slicing" progress note above for the bounds/overflow argument and
   the measured `GC.addrOf`-of-a-past-the-end-pointer fact). Unions and
   overlapping fields are also closed now — no production code needed a
   change; see the Status "unions and overlapping fields" progress note
   above for what DMD reports for a plain union's zero-offset fields and
   an anonymous union's flattened, overlapping ones, and why the
   block-wide conservative `Scan` policy is the only safe rounding for a
   pointer-bearing union. Array length assignment is also done now
   (`NativeArray.setLength` — the handle-level primitive behind a guest
   `arr.length = n`, built on the existing `capacity`/`reserve`/
   `tryExtendTo` machinery; see the Status "array length assignment"
   progress note above for the compiled-D-checked shrink/grow contract,
   the borrowed-growth decision (`setLength` refuses every growth of a
   `borrowed` handle unconditionally — shrink stays legal and
   storage-free — a narrowing made by review, with growth-and-rebind
   left to a future call site), and the shrink-then-grow re-zeroing
   subtlety) — this was the last named container primitive the array
   phase needed. The
   composition that had only gone one way — a struct could view its own
   fields as handles, but an array could not view a struct-typed element as
   one — is now symmetric too: `NativeArray.structElement` (and the new
   `NativeStruct.adopt` factory it is built on) is also done now; see the
   Status "array-of-struct element views" progress note above for the
   bounds/stride argument, the `Ownership.borrowed`/zero-`trueByteSize`
   contract, and the oversized-block decision `adopt` shares with
   `NativeArray.adopt`. That note's own remaining, narrower composition gap
   — an array-typed array element (`Point[][]`, or an array of static
   arrays) had no `arrayElement`/`sliceElement` counterpart, the way
   `NativeStruct` has both `structField` and `arrayField`/`sliceField` for
   its own fields — is also closed now: see the Status "array-element
   aggregate views" progress note above for the `@safe`/`@system` split
   (identical in shape to `structElement`/`sliceField`'s own) and the
   `readSliceHeaderBytes` de-duplication it required. The struct/array
   composition matrix is now symmetric on both axes — struct→{struct,
   static array, slice} fields and array→{struct, static array, slice}
   elements — with no accessor left one-directional. None of this has a
   user-visible display or FFI change yet.

   Progress 2026-07-10: the native-layout types now have a first production
   caller, and interpreter.md §9.10's `reinterpretLocalPointerLoad` +
   `floatBits`/`doubleBits` entry is narrowed, not retired -- see the
   Status "first interpreter call site" progress note above for the full
   account. Scoped precisely: `impl.d`'s `reinterpretLocalPointerLoad` (a
   `*cast(T*) &local` scalar reinterpret-load) now routes through a real
   `NativeBlock` plus the new `native_scalar.d` codec instead of a
   hardcoded `float`/`uint` and `double`/`ulong` name match, and
   `floatBits`/`doubleBits` are deleted from `impl.d`. But the entry's
   retirement condition ("native layout makes ALL reinterpret loads
   structural") is unmet -- aggregate, pointer, `real`, and widening
   reinterprets are still boxed/refused through the untouched passthrough
   path -- so no §9.10 shim is retired; only its scope is narrowed. That is
   the *scalar* leaf case only -- `reinterpretLocalPointerLoad` itself is
   not deleted, a local's authoritative storage is still a boxed `Value`
   (`locals[VarDeclaration]` is still `Value[VarDeclaration]`, not a
   `NativeBlock`), and the array/struct composition matrix built up above
   still has no call site at all: no guest expression yet reaches
   `arrayElement`/`sliceElement`/
   `structElement`/`arrayField`/`sliceField`. What remains, the next step:
   make a guest-level addressable local use authoritative native storage,
   including a scalar `&local` cell rather than the current temporary scalar
   byte snapshot, then wire array/struct call sites for the container types
   themselves — including, for `slice` specifically, the guest-level
   `~=`-on-a-slice reallocation semantics the "array sub-slicing" progress
   note explicitly does not model, and, for `setLength`, guest-level
   `~=`/append more generally
   (still a call-site allocate-and-rebind operation, per the "array length
   assignment" progress note) and keeping a previously written slice header
   in sync with a later reallocating `setLength` (the call site's problem,
   not this container's, exactly as for a stale compiled-D slice) — and
   only after that, further shim retirement one `interpreter.md` §9.10
   entry at a time, each proven by its ratchet fixtures staying green
   through the real path. Class objects stay third in the migration order,
   per the "Migration order" bullet above. Latency is measured only once the
   array and struct correctness gates are green and a real suite actually
   reaches native storage; item 6 already showed the benchmark suite never
   crossed the old marshaller seam. Until then, native layout is justified by
   the correctness ceiling (`&local`, unions, reinterpret casts, slices into
   locals), not by a benchmark.

   Progress 2026-07-10 (aggregate handles get their first production
   caller): `NativeStruct`/`NativeArray` themselves -- not just the scalar
   codec -- now have a real caller: `ffi_marshal.d`'s `unmarshalStruct`/
   `unmarshalStaticArray` (read side) and `marshalArgument`'s `Tstruct`/
   `Tsarray` arms (write side) route through `field(index)`/`element(index)`
   instead of a hand-rolled `sym.fields[i].offset`/`index * elementSize`
   walk -- see the Status "aggregate handles get their first production
   caller" progress note above for the full account, including the
   basetype-dispatch and offset/size-identity proofs. This is still the FFI
   seam, not the tree-walker's core representation: locals stay boxed, and
   no guest expression yet reaches `arrayElement`/`sliceElement`/
   `structElement`/`arrayField`/`sliceField` (the composition accessors this
   note left untouched) or `&local`/array/struct at all -- that remains the
   next step described just above.

   Progress 2026-07-10 (slice element layout joins the aggregate authority):
   the FFI marshaller's last two hand-rolled per-element layout walks --
   `marshalSliceArgument` (write side) and `unmarshalSlice`'s `default:` arm
   (read side) -- now route through `NativeArray.allocate`/`NativeArray.
   borrow` and `element(index)` too, closing the "must not grow a second set
   of D layout rules" guardrail for every struct/array/slice sub-slice site
   in `ffi_marshal.d`. See the Status "slice element layout joins the
   aggregate authority" progress note above for the full account, including
   the stride/offset-identity and lifetime proofs. Still the FFI seam, not
   the tree-walker's core representation, and still no new guest-reachable
   call site for the composition accessors -- that remains the next step
   described just above.

   Progress 2026-07-15 (class reference identity, decomposition item 1 --
   same-frame plain-variable aliasing): the class phase's first
   guest-reachable slice beyond `&c.field`. Before this, class REFERENCE
   identity was unmodelled: each class-typed local boxed its OWN
   independent copy of the field array (`Value.withClassField` builds a
   brand-new value written only into the target variable's own `locals`),
   so `C c2 = c; c2.x = 99; assert(c.x == 99)` silently read the stale
   original. Fixture
   `class.aliasedVariableWriteIsVisibleThroughOriginal.{Interpreter,
   SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d` (RED
   diagnostic on Interpreter: `0 != 99`; green on the SystemLinker
   oracle). Fix: `C c2 = c;` / `c2 = c;` now eagerly shares ONE
   authoritative `classCells` `NativeBlock` between the two variables --
   `registerClassAliasIfPlainVar` (called from `runDeclarationExpression`
   and `runAssignExpression`) promotes the source's cell via
   `promoteClassCell` and points the target's `classCells` entry at the
   same block (a `NativeBlock` is a value struct over a `bytes` slice, so
   the copy shares the byte range, exactly as two
   `structFieldPointerVariables` share a `structCells` block). The general
   class-field read and write paths now consult that cell WHEN PRESENT:
   `runDotVarExpression` reads through `classCellFieldValue` before the
   boxed `classFieldAt`, and `writeLocation`'s `DotVarExp` arm mirrors the
   write through `writeClassCellFieldIfPresent` before the boxed
   `withClassField` -- both no-ops for a non-`VarExp` receiver, a receiver
   with no `classCells` entry, or a non-scalar field, so every existing
   class/struct test that never aliases keeps its boxed `locals` path
   unchanged. Scope limited to scalar (`native_scalar.isNativeScalarType`)
   fields, matching the existing `classCells` slice. No §9.10 shim retired
   (`writeBackByValueClassArguments` retirement begins with decomposition
   item 3's `this`-reached aliasing, per the migration plan). Focused
   suites all green: ct.expressions 527/0, ct.structs 291/0,
   ct.cerealed 164/0, ct.diagnostics 177/0, ct.exceptions 130/0,
   ct.pollution 3/0, interpreter 218/0, bin.repl 228/0,
   evaluator.eval 71/0 (the "failing as expected" counts are pre-existing
   `@ShouldFail` characterizations, untouched). Remaining follow-up:
   decomposition item 2 (cross-frame aliasing -- an aliased class local
   passed into or returned from a callee), item 3 (`this`-reached
   aliasing, which begins retiring `writeBackByValueClassArguments`), and
   item 4 (aggregate composition -- a class field that is itself a
   struct/array/class handle rather than a scalar).

   Progress 2026-07-15 (class reference identity, decomposition item 2 --
   cross-frame parameter aliasing): investigated the task's own headline
   scenario first (`void mutate(C c) { c.x = 99; } ... mutate(c); assert(c.x
   == 99);`) and found it ALREADY GREEN today, both as a fresh fixture and
   as the pre-existing `classReferencePassedByValueMutatesObject` fixture in
   `cerealed.d`: `writeCelledLocal` (used by every `writeLocation` `VarExp`
   arm, including the §9.10 shim `writeBackByValueClassArguments`'s own
   whole-value writeback) already refreshes a variable's `classCells` entry
   on any whole-value overwrite when one is present, so the existing
   value-diffing shim and the byte-shared cell mechanism cooperate
   correctly for a single caller/callee alias pair, even across a call
   boundary. The REAL divergence: the shim links only the ONE argument
   expression it was invoked with back to the caller; it has no mechanism
   linking two DIFFERENT parameter `VarDeclaration`s bound from the SAME
   argument within the callee's OWN frame. Fixture
   `class.sameObjectPassedAsTwoParametersSharesIdentity.{Interpreter,
   SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d`: `void
   combine(C a, C b) { b.x = 99; assert(a.x == 99); }` called as `combine(c,
   c)` -- RED diagnostic on Interpreter: `0 != 99` (green on the
   SystemLinker oracle). Fix: `registerClassArgumentAliases` (mirrors
   `registerClassAliasIfPlainVar`, cross-frame) in `impl.d`, called from
   `runFunction` and `runMemberFunction` right after `child.classCells =
   classCells.dup` and before `child.bindFunctionParameters` -- for every
   non-`ref` class-typed parameter whose argument expression is a plain
   `VarExp`, promotes (or reuses) `this` (the CALLER)'s `classCells` entry
   for the source variable via the existing `promoteClassCell`, then points
   `child`'s entry for the PARAMETER at the SAME `NativeBlock`. Two
   parameters bound from the same source variable therefore both alias the
   identical cell (the second's `promoteClassCell` call is a no-op reusing
   the first's promotion), and the single-parameter caller/callee case gets
   the identical byte-shared cell too, keeping it green through the real
   path rather than the diffing shim alone. Drops any stale
   `child.classCells` entry inherited from an ancestor recursive call of
   the same `FuncDeclaration` first (parameters are the same
   `VarDeclaration` at every recursion depth), matching the existing
   `scalarCells`/`arrayCells`/`structCells` drop-on-rebind pattern in
   `bindFunctionParameters`, so a non-aliasing argument at a later call
   cannot resurrect an unrelated ancestor cell. No §9.10 shim retired:
   `writeBackByValueClassArguments` still runs unconditionally after every
   call (its own existing fixtures, including
   `classReferencePassedByValueMutatesObject`, stay green through the real
   path now rather than needing it, but retiring the shim itself is out of
   scope for this slice -- per the work order, retirement begins with
   decomposition item 3's `this`-reached aliasing). Scope limited to
   `runFunction`/`runMemberFunction` (the free-function and member-function
   call paths that already call `writeBackByValueClassArguments`); the
   ref-returning-function and constructor call sites were left untouched --
   narrower argument-expression plumbing there, and no fixture demanded it.
   Focused suites all green: ct.expressions 529/0 (5 failing as expected),
   ct.structs 291/0, ct.exceptions 130/0, interpreter 218/0, bin.repl
   228/0, evaluator.eval 71/0, ct.cerealed 164/0 (1 failing as expected),
   ct.pollution 3/0, ct.diagnostics 177/0 (all "failing as expected" counts
   are pre-existing `@ShouldFail` characterizations, untouched). Remaining
   follow-up: decomposition item 3 (`this`-reached aliasing, which begins
   retiring `writeBackByValueClassArguments`) and item 4 (aggregate
   composition -- a class field that is itself a struct/array/class handle
   rather than a scalar).

   Progress 2026-07-15 (class reference identity, decomposition item 3 --
   `this`-reached aliasing): a METHOD mutating `this.x` must be visible to
   another caller-side alias of the SAME object through the shared class
   cell, exactly like item 2's `combine(a, b)` case, except the mutating
   write happens through `this` rather than an ordinary by-value
   parameter. Fixture
   `class.methodMutatingThisIsVisibleThroughAliasedParameter.{Interpreter,
   SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d`: `void
   mutateAndCheck(C other) { this.x = 99; assert(other.x == 99); }` called
   as `c.mutateAndCheck(c)` -- both the receiver and the by-value
   parameter `other` bind from the SAME argument expression `c`, so
   `other` already gets a `classCells` entry shared with the caller's `c`
   (item 2's `registerClassArgumentAliases`), but `this` itself was bound
   from a plain boxed `Value` with no cell at all, so the assert read
   stale data. RED diagnostic on Interpreter: `0 != 99` (green on the
   SystemLinker oracle) -- the divergence is observed DURING the call,
   inside the method's own frame, before `writeBackThis`'s post-call
   whole-value copy into the receiver's location ever runs, so that
   existing writeback path cannot save it. Fix, all in `impl.d`: (1) a new
   `classCellKeyVariable` helper factors the receiver-to-`classCells`-key
   resolution `classCellFieldValue`/`writeClassCellFieldIfPresent` already
   did for a bare `VarExp`, and extends it to a bare `ThisExp`, resolving
   to `currentFunction.vthis` -- dmd's own stable `VarDeclaration` identity
   for the hidden `this` parameter, always available in the CURRENT
   frame's own `currentFunction`; (2) `registerClassThisAlias`, called
   from `runMemberFunction` right after `registerClassArgumentAliases` and
   before `child.bindFunctionParameters`, mirrors that function exactly
   for the receiver: promotes (or reuses) the CALLER's cell for
   `receiverExpression`'s source variable (when a bare `VarExp`) and
   points `child.classCells[function_.vthis]` at the same `NativeBlock`,
   dropping any stale entry inherited from an ancestor recursive call
   first, matching the existing drop-on-rebind pattern. A `this.x = v`
   write inside the method body now reaches the shared cell through the
   existing `writeClassCellFieldIfPresent` call in `writeLocation`'s
   `DotVarExp` arm, unchanged except for resolving its key through the new
   helper.

   A first attempt regressed two PRE-EXISTING virtual-dispatch fixtures
   (`class.virtualCallUsesDynamicClass.Interpreter`,
   `interface.virtualCallUsesRuntimeDispatch.Interpreter`) with a native
   `ArraySliceError: slice [16 .. 20] extends past source array of length
   0` inside `classCellFieldValue`: `Base value = new Child(...); return
   value.score;` dispatches to `Child.score()`, whose body reads
   `this.field`. `registerClassThisAlias` had promoted `value`'s cell
   sized from `value`'s STATIC type (`Base`, zero fields, since `field` is
   Child-only and Base's declared type is all `promoteClassCell` ever
   sees), then aliased it to `vthis`, whose type is `Child` (the override
   method's OWN declaring class) -- reading `this.field` through `vthis`'s
   LARGER layout ran past the tiny `Base`-sized cell. This is a new
   mismatch class item 1/2 never hit: their field-access call sites always
   resolve `dot.var`/`classFieldIndex` against the receiver EXPRESSION's
   own static type, so the cell's sizing type and the reading type were
   always identical; `this`-through-`vthis` is the first path where the
   sizing type (the CALLER's static declared type) and the reading type
   (the OVERRIDE method's own declaring class) can legitimately differ
   under polymorphism. Fix: `registerClassThisAlias` now compares the
   source variable's static class (`ClassDeclaration` identity) against
   `vthis`'s class and skips aliasing entirely on any mismatch -- the
   override body then falls back to its own boxed `thisValue`, exactly as
   before this slice, for every polymorphic/virtual-dispatch call; the
   exact-type case (this slice's own fixture, no inheritance involved)
   still aliases normally.

   No §9.10 shim retired. `writeBackByValueClassArguments` is NOT
   retired: it still protects whole-boxed-value uses of a by-value class
   argument (e.g. passing it onward, printing it, equality checks) that
   never go through `classCellFieldValue`'s scalar-field-only read
   authority -- only the CELL's bytes get refreshed by a direct field
   write, not the boxed `locals`/`thisValue` mirror the shim's diffing
   still reconciles for every other use. Retiring it would need those
   non-field-read uses proven safe first, which is out of surgical scope
   for this slice per the task's own instruction to leave the shim in
   place rather than risk a regression; its own fixture
   (`classReferencePassedByValueMutatesObject` in `ct/cerealed.d`) is
   additionally a FREE FUNCTION case (`fill(box)`), untouched by this
   `this`-reached slice's `runMemberFunction`-only change, and stays
   green through the pre-existing item 2 path exactly as before. Focused
   suites all green: ct.expressions 531/0 (5 failing as expected),
   ct.structs 291/0, ct.exceptions 130/0, ct.cerealed 164/0 (1 failing as
   expected), interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0 (all
   "failing as expected" counts are pre-existing `@ShouldFail`
   characterizations, untouched). Remaining follow-up: item 4 (aggregate
   composition -- a class field that is itself a struct/array/class
   handle rather than a scalar); shim retirement itself remains deferred
   until a slice addresses `writeBackByValueClassArguments`'s
   whole-value-use coverage, not just scalar-field reads/writes.

   Progress 2026-07-15 (class reference identity, decomposition item 4 --
   aggregate composition, class field that is itself a struct): the
   smallest real divergence in item 4's own scope -- a class field that is
   a STRUCT (as opposed to a scalar), reached one level deeper than every
   prior class-phase slice. `&c.inner.x` where `inner` is a (non-union)
   struct field of class `c` and `x` is a scalar field of `inner` mirrors
   the struct phase's own nested-struct-field slice
   (`promoteNestedStructFieldCell`/`nestedStructFieldPointerCellValue`)
   one receiver type over. Fixture `pointer.
   nestedClassStructFieldWrittenDirectlyIsVisibleThroughEarlierPointer.
   {Ctfe,Interpreter,SystemLinker,LLVMJit}` in `tests/ut/backends/runner/
   ct/expressions.d`: `struct Inner { int x; int y; } class C { Inner
   inner; }`, `C c = new C(); c.inner.x = one(); c.inner.y = two(); int*
   p = &c.inner.x; c.inner.x = ninetyNine(); assert(*p == 99);` (every
   value seeded from a runtime function call) -- the direct-write/read-
   through-pointer direction, matching `pointer.
   classFieldWrittenDirectlyIsVisibleThroughEarlierPointer`'s own
   direction rather than `addressOfNestedStructFieldWriteThroughUpdatesField`'s
   write-through-pointer one. RED diagnostic confirmed on Interpreter
   before any production change: `1 != 99` (`*p` returned the frozen
   address-of-time snapshot instead of the post-write value). Green on
   SystemLinker and Ctfe throughout.

   Root cause: `&c.inner.x`'s `dot.e1` (`c.inner`) is itself a
   `DotVarExp`, not a bare `VarExp`, so `promoteClassFieldCell` (which
   requires `dot.e1.isVarExp`) no-opped -- no `classCells` entry was ever
   promoted for `c`, so the pointer carried only its frozen boxed
   snapshot with no reverse-lookup entry to alias through.

   Fix, all in `impl.d`: (1) a new `promoteNestedClassStructFieldCell`,
   the class-receiver sibling of `promoteNestedStructFieldCell` --
   detects the one-level-nested shape (`dot.e1.isDotVarExp` whose own
   `e1` is the root `VarExp`, itself class-typed, whose own field is a
   non-union struct, whose own scalar field `x` is the target), promotes
   (or reuses) the receiver's `classCells` entry via the existing
   `promoteClassCell`, and records `id` -- the SAME id
   `addressOfExpression`'s caller already mints via
   `fieldSnapshotAllocationId` -- in a new (receiver, outer field index,
   inner field index) reverse-lookup triple,
   `nestedClassStructFieldPointerVariables`/`...OuterFieldIndices`/
   `...InnerFieldIndices`, called from `addressOfExpression`'s
   `DotVarExp` branch alongside the four existing promotion calls. (2)
   `writeClassCellScalarFields` -- previously scalar-fields-only, unlike
   its struct sibling `writeStructCellScalarFields`, which already
   recurses into nested struct fields -- now recurses one level into
   every (non-union) struct-typed field too: since a `classCells` entry
   is a plain `NativeBlock` with no `NativeStruct` wrapper of its own
   (unlike a `structCells` entry), the nested view is built directly via
   `NativeStruct.adopt(cell.subRange(offset, size), nestedStructType)`
   -- the same composition accessor `NativeStruct.structField` uses
   internally for a struct receiver -- then recurses into the existing
   `writeStructCellScalarFields`. This is what keeps the cell's nested
   bytes current on every whole-object refresh (`promoteClassCell`'s
   initial seed and `writeCelledLocal`'s refresh-on-every-write), so the
   direct write `c.inner.x = ninetyNine()` (which rewrites the WHOLE
   class object via `writeLocation`'s `DotVarExp` arm, same as any other
   class field write) actually reaches the promoted cell's nested bytes.
   (3) A new `nestedClassStructFieldPointerCellValue`, the class-receiver
   sibling of `nestedStructFieldPointerCellValue`, wired into
   `pointerTargetValue` and `runPointerExpression`'s deref-read arm
   alongside the existing five pointer-cell checks -- resolves the same
   reverse lookup, adopts the same `NativeStruct` view over the outer
   field's byte sub-range (via `classFields`/`fieldByteOffset`/
   `typeByteSize`, the same facts `classFieldPointerCellValue` already
   reads), and reads the inner field's scalar bytes through it.

   Reused the struct phase's own composition accessors exactly as
   directed: `NativeStruct.adopt`/`.structField`/`.field` are the SAME
   accessors the struct-receiver nested-field slice already built; no
   new `NativeStruct`/`NativeBlock` method was added.

   No §9.10 shim retired (as expected -- `writeBackByValueClassArguments`
   protects whole-boxed-value uses, untouched by this scalar/struct-
   field-composition read authority, same as every prior class-phase
   slice). Scope kept deliberately narrow, matching every prior class-
   phase slice's own bounded first-cut: (a) same-frame only --
   `nestedClassStructFieldPointerVariables` and its two index maps are
   NOT duplicated into child-frame walkers, so this pointer does not yet
   survive being passed into another function call, unlike the single-
   level `classFieldPointerVariables`, which already gained that
   cross-frame dup in an earlier slice; (b) read-only -- writing THROUGH
   this pointer (`*p = v`) is untouched and still refused by
   `writeLocation`'s `PtrExp` arm's existing `fieldSnapshotAllocationIds`
   guard, mirroring how the struct phase's OWN nested-field mechanism
   first shipped write-through-only and grew a cross-frame/direct-write
   follow-up later; (c) a class field that is a static array
   (`class C { int[3] arr; }`) is untouched -- a real, separate
   divergence (the array-typed-field sibling this note leaves for a
   follow-up, mirroring `promoteStructArrayFieldCell`'s own role next to
   `promoteNestedStructFieldCell`); (d) no `dropClassCell` exists yet at
   all (unlike `dropStructCell`), so a recursively-redeclared class local
   does not yet drop a stale `classCells`/reverse-lookup entry -- a
   pre-existing gap this slice did not introduce and did not need to
   close, since no fixture here exercises recursion.

   Focused suites all green: ct.expressions 535/0 (5 failing as
   expected), ct.structs 291/0, ct.exceptions 130/0, ct.cerealed 164/0 (1
   failing as expected), ct.diagnostics 177/0, ct.pollution 3/0,
   ct.arrays 346/0, interpreter 218/0, bin.repl 228/0, evaluator.eval
   71/0 (all "failing as expected" counts are pre-existing `@ShouldFail`
   characterizations, untouched). The full `bin/ut --random` was left to
   the orchestrator per the usual long-suite handoff. Remaining
   follow-up: a class field that is a static array (the other aggregate-
   composition shape item 4 named); cross-frame and write-through-pointer
   follow-ups for this nested shape, mirroring the struct phase's own
   incremental history; `dropClassCell` (stale-cell cleanup on
   recursive redeclaration) remains unimplemented for the whole class
   phase, not just this slice; shim retirement itself remains deferred
   until a slice addresses `writeBackByValueClassArguments`'s
   whole-value-use coverage.

   Progress 2026-07-15 (class reference identity, decomposition item 4 --
   aggregate composition, nested class-struct field, write-through-pointer
   follow-up): closes the write-through gap the prior slice's own note left
   open for `&c.inner.x` (class receiver, one-level-nested struct field,
   scalar leaf) -- `*p = v` now writes through the pointer, mirroring
   `writeThroughNestedStructFieldPointer`'s struct-receiver shape one
   receiver type over, exactly as the read side
   (`nestedClassStructFieldPointerCellValue`) already did for
   `classFieldPointerCellValue`. Same-frame only, as scoped.

   Fixture `pointer.
   nestedClassStructFieldWrittenThroughPointerIsVisibleDirectly.
   {Ctfe,Interpreter,SystemLinker,LLVMJit}` in `tests/ut/backends/runner/
   ct/expressions.d`: `struct Inner { int x; } class C { Inner inner; }`,
   `C c = new C(); c.inner.x = seed(); int* p = &c.inner.x; *p = 5; assert(
   c.inner.x == 5);` (seeded from a runtime function call) -- the opposite
   direction from the prior slice's own fixture
   (`nestedClassStructFieldWrittenDirectlyIsVisibleThroughEarlierPointer`),
   mirroring `addressOfNestedStructFieldWriteThroughUpdatesField`'s
   struct-receiver shape but with a class receiver. RED diagnostic
   confirmed on Interpreter before any production change: `object.
   Exception: Unsupported interpreter assignment target.` (the pre-
   existing `fieldSnapshotAllocationIds` refusal in `writeLocation`'s
   `PtrExp` arm, since no dedicated write-through helper existed yet for
   this pointer shape). Green on SystemLinker and Ctfe throughout.

   Fix, all in `impl.d`: a new `writeThroughNestedClassStructFieldPointer`,
   the class+nested-struct-field sibling of
   `writeThroughNestedStructFieldPointer` (struct receiver) and
   `writeThroughClassFieldPointer` (single-level class field) -- resolves
   the same `nestedClassStructFieldPointerVariables`/
   `...OuterFieldIndices`/`...InnerFieldIndices` reverse lookup the read
   side already built, adopts the same `NativeStruct` view over the outer
   field's byte sub-range (via `classFields`/`fieldByteOffset`/
   `typeByteSize`, the same facts `nestedClassStructFieldPointerCellValue`
   already reads), writes the inner field's scalar bytes through it with
   `writeScalar`, then re-derives the boxed `locals` mirror from the
   (already-updated) whole object via `current.classFieldAt(outerFieldIndex)
   .withStructField(innerFieldIndex, value)` composed back with
   `current.withClassField(outerFieldIndex, ...)`, mirroring
   `writeThroughNestedStructFieldPointer`'s cell-then-mirror discipline.
   Wired into `writeLocation`'s `PtrExp` arm (alongside its five existing
   pointer-shape checks) and `writePointerTarget` (alongside its own five),
   in both cases immediately after the single-level
   `writeThroughClassFieldPointer` check, matching the read side's own
   ordering in `pointerTargetValue`.

   No writeback-flag map (`nestedClassStructFieldPointerWritebacks`) was
   added, unlike the single-level `classFieldPointerWritebacks`/
   `structFieldPointerWritebacks`: that mechanism exists solely to recover
   a CROSS-frame write once control returns to the owning frame, and
   `nestedClassStructFieldPointerVariables` is still same-frame only (not
   duplicated into child-frame walkers), so no cross-frame case can occur
   yet for this pointer shape -- adding the flag now would be speculative
   plumbing with no fixture to exercise it. When the cross-frame follow-up
   lands, mirror `writeBackClassFieldPointerTargets`/
   `writeBackNestedStructFieldPointerTargets` at that point.

   No §9.10 shim retired (as expected -- `writeBackByValueClassArguments`
   protects whole-boxed-value uses, untouched by this scalar/struct-field-
   composition write-through, same as every prior class-phase slice).

   Focused suites all green: ct.expressions 539/0 (5 failing as expected,
   pre-existing `@ShouldFail` characterizations, unchanged from before this
   slice), ct.structs 291/0, ct.exceptions 130/0, interpreter 218/0,
   bin.repl 228/0, evaluator.eval 71/0. The full `bin/ut --random` was left
   to the orchestrator per the usual long-suite handoff. Remaining
   follow-up: cross-frame support for this nested shape (this pointer
   passed into another function call); a class field that is a static
   array (item 4's other named aggregate-composition shape, still
   untouched); `dropClassCell` (stale-cell cleanup on recursive
   redeclaration) remains unimplemented for the whole class phase; shim
   retirement itself remains deferred until a slice addresses
   `writeBackByValueClassArguments`'s whole-value-use coverage.

   Progress 2026-07-15 (class reference identity, decomposition item 4 --
   aggregate composition, class field that is a static array): closes the
   other aggregate-composition shape the nested-class-struct-field slices'
   own notes named as untouched -- `&c.arr[i]` where `arr` is a
   scalar-element static-array field of a plain class local `c`, the
   class-receiver sibling of the struct-static-array-field follow-up.

   Fixture `pointer.classStaticArrayFieldElementWrittenDirectlyIsVisibleThrough
   EarlierPointer.{Ctfe,Interpreter,SystemLinker,LLVMJit}` in `tests/ut/
   backends/runner/ct/expressions.d`: `class C { int[3] arr; }`, `C c = new
   C(); c.arr[0] = one(); int* p = &c.arr[0]; c.arr[0] = ninetyNine();
   assert(*p == 99);` (every value seeded from a runtime function call),
   mirroring `pointer.structStaticArrayFieldElementWrittenDirectlyIsVisible
   ThroughEarlierPointer`'s own shape one receiver type over. RED diagnostic
   confirmed on Interpreter before any production change -- and it was NOT
   the expected aliasing snapshot mismatch: `c.arr[0] = one();`, a plain
   direct write with no pointer involved yet, itself threw `object.
   Exception: Unsupported interpreter field access.` This was a bigger,
   pre-existing gap than the task's own framing assumed -- a class-typed
   static-array-field element write was entirely unsupported, not merely
   missing pointer-aliasing. Root cause: both `writeIndexLocation` (the
   compound-assignment/atomic/post-increment path) and
   `runIndexAssignExpression` (the plain `=` path, the one this fixture's
   `c.arr[0] = one();` actually takes) resolve a `DotVarExp` receiver's
   field index unconditionally via `structFieldIndex`, which requires
   `receiverStructType` and throws for a class receiver -- neither function
   had a class-receiver branch at all, unlike `writeLocation`'s own
   `DotVarExp` arm, which already dispatches on `receiver.isClassObject`.
   After adding that class branch to both (mirroring `writeLocation`'s own
   dispatch, using `classFieldIndex`/`classFieldAt`/`withClassField` instead
   of the struct-only accessors, and routing the whole rewritten class
   object back through the SAME `writeLocation(dot.e1, ...)` call the struct
   branch already uses, so `writeCelledLocal`'s existing class-cell refresh
   applies unchanged), the RED became the actually-intended aliasing
   mismatch: `1 != 99`. Green on SystemLinker and Ctfe throughout.

   Fix, all in `impl.d`: (1) `writeIndexLocation`'s and
   `runIndexAssignExpression`'s `DotVarExp` branches each gained a
   class-receiver arm (checked via the static `receiverClassType`), closing
   the direct-write gap described above -- a prerequisite this task's own
   red fixture exposed but that item 4's earlier slices, which only ever
   exercised scalar and nested-struct fields (never an array-typed field on
   a class), never had reason to hit. (2) A new
   `promoteClassArrayFieldCell`, the class-receiver sibling of
   `promoteStructArrayFieldCell` -- detects a static-array field of scalar
   element type on a plain class-typed `VarExp` receiver, promotes (or
   reuses) the receiver's `classCells` entry via the existing
   `promoteClassCell`, and records `id` -- the SAME id `arrayPointer`'s
   `DotVarExp` branch already mints via `fieldSnapshotAllocationId` -- in a
   new (receiver, field index) reverse-lookup pair,
   `classArrayFieldPointerVariables`/`classArrayFieldPointerFieldIndices`,
   called from `arrayPointer`'s `DotVarExp` branch alongside the existing
   `promoteStructArrayFieldCell` call. (3) `writeClassCellScalarFields` --
   previously scalar-and-nested-struct-fields only -- now also widens every
   scalar-element static-array field: since a `classCells` entry is a plain
   `NativeBlock` with no `NativeStruct` wrapper of its own (unlike a
   `structCells` entry, whose `NativeStruct.arrayField` handles this
   directly), the array view is built via `NativeArray.adopt(cell.subRange(
   offset, size), elementType, staticArrayLength(arrayType))` -- the same
   composition primitive `NativeStruct.arrayField` uses internally -- then
   every element is written with `writeScalar`, mirroring
   `writeStructCellScalarFields`'s own static-array-field widening. This is
   what keeps the cell's array bytes current on every whole-object refresh
   (`promoteClassCell`'s initial seed and `writeCelledLocal`'s
   refresh-on-every-write), so the direct write `c.arr[0] = ninetyNine()`
   (which rewrites the WHOLE class object via `writeLocation`'s `DotVarExp`
   arm/`runIndexAssignExpression`'s new class branch, same as any other
   class field write) actually reaches the promoted cell's array bytes. (4)
   A new `classArrayFieldPointerCellValue`, the class-receiver sibling of
   `structArrayFieldPointerCellValue`, wired into `pointerTargetValue` and
   `runPointerExpression`'s deref-read arm alongside the existing six
   pointer-cell checks -- resolves the reverse lookup, adopts the same
   `NativeArray` view over the field's byte sub-range, and reads the
   element at the pointer's own element offset through it.

   Reused the struct phase's own composition primitive exactly as directed:
   `NativeArray.adopt` is the SAME primitive `NativeStruct.arrayField`
   already uses internally; no new `NativeArray`/`NativeBlock` method was
   added.

   No §9.10 shim retired (as expected -- `writeBackByValueClassArguments`
   protects whole-boxed-value uses, untouched by this array-field-
   composition read authority, same as every prior class-phase slice).
   Scope kept deliberately narrow, matching every prior class-phase slice's
   own bounded first cut: (a) same-frame only --
   `classArrayFieldPointerVariables`/`...FieldIndices` are NOT duplicated
   into child-frame walkers, so this pointer does not yet survive being
   passed into another function call, unlike `structArrayFieldPointerVariables`,
   which already gained that cross-frame dup in an earlier struct-phase
   slice; (b) read-only -- a `writeThroughClassArrayFieldPointer` was
   drafted (mirroring `writeThroughStructArrayFieldPointer`/
   `writeThroughClassFieldPointer`'s cell-then-mirror discipline) and wired
   into `writeLocation`'s `PtrExp` arm and `writePointerTarget`, but then
   deliberately REVERTED before this commit: no fixture in this task's own
   scope drives that direction (the struct-array-field slice's own
   write-through-pointer code path is exercised only by its CROSS-FRAME
   fixture, `pointer.structArrayFieldWriteThroughPointerInCalleeIsVisibleTo
   Caller`, which this same-frame-only slice has no equivalent of yet), so
   landing it here would be untested production code -- a genuine
   write-through-pointer follow-up remains open, to land alongside its own
   red fixture; (c) `dropClassCell` (stale-cell cleanup on recursive
   redeclaration) remains unimplemented for the whole class phase, a
   pre-existing gap this slice did not introduce and did not need to close.

   Focused suites all green: ct.expressions 543/0 (5 failing as expected,
   pre-existing `@ShouldFail` characterizations, unchanged from before this
   slice), ct.structs 291/0, ct.arrays 346/0, ct.exceptions 130/0,
   interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0. The full
   `bin/ut --random` was left to the orchestrator per the usual long-suite
   handoff. Remaining follow-up: write-through-pointer support for this
   shape (drafted and reverted, see above); cross-frame support (this
   pointer passed into another function call); `dropClassCell` remains
   unimplemented for the whole class phase; shim retirement itself remains
   deferred until a slice addresses `writeBackByValueClassArguments`'s
   whole-value-use coverage. With decomposition item 4's two named
   aggregate-composition shapes (nested class-struct field, class
   static-array field) now both covered for the read/direct-write direction,
   the remaining class-phase surface is cross-frame and write-through-
   pointer follow-ups plus `dropClassCell`.

   Progress 2026-07-15 (class reference identity, `dropClassCell` -- the
   whole-class-phase gap every prior class-phase note flagged as missing):
   closes the stale-cell-on-rebind gap the struct/array phases already
   closed via `dropStructCell`/`dropArrayCell`, but the class phase never
   got its own version of.

   Fixture `pointer.recursiveClassDeclarationDropsStaleClassCell.
   {Ctfe,Interpreter,SystemLinker,LLVMJit}` in `tests/ut/backends/runner/
   ct/expressions.d`, mirroring `recursiveStructDeclarationDropsStaleStructCell`
   one receiver type over: `class C { int x; }`, a `valueForDepth` helper
   (avoids dmd's struct-ternary blit lowering that masked the struct
   sibling's own gap -- not applicable to classes, kept for fixture
   parity), and `rec(depth)` that declares `C c = new C();`, sets
   `c.x = valueForDepth(depth)`, takes `int* p = &c.x;`, returns `*p` at
   depth 0, else recurses and returns `c.x * 1000 + inner`. RED diagnostic
   confirmed on Interpreter before any production change: `rec(1)` returned
   `100100`, not the expected `1100` (SystemLinker/Ctfe/LLVMJit all agreed
   on `1100`). Root cause confirmed exactly as this task's framing
   predicted, but the mechanics are a corruption, not a plain stale read:
   depth 1 promotes `classCells[c]`; the depth-0 recursive call's
   `child.classCells = classCells.dup` copies the `NativeBlock` handle
   (its `_bytes` is a slice) into the child frame, sharing the SAME
   underlying byte buffer; depth 0's fresh `C c = new C();` does not drop
   that stale/shared entry (no `dropClassCell` existed), so `c.x =
   valueForDepth(0);`'s whole-object refresh (`writeCelledLocal`'s
   `classCells` branch) mutates the SHARED bytes in place, corrupting
   depth 1's own cell with depth 0's value before depth 1 ever reads `c.x`
   back. Confirms the task's own framing (a stale/incorrect cell survives
   a rebind of the same `VarDeclaration`), one layer more indirect than a
   simple "read returns the old value" because the struct/array phases'
   own `dropStructCell`/`dropArrayCell` already closed the equivalent gap
   for every other aggregate kind.

   Fix, in `impl.d`: a new `dropClassCell`, the class sibling of
   `dropStructCell` -- drops `variable`'s `classCells` entry (if any)
   together with every stale reverse-lookup entry that pointed at it
   across all three class-field pointer mechanisms decomposition item 4
   built (`classFieldPointerVariables`/`...FieldIndices`,
   `nestedClassStructFieldPointerVariables`/`...OuterFieldIndices`/
   `...InnerFieldIndices`, `classArrayFieldPointerVariables`/
   `...FieldIndices`), plus `fieldAddressAllocations` (shared with the
   struct phase's own memo, so removing it here is a harmless no-op at
   every current call site, kept for parity). Wired into
   `runDeclarationExpression` alongside the existing `scalarCells.remove`/
   `dropArrayCell`/`dropStructCell` calls -- the declaration/loop/
   recursion fresh-binding site this task's own fixture exercises.

   Deliberately NOT wired into `bindFunctionParameters`/
   `bindLazyFunctionParameter` (the other two `dropStructCell` call
   sites): unlike the struct/array phases, the class phase already has its
   own more specific fresh-binding handling for parameters --
   `registerClassArgumentAliases`/`registerClassThisAlias` run BEFORE
   `bindFunctionParameters` and already do `child.classCells.remove(
   parameter)` themselves before conditionally re-seeding it for
   reference-identity aliasing (`combine(c, c)` sharing one cell). Calling
   the new `dropClassCell` from `bindFunctionParameters` as well would run
   AFTER that re-seeding and immediately undo it, breaking the existing
   class-parameter-aliasing tests -- confirmed by reasoning through the
   call order, not just asserted; left as a pre-existing, narrower
   surface than this task's own fixture, which is declaration/loop/
   recursion-shaped, not parameter-binding-shaped.

   No §9.10 shim retired (as expected -- `writeBackByValueClassArguments`
   protects whole-boxed-value uses, unrelated to this stale-cell-on-rebind
   fix).

   Focused suites all green: ct.expressions 547/0 (5 failing as expected,
   pre-existing `@ShouldFail` characterizations, unchanged from before this
   slice), ct.structs 291/0, ct.arrays 346/0, ct.exceptions 130/0,
   ct.control_flow 336/0, interpreter 218/0, bin.repl 228/0,
   evaluator.eval 71/0. The full `bin/ut --random` was left to the
   orchestrator per the usual long-suite handoff. Remaining follow-up: a
   `classCells`-reverse-lookup-map staleness check for the
   parameter-binding path (narrower than this slice's scope, and no
   fixture here exercises it -- `registerClassArgumentAliases` already
   drops the forward `classCells` entry there, but not the three reverse-
   lookup maps); cross-frame and write-through-pointer follow-ups for the
   nested/array aggregate-composition shapes (unchanged, pre-existing);
   shim retirement itself remains deferred until a slice addresses
   `writeBackByValueClassArguments`'s whole-value-use coverage. With this
   slice, every named "`dropClassCell` (whole class phase)" gap in prior
   progress notes is now closed for the declaration/loop/recursion
   fresh-binding path.

   Progress 2026-07-15 (class-array-field write-through-pointer: the
   follow-up `02a08c67`'s own commit message named explicitly -- `*p = v`
   through `&c.arr[i]`, a class-receiver, scalar-element static-array
   field): closes the write-through-pointer gap `02a08c67` deliberately
   left open after drafting and reverting an untested version of exactly
   this code, mirroring `writeThroughStructArrayFieldPointer` (the struct
   sibling) and `writeThroughClassFieldPointer`/
   `writeThroughNestedClassStructFieldPointer` (the class-receiver
   write-through siblings already landed).

   Fixture `pointer.classArrayFieldElementWrittenThroughPointerIsVisible
   Directly.{Ctfe,Interpreter,SystemLinker,LLVMJit}` in `tests/ut/backends/
   runner/ct/expressions.d`, mirroring `pointer.nestedClassStructField
   WrittenThroughPointerIsVisibleDirectly`'s shape one aggregate-
   composition case over: `class C { int[3] arr; }`, `c.arr[0] = one();`,
   `int* p = &c.arr[0];`, `*p = 5;`, then `assert(c.arr[0] == 5);`. RED
   confirmed on Interpreter before any production change: `object.
   Exception: Unsupported interpreter assignment target.` at the `*p = 5;`
   line -- `writeLocation`'s `PtrExp` arm had no class-array-field-pointer
   check, so it fell through every existing write-through check to the
   `fieldSnapshotAllocationIds` refusal guard. Green on SystemLinker and
   Ctfe throughout.

   Fix, in `impl.d`: a new `writeThroughClassArrayFieldPointer`, the
   class-receiver sibling of `writeThroughStructArrayFieldPointer` --
   resolves the same `classArrayFieldPointerVariables`/
   `classArrayFieldPointerFieldIndices` reverse lookup
   `classArrayFieldPointerCellValue` (the read side) already uses, adopts
   the same `NativeArray.adopt(cell.subRange(offset, size), elementType,
   staticArrayLength(arrayType))` view over the field's byte sub-range
   (since a `classCells` entry is a plain `NativeBlock`, not a
   `NativeStruct`), writes the element at the pointer's own element offset
   with `writeScalar`, then re-derives the boxed `locals` mirror via
   `current.classFieldAt(*fieldIndex).withArrayElement(elementIndex,
   value)`/`current.withClassField(*fieldIndex, updatedField)` -- the same
   two calls the existing direct-write class-array-field-element path
   already uses. Wired into `writeLocation`'s `PtrExp` arm and
   `writePointerTarget` alongside the existing six write-through checks.

   No §9.10 shim retired (as expected -- `writeBackByValueClassArguments`
   protects whole-boxed-value uses, unrelated to this write-through-pointer
   addition).

   Focused suites all green: ct.expressions 551/0 (5 failing as expected,
   pre-existing `@ShouldFail` characterizations, unchanged from before this
   slice), ct.structs 291/0, ct.arrays 346/0, ct.exceptions 130/0,
   interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0. The full
   `bin/ut --random` was left to the orchestrator per the usual long-suite
   handoff. Remaining follow-up: cross-frame support for this shape (this
   pointer passed into another function call) -- unlike the single-level
   `classFieldPointerVariables`/`nestedClassStructFieldPointerVariables`
   maps, `classArrayFieldPointerVariables` is not yet duplicated into
   child-frame walkers; §9.10 shim retirement itself remains deferred
   until a slice addresses `writeBackByValueClassArguments`'s
   whole-value-use coverage.

   Progress 2026-07-15 (class-array-field pointer cross-frame follow-up):
   closes the smaller of the two remaining item-7 class-cell cross-frame
   gaps this task was asked to pick between -- `&c.arr[i]` (a
   scalar-element static-array field of a plain class local) surviving a
   call into another function -- deferring the nested-class-struct-field
   pointer (`&c.inner.x`) cross-frame gap as still open. Chosen as the
   smaller slice because a directly-precedented mechanism already existed
   twice over: the struct-receiver sibling's own cross-frame follow-up
   (`056e5590`, `structArrayFieldPointerVariables`/
   `structArrayFieldPointerWritebacks`/
   `mergeStructArrayFieldPointerVariableMaps`/
   `writeBackStructArrayFieldPointerTargets`) and the class single-field
   pointer's own cross-frame follow-up (`5314162a`,
   `classFieldPointerWritebacks`/`mergeClassFieldPointerVariableMaps`/
   `writeBackClassFieldPointerTargets`/`classValueFromCell`) combine
   directly into this shape's fix, whereas the nested-class-struct-field
   pointer has no landed cross-frame sibling anywhere in the codebase yet
   (the struct-receiver nested-field pointer's own cross-frame follow-up,
   `f9dafa6f`, is a larger diff and its merge helper's "never memoized"
   assumption would need separate verification for the class-receiver
   shape).

   Fixture
   `pointer.classArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller.
   {Ctfe,Interpreter,SystemLinker,LLVMJit}` in `tests/ut/backends/runner/
   ct/expressions.d`, mirroring `pointer.
   structArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller`'s shape
   one receiver type over: `class C { int[3] arr; }`, `c.arr[0] = one();`,
   `int* p = &c.arr[0];`, a `put(int* p, int v) { *p = v; }` callee, `put(p,
   ninetyNine());`, then `return *p + c.arr[0];` asserting `198`. RED
   confirmed on Interpreter before any production change: `object.
   Exception: Unsupported interpreter assignment target.` at the `*p = v;`
   line inside `put` -- the callee's own child `Walker` duped `classCells`
   (sharing the cell's bytes) but never duped
   `classArrayFieldPointerVariables`/`classArrayFieldPointerFieldIndices`,
   so the callee's own `writeThroughClassArrayFieldPointer` reverse-lookup
   missed and the write fell through to the `fieldSnapshotAllocationIds`
   refusal guard. Green on Ctfe, SystemLinker, and LLVMJit throughout.

   Fix, all in `impl.d`, mirroring `056e5590`'s mechanism combined with
   `5314162a`'s class-cell value-derivation helper: (1) a new
   `classArrayFieldPointerWritebacks` flag map, declared alongside
   `classArrayFieldPointerVariables`/`FieldIndices`. (2)
   `classArrayFieldPointerVariables`/`FieldIndices`/`Writebacks` are now
   duped into every child `Walker` at the same 7 sites that already dupe
   `classFieldPointerVariables`/`FieldIndices`/`Writebacks`. (3) a new
   `mergeClassArrayFieldPointerVariableMaps`, the array-typed-field sibling
   of `mergeClassFieldPointerVariableMaps` -- a class-array-field id is
   memoized through the SAME `fieldAddressAllocations[variable]` map a
   class scalar field's id is (`arrayPointer`'s `DotVarExp` branch mints
   both via `fieldSnapshotAllocationId`), so the same conflict-checked
   merge applies unchanged. (4) `writeThroughClassArrayFieldPointer` now
   sets `classArrayFieldPointerWritebacks[*variable] = true` unconditionally
   on every successful write (it already tolerated a missing `current` --
   an accident of its existing cell-then-mirror discipline, same as the
   struct sibling before its own cross-frame follow-up). (5) a new
   `writeBackClassArrayFieldPointerTargets`, wired into
   `writeBackFunctionState`/`writeBackMemberFunctionState` alongside the
   existing `writeBackClassFieldPointerTargets` call, refreshing the owning
   frame's boxed mirror via `classValueFromCell` once control returns. (6)
   `classValueFromCell` -- previously scalar-field-only -- widened to also
   overlay every scalar-element static-array field via a `NativeArray`
   adopted over the field's own byte sub-range, the read-side mirror of
   `writeClassCellScalarFields`'s own array-field widening, mirroring
   `structValueFromCell`'s identical widening in `056e5590`.

   Stale doc comments corrected in the same diff: the
   `classArrayFieldPointerVariables`/`FieldIndices` field declaration and
   `writeThroughClassArrayFieldPointer`'s own doc comment both still
   described the shape as same-frame-only and (in the field comment's
   case) read-only, though write-through-pointer support had already
   landed in `5b26ac49`; both now describe the actual (cross-frame,
   read+write) state.

   No §9.10 shim retired (as expected -- `writeBackByValueClassArguments`
   protects whole-boxed-value uses, unrelated to this cross-frame
   write-through-pointer addition).

   Focused suites all green: ct.expressions 555/0 (5 failing as expected,
   pre-existing `@ShouldFail` characterizations, unchanged from before this
   slice), ct.structs 291/0, ct.arrays 346/0, ct.exceptions 130/0,
   interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0. The full
   `bin/ut --random` was left to the orchestrator per the usual long-suite
   handoff. Remaining follow-up: nested-class-struct-field pointer
   (`&c.inner.x`) cross-frame propagation remains open -- the other shape
   this task named and deferred as the larger pick; §9.10 shim retirement
   itself remains deferred until a slice addresses
   `writeBackByValueClassArguments`'s whole-value-use coverage.

   Progress 2026-07-15 (nested-class-struct-field pointer cross-frame
   follow-up): closes the other of the two deferred item-7 class-cell
   cross-frame gaps -- `&c.inner.x` (a scalar field of a non-union struct
   field of a plain class local) surviving a call into another function.
   Mirrors the class-array-field pointer's own cross-frame follow-up
   (`a6ae05f3`) exactly, combined with the struct-receiver nested-field
   pointer's own cross-frame follow-up's unmemoized-id merge reasoning
   (`mergeNestedStructFieldPointerVariableMaps`, since a nested `DotVarExp`
   receiver always takes `fieldSnapshotAllocationId`'s non-`VarExp`-receiver
   fresh-id fallback, unlike the scalar/array class-field maps).

   Fixture `pointer.
   nestedClassStructFieldWriteThroughPointerInCalleeIsVisibleToCaller.
   {Ctfe,Interpreter,SystemLinker,LLVMJit}` in `tests/ut/backends/runner/
   ct/expressions.d`, mirroring `pointer.
   classArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller`'s shape one
   field-nesting level over: `struct Inner { int x; }`, `class C { Inner
   inner; }`, `c.inner.x = one();`, `int* p = &c.inner.x;`, a `put(int* p,
   int v) { *p = v; }` callee, `put(p, ninetyNine());`, then `return *p +
   c.inner.x;` asserting `198`. RED confirmed on Interpreter before any
   production change: `object.Exception: Unsupported interpreter assignment
   target.` at the `*p = v;` line inside `put` -- the callee's own child
   `Walker` duped `classCells` (sharing the cell's bytes) but never duped
   `nestedClassStructFieldPointerVariables`/`...OuterFieldIndices`/
   `...InnerFieldIndices`, so the callee's own
   `writeThroughNestedClassStructFieldPointer` reverse-lookup missed and the
   write fell through to the `fieldSnapshotAllocationIds` refusal guard.
   Green on Ctfe, SystemLinker, and LLVMJit throughout.

   Fix, all in `impl.d`: (1) a new `nestedClassStructFieldPointerWritebacks`
   flag map, declared alongside `nestedClassStructFieldPointerVariables`/
   `OuterFieldIndices`/`InnerFieldIndices`. (2) those four maps are now
   duped into every child `Walker` at the same 7 sites that already dupe
   `classFieldPointerVariables`/`FieldIndices`/`Writebacks`. (3) a new
   `mergeNestedClassStructFieldPointerVariableMaps`, a plain union merge (no
   `fieldAddressAllocations` conflict check, mirroring
   `mergeNestedStructFieldPointerVariableMaps`'s own reasoning for the
   struct-receiver sibling -- the id is never memoized per (variable, field
   path) for this one-level-nested shape). (4)
   `writeThroughNestedClassStructFieldPointer` now sets
   `nestedClassStructFieldPointerWritebacks[*variable] = true`
   unconditionally on every successful write (it already tolerated a
   missing `current`, same pre-existing cell-then-mirror discipline as the
   other class-field siblings before their own cross-frame follow-ups). (5)
   a new `writeBackNestedClassStructFieldPointerTargets`, wired into
   `writeBackFunctionState`/`writeBackMemberFunctionState` alongside the
   existing `writeBackClassFieldPointerTargets`/
   `writeBackClassArrayFieldPointerTargets` calls, refreshing the owning
   frame's boxed mirror via `classValueFromCell` once control returns. (6)
   `classValueFromCell` widened again to recurse one level into every
   (non-union) struct-typed field via a `NativeStruct` adopted over the
   field's own byte sub-range and `structValueFromCell`, mirroring
   `structValueFromCell`'s own nested-field recursion from the
   nested-struct-field follow-up.

   Stale doc comments corrected in the same diff: the
   `nestedClassStructFieldPointerVariables`/`OuterFieldIndices`/
   `InnerFieldIndices` field declaration and
   `writeThroughNestedClassStructFieldPointer`'s own doc comment both still
   described the shape as same-frame-only, though this slice makes it
   cross-frame; both now describe the actual state.

   No §9.10 shim retired (as expected -- `writeBackByValueClassArguments`
   protects whole-boxed-value uses, unrelated to this cross-frame
   write-through-pointer addition). This closes the item-7 class-aggregate
   cross-frame story (single-field, array-field, and nested-struct-field
   class pointers all now cross-frame); the remaining big item-7 follow-up
   is §9.10 `writeBackByValueClassArguments` retirement, which needs
   whole-value class-reference handling, a separately-scoped slice.

   Focused suites all green: ct.expressions 559/0 (5 failing as expected,
   pre-existing `@ShouldFail` characterizations, unchanged from before this
   slice), ct.structs 291/0, ct.arrays 346/0, ct.exceptions 130/0,
   interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0. The full
   `bin/ut --random` was left to the orchestrator per the usual long-suite
   handoff.

   Progress 2026-07-15 (union write-through-one-member visible through
   another): probed whether `promoteStructCell`'s union guard (2026-07-14,
   Finding 6 -- a union local never gets a `structCells` entry, staying on
   the boxed `Value.Struct` path) leaves a real `SystemLinker` divergence,
   as item 7's introduction names unions among the cases boxing "cannot
   pass at any speed." It does, but NOT through the pointer/cell-promotion
   path the guard protects -- a plain, address-free `U u; u.i = x;`
   already diverges, because `Value.Struct` stores each member in its own
   independent `Field[]` slot (`withStructField`/`structFieldAt`, keyed by
   declaration index): writing `u.i` never touches `u.f`'s own slot, while
   real D's `union` overlaps every member on the same bytes. RED confirmed
   on Interpreter before any production change, with the exact scenario
   value.md's task brief suggested: `union U { int i; float f; }`, `u.i =
   1065353216;` (a runtime local, not a literal, per `ai/mistakes.md`),
   `assert(u.f == 1.0f);` -- `object.Exception: nan != 1` (`u.f`'s own
   independent `float.init` slot, untouched by the `u.i` write). Green on
   `SystemLinker` throughout. A second, related divergence was also found
   and deliberately left OUT of this slice's fix (see below).

   Fix, in `impl.d`: a new `withUnionFieldWrite`, called only from
   `writeLocation`'s `DotVarExp` write arm when `dot.e1`'s resolved
   `TypeStruct.sym.isUnionDeclaration` is non-null (every other struct
   write is completely unchanged, so no existing non-union test path is
   touched). It writes the assigned field's raw bytes into a transient
   `ubyte[]` buffer sized to `layout.typeByteSize(unionType)` via the
   existing `native_scalar.writeScalar`, then re-derives every OTHER
   native-scalar sibling field's boxed value by `native_scalar.readScalar`
   reinterpreting those same bytes -- the identical byte-level machinery
   `NativeStruct` cells already use elsewhere (`writeStructCellScalarFields`
   et al.), but as a one-shot scratch buffer rather than a persisted cell.
   This deliberately does NOT touch `promoteStructCell`, its guard, or any
   pointer/cross-frame aliasing map: the address-taken (`&u.i`) case named
   in the task brief stays exactly as guarded before this slice, on the
   boxed fallback. A non-scalar sibling member (aggregate/array/class) is
   left on its own prior boxed value, matching `writeStructCellScalarFields`'s
   identical scalar-only scope; value.md already names a union member that
   is itself an aggregate as a separately open case.

   New fixture `union.writeThroughOneMemberIsVisibleThroughAnother.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/structs.d`
   -- the first union coverage in that file (previously none at all, per
   the 2026-07-14 note). Scoped to the `Interpreter`/`SystemLinker` oracle
   pair only, matching this slice's brief; `Ctfe`/`Bytecode`/`LLVMJit`
   union support is untested and out of scope here.

   No §9.10 shim retired -- unrelated to this write-through fix.

   Second divergence found, NOT fixed this slice: `U u;` (no write at
   all) already disagrees too -- `SystemLinker` zero-initializes the
   union's WHOLE block from its FIRST declared member's own default value
   (verified with a compiled probe: a union with `float` declared first
   reports its `int` sibling as the NaN bit pattern, not `0`), while the
   interpreter's `structDefaultValue` (`frontend/dmd/values.d`, shared
   with the `Ctfe` backend's module graph, NOT interpreter-only) computes
   each field's boxed default independently via `defaultValue(field.type)`
   -- `int.init == 0`, `float.init == NaN` -- so an untouched union field
   reads its own type's default, not the first member's reinterpreted
   bytes. Not fixed here because, unlike the write-through case above,
   there is no single call site to patch: `defaultValue`/`structDefaultValue`
   is called from roughly twenty sites across `impl.d` for every kind of
   default (locals, struct-literal missing fields, function returns,
   parameters), and `structDefaultValue` itself lives in the frontend-
   shared `values.d`, not the interpreter backend, so union-reinterpret
   logic does not belong there without a broader design decision about
   where it belongs. Left as an open, precisely-described follow-up rather
   than forced into this surgical slice.

   Focused suites all green: ct.expressions 559/0 (5 failing as expected,
   pre-existing `@ShouldFail` characterizations, unchanged from before this
   slice), ct.structs 293/0 (291 + this slice's 2 new backend instances),
   ct.arrays 346/0, ct.exceptions 130/0, interpreter 218/0, bin.repl 228/0,
   evaluator.eval 71/0; also ran rt.cstdlib 89/0 and rt.dependency_image
   119/0 since both carry pre-existing union FFI fixtures (`pthread`
   `mutexattr`, extern(C) union return/out-param), unaffected by this
   change. The full `bin/ut --random` was left to the orchestrator per the
   usual long-suite handoff.

   Progress 2026-07-15 (address-taken scalar-only union field: `&u.i`
   promotes a native cell, `u.f = x` reaches it through the SAME
   machinery already landed for structs and classes): the previous
   union slice (above) deliberately left the address-taken case exactly
   as `promoteStructCell`'s guard had it -- boxed only -- since
   value.md's task brief names it as the still-open case. Probed
   whether that guard leaves a real `SystemLinker` divergence for
   `union U { int i; float f; } U u; int* p = &u.i; u.f = <bits>;
   assert(*p == <reinterpreted bits>);` (a runtime-seeded float local
   assigned to `u.f`, per `ai/mistakes.md`, not a literal). RED
   confirmed on Interpreter before any production change: `*p` reads
   the stale field-snapshot value taken at `&u.i` time (`0`, `int.init`)
   because `promoteStructFieldCell`'s call into `promoteStructCell`
   no-ops for a union receiver, so neither a `structCells` entry nor a
   `structFieldPointerVariables` reverse-lookup entry is ever created --
   `object.Exception: 0 != 1065353216`. Green on `SystemLinker`
   throughout.

   Read why the guard exists (2026-07-14, Finding 6, and `withUnion
   FieldWrite`'s own comment): `writeStructCellScalarFields` seeds/
   refreshes a cell by writing EVERY field's boxed value to its own
   (declaration-order) byte range with no union-vs-struct branch: for a
   union, every native-scalar field shares the SAME offset (`NativeStruct.
   allocate` sizes/offsets a union correctly already, reading DMD's own
   `VarDeclaration.offset` via `layout.fieldByteOffset` -- confirmed by
   inspection, no change needed there), so the LAST field written in
   declaration order always wins, silently discarding an earlier
   sibling's bytes. That clobber is only a BUG when the fields' boxed
   values disagree about the underlying bits. Traced both places a
   union's cell bytes actually get (re)seeded once a cell exists: (1)
   `withUnionFieldWrite` (2026-07-15, prior slice) always re-derives
   every OTHER native-scalar sibling from the SAME just-written value's
   own bytes before `writeLocation`/`writeCelledLocal` reaches
   `writeStructCellScalarFields` -- so by the time the overlay runs,
   every field already agrees bit-for-bit, and the declaration-order
   overwrite is provably a no-op (same bytes, written twice); (2) the
   very first seed, from an untouched union's boxed default value,
   where fields genuinely disagree (`int.init == 0`,
   `float.init == NaN`, computed independently) -- but this is the
   SAME already-tracked, deliberately-deferred divergence the prior
   slice's "second divergence" paragraph names (`structDefaultValue`
   zero-initializes each field independently instead of copying the
   first declared member's bits across the whole block), not a new bug
   this slice introduces, and no existing or new test reads an
   untouched union field through a promoted cell (this slice's fixture
   writes `u.f` before ever reading `*p`), so it cannot regress
   anything today.

   Fix, in `impl.d`'s `promoteStructCell`: replaced the blanket "decline
   every union" guard with a narrower one -- decline only when the union
   has at least one member that is NOT `native_scalar.isNativeScalarType`
   (an aggregate/array/class member sharing the same bytes, where
   `writeStructCellScalarFields`'s recursion into that member's own
   sub-fields has no such consistency guarantee, still correctly left as
   an open follow-up per the prior slice). A scalar-only union now gets a
   `structCells` entry exactly like a plain struct, and every downstream
   consumer already handled it correctly with NO further changes needed,
   by design of the earlier struct-phase slices: `NativeStruct.allocate`
   (correct overlapping offsets from DMD), `writeStructCellScalarFields`/
   `structValueFromCell` (already field-index-generic, no struct-specific
   assumption), `structFieldPointerCellValue` (reads the field-index's own
   byte range, reinterpreted as the POINTEE's type), and `withUnionField
   Write`'s caller chain (`writeLocation` -> `writeCelledLocal`, which
   already refreshes a `structCells` entry from any struct-typed value it
   is given). Confirmed the OTHER two `promoteStructCell` call sites
   (`promoteStructArrayFieldCell`, `promoteNestedStructFieldCell`) can
   never reach a scalar-only union in the first place -- both require the
   ADDRESSED field itself to be a static array or a (non-union) struct,
   which by definition means the union has a non-scalar member, so the
   guard's new all-scalar check already declines for them; no separate
   exclusion needed at those call sites.

   New fixture `union.addressTakenFieldSeesWriteThroughSiblingMember.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/structs.d`,
   immediately after the prior slice's union fixture. Scoped to the
   `Interpreter`/`SystemLinker` oracle pair only, matching this slice's
   brief.

   No §9.10 shim retired -- unrelated to this promotion-guard relaxation.

   Remaining follow-up, unchanged from the prior slice's "second
   divergence" paragraph and value.md's own task brief: (1) an untouched
   union's default-init still diverges from `SystemLinker`'s first-
   member-wins zero-init (independent per-field `defaultValue`,
   `structDefaultValue` lives in the frontend-shared `values.d`); (2) a
   union member that is itself an aggregate (nested struct/array/class)
   still declines cell promotion entirely, matching
   `writeStructCellScalarFields`'s identical scalar-only scope.

   Focused suites all green: ct.expressions 559/0 (5 failing as
   expected, unchanged), ct.structs 295/0 (293 + this slice's 2 new
   backend instances), ct.arrays 346/0, ct.exceptions 130/0, interpreter
   218/0, bin.repl 228/0, evaluator.eval 71/0; also ran rt.cstdlib 89/0
   and rt.dependency_image 119/0 (pre-existing union FFI fixtures,
   unaffected). The full `bin/ut --random` was left to the orchestrator
   per the usual long-suite handoff.

   Progress 2026-07-15 (non-scalar union member: a struct-typed union
   field write-through-write another member is visible, via the same
   `NativeStruct` composition already landed for structs): the prior
   two union slices (above) deliberately left a union with a NON-
   scalar member (a struct/static-array field sharing the same bytes)
   entirely on the boxed path -- `promoteStructCell`'s guard still
   declines cell PROMOTION for it, and `withUnionFieldWrite`'s sibling
   overlay only handled `native_scalar.isNativeScalarType` fields on
   both the written and sibling sides. Probed whether that gap is a
   real `SystemLinker` divergence with `struct P { int a; int b; }
   union U { P p; long l; }`, writing the SCALAR member (`u.l = bits`,
   a runtime-computed `long` from two mutable `int` locals, per
   `ai/mistakes.md`) and reading the STRUCT member's overlapping fields
   (`u.p.a`/`u.p.b`). RED confirmed on Interpreter before any
   production change: `object.Exception: assert(u.p.a == low &&
   (u.p.b == high))` failed -- `withUnionFieldWrite`'s sibling loop
   skipped `p` outright (`!isNativeScalarType(sibling.type)`), leaving
   `u.p`'s boxed value exactly as `U`'s independent-per-field default
   left it, never overlaid from `u.l`'s just-written bytes. Green on
   `SystemLinker` throughout. Also manually verified (transient probe
   fixture, run then discarded, not part of this commit) that the
   REVERSE direction -- writing `u.p.a`/`u.p.b` then reading `u.l` --
   hit a second, related gap: `withUnionFieldWrite`'s OWN early return
   (`!isNativeScalarType(fields[fieldIndex].type)`) skipped the entire
   overlay whenever the WRITTEN field itself was non-scalar, so even
   `l`'s native-scalar slot was left stale. Both directions are fixed by
   the same change below.

   This turned out to be surgical: `withUnionFieldWrite` already ran a
   transient (never persisted, never touching `structCells`) byte
   buffer to overlay scalar siblings; extending the WRITTEN side and
   the SIBLING side to also handle a (non-union) struct-typed field
   needed no new machinery, only reusing `promoteStructCell`'s own
   struct-cell composition: `NativeStruct.allocate(unionType)` in
   place of the bare `ubyte[]` scratch buffer (so `NativeStruct.
   field`/`structField` do the offset arithmetic instead of
   re-deriving it), `writeStructCellScalarFields` to seed a
   struct-typed WRITTEN field's own scalar sub-fields into the cell's
   shared bytes (the same recursive seed `promoteStructCell` itself
   uses), and `structValueFromCell` to re-derive a struct-typed
   SIBLING field's boxed value back out of those bytes (the same
   read-side mirror `structCells`' cross-frame write-back paths
   already use). A union member that is a dynamic array, class, static
   array, or nested union is still left on its own prior boxed value
   on both sides, matching `writeStructCellScalarFields`'s identical
   scope -- not this slice's target and not surgical to add here (no
   existing `writeStructCellScalarFields`/`structValueFromCell`
   counterpart handles those field kinds at all yet).

   Deliberately NOT touched: `promoteStructCell`'s guard itself, still
   declining cell PROMOTION (the `&u.<field>` address-taken/pointer
   path) for any union with a non-scalar member -- this slice's fix is
   entirely inside `withUnionFieldWrite`'s transient, address-free
   overlay, which never creates or consults a `structCells` entry, so
   the guard's own scope (and the pointer/cross-frame aliasing map it
   protects) is unaffected by this change, exactly as the prior union
   slices' own guard-preserving discipline.

   Fix, in `impl.d`'s `withUnionFieldWrite` only: replaced the bare
   `ubyte[]` scratch buffer with `NativeStruct.allocate(unionType)`;
   the written-field branch now checks EITHER `isNativeScalarType` (as
   before, `writeScalar` into `cell.field(fieldIndex)`) OR "a
   `TypeStruct` whose `sym.isUnionDeclaration` is null" (new,
   `writeStructCellScalarFields` into `cell.structField(fieldIndex)`);
   declines (returns `updated` unchanged) only when NEITHER holds. The
   sibling loop mirrors this: `isNativeScalarType` overlays via
   `readScalar(cell.field(siblingIndex))` as before; a (non-union)
   struct-typed sibling now overlays via `structValueFromCell(
   updated.structFieldAt(siblingIndex), cell.structField(siblingIndex))`;
   anything else is skipped exactly as before.

   New fixture `union.writeThroughScalarMemberIsVisibleThroughStructMember.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/structs.d`,
   immediately after the prior union fixtures. Scoped to the
   `Interpreter`/`SystemLinker` oracle pair only, matching the existing
   union fixtures' scope.

   No §9.10 shim retired -- unrelated to this union-write overlay
   widening.

   Remaining follow-up, unchanged from the prior slices and value.md's
   own task brief: (1) an untouched union's default-init still diverges
   from `SystemLinker`'s first-member-wins zero-init (independent
   per-field `defaultValue`, `structDefaultValue` lives in the
   frontend-shared `values.d`); (2) a union member that is a dynamic
   array, class, or static array (as opposed to a plain non-union
   struct, now handled) still has no write-through overlay on either
   side, matching the identical gap in `writeStructCellScalarFields`/
   `structValueFromCell` for those field kinds; (3) cell PROMOTION
   (`&u.<field>`) for a union with a non-scalar member is still
   declined entirely by `promoteStructCell`'s guard -- this slice only
   widened the address-free, non-persisted overlay path.

   Focused suites all green: ct.expressions 559/0 (5 failing as
   expected, unchanged), ct.structs 297/0 (295 + this slice's 2 new
   backend instances), ct.arrays 346/0, ct.exceptions 130/0, interpreter
   218/0, bin.repl 228/0, evaluator.eval 71/0; also ran rt.cstdlib 89/0
   and rt.dependency_image 119/0 (pre-existing union FFI fixtures,
   unaffected). The full `bin/ut --random` was left to the orchestrator
   per the usual long-suite handoff.

   Progress 2026-07-15 (pointer-identity memoization: `&s.inner.x`/
   `&c.inner.x` now stable across re-evaluation): closes the "full
   field-PATH generalization" gap several prior notes above named and
   deferred -- `fieldSnapshotAllocationId` only memoized an id per
   (receiver variable, field index) when `dot.e1` resolved directly to a
   `VarExp`; a one-level-nested receiver (`dot.e1` itself a `DotVarExp`)
   always took the non-`VarExp` fresh-id fallback, so `&s.inner.x` minted
   a brand-new identity on every evaluation, unlike real D's stable
   address. Checked first whether `fieldAddressAllocations` already
   covered this (per this slice's own brief): it does for the DIRECT
   field case (`&s.x`, `&c.x`) and for `&a[i]` (`arrayAllocations`, keyed
   by variable with the element offset carried separately in the pointer
   `Value`) -- both already pointer-equal across re-evaluation, confirmed
   with transient scratch probes (discarded, not part of this commit)
   before writing the real fixture. Only the nested-field shape diverged.

   Fixture `pointer.addressOfNestedStructFieldIsStableAcrossReEvaluation.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/
   expressions.d`, the nested sibling of the existing `pointer.
   addressOfStructFieldIsStableAcrossReEvaluation`: `struct Inner { int x;
   } struct S { Inner inner; } S s = S(Inner(seed())); int* p =
   &s.inner.x; assert(p is &s.inner.x);`. RED confirmed on Interpreter
   before any production change: `const(Pointer)([7], 1, 0) !is
   const(Pointer)([7], 3, 0)` -- two different allocation ids for the
   same field. Green on SystemLinker throughout.

   Fix, in `impl.d`'s `fieldSnapshotAllocationId` only: added a branch
   that recognises the one-level-nested shape (`dot.e1.isDotVarExp` whose
   own `e1` resolves to a plain `VarExp`) and memoizes its id per (root
   variable, outer field index, inner field index) in a new map,
   `nestedFieldAddressAllocations` -- the nested sibling of
   `fieldAddressAllocations`, shared between a struct and a class root
   variable the same way that map already is (a variable's static type
   never changes, so the two outer-field-index spaces never collide).
   The outer index dispatches on `receiverClassType(innerDot.e1)` exactly
   like the existing direct-field dispatch, so the SAME branch closes the
   gap for both `&s.inner.x` and `&c.inner.x` -- manually verified the
   class-nested shape too (transient probe, run then discarded, not part
   of this commit): `struct Inner { int x; } class C { Inner inner; }`,
   `&c.inner.x is &c.inner.x`, RED before the fix (fresh ids), green
   after, on Interpreter, matching SystemLinker throughout. `dropStructCell`/
   `dropClassCell` both also now clear `nestedFieldAddressAllocations
   [variable]` on a fresh rebind, mirroring their existing
   `fieldAddressAllocations.remove(variable)` call, so a loop or
   recursion re-declaring the same struct/class local still mints a
   genuinely fresh id after the rebind rather than reusing the stale one.

   Deliberately narrower than `fieldAddressAllocations` in one respect,
   by choice, not oversight: `nestedFieldAddressAllocations` is NOT
   duplicated into child-frame walkers and never merged back after a call
   returns, so it only memoizes within a single `Walker` frame. Chosen
   because no fixture (old or new) exercises comparing a nested-field
   pointer minted in one frame against one minted in a different frame
   for the same (variable, outer, inner) triple -- unlike the direct-field
   case's own recursion-rebind fixtures (Finding 3/4 above), which drove
   the cross-frame dup+merge treatment `fieldAddressAllocations` already
   has. Extending that same cross-frame treatment here would additionally
   require adding a conflict-guard to the existing `mergeNestedStruct
   FieldPointerVariableMaps`/`mergeNestedClassStructFieldPointerVariable
   Maps` (both currently a plain union merge, correct only because ids
   were never memoized -- their own doc comments say so) -- a second,
   compounding change with no fixture to drive or verify it. Left as a
   named follow-up rather than attempted speculatively.

   No `interpreter.md` §9.10 shim is retired by this slice: it only
   changes which allocation id a nested-field address-of returns, not any
   shim's own execution path.

   Focused suites all green: ct.expressions 561/0 (5 failing as expected,
   unchanged), ct.structs 297/0, ct.arrays 346/0, ct.exceptions 130/0,
   ct.control_flow 336/0, interpreter 218/0, bin.repl 228/0, evaluator.eval
   71/0. The full `bin/ut --random` was left to the orchestrator per the
   usual long-suite handoff. Remaining follow-up: cross-frame identity for
   `&s.inner.x`/`&c.inner.x` (comparing ids minted in different frames for
   the same nested field) is unproven, as is deeper nesting (2+ levels, in
   any shape) and full field-PATH generalization beyond one level.

   Progress 2026-07-15 (union default-init: an untouched sibling scalar now
   reads the first member's bits, not its own type's independent default):
   attempted the divergence the prior slices' own follow-up named --
   `union U { float f; int i; } U u;` -- `u.i` must read `float.init`'s NaN
   bit pattern (`0x7FC00000`), not `int.init` (`0`). The follow-up note
   pointed at `frontend/dmd/values.d`'s `structDefaultValue` (shared with
   `Ctfe`) as the culprit; traced the ACTUAL runtime path first rather than
   trusting that pointer, since a wrong shared-module change here is high
   blast radius. Confirmed by inspection (temporary debug instrumentation,
   run then discarded, not part of this commit): a local union declaration
   with no initializer never reaches `structDefaultValue` at all -- DMD
   lowers `U u;` to a `BlitExp` whose RHS is a `VarExp` over a
   `SymbolDeclaration` (the compiler's `U.init` symbol), which `impl.d`'s
   `runSymbolDeclarationVarExpression` resolves via DMD's OWN
   `TypeStruct.defaultInitLiteral`, then evaluates as a `StructLiteralExp`.
   DMD's own `defaultInitLiteral` for a union fills ONLY the first declared
   member's `elements` slot (confirmed: `[<float.init literal>, null]` for
   `U` above) -- every sibling slot is `null`. The actual bug is
   `impl.d`'s own `structLiteralValue`/`structLiteralDefaultFieldValue`:
   a `null` element unconditionally called `defaultValue(field.type)`,
   independently re-deriving the sibling's OWN type's default instead of
   reinterpreting the already-resolved first member's bits. So the real
   fix is entirely interpreter-local (`impl.d`), not in the frontend-shared
   `values.d` the follow-up note pointed at -- `structDefaultValue` is
   unreached for this case and was left untouched (confirmed by reverting
   an initial speculative `values.d` change once this was discovered: 0
   effect on the red fixture, so it was dropped per strict TDD -- no
   failing test drove it).

   Fixture `union.untouchedSiblingDefaultsFromFirstMemberBits.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/structs.d`,
   immediately before the prior union fixtures. RED confirmed on
   Interpreter before any production change: `0 != 2143289344`. Green on
   `SystemLinker` throughout. `Ctfe` deliberately omitted (omit-don't-pin):
   real DMD's own CTFE engine throws `reinterpretation through overlapped
   field 'i' is not allowed in CTFE` for this exact read -- confirmed via a
   temporary three-backend probe (`Ctfe`/`Interpreter`/`SystemLinker`, run
   then discarded) that this is DMD's own `dinterpret.d` diagnostic, not a
   quickbite message, so `Ctfe` diverges from `SystemLinker` here by a
   DIFFERENT mechanism than the interpreter's (an exception instead of a
   silently-wrong `0`) and is not this repo's to fix.

   Fix, in `impl.d` only: `structLiteralValue` now threads its own
   `fields` accumulator into `structLiteralDefaultFieldValue` (index 0's
   value is always already computed and appended by the time a later
   `null` sibling is processed, so no second pass is needed). New
   `unionSiblingDefaultFieldValue` returns `false` (leaving the caller's
   existing independent-`defaultValue` fallback unchanged) unless: the
   literal's `sd` is a union, `index != 0`, and BOTH the first member and
   the target sibling are `native_scalar.isNativeScalarType` -- the exact
   same scalar-only scope `withUnionFieldWrite` already established for
   the write-through gap. When it applies, it reuses that same slice's
   idiom exactly: `NativeStruct.allocate(unionType)`, `writeScalar` the
   first member's already-resolved value into `cell.field(0)`, `readScalar`
   the sibling back out of the same (zero-offset-overlapping) cell bytes --
   no new byte-reinterpretation machinery, the existing scalar<->bytes
   codec `writeScalar`/`readScalar` already used for the union write-through
   overlay.

   Deliberately unchanged, matching the identical scope this repo's other
   union slices already accepted: a union whose first member or targeted
   sibling is non-scalar (struct/array/class) still falls back to the
   independent per-field `defaultValue` -- the same open gap
   `writeStructCellScalarFields`/`withUnionFieldWrite` already have, not
   widened here.

   No §9.10 shim retired -- unrelated to this default-init fix.

   Focused suites all green: ct.expressions 561/0 (5 failing as expected,
   unchanged), ct.structs 299/0 (297 + this slice's 2 new backend
   instances), ct.arrays 346/0, ct.exceptions 130/0, ct.control_flow 336/0,
   ct.logic 204/0, ct.diagnostics 177/0, ct.integrals 81/0, ct.math 265/0,
   ct.cerealed 164/0 (1 failing as expected, unchanged), ct.imports 1/0,
   ct.pollution 3/0, interpreter 218/0, bin.repl 228/0, evaluator.eval
   71/0; also ran rt.cstdlib 89/0 and rt.dependency_image 119/0
   (pre-existing union FFI fixtures, unaffected). The full `bin/ut
   --random` was left to the orchestrator per the usual long-suite
   handoff.

   Remaining follow-up, unchanged from before: (1) a union member that is
   itself an aggregate (struct/array/class) still has no default-init
   reinterpret, matching the identical write-through gap; (2) `Ctfe`'s own
   divergence here (an exception, not a silent wrong value) is DMD's own
   CTFE engine behaviour and is out of this repo's scope to change.

   Progress 2026-07-16 (static-array union member: writing a scalar sibling
   is now visible through an overlapping static-array member's elements):
   probed the documented gap -- `union U { int[2] a; long l; } U u; u.l =
   bits; assert(u.a[0] == low && u.a[1] == high);` -- against the
   `Interpreter`/`SystemLinker` oracle pair. Confirmed a real divergence: RED
   on `Interpreter`, green on `SystemLinker`. `withUnionFieldWrite`'s sibling
   refresh loop had no branch for a static-array sibling at all, so `u.a`
   kept its stale prior boxed value after writing `u.l` (silently skipped,
   same as any other unhandled field kind).

   Fixture `union.writeThroughScalarMemberIsVisibleThroughArrayMember.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/structs.d`,
   immediately after the prior union fixtures. RED confirmed on `Interpreter`
   before any production change: `assert(u.a[0] == low && (u.a[1] == high))`
   failed. Green on `SystemLinker` throughout. `Ctfe` omitted: DMD's own
   CTFE reinterpretation-through-overlapped-field restriction applies here
   too (established by the prior default-init slice for the scalar case;
   not re-probed since this slice only touches the write-through side, which
   was already `Ctfe`-omitted for the analogous scalar/struct siblings).

   Fix, in `impl.d`'s `withUnionFieldWrite` only: added a
   `isStaticArrayType(sibling.type)` branch to the sibling loop, gated on the
   array's own element type being `native_scalar.isNativeScalarType` (scope
   explicitly limited to scalar-ELEMENT static arrays per the task brief).
   Reuses the exact composition machinery `writeStructCellScalarFields`/
   `structValueFromCell` already established for a struct's own
   static-array field: `cell.arrayField(siblingIndex)` views the transient
   `NativeStruct`'s shared bytes as a `NativeArray`, and each element is
   `readScalar`'d back into the sibling's boxed array value via
   `withArrayElement`. The WRITTEN side (assigning a whole static-array union
   member, e.g. `u.a = [x, y];`, then reading a scalar sibling back) is
   deliberately NOT widened: no fixture exercises it, so per strict TDD only
   the tested direction got production code; that direction still falls
   through the pre-existing `!writtenScalar && !writtenStruct` decline
   unchanged. `promoteStructCell`'s guard (cell PROMOTION / address-taken
   path) is untouched, exactly as the prior union slices' own
   guard-preserving discipline.

   No §9.10 shim retired -- unrelated to this union-write overlay widening.

   Focused suites all green: ct.expressions 561/0 (5 failing as expected,
   unchanged), ct.structs 301/0 (299 + this slice's 2 new backend
   instances), ct.arrays 346/0, ct.exceptions 130/0, interpreter 218/0,
   bin.repl 228/0, evaluator.eval 71/0; also ran rt.dependency_image 119/0
   and rt.cstdlib 89/0 (pre-existing union FFI fixtures, unaffected). The
   full `bin/ut --random` was left to the orchestrator per the usual
   long-suite handoff.

   Remaining follow-up: (1) the WRITTEN-side static-array union member
   (`u.a = [...]` then reading a scalar sibling) is still unwidened, matching
   the note above; (2) a union member that is a dynamic array, class, or
   static array of non-scalar elements still has no write-through overlay on
   either side; (3) default-init (`unionSiblingDefaultFieldValue`) still
   falls back to independent `defaultValue` for any aggregate (struct/array/
   class) first member or sibling, unchanged from the prior slice's own
   follow-up; (4) cell PROMOTION (`&u.<field>`) for a union with a
   non-scalar member is still declined entirely by `promoteStructCell`'s
   guard.

   Progress 2026-07-15 (class reference identity, decomposition item 1's
   aggregate-composition follow-up: direct read of an aliased class local's
   scalar-element static-array field): closes the specific gap the recon note
   named -- `classCellFieldValue`, the DIRECT (non-pointer) class-field read's
   authoritative-cell dispatcher, consulted the shared `classCells` cell ONLY
   for a `native_scalar.isNativeScalarType` field; a static-array field (or a
   struct-typed field) still fell back to the boxed `locals` mirror, which can
   be stale when a DIFFERENT alias mutated that field's bytes in the shared
   cell. Took the smallest of the two named candidates: a static-array field
   (a struct-typed field is left for a follow-up slice).

   Fixture `class.aliasedVariableArrayFieldWriteIsVisibleThroughOriginal.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d`,
   immediately after decomposition item 1's own scalar-field fixture: `class
   C { int[2] arr; } C c = new C(); C c2 = c; c2.arr[0] = ninetyNine();
   assert(c.arr[0] == 99);`. RED confirmed on Interpreter before any
   production change: `0 != 99` -- `c2.arr[0] = 99` already reaches the
   shared cell (the write side's `writeClassCellScalarFields` already widens
   every scalar-element static-array field, decomposition item 4, landed
   earlier), but reading `c.arr[0]` back through the ORIGINAL alias fell
   through `classCellFieldValue`'s scalar-only gate to the stale independent
   boxed copy. Green on SystemLinker throughout.

   Fix, in `impl.d`'s `classCellFieldValue` only: added an `isStaticArrayType`
   branch alongside the existing scalar branch, gated (like every prior
   aggregate-composition slice) on the array's own element type being
   `native_scalar.isNativeScalarType`. Reuses the exact composition primitive
   `classArrayFieldPointerCellValue` (pointer-deref read side) and
   `writeClassCellScalarFields` (write side) already use:
   `NativeArray.adopt(cell.subRange(offset, size), elementType,
   staticArrayLength(...))`, then `readScalar` each element back via
   `withArrayElement` -- no new byte-reinterpretation machinery. The
   function's signature grew a `target` parameter (the caller's own
   already-computed boxed receiver `Value`, `runDotVarExpression`'s `target`)
   so the array branch has a starting shape (`.isArray`/`.length`) to
   overwrite element-by-element, mirroring `structValueFromCell`'s identical
   use of its own `current` parameter for the analogous struct-cell case; the
   scalar branch's own behaviour and the caller's post-`false` boxed fallback
   (`target.classFieldAt(fieldIndex)`) are both unchanged.

   No §9.10 shim retired: `writeBackByValueClassArguments` still protects
   whole-boxed-value uses, untouched by this direct-read widening, matching
   every prior aggregate-composition slice. This narrows the recon's own
   decomposition item 1 gap by one shape (scalar-element static-array field);
   the struct-typed-field shape the recon also named is left for a follow-up
   slice, together with a dynamic-array or class-typed field (neither of
   which any class-phase slice has widened on either the read or write side
   yet).

   Focused suites all green: ct.expressions 563/0 (5 failing as expected,
   unchanged), ct.structs 301/0, ct.arrays 346/0, ct.exceptions 130/0,
   ct.control_flow 336/0, interpreter 218/0, bin.repl 228/0, evaluator.eval
   71/0, rt.dependency_image 119/0. The full `bin/ut --random` was left to
   the orchestrator per the usual long-suite handoff.

   Remaining follow-up: (1) a struct-typed class field, read through an
   aliased class local, is still unwidened in `classCellFieldValue` -- the
   other shape the recon named; (2) a dynamic-array or class-typed class
   field has no widening on either the read or write side; (3) shim
   retirement itself remains deferred until a slice addresses
   `writeBackByValueClassArguments`'s whole-value-use coverage.

   Progress 2026-07-15 (class reference identity, decomposition item 1's
   aggregate-composition follow-up, struct shape: direct read of an
   aliased class local's struct-typed field): closes the symmetric gap
   this file's own prior entry named -- `classCellFieldValue`, the DIRECT
   (non-pointer) class-field read's authoritative-cell dispatcher, had a
   scalar branch and a scalar-element-static-array branch but no branch
   for a (non-union) struct-typed field, so that shape still fell back to
   the boxed `locals` mirror, which can be stale when a DIFFERENT alias
   mutated the field's bytes in the shared `classCells` cell.

   Fixture `class.aliasedVariableStructFieldWriteIsVisibleThroughOriginal.
   {Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/
   expressions.d`, immediately after decomposition item 1's own
   scalar-element-static-array fixture: `struct Inner { int x; } class C {
   Inner inner; } C c = new C(); C c2 = c; c2.inner.x = ninetyNine();
   assert(c.inner.x == 99);`. RED confirmed on Interpreter before any
   production change: `0 != 99` -- `c2.inner.x = 99` already reaches the
   shared cell (the write side's `writeClassCellScalarFields` already
   recurses one level into a struct-typed field), but reading `c.inner.x`
   back through the ORIGINAL alias fell through `classCellFieldValue`'s
   scalar/array-only gate to the stale independent boxed copy. Green on
   SystemLinker throughout.

   Fix, in `impl.d`'s `classCellFieldValue` only: added a struct branch
   alongside the existing scalar and static-array branches, gated on the
   field's type being a (non-union) `TypeStruct` and the caller's
   already-computed boxed field value (`target.classFieldAt(fieldIndex)`)
   actually being a struct value. Reuses the exact composition primitives
   `writeClassCellScalarFields`'s own struct recursion and
   `nestedClassStructFieldPointerCellValue` already use for a
   `classCells` entry's nested struct field -- `NativeStruct.adopt(cell.
   subRange(offset, size), nestedStructType)`, since a `classCells` entry
   is a plain `NativeBlock` with no `NativeStruct` wrapper of its own --
   and then this file's own struct-receiver read-back, `structValueFromCell`,
   to overlay every one of the nested struct's own scalar/array/struct
   fields onto the boxed field value. No new byte-reinterpretation
   machinery.

   No §9.10 shim retired: `writeBackByValueClassArguments` still protects
   whole-boxed-value uses, untouched by this direct-read widening,
   matching every prior aggregate-composition slice.

   Focused suites all green (run together): ct.expressions, ct.structs,
   ct.arrays, ct.exceptions, ct.control_flow, interpreter, bin.repl,
   evaluator.eval, rt.dependency_image -- 2314 run, 0 failed, 5/5 failing
   as expected (the same pre-existing ct.expressions failures, unchanged
   count; ct.expressions itself grew by this slice's own 2 new backend
   instances). The full `bin/ut --random` was left to the orchestrator per
   the usual long-suite handoff.

   Remaining follow-up: (1) a dynamic-array or class-typed class field
   still has no widening on either the read or write side; (2) whole-value
   cell reads (reading an entire class object's fields back from its
   `classCells` entry in one pass, rather than one `DotVarExp` field at a
   time) remain unaddressed, which is what would let a future slice retire
   `writeBackByValueClassArguments`; (3) `Ctfe` is not affected by this
   slice (class objects are heap-allocated reference types outside CTFE's
   own reach in this codebase, matching every prior class-phase slice's
   omission).

Progress 2026-07-15 (cross-frame nested-field pointer-identity follow-up:
`&s.inner.x`/`&c.inner.x` now stable across a nested-function-closure
call, not just within one `Walker` frame): closes the gap `54d0bb99`'s own
progress note (immediately above the class-phase entries in this log)
explicitly deferred -- `nestedFieldAddressAllocations` memoized an id per
(root variable, outer field index, inner field index) but was deliberately
NOT duplicated into child-frame walkers nor merged back after a call
returns, so any frame OTHER than the one that first evaluated `&s.inner.x`
saw an empty map and always minted a fresh id, even when no rebind of the
receiver had happened at all.

Found a real, cleanly reachable divergence via a nested function closing
over an enclosing struct local (no rebind, no recursion needed): a nested
function shares its enclosing frame's stack storage in real D, so
`&s.inner.x` taken from inside a nested function that merely reads the
SAME, never-rebound `s` must compare equal to the enclosing frame's own
`&s.inner.x` -- but since `nestedFieldAddressAllocations` was per-frame
only, the nested function's own (empty) copy always minted a new id.

Fixture `pointer.addressOfNestedStructFieldIsStableAcrossNestedFunctionCall.
{Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d`,
immediately after `pointer.addressOfNestedStructFieldIsStableAcrossReEvaluation`
(the same-frame sibling `54d0bb99` added): `struct Inner { int x; } struct
S { Inner inner; } S s = S(Inner(seed())); int* p = &s.inner.x; int* q; void
capture() { q = &s.inner.x; } capture(); return p is q;`, asserted true.
RED confirmed on Interpreter before any production change: `false != true`
-- `capture()`'s own frame minted a fresh id for `q` instead of reusing
`p`'s. Green on SystemLinker throughout. `Ctfe`/`Bytecode`/`LLVMJit`
omitted, matching the same-frame sibling's own omit-don't-pin convention
(unconfirmed there).

Fix, in `impl.d`, mirroring `fieldAddressAllocations`'s own cross-frame
treatment exactly (no new plumbing shape invented): (1)
`nestedFieldAddressAllocations` is now duplicated (`.dup`) into every
child `Walker` at the same 8 call sites `fieldAddressAllocations` already
is. (2) A new `mergeNestedFieldAddressAllocations`, the nested-field
sibling of the existing `mergeFieldAddressAllocations`, with the identical
"this frame's own entry wins" rule one key level deeper (root variable,
outer index, inner index); called at the same 5 sites
`mergeFieldAddressAllocations` already is. (3) The reverse-lookup merges,
`mergeNestedStructFieldPointerVariableMaps`/
`mergeNestedClassStructFieldPointerVariableMaps`, gained the identical
symmetric conflict-guard `mergeStructFieldPointerVariableMaps`/
`mergeClassFieldPointerVariableMaps` already have against
`fieldAddressAllocations` -- now checking `nestedFieldAddressAllocations`
instead, since an id in these reverse maps is no longer guaranteed
unique-per-triple the moment the forward memo is duped and can be
independently re-merged. Verified this guard does not fire for any
existing green fixture (it is symmetric hardening the same way the
scalar-field guard's own comment already documents -- no fixture directly
exercises the conflict branch). `dropStructCell`/`dropClassCell` already
cleared `nestedFieldAddressAllocations[variable]` on a fresh rebind
(`54d0bb99`) and already cleared the matching reverse-map entries (an
earlier slice), so a loop or recursion re-declaring the same struct/class
local still mints a genuinely fresh id after the rebind rather than
resurrecting the stale one -- traced this explicitly against the existing
`pointer.recursiveStructFieldPointerPassedAcrossRebindDereferencesOuterValue`-
style recursion-rebind shape for the nested-field case (not committed as a
separate fixture: dropStructCell's existing per-variable-key removal of
the WHOLE `nestedFieldAddressAllocations[variable]` submap already covers
it, and no new production branch was needed to make that shape work).

Updated the three stale doc comments this change falsifies: the
`nestedFieldAddressAllocations` field's own comment (used to say
"deliberately NOT duplicated ... never merged back"),
`fieldSnapshotAllocationId`'s reference to that field's "narrower,
same-frame-only scope", and the two reverse-map merge functions' own
"unmemoized-id, plain union merge is safe" comments.

No `interpreter.md` §9.10 shim retired -- unrelated to this pointer-
identity cross-frame widening, matching `54d0bb99`'s own note.

Focused suites all green: ct.expressions 567/0 (5 failing as expected,
unchanged; grew by this slice's own 2 new backend instances), ct.structs
301/0, ct.arrays 346/0, ct.exceptions 130/0, ct.control_flow 336/0,
interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0. The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Remaining follow-up: (1) a `ref` struct/class parameter is bound in this
interpreter as a boxed VALUE COPY plus an end-of-call write-back
(`writeBackRefArguments`), not live shared storage during the call itself
-- so `&s.inner.x` taken from INSIDE a function receiving `s` by `ref`
still mints an entirely independent id (keyed off the callee's own
parameter `VarDeclaration`, disjoint from the caller's local's
`VarDeclaration`) and would NOT compare equal to the caller's own
`&s.inner.x`, a real divergence from SystemLinker's true address aliasing.
This is a pre-existing gap in how `ref` parameters are modeled generally
(the identical divergence already exists for the DIRECT-field case,
`fieldAddressAllocations`, not something this slice's map introduced or
widened), well beyond a "dup + conflict-guard" surgical fix -- modeling
`ref`-parameter identity would need the callee's parameter to alias the
caller's own cell/id rather than binding a fresh copy, a materially larger
change left out of scope here. (2) Two-or-more-level field nesting (e.g.
`&s.a.b.c`) still has no memoization at all (falls to the fresh-id
fallback), unchanged from `54d0bb99`'s own "full field-PATH
generalization" gap.

Progress 2026-07-16 (union write-through: assigning a WHOLE static-array
member is now visible through an overlapping scalar sibling -- the
WRITTEN-side counterpart of the prior static-array slice): probed the
gap fa6b5e12's own follow-up flagged as unwidened -- `union U { int[2] a;
long l; } U u; u.a = [low, high]; assert(u.l == combined);` -- against the
`Interpreter`/`SystemLinker` oracle pair. Confirmed a real divergence: RED
on `Interpreter`, green on `SystemLinker`. `withUnionFieldWrite` only
handled a scalar-or-struct WRITTEN member; a whole static-array WRITTEN
member fell through its `!writtenScalar && !writtenStruct` decline
entirely, so `u.l` stayed on its stale prior value instead of picking up
`u.a`'s just-written bytes.

Fixture `union.writeThroughArrayMemberIsVisibleThroughScalarMember.
{Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/structs.d`,
immediately after `writeThroughScalarMemberIsVisibleThroughArrayMember`
(the read-side sibling `fa6b5e12` added). RED confirmed on `Interpreter`
before any production change: `0 != 55834574855`. Green on `SystemLinker`
throughout. `Ctfe` omitted, matching the established convention for this
whole fixture family (DMD's own CTFE reinterpretation-through-overlapped-
field restriction; not re-probed since this slice only touches the
WRITTEN side of the same overlay machinery already `Ctfe`-omitted for
every sibling direction).

Fix, in `impl.d`'s `withUnionFieldWrite` only: added a third `writtenArray`
case (gated on the WRITTEN field being a static array whose own element
type is `native_scalar.isNativeScalarType`, scope-matched to the read-side
slice) alongside the existing scalar/struct branches. Reuses the exact
`NativeStruct.arrayField` view `writeStructCellScalarFields`'s own
static-array branch already established: `writeScalar`s each of the
just-written array value's own elements into the transient cell's shared
bytes via `cell.arrayField(fieldIndex).element(elementIndex)`, before the
existing (unchanged) sibling refresh loop overlays every other member. No
new byte-reinterpretation machinery; `promoteStructCell`'s guard is
untouched.

No `interpreter.md` §9.10 shim retired -- unrelated to this union-write
overlay widening.

Focused suites all green (run together): ct.expressions, ct.structs,
ct.arrays, ct.exceptions, interpreter, bin.repl, evaluator.eval,
rt.dependency_image, rt.cstdlib -- 2071 run, 0 failed, 5/5 failing as
expected (the same pre-existing ct.expressions failures, unchanged count;
ct.structs itself grew by this slice's own 2 new backend instances). The
full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Remaining follow-up: (1) a union member that is a dynamic array, class,
static array of non-scalar elements, or nested union still has no
write-through overlay on either side (written or sibling), unchanged from
the prior slice's own follow-up; (2) default-init
(`unionSiblingDefaultFieldValue`) still falls back to independent
`defaultValue` for any aggregate (struct/array/class) first member or
sibling; (3) cell PROMOTION (`&u.<field>`) for a union with a non-scalar
member is still declined entirely by `promoteStructCell`'s guard.

Progress 2026-07-16 (union default-init, aggregate-first-member follow-up:
an untouched sibling now reads through a STRUCT first member's default
bytes, not just a scalar one): probed the gap this file's own note (2)
above flagged -- `struct P { float x; } union U { P p; int i; } U u;
assert(u.i == 0x7FC00000);` -- against the `Interpreter`/`SystemLinker`
oracle pair. Confirmed a real divergence: RED on `Interpreter`, green on
`SystemLinker`. `unionSiblingDefaultFieldValue` required BOTH the first
member and the target sibling to be `native_scalar.isNativeScalarType`, so
a struct first member (`P p`) declined entirely and `u.i` fell back to
`int.init` (`0`) instead of reinterpreting `P.init`'s NaN bits
(`0x7FC00000`).

Fixture `union.untouchedSiblingDefaultsFromStructFirstMemberBits.
{Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/structs.d`,
appended after the existing union fixtures. RED confirmed on `Interpreter`
before any production change: `0 != 2143289344`. Green on `SystemLinker`
throughout. `Ctfe` omitted (omit-don't-pin): re-probed rather than assumed
-- real DMD's own CTFE engine throws the identical `reinterpretation
through overlapped field 'i' is not allowed in CTFE` diagnostic as the
scalar-first-member sibling fixture.

Fix, in `impl.d`'s `unionSiblingDefaultFieldValue` only: the first-member
gate now accepts EITHER `isNativeScalarType` (unchanged) OR a plain
(non-union) struct type; the sibling itself is still required to be
`isNativeScalarType` (scalar leaves only, no widening on that side). When
the first member is a struct, reuses `withUnionFieldWrite`'s own
`writeStructCellScalarFields` idiom exactly -- `cell.structField(0)` seeds
the transient `NativeStruct`'s shared bytes from the first member's
already-resolved struct value (`fieldsSoFar[0]`), recursing through nested
scalar/scalar-element-array/struct sub-fields exactly as that helper
already does -- before `readScalar` reads the sibling back out of the same
overlapping bytes. No new byte-reinterpretation machinery.

No `interpreter.md` §9.10 shim retired -- unrelated to this default-init
widening.

Focused suites all green: ct.expressions 567/0 (5 failing as expected,
unchanged), ct.structs 305/0 (303 + this slice's own 2 new backend
instances), ct.arrays 346/0, ct.exceptions 130/0, ct.math 265/0,
interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0,
rt.dependency_image 119/0, rt.cstdlib 89/0. The full `bin/ut --random` was
left to the orchestrator per the usual long-suite handoff.

Remaining follow-up: (1) a static-array or class first member still falls
back to independent `defaultValue` for its siblings, unchanged; (2) an
aggregate (struct/array/class) SIBLING being read through a scalar or
struct first member is likewise still unwidened -- this slice only widened
the first-member side, matching the scalar sibling scope
`withUnionFieldWrite`'s WRITTEN-struct branch already established; (3)
cell PROMOTION (`&u.<field>`) for a union with a non-scalar member is
still declined entirely by `promoteStructCell`'s guard, unchanged.

Progress 2026-07-16 (array-element/nested-field composition: `&a[i].inner.x`
now gets a native cell): probed the untried COMPOSITION the array-element
(`ec5c794a`) and nested-struct-field (`39881488`) slices each left named --
a nested struct field OF an array-of-struct element -- against the
`Interpreter`/`SystemLinker` oracle pair. Confirmed a real divergence: RED
on `Interpreter`, green on `SystemLinker`.

Fixture `pointer.
arrayElementNestedStructFieldWrittenDirectlyIsVisibleThroughEarlierPointer.
{Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d`,
immediately after `pointer.
structArrayElementWrittenDirectlyIsVisibleThroughEarlierPointer`: `struct
Inner { int x; } struct S { Inner inner; } S[] a = [S(Inner(one()))]; int*
p = &a[0].inner.x; a[0].inner.x = ninetyNine(); assert(*p == 99);`. RED
confirmed on `Interpreter` before any production change: `1 != 99` (the
frozen pre-write snapshot `addressOfExpression` took at address-of time,
not an exception -- the pointer's deref-read always missed every cell-value
check and fell to `pointer.pointerTarget`). Green on `SystemLinker`
throughout. `Ctfe`/`Bytecode`/`LLVMJit` omitted per the omit-don't-pin
convention (unconfirmed there).

Root cause: `addressOfExpression`'s `DotVarExp` branch only called
`promoteNestedStructFieldCell`, which requires the nested field's own
receiver (`innerDot.e1`) to be a plain `VarExp` -- for `&a[0].inner.x`,
`innerDot.e1` is an `IndexExp` (`a[0]`), so that function (and
`promoteStructFieldCell`) both no-op, no cell ever backed this pointer.

This composition turned out to be surgical, not a new mechanism, because
the byte-layout composition was already built: `NativeArray.structElement`
returns a `NativeStruct` view, and `NativeStruct.structField` composes on
top of it -- the exact chain `promoteArrayCell`'s own struct-element seeding
and `writeStructCellScalarFields`'s nested-field recursion already rely on
internally. Confirmed separately that the WRITE side already worked before
this slice: `a[0].inner.x = 99` bottoms out in `writeIndexLocation`'s plain
`VarExp` branch (`index.e1` is `a`, a bare local, not a `DotVarExp`), which
already calls `writeThroughArrayCell` unconditionally whenever `variable`
has a cell -- so once a cell exists, direct writes already keep it current;
only the DEREF-READ side needed new glue.

Fix, in `impl.d`: a new `promoteArrayNestedStructFieldCell(dot, id)`, the
array-element sibling of `promoteNestedStructFieldCell`, detects the
`a[i].inner.x` shape directly (mirroring that function's own direct-shape
detection, not a new memoized-path key -- this receiver shape already takes
`fieldSnapshotAllocationId`'s final fresh-id fallback, same pre-existing gap
as the non-array nested-field case), calls the EXISTING `promoteArrayCell`
to give the array variable its cell, and records `id` in four new reverse-
lookup maps (`arrayNestedStructFieldPointerVariables`/`...ElementIndices`/
`...OuterFieldIndices`/`...InnerFieldIndices`) -- one more map than the
non-array case, for the array index. A new `arrayNestedStructFieldPointer
CellValue`, the array-element sibling of `nestedStructFieldPointerCellValue`,
reads `cell.structElement(elementIndex).structField(outerIndex).
field(innerIndex)` -- composing the two pre-existing accessors -- and is
wired into both existing pointer-deref dispatch chains (`runPointerExpression`
and `pointerTargetValue`) right after `nestedStructFieldPointerCellValue`.
No change to `promoteArrayCell`, `writeStructCellScalarFields`,
`writeThroughArrayCell`, or any existing map/function -- purely additive.

No `interpreter.md` §9.10 shim retired -- unrelated to this composition
slice.

Scope, matching every prior FIRST slice in this same map family's own
history (`nestedStructFieldPointerVariables`'s cross-frame duping/merge/
writeback machinery was added in a LATER, separate commit, not its first):
same-frame only. No duping into child `Walker`s, no cross-frame writeback,
and no write-through-pointer direction (`*p = v` writing back into
`a[i].inner.x`) -- all left as follow-ups, not this slice's scope. No
cleanup of the new maps was added to `dropArrayCell` (the array-cell
sibling of `dropStructCell`'s stale-id cleanup) either; a stale pointer
surviving a recursive re-binding of the same array variable is an
unaddressed, untested gap here, matching `dropStructCell`'s own history of
that cleanup arriving in a later review round rather than the first slice.

Focused suites all green (run together): ct.expressions 569/0 (5 failing
as expected, unchanged, plus this slice's own 2 new backend instances),
ct.structs 305/0, ct.arrays 346/0, ct.exceptions 130/0, interpreter 218/0,
bin.repl 228/0, evaluator.eval 71/0 -- 1867 run, 0 failed, 5/5 failing as
expected. The full `bin/ut --random` was left to the orchestrator per the
usual long-suite handoff.

Remaining follow-up: (1) cross-frame propagation of this slice's own four
maps (passing `&a[i].inner.x` into another function); (2) the
write-through-pointer direction (`*p = v` writing back into
`a[0].inner.x`); (3) pointer-identity memoization (repeated `&a[i].inner.x`
evaluations do not share an id), unchanged, pre-existing gap shared with the
non-array nested-field case; (4) `dropArrayCell`'s stale-id cleanup for
this slice's own four maps; (5) deeper nesting (2+ levels) or a class
receiver/class-typed inner field composed with an array element, all out of
this narrow slice's scope.

Progress 2026-07-16 (struct static-array field, foreach-ref write-through:
`foreach (ref e; s.arr) e = ...;` now visible through an earlier
`&s.arr[0]`): probed a menu of distinct native-storage behaviours
(struct-static-array-field `foreach (ref e; ...)` mutation, a runtime-
variable array index for `&a[i]`, a by-value-returned struct's field
address-taken and written, `s.arr[i] += v`/`s.arr[i]++` compound ops
through a cell, a pointer threaded through two levels of function calls,
and a slice of a struct's static-array field mutated then read through an
earlier pointer) against the `Interpreter`/`SystemLinker` oracle pair.
Confirmed a real divergence for the `foreach`-ref shape (and its slice-
mutation sibling, the same root cause): RED on `Interpreter`, green on
`SystemLinker`. Every other probed shape already matched (compound ops,
cross-call pointer threading, by-value-return field address-taking, and
the runtime-variable index all passed on both backends already).

Root cause: dmd's own `foreach`-to-`for` rewrite (`statementsem.d`) lowers
`foreach (ref e; s.arr)` to `T[] __r = s.arr[]; ... ref T e = __r[__key];`
-- the write reaches `s` through a SLICE alias of the field
(`writeThroughSliceAlias`'s `hasFieldIndex` branch, added for exactly this
lowering shape), not through the direct `s.arr[i] = ...` assignment path
(`writeIndexLocation`) that already refreshes a promoted `structCells`
entry via `writeLocation`/`writeCelledLocal`. `writeThroughSliceAlias`'s
field-index branch only updated the boxed `locals[alias_.source]` mirror
and returned -- it never refreshed `alias_.source`'s `structCells` entry,
so a pointer taken before the loop (`&s.arr[0]`) kept answering with the
pre-loop byte snapshot instead of the loop's writes.

Fixture `pointer.
structStaticArrayFieldElementWrittenByForeachRefIsVisibleThroughEarlierPointer.
{Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d`,
immediately after `pointer.
structStaticArrayFieldElementWrittenDirectlyIsVisibleThroughEarlierPointer`
(the direct-write sibling): `struct S { int[3] arr; } S s; s.arr[0] =
one(); int* p = &s.arr[0]; foreach (ref e; s.arr) e = e + ninetyNine();
assert(*p == 1 + 99);`. RED confirmed on `Interpreter` before any
production change: `1 != 100`. Green on `SystemLinker` throughout.
`Ctfe`/`LLVMJit` omitted per the omit-don't-pin convention (unconfirmed
there) -- unlike the direct-write sibling fixture, not yet probed against
those two backends.

Fix, in `impl.d`'s `writeThroughSliceAlias` only: the `hasFieldIndex`
branch now calls the EXISTING `writeCelledLocal(alias_.source, ...)` with
the updated whole-struct value, instead of writing only `locals[alias_.
source]` and returning. This is the SAME whole-struct refresh a direct
`s.arr[i] = v` write already reaches (`writeIndexLocation` ->
`writeLocation`'s `VarExp` arm -> `writeCelledLocal`), which in turn calls
the existing `writeStructCellScalarFields` -- already widened to handle a
scalar-element static-array field -- to refresh the `structCells` entry's
bytes when one exists (a no-op otherwise). No new byte-reinterpretation
machinery, and no change to `writeCelledLocal`, `writeStructCellScalarFields`,
or `writeIndexLocation`. This also fixes the sibling slice-mutation shape
(`int[] sl = s.arr[]; sl[0] = v;`) probed alongside it, since both route
through this same branch; no separate fixture added for that shape
(same root cause, same fix, avoiding a near-duplicate test).

No `interpreter.md` §9.10 shim retired -- unrelated to this slice-alias
write-through widening.

Focused suites all green (run together): ct.expressions 571/0 (5 failing
as expected, unchanged, plus this slice's own 2 new backend instances),
ct.structs 305/0, ct.arrays 346/0, ct.exceptions 130/0, ct.control_flow
336/0, interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0 -- 2205 run,
0 failed, 5/5 failing as expected. The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Remaining follow-up: (1) `Ctfe`/`LLVMJit` behaviour for this fixture is
unconfirmed (never probed), unlike its direct-write sibling which already
covers all four backends; (2) a dynamic-array or class-typed field sliced
the same way (`c.arr[]`/a dynamic-array field's own `foreach (ref e;
...)`) is untried; (3) other slice-alias write-through shapes composed
with this one (e.g. a nested struct field's static-array field sliced via
`foreach`) are untried.

Progress 2026-07-16 (class-static-array-field follow-up, foreach-ref shape:
`foreach (ref e; c.arr) e = ...;` on a CLASS field now works at all, and is
visible through an earlier `&c.arr[0]`): probed a menu of distinct
native-storage behaviours (plain-array `foreach (ref e; a)` through
`&a[i]`, a class static-array field's `foreach (ref e; c.arr)`, whole-
struct reassignment coherence, nested `&s.inner.arr[i]`, a `static` local's
address-taken write, swapping two address-taken struct locals, and a
struct static-array field passed by `ref` to a callee) against the
`Interpreter`/`SystemLinker` oracle pair, following up on this file's own
note (2) above. Confirmed a real divergence for the class-field `foreach`-
ref shape: RED on `Interpreter` (an exception, not merely a wrong value),
green on `SystemLinker`. Every other probed shape already matched.

Root cause: `recordSliceAlias`'s `DotVarExp` branch (populated when dmd's
own `foreach`-to-`for` rewrite lowers `foreach (ref e; c.arr)` to `T[] __r
= c.arr[]; ...`) computed the field index via `structFieldIndex(dot)`
unconditionally. `structFieldIndex` requires `receiverStructType`, which is
null for a class receiver, so it threw `"Unsupported interpreter field
access."` immediately when recording the alias -- this shape was entirely
unsupported, not merely missing pointer-aliasing (unlike the struct
sibling, which had the write-through gap fixed a slice ago).

Fixture `pointer.
classStaticArrayFieldElementWrittenByForeachRefIsVisibleThroughEarlierPointer.
{Interpreter,SystemLinker}` in `tests/ut/backends/runner/ct/expressions.d`,
immediately after `pointer.
classStaticArrayFieldElementWrittenDirectlyIsVisibleThroughEarlierPointer`
(the direct-write sibling): `class C { int[3] arr; } C c = new C();
c.arr[0] = one(); int* p = &c.arr[0]; foreach (ref e; c.arr) e = e +
ninetyNine(); assert(*p == 1 + 99);`. RED confirmed on `Interpreter` before
any production change: `object.Exception ... "Unsupported interpreter
field access."` thrown from `structFieldIndex`. Green on `SystemLinker`
throughout. `Ctfe`/`LLVMJit` omitted per the omit-don't-pin convention
(unconfirmed there), matching the struct sibling fixture's own backend
set.

Fix, in `impl.d`: `recordSliceAlias`'s `DotVarExp` branch now dispatches on
the STATIC receiver type (`receiverClassType(dot.e1) !is null`, mirroring
`writeIndexLocation`'s own `DotVarExp` arm), computing the field index via
the EXISTING `classFieldIndex(dot)` instead of `structFieldIndex(dot)` for
a class receiver, and records the new `SliceAlias.isClassField` bool.
`writeThroughSliceAlias`'s `hasFieldIndex` branch then reads/writes the
field via `classFieldAt`/`withClassField` instead of `structFieldAt`/
`withStructField` when `isClassField` is set (`structFieldAt` throws
`"Expected struct."` for a `ClassObject` value, since `Value`'s struct and
class variants are disjoint `SumType` alternatives). No change to
`writeCelledLocal`: it already dispatches its own `structCells`/
`classCells` refresh on the VALUE's runtime kind (`isStruct`/
`isClassObject`), so passing it a `ClassObject`-valued whole-owner update
already refreshes a promoted `classCells` entry correctly, the same way it
already did for the struct case the prior slice fixed.

No `interpreter.md` §9.10 shim retired -- unrelated to this class/struct
dispatch widening.

Focused suites all green (run together): ct.expressions 573/0 (5 failing
as expected, unchanged, plus this slice's own 2 new backend instances),
ct.structs 305/0, ct.arrays 346/0, ct.exceptions 130/0, ct.control_flow
336/0, interpreter 218/0, bin.repl 228/0, evaluator.eval 71/0 -- 2207 run,
0 failed, 5/5 failing as expected. The full `bin/ut --random` was left to
the orchestrator per the usual long-suite handoff.

Remaining follow-up: (1) `Ctfe`/`LLVMJit` behaviour for this fixture is
unconfirmed (never probed), unlike its direct-write sibling which already
covers all four backends; (2) a dynamic-array field sliced the same way
(a dynamic-array field's own `foreach (ref e; ...)`) is still untried, for
both struct and class receivers; (3) other slice-alias write-through
shapes composed with this one (e.g. a nested struct or class field's
static-array field sliced via `foreach`) are untried; (4) the plain chained
slice-alias branch (`recordSliceAlias`'s final `VarExp` arm) never
propagates `hasFieldIndex`/`isClassField` at all -- unchanged, pre-existing
gap shared with the struct sibling slice, out of this narrow slice's scope.

Progress 2026-07-16 (`out` struct parameter field write no longer corrupts
the parameter to a bare int): probed a fresh menu of distinct
native-storage-adjacent behaviours (a 2D static array's `&m[i][j]`, a
`string` struct field's address-of/read coherence through a cell, an `out`
struct parameter, a `with (structInstance) { field = v; }` write's
coherence with an earlier pointer, and a struct static-array field's
element address taken then the whole field slice-filled) against the
`Interpreter`/`SystemLinker` oracle pair. The `with`-statement and
slice-fill-field probes already matched. The 2D static array and `string`
field probes are real divergences too (RED on `Interpreter`) but both need
a genuinely new mechanism -- flattening nested static arrays down to their
scalar leaf elements for pointer arithmetic, and a slice-valued struct-field
cell primitive, respectively -- not a surgical single-function fix, so
neither was picked. The `out` struct parameter probe was the first
divergence with a small, well-understood root cause and no new mechanism.

Root cause: dmd's own `semantic3.d` ("Merge in initialization of 'out'
parameters") synthesizes a zero-init statement for every `out` parameter of
a zero-init struct type and merges it as the FIRST statement of the
callee's own body: `BlitExp(VarExp(param), IntegerExp(0))`, with the
literal's own `.type` retyped to the struct type as a "memset" marker for
codegen (`dsymbolsem.d`'s own comment on this exact shape: "Must do same
check in interpreter"). `runDeclarationExpression` already special-cases
this identical shape for a plain LOCAL declaration (`S s = 0;` materializes
the struct's real default value instead of writing the literal through
naively) -- but the synthesized out-parameter statement is a bare top-level
assignment, never wrapped in a `DeclarationExp`, so it never reached that
check. It fell through `runAssignExpression`'s generic
`runExpression(assign.e2)` path instead, which evaluated the `IntegerExp`
as a scalar `Value(0)` and clobbered the parameter's boxed struct value
with a bare int. The following `s.x = one();` field write then threw
("Expected struct.") from `Value.withStructField`, which requires a
`Value.Struct` receiver -- an exception, not merely a wrong value.

Fixture `function.outStructParameterFieldWriteIsVisibleToCaller.
{Ctfe,Interpreter,SystemLinker,LLVMJit}` in
`tests/ut/backends/runner/ct/control_flow.d`, immediately after
`function.refSizeTParameter`: `struct S { int x; int y; } void makeS(out S
s) { s.x = one(); s.y = two(); } unittest { S s; makeS(s); assert(s.x ==
1); assert(s.y == 2); }`. RED confirmed on `Interpreter` before any
production change: `object.Exception ... "Expected struct."`. Green on
`Ctfe`, `SystemLinker`, and `LLVMJit` throughout. `Bytecode` omitted per
the "never pin an in-development backend's refusal, omit instead"
convention: it throws its own unrelated `"Unsupported assignment in
bytecode core: s = 0"` for this shape, a separate, actively-developed
backend's own gap, not a wrong value.

Fix, in `impl.d`'s `runAssignExpression` only: before the existing generic
`runExpression(assign.e2)` write, a new check detects the synthesized
zero-init shape (`assign.isBlitExp`, `blit.e2.isIntegerExp !is null`, and
`isStructType(assign.e1.type)`) with a plain `VarExp` target, and writes
the target variable's real `defaultValue(variable)` instead -- the exact
same fallback `runDeclarationExpression`'s own sibling check already uses
for a local declaration. No new byte-reinterpretation machinery, no new
map; reuses the existing `defaultValue`/`writeLocation` calls verbatim.
Every other `BlitExp`/`ConstructExp`/`AssignExp` shape (including a
zero-init static array, already handled solely by
`runDeclarationExpression`'s own pre-existing check) is unaffected: the new
check's three guards (`isBlitExp`, integer-literal RHS, struct-typed LHS)
all must hold, and only a plain-`VarExp` target takes the new branch at
all.

Focused suites all green (run together): ct.expressions, ct.structs,
ct.arrays, ct.exceptions, ct.control_flow, interpreter, bin.repl,
evaluator.eval -- 2211 run, 0 failed, 5/5 failing as expected (the same
pre-existing ct.expressions failures, unchanged count; ct.control_flow grew
by this slice's own 4 new backend instances). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Remaining follow-up: (1) the 2D static-array `&m[i][j]` divergence found
during this same probe (`symbolOffsetLocalValue`'s constant-folded
`SymOffExp` arm divides the raw byte offset by the IMMEDIATE element
type's size -- `int[2]` for `int[2][3]`, not the innermost scalar's -- so
`arrayPointerElements`' un-flattened top-level elements list resolves to
the wrong, non-scalar element entirely) is real but needs a genuine
flattening mechanism, not fixed here; (2) the `string`/dynamic-array
struct-field address-of/write coherence gap found in the same probe
(`promoteStructFieldCell`'s `isNativeScalarType(dot.type)` gate declines
any non-scalar field, matching every prior slice's own documented "dynamic
array field... is untried" follow-up) needs a slice-valued struct-field
cell primitive, not fixed here; (3) a NON-zero-init struct's synthesized
`out`-parameter initializer (a user-defined default constructor or a
non-all-zero field default) takes a different dmd-synthesized shape
(`ConstructExp`/a real call) entirely untried by this narrow fix, which
only recognises the `BlitExp`-with-`IntegerExp` zero-memset shape.

Progress 2026-07-16 (plain-local static-array pointer: a direct element
write after `&a[i]` was taken is now visible through the earlier pointer):
probed a fresh menu of distinct native-storage behaviours against the
`Interpreter`/`SystemLinker` oracle pair: a struct passed BY VALUE with a
callee write through `&param.field`, a `ref`-returning function used as an
assignment target, a non-zero default struct field initializer's cell
coherence, `a.length` growth not aliasing an earlier pointer, `a.ptr`
arithmetic writes visible through indexing, a union nested inside a
struct, pointer subtraction between two array-element pointers, recursive-
frame cell distinctness for an address-taken local, class-reference
reassignment leaving an earlier field pointer on the old object, and
in-place slice assignment (`a[] = b[];`) visible through an earlier
pointer for both dynamic and static array locals. Most already matched.
Three genuine divergences turned up (RED on `Interpreter`, green on
`SystemLinker`): recursive-frame cell distinctness (a single global
`scalarCells`/`VarDeclaration`-keyed cell shared across recursive
activations, not scoped per call frame -- a structural, non-surgical gap
in how every cell map in this file is keyed, out of scope for a single
fix); class-reference reassignment (an earlier `&c.field` pointer sees the
NEW object's field after `c = new C();` rebinds `c`, not the old object's
-- also a deeper identity-vs-variable-slot gap, not picked); and a plain
LOCAL static array's element pointer not observing a later direct write
(`int[3] a; a[0] = x; int* p = &a[0]; a[0] = y; assert(*p == y);` --
`*p` stayed `x`). The static-array-pointer divergence was the only one
with a small, well-understood, genuinely surgical root cause, so it was
picked (first surfaced via an `a[] = b[];` static-array-local slice-assign
probe, then narrowed to this simpler direct-write shape as the minimal
reproduction and the natural static-array sibling of the already-passing
dynamic-array fixture `pointer.
arrayElementWrittenDirectlyIsVisibleThroughEarlierPointer`).

Root cause: `promoteArrayCell` (the eager `arrayCells` promotion
`arrayPointer` calls when `&a[i]` is taken) guards on
`isDynamicArrayType(variable.type)`, so a plain LOCAL static array never
gets an `arrayCells` entry -- none of `runPointerExpression`'s `*CellValue`
checks (all keyed off promoted cells) can ever fire for it. Its pointer
value is still array-allocation-backed, though: `arrayPointer`/
`symbolOffsetLocalValue` both mint one via the existing `allocationId`
mechanism (the same one dynamic arrays use), and `arrayPointerVariable`
already resolves such a pointer back to its owning variable -- that
resolve-and-re-read exists and is already used by `readPointerElement` for
`p[i]` indexing through this same pointer kind, and by
`writeThroughArrayPointer` for a write through the pointer. But
`runPointerExpression`'s OWN dereference fallback, reached once every
`*CellValue` check declines, returned the raw `value.pointerTarget` --
the boxed element snapshot frozen at address-of time -- without ever
consulting `arrayPointerVariable`, so a later direct write to `a` (landing
in `locals[variable]`, the only place a static array's writes ever go)
was invisible through `*p`.

Fixture `pointer.
staticArrayLocalElementWrittenDirectlyIsVisibleThroughEarlierPointer.
{Ctfe,Interpreter,SystemLinker,LLVMJit}` in
`tests/ut/backends/runner/ct/expressions.d`, immediately after `pointer.
arrayElementWrittenDirectlyIsVisibleThroughEarlierPointer` (the dynamic-
array sibling): `int[3] a; a[0] = one(); int* p = &a[0]; a[0] =
ninetyNine(); assert(*p == 99);`. RED confirmed on `Interpreter` before
any production change: `1 != 99`, a wrong value, not an exception. Green
on `Ctfe`, `SystemLinker`, and `LLVMJit` throughout (all three probed and
confirmed passing before the fixture was written, unlike several prior
slices' unconfirmed-elsewhere fixtures).

Fix, in `impl.d`'s `runPointerExpression` only: the final dereference
fallback (reached when the pointer is not a native pointer, not a local
pointer, and none of the `*CellValue` checks fired) now calls the EXISTING
`readPointerElement(pointer.e1.type, value, 0)` instead of returning
`value.pointerTarget` directly. `readPointerElement` already re-reads
`arrayPointerVariable(pointer)` + `locals` fresh when the pointer resolves
to an array-allocation variable (fixing exactly this gap), and falls back
to `pointer.pointerIndex(0)` otherwise -- which is `pointerTarget`'s own
definition verbatim, so every other pointer kind (a `&s.field` struct-
field snapshot, a nested-field snapshot, etc.) behaves identically to
before. No new map, no new cell kind; reuses `readPointerElement` and
`arrayPointerVariable` verbatim, both pre-existing.

No `interpreter.md` §9.10 shim retired -- unrelated to this dereference-
fallback fix.

Focused suites all green (run together): ct.expressions, ct.structs,
ct.arrays, ct.exceptions, ct.control_flow, interpreter, bin.repl,
evaluator.eval -- 2215 run, 0 failed, 5/5 failing as expected (the same
pre-existing failures, unchanged count; ct.expressions grew by this
slice's own 4 new backend instances). The full `bin/ut --random` was left
to the orchestrator per the usual long-suite handoff.

Remaining follow-up: (1) recursive-frame cell distinctness (found in this
same probe) is a real divergence but needs every cell map in this file
re-keyed per activation frame instead of per `VarDeclaration`, a
structural change out of a single surgical fix's scope; (2) class-
reference reassignment not decoupling an earlier field pointer from the
old object (found in the same probe) is a real divergence too, needing an
object-identity-scoped cell rather than a variable-slot-scoped one, also
out of scope here; (3) the analogous in-place slice-assignment shape
(`a[] = b[];`) for a plain LOCAL static array was the probe that first
surfaced this bug and is very likely fixed by the same dereference-
fallback change (it shares the identical `runPointerExpression` read path)
but was not re-added as its own fixture, to keep this slice's fixture
count to the minimum needed to red/green the fix; (4) a struct- or
class-static-array-FIELD's plain local pointer (as opposed to the field's
already-cell-backed direct-write siblings) was not re-probed against this
same fallback path, since those shapes already have their own promoted
`structCells`/`classCells` entries and take an earlier `*CellValue` branch,
never reaching the fallback this fix changed.

Progress 2026-07-16 (review fix: two BLOCKER regressions in class
reference identity, both from `writeCelledLocal`'s `classCells` branch
conflating a reference REBIND with a same-object field-write refresh):
code review of the class-reference-identity work above found two
regressions this PR itself introduced, both traced to the same root
cause. Finding 1: `c = b;` (a plain rebind) went through `writeLocation`'s
`VarExp` arm into `writeCelledLocal`, whose `classCells` branch
unconditionally called `writeClassCellScalarFields` on ANY class-typed
value -- splicing `b`'s fields into the cell `c` still shared with `a`
(`auto c = a;`) BEFORE `runAssignExpression`'s trailing
`registerClassAliasIfPlainVar` call re-pointed `c` at `b`'s own cell,
corrupting `a`'s value in the process. Finding 2: `writeLocation`'s
`DotVarExp` class arm re-derived its receiver via `runExpression(dot.e1)`,
the plain `VarExp`/`ThisExp` read path, which has no `classValueFromCell`
overlay (only the 3 cross-frame writeback helpers use one) -- so writing
ONE field folded every OTHER (possibly stale) field from that boxed
snapshot back into the shared cell via the same unconditional
`writeClassCellScalarFields` call, clobbering a DIFFERENT alias's earlier
field write that `writeClassCellFieldIfPresent` had already correctly
landed in the cell.

Fixtures, both in `tests/ut/backends/runner/ct/expressions.d`, right
after `class.methodMutatingThisIsVisibleThroughAliasedParameter`, pinned
on `Interpreter`/`SystemLinker` (the oracle) only, using function-
returning seed values throughout: `class.
reassigningAliasedVariableDoesNotCorruptOriginalObject` (`auto a = new
C(one()); auto b = new C(two()); auto c = a; c = b; assert(a.x ==
one());`) and `class.
aliasedFieldWriteSurvivesUnrelatedFieldWriteThroughOriginal` (`auto a =
new C(); a.x = one(); auto c = a; c.x = five(); a.y = seven();
assert(c.x == five());`). RED confirmed on `Interpreter` before any
production change, matching the review's own diagnosis exactly: `2 != 1`
for the first (`a.x` read back the NEW object's field) and `1 != 5` for
the second (`c.x` read back the value from BEFORE the unrelated `a.y`
write clobbered it). Both green on `SystemLinker` throughout.

Fix, in `impl.d`: `writeCelledLocal` gains a `classFieldRefresh` parameter
(default `false`), the class-typed sibling of the pre-existing
`arrayIsRefWriteback`, with inverted polarity -- `true` means "this value
is an AUTHORITATIVE same-object field-write refresh, safe to overwrite the
cell in place"; the default `false` covers every other caller (a plain
`c = b;`, a fresh declaration, a cross-frame writeback), which the
language's own semantics (classes have no `opAssign`) make a reference
REBIND, never a same-object mutation. Its `classCells` branch now only
calls `writeClassCellScalarFields` when `classFieldRefresh` is `true`;
otherwise it drops the cell via `dropClassCell` (not a bare
`classCells.remove`, so stale field-pointer reverse-lookup entries do not
survive either) and records the rebind in a new `classRebinds` marker map
(the class sibling of `arrayRebinds`), leaving the caller's own alias
bookkeeping (`registerClassAliasIfPlainVar`/`registerClassArgumentAliases`/
`registerClassThisAlias`, which every known rebind site already calls
right after) to associate the correct new cell -- this alone fixes
finding 1. `writeLocation` threads the same flag through to
`writeCelledLocal`; its `DotVarExp` class arm, `writeIndexLocation`'s and
`runIndexAssignExpression`'s class-array-field arms, and
`writeThroughSliceAlias`'s class-field arm (the foreach-ref-over-a-class-
static-array-field write path) all pass `true`, and each first re-derives
its receiver from the shared cell via a new `classCellOverlaidValue`
helper (a thin wrapper reusing the existing `classCellKeyVariable` +
`classValueFromCell`) before folding in the one field/element that
changed -- this closes finding 2, and the same staleness hazard in the
two array-field write arms and the slice-alias arm it shares the exact
read pattern with, even though only the `DotVarExp` scalar-field shape was
the review's own repro. `writeBackNestedLocals` (the one OTHER
`writeCelledLocal` call site that iterates every variable in a callee's
frame, including untouched class locals sharing a cell) gains a new
`classWritebackIsMutation` per-variable check (reading `child.
classRebinds`, mirroring the pre-existing `arrayWritebackIsMutation`/
`arrayRebinds` pair) so a nested/captured class variable the callee never
rebound still gets its parent-frame cell refreshed rather than needlessly
dropped.

Focused suites all green (run individually): ct.expressions (581 run, 0
failed, 5/5 failing as expected), ct.structs (305 run, 0 failed),
ct.arrays (346 run, 0 failed), ct.exceptions (130 run, 0 failed),
ct.control_flow (340 run, 0 failed), interpreter (218 run, 0 failed),
bin.repl (228 run, 0 failed), evaluator.eval (71 run, 0 failed). All 5
pre-existing must-stay-green class-aliasing fixtures (`aliasedVariable
WriteIsVisibleThroughOriginal`, `sameObjectPassedAsTwoParametersShares
Identity`, `methodMutatingThisIsVisibleThroughAliasedParameter`,
`aliasedVariableArrayFieldWriteIsVisibleThroughOriginal`,
`aliasedVariableStructFieldWriteIsVisibleThroughOriginal`) plus the
polymorphic-dispatch fixture (`typeid.classReferenceUsesDynamicClass`,
base-vs-derived cell sizing) and the recursive-class-cell fixture
(`pointer.recursiveClassDeclarationDropsStaleClassCell`) reconfirmed green
alongside both new fixtures. The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

Remaining follow-up (unchanged from the prior entry, not addressed by
this fix): recursive-frame cell distinctness, and class-reference
reassignment not decoupling an earlier field pointer from the old object,
both still need an activation-frame- or object-identity-scoped cell
rather than a variable-slot-scoped one -- structural changes out of this
surgical fix's scope.

Progress 2026-07-16 (review fix: `withUnionFieldWrite` zeroed a wider
sibling's tail, SHOULD-FIX finding 3, review of `value-native-20260715`):
the transient cell `withUnionFieldWrite` (`impl.d`) allocates to
re-derive every sibling after one union member's write is fresh and
zeroed (`NativeStruct.allocate`); it was seeded ONLY with the
just-written member's own bytes, so a sibling WIDER than the written
member had its bytes OUTSIDE that member's extent read back as zero
instead of the union's prior value there (`int[2] a; int i;`: writing
`u.i` after `u.a = [...]` zeroed `a[1]`; `long l; int i;`: writing `u.i`
zeroed `l`'s high 4 bytes). Fix, in `impl.d`'s `withUnionFieldWrite`
only: one added call, `writeStructCellScalarFields(cell, receiver)`,
seeding the whole cell from the union's CURRENT boxed state (the SAME
overlay-every-member path `promoteStructCell` already uses to seed a
cell from scratch) before the just-written member's own bytes are
written on top and the sibling-refresh loop runs -- a wider sibling's
tail outside the written extent now keeps its prior bytes instead of
reading zero. Exposing fixture (red-first; Interpreter read `0`,
expected `13`, matching the finding's own repro exactly):
`union.writeThroughScalarMemberPreservesWiderArraySiblingTail`
(`Interpreter`/`SystemLinker`; `Ctfe` omitted, omit-don't-pin, same
overlapped-field-read CTFE refusal the other write-then-read-a-sibling
union fixtures above already hit).

All 16 existing + new `union.*` fixtures reconfirmed green together,
including the four WRITE-the-WIDEST-member fixtures this fix must not
regress (`writeThroughOneMemberIsVisibleThroughAnother`,
`writeThroughScalarMemberIsVisibleThroughStructMember`,
`writeThroughScalarMemberIsVisibleThroughArrayMember`,
`writeThroughArrayMemberIsVisibleThroughScalarMember`) plus the
default-init pair (`untouchedSiblingDefaultsFromFirstMemberBits`,
`untouchedSiblingDefaultsFromStructFirstMemberBits`) and the
address-taken union fixture
(`addressTakenFieldSeesWriteThroughSiblingMember`). Focused suites all
green (run individually): ct.expressions (581 run, 0 failed, 5/5 failing
as expected), ct.structs (307 run, 0 failed), ct.arrays (346 run, 0
failed), ct.exceptions (130 run, 0 failed), interpreter (218 run, 0
failed), bin.repl (228 run, 0 failed), evaluator.eval (71 run, 0 failed).
The full `bin/ut --random` was left to the orchestrator per the usual
long-suite handoff.

Progress 2026-07-16 (review fix: `dropArrayCell` never invalidated the
`arrayNestedStructFieldPointer*` maps, SHOULD-FIX finding 4, review of
`value-native-20260715`): `promoteArrayNestedStructFieldCell` (`impl.d`,
the array-element/nested-field composition follow-up above, `&a[i].
inner.x`) populates four reverse-lookup maps
(`arrayNestedStructFieldPointerVariables`/`...ElementIndices`/
`...OuterFieldIndices`/`...InnerFieldIndices`) but, unlike every OTHER
pointer family's own reverse lookup, `dropArrayCell` never cleaned them
on a fresh binding -- it dropped only `arrayCells` plus the
`arrayAllocations`/`arrayAllocationVariables` memo. A loop body
re-executing the same `DeclarationExp` for the array local left an
EARLIER iteration's pointer id still mapped to that `VarDeclaration`, so
dereferencing it after the fresh binding resolved into the NEW binding's
freshly-promoted cell instead of correctly declining to the earlier
binding's own frozen snapshot. Fix, in `impl.d`'s `dropArrayCell` only:
collects and removes every stale id (mirroring `dropStructCell`'s own
reverse-lookup cleanup idiom exactly) from all four maps. No extra memo
to clear here -- this shape's receiver is never a plain `VarExp`, so
`fieldSnapshotAllocationId` always takes its fresh-id fallback and there
is nothing memoized per-variable the way `fieldAddressAllocations` is for
the struct/class cases. Exposing fixture (red-first; Interpreter read
`99`, expected `5`, matching the finding's own repro exactly):
`pointer.loopRedeclaredArrayNestedStructFieldPointerKeepsPreRebindValue`
(`Interpreter`/`SystemLinker`; other backends omitted, omit-don't-pin,
unconfirmed there).

All existing array-cell and array-nested-struct-field fixtures
reconfirmed green together, including
`pointer.arrayElementNestedStructFieldWrittenDirectlyIsVisibleThroughEarlierPointer`
(the fixture the four maps exist for) and the other stale-cell
regressions (`recursiveArrayDeclarationDropsStaleArrayCell`,
`arrayPointerTakenBeforePlainRebindKeepsPreRebindValue`,
`arrayPointerTakenBeforePlainRebindToShorterArrayDoesNotCrash`). Focused
suites all green (run individually): ct.expressions (583 run, 0 failed,
5/5 failing as expected), ct.structs (307 run, 0 failed), ct.arrays (346
run, 0 failed), ct.exceptions (130 run, 0 failed), ct.control_flow (340
run, 0 failed), interpreter (218 run, 0 failed), bin.repl (228 run, 0
failed), evaluator.eval (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

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

Progress 2026-07-16 (review fix: `promoteArrayNestedStructFieldCell`
double-evaluated a side-effecting array index, SHOULD-FIX finding 5, review
of `value-native-20260715`): `promoteArrayNestedStructFieldCell` (`impl.d`)
evaluated `index.e2` itself (`runExpression(index.e2).asLong`, to seed the
`arrayNestedStructFieldPointer*ElementIndices` reverse-lookup entry), while
`addressOfExpression`'s `DotVarExp` branch unconditionally called
`runExpression(dot)` right after to build the pointer's boxed snapshot --
re-running the WHOLE `a[i++].inner.x` chain, including `i++`, a second
time. Two bugs from the one root cause: a side-effecting index ran twice
(`&a[i++].inner.x` left `i` at 2, not 1), and the reverse map's element
index (from the FIRST evaluation) could diverge from the boxed snapshot's
element (from the SECOND). Fix: `promoteArrayNestedStructFieldCell` now
returns `bool` with `out Value value` (matching this file's established
`bool ...(out Value value)` convention, e.g.
`arrayNestedStructFieldPointerCellValue`) -- when the array-nested-struct-
field shape applies and a cell promotes, it builds the snapshot itself from
the ALREADY-evaluated `elementIndex`
(`runExpression(index.e1)[elementIndex].structFieldAt(outer).
structFieldAt(inner)`, the same field path `runExpression(dot)` walks, only
without re-running `index.e2`) and returns `true`; `addressOfExpression`
uses that value directly instead of falling back to `runExpression(dot)`.
Every other shape this promotion declines returns `false` before touching
`index.e2` at all, so `runExpression(dot)` remains their sole (first)
evaluation, unchanged. Exposing fixture (red-first; Interpreter read `i ==
2`, expected `1`, matching the finding's own repro exactly):
`pointer.arrayNestedStructFieldIndexWithSideEffectEvaluatedOnce`
(`Interpreter`/`SystemLinker`; other backends omitted, omit-don't-pin,
unconfirmed there).

Focused suites all green (run individually): ct.expressions (585 run, 0
failed, 5/5 failing as expected), ct.structs (307 run, 0 failed), ct.arrays
(346 run, 0 failed), ct.exceptions (130 run, 0 failed), interpreter (218
run, 0 failed), bin.repl (228 run, 0 failed), evaluator.eval (71 run, 0
failed). The full `bin/ut --random` was left to the orchestrator per the
usual long-suite handoff.

Progress 2026-07-16 (review fix: cross-frame class rebind is now marked even
through a null intermediate, HIGH residual finding, second-pass review of
`value-native-20260715`): the BLOCKER fix (`7e67c69c`) closed the SAME-FRAME
class-rebind corruption but left a CROSS-FRAME / nested-function-capture
analog open. `writeCelledLocal`'s `classCells` branch (`impl.d`) only set
`classRebinds[variable] = true` `if (value.isClassObject)`, so a nested
function rebinding a captured aliased class variable THROUGH an intermediate
`null` (`c = null; c = new C(2); c.x = 5;`) dropped this frame's own cell for
`c` (correctly) without marking the rebind (`null` fails `isClassObject`).
`writeBackNestedLocals`'s cross-frame reconciliation
(`classWritebackIsMutation`) read the absent marker as "child never rebound
this" and refreshed the PARENT's still-shared cell in place with the child's
new object instead of dropping it, splicing an unrelated object's fields into
whatever OTHER alias (`a` in the repro) still shared that buffer --
NONDETERMINISTICALLY, since which alias's writeback lands last depends on
`child.locals`'s pointer-keyed AA iteration order (`VarDeclaration*` hashes by
address, which varies run to run under ASLR). A net regression vs. the merge
base (`65f2e98c`, no class-cell machinery, boxed-mirror reference semantics
always correct).

Fix: a plain `VarExp` write to a class-typed variable is a rebind whenever it
is not an authoritative same-object field refresh, independent of what kind
of value it rebinds TO -- so `classRebinds[variable] = true` is now set
unconditionally in the drop branch (removed the `value.isClassObject` guard),
plus a new `else if` branch (mirroring `arrayRebinds`'s own no-cell-yet
branch) marking the rebind even when no `classCells` entry exists at all to
drop (the second rebind in a `null`-then-real-object chain, once the first
already dropped it).

Exposing fixture (red-first; confirmed reliably RED across 10 runs pre-fix,
diagnostic `11 != 15` -- i.e. `a.x` read back correctly as `1` but `c.x`
lost its own `5` and read back as `1`, clobbered by the parent's later
same-buffer refresh; asserting `a.x * 10 + c.x` in one expression means any
AA order that loses either side fails):
`class.nestedFunctionRebindOfCapturedAliasedVariableDoesNotCorruptOriginal`
(`Interpreter`/`SystemLinker`, omit-don't-pin). Confirmed deterministically
green across 10 runs post-fix. All pre-existing class-aliasing fixtures
(`reassigningAliasedVariableDoesNotCorruptOriginalObject`,
`aliasedFieldWriteSurvivesUnrelatedFieldWriteThroughOriginal`,
`sameObjectPassedAsTwoParametersSharesIdentity`,
`methodMutatingThisIsVisibleThroughAliasedParameter`, both
`aliasedVariable*FieldWriteIsVisibleThroughOriginal` fixtures, and
`pointer.recursiveClassDeclarationDropsStaleClassCell`) stay green.

Focused suites all green (run individually): ct.expressions (587 run, 0
failed, 5/5 failing as expected), ct.structs (307 run, 0 failed), ct.arrays
(346 run, 0 failed), ct.exceptions (130 run, 0 failed), ct.control_flow (340
run, 0 failed), interpreter (218 run, 0 failed), bin.repl (228 run, 0
failed), evaluator.eval (71 run, 0 failed). The full `bin/ut --random` was
left to the orchestrator per the usual long-suite handoff.
