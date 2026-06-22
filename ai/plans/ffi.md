# Design: Native Dependency Integration for Quickbite Backends

## 1. Goal

The goal is to minimize the latency of the normal development loop:

```text
edit project code -> run unittests -> get result
```

Quickbite backends exist to avoid the cost of repeatedly compiling and
linking the project under test through the normal native toolchain.
Some backends interpret an internal representation, some walk analysed
DMD trees, and later backends may execute generated native code.

However, real D projects usually depend on dub packages, Phobos,
druntime, C libraries, OS services, and other native facilities.
Reimplementing or emulating those dependencies inside every backend
would be both expensive and semantically fragile.

The intended design is therefore a mixed-mode execution model:

```text
project-under-test code: backend-specific artifact
dub D dependencies: native code, compiled and cached ahead of time
runtime/native environment: discovered, validated, and recorded ahead of time
interop boundary: generated wrapper thunks
runtime: same process, same druntime, same GC, same OS access
```

Dependency-side work may be expensive, but it must be moved out of the
hot edit-test path.

Starting point. The irreducible reason this document exists is **not** the
dub-dependency native image described in §3–§20, but the body-less native
leaf that every non-trivial library bottoms out in (libc, druntime, Phobos).
The implementation therefore starts there. See §21 for the reframing and the
shared body-less resolver, and §22 for the first test. §3–§20 describe the
later dub-dependency-image design and are deferred.

## 2. Non-goals

This design does not attempt to:

```text
- load arbitrary .o files directly;
- implement a D linker inside every backend;
- emulate filesystem, sockets, threads, GC, TLS, or druntime behavior;
- make dependency execution hermetic by default;
- call arbitrary extern(D) functions directly from backend code;
- make all dub dependency code native purely because it came from a dub package.
```

The design is optimized for fast feedback, not full process isolation.

The direct-call non-goal applies to backends with a boxed value
representation. It is superseded for native-layout backends — see §23.

## 3. High-level architecture

The system consists of two paths: a cold dependency preparation path
and a hot project execution path.

```text
Cold path, rarely run:
  dub resolve
  discover compiler/runtime/native library availability
  compile D dependencies native
  generate dependency/native wrappers
  link/write native dependency image
  cache manifests, environment records, and metadata

Hot path, per edit:
  check cached dependency image and native environment freshness
  start the Quickbite host process
  load cached native dependency image
  initialize generated wrapper table
  parse/sema changed project modules
  emit or prepare the backend-specific test artifact
  execute selected unittests through the active backend
  call cached native dependency image when needed
```

The cold path runs when dependencies change, typically after:

```text
dub upgrade
dub add
dub remove
dependency source changes
compiler/version flag changes
ABI-affecting configuration changes
runtime library changes
native package-manager library changes
pkg-config or linker flag changes
loader search-path changes
```

The hot path should not invoke dub, compile dependencies, query
package managers, run `pkg-config`, generate wrappers, link native
code, or resolve native symbols by name.

## 4. Native dependency image and environment

Dub D dependencies are compiled into a cached native image.

Possible forms:

```text
libquickbite_deps_<hash>.so
libquickbite_deps_<hash>.dylib
quickbite_deps_<hash>.dll
linked native object bundle
```

The preferred model is a shared library loaded by the Quickbite host
process.

Not every native input is compiled by Quickbite. Phobos, druntime,
libc, compiler support libraries, and libraries installed by the
system package manager are part of the native environment. Quickbite
should discover and record them during preparation, then treat their
recorded ABI and loader data as part of the cached execution surface.

The environment manifest should include:

```text
druntime and Phobos library identity and load path
C runtime identity
compiler support libraries
external native library names, SONAMEs, and resolved paths
pkg-config versions and emitted cflags/libs, where used
linker search paths and rpath/runpath settings
loader-affecting environment settings
package-manager package names and versions, where cheaply available
```

This manifest is not a promise of hermeticity. It is a freshness and
diagnostic record so the hot path can detect obvious stale native
state without rediscovering the world.

The cache key should include at least:

```text
dub.selections.json
dependency source hashes
compiler identity and version
target triple
compiler flags
version identifiers
debug/release mode
static import path configuration
druntime and Phobos ABI identity
C runtime identity
external native library ABI/load identity
pkg-config outputs used for compilation or loading
linker and loader search-path configuration
callable identity set and lowering manifest
wrapper ABI version
Quickbite dependency ABI version
```

The dependency image cache key should not include ordinary project
source files under edit. Mixed template instantiations are separate:
if Quickbite caches a native instantiation that depends on project
code, that artifact needs its own cache key covering the instantiated
callable identity, template arguments, project type and symbol
identities, compile-time values, relevant `version` and `debug`
context, and the wrapper lowering contract.

The output directory may look like:

```text
.quickbite/
  deps/
    <hash>/
      libquickbite_deps_<hash>.so
      wrappers.d
      wrappers.o
      wrapper_manifest.qb
      native_environment.qb
      abi_manifest.qb
      dependency_summary.qb
      build_manifest.qb
```

## 5. Same-process execution

Dependencies live in the same process as the active backend.

This gives dependency code normal access to:

```text
druntime
Phobos
GC
TLS
module constructors
filesystem
sockets
C libraries
package-manager installed native libraries
threads
environment variables
process APIs
```

This matches ordinary compiled D execution much more closely than a
sandboxed or emulated dependency model.

The host must load dependency images through platform- and
druntime-supported mechanisms that run native library constructors,
D module constructors, TLS setup, and runtime registration before any
wrapper thunk is called. Generated wrapper table initialization happens
after dependency image initialization succeeds.

The MVP should treat dependency image unloading and destructor behavior
as process-exit cleanup only. Explicit unloading, reloading, and
destructor sequencing are later extensions.

The host process contains:

```text
quickbite-host executable
  ├─ druntime / Phobos
  ├─ libc / platform libraries
  ├─ external native libraries
  ├─ active Quickbite backend
  ├─ dependency native image
  ├─ generated wrapper table
  └─ backend artifact for project-under-test
```

The main runtime transition is:

```text
backend execution engine
  -> generated native wrapper thunk
      -> real compiled D dependency function
```

## 6. Process model

The current design assumes an ordinary Quickbite host process for each
`quickbite test` invocation. A persistent host daemon is a future
latency aspiration only.

## 7. Wrapper-based native calls

Backends should not call arbitrary dependency functions directly.

Instead, dependency calls go through generated wrapper thunks. The
wrapper is responsible for converting backend values into D values,
calling the real dependency function, catching exceptions, and
converting the result back into the backend representation.

Generic wrapper shape:

```d
extern(C)
QBValue qb_dep_37(QBContext* ctx, QBValue* args, size_t nargs)
{
    try
    {
        auto path = args[0].toDString();
        auto result = package.foo.readConfig(path);
        return QBValue.from(ctx, result);
    }
    catch (Exception e)
    {
        return ctx.throwNative(e);
    }
    catch (Error e)
    {
        return ctx.failNative(e);
    }
}
```

Each backend maps call sites to numeric wrapper IDs in its own
representation:

```text
bytecode:     CALL_DEP 37, argc=1
IR:           NativeCall id=37, argc=1
tree walker:  dispatch wrapper id 37 from the analysed call
codegen:      call generated stub or import entry for wrapper id 37
```

Runtime call path:

```d
auto thunk = ctx.nativeThunks[37];
auto result = thunk(ctx, args.ptr, args.length);
```

There should be no per-wrapper string lookup, symbol lookup,
reflection, or signature decoding in the hot path.

The value-conversion half of this wrapper contract is superseded for
native-layout backends (§23); the exception-guard half (§12) survives
for every backend.

## 8. Generic versus specialized thunks

Two wrapper tiers are useful.

### 8.1 Generic wrappers

Generic wrappers use boxed `QBValue` arguments and return a boxed
`QBValue`.

They are appropriate for:

```text
filesystem calls
network calls
database calls
object construction
error paths
large dependency functions
rarely executed APIs
opaque native values
```

The overhead is usually irrelevant compared with OS or library work.

### 8.2 Specialized wrappers

Specialized wrappers avoid boxing and dynamic conversion for hot
simple calls.

Example:

```d
extern(C)
int qb_dep_91_i32_i32_to_i32(QBContext* ctx, int a, int b)
{
    return dep.fastAdd(a, b);
}
```

Backends may use specialized call forms:

```text
bytecode: CALL_DEP_I32_I32_TO_I32 91
IR:       NativeCallI32I32ToI32 id=91
codegen:  direct call to qb_dep_91_i32_i32_to_i32
```

Specialized wrappers are useful for:

```text
small math functions
hashing steps
small parser helpers
string/array primitives
dependency functions inside loops
```

The system can start with generic wrappers and promote hot dependency
call sites after profiling.

## 9. Avoiding hot boundary crossings

The main performance danger is not a single native call. It is
repeated crossing in tight loops.

Bad shape:

```d
foreach (x; xs)
    ys ~= dep.processOne(x);
```

Better shapes:

```d
auto ys = dep.processAll(xs);
```

or:

```text
execute processOne in the active backend if its source/body is available
and simple
```

The compiler should detect dependency calls inside loops and classify
them carefully.

Possible policies:

```text
small dependency function + body available:
  execute through the active backend or inline

small dependency function + body unavailable:
  specialized native thunk

large or side-effecting dependency function:
  generic native thunk

OS-facing dependency function:
  generic native thunk
```

## 10. Dependency classification

The system should not classify execution purely by package ownership.

Bad rule:

```text
if module belongs to dub dependency:
    execute native
else:
    execute through the active backend
```

Better rule:

```text
if concrete function body should be executed by the active backend:
    lower, interpret, or compile it through that backend

elif concrete function has cached native implementation:
    call wrapper thunk

elif function is template-instantiated with project code:
    handle the instantiation through the active backend or cache it separately

else:
    unsupported or native fallback
```

D templates make this distinction necessary.

Example:

```d
auto ys = xs.map!(x => x + 1);
```

This is not merely a precompiled dependency call. The instantiated
body contains project code via the lambda. It should usually be
handled by the active backend or as a separately cached specialization,
not as a simple call into precompiled dependency code.

Separately cached specializations are not part of the ordinary
dependency image. They are project-sensitive artifacts with their own
freshness rules.

By contrast:

```d
auto text = readText("foo.txt");
```

can reasonably be a native dependency call.

## 11. Value representation across the boundary

Values crossing the backend/native boundary fall into three categories.

### 11.1 Plain ABI values

These can be passed directly or cheaply converted:

```text
int
long
bool
float
double
char
enum
pointers, where permitted
```

### 11.2 Bridgeable D values

These require explicit conversion and lifetime rules:

```text
string
T[]
const(char)[]
simple structs
```

Example rules:

```text
backend string -> native string valid for duration of call, or GC-owned copy
native string -> backend-owned copy, unless explicitly borrowed
backend array -> native slice with clear ownership/lifetime
native array -> backend-owned copy or native handle, depending on type
```

Mutable aliases are separate from ordinary array/string bridging. The
MVP should treat basic dynamic arrays as copy/owned values or immutable
borrows only. It may reject mutable slices, pointers, `ref` returns, and
any native API that can retain or write through a backend-owned
reference. Later support needs an explicit borrow, writeback, pinning,
and rooting contract before those calls are accepted.

### 11.3 Opaque native values

Backends should not inspect complex native values such as:

```text
File
Socket
Regex
class objects
interfaces
delegates
complex structs
types with destructors/invariants
allocator-backed containers
```

These should be represented as native handles:

```d
struct NativeHandle
{
    void* ptr;
    TypeInfo type;
    void function(void*) destroy;
}
```

Method calls on native handles dispatch back through wrappers.

Example:

```d
auto f = File("foo.txt", "r");
auto line = f.readln();
```

The active backend represents `f` as an opaque handle. `readln`
becomes another native wrapper call that receives the handle.

## 12. Exceptions

Native D code may throw. Exceptions should not initially unwind
through arbitrary backend interpreter frames.

Wrapper boundary rule:

```d
try
{
    auto r = realDependencyFunction(...);
    return QBValue.from(ctx, r);
}
catch (Exception e)
{
    return ctx.throwNative(e);
}
catch (Error e)
{
    return ctx.failNative(e);
}
```

The active backend then maps the native exception into its own
exception state. Native `Error` values are different: they indicate
assertion failure, runtime failure, or another fatal condition. Wrappers
may catch them to attach diagnostics, but should not turn them into
ordinary backend pending exceptions.

Initial support:

```text
native Exception -> backend pending exception
native Error -> fatal native failure
backend handles or reports normal exceptions
```

Later support:

```text
backend exception -> native D Throwable when native code calls back into backend
```

The second direction is harder and can be deferred.

## 13. GC and lifetime

Because the Quickbite host and native dependencies share one D
runtime, native GC allocation works normally.

However, backend storage must not hide GC references from the collector.

If backend values can contain D GC pointers, then one of the following
must be true:

```text
backend frames are allocated in GC-scanned memory
GC references are stored in GC-managed objects
backend registers/stacks are registered as roots
backend avoids raw GC pointers in unscanned malloc memory
```

This applies to:

```text
string
dynamic arrays
class references
delegates
closures
native handles pointing to GC objects
```

A conservative initial design should copy simple data into backend-owned
representations and use GC-visible handle tables for native
references.

## 14. Native callbacks into backend code

Some dependency APIs accept callbacks:

```d
sort!((a, b) => ...)
array.map!(x => ...)
eventLoop.setTimer(..., delegate { ... })
```

This requires a reverse bridge:

```text
native dependency
  -> callback trampoline
      -> backend invokes project closure
```

Initial implementation may reject callbacks/delegates crossing into
native dependency code.

