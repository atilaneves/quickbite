# Quickbite

Quickbite executes D programs and their unittests through multiple backends
(interpreted, bytecode, JIT, compiled). This glossary fixes the words the
plans (`ai/plans/`), tests, and agent docs share. Terms mean exactly this;
the _Avoid_ lists name the drift to reject.

## Language

### Testing

**Oracle**:
The role a backend plays when its behaviour defines correct for the language
surface. `SystemLinker` (compiled, linked, executed D) plays it in the unit
suite. A role, not an intrinsic property of the backend.
_Avoid_: reference backend, ground truth

**Product**:
The role a backend plays when it is itself the measured deliverable, as in
the benchmark binary. The same backend can be oracle in one binary and
product in another.

**Fixture**:
The guest D source snippet a test executes.
_Avoid_: "fixture" for the test call site (say "fixture call site"), the
compiled shared library (say "fixture image"), or a module run under
`--dub` (say "fixture module")

**Matrix**:
The per-fixture block declaring which backends run it; collectively, all
such blocks in the suite.
_Avoid_: oracle matrix, compiled-behaviour matrix, backend matrix,
language-surface matrix

**Row**:
One backend's line in a benchmark table.
_Avoid_: "row" for an entry in a test's matrix (say "matrix entry")

**Pin**:
To assert with a test what a backend actually does, where that differs from
what the oracle does.
_Avoid_: "pin" for freezing a dependency version (say "locked SHA")

**Refusal**:
A backend's documented, loud rejection of a construct it does not support,
pinned by a test — as opposed to a silently wrong answer.

**Promotion**:
Adding a backend to an existing oracle-backed test's matrix.
_Avoid_: "promotion" for turning a REPL cell declaration into module storage
(say "lifting"), or for the banned boxed-era lazy value promotion

**Gate**:
A machine-checkable pass/fail criterion that blocks work from landing.
_Avoid_: "gate" for a human approval checkpoint (say "approval stop"), a
milestone, a per-backend opt-in flag, or a known open defect (say "open
blocker")

**Dub corpus**:
The external dub packages the benchmarks and gates run, selected by
code.dlang.org popularity plus the maintainer's own packages.
_Avoid_: bare "the corpus"

**Fixture corpus**:
The in-repo unit-suite fixtures.
_Avoid_: bare "the corpus"

### Execution

**Host**:
The running quickbite process: compiled D executing at full speed.

**Guest**:
The program a backend is executing, and its values, functions, and types as
the backend represents them.

**Native**:
In the host D ABI layout produced by compiled D.
_Avoid_: "native" for the compiled backend (name it: `SystemLinker`), or for
the far side of the FFI boundary (say "foreign")

**Place**:
A static type paired with the storage it governs.

**Boxed value**:
A guest value passed through a single universal host type instead of living
in native layout. The banned pattern; the boxed era is the period when all
guest values lived this way.
_Avoid_: carrier, universal value carrier, expression currency

**Storage authority**:
The single representation through which a binding is read and written — its
source of truth.
_Avoid_: layout authority, binding authority, value authority, storage world

**Authority switch**:
The point in the migration when a binding population's storage authority
becomes the native layout.

**Reify**:
Create a guest binding's native representation at first need, exactly once.
_Avoid_: materialize

**Cell**:
One REPL submission, together with the artifacts derived from it.
_Avoid_: "cell" for boxed-era variable storage ("cell family" names legacy
machinery and appears only in prohibitions)

**Lifting**:
Turning a cell-local declaration into a module-level variable so it has real
storage across cells.

**Interception**:
Diverting a call by name to a host implementation, sanctioned by an
enumerated exemption entry with a stated retirement condition.

**Shim**:
A name-based diversion or approximation without an exemption entry and
retirement condition. Always a defect.

**Lightning rod**:
The first root module parsed in a process, which deliberately accumulates
DMD's allInst/importedFrom funneling of druntime/phobos template instances
and TypeInfos so later-parsed modules stay clean.
_Avoid_: scapegoat root (superseded predecessor mechanism)

### Plans

**Item**:
One numbered unit of remaining work in an `ai/plans` document.
_Avoid_: slice, rung, milestone

**Acceptance criterion**:
The condition that makes a plan item done.
_Avoid_: bare "acceptance" as a noun, "acceptance result"

**Root-cause class**:
A set of red fixtures sharing one root cause; the unit of interpreter fix
work.
_Avoid_: gap class, disagreement class, frontier class, ceiling class, wall

**Frontier**:
The current set of open root-cause classes.
