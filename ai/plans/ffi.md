# Native-Layout FFI

## Goal

Build the smallest native-call mechanism needed by the Bytecode backend.
Bytecode values already occupy stable storage in the host's native D layout.
The bridge therefore accepts typed addresses, invokes a resolved callable, and
writes the result into caller-provided typed storage. It never converts a
backend value representation into an ABI representation because there is only
one representation.

The existing marshaller-based implementation lives in
`quickbite.ffi.oldffi` so the Interpreter and its other current consumers
remain operational during migration. It is not the starting point for this
design. Do not copy its interfaces, work order, or supported-shape taxonomy
into the new package.

## Module boundary

```text
quickbite.ffi.libffi   declaration-only libffi binding
quickbite.ffi.oldffi   legacy marshaller-based implementation
quickbite.ffi.ffi      new native-layout call mechanism
```

`quickbite.ffi.libffi` stays in its current module. It contains only translated
libffi declarations, constants, and platform assertions. It contains no D type
mapping, symbol policy, CIF cache, backend concept, or value conversion. Both
FFI implementations may import it.

`quickbite.ffi.oldffi` is migration debt, not a second supported design.
Existing consumers may remain on it temporarily. No new backend may import it,
and it gains no new feature unless a correctness fix is required to reach the
Interpreter's Cerealed gate. Its remaining consumers and deletion conditions
belong to `interpreter.md` and `value.md`; it needs no architecture plan of its
own.

## Public contract

Conceptually, one invocation supplies:

```text
callable:       native address, linkage, and compiler-ABI provenance
arguments:      source-order static types and addresses of native values
receiver:       optional native hidden-argument value address
result:         static type and writable native destination address
```

The exact D API should be the smallest collection of structs and free
functions that supports the first Bytecode call. Do not introduce a class,
backend interface, visitor, marshaller, or callback registry in anticipation
of later call shapes.

The boundary obeys these invariants:

- Every supplied address already points at the value's native D
  representation, with its native size and alignment.
- A dynamic array is already `{length, ptr}`. The bridge never reads,
  rearranges, copies, or repairs its words.
- A struct, static array, class reference, pointer, delegate, and scalar cross
  in their ordinary native representation.
- A `ref` or `out` argument designates the caller's authoritative storage.
  Native writes require no cell reconstruction or post-call writeback.
- A result is written directly into storage allocated for its static D type.
- An rvalue without an existing address is first evaluated into a typed
  backend temporary. Creating that ordinary value is backend evaluation, not
  FFI marshalling.
- The argument-address array required by libffi contains pointers to existing
  native values. Reordering that pointer array for a calling convention does
  not move or transform the values.

The new package must not expose or contain:

```text
Value or RuntimeValue
NativeMarshaller or another backend conversion interface
marshal, unmarshal, materialize, reify, fill, or writeback operations
aggregate reconstruction
mutable-slice copy-in/copy-out
slice word swapping or any other representation repair
compatibility fallbacks to quickbite.ffi.oldffi
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
callback entry shape, and any CIF cache key from that provenance. It never
globally assumes DMD order or LDC order. `extern(C)` uses the platform C ABI;
the callable's D compiler provenance is irrelevant to its explicit argument
order.

Resident host symbols use the host compiler ABI. A symbol resolved from a
dependency image uses the ABI recorded for that image. Image preparation and
caching must preserve that identity; see `dependency-image-contract.md` and
`dub-deps.md`.

ABI adaptation changes only libffi metadata and the ordering of pointers in
the argument-address array. It never changes value layout.

## Ownership

`quickbite.ffi.ffi` owns only native-call mechanics:

- symbol resolution or consumption of an already-resolved callable;
- DMD-type-to-`ffi_type` mapping;
- CIF preparation and, when useful, caching;
- ordering native value addresses for the callable's ABI;
- `ffi_call`; and
- narrowly required exception or inbound-entry mechanics when an enabled
  Bytecode behavior first demands them.

Bytecode owns evaluation, storage, lifetimes, typed temporaries, receiver
selection, and the address of every argument and result. The bridge never asks
Bytecode to describe how to convert a value.

Dependency discovery, image construction, and cache invalidation remain in
the dependency-image plans. Loading an image may be a small shared utility,
but it does not expand the call API or erase the image's ABI provenance.

## Work order

1. Implement one address-only outbound call sufficient for the first existing
   Bytecode native-call behavior. Support only the linkage and value shapes
   that behavior requires.
2. Carry compiler-ABI provenance through symbol resolution, explicit-argument
   address ordering, and CIF cache identity. Exercise both DMD- and LDC-defined
   D callables rather than selecting one compiler globally.
3. Add another call shape only when an enabled, `SystemLinker`-backed Bytecode
   behavior requires it. Keep each addition address-only.

Backend migration is not work in this plan. `bytecode.md` owns Bytecode's
native-layout correction, legacy-marshaller deletion, and switch to the new
module. `value.md` owns the later Interpreter migration and deletion of
`quickbite.ffi.oldffi`.

## Completion criteria

- `quickbite.ffi.libffi` remains declaration-only.
- `quickbite.ffi.ffi` imports no backend and exposes no backend conversion
  interface.
- Neither the new public API nor its implementation contains slice swapping,
  representation repair, or a compatibility path to `quickbite.ffi.oldffi`.
- Native arguments, receivers, `ref`/`out` values, and results cross as typed
  addresses to existing storage.
- `extern(D)` calls use the defining callable's DMD or LDC ABI provenance.
- The demanded native call shapes agree with their compiled-D oracle under
  both DMD- and LDC-hosted execution where applicable.

The bridge is not complete merely because it can imitate every feature of
`quickbite.ffi.oldffi`. It is complete when Bytecode's demanded native surface
is correct with this smaller contract. Unsupported future shapes remain absent
until real Bytecode execution reaches them.
