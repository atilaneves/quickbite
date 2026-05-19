module ut.compiler_api;

private:

import unit_threaded;

@("parseModule.withImportPaths")
unittest {
    import quickbite.frontend.compiler: parseModule;
    import ut.dub_paths: dubImportPaths, cerealTestsDir;
    import std.file: readText;

    parseModule(readText(cerealTestsDir ~ "/utils.d"), dubImportPaths);
}

@("runTests.withImportPaths.dmdCtfe")
unittest {
    import quickbite: ExecutorBackend, runTestsFromFile;
    import ut.dub_paths: dubImportPaths, cerealTestsDir;

    runTestsFromFile(cerealTestsDir ~ "/utils.d", dubImportPaths, ExecutorBackend.dmdCtfe);
}

@("runTests.importPathsRetryAfterFailure")
unittest {
    import quickbite: ExecutorBackend, runTests;
    import quickbite.frontend.compiler: parseModule;
    import std.path: buildPath;
    import std.file: mkdirRecurse, write;

    const importPath = tempModuleDir("retry");
    mkdirRecurse(importPath);
    write(
        buildPath(importPath, "quickbite_retry_import.d"),
        q{
            module quickbite_retry_import;
            enum quickbiteRetryAnswer = 42;
        },
    );
    const source = q{
        import quickbite_retry_import;
        unittest {
            assert(quickbiteRetryAnswer == 42);
        }
    };

    parseModule(source, []).shouldThrowWithMessage(
        "DMD reported an error without a diagnostic message.",
    );
    runTests(source, [importPath], ExecutorBackend.dmdCtfe);
}

