module ut.bin.benchmarks;


import benchmarks.cli;
import quickbite.backends.native.run_executor:
    RunExecutorConfig, runExecutor;
import quickbite.backends.runner: TestResult;
import quickbite.backends.runner: Runner;
import dmd.dmodule: Module;
import ut;


private enum projectRoot = __FILE_FULL_PATH__[0 .. $
    - "/tests/ut/bin/benchmarks.d".length];


@("cgroupDriverReportsUnsupportedWithoutCgroupV2")
unittest {
    import std.file: mkdirRecurse;
    import std.path: buildPath;
    import std.process: environment, execute;

    with(immutable Sandbox()) {
        const cgroupRoot = inSandboxPath("cgroup");
        mkdirRecurse(cgroupRoot);

        auto childEnvironment = environment.toAA;
        childEnvironment["QUICKBITE_CGROUP_ROOT"] = cgroupRoot;
        const result = execute(
            [buildPath(projectRoot, "bin", "bench-cgroup")],
            childEnvironment,
        );

        result.status.should == 0;
        result.output.should ==
            "cgroup peak memory: unsupported (cgroup v2 unavailable)\n";
    }
}


@("cgroupDriverRunsSampleAndReportsExactPeak")
unittest {
    import std.file: mkdirRecurse, setAttributes;
    import std.path: buildPath;
    import std.process: environment, execute;

    with(immutable Sandbox()) {
        mkdirRecurse(inSandboxPath("cgroup/sample.scope"));
        writeFile("cgroup/cgroup.controllers", "memory\n");
        writeFile("cgroup/sample.scope/memory.peak", "3145728\n");
        writeFile("self.cgroup", "0::/sample.scope\n");
        writeFile("cgroup-launcher", `#!/bin/sh
exec "$@"
`);
        writeFile("bench", `#!/usr/bin/env bash
IFS= read -r inherited_peak <&"$QUICKBITE_CGROUP_PEAK_FD"
printf 'inherited memory.peak: %s\n' "$inherited_peak"
printf 'bench arguments:'
printf ' <%s>' "$@"
printf '\n'
`);
        setAttributes(inSandboxPath("cgroup-launcher"), 0x1ED);
        setAttributes(inSandboxPath("bench"), 0x1ED);

        auto childEnvironment = environment.toAA;
        childEnvironment["QUICKBITE_CGROUP_ROOT"] =
            inSandboxPath("cgroup");
        childEnvironment["QUICKBITE_CGROUP_FILE"] =
            inSandboxPath("self.cgroup");
        childEnvironment["QUICKBITE_CGROUP_LAUNCHER"] =
            inSandboxPath("cgroup-launcher");
        childEnvironment["QUICKBITE_BENCH"] = inSandboxPath("bench");
        const result = execute(
            [
                buildPath(projectRoot, "bin", "bench-cgroup"),
                "--backend=bytecode",
                "--runs=1",
                "fixture.d",
            ],
            childEnvironment,
        );

        result.status.should == 0;
        result.output.should ==
            "inherited memory.peak: 3145728\n"
            ~ "bench arguments: <--backend=bytecode> <--runs=1> <fixture.d>\n";
    }
}


@("cgroupDriverRequiresOneBackend")
unittest {
    import std.file: mkdirRecurse;
    import std.path: buildPath;
    import std.process: environment, execute;

    with(immutable Sandbox()) {
        mkdirRecurse(inSandboxPath("cgroup"));
        writeFile("cgroup/cgroup.controllers", "memory\n");

        auto childEnvironment = environment.toAA;
        childEnvironment["QUICKBITE_CGROUP_ROOT"] =
            inSandboxPath("cgroup");
        childEnvironment["QUICKBITE_CGROUP_LAUNCHER"] = "/usr/bin/true";
        const result = execute(
            [
                buildPath(projectRoot, "bin", "bench-cgroup"),
                "--runs=1",
                "fixture.d",
            ],
            childEnvironment,
        );

        result.status.should == 2;
        result.output.should ==
            "bench-cgroup requires exactly one --backend option\n";
    }
}


@("cgroupDriverAcceptsSplitBackendOption")
unittest {
    import std.file: mkdirRecurse;
    import std.path: buildPath;
    import std.process: environment, execute;

    with(immutable Sandbox()) {
        mkdirRecurse(inSandboxPath("cgroup"));
        writeFile("cgroup/cgroup.controllers", "memory\n");

        auto childEnvironment = environment.toAA;
        childEnvironment["QUICKBITE_CGROUP_ROOT"] =
            inSandboxPath("cgroup");
        childEnvironment["QUICKBITE_CGROUP_LAUNCHER"] = "/usr/bin/true";
        const result = execute(
            [
                buildPath(projectRoot, "bin", "bench-cgroup"),
                "--backend",
                "bytecode",
            ],
            childEnvironment,
        );

        result.status.should == 0;
    }
}


@("cgroupDriverAcceptsShortBackendOption")
unittest {
    import std.file: mkdirRecurse;
    import std.path: buildPath;
    import std.process: environment, execute;

    with(immutable Sandbox()) {
        mkdirRecurse(inSandboxPath("cgroup"));
        writeFile("cgroup/cgroup.controllers", "memory\n");

        auto childEnvironment = environment.toAA;
        childEnvironment["QUICKBITE_CGROUP_ROOT"] =
            inSandboxPath("cgroup");
        childEnvironment["QUICKBITE_CGROUP_LAUNCHER"] = "/usr/bin/true";
        const result = execute(
            [
                buildPath(projectRoot, "bin", "bench-cgroup"),
                "-b",
                "bytecode",
            ],
            childEnvironment,
        );

        result.status.should == 0;
    }
}


