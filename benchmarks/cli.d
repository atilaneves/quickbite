module benchmarks.cli;

import benchmarks.harness: measure, Result;
import benchmarks.backends: BackendEnv, makeRunners;
import quickbite.backends.runner: Runner, TestResult, runTests;
import quickbite.benchmarks: moduleDisplayName;
import quickbite.frontend.compiler: FrontendFlags, parseModule, parseSnippetUncached;
import dmd.dmodule: Module;

public import quickbite.dub: findPkgDir;

private:

// Defaults; overridable with -w/--warmup / -r/--runs.
enum size_t defaultWarmup = 1;
// Odd, so the median is a single sample without averaging two values.
enum size_t defaultRuns = 9;
public immutable string[] defaultBackendNames = [
    "ctfe",
    "interpreter",
    "system-linker",
    "llvmjit",
];

public struct BenchOptions {
    public size_t warmup = defaultWarmup;
    public size_t runs   = defaultRuns;
    public bool skipCheck;
    public string[] importPaths;
    public string[] backendNames;
    // Repeatable: each --dub names one dub package to benchmark. A scalar would
    // make getopt keep only the last, silently dropping every earlier package.
    public string[] dubPkgs;
    public string[] fixtures;
    public bool helpWanted;
}

public BenchOptions parseOptions(string[] args) {
    import std.getopt: defaultGetoptPrinter, getopt;

    BenchOptions opts;
    auto info = getopt(
        args,
        "w|warmup",     "untimed iterations before sampling",          &opts.warmup,
        "r|runs",       "timed iterations per measurement",            &opts.runs,
        "skip-check",   "skip correctness checks before timing",       &opts.skipCheck,
        "import-path",  "add an import search path (repeatable)",      &opts.importPaths,
        "b|backend",    "backend to measure (repeatable)",             &opts.backendNames,
        "dub",          "benchmark a dub package's tests by name (repeatable)",
                                                                       &opts.dubPkgs,
    );
    opts.helpWanted = info.helpWanted;
    if (info.helpWanted)
        defaultGetoptPrinter(
            "usage: bench [-w N] [-r N] [--skip-check]"
            ~ " [--import-path=P ...] [--backend=NAME ...] [--dub=NAME ...]"
            ~ " [<module.d> ...]",
            info.options,
        );
    // getopt consumed the recognised options in place; the remaining positional
    // arguments (after the program name) are standalone fixtures.
    opts.fixtures = args[1 .. $].dup;
    return opts;
}

// A set of benchmark units that share one backend environment: standalone
// fixtures under the default environment, or a single dub package under its own
// import paths, dependency image, and package root. Each group owns the runner
// set built from that environment because the native backends are
// environment-specific.
private struct BenchmarkGroup {
    Runner[string] runners;
    BenchmarkUnit[] units;
}

