module ut.backends.api.runner;


import ut.backends;
import quickbite.frontend.compiler: parseModule;
import std.algorithm: count;
import std.conv: text;
import std.path: buildPath;


static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
    @("runTests.importPathsRetryAfterFailure." ~ backend.stringof)
    unittest {

        with(immutable Sandbox()) {
            const importPath = "imports";
            // DMD caches failed imports by module name in process-global state.
            // The CTFE and Interpreter matrix cases must not share one name.
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

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
    @("runTestResults.countsAttributedPassingAndFailingUnittests." ~
        backend.stringof)
    unittest {
        const results = runBackendSourceFixtureTestResults!backend(q{
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

        results.length.should == 3;
        results.count!(result => result.passed).should == 2;
        results.count!(result => !result.passed).should == 1;
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
    @("runTestResults.countsAllPassingUnittests." ~ backend.stringof)
    unittest {
        const results = runBackendSourceFixtureTestResults!backend(q{
            unittest {
                assert(1 == 1);
            }

            @("also passes")
            unittest {
                assert(2 == 2);
            }
        });

        results.length.should == 2;
        results.count!(result => result.passed).should == 2;
        results.count!(result => !result.passed).should == 0;
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
    @("runTestResults.countsAssertErrorsAsFailures." ~ backend.stringof)
    unittest {
        const results = runBackendSourceFixtureTestResults!backend(q{
            import core.exception: AssertError;

            unittest {
                throw new AssertError("expected");
            }
        });

        results.length.should == 1;
        results.count!(result => result.passed).should == 0;
        results.count!(result => !result.passed).should == 1;
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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

        result.length.should == 2;
        result[0].name.should == "__unittest_L2_C13";
        result[1].name.should == "__unittest_L6_C13";
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
    @("runTestResults.reportsFileBackedUnittestLocations." ~
        backend.stringof)
    unittest {
        import unit_threaded.integration: Sandbox;

        with (immutable Sandbox()) {
            // DMD keys file-backed modules by module name, not absolute path,
            // so both backend matrix cases need distinct fixture basenames.
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

            result.length.should == 1;
            result[0].location.should == fixturePath ~ "(1)";
        }
    }
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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
}

static foreach (backend; backendsWith!(Interpreter, Bytecode, IR)) {
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

            // DMD keys file-backed modules by module name, not absolute path,
            // so both backend matrix cases need distinct fixture basenames.
            const fixturePath = buildPath(
                importPath,
                text("fixture_", backend.stringof, ".d"),
            );
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
