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
