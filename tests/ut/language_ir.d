module ut.language_ir;

private:

import unit_threaded;
import quickbite: ExecutorBackend, runTests;

@("ir.structFieldReadWrite")
unittest {
    q{
        struct Foo { int x; }
        unittest {
            Foo f;
            f.x = 42;
            assert(f.x == 42);
        }
    }.runTests(ExecutorBackend.ir);
}
