# Native-Layout FFI

## Goal

Provide exhaustive outbound native calls for the x86-64 SysV ABI surface used
by D's `extern(C)`, `extern(D)`, and `extern(C++)` functions. Exhaustive means
that the bridge composes every native type and calling-convention feature in
that platform surface, including vectors, aggregate classification, hidden
operands, register pressure, variadics, and C++ invisible references. It does
not mean supporting a partial list selected by the first Bytecode consumers.

Bytecode values already occupy stable storage in the host's native D layout.
The bridge therefore accepts typed addresses, invokes a resolved callable, and
writes the result into caller-provided typed storage. It never converts a
backend value representation into an ABI representation because there is only
one representation.

## Module boundary

```text
quickbite.ffi.libffi   declaration-only libffi binding
quickbite.ffi.ffi      native-layout call mechanism
quickbite.ffi.sysv_call private vector-capable x86-64 SysV transport
```

`quickbite.ffi.libffi` stays in its current module. It contains only translated
libffi declarations, constants, and platform assertions. It contains no D type
mapping, symbol policy, CIF cache, backend concept, or value conversion.
`quickbite.ffi.sysv_call` contains only the private invocation frame and
architecture-specific register transfer needed when libffi cannot express a
vector call.

`quickbite.ffi.ffi` is the only native-call mechanism. A second one may not be
reintroduced as a fallback for a backend that finds address-only storage
inconvenient, nor as a staging area for a shape this one cannot yet compose.

## Public contract

One invocation supplies:

```text
callable:       native address, semantic TypeFunction, compiler-ABI
                provenance, and declaration semantics when C++ lowering
                depends on the declared special member or POD status
arguments:      source-order static types and addresses of native values
receiver:       optional native hidden-argument value address
result:         static type and writable native destination address
D variadics:    optional address of caller-owned compiler-specific metadata
```

The API is a small collection of structs and one free call function. Do not
introduce a class, backend interface, visitor, marshaller, or callback
registry.

The callable's semantically analysed DMD `TypeFunction` is the authoritative
signature. The bridge derives linkage, return type, fixed parameter types,
`ref`/`out` policy, ref-return policy, and variadic shape from it rather than
duplicating those properties in flags or parallel arrays. The supplied typed
addresses are checked against that signature before calling native code.

C++ constructors, destructors, non-POD parameters, and non-POD results
additionally require declaration semantics because a `TypeFunction` alone
does not encode their invisible-reference policy.

All linkages first lower through one semantic-to-physical-call contract. That
lowering decides explicit argument order, ignored empty arguments, direct or
indirect parameters, receiver placement, variadic metadata placement, hidden
result placement, and physical result policy. Native transports consume that
same lowered call. Transport selection must not duplicate or amend semantic
lowering rules.

The boundary obeys these invariants:

- Every supplied address already points at the value's native D
  representation, with its native size and alignment.
- A dynamic array is already `{length, ptr}`. The bridge never reads,
  rearranges, copies, or repairs its words.
- A struct, static array, class reference, pointer, delegate, and scalar cross
  in their ordinary native representation.
- A `ref` or `out` argument designates the caller's authoritative storage.
  A pointer-value cell is private call metadata; it points directly at that
  storage, so native writes require no pointee copy or post-call writeback.
- A ref return writes the returned native pointer into caller-provided
  pointer-sized storage. The bridge does not copy the referenced value.
- A result is written directly into storage allocated for its static D type.
- Caller-provided D variadic metadata is already in the defining compiler's
  native representation. DMD receives its `TypeInfo_Tuple` class reference;
  LDC receives its `TypeInfo[]` descriptor. The bridge neither constructs nor
  inspects either value.
- Hidden result, receiver, invisible-reference, and `ref`/`out` pointers are
  physical call operands. A private pointer cell may name existing storage,
  but it never owns a copy of the pointed-to value.
- An rvalue without an existing address is first evaluated into a typed
  backend temporary. Creating that ordinary value is backend evaluation, not
  FFI marshalling.
- Native call metadata contains pointers to existing native values. Reordering
  those pointers or placing their bytes in ABI registers and stack slots does
  not change the values' representation.

The package must not expose or contain:

```text
Value or RuntimeValue
NativeMarshaller or another backend conversion interface
marshal, unmarshal, materialize, reify, fill, or writeback operations
aggregate reconstruction
mutable-slice copy-in/copy-out
slice word swapping or any other representation repair
```