public void run(string[] args) {
    import quickbite.backends.native: DubPackage;
    import std.stdio: stderr, write, writefln, writeln;

    const opts = parseOptions(args);
    if (opts.helpWanted)
        return;

    const warmup    = opts.warmup;
    const runs      = opts.runs;
    const skipCheck = opts.skipCheck;

    // A --dub run is dedicated to dub packages, compiled like `dub test` (a
    // whole root set, no lightning rod). A standalone-fixture run is the
    // single-snippet world. The frontend must know before its first parse.
    {
        import quickbite.frontend.compiler: DubMode, initialize;
        initialize(opts.dubPkgs.length > 0 ? DubMode.yes : DubMode.no);
    }

    string[] fixtures = opts.fixtures.dup;
    if (fixtures.length == 0 && opts.dubPkgs.length == 0)
        fixtures = ["tests/example.d"];

    if (!isOptimisedBuild) {
        throw new Exception(
            "benchmark refuses to run on a non-optimised build "
            ~ "(rebuild with `dub build -c benchmark -b benchmark-opt`).",
        );
    }

    printRunHeader(warmup, runs);

    // Every environment produces the same backend names, so the default runner
    // set both validates the selection and serves the standalone fixtures.
    auto defaultRunners = makeRunners(BackendEnv());

    const usingDefaultBackends = opts.backendNames.length == 0;
    string[] backendNames = usingDefaultBackends
        ? defaultBackendNames.dup
        : opts.backendNames.dup;

    backendNames = withoutUnavailableBackends(backendNames, usingDefaultBackends);

    foreach (name; backendNames)
        if (name !in defaultRunners)
            throw new Exception("unknown backend: " ~ name);

    // Each dub package carries its own native-backend environment (import paths,
    // dependency image, package root), so it needs its own runner set; standalone
    // fixtures share the default one. Group units with the runners that serve them.
    PreparationRecord[] preparation;
    BenchmarkGroup[] groups;

    auto prepared = prepareFixtureRuns(fixtures, opts.importPaths, warmup, runs);
    BenchmarkUnit[] fixtureUnits;
    foreach (run; prepared.runs) {
        fixtureUnits ~= BenchmarkUnit(
            run.displayName,
            [run],
            false,
            run.frontend,
            run.frontendUnmeasurable,
        );
        preparation ~= PreparationRecord(run.displayName, 1, 1, "");
    }
    preparation ~= prepared.failures;
    if (fixtureUnits.length > 0)
        groups ~= BenchmarkGroup(defaultRunners, fixtureUnits);

    foreach (dubPkg; opts.dubPkgs) {
        auto dubInfo = resolveDubPkg(dubPkg);
        // The raw dub import paths, not the merged ones (which also carry CLI
        // --import-path args): the backend derives the archive import paths from
        // these and the package root.
        auto env = BackendEnv(
            dubInfo.importPaths,
            dubInfo.linkFiles,
            dubInfo.packageRoot,
            dubInfo.frontendFlags,
            DubPackage.yes,
        );
        const pkgImportPaths = opts.importPaths ~ dubInfo.importPaths;
        try {
            auto unit = prepareDubUnit(
                dubPkg,
                dubInfo.fixtures,
                pkgImportPaths,
                dubInfo.frontendFlags,
            );
            preparation ~= PreparationRecord(
                dubPkg, dubInfo.fixtures.length, unit.members.length, "",
            );
            groups ~= BenchmarkGroup(makeRunners(env), [unit]);
        } catch (Exception e)
            preparation ~= PreparationRecord(
                dubPkg, dubInfo.fixtures.length, 0, e.msg.firstLine,
            );
    }

    if (preparation.length > 0)
        write(renderPreparationSection(preparation));

    // Flattened view for the per-unit sections (frontend rows, skip reporting);
    // the check and timing loops below use each group's own runners.
    BenchmarkUnit[] units;
    foreach (group; groups)
        units ~= group.units;

    TestResult[][string] checkedResults;
    if (skipCheck) {
        foreach (name; backendNames)
            foreach (unit; units)
                checkedResults[pairKey(unit.displayName, name)] = [];
    } else {
        foreach (group; groups) {
            auto groupResults =
                checkRunnerResults(group.runners, backendNames, group.units);
            foreach (key, value; groupResults)
                checkedResults[key] = value;
        }
        foreach (unit; units)
            foreach (name; backendNames) {
                const key = pairKey(unit.displayName, name);
                if (key !in checkedResults)
                    continue;

                const failure = firstFailureMessage(checkedResults[key]);
                if (failure !is null)
                    stderr.writefln(
                        "skipping %s %s: %s",
                        unit.displayName,
                        name,
                        failure.firstLine,
                    );
            }
    }

    if (units.length > 0) {
        writeln("== frontend (parse + semantic) ==");
        printHeader;
        foreach (unit; units) {
            if (unit.frontendUnmeasurable)
                writefln(
                    "%-32s %-14s %-10s unmeasurable (module declaration)",
                    unit.displayName,
                    "frontend",
                    "n/a",
                );
            else
                printRow(unit.displayName, "frontend", "n/a", unit.frontend);
        }
        writeln;
    }

    writeln("== post-parse (excludes dmd parse + semantic) ==");
    printHeader;
    foreach (name; backendNames)
        foreach (group; groups) {
            auto runner = group.runners[name];

            foreach (unit; group.units) {
                const allPassing = skipCheck
                    || checkedTestsPassing(checkedResults, unit, name);
                if (!allPassing) {
                    // A standalone fixture's own skip reason was already printed
                    // by checkRunnerResults; a group needs its own line because
                    // it is reported under one name its failing member lacks.
                    if (unit.grouped)
                        stderr.writefln(
                            "skipping %s %s: failing fixtures", unit.displayName, name,
                        );
                    continue;
                }

                Module[] modules;
                foreach (member; unit.members)
                    modules ~= member.module_;

                try {
                    printRow(
                        unit.displayName,
                        name,
                        checkedTestsDisplay(checkedResults, unit, name),
                        measure(
                            () { runTests(runner, modules); },
                            warmup,
                            runs,
                        ),
                    );
                } catch (Exception e) {
                    stderr.writefln(
                        "skipping %s %s: %s",
                        unit.displayName, name,
                        unit.grouped ? e.msg : e.msg.firstLine,
                    );
                }
                writeln;
            }
        }
}

