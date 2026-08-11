# Dependency Image Contract Cleanup

## Goal

Delete all static-library support from execution backends. A loadable shared
dependency image is the only binary-dependency form a backend may receive.

Static archives are not an execution feature. They remain only as Dub's cold
build output, consumed once by dependency preparation to construct the shared
image. No backend may accept, classify, search, wrap, link, or call a `.a`.

Start this cleanup after PRs #456 and #457 are integrated so it removes the
final archive-specific Bytecode shape and verifies against the combined tree.

## Target model

```text
cold, when dependency build identity changes:
  dub build                         -> dependency .a files
  dependency preparation           -> lib<pkg>_dub_deps.so

hot, after a project edit:
  SystemLinker:
    compile project source to .o
    link project .o against lib<pkg>_dub_deps.so
    load and run the project .so

  LLVMJit:
    load lib<pkg>_dub_deps.so
    compile project source to .o
    ORC-link only the project .o files
    resolve concrete dependency D symbols from the loaded image

  Interpreter / Bytecode:
    interpret or bytecode-compile project and dependency D source
    use loaded images only for declarations with no executable D body
```

SystemLinker and LLVMJit therefore use the dependency image for all concrete
precompiled D dependency code. Interpreter and Bytecode do not substitute the
image for source-backed D functions. Whether that substitution would improve
latency remains a separate measurement-gated decision.

Dub's `libs` and `lflags` are cold native link inputs. For example, a package
may report `ssl` and `crypto`; dependency preparation adds `-lssl -lcrypto`
while constructing the image. Those libraries become shared-image
dependencies in the ordinary platform-linker sense. VM backends encounter
their functions only through body-less native declarations reached while
executing the D binding source.

## Why this cleanup exists

PR #215 introduced direct archive linking as the first Dub dependency
implementation. SystemLinker appended Dub-built archives to every hot project
link. Commit `aaaf5d3a` replaced that path with the cold aggregated dependency
image, but the direct-archive API and synthetic test remained.

The surviving test was then mistaken for a backend contract:

- PR #293 added an ORC static-library generator for LLVMJit parity.
- PR #443 made Bytecode turn archives into a throwaway shared image.
- PR #456 adds archive-specific Bytecode function-pointer, method, receiver,
  delegate, and refusal behavior.

No CLI, REPL, Dub, benchmark, or documented embedding use case accepts an
arbitrary static archive as an execution input. Archive execution is a
superseded implementation detail, not D language behavior.

## Contracts and invariants

### Compiler ABI is part of image identity

A dependency image that contains D code records the compiler ABI that produced
it and has an identity for each loaded image generation. Those identities
participate in preparation inputs, backend loading decisions, and native
symbol resolution. A resolved D callable is an address plus its defining
image generation and ABI provenance; loading it into a DMD- or LDC-built host
does not change that provenance. `LINK.d` alone is not enough.
The legacy path-only loader derives that identity from the compiler-authored
ELF `.comment` section and rejects missing or ambiguous metadata; callers that
already carry provenance supply it explicitly per image.

Boundary argument ordering cannot make an otherwise incompatible D image safe
inside a host with a different druntime ABI. An in-process backend may load D
code only when the image's compiler ABI and runtime requirements are compatible
with that host; otherwise execution needs a matching process boundary or an
image built for the host compiler. C symbols continue to use the platform C
ABI and need no D-compiler ordering metadata.

`quickbite.ffi.ffi` consumes this provenance and owns the resolved-target
cache. Replacing an image generation invalidates its target entries without
invalidating prepared physical ABI shapes. The dependency-image layer owns
the generation and ABI facts, not the target cache or prepared call plans.
The bridge only orders addresses for the actual callable; it never rewrites
the value layout.

### Dependency preparation owns archives

The cold dependency-preparation layer:

- consumes Dub's dependency archives, native library names, and linker flags;
- includes every dependency archive member in one shared image;
- links against shared Phobos and Dub's required native libraries;
- returns a loadable dependency-image path;
- reports failures before constructing an execution backend.

This is the only production code allowed to inspect or pass `.a` files. It is
not a general static-library API: it is an implementation detail of converting
Dub's build outputs into the execution contract.

### Execution backends own only ready-to-execute inputs

The backend boundary accepts dependency images explicitly:

- SystemLinker puts images on the fresh project link line.
- LLVMJit loads images before ORC resolves project symbols.
- VM native bridges resolve body-less leaves from images the backend
  itself loaded. A backend that works only because another backend in the
  same process loaded the image is broken: every backend must run
  standalone.
- No backend classifies inputs by filename suffix to handle them
  differently. Rejecting anything that is not a `.so` outright, with a
  dependency-image diagnostic, is the required boundary check.
