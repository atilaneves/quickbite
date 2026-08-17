# Design: Interpreter — executing real project source

This is the **Interpreter language-completeness plan**. Its terminal goal: the
`Interpreter` backend executes the project source of a real dub package — every
statement and expression DMD hands it — so the package's unittests run under the
interpreter and agree, byte for byte, with the `SystemLinker` oracle. It is the
prerequisite no other plan owns.

This is the project's first priority. Cerealed is the driving integration
workload because it exercises a useful ordinary-D subset, not because the
Interpreter may know anything about that package. Production code must not
special-case Cerealed names, modules, paths, types, or behavior. Every failure
class becomes a standalone D semantic supported independently of the package.

The standing LDC-hosted two-backend acceptance command and its resource
calibration are the standing regression gate in §10. A DMD-hosted run is a
useful diagnostic control, but it is not the acceptance or performance
target: `bench.sh` uses LDC because DMD's optimiser makes the benchmark
result unrepresentative.

## 1. Goal

`Interpreter` executes the full statement/expression surface a real dub
package puts in front of it, so that `runTests(Interpreter, modules)`
produces the same per-unittest results as `SystemLinker`. This includes
reaching and correctly calling the body-less native leaves encountered along
the way. The Interpreter uses the typed-address `quickbite.ffi.ffi` bridge;
Interpreter-specific preparation, callback re-entry, and exception
translation stay in its backend adapter.

The unittest execution boundary returns success or a diagnostic directly. It
does not format the final interpreter result: display is a separate REPL
concern owned with `value.md`'s prelude formatter. `value.md` items 8-10 will
move expressions and nested function returns inside a unittest to
caller-provided typed destinations.

## Execution architecture

This section is authoritative for execution-state ownership, interpreted D
calls, and the migration away from child-`Walker` state copying. `value.md`
remains authoritative for value and place representation, while `ffi.md`
remains authoritative for the native-call seam. The precedent surveys —
including the call-state survey behind this section — live in
`ai/research/interpreter.md`.

The surveyed engines agree on the lifetime split that matters here: shared
execution state is borrowed, calls allocate compact frames, and none
duplicates growing mutable registries per call. The common asymptotic
contract is:

```text
call setup        O(arguments + frame storage)
registry access   expected O(1) per relevant operation
live frame memory O(call depth + escaped frame storage)
metadata memory   O(metadata actually created)
```

Call setup must not depend on the number of callables, objects, exceptions,
or slot addresses accumulated by earlier calls. Copying a registry of size
`n` at each of `m` calls costs `O(m * n)` and becomes quadratic when calls
grow the registry. That is an ownership defect, not a workload-specific
optimisation opportunity.

### Clean-sheet design

The Interpreter remains a no-emit AST interpreter. Recursive descent through
an expression or statement tree is appropriate; constructing another object
that combines evaluator machinery, execution-wide state, and call-local state
for every interpreted D call is not.

The existing `TreeNodeBackend` interface remains the external seam. Behind it,
one deep `Execution` module conceptually exposes one operation:

```text
execute(entry function, execution mode) -> EvalResult
```

The module hides frame allocation, receiver and parameter binding, `ref`,
`out`, and `lazy` semantics, closure capture, interpreted/native dispatch,
callback re-entry, return and exception propagation, and result construction.
Tests exercise the same backend interface as callers. DMD, storage, layout,
and GC are in-process dependencies and do not justify new public adapters. The
typed-address FFI bridge remains a real internal seam because multiple
backends use it and the Interpreter has distinct callback and exception work.

The clean design has four lifetimes:

```text
frontend session
    immutable AST-derived facts and layout caches, tied to one DMD arena
runtime
    module storage, address metadata, callable identity, native callback state
root execution
    one running entry, temporary roots, diagnostics, activation stack
activation
    one interpreted D function invocation
```

The current backend may combine runtime and root-execution storage until REPL
persistence or multi-test process semantics require the distinction. It may
not combine either with an activation.

An activation owns:

- its current function and fresh `FrameBlock`;
- lexical enclosing-frame handles or a captured environment;
- its receiver place;
- only its own lazy thunks;
- its ordinary or `ref` return target;
- return, loop, `goto`, `switch`, `finally`, and exception-control state; and
- expression scratch whose meaning ends with that invocation.

