module ut.backends.runner.lang.callable_identity;


import ut.backends;


// A function pointer copied into a second variable stays the same callable
// identity; a function pointer to a different function is a different
// identity; an unset function pointer is `null`. `SystemLinker` is the
// oracle: a function pointer's identity is its code address.
static foreach (backend; Matrix!()) {
    @("pointer.functionPointerIdentityComparesSameDifferentAndNull." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int increment(int seed) {
                return seed + 1;
            }

            int decrement(int seed) {
                return seed - 1;
            }

            unittest {
                int function(int) a = &increment;
                int function(int) b = a;
                int function(int) c = &decrement;
                int function(int) none;

                assert(a is b);
                assert(a == b);
                assert(a !is c);
                assert(a != c);
                assert(none is null);
                assert(a !is null);
            }
        });
    }
}

// Writing a union's non-callable sibling overwrites a stored function
// pointer's bytes; re-storing the function pointer afterwards makes the slot
// callable again. `SystemLinker` is the oracle.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "DMD CTFE rejects reads through an overlapping union member"),
)) {
    @("union.functionPointerOverwrittenBySiblingThenRestoredIsCallable." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int increment(int seed) {
                return seed + 1;
            }

            union Slot {
                int function(int) callback;
                long bits;
            }

            unittest {
                Slot slot;
                slot.callback = &increment;
                assert(slot.callback(41) == 42);

                slot.bits = 0;
                assert(slot.callback is null);

                slot.callback = &increment;
                assert(slot.callback(41) == 42);
            }
        });
    }
}

// The delegate sibling of the fixture above: writing a union's non-callable
// sibling overwrites a stored delegate's bytes; re-storing the delegate
// afterwards makes the slot callable again, still bound to its original
// receiver. `SystemLinker` is the oracle.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "DMD CTFE rejects reads through an overlapping union member"),
    Omit!(Bytecode, Because.unconfirmed,
        "Bytecode loses a delegate's receiver when stored through a union "
        ~ "member: `slot.callback()` throws \"class `this` is `null`\" "
        ~ "immediately after `slot.callback = &counter.increment`, before "
        ~ "any sibling-member overwrite; independent of the "
        ~ "Interpreter-only fix this fixture targets"),
)) {
    @("union.delegateOverwrittenBySiblingThenRestoredIsCallable." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Counter {
                int value;

                int increment() {
                    return ++value;
                }
            }

            union Slot {
                int delegate() callback;
                long[2] bits;
            }

            unittest {
                auto counter = new Counter;
                Slot slot;
                slot.callback = &counter.increment;
                assert(slot.callback() == 1);

                slot.bits[] = 0;
                assert(slot.callback is null);

                slot.callback = &counter.increment;
                assert(slot.callback() == 2);
            }
        });
    }
}
