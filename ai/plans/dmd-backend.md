# Goal

Make this command produce real cerealed benchmark rows with the DMD codegen
backend:

```sh
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-codegen --dub cerealed
```

The end state is:

- No cerealed fixture is skipped by the benchmark harness for DMD-codegen link,
  load, or DMD codegen failures.
- The command prints timing rows for cerealed fixtures.
- Quickbite's in-process DMD codegen driver behaves like normal DMD for the
  semantic/codegen cases needed by the benchmark, including repeated benchmark
  iterations over parsed modules.
- The fix does not grow fake `pragma(mangle)` shims and does not hand-roll a
  broad template/codegen dependency closure in Quickbite.

This plan is a lab log and handoff document, not a pre-committed solution. Keep
it focused on the desired end state, constraints, evidence, what was tried, and
why each result was insufficient.

This file lives at `ai/plans/dmd-backend.md`. Keep it updated with what was
tried, what happened, and why the result was insufficient.

## Current Handoff Snapshot

Coordination note:

- `master` has been merged into this branch.
- The merged default suite is green with DMD-codegen tests excluded from the
  default `unittest` and `unittest-cov` configs.
- DMD-codegen remains enabled for the benchmark config; benchmark work is still
  follow-up.

The latest checked state is green for the default test suite, but the
DMD-codegen implementation still contains diagnostic/WIP edits. Do not treat the
current implementation as a final fix.

Latest verification:

```sh
dub test
```

Result:

- 516 tests run.
- 0 failed.

Important post-merge test-suite note:

- DMD-codegen is always available in the build. Do not hide it behind
  `version (QuickbiteDmdCodegen)` unless the backend prevents the project from
  compiling or linking.
- Default test and benchmark selection is runtime policy. Broad tests iterate
  over `matureExecutorBackends`; known-broken DMD-codegen focused tests run only
  when `QUICKBITE_EXPERIMENTAL_BACKEND_TESTS` is set.
- Benchmarks now treat `treeWalking` and `dmd-codegen` as experimental
  backends. The default benchmark list is `ir`, `treeWalkingOld`, and
  `dmd-ctfe`; experimental backends remain opt-in via `--backend=treeWalking`
  or `--backend=dmd-codegen`.

What works now:

- The goal command prints a timing row for `bugs`.
- The repeated-codegen failure for `bugs` was moved past the
  `std.typecons.Tuple!(TypeInfo, ubyte[32]*).Tuple.this(...)` blocker by
  resetting direct `StaticIfDeclaration` children.
- A temporary root-member experiment makes `cerealiser_impl` move past the
  first missing `CerealiserImpl.opOpAssign` bodies.
- Extending that experiment to DMD's always-codegen `_d_arrayliteralTX`
  template moves the first `cerealiser_impl` failure again.

What still fails:

- Later cerealed fixtures still skip.
- After the latest temporary experiments, the first explicit
  `cerealiser_impl` after `bugs` fails on stale prior-fixture TypeInfo
  references:

  ```text
  tests.bugs.Pair.__xtoHash(ref const(tests.bugs.Pair))
  tests.bugs.Pair.__xopEquals(ref const(tests.bugs.Pair)) const
  ```

Working diagnosis:

- Template reachability is part of the problem. DMD only object-generates
  template instances reached from module `members`; changing
  `TemplateInstance.minst` alone is insufficient.
- The temporary root-member append proves that `TemplateInstance.memberOf` /
  root `members` placement matters, because it removes the first missing
  cerealed template bodies.
- The same experiment is too broad: it can pull stale template/typeinfo state
  from earlier fixtures into later generated objects.

Immediate next investigation:

- Keep the root-member append signal, but make eligibility sharper. Inspect why
  stale `tests.bugs.Pair` TypeInfo is reachable when generating
  `cerealiser_impl` and whether it comes from global support-module collection,
  cached `Type.vtinfo`, appended root members from earlier runs, or another
  DMD global queue.
- Before any PR-ready verification, restore diagnostics-only edits:
  `compileAndRun` should delete `/tmp/quickbite_dmd_*`, and
  `benchmarks/main.d` should print `firstLine(e.msg)` again.

## Constraints

- Do not solve this by growing fake `pragma(mangle)` shims.
- Do not hand-roll template/codegen dependency closure in Quickbite.
- Call into DMD and make Quickbite's in-process driver behave like normal DMD
  in every semantically relevant way.
- Avoid magic booleans, magic strings, and magic arrays at the
  `generateCodeAndWrite` call site.
- Use subagents whenever possible, especially for research.
- Do not overfit to the associative-array reproducer if the cerealed benchmark
  still fails.

## Current Failure

The goal command now produces a `bugs` timing row, but later cerealed fixtures
still skip with link failures. With the latest temporary root-member
experiments, the first explicit `cerealiser_impl` fixture after `bugs` moved
from missing cerealed `opOpAssign` bodies to stale `tests.bugs.Pair` TypeInfo
references.

The current failure is therefore cross-fixture DMD/global state contamination
after earlier codegen, not the already-fixed repeated-codegen path for `bugs`.

## Current Working Diagnosis

Quickbite is still not isolating or resetting enough of DMD's process-global
template/typeinfo/backend state between generated fixtures.

The shared-library path can introduce separate link/load failures, but the
latest evidence still points at incomplete or over-broad in-process DMD codegen
state. The same complete object bodies would be required by a future in-memory
code emitter, so replacing the shared-library bridge is not the immediate fix
unless new evidence shows the bridge is the reason complete code cannot be
emitted.

## Branch Context

The current branch renamed the backend from `dmd-backend` to `dmd-codegen`.
The stale command was:

```sh
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-backend --dub cerealed
```

Use:

```sh
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-codegen --dub cerealed
```

## Approved Test

The approved DMD-codegen-only regression in `tests/ut/compiler_api.d` is:

```d
@("runTests.dmdCodegenRunsAssociativeArrayLiteral")
```

It was added for this source shape:

```d
unittest {
    auto map = [5: 105];
}
```

The original failure was a load/link failure with unresolved
`core.internal.newaa` template support, including `Impl.__xtoHash`, `_d_aaIn`,
`_aaGetHash`, `_aaEqual`, and related associative-array support.

## Current Dirty State And Why

Current uncommitted edits:

- `tests/ut/compiler_api.d`
  - Adds `runTests.dmdCodegenRunsAssociativeArrayLiteral`.
  - Why: approved regression for DMD-codegen emitting associative-array
    template support instead of leaving unresolved `core.internal.newaa`
    symbols.