The evaluator borrows the one runtime and the current activation. An
interpreted D call creates an activation, evaluates its body, and removes the
activation on every return and unwind path. During the migration Quickbite's
ordinary compiled function recursion may still remember where AST evaluation
resumes; the interpreted D function is still evaluated, not called as native
code. A continuation machine or non-recursive dispatch loop is unnecessary
unless stack-depth failures or a profile later justify encoding suspended AST
evaluation explicitly.

The eventual private call seam normalises free calls, member calls, nested
calls, delegates, function pointers, constructors, `ref` returns, and native
callback re-entry into one invocation path. It establishes the result
destination, evaluates each receiver and argument exactly once in D order,
allocates and binds the activation, dispatches the body or native leaf, and
unwinds the activation. The endpoint follows `value.md`:

- a statement produces no value;
- an lvalue produces a typed place;
- an rvalue constructs into a caller-provided typed destination; and
- a call receives its result destination before the callee runs.

`ExpressionResult` is a migration carrier, not part of this target interface.

Guest associative arrays are druntime `Impl*` tables built by interpreted
`core.internal.newaa` code, but two `Impl` fields still hold interpreter-world
objects, so an AA must not cross the native-call seam; the seam work is
recorded in ffi.md's "Associative arrays" section. See [druntime's AA
implementation][druntime-newaa].

### Ownership invariants

- One root execution has one shared execution state. Every interpreted D call
  and synchronous native callback re-entry observes that same state.
- Each activation owns fresh frame storage. `ref`, `out`, receiver, and
  captured bindings retain typed addresses into existing storage; they do not
  copy values for later reconciliation.
- An address plus its static D type is the authority for a place. Side metadata
  may describe bytes that cannot encode an interpreted callable, dynamic class
  type, or native exception directly; it never becomes a second value store.
- Callable identities are unique and monotonic within the execution that owns
  them. Address-keyed slot metadata is not monotonic: ordinary stores, clears,
  copies, moves, and reallocations insert, replace, relocate, and remove its
  entries in step with the bytes.
- A callee's writes to shared storage and execution metadata are visible
  immediately and survive an exception. Interpreted D calls are not
  transactions, and return/unwind performs no snapshot merge or rollback.
- A lazy argument is a thunk over its source expression and the caller
  environment needed to evaluate it. Forwarding forwards that thunk; lazy
  state is activation-local, never an execution-wide map.
- An escaping delegate retains the storage or explicit closure environment
  containing its captures. It never retains a pointer to movable activation
  bookkeeping. A native callback retained past a call is valid only while its
  owning runtime and durable trampoline session remain live.
- Callback re-entry adds an ordinary activation while the interrupted
  activation stays live. It shares module storage, callable identity,
  address metadata, roots, and exception metadata with the interrupted call.
- Activation selection and expression-scope cleanup are restored on normal
  return and every unwind path. Unsupported semantics become the
  Interpreter's diagnostic; native exceptions are translated at the FFI seam;
  internal invariant failures remain distinguishable from D program behavior.

### Current state division

The surviving `Walker` fields divide as follows; the target design has the
evaluator borrow execution/runtime state and select an activation, copying
neither:

- **Execution:** callable identities and delegates; symbolic function,
  delegate, and `TypeInfo` slot metadata; native class type and owner metadata;
  native exception metadata and throwable roots.
- **Activation:** `FrameBlock`, enclosing frames, current function, receiver,
  lazy bindings, synthetic `$`, result and `ref`-return state, and statement
  control.
- **Expression scope:** evaluated reference-argument indices and temporary
  pointer owners.
- **Module/runtime:** module and static storage, lazily materialised class
  `.init` storage, and the durable callback session.

### Bounded execution contract

The standing gate in §10 protects the smallest coherent prefix of the target
architecture:

- A root allocates one `InterpreterExecutionState`; every child `Walker`
  borrows it before capture, receiver, or parameter binding can consult it.
- The shared state owns throwable roots and chain metadata; symbolic function,
  delegate, and `TypeInfo` slots; function identities and delegate definitions;
  native class types and owners; and native exception metadata. Calls publish
  mutations immediately rather than copying and merging these registries.
- Each child `Walker` remains a transitional activation container with a fresh
  `FrameBlock`, activation-local receiver/control state, lazy bindings, and the
  recursive AST evaluator. Callable metadata associated with a frame is
  retired with that frame unless an escaping closure retains it.
- Addressable receivers, slices, and `ref`/`out` arguments borrow their typed
  places. They are not snapshotted merely to pass them into another call.
