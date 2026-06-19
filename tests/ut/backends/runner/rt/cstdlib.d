module ut.backends.runner.rt.cstdlib;


import ut.backends;


private enum noSource(string name) =
    "`" ~ name ~ "` cannot be interpreted at compile time, " ~
    "because it has no available source code";

private void shouldFailNoSource
    (alias backend, string name, string source)
    (in string file = __FILE__, in size_t line = __LINE__)
{
    runBackendSourceFixtureTests!backend(source)
        .shouldThrowWithMessage(noSource!name, file, line);
}


// CTFE should stay pure: no host libc calls.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("malloc.noSource." ~ backend.stringof)
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

        shouldFailNoSource!(backend, "malloc", source);
    }

    @("free.noSource." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: free;

                free(null);
            }
        };

        shouldFailNoSource!(backend, "free", source);
    }
}


static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("atoi.noSource." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: atoi;

                assert(atoi("12345".ptr) == 12345);
            }
        };

        shouldFailNoSource!(backend, "atoi", source);
    }

    @("strtol.noSource." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: strtol;

                const(char)* endptr;
                const value = strtol("123xyz".ptr, &endptr, 10);

                assert(value == 123);
                assert(*endptr == 'x');
            }
        };

        shouldFailNoSource!(backend, "strtol", source);
    }

    @("div.noSource." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: div;

                const result = div(7, 3);

                assert(result.quot == 2);
                assert(result.rem == 1);
            }
        };

        shouldFailNoSource!(backend, "div", source);
    }
}


static foreach (backend; AliasSeq!(Interpreter)) {
    @("free.null.voidReturn." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: free;

                free(null);

                assert(true);
            }
        };

        runBackendSourceFixtureTests!backend(source);
    }
}


static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("malloc.pointerRoundTrip." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: malloc, free;

                auto ptr = malloc(8);

                assert(ptr !is null);

                free(ptr);
            }
        };

        runBackendSourceFixtureTests!backend(source);
    }
}


// Design-driving expected-failure tests for a future host FFI bridge.
//
// These only include fixtures that currently reach the extern(C) libc call
// before failing. Do not add tests that first fail on unrelated frontend /
// backend gaps such as string-literal pointer lowering, local pointer out
// params, symbolOffset, array initializers, or callbacks.
static foreach (backend; AliasSeq!(Bytecode, IR)) {
    @("free.null.voidReturn." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: free;

                free(null);

                assert(true);
            }
        };

        shouldFailNoSource!(backend, "free", source);
    }

    @("malloc.pointerReturn.nativeMemory." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: malloc, free;

                auto ptr = cast(ubyte*) malloc(8);
                scope(exit) free(ptr);

                assert(ptr !is null);

                ptr[0] = 0x11;
                ptr[7] = 0xff;

                assert(ptr[0] == 0x11);
                assert(ptr[7] == 0xff);
                assert(ptr[7] != 0);
            }
        };

        shouldFailNoSource!(backend, "malloc", source);
    }
}


static foreach (backend; AliasSeq!(Interpreter)) {
    @("malloc.pointerReturn.nativeMemory." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: malloc, free;

                auto ptr = cast(ubyte*) malloc(8);
                scope(exit) free(ptr);

                assert(ptr !is null);

                ptr[0] = 0x11;
                ptr[7] = 0xff;

                assert(ptr[0] == 0x11);
                assert(ptr[7] == 0xff);
                assert(ptr[7] != 0);
            }
        };

        runBackendSourceFixtureTests!backend(source);
    }
}


static foreach (backend; AliasSeq!(Interpreter, Bytecode, IR)) {

    @("calloc.multiArg.zeroedNativeMemory." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: calloc, free;

                auto ptr = cast(ubyte*) calloc(4, 2);
                scope(exit) free(ptr);

                assert(ptr !is null);

                foreach (i; 0 .. 8)
                    assert(ptr[i] == 0);

                ptr[7] = 0xaa;
                assert(ptr[7] == 0xaa);
            }
        };

        shouldFailNoSource!(backend, "calloc", source);
    }

    @("realloc.null.pointerArgPointerReturn." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: realloc, free;

                auto ptr = cast(ubyte*) realloc(null, 8);
                scope(exit) free(ptr);

                assert(ptr !is null);

                ptr[7] = 0xaa;
                assert(ptr[7] == 0xaa);
            }
        };

        shouldFailNoSource!(backend, "realloc", source);
    }
}


static foreach (backend; AliasSeq!(Bytecode, IR)) {

    @("realloc.grow.preservesNativeMemory." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: malloc, realloc, free;

                auto ptr = cast(ubyte*) malloc(4);
                assert(ptr !is null);

                ptr[0] = 10;
                ptr[1] = 20;
                ptr[2] = 30;
                ptr[3] = 40;

                ptr = cast(ubyte*) realloc(ptr, 8);
                scope(exit) free(ptr);

                assert(ptr !is null);

                assert(ptr[0] == 10);
                assert(ptr[1] == 20);
                assert(ptr[2] == 30);
                assert(ptr[3] == 40);

                ptr[7] = 80;
                assert(ptr[7] == 80);
            }
        };

        shouldFailNoSource!(backend, "malloc", source);
    }
}


static foreach (backend; AliasSeq!(Interpreter)) {
    @("realloc.grow.preservesNativeMemory." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: malloc, realloc, free;

                auto ptr = cast(ubyte*) malloc(4);
                assert(ptr !is null);

                ptr[0] = 10;
                ptr[1] = 20;
                ptr[2] = 30;
                ptr[3] = 40;

                ptr = cast(ubyte*) realloc(ptr, 8);
                scope(exit) free(ptr);

                assert(ptr !is null);

                assert(ptr[0] == 10);
                assert(ptr[1] == 20);
                assert(ptr[2] == 30);
                assert(ptr[3] == 40);

                ptr[7] = 80;
                assert(ptr[7] == 80);
            }
        };

        shouldFailNoSource!(backend, "realloc", source);
    }
}


static foreach (backend; AliasSeq!(Interpreter, Bytecode, IR)) {

    @("div.structReturn." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: div;

                const result = div(7, 3);

                assert(result.quot == 2);
                assert(result.rem == 1);
            }
        };

        shouldFailNoSource!(backend, "div", source);
    }

    @("ldiv.structReturn.longArgs." ~ backend.stringof)
    unittest {
        enum source = q{
            unittest {
                import core.stdc.stdlib: ldiv;

                const result = ldiv(10L, 4L);

                assert(result.quot == 2);
                assert(result.rem == 2);
            }
        };

        shouldFailNoSource!(backend, "ldiv", source);
    }
}

// Compiled code calls the real malloc and the fixture passes; the diagnostic
// above is interpretation-only. LLVMJit is promoted alongside SystemLinker
// (its single behaviour oracle) on this surviving rt/ block: a real runtime
// libc malloc call through the in-process JIT.
static foreach (backend; AliasSeq!(SystemLinker, LLVMJit)) {
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