- `source/quickbite/frontend/compiler.d`
  - Sets `global.params.allInst = true` during compiler init.
  - Why: DMD's template codegen placement logic must see this before semantic
    analysis, matching normal DMD's linkability-focused mode for template
    instantiations.
- `source/quickbite/backends/dmd_codegen.d`
  - Adds `codegenSourceImportPaths`, which excludes import paths that resolve
    to a static library from imported-source module collection.
  - Why: DUB package dependencies can be linked from archives; compiling their
    source modules as extra roots caused DMD-shaped ownership problems and
    earlier crashes.
  - Adds `generateObjectFiles` to name `generateCodeAndWrite` arguments.
  - Why: keeps the intended DMD call shape readable, although the current WIP
    is still using the per-module generation loop.
  - Preserves/restores `TemplateInstance.tnext` across codegen passes.
  - Why: DMD's `needsCodegen` destructively clears this sibling chain; normal
    DMD only generates an AST once, while the benchmark repeatedly codegens the
    same parsed module.
  - Clears `FuncLiteralDeclaration.deferToObj` and
    `UnitTestDeclaration.deferredNested`.
  - Why: DMD queues deferred nested/literal functions during object generation;
    stale queues/flags can suppress second-pass emitted bodies.
  - Clears `FuncDeclaration.skipCodegen`.
  - Why: DMD checks this flag before emitting a function body, and stale `true`
    would leave references without definitions on repeated codegen.
  - Resets direct `StorageClassDeclaration` and `VisibilityDeclaration`
    children.
  - Why: DMD object generation visits declarations under these attribute
    wrappers; missing this reset caused second-pass AA support methods under
    `private:`/attribute sections to remain undefined.
  - Wraps static archive link files in `-L=--start-group` and
    `-L=--end-group`.
  - Why: archive interdependencies were observed during cerealed linking. This
    did not solve the missing template bodies, but remains part of the current
    dirty state.

## Research Notes

Normal DMD emits associative-array support into the root object. This command
was used to compare behavior:

```sh
printf 'module qb_aa_min;\nunittest { auto map = [5: 105]; assert(map[5] == 105); }\n' > /tmp/qb_aa_min.d
mkdir -p /tmp/qb-aa-normal
/usr/bin/dmd -c -unittest -fPIC -od=/tmp/qb-aa-normal /tmp/qb_aa_min.d
nm -C /tmp/qb-aa-normal/qb_aa_min.o | rg 'core\.internal\.newaa|_d_aa|Impl|xtoHash'
```

The object contains weak definitions for `core.internal.newaa.Impl!(int, int)`
methods, `_d_assocarrayliteralTX`, `_d_aaIn`, `_aaGetHash`, and related
helpers.

Normal DMD also emits the missing cerealed `bugs.d` bodies into the test object.
This command was run:

```sh
/usr/bin/dmd -c -unittest -fPIC -of=/tmp/qb-bugs-normal/bugs.o \
  -I/home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/src/ \
  -I/home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/ \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/bugs.d
```

The real command included all DUB import paths. `nm -C` on the resulting object
showed weak definitions for examples that Quickbite leaves unresolved:

```text
W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.this(ulong)
W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.findSlotInsert(ulong) const
W core.internal.newaa.Bucket!(tests.bugs.Pair, int).Bucket.empty() const
W unit_threaded.assertions.formatRange!(int[]).formatRange(...).__lambda_L536_C25()
W std.format.write.formatValue!(..., tests.bugs.Pair, char).__dgliteral_L1261_C16()
```

The same object only left ordinary druntime helpers such as
`core.internal.newaa.mix`, `talign`, and `nextpow2` undefined.

DMD's public glue entry point is:

```d
generateCodeAndWrite(
    modules[],
    libmodules[],
    params.libname,
    params.objdir,
    driverParams.lib,
    params.obj,
    driverParams.oneobj,
    params.multiobj,
    params.v.verbose,
);
```

DMD's non-`oneobj` path calls `obj_start`, `genObjFile`, `obj_end`, then
`obj_write_deferred`. `obj_start` resets `bzeroSymbol`, so the old manual
`bzeroSymbol = null` before each per-module call was suspicious.

DMD's `TemplateInstance.needsCodegen` and `appendToModuleMember` logic are in
`dmd/templatesem.d`. `global.params.allInst` must be set before semantic
analysis to influence where template instances are attached.

## Attempts And Results

### Reproduce Current WIP Goal Failure

Rebuilt the benchmark binary and reran:

```sh
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-codegen --dub cerealed
```

Result:

- `bugs` still prints a timing row.
- Every later cerealed fixture still skips with link errors.
- The first skip is still `cerealiser_impl`.

This confirms the current worktree matches the plan's current failure shape.

### Preserve Objects And Print Full Link Diagnostics Again

Temporarily commented out `scope(exit) rmdirRecurse(tmpDir)` in
`compileAndRun` and stopped truncating benchmark skip diagnostics in
`benchmarks/main.d`.

Ran:

```sh
./bench --warmup=1 --iterations=1 --backend=dmd-codegen --dub cerealed \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/bugs.d \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/cerealiser_impl.d
```

Result:

- The explicit and DUB-appended `bugs` fixtures both printed timing rows.
- The explicit `cerealiser_impl` fixture failed after `bugs`.
- The first failing preserved directory was `/tmp/quickbite_dmd_2`.
- Representative unresolved references:

  ```text
  cerealed.cerealiser.CerealiserImpl!(cerealed.range.DynamicArrayRange).CerealiserImpl.opOpAssign!("~", tests.cerealiser_impl.WhateverStruct).opOpAssign(tests.cerealiser_impl.WhateverStruct)
  cerealed.cerealiser.CerealiserImpl!(cerealed.range.DynamicArrayRange).CerealiserImpl.opOpAssign!("~", int).opOpAssign(int)
  cerealed.cerealiser.CerealiserImpl!(cerealed.range.ScopeBufferRange).CerealiserImpl.opOpAssign!("~", tests.cerealiser_impl.WhateverStruct).opOpAssign(tests.cerealiser_impl.WhateverStruct)
  core.internal.array.construction._d_arrayliteralTX!(ubyte)._d_arrayliteralTX(ulong)
  ```

- Later failing fixtures also contained stale references to previous fixture
  types such as `tests.bugs.Pair.__xtoHash`.

Conclusion:

- The current blocker is not just missing cerealed template bodies for the
  current fixture.
- DMD-codegen is also emitting or referencing process-global backend/runtime
  state that still mentions earlier fixture-local types.

### Stop Appending All Global Runtime Support Modules

Change being tried:

- Keep `collectBackendRuntimeSupportImports`, which follows runtime support
  modules imported by the current source module set.