- No backend spawns a linker to make an archive executable.
- No backend exposes a direct-archive constructor or wire field.

### Dependency source classification remains

Removing archive transport must not make native backends compile the entire
dependency source tree on every edit. Native project codegen still needs to
know which imported modules have concrete definitions in the dependency
image.

Rename transport-derived terms to state their real purpose:

- `archiveImportPaths` -> `dependencyImportPaths`
- `archiveImportPathsUnder` -> `dependencyImportPathsOutside`
- `archiveCodegenImports` -> `dependencyImageImports` or another precise name

Preserve template-instance and TypeInfo ownership. A dependency template
instantiated with a project type is emitted with the project; ordinary
concrete dependency definitions remain in the image.

### VM execution policy remains

Interpreter and Bytecode continue to execute available D bodies. The native
bridge remains available for `fbody is null`, native data symbols, callbacks,
member calls, ref returns, and other real ABI crossings.

An import path must never make a source-backed D function native. Remove
`isArchiveBackedFunction` without weakening the ordinary native-leaf path.

Bytecode gains a `dependencyImages` constructor matching Interpreter's, and
the benchmark backend registry passes the prepared image to both VM
backends instead of discarding `BackendEnv`. The REPL builds no dependency
image at all today for any backend; closing that is separate work, not
part of this cleanup.

### Image loading remains process-global

Keep the current lifetime policy:

- load with `RTLD_NOW | RTLD_GLOBAL` before symbol resolution;
- resolve through `RTLD_DEFAULT`;
- use collision-free test symbols because loaded image state can outlive a
  fixture;
- do not introduce unloading in this cleanup.

Each load set still receives a distinct generation identity even while old
images remain process-global. Symbol resolution must not reuse an address
from an earlier generation merely because that image cannot be unloaded.

Use one dependency-image loading implementation. Fold LLVMJit's private copy
into `quickbite.ffi.loadDependencyImages` unless the frontend-free LDC
executor requires a lower shared module. If two call sites remain, they must
share one implementation and document the process boundary.

## Required removals

### Language-surface archive tests

Delete `tests/ut/backends/runner/lang/archive.d`. Its free-function,
function-pointer, struct/class method, delegate, refusal, and omission rows
test an unsupported binary input format, not D behavior.

Retain one subsystem-level cold-builder test proving the supported boundary:

1. build a PIC archive containing a function;
2. convert it with the dependency-image builder;
3. verify the output is a shared image;
4. load it through the common image loader;
5. resolve and call the function.

This test belongs with dependency-image or FFI mechanism coverage. Before
changing tests, present the exact deletion and replacement and wait for user
approval as required by `AGENTS.md`.

### Bytecode

Remove:

- the `(archivePaths, archiveImportPaths)` constructor, replaced by a
  `dependencyImages` constructor matching Interpreter's;
- `loadArchiveDependencyImages` and its hot `cc -shared` spawn;
- archive-image counters and temporary directories;
- archive-backed function/module classification;
- import-path-based native-leaf promotion;
- archive-only forwarding wrappers, receivers, diagnostics, and refusals from
  PRs #443 and #456.

Do not revert PR #456 wholesale. For every touched native-call field,
instruction, wrapper, or marshaller method:

- retain it if a supported `fbody is null` or other real native boundary uses
  it;
- remove it if its only trigger is archive-backed classification;
- remove any orphan rather than keeping speculative ABI machinery.

### Interpreter

Interpreter has no direct-archive implementation. Remove only archive matrix
omissions and plan backlog. Preserve PR #457: it implements ordinary D
behavior and does not depend on static-library support.

### LLVMJit and ORC

Remove:

- `LLVMJitInputs.staticLibraries`;
- suffix-based shared/static splitting;
- static-archive fields in executor requests and wire encoding;
- ORC static-library generator creation;
- `LLVMOrcCreateStaticLibrarySearchGeneratorForPath` bindings if unused.

LLVMJit loads dependency images and adds only freshly generated project
objects to ORC. Preserve process-symbol resolution, weak-symbol interposition,
ELF normalization, exception-frame registration, and child isolation.

### SystemLinker

Remove:

- generic `linkFiles` inputs;
- shared/static classification helpers;
- `--start-group` and `--end-group` archive handling;
- acceptance of non-image link inputs;
- executor filtering that silently discards non-shared files.

The hot link accepts and appends dependency images directly. Invalid image
inputs fail at the boundary with a dependency-image diagnostic.

### Driver and wire types

Rename the complete data path:

```text
DubInfo.linkFiles                 -> dependencyImages
BackendEnv.linkFiles              -> dependencyImages
SystemLinkerInputs.linkFiles      -> dependencyImages
archiveImportPaths                -> dependencyImportPaths
```

