module ut.backends.runner.lang.module_state;


import ut.backends;


/++
    Module constructors and module-scope immutable state.
+/
// `Ctfe`, `Interpreter`, and `LLVMJit` all disagree with `SystemLinker` on
// every fixture in this module (issue #543, filed alongside these tests):
// `Ctfe` can never run a module constructor (CTFE evaluates one expression,
// not a module's startup sequence), so it is omitted `Because.inexpressible`;
// `Interpreter` and `LLVMJit` simply do not run module constructors yet, so
// they are omitted `Because.refusal`.

// A `shared static this()` runs once per process, before any unittest in
// the module, and its writes to a `__gshared` global are visible from a
// unittest that never itself assigns the global.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable `seed` cannot be read at compile time"),
    Omit!(Interpreter, Because.refusal, "0 != 42"),
    Omit!(LLVMJit, Because.refusal, "0 != 42"),
)) {
    @("moduleCtor.sharedStaticThisRunsBeforeTest." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            __gshared int seed;

            shared static this() {
                seed = 42;
            }

            unittest {
                assert(seed == 42);
            }
        });
    }
}

// The thread-local counterpart: `static this()` also runs once per process,
// before any unittest, and its writes to a thread-local global are visible
// from a unittest that never itself assigns the global.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable `seed` cannot be read at compile time"),
    Omit!(Interpreter, Because.refusal, "0 != 42"),
    Omit!(LLVMJit, Because.refusal, "0 != 42"),
)) {
    @("moduleCtor.staticThisRunsBeforeTest." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed;

            static this() {
                seed = 42;
            }

            unittest {
                assert(seed == 42);
            }
        });
    }
}

// A module constructor runs exactly once per process, regardless of how
// many unittest blocks the module has: two unittests each observe the same
// single increment, not one increment apiece.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable `runs` cannot be read at compile time"),
    Omit!(Interpreter, Because.refusal, "0 != 1"),
    Omit!(LLVMJit, Because.refusal, "0 != 1"),
)) {
    @("moduleCtor.runsOnceAcrossTests." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            __gshared int runs;

            shared static this() {
                ++runs;
            }

            unittest {
                assert(runs == 1);
            }

            unittest {
                assert(runs == 1);
            }
        });
    }
}

// A module-scope `immutable` variable with no initializer still gets
// storage, and a module constructor may assign it exactly once. Both taking
// its address and reading a field through that address, and reading a field
// straight off the variable, observe the module constructor's write.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable `_tab` cannot be read at compile time"),
    Omit!(Interpreter, Because.refusal,
        "field address has no composable native place: (*vtable()).x: "
        ~ "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression"),
    Omit!(LLVMJit, Because.refusal, "0 != 42"),
)) {
    @("moduleCtor.immutableGlobalAssignedInCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Tab {
                int x;
            }

            static immutable Tab _tab;

            shared static this() {
                _tab = Tab(42);
            }

            auto vtable() {
                return &_tab;
            }

            unittest {
                assert(vtable().x == 42);
                assert(_tab.x == 42);
            }
        });
    }
}

// The scalar counterpart of `immutableGlobalAssignedInCtor`: an
// uninitialized `immutable` scalar global, read directly (not through an
// address), still observes the module constructor's write.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable `answer` cannot be read at compile time"),
    Omit!(Interpreter, Because.refusal, "0 != 42"),
    Omit!(LLVMJit, Because.refusal, "0 != 42"),
)) {
    @("moduleCtor.immutableScalarAssignedInCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            static immutable int answer;

            shared static this() {
                answer = 42;
            }

            unittest {
                assert(answer == 42);
            }
        });
    }
}

// A module-scope `immutable` static array whose initializer is a literal
// of literals (`int[2][2] table = [[1, 2], [3, 4]];`) reads the same as
// any other module-scope `immutable`: indexing it twice reaches the
// initializer's own value.
static foreach (backend; Matrix!()) {
    @("immutableGlobal.nestedArrayInitializerRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            immutable int[2][2] table = [[1, 2], [3, 4]];

            unittest {
                int row = 1;
                assert(table[row][0] == 3);
            }
        });
    }
}

// A module-scope `immutable` with a constant initializer has exactly one
// storage location for the whole process: taking its address twice yields
// the same address both times, and an aggregate sibling's elements read
// back the initializer's own values.
static foreach (backend; Matrix!()) {
    @("immutableGlobal.constantInitializerHasStableAddress." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            immutable int answer = 42;
            immutable int[3] table = [1, 2, 3];

            unittest {
                const p = &answer;
                assert(*p == 42);
                assert(p is &answer);
                int index = 1;
                assert(table[index] == 2);
            }
        });
    }
}
