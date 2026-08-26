# Research: performant bytecode-VM and interpreter design

## Purpose

This document is the precedent survey behind the from-scratch Bytecode VM plan
of 2026-08-11 (`ai/plans/bytecode.md`, since deleted). It is a research
record, not an implementation plan: the plan owns decisions and remaining
work; this file records the surveyed systems, the mechanisms found in their
primary sources, the per-system transferable/non-transferable verdicts, the
conclusions that multiple systems support independently, and the pinned
sources.

Research date: 2026-08-11.

## Method

Nine systems were researched in parallel, one agent per system, each working
from primary sources (engine source code, specs, design docs, the authors'
own writing), with secondary sources used only to corroborate measured
numbers and flagged as such. The axis surveyed is the execution engine:
instruction encoding, dispatch, frame and calling-convention design,
exception handling, and runtime specialization. JIT compilation and tiering
are out of scope throughout — the project has a separate LLVM JIT backend —
so machine-code-generation techniques were recorded only to mark them
explicitly non-transferable. Where a commonly repeated number could not be
verified in a primary source, that is stated rather than the number repeated.

One D/LDC-specific experiment was run during the research: a synthetic
230-case `final switch` dispatch loop compiled with LDC 1.42.0 (LLVM 21.1.8)
at `-O3 -release`, generated assembly inspected directly. Its result is
load-bearing for the dispatch conclusions below.

## The implementation being compared

Quickbite's Bytecode backend, as of the research date:

- A register machine over a flat byte-addressed frame: every operand is a
  16-bit byte offset into the activation record. Values live in native D
  memory layout with no boxing and no tags — slices are `{length, ptr}`,
  structs are inline in the frame, classes are heap blocks whose first word
  indexes class metadata.
- Fixed-width 12-byte instructions, `{ubyte op; 5×ushort operands}`,
  regardless of how many operand slots an opcode uses.
- Roughly 230 opcodes, mostly width-specialized variants of about 30 logical
  operations, kept consistent through 9 hand-maintained width↔op tables.
- Dispatch is a D `final switch` inside a per-instruction `try`/`catch`.
- Virtual dispatch is a linear search of registered overrides; associative
  arrays are insertion-ordered parallel arrays with linear-scan lookup.
- Calls memcpy the argument block into the callee's frame region.
- Bytecode is compiled lazily per function on first call — the machine calls
  back into the compiler mid-run.
- FFI is outbound-only via libffi, passing frame addresses directly.
- Exceptions use pushed handler records plus compiler-inlined finally blocks
  on every exit edge.
- Full per-instance template instantiation; no generic sharing; no JIT tier
  and none planned for this backend.

## JVM / HotSpot

**What it is / why surveyed.** The most heavily engineered managed-language
VM in production; its interpreters (template plus the portable Zero C++ one)
and class-linking machinery are the canonical reference for exception
tables, vtables, and bytecode quickening.

**Key mechanisms.**

- *Exception tables consulted only on throw.* The `Code` attribute carries a
  static per-method `exception_table` of `(start_pc, end_pc, handler_pc,
  catch_type)` ranges (JVMS SE21 §4.7.3). HotSpot's
  `InterpreterRuntime::exception_handler_for_exception` carries its own
  comment: "the implementation of this method assumes it's only called when an
  exception has actually occurred." The Zero interpreter
  (`zero/bytecodeInterpreter.cpp`) has no wrapping `try` at all: faultable
  opcodes do an explicit cheap check (`CHECK_NULL` → `goto handle_exception`),
  non-faultable opcodes carry zero exception-related code, and the table walk
  happens once, on the taken branch.
- *Vtables and itables.* `klassVtable::initialize_vtable` assigns each virtual
  method a permanent integer slot at class-link time; dispatch is
  `recv_klass->method_at_vtable(vtable_index)` — one array index on the
  receiver's own vtable, O(1) regardless of hierarchy depth. Interfaces use
  itables: a linear scan over the (small) set of interfaces a class
  implements, then O(1) within the matched interface's slice.
- *Quickening / self-patching bytecode.* `Rewriter` rewrites constant-pool
  operands into resolved-entry indices at link time ("The ConstantPoolCache is
  not a cache! It is the resolution table that the interpreter uses to avoid
  going into the runtime" — `cpCache.hpp`). On first execution a generic
  field/call bytecode resolves its target, fills a `ResolvedFieldEntry`
  (cached byte offset, type state, flags), and `TemplateTable::patch_bytecode`
  overwrites the opcode byte in place with a specialized `_fast_*` variant.
  Quickening is applied selectively — `putfield` variants skip it when the
  fast path would bypass work that must always run.
- *Argument aliasing.* Parameters are not copied on call: across at least four
  architectures, `abstractInterpreter_*.cpp` computes the callee's locals
  pointer as `sender_sp() + max_locals - 1` — the tail of the caller's operand
  stack *is* the head of the callee's locals.
- *Dispatch family.* HotSpot's own portable interpreter is exactly a
  switch/computed-goto loop (`goto *(void*)dispatch_table[opcode]` under
  `USELABELS`). The template interpreter's ~2x speedup over it (secondary
  sources: Azul citing Simonis; an independent reimplementation measured
  ~2.5x) comes from generating machine code per opcode plus TOS register
  caching — a JIT-class technique.

**Transferable.** Exception tables plus explicit checks at fault sites only;
vtable/itable slot assignment at link time (maps onto the lazy per-function
compilation moment); instruction self-patching after first resolution (fits
the fixed 12-byte format — rewrite `ubyte op` or an operand slot in place);
argument aliasing as a calling-convention design.

**Not transferable.** The template interpreter itself — per-opcode machine
code generated by a macro-assembler at startup is exactly the JIT-tier
tooling this backend deliberately does not have. The variable-width `wide`
prefix encoding solves classfile density constraints Quickbite does not have;
a fixed 16-bit operand already covers the JVM's worst case. TOS register
caching targets an implicit operand stack a register machine lacks.

## CLR: Mono interpreter (and the CoreCLR interpreter effort)

**What it is / why surveyed.** Mono's `mini/interp` is a mature production
interpreter for a statically typed IL and the closest overall structural
match to Quickbite: it executes its own internal instruction set over a flat
byte-addressed frame. The new CoreCLR interpreter explicitly adopted Mono's
design after analyzing it; ECMA-335's typed opcodes are the baseline its
specialization extends.

**Key mechanisms.**

