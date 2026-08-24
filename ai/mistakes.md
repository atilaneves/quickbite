# Mistakes To Avoid

- Check the existing tree and layout before editing paths or source-discovery
  settings.

- Verify external APIs and config syntax against the real local source before
  inventing names.

- Follow instructions literally unless there is a documented reason to deviate.

- Never weaken or replace a test to make it pass.

- Never put a required evaluation inside `assert`. Release builds remove the
  expression and can read untouched destination storage. Evaluate first, then
  report a normal checked failure if the required operation declines.

- A ref-returning call's address path is its complete lvalue contract. Reuse
  that path for assignment and reference forwarding. A second assign-during-
  return mode duplicates argument and receiver evaluation and preserves a
  boxed call channel.

- When a normalization helper may return its input unchanged, do not infer
  that normalization occurred solely from the result's value category.

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

- When an operation accepts operands with different physical representations,
  preserve each operand's type metadata for diagnostics too. Reusing the
  execution's common type can select the wrong stride or read past an operand.

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

- A native callback retained beyond an interpreted child call must dispatch
  through root-execution state, not a delegate whose context points at the
  child Walker's stack frame.

- Do not use Python scripts to rewrite repository files. Use `apply_patch` for
  semantic edits and reserve dedicated formatters for bulk formatting.

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

- Do not omit untested backend rows: verify every mature backend and include
  each one that passes.

- In `@safe pure` generic guest formatters, dispatch class and interface
  references before falling back to `std.conv.text`; its reference formatting
  is `@system` and impure even when the runtime reference is null.

- When replacing a boxed value store with typed native places, handle DMD's
  `Tnull` as its own place-composable leaf. Supporting null only for
  pointer-like destinations does not cover `auto value = null`.

- In zsh, do not assign to reserved readonly parameters such as `status`; use
  a task-specific variable name.

- After routing an aggregate rvalue through a shared place, delete downstream
  predicates that reinterpret its bytes as the old transport metadata. A
  place load exposes the language value, not a legacy descriptor wrapper.

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

- Do not retain pointer-keyed DMD AST metadata across independently parsed
  fixtures. DMD can reclaim an AST node and reuse its address, making stale
  metadata appear to belong to an unrelated node.

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

- Link DMD-built dependency archives through DMD's driver, not bare `cc`.
  Compiler installations may keep shared Phobos outside the system linker's
  default search paths even though DMD's configuration can find it. Preserve
  whole-archive ordering when forwarding the archives through the driver.

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

- This repo sets `push.default = matching`, so a bare `git push` from one of
  several worktrees can publish unrelated matching local branches, including
  the user's unpushed `master`. Push the current worktree explicitly with
  `git push origin HEAD:<branch>` (and `--force-with-lease` after a rebase).

- dmd's own AST visitor classes (`Visitor`, `SemanticTimePermissiveVisitor`,
  `StatementRewriteWalker`, etc.) are `extern (C++)`. A subclass written to
  override one of their `visit(...)` overloads must also be declared
  `extern (C++)` — a plain D subclass does not share the Itanium-ABI vtable
  layout, so dmd rejects the override with "does not override any function,
  did you mean to override alias ...", even though the exact same override
  compiles fine once `extern (C++)` is added.

- Quickbite runs the dmd frontend with no attached backend
  (`-version=NoBackend`). Anything whose resolution is deferred to codegen
  never happens: an `asm { ... }` block's individual instructions stay `null`
  placeholders inside its `CompoundAsmStatement.statements` even after
  `functionSemantic3` — check for the `CompoundAsmStatement` node itself
  (present from parse time), not for `AsmStatement`/`InlineAsmStatement`
  leaves, when detecting "this function's body is inline asm" in this
  codebase.