- Packed call arguments, native-call staging, and aggregate-construction
  scratch have lexical lifetimes and are released only after their synchronous
  consumer has copied the result. Guest allocations, activation frames, and
  values that can escape are not reclaimed by this rule.
- Symbolic callable metadata follows general interpreted storage copy, clear,
  and relocation rules. An array-, delegate-, or Cerealed-specific snapshot
  path is not a substitute.

This contract deliberately preserves child `Walker` and recursive AST descent.
Renaming or splitting the evaluator is not part of the bounded gate.

### Later migration, in dependency order

The remaining clean-sheet migration is:

1. Extract an explicit `Activation` from the call-local `Walker` fields while
   preserving behavior and recursive AST descent.
2. Replace inherited lazy maps with activation-owned thunk bindings that
   retain the exact caller environment needed for evaluation.
3. Centralise activation entry and exit, then route every interpreted call and
   native callback through the one private invocation path. Delete child
   `Walker`, fork, and merge machinery.
4. Represent return, break, continue, `goto`, and interpreted throw as explicit
   evaluation outcomes instead of mutable evaluator flags or host exceptions
   used for language control flow.
5. Complete `value.md`'s place/destination-passing migration behind the same
   execution interface and delete `ExpressionResult`.
6. Split implementation files only where a private semantic module hides real
   complexity and improves locality. Do not expose shallow helper interfaces
   merely to reduce `impl.d`'s line count.
7. Profile again. Dense frame indices, frame reuse, AST/type caches, or an
   explicit continuation loop require evidence from the surviving
   implementation.

### Rejected directions

- No bytecode, threaded dispatch, JIT, or package-specific call path.
- No continuation-based rewrite of recursive AST descent.
- No frame arena, pooling, dense-slot rewrite, name cache, AST cache, or
  native-call cache without a profile that identifies it as the next bounded
  cost.
- No execution-wide lazy map. Lazy bindings belong to activations; their
  current transitional copying remains until the thunk migration or a profile
  proves it is the next blocker.
- No broad module extraction, frontend abstraction rewrite, persistent REPL
  runtime, debugger, suspension model, or concurrent execution requirement.
- No claim that every execution-state entry is monotonic. Only identity
  allocation is; address-keyed slot metadata mirrors mutable storage.

## 2. Non-goals

```text
- the Bytecode/IR backends' execution (ai/plans/bytecode.md);
- value representation choice (boxed vs native layout): ai/plans/value.md;
- new language features DMD does not lower for us (we execute DMD's AST, not
  raw source — templates and `static foreach` arrive pre-lowered);
- general interpreter tuning, deferred until `value.md` item 10 deletes
  the carrier (timings per `overview.md`'s measurement contract);
  execution-state lifetime correctness and bounded call setup remain here;
- value-representation performance, owned by `value.md`.
```

## 3. Oracle

`SystemLinker` (compiled, linked, executed native D) is the single behaviour
oracle, per `ai/plans/single-oracle.md` and `AGENTS.md`. Every fixture asserts
the same source on `SystemLinker` (passes) and `Interpreter` (red before, green
after). `Ctfe` is **not** an oracle here and never the definition of correct
behaviour.

Per `AGENTS.md`: adding or changing a test needs approval first; promoting an
existing oracle-backed matrix fixture to `Interpreter` is pre-approved. Fixtures
live in `tests/ut/backends/runner/lang/` (pure interpretation) and `sys/`
(runtime / FFI). This plan's fixtures are almost all `lang/` — they exercise
interpreter execution, not the native boundary.

## 4. Relationship to the FFI and representation plans

```text
quickbite.ffi.ffi
               address-only bridge shared by native-layout backends. It owns
               callable resolution, compiler-ABI provenance, CIF construction,
               and execution, but no backend value representation.
Interpreter adapter
               selects typed addresses and owns callback lifetime/re-entry and
               native exception translation. It has one preparation path and
               one execution path, with no legacy marshalling fallback.
value.md       how the interpreter represents runtime results and addressable
               storage. The meeting surface is wider than "a missing Value
               kind": any frontier class rooted in recursive aggregate boxing
               (synthetic pointers, cast-aliasing, allocation identity,
               reinterpret loads) is value.md's, handled per the §8 triage
               rule — red fixture here, Interpreter omitted, root fix there.
               value.md decisions 15-19 commit its end state (native-layout
               storage, a place is an address plus its static type,
               destination-passing evaluation, no FFI marshalling; the
               expression-carrier and shared-`Value` deletions are
               independent completion markers) and a two-track migration in
               which THIS plan is the workingness track and leads; the
               representation track lands as oracle-green slices per value.md
               items 8-10.
bytecode.md    a different backend; native-layout execution. Out of scope.
overview.md    the benchmarking measurement contract (GC policy, ratchet,
               corpus selection). Tuning the machinery delivered here waits
               for value.md item 10 and may not redefine language behavior
               or the `SystemLinker` oracle; correcting execution-state
               ownership and removing per-call state snapshots belongs to
               this plan.
```

