# Ctfe Backend Integral-Type Test Migration Plan

## Summary

The broad Ctfe backend pure-test migration is complete. The remaining
executor behaviour that is not already covered semantically by the Ctfe
backend suite is the `integralType` matrix from
`tests/ut/executors/pure_/lang/expressions.d`.

Migrate only that uncovered behaviour, using the same backend-test migration
shape as the previous pure modules: add a Ctfe backend test module, wire it
into `tests/main.d`, verify the negative diagnostics against real DMD Ctfe
output, focused-test it with the architecture guard, audit-poke the positive
tests, then run full verification.

The behaviour to migrate is:

- A runtime `int` value returns `130`.
- The value is cast to each integral type:
  `byte`, `ubyte`, `short`, `ushort`, `int`, `uint`, `long`, and `ulong`.
- The narrowed value is stored in a `T` local.
- The value is passed through `T identity(T value)` and returned.
- The test asserts both identity preservation and D narrowing/sign behaviour,
  especially `byte` producing `-126`.

Do not remigrate simple expression fixtures such as `lessThan`, `rightShift`,
`multiplication`, `subtraction`, `preIncrement`, or `castUbyteTruncates`; their
language behaviour is already covered by existing Ctfe backend tests under
different names. Do not migrate executor-specific diagnostics such as
`treeWalkingOld assertion context does not reevaluate equality operands`.

## Key Changes

- Add a focused unittest-style Ctfe backend test module under
  `tests/ut/backends/pure_/lang`.
- Wire the module into `tests/main.d`.
- Keep the executor test as source material only. Copy the D fixture shape and
  expected D behaviour, but do not import, call, or exercise executor code.
- Add negative diagnostic probes that prove the generated positive tests run
  and expose the observed narrowed values.
- Verify negative diagnostic strings against real DMD CLI Ctfe output before
  encoding them.
- Audit-poke every migrated positive generated test before committing.

## Architecture Constraints

- Work in a fresh branch and worktree under `worktrees/`.
- Treat this as test migration from already-approved executor coverage, not
  new language-surface design.
- Keep backend tests isolated from executor APIs. Backend source and backend
  tests must not import `quickbite.executor`, `quickbite.executors`,
  `ut.executors`, or executor helper modules.
- Preserve valid D source with `unittest` blocks. Do not convert the fixture to
  REPL-only snippets.
- Preserve the runtime-shaped `input()` helper so DMD cannot fold the cast
  before Ctfe execution sees the behaviour.
- Do not add production code unless the migrated test exposes a true Ctfe
  backend gap.
- Do not add fallback paths, post-failure assertion walking, DMD diagnostic
  text parsing, or executor integration.
- Keep `tests/ut/backends/architecture.d` focused on backend source and
  backend tests.

## Migration Shape

Add a new module:

`tests/ut/backends/pure_/lang/integral_types.d`

Wire it into `tests/main.d` as:

`ut.backends.pure_.lang.integral_types`

Use the standard backend-test harness:

```d
module ut.backends.pure_.lang.integral_types;


import std.conv: text;
import std.meta: AliasSeq;
import ut.backends;


private:

static foreach (backend; backends) {
    // Tests go here.
}
```

Preferred positive fixture shape:

```d
static foreach (backend; backends) {
    alias IntegralTypes = AliasSeq!(
        byte,
        ubyte,
        short,
        ushort,
        int,
        uint,
        long,
        ulong,
    );

    static foreach (T; IntegralTypes) {
        @("integralType." ~ T.stringof ~ "." ~ backend.stringof)
        unittest {
            newBackend!backend.runTests(text(
                "alias T = ",
                T.stringof,
                ";",
                q{
                    static if (is(T == byte))
                        enum expected = -126;
                    else
                        enum expected = 130;

                    T identity(T value) {
                        return value;
                    }

                    int input() {
                        return 130;
                    }

                    unittest {
                        T value = cast(T) input;
                        assert(identity(value) == value);
                        assert(value == expected);
                    }
                },
            ));
        }
    }
}
```

Add negative probes that prove the migrated unittests execute and expose the
observed narrowed values through DMD's Ctfe assertion diagnostics. Keep them
close to the positive matrix and name them with stable suffixes, for example:

- `integralTypeFailureMessage.byte.0.Ctfe`
- `integralTypeFailureMessage.byte.1.Ctfe`
- `integralTypeFailureMessage.uint.0.Ctfe`

Prefer two negative probes per generated positive type. If that becomes too
noisy, include at minimum:

- `byte`: expected `130` or another wrong value, proving signed narrowing to
  `-126`.
- One unsigned narrow type such as `ubyte`: expected a wrong value, proving
  unsigned narrowing from the same runtime input.
- One wider type such as `uint`, `long`, or `ulong`: expected a wrong value,
  proving the non-narrowing path still executes.

For each negative probe, keep the fixture valid D and runtime-shaped. Do not
replace `input()` with an enum or literal-only expression.

