module ut.backends.api.runner;


import ut.backends;
import quickbite.frontend.compiler: parseModule;
import std.conv: text;
import std.path: buildPath;


static foreach (backend; backendsWith!Interpreter) {
    @("runTests.runsAttributedUnittests." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            @("quickbite regression")
            unittest {
                assert(1 == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runTests.runsAttributedThrowingUnittests." ~ backend.stringof)
    unittest {
        const msg = runBackendSourceFixtureTests!backend(q{
            @("quickbite regression")
            unittest {
                throw new Exception("quickbite regression");
            }
        }).shouldThrow.msg;
        "quickbite regression".should.be in msg;
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runTests.importPathsRetryAfterFailure." ~ backend.stringof)
    unittest {

        with(immutable Sandbox()) {
            const importPath = "imports";
            const moduleName = text(
                "quickbite_backend_retry_import_",
                backend.stringof,
            );
            writeFile(
                buildPath(importPath, moduleName ~ ".d"),
                text(
                    "module ",
                    moduleName,
                    q{;
                    enum quickbiteRetryAnswer = 42;
                },
                ),
            );
            const source = text(
                "import ",
                moduleName,
                q{;
                unittest {
                    assert(quickbiteRetryAnswer == 42);
                }
            },
            );

            parseModule(source, []).shouldThrowWithMessage(
                "unable to read module `" ~ moduleName ~ "`\n" ~
                "unable to read module `" ~ moduleName ~ "`\n" ~
                "undefined identifier `quickbiteRetryAnswer`",
            );

            runBackendSourceFixtureTests!backend(source, [inSandboxPath(importPath)]);

        }
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runTestSummary.countsAttributedPassingAndFailingUnittests." ~
        backend.stringof)
    unittest {
        const summary = runBackendSourceFixtureTestSummary!backend(q{
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
        });

        summary.total.should == 3;
        summary.passed.should == 2;
        summary.failed.should == 1;
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runTestSummary.countsAllPassingUnittests." ~ backend.stringof)
    unittest {
        const summary = runBackendSourceFixtureTestSummary!backend(q{
            unittest {
                assert(1 == 1);
            }

            @("also passes")
            unittest {
                assert(2 == 2);
            }
        });

        summary.total.should == 2;
        summary.passed.should == 2;
        summary.failed.should == 0;
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runTestSummary.countsAssertErrorsAsFailures." ~ backend.stringof)
    unittest {
        const summary = runBackendSourceFixtureTestSummary!backend(q{
            import core.exception: AssertError;

            unittest {
                throw new AssertError("expected");
            }
        });

        summary.total.should == 1;
        summary.passed.should == 0;
        summary.failed.should == 1;
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runTestResults.reportsDmdUnittestSymbolNames." ~ backend.stringof)
    unittest {
        const result = runBackendSourceFixtureTestResults!backend(q{
            unittest {
                assert(1 == 1);
            }

            unittest {
                assert(1 == 2);
            }
        });

        result.cases.length.should == 2;
        result.cases[0].name.should == "__unittest_L2_C13";
        result.cases[1].name.should == "__unittest_L6_C13";
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runTestResults.reportsFileBackedUnittestLocations." ~
        backend.stringof)
    unittest {
        import unit_threaded.integration: Sandbox;

        with (immutable Sandbox()) {
            const fixtureName = text(
                "structured_result_locations_",
                backend.stringof,
                ".d",
            );
            writeFile(
                fixtureName,
                "unittest {\n" ~
                "    assert(1 == 2);\n" ~
                "}",
            );
            const fixturePath = inSandboxPath(fixtureName);

            const result = runBackendFileFixtureTestResults!backend(
                fixturePath,
                [],
            );

            result.cases.length.should == 1;
            result.cases[0].location.should == fixturePath ~ "(1)";
        }
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("runModulesTests.runsBothModules." ~ backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseModule;

        auto module1 = parseModule(q{
            unittest {
                assert(1 == 1);
            }
        }).module_;

        auto module2 = parseModule(q{
            unittest {
                throw new Exception("second module ran");
            }
        }).module_;

        auto backend_ = newBackend!backend;
        const msg = runModulesTests(backend_, [module1, module2,]).shouldThrow.msg;
        "second module ran".should.be in msg;
    }
}

static foreach (backend; backends) {
    @("runBackendSourceFixtureTests.withImportPaths." ~ backend.stringof)
    unittest {
        with(immutable Sandbox()) {
            const importPath = "backend-source-import-paths";
            writeFile(
                buildPath(importPath, "quickbite_backend_api_import.d"),
                q{
                    module quickbite_backend_api_import;
                    int importedValue() {
                        return 42;
                    }
                },
            );

            runBackendSourceFixtureTests!backend(
                q{
                    import quickbite_backend_api_import;

                    unittest {
                        assert(importedValue == 42);
                    }
                },
                [inSandboxPath(importPath)],
            );
        }
    }

    @("runBackendFileFixtureTests.withImportPaths." ~ backend.stringof)
    unittest {
        with(immutable Sandbox()) {
            const importPath = "backend-file-import-paths";
            writeFile(
                buildPath(importPath, "quickbite_backend_api_file_import.d"),
                q{
                    module quickbite_backend_api_file_import;
                    int importedValue() {
                        return 42;
                    }
                },
            );

            const fixturePath = buildPath(importPath, "fixture.d");
            writeFile(
                fixturePath,
                q{
                    import quickbite_backend_api_file_import;

                    unittest {
                        assert(importedValue == 42);
                    }
                },
            );

            runBackendFileFixtureTests!backend(
                inSandboxPath(fixturePath),
                [inSandboxPath(importPath)],
            );
        }
    }
}
