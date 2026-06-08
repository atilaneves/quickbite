# Design: Native Dub Dependency Integration for a D Bytecode VM

## 1. Goal

The goal is to minimize the latency of the normal development loop:

```text
edit project code -> run unittests -> get result
```

The bytecode VM exists to avoid the cost of repeatedly compiling and
linking the project under test to native code. However, real D
projects usually depend on dub packages, Phobos, druntime, C
libraries, OS services, and other native facilities. Reimplementing or
emulating those dependencies inside the VM would be both expensive and
semantically fragile.

The intended design is therefore a mixed-mode execution model:

```text
project-under-test code: bytecode
dub dependencies: native code, compiled and cached ahead of time
interop boundary: generated wrapper thunks
runtime: same process, same druntime, same GC, same OS access
```

Dependency-side work may be expensive, but it must be moved out of the
hot edit-test path.

## 2. Non-goals

This design does not attempt to:

```text
- load arbitrary .o files directly;
- implement a D linker inside the VM;
- emulate filesystem, sockets, threads, GC, TLS, or druntime behavior;
- make dependency execution hermetic by default;
- call arbitrary extern(D) functions directly from bytecode;
- make all dub dependency code native purely because it came from a dub package.
```

The design is optimized for fast feedback, not full process isolation.

## 3. High-level architecture

The system consists of two paths: a cold dependency preparation path
and a hot project execution path.

```text
Cold path, rarely run:
  dub resolve
  compile dependencies native
  generate dependency/native wrappers
  link/load native dependency image
  cache manifests and metadata

Hot path, per edit:
  parse/sema changed project modules
  bytecode-compile project-under-test
  execute VM unittests
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
```

The hot path should not invoke dub, compile dependencies, generate
wrappers, link native code, or resolve native symbols by name.

## 4. Native dependency image

Dub dependencies are compiled into a cached native image.

Possible forms:

```text
libquickbite_deps_<hash>.so
libquickbite_deps_<hash>.dylib
quickbite_deps_<hash>.dll
linked native object bundle
```

The preferred model is a shared library loaded by a persistent
Quickbite host process.

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
wrapper ABI version
Quickbite dependency ABI version
```

The cache key should not include ordinary project source files under
edit, except where template instantiations or generated wrappers
depend on project-specific code.

The output directory may look like:

```text
.quickbite/
  deps/
    <hash>/
      libquickbite_deps_<hash>.so
      wrappers.d
      wrappers.o
      wrapper_manifest.qb
      abi_manifest.qb
      dependency_summary.qb
      build_manifest.qb
```

## 5. Same-process execution

Dependencies live in the same process as the VM.

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
threads
environment variables
process APIs
```

This matches ordinary compiled D execution much more closely than a
sandboxed or emulated dependency model.

The host process contains:

```text
quickbite-host executable
  ├─ druntime / Phobos
  ├─ bytecode VM
  ├─ dependency native image
  ├─ generated wrapper table
  └─ bytecode for project-under-test
```

The main runtime transition is:

```text
bytecode VM
  -> generated native wrapper thunk
      -> real compiled D dependency function
```

## 6. Persistent daemon

For lowest edit-test latency, the preferred runtime is a persistent
daemon.

The daemon keeps resident:

```text
druntime
loaded native dependency image
wrapper table
dependency metadata
possibly dmd frontend state
test discovery cache
VM infrastructure
```

Per edit, the daemon receives changed project code or a test request,
invalidates affected project modules, emits bytecode, resets VM state,
and runs tests.

This avoids repeated process startup, dependency loading, module
construction, and wrapper table initialization.

There should be at least two modes:

```text
fast mode:
  persistent process
  dependency module constructors run once
  native globals persist between test runs

strict mode:
  fresh process or stronger reset behavior
  closer to normal dub test isolation
```

Fast mode is the default for quick feedback. Strict mode is used when
native global state or module constructor behavior affects
correctness.

## 7. Wrapper-based native calls

The VM should not call arbitrary dependency functions directly.

Instead, dependency calls go through generated wrapper thunks. The
wrapper is responsible for converting VM values into D values, calling
the real dependency function, catching exceptions, and converting the
result back into VM representation.

Generic wrapper shape:

```d
extern(C)
VMValue qb_dep_37(VMContext* ctx, VMValue* args, size_t nargs)
{
    try
    {
        auto path = args[0].toDString();
        auto result = package.foo.readConfig(path);
        return VMValue.from(ctx, result);
    }
    catch (Throwable t)
    {
        return ctx.throwNative(t);
    }
}
```

Bytecode uses numeric IDs:

```text
CALL_DEP 37, argc=1
```

Runtime call path:

```d
auto thunk = ctx.depThunks[37];
auto result = thunk(ctx, args.ptr, args.length);
```

There should be no string lookup, symbol lookup, reflection, or
signature decoding in the hot path.

## 8. Generic versus specialized thunks

Two wrapper tiers are useful.

### 8.1 Generic wrappers

Generic wrappers use boxed `VMValue` arguments and return a boxed
`VMValue`.

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
int qb_dep_91_i32_i32_to_i32(VMContext* ctx, int a, int b)
{
    return dep.fastAdd(a, b);
}
```

Bytecode may use specialized instructions:

```text
CALL_DEP_I32_I32_TO_I32 91
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
compile processOne to bytecode if its source/body is available and simple
```

The compiler should detect dependency calls inside loops and classify
them carefully.

Possible policies:

```text
small dependency function + body available:
  bytecode-compile or inline

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
    execute bytecode