@("cliRejectsOldOptionSpelling")
unittest {
    run(["bench", "--executor=dmd-ctfe", "--help"])
        .shouldThrowWithMessage("Unrecognized option --executor=dmd-ctfe");
}

@("cliAcceptsBackendOption")
unittest {
    run(["bench", "--backend=ctfe", "--help"]);
}

@("cliDubOptionIsRepeatable")
unittest {
    // --dub used to bind to a scalar string, so getopt silently kept only the
    // last package. It must accumulate like --backend / --import-path.
    const opts = parseOptions(["bench", "--dub=foo", "--dub=bar", "extra.d"]);
    opts.dubPkgs.should == ["foo", "bar"];
    opts.fixtures.should == ["extra.d"];
}

@("benchmarkMeasurementSeparatesWarmupFromMeasuredCalls")
unittest {
    import benchmarks.harness: measureWithResults;

    size_t invocation;
    const measured = measureWithResults(
        () { return ++invocation; },
        2,
        3,
    );

    measured.warmupResults.should == [1, 2];
    measured.results.should == [3, 4, 5];
}

@("benchmarkMeasurementReportsDgcAllocation")
unittest {
    import benchmarks.harness: measureWithResults;
    import core.memory: GC;

    ubyte[] retained;
    const measured = measureWithResults(
        () {
            const before = GC.allocatedInCurrentThread;
            retained = new ubyte[](4096);
            return GC.allocatedInCurrentThread - before;
        },
        0,
        1,
    );

    assert(measured.results[0] > 0);
    measured.timing.dGcAllocation.should == measured.results[0];
}

@("benchmarkBackendsIncludeInterpreter")
unittest {
    import benchmarks.backends: BackendEnv, makeRunners;

    auto runners = makeRunners(BackendEnv());

    assert(("interpreter" in runners) !is null);
    assert(("bytecode" in runners) !is null);
}

@("benchmarkBackends.constructsOnlyRequestedBackends")
unittest {
    import benchmarks.backends: BackendEnv, makeRunners;

    auto runners = makeRunners(BackendEnv(), ["ctfe"]);

    assert(runners.length == 1);
    assert(("ctfe" in runners) !is null);
}

@("makeRunners.llvmjitReceivesDubPackage")
unittest {
    import quickbite.backends.native: DubPackage, LLVMJit;
    import quickbite.frontend.compiler: FrontendFlags;

    static assert(__traits(compiles,
        new LLVMJit(
            cast(const string[]) [],
            cast(const string[]) [],
            "",
            FrontendFlags.init,
            DubPackage.yes,
        )));
}

