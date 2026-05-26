module ut.backends.api;


import ut.backends;


private:

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

@("runTests.withImportPaths")
unittest {
    import quickbite: runTestsFromFile;
    import ut.dub_paths: dubImportPaths, cerealTestsDir;

    static foreach (backend; matureExecutorBackends) {
        {
            runTestsFromFile(cerealTestsDir ~ "/utils.d", dubImportPaths, backend);
        }
    }
}

@("runTests.importPathsRetryAfterFailure")
unittest {
    import quickbite: runTests;
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
        "unable to read module `quickbite_retry_import`\nunable to read module `quickbite_retry_import`\nundefined identifier `quickbiteRetryAnswer`",
    );

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(source, [importPath], backend);
        }
    }
}

@("runTests.dmdCtfeFallbackReportsFailingUnittest")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        void set(out int x) {
            x = 42;
        }

        unittest {
            int x;
            set(x);
            assert(x == 42);
        }

        bool nope() {
            return false;
        }

        void fail() {
            assert(nope());
        }

        unittest {
            fail();
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("false != true");
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

@("runTestSummary.countsAssertErrorsAsFailures")
unittest {
    import quickbite: runTestSummary;

    static foreach (backend; matureExecutorBackends) {
        {
            const summary = runTestSummary(q{
                import core.exception: AssertError;

                unittest {
                    throw new AssertError("expected");
                }
            }, backend);

            summary.total.should == 1;
            summary.passed.should == 0;
            summary.failed.should == 1;
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
