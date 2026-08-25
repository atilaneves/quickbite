module ut.backends.bytecode.module_ctor;


import ut;
import ut.backends;


// Each `runTests` call behaves like a fresh process: the module's
// constructors run again, so a `__gshared` counter a `shared static
// this()` increments reads back the same once-run value on every call, the
// same way a compiled D program's module constructor runs exactly once
// during a single process's startup.
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
// `runTests` call: each call behaves like a fresh process, its
// constructors running against the global's still-unassigned starting
// value, so the second call must not leave the first call's write behind
// uninitialised.
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

// A compile that registers a module variable (growing `moduleData`) and
// then fails on a later, unrelated statement must fail the same way on
// every call, not just the first: the failed compile must not leave
// `moduleData` longer than the registration-time snapshot `resetModuleData`
// resets it to on the next call.
@("runTests.compileFailureAfterModuleVariableRegistrationRepeatsOnRerun")
@Tags("Bytecode")
unittest {
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

    auto backend = new Bytecode;
    auto module_ = parseSnippetWithCheckActionContext(q{
        __gshared int x;
        struct C { cdouble z; }
        __gshared C c;

        unittest {
            x = 1;
            assert(c.z != c.z);
        }
    }, []).module_;

    const first = backend.runTests(module_)[0];
    const second = backend.runTests(module_)[0];

    first.passed.should == false;
    second.passed.should == false;
    second.message.should == first.message;
}