@("runTests.runsAttributedUnittests")
unittest {
    import quickbite: ExecutorBackend, runTests;
    import std.traits: EnumMembers;

    static foreach (backend; EnumMembers!ExecutorBackend) {
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

@("runTests.dmdBackendRunsFailingPackageModuleUnittest")
unittest {
    import quickbite: ExecutorBackend, runTests;

    // The DMD backend looks up the generated __modtest symbol by module
    // name; dotted module names catch silently-skipped unittests there.
    runTests(q{
        module quickbite_dmd_backend_regression.package_module;

        unittest {
            assert(1 == 2, "Unittest assertion failed.");
        }
    }, ExecutorBackend.dmdBackend).shouldThrowWithMessage(
        "Unittest assertion failed.",
    );
}

@("runTests.dmdBackendCatchesAssertWithoutMessage")
unittest {
    import quickbite: ExecutorBackend, runTests;

    // A bare assert (no message) calls _d_unittestp in the D runtime, which
    // is a different code path from assert(cond, "msg"). This test confirms
    // that the dmd backend catches the resulting AssertError rather than
    // letting it abort the process.
    runTests(q{
        module quickbite_dmd_backend_regression.assert_no_message;

        unittest {
            assert(1 == 2);
        }
    }, ExecutorBackend.dmdBackend).shouldThrow;
}

@("runTests.dmdBackendRejectsImportedSourceModules")
unittest {
    import quickbite: ExecutorBackend, runTests;
    import std.path: buildPath;
    import std.file: mkdirRecurse, write;

    const importPath = tempModuleDir("dmd-backend-imported-source");
    mkdirRecurse(importPath);
    write(
        buildPath(importPath, "quickbite_dmd_backend_imported_source.d"),
        q{
            module quickbite_dmd_backend_imported_source;

            int quickbiteImportedAnswer = 42;

            int importedAnswer() {
                return quickbiteImportedAnswer;
            }
        },
    );

    // The DMD backend currently compiles only the source module. Imported
    // source modules would need transitive object generation/linking, so keep
    // this explicitly unsupported until that backend grows that behavior.
    runTests(q{
        module quickbite_dmd_backend_regression.imported_source;

        import quickbite_dmd_backend_imported_source;

        unittest {
            assert(importedAnswer == 42);
        }
    }, [importPath], ExecutorBackend.dmdBackend).shouldThrowWithMessage(
        "DMD backend does not support imported source modules.",
    );
}

@("runTests.runsAttributedThrowingUnittests")
unittest {
    import quickbite: ExecutorBackend, runTests;
    import std.traits: EnumMembers;

    static foreach (backend; EnumMembers!ExecutorBackend) {
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
    import quickbite: ExecutorBackend, runTestSummary;
    import std.traits: EnumMembers;

    static foreach (backend; EnumMembers!ExecutorBackend) {
        // This generic test covers backends that execute unittest blocks
        // individually; the DMD backend is covered separately below.
        static if (backend != ExecutorBackend.dmdBackend) {
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
}

@("runTestSummary.countsAllPassingUnittests")
unittest {
    import quickbite: ExecutorBackend, runTestSummary;
    import std.traits: EnumMembers;

    static foreach (backend; EnumMembers!ExecutorBackend) {
        // DMD backend module-level reporting is tested separately below.
        static if (backend != ExecutorBackend.dmdBackend) {
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
}

@("runTestSummary.dmdBackendCountsPassingSourceModule")
unittest {
    import quickbite: ExecutorBackend, runTestSummary;

    // DMD's generated __modtest runner exposes one result for the whole source
    // module. Even with multiple passing unittest blocks, quickbite can only
    // report one passing module for this backend.
    const summary = runTestSummary(q{
        module quickbite_dmd_backend_summary.passing_module;

        unittest {
            assert(1 == 1);
        }

        @("also passes")
        unittest {
            assert(2 == 2);
        }
    }, ExecutorBackend.dmdBackend);

    summary.total.should == 1;
    summary.passed.should == 1;
    summary.failed.should == 0;
}

@("runTestSummary.dmdBackendCountsFailingSourceModule")
unittest {
    import quickbite: ExecutorBackend, runTestSummary;

    // __modtest aborts the module on the first failing unittest and does not
    // expose later block outcomes. The DMD backend therefore reports one
    // failing source module, not one pass plus one failure plus one skipped
    // block.
    const summary = runTestSummary(q{
        module quickbite_dmd_backend_summary.failing_module;

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
    }, ExecutorBackend.dmdBackend);

    summary.total.should == 1;
    summary.passed.should == 0;
    summary.failed.should == 1;
}

@("parseModule.countsAttributedUnittests")
unittest {
    import quickbite.frontend.util: foreachUnitTestDeclaration;
    import quickbite.frontend.compiler: parseModule;

    // auto: DMD owns mutable Module state.
    auto parsed = parseModule(q{
        unittest {
        }

        // The UDA makes DMD wrap the unittest in an AttribDeclaration, as
        // unit-threaded and cerealed tests do.
        @("quickbite regression")
        unittest {
        }
    });

    size_t count;
    foreachUnitTestDeclaration(parsed.module_, (unitTest) {
        ++count;
    });

    count.should == 2;
}

@("parseModule.importPathsDoNotLeak")
unittest {
    import quickbite.frontend.compiler: parseModule;
    import std.path: buildPath;
    import std.file: mkdirRecurse, write;

    const importPath = tempModuleDir("leak");
    mkdirRecurse(importPath);
    write(
        buildPath(importPath, "quickbite_leak_import_a.d"),
        q{
            module quickbite_leak_import_a;
            enum quickbiteLeakA = 42;
        },
    );
    write(
        buildPath(importPath, "quickbite_leak_import_b.d"),
        q{
            module quickbite_leak_import_b;
            enum quickbiteLeakB = 42;
        },
    );

    parseModule(q{
        import quickbite_leak_import_a;
        enum parsedWithPath = quickbiteLeakA;
    }, [importPath]);

    const source = q{
        import quickbite_leak_import_b;
        enum parsedWithoutPath = quickbiteLeakB;
    };
    parseModule(source, []).shouldThrowWithMessage(
        "DMD reported an error without a diagnostic message.",
    );
}

private string tempModuleDir(in string suffix) {
    import std.path: buildPath;
    import std.file: tempDir;

    return buildPath(tempDir, "quickbite-compiler-api", suffix);
}