`LINK.d` alone does not identify a callable's ABI: DMD and LDC order explicit D
arguments differently. Every resolved callable carries the ABI of its defining
compiler; neither the bridge nor an adapter may hard-code DMD or LDC globally.

Pointer slicing is ordinary D semantics and stays in this plan. Constructing
`ptr[lower .. upper]` creates a view at the adjusted address and length; it
must not eagerly read, unmarshal, or reconstruct the pointed-to elements.
It rejects `lower > upper` before address arithmetic, while deliberately not
checking whether the resulting view lies inside an allocation, matching
compiled D.

### 4.1 Standing work order

1. Restore, then keep, the default LDC-hosted Cerealed acceptance command
   green.
2. Take the next confirmed omission from §9 or a newly measured package.
3. Distil it into a standalone, package-independent D behavior, then implement
   that behavior against `SystemLinker`.
4. Promote the fixture into its oracle matrix and re-run the Cerealed gate.

### 4.2 Unittest execution is not REPL evaluation

`TreeNodeBackend` keeps unittest execution and REPL evaluation distinct:

```text
runTests(Module) -> TestResult[]
    uses executeUnitTest(UnitTestDeclaration) -> EvalResult
eval(FuncDeclaration) / evalFormattedDisplay(FuncDeclaration) -> EvalResult
```

The separation is the contract. A successful unittest reaches `TestResult`
without `displayString`, `Value.toString`, or `__quickbiteFormat`. A REPL
expression cell executes the frontend-synthesized formatter and returns its
string. Statement/no-display cells may use the same execution machinery
without manufacturing a display value.

Inside the walker, expression evaluation remains recursive because all real D
code, including unittests, computes expressions and calls value-returning
functions. Its endpoint is `value.md` decision 7: a call receives its caller's
typed destination, an lvalue yields a place, scalar work uses statically typed
host locals, and a statement executes with no result. Items 8-10 own the
migration from the current interpreter-private expression carrier to that
destination-passing contract.

## 8. Method: one standalone red/green unit test per reason

**The core rule.** For *each* reason the interpreter cannot run a driving
package's unittests — each root-caused gap class — the implementer writes a
**standalone unit test that passes on `SystemLinker` and fails on
`Interpreter`**. "Standalone" is load-bearing: the test must **not import,
build, or otherwise depend on the package**. It is a minimal, hand-written
reproduction of the construct — derived from *understanding* the package
failure, but self-contained — so it lives in `lang/`, runs with no package
present, and stays meaningful long after the package changes. The package is
the *discovery* instrument; the regression suite that proves each fix is
these independent fixtures, not the package.

```text
1. Re-measure: bin/bench.sh -b interpreter -b system-linker --dub <pkg>
   enumerates the disagreement set. A throwaway probe in benchmarks/cli.d
   printing every failing TestResult (the bench normally prints only the
   first) locates each by file/line; a permanent --list-failures bench
   mode is worth landing separately so this stops needing a patch.
2. Triage the set into root-cause classes. Counts are symptoms, not
   independent roots; clustering is the first action, not the frequency
   table.
3. Per class, write ONE standalone lang/ fixture reproducing that
   construct: green on SystemLinker (the oracle), red on Interpreter. Get
   it approved (AGENTS.md) before adding it.
4. Fix the ROOT until the fixture is green on Interpreter too. Re-measure
   and let the package inventory collapse.
5. Closing one class routinely reveals the next, deeper one previously
   hidden behind the first thrown error per unittest. Each newly revealed
   reason gets its own standalone red/green fixture in turn.
```

A single reason may need more than one fixture (e.g. read vs write, or per
element width), but each fixture still pins exactly one construct and obeys
the green-on-oracle / red-on-Interpreter rule. Fixtures follow the existing
`lang/` convention: a `static foreach` over the backend `Matrix!(...)`
wrapping `runBackendSourceFixtureTests!backend(q{ ... })` (see
`tests/ut/backends/runner/lang/cerealed.d` for the style — that file is
itself standalone distilled snippets, not a cerealed import).