- Temporarily disable `collectGlobalBackendRuntimeSupportModules`, which
  appends every `core.internal.*` support module seen in `Module.amodules`.

Reason for trying:

- Full link diagnostics showed later fixtures referencing `tests.bugs.*` from
  support-module objects even when `tests.bugs` is not part of the current
  generated module set.
- `collectGlobalBackendRuntimeSupportModules` is a direct path for stale global
  druntime modules to enter every later codegen set after they have accumulated
  fixture-local template/typeinfo state.

Result:

- Rebuilt the benchmark and reran the goal shape with a timeout.
- `bugs` still printed a row.
- Later fixtures still skipped.
- The stale-fixture symbol surface was reduced in some early diagnostics, but
  required support bodies disappeared too. New unresolved examples included:

  ```text
  core.internal.array.construction._d_arrayliteralTX!(ubyte)._d_arrayliteralTX(ulong)
  core.internal.newaa._d_aaLen!(int, const(quickbite_dmd_codegen_support_3.NestedNested))._d_aaLen(...)
  ```

- This is insufficient and was reverted. The global support modules are still
  needed for current support bodies; simply dropping them only trades stale
  references for missing runtime support.

### Allow Template Rooting When Instance Mentions Current Module

Temporarily changed `canRootTemplateInstance` so a template instance that
mentions a current codegen module can be rooted even if it also mentions an
archive-backed non-current module.

Reason for trying:

- The first `cerealiser_impl` unresolved symbol was:

  ```text
  cerealed.cerealiser.CerealiserImpl!(cerealed.range.DynamicArrayRange).CerealiserImpl.opOpAssign!("~", tests.cerealiser_impl.WhateverStruct).opOpAssign(tests.cerealiser_impl.WhateverStruct)
  ```

- That instance mentions both an archive-backed cerealed type and the current
  test type. The existing `referencesNonCurrentSourceModule` guard rejects it
  as soon as it sees `cerealed.range`, which may prevent DMD from emitting a
  test-local instantiation that cannot exist in the prebuilt cerealed archive.

Result:

- Rebuilt the benchmark and reran the goal shape.
- The first `cerealiser_impl` failure did not move; it still missed the same
  `CerealiserImpl!(cerealed.range.DynamicArrayRange).opOpAssign` bodies.
- This means either the relevant `TemplateInstance` is not reached by the
  current reset/rooting traversal, `TemplateInstance.toChars` is not the right
  evidence for detecting current-module participation, or another DMD codegen
  flag/state suppresses emission before `needsCodegen` observes the changed
  ownership.
- The experiment was reverted.

### Full Suite Verification After Reverting Experiments

Restored the diagnostics-only edits:

- `compileAndRun` again removes `/tmp/quickbite_dmd_*` with
  `scope(exit) rmdirRecurse(tmpDir)`.
- `benchmarks/main.d` again prints only `firstLine(e.msg)` for skipped
  fixtures.

Also reverted both exploratory implementation changes from this session:

- The temporary removal of `collectGlobalBackendRuntimeSupportModules`.
- The temporary `referencesCurrentCodegenModule` shortcut in
  `canRootTemplateInstance`.

Then ran:

```sh
dub test
```

Result:

- The full suite failed with the same process-order-sensitive DMD-codegen
  failures previously documented.
- Four tests failed:

  ```text
  ut.compiler_api.runTests.dmdCodegenRunsAssociativeArrayLiteral
  ut.compiler_api.runTests.dmdCodegenRunsFailingPackageModuleUnittest
  ut.compiler_api.runTests.dmdCodegenRunsImportedSourceModules
  ut.minicereal.dmd-codegen.minicerealFileCanRunTwice
  ```

- Representative failures:

  ```text
  dlopen failed: /tmp/quickbite_dmd_3/module.so: undefined symbol:
  _D4core8internal5newaa__T4ImplTiTiZQk9__xtoHashFNbNeKxSQCbQBzQBt__TQBqTiTiZQByZm

  dlopen failed: /tmp/quickbite_dmd_4/module.so: undefined symbol:
  _D4core8internal5newaa__T7_d_aaInHTHiiTiTiTiZQuFNaNbNiNfNgHiiMKiZPNgi
  ```

Conclusion:

- No implementation experiment from this session was kept.
- The useful new evidence is that global support-module collection is both
  necessary and a likely contamination path: removing it reduces some stale
  references but loses required druntime bodies.
- Another useful negative result is that simply allowing current-module names
  through the template-rooting guard does not reach or change the first
  `cerealiser_impl` missing-template-body failure.
- The next investigation should focus on how DMD reaches and marks the
  specific `CerealiserImpl!(...).opOpAssign` template/function declarations,
  and why Quickbite's reset traversal does not make those declarations emit
  after earlier fixtures have run.

### One DMD-Style Object Generation Call

Changed `generateObjs` from one `generateCodeAndWrite` call per module with
`oneobj=true` to a single `generateCodeAndWrite(modules, ..., oneobj=false)`.

Result:

- This matched DMD's normal public glue shape more closely.
- By itself it did not fix unresolved `core.internal.newaa` symbols.

### Enable `allInst` During Compiler Init

Set `global.params.allInst = true` in `Compiler` initialization.

Result:

- This was needed before semantic analysis.
- By itself it did not fix unresolved `core.internal.newaa` symbols.

### Remove Runtime-Support Module Collection

Temporarily removed `collectBackendRuntimeSupportModules(modules, seen)`.

Result:

- The full unittest run still failed.
- Existing DMD-codegen tests regressed with unresolved support-module symbols.
- The change was reverted; support-module collection is currently restored.

### Manually Append Rooted Templates To Root Members

Experimented with forcing selected template instances into the current root
module's `members` list after setting `minst = root`.

Result:

- The focused associative-array regression passed.
- The cerealed benchmark segfaulted during DMD backend codegen.
- GDB showed:

  ```text
  Type::isTypeEnum()
  Type::toBasetype()
  dmd.glue.e2ir.toElem(...).visitCall(CallExp)
  dmd.glue.s2ir.Statement_toIR(...)
  dmd.glue.FuncDeclaration_toObjFile(...)
  dmd.glue.toobj.toObjFile(... TemplateMixin ...)
  dmd.glue.genObjFile(Module, ...)
  dmd.glue.generateCodeAndWrite(...)
  quickbite.backends.dmd_codegen.generateObjectFiles(...)
  ```

- The experiment was removed because it made DMD generate through an invalid
  template/mixin context for cerealed.

### Restore Support Modules And Remove Manual Member Insertion

Restored `collectBackendRuntimeSupportModules(modules, seen)` and removed the
manual root-member insertion experiment.

Result:

- These focused tests passed:

  ```sh
  dub test --config=unittest -- \
    ut.compiler_api.runTests.dmdCodegenRunsAssociativeArrayLiteral

  dub test --config=unittest -- \
    ut.compiler_api.runTestSummary.dmdCodegenCountsPassingSourceModule \
    ut.compiler_api.runTests.dmdCodegenRunsImportedSourceModules \
    ut.minicereal.dmd-codegen.minicerealFileCanRunTwice
  ```

- The cerealed benchmark still failed.
- An isolated benchmark run no longer segfaulted, but the harness skipped most
  cerealed fixtures with link errors.

### Exclude Archive-Backed Import Paths From Source Collection

Added `codegenSourceImportPaths`. `generateObjs` now passes filtered import
paths to `collectSourceModules`; an import path is excluded if
`linkFileForImportPath` resolves a static archive for it.

Verification command:

```sh
dub build -c benchmark -b benchmark-opt
./bench --warmup=0 --iterations=1 --backend=dmd-codegen \
  --dub cerealed \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/bugs.d
```

Result:

- The command did not segfault.
- The DUB-discovered cerealed fixtures were still skipped with link errors.
- The explicit duplicate `bugs.d` fixture produced one timing row:

  ```text
  bugs dmd-codegen 1579.884 ms 1579.884 ms 0.000 ms
  ```

- This is insufficient because the real goal command must run the cerealed
  fixtures instead of skipping them.

### Run `bugs.d` Without `--dub` Fixture Expansion

Ran only the first cerealed fixture with the DUB import paths passed manually:

```sh
./bench --warmup=0 --iterations=1 --backend=dmd-codegen \
  --import-path=/home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/src/ \
  --import-path=/home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/ \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/bugs.d
```

The real command included all DUB import paths; the shortened command above
shows the important shape without listing every unit-threaded subpackage path.

Result:

- The fixture was skipped with a link error:

  ```text
  undefined reference to `ModuleInfo for unit_threaded.from'
  ```

- The undefined reference came from
  `unit-threaded/subpackages/runner/libunit-threaded_runner.a(io.o)`.
- This shows at least one remaining failure is static archive interdependency
  during the shared-library link step.

### Group Static Archives In The Link Step

Changed `link` so non-empty `linkFiles` are wrapped with:

```text
-L=--start-group
...
-L=--end-group
```

This only changes the final shared-library link command. It does not change
DMD parsing, semantic analysis, module collection, or object generation.

First tried the non-equals form (`-L--start-group` / `-L--end-group`).
Running the isolated `bugs.d` command still reported:

```text
undefined reference to `ModuleInfo for unit_threaded.from'
```

DMD help documents `-L=<linkerflag>`, matching the existing `-L=-z` and
`-L=defs` flags in this file, so the group flags were changed to the equals
form.

Result after rebuilding and rerunning the reduced `bugs.d` command:

- The link still failed.
- Temporarily changed `benchmarks/main.d:firstLine` to print full diagnostics,
  then reverted that diagnostics edit.
- Full diagnostics showed the remaining failure is not just archive ordering.
  It is missing emitted template bodies referenced from generated objects.
- Examples:

  ```text
  undefined reference to `core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.this(ulong)'
  undefined reference to `core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.findSlotInsert(ulong) const'
  undefined reference to `core.internal.newaa.Bucket!(tests.bugs.Pair, int).Bucket.empty() const'
  undefined reference to `unit_threaded.assertions.formatRange!(int[]).__lambda_L536_C25()'
  undefined reference to `std.format.write.formatValue!(..., tests.bugs.Pair, char).__dgliteral_L1261_C16()'
  undefined reference to `core.internal.lifetime.emplaceRef!(int, int, int).__lambda_L54_C20()'
  ```

- This is insufficient because the linker still sees references to DMD/Phobos
  template bodies that were not emitted into the generated object set.

### Set Imported Modules' `importedFrom` To The Root

Changed `semantic3Dependencies` so only `modules[0]` is marked as its own root.
Other modules in the generated set get `importedFrom = modules[0]` before
`importAll`/semantic passes.

Reason for trying:

- Quickbite previously set `module_.importedFrom = module_` for every module in
  the generated set.
- Normal DMD marks command-line roots as roots, while imported modules point at
  the importing root.
- DMD's template placement logic consults `importedFrom`; marking runtime or
  imported modules as their own roots can attach generated template bodies to
  modules differently from normal DMD.

First build failed because `const root = modules[0]` could not be assigned to
DMD's mutable `Module.importedFrom`; changed it to `auto root` with a comment.

Result:

- The focused DMD-codegen tests regressed.
- Failures were unresolved support-module symbols, for example:

  ```text
  undefined symbol: _D31quickbite_dmd_codegen_support_016NestedSomeStruct9__xtoHashFNbNeKxSQCrQBnZm
  ```

- The experiment was reverted; `semantic3Dependencies` again sets
  `module_.importedFrom = module_` for modules being generated.

### Stop Rewriting Template `minst` During Reset

Temporarily removed the call to `makeRootTemplateInstance` from `resetObjState`.

Reason for trying:

- `global.params.allInst` is now set before semantic analysis.
- The remaining link failures are missing template bodies.
- Quickbite's reset pass was still mutating DMD template ownership after
  semantic analysis by assigning `minst`.
- This checks whether DMD's own template ownership is now enough, and whether
  Quickbite's mutation is causing mismatched references/definitions.

Result:

- Focused tests still passed:

  ```sh
  dub test --config=unittest -- \
    ut.compiler_api.runTests.dmdCodegenRunsAssociativeArrayLiteral \
    ut.compiler_api.runTests.dmdCodegenRunsImportedSourceModules \
    ut.minicereal.dmd-codegen.minicerealFileCanRunTwice
  ```

- The real cerealed benchmark still skipped every fixture with unresolved
  template-body references.
- This is insufficient; removing the `minst` rewrite did not make DMD emit the
  missing bodies for cerealed.

### Restore Per-Module Codegen Loop Temporarily

Temporarily restored the old per-module `generateCodeAndWrite([currentModule],
..., oneobj=true)` loop with `bzeroSymbol = null`, while keeping `allInst`
enabled before semantic analysis and keeping the import-path filter.

Reason for trying:

- The full cerealed diagnostics still show missing template bodies.
- A subagent found the earlier SIGSEGV after the switch to one all-module
  `generateCodeAndWrite` call.
- This checks whether the one-call object generation shape is necessary for the
  current unresolved-template-body failure.

Result:

- Focused tests still passed.
- The real cerealed benchmark still skipped every fixture with unresolved
  template-body references.
- This is insufficient; the one-call object generation shape was not the sole
  cause of the current missing-template-body failures.