Eventually, callback support requires generated native trampolines and
a backend closure registry keyed by callback ID. D delegates carry both
a function pointer and a context pointer, so the bridge must define the
delegate context lifetime, keep backend closure state GC-visible, and
reject callbacks that may outlive the current test or backend execution
context unless a durable owner is provided.

The hard cases are template-heavy D APIs where the callback is part of
the instantiated dependency code. These may be better handled by
executing the instantiated template body through the active backend
instead of using native callbacks.

## 15. Build pipeline

### 15.1 Preparation command

A command such as:

```text
quickbite prepare
```

performs the cold dependency work:

```text
1. run or query dub dependency resolution
2. discover compiler runtime, Phobos, druntime, libc, and native libraries
3. compute dependency and native-environment cache key
4. check for existing dependency image and environment manifest
5. compile dub D dependencies natively if needed
6. analyze reachable dependency call boundaries
7. generate wrapper source
8. compile wrappers
9. link dependency image against recorded native inputs
10. write wrapper, ABI, and native environment manifests
```

### 15.2 Test command

A command such as:

```text
quickbite test
```

performs the hot path:

```text
1. check dependency image and native environment freshness
2. start the Quickbite host process
3. load and initialize the cached dependency image
4. initialize the generated wrapper table
5. parse/sema changed project modules
6. prepare the backend-specific execution artifact
7. run selected unittests through the active backend
8. report result
```

If dependencies are stale, `quickbite test` may either:

```text
- fail with “run quickbite prepare”;
- automatically rebuild the dependency image;
- rebuild only if configured to do so.
```

For minimum latency, dependency rebuilds should be explicit or at
least clearly reported.

## 16. Wrapper manifest

The dependency preparation phase emits a wrapper manifest mapping
concrete callable instances to numeric IDs. Source-level names are
diagnostic metadata only; they are not stable enough to key wrapper
selection.

Each wrapper record should include:

```text
numeric wrapper ID
frontend symbol identity, or native mangled symbol if the frontend cannot
  provide a stable identity
module and fully qualified diagnostic name
overload signature after semantic analysis
instantiated template arguments, where applicable
ABI, calling convention, linkage, and mangling
dependency image and native environment hash
parameter and return lowering
ownership and lifetime policy
wrapper kind
wrapper thunk symbol
```

This matters for overloads, templates, aliases, UFCS, `version` and
`debug` conditions, module-private symbols, and extern linkage. All of
that resolution happens during preparation. The hot path consumes the
numeric ID and already-lowered argument contract.

Wrapper generation must obey normal D visibility rules. A wrapper may
target a callable visible from the generated wrapper module. Reaching a
`private` or `package` symbol requires deliberately generating the
wrapper inside the defining module or package, or using a
dependency-authored exported registration surface. Source-level names
are diagnostic metadata; they do not imply access bypass.

Example:

```text
wrapper 37:
  diagnosticName: package.foo.readConfig
  symbolIdentity: frontend-symbol:<opaque-id>
  overload: readConfig(string)
  kind: generic
  abi: extern(D)
  parameters: [string -> borrowed native string]
  return: Config -> native handle
  thunk: qb_dep_37
  image: libquickbite_deps_<hash>.so

wrapper 91:
  diagnosticName: dep.fastAdd
  symbolIdentity: _D3dep7fastAddFiiZi
  overload: fastAdd(int, int)
  kind: specialized
  abi: extern(D)
  parameters: [int -> i32, int -> i32]
  return: int -> i32
  thunk: qb_dep_91_i32_i32_to_i32
  image: libquickbite_deps_<hash>.so
```

Backends use this manifest according to their execution model:

```text
bytecode: CALL_DEP 37
IR:       NativeCall id=37
walker:   dispatch wrapper id 37
codegen:  call generated wrapper stub
```

The runtime uses the same manifest to initialize the thunk table. A
fresh host process should not perform one lookup per wrapper. The
dependency image should expose one generated registration entry point
or one generated table symbol that returns the complete thunk table in
wrapper-ID order.

## 17. Hot-path invariant

The hot edit-test path must avoid:

```text
dub invocation
package-manager queries
pkg-config queries
dependency native compilation
dependency linking
wrapper generation
per-wrapper symbol lookup by name
```

The hot path should be approximately:

```text
changed D source
  -> load cached dependency image and generated thunk table
  -> dmd frontend parse/sema
  -> active backend preparation
  -> active backend execution
  -> cached native calls by integer ID
```

This is the shape that can plausibly beat normal `dub test`.

## 18. Initial MVP

The first useful implementation should support:

```text
same-process native host
dependency shared library cache
native environment manifest for druntime, Phobos, libc, and native libraries
loader/link path validation
generated generic wrappers
numeric wrapper IDs
at least one backend-integrated project execution path
scalars: int, long, bool, float, double
strings
basic dynamic arrays
opaque native handles
native Exception -> backend exception state
fatal native Error diagnostics
explicit dependency prepare step
```

The MVP may reject:

```text
callbacks from native into backend-managed code
delegates crossing the boundary
complex structs by value
ref/out parameters
ref returns
mutable slices or pointers crossing the boundary
native code calling backend-managed functions
direct extern(D) ABI calls without wrappers
template instantiations requiring native/project mixed code
```

## 19. Later extensions

After the MVP:

```text
specialized unboxed wrappers
profiling-based wrapper promotion
backend-local execution of small dependency functions
loop-aware native call avoidance
struct field bridging
ref/out support
mutable borrow/writeback and alias lifetime policies
delegate/callback trampolines
native-to-backend calls
strict isolation mode
dependency image unloading/reloading
incremental wrapper generation
cached native template specializations
```

## 20. Summary

The design should treat dub dependencies and the external native
environment as stable native infrastructure, and project code as
volatile backend input.

The main principle is:

```text
pay dependency cost rarely;
pay project compilation cost cheaply;
make native calls cheap and pre-indexed;
avoid native/backend crossings in tight loops;
do not put dub, package-manager queries, linking, or wrapper generation
in the edit-test path.
```

This yields a mixed-mode execution system where dependency code runs
normally as native D code, while edited project code can be interpreted,
lowered, or code-generated quickly enough to improve the unit-test
feedback loop.

## 21. Implementation reframing: start at the body-less leaf

Sections §3–§20 describe the long-term design: compiling dub D dependencies
into a cached native image and calling them through a wrapper manifest. That
is a real future cost centre, but it is **not** where this work starts and
**not** the irreducible reason this document exists.

The irreducible reason is the **body-less leaf**. Every non-trivial library
eventually calls a function for which there is no D body to execute — libc,
druntime, Phobos, or any native library installed by a package manager.
Reading a file, allocating memory, or formatting a float all bottom out in
such a call. `fd.fbody is null` is the mechanical signal: the function is
assumed to be precompiled native code that is **already resident** in the
host process (Quickbite is itself a D program, so libc/druntime/Phobos are
already mapped in). Resolution is `dlsym(RTLD_DEFAULT, mangledName)`; a null
result is a fail-closed diagnostic — the deferred dub-dependency case.

Available D code (templates, ranges, project source) is **not** the problem;
every backend already handles it by lowering, interpreting, or compiling. The
leaf is the problem. Two distinct native populations:

```text
already-resident (libc, druntime, Phobos): bind by symbol, no load,
  no module-ctor problem — this is where we start
newly-compiled (dub-dependency image, §3–§5): needs load + module-ctor +
  init — deferred
```

### 21.1 Shared, backend-neutral resolver

The resident native-call resolver is shared infrastructure, not per-backend
code and not a backend choice (proposed module `quickbite.ffi`). The first
mechanical trigger is a resolved `FuncDeclaration` with `fbody is null`, but
the resolver should serve every supported already-resident native call,
including functions reached today through DMD-builtin bridges such as `fabs`
and `pow`. It contains:

```text
- the frontend native-call descriptor: linkage, symbol name (mangling),
  parameter and return ABI types — derived from the resolved
  FuncDeclaration, kept behind the quickbite interface so no dmd.* type
  leaks into a public quickbite.* API
- the single resident native-call chokepoint every backend routes supported
  native runtime calls through (§21.2)
- dlsym(RTLD_DEFAULT, ...) resolution against the resident process
- the typed call plus scalar/pointer marshalling
```

Per-backend code is limited to: (a) recognizing a supported resident native
call and delegating to the chokepoint, and (b) converting between the backend's
value representation and the ABI. No backend is privileged; whichever backend
reaches CTFE parity first can adopt it.

### 21.2 The native-call chokepoint

Supported resident native calls route through one chokepoint:

```text
supported resident native call -> dlsym + native call
```

The chokepoint resolves the symbol and marshals scalars/pointers, with no
backend-local special cases: `malloc`, `free`, `fabs`, and `pow` all go
through the same resident native-call resolver.

A CTFE-compatible variant (rejecting body-less calls unless the function is
a CTFE-supported builtin, to match DMD CTFE) is **deferred** with the
CTFE-engine-replacement goal (`ai/plans/single-oracle.md`,
`ai/plans/bytecode.md`). It is not built now; the chokepoint is left so the
gate can be reintroduced in one place if that goal is revived.

### 21.3 Oracle

```text
Oracle: compiled native D via SystemLinker. malloc returns a non-null
  pointer; that compiled-D result is the truth (ai/plans/single-oracle.md).
```

`Ctfe` is not an oracle here. DMD CTFE throws when `malloc` is called at
compile time; that is a `Ctfe` characteristic, pinned as a `Ctfe`
characterization test, not as the definition of correct behaviour. The
success path is defined by `SystemLinker`.

## 22. Increment 1: first resident native call

**Scope warning.** Do not start by promoting the existing
`rt/cstdlib.malloc` acceptance test to the Interpreter. That fixture writes
to and reads from `ptr[index]`, so it drives native allocation **plus native
memory indexing and mutation**. That is larger than the first resident-call
slice and should remain an expected-failure test until §22.2.

The #1 task for this slice is to add a new, narrow oracle-backed test before
writing production code. Do not reuse the existing `rt/cstdlib.malloc`
success fixture for this slice.

Add a new fixture in `tests/ut/backends/runner/rt/cstdlib.d`, initially with
`SystemLinker` as the oracle. After seeing it fail on `Interpreter`, promote
`Interpreter` to that same fixture and make it pass. The source under test is
exactly:

```d
unittest {
    import core.stdc.stdlib: malloc, free;

    auto ptr = malloc(8);

    assert(ptr !is null);

    free(ptr);
}
```

Name it separately from the existing memory test, e.g.
`malloc.pointerRoundTrip.<backend>`, so the later byte-memory fixture remains
clearly distinct.

This test pins the native-call chokepoint in place from day one.
`malloc`/`free` are the first pointer-returning proof, not a special case in
the implementation.

`malloc`/`free` are `extern(C)`, body-less, not pure, and absent from DMD's
`BUILTIN` whitelist — the cleanest pointer-returning probe of the chokepoint.
`free(p)` also exercises passing a pointer **back** into a native call.

Expectations:

```text
Oracle (SystemLinker): succeeds — malloc returns non-null, free accepts it.
  This is the red test that drives the work.
Ctfe (characterization): rejected — the call fails to interpret, exactly as
  DMD CTFE does. Already true for the Ctfe backend, so this is pinned as a
  Ctfe characterization test, not as the definition of correct behaviour.
```

What Increment 1 forces into existence (all in `quickbite.ffi` unless
noted):

```text
- the single resident native-call chokepoint (§21.2)
- the frontend native-call descriptor (linkage, symbol, ABI types)
- dlsym(RTLD_DEFAULT, symbol)
- a general pointer Value kind in quickbite.lang (a machine word, NOT
  GC-scanned, since pointed-to memory may be C heap) with v1 operations
  limited to null/equality checks and native ABI marshalling
- marshalling: size_t in, void* out, void* in
```

What Increment 1 deliberately does **not** force:

```text
- pointer dereference;
- pointer indexing;
- writes through a native pointer;
- preserving native allocation lengths for bounds checks;
- calloc/realloc/string/out-parameter/struct-return support.
```

Do not replace or weaken the existing
`malloc.pointerReturn.nativeMemory` expected-failure fixture; it is the next
slice, not the first one.

The next proof should use another resident `extern(C)` scalar call, such as
`core.stdc.stdlib.abs`, to prove the path is descriptor-driven rather than
malloc-specific.

Explicitly still rejected after Increment 1 (scope guard):

```text
anything but extern(C) scalar/pointer signatures of this shape
  — arrays, strings, structs, extern(D), exceptions, GC-returning calls
```

This is the first resident-native-call rung of the ladder. Pointer
dereference, indexing, and writes are deferred until a later memory-semantics
slice. The next rungs (file read, then GC-returning calls needing the
handle-table/arena from §13) build on the same chokepoint.

### 22.2 Increment 2: native byte memory

Only after Increment 1 is green should the Interpreter adopt the existing
`rt/cstdlib.malloc` success fixture. That promotion requires a native pointer
value that can carry enough allocation metadata to support `ubyte*`
indexing and writes:

```d
ptr[0] = 0x11;
ptr[7] = 0xff;

assert(ptr[0] == 0x11);
assert(ptr[7] == 0xff);
assert(ptr[7] != 0);
```

This is a memory-semantics increment, not just an FFI-call increment. Keep it
limited to byte-addressed `ubyte*` memory returned by resident libc allocation
calls. Do not generalize to typed loads/stores, strings, slices, out
parameters, structs, callbacks, or backend-owned GC memory in this step.

`free(null)` may be promoted with either Increment 1 or Increment 2 if the
shared chokepoint already supports null pointer arguments. `calloc`,
`realloc`, `atoi`, `strtol`, `div`, and `ldiv` remain later rungs because
they each add another independent ABI or frontend surface.

## 23. Amendment: native-layout backends

The bytecode VM rewrite (`ai/plans/bytecode.md`) lays out all VM memory —
frames, heap, module data segments — exactly as compiled code would, using
DMD's computed sizes, alignments, and offsets. That changes the boundary
economics this document was written under, and where the two documents
disagree, `bytecode.md` wins for that backend. Specifically:

- **Value conversion is gone, not cheap.** The `QBValue` boxing layer and
  per-signature wrapper codegen (§7, §8, §11) exist to convert between a
  backend value representation and the D ABI. A native-layout backend has
  no other representation: scalars, pointers, structs, slices, and class
  references cross the boundary unchanged. The §2 non-goal "call arbitrary
  extern(D) functions directly" and the §18 rejection of direct ABI calls
  do not apply to this backend.
- **What remains of marshalling is the call ABI itself.** Invoking a
  function whose signature is only known at run time still requires
  implementing the SysV x86_64 calling convention. The bytecode backend
  builds libffi CIFs from DMD type signatures, cached per bridge entry —
  this extends the §21.1 resolver's "typed call plus scalar/pointer
  marshalling" to arbitrary signatures.
- **The exception guard survives.** Every outbound call is still wrapped
  per §12, converting native `Throwable`s into VM unwinding. It is the
  conversion half of the wrapper contract that is superseded, not the
  guard half.
- **The §10/§21 classification is confirmed and sharpened.** The boundary
  is the body-less leaf: anything with available source — including
  druntime template hooks and Phobos template bodies instantiated with
  project types — is executed by the VM. The §18 rejection of mixed
  template instantiations is therefore moot for this backend: they are
  ordinary VM-executed code, not a boundary case.
- **Inbound calls arrive earlier than §14 assumed.** Native-layout
  execution hands real objects to the real GC and the real AA runtime, so
  GC finalizers and AA key methods (dtor, postblit, toHash, opEquals on
  VM-compiled types) force native-to-VM trampolines before any
  callback-taking dependency API does. See "Runtime type metadata" in
  `bytecode.md`.

The §3–§20 dependency-image design is unaffected for boxed-value backends
and for the cold-path caching story; this amendment narrows only the
interop boundary mechanics for native-layout backends.

Scheduling boundary: this section is design context only. Do not treat it as
the next implementation work from this plan. Until the Interpreter can call
arbitrary native functions, do not promote Bytecode or IR FFI expected-failure
fixtures, and do not start the Bytecode native-layout bridge from this plan.

## 24. Increment 3: descriptor-driven resident calls (Interpreter)