**Matrix width and refusals.** Each fixture runs on the widest backend matrix
it can express. A backend for which the fixture stays red after the rung's
fix is *omitted* from the fixture's backend list — the omission is the
documentation, spelled `Omit!(B, Because.refusal, "verbatim red")`
(`tests/ut/backends/package.d`). Do **not** pin a structured unsupported
diagnostic with `shouldThrowWithMessage`, especially for backends still in
development: such pins turn every feature landing into a test-update chore,
and a pinned refusal is never the end state.

**The goal is support, not pinned refusal** (user directive). A fixture that
accepts an unsupported diagnostic as a passing outcome is crash-scoped
triage, never the end state: the goal is that the interpreter **runs** the
construct and agrees with `SystemLinker`. Do not add tests that pin an
unsupported diagnostic as acceptable interpreter behaviour.

**Triage rule: language-surface vs representation-ceiling.** Before fixing a
frontier class, classify its root:

```text
language-surface      the interpreter lacks a language behaviour any
                      representation needs (a missing expression branch,
                      lazy-parameter semantics, exception hierarchy,
                      on-demand semantic2). Fix here, red fixture first,
                      per the §8 loop.
representation-       the root is value representation: synthetic
ceiling               pointers instead of addresses, cast-aliasing the
                      value model cannot see, lost allocation identity,
                      reinterpret loads, or a runtime hook whose contract
                      is real memory (gc_*, memcpy). Write the standalone
                      red fixture (the durable asset), OMIT `Interpreter`
                      from its matrix per the rule above, and defer the
                      root to value.md's native-layout track. Do not add
                      a shim.
```

Support for ceiling classes arrives via the representation change, not via
name-based shims that approximate it — a shim that skips construction
semantics or fabricates a hook's return value is a silent wrong answer, the
worst failure class. A class whose root fix needs new boxed FFI marshalling
gets the same gap-fixture-and-wait treatment (`value.md` decisions 17/18): a
blocked package waits and re-earns its rows at the authority switch.

**Interception policy.** AGENTS.md's druntime-first rule governs: a function
with interpretable D source must be executed. Name-based interception of a
called function is reserved for functions the frontend has **no body** for
(`extern(C)` prototypes such as `memcpy` and the `gc_*` hooks — verify:
`fd.fbody is null` at the call site) or whose body is inline asm the walker
cannot execute (`core.internal.atomic`).

**Mechanical guard.** The chokepoint is `Walker.runCallExpression` (impl.d).
Every name-based intercept there calls
`enforceInterceptionPolicy(callee, interceptorName)`
(`source/quickbite/backends/interpreter/interception_guard.d`) immediately
before running its handler. The guard's predicate, `isLegalInterception`,
accepts a callee when `fd.fbody is null`, or the body is/contains a
`CompoundAsmStatement` (a recursive walk using dmd's own
`StatementRewriteWalker` — quickbite runs dmd frontend-only, so the
individual asm instructions inside an asm block are never resolved past
`null` placeholders; only the `CompoundAsmStatement` wrapper node itself is
reliably present, from parse time onward), or the callee is on the exemption
list below. Any other body-ful, non-asm callee fails an `assert` naming the
intercept and the callee — deliberately an `AssertError` (a `Throwable`, not
`Exception`) rather than a thrown `Exception`, so it cannot be swallowed by
an interpreted `catch (Exception)` or by unit-threaded's `shouldThrow`, and
fails the enclosing unittest outright. Predicate unit tests live in
`tests/ut/backends/interpreter/interception_guard.d`.

Exemption list (`isExemptInterception`), each with its retirement condition:

```text
std.conv.text                             retire per value.md remaining work
                                           item 10.
core.internal.array.operations.arrayOp!(  retire when static-array
...)                                      element-wise ops interpret
                                           end-to-end over native layout.
rt.aApply's _aApplycd1/_aApplywd1/        extern(C)-mangled but D-bodied;
_aApplydc1/_aApplyRwd1                    retire when string/array native
                                           layout covers UTF-mismatch
                                           foreach.
core.internal.util.array.                 the shim fakes a `bool` return for
enforceRawArraysConformable[No]gc         a `void`-returning function.
                                           Retire by executing the real bodies
                                           once static-array element-wise ops
                                           are interpretable end-to-end.
core.atomic.atomicValueIsProperlyAligned  plain D bit arithmetic, no asm.
!(...) / atomicPtrIsProperlyAligned!(...) Retire once interpreter values
                                           carry real addresses everywhere.
core.internal.atomic.atomicFetchSub!(...) each forwards in one line to a
/ atomicStore!(...)                       sibling primitive containing the
                                           real asm, so the asm-body check
                                           (which only inspects the callee's
                                           own body) misses them. Retire
                                           with the rest of the AtomicHook
                                           family.
tryInterpreterBuiltin's matched set:       dmd's own `isBuiltin()` recognises
std.math.algebraic.fabs/sqrt,             these by module+identifier for its
std.math.exponential.pow,                 CTFE builtin table regardless of
std.math.traits.isInfinity, and (via a    body, so quickbite's reuse of that
bare-identifier fallback with no          table inherits the same
`BUILTIN` entry) std.math.traits.signbit  body-independence. Retire once
                                           `InterpreterBuiltin` computes each
                                           from the value's real
                                           representation.
```

## 9. Open work queue

- `writeBackSliceElements` (impl.d, the array-op `+=` lowering's splice
  copy) rebuilds a pointer-typed slice base as a detached local copy — a
  latent silent-lost-write class. Needs its own exposing fixture before a
  fix.
- `tryInterpreterBuiltin`'s bare-identifier `signbit` fallback matches on
  the identifier alone with no module check
  (`interception_guard.d`), so a user or library function literally named
  `signbit` would be silently intercepted and given
  `std.math.traits.signbit`'s behaviour. Language-surface; fix with a
  module check.
- Confirmed `Interpreter` omissions to promote back into their
  `SystemLinker`-oracle matrix after fixing the named red behavior:
  - `dynamicArray.reserveThenAppendWithinCapacityDoesNotReallocate`: retain
    the zero-length allocation's pointer identity across `reserve` and
    append.
  - `pointer.comparisonWithinArray`,
    `pointer.relationsAcrossArraysReturnFalse`, and
    `pointer.arrayElementPostIncrementedThroughPointerIsVisibleDirectly`:
    provide the native pointer representation required by comparison and
    write-through operations.
  - `pointer.slicePastAllocatedBlockDiagnostic`: decide whether the
    interpreter should retain its allocated-block diagnostic; it currently
    neither matches that characterization nor participates in the
    compiled-behavior row.
  - `stdConvTextRendersCharArrayExpressionRaw`: keep the character array's
    full allocated block visible through the `std.array`/`std.conv.text`
    path.
  - `refArgument.voidStructLocalFieldWritableThroughNestedRefWrite`:
    materialize the void-initialized struct before nested ref forwarding
    reads its field.
  - `struct.staticArrayCopyRunsPostblitAndDtors`: preserve pointer fields
    while copying static-array elements before their postblits run; the
    current postblit dereferences a null counter pointer and terminates the
    test process.
- An interface method taking a parameter, called through an interface-typed
  variable, fails with "Unsupported interpreter call arguments." Only
  zero-arg interface methods are proven (`expressions.d`'s
  `Speaker.score()`). Found via `tests/example.d`; no matrix fixture pins
  it yet.
- A zero-arg interface method called through an interface-typed variable
  constructed directly inside a `unittest { }` block (rather than inside an
  ordinary function, as every proven matrix fixture does) silently returns
  the wrong value, with no diagnostic. Found via `tests/example.d`; no
  matrix fixture pins it yet.
- A method call chained off an assignment whose target is a side-effecting
  `PtrExp`/`IndexExp` is refused; the lifting condition is recorded in
  `value.md`'s item 4 notes.

## 10. Standing Cerealed regression gate

The exact standing LDC-hosted command must remain green:

```text
./bin/bench.sh -b interpreter -b system-linker --dub cerealed -w 0 -r 1
```

Acceptance requires both rows to execute and agree on all 156 tests. A skip,
backend disagreement, crash, timeout, or out-of-memory result is a failure.
The portability gate is completion inside `ci.sh`'s existing resource limits.

The establishing measurement for the corrected workload completed with exit
status 0:

```text
Interpreter   156/156   233724.925 ms
SystemLinker  156/156     1241.986 ms
GC used delta             8286906.8 KiB
maximum RSS               8859432 KiB
```