### Keep Temp Dirs To Compare Warmup And Timed Objects

Temporarily commented out `scope(exit) rmdirRecurse(tmpDir)` in `compileAndRun`
and rebuilt the benchmark. Then ran:

```sh
./bench --warmup=0 --iterations=1 --backend=dmd-codegen --dub cerealed \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/bugs.d
```

The explicit `bugs.d` fixture runs before the `--dub` fixture list because the
benchmark appends DUB fixtures after command-line fixtures. Results:

- `/tmp/quickbite_dmd_0` has `module.so`; the first codegen/load of `bugs.d`
  succeeded.
- `/tmp/quickbite_dmd_1` is the same parsed `bugs.d` module generated again;
  it failed to link.
- `nm -C /tmp/quickbite_dmd_0/module_0.o` contains weak definitions for the
  `core.internal.newaa.Impl!(tests.bugs.Pair, int)` methods and buckets.
- `nm -C /tmp/quickbite_dmd_1/module_0.o` has some weak definitions, but leaves
  methods such as `Impl.this`, `findSlotInsert`, `dim`, `grow`, `mask`,
  `length`, and `Bucket.empty/filled/deleted` undefined.

Conclusion:

- The current failure is repeated codegen of the same parsed module.
- In the real goal command with `--warmup=1`, the warmup run likely succeeds,
  then the first timed iteration reuses the same parsed module and fails to
  re-emit all template bodies.
- This is why the benchmark prints skipped fixtures instead of timing rows.

### Reset Deferred Function-Literal Codegen State

DMD queues function literals for deferred object emission using
`FuncLiteralDeclaration.deferToObj`. Quickbite reset `semanticRun` and backend
symbols, but did not reset this flag. DMD also stores nested functions to emit
after a unittest in `UnitTestDeclaration.deferredNested`.

Changed `resetObjState` for functions to:

```d
if (auto literal = function_.isFuncLiteralDeclaration)
    literal.deferToObj = false;
if (auto unitTest = function_.isUnitTestDeclaration)
    unitTest.deferredNested.setDim(0);
```

Reason for trying:

- The second generated `bugs.d` object was missing deferred lambda definitions
  that normal DMD and the first generated object both emitted.

Result:

- Focused tests still passed.
- The real cerealed benchmark still skipped every fixture.
- This was insufficient on its own.

### Restore Narrow Template Rooting Plus Deferred Reset

Restored the existing `makeRootTemplateInstance` call from `resetObjState`,
without restoring the earlier failed experiment that pushed template instances
into root `members`.

Reason for trying:

- Temp-dir comparison showed first codegen of `bugs.d` emitted the needed weak
  template bodies, while the repeated codegen skipped some of them.
- DMD's `TemplateInstance.needsCodegen` still depends on root ownership.
- The deferred function-literal reset fixes one repeated-codegen state gap, but
  template ownership still needs to be root-like before `needsCodegen` runs.

Also reverted the temporary diagnostics edit that kept `/tmp/quickbite_dmd_*`
directories by commenting out `scope(exit) rmdirRecurse(tmpDir)`.

Result:

- Focused tests still passed.
- The real cerealed benchmark still skipped every fixture.
- This is insufficient.

### Run Cerealed With One Iteration And No Warmup

Ran:

```sh
./bench --warmup=0 --iterations=1 --backend=dmd-codegen --dub cerealed
```

Result:

- `bugs` produced a timing row.
- Every later cerealed fixture was still skipped with link errors.

This separates two failure surfaces:

- The normal goal command (`--warmup=1 --iterations=2`) fails even for `bugs`
  because the same parsed fixture is generated more than once.
- With only one generation per fixture, `bugs` succeeds, but later fixtures
  still fail after DMD global template/backend state has already been used by
  earlier fixtures.

### Trace Benchmark Reuse Path

Inspected `benchmarks/main.d` and `benchmarks/harness.d`.

Result:

- Each fixture is parsed once in `benchmarks/main.d`, then the benchmark passes
  the same `Module` handle to `executor.runParsedTests(module_)` for every
  warmup and timed iteration.
- `benchmarks/harness.d` calls the supplied delegate once per warmup iteration
  and once per timed iteration, so the DMD codegen backend receives the same
  parsed module three times for the goal command's `--warmup=1 --iterations=2`.
- This matches the temp-directory comparison: the first generated `bugs.d`
  object can contain the needed weak template bodies, while a later generation
  of the same parsed module can leave them unresolved.
- This is insufficient because the benchmark must produce rows with the goal
  command, not only when each fixture is generated once.

Re-ran the goal command against the current WIP:

```sh
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-codegen --dub cerealed
```

Result:

- The command completed but skipped every cerealed fixture.
- `bugs` failed in `/tmp/quickbite_dmd_1/module_0.o`, which matches the
  warmup consuming `/tmp/quickbite_dmd_0` and the first timed iteration failing
  on the second codegen of the same parsed module.
- The output printed the benchmark headers but no timing rows.

### Reparse Fixture Inside DMD-Codegen Benchmark Iteration

Temporarily added an uncached parse API and changed `benchmarks/main.d` so
`dmd-codegen` reparsed the fixture inside each measured delegate invocation.

Reason for trying:

- DMD's `TemplateInstance.needsCodegen` destructively clears the `tnext`
  sibling chain.
- Reusing the same parsed module for warmup and timed iterations means later
  codegen passes have less template-placement evidence than the first pass.
- This experiment checked whether fresh parsed root modules were enough.

Result:

- The goal command still skipped every fixture.
- The failure moved earlier to:

  ```text
  DMD reported an error without a diagnostic message.
  ```

- This indicates uncached reparsing same-named source modules in the same DMD
  process trips DMD's global module/semantic state before codegen.
- The experiment was reverted. It is insufficient because the benchmark still
  produces no timing rows and it no longer preserves the post-parse benchmark
  shape.

### Reset Through `AttribDeclaration.include`

DMD's object visitor descends through `AttribDeclaration.include(null)` before
emitting symbols. Quickbite's reset traversal did not, so declarations under
storage-class, conditional, pragma, user-attribute, mixin, and related
attribute wrappers could keep stale `PASS.obj` / backend state.

Changed `resetObjState(Dsymbol)` to call:

```d
if (symbol.isAttribDeclaration) {
    import dmd.dsymbolsem: include;

    resetObjState(symbol.include(null), root, seen, modules);
}
```

before descending through `ScopeDsymbol.members`.

First attempt used `attribute.include(null)` directly and failed to compile
because `include` is exposed as a `dmd.dsymbolsem` free function in this DMD
library surface. Updated the code to import `dmd.dsymbolsem: include`.

