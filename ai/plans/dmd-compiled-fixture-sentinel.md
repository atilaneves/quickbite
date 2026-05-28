# DMD Compiled Fixture Sentinel

## Summary

Make compiled DMD the sentinel for migrated backend fixtures. Negative
fixtures should specify the failing source once, then generate:

- a backend test for each backend, named with the backend last
- a compiled-D sentinel test, named with `.dmd` last
- an exact diagnostic comparison using DMD's `-checkaction=context` message

The first implementation should target equality-style assertion failures only.
Add other assertion shapes later when a migrated fixture requires them.

## Key Changes

Add a fixture helper module for backend fixture tests, for example
`ut.backends.pure_.fixtures`.

The main API should be:

```d
mixin failingFixture!(
    "intAdditionFailureMessage.0",
    q{
        static int one() {
            return 1;
        }

        static int answer() {
            return one + 41;
        }
    },
    q{answer},
    43,
);
```

`failingFixture` should generate a uniquely named helper struct per mixin use.
Derive the struct name from the fixture name, for example
`intAdditionFailureMessage.0` to `IntAdditionFailureMessage_0_Fixture`.

The generated struct should contain:

- `static:` before the mixed-in setup source
- a normal `assertEqual(T, U)(T actual, U expected)` helper, or access to one
- exactly one hidden failing `unittest`

The generated hidden unittest should be equivalent to:

```d
@HiddenTest
unittest {
    assertEqual(answer, 43);
}
```

The visible compiled-D sentinel test should collect that hidden unittest
through `__traits(getUnitTests, Fixture)` and assert that DMD produced a
non-empty contextual assertion message.

The visible backend tests should run generated source through each backend and
compare the backend diagnostic to the compiled-D sentinel diagnostic.

Preserve backend-last names:

```text
intAdditionFailureMessage.0.dmd
intAdditionFailureMessage.0.Ctfe
```

Do not spawn a DMD process per test.

## Helper Details

Implement a helper shaped like:

```d
string dmdFailureMessage(alias Fixture)() {
    import core.exception: AssertError;
    import std.exception: collectException;

    alias tests = __traits(getUnitTests, Fixture);
    static assert(
        tests.length == 1,
        Fixture.stringof ~ " must contain exactly one unittest",
    );

    alias test = tests[0];

    const thrown = collectException!AssertError(test());
    assert(thrown !is null);

    return thrown.msg;
}
```

The `static assert` is required. It prevents a fixture from silently collecting
the wrong unittest if the setup source accidentally adds another one.

Generate backend source from the same fixture ingredients:

```d
setupSource ~ q{

void assertEqual(T, U)(T actual, U expected) {
    assert(actual == expected);
}

unittest {
    assertEqual(} ~ actualSource ~ ", " ~ expected.stringof ~ q{);
}
}
```

Keep `actualSource` as a string because it names code inside the generated
fixture, not the host test module. Keep `expected` as an inferred template
value so simple literals such as `43` do not need to be written as strings.

Use module-scope imports in test helper modules. Do not use selective imports
such as:

```d
import ut.backends.pure_.fixtures: failingFixture;
```

Use this at most:

```d
import ut.backends.pure_.fixtures;
```

## Tests

Before changing production or fixture helper code, propose one test for
approval per the repo TDD rule.

The first approval test should migrate one existing negative fixture, such as
`intAdditionFailureMessage.0`, to the new helper and expect:

- the `.dmd` sentinel test is discovered by unit-threaded
- the backend test still fails with `42 != 43`
- `dmdFailureMessage` is the source of the expected diagnostic
- the generated fixture name keeps the backend last

Also add a small helper-level test for the `dmdFailureMessage` contract if the
first migrated fixture does not exercise it clearly:

- a fixture with exactly one hidden unittest returns its contextual message
- a fixture with two unittests fails at compile time via the `static assert`

After implementation, run `dub test`.

## Assumptions

The initial helper is only for equality failures. Non-equality helpers are out
of scope until an actual migrated fixture requires them.

The helper struct approach is acceptable for these expression fixtures even
though setup declarations become static struct members. If a later fixture
needs true module-scope lookup semantics, add a separate fixture style then.

The unittest configuration must compile with `-checkaction=context` so the
compiled-D sentinel observes contextual assertion messages.

Keep these shapes rejected:

- manual `version(...)` branches in each fixture
- `@ShouldFail` as the diagnostic oracle
- making the actual expression a template parameter
- asking fixture authors to write preformatted messages such as `"42 != 43"`