string firstLine(in string message) {
    import std.string: lineSplitter;

    foreach (line; message.lineSplitter)
        return line.idup;
    return "";
}

// Runners must agree on which tests exist and whether they pass before any
// of them is timed: a disagreement means at least one runner is wrong, so
// its numbers would be meaningless. Fixtures whose tests fail are skipped
// rather than timed.
public TestResult[][string] checkRunnerResults(
    Runner[string] runners,
    in string[] backendNames,
    BenchmarkUnit[] units,
) {
    import std.conv: text;

    TestResult[][string] checkedResults;

    foreach (unit; units) {
        Module[] modules;
        foreach (member; unit.members)
            modules ~= member.module_;

        string[] resultNames;
        TestResult[][] allResults;
        bool[] errored;

        foreach (name; backendNames) {
            try {
                // Mutable: empty backend results are normalised below.
                auto results = runTests(runners[name], modules);
                if (results.length == 0)
                    results = [
                        TestResult(
                            false,
                            "runner returned no tests",
                            "",
                            "backend reported zero unittest results",
                        ),
                    ];
                allResults ~= results;
                resultNames ~= name;
                errored ~= false;
            } catch (Exception e) {
                allResults ~= [
                    TestResult(
                        false,
                        "runner threw",
                        "",
                        e.msg.firstLine,
                    ),
                ];
                resultNames ~= name;
                errored ~= true;
            }
        }

        // A backend that threw never ran the benchmark, so it cannot have
        // "disagreed" with one that did: its fabricated single result would
        // misreport the crash as "N tests vs 1". Report the error itself. Only
        // for multi-backend runs: a single backend that errors is recorded as a
        // failing self-check and skipped, not aborted (see run()).
        if (resultNames.length > 1)
            foreach (i, name; resultNames)
                if (errored[i])
                    throw new Exception(text(
                        "backend ", name, " errored on ", unit.displayName,
                        ": ", allResults[i][0].message,
                    ));

        foreach (i; 1 .. allResults.length) {
            const mismatch = testResultsMismatch(allResults[0], allResults[i]);
            if (mismatch !is null)
                throw new Exception(text(
                    "backends ", resultNames[0], " and ", resultNames[i],
                    " disagree on ", unit.displayName, ": ", mismatch,
                ));
        }

        foreach (i, name; resultNames)
            checkedResults[pairKey(unit.displayName, name)] = allResults[i];
    }

    return checkedResults;
}

public string pairKey(in string fixture, in string backendName) {
    return fixture ~ '\0' ~ backendName;
}

// Failure messages may legitimately differ between backends; test names and
// outcomes may not.
public string testResultsMismatch(
    in TestResult[] lhs,
    in TestResult[] rhs,
) {
    import std.conv: text;

    if (lhs.length != rhs.length)
        return text(lhs.length, " tests vs ", rhs.length);

    foreach (i, left; lhs) {
        const right = rhs[i];
        if (left.name != right.name)
            return text("test ", left.name, " vs ", right.name);
        if (left.passed != right.passed) {
            // Exactly one side failed; surface its diagnostic so a disagreement
            // reports *why* the failing backend diverged, not just that it did.
            const failure = left.passed ? right : left;
            return text(
                "test ", left.name, " ",
                left.passed ? "passes" : "fails", " vs ",
                right.passed ? "passes" : "fails",
                failure.message.length > 0
                    ? text(": ", failure.message.firstLine)
                    : "",
            );
        }
    }

    return null;
}

string firstFailureMessage(in TestResult[] results) {
    foreach (result; results)
        if (!result.passed)
            return result.message;
    return null;
}

bool checkedTestsPassing(
    TestResult[][string] checkedResults,
    in BenchmarkUnit unit,
    in string backendName,
) {
    size_t passed;
    size_t total;
    const key = pairKey(unit.displayName, backendName);
    if (key !in checkedResults)
        return false;

    const results = checkedResults[key];
    foreach (result; results) {
        ++total;
        if (result.passed)
            ++passed;
    }

    return total > 0 && passed == total;
}

