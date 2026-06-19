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

## 24. Increment 3: descriptor-driven resident calls (Interpreter)

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
`ffi_prep_cif`, `ffi_prep_cif_var`, `ffi_call`, and the predefined
`ffi_type_*` globals — with `pragma(lib, "ffi")` in-file and `libs "ffi"` in
`dub.sdl`. No new dub dependency, no libffi dev headers.

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
