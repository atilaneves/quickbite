module benchmarks.cli;

import benchmarks.harness: measure, Result;
import benchmarks.backends: BackendEnv, makeRunners;
import quickbite.backends.runner: Runner, TestResult, runTests;
import quickbite.benchmarks: moduleDisplayName;
import quickbite.frontend.compiler: parseModule, parseModuleUncached;
import dmd.dmodule: Module;

private:

// Defaults; overridable with -w/--warmup / -r/--runs.
enum size_t defaultWarmup = 1;
// Odd, so the median is a single sample without averaging two values.
enum size_t defaultRuns = 9;

public void run(string[] args) {
    import std.algorithm.searching: all;
    import std.file: readText;
    import std.getopt: defaultGetoptPrinter, getopt;
    import std.stdio: stderr, writefln, writeln;

    size_t warmup     = defaultWarmup;
    size_t runs       = defaultRuns;
    bool   skipCheck  = false;
    string[] importPaths;
    string[] backendNames;
    string dubPkg;

    auto info = getopt(
        args,
        "w|warmup",     "untimed iterations before sampling",          &warmup,
        "r|runs",       "timed iterations per measurement",            &runs,
        "skip-check",   "skip correctness checks before timing",       &skipCheck,
        "import-path",  "add an import search path (repeatable)",      &importPaths,
        "b|backend",    "backend to measure (repeatable)",             &backendNames,
        "dub",          "benchmark a dub package's tests by name",     &dubPkg,
    );
    if (info.helpWanted) {
        defaultGetoptPrinter(
            "usage: bench [-w N] [-r N] [--skip-check]"
            ~ " [--import-path=P ...] [--backend=NAME ...] [--dub=NAME]"
            ~ " [<module.d> ...]",
            info.options,
        );
        return;
    }

    string[] fixtures    = args[1 .. $].dup;
    string[] dubFixtures;
    BackendEnv env;

    if (dubPkg.length > 0) {
        auto dubInfo = resolveDubPkg(dubPkg);
        importPaths ~= dubInfo.importPaths;
        dubFixtures  = dubInfo.fixtures;
        // The raw dub import paths, not the merged importPaths (which also
        // carries CLI --import-path args): the backend derives the archive
        // import paths from these and the package root.
        env = BackendEnv(dubInfo.importPaths, dubInfo.linkFiles, dubInfo.packageRoot);
    }

    if (fixtures.length == 0 && dubFixtures.length == 0)
        fixtures = ["tests/example.d"];

    if (!isOptimisedBuild) {
        throw new Exception(
            "benchmark refuses to run on a non-optimised build "
            ~ "(rebuild with `dub build -c benchmark -b benchmark-opt`).",
        );
    }

    printRunHeader(warmup, runs);

    auto runners = makeRunners(env);

    if (backendNames.length == 0)
        backendNames = ["ctfe", "system-linker", "llvmjit"];

    foreach (name; backendNames)
        if (name !in runners)
            throw new Exception("unknown backend: " ~ name);

    if (backendNames.length == 1)
        skipCheck = true;

    auto fixtureRuns = prepareFixtureRuns(fixtures, importPaths, warmup, runs);
    auto dubRuns = prepareFixtureRuns(dubFixtures, importPaths, warmup, runs);

    RunnerCheck check;
    if (skipCheck) {
        foreach (name; backendNames)
            foreach (run; fixtureRuns ~ dubRuns)
                check.passingPairs[pairKey(run.displayName, name)] = true;
    } else {
        check = checkRunnerResults(runners, backendNames, fixtureRuns ~ dubRuns);
        foreach (message; check.skipped)
            stderr.writeln(message);
    }

    if (fixtureRuns.length > 0 || dubRuns.length > 0) {
        writeln("== frontend (parse + semantic) ==");
        printHeader;
        foreach (run; fixtureRuns ~ dubRuns) {
            if (run.frontendUnmeasurable)
                writefln(
                    "%-32s %-14s unmeasurable (module declaration)",
                    run.displayName,
                    "frontend",
                );
            else
                printRow(run.displayName, "frontend", run.frontend);
        }
        writeln;
    }

    BenchmarkUnit[] units;
    foreach (run; fixtureRuns)
        units ~= BenchmarkUnit(run.displayName, [run], false);
    if (dubRuns.length > 0)
        units ~= BenchmarkUnit(dubPkg, dubRuns, true);

    writeln("== post-parse (excludes dmd parse + semantic) ==");
    printHeader;
    foreach (name; backendNames) {
        auto runner = runners[name];

        foreach (unit; units) {
            const allPassing = unit.members.all!(
                member => check.passingPairs.get(pairKey(member.displayName, name), false),
            );
            if (!allPassing) {
                // A standalone fixture's own skip reason was already printed by
                // checkRunnerResults; a group needs its own line because it is
                // reported under one name its failing member does not carry.
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
                    unit.displayName, name,
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

public struct RunnerCheck {
    public bool[string] passingPairs;
    public string[] skipped;
}

// Runners must agree on which tests exist and whether they pass before any
// of them is timed: a disagreement means at least one runner is wrong, so
// its numbers would be meaningless. Fixtures whose tests fail are skipped
// rather than timed.
public RunnerCheck checkRunnerResults(
    Runner[string] runners,
    in string[] backendNames,
    BenchmarkRun[] runs,
) {
    import std.conv: text;

    RunnerCheck check;

    foreach (run; runs) {
        string[] resultNames;
        TestResult[][] allResults;

        foreach (name; backendNames) {
            try {
                allResults ~= runners[name].runTests(run.module_);
                resultNames ~= name;
            } catch (Exception e) {
                check.skipped ~= text(
                    "skipping ", run.displayName, " ", name, ": ",
                    e.msg.firstLine,
                );
            }
        }

        foreach (i; 1 .. allResults.length) {
            const mismatch = testResultsMismatch(allResults[0], allResults[i]);
            if (mismatch !is null)
                throw new Exception(text(
                    "backends ", resultNames[0], " and ", resultNames[i],
                    " disagree on ", run.displayName, ": ", mismatch,
                ));
        }

        foreach (i, name; resultNames) {
            const failure = firstFailureMessage(allResults[i]);
            if (failure is null)
                check.passingPairs[pairKey(run.displayName, name)] = true;
            else
                check.skipped ~= text(
                    "skipping ", run.displayName, " ", name, ": ",
                    failure.firstLine,
                );
        }
    }

    return check;
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
        if (left.passed != right.passed)
            return text(
                "test ", left.name, " ",
                left.passed ? "passes" : "fails", " vs ",
                right.passed ? "passes" : "fails",
            );
    }

    return null;
}

string firstFailureMessage(in TestResult[] results) {
    foreach (result; results)
        if (!result.passed)
            return result.message;
    return null;
}

struct DubInfo {
    string[] importPaths;
    string[] linkFiles;
    string packageRoot;
    string[] fixtures;
}

public struct BenchmarkRun {
    public string displayName;
    public Module module_;
    public Result frontend;
    public bool frontendUnmeasurable;
}

struct BenchmarkUnit {
    string displayName;
    BenchmarkRun[] members;   // 1 for a standalone fixture, N for a dub package
    bool grouped;             // a dub package reports under one name across N modules
}

public struct BenchmarkRow {
    public string fixture;
    public string backend;
    public Result result;
}

DubInfo resolveDubPkg(in string name) {
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.process: Config, execute;
    import std.string: splitLines, strip;

    const pkgDir = findPkgDir(name);

    // dub describe reports dependency archives whether or not they have been
    // built; build first so the link files below actually exist. dub owns
    // their invalidation: it rebuilds on source or dub.selections.json
    // changes.
    auto buildResult = execute(
        ["dub", "build", "--config=unittest"],
        null, Config.none, size_t.max,
        pkgDir,
    );
    if (buildResult.status != 0)
        buildResult = execute(
            ["dub", "build"],
            null, Config.none, size_t.max,
            pkgDir,
        );
    if (buildResult.status != 0)
        throw new Exception("dub build failed for " ~ name ~ ": " ~ buildResult.output);

    // Prefer the unittest config so test-only deps (e.g. unit-threaded) are included.
    auto importPathResult = execute(
        ["dub", "describe", "--config=unittest", "--data=import-paths", "--data-list"],
        null, Config.none, size_t.max,
        pkgDir,
    );
    if (importPathResult.status != 0)
        importPathResult = execute(
            ["dub", "describe", "--data=import-paths", "--data-list"],
            null, Config.none, size_t.max,
            pkgDir,
        );
    if (importPathResult.status != 0)
        throw new Exception("dub describe failed for " ~ name ~ ": " ~ importPathResult.output);

    auto importPaths = importPathResult.output
        .splitLines
        .map!(l => l.strip)
        .filter!(l => l.length > 0)
        .array;

    auto linkFileResult = execute(
        ["dub", "describe", "--config=unittest", "--data=linker-files", "--data-list"],
        null, Config.none, size_t.max,
        pkgDir,
    );
    if (linkFileResult.status != 0)
        linkFileResult = execute(
            ["dub", "describe", "--data=linker-files", "--data-list"],
            null, Config.none, size_t.max,
            pkgDir,
        );
    if (linkFileResult.status != 0)
        throw new Exception("dub describe failed for " ~ name ~ ": " ~ linkFileResult.output);

    auto linkFiles = linkFileResult.output
        .splitLines
        .map!(l => l.strip)
        .filter!(l => l.length > 0)
        .array;

    // The fixtures are the modules dub compiles for the unittest config, not a
    // hardcoded tests/ glob: that lets packages keep their tests in source/
    // (no tests/ dir at all) and excludes intentionally-failing example
    // modules dub leaves out of the unittest build.
    auto sourceFileResult = execute(
        ["dub", "describe", "--config=unittest", "--data=source-files", "--data-list"],
        null, Config.none, size_t.max,
        pkgDir,
    );
    if (sourceFileResult.status != 0)
        sourceFileResult = execute(
            ["dub", "describe", "--data=source-files", "--data-list"],
            null, Config.none, size_t.max,
            pkgDir,
        );
    if (sourceFileResult.status != 0)
        throw new Exception("dub describe failed for " ~ name ~ ": " ~ sourceFileResult.output);

    const sourceFiles = sourceFileResult.output
        .splitLines
        .map!(l => l.strip)
        .filter!(l => l.length > 0)
        .array;

    auto fixtures = discoverFixtures(pkgDir, sourceFiles);  // auto: DubInfo needs mutable string[]
    if (fixtures.length == 0)
        throw new Exception("no test fixtures found for " ~ name ~ " in " ~ pkgDir);

    return DubInfo(importPaths, linkFiles, pkgDir, fixtures);
}

// Keep only the package's own modules (under pkgDir, so the generated test
// runner in the dub cache and dependency sources drop out) that are not
// non-standalone runner/package files.
public string[] discoverFixtures(in string pkgDir, in string[] sourceFiles) {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.path: baseName, dirSeparator;
    import std.string: startsWith;

    const prefix = pkgDir ~ dirSeparator;
    auto fixtures = sourceFiles
        .filter!(f => f.startsWith(prefix))
        .filter!(f => !f.baseName.isTestRunnerFile)
        .map!(f => f.idup)
        .array;
    fixtures.sort;
    return fixtures;
}

bool isTestRunnerFile(in string basename) {
    import std.string: endsWith;
    // Exclude non-standalone files: runner entry points and package modules.
    return basename == "main.d"
        || basename == "package.d"
        || basename.endsWith("_main.d");
}

string findPkgDir(in string name) {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: dirEntries, exists, SpanMode;
    import std.path: baseName, buildPath, expandTilde;
    import std.process: execute;
    import std.string: startsWith;

    const cache = expandTilde("~/.dub/packages");

    // Handles both cache layouts:
    //   new: ~/.dub/packages/<name>/<version>/<name>/
    //   old: ~/.dub/packages/<name>-<version>/<name>/
    string[] scan() {
        if (!cache.exists) return [];
        const newStyle = buildPath(cache, name);
        if (newStyle.exists)
            return dirEntries(newStyle, SpanMode.shallow)
                .filter!(e => e.isDir)
                .map!(e => buildPath(e.name, name))
                .filter!(p => p.exists)
                .array;
        return dirEntries(cache, SpanMode.shallow)
            .filter!(e => e.isDir && e.name.baseName.startsWith(name ~ "-"))
            .map!(e => buildPath(e.name, name))
            .filter!(p => p.exists)
            .array;
    }

    auto found = scan;  // auto: mutable for sort and re-fetch
    if (found.length == 0) {
        execute(["dub", "fetch", name]);
        found = scan;
    }
    if (found.length == 0)
        throw new Exception("could not find package '" ~ name ~ "' in dub cache");
    found.sort;
    return found[$ - 1];
}

void printHeader() {
    import std.stdio: writefln, writeln;
    writefln(
        "%-32s %-14s %10s %10s %10s %10s",
        "fixture", "backend", "min", "median", "stddev", "max ram",
    );
    writeln;
}

public void printRow(
    in string fixture,
    in string backendName,
    in Result result,
) {
    import std.stdio: writefln;

    enum hnsecsPerMs = 10_000.0;
    writefln(
        "%-32s %-14s %7.3f ms %7.3f ms %7.3f ms %7.1f KiB",
        fixture,
        backendName,
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
        "%-32s %-14s %10s %10s %10s %10s\n\n",
        "fixture",
        "backend",
        "min",
        "median",
        "stddev",
        "max ram",
    ));
    foreach (row; rows) {
        enum hnsecsPerMs = 10_000.0;
        output.put(format(
            "%-32s %-14s %7.3f ms %7.3f ms %7.3f ms %7.1f KiB\n",
            row.fixture,
            row.backend,
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

public BenchmarkRun[] prepareFixtureRuns(
    in string[] fixtures,
    in string[] importPaths,
    in size_t warmup,
    in size_t runs,
) {
    import std.file: readText;

    BenchmarkRun[] fixtureRuns;
    foreach (path; fixtures) {
        const source      = readText(path);
        const displayName = moduleDisplayName(path, importPaths);
        Module module_;
        try {
            module_ = parseModule(source, importPaths).module_;
        } catch (Exception e) {
            import std.stdio: stderr;

            stderr.writefln("skipping %s: %s", displayName, e.msg);
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
                    parseModuleUncached(source, importPaths);
                },
                warmup,
                runs,
            );
        } catch (Exception e) {
            frontendUnmeasurable = true;
        }
        fixtureRuns ~= BenchmarkRun(
            displayName,
            module_,
            frontend,
            frontendUnmeasurable,
        );
    }
    return fixtureRuns;
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
