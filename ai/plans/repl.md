# REPL: From Transcript Replay to Backend-Owned Sessions

## Context

The REPL today is replay-based. `EvalSession`
(`source/quickbite/frontend/cell.d`) stores session state as two flat strings
— `moduleTranscript` (declarations) and `localTranscript` (statements and
expression results). Every submission re-synthesizes the whole session as one
module:

```
<loaded sources> <moduleTranscript>
auto __quickbite_repl_eval_N__() { <localTranscript> <new input> }
```

reparses it in full, and hands the synthetic function to
`Backend.eval(Cell)`, which re-executes every prior statement.
Expression results persist as `auto __quickbite_repl_value_N = <expr>;`
transcript lines, re-evaluated in every later cell. Cells are accepted into
the transcript only after successful evaluation.

This design has genuine strengths that this plan must preserve:

- **Rollback by construction**: failed cells never enter the transcript.
  (Cling's equivalent — Transactions + DeclUnloader — is its most fragile
  subsystem.)
- **Backend-agnostic frontend**: one session drives all backends, enabling
  the single-oracle testing strategy (`AGENTS.md`, Testing).
- **Coherent whole-program semantics** for pure code.

And structural faults, established finding by finding (June 2026 review,
each fault paired with an exposing test or benchmark — see Tests and
Benchmarks below):

