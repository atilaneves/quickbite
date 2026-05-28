# DMD CTFE Coverage-Driven Tests

## Goal

Use DMD coverage data to find untested paths in the CTFE engine and turn every
reachable gap into a focused Quickbite test.

The primary target is DMD's CTFE interpreter:

- `dmd.dinterpret`
- local source path from `dub.selections.json`:
  `/home/atila/.dub/packages/dmd/2.112.0/dmd/compiler/src/dmd/dinterpret.d`

Whole uncovered visitor methods for expression or statement AST nodes should be
treated as the highest-priority gaps. Isolated uncovered lines should still be
triaged, but only reachable D semantics should become tests.

## Current Baseline

Quickbite already has a `unittest-cov` configuration in `dub.sdl`. It is meant
to be paired with `--build=unittest-cov`, which causes DUB/DMD to build with
coverage enabled.

A local probe of:

```sh
dub test --build=unittest-cov -- \
    ut.backends.pure_.lang.expressions.intAddition.Ctfe
```

failed at link time while building instrumented DMD frontend libraries:

```text
undefined symbol: ModuleInfo for dmd.link
undefined symbol: dmd.link.runPreprocessor(...)
```

Both unresolved symbols were referenced from `dmd.cpreprocess`. Treat this as a
coverage-workflow issue to investigate before relying on fresh coverage output.
Do not edit files under `~/.dub/packages` directly to fix it.

There are also stale DMD coverage `.lst` files in the repository root from an
older DMD package version. They are useful only as examples of DMD's coverage
file format; regenerate coverage before choosing tests.

## Coverage Workflow

Create a repo-owned way to generate CTFE coverage without modifying vendored or
DUB package files in place.

The workflow should:

- build and run the Quickbite CTFE backend tests with DMD coverage enabled;
- include coverage for dependency source modules, especially `dmd.dinterpret`;
- write generated `.lst` coverage files to a predictable ignored location or
  document the existing DMD output location clearly;
- avoid running coverage in parallel with normal `dub test` in the same
  checkout;
- keep the ordinary `dub test` path unchanged.

If the `dmd.cpreprocess`/`dmd.link` linker failure still reproduces, fix the
coverage workflow in Quickbite-owned code or scripts. A likely route is a
temporary DUB package/build setup that includes the DMD frontend source needed
for the instrumented build, without changing the checked-in dependency package.

After the workflow runs, parse the `dmd.dinterpret` `.lst` file and group
`0000000|` lines by enclosing function or visitor method. The first useful
report should separate:

- wholly uncovered `interpretStatement` statement visitor methods;
- wholly uncovered `Interpreter.visit(...)` expression visitor methods;
- partially covered visitor methods with important branch gaps;
- CTFE helper functions not tied to one AST node;
- lines that are defensive, impossible, or not reachable from semantic D code.

## Test Selection

Add tests one behaviour at a time. Before adding or modifying any test, show the
exact proposed test body and wait for approval.

For each uncovered group:

1. Identify the smallest D source fixture that should reach the uncovered CTFE
   code through normal semantic analysis.
2. Check whether the fixture represents valid D language behaviour. For
   `pure_` tests, DMD CTFE is the canonical oracle unless completed DMD codegen
   proves compiled D differs.
3. Prefer a normal passing behaviour test. Use a diagnostic test only when the
   uncovered path is genuinely an error path.
4. Add the test under the closest existing backend pure-test module, such as
   `tests/ut/backends/pure_/lang/expressions.d`,
   `tests/ut/backends/pure_/lang/control_flow.d`,
   `tests/ut/backends/pure_/lang/arrays.d`,
   `tests/ut/backends/pure_/lang/structs.d`, or
   `tests/ut/backends/pure_/lang/exceptions.d`.
5. Run the focused test, then regenerate CTFE coverage and confirm the intended
   `dmd.dinterpret` lines changed from uncovered to covered.

Avoid all-literal fixtures unless constant folding itself is the target. Use
runtime-shaped values such as mutable locals or helper calls so DMD does not
fold away the AST node before CTFE interprets it.

Do not add tests for internal assertions, compiler consistency checks, frontend
states that semantic analysis rewrites away, or impossible AST shapes. Record
those gaps with the exact line or method and a short reason.

## Audit Log

Keep an audit table in this plan or in a sibling coverage audit file. Each row
should track one uncovered method or coherent branch group.

Suggested columns:

| DMD CTFE area | Coverage status | Test or reason | Notes |
| --- | --- | --- | --- |
| `visit(FooExp)` | Needs triage | Pending | Whole method |
| `visitBar` line N | Covered | `test.name.Ctfe` | Focused fixture |
| `visitBaz` assertion | Not reachable | Semantic rewrite | No test |

Update the table as tests are approved and added. Do not leave uncovered
reachable methods as undocumented backlog.

## Acceptance Criteria

- Fresh coverage for `dmd.dinterpret` can be generated from this repository.
- Every new test maps to at least one previously uncovered CTFE line or method.
- Reachable whole-method gaps for CTFE AST-node visitors are covered by focused
  tests.
- Remaining uncovered CTFE lines are explicitly classified as unreachable,
  defensive, unsupported, or pending.
- Final verification includes focused tests for each added fixture and a full
  `dub test`.