@("defaultBenchmarkBackendsIncludeInterpreter")
unittest {
    import benchmarks.cli: defaultBackendNames;

    defaultBackendNames.should == [
        "ctfe",
        "bytecode",
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

@("frontendRowsArePreparedPerFixtureAndRenderedInTheFixtureHeader")
unittest {
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
    ).runs;

    assert(runs.length == 2);
    assert(runs[0].displayName == "a");
    assert(runs[1].displayName == "b");
    assert(runs[0].frontend.min.total!"hnsecs" > 0);
    assert(runs[1].frontend.min.total!"hnsecs" > 0);

    // Each fixture's frontend timing is named in its own block header, not a
    // shared "== frontend ==" section row keyed by a "frontend" pseudo-backend.
    const headerA = renderFixtureHeader(
        runs[0].displayName, 1, runs[0].frontend, false,
        "LDC 2112", "-O", "efdd6ce5", 0, 1, false,
    );
    const headerB = renderFixtureHeader(
        runs[1].displayName, 1, runs[1].frontend, false,
        "LDC 2112", "-O", "efdd6ce5", 0, 1, false,
    );

    "a".should.be in headerA;
    "frontend".should.be in headerA;
    "b".should.be in headerB;
    "frontend".should.be in headerB;
}

@("bytecodeReportsCompileTime")
unittest {
    import core.time: Duration;
    import quickbite.backends.bytecode: Bytecode;
    import quickbite.backends.runner: CompileTimeReporter;
    import quickbite.frontend.compiler:
        FrontendFlags, parseSnippetWithCheckActionContext;

    auto bytecode = new Bytecode;
    auto reporter = cast(CompileTimeReporter) bytecode;
    assert(reporter !is null);
    reporter.compileTime.should == Duration.zero;

    // The unittest calls a helper so compilation also happens lazily
    // mid-run; the reported time must cover that as well as the eager
    // entry compile, so it must be positive after a run.
    auto moduleResult = parseSnippetWithCheckActionContext(
        q{
            int twice(in int value) { return value * 2; }

            unittest {
                assert(twice(21) == 42);
            }
        },
        [],
        FrontendFlags.init,
    );
    bytecode.runTests(moduleResult.module_).length.should == 1;

    assert(reporter.compileTime > Duration.zero);
    reporter.resetCompileTime;
    reporter.compileTime.should == Duration.zero;
}

@("systemLinkerReportsCompileTime")
unittest {
    import core.time: Duration;
    import quickbite.backends.native: SystemLinker;
    import quickbite.backends.runner: CompileTimeReporter;
    import quickbite.frontend.compiler:
        FrontendFlags, parseSnippetWithCheckActionContext;

    auto linker = new SystemLinker;
    auto reporter = cast(CompileTimeReporter) linker;
    assert(reporter !is null);
    reporter.compileTime.should == Duration.zero;

    auto moduleResult = parseSnippetWithCheckActionContext(
        q{
            unittest {
                assert(21 * 2 == 42);
            }
        },
        [],
        FrontendFlags.init,
    );
    linker.runTests(moduleResult.module_).length.should == 1;

    assert(reporter.compileTime > Duration.zero);
    reporter.resetCompileTime;
    reporter.compileTime.should == Duration.zero;
}

@("runExecutorUsesRequestedWorkingDirectory")
unittest {
    import std.file: mkdirRecurse, readText, setAttributes;
    import std.string: strip;

    with(immutable Sandbox()) {
        const executor = inSandboxPath("executor");
        const workingDirectory = inSandboxPath("package");
        const resultsFile = inSandboxPath("results");
        writeFile("executor", `#!/bin/sh
pwd > "$2"
`);
        setAttributes(executor, 0x1ED);
        mkdirRecurse(workingDirectory);

        runExecutor(
            "unused-request",
            resultsFile,
            RunExecutorConfig(workingDirectory, executor),
        );

        readText(resultsFile).strip.should == workingDirectory;
    }
}

@("runExecutorReportsStandardErrorOnFailure")
unittest {
    import std.file: setAttributes;

    with(immutable Sandbox()) {
        const executor = inSandboxPath("executor");
        writeFile("executor", `#!/bin/sh
echo 'Error: Cannot find reggae top dir using dub.json' >&2
kill -ABRT $$
`);
        setAttributes(executor, 0x1ED);

        void runFailure() {
            runExecutor(
                "unused-request",
                inSandboxPath("unused-results"),
                RunExecutorConfig("", executor),
            );
        }

        runFailure.shouldThrowWithMessage(
            "run executor exited with status -6 "
            ~ "(a fixture may have crashed the process):\n"
            ~ "Error: Cannot find reggae top dir using dub.json",
        );
    }
}

@("executorWireResultCarriesDgcAllocation")
unittest {
    import run_wire:
        RunResponse, WireResult, decodeResults, encodeResults;

    const response = decodeResults(encodeResults(RunResponse(
        4096,
        [WireResult(true, "test0", "fixture.d:1", "")],
    )));

    response.dGcAllocation.should == 4096;
    response.results.should == [
        WireResult(true, "test0", "fixture.d:1", ""),
    ];
}

@("executorWireResultCanRecordAllocationAfterEncoding")
unittest {
    import run_wire:
        RunResponse, decodeResults, encodeResults,
        setResultsDgcAllocation;

    auto bytes = encodeResults(RunResponse.init);
    bytes.setResultsDgcAllocation(8192);

    decodeResults(bytes).dGcAllocation.should == 8192;
}

@("renderBackendTableShowsCompileColumnOnlyForBackendsThatReportIt")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;
    import std.algorithm.searching: canFind;
    import std.typecons: nullable;

    const timing = Result(hnsecs(10_000), hnsecs(20_000), 0.0, 1024);
    const withCompile = renderBackendTable(
        [
            BenchmarkRow(
                "pkg", "bytecode", "3/3", timing,
                nullable(hnsecs(120_000)),
            ),
            BenchmarkRow("pkg", "ctfe", "3/3", timing),
        ],
        false,
        false,
    );
    const withoutCompile = renderBackendTable(
        [BenchmarkRow("pkg", "ctfe", "3/3", timing)],
        false,
        false,
    );

    "compile".should.be in withCompile;
    // A backend that reports compile time shows it in ms; one that does not
    // shows a bare dash in the same column, never "n/a".
    assert(withCompile.canFind("12.0 ms"));
    assert(withCompile.canFind("-"));
    // No backend in this table reports a compile split, so the whole column
    // (and its header) disappears rather than showing an all-dash column.
    assert(!withoutCompile.canFind("compile"));
}

@("renderBackendTableHasNoFixtureOrGcColumnAndNoVerdictWord")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;
    import std.algorithm.searching: canFind;

    const report = renderBackendTable(
        [
            BenchmarkRow(
                "pkg", "bytecode", "3/3",
                Result(hnsecs(70_000), hnsecs(70_000), 0.0, 1024),
            ),
            BenchmarkRow(
                "pkg", "ctfe", "3/3",
                Result(hnsecs(20_000), hnsecs(20_000), 0.0, 512),
            ),
        ],
        false,
        false,
    );

    // The block header already names the fixture; the table has no column
    // for it. The run is always GC-enabled, so that column is gone too.
    assert(!report.canFind("pkg"));
    assert(!report.canFind("GC"));
    assert(!report.canFind("verdict"));
    assert(!report.canFind("repeated"));
}

@("renderBackendTableMarksAFailingBackendRowInThePassColumn")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;
    import std.algorithm.searching: canFind;

    const timing = Result(hnsecs(70_000), hnsecs(70_000), 0.0, 1024);
    const report = renderBackendTable(
        [
            BenchmarkRow("pkg", "bytecode", formatPass("104/109"), timing),
            BenchmarkRow("pkg", "ctfe", formatPass("109/109"), timing),
        ],
        false,
        false,
    );

    "104/109 FAIL".should.be in report;
    assert(!report.canFind("109/109 FAIL"));
}