public string checkedTestsDisplay(
    TestResult[][string] checkedResults,
    BenchmarkUnit unit,
    in string backendName,
) {
    import std.conv: text;

    size_t passed;
    size_t total;
    const key = pairKey(unit.displayName, backendName);
    if (key !in checkedResults)
        return "unchecked";

    foreach (result; checkedResults[key]) {
        ++total;
        if (result.passed)
            ++passed;
    }

    if (total == 0)
        return text(runnableUnittestCount(unit), " unchecked");

    return text(passed, "/", total);
}

private size_t runnableUnittestCount(BenchmarkUnit unit) {
    import quickbite.frontend.util: foreachUnitTestDeclaration;

    size_t count;
    foreach (member; unit.members)
        foreachUnitTestDeclaration(member.module_, (_) { ++count; });
    return count;
}

public struct DubInfo {
    string[] importPaths;
    string[] linkFiles;
    string packageRoot;
    string[] fixtures;
    FrontendFlags frontendFlags;
}

public alias DubDependencyImageBuilder = string delegate(
    in string packageName,
    in string[] dependencyArchives,
    in string outDir,
);

public struct BenchmarkRun {
    public string displayName;
    public Module module_;
    public Result frontend;
    public bool frontendUnmeasurable;
}

public struct BenchmarkUnit {
    public string displayName;
    public BenchmarkRun[] members;   // 1 for a standalone fixture, N for a dub package
    public bool grouped;             // a dub package reports under one name across N modules
    // The frontend (parse + semantic) measurement for the whole unit: a
    // standalone fixture's own re-parse, or a dub package's single whole-package
    // root-set parse. One frontend row per unit, never per module.
    public Result frontend;
    public bool frontendUnmeasurable;
}

public struct BenchmarkRow {
    public string fixture;
    public string backend;
    public string tests;
    public Result result;
}

// One unit's preparation outcome. A failure to prepare is reported here, never
// as a `skipping ...` line that reads like a backend skip: preparation happens
// before any backend runs, so a unit that did not prepare was never benchmarked
// by any backend.
public struct PreparationRecord {
    public string name;        // package or fixture display name
    public size_t discovered;  // modules discovered for the unit
    public size_t prepared;    // modules that parsed into the unit
    public string note;        // failure reason, or dep-image/"" on success
}

public string renderPreparationSection(in PreparationRecord[] records) {
    import std.array: appender;
    import std.format: format;

    auto output = appender!string;
    output.put("== preparation ==\n");
    output.put(format(
        "%-32s %10s %9s %8s  %s\n\n",
        "package", "discovered", "prepared", "skipped", "note",
    ));
    foreach (record; records) {
        const skipped = record.discovered - record.prepared;
        // prepared == 0 means nothing in the unit parsed, so the unit could not
        // be prepared at all; spell that out rather than leaving a bare reason.
        const note = record.prepared == 0
            ? "not prepared: " ~ record.note
            : record.note;
        output.put(format(
            "%-32s %10d %9d %8d  %s\n",
            record.name,
            record.discovered,
            record.prepared,
            skipped,
            note,
        ));
    }
    output.put("\n");
    return output.data;
}

DubInfo resolveDubPkg(in string name) {
    import quickbite.dub:
        buildDubDependencyImage, dubBuild, dubCompilerArguments, dubDescribe;

    const pkgDir = findPkgDir(name);

    // Everything below is asked of dub and forwarded to the frontend verbatim:
    // the import paths, the source files dub compiles for the unittest config,
    // and the compiler flags (versions, -preview=..., string imports) dub chose.
    // quickbite invents nothing about the build.
    auto importPaths = dubDescribe(pkgDir, "import-paths");
    const sourceFiles = dubDescribe(pkgDir, "source-files");

    // Build so the dependency archives exist on disk for the dependency image.
    dubBuild(name, pkgDir);
    auto dependencyArchives = dubDescribe(pkgDir, "linker-files");

    // dub's own external link inputs for the package: `libs` are system C
    // libraries (e.g. vibe-d's ssl/crypto) the dependency archives reference but
    // do not define; `lflags` are raw linker flags. Forwarded to the image link
    // so it resolves instead of loading with undefined symbols like RAND_poll.
    const systemLibs = dubDescribe(pkgDir, "libs");
    const linkerFlags = dubDescribe(pkgDir, "lflags");

    return dubInfoFromDescribeData(
        name,
        pkgDir,
        importPaths,
        dependencyArchives,
        sourceFiles,
        (packageName, dependencyArchives, outDir) {
            return buildDubDependencyImage(
                packageName,
                dependencyArchives,
                outDir,
                systemLibs,
                linkerFlags,
            );
        },
        FrontendFlags(dubCompilerArguments(pkgDir)),
    );
}

