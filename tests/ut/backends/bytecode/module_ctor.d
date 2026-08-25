module ut.backends.bytecode.module_ctor;


import ut;
import ut.backends;


// Each `runTests` call is a fresh process: module storage resets to its
// registration-time bytes and the module's constructors run again, so a
// `__gshared` counter a `shared static this()` increments reads back the
// same once-run value on every call, the same way a compiled D program's
// module constructor runs exactly once during a single process's startup.
@("runTests.moduleCtorRunsOnceAcrossRepeatedCalls")
@Tags("Bytecode")
unittest {
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

    auto backend = new Bytecode;
    auto module_ = parseSnippetWithCheckActionContext(q{
        __gshared int runs;

        shared static this() {
            ++runs;
        }

        unittest {
            assert(runs == 1);
        }
    }, []).module_;

    backend.runTests(module_)[0].passed.should == true;
    backend.runTests(module_)[0].passed.should == true;
}

// A module constructor that fails leaves the module unconstructed: a later
// run attempts it again and fails again instead of treating the module as
// constructed.
@("runTests.throwingModuleCtorFailsEveryRun")
@Tags("Bytecode")
unittest {
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

    auto backend = new Bytecode;
    auto module_ = parseSnippetWithCheckActionContext(q{
        shared static this() {
            int zero = 0;
            assert(zero == 1, "module constructor failed");
        }

        unittest {
        }
    }, []).module_;

    backend.runTests(module_).shouldThrow;
    backend.runTests(module_).shouldThrow;
}

// An `immutable` global with no initializer of its own, assigned only by a
// module constructor, must read back the ctor-assigned value on every
// `runTests` call: module storage resets to its registration-time (still
// unassigned) bytes before each call's constructors run, so the second
// call's reset must not leave the first call's write behind uninitialised.
@("runTests.moduleCtorWrittenImmutableSurvivesRepeatedCalls")
@Tags("Bytecode")
unittest {
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

    auto backend = new Bytecode;
    auto module_ = parseSnippetWithCheckActionContext(q{
        immutable int x;

        shared static this() {
            x = 42;
        }

        unittest {
            assert(x == 42);
        }
    }, []).module_;

    backend.runTests(module_)[0].passed.should == true;
    backend.runTests(module_)[0].passed.should == true;
}