If the final implementation uses fewer than two negative probes per generated
positive type, document why in the handoff. The likely acceptable reason is
that the positive matrix already creates eight generated positive tests, and
the representative probes cover the distinct semantic classes: signed
narrowing, unsigned narrowing, and non-narrowing.

## Review Gates

Use judgment on whether a separate conversion reviewer is useful. This is a
small source-preserving migration, so an additional conversion reviewer is not
required unless the fixture shape changes substantially.

Before committing, review that:

- The new backend module covers only the uncovered `integralType` behaviour.
- The test module imports backend helpers, not executor helpers.
- The positive tests preserve the runtime-shaped `input()` call.
- The positive matrix covers all eight integral types.
- The negative probes check DMD `-checkaction=context`-style messages verified
  against real CLI output.
- No production changes exist unless a true backend gap forced them.

## Oracle

Before encoding expected failure messages, verify each distinct negative probe
against real DMD Ctfe output using a CLI command from the active worktree, for
example:

```sh
dmd -o- -checkaction=context fixture.d
```

If the fixture needs imports or string imports, add the same switches the real
fixture needs. Do not use the current dmd-as-a-library wrapper output as the
oracle when it disagrees with the CLI.

Temporary probe edits should stay in the active worktree. Prefer temporarily
editing the backend test fixture and restoring it before committing. If a
separate probe file is necessary, create it inside the worktree and delete it
before committing.

## Workflow

1. Create a fresh worktree for the branch.
2. Add `tests/ut/backends/pure_/lang/integral_types.d`.
3. Wire `ut.backends.pure_.lang.integral_types` into `tests/main.d`.
4. Add the migrated `integralType` positive matrix.
5. Add the representative negative diagnostic probes.
6. Verify negative diagnostic strings against real DMD CLI Ctfe output.
7. Run focused verification:
   `dub test -- ut.backends.architecture ut.backends.pure_.lang.integral_types`.
8. If the focused test is red because of a migration mistake, fix the test and
   rerun focused verification.
9. If the focused test exposes a true Ctfe backend gap, stop and discuss the
   smallest production change before implementing it.
10. Once focused verification is green, audit-poke the new positive generated
    tests so each one fails, run the focused command, confirm unit-threaded
    reports all eight poked positive tests as failing, then restore the source.
11. Run the focused verification again after restoring the poke.
12. Run `dub test`.
13. Update this plan's handoff section with the final test names, exact DMD
    probe commands, focused verification result, audit-poke result, full
    verification result, and any true backend gap fixed.

## PR Boundary

This plan is one coherent migration slice. Do not add unrelated expression
tests, remigrate already-covered executor fixtures, or start another backend
test migration in the same PR.

Before opening the PR:

- Run the focused command with `ut.backends.architecture`.
- Run the audit poke and restore it.
- Run `dub test`.
- Update this handoff section.
- Push the branch.
- Create the PR.
- Open the PR in the browser, following repo instructions.

## Handoff Status

- Branch/worktree: `ctfe-backend-integral-types` at
  `worktrees/ctfe-backend-integral-types`.
- Added `tests/ut/backends/pure_/lang/integral_types.d` and wired
  `ut.backends.pure_.lang.integral_types` into `tests/main.d`.
- Migrated the uncovered `integralType` matrix from
  `tests/ut/executors/pure_/lang/expressions.d` for all eight integral types:
  `byte`, `ubyte`, `short`, `ushort`, `int`, `uint`, `long`, and `ulong`.
- The positive fixture keeps the runtime-shaped `input()` helper and uses
  `enum expected = cast(T) 130;` so D defines the narrowing/sign behaviour for
  each migrated type.
- Added representative negative assertion probes:
  `integralTypeFailureMessage.byte.0.Ctfe`,
  `integralTypeFailureMessage.ubyte.0.Ctfe`, and
  `integralTypeFailureMessage.uint.0.Ctfe`.
- Used fewer than two negative probes per generated positive type because the
  positive matrix already creates eight generated tests and the representative
  probes cover the distinct semantic classes: signed narrowing, unsigned
  narrowing, and non-narrowing.
- Verified the negative probe messages against real DMD CLI output with a
  temporary `integral_type_probe.d` file in the worktree, then deleted it:
  `dmd -checkaction=context -unittest -main -run integral_type_probe.d`.
  Observed messages were `-126 != 130`, `130 != 129`, and `130 != 131`.
- No production code changes were needed. No true Ctfe backend gaps were found.
- Focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.integral_types`
  reported `12 test(s) run, 0 failed`.
- Audit poke passed: temporarily changing the positive matrix to `assert(false)`
  made all eight generated positive `integralType.*.Ctfe` tests fail in the
  focused run, then the source was restored and focused verification passed
  again.
- Full verification passed: `dub test` reported
  `1378 test(s) run, 0 failed, 27/27 failing as expected`.