public DubInfo dubInfoFromDescribeData(
    in string packageName,
    in string pkgDir,
    in string[] importPaths,
    in string[] dependencyArchives,
    in string[] sourceFiles,
    scope DubDependencyImageBuilder buildDependencyImage,
    in FrontendFlags frontendFlags = FrontendFlags.init,
) {
    import std.path: buildPath;

    // dub already reports exactly the root package's compile inputs for the
    // unittest config; quickbite forwards them to the frontend verbatim rather
    // than discovering or filtering anything itself. Dependencies are supplied
    // prebuilt as the dependency image (the cold/hot build model, dub-deps.md),
    // which is why dub's root-only source-files list is precisely what to compile.
    auto fixtures = sourceFiles.dup;  // dup: DubInfo needs mutable string[]
    if (fixtures.length == 0)
        throw new Exception("no source files reported by dub for " ~ packageName ~ " in " ~ pkgDir);

    string[] linkFiles;
    if (dependencyArchives.length != 0)
        linkFiles = [
            buildDependencyImage(
                packageName,
                dependencyArchives,
                buildPath(pkgDir, ".quickbite"),
            ),
        ];

    return DubInfo(
        importPaths.dup,
        linkFiles,
        pkgDir.idup,
        fixtures,
        FrontendFlags(frontendFlags.compilerArguments.dup),
    );
}

void printHeader() {
    import std.stdio: writefln, writeln;
    writefln(
        "%-32s %-14s %-10s %10s %10s %10s %10s",
        "fixture", "backend", "tests", "min", "median", "stddev", "max ram",
    );
    writeln;
}

public void printRow(
    in string fixture,
    in string backendName,
    in string tests,
    in Result result,
) {
    import std.stdio: writefln;

    enum hnsecsPerMs = 10_000.0;
    writefln(
        "%-32s %-14s %-10s %7.3f ms %7.3f ms %7.3f ms %7.1f KiB",
        fixture,
        backendName,
        tests,
        result.min.total!"hnsecs" / hnsecsPerMs,
        result.median.total!"hnsecs" / hnsecsPerMs,
        result.stddevHnsecs / hnsecsPerMs,
        result.ramKiB,
    );
}

public string renderBenchmarkSection(
    in string title,
    in BenchmarkRow[] rows,
) {
    import std.array: appender;
    import std.format: format;

    auto output = appender!string;
    output.put("== " ~ title ~ " ==\n");
    output.put(format(
        "%-32s %-14s %-10s %10s %10s %10s %10s\n\n",
        "fixture",
        "backend",
        "tests",
        "min",
        "median",
        "stddev",
        "max ram",
    ));
    foreach (row; rows) {
        enum hnsecsPerMs = 10_000.0;
        output.put(format(
            "%-32s %-14s %-10s %7.3f ms %7.3f ms %7.3f ms %7.1f KiB\n",
            row.fixture,
            row.backend,
            row.tests,
            row.result.min.total!"hnsecs" / hnsecsPerMs,
            row.result.median.total!"hnsecs" / hnsecsPerMs,
            row.result.stddevHnsecs / hnsecsPerMs,
            row.result.ramKiB,
        ));
    }
    output.put("\n");
    return output.data;
}

private double ramKiB(in Result result) {
    return result.maxRamBytes / 1024.0;
}

public struct PreparedFixtures {
    public BenchmarkRun[] runs;
    public PreparationRecord[] failures;
}

public PreparedFixtures prepareFixtureRuns(
    in string[] fixtures,
    in string[] importPaths,
    in size_t warmup,
    in size_t runs,
) {
    import std.file: readText;

    PreparedFixtures prepared;
    foreach (path; fixtures) {
        const source      = readText(path);
        const displayName = moduleDisplayName(path, importPaths);
        Module module_;
        try {
            module_ = parseModule(path, importPaths).module_;
        } catch (Exception e) {
            // A fixture that does not parse was never benchmarked by any
            // backend: record it as a preparation failure, not a backend skip.
            prepared.failures ~= PreparationRecord(
                displayName,
                1,
                0,
                e.msg.firstLine,
            );
            continue;
        }

        // Re-parsing a module-declared fixture collides with the cached
        // module in DMD's process-global symbol table, so the frontend
        // timing can fail even though the cached module is fine for the
        // post-parse runs.
        Result frontend;
        bool frontendUnmeasurable;
        try {
            frontend = measure(
                () {
                    parseSnippetUncached(source, importPaths);
                },
                warmup,
                runs,
            );
        } catch (Exception e) {
            frontendUnmeasurable = true;
        }
        prepared.runs ~= BenchmarkRun(
            displayName,
            module_,
            frontend,
            frontendUnmeasurable,
        );
    }
    return prepared;
}

