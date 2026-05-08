module ut.language_tw;

private:

import unit_threaded;
import quickbite: ExecutorBackend, runTests;

@("tw.structFieldReadWrite")
unittest {
    q{
        struct Foo { int x; }
        unittest {
            Foo f;
            f.x = 42;
            assert(f.x == 42);
        }
    }.runTests(ExecutorBackend.treeWalking);
}

// processFile must strip `pure` from `@safe pure unittest` and
// `pure @safe unittest` so that non-pure library functions (e.g.
// cerealise) can be called from unittest blocks without a
// "pure function cannot call impure" compile error.
@("cerealed.processFile.stripsPureFromUnittest")
unittest {
    import ut.cerealed: processFilePackage;
    import std.algorithm: canFind;

    const input =
        "@safe pure unittest { assert(true); }\n" ~
        "pure @safe unittest { assert(true); }\n" ~
        "@safe unittest { assert(true); }\n";
    const output = processFilePackage(input);
    output.canFind("@safe pure unittest").shouldEqual(false);
    output.canFind("pure @safe unittest").shouldEqual(false);
    output.canFind("pure unittest").shouldEqual(false);
}

// DMD-as-library must be able to compile code that uses dynamic array
// length assignment.  Previously this failed with
// `object._d_arraysetlengthTImpl not found` because the druntime
// import path pointed to an older system druntime that lacked the hook.
// The dmdCtfe backend compiles and CTFE-evaluates the code, so it can
// verify that both compilation and basic execution succeed.
@("cerealed.dmdCtfe.dynamicArrayLengthCompiles")
unittest {
    q{
        unittest {
            int[] arr;
            arr.length = 3;
            assert(arr.length == 3);
        }
    }.runTests(ExecutorBackend.dmdCtfe);
}