**Status: Phases 0–4 landed (PR #272 and PR #274).** The hand-enumerated
cascade described below is deleted; `tryCallResidentNative` now builds an
`ffi_cif` from the resolved `FuncDeclaration` and marshals each
`quickbite.lang.Value` to and from raw ABI bytes, via the new
`quickbite.backends.libffi` binding (`libs "ffi"` in `dub.sdl`, `pragma(lib,
"ffi")` in-file). The full `rt/cstdlib.d` suite stays green through the new
path and `ci.sh` passes. Phase 4 added oracle-backed fixtures for capability
the descriptor path already supported (`abs`/`labs`, `toupper`/`tolower`,
`strtod`/`atof` float returns, wider scalar and by-value-struct shapes). This
section is retained as the as-built record of how that path works.

The Interpreter has climbed the §22/§22.2 ladder well past the first rungs:
`malloc`, `free`, `free(null)`, `atoi`, `strtol` (with `endptr` writeback),
`div`, `ldiv`, `calloc`, and `realloc` are all green against the
`SystemLinker` oracle. But the chokepoint in `source/quickbite/backends/ffi.d`
grew the way §22 warned against: `tryCallResidentNative` is a hand-enumerated
cascade of `(return TY, arg count, arg TYs)` branches, each casting the
`dlsym` result to a concrete `extern(C)` function alias. Every new libc
function is a new branch. §21.1 always intended the resolver to be
**descriptor-driven** — "linkage, symbol name, parameter and return ABI types
derived from the resolved `FuncDeclaration`" — not malloc-specific. This
increment makes it so, for the Interpreter.

This is the boxed-value analogue of the libffi CIF mechanism §23 specifies for
the native-layout backend. The two share an engine (libffi) and the §21.1
descriptor; they differ only in marshalling endpoint: the native-layout
backend's memory already *is* the ABI layout, whereas the Interpreter must
convert each `quickbite.lang.Value` to and from raw ABI bytes.

### 24.1 Engine

libffi (3.x, present system-wide) builds a call interface (`ffi_cif`) from a
return `ffi_type*` and an array of parameter `ffi_type*`, then performs the
SysV x86_64 call given raw argument buffers and a return buffer. It does the
register classification — small-struct-in-registers versus memory, INTEGER
versus SSE eightbytes — that the cascade was hardcoding per shape.

```text
FuncDeclaration -> TypeFunction
  -> build ffi_type* per parameter and for the return (recursively for structs)
  -> ffi_prep_cif (cached per resolved callable)
  -> marshal Value[] args -> raw arg buffers
  -> ffi_call(symbol)
  -> marshal raw return buffer -> Value
```

libffi is bound the way the project already binds `libLLVM` (see
`source/quickbite/backends/native/llvm_orc.d`): a hand-written `extern(C)`
module declaring only the surface used — `ffi_type`, `ffi_cif`, `ffi_status`,
`ffi_prep_cif`, `ffi_call`, and the predefined `ffi_type_*` globals — with
`pragma(lib, "ffi")` in-file and `libs "ffi"` in `dub.sdl`. No new dub
dependency, no libffi dev headers. (`ffi_prep_cif_var` is **not** bound: it is
only needed for variadics, which §24.6 defers.)

### 24.2 What is preserved exactly

The rewrite is confined to the body of `tryCallResidentNative`. Unchanged:

```text
the single call site (Walker.runCallExpression)
the gates: hasNoAvailableSource (fbody is null), !needThis, LINK.c only
symbol resolution: dlsym(RTLD_DEFAULT, mangleExact)
the "symbol is not loaded" fail-closed throw
the fall-through to noAvailableSourceMessage when the call is unsupported
the strtol-style out-parameter writeback (applyNativeWritebacks)
```

`fabs`/`sqrt`/`pow` and the other DMD builtins keep going through the
Interpreter's `builtins.d` (`isBuiltin`) path; they never reach this chokepoint
and are unaffected.

### 24.3 Type-to-ffi_type mapping

A pure mapping from a DMD `Type` (basetype) to an `ffi_type*`, keyed on `TY`:

```text
scalar TYs    -> predefined ffi_type_* globals (sint32, uint64, double, ...)
Tbool/Tchar.. -> the matching integer ffi_type
Tpointer      -> &ffi_type_pointer
Tvoid         -> &ffi_type_void
Tenum         -> recurse on toBasetype
Tstruct       -> synthesize ffi_type{STRUCT, elements} by walking sym.fields
                 recursively; assert libffi's computed size == DMD structsize
```

Anything not yet modelled returns false and preserves today's diagnostic:
`Tarray`, `Tsarray`, `Taarray`, `Tdelegate`, `Tclass`, and variadic
signatures (`parameterList.varargs != none`).

### 24.4 Marshalling

The boxed-value endpoint, and the real work of this increment.

```text
Value arg -> raw bytes sized to the ffi_type:
  integers      asLong truncated to width
  bool/char     same, by width
  float/double/real  asReal cast to the ABI float width
  pointer arg   NativePointer / Null passed straight through
  char array    -> C string, preserving today's borrow lifetime
                   (toStringz for call duration; the leaked-malloc
                   residentNativeString only when the buffer may escape
                   through a writeback, as strtol's endptr does)
  out pointer   a pointer-to-pointer parameter (Tpointer whose next is
                Tpointer, e.g. strtol's char**) is an OUT slot: allocate a
                host cell, pass &cell, and after the call set
                argumentWritebacks[i] = nativePointerValue(cell). This is the
                one rule that keeps strtol green under the rewrite; see §24.7.
  struct arg    recurse field-by-field (structFieldAt) into the laid-out buffer

raw return bytes -> Value, keyed on the return TY:
  scalar        the matching Value(...) ctor
  Tpointer      nativePointerValue
  Tstruct       structValue(name, fields...) rebuilt via DMD field offsets
```

The out-pointer rule is type-driven, so the existing call site and writeback
machinery are reused unchanged: the marshaller only has to populate
`argumentWritebacks[i]`; `Walker.applyNativeWritebacks` already maps slot `i`
to the `&local` argument expression. `tryCallResidentNative`'s signature does
not change.

Two libffi-specific obligations: the return buffer must be at least
`sizeof(ffi_arg)` (8 bytes) and suitably aligned even for narrow returns; and
every `toStringz` temporary must be rooted on the D stack across `ffi_call` so
the GC cannot collect it mid-call.

### 24.5 Staging

Each phase keeps `bin/ut --random` green.

```text
Phase 0  wire libffi: libs "ffi" + the extern(C) binding module. No behaviour
         change; validated indirectly by Phase 3.
Phase 1  Type -> ffi_type* mapper (internal, pure).
Phase 2  the Value <-> raw-bytes marshaller.
Phase 3  replace the cascade body with prep_cif + marshal + ffi_call + marshal
         back, keeping every §24.2 invariant. Acceptance: the entire existing
         rt/cstdlib.d suite stays green. Behaviour-preserving refactor, so no
         test is added or changed.
Phase 4  new capability, each its own oracle-backed fixture (approval required
         per AGENTS.md): abs/labs (int(int)), toupper/tolower, strtod/atof
         (float return), wider scalar and by-value-struct shapes.
```

After this increment, `tryCallResidentNative` accepts any non-variadic
`extern(C)` call over scalars, pointers, char-strings, and by-value structs.
A new libc function costs an approved test, not a new code branch.

### 24.6 Explicitly out of scope

```text
out-params other than the single-level pointer-to-pointer rule in §24.4
  — scalar out-params (int*) are ambiguous with in-pointers and are deferred;
  struct-by-ref out and multi-level indirection are deferred
variadics (printf) — would need ffi_prep_cif_var and per-call cifs
the §12 exception guard — separate increment, irrelevant for extern(C) libc
arrays/slices, delegates/callbacks, opaque native handles (§11.3)
the Bytecode and IR backends — this increment is Interpreter-only; their
  native-layout path is §23. Their rt/cstdlib.d expected-failures run through
  a different code path, not this chokepoint, so the refactor cannot affect
  them.
```

### 24.7 Implementation handoff

This subsection makes the increment buildable from a cold start, with no
context beyond the repository. Read `AGENTS.md` and `ai/mistakes.md` first.
Work in a worktree (`worktrees/ffi-libffi`). Build/test per `AGENTS.md`:
`dub run reggae --compiler=ldc -- -b ninja` (if `build.ninja` is absent), then
`ninja bin/ut`, then `bin/ut --random`.

Autonomy boundary: Phases 0–3 are a behaviour-preserving refactor that adds no
test and changes no test, so they need no approval and can be done end to end.
Phase 4 adds new fixtures and is gated by the standing `AGENTS.md` test-
approval rule.

Anchors (symbols are stable; re-grep for current line numbers and re-read
before editing):

```text
chokepoint to rewrite   source/quickbite/backends/ffi.d
                          (tryCallResidentNative; the parameterType helper and
                           the nativeString/residentNativeString helpers stay)
sole call site + gates   source/quickbite/backends/interpreter/impl.d
                          (Walker.runCallExpression, ~1580: hasNoAvailableSource
                           && !needThis && tryCallResidentNative)
writeback machinery      same file, applyNativeWritebacks /
                           nativeOutParameterVariable (~3844) — reuse as-is
no-source predicate/msg  source/quickbite/frontend/dmd/functions.d
                          (hasNoAvailableSource, noAvailableSourceMessage)
Value type               source/quickbite/lang/package.d
C-binding precedent      source/quickbite/backends/native/llvm_orc.d
                          (extern(C) + pragma(lib); mirror for libffi)
link flags               dub.sdl (libs "LLVM" lines; add libs "ffi")
acceptance test suite    tests/ut/backends/runner/rt/cstdlib.d (must stay green)
```

libffi binding surface (declare only this; libffi 3.x, /usr/include/ffi.h):

```d
struct ffi_type {
    size_t size;
    ushort alignment;
    ushort type;
    ffi_type** elements;   // null-terminated; for STRUCT
}
struct ffi_cif { /* opaque; size it from ffi.h or box behind a pointer */ }
enum ffi_status { FFI_OK = 0, FFI_BAD_TYPEDEF, FFI_BAD_ABI, FFI_BAD_ARGTYPE }
// FFI_DEFAULT_ABI is 2 (FFI_UNIX64) on x86-64 SysV; confirm against ffi.h.
extern(C) ffi_status ffi_prep_cif(
    ffi_cif*, uint abi, uint nargs, ffi_type* rtype, ffi_type** atypes);
extern(C) void ffi_call(ffi_cif*, void function(), void* rvalue, void** avalue);
// predefined globals: ffi_type_void/uint8/sint8/.../uint64/sint64/
//   float/double/longdouble/pointer
```

Note `ffi_prep_cif` fills in `size`/`alignment` for STRUCT `ffi_type`s it is
given, so the §24.3 size-vs-`structsize` assert must run after prep, or build
the struct `ffi_type` and let libffi compute layout then compare.

DMD API the mapper/marshaller needs (all already used in `ffi.d` except the
struct-field walk):

```text
TypeFunction    cast(TypeFunction) function_.type; .next.toBasetype (return);
                .parameterList; .parameterList.varargs (reject if != none)
parameter type  (*tf.parameterList.parameters)[i].type.toBasetype
                (the existing parameterType helper)
symbol name     dmd.mangle.mangleExact(function_)  (already used)
TY tags         dmd.astenums.TY (Tint32, Tuns64, Tpointer, Tstruct, Tvoid, ...)
pointer next    (cast(TypePointer) t).nextOf  — to detect char** out-params
struct fields   (cast(TypeStruct) t).sym.fields → VarDeclaration[]; per field
                .type (recurse) and .offset (byte offset). Trigger layout via
                dmd.typesem.size(t) / dmd.dsymbolsem.size before reading.
```

Value API the marshaller needs (`source/quickbite/lang`, all `@safe pure`
unless noted):

```text
in:   asLong, asReal, isNativePointer, asNativePointer (not @safe/pure),
      asCharArrayString, isStruct, structFieldCount, structFieldAt
out:  Value(int|long|double|...) ctors, Value.nativePointerValue(void*),
      Value.void_, Value.structValue(string typeName, Value[] fields)
```

Done when: `bin/ut --random` is green with the §24.3 reject-list returning
`false` (preserving the no-source diagnostic), the eight cstdlib functions
still passing through the new libffi path, and the cascade deleted.

## 25. Arbitrary native functions in the Interpreter

**Status: landed (PR #276).** The Interpreter now loads dependency images
with `RTLD_NOW | RTLD_GLOBAL`, routes supported body-less non-member native
calls through `tryCallNative`, accepts both `extern(C)` and `extern(D)`
linkage, resolves by `mangleExact(function_)`, and reuses the §24 libffi
descriptor path for the existing scalar/pointer/string/by-value-struct
signature set. The first oracle-backed fixture lives in
`tests/ut/backends/runner/rt/dependency_image.d` and proves an `extern(D)`
function supplied by a prepared dependency image.

This FFI increment was Interpreter-only. The goal was to move beyond resident
`extern(C)` libc leaves and make the boxed Interpreter call arbitrary concrete
native functions whose addresses are available in the host process or the
prepared dependency image.

Bytecode and IR were deliberately left out of this slice. Their native bridge
remains future work, even though §23 records how native-layout backends should
eventually cross the boundary.

What "arbitrary functions" meant for this increment:

```text
in scope:
  non-member native callables resolved from a FuncDeclaration
  extern(C) and extern(D)
  resident process symbols and symbols from a prepared dependency image
  the §24 scalar/pointer/string/by-value-struct signature set

out of scope:
  member functions needing `this`
  delegates, callbacks, closures, virtual dispatch, interfaces
  variadics
  exceptions crossing the boundary as ordinary backend exceptions
  generating wrapper source
  Bytecode/IR/native-layout bridge work
```

Original blockers in the code:

```text
source/quickbite/backends/interpreter/impl.d
  Walker.runCallExpression only tries FFI for `hasNoAvailableSource(call.f)`
  and `!call.f.needThis`.

source/quickbite/backends/ffi.d
  tryCallResidentNative rejects every linkage except LINK.c.
  It resolves only with dlsym(RTLD_DEFAULT, mangleExact(function_)).

source/quickbite/backends/native/llvm_jit.d
  LLVMJit already loads dependency images with RTLD_GLOBAL. The Interpreter
  does not yet have an equivalent session-level load step.
```

The PR preserved the §24 libffi descriptor path and extended the
Interpreter call boundary instead of adding more libc-specific branches:

```text
resolved FuncDeclaration
  -> supported callable descriptor
  -> ensure prepared dependency images are loaded once for the Interpreter
     session when present
  -> resolve callable address from resident symbols or the loaded dependency
     image using the function's DMD mangled name
  -> marshal quickbite.lang.Value arguments with the existing libffi machinery
  -> ffi_call
  -> unmarshal the result
```

Implementation shape:

```text
1. Give Interpreter construction or runner inputs access to the same prepared
   dependency-image paths already passed to LLVMJit for dub packages.
2. Load those images once per Interpreter instance with RTLD_NOW | RTLD_GLOBAL,
   mirroring LLVMJit's `loadDependencyImage` helper. Do not unload them during
   the hot path.
3. Rename/generalize `tryCallResidentNative` so the public API no longer says
   "resident" when dependency-image symbols are also valid.
4. Replace the `LINK.c` gate with a supported-linkage gate for LINK.c and
   LINK.d. Keep unsupported linkages returning `false` so the existing
   no-source diagnostic still owns the failure.
5. Resolve by `mangleExact(function_)`. `extern(C)` keeps the C symbol spelling;
   `extern(D)` gets the D mangled symbol.
6. Reuse `callViaLibffi` unchanged where possible. Any new signature support
   should be driven by a separate approved oracle-backed fixture, not by this
   plumbing PR.
```

The approved fixture proves the Interpreter can call a non-libc function
through this generalized path, with `SystemLinker` as the oracle. The slice
did not add Bytecode/IR expectations, did not implement the native-layout
bridge, and did not start callback/delegate support.

## 26. Current FFI boundary

§27 corrected the `extern(D)` calling convention in the Interpreter. Do not
start a new FFI implementation PR by silently choosing from §25's deferred
items; each of these changes adds a distinct semantic contract and needs its own
narrow plan plus an approved oracle-backed test:

```text
member functions needing `this`
delegates, callbacks, closures, virtual dispatch, interfaces
variadics
exceptions crossing the boundary as ordinary backend exceptions
generated wrapper source
Bytecode/IR/native-layout bridge work
```

The next planning PR should pick exactly one of those contracts, identify the
smallest compiled-D oracle fixture that proves it, and state which backend owns
the first implementation. Until that exists, keep Bytecode and IR out of the FFI
work from this plan; their native-layout bridge remains governed by §23 and
`ai/plans/bytecode.md`.

**Superseded by §34.** The remaining Interpreter ladder is now enumerated in
full, in dependency order, in §34. Do **not** open a new per-increment planning
PR to choose and spec the next rung — that spec already exists there. Implement
the next unimplemented rung from §34 directly (it still needs its approved
oracle fixture per `AGENTS.md`, but no new plan). This contract list stays as
the index of the semantic gaps §34 closes.

## 27. Increment 4: correct the extern(D) calling convention (Interpreter)

**Status: implemented.** This slice is Interpreter-only. Bytecode and IR stay
out (§23, §26).

### 27.1 Why this, and why it is not a §26 contract

§25 landed `extern(D)` support, but the only `extern(D)` oracle fixture
(`tests/ut/backends/runner/rt/dependency_image.d`) calls `dependencyAdd(int)` —
**one** explicit argument — and every other FFI fixture is `extern(C)`
(`rt/cstdlib.d`). No test exercises an `extern(D)` call with two or more
register arguments, and that case is currently **wrong**.

`callViaLibffi` prepares its CIF with `FFI_DEFAULT_ABI` (`FFI_UNIX64`, i.e. the
System V **C** ABI). But the D x86-64 ABI passes the *explicit* parameters of an
`extern(D)` function in **reverse register order** relative to C. Hidden
parameters (`this`, the nested-context pointer, the struct-return `sret`
pointer) keep their normal leading position and are **not** reversed.

This was confirmed empirically against `dmd`-compiled symbols invoked through
the C ABI:

```text
extern(D) int sub(int a, int b)        // a - b
  called C-order sub(10, 3)  ->  -7    // i.e. it computed 3 - 10: args reversed

extern(D) int three(int a,int b,int c) // a*100 + b*10 + c
  called C-order three(1, 2, 3)  ->  321   // read as (a,b,c) = (3,2,1)

struct Box { int value; int addTwo(int a, int b); } // value*1000 + a*100 + b
  called C-order addTwo(&Box(9), 1, 2)  ->  9201     // this kept first; (a,b)=(2,1)
```

Reverse-of-one is the identity, which is the *only* reason the §25
one-argument fixture is green. Almost every real dub-package `extern(D)`
function takes ≥2 arguments, so "execute any dub package" is impossible until
this is correct. It is also the prerequisite for member functions with
arguments (§27.6): `this`-only methods already call correctly (no explicit args
to reverse — `Box.get()` above with `this` as the first register argument
returns the right value today), but `obj.method(a, b)` does not.

Because this is a correctness gap in already-landed behaviour rather than a new
semantic contract, it jumps the §26 queue instead of being chosen from the
deferred list.

### 27.2 The rule to implement

D defines the `extern(D)` x86-64 convention as the System V C ABI applied to
the parameter list with the **explicit** parameters in **reverse order**;
hidden parameters keep their normal leading position. Concretely, in terms of
the arrays handed to `ffi_prep_cif`/`ffi_call`:

```text
extern(C):  atypes/avalue = [arg0, arg1, ..., argN]            (unchanged)
extern(D):  atypes/avalue = [hidden..., argN, ..., arg1, arg0]
```

libffi performs SysV register/stack classification on whatever array it is
given, so reversing the explicit `(ffi_type*, value-bytes)` pairs **together**,
before `ffi_prep_cif`, reproduces `extern(D)` assignment for the
register-resident case. No new libffi surface is needed; this is purely how the
existing `atypes`/`avalue` arrays are ordered.

### 27.3 Scope

In scope: non-member `extern(D)` functions whose explicit parameters are
scalars and pointers that all fit in argument registers (≤6 integer/pointer,
≤8 SSE), over the existing §24 signature surface. The reversal applies **only**
for `LINK.d`; `LINK.c` (libc, `rt/cstdlib.d`) keeps source order and must not
change. The existing one-argument `dependency_image.d` fixture must stay green
(reverse of one element is the identity).

Out of scope — each a named follow-up with its own approved oracle fixture:

```text
arguments that spill to the stack (>6 integer or >8 SSE register args, or large
  by-value structs): D's "reverse then classify" must be verified against the
  oracle before claiming support — do not assume the register-only reversal
  generalizes to stack slots
this / member functions (the rung after this — §27.6)
struct-by-value parameter reversal and sret ordering beyond what the
  register-only scalar fixture proves
variadics, delegates, exceptions, Bytecode/IR — unchanged from §26
```

### 27.4 Implementation shape

All changes are confined to `callViaLibffi` in
`source/quickbite/backends/ffi.d`; the call site, gates, symbol resolution, and
the no-source diagnostic are unchanged.

```text
1. Decide reversal from the function's linkage: reverse the explicit parameter
   order iff LINK.d. (extern(C) keeps source order.) There is no this/sret in
   this slice — member functions are still gated out at the call site by
   !call.f.needThis (interpreter/impl.d), and no signature here returns a
   struct via sret beyond the existing by-value support.
2. Build the libffi-facing atypes** and avalue** arrays in ABI order: identity
   for LINK.c, reverse(explicit) for LINK.d. Keep the logical, source-order
   arrays for everything else.
3. Preserve out-parameter writeback correctness across the reversal. The
   out-pointer cells and argumentWritebacks[index] are keyed by ORIGINAL
   (source) argument index; the writeback contract (Walker.applyNativeWritebacks
   maps slot i to the i-th argument expression) must keep using source indices.
   Reverse only the arrays passed to libffi, and translate between source index
   and libffi slot when reading back the out-pointer cells. Getting this wrong
   silently breaks strtol-style writeback — but note strtol is extern(C), so it
   is not reversed; an extern(D) out-pointer case is itself a later rung.
4. Run ffi_prep_cif + ffi_call exactly as today on the ABI-ordered arrays.
```

The reversal must operate on the `(ffi_type*, marshalled-bytes)` pair as a
unit — reversing only the types or only the buffers corrupts the call.

### 27.5 The fixture (approval required)

Add one new oracle-backed fixture proving a ≥2-argument `extern(D)` call, in the
style of `rt/dependency_image.d` (build a `.so` with `dmd -shared`, rewrite the
dependency as declaration-only, then run the same source on `SystemLinker` (the
oracle) and `Interpreter`). The function must take at least two register
arguments whose result is order-sensitive, e.g.:

```d
// dependency image (compiled with body, then rewritten to a declaration):
int dependencySub(int a, int b) { return a - b; }   // extern(D) by default

// source under test:
import dep_image_fixture;
unittest {
    assert(dependencySub(10, 3) == 7);
}
```

Expectations:

```text
SystemLinker (oracle): passes — links the image, calls dependencySub natively.
Interpreter: FAILS before the fix (returns -7 via the C-ABI ordering), the red
  test that drives the work; PASSES after the reversal is applied.
```

Per `AGENTS.md` this new fixture needs approval before it is added; it is the
red test, so propose it first (strict TDD: failing test → fix → green suite).
Unlike §24's behaviour-preserving phases, this slice changes behaviour and
cannot be done without an approved test.

### 27.6 The rung after this

Member functions, `this`-only first. With §27 landed, the reversal machinery and
the existing by-value-struct marshalling combine cleanly:

```text
this-only method (int Box.get()):  already correct today (no explicit args);
  needs only relaxing the !call.f.needThis gate and marshalling the receiver
  address as the leading hidden argument.
this + args (int Box.addTwo(a,b)):  depends on §27 — [this, reverse(explicit)].
```

That is a separate planning PR and a separate approved fixture; do not fold it
into §27.

### 27.7 Implementation handoff

Read `AGENTS.md` and `ai/mistakes.md` first. Work in a worktree
(`worktrees/ffi-externd-abi`). Build/test per `AGENTS.md`:
`dub run reggae --compiler=ldc -- -b ninja` (if `build.ninja` is absent), then
`ninja bin/ut`, then `bin/ut --random`.

Anchors (re-grep for current line numbers and re-read before editing):

```text
function to change       source/quickbite/backends/ffi.d
                          (callViaLibffi — the atypes/avalue construction and
                           the ffi_prep_cif/ffi_call; ffiTypeFor, marshalArgument,
                           unmarshalValue, isOutPointer stay as-is)
linkage gate             same file, isSupportedNativeLinkage (LINK.c | LINK.d)
                          and the LINK.d branch you key reversal on
entry point + writeback  same file, tryCallNative (signature unchanged) and the
                          out-pointer cell handling
call site + gates        source/quickbite/backends/interpreter/impl.d
                          (Walker.runCallExpression: hasNoAvailableSource &&
                           !call.f.needThis && tryCallNative); unchanged here
writeback machinery      same file, applyNativeWritebacks /
                          nativeOutParameterVariable; unchanged, but keep its
                          source-index contract intact (§27.4 step 3)
libffi binding           source/quickbite/backends/libffi.d (no new surface)
fixture style to mirror  tests/ut/backends/runner/rt/dependency_image.d
acceptance suite         tests/ut/backends/runner/rt/cstdlib.d (extern(C) must
                          stay green — it is NOT reversed)
```

DMD API needed: `function_._linkage` (already read by `isSupportedNativeLinkage`)
to distinguish `LINK.d` from `LINK.c`; `TypeFunction.parameterList` for the
explicit parameter sequence (already used). No new DMD surface.

Done when: `bin/ut --random` is green; the new ≥2-argument `extern(D)` fixture
passes on `SystemLinker` and `Interpreter`; the one-argument `dependency_image.d`
fixture and the entire `extern(C)` `cstdlib.d` suite remain green; and the
reversal is applied for `LINK.d` only.

## 28. Increment 5: member functions with `this` (Interpreter)

**Status: landed (PR #284).** This §26 contract added native member calls that
need a hidden `this` argument. The implementation is Interpreter-only.
Bytecode and IR stay out (§23, §26), and no callback/delegate/virtual-dispatch
work is implied.

### 28.1 Why this next

§25 made the Interpreter call body-less non-member functions from resident
symbols and prepared dependency images. §27 corrected the `extern(D)` argument
order for those calls. The next body-less leaf a D dependency exposes is a
method call:

```d
struct Counter {
    int value;
    int read() const { return value + 17; }
}
```

When the dependency image supplies the method body and the source visible to
the Interpreter contains only the declaration, DMD resolves the call to a
`FuncDeclaration` with `fbody is null` and `needThis == true`. The current
Interpreter handles that path before the native-call fallback:

```text
DotVarExp receiver -> needThis -> resolveMemberFunction ->
  hasNoAvailableSource -> throw noAvailableSourceMessage
```

So the existing `tryCallNative` chokepoint is never given a chance to marshal
the receiver. This increment adds that one missing hidden argument.

### 28.2 First fixture (approval required)

Add one oracle-backed dependency-image fixture in
`tests/ut/backends/runner/rt/dependency_image.d`, mirroring the existing
`extern(D)` fixtures. The dependency image is compiled with the method body and
then rewritten to declarations only:

```d
module dep_image_member_fixture;

struct Counter {
    int value;

    int read() const {
        return value + 17;
    }
}
```

Visible source after image build:

```d
module dep_image_member_fixture;

struct Counter {
    int value;
    int read() const;
}
```

Source under test:

```d
import dep_image_member_fixture;

unittest {
    Counter counter = Counter(25);
    assert(counter.read == 42);
}
```

Expectations:

```text
SystemLinker (oracle): passes — compiled D constructs the same struct and calls
  the dependency-image method body natively.
Interpreter: fails before the fix with the no-available-source diagnostic;
  passes after the hidden receiver is marshalled through the FFI chokepoint.
```

This fixture proves only a `this`-only, non-mutating, non-virtual struct method.
It is intentionally order-sensitive only through the receiver field value, not
through explicit parameters.

### 28.3 Scope

In scope:

```text
Interpreter only
non-virtual struct member functions from prepared dependency images
`extern(D)` member functions with no explicit parameters
receiver passed as the leading hidden `this` pointer
read-only receiver usage; no receiver writeback
existing §24 scalar return surface
```

Out of scope, each requiring a separate approved oracle fixture:

```text
member functions with explicit parameters (`[this, reverse(explicit)]`)
mutating struct methods and receiver writeback
class methods, virtual dispatch, interfaces, and vtables
constructors/destructors/postblits
properties beyond ordinary zero-argument call lowering
member functions returning structs through hidden sret
callbacks, delegates, exceptions, variadics, Bytecode, and IR
```

The method must remain a normal body-less leaf. Do not inline, recompile, or
special-case the dependency body inside the Interpreter.

### 28.4 Implementation shape

All native execution still goes through `quickbite.backends.ffi`; do not add a
backend-local call path in `interpreter/impl.d`.

```text
1. Extend the FFI entry point to accept hidden arguments separately from the
   source-order explicit argument list. The simplest shape is a new helper or
   overload that takes the receiver value and prepends it to the libffi ABI
   arrays as a hidden argument.
2. Keep explicit argument reversal from §27 applying only to explicit
   parameters. For this first fixture there are none, so the ABI order is
   simply `[this]`.
3. In `Walker.runCallExpression`, when a `DotVarExp` member call resolves to a
   body-less `FuncDeclaration`, try the native member-call path before throwing
   `noAvailableSourceMessage`.
4. Marshal the struct receiver into native memory for the duration of the call
   and pass a pointer to that memory as hidden `this`. Reuse the existing
   struct field marshalling instead of inventing a separate field walker.
5. Do not write the receiver back after the call in this slice. Reject or leave
   unclaimed any method shape that would require mutation semantics.
6. Preserve the existing non-member call path and the `rt/cstdlib.d` suite.
```

The hidden receiver must not be counted as a source argument for
`argumentWritebacks`; writeback slots remain keyed to the user's explicit
argument expressions.

### 28.5 Anchors

Re-grep and re-read before editing; line numbers drift.

```text
member call gate         source/quickbite/backends/interpreter/impl.d
                          (Walker.runCallExpression: DotVarExp + needThis +
                           resolveMemberFunction + hasNoAvailableSource)
native chokepoint        source/quickbite/backends/ffi.d
                          (tryCallNative, callViaLibffi, abiSourceIndex,
                           marshalArgument)
struct marshalling       source/quickbite/backends/ffi.d
                          (TY.Tstruct handling in marshalArgument)
dependency fixture style tests/ut/backends/runner/rt/dependency_image.d
no-source diagnostic     source/quickbite/frontend/dmd/functions.d
```

Done when: after an approved fixture is added, `bin/ut --random` is green; the
new member fixture passes on `SystemLinker` and `Interpreter`; existing
dependency-image and `rt/cstdlib.d` fixtures still pass; and unsupported member
shapes continue to fall through to the existing no-available-source diagnostic.

## 29. Increment 6: member functions with explicit arguments (Interpreter)

**Status: implemented.** This native-member rung after §28 added dependency
image struct member functions that take ordinary explicit arguments in addition
to the hidden `this` pointer. The implementation is Interpreter-only. Bytecode
and IR stay out (§23, §26), and no mutation, virtual dispatch, callbacks,
delegates, or exception interop is implied.

### 29.1 Why this next

§28 proved that the Interpreter can marshal a struct receiver as the leading
hidden `this` pointer:

```text
extern(D) int Counter.read() const
  -> ABI arguments: [this]
```

Real dependency methods usually also take explicit parameters. For `extern(D)`,
§27 already established the ABI rule: hidden arguments keep their leading
position and explicit arguments are passed in reverse order. A member call with
two explicit integer arguments is therefore the smallest fixture that combines
the two landed rules:

```text
extern(D) int Counter.addSub(int a, int b) const
  -> ABI arguments: [this, b, a]
```

The current `tryCallNativeMember` entry point deliberately rejects
`arguments.length != 0`, so this call still falls through to the existing
no-available-source diagnostic even though the lower-level libffi path already
has most of the required ordering machinery.

### 29.2 First fixture (approval required)

Add one oracle-backed dependency-image fixture in
`tests/ut/backends/runner/rt/dependency_image.d`, mirroring §28. The dependency
image is compiled with the method body and then rewritten to declarations only:

```d
module dep_image_member_args_fixture;

struct Counter {
    int value;

    int addSub(int addend, int subtrahend) const {
        return value + addend - subtrahend;
    }
}
```

Visible source after image build:

```d
module dep_image_member_args_fixture;

struct Counter {
    int value;
    int addSub(int addend, int subtrahend) const;
}
```

Source under test:

```d
import dep_image_member_args_fixture;

unittest {
    Counter counter = Counter(25);
    int addend = 20;
    int subtrahend = 3;
    assert(counter.addSub(addend, subtrahend) == 42);
}
```

Expectations:

```text
SystemLinker (oracle): passes — compiled D calls the dependency-image method
  body natively.
Interpreter: fails before the fix with the no-available-source diagnostic;
  passes after explicit arguments are allowed on the native member-call path.
```

The fixture is order-sensitive: if the explicit parameters are passed in C
source order after `this`, the dependency image computes `25 + 3 - 20 == 8`
instead of `42`.

### 29.3 Scope

In scope:

```text
Interpreter only
non-virtual struct member functions from prepared dependency images
`extern(D)` member functions with at least two explicit register arguments
receiver passed as the leading hidden `this` pointer
explicit argument order `[this, reverse(explicit)]`
read-only receiver usage; no receiver writeback
existing §24 scalar/pointer/string/by-value-struct signature surface where it
  already fits the §27 register-only extern(D) scope
```

Out of scope, each requiring a separate approved oracle fixture:

```text
mutating struct methods and receiver writeback
class methods, virtual dispatch, interfaces, and vtables
constructors/destructors/postblits
member functions whose hidden plus explicit arguments spill to the stack
member functions returning structs through hidden sret
extern(C++) member ABI
callbacks, delegates, exceptions, variadics, Bytecode, and IR
```

The method must remain a normal body-less leaf. Do not inline, recompile, or
special-case the dependency body inside the Interpreter.

### 29.4 Implementation shape

All native execution still goes through `quickbite.backends.ffi`; do not add a
backend-local call path in `interpreter/impl.d`.

```text
1. Add the approved fixture first and confirm it fails on the Interpreter with
   the existing no-available-source diagnostic.
2. Relax `tryCallNativeMember` so it no longer rejects all explicit arguments.
   Keep rejecting unsupported receiver shapes and unsupported signatures by
   returning `false`.
3. Keep the receiver as a hidden leading ABI argument and keep
   `argumentWritebacks` keyed only to explicit source arguments.
4. Reuse §27's explicit-argument reversal: for `LINK.d`, libffi sees
   `[hidden..., argN, ..., arg0]`; for `LINK.c`, source order remains
   unchanged.
5. Extend the register-scope guard to account for the hidden `this` pointer.
   Do not claim stack-spilled extern(D) member calls in this increment.
6. Preserve the existing §28 `this`-only fixture, the non-member
   dependency-image fixtures, and the `rt/cstdlib.d` suite.
```

The reversal must continue to operate on each `(ffi_type*, marshalled-bytes)`
pair as a unit. Writeback slots, if any later fixture enables them for member
calls, stay indexed by the user's explicit argument list, not the libffi ABI
slot.

### 29.5 Anchors

Re-grep and re-read before editing; line numbers drift.

```text
member call gate         source/quickbite/backends/interpreter/impl.d
                          (Walker.runCallExpression: DotVarExp + needThis +
                           resolveMemberFunction + hasNoAvailableSource)
native member entry      source/quickbite/backends/ffi.d
                          (tryCallNativeMember, NativeThis, tryCallNativeImpl)
ABI ordering             source/quickbite/backends/ffi.d
                          (callViaLibffi, abiSourceIndex,
                           externDArgumentsFitRegisterScope)
struct marshalling       source/quickbite/backends/ffi.d
                          (TY.Tstruct handling in marshalArgument)
dependency fixture style tests/ut/backends/runner/rt/dependency_image.d
no-source diagnostic     source/quickbite/frontend/dmd/functions.d
```

Done when: after an approved fixture is added, `bin/ut --random` is green; the
new member-arguments fixture passes on `SystemLinker` and `Interpreter`;
existing dependency-image and `rt/cstdlib.d` fixtures still pass; and
unsupported member shapes continue to fall through to the existing
no-available-source diagnostic.

## 30. Increment 7: native exceptions become Interpreter exceptions

**Status: landed (PR #290).** This §26 contract after member-function calls
made native `object.Exception` values thrown by dependency-image functions
become ordinary Interpreter exceptions. The implementation is Interpreter-only.
Bytecode and IR stay out (§23, §26), and no callback, delegate, virtual
dispatch, variadic, or generated-wrapper work is implied.

### 30.1 Why this next

§25 through §29 make the Interpreter cross the native boundary for concrete
dependency-image functions and struct member functions. A normal D dependency
can also signal failure by throwing:

```d
void dependencyThrow() {
    throw new Exception("dependency failed");
}
```

Today the libffi path calls the native function with no Quickbite exception
boundary:

```text
Interpreter frame -> quickbite.backends.ffi -> ffi_call -> dependency function
```

If the dependency function throws, the native `Throwable` escapes through the
libffi call instead of becoming the Interpreter's existing
`InterpretedException` state. That means ordinary interpreted `try`/`catch`
cannot handle an exception raised by a dependency-image function, even though
compiled D can.

This increment implements the §12 rule for the first direction only:

```text
native Exception -> Interpreter pending exception
native Error     -> fatal native failure
```

### 30.2 First fixture (approval required)

Add one oracle-backed dependency-image fixture in
`tests/ut/backends/runner/rt/dependency_image.d`, mirroring the existing
dependency-image tests. The dependency image is compiled with the throwing body
and then rewritten to declarations only:

```d
module dep_image_exception_fixture;

void dependencyThrow() {
    throw new Exception("dependency failed");
}
```

Visible source after image build:

```d
module dep_image_exception_fixture;

void dependencyThrow();
```

Source under test:

```d
import dep_image_exception_fixture;

unittest {
    try {
        dependencyThrow();
        assert(false);
    } catch (Exception caught) {
        assert(caught.msg == "dependency failed");
    }
}
```

Expectations:

```text
SystemLinker (oracle): passes — compiled D catches the dependency-image
  `Exception` and exposes its message.
Interpreter: fails before the fix because the native exception is not converted
  into the interpreter's exception representation; passes after the FFI
  boundary maps the native exception into the existing interpreted catch path.
```

This fixture intentionally uses `object.Exception`, not a dependency-defined
subclass. Preserving the thrown message and matching `catch (Exception)` is the
first semantic contract. Dependency-defined exception subclasses and field
state are later rungs.

### 30.3 Scope

In scope:

```text
Interpreter only
non-member dependency-image functions called through `tryCallNative`
`object.Exception` thrown by native dependency code
mapping the native exception message to an interpreted `Exception` object
ordinary interpreted `catch (Exception caught)` handling and `caught.msg`
native `Error` remains fatal and is not caught by `catch (Exception)`
```

Out of scope, each requiring a separate approved oracle fixture:

```text
member functions that throw
dependency-defined exception subclasses and subclass-specific fields
native exception chaining (`Throwable.next`)
native `Error` recovery as an ordinary backend exception
exceptions thrown after out-parameter writebacks
backend exceptions crossing into native callbacks
callbacks, delegates, virtual dispatch, variadics, Bytecode, and IR
generated wrapper source
```

Do not special-case the dependency fixture. The throw must remain a native
throw from the dependency image, caught at the common FFI boundary.

### 30.4 Implementation shape

All native execution still goes through `quickbite.backends.ffi`; do not add a
backend-local direct call path in `interpreter/impl.d`.

```text
1. Add the approved fixture first and confirm it fails on the Interpreter.
2. Change the FFI API so a native call can report one of: no supported call
   shape, returned value, native `Exception`, or native `Error`.
3. Catch `Exception` and `Error` around `ffi_call` in `callViaLibffi`.
   `Exception` is returned to the Interpreter as a caught native exception;
   `Error` is rethrown or reported as fatal native failure, not converted into
   an interpreted `Exception`.
4. In `Walker.runCallExpression`, convert a caught native `Exception` into the
   same `Value.classValue` shape used by interpreted `new Exception(message)`,
   then throw `InterpretedException` so existing `runTryCatchStatement`,
   `catchMatches`, and `bindCatchVariable` handle it.
5. Keep the no-supported-call path returning false so the existing
   no-available-source diagnostic still owns unsupported signatures.
6. Preserve successful return values and existing argument writeback behavior.
```

The native exception object must not be stored as an opaque native handle in
this slice. The interpreted value only needs the existing class type names for
`Throwable`/`Exception` matching and the `msg` field for the approved fixture.

### 30.5 Anchors

Re-grep and re-read before editing; line numbers drift.

```text
native call result       source/quickbite/backends/ffi.d
                          (tryCallNative, tryCallNativeMember,
                           tryCallNativeImpl, callViaLibffi)
libffi boundary          source/quickbite/backends/ffi.d
                          (ffi_call and return-value unmarshalling)
interpreter exception    source/quickbite/backends/interpreter/impl.d
                          (InterpretedException, throwInterpretedException,
                           applyThrowableConstructor)
call site                source/quickbite/backends/interpreter/impl.d
                          (Walker.runCallExpression native-call branches)
catch handling           source/quickbite/backends/interpreter/impl.d
                          (runTryCatchStatement, catchMatches,
                           bindCatchVariable)
fixture style to mirror  tests/ut/backends/runner/rt/dependency_image.d
```

Done when: after an approved fixture is added, `bin/ut --random` is green; the
new dependency-image exception fixture passes on `SystemLinker` and
`Interpreter`; the existing dependency-image member fixtures and `rt/cstdlib.d`
suite still pass; unsupported native call shapes still fall through to the
existing no-available-source diagnostic; and native `Error` is not converted
into an interpreted `Exception`.

## 31. Increment 8: dependency-defined exception subclasses

**Status: implemented.** This native-exception rung after §30 preserves enough
native exception type metadata for dependency-defined subclasses to match
ordinary interpreted `catch` clauses. The implementation is Interpreter-only.
Bytecode and IR stay out (§23, §26), and no callback, delegate, virtual
dispatch, variadic, or generated-wrapper work is implied.

### 31.1 Why this next

§30 preserves the message from a native `object.Exception` and lets ordinary
interpreted `catch (Exception)` code handle it. Real dependencies often throw
their own exception subclasses:

```d
class DependencyException: Exception {
    this(string msg) {
        super(msg);
    }
}

void dependencyThrowCustom() {
    throw new DependencyException("dependency failed");
}
```

Today the FFI boundary reports only the message. `Walker.runCallExpression`
then builds the same interpreted `object.Exception` shape used for §30. That
means `catch (DependencyException)` cannot distinguish the native dynamic type,
even though compiled D can.

This increment keeps the §12 first-direction rule but carries one more piece of
native exception metadata:

```text
native DependencyException -> interpreted DependencyException pending exception
native Error               -> fatal native failure
```

### 31.2 First fixture (approval required)

Add one oracle-backed dependency-image fixture in
`tests/ut/backends/runner/rt/dependency_image.d`, mirroring §30. The dependency
image is compiled with the class and throwing body, then rewritten to
declarations only:

```d
module dep_image_custom_exception_fixture;

class DependencyException: Exception {
    this(string msg) {
        super(msg);
    }
}

void dependencyThrowCustom() {
    throw new DependencyException("dependency failed");
}
```

Visible source after image build:

```d
module dep_image_custom_exception_fixture;

class DependencyException: Exception {
    this(string msg);
}

void dependencyThrowCustom();
```

Source under test:

```d
import dep_image_custom_exception_fixture;

unittest {
    try {
        dependencyThrowCustom();
        assert(false);
    } catch (DependencyException caught) {
        assert(caught.msg == "dependency failed");
    }
}
```

Expectations:

```text
SystemLinker (oracle): passes — compiled D catches the dependency-defined
  subclass and exposes the inherited `Exception.msg`.
Interpreter: fails before the fix because the native exception is converted to
  interpreted `object.Exception`; passes after the FFI boundary preserves the
  native dynamic type well enough for `catch (DependencyException)` and
  `caught.msg`.
```

This fixture intentionally avoids subclass fields. It proves only dynamic type
matching and the inherited message.

### 31.3 Scope

In scope:

```text
Interpreter only
non-member dependency-image functions called through `tryCallNative`
dependency-defined classes that directly extend `object.Exception`
preserving the native exception's dynamic class name
mapping that class name to the interpreted declaration visible in the module
ordinary interpreted `catch (DependencyException caught)` handling
inherited `Exception.msg`
native `Error` remains fatal and is not caught by `catch (Exception)`
```

Out of scope, each requiring a separate approved oracle fixture:

```text
subclass-specific fields and constructor state beyond `msg`
exception subclasses outside the visible imports of the interpreted module
full imported-class declaration reconstruction when lexical lookup cannot find
  the class
member functions that throw dependency-defined subclasses
native exception chaining (`Throwable.next`)
native `Error` recovery as an ordinary backend exception
exceptions thrown after out-parameter writebacks
backend exceptions crossing into native callbacks
callbacks, delegates, virtual dispatch, variadics, Bytecode, and IR
generated wrapper source
```

Do not retain the native exception object as an opaque handle in this slice.
The interpreted value should be an ordinary class value whose dynamic type is
the dependency-defined exception declaration and whose inherited `msg` matches
the native exception.

### 31.4 Implementation shape

All native execution still goes through `quickbite.backends.ffi`; do not add a
backend-local direct call path in `interpreter/impl.d`.

```text
1. Add the approved fixture first and confirm it fails on the Interpreter.
2. Extend `NativeCallException` so the FFI boundary reports the native
   exception's dynamic class name as well as `msg`.
3. Catch `Exception` around `ffi_call` exactly as §30 does. Native `Error`
   stays fatal by falling through the boundary.
4. In `Walker.runCallExpression`, first try to resolve the reported class name
   against the interpreter's lexical class lookup. If it is found, build that
   interpreted class value with the inherited `msg` field and throw
   `InterpretedException`.
5. If lexical lookup cannot find the imported dependency class, build the
   narrow exception value shape this fixture needs: native fully-qualified
   dynamic name, short dynamic name, the known `Exception`/`Throwable` base
   type names, and the inherited `msg` field. This keeps `catch` matching on
   the existing `Value.classHasType` path without claiming subclass fields.
6. Preserve the §30 `object.Exception` fixture, member-call fixtures, and the
   `rt/cstdlib.d` suite.
```

The class-name metadata is matching input only; it must not become a new
mechanism for importing fields or declarations that are not visible to the
interpreted module.

### 31.5 Anchors

Re-grep and re-read before editing; line numbers drift.

```text
native exception type    source/quickbite/backends/ffi.d
                          (NativeCallException and the `ffi_call` catch)
interpreter conversion   source/quickbite/backends/interpreter/impl.d
                          (throwNativeException and native-call branches in
                           Walker.runCallExpression)
catch matching           source/quickbite/backends/interpreter/impl.d
                          (runTryCatchStatement, catchMatches,
                           bindCatchVariable)
class values             source/quickbite/lang/package.d
fixture style to mirror  tests/ut/backends/runner/rt/dependency_image.d
```

Done when: after an approved fixture is added, `bin/ut --random` is green; the
new dependency-defined exception fixture passes on `SystemLinker` and
`Interpreter`; the §30 `object.Exception` fixture still passes; existing
dependency-image member fixtures and `rt/cstdlib.d` still pass; subclass fields
remain unsupported; and native `Error` is not converted into an interpreted
`Exception`.

## 32. Increment 9: D string slice arguments (Interpreter)

**Status: implemented.** This arbitrary-native-call rung after §31 lets the
Interpreter pass a D `string` argument to a dependency-image `extern(D)`
function. Bytecode and IR stay out (§23, §26), and no callback, delegate,
virtual dispatch, variadic, exception, generated-wrapper, mutable-slice, or
array-return work is implied.

### 32.1 Why this next

§25 says the Interpreter can call arbitrary dependency-image functions over the
existing scalar/pointer/string/by-value-struct signature set. In practice the
"string" part only covers C-style `char*` calls such as `atoi("123".ptr)`.
Ordinary D functions commonly take D slices:

```d
int dependencyScore(string value) {
    return cast(int) value.length * 10 + value[0];
}
```

Before this increment the FFI descriptor builder rejects `string`, because DMD
represents it as `immutable(char)[]` (`TY.Tarray`) and `ffiTypeFor` has no
dynamic-array descriptor. That means a body-less dependency-image declaration
with a `string` parameter falls through to the existing no-available-source
diagnostic even though the function is native and loaded.

This increment adds the first D-slice ABI bridge:

```text
interpreted string Value -> native D slice descriptor -> dependency function
```

### 32.2 First fixture

The oracle-backed dependency-image fixture lives in
`tests/ut/backends/runner/rt/dependency_image.d`. The dependency image is
compiled with a `string`-taking function body, then rewritten to a declaration
only:

```d
module dep_image_string_fixture;

int dependencyStringScore(string value) {
    return cast(int) value.length * 10 + value[0];
}
```

Visible source after image build:

```d
module dep_image_string_fixture;

int dependencyStringScore(string value);
```

Source under test:

```d
import dep_image_string_fixture;

unittest {
    string value = "abc";
    assert(dependencyStringScore(value) == 127);
}
```

Expectations:

```text
SystemLinker (oracle): passes - compiled D links the image and passes the D
  string slice normally.
Interpreter: failed before the fix because `TY.Tarray` was unsupported by the
  libffi descriptor path; passes after the FFI boundary marshals a string slice
  descriptor containing length and data pointer.
```

The fixture uses a local `string` variable rather than passing the literal
directly so the backend sees the normal interpreted string value.

### 32.3 Scope

In scope:

```text
Interpreter only
non-member dependency-image functions called through `tryCallNative`
extern(D)
one immutable `char` dynamic-array argument (`string`)
read-only native use during the call
scalar return values already supported by §24
```

Out of scope, each requiring a separate approved oracle fixture:

```text
mutable dynamic arrays and writeback
wstring, dstring, and non-character element arrays
dynamic-array return values
dynamic arrays inside structs
multiple D-slice arguments with aliasing-sensitive behaviour
extern(C) structs that merely resemble D slices
variadics, callbacks, delegates, virtual dispatch, Bytecode, and IR
generated wrapper source
```

### 32.4 Implementation shape

All native execution still goes through `quickbite.backends.ffi`; do not add a
backend-local direct call path in `interpreter/impl.d`.

```text
1. Add the approved fixture first and confirm it fails on the Interpreter with
   the existing no-available-source diagnostic.
2. Add a libffi descriptor for supported D dynamic arrays: a struct containing
   `size_t length` and `void* ptr`, matching D's slice ABI for `T[]`.
3. Gate this first slice to `TY.Tarray` whose element basetype is `TY.Tchar`;
   leave other dynamic arrays unsupported.
4. Marshal the interpreted string into a native element buffer and write the
   slice descriptor into the argument buffer.
5. Keep the element buffer alive until after `ffi_call`; native code must not
   retain the pointer in this slice.
6. Preserve existing `extern(C)` pointer-string behaviour in `rt/cstdlib.d`.
```

The implementation should reuse the existing `Value.asCharArrayString`
conversion for this first string-only bridge. It should not introduce ownership
or writeback rules for general arrays until a fixture demands them.

### 32.5 Anchors

Re-grep and re-read before editing; line numbers drift.

```text
descriptor + marshal     source/quickbite/backends/ffi.d
                          (`ffiTypeFor`, `marshalArgument`, `callViaLibffi`)
string value helpers     source/quickbite/lang/package.d
                          (`Value.asCharArrayString`, array/string values)
call site                source/quickbite/backends/interpreter/impl.d
                          (`Walker.runCallExpression`, unchanged)
fixture style to mirror  tests/ut/backends/runner/rt/dependency_image.d
extern(C) regression     tests/ut/backends/runner/rt/cstdlib.d
```

Done when: `bin/ut --random` is green; the new dependency-image `string`
fixture passes on `SystemLinker` and `Interpreter`; the existing
dependency-image scalar/member/exception fixtures still pass; and the
`rt/cstdlib.d` suite still passes.

## 33. Increment 10: D string slice return values (Interpreter)

**Status: implemented.** This arbitrary-native-call rung after §32 lets the
Interpreter receive a D `string` return value from a dependency-image
`extern(D)` function.

Bytecode and IR stay out (§23, §26), and no mutable-slice, array-argument
generalisation, callback, delegate, virtual-dispatch, variadic, exception, or
generated-wrapper work is implied.

### 33.1 Why this next

§32 added the first D-slice ABI bridge in the argument direction:

```text
interpreted string Value -> native D slice descriptor -> dependency function
```

Real D dependencies also commonly return freshly allocated or static strings:

```d
string dependencyGreeting() {
    return "quickbite";
}
```

Before this increment the libffi descriptor path still rejects a `string`
return, because DMD represents it as `immutable(char)[]` (`TY.Tarray`) and
`ffiTypeFor` has no return descriptor for dynamic arrays. That means a
body-less dependency-image declaration with a `string` return falls through to
the existing no-available-source diagnostic even though the function is native
and loaded.

This increment adds the return half of the first D-slice bridge:

```text
dependency function -> native D slice descriptor -> interpreted string Value
```

### 33.2 First fixture (approval required)

Add one oracle-backed dependency-image fixture in
`tests/ut/backends/runner/rt/dependency_image.d`, mirroring §32. The dependency
image is compiled with a `string`-returning function body, then rewritten to a
declaration only:

```d
module dep_image_string_return_fixture;

string dependencyGreeting() {
    return "quickbite";
}
```

Visible source after image build:

```d
module dep_image_string_return_fixture;

string dependencyGreeting();
```

Source under test:

```d
import dep_image_string_return_fixture;

unittest {
    string value = dependencyGreeting();
    assert(value == "quickbite");
    assert(value.length == 9);
}
```

Expectations:

```text
SystemLinker (oracle): passes - compiled D links the image and receives the D
  string slice normally.
Interpreter: fails before the fix because `TY.Tarray` is unsupported as a
  libffi return type; passes after the FFI boundary unmarshals a string slice
  descriptor into a backend-owned string value.
```

The fixture stores the returned string in a local before asserting so the
backend exercises normal interpreted string value operations after the native
call.

### 33.3 Scope

In scope:

```text
Interpreter only
non-member dependency-image functions called through `tryCallNative`
extern(D)
one immutable `char` dynamic-array return value (`string`)
copying the returned slice into a backend-owned string value
zero explicit arguments for the first fixture
```

Out of scope, each requiring a separate approved oracle fixture:

```text
mutable dynamic arrays and writeback
wstring, dstring, and non-character element arrays
dynamic-array parameters beyond the §32 single string argument
dynamic arrays inside structs
multiple D-slice arguments or returns with aliasing-sensitive behaviour
returned slices whose lifetime is shorter than the call boundary
extern(C) structs that merely resemble D slices
variadics, callbacks, delegates, virtual dispatch, Bytecode, and IR
generated wrapper source
```

### 33.4 Implementation shape

All native execution still goes through `quickbite.backends.ffi`; do not add a
backend-local direct call path in `interpreter/impl.d`.

```text
1. Add the approved fixture first and confirm it fails on the Interpreter with
   the existing no-available-source diagnostic.
2. Allow the existing string-slice libffi descriptor to be used for supported
   return types as well as argument types.
3. Gate this first return bridge to `TY.Tarray` whose element basetype is
   `TY.Tchar`; leave other dynamic arrays unsupported.
4. Unmarshal the returned D slice descriptor (`size_t length`, `void* ptr`) by
   copying the pointed-to bytes into a backend-owned string value.
5. Treat a non-empty slice with a null pointer as unsupported or fatal rather
   than fabricating contents; an empty null slice may become an empty string if
   the oracle fixture later requires it.
6. Preserve existing `extern(C)` pointer-string behaviour in `rt/cstdlib.d`
   and the §32 string-argument fixture.
```

This slice intentionally copies the native bytes. It does not introduce a
borrowed native string handle or any ownership protocol for native memory that
could be invalidated after the call.

### 33.5 Anchors

Re-grep and re-read before editing; line numbers drift.

```text
descriptor + unmarshal   source/quickbite/backends/ffi.d
                          (`ffiTypeFor`, `ffiArgumentTypeFor`,
                           `unmarshalValue`, `callViaLibffi`)
string value helpers     source/quickbite/lang/package.d
                          (`Value(string)`, `Value.asCharArrayString`,
                           array/string values)
call site                source/quickbite/backends/interpreter/impl.d
                          (`Walker.runCallExpression`, unchanged)
fixture style to mirror  tests/ut/backends/runner/rt/dependency_image.d
extern(C) regression     tests/ut/backends/runner/rt/cstdlib.d
```

Done when: after an approved fixture is added, `bin/ut --random` is green; the
new dependency-image `string` return fixture passes on `SystemLinker` and
`Interpreter`; the §32 string-argument fixture still passes; existing
dependency-image scalar/member/exception fixtures still pass; and the
`rt/cstdlib.d` suite still passes.

## 34. The complete remaining Interpreter FFI ladder

### 34.1 Terminal goal and why this section exists

The terminal goal of all Interpreter FFI work is one sentence: **the
Interpreter should call out to arbitrary compiled dependency code, so a real
dub project "just" runs under it** — project source interpreted, every
dependency leaf called natively. Quickbite reaches that goal when every
body-less callable a real dub package can put in front of the Interpreter
(`fbody is null` — see §21) is marshalled and called correctly, and every
native `Throwable` it can raise is mapped back.

§21–§33 climbed that ladder one rung per PR, and each rung was *planned* in its
own PR before being *implemented* in the next (the most recent example: §33,
string slice returns, is markdown only — no code yet). That per-increment
planning cadence is what this section ends. Below is the **entire** remaining
ladder, in dependency order, each rung specified to the same depth the
implementer needs: the one new semantic contract, the smallest oracle fixture,
in/out scope, the code to change, and the done criteria.

How to use this section:

```text
- Implement the next rung whose Status is not "landed", top to bottom.
- Do NOT write a new planning PR to choose or re-spec a rung. The spec is here.
- Each rung still needs its approved oracle fixture before code (AGENTS.md);
  propose the fixture sketched here, get approval, then go red -> green.
- A rung may carry more than one fixture (e.g. one per element type or
  direction) but only one new semantic contract. Land them as small steps.
- When a rung lands, set its Status to "landed (PR #...)" and move on. Do not
  append a new §N planning section.
```

Ordering principle: rungs are sorted by how often real dub code forces them,
so the Interpreter can run the largest fraction of real packages the soonest.
ABI-correctness gaps that silently miscompile common calls (stack spill, sret)
rank above rare type surface (extern(C++)).

### 34.2 Shared invariants for every rung below

```text
- Interpreter only. Bytecode and IR stay out (§23, §26); their native-layout
  bridge is governed by ai/plans/bytecode.md, not this ladder.
- SystemLinker is the oracle (ai/plans/single-oracle.md). Every fixture asserts
  the same source on SystemLinker (passes) and Interpreter (red before, green
  after). Ctfe stays a characterization backend, never the truth.
- All native execution goes through quickbite.backends.ffi. Never add a
  backend-local call path in interpreter/impl.d.
- One semantic contract per fixture; the throw/struct/slice stays a real native
  leaf from a prepared dependency image. Do not inline or special-case bodies.
- extern(D) explicit args are reversed (§27, abiSourceIndex); hidden args
  (this, sret) keep their leading position. extern(C) keeps source order.
- argumentWritebacks stay keyed to the user's explicit source-argument
  expressions, never to libffi ABI slots (§27.4).
- Register-before-stack discipline: a rung claims register-resident shapes
  first; stack spill is its own rung (§34.5) unless the rung is itself about
  spill.
```

### 34.3 The ladder at a glance

```text
Increment  Contract                                            Status   Ref
10  D string slice RETURN value                                done     §33
11  typed (non-char) immutable slice args and returns          done     §34.4
12  stack-spilled extern(D) arguments (>6 int / >8 SSE)        done     §34.5
13  large struct returns via hidden sret + extern(D) ordering  todo     §34.6
14  scalar out-parameters (int*) with writeback                todo     §34.7
15  mutating struct member methods + receiver writeback        todo     §34.8
16  mutable slice arguments with writeback                     todo     §34.9
17  slices/arrays nested inside by-value structs               todo     §34.10
18  class references, virtual dispatch, interfaces (vtables)   todo     §34.11
19  constructors, destructors, postblits                       todo     §34.12
20  native Error recovery and exception chaining (next)        todo     §34.13
21  variadics (printf-shaped; ffi_prep_cif_var)                todo     §34.14
22  delegates / callbacks / closures: the reverse bridge       todo     §34.15
23  extern(C++) function and member ABI                        todo     §34.16
```

Anchors shared by most rungs (re-grep; line numbers drift):

```text
descriptor mappers   source/quickbite/backends/ffi.d
                       ffiTypeFor (return), ffiArgumentTypeFor (arg),
                       ffiStructType, ffiSliceType, isSupportedScalarSlice
marshalling          source/quickbite/backends/ffi.d
                       marshalArgument, marshalSliceArgument,
                       unmarshalValue, unmarshalStruct
call + ABI order     source/quickbite/backends/ffi.d
                       callViaLibffi, abiSourceIndex, isOutPointer
entry points         source/quickbite/backends/ffi.d
                       tryCallNative, tryCallNativeMember, tryCallNativeImpl,
                       NativeThis, NativeCallException
libffi binding       source/quickbite/backends/libffi.d
call site + gates    source/quickbite/backends/interpreter/impl.d
                       Walker.runCallExpression (free-function and DotVarExp
                       member branches), throwNativeException,
                       applyNativeWritebacks, nativeOutParameterVariable,
                       resolveMemberFunction
no-source diagnostic source/quickbite/frontend/dmd/functions.d
                       hasNoAvailableSource, noAvailableSourceMessage
fixture style        tests/ut/backends/runner/rt/dependency_image.d
extern(C) regression tests/ut/backends/runner/rt/cstdlib.d (must stay green)
```

### 34.4 Increment 10 — D string slice return (Status: done, §33)

Fully specified in §33; implement it as written. **Contract:** unmarshal a D
`string` (`immutable(char)[]`) return into a backend-owned string `Value`.
**Code:** teach `ffiTypeFor` (the *return* mapper used by `callViaLibffi`) to
return `ffiStringSliceType()` for a `Tarray`-of-`Tchar`, and add a `Tarray`
case to `unmarshalValue` that copies `length` bytes from `ptr` into a
`Value(string)`. **Done:** `dep_image_string_return_fixture` green on
`SystemLinker` and `Interpreter`; §32 arg fixture and `rt/cstdlib.d` still
green. This is the first rung because every other slice rung reuses its
descriptor plumbing.

### 34.5 Increment 11 — typed (non-char) slice args and returns

**Status: implemented.** Generalize the slice ABI bridge from `char` elements
to any scalar element type, in both directions: `int[]`, `double[]`,
`wstring`, `dstring`. The descriptor is unchanged
(`{size_t length, void* ptr}`); only element marshalling widens.

**Oracle fixture.** Dependency image (body, then declaration-only):

```d
long dependencySum(const(long)[] xs);     // returns the element sum
const(int)[] dependencyTriple(int n);      // returns [n, n*2, n*3]
```

Source under test passes a local `long[]` and checks the returned `int[]`.

**In scope.** Immutable / `const` scalar-element dynamic arrays, read-only for
the call duration, copied out on return. `wstring`/`dstring` count as
`Twchar`/`Tdchar` element arrays.

**Out of scope.** Mutability/writeback (§34.9), arrays of structs or arrays of
arrays, arrays nested in structs (§34.10).

**Implementation.** Replace the `isSupportedStringSlice` (char-only) gate in
`ffiArgumentTypeFor`/`ffiTypeFor` with a "supported scalar slice element"
predicate. In `marshalStringSliceArgument`, size the keep-alive element buffer
by the element's basetype width instead of assuming `char`. Add the return-side
copy for each element width in `unmarshalValue`. Reuse the existing keep-alive
discipline so native code may not retain the pointer past the call.

**Done.** New typed-slice fixtures green on both backends; the §32/§33 char
fixtures and `rt/cstdlib.d` still green.

### 34.6 Increment 12 — stack-spilled extern(D) arguments

**Status: implemented.**

**Contract.** Allow `extern(D)` calls whose explicit arguments do not all fit
in registers (>6 integer/pointer or >8 SSE), and prove that D's "reverse the
explicit list, then classify" matches the oracle once some arguments land on
the stack. This is pure ABI correctness over the existing scalar surface — no
new type — and is the rung §27.3 explicitly deferred. It is high on the ladder
because real dub functions routinely exceed six parameters, and the call is
silently wrong today (it returns `false` and hits the no-source diagnostic).

**Oracle fixture.** An order-sensitive `extern(D)` free function with eight
`int` parameters whose body encodes argument position (e.g. base-10 positional
weighting), called with eight distinct constants. The oracle fixes the truth;
the Interpreter must match it after the spill is allowed.

**In scope.** `extern(D)` non-member functions, scalar/pointer explicit args
that spill the integer or SSE register file. `extern(C)` is unaffected (source
order, libffi already spills correctly).

**Out of scope.** Large by-value structs that themselves split across
registers and stack (their classification is its own verification — defer with
§34.6 sret work if a fixture needs it); member-call spill (compose with §28/§29
once this lands).

**Implementation.** `externDArgumentsFitRegisterScope` currently returns
`false` past 6 integer / 8 SSE registers — stop using that as a hard reject and
instead let `callViaLibffi` build the full reversed `(ffi_type*, bytes)` arrays
and hand them to libffi, which performs SysV stack classification itself.
Verify against the oracle that reversing the *explicit* list before libffi
classifies reproduces D's stack assignment; if it diverges, the divergence and
its fix belong in this rung with a comment. Keep the register-scope helper only
where it still gates an unsupported shape.

**Done.** Eight-arg `extern(D)` fixture green on both backends; every existing
register-only fixture (§27 two-arg, members, `rt/cstdlib.d`) still green.

### 34.7 Increment 13 — large struct returns via sret

**Contract.** Return structs large enough to use the hidden `sret` pointer
(beyond the in-register small structs that already work — `div`/`ldiv` are
green), including from `extern(D)` functions with explicit args, where the
`sret` pointer is a leading hidden argument that must sit *before* the reversed
explicit args.

**Oracle fixture.** `extern(D)` free function returning a >16-byte struct
(e.g. four `long` fields) computed from two explicit `int` args, so both the
sret placement and the §27 reversal are exercised together.

**In scope.** By-value struct returns through `sret`, free functions,
`extern(D)` and `extern(C)`. **Out of scope.** Member functions returning
structs via `sret` (compose later), structs containing slices/classes (§34.10).

**Implementation.** libffi already issues the memory-return ABI when given the
struct `ffi_type` (this is why small struct returns pass). The new work is
ordering: confirm libffi's own `sret` handling versus D's, and make the
hidden-argument ordering in `callViaLibffi`/`abiSourceIndex` place `sret`
ahead of the reversed explicit args, exactly as `this` is placed in §28. Verify
the layout assert (`ffiStructType` size vs DMD `structsize`) still holds after
`ffi_prep_cif`.

**Done.** Large-struct-return fixture green on both backends; `div`/`ldiv`
small-struct returns and the §27 reversal fixtures still green.

### 34.8 Increment 14 — scalar out-parameters with writeback

**Contract.** Support a single-level scalar out-pointer (`int*`, `double*`)
that the native function writes through, mapping the post-call value back into
the caller's variable. §24.6 deferred this because `int*` is ambiguous with an
ordinary in-pointer; this rung defines the disambiguation.

**Oracle fixture.** `extern(C)` or `extern(D)` `void f(int* out, int in)` that
sets `*out = in * 2`; source under test passes `&local` and asserts `local`.

**In scope.** One level of pointer-to-scalar treated as an out slot when the
call site passes `&local` (the `AddrExp`/`SymOffExp` shape
`nativeOutParameterVariable` already recognizes). **Out of scope.** Multi-level
indirection beyond the existing `char**` rule, struct-by-ref out, arrays.

**Implementation.** Today `isOutPointer` only treats pointer-to-pointer
(`char**`) as an out slot; a pointer-to-scalar is marshalled as an in-pointer.
Disambiguate by the *call-site argument expression*, not the type alone: when
the argument is `&local` (per `nativeOutParameterVariable`) and the parameter
is a single-level pointer-to-scalar, allocate a host cell, pass `&cell`, and
set `argumentWritebacks[sourceIndex]` to the post-call cell value — reusing the
existing `applyNativeWritebacks` path. A bare pointer value (not `&local`) stays
an in-pointer.

**Done.** Scalar out-param fixture green on both backends; `strtol`'s `char**`
endptr writeback and all `rt/cstdlib.d` still green.

### 34.9 Increment 15 — mutating struct member methods + receiver writeback

**Contract.** A struct member method that mutates `this` writes the receiver
back into the caller's variable. §28/§29 marshalled the receiver read-only;
this adds the write-back half.

**Oracle fixture.** `dep_image_member_fixture`-style struct with
`void bump(int by)` that does `value += by`; source under test calls
`counter.bump(5)` then asserts `counter.value`.

**In scope.** Non-virtual struct methods, receiver passed as hidden leading
`this` pointer, receiver copied back after the call. **Out of scope.** Class
receivers (§34.11), virtual methods, partial-field aliasing.

**Implementation.** In the member branch of `Walker.runCallExpression` /
`tryCallNativeMember`, after `ffi_call`, read the (possibly mutated) receiver
bytes from the native `this` buffer back through `unmarshalStruct` and assign
them to the receiver `VarDeclaration` — analogous to `applyNativeWritebacks`
but for the hidden receiver, which is *not* in `argumentWritebacks`. Gate to
receivers that are addressable locals.

**Done.** Mutating-member fixture green on both backends; §28/§29 read-only
member fixtures still green.

### 34.10 Increment 16 — mutable slice arguments with writeback

**Contract.** Pass a mutable D slice (`int[]`, `char[]`) that native code
writes through, and reflect the writes in the caller's array. This is the
first rung that needs the §11.2/§13 borrow + pin + writeback contract rather
than a copy.

**Oracle fixture.** `extern(D) void fill(int[] xs, int v)` that sets every
element to `v`; source under test passes a local `int[]` and asserts contents.

**In scope.** Single mutable scalar-element slice argument, written in place,
pinned across the call. **Out of scope.** Native code retaining the pointer
past the call, growing the slice, multiple aliasing mutable slices.

**Implementation.** Extend the slice marshaller (§34.5) so a *mutable* element
type marshals to a buffer that is copied back into the backend array `Value`
after `ffi_call`, with the buffer rooted (GC-visible) for the call duration per
§13. Reuse the writeback machinery; key the writeback to the source argument.
Reject any signature that lets the slice escape (no return aliasing, no
storage).

**Done.** Mutable-slice fixture green on both backends; immutable §34.5
fixtures still green.

### 34.11 Increment 17 — slices/arrays nested inside by-value structs

**Contract.** Marshal a by-value struct one of whose fields is a slice
(`struct S { string name; int id; }`), in both directions, combining §34.5's
slice descriptor with the existing recursive struct walk.

**Oracle fixture.** `extern(D) int score(S s)` reading `s.name.length` and
`s.id`; and a struct-returning variant.

**In scope.** Structs whose fields are scalars, pointers, and supported slices,
read-only. **Out of scope.** Nested structs of structs of slices beyond one
level if a fixture does not need it; mutable nested slices.

**Implementation.** In `ffiStructType`/`marshalArgument`/`unmarshalStruct`,
emit the `{length, ptr}` sub-descriptor for a slice field instead of rejecting
it, keeping each element buffer alive for the call. Reuse §34.5's element
marshalling per field.

**Done.** Nested-slice struct fixtures green on both backends; existing
by-value-struct fixtures (`div`, members) still green.

### 34.12 Increment 18 — class references, virtual dispatch, interfaces

**Contract.** Call a method on a native class reference through its vtable,
and on an interface through its interface table. This is the largest type-side
rung: it introduces a native class-object representation in the Interpreter and
real virtual dispatch across the boundary.

**Oracle fixture.** A dependency-image `class Widget { int draw(); }` with a
virtual method and a subclass override; source under test holds a base
reference to a derived instance and asserts the override runs.

**In scope.** `extern(D)` class instances supplied by the dependency image,
single-inheritance virtual dispatch, interface method calls. **Out of scope.**
Constructing native classes in the Interpreter (that is §34.12), `synchronized`,
`__monitor`, GC finalization ordering (governed by §13 / bytecode.md).

**Implementation.** Represent a native class reference as an opaque native
handle (§11.3) carrying the object pointer. A method call reads the vtable slot
from the object's `__vptr` at the DMD-computed index, resolves the function
pointer, and calls it through libffi with the handle as hidden `this`. This is
where `resolveMemberFunction`'s dynamic-dispatch result must be honored against
the *runtime* type, not the static one. Keep the handle GC-visible per §13.

**Done.** Virtual-dispatch and interface fixtures green on both backends;
struct-member fixtures (§28/§29) unaffected.

### 34.13 Increment 19 — constructors, destructors, postblits

**Contract.** Construct a native class/struct via its dependency-image
constructor, and run its destructor/postblit at the right points, so the
Interpreter can create and own native objects rather than only receive them.

**Oracle fixture.** A dependency-image type with a constructor that sets state
and a destructor with an observable side effect (e.g. increments a native
counter); source under test constructs, uses, and lets it go out of scope,
asserting both ran.

**In scope.** Explicit `new`/value construction of a dependency type, scoped
destruction, postblit on copy. **Out of scope.** GC-finalizer timing semantics
(those are native-layout/bytecode.md territory), `scope`/RAII corner cases
beyond the fixture.

**Implementation.** Route construction through the same chokepoint: resolve the
constructor `FuncDeclaration` (`__ctor`) and call it with the allocated
object's `this`. Hook destructor/postblit calls into the Interpreter's existing
scope-exit and copy paths, dispatching to the native `__dtor`/`__postblit`
leaves. Reuse §34.11 receiver handling.

**Done.** Construct/destruct/postblit fixtures green on both backends; member
and exception fixtures still green.

### 34.14 Increment 20 — native Error recovery and exception chaining

**Contract.** Two deferred exception items from §30/§31: carry a native
`Throwable.next` chain across the boundary, and define whether a native `Error`
can be observed at all (today it is fatal). Real libraries chain exceptions and
some throw `Error` subclasses the project may need to characterize.

**Oracle fixture.** A dependency function that throws an `Exception` whose
`.next` is another `Exception`; source under test asserts both messages down the
chain. (`Error` recovery, if pursued, is a separate approved fixture; default
remains "Error is fatal".)

**In scope.** Preserving `Throwable.next` and its message chain through
`NativeCallException`/`throwNativeException`. **Out of scope.** Turning `Error`
into an ordinary backend exception unless a fixture justifies it; exceptions
thrown after out-parameter writebacks.

**Implementation.** Extend `NativeCallException` to carry the chained
messages/types; rebuild the chain in `throwNativeException` as linked
interpreted exception values. Keep the §30 first-direction rule
(`Exception` → pending, `Error` → fatal) intact.

**Done.** Chained-exception fixture green on both backends; §30/§31 fixtures
still green; `Error` remains fatal unless separately approved.

### 34.15 Increment 21 — variadics

**Contract.** Call a C variadic function (`printf`-shaped) — the one signature
class §24.6 deferred because it needs libffi's variadic CIF path.

**Oracle fixture.** A dependency `extern(C) int format(const char* fmt, ...)`
exercised with a fixed, known set of trailing arguments whose result is
order-sensitive.

**In scope.** `extern(C)` variadics with a per-call argument list. **Out of
scope.** `extern(D)` variadics (`_argptr`/`TypeInfo` machinery — a separate
rung if ever needed), variadic templates (those are interpreted, not native).

**Implementation.** Bind `ffi_prep_cif_var` in `libffi.d` (the one piece of
surface §24.1 deliberately left unbound) and build a per-call CIF that splits
fixed from variadic args. Variadic calls cannot share a cached CIF.

**Done.** Variadic fixture green on both backends; all non-variadic fixtures
still green and still using the cached non-variadic CIF path.

### 34.16 Increment 22 — delegates / callbacks / closures (reverse bridge)

**Contract.** The §14 reverse bridge: pass an interpreted closure to a native
dependency API that calls it back (`sort!`, `setTimer`, etc.). This is the
capstone — the only rung where control re-enters the Interpreter *from* native
code — and the last thing standing between "call any dub leaf" and "run any dub
package that takes a callback".

**Oracle fixture.** A dependency `extern(D) int apply(int x, int delegate(int))`
that invokes the delegate; source under test passes an interpreted lambda
capturing a local and asserts the result.

**In scope.** A backend closure invoked through a generated native trampoline,
delegate context lifetime bounded by the call, closure state kept GC-visible
(§14). **Out of scope.** Callbacks that outlive the call/test without a durable
owner; template-heavy APIs where the callback is part of instantiated
dependency code (those are interpreted, per §10/§23).

**Implementation.** Use libffi closures: bind `ffi_closure_alloc` /
`ffi_prep_closure_loc` in `libffi.d`, register interpreted closures in a
GC-visible table keyed by callback id, and generate a trampoline whose user
data is that id; the trampoline re-enters `Walker` to run the closure and
marshals across as the forward path does in reverse. Define and enforce the
delegate-context lifetime: reject a callback that can escape the call boundary.

**Done.** Callback fixture green on both backends; no forward-path fixture
regresses; escaping callbacks are rejected with a clear diagnostic.

### 34.17 Increment 23 — extern(C++) ABI

**Contract.** Call `extern(C++)` free and member functions (name mangling and
the C++ `this`/ABI conventions). Lowest on the ladder: only dub packages that
bind C++ need it, and it is independent of the D-ladder rungs above.

**Oracle fixture.** A dependency `extern(C++)` function and a C++-linkage member
method, resolved by C++ mangling.

**In scope.** `extern(C++)` over the existing scalar/pointer/struct surface.
**Out of scope.** C++ exceptions, templates, multiple inheritance, RTTI.

**Implementation.** Add `LINK.cpp` to `isSupportedNativeLinkage`, resolve by the
C++ mangled name, and apply the C++ argument order (no extern(D) reversal). The
C++ `this` ABI may differ from D's hidden-argument placement; verify against the
oracle.

**Done.** `extern(C++)` fixture green on both backends; D and C linkage paths
unchanged.

### 34.18 After the ladder

When §34.4–§34.16 are landed, the Interpreter can call essentially any
non-template body-less leaf a dub package exposes, in both directions, with
native exceptions mapped back — i.e. the terminal goal of §34.1: interpret the
project, call the dependencies, run the whole dub project. What remains beyond
this ladder is not Interpreter FFI but the deferred, separately-owned work:

```text
- the §3-§20 cold-path dependency-image build, prepare command, wrapper
  manifest, and caching story (boxed-value infrastructure);
- the §23 native-layout bridge for Bytecode/IR (governed by bytecode.md);
- strict isolation, daemonized host, profiling-based promotion (§6, §19).
```

Those get their own plans when scheduled; they are out of this section's scope.
