# Bytecode VM plan

Created from scratch 2026-08-11 after deleting the previous plan. Nothing
from that plan — nor from value.md, ffi.md, or RESEARCH.md — binds this one;
the only inherited constraint is the project goal: minimal
edit-to-unittest-verdict latency. The design survey behind this plan lives
in ai/research/bytecode.md.

## North star

The backends compete on edit-to-unittest latency and the bake-off decides
which wins; Bytecode is one competitor, not the anointed engine. Its entry
is an interpreter-only VM (no JIT tier — that is LLVMJit's job; no CTFE
role) compiled lazily per function from DMD's semantically-analysed AST,
with values in native D memory layout throughout. First make it right, then
profile, then make it fast.

## Milestone 1 — druntime-first convergence

Principle: every operation either compiles to bytecode from its D body or
crosses to native via FFI because no body exists (extern without source,
inline asm, DMD BUILTIN intrinsics). Where the frontend populates
`Expression.lowering`, the backend compiles that lowering — agreement with
dmd/LDC/GDC by construction. Name-based diversion of code with an available
body is forbidden, enforced by porting the Interpreter's
interception-policy guard (assertion at function-compilation time, an
enumerated exemption list, each entry with a stated retirement condition).

Work queue (each item = one commit, exposing red fixture written before the
fix, SystemLinker as the behavior oracle):

1. Consume the frontend lowerings for `~=`, `.length=`, `new T[n]`/multi-dim,
   `~`, and array literals; delete the hand-rolled append/resize/alloc/concat
   opcodes and machine.d helpers, `isNewArrayRuntimeCall`, and the
   `_d_arrayctor` interception. `CatDcharAssignExp` is un-lowered by design
   and its helpers live in non-importable `rt/lifetime.d`: declare
   `_d_arrayappendcd`/`_d_arrayappendwd` as `extern(C)` prototypes in D
   source and the ordinary no-body path makes the FFI call. Test changes
   follow behavior coverage: delete `Omit`s the switch turns green; new
   tests only for uncovered documented behavior, never implementation
   details.
2. Delete the remaining name-matched diversions with available bodies, one
   commit per mechanism: `__switch`, `arrayOp!`, `_aApply*`, `__ArrayDtor`,
   `emplace*`, `_d_arraybounds*`, and the `_d_assert_fail` shape-sniffing
   (compile the real core.internal.dassert machinery). Body available →
   compile it; no body → FFI; never a hand-rolled substitute.
3. Port the interception-policy guard with the enumerated exemption list
   (DMD BUILTIN intrinsics, the dchar-append glue, TypeInfo materialization,
   plus anything items 1-2 prove genuinely uncompileable), asserted at
   function-compilation time.
4. Real object model: real GC allocation with DMD's field offsets, real
   `__vptr`/`TypeInfo_Class`; the VM-private heap, class table, and parallel
   vtables are deleted. Unlocks class receivers across FFI and makes
   `CastExp.lowering` (`_d_cast`) compileable — the unchecked-downcast bug
   gets its exposing fixture first.
5. Real `Throwable`: throw allocates real class objects, catch matches
   through the real hierarchy; `ExceptionObjectLocal` and the throw-string
   fast path die; the VM's handler-stack unwinder stays as mechanism.

Items 1-3 are independent of 4-5; 4 gates 5.

Recorded deviation, item 4's territory: a guest function-pointer value is
currently a `Program.functions` table index, not a native code address —
the VM emits no machine code for a bytecode-compiled function, so no such
address exists yet. A native-leaf target (`&f` where `f` has no body, e.g.
`core.internal.dassert`'s `assumeFakeAttributes` closing over a druntime
hook) shares the same index space via a table-entry marker rather than a
real address. This encoding must never cross the FFI boundary; it retires,
at least for native-leaf targets (which do have real addresses), once
inbound FFI/native-callback support forces a raw-address representation.

## Milestone 2 — cerealed green via bench.sh

Acceptance: `bin/bench.sh -b bytecode -b system-linker --dub cerealed`
prints a bytecode row agreeing with SystemLinker, the compiled-truth
oracle. No dependency on the Interpreter backend's status.

Rules of engagement:

- The ordering authority is the cerealed failure stream: gaps get fixed in
  the order cerealed surfaces them. Gaps it never touches queue in
  milestone 2.
- Every fix is generic D language support; nothing cerealed-specific.
- Strictly additive on the current architecture: no research-motivated
  restructuring inside this milestone.
- Per discovered failure: search the existing suite for an
  `Omit!(Bytecode, ...)` fixture that looks like the same gap; a candidate
  is confirmed only by deleting the omit and reproducing the same failure,
  and then becomes the red test for the fix (the omit stays deleted).
  Otherwise write a new regression test on the widest backend matrix that
  can run it.

Work queue:

1. Make the acceptance gate machine-checkable. bench exits 0 when it skips
   a disagreeing or failing backend (benchmarks/cli.d returns nonzero only
   for preparation failure), so a green-looking run can hide a missing
   bytecode row. The gate must fail when the row is absent or disagrees.
2. Debug-mode discovery: a way to run a dub package's unittests on Bytecode
   under the normal asserts-on build, so gaps surface as named diagnostics
   in batches rather than release-mode segfaults. bench.sh deliberately
   refuses non-optimised builds, so discovery needs its own entry point
   driving the same dub-package preparation machinery from the debug build.
3. First known blocker: `bin/bench.sh -b bytecode -b system-linker --dub
   cerealed -w 0 -r 1` currently dies with SIGSEGV inside
   `Compiler.compileFunctionBody` while lazily compiling a function reached
   from a cerealed unittest (preparation itself succeeds). Diagnose under
   item 2's debug entry; the release build has asserts off, so whatever
   diagnostic this would be surfaces as a raw crash.
4. The failure stream from items 2–3: one work item per discovered gap,
   handled per the rules above, until the acceptance gate is green.

## Milestone 3 — broad language coverage

Work through the remaining documented Bytecode gaps: every
`Omit!(Bytecode, ...)` in the test matrix is by definition open work. Omits
carry no special status — the refusal rationales recorded in them predate
this plan and do not bind; each gets fixed or re-justified when reached.
Re-measure the backlog with
`grep -rn 'Omit!(Bytecode' tests/ut/backends/runner/`.

## Milestone 4 — performance

Blocked on milestone 1: profiling needs a real workload, and bench.sh
timings on the dub corpus are the measure — microbenchmarks explain,
project latency decides. Timings follow overview.md's measurement
contract (GC enabled, ratchet, corpus selection). The canonical backlog
is the ranked cheapest-first technique list in ai/research/bytecode.md's
final section; profile before picking any of them.

## Out of scope

Interpreter backend regressions (tracked elsewhere), CTFE, any JIT tier,
and inbound FFI (native→VM callbacks) unless cerealed forces it.
