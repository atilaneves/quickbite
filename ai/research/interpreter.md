# Research: the native-place Interpreter endpoint

## Purpose

This document is the precedent survey behind the Interpreter's carrier-free
storage and typed-address native-call boundaries. The current contracts live
in AGENTS.md's "Runtime semantics" section; display belongs to
`ai/plans/repl.md`. This file
records the surveyed projects, the questions each was evaluated against, the
conclusions the survey supports, and the pinned primary sources.

Research date: 2026-08-11.

## How precedents were selected

The survey prioritized statically typed languages and typed intermediate
representations. Dynamic-language FFI packages were not used as architectural
authority.

Each project was evaluated against these questions:

- What is the project's actual goal?
- Does it optimize one-time bootstrap, per-edit invalidation, throughput,
  portability, safety analysis, constexpr evaluation, embedding convenience,
  or interactive compilation?
- Are values in target-native layout?
- Are aggregates recursive boxes, memory-backed values, or references?
- What does the hot native-call path do?
- What work is cached, and when is it paid?
- How are interpreted callables represented?
- Are inbound callbacks the same interface as outbound calls?
- Which conclusions transfer to Quickbite's edit-to-test-verdict objective?

No representation was accepted merely because another interpreter uses it.

## Typed precedent survey

### DMD CTFE

DMD's compile-time function evaluator is the most directly relevant
counterexample because it evaluates the same language and reuses DMD's
semantic AST.

It recursively returns `Expression` objects. Stored variables and aggregates
are expression subclasses; structs, arrays, and associative arrays are literal
expression graphs and are copied in several evaluation paths. `CTFEGoal`
distinguishes rvalues, lvalues, and no-result execution, and a region allocator
reduces collection pressure.

Arbitrary extern calls are not the goal. CTFE requires interpretable function
bodies or compiler-recognized builtins.

Transferable lessons:

- distinguish rvalue, lvalue, and no-result evaluation; and
- use scoped allocation where temporary objects are genuinely necessary.

Do not transfer the AST-expression value model. It is designed for
target-independent compile-time semantics, not host-native unit-test execution
or low-overhead FFI.

Primary sources:

- [DMD CTFE evaluator][dmd-ctfe]
- [D CTFE specification][d-ctfe-spec]

### Clang constant interpreter

Clang's newer constant interpreter was built to improve the performance of an
older AST-walking constexpr evaluator. It uses strongly typed opcodes and an
aligned `InterpStack`. A call frame reserves all locals in one allocation.

It makes a particularly relevant demand-sensitive choice: reusable functions
compile to bytecode, while one-shot top-level expressions can be executed
directly by `EvalEmitter` as they are compiled, avoiding bytecode that will
never be reused. For Quickbite, the relevant question is whether preparation
survives the next edit, not merely whether it is paid during initial startup.

Its memory model is still for C++ constant evaluation. Blocks interleave data
with lifetime, initialization, and pointer metadata and do not simply expose
host-native objects to arbitrary FFI.

Transferable lessons:

- type-specialize operations instead of inspecting a universal runtime tag;
- allocate frame locals together;
- use reusable aligned LIFO storage for scalar operand traffic; and
- do not generate an execution representation for one-shot work unless reuse
  pays for it.

Clang's `InterpStack` does not prove that arbitrary addressable D temporaries
can be plain LIFO bytes. Clang represents composite objects and lifetime state
with `Block` and `Descriptor` machinery, including destruction and dead-block
tracking. Do not transfer that abstract constexpr memory metadata as D runtime
storage.

Primary source: [Clang Constant Interpreter][clang-const-interp].

### GCC C++ constexpr evaluator

GCC's constexpr implementation is another typed AST/tree evaluator. Locals and
temporaries map compiler trees to compiler trees; aggregates are constructor
trees; caches reduce repeated evaluation.

It has no arbitrary native FFI path because its goal is language-mandated
constant evaluation. It shows that sophisticated caching can mitigate a boxed
tree model without making that model suitable for runtime tests.

Primary source: [GCC constexpr evaluator][gcc-constexpr].

### rustc CTFE and Miri

Rust's MIR interpreter has the closest value/place split found in the survey.
A local or operand is either:

- an `Immediate`, limited to one scalar, a scalar pair, or uninitialized; or
- an indirect memory place.

Arbitrary-sized aggregates remain in target-layout virtual memory. Typed
`PlaceTy` and `MPlaceTy` designate destinations, and copying writes operands to
places. Function-call evaluation carries a destination place.

This is evidence against an arbitrary-sized universal value and in favor of
destination passing. It is not evidence for retaining a smaller carrier:
rustc still needs an operand enum because it is a generic MIR abstract
machine, whereas Quickbite's tree walker can invoke statically typed helpers
from statically typed AST nodes.