```

Better rule:

```text
if concrete function body should be executed by VM:
    compile to bytecode

elif concrete function has cached native implementation:
    call wrapper thunk

elif function is template-instantiated with project code:
    compile instantiated body to bytecode or cache separately by instantiation hash

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
handled as bytecode or as a separately cached specialization, not as a
simple call into precompiled dependency code.

By contrast:

```d
auto text = readText("foo.txt");
```

can reasonably be a native dependency call.

## 11. Value representation across the boundary

Values crossing the VM/native boundary fall into three categories.

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
VM string -> native string valid for duration of call, or GC-owned copy
native string -> VM-owned copy, unless explicitly borrowed
VM array -> native slice with clear ownership/lifetime
native array -> VM-owned copy or native handle, depending on type
```

### 11.3 Opaque native values

The VM should not inspect complex native values such as:

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

The VM represents `f` as an opaque handle. `readln` becomes another
native wrapper call that receives the handle.

## 12. Exceptions

Native D code may throw. Exceptions should not initially unwind
through arbitrary VM interpreter frames.

Wrapper boundary rule:

```d
try
{
    auto r = realDependencyFunction(...);
    return VMValue.from(ctx, r);
}
catch (Throwable t)
{
    return ctx.throwNative(t);
}
```

The VM then maps the native throwable into its own exception state.

Initial support:

```text
native exception -> VM pending exception
VM handles or reports it
```

Later support:

```text
bytecode exception -> native D Throwable when native code calls back into bytecode
```

The second direction is harder and can be deferred.

## 13. GC and lifetime

Because the VM and native dependencies share one D runtime, native GC
allocation works normally.

However, VM storage must not hide GC references from the collector.

If VM values can contain D GC pointers, then one of the following must
be true:

```text
VM frames are allocated in GC-scanned memory
GC references are stored in GC-managed objects
VM registers/stacks are registered as roots
VM avoids raw GC pointers in unscanned malloc memory
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

A conservative initial design should copy simple data into VM-owned
representations and use GC-visible handle tables for native
references.

## 14. Native callbacks into bytecode

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
      -> VM invokes bytecode closure
```

Initial implementation may reject callbacks/delegates crossing into
native dependency code.

Eventually, callback support requires generated native trampolines and
a bytecode closure registry.

The hard cases are template-heavy D APIs where the callback is part of
the instantiated dependency code. These may be better handled by
bytecode-compiling the instantiated template body instead of using
native callbacks.

## 15. Build pipeline

### 15.1 Preparation command

A command such as:

```text
quickbite prepare
```

performs the cold dependency work:

```text
1. run or query dub dependency resolution
2. compute dependency cache key
3. check for existing dependency image
4. compile dub dependencies natively if needed
5. analyze reachable dependency call boundaries
6. generate wrapper source
7. compile wrappers
8. link dependency image
9. write wrapper and ABI manifests
```

### 15.2 Test command

A command such as:

```text
quickbite test
```

performs the hot path:

```text
1. check dependency image freshness
2. connect to daemon or start host
3. parse/sema changed project modules
4. emit bytecode
5. run selected unittests in VM
6. report result
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
semantic symbols to numeric IDs.

Example:

```text
wrapper 37:
  symbol: package.foo.readConfig
  kind: generic
  args: [string]
  return: Config
  thunk: qb_dep_37

wrapper 91:
  symbol: dep.fastAdd
  kind: specialized
  args: [int, int]
  return: int
  thunk: qb_dep_91_i32_i32_to_i32
```

The bytecode compiler uses this manifest to emit:

```text
CALL_DEP 37
CALL_DEP_I32_I32_TO_I32 91
```

The runtime uses the same manifest to initialize the thunk table.

## 17. Hot-path invariant

The hot edit-test path must avoid:

```text
dub invocation
dependency native compilation
dependency linking
wrapper generation
symbol lookup by name
dependency module construction
full process startup, in daemon mode
```

The hot path should be approximately:

```text
changed D source
  -> dmd frontend parse/sema
  -> bytecode emit
  -> VM run
  -> cached native calls by integer ID
```

This is the shape that can plausibly beat normal `dub test`.

## 18. Initial MVP

The first useful implementation should support:

```text
same-process native host
dependency shared library cache
generated generic wrappers
numeric wrapper IDs
bytecode project modules
scalars: int, long, bool, float, double
strings
basic dynamic arrays
opaque native handles
native Throwable -> VM exception state
persistent daemon
explicit dependency prepare step
```

The MVP may reject:

```text
callbacks from native into bytecode
delegates crossing the boundary
complex structs by value
ref/out parameters
native code calling bytecode functions
direct extern(D) ABI calls without wrappers
template instantiations requiring native/project mixed code
```

## 19. Later extensions

After the MVP:

```text
specialized unboxed wrappers
profiling-based wrapper promotion
bytecode compilation of small dependency functions
loop-aware native call avoidance
struct field bridging
ref/out support
delegate/callback trampolines
native-to-bytecode calls
strict isolation mode
dependency image unloading/reloading
incremental wrapper generation
cached native template specializations
```

## 20. Summary

The design should treat dub dependencies as stable native
infrastructure and project code as volatile bytecode.

The main principle is:

```text
pay dependency cost rarely;
pay project compilation cost cheaply;
make native calls cheap and pre-indexed;
avoid native/VM crossings in tight loops;
do not put dub, linking, or wrapper generation in the edit-test path.
```

This yields a mixed-mode execution system where dependency code runs
normally as native D code, while edited project code can be recompiled
to bytecode quickly enough to improve the unit-test feedback loop.
