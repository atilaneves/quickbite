module ut.benchmarks;


import benchmarks.cli: BenchmarkRow, prepareFixtureRuns, renderBenchmarkSection, run;
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