Miri adds allocation identities, pointer provenance, validity checking,
cross-target behavior, and isolation because its product is undefined-behavior
detection. Its experimental native bridge constructs libffi descriptions,
copies values between virtual and native memory, and traces exposed memory.
Those costs buy Miri's abstract-machine guarantees and are the wrong trade-off
for Quickbite.

Transferable lessons:

- keep large values indirect;
- treat places and operands as different concepts;
- write results into destinations; and
- keep interpreted callable identity distinct from executable native code.

Do not transfer allocation IDs, provenance, per-call virtual/native copying,
or Miri's safety-analysis overhead.

Primary sources:

- [rustc interpreter overview][rustc-interp]
- [Rust `Operand`][rust-operand]
- [Rust `Immediate`][rust-immediate]
- [Rust `PlaceTy`][rust-place]
- [Rust place copying][rust-copy]
- [Miri project and limitations][miri]
- [Miri native bridge][miri-native]

### Zig comptime

Zig fuses semantic analysis and compile-time execution. A `Value` is primarily
an index into the compiler's `InternPool`; aggregates may be interned as bytes,
element indices, or repeated elements. Mutable comptime allocations also have
compiler identities.

Interning and pure-call memoization serve compiler canonicalization and
compile-time reuse. Calling arbitrary extern functions at comptime is not the
goal.

Transferable lessons are limited to demand-driven semantic work, arenas, and
possibly memoizing proven-pure work. Intern-pool lookup and compiler allocation
identity should not be placed on Quickbite's runtime or FFI path.

Primary sources:

- [Zig semantic interpreter][zig-sema]
- [Zig values][zig-value]
- [Zig intern pool][zig-intern]
- [Zig comptime language reference][zig-comptime]

### Nim VM

Nim compiles macros and compile-time code to a register VM. Each procedure has
a known number of register slots, and the compiler reuses slots. A `TFullReg`
is nevertheless a tagged union containing integers, floats, AST nodes, and
addresses. Complex values remain recursive `PNode` structures.

Nim's optional compile-time FFI demonstrates the cost of that choice: it
converts registers to AST nodes, allocates native buffers, recursively packs
aggregates, calls libffi, and unpacks the result.

Transferable lessons:

- pre-size declaration/frame storage where doing so is cheap; and
- reuse temporary slots rather than allocating one object per operation.

Do not transfer tagged registers, AST aggregates, or FFI pack/unpack.

Primary sources:

- [Nim VM definitions][nim-vmdef]
- [Nim VM execution][nim-vm]
- [Nim compile-time FFI][nim-evalffi]

### Go Yaegi

Yaegi is a statically typed Go interpreter optimized for embeddability and
interaction with already compiled Go packages. Every frame is a slice of
`reflect.Value`. Host calls build reflection argument/result slices and use
`reflect.Value.Call`; interpreted functions become host-callable through
`reflect.MakeFunc`.

This buys a broad embedding interface, but it boxes every frame and boundary.
Yaegi also does not provide general C FFI. It is a functionality precedent for
bidirectional host interaction and a performance counterexample for
Quickbite.

Primary sources:

- [Yaegi frames][yaegi-frame]
- [Yaegi execution and calls][yaegi-run]
- [Yaegi public API][yaegi-api]

### LLVM Interpreter

LLVM's legacy Interpreter stores every SSA result as `GenericValue` in a map.
`GenericValue` is a scalar union plus a recursive vector of `GenericValue` for
aggregates. This is extremely close to the design Quickbite is leaving.

Interpreted function pointers are stable `Function*` descriptor tokens cast to
`void*`; indirect interpreted calls recover the descriptor. That token is not
an executable native callback.

The native symbol address is cached, but the Interpreter recreates libffi type
arrays, argument storage, result storage, and `ffi_cif` preparation on each
call. Aggregate native calls are limited, and no inbound trampoline is
provided.

Transferable lessons:

- a stable descriptor can be the internal identity of an interpreted
  callable; and
- symbol lookup belongs outside the repeated call path.

Do not transfer `GenericValue`, recursive aggregate values, value maps, or
per-call CIF preparation.

Primary sources:

- [LLVM `GenericValue`][llvm-generic-value]
- [LLVM Interpreter frames and tokens][llvm-interpreter]
- [LLVM Interpreter native calls][llvm-external]

### Clang-Repl and Cling

Clang-Repl and Cling are called interpreters but incrementally compile source
to LLVM IR and JIT it to native code. Native calls then have ordinary compiled
overhead, but AST lowering, IR generation, JIT compilation, and relocation are
paid before execution.

Clang-Repl also has a `Value` at the result-capture boundary. It maps a static
C++ type to JIT-owned memory and supports small scalar storage and
reference-counted object storage. That `Value` is for REPL result retention and
cross-language embedding, not the execution currency of the JITted program.

This distinction is useful: a boundary-only result helper need not infect
execution. Quickbite can go further and expose only a display string or a
test-supplied typed destination.

