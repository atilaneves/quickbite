module ut.bin.benchmarks;


import benchmarks.cli;
import quickbite.backends.runner: TestResult;
import quickbite.backends.runner: Runner;
import dmd.dmodule: Module;
import ut;


@("cliRejectsOldOptionSpelling")
unittest {
    run(["bench", "--executor=dmd-ctfe", "--help"])
        .shouldThrowWithMessage("Unrecognized option --executor=dmd-ctfe");
}

@("cliAcceptsBackendOption")
unittest {
    run(["bench", "--backend=ctfe", "--help"]);
}

@("benchmarkBackendsIncludeInterpreter")
unittest {
    import benchmarks.backends: BackendEnv, makeRunners;

    auto runners = makeRunners(BackendEnv());

    assert(("interpreter" in runners) !is null);
}

@("defaultBenchmarkBackendsIncludeInterpreter")
unittest {
    import benchmarks.cli: defaultBackendNames;

    defaultBackendNames.should == [
        "ctfe",
        "interpreter",
        "system-linker",
        "llvmjit",
    ];
}

@("preParseReportsMissingFixture")
unittest {
    import quickbite.benchmarks: populateDmdCodegenModuleSet;
    import std.algorithm.searching: canFind, startsWith;
    import std.path: buildPath;

    const importPath = tempModuleDir("benchmark-preparse");
    const missingFixture = buildPath(importPath, "missing_fixture.d");

    try {
        populateDmdCodegenModuleSet([missingFixture], [importPath]);
        assert(false, "missing fixture did not throw");
    } catch (Exception e) {
        assert(e.msg.startsWith("failed to pre-parse missing_fixture: "));
        assert(e.msg.canFind("missing_fixture.d"));
    }
}

@("frontendRowsArePreparedAndRenderedPerFixture")
unittest {
    import std.algorithm.searching: canFind;
    import std.file: mkdirRecurse, write;
    import std.path: buildPath;

    const importPath = tempModuleDir("benchmark-frontend-rows");
    mkdirRecurse(importPath);
    const fixtureA = buildPath(importPath, "a.d");
    const fixtureB = buildPath(importPath, "b.d");

    write(
        fixtureA,
        q{
            unittest {
                int value = 1;
                assert(value == 1);
            }
        },
    );
    write(
        fixtureB,
        q{
            unittest {
                int value = 2;
                assert(value == 2);
            }
        },
    );

    const runs = prepareFixtureRuns(
        [fixtureA, fixtureB],
        [importPath],
        0,
        1,
    );

    assert(runs.length == 2);
    assert(runs[0].displayName == "a");
    assert(runs[1].displayName == "b");
    assert(runs[0].frontend.min.total!"hnsecs" > 0);
    assert(runs[1].frontend.min.total!"hnsecs" > 0);

    const report = renderBenchmarkSection(
        "frontend (parse + semantic)",
        [
            BenchmarkRow(
                runs[0].displayName,
                "frontend",
                "n/a",
                runs[0].frontend,
            ),
            BenchmarkRow(
                runs[1].displayName,
                "frontend",
                "n/a",
                runs[1].frontend,
            ),
        ],
    );

    assert(report.canFind("== frontend (parse + semantic) =="));
    assert(report.canFind("a"));
    assert(report.canFind("b"));
    assert(report.canFind("frontend"));
    assert(report.canFind("fixture"));
    "ram".should.be in report;
    "KiB".should.be in report;
}

@("moduleDeclarationFixtureIsNotSkipped")
unittest {
    with(immutable Sandbox()) {
        writeFile(
            "bench_module_decl_fixture.d",
            q{
                module bench_module_decl_fixture;
                unittest {
                    assert(1 == 1);
                }
            },
        );

        const runs = prepareFixtureRuns(
            [inSandboxPath("bench_module_decl_fixture.d")],
            [sandboxPath],
            0,
            1,
        );

        // Fixture must not be dropped even though the timed re-parse
        // collides with the cached module in DMD's global symbol table.
        assert(runs.length == 1);
        assert(runs[0].displayName == "bench_module_decl_fixture");
        assert(runs[0].module_ !is null);
        assert(runs[0].frontendUnmeasurable);
    }
}

