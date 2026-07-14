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
(`ut.backends.runner.ct.expressions` `pointer.
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
`ut.backends.runner.ct.cerealed.encodeFloatReinterpretsBytes` is the other
live pointer-reinterpret fixture and is the same, already-covered
`float`->`uint` pair through a function parameter rather than a plain
local. No test pinned an old wrong answer for a newly-handled pair, so
nothing needed weakening or was left un-migrated. The strict-narrowing
case (target strictly narrower than source, e.g. a `uint` local read
through a `ushort*`) also newly takes this byte-level path rather than
the untouched passthrough -- the narrowing behaviour is correct (it reads
the leading bytes, matching compiled D) but, unlike the `dchar`/`uint`
pair above, no `ct/`/`rt/` fixture exercises a strict-narrowing
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
ut.backends.runner.ct.expressions ut.backends.runner.ct.cerealed
ut.backends.runner.ct.structs ut.backends.evaluator.eval` (all
pre-existing `@ShouldFail` rows still fail as expected), and `bin/ut -s
ut.backends.runner.rt.cstdlib ut.backends.runner.rt.dependency_image`. The
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
a new `ct/`/`rt/` fixture -- no such fixture was added, per this task's
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
ut.backends.interpreter`, `bin/ut -s ut.backends.runner.ct.expressions ut.
backends.runner.ct.cerealed ut.backends.runner.ct.structs ut.backends.
evaluator.eval` (identical to the pre-change baseline, pre-existing
`@ShouldFail` rows still fail as expected), and `bin/ut -s
ut.backends.runner.rt.cstdlib ut.backends.runner.rt.dependency_image`
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
ut.backends.interpreter.native_scalar`, `bin/ut -s ut.backends.runner.rt.
cstdlib ut.backends.runner.rt.dependency_image`, `bin/ut -s ut.backends.
runner.rt.concurrency ut.backends.runner.rt.file ut.backends.runner.rt.
random ut.backends.runner.rt.inline_asm ut.backends.runner.rt.elf ut.
backends.runner.rt.llvm_jit`, and `bin/ut -s ut.
backends.runner.ct.expressions ut.backends.runner.ct.cerealed ut.backends.
runner.ct.structs ut.backends.evaluator.eval` (identical to the pre-change
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
  struct field or array element exists in the `rt/` FFI fixtures to exercise
  this at runtime (grepped `tests/ut/backends/runner/rt/` for a struct with
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
`bin/ut -s ut.backends.runner.rt.cstdlib ut.backends.runner.rt.
dependency_image`, `bin/ut -s ut.backends.runner.rt.concurrency ut.
backends.runner.rt.file ut.backends.runner.rt.random ut.backends.runner.rt.
inline_asm ut.backends.runner.rt.elf ut.backends.runner.rt.llvm_jit`, and
`bin/ut -s ut.backends.runner.ct.expressions ut.backends.runner.ct.
cerealed ut.backends.runner.ct.structs ut.backends.evaluator.eval`
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
  regardless of what the bytes inside it actually held. No `rt/` fixture
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
backends.runner.rt.cstdlib ut.backends.runner.rt.dependency_image ut.
backends.runner.rt.concurrency ut.backends.runner.rt.file ut.backends.
runner.rt.random ut.backends.runner.rt.inline_asm ut.backends.runner.rt.elf
ut.backends.runner.rt.llvm_jit`, and `bin/ut -s
ut.backends.runner.ct.expressions ut.backends.runner.ct.cerealed
ut.backends.runner.ct.structs ut.backends.evaluator.eval` (identical to
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
ut.backends.interpreter.layout`, `bin/ut -s ut.backends.runner.rt.cstdlib
ut.backends.runner.rt.dependency_image ut.backends.runner.rt.concurrency
ut.backends.runner.rt.file ut.backends.runner.rt.random ut.backends.
runner.rt.inline_asm ut.backends.runner.rt.elf ut.backends.runner.rt.
llvm_jit`, and `bin/ut -s ut.backends.runner.ct.expressions ut.backends.
runner.ct.cerealed ut.backends.runner.ct.structs ut.backends.
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
ut.backends.interpreter ut.backends.runner.ct.expressions
ut.backends.runner.ct.structs ut.backends.runner.ct.arrays
ut.backends.evaluator.eval` -- 1139 run, 1 failed, 5/5 failing as
expected; the 1 failure
(`ut.backends.runner.ct.arrays.pointer.sliceAssignmentWritesArrayStorage.
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
ut.backends.runner.ct.expressions ut.backends.runner.ct.structs
ut.backends.runner.ct.arrays ut.backends.evaluator.eval` -- 1139 run, 1
failed, 5/5 failing as expected; the 1 failure
(`ut.backends.runner.ct.arrays.pointer.sliceAssignmentWritesArrayStorage.
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
ut.backends.runner.ct.expressions ut.backends.runner.ct.structs
ut.backends.evaluator.eval` (`ut.backends.runner.ct.classes` does not
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
ut.backends.interpreter.layout ut.backends.runner.ct.expressions
ut.backends.runner.ct.structs ut.backends.evaluator.eval` -- 838 run, 0
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
ut.backends.interpreter ut.backends.runner.ct.expressions
ut.backends.runner.ct.structs ut.backends.runner.ct.arrays
ut.backends.evaluator.eval` -- 1139 run, 1 failed, 5/5 failing as expected;
the one failure is the known pre-existing, unrelated
`ut.backends.runner.ct.arrays.pointer.sliceAssignmentWritesArrayStorage.
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
run: `bin/ut -s ut.backends.interpreter ut.backends.runner.rt.cstdlib
ut.backends.runner.rt.dependency_image ut.backends.runner.ct.expressions
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
ut.backends.runner.rt.cstdlib ut.backends.runner.rt.dependency_image
ut.backends.runner.rt.file ut.backends.runner.rt.random
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
`ut.backends.runner.rt.cstdlib.pthread.mutexattr.unionOutPointer.
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

New fixture (pre-approved): `tests/ut/backends/runner/ct/expressions.d`
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
`ut.backends.runner.ct.arrays.pointer.sliceAssignmentWritesArrayStorage.
Bytecode` ("Expression did not throw", already flagged by a prior progress
note above) and `ut.backends.runner.ct.structs.struct.
staticArrayCopyRunsPostblitAndDtors.Bytecode`, which segfaults
(`bin/ut -s ut.backends.runner.ct.structs` exits 139) -- a Bytecode-track
issue, not touched by or related to this Interpreter-only change. Both are
excluded from the focused runs below by naming every other test
explicitly; neither was fixed or weakened.

Focused runs, all green except the two pre-existing failures above:
`bin/ut -s ut.backends.runner.ct.expressions` (312 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`ut.backends.runner.ct.structs`/`ut.backends.runner.ct.arrays`/
`ut.backends.runner.rt.cstdlib` run explicitly by name minus the two
pre-existing failures above (631 run, 0 failed). The full `bin/ut
--random` was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (cross-frame scalar `&local`: shared cell already
coherent, redundant writeback retired): item 7's guest-level call site
continues -- the CROSS-FRAME case, where a called function writes through
a pointer to a caller's scalar local. New fixture (pre-approved):
`tests/ut/backends/runner/ct/expressions.d`
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
prior progress note) persists in `ut.backends.runner.ct.arrays` and is
untouched.

Focused runs, all green except that one known pre-existing failure:
`bin/ut -s ut.backends.runner.ct.expressions` (314 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.rt.cstdlib ut.backends.runner.rt.
dependency_image` (148 run, 0 failed); `bin/ut -s ut.backends.runner.ct.
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

New fixture (pre-approved): `tests/ut/backends/runner/ct/expressions.d`
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
`ut.backends.runner.ct.arrays` and is untouched;
`staticArrayCopyRunsPostblitAndDtors.Bytecode` (segfaults) was left alone
per standing instruction.

Focused runs, all green except the one known pre-existing failure:
`bin/ut -s ut.backends.runner.ct.expressions` (316 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.rt.cstdlib` (88 run, 0 failed); `bin/ut -s ut.bin.repl`
(228 run, 0 failed). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (ref-parameter guest call site: already coherent,
characterization test only): the last named frontier for item 7's
guest-level call site was a `ref` scalar parameter -- a guest takes
`&f` of a `ref` parameter, writes reinterpreted bytes through that
pointer, and the CALLER's own variable (bound to `f`) must observe the
write after the call returns. New fixture (pre-approved): `tests/ut/
backends/runner/ct/expressions.d`
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
Bytecode` failure persists in `ut.backends.runner.ct.arrays` and is
untouched.

Focused runs, all green except the one known pre-existing failure:
`bin/ut -s ut.backends.runner.ct.expressions` (318 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.rt.cstdlib` (88 run, 0 failed); `bin/ut -s ut.bin.repl`
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
matrix test `ut.backends.runner.ct.structs.struct.
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
`ut.backends.runner.ct.structs.struct.staticArrayCopyRunsPostblitAndDtors`
`.Interpreter`/`.Ctfe`/`.SystemLinker`/`.LLVMJit` (4 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.expressions` (318 run, 0 failed, 5/5
failing as expected); `bin/ut -s ut.backends.interpreter` (218 run, 0
failed); `bin/ut -s ut.backends.evaluator.eval` (70 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.rt.cstdlib` (88 run, 0 failed); `bin/ut -s ut.bin.repl`
(228 run, 0 failed). The full `bin/ut --random` was left to the
orchestrator per the usual long-suite handoff.

Progress 2026-07-13 (review fixes: cell invalidation on re-bind, two more
stale mirror-only read/write arms, sub-word reinterpret-write no longer
throws): a code review of the guest-level call site's four prior slices
above found four real gaps; all four are fixed by this commit, each with
its own red-then-green fixture in `tests/ut/backends/runner/ct/
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
ut.backends.runner.ct.expressions` (328 run, 0 failed); `bin/ut -s
ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (70 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.arrays` (302 run, 1 failed -- the known
`sliceAssignmentWritesArrayStorage.Bytecode`); `bin/ut -s
ut.backends.runner.rt.cstdlib ut.backends.runner.rt.dependency_image
ut.backends.runner.rt.concurrency` (151 run, 0 failed);
`ut.backends.runner.ct.structs.struct.staticArrayCopyRunsPostblitAndDtors`
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
`bin/ut -s ut.backends.runner.ct.expressions`; `bin/ut -s
ut.backends.interpreter`; `bin/ut -s ut.backends.evaluator.eval`;
`bin/ut -s ut.backends.runner.ct.arrays`; `bin/ut -s
ut.backends.runner.rt.cstdlib ut.backends.runner.rt.dependency_image`;
`bin/ut -s ut.bin.repl`; `bin/ut -s ut.backends.runner.ct.imports
ut.backends.runner.ct.pollution`. The full `bin/ut --random` was left to
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
`tests/ut/backends/runner/ct/expressions.d`, scoped to
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
ut.backends.runner.ct.expressions` (360 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.arrays` (320 run, 0 failed -- the previously-known
`sliceAssignmentWritesArrayStorage.Bytecode`/
`staticArrayCopyRunsPostblitAndDtors.Bytecode` failures noted in the round
above are gone, from unrelated master merges, not this slice); `bin/ut -s
ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.structs` (281 run, 0 failed). The full `bin/ut
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
`tests/ut/backends/runner/ct/expressions.d`, scoped to
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
ut.backends.runner.ct.expressions` (361 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.arrays` (320 run, 0 failed); `bin/ut -s
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
`tests/ut/backends/runner/ct/arrays.d`, scoped to `Interpreter`/
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
ut.backends.runner.ct.expressions` (361 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

Progress 2026-07-14 (slice-cell promotion guard: fixing a regression the
above slice introduced): the cerealed matrix test
`ut.backends.runner.ct.cerealed.multidimensionalArrayWritesNestedLengths`,
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
promotes). Focused runs, all green: `bin/ut -s ut.backends.runner.ct.cerealed`
(164 run, 0 failed, 1/1 failing as expected); `bin/ut -s
ut.backends.runner.ct.arrays` (322 run, 0 failed); `bin/ut -s
ut.backends.runner.ct.expressions` (361 run, 0 failed, 5/5 failing as
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
`tests/ut/backends/runner/ct/expressions.d`, scoped to
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
ut.backends.runner.ct.expressions` (363 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing
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
`tests/ut/backends/runner/ct/expressions.d`, scoped to `Interpreter`/
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
construction guards from the prior slices are unaffected. No
`interpreter.md` §9.10 shim is retired by this slice.

Focused runs, all green: the new fixture (confirmed red on Interpreter /
green on SystemLinker before the fix, green on both after); `bin/ut -s
ut.backends.runner.ct.expressions` (365 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing
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
in `tests/ut/backends/runner/ct/expressions.d`, scoped to `Interpreter`/
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
ut.backends.runner.ct.expressions` (367 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.arrays` (322 run, 0 failed);
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
`tests/ut/backends/runner/ct/expressions.d`, scoped to `Interpreter`/
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
ut.backends.runner.ct.expressions` (369 run, 0 failed, 5/5 failing as
expected); `bin/ut -s ut.backends.runner.ct.arrays` (322 run, 0 failed);
`bin/ut -s ut.backends.runner.ct.cerealed` (164 run, 0 failed, 1/1 failing
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
backends/runner/ct/expressions.d`, scoped to `Interpreter`/`SystemLinker`
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
SystemLinker); `bin/ut -s ut.backends.runner.ct.expressions` (371 run, 0
failed, 5/5 failing as expected); `bin/ut -s ut.backends.runner.ct.structs`
(281 run, 0 failed); `bin/ut -s ut.backends.runner.ct.arrays` (322 run, 0
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
(`tests/ut/backends/runner/ct/expressions.d`) turned out to already BE that
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
unchanged), `bin/ut -s ut.backends.runner.ct.expressions` reported exactly
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

Focused runs, all green: `bin/ut -s ut.backends.runner.ct.expressions` (371
run, 0 failed, 5/5 failing as expected); `bin/ut -s
ut.backends.runner.ct.structs` (281 run, 0 failed); `bin/ut -s
ut.backends.interpreter` (218 run, 0 failed); `bin/ut -s
ut.backends.evaluator.eval` (71 run, 0 failed). The full `bin/ut --random`
was left to the orchestrator per the usual long-suite handoff.

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
