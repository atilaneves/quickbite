# Interpreter Performance

## Goal

Minimise edit-to-unittest-result latency for the tree-walking Interpreter while
preserving its agreement with `SystemLinker`. The Interpreter remains a no-emit
backend: an optimisation may change its internal execution machinery, but may
not add bytecode generation, native code generation, or package-specific
shortcuts.

This plan owns Interpreter execution latency. `interpreter.md` owns language
completeness, `value.md` owns representation, and `bench.md` owns trustworthy
measurement. Correctness work takes precedence when the Interpreter and
`SystemLinker` disagree.

Representation work is a prerequisite for production optimisation. Complete
`value.md`'s formatter, unittest/expression split, shared-`Value` deletion, and
Interpreter transitional-map removal before changing Interpreter execution
machinery for speed. Measurement infrastructure may land earlier. Never
optimise, share, or otherwise entrench a representation component that
`value.md` schedules for deletion.

## Measured Baseline

On commit `7bf3c583`, with the LDC 1.42 optimised benchmark host and Cerealed's
156 unittests:

```text
frontend                          about 2.4 s
interpreter post-parse            12.49-13.46 s
interpreter GC-used-size delta    about 8.42 GiB
system-linker post-parse          about 1.17 s
```

The post-parse numbers above use `-w 0 -r 1 --skip-check` to avoid the current
benchmark driver's duplicate untimed execution. They are single samples, so
they establish scale rather than an acceptance threshold.

A whole-process `perf` profile of the same Interpreter command showed
substantial time in druntime allocation machinery and these Interpreter-owned
operations:

```text
NativeBlock associative-array duplication       3.99% self
NativeBlock associative-array lookup/insertion  2.07% self
VarDeclaration-to-address map duplication        0.77% self
runExpression                                    1.29% self
```

The profile also contained GC marking from preparation and the harness's
pre-sample `GC.collect`; it therefore does not assign all GC samples to the
timed Interpreter body. It does prove that associative-array duplication is a
hot Interpreter operation. The 8.42 GiB figure is the increase in
`GC.stats.usedSize` while collection is disabled, not an allocation-site
breakdown.

`forkExecutionStateInto` currently duplicates many associative arrays for
every interpreted call. The profile identifies real cost, but the hottest
`NativeBlock` registry is transitional state that `value.md` schedules for
deletion. This evidence prioritises finishing that deletion; it does not make
the registry a production-code optimisation target. The profile does not yet
account for the whole runtime or allocation delta.

The Symmetry Investments collector is not a viable comparison at this
baseline. Registering symgc 0.0.8 through `import symgc.gcobj` and selecting
`gc:sdcq` exposes two collector failures before a usable row is published. The
harness's explicit pre-sample `GC.collect` corrupts symgc's dense-slab free
heap while finalizing unreachable objects. Omitting that collection and
disabling automatic collection lets a small Interpreter fixture finish, but
DMD shutdown then crashes when `Global.deinitialize` frees a large allocation
whose page descriptor has no extent. Symgc's own 29-module unittest suite
passes with the same LDC, so this is a workload compatibility defect rather
than a missing registration or custom-toolchain requirement. Collector work is
not on this plan's critical path.

## Measurement Contract

Every performance claim must include:

- the commit and exact command;
- median wall time from at least five measured process launches, interleaved
  with the baseline when comparing branches;
- the number and outcome of executed unittests;
- peak RSS and the benchmark's GC-used-size delta;
- a CPU profile scoped to post-parse execution; and
- an allocation-site or allocation-counter breakdown scoped to post-parse
  execution.

The benchmark must expose phase markers or a post-parse-only profiling mode so
profiles do not mix dependency preparation, frontend work, explicit
pre-sample collection, and Interpreter execution. A whole-process profile may
identify candidates, but may not close an optimisation item.

The profiling boundary must leave the process attachable while idle and resume
without executing backend work before the profiler is active. `SIGSTOP` is not
that contract: this host's `perf record -p` cannot create maps for the stopped
task. Use a sleeping signal/fd-controlled boundary or profiler control events,
and verify the resulting profile contains no frontend samples.

Measure normal user-visible latency with collection enabled. A GC-disabled run
may remain as a diagnostic for allocation volume and variance, but may not be
the sole acceptance number: suppressing collection while one execution creates
gigabytes of garbage does not model edit-to-result latency. Each row must state
the collection policy it used.

