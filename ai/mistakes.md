# Mistakes To Avoid

- Check the existing tree and layout before editing paths or source-discovery
  settings.

- Verify external APIs and config syntax against the real local source before
  inventing names.

- Follow instructions literally unless there is a documented reason to deviate.

- Never weaken or replace a test to make it pass.

- Keep touched code aligned with repo conventions (OTBS, local imports).

- For `in` parameters and stronger attributes, reconcile signatures properly
  instead of weakening qualifiers.

- Local imports inside functions/types only. `imported!"..."` only for
  parameter and return types.

- `private:` at module top and explicit `public`/`private` per declaration are
  both required.

- DMD helpers such as `Expression.toChars()` and `Type.nextOf()` are not
  `@safe`; wrap them in a small `@trusted` helper before calling from `@safe`
  code.

- Omit empty parens everywhere, including inside `q{...}` fixtures: `doStuff;`
  not `doStuff();`.

- Stop and wait for user feedback after writing or modifying a test. Do not
  apply the test diff and ask after — stop before.

- When asking for approval to add or modify a test, show the exact proposed
  test or diff before asking.

- For test approval, prefer showing the proposed test code in a
  language-tagged code block over a raw unified diff. Use a diff only when the
  surrounding edit context matters, and still include the test body in a
  syntax-highlighted block if readability would suffer.

- When converting a fixture to an unsupported-diagnostic test, keep the inner
  assertion for the intended supported behavior.

- Don't use `cast(bool)` for STC bitmask checks; compare the masked value
  against `STC.none`.

- Avoid all-literal fixtures unless constant folding is under test; use runtime
  values (mutable locals, function calls) so DMD cannot fold the expression
  before the VM sees it. This applies to tree-walker tests too.

- Prefer `uint[] values;` over `auto values = cast(uint[]) [];`.

- Don't use variadic functions as call-argument fixtures; they introduce
  DMD/runtime varargs constructs that can fail before the VM reaches the
  intended behavior.

- In a named git worktree, prefix patched paths with the worktree directory
  when the session cwd is the parent checkout.

- Don't run parallel `dub test` in the same checkout; it races on shared build
  artifacts.

- Strict TDD: make the smallest green step (fake if needed), then ask for the
  next test before expanding the implementation.

- Prefer `const`; use `auto` with a reason if `const` fails; use an explicit
  LHS type only if `auto` fails (explain why).

- When adding an `else` branch under `if (auto x = ...)`, brace both branches
  if both need `x`; otherwise `x` is out of scope in the second branch.

- Don't add helper functions to fixtures just to avoid constant folding unless
  the purpose is clear; add a comment if you do; otherwise use a direct runtime
  expression.

- When spawning subagents for backend work, delegate bounded implementation to
  worker agents with disjoint file ownership after test approval — don't
  implement everything in the main thread.

- Give subagents that edit code separate git worktrees only when they are
  running in parallel. Sequential subagents should share the same task
  worktree so each worker builds on the previous worker's committed state.

- Unit-threaded focused-test arguments use the full name from `./ut -l` (e.g.
  `ut.ir.ir.minicerealFile`), not just the `@("...")` label.

- Don't add broad acceptance tests in TDD unless the current implementation is
  expected to fail them; an immediately-passing test drives no production code.

- Pass review text containing Markdown backticks via a body file or
  single-quoted input, not double quotes.

- Pass multiline PR bodies through a file or another mechanism that preserves
  actual newlines; shell double-quoted `\n` becomes literal backslash-n text.

- Don't run the local test suite during PR review just to confirm CI; use the
  diff and CI signal.

- In DMD 2.112.1 array equality may stay an `EqualExp` without
  `EqualExp.lowering`; don't assume all array equality reaches
  `object.__equals`.

- Apply `@safe` and other attributes to new helpers immediately, not after
  review.

- Don't put expensive work (process spawning) in per-unittest test helpers;
  cache or move it out of the hot path.

- Don't add `@trusted` without a specific justification.

- When told not to use `@trusted`, don't add wrappers around unsafe DMD APIs.
  Leave the caller unannotated or restructure the code instead.

- When a PR replaces a process-spawning CLI call with a library call, don't
  satisfy review comments by hiding the same CLI call behind a library-shaped
  wrapper.

- TDD: for a first red test asking for a count, return the smallest pre-canned
  value; add another approved test to force real implementation before
  refactoring.

- Prefer `.should == expected` over `.shouldEqual(expected)` in new
  unit-threaded tests.

