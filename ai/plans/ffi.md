# Design: FFI — calling native code from Quickbite backends

## Status

The FFI bridge v1 milestone is complete. There is no independent FFI ladder to
climb. New bridge work is selected only by a concrete consumer:

- a real dub package reaches a body-less native leaf that is handled wrongly;
- the Bytecode native-runtime track needs another ABI shape or inbound entry;
- the Interpreter native-layout track reaches native class/object storage; or
- measurements justify cold-path dependency-image work.

The shared bridge is live infrastructure, so this document remains its contract
and ownership plan. It is not an implementation diary. Historical detail is in
git history; the tests named below are the executable record.

Bridge completion does not mean every backend has eliminated representation
conversion. The Interpreter now has native storage authority and direct-address
argument/result paths, but its adapter still retains transitional
`RuntimeValue` buffer fallbacks. Deleting those fallbacks is planned in
`ai/plans/value.md` item 5 and does not reopen the shared bridge milestone.

## 1. Goal

Quickbite executes project source without relinking it, then calls the native
leaves it bottoms out in. A native leaf is mechanically a resolved
`FuncDeclaration` whose `fbody is null`. The bridge must:

- resolve already-loaded native symbols;
- derive the ABI call descriptor from DMD's resolved type;
- cross values without importing any backend representation;
- preserve native writeback, callbacks, and supported exceptions; and
- keep symbol resolution and non-variadic CIF preparation off the per-call
  hot path.

Bridge v1 meets that goal for the supported surface in §34.3. It does not claim
that every possible D or C++ ABI feature is supported. The explicit boundaries
are in §35.

The project-level goal, running real dub projects, also needs the backend to
execute all source that leads to those leaves. That work belongs to
`ai/plans/interpreter.md` and `ai/plans/bytecode.md`.

## 2. Non-goals

```text
- implement a linker inside a backend;
- load arbitrary object files directly;
- reimplement libc, druntime, Phobos, or OS services;
- generate or AOT-compile a wrapper per callable;
- make native dependency execution hermetic by default;
- solve dependency discovery, image construction, or persistent-host caching.
```

Dependency-image preparation and caching belong to `ai/plans/dub-deps.md`.

## 3. Rejected generated-wrapper design

The original plan proposed generated wrapper source, numeric wrapper IDs, a
manifest, and AOT-compiled thunks. That design is rejected. DMD already gives
the bridge the mangled symbol and ABI-level signature, so libffi can construct
the call dynamically without generated source.

Generated thunks may be reconsidered only as a measured performance
optimization. They are not a correctness prerequisite. The old cold-path
ideas—dependency-image construction, a persistent host, and cache keys—belong
to `ai/plans/dub-deps.md`, not this bridge plan.

## 4. Mechanism

The outbound bridge performs two operations:

```text
resolve: dlsym(RTLD_DEFAULT, mangleExact(function))
call:    ffi_call(cachedCif, symbol, argumentAddresses, resultAddress)
```

The bridge derives `ffi_type` trees from DMD types. libffi performs the host
ABI classification, including integer and SSE classes, stack spill, small
structs, hidden memory returns, and C variadics.

Non-variadic CIFs are cached per resolved callable and hidden-call shape.
Variadic C calls use `ffi_prep_cif_var` per call because their trailing actual
types are call-site data.

The implementation is:

```text
source/quickbite/ffi/core.d     resolution, ABI descriptors, calls, callbacks
source/quickbite/ffi/libffi.d   libffi declarations
```

## 5. Backend-neutral seam

`quickbite.ffi` deals in DMD types, native addresses, and ABI bytes. It never
names `quickbite.lang.Value` or imports a backend.

Backends currently implement `NativeMarshaller`:

```text
canRepresent / canRepresentOutCell
fillArgument / fillReceiver / fillOutParameterCell
readResult / writeRefResult / writeOutParameter
receiverObjectPointer
invokeClosure / durableInboundCallbackId
argumentAddress / resultAddress
```

