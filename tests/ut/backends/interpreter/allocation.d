module ut.backends.interpreter.allocation;


import ut;


// Repeated calls must reuse returned activation storage. The local verifies
// that reused bytes are zeroed, while recursion verifies that an active frame
// is never lent to its callee.
@("callLoop.reusesReturnedActivationStorage")
@Tags("Interpreter")
unittest {
    import core.memory: GC;
    import quickbite.backends.interpreter: Interpreter;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.conv: text;

    auto backend = new Interpreter;
    auto module_ = parseSnippetWithCheckActionContext(q{
        int recurse(in int depth) {
            int local;
            if (depth == 0)
                return local;
            local = depth;
            return local + recurse(depth - 1);
        }

        int bump(in int value) {
            int local;
            return value + local + 1;
        }

        unittest {
            assert(recurse(8) == 36);
            int total;
            foreach (_; 0 .. 20_000)
                total = bump(total);
            assert(total == 20_000);
        }
    }, []).module_;

    const before = GC.allocatedInCurrentThread;
    backend.runTests(module_)[0].passed.should == true;
    const allocated = GC.allocatedInCurrentThread - before;

    assert(allocated < 2 * 1024 * 1024, text("allocated ", allocated, " bytes"));
}