Result:

- Focused DMD-codegen tests regressed.
- Failures included `DMD codegen failed without a diagnostic message` and DMD
  backend assertions in `vendor/dmd-backend/dmd/backend/elfobj.d`.
- This reset was too broad and was reverted.

### Preserve Template Sibling Chains Across Codegen Passes

DMD's `TemplateInstance.needsCodegen` starts by saving `ti.tnext` locally and
then clearing `ti.tnext = null`. The DMD source comment says `tnext` is only
needed for the first invocation. In normal DMD that is fine because an AST is
generated once. Quickbite's benchmark reuses the same parsed module for warmup
and timed iterations.

Reason for trying:

- With `global.params.allInst`, `needsCodegen` uses the sibling chain to find a
  root-module instantiation and decide whether weak template bodies should be
  emitted.
- The first codegen pass over `bugs.d` can emit the needed weak template
  bodies; the second pass over the same module loses some of them.
- Preserving and restoring the sibling chain lets DMD make the same
  linkability-focused decision on repeated codegen passes without Quickbite
  hand-rolling a template dependency closure.

Change being tried:

- Store each non-null `TemplateInstance.tnext` before codegen.
- If a later reset sees the same template instance with `tnext == null`, restore
  the stored chain before DMD calls `needsCodegen` again.

Result:

- Focused tests still passed:

  ```sh
  dub test --config=unittest -- \
    ut.compiler_api.runTests.dmdCodegenRunsAssociativeArrayLiteral \
    ut.compiler_api.runTests.dmdCodegenRunsImportedSourceModules \
    ut.minicereal.dmd-codegen.minicerealFileCanRunTwice
  ```

- The goal command still skipped every cerealed fixture.
- `bugs` still failed in `/tmp/quickbite_dmd_1/module_0.o`.
- This was insufficient; preserving `tnext` alone did not restore the missing
  weak template bodies.

### Reset `FuncDeclaration.skipCodegen`

DMD checks `fd.skipCodegen` before emitting a function body, and `toSymbol()`
can set it during object generation. Quickbite reset `semanticRun` back from
`PASS.obj`, but did not reset `skipCodegen`.

Reason for trying:

- The second `bugs.d` object references template methods that the first object
  emitted.
- If those methods' `FuncDeclaration` nodes keep a stale `skipCodegen = true`,
  DMD will skip the body even though Quickbite reset `semanticRun`.

Change being tried:

- Clear `function_.skipCodegen` in `resetObjState` before walking the function
  body.

Result:

- Focused tests still passed.
- The goal command still skipped every cerealed fixture with the same `bugs`
  second-pass link failure.
- This was insufficient; stale `skipCodegen` alone is not the missing state.

### Compare Preserved `bugs.d` Objects After New Resets

Temporarily kept `/tmp/quickbite_dmd_*` directories and ran:

```sh
./bench --warmup=1 --iterations=1 --backend=dmd-codegen --dub cerealed \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/bugs.d
```

Result:

- `/tmp/quickbite_dmd_0/module_0.o` was the warmup object and linked.
- `/tmp/quickbite_dmd_1/module_0.o` was the timed object and failed.
- `nm -C` showed the first object defines these weak bodies:

  ```text
  W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.this(ulong)
  W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.findSlotInsert(ulong) const
  W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.dim() const
  W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.grow()
  W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.mask() const
  W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.length() const
  W core.internal.newaa.Bucket!(tests.bugs.Pair, int).Bucket.empty() const
  ```

- The second object leaves the same bodies undefined.
- These methods live under `private:` and `private pure nothrow @nogc:`
  attribute sections in `core.internal.newaa`.

### Reset Direct Storage/Visibility Attribute Declarations

The earlier `AttribDeclaration.include(null)` traversal was too broad and
regressed focused tests. The object comparison above points at a narrower gap:
ordinary storage-class and visibility attribute wrappers hold declarations that
DMD object generation visits, but Quickbite's reset traversal did not.

Change being tried:

- For `StorageClassDeclaration` and `VisibilityDeclaration`, reset the direct
  `decl` list.
- Do not evaluate conditional/static-foreach/mixin attribute wrappers through
  `include(null)`.

Result:

- Focused tests still passed.
- The goal command still skipped every fixture, but the first `bugs` failure
  moved from missing `core.internal.newaa.Impl`/`Bucket` bodies to:

  ```text
  std.typecons.tuple!().tuple!(TypeInfo, ubyte[32]*).tuple(TypeInfo, ubyte[32]*)
  ```

- This is progress: the narrow attribute traversal restored the AA support
  bodies that live under storage/visibility attributes.
- Remaining failures now appear to involve other DMD object-generation state,
  starting with TypeInfo/template support used by `std.typecons`.

Compared preserved `/tmp/quickbite_dmd_0` and `/tmp/quickbite_dmd_1` objects
after this change.

Result:

- The second object now defines the previously-missing AA bodies, including:

  ```text
  W core.internal.newaa.Impl!(tests.bugs.Pair, int).Impl.this(ulong)
  W core.internal.newaa.Bucket!(tests.bugs.Pair, int).Bucket.empty() const
  ```

- The remaining first `bugs` failure is narrower. The first object defines:

  ```text
  W std.typecons.Tuple!(TypeInfo, ubyte[32]*).Tuple.this(TypeInfo, ubyte[32]*)
  ```

- The second object leaves that constructor undefined while still defining
  related `std.typecons.Tuple!(TypeInfo, ubyte[32]*)` methods such as
  `__xopEquals`, `toHash`, `opAssign`, `opEquals`, and the wrapper
  `std.typecons.tuple!().tuple!(TypeInfo, ubyte[32]*)`.
- The temporary keep-temp-dirs edit was reverted.

### Reset Direct `static if` Attribute Declarations

A subagent checked the remaining `Tuple!(TypeInfo, ubyte[32]*)` constructor
failure and found that the value constructor in `std.typecons.Tuple` is inside:

```d
static if (Types.length > 0)
```

DMD object generation visits `AttribDeclaration.include(null)` before emitting
members, so the first codegen pass emitted the constructor and marked it
`PASS.obj`. Quickbite's reset traversal did not reach declarations behind the
`StaticIfDeclaration`, so the second codegen pass still saw `PASS.obj` and
returned without emitting that constructor.

Changed the narrow attribute reset to include direct `StaticIfDeclaration.decl`
children, while still avoiding the earlier broad `include(null)` traversal.

Result:

- Focused tests still passed:

  ```sh
  dub test --config=unittest -- \
    ut.compiler_api.runTests.dmdCodegenRunsAssociativeArrayLiteral \
    ut.compiler_api.runTests.dmdCodegenRunsImportedSourceModules \
    ut.minicereal.dmd-codegen.minicerealFileCanRunTwice
  ```