@("discoverFixturesKeepsInPackageTestModules")
unittest {
    import std.path: buildPath;

    // dub describe --data=source-files returns: the package's own library and
    // test modules (under pkgDir), a generated runner under the dub cache, a
    // dependency source outside pkgDir, plus package.d and a *_main.d. Only the
    // in-package non-runner modules are fixtures, sorted.
    const pkgDir = "/cache/pkgs/acme/1.0.0/acme";
    const sourceFiles = [
        "/cache/build/acme-test/dub_test_root.d",
        buildPath(pkgDir, "source/acme/widget.d"),
        buildPath(pkgDir, "source/acme/package.d"),
        buildPath(pkgDir, "tests/roundtrip.d"),
        buildPath(pkgDir, "tests/app_main.d"),
        "/cache/pkgs/dep/2.0.0/dep/source/dep/thing.d",
    ];

    discoverFixtures(pkgDir, sourceFiles).should == [
        buildPath(pkgDir, "source/acme/widget.d"),
        buildPath(pkgDir, "tests/roundtrip.d"),
    ];
}

@("testResultsMismatch")
unittest {
    const passing = [TestResult(true, "t0", "loc", null)];

    assert(testResultsMismatch(passing, passing) is null);
    assert(testResultsMismatch(passing, []) !is null);
    assert(testResultsMismatch(
        passing,
        [TestResult(true, "other", "loc", null)],
    ) !is null);
    assert(testResultsMismatch(
        passing,
        [TestResult(false, "t0", "loc", "1 != 2")],
    ) !is null);
}

@("results.RejectsDisagreeingBackends")
unittest {
    Runner[string] runners;
    runners["good"] = new FixedVerdictRunner(null);
    runners["bad"] = new FixedVerdictRunner("1 != 2");

    checkRunnerResults(
        runners,
        ["good", "bad"],
        [BenchmarkRun("fixture", testModule)],
    )
        .shouldThrow;
}

@("results.SingleBackendSelfCheckRecordsFailure")
unittest {
    Runner[string] runners;
    runners["a"] = new FixedVerdictRunner("1 != 2");

    const checkedResults = checkRunnerResults(
        runners,
        ["a"],
        [BenchmarkRun("fixture", testModule)],
    );

    const results = checkedResults[pairKey("fixture", "a")];
    results.length.should == 1;
    results[0].passed.should == false;
    results[0].message.should == "1 != 2";
}

@("results.AcceptsAgreeingBackends")
unittest {
    Runner[string] runners;
    runners["a"] = new FixedVerdictRunner(null);
    runners["b"] = new FixedVerdictRunner(null);

    const checkedResults = checkRunnerResults(
        runners,
        ["a", "b"],
        [BenchmarkRun("fixture", testModule)],
    );

    checkedResults[pairKey("fixture", "a")].length.should == 1;
    checkedResults[pairKey("fixture", "a")][0].passed.should == true;
    checkedResults[pairKey("fixture", "b")].length.should == 1;
    checkedResults[pairKey("fixture", "b")][0].passed.should == true;
}

@("results.SingleBackendSelfCheckRecordsPassingSummary")
unittest {
    Runner[string] runners;
    runners["a"] = new FixedVerdictRunner(null);

    const checkedResults = checkRunnerResults(
        runners,
        ["a"],
        [BenchmarkRun("fixture", testModule)],
    );

    const results = checkedResults[pairKey("fixture", "a")];
    results.length.should == 1;
    results[0].passed.should == true;
}

private Module testModule() {
    import quickbite.frontend.compiler: parseModule;

    return parseModule(q{
        unittest {
            assert(1 == 1);
        }
    }).module_;
}

// A test double that reports a fixed verdict (empty message = pass, non-empty
// = fail) for every unittest in the module. It lets the checkRunnerResults
// tests exercise cross-runner agreement and fixture-skipping logic without
// standing up a real backend, so it implements Runner directly rather than
// evaluating anything.
private final class FixedVerdictRunner: Runner {
    private string failureMessage;

    this(string failureMessage) {
        this.failureMessage = failureMessage;
    }

    public override TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;
        import std.conv: text;

        TestResult[] results;
        size_t index;
        foreachUnitTestDeclaration(module_, (unitTest) {
            results ~= TestResult(
                failureMessage.length == 0,
                text("test", index++),
                "loc",
                failureMessage,
            );
        });

        return results;
    }
}
