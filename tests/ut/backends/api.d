module ut.backends.api;


import ut.backends;
import std.algorithm.searching: canFind;
import std.file: mkdirRecurse, write;
import std.path: buildPath;


private:

static foreach (backend; backends) {
    @("runTests.runsAttributedUnittests." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            @("quickbite regression")
            unittest {
                assert(1 == 2);
            }
        }).shouldThrow;
    }

    @("runTests.runsAttributedThrowingUnittests." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            @("quickbite regression")
            unittest {
                throw new Exception("quickbite regression");
            }
        }).shouldThrow.msg.canFind("quickbite regression").should == true;
    }

    @("runTests.importPathsRetryAfterFailure." ~ backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseModule;

        const importPath = tempModuleDir("backend-retry");
        mkdirRecurse(importPath);
        write(
            buildPath(importPath, "quickbite_backend_retry_import.d"),
            q{
                module quickbite_backend_retry_import;
                enum quickbiteRetryAnswer = 42;
            },
        );
        const source = q{
            import quickbite_backend_retry_import;
            unittest {
                assert(quickbiteRetryAnswer == 42);
            }
        };

        parseModule(source, []).shouldThrowWithMessage(
            "unable to read module `quickbite_backend_retry_import`\n" ~
            "unable to read module `quickbite_backend_retry_import`\n" ~
            "undefined identifier `quickbiteRetryAnswer`",
        );

        runBackendSourceFixtureTests!backend(source, [importPath]);
    }

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

    @("runTestResults.reportsFileBackedUnittestLocations." ~
        backend.stringof)
    unittest {
        import unit_threaded.integration: Sandbox;

        with (immutable Sandbox()) {
            writeFile(
                "structured_result_locations.d",
                "unittest {\n" ~
                "    assert(1 == 2);\n" ~
                "}",
            );
            const fixturePath = inSandboxPath(
                "structured_result_locations.d",
            );

            const result = runBackendFileFixtureTestResults!backend(
                fixturePath,
                [],
            );

            result.cases.length.should == 1;
            result.cases[0].location.should == fixturePath ~ "(1)";
        }
    }

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
        runModulesTests(backend_, [module1, module2,]).shouldThrow.msg
            .canFind("second module ran").should == true;
    }

    @("runBackendSourceFixtureTests.withImportPaths." ~ backend.stringof)
    unittest {
        const importPath = tempModuleDir("backend-source-import-paths");
        mkdirRecurse(importPath);
        write(
            buildPath(importPath, "quickbite_backend_api_import.d"),
            q{
                module quickbite_backend_api_import;
                int importedValue() {
                    return 42;
                }
            },
        );

        runBackendSourceFixtureTests!backend(q{
            import quickbite_backend_api_import;

            unittest {
                assert(importedValue == 42);
            }
        }, [importPath]);
    }

    @("runBackendFileFixtureTests.withImportPaths." ~ backend.stringof)
    unittest {
        const importPath = tempModuleDir("backend-file-import-paths");
        mkdirRecurse(importPath);
        write(
            buildPath(importPath, "quickbite_backend_api_file_import.d"),
            q{
                module quickbite_backend_api_file_import;
                int importedValue() {
                    return 42;
                }
            },
        );

        const fixturePath = buildPath(importPath, "fixture.d");
        write(
            fixturePath,
            q{
                import quickbite_backend_api_file_import;

                unittest {
                    assert(importedValue == 42);
                }
            },
        );

        runBackendFileFixtureTests!backend(fixturePath, [importPath]);
    }
}
