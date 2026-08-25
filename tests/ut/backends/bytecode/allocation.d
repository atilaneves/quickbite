module ut.backends.bytecode.allocation;


import ut;
import ut.backends;


// A guest loop of N calls must not allocate in proportion to N: at this
// call count, per-call allocation shows up as megabytes, while a
// steady-state re-run of a module's tests stays well under one.
@("callLoop.doesNotAllocatePerCall")
@Tags("Bytecode")
unittest {
    import core.memory: GC;
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.conv: text;

    auto backend = new Bytecode;
    auto module_ = parseSnippetWithCheckActionContext(q{
        int bump(in int value) { return value + 1; }

        unittest {
            int total;
            foreach (i; 0 .. 100_000)
                total = bump(total);
            assert(total == 100_000);
        }
    }, []).module_;

    // The first run pays lazy compilation and warm-up allocations.
    backend.runTests(module_)[0].passed.should == true;

    const before = GC.stats.allocatedInCurrentThread;
    backend.runTests(module_)[0].passed.should == true;
    const allocated = GC.stats.allocatedInCurrentThread - before;

    assert(allocated < 1024 * 1024, text("allocated ", allocated, " bytes"));
}

@("repeatedRunResetsModuleStorage")
@Tags("Bytecode")
unittest {
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

    auto backend = new Bytecode;
    auto module_ = parseSnippetWithCheckActionContext(q{
        int[] values;

        unittest {
            values ~= 2;
            assert(values == [2]);
        }
    }, []).module_;

    backend.runTests(module_)[0].passed.should == true;
    backend.runTests(module_)[0].passed.should == true;
}