1. **O(n²) cost**: cell N re-parses and re-executes cells 1..N−1.
   Contradicts the charter ("optimise for latency", "no whole-program
   compilation"). Exposed by the session-depth benchmark, runnable today
   on CTFE.
2. **Side-effect replay**: re-execution is only observationally correct for
   pure, deterministic code. CTFE's purity masks this; the existing
   `pragma(msg)` transcript exclusion is an ad-hoc patch for the one side
   effect CTFE has. Under native execution every statement is in that
   category. Exposed by the MonoTime rebinding test. The existing test
   suite cannot catch this — it is CTFE-shaped.
3. **No redefinition**: rebinding a variable or redefining a function is a
   hard compile error (same-scope shadowing / duplicate definition). Every
   surveyed REPL (GHCi, Cling, JShell, Scala, fsi, OCaml, Julia) treats
   rebinding as table stakes. The flat-string transcript blocks all known
   fixes.
4. **No module-level variables**: `isEvalModuleDeclaration` excludes
   `VarDeclaration`, so `int counter;` becomes a function-local invisible
   to module-scope functions. Exposed by the globals test (fails today on
   every backend).
5. **Stateless backend interface**: `eval(Cell)` hands backends a
   fresh-parsed snapshot each cell — no delta, no session handle, no symbol
   continuity. No implementation of this interface can pass the finding-2
   test. This is the pivotal fault: a codegen backend behind this interface
   can only implement replay.
6. **Replay × dlopen multiplies runtime obligations**: whole-transcript
   compile + link + load per cell re-runs module ctors and re-registers
   eh_frame/TypeInfo/GC ranges, N times over.
7. **No result transport for native code**: no mechanism exists to
   extract a cell's rendered result from machine-code execution. The existing
   matrix tests are the exposing tests.
8. **Crash isolation** (deferred — see Deferred Work).
9. **Ergonomics**: no user-visible last-value binding; diagnostic line
   numbers point into invisible transcript text. (Retracted during review:
   classification-parse cost — the classification parses are O(1), they
   parse only the new input; the sole O(transcript) path is the type-alias
   probe, which short-circuits for statements.)
10. **Classification parses steal phobos `importedFrom`** (diagnosed
    2026-06-17): classification runs `fullSemantic` on throwaway
    `eval_cell_N` modules (`isIncompleteCell`/`isModuleDeclarationCell` →
    `parseModuleLocked`). The first such parse to import a phobos module
    permanently claims that module's `importedFrom`, so template instances
    (e.g. `std.range.iota`'s Voldemort `Result` from `3.iota`) home on a
    transient classification module not in any link set and strand at link
    in the native backends. This is the cold trigger for the `3.iota` bug. A
    cleanup candidate is to classify by parse only, without `fullSemantic`,
    so classification never claims ownership.

## Current Status

As of 2026-06-17, `Interpreter` is selectable in the REPL with
`--backend=interpreter`. The implicit REPL default remains `ctfe`, so a plain
`qb` / `repl` session preserves the existing CTFE behaviour while the
tree-walker path is available on request.

This does not change the architecture target below: pure backends may still use
snapshot replay, and future native/persistent sessions still need
backend-owned state.

This plan is the sole owner of REPL display syntax, result transport, and
formatter verification. Each backend earns display by executing the guest
formatter; backend-specific host rendering is interim scaffolding. New or
changed display tests use only formatter-capable backends until the remaining
engines can execute the formatter.

## Constraints

- **dmd glue lowers modules and functions only.** There is no
  compile-an-expression entry point in `glue.d`/`e2ir`/`s2ir`. Whatever the
  REPL feeds a codegen backend must be a semantically-analyzed module
  containing a callable function. The synthetic-function wrapping survives
  this redesign; what changes is what the module contains.
- **The live interfaces govern the shape.**
  `source/quickbite/backends/evaluator.d` exposes the single execution
  primitive `EvalResult eval(FuncDeclaration)`, with a rendered display
  string on success and failure carried as data; `eval(Cell)` is the REPL
  dispatch adapter. `source/quickbite/backends/runner.d` owns whole-module
  unittest execution. `Backend` composes the two capabilities, while a
  runner-only backend can implement `Runner` directly. The REPL session
  capability (`createReplSession`) grows out of the eval primitive. The "dmd
  objects stay behind frontend boundaries" rule applies to VM-family
  backends; the dmd-codegen backend is inherently a dmd client.
- **Native loading mechanics need fresh evidence.** Re-validate memfd, mold,
  dlopen, and in-process relocation choices when the native session starts;
  no live plan owns an implementation sketch for them.
- **`SystemLinker` (compiled D) is the single oracle**
  (`AGENTS.md`, Testing). Replay is *correct* for pure backends and
  stays as their session implementation, but it is an implementation note,
  not an oracle claim: the redesign adds a persistent-state path, and both
  must agree with compiled-D behaviour. `Ctfe` is not an oracle; where it
  diverges its behaviour is characterized. Tests are gated to capable
  backends.
- **AGENTS.md**: strict TDD; no test additions or changes without
  approval (all tests below are designs awaiting approval); serial test
  runs; no per-test process spawning.

## Target Design

### 1. Structured transcript

Replace the two flat strings with a structured history:

```d
private struct TranscriptCell {   // `Cell` now names the renamed eval cell
    string source;
    Cell.Kind kind;
    string[] declaredNames;   // captured at accept time from the parse
}
private TranscriptCell[] moduleCells;
private TranscriptCell[] localCells;
```

Joining the cells reproduces today's synthesized source exactly — this
slice is a pure refactor under the existing green suite. Everything else
in this plan hangs off cell granularity: replacement (redefinition),
per-cell `#line` attribution, and per-cell delta modules.

### 2. Backend-owned REPL sessions

The frontend keeps what it is good at: classification (unchanged),
transcript management, semantic analysis under the compiler lock, and
synthesizing compilable modules. Backends gain a session object that owns
cross-cell execution state. The interface split is complete; exact session
extensions remain driven by tests. `submit` reports failure as data
(`EvalResult` — `result.failed` is the discriminator), consistent with
the `Backend.eval` primitive; it does not throw on evaluation failure:

```d
public interface Evaluator {
    public string eval(in string expr);  // one-shot display string;
                                         // throws at the boundary
    public ReplSession createReplSession();
}

public interface ReplSession {
    public EvalResult submit(ReplCellView cell);  // session; failure as data
}
```

`ReplCellView` is produced by the frontend per accepted-candidate cell and
offers two views; each backend consumes the one matching its execution
model:

- **Snapshot view** (today's behaviour): the whole-transcript module and
  synthetic eval function. Pure backends — CTFE, interpreter, bytecode, IR
  — implement their session *by* replay using this view. Their behaviour
  does not change; the oracle role is preserved.
- **Delta view**: a per-cell module containing only the new cell's
  declarations and statements, with prior cells' symbols visible (see 3).
  Persistent-state backends (native codegen) consume this.

Both views are synthesized lazily so neither path pays for the other.
Accept-on-success is preserved at the frontend: a backend session is told
to commit a cell only after evaluation succeeds; a failed cell's artifacts
(loaded images, symbols) are discarded before the transcript advances.

### 3. Delta modules and variable lifting (native path)

Each cell becomes its own dmd module, compiled and loaded once:

```d
module __qb_cell_N;
public import __qb_cell_A, __qb_cell_B, ...;  // live prior cells
// lifted: cell-local variable declarations promoted to module scope,
// declared with their semantically-resolved type, assigned in the eval
// function (D module-level initializers must be static; runtime
// initialization moves into the eval body):
T x;
// new module-level declarations verbatim
auto __qb_eval_N() {
    x = <init-expr>; <new statements only>;
    return __quickbiteFormat(<expr>);  // see 5
}
extern(C) void __qb_cell_N(void* ctx, SinkFunction sink) { ... }  // see 5
```

- **Lifting** is the Cling-DeclExtractor / dabble / Swift move: cell-local
  `auto x = e;` is promoted to a module-level variable so it has real
  storage that later cells reference by symbol. The frontend knows the
  resolved type after semantic analysis.
- **Visibility**: later cells `public import` live prior cells (drepl's
  import-chain mechanism), so statements execute exactly once and
  per-cell *execution* cost is O(cell), not O(session). The compile
  component still grows with depth — cell N imports N−1 modules and
  identifier lookup searches them — which is why B1's acceptance is
  split (see Tests and Benchmarks). Finding 4 (globals) falls out
  naturally: a module-level `VarDeclaration` is just a lifted variable
  the user declared explicitly.
- **Loaded images are never `dlclose`d.** Old cells' symbols stay
  referenced; D shared-object unloading with live GC pointers and TLS is
  unsafe anyway. Per-load runtime obligations (module ctors, eh_frame, GC
  ranges, TypeInfo) are paid exactly once per cell.
- **Known divergence to document**: `private` across cell-module
  boundaries behaves differently from the single-module snapshot view.
  Default (public) visibility is unaffected. Resolve when a test forces
  it.

### 4. Redefinition

Enabled by the structured transcript; semantics agreed during review:

- **Module-level declarations: replace + whole-program recheck.** A new
  cell declaring a name an earlier cell declared *replaces* that cell.
  For functions: same name and parameter list → replace; different
  parameter list → legal overload, keep both. The replacement is accepted
  only if the entire resulting transcript still compiles and evaluates —
  the existing accept-on-success flow gives this atomically, with
  rollback, for free. (JShell needs a dependency graph and a
  `RECOVERABLE_DEFINED` limbo for the same feature; whole-transcript
  recompilation makes the cascade check free here.)
- **Statement-local rebinding: rename-the-old.** D forbids local
  shadowing even in nested blocks, so when a new cell rebinds `x`: rewrite
  the old declaration to a hidden name and rewrite references to `x` in
  the intervening cells. Under replay this is exact (those uses referred
  to the old binding; re-execution computes identical results). This is
  GHCi's shadowing semantics implemented textually.
- **Native path**: replacement at cell granularity maps onto the symbol
  map — the replaced cell's module drops out of future cells' import
  lists; its already-loaded image stays for memory safety. Divergence to
  document: under replay, replacement retroactively changes history;
  under persistent state, executed effects are immutable. Unobservable
  for pure backends — exactly the boundary where replay is sound.

### 5. Result transport and display

The `Evaluator` contract carries a rendered display string. The frontend
synthesizes expression cells as `__quickbiteFormat(expr)`, so semantic
analysis instantiates the guest formatter against the expression's static
type. Every formatter-capable backend executes that same D function.

A native session exports only the rendered string or diagnostic through a C
entry point and a length-plus-pointer copy. No D runtime object crosses the
loader boundary. This transport also works across the deferred crash-isolation
process boundary.

#### Display syntax

The formatter produces concise inspection text. It is not injective by type,
and current output is not universally valid D source. The current syntax is:

- `bool`, signed integrals, and the default `int` use their ordinary text.
  `uint`, `long`, and `ulong` add `u`, `L`, and `UL`.
- Floating values always contain a decimal point or exponent. `float` adds
  `f`, `real` adds `L`, and `double` has no suffix.
- Characters use single quotes. Strings use double quotes; `wstring` and
  `dstring` add `w` and `d`. Width is not shown for characters, and narrow
  signed and unsigned integral types have no suffix.
- Arrays render as `[element, ...]`. Associative arrays render as
  `[key:value, ...]`; their iteration order is unspecified.
- Structs render as `Type(field, ...)` using declared fields only. Declared
  enum members render as `Type.member`.
- Null pointers, references, functions, and delegates render as `null`.
  Non-null functions, delegates, classes, and interfaces render as
  `<undisplayable>`. Non-null pointer text is otherwise unspecified.
- Type qualifiers and mutability are not displayed. A `void` cell produces no
  display output.

Three parseability gaps have issue owners: character and string escaping is
[issue #559], non-member enum casts are [issue #557], and typed empty
associative arrays are [issue #564]. Do not claim general D-source round-trip
until those public behavior contracts are complete.

#### Formatter verification

- Fast hermetic tests compare public cell output with hand-written expected
  text. They do not test private formatter helpers.
- [Issue #567] owns the differential layer that compares the same cell with
  `SystemLinker` and each formatter-capable backend.
- Runtime semantic tests prove behavior that display cannot reveal. Static
  type queries do not prove a backend used the correct runtime width or
  signedness.
- Representation fixtures seed values from runtime expressions when DMD
  folding would otherwise remove the behavior under test.

### 6. Ergonomics

- **Last-value binding**: expression results already persist as
  `__quickbite_repl_value_N`; give the latest a user-visible name. Open
  decision: single rebinding `it` (GHCi) vs numbered `res0`-style
  (Scala/JShell); interacts with the redefinition rules in 4.
- **Diagnostic attribution**: emit a `#line` directive per cell (the
  `#line 1 "<repl>"` machinery exists), giving "cell N, line M"
  attribution instead of positions in invisible accumulated text. The
  `userDiagnostic` string-scrubbing in `repl.d` shrinks accordingly.
- **`:t`**: answer from semantic analysis directly instead of evaluating
  `<expr>.stringof` through a backend. Recommendation only — observable
  behaviour today is correct; `.stringof` is also unstable across dmd
  versions.
- **Classification**: untouched (fault retracted; see finding 9).

## Tests and Benchmarks

All designs below require approval before being added (AGENTS.md). Each
gates the slice listed in Slice Order. Lesson baked into the designs:
deterministic in-process state is reconstructed correctly by replay —
only nondeterminism or external effects can expose re-execution, and
expressiveness gaps are exposed by straight-line behaviour tests.

- **T1 — replay exposure** (gates native session; inapplicable to pure
  backends by construction):

  ```d
  repl.submit("import core.time;");
  repl.submit("auto t = MonoTime.currTime.ticks;");
  const first  = repl.submit("t");
  const second = repl.submit("t");
  first.should == second;   // persistent: equal; replay: rebound per cell
  ```

- **T2 — module-level globals** (fails today on every backend; after the
  fix, gated to backends that can mutate globals — CTFE correctly rejects
  global mutation at compile time, and that rejection is itself pinned):

  ```d
  repl.submit("int counter;");
  repl.submit("int get() { return counter; }");   // throws today
  repl.submit("counter = 5;");
  repl.submit("get()").should == "5";
  ```

- **T3 — module ctors**: (a) `static this() { }` is *already accepted*
  by classification (`StaticCtorDeclaration.isFuncDeclaration` is
  non-null) — regression-guard it; (b) `static this() { counter = 99; }`
  initializes a global — only meaningful after T2's fix; backend-gated
  (CTFE does not run module ctors).

- **T4 — last-value binding** (fails today: undefined identifier):

  ```d
  repl.submit("41 + 1").should == "42";
  repl.submit("it").should == "42";   // name TBD
  ```

- **B1 — session-depth benchmark** (`benchmarks/repl_session_depth.d`,
  picked up by the existing benchmark dub config, run by `bin/bench.sh`):
  pre-build an `EvalSession` to depth−1 outside the timed loop
  (`EvalSession` is a copyable value type), time `submitComplete(probe)`
  + `eval(Cell)` at depths 1/10/50/100/200 on CTFE. **The probe must
  be unique per iteration** — `parseModule` caches by source text
  (`sourceCache`, `frontend/compiler.d`), and identical probes would hide
  the parse growth. Variant B times `eval(Cell)` alone to attribute
  parse
  vs execution growth. Acceptance for the delta path is split, because
  its compile component is inherently Ω(depth): the per-cell import list
  is O(depth) and identifier lookup searches it, so total-latency slope
  ≈ 0 is unsatisfiable as a gate (drepl, the same import-chain shape,
  slows with session depth in the field). The **hard gate** is Variant
  B: linear-fit slope of median *execution* latency vs depth ≈ 0 — that
  is what replay fails. Total latency must show only a small slope,
  measured and documented, not gated at ≈ 0; if the measured
  import-chain slope proves unacceptable, the escape hatch is a
  Cling-style flat symbol namespace instead of a transitive import
  list. (Today: affine, ~15× from depth 1 to 200 expected.)

- **T5 — redefinition behaviours** (gates slice 4): function replace,
  overload preservation, rejected replacement keeps old definition,
  local rebinding. Specific cases written at slice time for approval.

- Diagnostic-attribution and hidden-name-referenceability test designs
  are pending a verification report; fold in when confirmed.

## Slice Order

Strict TDD per slice: failing test → dumbest green → refactor → ask.
Dependencies are noted; order within independent slices is flexible.

1. **Formatter prelude.** CTFE and Interpreter expression cells synthesize
   `__quickbiteFormat(expr)` for supported scalars and aggregates. Section 5
   owns the syntax and verification contract. Add a backend to display rows
   only after it executes the guest formatter; then remove its interim host
   rendering.
2. **Native REPL session** (depends on 5, 7, 8, and a working
   codegen-and-load path): delta modules, lifting, per-cell link/load, symbol
   continuity. Gated by T1, T2/T3 on the native backend, the full existing
   REPL matrix, and B1's split criterion (execution-slope flatness; compile
   slope measured and documented).

## Deferred Work

**Crash isolation** (finding 8, discussion deferred): a native cell crash
kills compiler and session; every mature system isolates (GHCi iserv,
JShell child JVM, evcxr child process). Cost containment now, not
implementation: the native session's execution seam is "load these object
bytes, call this symbol, stream result bytes back" — implementable
in-process (v1) or by a child process over a pipe (same interface; the
transport from Target Design 5 is already process-boundary-safe). The
child-process slice, if and when wanted, is gated by a
session-survives-null-deref test and spawns one process per session, not
per test.

## Open Questions

- `it` vs `res0`-style naming for the last-value binding.
- `private` semantics across cell-module boundaries on the delta path.
- TLS variables lifted to cell-module scope: per-thread semantics under
  a session that may later move execution to a child process.
- Whether the snapshot view should eventually be retired for pure
  backends too (replay stays sound for them; retiring it is a latency
  question answered by B1, not a correctness one).

## Key Reference Files

- `source/quickbite/frontend/cell.d` — EvalSession, classification,
  transcript synthesis; most of slices 1–5 land here.
- `source/quickbite/repl/package.d` — Repl struct, diagnostics scrubbing.
- `source/quickbite/backends/evaluator.d` — evaluation result and REPL-session
  contracts.
- `source/quickbite/backends/runner.d` — whole-module unittest execution.
- `source/quickbite/backends/package.d` — composition of evaluator and runner
  capabilities for full backends.
- `tests/ut/backends/api/repl.d` — behaviour matrix every change must
  keep green; the acceptance gate for the native session.

## Prior Art Map

- Cling/clang-repl: persistent Sema/ASTContext, per-input modules into a
  flat JIT namespace; DeclExtractor lifting; fragile rollback (avoided
  here by accept-on-success).
- GHCi: `closure_env` name→value linker state; shadowing with old
  bindings alive; iserv process separation.
- Swift REPL: per-input `REPL_N` modules; top-level vars heap-allocated,
  later modules link by address.
- evcxr: per-cell dylib + dlopen, variable store, in-cell rendering —
  closest existing native-REPL-without-JIT analogue.
- JShell: replace + dependency cascade (superseded here by free
  whole-transcript recheck); `$N` scratch variables.
- drepl (D, Nowak — the canonical D REPL): per-line module compiled
  with `dmd -shared`, dlopen'd; state persists via an import chain over
  prior cells plus linking their `.so`s — the session-level existence
  proof for Target Design 3 (import chain, link prior images, never
  unload). Its quirks are exactly this plan's deltas from it:
  module-scope declarations collide with D's static-initializer rule
  (solved here by lifting with runtime init in the eval body), no
  redefinition, textual classification without semantic analysis, and a
  fresh dmd process per line — the cost baseline the in-process
  frontend must beat. Its depth-dependent slowdown is the field
  evidence behind B1's split criterion.
- dabble (D, 2014): heap-lifted variables, dlopen'd cells — prior proof
  the lifting approach works for D specifically.
- gore (Go): the replay cautionary tale — same architecture as today's
  quickbite REPL; its README recommends alternatives.

[issue #557]:
  https://github.com/atilaneves/quickbite/issues/557
[issue #559]:
  https://github.com/atilaneves/quickbite/issues/559
[issue #564]:
  https://github.com/atilaneves/quickbite/issues/564
[issue #567]:
  https://github.com/atilaneves/quickbite/issues/567
