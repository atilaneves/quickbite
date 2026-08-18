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

AGENTS.md's druntime-first rule applied to the VM's existing
reimplementations, after milestone 1 (whose rules forbid restructuring):

- Associative arrays: compile druntime's real `core.internal.newaa`
  source through the VM's own compiler, like any user code — guest-only
  key/value types have no host-compiled instantiations to call anyway.
  The VM-owned linear-scan `AssocArray` table, its `Op.aa*` opcodes, and
  the `AssocArrayHook` interception table are deleted with the switch.
- Array append: execute druntime's real append/allocation templates.
  The hand-rolled grow path (`appendElement`/`resizeArray`) reallocates
  exact-size, making repeated `~=` quadratic; it retires with the
  switch.
- Port the Interpreter's interception-policy invariant: one enumerated
  hook-exemption list, each entry with a stated retirement condition,
  enforced by assertion; everything else with a D body and no inline
  asm executes for real. The current separate `AssocArrayHook` and
  `isNewArrayRuntimeCall` mechanisms fold into it or retire.

Recorded, demand-driven (take up when a corpus fixture forces the
area): real `Throwable` objects replacing the synthetic
`ExceptionObjectLocal` catch shape.

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