@("renderBackendTableOmitsSigmaColumnWhenCallerSaysRunsIsOne")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;
    import std.algorithm.searching: canFind;

    const rows = [
        BenchmarkRow(
            "pkg", "bytecode", "3/3",
            Result(hnsecs(70_000), hnsecs(70_000), 4_000.0, 1024),
        ),
    ];

    "σ".should.be in renderBackendTable(rows, true, false);
    assert(!renderBackendTable(rows, false, false).canFind("σ"));
}

@("renderBackendTableGoldenOutputAlignsTheMultiByteSigmaHeaderWithItsColumn")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;
    import std.array: replicate;
    import std.typecons: nullable;

    // One row per backend, chosen so every "%.1f"-formatted min/median/sigma
    // cell is exactly the same width as its neighbours in the same column:
    // this is a real golden (exact, whole-table) comparison, not a substring
    // check, so it also pins column widths and inter-column spacing.
    const rows = [
        BenchmarkRow(
            "example", "ctfe", "109/109",
            Result(hnsecs(68_000), hnsecs(70_000), 4_000.0, 1_572_864), // 1.5 MiB
        ),
        BenchmarkRow(
            "example", "bytecode", "109/109",
            Result(hnsecs(51_000), hnsecs(51_000), 1_000.0, 49_152),    // 48 KiB
            nullable(hnsecs(0)),
        ),
        BenchmarkRow(
            "example", "interpreter", "109/109",
            Result(hnsecs(260_000), hnsecs(271_000), 91_000.0, 2_097_152), // 2.0 MiB
        ),
        BenchmarkRow(
            "example", "system-linker", "109/109",
            Result(hnsecs(655_000), hnsecs(784_000), 68_000.0, 131_072),   // 128 KiB
            nullable(hnsecs(635_000)),
        ),
        BenchmarkRow(
            "example", "llvmjit", "109/109",
            Result(hnsecs(637_000), hnsecs(703_000), 46_000.0, 3_145_728), // 3.0 MiB
        ),
    ];

    const report = renderBackendTable(rows, true, false);

    const expected =
        "backend" ~ replicate(" ", 6) ~ "  "
            ~ replicate(" ", 3) ~ "pass" ~ "  "
            ~ replicate(" ", 4) ~ "min" ~ "  "
            ~ replicate(" ", 1) ~ "median" ~ "  "
            // "σ" is one display column but two UTF-8 bytes: a byte-length-based
            // pad would give it one space instead of two here, shifting it (and
            // everything to its right) one column left of the numeric data below.
            ~ replicate(" ", 2) ~ "σ" ~ "  "
            ~ "compile" ~ "  "
            ~ replicate(" ", 4) ~ "RAM" ~ "\n"
        ~ "ctfe" ~ replicate(" ", 9) ~ "  "
            ~ "109/109" ~ "  "
            ~ replicate(" ", 1) ~ "6.8 ms" ~ "  "
            ~ replicate(" ", 1) ~ "7.0 ms" ~ "  "
            ~ "0.4" ~ "  "
            ~ replicate(" ", 6) ~ "-" ~ "  "
            ~ "1.5 MiB" ~ "\n"
        ~ "bytecode" ~ replicate(" ", 5) ~ "  "
            ~ "109/109" ~ "  "
            ~ replicate(" ", 1) ~ "5.1 ms" ~ "  "
            ~ replicate(" ", 1) ~ "5.1 ms" ~ "  "
            ~ "0.1" ~ "  "
            ~ replicate(" ", 1) ~ "0.0 ms" ~ "  "
            ~ replicate(" ", 1) ~ "48 KiB" ~ "\n"
        ~ "interpreter" ~ replicate(" ", 2) ~ "  "
            ~ "109/109" ~ "  "
            ~ "26.0 ms" ~ "  "
            ~ "27.1 ms" ~ "  "
            ~ "9.1" ~ "  "
            ~ replicate(" ", 6) ~ "-" ~ "  "
            ~ "2.0 MiB" ~ "\n"
        ~ "system-linker" ~ "  "
            ~ "109/109" ~ "  "
            ~ "65.5 ms" ~ "  "
            ~ "78.4 ms" ~ "  "
            ~ "6.8" ~ "  "
            ~ "63.5 ms" ~ "  "
            ~ "128 KiB" ~ "\n"
        ~ "llvmjit" ~ replicate(" ", 6) ~ "  "
            ~ "109/109" ~ "  "
            ~ "63.7 ms" ~ "  "
            ~ "70.3 ms" ~ "  "
            ~ "4.6" ~ "  "
            ~ replicate(" ", 6) ~ "-" ~ "  "
            ~ "3.0 MiB" ~ "\n";

    report.should == expected;
}

@("renderBackendTableShowsRamWithTheSmallestUnitUnderOneThousandTwentyFour")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;

    const report = renderBackendTable(
        [
            // 48 KiB
            BenchmarkRow(
                "pkg", "bytecode", "3/3",
                Result(hnsecs(10_000), hnsecs(10_000), 0.0, 49_152),
            ),
            // 1.5 MiB
            BenchmarkRow(
                "pkg", "ctfe", "3/3",
                Result(hnsecs(10_000), hnsecs(10_000), 0.0, 1_572_864),
            ),
        ],
        false,
        false,
    );

    "RAM".should.be in report;
    "48 KiB".should.be in report;
    "1.5 MiB".should.be in report;
}

