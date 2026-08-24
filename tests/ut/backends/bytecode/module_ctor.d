module ut.backends.bytecode.module_ctor;


import ut;
import ut.backends;


// A module constructor must run exactly once per (backend instance, module)
// pair, not once per `runTests` call: the benchmark harness calls
// `runTests` repeatedly on the same instance and module (warmup plus
// measured runs), and dataseg state a module constructor writes to must
// stay at its once-run value across those repeated calls, the same way a
// compiled D program's module constructor runs once per process no matter
// how many times a caller re-enters the module's code.
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
