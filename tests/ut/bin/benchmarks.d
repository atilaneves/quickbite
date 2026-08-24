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

@("cliDubOptionIsRepeatable")
unittest {
    // --dub used to bind to a scalar string, so getopt silently kept only the
    // last package. It must accumulate like --backend / --import-path.
    const opts = parseOptions(["bench", "--dub=foo", "--dub=bar", "extra.d"]);
    opts.dubPkgs.should == ["foo", "bar"];
    opts.fixtures.should == ["extra.d"];
}

@("benchmarkBackendsIncludeInterpreter")
unittest {
    import benchmarks.backends: BackendEnv, makeRunners;

    auto runners = makeRunners(BackendEnv());

    assert(("interpreter" in runners) !is null);
    assert(("bytecode" in runners) !is null);
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
    ).runs;

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

@("renderBenchmarkSectionShowsCompileTime")
unittest {
    import benchmarks.harness: Result;
    import core.time: msecs;
    import std.algorithm.searching: canFind;
    import std.typecons: nullable;

    const timing = Result(1.msecs, 2.msecs, 0.0, 1024);
    const report = renderBenchmarkSection(
        "post-parse",
        [
            BenchmarkRow("pkg", "bytecode", "3/3", timing, nullable(12.msecs)),
            BenchmarkRow("pkg", "ctfe", "3/3", timing),
        ],
    );

    "compile".should.be in report;
    // A backend that reports compile time shows it in ms; one that does
    // not shows n/a in the same column.
    assert(report.canFind("12.000 ms"));
    assert(report.canFind("n/a"));
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