@("renderBackendTableShowsCgroupPeakColumnOnlyWhenVerboseAndMeasured")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;
    import std.algorithm.searching: canFind;
    import std.typecons: nullable;

    auto measured = Result(hnsecs(10_000), hnsecs(10_000), 0.0, 1024);
    measured.cgroupPeakMemory = nullable(3_145_728UL); // 3.0 MiB
    const unmeasured = Result(hnsecs(10_000), hnsecs(10_000), 0.0, 1024);

    const measuredRows = [BenchmarkRow("pkg", "bytecode", "3/3", measured)];
    const unmeasuredRows = [BenchmarkRow("pkg", "bytecode", "3/3", unmeasured)];

    assert(!renderBackendTable(measuredRows, false, false).canFind("cgroup"));
    "cgroup peak".should.be in renderBackendTable(measuredRows, false, true);
    "3.0 MiB".should.be in renderBackendTable(measuredRows, false, true);
    assert(!renderBackendTable(unmeasuredRows, false, true).canFind("cgroup"));
}

@("formatBytesChoosesTheLargestUnitUnderOneThousandTwentyFour")
unittest {
    formatBytes(0).should == "0 KiB";
    formatBytes(1024).should == "1 KiB";
    formatBytes(49_152).should == "48 KiB";
    formatBytes(1_572_864).should == "1.5 MiB";
    formatBytes(1024UL * 1024 * 1024).should == "1.0 GiB";
}

@("formatPassAppendsFailOnlyWhenSomeTestDidNotPass")
unittest {
    formatPass("109/109").should == "109/109";
    formatPass("104/109").should == "104/109 FAIL";
    formatPass("12 unchecked").should == "12 unchecked";
}

@("renderFixtureHeaderNamesFixtureTestCountFrontendCompilerAndCommit")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;

    const header = renderFixtureHeader(
        "example",
        109,
        Result(hnsecs(164_000), hnsecs(164_000), 0.0, 0),
        false,
        "LDC 2112",
        "-O",
        "efdd6ce5",
        1,
        9,
        false,
    );

    "example".should.be in header;
    "109 tests".should.be in header;
    "frontend 16.4 ms".should.be in header;
    "LDC 2112 -O".should.be in header;
    "efdd6ce5".should.be in header;
    "1+9 runs".should.be in header;
}

@("renderFixtureHeaderReportsAnUnmeasurableFrontendInsteadOfATime")
unittest {
    import benchmarks.harness: Result;

    const header = renderFixtureHeader(
        "bench_module_decl_fixture",
        1,
        Result.init,
        true,
        "LDC 2112",
        "-O",
        "",
        0,
        1,
        false,
    );

    "frontend unmeasurable (module declaration)".should.be in header;
}

@("renderFixtureHeaderOmitsCommitSegmentWhenUnavailable")
unittest {
    import benchmarks.harness: Result;
    import std.array: split;
    import std.string: strip;

    const header = renderFixtureHeader(
        "example", 1, Result.init, false, "LDC 2112", "-O", "", 0, 1, false,
    );

    // 5 segments: name, tests, frontend, compiler, runs -- no empty commit
    // segment between compiler and runs.
    header.strip.split("   ").length.should == 5;
}

@("renderFixtureHeaderAddsFrontendAllocationFigureOnlyWhenVerbose")
unittest {
    import benchmarks.harness: Result;
    import core.time: hnsecs;
    import std.algorithm.searching: canFind;

    // 1.5 MiB exactly.
    const frontend = Result(hnsecs(164_000), hnsecs(164_000), 0.0, 1_572_864);

    const quiet = renderFixtureHeader(
        "example", 109, frontend, false, "LDC 2112", "-O", "efdd6ce5", 1, 9, false,
    );
    const verbose = renderFixtureHeader(
        "example", 109, frontend, false, "LDC 2112", "-O", "efdd6ce5", 1, 9, true,
    );

    assert(!quiet.canFind("MiB"));
    "frontend 16.4 ms (1.5 MiB)".should.be in verbose;
}

@("parseOptionsRecognisesVerboseFlag")
unittest {
    parseOptions(["bench", "--verbose"]).verbose.should == true;
    parseOptions(["bench", "-v"]).verbose.should == true;
    parseOptions(["bench"]).verbose.should == false;
}

@("renderPreparationSectionReportsFailuresAsPreparationStatus")
unittest {
    import std.algorithm.searching: canFind;

    // discovered=1, prepared=0 -> a fixture that could not be prepared at all.
    const report = renderPreparationSection([
        PreparationRecord("cerealed.cerealiser", 1, 0, "DMD module-table conflict"),
    ]);

    assert(report.canFind("== preparation =="));
    assert(report.canFind("cerealed.cerealiser"));
    assert(report.canFind("not prepared"));
    assert(report.canFind("DMD module-table conflict"));
    // A preparation failure must not read like a backend skip.
    assert(!report.canFind("skipping"));
}