The standing acceptance command compares the Interpreter with its oracle:

```text
./bin/bench.sh -w 0 -r 5 -b interpreter -b system-linker --dub cerealed
```

Use `--skip-check` only for diagnostic profiling that deliberately does not
publish a correctness-backed performance result. Run the ordinary two-backend
command separately to establish agreement with the oracle.

## Correctness And Benchmark Contracts

- The Interpreter and `SystemLinker` must return identical test names and
  pass/fail outcomes before an Interpreter result is published.
- Correctness verification is the first measured execution, not a separate
  untimed execution. The benchmark retains its results and validates them.
- Every subsequent measured execution must also return the same result shape
  and outcomes. A nondeterministic failure invalidates the row.
- For multiple backends, collect provisional measurements and retained results
  for all selected backends, compare them, then print or discard the rows.
- For one backend, validate that its retained result set is nonempty and all
  tests pass before printing the row.
- Warmups, when requested, may be discarded for timing but their failures must
  still abort the row. A warmup does not justify an additional verification
  execution.
- `--skip-check` remains the explicit way to bypass result validation. It does
  not add any execution.

The obsolete sequence was:

```text
verify every backend -> run every backend again under the timer
```

The required sequence is:

```text
measure and retain results -> compare retained results -> publish valid rows
```

The timing harness must therefore accept a delegate returning `TestResult[]`
and retain one result set alongside each sample instead of accepting a `void`
delegate and discarding every result.

## Optimisation Order

### 1. Finish The Measurement Foundation

Result capture and validation belong to the measured executions as specified
above; no separate backend execution precedes them. This is harness latency,
not an Interpreter speedup, but it reduces command edit-to-result latency and
makes later profiling cheaper and less ambiguous.

Do not weaken the check rule. A row is printed only after the retained timed
results satisfy the same single-backend or cross-backend correctness contract
that the separate pass enforces today.

The remaining measurement prerequisite is an attachable post-parse profiling
boundary. Report whether GC collection remained enabled during each row.
GC-disabled diagnostic profiles may guide `value.md` deletion before the
boundary exists, but cannot close a performance item. Re-baseline after
representation completion and before changing surviving Interpreter machinery
for speed.

### 2. Finish The Value-Representation End State

Complete `value.md` before production performance changes. Delete the shared
`Value`, the existing broad Interpreter `RuntimeValue`, formatting/reification
scaffolding, and transitional allocation/declaration identity maps.
`nativePointerRoots` is specifically not an optimisation target: replace it
with ordinary GC scanning from native frames and blocks, using a scoped
temporary owner only while a newly produced raw address has not yet reached
scanned storage.

Completion means the Interpreter satisfies `value.md`'s end-state criteria and
the performance profile contains only machinery intended to survive. Do not
move a transitional map into a shared context merely because copying it is hot.

### 3. Re-baseline After Representation Completion

Repeat the full measurement contract. Compare the new profile with this plan's
historical baseline, but choose targets only from the new scoped CPU and
allocation evidence. Rewrite the remaining order if representation deletion
changes the dominant costs.

### 4. Stop Copying Surviving Execution-Global State Per Call

Partition `Walker` state by lifetime:

- one execution context shared by every call in a unittest;
- one activation frame owned by a single interpreted call; and
- explicitly scoped temporary roots whose lifetime ends at a known return or
  expression boundary.

Move only surviving function-pointer and delegate registries, exception
metadata, and other genuinely execution-global maps into a shared struct. Keep
call-local bindings, lazy arguments, loop control, result state, and the
activation frame local. A child call must borrow the shared context rather than
duplicate it.

Do not move a map merely because sharing is faster. For each map currently
copied by `forkExecutionStateInto`, document:

- who creates and destroys an entry;
- whether child writes are immediately visible to the caller;
- whether unwinding must roll them back;
- which addresses keep GC allocations alive; and
- what `mergeFunctionState` currently does with it.

Convert one surviving map family at a time, then re-profile. Delete each
corresponding copy and merge path once the shared-lifetime contract makes it
redundant. Completion means `forkExecutionStateInto` contains no full
execution-global associative-array duplication.

### 5. Make Call Frames Dense And Reusable