The JIT pipeline does not transfer by default because lowering and generating
changed code would be repeated after edits, and Quickbite's tests can finish
before that per-edit cost is recovered. JITting stable dependency code once at
project bootstrap is a different trade-off, but is outside the current
bytecode-VM goal.

Primary source: [Clang-Repl documentation][clang-repl].

### GHCi bytecode interpreter

GHCi normally compiles loaded Haskell modules to bytecode and runs them in the
RTS. The interpreter stack is host-word aligned; subword values are extended
to words. Bytecode objects carry GC bitmaps and separate pointer/non-pointer
literal tables. Haskell values with identity remain RTS heap closures rather
than recursive variants in every stack slot. GHCi links bytecode into a
long-lived RTS session; it is not designed around Quickbite's source-edit
invalidation frontier.

Its native-call path is highly relevant. A `CCALL` bytecode instruction carries
typed FFI information. Linking prepares every FFI descriptor in the linked BCO
and places the prepared token in the bytecode. Repeated execution supplies the
target pointer and argument/result addresses. This proves preparation can stay
out of the hot call. It does not prove first-executed-call preparation is the
right Quickbite granularity.

Inbound Haskell callbacks use a distinct typed wrapper/`FunPtr` facility with
explicit lifetime. They are not ordinary outbound `CCALL` operations run
backwards.

Transferable lessons:

- prepare ABI facts before repeated calls;
- keep the resolved target and prepared signature out of the hot call body;
- store raw execution words with side type/GC information; and
- model callbacks as a separate direction and lifetime.

Quickbite must separately choose whether a still-valid signature is prepared
during project bootstrap, bytecode linking, or first execution according to
its cross-edit reuse and incremental latency.

Do not transfer lazy STG closures, thunks, partial applications, scheduler
semantics, or the Haskell heap representation.

Primary sources:

- [GHC bytecode instructions][ghc-bytecode]
- [GHC bytecode types][ghc-bco]
- [GHC bytecode linker][ghc-linker]
- [GHC RTS interpreter][ghc-rts-interpreter]
- [GHC FFI preparation][ghc-ffi-prep]
- [GHC FFI guide][ghc-ffi-guide]
- [Haskell FFI specification][haskell-ffi]

### OCaml bytecode

OCaml's bytecode interpreter has a `value*` stack and a `value` accumulator.
`value` is one machine word: a tagged immediate or a pointer to an OCaml block
whose header describes its runtime representation. Its C-call opcodes invoke a
fixed all-`value` OCaml primitive ABI, not arbitrary native signatures. The
design optimizes execution inside OCaml's managed runtime and heap.

This design is efficient for OCaml because the entire language and runtime use
that representation. It is not evidence that a native-layout D interpreter
should introduce a one-word or tagged universal value. The transferable part
is prebinding native primitive indices. Native-held OCaml values must be rooted
or recovered through the named-root registry.

Primary sources:

- [OCaml bytecode interpreter][ocaml-interp]
- [OCaml value representation][ocaml-values]
- [OCaml C interface][ocaml-c]

### Mono and broader CLR interpreter boundaries

Mono's interpreter uses a nonrecursive `stackval` union for scalar, object, and
native-pointer operands. Crucially, CLR value types on the evaluation stack are
represented as pointers to their actual storage rather than recursively boxed
inside `stackval`. The execution context owns contiguous stack storage and GC
metadata. These are Mono representation facts, designed for a generic managed
IL runtime and repeated method execution.

The broader CoreCLR ABI separately shows that P/Invoke and indirect calls keep
method identity, target address, and signature metadata distinct. Normal
P/Invoke can share stubs by signature while retaining the exact method
identity. CoreCLR's Wasm interpreter transition ABI uses `pArgs` and `pRet`
storage, and reverse P/Invoke is a separate thunk direction. Those facts do not
by themselves describe Mono's native P/Invoke implementation on general hosts.

This is one of the closest runtime precedents, but its scalar union is required
by a generic IL instruction loop and CLR evaluation-stack semantics. It does
not prove that a statically dispatched D AST walker needs an equivalent union.

Transferable lessons:

- keep value types in authoritative out-of-line storage;
- use contiguous reusable frame storage;
- pass argument and result addresses across execution boundaries; and
- separate reusable signature metadata from exact callable identity.

Do not transfer CLR boxing, object semantics, tiering, deoptimization, or its
managed marshaller.

Primary sources:

- [Mono interpreter internals][mono-interp]
- [Mono interpreter execution][mono-exec]
- [CLR ABI and interpreter transitions][clr-abi]
- [.NET callback lifetime][dotnet-callback]

### HotSpot template interpreter and JNI