@("prepareFixtureRunsReportsParseFailureAsPreparation")
unittest {
    with(immutable Sandbox()) {
        writeFile("broken_fixture.d", q{
            this is not valid D syntax;
        });

        const prepared = prepareFixtureRuns(
            [inSandboxPath("broken_fixture.d")],
            [sandboxPath],
            0,
            1,
        );

        prepared.runs.length.should == 0;
        prepared.failures.length.should == 1;
        prepared.failures[0].name.should == "broken_fixture";
        prepared.failures[0].discovered.should == 1;
        prepared.failures[0].prepared.should == 0;
    }
}

@("dubPathArgumentResolvesToLocalPackageDir")
unittest {
    with(immutable Sandbox()) {
        writeFile("dub.sdl", `name "sandboxpkg"`);

        findPkgDir(sandboxPath).should == sandboxPath;
    }
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
        ).runs;

        // Fixture must not be dropped even though the timed re-parse
        // collides with the cached module in DMD's global symbol table.
        assert(runs.length == 1);
        assert(runs[0].displayName == "bench_module_decl_fixture");
        assert(runs[0].module_ !is null);
        assert(runs[0].frontendUnmeasurable);
    }
}

@("prepareFixtureRunsUsesFileIdentityForPackageModules")
unittest {
    import std.path: buildPath;

    with(immutable Sandbox()) {
        const importPath = "src";
        const importedPath = buildPath(importPath, "cerealed", "traits.d");
        const importerPath = buildPath(importPath, "cerealed", "cerealiser.d");

        writeFile(
            importedPath,
            q{
                module cerealed.traits;

                enum answer = 42;

                unittest {
                    assert(answer == 42);
                }
            },
        );
        writeFile(
            importerPath,
            q{
                module cerealed.cerealiser;

                import cerealed.traits;

                unittest {
                    assert(answer == 42);
                }
            },
        );

        const runs = prepareFixtureRuns(
            [
                inSandboxPath(importerPath),
                inSandboxPath(importedPath),
            ],
            [inSandboxPath(importPath)],
            0,
            1,
        ).runs;

        runs.length.should == 2;
        runs[0].displayName.should == "cerealed.cerealiser";
        runs[1].displayName.should == "cerealed.traits";
    }
}

@("prepareDubUnitParsesRootSetPreservingOrder")
unittest {
    import std.path: buildPath;

    with(immutable Sandbox()) {
        // A package whose importer root imports a leaf root. The dub unit is
        // prepared through the root-set API as one grouped unit, and its
        // members follow input order (not sorted: "root" sorts after "leaf").
        const importPath = "src";
        const leafPath = buildPath(importPath, "benchpkg", "leaf.d");
        const rootPath = buildPath(importPath, "benchpkg", "root.d");

        writeFile(
            leafPath,
            q{
                module benchpkg.leaf;

                enum answer = 42;

                unittest {
                    assert(answer == 42);
                }
            },
        );
        writeFile(
            rootPath,
            q{
                module benchpkg.root;

                import benchpkg.leaf;

                unittest {
                    assert(answer == 42);
                }
            },
        );

        const unit = prepareDubUnit(
            "benchpkg",
            [inSandboxPath(rootPath), inSandboxPath(leafPath)],
            [inSandboxPath(importPath)],
        );

        unit.displayName.should == "benchpkg";
        unit.grouped.should == true;
        unit.members.length.should == 2;
        unit.members[0].displayName.should == "benchpkg.root";
        unit.members[1].displayName.should == "benchpkg.leaf";
    }
}

@("dub.parseDescribeList yields the import paths, dropping blanks and whitespace")
unittest {
    import quickbite.dub: parseDescribeList;

    // Shape of `dub describe --data=import-paths --data-list`: the package's own
    // source path plus its transitive dependency paths, one per line.
    const output =
        "/cache/pkgs/cerealed/0.6.8/cerealed/source/\n" ~
        "  /cache/pkgs/concepts/0.0.7/concepts/source/  \n" ~
        "\n" ~
        "/cache/pkgs/unit-threaded/2.1.9/unit-threaded/source/\n";

    parseDescribeList(output).should == [
        "/cache/pkgs/cerealed/0.6.8/cerealed/source/",
        "/cache/pkgs/concepts/0.0.7/concepts/source/",
        "/cache/pkgs/unit-threaded/2.1.9/unit-threaded/source/",
    ];
}

