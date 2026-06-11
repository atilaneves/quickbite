module ut.backends.runner.rt.cstdlib;


import ut.backends;


static foreach (backend; AliasSeq!(Ctfe, Interpreter, Bytecode, IR)) {
    @("malloc." ~ backend.stringof)
    unittest {
        const msg =
            "`malloc` cannot be interpreted at compile time, " ~
            "because it has no available source code";
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

        runBackendSourceFixtureTests!backend(source).shouldThrowWithMessage(msg);
    }
}

// Compiled code calls the real malloc and the fixture passes; the diagnostic
// above is interpretation-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("malloc." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                import core.stdc.stdlib: malloc, free;
                auto ptr = cast(ubyte*) malloc(8);
                scope(exit) free(ptr);
                ptr[7] = 0xff;
                assert(ptr[7] == 0xff);
                assert(ptr[7] != 0);
            }
        });
    }
}