// Prepare a dub package as one grouped benchmark unit. Unlike standalone
// fixtures (parsed one file at a time), the package is parsed as a single root
// set through `parseRootModules`, so a module imported by a sibling fixture
// keeps its unittest bodies instead of becoming a bodyless non-root
// placeholder. Members follow input order so display names stay stable.
public BenchmarkUnit prepareDubUnit(
    in string packageName,
    in string[] fixtures,
    in string[] importPaths,
    in FrontendFlags frontendFlags = FrontendFlags.init,
) {
    import quickbite.frontend.compiler: parseRootModules;
    import core.time: MonoTime;

    const start   = MonoTime.currTime;
    auto results  = parseRootModules(fixtures, importPaths, frontendFlags);
    const elapsed = MonoTime.currTime - start;

    BenchmarkRun[] members;
    foreach (i, result; results)
        members ~= BenchmarkRun(
            moduleDisplayName(fixtures[i], importPaths),
            result.module_,
        );

    // Re-parsing the package would collide with the modules just registered in
    // DMD's process-global symbol table, so the single preparation parse is the
    // frontend measurement: one whole-package sample, not a warmup/run loop.
    return BenchmarkUnit(
        packageName,
        members,
        true,
        Result(elapsed, elapsed, 0.0, 0),
        false,
    );
}

// version(LDC): an LDC-built bench cannot run llvmjit. Its value is the
// in-process ORC JIT, which has no .so to hand the DMD run executor and whose
// JIT'd DMD-codegen would mismatch the LDC host's extern(D) ABI
// (ai/spikes/ldc-eh/FINDINGS.md). system-linker stays available because it
// produces a .so the executor can run. Drop llvmjit silently from the defaults,
// but reject it loudly when explicitly requested so the user is not surprised.
string[] withoutUnavailableBackends(string[] backendNames, in bool usingDefaults) {
    version (LDC) {
        import std.algorithm.iteration: filter;
        import std.algorithm.searching: canFind;
        import std.array: array;
        import std.stdio: stderr;

        if (!backendNames.canFind("llvmjit"))
            return backendNames;
        if (!usingDefaults)
            throw new Exception(
                "llvmjit is unavailable under the LDC benchmark build "
                ~ "(its in-process JIT cannot cross the run-executor process "
                ~ "boundary); use system-linker, or rebuild with "
                ~ "`dub build -c benchmark -b benchmark-opt`.",
            );
        stderr.writeln(
            "note: llvmjit is unavailable under the LDC build; skipping it.",
        );
        return backendNames.filter!(name => name != "llvmjit").array;
    } else
        return backendNames;
}

bool isOptimisedBuild() {
    version (D_Optimized) return true;
    else return false;
}

void printRunHeader(in size_t warmup, in size_t runs) {
    import core.cpuid: processor;
    import std.algorithm.searching: until;
    import std.array: array;
    import std.conv: text;
    import std.file: exists, readText;
    import std.process: execute;
    import std.stdio: writefln, writeln;
    import std.string: strip;
    import std.system: os;

    writeln("== run metadata ==");
    writefln("compiler:    %s %s", __VENDOR__, __VERSION__);
    writefln("build:       %s", buildFlagsSummary);

    const commit = execute(["git", "rev-parse", "--short", "HEAD"]);
    if (commit.status == 0)
        writefln("commit:      %s", commit.output.strip);

    writefln("cpu:         %s", processor.strip);

    enum governor = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor";
    if (governor.exists)
        writefln("governor:    %s", governor.readText.strip);

    writefln("os:          %s", os);
    writefln("gc:          disabled during timed loop");
    writefln("sampling:    %s warmup + %s runs", warmup, runs);
    writeln;
}

string buildFlagsSummary() {
    import std.array: join;

    string[] flags;
    version (D_Optimized) flags ~= "-O";
    version (D_NoBoundsChecks) flags ~= "-boundscheck=off";
    version (assert) flags ~= "asserts=on";
    else flags ~= "asserts=off";
    debug flags ~= "-debug";

    return flags.join(" ");
}
