module ut.benchmarks;


import benchmarks.cli:
    BenchmarkRow,
    BenchmarkRun,
    checkBackendResults,
    pairKey,
    prepareFixtureRuns,
    renderBenchmarkSection,
    run,
    testResultsMismatch;
import quickbite.backends: Backend, TestResult, EvalResult;
import quickbite.lang: Value;
import dmd.dmodule: Module;
import dmd.func: FuncDeclaration;
import ut;


private:

@("benchmark.cliRejectsOldOptionSpelling")
unittest {
    run(["bench", "--executor=dmd-ctfe", "--help"])
        .shouldThrowWithMessage("Unrecognized option --executor=dmd-ctfe");
}

@("benchmark.cliAcceptsBackendOption")
unittest {
    run(["bench", "--backend=ctfe", "--help"]);
}

@("benchmark.preParseReportsMissingFixture")
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

@("benchmark.frontendRowsArePreparedAndRenderedPerFixture")
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
            BenchmarkRow(runs[0].displayName, "frontend", runs[0].frontend),
            BenchmarkRow(runs[1].displayName, "frontend", runs[1].frontend),
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

@("benchmark.testResultsMismatch")
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

@("benchmark.checkBackendResultsRejectsDisagreeingBackends")
unittest {
    Backend[string] backends;
    backends["good"] = new FixedVerdictBackend(null);
    backends["bad"] = new FixedVerdictBackend("1 != 2");

    checkBackendResults(
        backends,
        ["good", "bad"],
        [BenchmarkRun("fixture", testModule)],
    )
        .shouldThrow;
}

@("benchmark.checkBackendResultsSkipsFailingFixtures")
unittest {
    Backend[string] backends;
    backends["a"] = new FixedVerdictBackend("1 != 2");

    const check = checkBackendResults(
        backends,
        ["a"],
        [BenchmarkRun("fixture", testModule)],
    );

    check.passingPairs.length.should == 0;
    check.skipped.length.should == 1;
    "1 != 2".should.be in check.skipped[0];
}

@("benchmark.checkBackendResultsAcceptsAgreeingBackends")
unittest {
    Backend[string] backends;
    backends["a"] = new FixedVerdictBackend(null);
    backends["b"] = new FixedVerdictBackend(null);

    const check = checkBackendResults(
        backends,
        ["a", "b"],
        [BenchmarkRun("fixture", testModule)],
    );

    check.skipped.length.should == 0;
    check.passingPairs.get(pairKey("fixture", "a"), false).should == true;
    check.passingPairs.get(pairKey("fixture", "b"), false).should == true;
}

private Module testModule() {
    import quickbite.frontend.compiler: parseModule;

    return parseModule(q{
        unittest {
            assert(1 == 1);
        }
    }).module_;
}

// A test double that reports a fixed unittest verdict (null message = pass,
// non-empty = fail) regardless of the function it is handed. It lets the
// checkBackendResults tests exercise cross-backend agreement and
// fixture-skipping logic without standing up a real backend: the only path
// those tests reach is runTests, which calls eval per unittest, so eval just
// replays the canned verdict.
private final class FixedVerdictBackend: Backend {
    private string failureMessage;

    this(string failureMessage) {
        this.failureMessage = failureMessage;
    }

    public override EvalResult eval(FuncDeclaration) {
        return failureMessage.length == 0
            ? EvalResult(Value.void_)
            : EvalResult(EvalResult.Diagnostic(failureMessage));
    }
}
