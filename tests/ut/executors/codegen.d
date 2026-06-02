module ut.executors.codegen;


import ut.executors;


private:

import std.conv: text;

@("runTests.runsFailingPackageModuleUnittest")
unittest {
    if (experimentalExecutorTestsEnabled) {
        import quickbite: ExecutorName, runTests;

        // DMD codegen looks up the generated __modtest symbol by module
        // name; dotted module names catch silently-skipped unittests there.
        runTests(q{
            module quickbite_dmd_codegen_regression.package_module;

            unittest {
                assert(1 == 2, "Unittest assertion failed.");
            }
        }, ExecutorName.dmdCodegen).shouldThrowWithMessage(
            "Unittest assertion failed.",
        );
    }
}

@("runTests.catchesAssertWithoutMessage")
unittest {
    if (experimentalExecutorTestsEnabled) {
        import quickbite: ExecutorName, runTests;

        // A bare assert (no message) calls _d_unittestp in the D runtime, which
        // is a different code path from assert(cond, "msg"). This test confirms
        // that DMD codegen catches the resulting AssertError rather than
        // letting it abort the process.
        runTests(q{
            module quickbite_dmd_codegen_regression.assert_no_message;

            unittest {
                assert(1 == 2);
            }
        }, ExecutorName.dmdCodegen).shouldThrow;
    }
}

@("runTests.runsImportedSourceModules")
unittest {
    if (experimentalExecutorTestsEnabled) {
        import quickbite: ExecutorName, runTests;
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
        }, [importPath], ExecutorName.dmdCodegen);
    }
}

@("runTests.runsAssociativeArrayLiteral")
unittest {
    if (experimentalExecutorTestsEnabled) {
        import quickbite: ExecutorName, runTests;

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
        }, ExecutorName.dmdCodegen);
    }
}

@("runTestSummary.countsPassingSourceModule")
unittest {
    if (experimentalExecutorTestsEnabled) {
        import quickbite: ExecutorName, runTestSummary;

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
        }, ExecutorName.dmdCodegen);

        summary.total.should == 1;
        summary.passed.should == 1;
        summary.failed.should == 0;
    }
}

@("runTestSummary.countsFailingSourceModule")
unittest {
    if (experimentalExecutorTestsEnabled) {
        import quickbite: ExecutorName, runTestSummary;

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
        }, ExecutorName.dmdCodegen);

        summary.total.should == 1;
        summary.passed.should == 0;
        summary.failed.should == 1;
    }
}

@("moduleCanRunTwice.dmdCodegen")
unittest {
    if (experimentalExecutorTestsEnabled) {
        import quickbite.executors.dmd_codegen: DmdCodegen;
        import quickbite.frontend.compiler: parseModule;

        // Reusing a DMD module catches stale DMD codegen object state
        // between in-process codegen runs. Without the reset, DMD can carry
        // codegen symbols such as `__bzeroBytes` from the first object into
        // the second; the linker then rejects the generated objects before
        // the test runs.
        auto module_ = parseModule(q{
            int value() {
                return 42;
            }

            unittest {
                assert(value == 42);
            }
        }).module_;
        auto executorName = new DmdCodegen;

        executorName.runTests(module_);
        executorName.runTests(module_);
    }
}

static foreach (executorName; dmdCodegenRamExecutorNames) {
    @(text("ok.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    assert(answer == 42);
                }
            }, executorName);
        }
    }

    @(text("assertionContext.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int answer() {
                    return 42;
                }

                unittest {
                    int expected = 43;
                    assert(answer == expected);
                }
            }, executorName).shouldThrowWithMessage("42 != 43");
        }
    }

    @(text("throwingTest.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                unittest {
                    throw new Exception("boom");
                }
            }, executorName).shouldThrowWithMessage("boom");
        }
    }

    @(text("__gsharedIntRead.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                __gshared int value = 41;

                int answer() {
                    return value + 1;
                }

                unittest {
                    assert(answer == 42);
                }
            }, executorName);
        }
    }

    @(text("moduleIntRead.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int value = 41;

                int answer() {
                    // Unlike __gshared, default module variables are D TLS.
                    // The RAM executor must handle DMD's TLS relocation path
                    // instead of only the normal global/GOT access shape.
                    return value + 1;
                }

                unittest {
                    assert(answer == 42);
                }
            }, executorName);
        }
    }

    @(text("zeroInitializedModuleIntRead.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int value;

                int answer() {
                    return value + 1;
                }

                unittest {
                    assert(answer == 1);
                }
            }, executorName);
        }
    }

    @(text("userDefinedTlsGetAddrCall.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
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
            }, executorName);
        }
    }
}
