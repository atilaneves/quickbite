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


enum atoiSource = q{
    unittest {
        import core.stdc.stdlib: atoi;

        assert(atoi("12345".ptr) == 12345);
    }
};

// CTFE cannot call host libc; the Interpreter marshals the char array.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("atoi.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "atoi", atoiSource);
    }
}

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("atoi.value." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(atoiSource);
    }
}

enum strtolSource = q{
    unittest {
        import core.stdc.stdlib: strtol;

        const(char)* endptr;
        const value = strtol("123xyz".ptr, &endptr, 10);

        assert(value == 123);
        assert(*endptr == 'x');
    }
};

// CTFE cannot call host libc; the Interpreter writes the endptr out
// parameter back and dereferences the native char pointer.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("strtol.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "strtol", strtolSource);
    }
}

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("strtol.endptr." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(strtolSource);
    }
}

enum divSource = q{
    unittest {
        import core.stdc.stdlib: div;

        const result = div(7, 3);

        assert(result.quot == 2);
        assert(result.rem == 1);
    }
};

enum ldivSource = q{
    unittest {
        import core.stdc.stdlib: ldiv;

        const result = ldiv(10L, 4L);

        assert(result.quot == 2);
        assert(result.rem == 2);
    }
};

// CTFE rejects div: DMD CTFE has no host libc struct-return support.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("div.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "div", divSource);
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


enum callocZeroedSource = q{
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

enum reallocNullSource = q{
    unittest {
        import core.stdc.stdlib: realloc, free;

        auto ptr = cast(ubyte*) realloc(null, 8);
        scope(exit) free(ptr);

        assert(ptr !is null);

        ptr[7] = 0xaa;
        assert(ptr[7] == 0xaa);
    }
};

static foreach (backend; AliasSeq!(Bytecode, IR)) {

    @("calloc.multiArg.zeroedNativeMemory." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "calloc", callocZeroedSource);
    }

    @("realloc.null.pointerArgPointerReturn." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "realloc", reallocNullSource);
    }
}


static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {

    @("calloc.multiArg.zeroedNativeMemory." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(callocZeroedSource);
    }

    @("realloc.null.pointerArgPointerReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(reallocNullSource);
    }
}


enum reallocGrowSource = q{
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

// Bytecode/IR fail at the first malloc leaf; the Interpreter reaches realloc.
static foreach (backend; AliasSeq!(Bytecode, IR)) {

    @("realloc.grow.preservesNativeMemory." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "malloc", reallocGrowSource);
    }
}


static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {

    @("realloc.grow.preservesNativeMemory." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(reallocGrowSource);
    }
}


static foreach (backend; AliasSeq!(Bytecode, IR)) {

    @("div.structReturn." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "div", divSource);
    }

    @("ldiv.structReturn.longArgs." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "ldiv", ldivSource);
    }
}


static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {

    @("div.structReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(divSource);
    }

    @("ldiv.structReturn.longArgs." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(ldivSource);
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


// ffi.md §24.5 Phase 4: oracle-backed fixtures exercising shapes the
// descriptor-driven chokepoint already supports without a new code branch:
// wider scalars (labs), floating-point returns (atof/strtod), and an
// extern(C) call in a second module (core.stdc.ctype).
enum absSource = q{
    unittest {
        import core.stdc.stdlib: abs;

        int negative = -5;

        assert(abs(negative) == 5);
    }
};

enum labsSource = q{
    unittest {
        import core.stdc.stdlib: labs;

        long negative = -5_000_000_000L;

        assert(labs(negative) == 5_000_000_000L);
    }
};

enum ctypeSource = q{
    unittest {
        import core.stdc.ctype: toupper, tolower;

        int lower = 'a';
        int upper = 'Z';

        assert(toupper(lower) == 'A');
        assert(tolower(upper) == 'z');
    }
};

enum atofSource = q{
    unittest {
        import core.stdc.stdlib: atof;

        const value = atof("3.5".ptr);

        assert(value == 3.5);
    }
};

enum strtodSource = q{
    unittest {
        import core.stdc.stdlib: strtod;

        const(char)* endptr;
        const value = strtod("3.5xyz".ptr, &endptr);

        assert(value == 3.5);
        assert(*endptr == 'x');
    }
};

// CTFE cannot call host libc; each fixture reaches the body-less leaf.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("abs.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "abs", absSource);
    }
}

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("abs.scalar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(absSource);
    }
}


static foreach (backend; AliasSeq!(Ctfe)) {
    @("labs.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "labs", labsSource);
    }
}

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("labs.widerScalar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(labsSource);
    }
}


static foreach (backend; AliasSeq!(Ctfe)) {
    @("ctype.toupperTolower.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "toupper", ctypeSource);
    }
}

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("ctype.toupperTolower." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(ctypeSource);
    }
}


static foreach (backend; AliasSeq!(Ctfe)) {
    @("atof.floatReturn.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "atof", atofSource);
    }
}

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("atof.floatReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(atofSource);
    }
}


static foreach (backend; AliasSeq!(Ctfe)) {
    @("strtod.floatReturn.endptr.noSource." ~ backend.stringof)
    unittest {
        shouldFailNoSource!(backend, "strtod", strtodSource);
    }
}

static foreach (backend; AliasSeq!(Interpreter, SystemLinker, LLVMJit)) {
    @("strtod.floatReturn.endptr." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(strtodSource);
    }
}
