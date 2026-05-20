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

            summary.total.shouldEqual(3);
            summary.passed.shouldEqual(2);
            summary.failed.shouldEqual(1);
        }
    }
}

@("runTestSummary.countsAllPassingUnittests")
unittest {
    import quickbite: ExecutorBackend, runTestSummary;
    import std.traits: EnumMembers;

    static foreach (backend; EnumMembers!ExecutorBackend) {
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

            summary.total.shouldEqual(2);
            summary.passed.shouldEqual(2);
            summary.failed.shouldEqual(0);
        }
    }
}

@("parseModule.countsAttributedUnittests")
unittest {
    import quickbite.dmd_util: foreachUnitTestDeclaration;
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
