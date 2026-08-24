# Value Representation — remaining work

This plan is a store of the value-track work still to be done. Completed
work lives in git history, and the current state is re-derived from the
code, never from a snapshot here. The precedent survey and primary-source
evidence behind the settled representation — native-layout storage as the
only value authority, destination-passing evaluation into typed places,
a typed-address-only FFI boundary — live in `ai/research/interpreter.md`.

The completion marker closes the track: deleting
`source/quickbite/backends/interpreter/expression_result.d` (item 10).
Production Interpreter optimisation begins only after item 10 deletes the
carrier; timings follow `overview.md`'s measurement contract.

## Remaining work

The remaining value-track work is the carrier deletion (item 10) and the
language-surface tasks below. Item numbers remain stable for existing
cross-references.

### Item 10 — Carrier deletion

Re-measure with `grep -c ExpressionResult
source/quickbite/backends/interpreter/*.d`. `Walker._returnDestination` is
already destination-typed, not carrier-typed — that former bottleneck is
cleared and no longer blocks the rest.

Expression evaluation has one dispatch: `constructInto` for an observed result
and `executeForEffectImpl` for a discarded result. Arm-local adapters can still
return `ExpressionResult`, but no separate result-returning expression walk
exists. Assignment evaluates its live place once, constructs its right-hand
side in separate fresh typed temporary storage, then applies D-defined
assignment, move, postblit, and destruction semantics to that place. Never
construct the right-hand side directly in a live target: an alias could observe
a partially constructed value.

Calls evaluate each non-lazy argument once into a typed `Place`; `ref` and
`out` arguments pass either their resolved lvalue place or a typed synthetic
temporary. Function, member, delegate, constructor, and FFI binding consumes
only those places. Member and delegate receivers are places too. Reverse FFI
callbacks borrow the typed libffi buffers directly, and callable metadata is
keyed by the delegate place address.

- **Final flip**: type `readStoredValue`/
  `writeStoredValue` and the `run*` helpers' signatures, delete
  `constructedExpressionValue`'s boundary box and `place_value.d`'s carrier
  codec (`readValue`/`writeValue`/`readScalarLeaf`/`writeScalarLeaf`),
  `git rm expression_result.d`, and retire
  `tests/ut/backends/interpreter/place_value.d`/`native_array.d`. Also
  inventory real corpus crossings that need an interpreted callable or
  `TypeInfo` to escape to native code — the standing refusal holds:
  no trampoline or proxy until a real crossing exists.
- **Deferred findings** (need a proving test first, AGENTS.md): a native
  delegate slot's `.ptr`/`.funcptr` always throws, pre-existing;
  `constructPointerExpressionInto`'s pointer-typed `CastExp` branch
  (`isPointerType(cast_.e1.type)`) may wrongly collapse a null slice/pointer
  read (unproven, like its guarded array-projection sibling once did);
  the opAssign-postblit interaction candidate from the branch review is
  unverified.

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

### Item 6 — Open design questions

Determine the lifetime contracts for blocks borrowed from arbitrary C owners,
what a guest pointer into a grown array should observe, and whether that
deserves a diagnostic rather than compiled D's silent staleness.

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

## Out of scope

`quickbite.executor.Value` (the legacy executor type) is unaffected, as
before; it dies with the legacy executors. Bytecode/interpreter
native-layout deduplication and any shared-substrate extraction are out
of scope: later, if ever, and subordinate to finishing the
bytecode VM.

## Guardrails

- Addressable-temporary storage: the gate-corpus measurement did not
  justify segmented scratch; do not introduce it without a new
  measurement that does.
- The display format spec above is the contract: no formatter or
  test-migration work may diverge from it without updating it first.
- Display renderings must round-trip as valid D: a rendering
  that cannot be parsed back and evaluated to an equal value is a spec
  violation, except for the no-D-expression values of rule 7.
- Do not use string heuristics in REPL/frontend code to classify D
  source.
- Do not use failed evaluation as REPL control flow.
- Keep backend-specific DMD conversion inside backend adapters while the
  interim scaffolding lives.
- Formatter-track changes must not touch `backends/bytecode/**`; bytecode
  display parity goes through `bytecode.md` slice 11. When
  a display change collides with a bytecode-pinned row, apply the matrix
  rule (drop the engine from that block, record the pending re-earn)
  rather than extending bytecode display scaffolding.
- Do not restore FFI marshalling, cell families, alias maps, pointer-kind
  predicates, or name-based representation shims. A blocked project gets an
  oracle-backed gap fixture and a native-storage fix.
- DMD-derived layout facts stay the source of truth, cached on the
  handle; the interpreter must not grow a second set of D layout rules.