- Don't use unit-threaded assertions or imports inside `q{}` fixture strings;
  keep host-test dependencies out of code under test.

- In `tests/ut/compiler_api.d`, use `shouldThrowWithMessage`, not naked
  `shouldThrow`, so tests verify the relevant diagnostic text.

- Do not mark helpers that mutate `__gshared` state as `@safe`; D rejects
  direct `__gshared` access from `@safe` functions.

- Don't use `throw new Exception` as a failing-test stand-in unless exception
  handling is under test; use `assert`.

- DMD declaration helpers are type-specific. Don't call a `VarDeclaration`
  helper such as `declarationName` with a `FuncDeclaration`; use the existing
  function helper instead.

- For established interactive-tool behavior, check the closest precedent
  before designing. For a Python-like REPL, use Python as the default baseline
  and diverge only after explaining the concrete reason.

- Do not make the REPL loop parse or classify D code with string heuristics
  such as suffix checks, delimiter counting, keyword checks, or regexes. Ask
  the frontend/eval API for structured cell status instead.

- Do not classify DMD diagnostics by searching the rendered diagnostic text.
  Use DMD AST nodes, symbols, and semantic helpers as the protocol.

- Do not use failed REPL evaluation as control flow to distinguish
  expressions from statements/declarations or incomplete input. Exceptions are
  diagnostics/failures, not a parser API.

- When creating a PR, first create it with `gh pr create` and verify that
  GitHub reports an open PR URL. Only after it exists, open that exact PR URL
  with `xdg-open`.

- Run `ci.sh` before creating a PR. AGENTS.md requires it. Skipping it means
  the PR may be created without benchmarks or integration checks passing.

- When creating a PR from a coverage plan, include the coverage table and
  delta in the PR body. The plan's PR Coverage Report section specifies the
  exact format: starting commit SHA, final commit SHA, covered/total counts,
  percentage, and delta. Don't leave the body blank and make the user ask.

- In D, member access through a pointer auto-dereferences (`ptr.field` works),
  but indexing does NOT (`ptr[i]` is pointer arithmetic). To index into a
  struct wrapped in a pointer (e.g. `Array!T*`), always use `(*ptr)[i]`.

- Don't implement TDD cycles inline in the main thread when the plan prescribes
  subagents; see the existing subagent rule above.

- Don't change vendored code for convenience. If a wrapper or helper is needed,
  add Quickbite-owned code instead, and re-vendor to verify vendor files stay
  clean.

- Backend diagnostics should report mechanically-derived facts. Don't classify
  external symbols with hardcoded "known symbol" lists, and don't probe the
  process loader from diagnostics just to guess symbol availability.

- Don't propose adding or enabling dependency-backed tests for new tree walker
  TDD slices; extract dependency-free language or project-inspired tests
  instead.

- Don't add backend-specific workarounds to make tests pass. A backend either
  implements the language behaviour properly enough for the test, or it should
  be left out of that test.

- Do not accept a prior-agent "narrow exception" when it contradicts a local
  plan. Re-read the plan, identify the conflict, and ask before implementing.

- Don't write language-surface tests that encode behaviour different from DMD
  CTFE or compiled D code. For `pure_` tests, CTFE is canonical unless the
  completed dmd codegen backend proves compiled code behaves differently.

- Treat CTFE floating assertion formatter placeholders such as
  `<float not supported>` the same as `<double not supported>`: mark the
  affected migration test `@ShouldFail` with a concrete upstream formatter
  reason instead of calling it a true red.

- Do not treat `gh pr create --web` as creating a PR. It only opens a
  pre-filled form; use non-interactive `gh pr create` when asked to create one.

- Every `@trusted` declaration needs a nearby comment explaining the concrete
  safety argument that justifies it.

- Do not amend an existing commit unless the user explicitly asks for an
  amend. Make a new commit for follow-up changes.

- For unit-threaded substring assertions, prefer
  `"expected".should.be in actual` over `actual.canFind("expected").should ==
  true`.

- When pinning an improved diagnostic, assert the expected message directly;
  do not only assert that the old bad message is absent.

- When summarizing a failing test run through `tail`/`head`, reconcile the
  visible failure lines against the reported failure count before concluding
  which tests passed; truncated output silently drops the first failures.

- When promoting backend matrix tests in files with repeated identical
  `AliasSeq` lines, patch with nearby test-name context and verify `bin/ut -l`
  shows the intended new backend instance before running the test.

