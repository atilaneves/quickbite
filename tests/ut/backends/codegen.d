module ut.backends.codegen;


import ut.backends;


private:

import std.conv: text;

@("runTests.runsFailingPackageModuleUnittest")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite: ExecutorBackend, runTests;

        // DMD codegen looks up the generated __modtest symbol by module
        // name; dotted module names catch silently-skipped unittests there.
        runTests(q{
            module quickbite_dmd_codegen_regression.package_module;

            unittest {
                assert(1 == 2, "Unittest assertion failed.");
            }
        }, ExecutorBackend.dmdCodegen).shouldThrowWithMessage(
            "Unittest assertion failed.",
        );
    }
}

@("runTests.catchesAssertWithoutMessage")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite: ExecutorBackend, runTests;

        // A bare assert (no message) calls _d_unittestp in the D runtime, which
        // is a different code path from assert(cond, "msg"). This test confirms
        // that DMD codegen catches the resulting AssertError rather than
        // letting it abort the process.
        runTests(q{
            module quickbite_dmd_codegen_regression.assert_no_message;

            unittest {
                assert(1 == 2);
            }
        }, ExecutorBackend.dmdCodegen).shouldThrow;
    }
}

@("runTests.runsImportedSourceModules")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite: ExecutorBackend, runTests;
        import std.path: buildPath;
        import std.file: mkdirRecurse, write;

        const importPath = tempModuleDir("dmd-codegen-imported-source");
        mkdirRecurse(importPath);
        write(
            buildPath(importPath, "quickbite_dmd_codegen_imported_leaf.d"),
            q{
                module quickbite_dmd_codegen_imported_leaf;

                int quickbiteImportedAnswer = 42;
            },
        );
        write(
            buildPath(importPath, "quickbite_dmd_codegen_imported_source.d"),
            q{
                module quickbite_dmd_codegen_imported_source;

                import quickbite_dmd_codegen_imported_leaf;

                int importedAnswer() {
                    return quickbiteImportedAnswer;
                }
            },
        );

        runTests(q{
            module quickbite_dmd_codegen_regression.imported_source;

            import quickbite_dmd_codegen_imported_source;

            unittest {
                assert(importedAnswer == 42);
            }
        }, [importPath], ExecutorBackend.dmdCodegen);
    }
}

@("runTests.runsAssociativeArrayLiteral")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite: ExecutorBackend, runTests;

        // Associative-array literals instantiate druntime template support
        // that normal DMD codegen must emit into the generated object set. In
        // Quickbite's long-lived DMD process, an earlier semantic pass can
        // leave the shared template cache looking as if that support belongs
        // to a non-root module; without DMD's linkability-focused codegen mode,
        // the generated unittest keeps unresolved references and dlopen fails.
        runTests(q{
            module quickbite_dmd_codegen_regression.associative_array_literal;

            unittest {
                auto map = [5: 105];
                assert(map[5] == 105);
            }
        }, ExecutorBackend.dmdCodegen);
    }
}

@("runTestSummary.countsPassingSourceModule")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite: ExecutorBackend, runTestSummary;

        // DMD's generated __modtest runner exposes one result for the whole
        // source module. Even with multiple passing unittest blocks, quickbite
        // can only report one passing module for DMD codegen.
        const summary = runTestSummary(q{
            module quickbite_dmd_codegen_summary.passing_module;

            unittest {
                assert(1 == 1);
            }

            @("also passes")
            unittest {
                assert(2 == 2);
            }
        }, ExecutorBackend.dmdCodegen);

        summary.total.should == 1;
        summary.passed.should == 1;
        summary.failed.should == 0;
    }
}

@("runTestSummary.countsFailingSourceModule")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite: ExecutorBackend, runTestSummary;

        // __modtest aborts the module on the first failing unittest and does
        // not expose later block outcomes. DMD codegen therefore reports
        // one failing source module, not one pass plus one failure plus one
        // skipped block.
        const summary = runTestSummary(q{
            module quickbite_dmd_codegen_summary.failing_module;

            unittest {
                assert(1 == 1);
            }

            @("fails")
            unittest {
                assert(1 == 2);
            }

            unittest {
                assert(3 == 3);
            }
        }, ExecutorBackend.dmdCodegen);

        summary.total.should == 1;
        summary.passed.should == 0;
        summary.failed.should == 1;
    }
}

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