These measurements calibrate the workload on the establishing host; they are
not cross-machine timing thresholds. In particular, do not use `02c0c9b5`'s
12-13 second Interpreter run as a target. That revision failed to bind the
live heap receiver for `Random` construction, causing 99 generated arrays to
have length 1 instead of the hundreds of elements produced by compiled D. It
therefore timed a smaller, incorrect workload. `SystemLinker` is the sole
behaviour oracle.

If the exact command is correct and bounded, stop. If it becomes unbounded,
profile the surviving per-call work and take only the next measured cause. Do
not begin the complete architecture migration merely because more cleanup is
possible.

Timing discipline: the establishing ratio (~190x Interpreter to
`SystemLinker`) is the unacceptable baseline, not a tolerated fact. Every
landed optimisation slice must reduce the post-parse ratio, re-measured with
the exact command above; the expected destination is the Interpreter row
beating the `SystemLinker` row, which pays per-test native compile+link.
Official timings follow `overview.md`'s measurement contract (GC enabled).
Before executing the optimisation queue, one whole-process `perf record`
plus allocation-count run of the gate command orders it: while execution
dominates the row by two orders of magnitude, a whole-process profile is a
valid post-parse profile and no dedicated profiling boundary is needed.

Every new semantic rung keeps an approved oracle-backed, package-independent
fixture and must not regress this gate. Production code remains free of
Cerealed-specific names and behavior.

## 11. Beyond cerealed

Cerealed is the first driving package, not the finish line. Automem is the
second package and exercises allocators, reference-counted ownership,
interfaces, nested callables, and native-layout mutation. Once both package
gates are green, the next prioritized Interpreter work is `value.md` item 8:
destination-passing entry points and a genuine no-result statement path.
Package-driven workingness continues in parallel through `value.md` item 4;
do not restore legacy marshalling or value machinery for a later package.

### 11.1 automem — open disagreement queue

automem is the second driving package. Acceptance:

```text
./bin/bench.sh -b interpreter -b system-linker --dub automem -w 0 -r 1
```

Post-parse timing is skipped until the Interpreter agrees with the oracle on
every automem test; the disagreement skip makes the whole command exit 1.
Re-measure with the command above before starting. Two gate facts that no
interpreter work changes: `findPkgDir` sorts cached versions lexicographically,
so the gate benches automem 0.6.9 even with 0.6.11 cached; and the
`@ShouldFail` issue-19752 test in `ut.issues` reads a `Vector.range` that
points into a smashed stack frame, so the oracle fails it while the
Interpreter passes — the bench runs raw unittest blocks and ignores
`@ShouldFail`, so agreement there needs a harness/policy decision, not an
interpreter feature.

The open classes, each with its refusal site and the automem shape driving it:

- **Unsupported interpreter field access** — `structFieldIndex` resolves a
  field only when the receiver's static type is literally a struct and the
  field is found by identity in `structFields`; automem reads fields through a
  class emplaced in `RefCounted.Impl._rawMemory` (including `shared`),
  `mixin Proxy`/`alias this` chains onto class references, and
  interface-typed handles. Fix direction: the `Place.field` byte-offset
  route, which needs neither a struct-typed receiver nor identity lookup.
- **Unsupported interpreter assignment target** — `writeIndexLocation`
  hand-enumerates its supported base shapes; `Vector!(immutable T)` writes
  through `(*(cast(MutE[]*) &_elements))[i] = x`, a dereferenced-cast base it
  lacks. Fix direction: resolve the base to a `Place` and compose
  `Place.index` instead of rebuilding aggregates with `AggregateValue.with*`.
- **cast_** — the op is dispatched; the refusals are `pointerCastValue`
  (operand not carried as `Pointer`) and `delegateCastValue` (live
  interpreted closure). Driven by `allocatorObject`/`CAllocatorImpl` in the
  `theAllocator` tests and by `StackFront`/`mmapRegionList` internals.
- **classReference** — genuinely absent from the walker: automem throws a
  CTFE-constructed `static immutable boundsException = new BoundsException(…)`,
  which reaches the walker as `ClassReferenceExp` (a `StructLiteralExp` whose
  `sd` is a `ClassDeclaration`). Needs materializing a native class body from
  the wrapped literal and rooting it in the class-identity table, as
  `structLiteralExpression` does for structs.
- **loweredAssignExp** — `runLoweredAssignExpression` handles only the
  `arr.length = n` lowering and ignores the node's `lowering` field; the
  vector-of-vectors block copy `_elements[] = elements[]` (postblit+dtor
  element type) lowers to `_d_arrayassign*` and is refused. Fix direction:
  run `assign.lowering` (already a `CallExp`) or route through the existing
  slice-assign machinery.