- An in-process ORC/LLJIT load of a dmd `.o` is not equivalent to dlopen: dmd
  emits weak (COMDAT) druntime/phobos template instances whose bodies can be
  degenerate stubs, and ORC binds calls to the object's own weak definition
  (the process-symbol generator only fills *unresolved* symbols), whereas
  dlopen gets ELF interposition to libphobos2's correct copy. Replicate
  interposition: before `AddObjectFile`, define every object symbol the host
  process exports (`dlsym(RTLD_DEFAULT)`) as a weak absolute symbol. Don't
  reach for `_d_dso_registry`/`.init_array` — the LLVM C API can't run
  initializers and the shared-druntime registry path crashes on JIT mmap'd
  code.

- SystemLinker's default-import template codegen is not derivable from "has
  archive imports": root-promoting druntime/phobos modules
  (`prepareArchiveImportsForTemplateCodegen`) permanently mutates process-
  global `importedFrom`, so doing it for an archive dep that needs nothing
  (e.g. the trivial archive unit-test dep) silently breaks unrelated later
  links in the same process — an order-dependent `bin/ut --random` flake, not
  an isolated-test failure. Derive it from whether an archive-backed module
  actually holds template-instance members instead.

- A `bin/ut --random` regression that passes in isolation and only fails in
  some orderings points at process-global state mutation, not the test. Bisect
  it by running both baseline and patched builds several times under `--random`
  and comparing failure counts, not a single shared seed.

- An in-process LLJIT that disposes (`LLVMOrcDisposeLLJIT`) in the long-lived
  test process crashes later: dmd emits user `ClassInfo`/vtables/`TypeInfo` into
  the JIT object, disposal `munmap`s it, and a subsequent GC collection (or
  `gc_term`) dereferences the now-dangling metadata. Run the whole
  create→load→execute cycle in a forked child that `_exit`s (no dispose); report
  results over a pipe. The parent then never executes JIT code nor outlives a
  disposed LLJIT.

- JITLink (LLVM ORC) does not coalesce duplicate undefined symbols the way GNU
  ld does. Under accumulated process-global DMD state dmd can emit one `.o` with
  the same druntime helper (e.g. `gc_expandArrayUsed`) as two `UND GLOBAL`
  symtab entries; JITLink resolves the extra one's GOT slot to 0 and JIT'd code
  calls null, while `dmd -shared`+`dlopen` links the identical object fine. This
  is codegen-deterministic (does not scatter under `--random`). Deduping the
  `LLVMOrcAbsoluteSymbols` map does not help (the duplicate is in the object's
  symtab); a real fix needs object symtab surgery or a dmd codegen change.

- The `--dub` dependency image must be linked with dub's own `libs`/`lflags`,
  not just its dependency archives. Archives reference but do not define the
  system C libraries the package needs (vibe-d → `ssl`/`crypto`), so an image
  built with only `-lphobos2` builds fine (shared objects allow undefined
  symbols) yet fails at `dlopen` (`RTLD_NOW`) with e.g. `undefined symbol:
  RAND_poll`. Forward `dub describe --data=libs` (as `-l<name>`) and `--data=
  lflags` to the image link. General rule: the `--dub` path relays dub's build
  info verbatim; missing link inputs is the same class of bug as missing flags.

- `makeRunners` constructs every backend eagerly, so an LDC bench run builds the
  llvmjit backend even though it is unavailable under LDC and never timed.
  Its ctor `dlopen`s the DMD-compiled dependency image into the LDC host; for a
  package with real shared static ctors (vibe-core) those ctors run DMD-codegen'd
  code against the host's LDC druntime and segfault (extern(D) ABI, ai/spikes/
  ldc-eh/FINDINGS.md) — an uncatchable crash that the surrounding `try/catch`
  cannot turn into a graceful skip. Don't construct a backend you cannot run.

- In status/research reports, don't hedge what you can verify: no "worth
  checking" without checking, no vague verdicts like "essentially complete" —
  state what is done and what is not. When a plan defers work to another plan,
  read and report that plan too instead of leaving the pointer. Don't scope a
  report by session memory (machine-local, may be stale); git history and
  `ai/plans` are the authoritative record.

- This repo sets `push.default = matching`, so a bare `git push` from a
  worktree also publishes every other matching local branch — including the
  user's unpushed local `master`. Always push explicitly:
  `git push origin <branch>` (with `--force-with-lease` after a rebase).