The Interpreter uses the address methods where its call site already exposes
native storage, but still uses buffer methods to materialize and reify
transient `RuntimeValue`s on remaining paths. That fallback is migration debt
owned by `ai/plans/value.md` item 5. A native-layout backend may return stable
frame-slot addresses from `argumentAddress` and `resultAddress`, avoiding
per-argument allocation and copying. Null addresses request the buffer
fallback.

The pointer-handing variant and the non-variadic CIF cache are landed. The live
Bytecode call site proves the seam has a second, native-layout consumer.

## 6. Ownership and track boundary

```text
Track A — this plan, source/quickbite/ffi/**
  symbol resolution, ffi_type construction, CIF caching, ffi_call,
  ABI ordering, inbound trampoline registry, native exception capture

Track B — ai/plans/value.md, backends/interpreter/**
  removal of transitional materialize/reify, object representation,
  interpreter writeback and catch-object construction

Bytecode — ai/plans/bytecode.md, backends/bytecode/**
  native-call lowering, accepted VM value shapes, frame-slot addresses,
  VM re-entry and runtime metadata consumers
```

A backend limitation does not become shared bridge work unless the shared ABI
core is the limiting layer. Backends must not import one another.

## 11. Values crossing the boundary

### 11.1 Plain ABI values

Integers, booleans, characters, floating-point values, enums, and pointers use
their native ABI width and alignment.

### 11.2 Bridgeable aggregate values

Slices use the native `{length, pointer}` descriptor. Static arrays are inline.
Structs recurse through DMD field offsets. The boxed Interpreter copies these
shapes and applies explicit writeback; native-layout backends can hand their
storage directly to the bridge.

Associative arrays are not a portable ABI value and are refused before native
side effects. Packed layouts and unsupported overlapping layouts also fail
before the call.

### 11.3 Opaque native values

Class and interface references cross as native object pointers. The boxed
Interpreter treats the pointer as an opaque handle and routes methods back
through the bridge. Native-layout backends eventually use the same pointer as
the actual object reference.

Opaque handles are appropriate only when the backend need not interpret the
object's bytes. Using handles for values the backend must index, branch on, or
mutate would evade rather than implement the language semantics.

## 12. Exceptions

Outbound native calls catch `Exception`, retain the native `Throwable`
reference, and expose its dynamic class, message, and `next` chain to the
backend. `Error` remains fatal at the native boundary.

The boxed Interpreter reconstructs its catch value and may read subclass
fields from the retained native object by DMD field offset. A native-layout
backend should use the native object reference directly when its exception
execution path is ready.

Stack-trace preservation, native rethrow identity, and exceptions escaping an
inbound callback are not part of bridge v1.

## 13. GC and lifetime

Quickbite and loaded D dependencies share the host D runtime. Any native
reference kept after a call must remain visible to the collector.

Call-scoped buffers and closures are rooted for the call. Durable delegate
callbacks are rooted for the owning backend session. Native-layout storage is
responsible for its own scan policy and stable addresses, as specified by
`ai/plans/value.md` and `ai/plans/bytecode.md`.

The bridge cannot infer whether opaque native code retains a passed pointer or
slice. The remaining escape limitation is recorded in §35.5.

## 14. Native callbacks into backend code

The reverse bridge uses libffi closures. There are two lifetimes:

- explicitly `scope` delegates use a call-scoped closure freed when the
  outbound call returns;
- unscoped top-level `extern(D)` delegates use the session-owned
  `InboundTrampolineRegistry` and may be invoked by a later native call.

The registry owns the writable closure allocation, executable entry, CIF,
callback ID, and rooted backend invoker until session teardown.

Future consumers—`extern(C)` function pointers, class-method callbacks,
TypeInfo/vtable slots, finalizers, and associative-array key methods—must reuse
this registry rather than create a second trampoline system.

## 21. Start at the body-less leaf

Available source is backend work. The bridge begins only when DMD has resolved
a callable with `fbody is null`, or an extern data declaration backed by a
native symbol.

Two native populations remain distinct:

```text
resident symbols
  libc, druntime, Phobos, and already-loaded dependency images;
  resolved through RTLD_DEFAULT

new dependency images
  discovered and built outside the bridge;
  loaded RTLD_NOW | RTLD_GLOBAL before symbol resolution
```

