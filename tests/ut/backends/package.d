module ut.backends;


public import ut;
public import quickbite.executor;
public import quickbite: ExecutorBackend;


private:

import quickbite: ExecutorBackend;

public enum matureExecutorBackends = [
    ExecutorBackend.ir,
    ExecutorBackend.treeWalkingOld,
    ExecutorBackend.dmdCtfe,
];

public enum dmdCodegenRamExecutorBackends = [
    ExecutorBackend.dmdCodegenRam,
];

public enum evalBackends = [
    ExecutorBackend.ir,
    ExecutorBackend.treeWalkingOld,
    ExecutorBackend.treeWalking,
    ExecutorBackend.dmdCtfe,
    ExecutorBackend.bytecode,
];

public bool experimentalBackendTestsEnabled() {
    import std.process: environment;

    return environment.get("QUICKBITE_EXPERIMENTAL_BACKEND_TESTS").length != 0;
}

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


@("runTests.runsAttributedUnittests")
unittest {
    import quickbite: runTests;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                // The UDA makes DMD wrap the unittest in an AttribDeclaration,
                // as unit-threaded and cerealed tests do.
                @("quickbite regression")
                unittest {
                    assert(1 == 2);
                }
            }, backend).shouldThrow;
        }
    }
}


@("runTests.runsAttributedThrowingUnittests")
unittest {
    import quickbite: runTests;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                // The UDA makes DMD wrap the unittest in an AttribDeclaration,
                // as unit-threaded and cerealed tests do.
                @("quickbite regression")
                unittest {
                    throw new Exception("quickbite regression");
                }
            }, backend).shouldThrow;
        }
    }
}

@("runTestSummary.countsAttributedPassingAndFailingUnittests")
unittest {
    import quickbite: runTestSummary;

    static foreach (backend; matureExecutorBackends) {
        {
            const summary = runTestSummary(q{
                @("passes")
                unittest {
                    assert(1 == 1);
                }

                @("fails")
                unittest {
                    assert(1 == 2);
                }

                unittest {
                    assert(2 == 2);
                }
            }, backend);

            summary.total.should == 3;
            summary.passed.should == 2;
            summary.failed.should == 1;
        }
    }
}

@("runTestSummary.countsAllPassingUnittests")
unittest {
    import quickbite: runTestSummary;

    static foreach (backend; matureExecutorBackends) {
        {
            const summary = runTestSummary(q{
                unittest {
                    assert(1 == 1);
                }

                @("also passes")
                unittest {
                    assert(2 == 2);
                }
            }, backend);

            summary.total.should == 2;
            summary.passed.should == 2;
            summary.failed.should == 0;
        }
    }
}

@("runModulesTests.runsBothModules")
unittest {
    import quickbite.executor: runModulesTests;
    import quickbite.frontend.compiler: parseModule;
    import quickbite: executor;

    auto module1 = parseModule(q{ // auto: DMD owns mutable Module state
        unittest {
            assert(1 == 1);
        }
    }).module_;

    auto module2 = parseModule(q{ // auto: DMD owns mutable Module state
        unittest {
            throw new Exception("second module ran");
        }
    }).module_;

    static foreach (backend; matureExecutorBackends) {
        {
            executor(backend).runModulesTests([module1, module2,]).shouldThrowWithMessage(
                "second module ran",
            );
        }
    }
}
