module ut.backends.codegen;


import ut.backends;


private:

import std.conv: text;

@("minicerealFileCanRunTwice.dmdCodegen")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite.backends.dmd_codegen: DmdCodegen;
        import quickbite.frontend.compiler: parseModule;
        import std.file: readText;

        // Reusing a parsed module catches stale DMD codegen object state
        // between in-process codegen runs. Without the reset, DMD can carry
        // backend symbols such as `__bzeroBytes` from the first object into
        // the second; the linker then rejects the generated objects before
        // the test runs.
        auto module_ = parseModule(readText("tests/minicereal.d")).module_;
        auto backend = new DmdCodegen;

        backend.runParsedTests(module_);
        backend.runParsedTests(module_);
    }
}

static foreach (backend; dmdCodegenRamExecutorBackends) {
    @(text("ok.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 42);
                }
            }, backend);
        }
    }

    @(text("assertionContext.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    int expected = 43;
                    assert(answer == expected);
                }
            }, backend).shouldThrowWithMessage("42 != 43");
        }
    }

    @(text("throwingTest.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                unittest {
                    throw new Exception("boom");
                }
            }, backend).shouldThrowWithMessage("boom");
        }
    }

    @(text("__gsharedIntRead.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                __gshared int value = 41;

                int answer() {
                    return value + 1;
                }

                unittest {
                    assert(answer == 42);
                }
            }, backend);
        }
    }

    @(text("moduleIntRead.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int value = 41;

                int answer() {
                    // Unlike __gshared, default module variables are D TLS.
                    // The RAM backend must handle DMD's TLS relocation path
                    // instead of only the normal global/GOT access shape.
                    return value + 1;
                }

                unittest {
                    assert(answer == 42);
                }
            }, backend);
        }
    }

    @(text("zeroInitializedModuleIntRead.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int value;

                int answer() {
                    return value + 1;
                }

                unittest {
                    assert(answer == 1);
                }
            }, backend);
        }
    }

    @(text("userDefinedTlsGetAddrCall.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                __gshared int calls;

                extern(C) void __tls_get_addr() {
                    calls = 41;
                }

                void answer() {
                    __tls_get_addr();
                }

                unittest {
                    calls = 1;
                    answer();
                    assert(calls == 41);
                }
            }, backend);
        }
    }
}