After state copying is removed, measure `FrameBlock.allocate`, frame-layout
lookup, parameter binding, and frame destruction separately.

Use `FrameLayout`'s compile-time knowledge to replace hot
`VarDeclaration`-keyed runtime lookups with dense slot indices or direct
offsets. Preserve DMD-derived offsets and alignment; do not create a second
layout model.

If frame allocation remains material, introduce an execution-owned frame arena
or free list with stack discipline:

- allocate a frame on call;
- retain every pointer-bearing frame as a GC-visible root while live;
- rewind or recycle it on normal return and exception unwinding; and
- never reuse storage while a delegate, `ref`, pointer, or closure can still
  observe it.

Escaping-frame analysis is a correctness requirement, not an optional
optimisation. Keep ordinary GC allocation for frames whose addresses escape
until their lifetime can be proved.

### 6. Remove Temporary Allocation In Expression Execution

Re-profile after call-state and frame changes. Count allocation calls and bytes
for:

- argument arrays in `runCallExpression`;
- native-call operand and callback arrays;
- string and diagnostic duplication;
- aggregate-handle temporaries;
- associative-array helper keys and values; and
- surviving expression-carrier copies.

Reuse scratch buffers owned by the current activation where recursion permits,
or use stack/static-capacity storage for small common arities. A scratch buffer
must not outlive its frame or alias a nested call's active buffer.

Do not attribute cost to a surviving expression carrier from its presence
alone. Measure its copy and construction costs, and optimise it only if a
scoped profile identifies them. Do not restore recursively boxed aggregate
storage or a universal runtime value.

### 7. Reduce AST And Type Dispatch Cost

Only after allocation pressure is no longer dominant, profile the tree walk's
own work. Candidate costs include repeated `isXxxExp` chains,
`Type.toBasetype`, layout queries, function semantic preparation, and repeated
classification of the same DMD declaration or expression.

Cache immutable facts by DMD node identity for one frontend lifetime. Clear
all such caches at the existing compiler-lifetime boundary. A cache may store
classification, layout, or resolved callable metadata; it may not cache a
runtime value or skip expression side effects.

### 8. Reconsider The Backend Boundary

If the preceding work leaves the Interpreter materially slower than the
edit-latency target, use the profile to decide whether the remaining cost is
inherent AST dispatch or a removable implementation cost. Bytecode compilation
belongs to `bytecode.md`; do not turn this Interpreter into a second bytecode
backend. The useful comparison is then total edit-to-result latency between
the no-emit Interpreter and Bytecode, including Bytecode lowering time.

## Gates For Every Production Slice

Strict TDD applies. Before adding or changing a test for new functionality,
show the exact test and wait for approval. A bug-exposing test does not require
advance approval, but must first fail on every applicable backend.

For each optimisation slice:

1. establish a clean focused and full-suite baseline;
2. add or use a behavior-level oracle test for the lifetime/aliasing contract;
3. make the smallest internal change that preserves that contract;
4. run the focused test after every code edit;
5. run `bin/ut --random` and the Cerealed two-backend gate;
6. collect the required before/after performance evidence; and
7. revert the optimisation if the median improvement is within noise or if
   peak memory, correctness, or diagnostic quality regresses without an
   explicit accepted trade-off.

Run `ci.sh` before creating a PR. Performance work does not relax the oracle,
backend isolation, or CI requirements.

## Rejected Shortcuts

- Do not special-case Cerealed modules, declarations, or call patterns.
- Do not disable correctness checks to make the command finish sooner.
- Do not retain the separate verification pass; correctness comes from the
  retained measured results.
- Do not treat GC replacement as a substitute for removing avoidable
  allocation. Symgc currently cannot reach this workload, and a different
  collector would not remove the copied maps.
- Do not infer allocation ownership from `GC.stats.usedSize`; use scoped
  allocation evidence.
- Do not optimise legacy boxed aggregate arms that are scheduled for deletion
  unless a profile proves they execute in the measured workload.
- Do not optimise, share, or consolidate allocation/declaration identity maps
  that `value.md` schedules for deletion. Delete them through the native
  storage-authority work first, then profile what remains.
- Do not add a JIT to the Interpreter. JIT compilation is contrary to the
  project's edit-latency goal and belongs to a different backend.