@("dubDependencyImageLinksArchivesAndExternalInputs")
unittest {
    import core.sys.posix.dlfcn: dlclose, dlopen, dlsym, RTLD_NOW;
    import quickbite.dub: buildDubDependencyImage;
    import std.file: mkdirRecurse, setAttributes;
    import std.path: buildPath, pathSeparator;
    import std.process: environment, execute;
    import std.string: strip, toStringz;

    with(immutable Sandbox()) {
        writeFile("dependency.d", q{
            module dependency;

            extern(C) int dependencySupport();

            extern(C) int dependencyValue() {
                return dependencySupport() + 1;
            }
        });
        const dependencyObject = inSandboxPath("dependency.o");
        execute([
            "dmd",
            "-c",
            "-fPIC",
            "-of=" ~ dependencyObject,
            inSandboxPath("dependency.d"),
        ]).status.should == 0;
        const dependencyArchive = inSandboxPath("libdependency.a");
        execute([
            "ar",
            "rcs",
            dependencyArchive,
            dependencyObject,
        ]).status.should == 0;

        writeFile("support.d", q{
            module support;

            extern(C) int dependencySupport() {
                return 41;
            }
        });
        const supportObject = inSandboxPath("support.o");
        execute([
            "dmd",
            "-c",
            "-fPIC",
            "-of=" ~ supportObject,
            inSandboxPath("support.d"),
        ]).status.should == 0;
        const supportArchive = inSandboxPath("libdependency_support.a");
        execute([
            "ar",
            "rcs",
            supportArchive,
            supportObject,
        ]).status.should == 0;

        const originalPath = environment.get("PATH");
        const realDmd = execute(["which", "dmd"]).output.strip.idup;
        const toolchainPath = inSandboxPath("toolchain");
        mkdirRecurse(toolchainPath);
        writeFile("toolchain/dmd", `#!/bin/sh
PATH="$QUICKBITE_TEST_ORIGINAL_PATH"
export PATH
exec "$QUICKBITE_TEST_REAL_DMD" "$@"
`);
        writeFile("toolchain/cc", `#!/bin/sh
for argument in "$@"; do
    if [ "$argument" = "-lphobos2" ]; then
        echo 'cannot find compiler-local -lphobos2' >&2
        exit 1
    fi
done
exit 2
`);
        setAttributes(buildPath(toolchainPath, "dmd"), 0x1ED);
        setAttributes(buildPath(toolchainPath, "cc"), 0x1ED);

        const previousOriginalPath =
            environment.get("QUICKBITE_TEST_ORIGINAL_PATH");
        const previousRealDmd = environment.get("QUICKBITE_TEST_REAL_DMD");
        environment["QUICKBITE_TEST_ORIGINAL_PATH"] = originalPath;
        environment["QUICKBITE_TEST_REAL_DMD"] = realDmd;
        environment["PATH"] = toolchainPath ~ pathSeparator ~ originalPath;
        scope(exit) {
            environment["PATH"] = originalPath;
            if (previousOriginalPath is null)
                environment.remove("QUICKBITE_TEST_ORIGINAL_PATH");
            else
                environment["QUICKBITE_TEST_ORIGINAL_PATH"] =
                    previousOriginalPath;
            if (previousRealDmd is null)
                environment.remove("QUICKBITE_TEST_REAL_DMD");
            else
                environment["QUICKBITE_TEST_REAL_DMD"] = previousRealDmd;
        }

        const imagePath = buildDubDependencyImage(
            "driver_inputs",
            [dependencyArchive],
            sandboxPath,
            ["dependency_support"],
            ["-L" ~ sandboxPath, "-z", "defs"],
        );

        auto library = dlopen(imagePath.toStringz, RTLD_NOW);
        assert(library !is null);
        scope(exit) dlclose(library);
        const dependencyValue =
            cast(int function()) dlsym(library, "dependencyValue");
        assert(dependencyValue !is null);
        dependencyValue().should == 42;
    }
}