`RTLD_GLOBAL` images and druntime registration are process-lifetime state, so
dependency-image fixtures must use collision-free symbols.

Image loading has one entry point: `quickbite.ffi.loadDependencyImages`.
`backends/native/llvm_jit.d` carries a verbatim private copy; fold it into
the shared entry point.

### 21.1 Shared resolver

The resolver is backend-neutral. It derives the mangled name, linkage,
parameter types, return type, and data-symbol type through the frontend
interface and resolves them against the process.

### 21.2 Native-call chokepoint

Every backend routes native execution through `quickbite.ffi.callNative` and
related member/delegate/ref-return entry points. No backend-local ABI caller is
permitted.

### 21.3 Oracle

`SystemLinker` is the behavior oracle. Every new language-surface fixture runs
the same D source through `SystemLinker` and the backend under test. `Ctfe` is
not an FFI oracle.

## 22. First resident-call milestone

The first resident scalar, pointer, allocation, byte-memory, and libc calls are
landed. This section is retained as a compatibility anchor for historical
references; new work is selected by §36, not by replaying these increments.

### 22.2 Native byte memory

Native allocation pointers can round-trip through supported backends. Memory
indexing and pointer semantics remain backend execution responsibilities, not
special FFI cases.

## 23. Native-layout backends

Native layout removes conversion, not the native call. Bytecode and future IR
backends reuse the same symbol resolver, cached CIF, exception guard, and
trampoline registry while handing frame-slot addresses across the seam.

The shared core does not decide which types a backend can currently compile.
Widening Bytecode from scalar/pointer calls to structs, classes, or callbacks is
owned by `ai/plans/bytecode.md` unless it exposes a shared ABI defect.

## 24. Interpreter bridge milestone

The Interpreter can call resident and dependency-image functions through the
shared bridge. Its adapter lives in
`source/quickbite/backends/interpreter/native_call_adapter.d`. Native storage
is authoritative and the adapter can pass arguments and results by address,
but it still contains buffer-based `RuntimeValue` conversion and writeback
fallbacks. Their deletion is open representation work in `value.md` item 5;
the ABI support milestone below remains complete.

### 24.3 Type and layout mapping

The shared mapper covers scalar widths, pointers, classes, slices, static
arrays, structs, fixed-layout unions, and delegates. DMD size, alignment, and
field offsets are authoritative. A layout the mapper claims must match libffi
after CIF preparation; unsupported layouts are refused before the call.

### 24.5 Completed staging

The historical Interpreter phases—scalar calls, pointers, allocation, native
memory, descriptor-driven aggregates, and dependency images—are complete.
`sys/cstdlib.d` and `backends/ffi/dependency_image.d` hold their oracle
fixtures.

## 34. Supported bridge surface

### 34.1 Completion definition

Bridge v1 is complete when the shared core supports the common body-less ABI
surface needed by the Interpreter, has a real native-layout consumer, and
preserves its declared failure boundaries before native side effects.

This is narrower and more honest than "every possible native leaf". Running a
whole package also depends on source execution and dependency preparation.

### 34.2 Invariants

- `SystemLinker` is the oracle.
- One behavioral contract per approved fixture.
- Native calls use the shared bridge.
- DMD layout is authoritative.
- `extern(D)` explicit arguments are reversed; hidden arguments stay leading.
- `extern(C)` and `extern(C++)` explicit arguments keep source order.
- Writebacks are keyed to source arguments, not ABI slots.
- Unsupported shapes fail before the native call when mechanically knowable.

### 34.3 Completed work order and support matrix

There is no open item in the former FFI work order.

```text
Contract                                             Status
resident C and D scalar/pointer calls                done
typed slice arguments and returns                    done
stack-spilled extern(D) arguments                    done
small and large struct returns                       done
scalar and pointer out/in-out writeback              done
mutating struct receivers and mutable slices         done
nested slices/static arrays/struct aggregates        done
class references, virtual dispatch, interfaces       done
native struct ctor/dtor/postblit                      done
native Exception subclasses and chaining             done
C variadics                                           done
extern(D) delegate callbacks, scoped and durable      done
extern(C++) free and member calls                     done
zero-copy native-layout slots and cached CIFs         done
native data symbols, TLS, and image constructors      done
native ref-return reads and writes                    done
```