JVM frames have typed locals and operand-stack slots. Objects remain GC
references rather than inline recursive values. HotSpot's first native entry
resolves and stores the native address and a signature-specific handler;
repeated calls use the cached handler. Very large signatures have an explicit
slow path. HotSpot optimizes long-lived JVM/JNI method execution, not
incremental source verification.

JNI separates symbol lookup, native invocation, and native-to-Java method
calls. The `Call<Type>MethodA` forms interpret an untagged `jvalue[]` according
to the method signature; JNI also offers varargs and `va_list` forms. Inbound
calls require an attached thread, a `JNIEnv*`, method IDs, and explicit object
handle lifetimes. JNI does not manufacture an arbitrary retainable C ABI
function pointer for a Java method.

Transferable lessons:

- lazily resolve both target and signature handling;
- retain or reference them from a call site or callable while allowing
  signature-keyed ownership; and
- make inbound ownership and direction explicit.

Do not transfer Java's fixed type universe, GC-only object model, handle frames,
or generated architecture handlers without Quickbite measurements.

Primary sources:

- [JVM frame specification][jvms-frames]
- [HotSpot interpreter state][hotspot-interp]
- [HotSpot native entry][hotspot-native]
- [JNI design][jni-design]
- [JNI functions][jni-functions]

### .NET expression-tree interpreter

The LINQ expression-tree interpreter is a useful negative typed precedent. It
optimizes away dynamic-code-generation startup, but its `InterpretedFrame`
stores locals and the operand stack in `object?[] Data`. Primitive pushes box
into that array. It can later adapt or compile delegates.

That trade-off is rational for a general managed expression-tree API. It is
also a close warning against letting low compilation latency justify permanent
boxing in Quickbite: the resulting per-operation and interop costs remain on
every short test.

Primary sources:

- [.NET interpreted frame][dotnet-frame]
- [.NET interpreted lambda][dotnet-lambda]

### Typed WebAssembly interpreters

Typed WebAssembly engines have a much smaller value universe than D and put
aggregates in linear memory, so their representations are not directly
portable. They still provide useful execution and boundary lessons.

Wasmtime Pulley uses separate integer, floating-point, and vector registers
plus a VM stack. Calls use retained function descriptors and raw argument and
result buffers. Its RFC explicitly says minimum time-to-first-execution is a
non-goal: it lowers through Cranelift optimization and register allocation to
improve throughput. Slow one-time startup is not itself a problem for
Quickbite. The non-transferable risk is repeating that lowering for code
invalidated by every edit before running millisecond tests. Typed registers and
retained descriptors remain useful ideas.

WAMR's fast interpreter uses contiguous 32-bit cells addressed by precomputed
offsets; wider values use several cells. Native symbols are registered with
names, addresses, and signatures before loading. Its fastest host-call paths
are architecture-specific. Inbound re-entry uses explicit table indices rather
than pretending every guest function is a C pointer.

WABT's tooling interpreter uses an inline union and a vector operand stack,
plus indexed function descriptors and `std::function` host callbacks. It
prioritizes clarity and tool integration rather than FFI latency.

Transferable lessons:

- use statically selected opcodes or register classes and allocation-free
  storage;
- precompute offsets when the result can survive edits or a bytecode
  instruction will be reused;
- retain callable descriptors and native registrations; and
- distinguish guest callable identity from a platform ABI callback pointer.

Do not transfer linear-memory aggregate rules, sandbox pointer conversion, raw
cell stacks, generic maximum-sized value unions, or Pulley's lowering pipeline
without proving that its invalidated per-edit work improves total verification
latency.

Primary sources:

- [Pulley RFC][pulley-rfc]
- [Pulley interpreter][pulley-interp]
- [Wasmtime function descriptors][wasmtime-func]
- [WAMR fast interpreter][wamr-fast]
- [WAMR native API][wamr-native]
- [WAMR embedding guide][wamr-embed]
- [WABT interpreter types][wabt-types]
- [WABT execution][wabt-exec]

### GraalVM Sulong and Truffle NFI

Sulong stores primitive SSA temporaries in typed Truffle frame slots and uses a
lazy aligned native stack for native-mode allocations. An interpreted function
is an `LLVMFunctionDescriptor`; a native wrapper is created and cached only
when the descriptor is converted to native.

Truffle NFI prepares reusable native state during signature construction and
preparation, then binds that signature to a symbol separately. Its hot native
implementation receives primitive-byte and object/patch arrays through JNI
before `ffi_call`. Callback signatures have explicit call-duration or
manual-release ownership.

Transferable lessons:

- prepare signatures once;
- create executable wrappers only on actual native escape; and
- make callback ownership explicit.

Do not transfer Truffle objects, JNI array packing, native/managed pointer
patching, or reliance on JIT specialization.

Primary sources:

- [Sulong typed frame writes][sulong-frame]
- [Sulong native stack][sulong-stack]
- [Sulong function descriptor][sulong-function]
- [Truffle NFI][truffle-nfi]
- [Truffle NFI native implementation][truffle-nfi-source]

