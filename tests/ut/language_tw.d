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