- The goal command now prints a timing row for `bugs`:

  ```text
  bugs                             dmd-codegen    1638.308 ms 1651.709 ms  18.952 ms
  ```

- Later cerealed fixtures still skip. This fixes the repeated-codegen
  `std.typecons.Tuple.this` blocker, but not cross-fixture DMD global state.

### Diagnose Cross-Fixture Cerealed Failures

Temporarily changed `benchmarks/main.d:firstLine` to print full diagnostics,
then reverted that diagnostics edit.

Ran:

```sh
./benchmarks/run.sh --warmup=0 --iterations=1 --backend=dmd-codegen \
  --dub cerealed \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/cerealiser_impl.d
```

Result:

- The explicit first `cerealiser_impl` fixture produced a timing row.
- Later fixtures skipped with many undefined cerealed template bodies and
  TypeInfo/backend-support references.
- Representative unresolved references:

  ```text
  cerealed.cerealiser.CerealiserImpl!(std.array.Appender!(ubyte[]).Appender).CerealiserImpl.opOpAssign!("~", int[tests.bugs.Pair]).opOpAssign(int[tests.bugs.Pair])
  cerealed.decerealiser.Decerealiser.this!(ubyte).this(in ubyte[])
  cerealed.decerealiser.Decerealiser.value!(int[tests.bugs.Pair]).value()
  std.range.primitives.empty!(tests.bugs.Pair[]).empty(scope ref tests.bugs.Pair[])
  initializer for TypeInfo_FKS8cerealed10cerealiser__T14CerealiserImplTS3std5array__T8AppenderTAhZQnZQBvC6ObjectZv
  ```

Conclusion:

- A fixture can succeed when it is the first DMD-codegen fixture in the process.
- Subsequent fixtures can fail after earlier fixtures have populated DMD global
  template/backend state.
- The remaining blocker is cross-fixture global state, not only repeated
  codegen of the same parsed module.

Temporarily expanded `benchmarks/main.d:firstLine` again and ran a smaller
diagnostic command with explicit `bugs.d` and `cerealiser_impl.d` fixtures plus
`--dub cerealed`. The `--dub` flag still appended the whole cerealed fixture
list, so this was not a pure two-fixture run, but it showed the first failing
explicit `cerealiser_impl` object immediately after `bugs`.

Representative unresolved references from that first `cerealiser_impl`
failure:

```text
cerealed.cerealiser.CerealiserImpl!(cerealed.range.DynamicArrayRange).CerealiserImpl.opOpAssign!("~", tests.cerealiser_impl.WhateverStruct).opOpAssign(tests.cerealiser_impl.WhateverStruct)
cerealed.cerealiser.CerealiserImpl!(cerealed.range.DynamicArrayRange).CerealiserImpl.opOpAssign!("~", int).opOpAssign(int)
cerealed.cerealiser.CerealiserImpl!(cerealed.range.ScopeBufferRange).CerealiserImpl.opOpAssign!("~", tests.cerealiser_impl.WhateverStruct).opOpAssign(tests.cerealiser_impl.WhateverStruct)
core.internal.array.construction._d_arrayliteralTX!(ubyte)._d_arrayliteralTX(ulong)
```

The same command printed timing rows for both the explicit `bugs` fixture and
the DUB-appended `bugs` fixture. This reinforces that the repeated-codegen path
for `bugs` is now fixed, while the next failing surface is template ownership or
emission for different fixture-local instantiations after an earlier root.

### Full Suite Process-Order Failure

After reverting diagnostics-only edits, ran:

```sh
dub test
```

Result:

- The full suite failed even though the focused DMD-codegen tests pass in a
  fresh run.
- Four tests failed:

  ```text
  ut.compiler_api.runTests.dmdCodegenRunsAssociativeArrayLiteral
  ut.compiler_api.runTests.dmdCodegenRunsFailingPackageModuleUnittest
  ut.compiler_api.runTests.dmdCodegenRunsImportedSourceModules
  ut.minicereal.dmd-codegen.minicerealFileCanRunTwice
  ```

- The first failure was:

  ```text
  dlopen failed: /tmp/quickbite_dmd_3/module.so: undefined symbol:
  _D4core8internal5newaa__T4ImplTiTiZQk9__xtoHashFNbNeKxSQCbQBzQBt__TQBqTiTiZQByZm
  ```

- Later failures included unresolved
  `core.internal.newaa._d_aaIn!(int[int], int, int, int)`.

Conclusion:

- DMD-codegen behavior is still sensitive to prior non-codegen tests in the
  same process, not only to prior DMD-codegen benchmark fixtures.
- This strengthens the current diagnosis: Quickbite is still not fully
  resetting or isolating DMD's process-global template/backend state before
  object generation.

### Retest Compiling Archive-Backed Imported Source Modules

Temporarily changed `generateObjs` back from:

```d
collectSourceModules(module_, sourceImportPaths.codegenSourceImportPaths)
```

to:

```d
collectSourceModules(module_, sourceImportPaths)
```

Reason for trying:

- After the `StaticIfDeclaration` reset fix, many remaining unresolved symbols
  are cerealed template bodies instantiated with test-local types.
- Excluding archive-backed import paths prevents Quickbite from generating
  cerealed source modules as extra roots, so this retested the older shape with
  the new reset fixes in place.

Result:

- Focused tests still passed.
- The goal command still produced only the `bugs` timing row.
- Skip details changed, for example:

  ```text
  skipping cerealiser_impl dmd-codegen: dmd link failed: /usr/bin/ld: /tmp/quickbite_dmd_3/module_29.o: in function `std.array.array!(tests.range.MyInputRange).array(tests.range.MyInputRange)':
  skipping compile_time dmd-codegen: dmd link failed: /usr/bin/ld: /tmp/quickbite_dmd_5/module_2.o: in function `cerealed.cereal.grainAllMembers!(cerealed.decerealiser.Decerealiser, tests.classes.ClassWithStruct).grainAllMembers(ref cerealed.decerealiser.Decerealiser, ref tests.classes.ClassWithStruct)':
  ```

- This was insufficient and was reverted. Compiling imported source modules
  changes the unresolved-symbol surface but does not make cerealed fixtures run.

## Current Failure Shape

The goal command now prints a row for `bugs`, but later cerealed fixtures still
skip. Examples include:

```text
bugs                             dmd-codegen    1638.308 ms 1651.709 ms  18.952 ms
skipping cerealiser_impl dmd-codegen: dmd link failed: /usr/bin/ld: /tmp/quickbite_dmd_3/module_0.o: in function `tests.cerealiser_impl.__unittest_L13_C1()':
skipping classes dmd-codegen: dmd link failed: /usr/bin/ld: /tmp/quickbite_dmd_4/module_0.o: in function `tests.classes.__unittest_L15_C1()':
skipping compile_time dmd-codegen: dmd link failed: /usr/bin/ld: /tmp/quickbite_dmd_5/module_1.o:(.data._D97TypeInfo_PFKS8cerealed10cerealiser__T14CerealiserImplTS3std5array__T8AppenderTAhZQnZQBvC6ObjectZv6__initZ+0x10): undefined reference to `initializer for TypeInfo_FKS8cerealed10cerealiser__T14CerealiserImplTS3std5array__T8AppenderTAhZQnZQBvC6ObjectZv'
```

Running only `bugs.d` with manual import paths reported:

```text
undefined reference to `ModuleInfo for unit_threaded.from'
```

The benchmark process exits successfully because the harness catches
`Exception` and reports skipped rows. This still fails the task because skipped
fixtures are not working benchmark results.

### Reproduce Current Failure Before New Experiments

Ran:

```sh
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-codegen --dub cerealed
```

Result:

- The command completed successfully at the process level.
- `bugs` printed one timing row:

  ```text
  bugs                             dmd-codegen    1667.534 ms 1686.045 ms  26.179 ms
  ```

- Every later cerealed fixture still skipped. The first skip was
  `cerealiser_impl`:

  ```text
  skipping cerealiser_impl dmd-codegen: dmd link failed: /usr/bin/ld: /tmp/quickbite_dmd_3/module_0.o: in function `tests.cerealiser_impl.__unittest_L13_C1()':
  ```

Conclusion:

- The worktree still matches the documented current failure shape.
- The immediate blocker remains cross-fixture DMD/global codegen state after
  `bugs`, not the already-fixed repeated-codegen path for `bugs`.

### Full Diagnostics For First Cross-Fixture Failure

Temporarily preserved `/tmp/quickbite_dmd_*` directories and changed
`benchmarks/main.d` to print full skip diagnostics instead of only the first
line.

Ran:

```sh
./bench --warmup=0 --iterations=1 --backend=dmd-codegen --dub cerealed \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/bugs.d \
  /home/atila/.dub/packages/cerealed/3340ea8b1881588c30f7f363f3dec0d5d13ec372/cerealed/tests/cerealiser_impl.d
```

Result before the root-member experiment:

- The explicit `bugs` fixture printed a timing row.
- The first explicit `cerealiser_impl` fixture failed in
  `/tmp/quickbite_dmd_1`.
- Representative unresolved symbols:

  ```text
  cerealed.cerealiser.CerealiserImpl!(cerealed.range.DynamicArrayRange).CerealiserImpl.opOpAssign!("~", tests.cerealiser_impl.WhateverStruct).opOpAssign(tests.cerealiser_impl.WhateverStruct)
  cerealed.cerealiser.CerealiserImpl!(cerealed.range.DynamicArrayRange).CerealiserImpl.opOpAssign!("~", int).opOpAssign(int)
  cerealed.cerealiser.CerealiserImpl!(cerealed.range.ScopeBufferRange).CerealiserImpl.opOpAssign!("~", tests.cerealiser_impl.WhateverStruct).opOpAssign(tests.cerealiser_impl.WhateverStruct)
  core.internal.array.construction._d_arrayliteralTX!(ubyte)._d_arrayliteralTX(ulong)
  ```

`nm -C /tmp/quickbite_dmd_1/*.o` showed these were undefined everywhere in the
generated object set. This supports the subagent finding that DMD was not
reaching the relevant template instances through a generated module's
`members` graph.

### Append Rooted Template Instances To The Current Root

Both research subagents converged on the same DMD behavior:

- `generateCodeAndWrite` ultimately calls `genObjFile`, which only walks a
  module's `members`.
- `TemplateInstance.needsCodegen` can only help after DMD reaches the
  `TemplateInstance`.
- DMD's normal `appendToModuleMember` path both sets `TemplateInstance.memberOf`
  and pushes the instance into a module's `members`.
- Quickbite was mutating `minst` but not re-homing `memberOf` or root
  membership.

Temporary experiment:

- When `makeRootTemplateInstance` roots an eligible non-mixin template
  instance, also push it into `root.members` and set `memberOf = root`.
- Let instances through if they were instantiated by a current codegen module,
  even when their pretty name also mentions an archive-backed source module.

Result:

- The benchmark build succeeded.
- The same two-fixture diagnostic command no longer failed on the
  `CerealiserImpl.opOpAssign` symbols for `cerealiser_impl`.
- The first `cerealiser_impl` failure moved to:

  ```text
  core.internal.array.construction._d_arrayliteralTX!(ubyte)._d_arrayliteralTX(ulong)
  ```

Conclusion:

- Re-homing rooted template instances into the current root `members` graph is
  a real positive signal.
- The experiment is still incomplete. It can pull stale earlier fixture
  TypeInfo into later fixture objects, and later fixtures still fail.

### Also Root DMD's Always-Codegen Array Literal Template

DMD 2.112 has a special case in `TemplateInstance.needsCodegen` for
`_d_arrayliteralTX`: if reached, it returns `true` even if an instance already
exists in a non-root module.

Temporary experiment:

- Extended the root-member append experiment so `_d_arrayliteralTX` template
  instances also pass the rooting guard.

Result:

- The `_d_arrayliteralTX!(ubyte)` failure disappeared from the first
  `cerealiser_impl` diagnostic.
- The first failure moved to stale `tests.bugs.Pair` TypeInfo references:

  ```text
  tests.bugs.Pair.__xtoHash(ref const(tests.bugs.Pair))
  tests.bugs.Pair.__xopEquals(ref const(tests.bugs.Pair)) const
  ```

Conclusion:

- The always-codegen rooting experiment fixed the immediate
  `_d_arrayliteralTX` reachability failure.
- The next blocker is stale prior-fixture typeinfo/template state being pulled
  into later fixture object generation. This suggests the root-member append
  needs sharper eligibility, cleanup, or isolation before it can be kept.

## Plan Location

This file has moved to:

```text
ai/plans/dmd-backend.md
```

Future implementation plans for DMD backend work, including plans to emit code
directly in RAM and remove the shared-library bridge, should live under
`ai/plans`.

## Verification Targets

Run before committing:

```sh
dub test --config=unittest
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-codegen
./benchmarks/run.sh --warmup=1 --iterations=2 --backend=dmd-codegen --dub cerealed
```

The full `./benchmarks/run.sh` should be run before a PR.