### libffi

libffi is a call mechanism rather than a language interpreter, but its split is
the clearest native boundary precedent:

1. prepare an `ffi_cif` from an ABI and types;
2. retain the CIF and its type graph; and
3. call an already-resolved function pointer with a result address and an
   array of pointers to argument storage.

libffi does not resolve libraries or symbols and does not need a guest value
model. Inbound closures are a separate API family with executable storage and
an explicit lifetime.

Recent libffi also exposes a reusable `ffi_call_plan` built from a prepared
CIF. The plan can remove work that ordinary `ffi_call` would repeat, although
a valid plan may fall back to `ffi_call` when no accelerated path exists. If
the project's libffi supplies this API, its plan is another reusable
physical-call artifact to cache and invalidate separately from the target
address.

This is almost exactly the deep boundary Quickbite needs for non-vector calls.
Any libffi-required narrow-result scratch is physical ABI scratch, not a
general representation conversion seam.

Primary source: [libffi manual][libffi].

## Projects considered but not adopted as representation precedents

Several typed interactive systems avoid a boxed interpreter by compiling
snippets:

- Clang-Repl and Cling lower to LLVM and JIT;
- [JShell][jshell] compiles Java snippets for a JVM execution engine;
- [F# Interactive][fsi] compiles and executes submissions;
- [EVCXR][evcxr] compiles Rust snippets; and
- [LLDB expression evaluation][lldb-expressions] uses a full compiler and
  either interprets a restricted expression or JITs it.

They demonstrate a real alternative: pay compilation and loading so execution
and native calls are ordinary compiled operations. Quickbite explicitly
rejects that default because code generation can dominate millisecond unit
tests. They remain useful comparison points if real measurements ever show a
specific small generated stub can repay its own cost.

Managed bytecode systems such as OCaml, the JVM, and the CLR use uniform words,
tagged values, or scalar unions because their language runtime defines those
representations. Their call caching and storage-lifetime techniques transfer;
their universal runtime values do not.

Reference, symbolic, or safety interpreters such as WABT, Miri, KLEE, and
compiler constexpr evaluators intentionally preserve metadata or abstract
identity that compiled host code does not. That is part of their product and a
cost Quickbite should not inherit.

## Conclusions supported by the survey

### 1. Representation follows the product goal

There is no useful answer to "what do interpreters do?" without first asking
what they optimize. DMD CTFE, Miri, Yaegi, HotSpot, and Pulley make different
choices because they solve different problems.

For Quickbite, agreement with compiled D on the host and minimum test-verdict
latency favor native bytes and host addresses. Cross-target symbolic identity,
managed-object uniformity, reflection, and JIT throughput do not justify a
runtime box.

### 2. A universal expression result is not the endpoint

A smaller, nonrecursive sum type is still a universal runtime value. It still:

- makes every expression return the same broad type;
- centralizes arithmetic, casts, equality, formatting support, call support,
  and type switching;
- requires every new D value category to answer how it fits the carrier;
- puts a branch and often a copy between static AST type information and
  native storage; and
- encourages native calls to grow an Interpreter adapter.

The survey found scalar unions in generic bytecode/IR loops, but no reason a
statically dispatched tree walker must copy that design. The frontend has
already typed every expression. The Interpreter now implements this endpoint:
production expression evaluation uses typed places and caller-provided
destinations, with no universal expression-result carrier.

### 3. Destination passing best matches the evidence

The surveyed tree walkers and native execution boundaries support separating
no-result execution, place evaluation, construction, and assignment. That
split uses the frontend's static types directly, leaves aggregates in native
storage, and avoids routing unrelated D values through one host type.

Construction and assignment remain distinct because D gives live-object
assignment different aliasing, postblit, move, destruction, and failure
semantics from initialization. Statically typed host locals can carry scalar
intermediates without becoming a guest-value currency.

AGENTS.md's "Runtime semantics" section is the normative evaluator contract.
This survey records why that contract was chosen; it does not define its
operations or invariants.

### 4. Locals and expression temporaries have different lifetimes

Declarations naturally fit fixed native frame/module storage. Expression
temporaries mostly disappear into caller destinations or statically typed
host locals, but addressable temporaries still require activation-owned
storage.

When a temporary must be addressable, two unboxed designs remain plausible:

- per-activation typed temporary offsets computed with the function's cached
  frame layout; or
- segmented aligned scratch allocated along the executed path, with lexical
  marks and cleanup records.

Neither candidate requires a universal value. Fixed offsets can reuse body
layout work, while segmented scratch can avoid reserving unexecuted paths.
Both have to associate runtime bytes with an activation rather than an AST
node to survive recursion and re-entry.

LIFO allocation does not mean a temporary can be rewound after any expression
or call. D normally defers temporary destruction to the full-expression
boundary, destroys in reverse construction order, gives the evaluated
right-hand side of `&&` and `||` a special boundary, and destroys already
constructed temporaries when an exception unwinds. Rewind may occur only after
the matching cleanup records have run.

Stable addresses, GC visibility, cleanup on unwind, recursion, and native
callback re-entry are therefore discriminating constraints. Clang's
`InterpStack` supports LIFO scalar operand traffic, but addressable composites
use separate lifetime-aware `Block` and `Descriptor` machinery.

The existing Interpreter caches whole-body frame layout for one root
execution. That cache does not survive a new root or a source edit, so the
survey gives neither candidate presumed cross-edit reuse credit. The
Interpreter's addressable-temporary guardrail requires a new measurement
before a different storage strategy.

Primary source for D temporary lifetime rules: [D expressions][d-expressions].

### 5. Interpreted callable identity is not native callability

LLVM, Clang, Wasm engines, Mono, and Sulong distinguish an internal callable
descriptor from an executable native address.

The surveyed representation pattern is:

- an interpreted function pointer stores the address of a stable
  Quickbite-owned descriptor or another stable token;
- an interpreted D delegate stores ordinary context and function-token words;
- copies preserve identity as ordinary bytes;
- direct interpreted calls already know the declaration and need no lookup;
- indirect interpreted calls resolve the token; and
- native code never receives that token as an executable function pointer.

This evidence rules out treating an internal descriptor address as executable
code. A real native crossing needs a native-valid representation; metadata
beside a null or fake slot does not provide one. AGENTS.md's "Runtime
semantics" section owns the storage contract; the Interpreter backend adapter
owns the callback-adapter contract; `quickbite.ffi.ffi` owns the typed
physical call mechanism.

### 6. Native calls split into reusable facts and a small hot path

The evidence consistently separates:

- dependency/image loading;
- symbol resolution;
- semantic signature and ABI lowering;
- prepared physical call metadata; and
- repeated invocation.

Across the surveyed systems, the repeated-call residue is:

```text
prepared ABI plan
already-resolved code address
addresses of existing typed arguments
direct typed result destination or preplanned bounded ABI scratch
```

This separation removes semantic type walking, symbol lookup, boxing, and
aggregate reconstruction from the hot call. A transport ABI can still require
bounded physical scratch, such as an `ffi_arg`-sized narrow-result slot; that
does not imply a guest-value adapter. The evidence does not choose eager
bootstrap over first-use preparation.

ABI preparation and target resolution have different identities and
invalidation rules:

- a prepared ABI shape is determined by calling convention, compiler ABI,
  normalized physical parameter/result layouts, variadic state, and any
  declaration provenance that affects lowering;
  and
- a resolved target is determined by dependency/image generation plus symbol
  or callable identity.

That independence supports separate reuse and invalidation. A prepared
`ffi_cif` is process-local and retains its `ffi_type` graph, while a target
address is tied to an image generation. The `quickbite.ffi.ffi` module owns
these physical-call caches; the Interpreter backend adapter owns callback
lifetime.

### 7. Inbound re-entry is a separate direction

The surveyed systems expose two importantly different inbound shapes:

- an explicit handle or table index passed to a runtime API, such as JNI's
  `JNIEnv*` plus method ID or WAMR's indirect-call table index; and
- a real native function pointer, such as a libffi closure, Haskell `wrapper`,
  reverse P/Invoke thunk, Wasmtime adapter, or Sulong native wrapper.

The handle/index shape does not require per-callback executable storage. The
native-pointer shape lazily creates a real ABI-valid trampoline and owns its
interpreted descriptor and context, roots, lifetime, and explicit release or
proven call-scoped lifetime. Thread attachment, re-entry, and exception policy
must be explicit where the particular runtime boundary requires them; they are
not universal properties of every callback.

Both shapes are separate from outbound calls and may share ABI classification.
The contrast supports lazy construction at an actual escape rather than a
cost on every interpreted callable. Inbound lifetime and re-entry stay
backend-adapter-owned.

### 8. Real projects choose order and tuning, not architecture debt

The long-term ABI target can remain exhaustive while implementation order is
driven by Cerealed, automem, and subsequent real projects.

For each project, after one-time project/dependency bootstrap:

1. measure end-to-end edit-to-verdict latency;
2. record what the edit invalidated, the first affected native call, repeated
   native calls, and total only when that breakdown helps a decision;
3. identify the first unsupported real D/ABI behavior;
4. reduce it to a SystemLinker-oracle language fixture;
5. implement the direct native-layout path; and
6. remeasure the project.

Microbenchmarks may explain a result, but total project test latency decides.

## Source links

Repository links resolve to commit trees pinned on the research date; the
reference labels and surrounding text identify the exact source. Versioned
specifications and API documentation remain linked to published versions.

[dmd-ctfe]:
  https://github.com/dlang/dmd/tree/8fd73db51d61
[d-ctfe-spec]:
  https://dlang.org/spec/function.html#interpretation
[d-expressions]:
  https://dlang.org/spec/expression.html#lifetime_of_temporaries
[clang-const-interp]:
  https://github.com/llvm/llvm-project/tree/09ceea09385d
[gcc-constexpr]:
  https://github.com/gcc-mirror/gcc/tree/7c48d6a74693
[rustc-interp]:
  https://github.com/rust-lang/rustc-dev-guide/tree/36fd26339de0
[rust-operand]:
  https://github.com/rust-lang/rust/tree/0913b18e489a
[rust-immediate]:
  https://github.com/rust-lang/rust/tree/0913b18e489a
[rust-place]:
  https://github.com/rust-lang/rust/tree/0913b18e489a
[rust-copy]:
  https://github.com/rust-lang/rust/tree/0913b18e489a
[miri]:
  https://github.com/rust-lang/miri/tree/2f7d190eb4ce
[miri-native]:
  https://github.com/rust-lang/miri/tree/2f7d190eb4ce
[zig-sema]:
  https://github.com/ziglang/zig/tree/738d2be9d6b6
[zig-value]:
  https://github.com/ziglang/zig/tree/738d2be9d6b6
[zig-intern]:
  https://github.com/ziglang/zig/tree/738d2be9d6b6
[zig-comptime]:
  https://github.com/ziglang/zig/tree/738d2be9d6b6
[nim-vmdef]:
  https://github.com/nim-lang/Nim/tree/2d22f243591c
[nim-vm]:
  https://github.com/nim-lang/Nim/tree/2d22f243591c
[nim-evalffi]:
  https://github.com/nim-lang/Nim/tree/2d22f243591c
[yaegi-frame]:
  https://github.com/traefik/yaegi/tree/fcb76d1ece0c
[yaegi-run]:
  https://github.com/traefik/yaegi/tree/fcb76d1ece0c
[yaegi-api]:
  https://pkg.go.dev/github.com/traefik/yaegi/interp
[llvm-generic-value]:
  https://github.com/llvm/llvm-project/tree/09ceea09385d
[llvm-interpreter]:
  https://github.com/llvm/llvm-project/tree/09ceea09385d
[llvm-external]:
  https://github.com/llvm/llvm-project/tree/09ceea09385d
[clang-repl]:
  https://github.com/llvm/llvm-project/tree/09ceea09385d
[ghc-bytecode]:
  https://ghc.gitlab.haskell.org/ghc/doc/libraries/ghc-9.15-inplace/
[ghc-bco]:
  https://ghc.gitlab.haskell.org/ghc/doc/libraries/ghc-9.15-inplace/
[ghc-linker]:
  https://github.com/ghc/ghc/tree/556db2f32f59
[ghc-rts-interpreter]:
  https://github.com/ghc/ghc/tree/556db2f32f59
[ghc-ffi-prep]:
  https://ghc.gitlab.haskell.org/ghc/doc/libraries/ghci-9.15-inplace/
[ghc-ffi-guide]:
  https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/ffi.html
[haskell-ffi]:
  https://www.haskell.org/onlinereport/haskell2010/haskellch8.html
[ocaml-interp]:
  https://github.com/ocaml/ocaml/tree/8cdc85c9db65
[ocaml-values]:
  https://github.com/ocaml/ocaml/tree/8cdc85c9db65
[ocaml-c]:
  https://ocaml.org/manual/5.3/intfc.html
[mono-interp]:
  https://github.com/dotnet/runtime/tree/643b8962835e
[mono-exec]:
  https://github.com/dotnet/runtime/tree/643b8962835e
[clr-abi]:
  https://github.com/dotnet/runtime/tree/643b8962835e
[dotnet-callback]:
  https://learn.microsoft.com/en-us/dotnet/standard/native-interop/
[jvms-frames]:
  https://docs.oracle.com/javase/specs/jvms/se25/html/jvms-2.html
[hotspot-interp]:
  https://github.com/openjdk/jdk/tree/e9157bb2d5d9
[hotspot-native]:
  https://github.com/openjdk/jdk/tree/e9157bb2d5d9
[jni-design]:
  https://docs.oracle.com/en/java/javase/25/docs/specs/jni/design.html
[jni-functions]:
  https://docs.oracle.com/en/java/javase/25/docs/specs/jni/functions.html
[dotnet-frame]:
  https://github.com/dotnet/runtime/tree/643b8962835e
[dotnet-lambda]:
  https://github.com/dotnet/runtime/tree/643b8962835e
[pulley-rfc]:
  https://github.com/bytecodealliance/rfcs/tree/b6faa4a4b7de
[pulley-interp]:
  https://github.com/bytecodealliance/wasmtime/tree/a9238c105b20
[wasmtime-func]:
  https://github.com/bytecodealliance/wasmtime/tree/a9238c105b20
[wamr-fast]:
  https://github.com/wasm-micro-runtime/wasm-micro-runtime/tree/f2528b714810
[wamr-native]:
  https://github.com/wasm-micro-runtime/wasm-micro-runtime/tree/f2528b714810
[wamr-embed]:
  https://github.com/wasm-micro-runtime/wasm-micro-runtime/tree/f2528b714810
[wabt-types]:
  https://github.com/WebAssembly/wabt/tree/9dfd98d11340
[wabt-exec]:
  https://github.com/WebAssembly/wabt/tree/9dfd98d11340
[sulong-frame]:
  https://github.com/oracle/graal/tree/4e9cb7838942
[sulong-stack]:
  https://github.com/oracle/graal/tree/4e9cb7838942
[sulong-function]:
  https://github.com/oracle/graal/tree/4e9cb7838942
[truffle-nfi]:
  https://docs.oracle.com/en/graalvm/jdk/22/docs/
[truffle-nfi-source]:
  https://github.com/oracle/graal/tree/4e9cb7838942
[libffi]:
  https://github.com/libffi/libffi/tree/303a0031a58a
[jshell]:
  https://docs.oracle.com/en/java/javase/26/docs/api/jdk.jshell/
[fsi]:
  https://learn.microsoft.com/en-us/dotnet/fsharp/tools/fsharp-interactive/
[evcxr]:
  https://github.com/evcxr/evcxr/tree/7d588b3cad38
[lldb-expressions]:
  https://lldb.llvm.org/resources/overview.html

## Call-state precedents

Relocated from the former Interpreter plan's execution-architecture section
(deleted once its design was implemented): the narrower survey behind the
Interpreter's execution-state ownership design. The implementations differ
in language and product goal, but agree on the lifetime split that matters
there:

- LuaJIT keeps heap, roots, interned strings, and registries in one
  `global_State`. A `lua_State` points at that shared state, while calls use
  compact headers and slots on its stack. Calls do not copy the Lua universe.
  See [LuaJIT state][luajit-state] and [LuaJIT frames][luajit-frames].
- JavaScriptCore's low-level interpreter represents a call with a
  register-backed `CallFrame`: caller, return address, code block, callee,
  argument count, receiver, arguments, and locals. The JavaScriptCore VM stays
  shared. See [JavaScriptCore `CallFrame`][jsc-call-frame].
- rustc's MIR interpreter owns one `InterpCx` with one virtual `Memory`; its
  machine supplies the stack of `Frame` values. `Memory` owns the allocation
  map and extra function-pointer map, while calls push and pop frames. Miri
  extends the same machine with semantic checking rather than snapshotting the
  memory at calls. See [rustc interpreter context][rustc-eval-context],
  [rustc interpreter memory][rustc-memory], and [Miri's machine][miri-machine].
- DMD's CTFE evaluator creates a small `InterState` for a call and uses the
  shared CTFE stack for values and frames. This is the closest same-language
  precedent. See [DMD's CTFE evaluator][dmd-interpret].
- Clang's constant interpreter has explicit interpreter frames and reusable
  stack storage. It replaced repeated AST-evaluator work with typed bytecode,
  but its relevant lesson here is independent of bytecode: a call adds a
  frame to one interpreter state. See [Clang's constant interpreter][clang-ci].
- Cling is an incremental compiler and JIT, not an AST or bytecode interpreter.
  Its one persistent `Interpreter` owns an `IncrementalParser` and
  `IncrementalExecutor`; transactions are incremental source submissions, not
  function calls. Generated function calls use ordinary native frames. See
  [Cling's `Interpreter`][cling-interpreter].

LuaJIT and JavaScriptCore are the performance precedents. rustc/Miri and DMD
are the semantic precedents. Cling is useful only for locating the incremental
session boundary. None provides precedent for eagerly duplicating growing,
mutable execution registries at every interpreted D call and merging them
afterwards.

[luajit-state]:
  https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_obj.h
[luajit-frames]:
  https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_frame.h
[jsc-call-frame]:
  https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/interpreter/CallFrame.h
[rustc-eval-context]:
  https://github.com/rust-lang/rust/blob/master/compiler/rustc_const_eval/src/interpret/eval_context.rs
[rustc-memory]:
  https://github.com/rust-lang/rust/blob/master/compiler/rustc_const_eval/src/interpret/memory.rs
[miri-machine]:
  https://github.com/rust-lang/miri/blob/master/src/machine.rs
[dmd-interpret]:
  https://github.com/dlang/dmd/blob/master/compiler/src/dmd/dinterpret.d
[clang-ci]:
  https://github.com/llvm/llvm-project/tree/main/clang/lib/AST/ByteCode
[cling-interpreter]:
  https://github.com/root-project/cling/blob/master/include/cling/Interpreter/Interpreter.h
