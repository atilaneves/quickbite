module ut.backends.runtime.cstdlib;


import ut.backends;


static foreach (backend; backendsWith!Interpreter) {
    @("malloc." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: malloc, free;
                auto ptr = cast(ubyte*) malloc(8);
                scope(exit) free(ptr);
                ptr[7] = 0xff;
                assert(ptr[7] == 0xff);
                assert(ptr[7] != 0);
            }
        };

        static if (is(backend == Ctfe)) {
            const msg =
                "`malloc` cannot be interpreted at compile time, " ~
                "because it has no available source code";
            runBackendSourceFixtureTests!backend(source)
                .shouldThrowWithMessage(msg);
        } else {
            runBackendSourceFixtureTests!backend(source);
        }
    }
}