An unavoidable libffi scratch slot is not representation conversion. For
example, libffi may require a return buffer widened to `ffi_arg` for a narrow
scalar result. Such scratch stays private, is justified at its allocation
site by the libffi contract, and is copied only at the scalar's native width.
It must not become a generic byte-buffer seam.

## ABI provenance

`LINK.d` identifies D linkage; it does not identify one D calling convention.
DMD and LDC pass explicit `extern(D)` arguments in opposite orders. A resolved
callable therefore carries the compiler ABI of the code that defines it.

The bridge derives explicit-argument pointer order, hidden-argument placement,
true-D-variadic metadata shape, and any cache key from that provenance. It
never globally assumes DMD order or LDC order. `extern(C)` and `extern(C++)`
use their x86-64 SysV platform order; the callable's D compiler provenance is
irrelevant to their explicit argument order. C++ declaration semantics remain
callable-specific and must not be guessed from a globally selected C++ mode.

Resident host symbols use the host compiler ABI. A symbol resolved from a
dependency image uses the ABI recorded for that image. Image preparation and
caching must preserve that identity; see `dependency-image-contract.md` and
`dub-deps.md`.

ABI adaptation changes only call metadata, operand order, and physical
register or stack placement. It never changes value layout.

On x86-64 SysV, ordinary unions and irregular non-vector aggregates use
pre-sized libffi classification witnesses. Their INTEGER, SSE, X87, and
MEMORY classes are derived recursively from semantic member types at their DMD
offsets and merged per eightbyte. Witness elements are metadata only: they
neither select a dominant union member nor describe bytes to copy.

libffi cannot faithfully describe vector/SSEUP classes. Any call whose
signature or supplied variadic tail contains a vector therefore uses the
private x86-64 SysV transport. It consumes DMD's SysV classification, places
the lowered physical operands in integer, vector, or stack locations, sets the
variadic SSE-register count, invokes the address, and stores returned register
classes directly into result storage. AVX is required only when a 256-bit
vector participates in the call. This transport is an ABI call mechanism, not
a value conversion path.

## Ownership

`quickbite.ffi.ffi` owns only native-call mechanics:

- symbol resolution or consumption of an already-resolved callable;
- semantic-to-physical call lowering;
- DMD-type-to-`ffi_type` mapping for non-vector calls;
- x86-64 SysV register and stack placement for vector-containing calls;
- CIF preparation and, when useful, caching;
- ordering native value addresses for the callable's ABI;
- native invocation through libffi or the private SysV transport; and
- propagation of native exceptions without translation at this boundary.

Bytecode owns evaluation, storage, lifetimes, typed temporaries, receiver
selection, and the address of every argument and result. The bridge never asks
Bytecode to describe how to convert a value.

Dependency discovery, image construction, and cache invalidation remain in
the dependency-image plans. Loading an image may be a small shared utility,
but it does not expand the call API or erase the image's ABI provenance.

## Adjacent work

Inbound callbacks are a separate direction of travel and are not part of the
outbound call mechanism. Their eventual design must preserve typed-address
storage and callable-specific ABI provenance rather than growing a marshalling
seam into this API.

Symbol resolution, dependency images, and any future CIF cache must preserve
the callable's compiler-ABI and declaration provenance without changing the
call boundary.

## Completion criteria

- `quickbite.ffi.libffi` remains declaration-only.
- `quickbite.ffi.ffi` imports no backend and exposes no backend conversion
  interface.
- Neither the public API nor its implementation contains slice swapping or
  representation repair.
- Native arguments, receivers, `ref`/`out` values, and results cross as typed
  addresses to existing storage.
- The semantic-to-physical lowering is shared by libffi and vector-containing
  native calls.
- `extern(D)` argument order, receiver and hidden-result placement, and true
  variadic metadata use the defining callable's DMD or LDC ABI provenance.
- `extern(C++)` free functions, members, constructors, destructors,
  references, and non-POD invisible references follow their declaration
  semantics.
- Fixed, C/K&R/C++ variadic, true D variadic, typesafe D variadic, and lazy
  parameters compose with scalars, descriptors, aggregates, unions, empty
  aggregates, 128-bit integers, X87 values, 128- and 256-bit vectors, hidden
  receivers, hidden results, register exhaustion, and stack placement.
- Native exceptions cross the outbound boundary untouched.
- The exhaustive x86-64 SysV outbound matrix agrees with compiled-D oracles
  under both DMD- and LDC-hosted execution where compiler provenance applies.

The bridge is not complete merely because a current backend happens to use a
subset of it. It is complete when the exhaustive x86-64 SysV outbound contract
above is proved without adding representation conversion. Other platform ABIs
and inbound callbacks require their own explicit contracts.