- *Transform pass.* Mono never executes CIL. `transform.c` ("transform CIL
  into different opcodes for more efficient interpretation") runs once per
  method on first call and does real compiler work: stack→frame-offset
  allocation (every abstract stack push gets a byte offset; the final frame
  size is frozen in `total_locals_size`), peephole fusion
  (`MINT_ADD_MUL_I4_IMM`, fused load+address arithmetic, 36 fused
  compare-branch opcodes), constant folding, and intrinsic replacement. The
  executor then trusts the emitted stream completely — no runtime type,
  width, or stack-depth re-derivation, ever.
- *Frame shape.* `#define frame_locals(frame) ((guchar*)(frame)->stack)` —
  the frame is one flat byte buffer addressed by transform-time offsets.
  Value types live out of line from the fixed-size `stackval` slots, moved by
  a dedicated `MINT_MOV_VT` bulk-copy-by-declared-size opcode.
- *No per-instruction exception guard.* The computed-goto/switch loop has
  zero try/setjmp scaffolding. `interp_throw()` calls one shared unwinder
  (`mono_handle_exception()`) that walks precomputed clause tables built once
  at transform time. Afterward the loop only needs `CHECK_RESUME_STATE` — a
  plain flag check present at **11 call sites** in ~9,400 lines, placed after
  the few operations that can re-enter managed code, not after all ~692
  handlers. Exceptional entry into finally/filter is a genuine recursive
  interpreter invocation on a child frame; the *non-exceptional*
  leave-into-finally path is a cheap jump-and-link (`MINT_CALL_HANDLER` /
  `MINT_ENDFINALLY`) within the same frame.
- *Virtual dispatch.* Not a linear scan: `get_virtual_method_fast` uses a
  lazily allocated per-`MonoVTable` array indexed directly by vtable slot,
  with a tagged-pointer fast path for the monomorphic case and a short list
  only for genuinely polymorphic generic/interface slots — all resolution
  paid once per (vtable, slot) and memoized.
- *Generics.* The interpreter fully instantiates: `mono_interp_transform_method`
  resolves the concrete generic context per instantiation. Mono's own
  RGCTX/gsharedvt generic-sharing machinery — sitting in the same codebase —
  is used only at AOT/JIT boundary crossings, never inside the interpreter
  loop. Shared generics solve machine-code bloat and JIT latency, costs a
  bytecode interpreter does not have.

**Transferable.** The complete EH blueprint (compile-time clause tables, one
shared unwind routine invoked from fault sites, sparse resume checks); the
slot-indexed lazy per-class dispatch cache; the front-load-everything
transform discipline (validate once, freeze frame size and offsets once,
fuse adjacent patterns at compile time); `MOV_VT`-style bulk struct copies.
Independent confirmation that flat byte-buffer frames and full
per-instantiation generics are the right calls.

**Not transferable.** The variable-length uint16-unit encoding (a density
trade Quickbite already rejected); the JIT-shared unwinder infrastructure
(imitate its shape, not its sharing); `stackval`'s GC-facing union and the
`MonoType`-driven call marshalling, which serve the CLR object model.

## V8 Ignition

**What it is / why surveyed.** V8's register-plus-accumulator bytecode
interpreter — the design-doc-documented reference for handler tables, operand
scale prefixes, and the memory cost of JIT-feeding machinery; V8's plain-C++
regexp interpreter doubles as a non-JIT dispatch precedent.

**Key mechanisms.**

- *Handler tables, zero cost until throw.* Try regions compile to per-function
  handler-table entries (start, end, handler target, context register). A
  `Throw` bytecode calls a runtime function and never returns; only the
  unwinder (`UnoptimizedJSFrame::LookupExceptionHandlerInTable` →
  `LookupHandlerIndexForRange(GetBytecodeOffset())`) consults the table, at
  actual-throw time, keyed by current PC. No bytecode pays anything on the
  non-throwing path.
- *Accumulator.* One implicit register kept in a machine register, so
  expression chains avoid round-tripping intermediates through the
  stack-resident register file; binary ops encode one explicit operand
  instead of three.
- *Operand scaling.* 8-bit operands by default, `Wide`/`ExtraWide` prefix
  bytecodes rebase dispatch into 256-entry-offset copies of the handler
  table; measured size overhead of the scheme "<1% on Octane." Register
  operands are byte offsets from a frame-file pointer — structurally
  Quickbite's choice, at variable width.
- *Non-JIT dispatch precedent.* `regexp-interpreter.cc` implements the same
  handler-table-plus-direct-jump structure in plain C++: computed goto with a
  label-address table where the compiler supports it, an ordinary
  switch-in-a-loop fallback where it doesn't.
- *Feedback vectors as a cautionary tale.* Ignition's per-call-site feedback
  slots exist solely to feed TurboFan. They cost "a significant portion of
  V8's heap memory usage"; naive removal caused a 120% CPU increase, and the
  fix (lazy allocation after ~1KB of executed bytecode) was itself new
  machinery that bought an 18% average heap reduction (v8.dev/blog/v8-lite).

**Transferable.** The handler-table EH model (Quickbite already builds the
equivalent data — handler records with target instruction indices — then
redundantly pays a per-instruction `try` on top); the accumulator as a
frame-traffic reduction, evaluated separately from encoding; the audit
question of whether uninitialized frame bytes can ever look pointer-shaped
to a conservative GC scan.

**Not transferable.** The CodeStubAssembler/TurboFan handler-generation
pipeline (JIT infrastructure); Wide/ExtraWide prefixes (Quickbite scales
width at the opcode level, avoiding prefix decode); and — as a standing
warning — any bytecode operand or per-function heap state whose only consumer
would be a future optimizing tier, since no such tier reads this backend.

## WebAssembly fast interpreters: wasm3 and WAMR

**What they are / why surveyed.** The two best-documented wasm "fast
interpreter" designs: wasm3's tail-call "meta machine" and WAMR's loader-time
stack→register transformation, both with primary-source numbers.

**Key mechanisms.**

- *wasm3's meta machine.* Bytecode is a stream of function pointers
  (`IM3Operation`) plus inline immediates; each operation ends with
  `M3_MUSTTAIL return nextOpImpl()` — Clang's guaranteed tail call — so
  dispatch compiles to a bare indirect `jmp` and ~90% of opcodes never touch
  the native stack. VM registers (pc, sp, memory base, one int and one float
  accumulator) are literal function arguments pinned via `vectorcall`.
  wasm3's own doc measures ~4-15x slower than native compiled code
  (Mandelbrot 4.4x, CRC32 8.5x).
- *wasm3 traps.* No exceptions anywhere: trap conditions are explicit checks
  in the few faultable operations, returning an `M3Result` up the tail-call
  chain — the return-value protocol *is* the unwind mechanism. The
  stack-overflow bound is precomputed per function (`maxStackSlots`) and
  checked once at entry.
- *WAMR fast-interp.* The loader precomputes everything: handler addresses
  replace opcode bytes (~7% of the total gain on CoreMark by itself), a
  simulated operand stack assigns every value a fixed frame slot id so
  provider opcodes (`get_local`, `const`) emit *no code at all*, LEB128
  immediates are pre-decoded, jump targets pre-resolved. Result: ~150%
  CoreMark improvement over the classic interpreter, executing 42% as many
  instructions, for ~30% more memory (the "2x memory" figure sometimes
  repeated is not in the primary sources).
- *WAMR traps.* Default tier: one predictable inline branch per faultable
  operation, `goto` to a shared error label. Opt-in tier on capable
  platforms: guard pages + signal handler + longjmp, layered over the
  always-correct portable baseline. Neither tier wraps dispatch in
  structured exception handling.

**Transferable.** The loader-time precomputation discipline, stated as a
rule: anything that is a pure function of static bytecode shape (operand
width, location, jump target, dispatch target, max stack depth) is computed
once where that shape is first known and baked into the stream — never
re-derived per visit. This is the direct answer to Quickbite's
per-instruction linear width-table scans. Also: per-function entry-time stack
bound checks, and traps as branch-plus-shared-label.

**Not transferable.** The tail-call meta machine as such: it is only *safe*
under a compiler-guaranteed tail call, and neither DMD nor LDC exposes a
musttail equivalent to user code (LDC uses LLVM musttail internally for ABI
thunks — issues #2686, #4795 — with no pragma/UDA exposing it; the D forum
DIP discussion on guaranteed TCO went nowhere), so porting the pattern would
bet stack safety on opportunistic optimization. Guard-page bounds checking
presumes a single runtime-owned linear memory arena; Quickbite's frames hold
real pointers into GC heap, stack, and FFI memory, where a SIGSEGV can mean
genuine corruption. WAMR's four-space slot scheme solves a stack→register
translation problem Quickbite's compiler never has.

## Wasmtime Pulley

**What it is / why surveyed.** Wasmtime's portable interpreter-only backend —
a recent, deliberately designed bytecode VM whose team measured its choices,
including the survey's only rigorous match-loop-vs-tail-call benchmark.

**Key mechanisms.**

- *Single-source opcode definitions.* One macro list (`for_each_op!` /
  `for_each_extended_op!` in `pulley/src/lib.rs`) generates the opcode enums,
  encoders, decoders, the disassembler/tooling visitor, the interpreter's
  handler tables, and — in a different crate and compiler stage — Cranelift's
  lowering/emission glue. Irregular instructions are named exceptions via an
  explicit `.skip()` list rather than contorting the generic path.
- *Encoding.* Two-tier opcode space (u8 hot set ~138 ops; `0xFF` escape to a
  u16 extended space ~302 ops); handlers decode operands inline and never
  materialize a generic instruction enum. Opcode duplication for speed is an
  explicit guideline ("a wide set of duplicate functionality between opcodes
  … and this is expected") — independent validation of width-specialized
  opcode proliferation, provided generation is centralized.
- *Dispatch, measured.* Pulley ships both a stable match-loop and an opt-in
  tail-call loop (nightly `become`, or hope-LLVM-sibling-calls). Wasmtime
  issue #9995's Sightglass runs inverted the folklore: the plain match loop
  beat tail calls by 1.13x-1.19x on two of three real workloads
  (pulldown-cmark, bz2); tail calls won ~3-4% on spidermonkey and ~20% only
  on a fib microbenchmark. The team kept both rather than crowning a winner.
- *Positioning.* Official docs set expectations at ~10x slower than
  Cranelift-compiled native; "world's fastest interpreter" is an explicit
  non-goal. A third-party embedded benchmark (treVM, DCOSS-IoT 2026) has
  Pulley at ~2x WAMR-classic and ~1.2x WAMR-fast on CoreMark/RP2350.

**Transferable.** The single-source opcode-table generation shape, including
the named-exception escape hatch — D's `static foreach`/CTFE/string mixins
are the native substitute for the macro machinery. The measured
dispatch-inversion result, which demotes dispatch surgery from "known win" to
"benchmark on your own workload first." The expectation-setting practice of
tracking an explicit interpreter-vs-native ratio internally.

**Not transferable.** Everything downstream of "bytecode is produced by
lowering through Cranelift": mid-end optimizations, `regalloc2` and the
32/32/32 typed register files it targets, ISLE-discovered superinstructions.
Quickbite has no IR and no allocator to feed one, and building them would
work against edit-to-verdict latency. Rust's `become` has no D counterpart.

## LuaJIT 2 (interpreter only)

**What it is / why surveyed.** The most famous hand-tuned interpreter in
existence; Mike Pall's source comments and posts quantify dispatch and
data-structure choices other engines only assert. Only the interpreter and
table design were surveyed; the trace JIT is out of scope.

**Key mechanisms.**

- *Tail-duplicated dispatch, quantified in-source.* `vm_x64.dasc` ships both
  dispatch designs behind an `.if`: replicated fetch/decode/dispatch at the
  tail of every handler (shipped) vs one shared dispatch site, with the
  comment measuring the shared form "around 10%-30% slower on Core2, a lot
  more slower on P4." The mechanism is per-branch-site indirect-branch
  prediction: each handler's own dispatch branch learns "what usually follows
  this opcode"; one shared site sees the union and thrashes. This is textual
  code placement, not assembly magic — it transfers to any language.
- *Why assembly at all.* Fixed register pinning: BASE/PC/DISPATCH/operand
  registers live in named hardware registers across all ~200 handlers ("This
  is very fragile … Caveat emptor."). Pall's roadmap post: the rewritten
  interpreter alone was "2x-4x faster" than LuaJIT 1.x's simple JIT; on LtU
  he reports the interpreter beating V8's JIT on 6 of 8 benchmarks, and his
  own 1.1 JIT only +12% on average over his 2.0 interpreter. The portable
  echo is keeping the interpreter's hot working set (frame base, ip) in a
  small stable set of whole-function locals.
- *Fast-path/slow-path discipline.* Every handler open-codes the common case
  and branches out to a shared out-of-line `->vmeta_*` routine for
  metamethods/errors, so the hot path never carries the slow path's code
  size or register pressure.
- *Tables.* Hybrid array + hash: integer keys in the dense array part are a
  direct index with zero hashing (`inarray`/`arrayslot`); the hash part is
  main-position chaining with explicit `next` links inside the node array (no
  probe sequences, no external buckets), plus Brent's variation
  (`lj_tab_newkey` evicts entries not at their own main position) to keep
  chains short.
- *Zero-copy calls.* `BC_CALL` is `lea BASE, [BASE+RA*8+16]` — the caller
  already placed arguments where the callee's frame begins, so an ordinary
  call is pointer arithmetic, no copy loop (tail calls *do* copy, to reuse
  the frame — a deliberate different trade).
- *Encoding.* 32-bit instructions, two layouts (ABC / AD), branch-free
  mask-and-shift decode; operand-*kind* specialization as separate opcodes
  (`ADDVN`/`ADDNV`/`ADDVV`) instead of in-handler branches; comparisons
  numbered so negation is `op ^ 1`.

**Transferable.** Tail-duplicated dispatch as the portable dispatch lesson
(reachable in D by having the code generator duplicate the fetch/dispatch
stub per case); fast/slow-path splitting with out-of-line failure paths; the
whole table design for the AA rewrite (array part first, then main-position
chaining; Brent's variation optional); zero-copy argument placement as a
calling-convention design question; enum-layout bit tricks.

**Not transferable.** The hand-written per-architecture assembly and its
register-pinning guarantees; NaN-tagging (solves dynamic-typing value
representation — adopting it in a statically typed native-layout VM would be
a regression); Lua-specific hash functions relying on interned-string
headers; the trace compiler entirely.

## CPython (Faster CPython, 3.11-3.14)

**What it is / why surveyed.** The best-documented recent interpreter
optimization program: per-technique numbers, a public postmortem correcting
one of them, and the cases_generator DSL. The survey's in-session LDC
experiment belongs to this thread.

**Key mechanisms.**

- *Computed goto.* `ceval_macros.h`'s comment is the canonical statement: a
  switch already becomes one jump table + one shared indirect branch; the
  15-20% win of threaded code comes from *N distinct branch sites*, one per
  handler, each with its own predictor history.
- *The LDC experiment.* A 230-case `final switch` loop shaped like
  Quickbite's, compiled with LDC 1.42.0/LLVM 21.1.8 at `-O3`: LLVM built the
  jump table but emitted exactly **one** shared `jmpq *%r11` for all 230
  cases — the badly-predicted shape, not the N-site shape. So `final switch`
  does not bank computed-goto's benefit, and D has no labels-as-values to
  claim it directly; the cheapest route to N sites is generator-duplicated
  dispatch stubs, measured before adoption.
- *Tail-call dispatch, deflated.* The 3.14 musttail interpreter's headline
  10-15% was mostly an artifact of an LLVM 19 tail-duplication regression in
  the baseline; re-measured against healthy baselines the real gain is
  ~1-5%, platform-dependent (Nelhage; corroborated by Ken Jin's own
  retraction posts).
- *PEP 659 specialization.* Quickening (in-place opcode rewriting), adaptive
  counters, inline cache words in the instruction stream, deopt by swapping
  the opcode back; estimated 10-60% overall. Most families (BINARY_OP,
  COMPARE_OP, subscript, UNPACK_SEQUENCE) recover dynamic-typing information
  Quickbite resolves at compile time — already solved more cheaply, no
  transfer. The families keyed on runtime *identity* facts do transfer:
  method-call target caching (10-20% cited) maps onto monomorphic caching of
  virtual-call targets by concrete class, and lazily-materialized-container
  checks map onto D AA null-vs-allocated guards.
- *cases_generator.* `Python/bytecodes.c` is a single DSL file (`inst`, `op`,
  `family`, `super` constructs) from which small generators emit the
  interpreter switch body, opcode IDs, metadata/deopt tables, and the
  computed-goto target table, all bannered "Do not edit!". CPython previously
  hand-maintained those artifacts in sync — exactly Quickbite's 9-table
  problem — and eliminated the class of drift bug by generation.
- *Superinstructions.* Hand-picked adjacent-pair fusions
  (`LOAD_FAST_LOAD_FAST` etc.), selected from runtime pair-frequency
  profiles, emitted at compile time since 3.12; jump targets into the second
  half still work because the unfused opcode remains decodable.

**Transferable.** The DSL/generator shape (in D: CTFE + `static foreach` +
mixins over one declared width-set and one generic body per logical op,
generating the enum, the 9 tables, the switch cases, and disassembly);
identity-keyed inline caches for virtual calls and AA state, with cache words
co-located with the instruction (PEP 659 chose in-stream over side tables);
profile-driven superinstruction selection on Quickbite's own unittest corpus
rather than CPython's pair list; and the measurement discipline — attribute
before believing, per the musttail episode.

**Not transferable.** Everything whose purpose is dynamic-typing erasure or
`PyObject` economics: type-guarded arithmetic specialization, unboxing fast
paths, small-int interning, immortal objects, deferred/biased refcounting,
free-threading work. Quickbite never boxes and never refcounts.

## Clang ByteCode interpreter, Cling and Clang-Repl

**What it is / why surveyed.** Clang's bytecode constant-expression
interpreter is a from-scratch statically typed bytecode VM inside a
production compiler, with the survey's cleanest opcode-generation precedent
(Opcodes.td); Cling/Clang-Repl document why a different problem (full C++ at
a REPL) chose JIT instead.

**Key mechanisms.**

- *Opcodes.td.* One TableGen file declares each opcode once with a
  `TypeClass` width-set; `ClangOpcodesEmitter` cross-products operation ×
  width into every artifact that must agree: the opcode enum, per-
  specialization interpreter dispatchers, the dispatch-function table, the
  compiler-side emitter methods, the type-dispatching `emitAdd(PrimType, …)`
  group wrappers, the disassembler cases, and the direct-eval overloads.
  The interpreter body is written once, templated over the primitive type.
  Nobody hand-writes `AddSint8` … `AddUint64`.
- *Dispatch.* Not a switch: a flat `InterpFunctions[]` pointer table, and
  under `USE_TAILCALLS` each generated dispatcher ends `MUSTTAIL return
  InterpNext(S)` with `[[clang::preserve_none]]` keeping state in registers
  — threaded code via guaranteed tail calls, gated off on platforms that
  cannot support it. Failure is a `bool` return threaded through dispatch
  (with a per-opcode `CanFail` bit controlling whether it is even checked),
  not C++ exceptions.
- *Frames.* One allocation per call holds all locals contiguously,
  addressed by byte offset (`InterpFrame::getLocal<T>(Offset)`); an
  `InterpStack` operand stack holds expression temporaries — a stack/frame
  hybrid where Quickbite is a pure register machine.
- *Compile vs direct-eval granularity.* `Compiler<Emitter>` is one AST
  walker with two backends: `ByteCodeEmitter` writes reusable bytecode for
  `FunctionDecl`s; `EvalEmitter` executes one-shot top-level expressions
  immediately during the walk, because "the bytecode would never be reused."
- *Constexpr-only machinery, explicitly identified.* Lifetime tracking,
  per-field init/active bits, one-past-end distinction, dead-block
  tombstones, and the per-block list of live Pointers all exist to
  *diagnose* C++ constant-expression illegality; virtual dispatch is an AST
  override-chain query because the memory model has no compiled vtables.
  Measured wins over the tree evaluator it replaces (2025 update): `#embed`
  14.8s vs 36.5s; a heap-heavy benchmark 4.2s vs 27.8s; one case 440ms vs
  >1000s — bytecode-over-AST-walking validated, though against a tree
  walker, not another VM.
- *Cling/Clang-Repl.* Chose JIT-via-LLVM not for runtime speed but to reuse
  Clang's semantics rather than re-implement C++ (the 230k-LOC Cint
  cautionary tale); per-input transactions wrap statements in unique
  functions, promote declarations to global scope, and support unloading. No
  published edit-eval latency numbers exist for either — searched, not found.

**Transferable.** The Opcodes.td shape is the strongest single-source
precedent: declare width-sets once, write each operation once generically,
generate every dependent artifact — D's CTFE/mixin machinery is the natural
equivalent. Bool-return fault propagation with per-opcode can-fail metadata
is the non-exception EH comparison point. Compile-time-emitted destructor
calls at scope exits (Clang's `*Scope` RAII emitters) confirm Quickbite's
compiler-inlined-finally approach is the standard shape.

**Not transferable.** TableGen itself; `preserve_none`/MUSTTAIL (no D
equivalent); the constexpr diagnostic memory model — Quickbite executes real
D against real memory and relies on DMD's static checks, the same bargain
compiled D makes; AST-query virtual dispatch (D's single-inheritance vtable
is a word load — simpler and faster than what Clang must do); the Cling JIT
pipeline, which answers an implementation-effort question, not an
interpreter-speed one.

## rustc MIR interpreter (const-eval) and Miri

**What it is / why surveyed.** The typed-IR tree/statement-walking
counterpoint: what it costs to interpret a rich typed IR directly with
per-access checking, from the authors' own POPL 2026 paper with real numbers.

**Key mechanisms.**

- *No bytecode, and the measured price.* Miri interprets MIR statements
  directly (infrastructure reuse and semantic fidelity, not speed, per the
  paper), with all MIR optimizations off. Measured: **~3000x slower than an
  unoptimized native build** at the small end of their benchmark, growing to
  ~7000x — against sanitizers at <10x and Valgrind at 20-50x. The authors'
  own future-work prescription is to move *toward* compiled/instrumented
  code. A flat bytecode VM sits on the fast side of exactly this divide.
- *Operand/Place split.* Scalar and two-word locals (including `{ptr, len}`
  slices) live as `Immediate`s outside memory until their address is first
  taken, then demote to a real allocation — flagged as one of ~5
  optimizations that made Miri practical at all, and explicitly *dynamic*,
  per-local, with metadata-migration bookkeeping at demotion time.
- *Destination passing.* MIR `Call` carries the destination place; the
  caller resolves it before the callee frame is pushed, the callee writes
  its result directly there, and returning is "pop frame, jump to the
  continuation stored on the callee's frame." Tail calls forward the old
  return place for free. Unwinding is just more MIR (cleanup blocks named by
  `UnwindAction`), not a side mechanism.
- *Layout caching.* Layout is never computed by the interpreter: the
  compiler's memoized `layout_of` query, fronted by a per-execution hash
  cache, fronted again by a per-frame-per-local memo cell.
- *UB machinery, labeled.* AllocId provenance, exposure tracking,
  Stacked/Tree Borrows, per-byte init masks, vector-clock race detection —
  all UB-*detection* state, not execution state. Constant-factor engineering
  (three-way byte/init/provenance array splits, range-coalesced metadata,
  defer-and-commit aggregate copies that memcpy source→destination once)
  made it usable without changing the asymptotic gap.

**Transferable.** The 3-4 orders-of-magnitude number as the survey's
strongest quantified validation of lowering to bytecode at all;
destination-passing as the calling-convention property to preserve; two-tier
layout caching keyed on frontend type identity (the analogue of caching DMD
`Type.size()` facts at bytecode-compile time); defer-and-commit aggregate
copies (safe here for the same reason — bytecode operands are resolved
places, never live expressions).

**Not transferable.** The provenance/borrow/race superstructure — a
trusted-input interpreter executing well-typed D needs none of it; real
memory with real addresses is the strictly simpler design Quickbite has. The
scalar-locals optimization is a considered *non*-adoption: the frame-always
model trades that win for trivial address-taking and zero demotion logic;
adopting it would import Miri's live/dead and metadata-migration complexity
for an unmeasured payoff.

## Convergent findings

Conclusions supported by multiple systems independently, strongest first.

1. **No surveyed engine pays a per-instruction try/catch.** Every engine
   with exceptions or traps uses the same shape: static handler/clause
   tables consulted only when a throw actually happens, explicit cheap
   checks only at the instructions that can fault, and (where needed) a
   sparse resume-flag check after the few operations that can re-enter.
   HotSpot exception tables + `CHECK_NULL`/`goto`; Mono's single unwinder
   with 11 resume checkpoints across ~692 handlers; Ignition handler tables
   looked up only from the unwinder; wasm3's return-value trap protocol;
   WAMR's branch-to-shared-label; Clang ByteCode's bool-return propagation.
   Quickbite already builds the handler-record data this design needs and
   pays the blanket `try` on top of it. One caveat keeps this honest: with
   zero-cost (table-driven) EH, *entering* a D try region is free at
   runtime — the real fast-path cost of the per-instruction try is that it
   acts as an optimizer fence and adds landing-pad/code-size pressure in
   the hottest loop, plus D-exception unwind weight on every actual throw.
   The fix is structural (narrow the try to genuine fault sites, resolve
   handlers from the existing table); its payoff should be measured, not
   assumed.
2. **Single-source opcode-table generation, three independent precedents.**
   Pulley's `for_each_op!` feeds encoders, decoders, disassembler, handler
   tables, and another crate's codegen from one list; CPython's
   `bytecodes.c` + cases_generator replaced exactly the hand-synced-tables
   problem Quickbite has; Clang's Opcodes.td cross-products operation ×
   width-set into seven artifacts from one declaration. All three converge:
   declare each logical operation once, declare the width/type set once,
   generate everything, name irregular opcodes as explicit exceptions.
   Against 9 hand-maintained width↔op tables this is the survey's cheapest
   correctness-preserving structural fix; D's equivalent of the DSLs is
   CTFE + `static foreach` + mixins, no external generator needed.
3. **Precompute at translate time; the hot loop re-derives nothing.**
   WAMR's loader (handler addresses, slot ids, pre-decoded immediates —
   ~150% CoreMark gain overall); Mono's transform pass (offsets frozen,
   validation done once, patterns fused); HotSpot's link-time rewriting and
   first-execution quickening; CPython's compile-time superinstructions.
   The shared rule: anything that is a pure function of static bytecode
   shape is computed once, where the shape is first known, and baked into
   the stream. Quickbite's per-instruction linear width-table scans at
   execution time are precisely the pattern all of these engines refuse.
4. **Dispatch-technique folklore deflates on modern hardware and current
   compilers.** CPython's 15-20% computed-goto figure is real but rests on
   N-distinct-branch-sites, which compilers grant unreliably; wasmtime
   measured its match loop *beating* tail calls by 13-19% on two of three
   real workloads; CPython's musttail interpreter re-measured at ~1-5% once
   an LLVM baseline regression was factored out; the literature (Rohou et
   al.) already found threading's edge shrinking on modern predictors. For
   D specifically: no computed goto exists in the language; LDC exposes no
   musttail (its backend uses LLVM musttail internally for ABI thunks —
   issues #960, #2686 — with no user-facing guarantee, so handler-chaining
   tail calls can silently fail to be tail calls and overflow the stack);
   and the in-session experiment showed a 230-case `final switch` compiling
   to one shared indirect branch — the badly-predicted shape. Conclusion:
   dispatch surgery is low-priority; if attempted, the portable candidate
   is LuaJIT's tail-duplicated dispatch (10-30% per its source comment),
   achieved in D by generator-duplicated dispatch stubs per case, measured
   on Quickbite's own workload before adoption.
5. **The native-layout flat-frame design is independently validated.**
   Mono lowers a stack IR into exactly Quickbite's shape — one flat byte
   buffer per activation, fixed compile-time offsets (`frame_locals`);
   HotSpot frames are offset-addressed locals arrays; Clang ByteCode
   allocates all locals in one offset-addressed block; Ignition's register
   file is byte-offset-addressed and statically sized; and Miri's
   3000-7000x cost of *not* lowering to a flat form is the quantified
   counterfactual. Nothing in the survey argues for tags, boxing, or a
   typed-slot stack for a statically typed input.
6. **O(1) virtual dispatch structures, not linear search.** HotSpot assigns
   permanent vtable slots at link time and dispatches by one array index
   (itables for the interface case); Mono keeps a lazily populated
   per-vtable slot-indexed cache with a tagged-pointer monomorphic fast
   path; CPython's method-call specialization (10-20% cited) is the same
   idea as an inline cache. Quickbite's linear search of registered
   overrides has no precedent among the engines surveyed.
7. **Real hash tables for associative arrays.** LuaJIT's hybrid
   array-part + main-position-chained hash (with Brent's variation) is the
   reference design; every engine's map implementation assumes O(1)
   expected lookup. Linear-scan parallel arrays have no precedent as the
   general-case design; the insertion-order property Quickbite preserves
   is an API fact to keep, not a reason to scan.
8. **Full per-instance generic instantiation is what the precedents do.**
   Mono's interpreter transforms each concrete instantiation separately and
   deliberately routes around its own generic-sharing machinery (gsharedvt
   is used only at AOT/JIT boundaries); rustc interprets fully
   monomorphized instances. Generic sharing amortizes machine-code size and
   JIT latency — costs a bytecode interpreter does not have. Nothing is
   missing in Quickbite's full-instantiation approach.

## Ranked candidate techniques

For a future performance milestone only — the plan's current milestone is
correctness (cerealed green). Cheapest first, each with its evidence.

1. **Single-source opcode/table generation** (CTFE/mixin over one width-set
   × one generic body per logical op, replacing the 9 hand tables).
   Correctness-preserving refactor, no runtime behavior change. Evidence:
   Pulley `for_each_op!`, CPython cases_generator, Clang Opcodes.td — three
   independent systems.
2. **Translate-time precomputation of everything shape-derived** (kill the
   per-instruction width-table scans; bake widths/locations/targets into
   emitted instructions at the existing lazy-compile moment). Evidence:
   WAMR fast-interp ~150% CoreMark over its own classic interpreter; Mono
   transform.c; HotSpot Rewriter.
3. **Layout-fact caching keyed on frontend type identity** (cache DMD
   `Type.size()`/alignment/field-offset answers per compile, two-tier).
   Evidence: rustc's memoized `layout_of` + per-EvalContext cache +
   per-local memo cell.
4. **EH restructuring: drop the per-instruction try** — explicit checks at
   genuine fault sites (bounds, null, division, explicit throw, calls),
   one shared handler-resolution routine over the existing handler
   records, sparse resume checks only where re-entry is possible.
   Evidence: HotSpot, Mono (11 checkpoints), Ignition, wasm3, WAMR, Clang
   ByteCode — universal; fast-path payoff to be measured (zero-cost-EH try
   entry is free; the cost is the optimizer fence and unwind-path weight).
5. **Vtable-slot virtual dispatch with a lazy per-class cache** (assign
   slots at compile/link of the class, index the receiver's table;
   monomorphic tagged fast path). Evidence: HotSpot klassVtable O(1)
   lookup; Mono get_virtual_method_fast; CPython method-call
   specialization 10-20%.
6. **AA rewrite: LuaJIT-style hybrid table** — dense integer-key array
   part first (zero hashing), main-position chaining for the general case,
   Brent's variation as optional polish, preserving insertion-order
   iteration via a side order list. Evidence: lj_tab.c; universal O(1)
   expectation across engines.
7. **Quickening / instruction self-patching** for repeatedly resolved
   facts (first execution rewrites its own opcode/operand words with the
   resolved value — pairs with 5 for call sites and with the AA
   "allocated yet" guard). Evidence: HotSpot patch_bytecode; PEP 659
   quickening within its 10-60% bundle.
8. **Superinstruction fusion, profile-driven on the unittest corpus** (fuse
   only pairs clearing a measured frequency threshold; likely
   prologue/epilogue and compare-branch patterns). Evidence: Mono fused
   compare-branch/addressing opcodes; CPython flowgraph pair selection;
   Pulley macro-ops.
9. **Fast-path/slow-path code layout** (out-of-line failure paths so hot
   handlers stay small; frame base/ip in stable whole-function locals).
   Evidence: LuaJIT vmeta_* discipline and register-pinning rationale;
   CPython's inlining-continuity argument against pointer dispatch.
10. **Zero-copy calling convention** (place arguments at compile time where
    the callee's parameter offsets expect them; pass the return destination
    in). Structural — a frame-layout design pass, not a patch. Evidence:
    LuaJIT BC_CALL pointer-rebase; HotSpot locals-overlap-caller-stack;
    rustc destination passing.
11. **Dispatch surgery, last** — if profiling ever indicts dispatch,
    prototype generator-duplicated per-case dispatch stubs
    (tail-duplication, LuaJIT's 10-30% in-source figure) and measure;
    avoid tail-call chaining outright absent an LDC musttail guarantee.
    Evidence: wasmtime #9995 match-loop wins; CPython musttail ~1-5%;
    the in-session LDC single-branch-site experiment.

## Sources

### JVM / HotSpot

- JVMS SE21 §4.7.3 (Code attribute, exception_table): https://docs.oracle.com/javase/specs/jvms/se21/html/jvms-4.html
- JVMS SE21 §6.5 (wide, per-instruction notes): https://docs.oracle.com/javase/specs/jvms/se21/html/jvms-6.html
- OpenJDK `openjdk/jdk` (master), read directly: `src/hotspot/share/oops/cpCache.hpp`; `share/interpreter/rewriter.{hpp,cpp}`; `share/interpreter/bytecodes.hpp`; `share/interpreter/zero/bytecodeInterpreter.cpp`; `share/runtime/frame.{hpp,cpp}`; `cpu/x86/frame_x86.hpp`; `share/oops/klassVtable.{hpp,cpp}`; `share/oops/instanceKlass.cpp`; `share/interpreter/linkResolver.cpp`; `share/interpreter/interpreterRuntime.cpp`; `share/oops/resolvedFieldEntry.hpp`; `cpu/x86/templateTable_x86.cpp`; `cpu/{aarch64,riscv,arm,s390,x86}/abstractInterpreter_*.cpp`
- Azul, "A Matter of Interpretation" (secondary; Simonis benchmark): https://www.azul.com/blog/a-matter-of-interpretation-from-bytecodes-to-machine-code-in-the-jvm/
- zackoverflow.dev, "Template Interpreters" (secondary): https://zackoverflow.dev/writing/template-interpreters/
- metebalci.com, "Demystifying the JVM" (secondary): https://metebalci.com/blog/demystifying-the-jvm-jvm-variants-cppinterpreter-and-templateinterpreter/
- albertnetymk.github.io, template interpreter intro (secondary): https://albertnetymk.github.io/2021/08/03/template_interpreter/
- hotspot-dev thread "-Xint: template or c++ interpreter?": https://mail.openjdk.org/pipermail/hotspot-dev/2013-October/011438.html

### CLR / Mono

- `dotnet/runtime` (main, fetched 2026-08-11): https://raw.githubusercontent.com/dotnet/runtime/main/src/mono/mono/mini/interp/transform.c ; .../interp/transform.h ; .../interp/interp.c ; .../interp/interp-internals.h ; .../interp/mintops.def ; .../interp/mintops.h ; .../mini/mini-generic-sharing.c
- Mono docs, "Generic Sharing": https://www.mono-project.com/docs/advanced/runtime/docs/generic-sharing/
- Mono docs, "gsharedvt": https://www.mono-project.com/docs/advanced/runtime/docs/gsharedvt/
- CoreCLR interpreter effort: https://github.com/dotnet/runtime/issues/112742 ; https://github.com/dotnet/runtime/issues/112748 ; https://github.com/dotnet/runtime/pull/113292
- ECMA-335 6th edition (June 2012), Partition III: https://ecma-international.org/wp-content/uploads/ECMA-335_6th_edition_june_2012.pdf

### V8 Ignition

- "Firing up the Ignition interpreter": https://v8.dev/blog/ignition-interpreter
- Ignition docs: https://v8.dev/docs/ignition
- Ignition Design Doc: https://docs.google.com/document/d/11T2CRex9hXxoJwbYqVQ32yIPMh0uouUZLdyrtmMoL44/mobilebasic
- "Launching Ignition and TurboFan": https://v8.dev/blog/launching-ignition-and-turbofan
- "A lighter V8" (feedback-vector costs): https://v8.dev/blog/v8-lite
- V8 source: `src/interpreter/bytecode-operands.h`; `src/interpreter/interpreter-assembler.cc`; `src/interpreter/bytecode-register.h`; `src/execution/frame-constants.h`; `src/execution/isolate.cc`; `src/execution/frames.cc` (`LookupExceptionHandlerInTable`); `src/codegen/handler-table.cc`; `src/interpreter/handler-table-builder.{h,cc}`; `src/compiler/bytecode-graph-builder.cc`; `src/interpreter/interpreter-generator.cc`; `src/regexp/regexp-interpreter.cc`; `src/interpreter/bytecode-generator.cc`; `src/objects/feedback-vector.cc`; `src/heap/object-stats.cc`; `src/interpreter/interpreter.cc`; `src/interpreter/interpreter-generator-tsa.cc`

### wasm3 and WAMR

- wasm3 design doc (primary): https://github.com/wasm3/wasm3/blob/main/docs/Interpreter.md
- wasm3 source: https://github.com/wasm3/wasm3 — `source/m3_exec_defs.h`, `m3_exec.h`, `m3_compile.{c,h}`, `m3_config_platforms.h`, `wasm3_defs.h`, `m3_code.{c,h}`, `m3_env.{c,h}`, `m3_bind.c`, `m3_info.c`, `m3_validate.c`, `wasm3.h`, `m3_core.c`
- LLVM musttail patch: https://reviews.llvm.org/D99517
- LDC musttail-related issues: https://github.com/ldc-developers/ldc/issues/2686 ; https://github.com/ldc-developers/ldc/issues/4795
- LDC pragma surface (no tail-call pragma found): https://github.com/ldc-developers/ldc/blob/master/gen/pragma.cpp ; https://github.com/ldc-developers/ldc/blob/master/runtime/druntime/src/ldc/intrinsics.di
- D guaranteed-TCO discussion (no accepted DIP): https://forum.dlang.org/thread/kmlorniwvjyivjyjntfu@forum.dlang.org ; https://github.com/dlang/DIPs
- WAMR source: https://github.com/bytecodealliance/wasm-micro-runtime — `core/iwasm/interpreter/wasm_interp_fast.c`, `wasm_interp_classic.c`, `wasm_loader.c`, `wasm_mini_loader.c`, `wasm_runtime.c`; `core/iwasm/common/wasm_memory.c`, `arch/invokeNative_general.c`, `arch/invokeNative_xtensa.s`; `core/iwasm/compilation/aot_emit_function.c`; `core/shared/platform/common/posix/posix_thread.c`; `core/shared/platform/linux/platform_internal.h`
- Intel/WAMR fast-interpreter paper (Xu, He, Wang, 2021; archived): https://www.intel.com/content/www/us/en/developer/articles/technical/webassembly-interpreter-design-wasm-micro-runtime.html (archive: https://web.archive.org/web/20230601000000/https://www.intel.com/content/www/us/en/developer/articles/technical/webassembly-interpreter-design-wasm-micro-runtime.html)
- WAMR blog syndication (archived): https://bytecodealliance.github.io/wamr.dev/blog/wamr-fast-interpreter-introduction/ (archive: https://web.archive.org/web/20230601000000/https://bytecodealliance.github.io/wamr.dev/blog/wamr-fast-interpreter-introduction/)
- WAMR wiki Performance page (corroboration): https://github.com/bytecodealliance/wasm-micro-runtime/wiki/Performance
- Shi, Gregg, Beatty, "Virtual Machine Showdown: Stack Versus Registers" (2005; cited by the WAMR paper, not independently re-verified)

### Wasmtime Pulley

- RFC `accepted/pulley.md`: https://github.com/bytecodealliance/rfcs/blob/main/accepted/pulley.md
- Pulley README: https://github.com/bytecodealliance/wasmtime/blob/main/pulley/README.md
- Wasmtime source: `pulley/src/lib.rs`, `opcode.rs`, `decode.rs`, `encode.rs`, `op.rs`, `regs.rs`, `interp.rs`, `interp/tail_loop.rs`, `interp/match_loop.rs`; `cranelift/codegen/meta/src/pulley.rs`
- Docs, "Using Pulley" (~10x expectation): https://docs.wasmtime.dev/examples-pulley.html
- Blog, "Making WebAssembly and Wasmtime More Portable": https://bytecodealliance.org/articles/wasmtime-portability
- Issue #9995, match loop vs tail-call loop (benchmarks): https://github.com/bytecodealliance/wasmtime/issues/9995
- Issue #10102, Pulley performance tracking: https://github.com/bytecodealliance/wasmtime/issues/10102
- treVM paper (third-party corroboration): https://arxiv.org/html/2604.27570v1

### LuaJIT

- LuaJIT source (`v2.1`): https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_bc.h ; https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/vm_x64.dasc ; https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_tab.c ; https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_tab.h ; https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_obj.h ; https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_dispatch.h
- Mike Pall, LuaJIT roadmap 2008 (lua-l, re-quoted 2009): http://lua-users.org/lists/lua-l/2009-02/msg00411.html
- Lambda-the-Ultimate node/3851 (Pall comments, interpreter-vs-JIT numbers): http://lambda-the-ultimate.org/node/3851
- HN item 8605225 (secondary paraphrase): https://news.ycombinator.com/item?id=8605225
- "Building the fastest Lua interpreter.. automatically!" (secondary): https://sillycross.github.io/2022/11/22/2022-11-22/
- LuaJIT issue #924 (NaN-tagging retrospect): https://github.com/LuaJIT/LuaJIT/issues/924

### CPython

- PEP 659, Specializing Adaptive Interpreter: https://peps.python.org/pep-0659/
- What's New in 3.11 / 3.12 / 3.13: https://docs.python.org/3/whatsnew/3.11.html ; https://docs.python.org/3/whatsnew/3.12.html ; https://docs.python.org/3/whatsnew/3.13.html
- `dis` docs (CACHE): https://docs.python.org/3/library/dis.html
- CPython source: https://github.com/python/cpython/blob/main/Python/ceval_macros.h ; .../Python/ceval.c ; .../Python/bytecodes.c ; https://github.com/python/cpython/tree/main/Tools/cases_generator ; .../Include/internal/pycore_code.h ; .../Include/internal/pycore_backoff.h ; .../Python/specialize.c ; .../Python/flowgraph.c ; `Python/generated_cases.c.h`, `Include/opcode_ids.h`, `Include/internal/pycore_opcode_metadata.h`
- faster-cpython/ideas: #642 (tail-calling interpreter) https://github.com/faster-cpython/ideas/issues/642 ; #537 https://github.com/faster-cpython/ideas/issues/537 ; #16 (super-instructions) https://github.com/faster-cpython/ideas/issues/16 ; `3.12/interpreter_definition.md` https://github.com/faster-cpython/ideas/blob/main/3.12/interpreter_definition.md
- Nelson Elhage, "Performance of the Python 3.14 tail-call interpreter": https://blog.nelhage.com/post/cpython-tail-call/
- Ken Jin: https://fidget-spinner.github.io/posts/apology-tail-call.html ; https://fidget-spinner.github.io/posts/no-longer-sorry.html
- Computed-goto history: bugs.python.org issue 1408710; python/cpython issue #42804
- In-session LDC experiment: 230-case `final switch` loop, LDC 1.42.0 (LLVM 21.1.8), `-O3 -release`, generated assembly inspected (session scratchpad, not in-repo)

### Clang ByteCode, Cling and Clang-Repl

- Clang ByteCode source (`clang/lib/AST/ByteCode/`, llvm-project main): `Opcodes.td`, `Opcode.h`, `PrimType.h`, `Interp.{h,cpp}`, `InterpStack.h`, `InterpFrame.h`, `InterpBlock.h`, `Pointer.h`, `Descriptor.h`, `Source.h`, `Compiler.{h,cpp}`, `ByteCodeEmitter.cpp`, `EvalEmitter.h`, `Context.cpp`, `Program.h` — e.g. https://github.com/llvm/llvm-project/blob/main/clang/lib/AST/ByteCode/Opcodes.td
- TableGen backend: https://github.com/llvm/llvm-project/blob/main/clang/utils/TableGen/ClangOpcodesEmitter.cpp
- Docs: https://clang.llvm.org/docs/ConstantInterpreter.html
- Timm Bäder, LLVM Dev Meeting 2024: slides https://llvm.org/devmtg/2024-10/slides/techtalk/Baeder-A-new-constant-expression-interpreter-for-Clang.pdf ; video https://www.youtube.com/watch?v=eMT1dBlaggQ
- Red Hat Developer series: Part 1 https://www.redhat.com/en/blog/new-constant-expression-interpreter-clang ; Part 2 https://www.redhat.com/en/blog/new-constant-expression-interpreter-clang-part-2 ; Part 3 https://developers.redhat.com/articles/2024/10/22/new-constant-expression-interpreter-clang-part-3 ; 2025 update (performance numbers) https://developers.redhat.com/articles/2025/10/15/clang-bytecode-interpreter-update
- Clang-Repl docs: https://clang.llvm.org/docs/ClangRepl.html
- Cling: https://github.com/root-project/cling ; https://root.cern/cling/
- "Interactive C++ with Cling" (LLVM blog, 2020): https://blog.llvm.org/posts/2020-11-30-interactive-cpp-with-cling/
- Vassilev, Canal, Naumann, Russo, "Cling – The New Interactive Interpreter for ROOT 6," J. Phys. Conf. Ser. 396 (2012): https://iopscience.iop.org/article/10.1088/1742-6596/396/5/052071/pdf
- Vassilev, "Enabling Interactive C++ in Clang" (LLVMDev 2021): https://compiler-research.org/assets/presentations/V_Vassilev-LLVMDev21_InteractiveCpp.pdf
- compiler-research.org CaaS: https://compiler-research.org/caas/
- Phabricator D104918 (PTUs/error recovery): https://reviews.llvm.org/D104918 ; D96033 (incremental parsing): https://reviews.llvm.org/D96033

### rustc MIR / Miri

- rustc source (rust-lang/rust): `compiler/rustc_const_eval/src/interpret/{eval_context,stack,operand,place,call,step,memory}.rs`; `compiler/rustc_middle/src/mir/interpret/pointer.rs`; `compiler/rustc_ty_utils/src/layout.rs`; `compiler/rustc_middle/src/ty/layout.rs`; `compiler/rustc_abi/src/layout/ty.rs`
- Miri source (rust-lang/miri): `src/borrow_tracker/*`, `src/alloc_addresses/mod.rs`, `src/concurrency/{data_race,scheduler}.rs`
- rustc-dev-guide: https://rustc-dev-guide.rust-lang.org/const-eval/interpret.html ; https://rustc-dev-guide.rust-lang.org/mir/index.html
- Jung, Kimock, Poveda, Sánchez Muñoz, Scherer, Wang, "Miri: Practical Undefined Behavior Detection for Rust," Proc. ACM Program. Lang. 10 (POPL), Article 48, Jan 2026: https://doi.org/10.1145/3776690 ; PDF: https://research.ralfj.de/papers/2026-popl-miri.pdf
- Miri issue #654 ("Miri is very slow"): https://github.com/rust-lang/miri/issues/654
