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
`Backend.evalRepl(EvalCell)`, which re-executes every prior statement.
Expression results persist as `auto __quickbite_repl_value_N = <expr>;`
transcript lines, re-evaluated in every later cell. Cells are accepted into
the transcript only after successful evaluation.

This design has genuine strengths that this plan must preserve:

- **Rollback by construction**: failed cells never enter the transcript.
  (Cling's equivalent — Transactions + DeclUnloader — is its most fragile
  subsystem.)
- **Backend-agnostic frontend**: one session drives all backends, enabling
  the CTFE-oracle testing strategy.
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
5. **Stateless backend interface**: `evalRepl(EvalCell)` hands backends a
   fresh-parsed snapshot each cell — no delta, no session handle, no symbol
   continuity. No implementation of this interface can pass the finding-2
   test. This is the pivotal fault: `ai/plans/dmd-backend.md` slice
   "SystemLinker.evalRepl" as specified can only be implemented as replay.
6. **Replay × dlopen multiplies runtime obligations**: whole-transcript
   compile + link + load per cell re-runs module ctors and re-registers
   eh_frame/TypeInfo/GC ranges, N times over.
7. **No value transport for native code**: no mechanism exists to extract a
   `quickbite.lang.Value` from machine-code execution. The existing
   backend-matrix tests are the exposing tests.
8. **Crash isolation** (deferred — see Deferred Work).
9. **Ergonomics**: no user-visible last-value binding; diagnostic line
   numbers point into invisible transcript text. (Retracted during review:
   classification-parse cost — the classification parses are O(1), they
   parse only the new input; the sole O(transcript) path is the type-alias
   probe, which short-circuits for statements.)

## Constraints

- **dmd glue lowers modules and functions only.** There is no
  compile-an-expression entry point in `glue.d`/`e2ir`/`s2ir`. Whatever the
  REPL feeds a codegen backend must be a semantically-analyzed module
  containing a callable function. The synthetic-function wrapping survives
  this redesign; what changes is what the module contains.
- **`ai/plans/interfaces.md` governs the interface shape.** `Backend`
  splits into `Evaluator` (Value at interactive boundaries only) and
  `Runner` (execution, no Value). The REPL session capability grows out of
  `Evaluator`, not the legacy `Backend` aggregate. Value-transport
  machinery is confined to the Evaluator path; `Runner` for native code is
  dlsym + call. The "dmd objects stay behind frontend boundaries" rule
  applies to VM-family backends; the dmd-codegen backend is inherently a
  dmd client.
- **`ai/plans/dmd-backend.md` is a non-authoritative sketch.** Use it for
  loading mechanics (memfd + mold + dlopen, in-process relocation) only;
  re-validate at implementation time. Its REPL slices are superseded by
  this plan.
- **CTFE remains the canonical oracle for pure behaviour.** Replay is
  *correct* for pure backends and stays as their session implementation.
  The redesign adds a persistent-state path; both must agree on pure
  programs. Where the language itself forbids CTFE (mutating globals,
  module ctors, I/O), compiled-D behaviour is the oracle and tests are
  gated to capable backends.
- **AGENTS.md**: strict TDD; no test additions or changes without
  approval (all tests below are designs awaiting approval); serial test
  runs; no per-test process spawning.

## Target Design

### 1. Structured transcript

Replace the two flat strings with a structured history:

```d
private struct Cell {
    string source;
    EvalCellKind kind;
    string[] declaredNames;   // captured at accept time from the parse
}
private Cell[] moduleCells;
private Cell[] localCells;
```

Joining the cells reproduces today's synthesized source exactly — this
slice is a pure refactor under the existing green suite. Everything else
in this plan hangs off cell granularity: replacement (redefinition),
per-cell `#line` attribution, and per-cell delta modules.

### 2. Backend-owned REPL sessions

The frontend keeps what it is good at: classification (unchanged),
transcript management, semantic analysis under the compiler lock, and
synthesizing compilable modules. Backends gain a session object that owns
cross-cell execution state. Shape (post-interfaces.md; exact names driven
by tests):

```d
public interface Evaluator {
    public Value eval(in string expr);
    public ReplSession createReplSession();
}

public interface ReplSession {
    public Value submit(ReplCellView cell);
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
auto __qb_eval_N() { x = <init-expr>; <new statements only>; return <expr>; }
extern(C) void __qb_cell_N(void* ctx, SinkFunction sink) { ... }  // see 5
```

- **Lifting** is the Cling-DeclExtractor / dabble / Swift move: cell-local
  `auto x = e;` is promoted to a module-level variable so it has real
  storage that later cells reference by symbol. The frontend knows the
  resolved type after semantic analysis.
- **Visibility**: later cells `public import` live prior cells, so
  statements execute exactly once and per-cell cost is O(cell), not
  O(session). Finding 4 (globals) falls out naturally: a module-level
  `VarDeclaration` is just a lifted variable the user declared explicitly.
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

### 5. Value transport (native Evaluator only)

Frontend-synthesized in-cell serialization; the typed wrapper is
untouched:

- A quickbite-owned **REPL prelude module** provides a serializer template
  `__quickbiteSerialize(T)(T value, void* ctx, SinkFunction sink)`:
  type-directed via `static if` introspection — integrals, floats,
  strings, arrays, AAs, structs (field recursion), enums; ranges consumed
  element-wise; anything else emits an `undisplayable` marker plus the
  type name. v1 vocabulary = exactly what the CTFE conversion supports,
  guaranteeing oracle agreement on the existing matrix.
- The synthesized `extern(C)` entry point calls `__qb_eval_N()`, catches
  `Throwable`, and serializes result or error into a tag-length-value
  encoding of `Value`'s variants. C ABI, raw callback: nothing
  druntime-shaped crosses the dlsym boundary; the host copies bytes and
  deserializes into `quickbite.lang.Value`.
- All type and ABI knowledge stays on the D-source side, where the
  compiler handles it. This implements interfaces.md's "convert to Value
  only at Evaluator result boundaries" for machine code. (Cling-style
  host-side ABI capture was considered and rejected: it permanently
  embeds calling-convention knowledge in the host and is Cling's most
  crash-prone subsystem. Text-only rendering, evcxr-style, fails the test
  matrix, which compares structured Values.)
- The byte-stream transport is process-boundary-safe by construction,
  so the deferred crash-isolation work reuses it unchanged.
- **De-risking**: the serializer is plain D with no loader dependency —
  it can be written and fully tested under CTFE and compiled unittests
  before any native backend exists.

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
  repl.submit("get()").should == Value(5);
  ```

- **T3 — module ctors**: (a) `static this() { }` is *already accepted*
  by classification (`StaticCtorDeclaration.isFuncDeclaration` is
  non-null) — regression-guard it; (b) `static this() { counter = 99; }`
  initializes a global — only meaningful after T2's fix; backend-gated
  (CTFE does not run module ctors).

- **T4 — last-value binding** (fails today: undefined identifier):

  ```d
  repl.submit("41 + 1").should == Value(42);
  repl.submit("it").should == Value(42);   // name TBD
  ```

- **B1 — session-depth benchmark** (`benchmarks/repl_session_depth.d`,
  picked up by the existing benchmark dub config, run by `bin/bench.sh`):
  pre-build an `EvalSession` to depth−1 outside the timed loop
  (`EvalSession` is a copyable value type), time `submitComplete(probe)`
  + `evalRepl` at depths 1/10/50/100/200 on CTFE. **The probe must be
  unique per iteration** — `parseModule` caches by source text
  (`sourceCache`, `frontend/compiler.d`), and identical probes would hide
  the parse growth. Variant B times `evalRepl` alone to attribute parse
  vs execution growth. Acceptance criterion for the delta path: linear-fit
  slope of median latency vs depth ≈ 0 (today: affine, ~15× from depth 1
  to 200 expected).

- **T5 — redefinition behaviours** (gates slice 4): function replace,
  overload preservation, rejected replacement keeps old definition,
  local rebinding. Specific cases written at slice time for approval.

- Diagnostic-attribution and hidden-name-referenceability test designs
  are pending a verification report; fold in when confirmed.

## Slice Order

Strict TDD per slice: failing test → dumbest green → refactor → ask.
Dependencies are noted; order within independent slices is flexible.

1. **Structured transcript** (`Cell[]`). Pure refactor, existing suite
   stays green; no new tests.
2. **Per-cell `#line` attribution + diagnostic cleanup.** Needs approved
   attribution tests.
3. **Last-value binding** (T4). Independent of 1 in principle, trivial
   after it.
4. **Redefinition** (T5; depends on 1): module-decl replacement first,
   local rename-the-old second.
5. **Module-level variables** (T2, T3; classification change admitting
   `VarDeclaration`): sound under replay because D requires module-level
   initializers to be static; runtime initialization arrives via
   statements (replayed, pure-only) or, later, lifting on the native
   path.
6. **interfaces.md migration** (Evaluator/Runner split) — prerequisite
   for 7; tracked in `ai/plans/interfaces.md`, not duplicated here.
7. **Backend-owned sessions** (depends on 6): introduce
   `createReplSession`/`ReplSession`; pure backends wrap today's replay
   behaviour behind it (no behaviour change, suite stays green); frontend
   moves to the session API.
8. **Serializer prelude + wire format** (independent of 7; testable today
   under CTFE and compiled unittests).
9. **Native REPL session** (depends on 5, 7, 8, and a working
   codegen-and-load path from the dmd-backend work): delta modules,
   lifting, per-cell link/load, symbol continuity. Gated by T1, T2/T3 on
   the native backend, the full existing REPL matrix, and B1 flatness.

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
- `source/quickbite/repl.d` — Repl struct, diagnostics scrubbing.
- `source/quickbite/backends/package.d` — interface to split per
  `ai/plans/interfaces.md`.
- `ai/plans/interfaces.md` — Evaluator/Runner split (prerequisite).
- `ai/plans/dmd-backend.md` — loading mechanics sketch
  (non-authoritative; its REPL slices are superseded by this plan).
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
- dabble (D, 2014): heap-lifted variables, dlopen'd cells — prior proof
  the lifting approach works for D specifically.
- gore (Go): the replay cautionary tale — same architecture as today's
  quickbite REPL; its README recommends alternatives.
