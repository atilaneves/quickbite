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
  the single-oracle testing strategy (`ai/plans/single-oracle.md`).
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
   test. This is the pivotal fault: the `ai/plans/dmd-backend.md` REPL
   slice as specified can only be implemented as replay.
6. **Replay × dlopen multiplies runtime obligations**: whole-transcript
   compile + link + load per cell re-runs module ctors and re-registers
   eh_frame/TypeInfo/GC ranges, N times over.
7. **No result transport for native code**: no mechanism exists to
   extract a cell's result from machine-code execution. (Per the
   2026-06-12 decision in `ai/plans/value.md` the result is a rendered
   display string, not a `quickbite.lang.Value`; the finding stands, the
   fix shrank.) The existing backend-matrix tests are the exposing tests.
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
  exposes a single execution primitive,
  `EvalResult eval(FuncDeclaration)`, reporting failure as data
  (`EvalResult` is a `SumType!(Value, EvalResult.Diagnostic)` today,
  queried via `result.failed`/`result.diagnostic`; per
  `ai/plans/value.md`, 2026-06-12, the success arm becomes the rendered
  display string and `Value` leaves the contract); `eval(Cell)` is the
  REPL dispatch adapter over it. The `Evaluator`/`Runner` split (display
  results confined to interactive boundaries; `Runner` for native code is
  dlsym + call) is **deferred**
  until the VMs adopt a private execution-slot type — see
  `ai/plans/interfaces.md`. The REPL session capability
  (`createReplSession`) grows out of the `eval` primitive. The "dmd
  objects stay behind frontend boundaries" rule applies to VM-family
  backends; the dmd-codegen backend is inherently a dmd client.
- **`ai/plans/dmd-backend.md` is a non-authoritative sketch.** Use it for
  loading mechanics (memfd + mold + dlopen, in-process relocation) only;
  re-validate at implementation time. Its REPL slices are superseded by
  this plan.
- **`SystemLinker` (compiled D) is the single oracle**
  (`ai/plans/single-oracle.md`). Replay is *correct* for pure backends and
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
cross-cell execution state. Shape (post-interfaces.md, deferred; exact
names driven by tests). `submit` reports failure as data
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

### 5. Result transport (native Evaluator only)

Frontend-synthesized in-cell formatting. (Decision 2026-06-12,
`ai/plans/value.md`: the `Evaluator` contract carries a rendered display
string, so transport is a string crossing the dlsym boundary. The earlier
design here — TLV serialization of `Value`'s variants, deserialized
host-side — is dead.)

- A quickbite-owned **REPL prelude module** provides the canonical
  formatter template `string __quickbiteFormat(T)(T value)`: type-directed
  via `static if` introspection, implementing the type-revealing display
  spec (`3u`, quoted strings — injective per type, see
  `ai/plans/value.md`) — integrals, floats, strings, arrays, AAs, structs
  (field recursion), enums; ranges consumed element-wise; anything else
  renders an `undisplayable` marker plus the type name. v1 vocabulary =
  exactly what the CTFE conversion supports, guaranteeing oracle
  agreement on the existing matrix.
- The frontend synthesizes expression cells as `__quickbiteFormat(expr)`,
  so semantic analysis instantiates the formatter against the real static
  type and the evaluated program itself produces the display string —
  one formatter implementation for every backend that can execute it.
- The synthesized `extern(C)` entry point calls `__qb_eval_N()`, catches
  `Throwable`, and hands the host the resulting string (or error text)
  via length + pointer copy. C ABI, raw callback: nothing druntime-shaped
  crosses the dlsym boundary.
- All type and ABI knowledge stays on the D-source side, where the
  compiler handles it. (Cling-style host-side ABI capture was considered
  and rejected: it permanently embeds calling-convention knowledge in the
  host and is Cling's most crash-prone subsystem. The earlier objection
  to text rendering — "fails the test matrix, which compares structured
  Values" — is obsolete: the matrix moves to text per
  `ai/plans/value.md`.)
- The string transport is process-boundary-safe by construction, so the
  deferred crash-isolation work reuses it unchanged.
- **De-risking**: the formatter is plain D with no loader dependency —
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

1. ~~**Structured transcript** (`Cell[]`)~~ (done in
   `repl-structured-transcript` — `EvalSession` now stores accepted
   module/local history as `TranscriptCell[]` and joins it only when
   synthesizing snapshot source; no new tests). Verified with `ninja bin/ut`
   and `bin/ut --random` (seed `405471795`).
2. ~~**Per-cell `#line` attribution + diagnostic cleanup**~~ (done in
   `repl-line-attribution` — accepted transcript cells now emit
   `#line 1 "<repl cell N>"`, so diagnostics report cell-local source
   locations instead of cumulative invisible transcript lines). Verified
   with `ninja bin/ut` and `bin/ut --random` (seed `377061793`).
3. ~~**Last-value binding** (T4)~~ (done in `repl-line-attribution` —
   expression cells expose the latest accepted result as `it`; failed
   expression cells do not advance it). Verified with `ninja bin/ut` and
   `bin/ut --random` (seed `4078371892`).
4. **Redefinition** (T5; depends on 1): module-decl replacement first,
   local rename-the-old second. Module-level same-signature function
   replacement is done in `repl-line-attribution`; rejected replacements
   keep the old definition; distinct function overloads are pinned as
   preserved. Simple local variable rebinding is done for statement cells
   and preserves intervening references to the old binding. Verified with
   `ninja bin/ut` and `bin/ut --random` (latest seed `3968792440`).
5. **Module-level variables** (T2, T3): T2 is partially done in
   `repl-line-attribution` for the Interpreter. A module function that
   references a prior REPL local declaration promotes that declaration into
   the module transcript, so `int counter; int get() { return counter; }`
   can observe later statement mutation under the Interpreter while
   preserving existing local/display semantics for ordinary declarations.
   CTFE's global-mutation rejection is pinned. Verified with
   `ninja bin/ut`, `bin/ut`, and `bin/ut --random` (seed `3004154049`);
   T3 module constructors and native lifting remain pending.
6. ~~**interfaces.md migration**~~ (done — single `eval` primitive,
   failure-as-data; slices 1–3 in `PLAN.md`) — prerequisite for 7,
   tracked in `ai/plans/interfaces.md`. The `Evaluator`/`Runner` split
   is deferred and is not a prerequisite for backend-owned sessions.
7. ~~**Backend-owned sessions**~~ (done in `repl-backend-sessions` —
   `Backend` now provides an overrideable replay-backed
   `createReplSession` default, pure backends run REPL cells through
   `ReplSession.submit`, and the REPL keeps separate frontend and backend
   sessions so later persistent backends can own execution state). Verified
   with `ninja bin/ut` and `bin/ut --random` (seed `3527759054`).
8. **Formatter prelude** (the canonical display formatter,
   `ai/plans/value.md`; independent of 7; testable today under CTFE and
   compiled unittests). Initial CTFE-capable prelude cases are done in
   `repl-backend-sessions`: `__quickbiteFormat(42)` renders `"42"`,
   `__quickbiteFormat('a')` renders `"'a'"`,
   `__quickbiteFormat("quickbite")` renders `"\"quickbite\""`, and
   `__quickbiteFormat(3.0)` renders `"3.0"`. Verified with
   `ninja bin/ut` and `bin/ut --random` (latest seed `2822468755`).
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