- Code comments must stand on their own. Never cite this repo's planning or
  review artefacts from `source/` or `tests/`: no `ai/plans/...` pointers as the
  *reason* a line exists, no "item N"/"decomposition item N"/"phase"/"follow-up"
  narrative, and above all no code-review labels ("review round 2, finding 3",
  "the BLOCKER above"). A reader of the source has no plan and no review in front
  of them, so such a comment conveys nothing; state the mechanism or the
  invariant instead ("drop the cell on rebind so a stale pointer cannot resolve
  into a later binding"), which is what the reference was standing in for. This
  is easy to get wrong when a commit is driven from a plan or a review finding —
  the framing that produced the change is not the framing that explains it. A
  bare `§`-section citation to a design doc (e.g. `ffi.md §35.2`) is a different
  thing and remains fine: it points at a stable specified contract, not at
  narrative.

- When a fixture carries a `SystemLinker`-oracle expectation, give it
  `Matrix!(...)` and opt backends out only via `Omit!(B, Because.…, "note")` —
  never hand-roll a shorter `AliasSeq!(Interpreter, SystemLinker)`. That raw form
  is reserved for characterization pins that carry no oracle expectation
  (`tests/ut/backends/package.d`), and using it for an oracle-backed test silently
  drops every backend you didn't happen to type — `LLVMJit` especially, which is
  compiled code and usually agrees with the oracle. `Matrix!()` forces the
  question: a backend can only leave the matrix with an explicit reason, so
  "never tried it" stops being expressible. Actually run each backend and promote
  the ones that pass.

- Before assuming a druntime/Phobos function referenced by name (e.g. for an
  interpreter/backend name-based special case) is a body-less `extern(C)`
  prototype, check the actual vendored source. `core.stdc.math.fabs` is
  body-less, but `std.math.algebraic.fabs`/`sqrt`, `std.math.exponential.pow`,
  and `std.math.traits.isInfinity`/`signbit` — the versions dmd's own
  `isBuiltin()` recognises via its `BUILTIN` enum — all have real D bodies.
  Likewise `core.internal.atomic.atomicStore`/`atomicFetchSub` have D source
  that just forwards to a sibling primitive (`atomicExchange`/
  `atomicFetchAdd`) which contains the actual asm.

- In the bytecode core, don't assume a runtime crash traces back to whatever
  compiler change most recently altered control flow near the crashing test;
  verify the mechanism by instrumenting the actual compiled instructions and
  runtime values, not by reasoning from the diff alone. A crash that only
  started reproducing after a fix that made compilation *proceed further*
  (rather than abort early with a diagnostic) can be a pre-existing,
  unrelated bug the earlier abort was accidentally masking. Concretely:
  `structBaseOffsetOrMaterialise`'s `CallExp` branch used
  `compileCall(call).offset` as a struct constructor call's (`S(args)`)
  result location; DMD types that `CallExp` as the constructed struct even
  though `__ctor` is declared `void`, so `compileCall`'s destination for it
  is the shared void-call dummy slot, not the constructed value, which
  actually lives at the call's own receiver offset (`methodReceiverOffset`).
  This crashed any struct with an explicit constructor returned by value
  (e.g. `std.array.appender`'s `return Appender!A(null);`), unrelated to
  virtual dispatch or vtables despite the crash first appearing right after
  a vtable-registration fix.

- For a suspected bytecode-core VM bug, bisect with `bin/qb`'s non-interactive
  REPL (`./bin/qb -b bytecode -c '<expr>'`, or pipe statements with a trailing
  `;` then a bare final expression into `./bin/qb -b <backend>`; an IIFE like
  `./bin/qb -b bytecode -c '(){ ulong v = 256; return (v && true) ? 1 : 0;
  }()'` lets `-c` take statements too; compare against `./bin/qb -b
  system-linker` as the oracle) instead of decoding a crash's compiled
  instructions by hand through gdb: it isolates the exact failing construct
  in seconds where manual `Instruction` field/`Op`-ordinal decoding from a
  core dump takes many single-stepped `print` calls.

- Don't act on a claimed bug mechanism inherited from a prior agent's report
  without re-verifying it against the oracle first; a plausible-sounding
  attribution to a nearby function can be wrong even when the symptom is
  real, and acting on it sends the fix into the wrong code. Concretely,
  `ulong v = 256; if (!v)` misbehaving was mis-attributed to
  `compileBoolCondition`/`Op.notBool`/`Op.jumpIfFalse`/`Op.jumpIfTrue`
  reading only the condition's low byte; the actual defect (fixed in
  `b0cddcfa`) was that DMD's `LogicalExp` semantic folds `x && true`/`x ||
  false`/`true && x` into `CastExp(bool, x)`, and
  `compileCastExpression`'s bool-target branch in
  `source/quickbite/backends/bytecode/core/compiler.d` only special-cased
  pointer sources — every other source fell through to the generic
  `size(target) <= size(source.type)` path, copying just the target's
  1-byte width via `Op.copy` instead of computing `operand != 0` at the
  operand's own full width.

- `compileCall`'s class-method call site treated any class-receiver call as
  virtual (`Op.classVirtualFunction` off the receiver's *runtime* class),
  with no exemption for a `super.f()` call site. A `super.f()` inside an
  override still runs with the most-derived object as `this`, so dispatching
  it through that object's own vtable looks the override right back up and
  the call recurses on itself forever (hung, not crashed) for any override
  whose body calls `super.f()`. Fixed by gating the virtual-dispatch branch
  on `call.e1.isDotVarExp.e1.isSuperExp is null`; a super call falls through
  to the same direct `Op.call` a non-class-receiver call uses, since
  `function_`/`index` are already resolved to the base implementation via
  DMD's `call.f`.

- When a change completes or reshapes an item from an implementation plan,
  update that plan in the same commit before handing the branch off. Remove
  the completed item, preserve the durable contract the implementation
  established, and name the next concrete item explicitly; otherwise the
  next agent can reasonably repeat work that git already contains.

- An interface extracted from a boxed backend is not backend-neutral merely
  because backend conversion is injected through virtual methods. Requiring a
  native-layout backend to implement a marshaller preserves the boxed
  backend's abstraction and invites conversion paths. Design the native-layout
  call boundary independently around typed addresses.

- `LINK.d` identifies D linkage, not the compiler ABI of a callable. DMD and
  LDC order explicit `extern(D)` arguments differently. Carry the defining
  compiler's ABI with every resolved D callable and use it to order the
  argument-address array; never hard-code either ordering globally.

- Never repair a backend representation violation at an FFI boundary. If a VM
  stores a D slice as `{ptr, length}` instead of native `{length, ptr}`, fix
  every VM reader and writer and delete the compensating swaps. A boundary
  conversion hides bad pointers nested inside structs or passed by reference
  and turns temporary migration code into permanent architecture.

- Do not derive an activation frame solely from source-level declarations.
  Run the required DMD semantic pass first, use DMD's variable visitors for
  body and expression declarations, and add DMD-owned function metadata that
  is not body-discoverable (notably `vresult`). Synthetic declarations have
  their lowered storage shape: for example, a struct `with` receiver is an
  owning `S* __withSym = &subject`, while a late-created `$` length variable
  may require scoped symbolic evaluator metadata if it did not exist when the
  frame layout was frozen.

- A semantic DMD type used to describe a native-call fixture must use the same
  alignment attributes as the compiled fixture type. Similar-looking `align`
  placements can describe different offsets and therefore different ABIs.

- When splitting execution from `displayEvalResult`, preserve its terminal
  `Throwable` boundary. D runtime assertion and bounds failures are `Error`s,
  not `Exception`s, and must still become backend diagnostics.

- An unset field of enum type defaults to that enum's *first* member, not to
  `0`, unless a member is explicitly given the value `0`. Conditionally
  assigning a flags field only in the `true` case (leaving it at `.init`
  otherwise) is wrong whenever the flag enum's first member isn't the zero
  value: `object.TypeInfo_Struct.StructFlags` declares `hasPointers = 0x1`
  first, so an unpopulated `m_flags` reads back as `hasPointers` regardless
  of the type's real shape. Assign an explicit value on every branch.

- A `ref`-returning `extern(C)` native call (no D body, e.g. the libc-mangled
  `core.stdc.errno.errno` accessor) must leave the callee's returned ADDRESS
  in its destination frame slot, not the dereferenced value. The bytecode
  core's convention for every `ref`-returning call, native or VM-compiled, is
  that the destination slot holds a pointer: an rvalue read dereferences it
  explicitly (`compileExpression`'s `CallExp` handling), an lvalue use wraps
  it directly (`resolvePlace`'s `pointerPlace`). A native-call bridge that
  pre-dereferences into a value slot happens to produce the right value for
  the rvalue case (the explicit deref never runs, since the operand isn't
  marked as a pointer) while silently corrupting any lvalue use of the same
  call, writing through whatever value the callee's storage happened to hold
  rather than its address. Diagnosed via SIGSEGV inside a completely
  unrelated druntime helper several calls downstream, not at the call site
  itself.

- `dynamicArrayDescriptor`'s place-backed path (an lvalue array expression)
  must rescale a wrapping cast's descriptor length the same way its
  no-place fallback (`compileDynamicArrayInto`) and `compileCastExpression`
  already do for `cast(T2[])x` where `T2`'s element size differs from `x`'s.
  `placeOrNull` unwraps a `CastExp` transparently and returns the INNER
  expression's own place, bypassing the cast entirely, so a `void[]` view of
  a `T[]` argument (the shape an implicit `T[]` -> `void[]` native-call
  argument conversion takes, e.g. `gc_shrinkArrayUsed(ptr[0 .. n], ...)`)
  silently keeps the source's element-count length instead of a byte length.
  The bug is invisible until something downstream (a real GC `void[]`-used
  bookkeeping call) trusts the wrong length.

- `rescaleReinterpretedSliceLength` must not gate its rescale on
  `ScalarType.void_`: that tag marks BOTH a genuine `void` array element
  (`void.sizeof == 1`, a real one-byte stride needing the same rescale as
  everything else) and an opaque struct/static-array/nested-array element (no
  fixed scalar width, handled separately). Deriving element width from
  `dynamicArrayElementType`'s `ScalarType` conflates the two; deriving it
  from `dynamicArrayElementSize` (which already special-cases `Tvoid`
  correctly) does not.

- `Type.vtinfo` populates lazily, the first time dmd's semantic pass
  processes an actual `typeid` naming that exact type; it is not eagerly
  populated for every type dmd's runtime library ships a real symbol for.
  A builtin element type reached only through a synthesised aggregate
  `TypeInfo`'s own field (never itself the direct operand of a source-level
  `typeid`) can have a null `vtinfo` even though its real host symbol
  exists. Forcing population by calling `dmd.typinf.genTypeInfo` directly
  from a lazily-running backend compiler (outside dmd's normal
  module-compilation walk) resolved the immediate symbol lookup but
  corrupted the host process's own GC heap, manifesting as a SIGSEGV far
  downstream in unrelated code (dmd Scope pooling is not safe to drive this
  way mid-compilation, or the freshly-synthesised `TypeInfoDeclaration` is
  not interchangeable with dmd's own runtime-simulated one) -- reverted
  rather than pursued further; composite `TypeInfo` for arrays, static
  arrays, and delegates is now synthesised recursively instead, so the
  remaining unsupported `typeid` categories are a class/interface reached
  only as a composite's field, associative arrays, function types,
  vectors, and tuples.

- `tryCompileNativeCall`'s (`compiler.d`) generic argument-compiling loop
  did not honour a native callee's `ref`/`out` parameter: its fallback
  branch always called `emitCallArgument(slot, false, argument)`, which
  copies the argument's VALUE into a fresh native-call staging slot and
  never wrote that slot's post-call bytes back to the caller's real
  variable -- any native call reached through the ordinary body-less
  (`fbody is null`) path with a `ref`/`out` scalar or dynamic-array
  parameter was affected, confirmed with `residentMulu`'s `ref bool
  overflow` and `_d_arrayappendcd`'s `ref byte[] x`. Fixed generically by
  recording each such argument's own `Place` and staging slot at the
  argument loop, then copying the slot's post-call bytes into that place
  once `emitNativeCall` returns (`NativeRefArgumentWriteback`); a `ref`/
  `out` struct or static-array parameter gets the same write-back through
  `storePlace`'s existing aggregate `Op.copy` branch, which already derives
  its width from `place.valueType` rather than from the stored operand, so
  widening the argument-loop gate to `struct_`/`staticArray` was enough --
  no new copy machinery was needed. Beware `bin/qb -l`: it starts
  the REPL after loading, it does not run the loaded file's `unittest`
  blocks, so a script driving it through `-l` alone proves nothing either
  way -- confirm through a real `bin/ut` fixture
  (`runBackendSourceFixtureTests`), as this entry's repro did. Also beware
  `core.checkedint.mulu`'s `ref bool overflow`: it is `overflow |= o`, an
  accumulate, not an assign -- pre-seeding it `true` and asserting it
  becomes `false` on a non-overflowing call is not a valid write-back
  probe; the flag must start `false`.

- Flipping a VM array representation from boxed-per-row descriptors to the
  real inline D layout (bytecode core's `Tsarray`-row fix, `int[N][]`
  storing rows `T[N].sizeof`-strided instead of behind a 16-byte
  `{length, ptr}` descriptor) is not done once construction and indexing
  compile and the target tests pass: a full `@Bytecode` sweep, not just the
  target tests, is what surfaces the other emit sites still keyed on the
  boxed assumption -- concretely `new T[N][](rows)` (`compileNewArrayInto`),
  slice-assignment broadcast-fill/range-copy (`storeDynamicSlice`), and
  module-level literal constant-folding (`moduleDynamicArrayLiteralInitializerBytes`)
  each had their own separate boxed-row special case. `storeDynamicSlice`'s
  turned out to be pure deletion once rows are flat: the same
  `emitSliceFill`/`emitSliceCopy` helpers scalars and structs already use
  handle arbitrary element width via their `N`-suffixed opcode variants
  (`Op.sliceFillN`/`Op.sliceCopyN`), so `emitRowBroadcastFill`/
  `emitRowRangeCopy`/`emitInlineRowRangeCopy` and `Op.rowRangeCopy` were
  dead weight, not a shape needing its own generic replacement. Also:
  `dynamicArrayElementSize`'s `elementIsArray` parameter (returning a
  hardcoded `sliceDescriptorSize` for a boxed row) was entirely redundant
  with its own `typeFacts(element).byteWidth` fallback -- a `Tarray`
  element's `byteWidth` already equals `sliceDescriptorSize` by
  definition, so the special case never needed to exist even before the
  `Tsarray` fix.

- A native leaf reached through a function pointer (`&f` where `f.fbody is
  null`, called via `Op.callIndirect`) builds its argument area as an
  ordinary VM parameter frame (`ParameterLayout`), not a direct native
  call's own uniform-stride staging area. `ParameterLayout` stores a
  `ref`/`out`/`auto ref` argument's slot as the referenced variable's
  ADDRESS, not its value -- unlike a direct native call's staging slot,
  which `tryCompileNativeCall` always fills with the argument's copied-in
  VALUE regardless of reference-ness. `native_call.d`'s
  `prepareNativeInvocation` read every indirect argument's address the
  same way as a direct one (the slot's own location), so a `ref`
  parameter's callee received the address of the frame slot holding the
  pointer, not the pointee -- one indirection short of the guest variable,
  silently leaving the caller's storage unwritten rather than crashing.
  Fixed by recording each indirect native target's `ParameterLayout
  .isReference` alongside its offsets (`NativeCall.argumentIsReference`,
  `program.d`) and following the slot's own pointer value for a marked
  argument instead of treating the slot as the storage.

- A struct-typed local's ternary initializer (`S s = cond ? a : b;`) had no
  compile route in bytecode core's `compileStructDeclaration`
  (`compiler.d`): the rvalue fallback only resolves a `CondExp` initializer
  through `structValueOffsetOrNull` -> `placeOrNull` -> `resolvePlace`,
  whose own `CondExp` arm declines unless `conditional.isLvalue` -- which a
  struct-typed ternary between two ordinary lvalues is not guaranteed to be,
  so it declines even for the simplest two-lvalue case. Dynamic arrays
  already have the right shape for this
  (`compileDynamicArrayInto`'s destination-directed `CondExp` arm: branch,
  then recurse into the same destination offset for each arm), structs
  never got the analogue. Fixed by adding the same destination-directed
  `CondExp` arm to `compileStructDeclaration`, plus a `compileStructValueInto`
  helper that block-copies one arm's value (an lvalue/call, a struct literal,
  or `S.init`) into the declared slot directly instead of going through
  `Place`. A fixture with a literal `true`/`false` condition does not
  exercise this: DMD's own constant folding replaces `true ? a : b` with `a`
  before bytecode core ever sees a `CondExp` node, so an exposing test needs
  a non-constant condition (a `bool` local, as the existing lvalue-ternary
  fixture already used).

- A helper for one load site does not cover another site loading the
  same kind of value; check every path that loads a pointer-typed value
  routes through it. `asPointerValue` (`compiler.d`) promoted `*p`/`p[i]`
  loads to `isPointer`, but a `ref T` parameter's own read never used it.

- Don't trust a removed branch's "untested, not required by the reported
  shape" comment when reusing the same helper from a new call site later.
  `compileStructValueInto` (`compiler.d`) had its `CondExp` arm dropped as
  untested; routing `compileStructLiteralInto`'s struct-typed field
  initializers through it (issue #510's field-initializer-constructor fix)
  made a ternary field initializer (`Outer(2, flag ? Inner(a) : Inner(b))`)
  reach that same helper and need the arm back. A helper's removed branch is
  scoped to the call sites that existed when it was removed, not to the
  helper itself; re-add it (rather than special-case the new call site) as
  soon as another caller needs the same expression shape.

- Re-trace every symptom in a multi-symptom bug independently, even when a
  diagnosis says they share one root cause. Issue #508's pointer-cast throw
  and struct-equality silent wrong answer did not: only the first was a
  ref-parameter metadata gap; the second was `compileIdentityExpression`'s
  unrelated hardcoded 8-byte width.

- dub's `dflags` silently drops a bare `-debug=name` (warns, does not add
  it); `debugVersions` in `dub.sdl` is the right knob, but reggae does not
  translate it into a dmd flag either. An unguarded `debug { }` block, gated
  only by the ambient `-debug` the `unittest` build type already passes, is
  the reliable way to add a temporary trace.

- A bug report's own root-cause hypothesis can be wrong even when carefully
  written by a prior diagnostic pass; bisect down to a hermetic, minimal
  repro before trusting the named mechanism. Issue #509 was filed as a
  cerealed `struct { string value; }` + whole-array slice-reassignment
  (`data[] = data2[]`) memory bug; bisecting the fixture statement by
  statement showed the slice reassignment was never involved at all -- the
  real defect was a nested immediately-invoked function literal
  (`() { return S(value); }()`) reading an enclosing function's `auto ref`
  parameter through a stale, wrong-function frame offset, exercised
  incidentally by `unit-threaded`'s `.should ==` machinery.

- An inlining/short-circuit optimization that bypasses one code path (here,
  `compiler.d`'s `immediateLambdaReturn`, which compiles an IIFE's single
  `return expr;` directly in the caller's context instead of a real nested
  call) must be transparent to every OTHER special-case a caller applies to
  the un-inlined shape, not just the one the optimization was written for.
  `placeOrNull`'s dedicated constructor-call receiver handling checked
  `expression.isCallExp`/`callFunction(call).isCtorDeclaration` directly, so
  it never saw through an inlined IIFE wrapping a constructor call and fell
  back to a receiver-unaware path. Narrowing the optimization itself (e.g.
  declining to inline whenever anything is captured) is the wrong fix -- it
  silently forces many more closures through unrelated, separately limited
  machinery (a multi-level nested-frame walk here) than the actual bug
  requires. The precise fix: make every caller that pattern-matches a
  specific expression shape unwrap the same inlining wrapper first.

- A total-divided-by-calls average is not attribution: 26 GB of benchmark
  garbage "per native call" turned out to be whole-array reallocation in
  the VM's own call loop, with the FFI path a bystander. Bracket each
  candidate phase with `GC.allocatedInCurrentThread` (O(1), collection-
  immune) and compare against a compiled-D ground-truth run before
  patching any site. An unchanged total is evidence against the hypothesis,
  not a reason to patch more similar sites. Never sample `GC.stats.usedSize`
  in a hot path -- it walks GC pools and gets slower as the heap grows. Issue
  #525's equivalent interpreter probe attributed 5.0 of 7.4 GB to returned
  activations discarding and rebuilding their expression-keyed temporary
  blocks; reusing eligible frames removed that churn.

- When one AST discriminator covers result types with different execution
  paths, retire only the type covered by the new path. A destination arm for
  void logical expressions does not replace the boxed fallback for a non-void
  logical expression when a destination-type mismatch makes scalar construction
  decline.

- A `SymOffExp` that names variable storage does not always have a pointer
  type. DMD can give it the final cast-result type while it still denotes the
  declaration's address. When this happens, derive the physical pointer place
  from the declaration type before adapting it to the result destination.

- A function declaration used as a value can retain `Tfunction` as the AST
  expression type while its destination is a function-pointer place. Do not
  allocate an expression-type temporary for this conversion: function types
  have no value-storage size. Send the symbolic callable identity directly to
  the pointer destination.

- A projection-place eligibility check and its lvalue-tree collector must
  accept the same roots. Adding struct `this`/`super` to only the first check
  still rejects `this.arrayField[index]` when the collector reaches the root;
  compound assignment then loses the live place that it must select once.

- For a mechanical edit of repeated statements such as `return value`, anchor
  every patch hunk in the containing function. A text-only replacement can
  silently change an unrelated execution path that happens to contain the
  same statement.