@("dubInfoUsesDependencyImageInsteadOfRawArchives")
unittest {
    import std.path: buildPath;

    const pkgDir = "/cache/pkgs/acme/1.0.0/acme";
    const archiveA = buildPath(pkgDir, ".dub/build/libdep_a.a");
    const archiveB = buildPath(pkgDir, ".dub/build/libdep_b.a");
    const imagePath = buildPath(pkgDir, ".quickbite/libacme_dub_deps.so");

    // dub's source-files for the unittest config, in dub's order. quickbite
    // forwards them to the frontend verbatim: no discovery, no filtering, no
    // reordering -- package.d included, exactly as dub reports.
    const sourceFiles = [
        buildPath(pkgDir, "source/acme/widget.d"),
        buildPath(pkgDir, "source/acme/package.d"),
        buildPath(pkgDir, "tests/roundtrip.d"),
    ];

    auto info = dubInfoFromDescribeData(
        "acme",
        pkgDir,
        [buildPath(pkgDir, "source")],
        [archiveA, archiveB],
        sourceFiles,
        (packageName, dependencyArchives, outDir) {
            packageName.should == "acme";
            dependencyArchives.should == [archiveA, archiveB];
            outDir.should == buildPath(pkgDir, ".quickbite");
            return imagePath;
        },
    );

    info.dependencyImages.should == [imagePath];
    info.fixtures.should == sourceFiles;  // forwarded verbatim, in dub's order
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

@("results.DisagreeingUnitMarksRunFailed")
unittest {
    Runner[string] runners;
    runners["good"] = new IndexedFailureRunner(99);
    runners["bad"] = new IndexedFailureRunner(0);

    bool correctnessFailed;
    const checkedResults = checkRunnerResults(
        runners,
        ["good", "bad"],
        [
            standaloneUnit("disagreeing", testModule),
            standaloneUnit("agreeing", testModule),
        ],
        correctnessFailed,
    );

    correctnessFailed.should == true;

    // The disagreeing unit is skipped so later units can still be checked,
    // but the completed benchmark run must return a failing status.
    assert(pairKey("disagreeing", "good") !in checkedResults);
    assert(pairKey("disagreeing", "bad") !in checkedResults);

    // ...and later units still run and record their results.
    checkedResults[pairKey("agreeing", "good")][0].passed.should == true;
    checkedResults[pairKey("agreeing", "bad")][0].passed.should == true;
}

@("results.ErroredBackendSkipsUnitNotFatal")
unittest {
    Runner[string] runners;
    runners["good"]   = new FixedVerdictRunner(null);
    runners["crashy"] = new ThrowingRunner("JIT child died (signal 11)");

    const checkedResults = checkRunnerResults(
        runners,
        ["good", "crashy"],
        [standaloneUnit("fixture", testModule)],
    );

    // A backend that errored never ran the benchmark: the unit is reported
    // and skipped for every backend instead of killing the whole bench.
    assert(pairKey("fixture", "good") !in checkedResults);
    assert(pairKey("fixture", "crashy") !in checkedResults);
}

@("testResultsMismatches.listsEveryMismatch")
unittest {
    const expected = [
        TestResult(true, "t0", "loc", null),
        TestResult(true, "t1", "loc", null),
        TestResult(true, "t2", "loc", null),
    ];
    const actual = [
        TestResult(false, "t0", "loc", "1 != 2"),
        TestResult(true, "t1", "loc", null),
        TestResult(false, "t2", "loc", "3 != 4"),
    ];

    testResultsMismatches(expected, actual).should == [
        "test t0 passes vs fails: 1 != 2",
        "test t2 passes vs fails: 3 != 4",
    ];
}

@("results.SingleBackendSelfCheckRecordsFailure")
unittest {
    Runner[string] runners;
    runners["a"] = new FixedVerdictRunner("1 != 2");

    const checkedResults = checkRunnerResults(
        runners,
        ["a"],
        [standaloneUnit("fixture", testModule)],
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
        [standaloneUnit("fixture", testModule)],
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
        [standaloneUnit("fixture", testModule)],
    );

    const results = checkedResults[pairKey("fixture", "a")];
    results.length.should == 1;
    results[0].passed.should == true;
}

@("results.SingleBackendSelfCheckReportsZeroResults")
unittest {
    Runner[string] runners;
    runners["a"] = new EmptyRunner;

    const checkedResults = checkRunnerResults(
        runners,
        ["a"],
        [standaloneUnit("fixture", testModule)],
    );

    const results = checkedResults[pairKey("fixture", "a")];
    results.length.should == 1;
    results[0].passed.should == false;
    results[0].message.should == "backend reported zero unittest results";
}

@("results.SkipCheckDisplayCountsRunnableDeclarations")
unittest {
    import quickbite.frontend.compiler: parseSnippet;

    auto first = parseSnippet(q{
        unittest {
            assert(1 == 1);
        }
    }).module_;
    auto second = parseSnippet(q{
        unittest {
            assert(2 == 2);
        }

        unittest {
            assert(3 == 3);
        }
    }).module_;

    TestResult[][string] checkedResults;
    checkedResults[pairKey("package", "a")] = [];

    checkedTestsDisplay(
        checkedResults,
        BenchmarkUnit(
            "package",
            [
                BenchmarkRun("fixture_a", first),
                BenchmarkRun("fixture_b", second),
            ],
            true,
        ),
        "a",
    )
        .should == "3 unchecked";
}

@("results.GroupedUnitChecksAllMemberModules")
unittest {
    import quickbite.frontend.compiler: parseSnippet;

    Runner[string] runners;
    runners["a"] = new IndexedFailureRunner(1);

    auto moduleWithOneTest = parseSnippet(q{ // Module is a mutable DMD AST node.
        unittest {
            assert(1 == 1);
        }
    }).module_;
    auto moduleWithTwoTests = parseSnippet(q{ // Module is a mutable DMD AST node.
        unittest {
            assert(1 == 1);
        }

        unittest {
            assert(2 == 2);
        }
    }).module_;

    const checkedResults = checkRunnerResults(
        runners,
        ["a"],
        [
            BenchmarkUnit(
                "package",
                [
                    BenchmarkRun("fixture_a", moduleWithOneTest),
                    BenchmarkRun("fixture_b", moduleWithTwoTests),
                ],
                true,
            ),
        ],
    );

    const results = checkedResults[pairKey("package", "a")];
    results.length.should == 3;
    results[0].passed.should == true;
    results[1].passed.should == false;
    results[2].passed.should == true;
}

private BenchmarkUnit standaloneUnit(in string name, Module module_) {
    return BenchmarkUnit(name, [BenchmarkRun(name, module_)], false);
}

private Module testModule() {
    import quickbite.frontend.compiler: parseSnippet;

    return parseSnippet(q{
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

// A test double whose runTests throws, standing in for a backend that crashes
// (e.g. the JIT child dying) before it can return any results.
private final class ThrowingRunner: Runner {
    private string _message;

    this(string message) {
        _message = message;
    }

    public override TestResult[] runTests(Module module_) {
        throw new Exception(_message);
    }
}

private final class EmptyRunner: Runner {
    public override TestResult[] runTests(Module module_) {
        return [];
    }
}

private final class IndexedFailureRunner: Runner {
    private size_t _failingIndex;
    private size_t _index;

    this(in size_t failingIndex) {
        _failingIndex = failingIndex;
    }

    public override TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;
        import std.conv: text;

        TestResult[] results;
        foreachUnitTestDeclaration(module_, (unitTest) {
            const passed = _index != _failingIndex;
            results ~= TestResult(
                passed,
                text("test", _index),
                "loc",
                passed ? null : "1 != 2",
            );
            ++_index;
        });

        return results;
    }
}