Remove static-archive lists from `RunRequest` and update encoding and decoding
together. Do not leave a generic `linkFiles` escape hatch.

### Plans

Rewrite existing plans to retain durable decisions, not a cleanup ledger:

- `dub-deps.md`: state the shared image as the sole binary dependency
  contract and delete direct-archive execution as a current option.
- `llvm-jit.md`: remove archive parity and static-generator claims while
  preserving the decision not to hand-roll an ELF linker.
- `bytecode.md`: remove archive promotion and archive-specific native-call
  work while preserving generally applicable ABI behavior.
- `bench.md`, `ffi.md`, and other plans: replace archive transport terminology
  with dependency-image terminology where it describes the current design.

## Execution order

### 1. Establish the combined baseline

Start from master containing PRs #456 and #457. Run:

```text
ninja bin/ut
bin/ut --random
```

Replay a failing random seed before changing the contract so baseline failures
are not attributed to the cleanup.

Also record whether a Dub package whose image needs native libraries (for
example `vibe-d`) prepares and runs on this baseline; step 8 compares
against that result.

### 2. Obtain test-change approval

Present the exact `runner/lang/archive.d` deletion and exact proposed cold
dependency-image test. Present in the same approval: adding Bytecode to the
`ffi/dependency_image.d` loading matrix, and the benchmark-binary test
change for the nonzero preparation-failure exit below. Stop until approved.

After approval, apply only the test contract change and run the focused tests.
If existing tests already prove the full cold conversion/load/call seam, show
that evidence before proposing no replacement. Check
`tests/ut/backends/ffi/dependency_image.d` and `tests/ut/bin/benchmarks.d`
first: together they may already cover the seam.

### 3. Normalize names

Rename image and dependency-import fields end to end while preserving
behavior. Run focused tests after every edit. Afterwards, remaining `archive`
references identify cold conversion or obsolete execution behavior.

### 4. Remove Bytecode archive behavior

Delete construction/linking first, then compiler and VM paths made
unreachable. Add the `dependencyImages` constructor and wire the benchmark
registry to pass the image to Interpreter and Bytecode. After every edit, run
focused Bytecode native-call, FFI, function-pointer, delegate, class, struct,
and ref tests. Ordinary body-less native calls must remain green.

### 5. Remove LLVMJit archive behavior

Delete in-process and executor archive fields together, then remove unused
ORC bindings. Run focused LLVMJit dependency-image, executor-wire, exception,
and random-order isolation tests after every edit.

### 6. Remove SystemLinker archive behavior

Make the hot link image-only and delete archive branches. Run all
SystemLinker tests and grouped Dub-package coverage. Missing dependency
symbols must still fail during link or load, not at the first call.

### 7. Deduplicate loading and settle plans

Consolidate image loading and rewrite affected plans. Use `rg` to prove no
execution backend retains `.a` handling or archive terminology. Expected
archive references are restricted to cold preparation and its mechanism test.

### 8. Verify production paths

Run:

```text
ninja bin/ut
focused dependency-image, FFI, SystemLinker, LLVMJit, and Bytecode tests
bin/ut --random
./bin/bench.sh -w 0 -r 1 -b system-linker --dub cerealed
./bin/bench.sh -w 0 -r 1 -b llvmjit --dub cerealed
./ci.sh
```

Make the benchmark binary exit nonzero when dependency preparation fails
(preparation records are already segregated from backend skips), so these
runs hard-gate image construction. Backend skips still exit zero: judge
those by the run's output, not by exit status.

Also exercise the native-library Dub package recorded in the step 1
baseline and require the baseline behaviour; unrelated backend language
gaps may still produce an honest skip.

## Completion criteria

- Execution backends contain no static-library support.
- No backend accepts, classifies, searches, wraps, or links `.a` inputs.
- No hot-path process converts archives into an image.
- Cold dependency preparation is the only production `.a` consumer.
- SystemLinker and LLVMJit consume explicit dependency images.
- VM backends execute source-backed dependency D and use resident images only
  for real native leaves, resolving them from images they loaded themselves —
  a single-backend run needs no native backend in the process.
- The runner wire format carries no static archives.
- `runner/lang` contains no archive-mechanism matrix.
- PR #457 and non-archive PR #456 behavior remain covered.
- Plans describe only the shared dependency-image contract.
- The full randomized suite, representative Dub benchmarks, and `ci.sh` pass.

## Non-goals

- Choosing native execution for source-available VM dependencies.
- Changing image unloading, symbol visibility, or lifetime.
- Optimizing cold `--whole-archive` image size.
- Fixing template-instance homing, JITLink defects, or unrelated backend gaps.
- Adding a general-purpose static-library or native linker API.
