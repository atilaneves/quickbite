# Plan: Tree-Walking Executor

## Summary

Walk the semantically-analysed DMD AST directly and execute it in a
single recursive descent, with no lowering pass and no intermediate
representation. The goal is to reach CTFE parity on the language
surface covered by the existing test suite, driven by promoting
CTFE-only tests one at a time to the tree-walking backend.

The process mirrors the IR backend: pick a test that currently only
runs under CTFE, add the tree-walking backend to it, confirm it is
red, implement the smallest handler that makes it green, then move
on. Do not add implementation beyond what a failing test demands.

When a test passes without any implementation change, do not assume
the feature works. Mutate the test or the production code to confirm
the passing result would become a failure under a meaningful change.
Only then accept the slice as done.

## Architecture

- Walk `FuncDeclaration` and `UnitTestDeclaration` AST nodes for
  unittest bodies; dispatch to statement and expression handlers by
  dynamic type.
- No intermediate form. Values are produced and consumed in the same
  recursive descent; no register allocation or instruction selection.
- Use a flat environment model: a locals map keyed by declaration
  identity, extended and restored on scope entry and exit.
- The executor must not import or delegate to other backends.
  Unsupported AST nodes must emit an explicit unsupported diagnostic
  rather than crashing or falling through.
- Keep DMD coupling behind the walker itself. Public types and return
  values must not expose `dmd.*` identities across the executor
  boundary.
- `tree_walking_old.d` is a reference for feature scope, not
  production code. Do not port code from it mechanically; re-derive
  each slice from a failing test.

## Slice Plan

Promote tests in order of complexity. Start with the narrowest
behaviors already in the CTFE-passing suite — integer literals,
arithmetic, comparisons — and work outward toward control flow,
arrays, structs, and exceptions as each prior slice stabilises.

Do not decide the ordering in advance beyond the immediate next test.
Let the failing test determine what to implement.

## Test Strategy

- CTFE-passing tests are the acceptance matrix. Promote a test by
  adding the tree-walking backend to it, confirm it turns red, then
  implement the minimum handler that makes it green. Existing
  CTFE-passing tests are pre-approved for promotion to the
  tree-walking backend; do not stop to ask before adding
  `TreeWalker` to exactly one existing test.
- When a promoted test is green without any implementation change,
  verify it is genuinely covered by mutating the test or the
  production code. A test that cannot be made to fail is not
  providing signal.
- Do not add new language-surface tests. The existing suite is the
  driver. Stop and ask before adding any new test.
- Add tree-walker-specific tests only for walker-native contracts:
  unsupported node diagnostics and environment scoping invariants.
- Never remove or weaken an existing test to satisfy the walker.
- After each slice, run `dub test -- --random` to catch regressions.

## Assumptions

- AST-first execution is the baseline; no intermediate form is
  planned.
- The executor targets unittest latency, not long-running throughput.
- DMD AST node types are stable at the pinned version. If a node
  shape changes, update the handler at the point of breakage.
- Templates and mixin expansions are resolved by DMD before the
  walker sees the AST; they are not a separate concern.