Rows marked done describe the tested bridge contract, not every related
language feature. Residuals are explicit in §35.

#### 34.3.1 Generic Type-driven marshalling

Aggregate marshalling recurses from DMD layout through supported leaf kinds.
Static arrays, slices of structs, and nested slice fields do not require
per-shape call code. Associative arrays are refused with an honest diagnostic.

### 34.4–34.6 Slice and argument-order contracts

String and typed slices cross through the native slice descriptor. C arguments
keep source order; D explicit arguments use D ABI order, including stack spill.

### 34.7 Large struct returns

libffi handles hidden memory returns from the DMD-derived struct type. Hidden
return storage precedes explicit `extern(D)` arguments.

### 34.8 Out and in-out parameters

Address-of-local arguments may request writeback. The pointed-to cell is seeded
with the caller's current value before the call, so write-only and in-out APIs
share one mechanism. Bare pointer values remain ordinary input pointers.

### 34.9 Mutating struct receivers

A mutable native struct member receives native `this` storage and writes the
post-call receiver back when the source receiver is addressable.

### 34.10 Mutable slice writeback

The boxed Interpreter copies mutable slice elements into call storage and
copies them back afterward. Native-layout backends may pass stable storage
directly. Retention beyond the documented lifetime is subject to §35.5.

### 34.11 Nested slices and arrays

Struct fields recurse through the same slice, static-array, and struct layout
rules as top-level values.

### 34.12 Class and interface references

Native class and interface references cross as object pointers. Virtual and
interface calls resolve through the runtime table and pass the native receiver
as hidden `this`.

Native class construction remains coupled to the native-layout class-object
phase in `ai/plans/value.md`; it is not a reason to add another boxed-object
workaround.

### 34.13 Constructors, destructors, and postblits

Native struct value construction, `new` struct construction, scope destruction,
and postblit receiver updates are landed. Source-available execution remains a
backend language concern. Native class construction is deferred as described
in §34.12.

### 34.14 Native exceptions

Native `Exception` objects retain their dynamic identity, message, chain, and
object reference across the shared core. The boxed Interpreter reconstructs a
catch value; native-layout backends consume the object reference when ready.
`Error` remains fatal.

### 34.15 Variadics

C `...` calls use `ffi_prep_cif_var`. Typesafe and K&R forms are unsupported,
as are `extern(D)` variadics with their TypeInfo/`_argptr` machinery.

### 34.16 Delegates, callbacks, and closures

The Interpreter supports call-scoped and session-durable top-level
`extern(D)` delegate parameters. Multi-argument D callback order is covered.
Throwing callbacks, class-method callbacks, and C function pointers are future
consumer-triggered work.

### 34.17 extern(C++)

Free and member calls over the supported value surface resolve by C++ mangled
name and use C++ argument order. C++ exceptions, multiple inheritance, RTTI,
and template ABI edge cases are outside bridge v1.

### 34.18 After bridge v1

Do not create another speculative FFI ladder. Continue through the owning
consumer plan and return here only when the shared bridge is the demonstrated
limitation.

Dependency discovery/build/caching belongs to `ai/plans/dub-deps.md`.
Interpreter representation belongs to `ai/plans/value.md`. Bytecode call-site
coverage and VM re-entry belong to `ai/plans/bytecode.md`.

## 35. Known boundaries and completed corrective work

### 35.1 Zero-copy seam and CIF cache

**Status: done.** Native-layout backends can hand stable argument and result
addresses to the shared core. Buffer fallback remains for boxed backends and
narrow results that require libffi padding. Non-variadic CIFs are cached;
variadic and raw native-delegate calls prepare per call as required.

### 35.2 Data symbols and dependency-image initialization

**Status: done except for the Linux cross-image constructor pin.** The
Interpreter resolves extern data symbols by mangled name and reads/writes them
through the declared type. Covered shapes include scalar widths, pointers,
structs, static arrays, slices, nested slice fields, `__gshared`, TLS, and
DT_NEEDED ordering.