- **Memory leak in TestAllocator** — symptom, not site (below). Two facts for
  the hunt: class disposal computes the freed slice via
  `typeid(ob).initializer.length`, so it sits behind the field-access/TypeInfo
  wall; and the Interpreter runs no module/static destructors at all, so any
  teardown-time leak check sees every module-level block outstanding.
- **Place.index out of range for static array place** — a slice or `&arr[0]`
  over a static array keeps the `Tsarray`-typed place, so later indexing
  bounds-checks against the declared element count; driven by
  `TestAllocator._textBuffer`, a `char[1024]` field of a `static` (TLS)
  struct. Fix direction: convert the place type to the pointer/slice-header
  form at slice/address-of time so the correct arm runs.
- **data pointers must carry a native binding address** — the automem member
  is a deliberate null dereference: `RefCounted`'s default ctor leaves
  `Impl*` null and the test expects a guest `AssertError` from the `in`
  contract. An unbound/null pointer dereference must map to the guest error,
  not the host-side exception.
- **plain wrong values** — the `ut.unique` members overwrite a live `Unique`
  (deref-assign, move-assign, assign-from-rvalue) and require the overwritten
  object's destructor to run before the move; the Interpreter skips it.
  Other members: `Vector.opBinary!"~"` building from `chain` of two slices,
  and `std.conv.text` over the pointer-backed `Range` struct.

Each class takes one subagent and §8's one-standalone-fixture-per-reason rule;
they are correctness bugs, not crashes, so `SystemLinker` arbitrates every one.

One member of the wrong-value class is already isolated: an element of a static
array of structs does not get its declared field defaults, so
`struct R { char[4] c = "...."; } R[2] arr;` reads `0xFF` bytes where compiled D
reads `'.'`. A single struct gets its defaults; only the array elements miss
them. Expect this to disguise itself as corruption in an unrelated fixture
before it is fixed — it did exactly that during review.

Two properties of this queue that a re-measure will not show. The field-access
class is a **wall**: clearing it does not retire its tests, it advances them into
`Unsupported interpreter call arguments`, `Array slice needs native aggregate
storage`, and `Interpreter binding value is not place-composable`, clustered on
`GC.addRange` over a `void[]` class-body slice — successors that belong to no
class above, so the queue drains more slowly than its width suggests. The
`Memory leak in TestAllocator` class is a **symptom, not a site**: a native call
that mutates a copy instead of the receiver leaves a freed block recorded, and
the allocator's destructor then throws from inside `opAssign` before it rebinds,
so the failure surfaces well after the test that actually diverged. Locate the
divergence, never the reported test.

Start from branch `automem-interpreter-disagreements` (`e0bd8482`), which carries
the field-access class with three fixtures whose Ctfe and Bytecode rows still
need adjudicating.

### 11.3 Evict the address-keyed tables

The table holding each class object's identity, and the two beside it
(class owners, nested-struct context frames), never evict: every guest object
an execution allocates is retained for the backend instance's lifetime.
Deriving retention from surviving roots needs a reachability pass over module
storage, which an address-keyed table cannot support as it stands. One
decision covers all three, and it is the same decision as whether identity
should be keyed by address at all.

### 11.4 `new`-expression constructors never bind captures

The two `new`-expression call sites in the Interpreter fork and retire a child
activation for the constructor but never call `bindCapturedReferenceSlots`, so
a function-local struct's constructor cannot read a captured variable the way
its ordinary methods can. No failing case is known: a struct constructed with
`new` whose constructor reads a capture currently resolves it some other way
(through the receiver's own context field, not this binding step) and passes
on every backend. Recorded because the asymmetry with the other four
call-spawning sites is real, not because a bug is known to follow from it.

## 12. Structural maintenance queue

Behaviour-preserving items; each is a ride-along for a nearby rung PR, not a
rung of its own.

- Cross-backend diagnostic wording moves out of
  `backends/interpreter/messages.d` one function at a time, into a
  `backends/`-level wording module, at the moment a second backend needs the
  function. The one function already shared is `uninitializedVariableMessage`
  (imported by `backends/ir/compiler.d`); it seeds the module. No new
  cross-package imports of `interpreter.messages`.

[druntime-newaa]:
  https://github.com/dlang/dmd/blob/master/druntime/src/core/internal/newaa.d
