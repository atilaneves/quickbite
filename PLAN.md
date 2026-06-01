# CTFE Coverage Handoff

This worktree has been merged with current `master`. The original PR was
merged, so the current branch is the in-progress coverage follow-up.

Current global coverage state:

- `tmp/dmd-ctfe-coverage/dmd-dinterpret-audit.md` reports
  `2343 / 3760 = 62.31%` executable entries covered.
- The `dmd-dinterpret.lst` summary reports `62% covered`.
- The unedited starting point for this worktree reported
  `2287 / 3760 = 60.82%` executable entries covered, with the
  `dmd-dinterpret.lst` summary at `60% covered`.
- `override void visit(StringExp e)` is now covered by mutable static string
  literal fixtures.

Files changed in this worktree:

- `tests/ut/backends/pure_/lang/arrays.d`
- `tests/ut/backends/pure_/lang/control_flow.d`
- `tests/ut/backends/pure_/lang/structs.d`

What has been verified:

- `env DUB_HOME=/tmp/qb-dub-home dub test -- --random`
- `env DUB_HOME=/tmp/qb-dub-home scripts/dmd-ctfe-coverage.sh`

Recent test additions that are green but did not move the method percentage:

- array copy and struct copy fixtures in `arrays.d` and `structs.d`
- direct `goto` restart fixtures in `control_flow.d`
- `try/finally` restart fixtures in `control_flow.d`
- catch-handler restart fixtures in `control_flow.d`

Recent test additions that moved method coverage:

- mutable static string literal copy fixtures in `arrays.d`

Observed blocker:

- The direct label/restart fixtures are not yet hitting the exact
  `istate.start == s` branches that would fully cover the small-gap visitors.
- The remaining easy-looking targets in `dinterpret.d` are still partial:
  `visitBreak`, `visitContinue`, `visitGoto`, `visitGotoCase`,
  `visitGotoDefault`, and the small statement visitors around them.

Next agent plan:

1. In the newly created worktree for the next coverage slice, run
   `env DUB_HOME=/tmp/qb-dub-home scripts/dmd-ctfe-coverage.sh` before edits
   to capture the baseline. Do not run this baseline measurement in the shared
   `master` checkout.
2. Re-read `tmp/dmd-ctfe-coverage/dmd-dinterpret-audit.md` and focus on the
   smallest remaining gaps first.
3. Inspect `/tmp/qb-dub-home/packages/dmd/2.112.0/dmd/compiler/src/dmd/
   dinterpret.d` around the restart logic before adding more tests.
4. Add one or two targeted fixtures at a time until a method row flips to
   `Covered`.
5. Re-run `env DUB_HOME=/tmp/qb-dub-home dub test -- --random`.
6. Re-run `env DUB_HOME=/tmp/qb-dub-home scripts/dmd-ctfe-coverage.sh`
   and compare the audit against the current `62.31%`.
7. Once the method percentage moves materially, hand the branch off for PR
   creation against current `master`.