The explicit sequential-`RTLD_GLOBAL` cross-image constructor fixture remains
registered outside Linux. On Ubuntu, both the Interpreter and LLVMJit cases
fail even in fresh processes, so their Linux registrations are deferred. The
next step is a minimal Ubuntu/DMD shared-library reproduction that distinguishes
fixture construction, the SystemLinker oracle, and dependency-image loading
before changing backend production ordering.

#### 35.2a Data-symbol resolution

`resolveDataSymbol` derives the mangled name through the frontend and uses
`dlsym(RTLD_DEFAULT, ...)`. A resolved address is reified or materialized
through the declaration's DMD type; native memory remains the source of truth.

### 35.3 Native Throwable fidelity

**Status: bridge contract done.** `NativeCallException` retains the native
`Throwable`, object pointer, dynamic class, message, and chain. Subclass fields
are observable by the boxed Interpreter.

Stack traces and rethrowing the exact native object through backend execution
remain future native-layout exception work.

### 35.4 Durable inbound trampolines

**Status: first consumer done.** `InboundTrampolineRegistry` owns durable
libffi closures and callback roots for an Interpreter session. Unscoped
top-level `extern(D)` delegates use it; explicitly `scope` delegates remain
call-scoped.

The next extension must be selected by a real consumer. Likely consumers are a
Bytecode runtime slot, an `extern(C)` function-pointer callback, a finalizer, or
an associative-array key method. They must extend this registry rather than
forking it.

### 35.5 Escape lifetime is fail-open

Opaque native code may retain a passed pointer or slice, and the bridge cannot
infer that fact. Call-scoped storage therefore relies on the API's lifetime
contract. A violating API can produce later use-after-free rather than a named
diagnostic.

If a real package exposes this, choose among session-rooted non-moving storage,
stable backend-owned storage, or a narrow API annotation. Do not claim general
escape analysis.

### 35.6 Out-cell input preservation

**Status: fixed.** Out/in-out storage is initialized from the caller's current
value before native execution, then written back after the call.

### 35.7 Unions and packed layouts

**Status: safe boundary established.** Fixed-layout union returns and opaque
union out cells are supported where their bytes are reproducible. Boxed
by-value union arguments and incompatible packed layouts are refused before
the call rather than failing through an assertion.

### 35.8 Type mapper and marshaller agreement

**Status: fixed.** Each backend owns representability through
`NativeMarshaller.canRepresent`; the core checks it before native execution.
Native delegate returns are reified as callable opaque values.

### 35.9 Native ref returns

**Status: fixed.** Ref returns use a pointer ABI. Reads dereference and reify
the returned address; assignments marshal through that address.

### 35.10 Union out cells

**Status: fixed.** Union-typed pthread-style out pointers cross as opaque native
buffers when their fixed-size members can be snapshotted safely. This does not
enable boxed by-value union arguments.

### 35.11 Scalar locals viewed as byte buffers

**Status: fixed for the Interpreter path.** Taking a scalar local's address,
slicing it as bytes, and passing it to a native fill operation preserves alias
and writeback, covering the `getrandom` entropy path.

## 36. Live work-selection order

When asked to continue FFI work, use this order:

1. Measure a real consumer. For the Interpreter, follow
   `interpreter.md`'s next-package loop. For Bytecode, follow its native-runtime
   backlog and existing oracle-backed promotions.
2. Classify the first mismatch:
   - available-source execution -> the backend plan;
   - representation or object identity -> `value.md` or `bytecode.md`;
   - dependency discovery/build/load -> `dub-deps.md`;
   - shared symbol, ABI, exception-guard, or trampoline failure -> this plan.
3. Distill one `SystemLinker`-backed behavior fixture and obtain approval before
   adding or changing it.
4. Implement the smallest shared bridge change, keeping backend conversion
   behind `NativeMarshaller`.
5. Run `ninja bin/ut` and `bin/ut --random`; then update only this plan's status
   and boundary summary.

There is deliberately no preselected next FFI feature. The next bridge change
must be pulled by evidence, not by section order.
