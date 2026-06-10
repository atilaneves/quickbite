module benchmarks.cli;

import benchmarks.harness: measure, Result;
import quickbite.backends.runner: Runner, TestResult;
import quickbite.benchmarks: moduleDisplayName;
import quickbite.backends.ctfe: Ctfe;
import quickbite.backends.native: SystemLinker;
import quickbite.frontend.compiler: parseModule, parseModuleUncached;
import dmd.dmodule: Module;

private:

// Defaults; overridable with --warmup / --iterations.
enum size_t defaultWarmup = 1;
// Odd, so the median is a single sample without averaging two values.
enum size_t defaultIterations = 9;

public void run(string[] args) {
    import std.algorithm.searching: all;
    import std.file: readText;
    import std.getopt: defaultGetoptPrinter, getopt;
    import std.stdio: stderr, writefln, writeln;

    size_t warmup     = defaultWarmup;
    size_t iterations = defaultIterations;
    string[] importPaths;
    string[] backendNames;
    string dubPkg;

    auto info = getopt(
        args,
        "warmup",       "untimed iterations before sampling",          &warmup,
        "iterations",   "timed iterations per measurement",            &iterations,
        "import-path",  "add an import search path (repeatable)",      &importPaths,
        "b|backend",    "backend to measure (repeatable)",             &backendNames,
        "dub",          "benchmark a dub package's tests by name",     &dubPkg,
    );
    if (info.helpWanted) {
        defaultGetoptPrinter(
            "usage: bench [--warmup=N] [--iterations=N]"
            ~ " [--import-path=P ...] [--backend=NAME ...] [--dub=NAME]"
            ~ " [<module.d> ...]",
            info.options,
        );
        return;
    }

    string[] fixtures    = args[1 .. $].dup;
    string[] dubFixtures;

    if (dubPkg.length > 0) {
        auto dubInfo = resolveDubPkg(dubPkg);
        importPaths ~= dubInfo.importPaths;
        dubFixtures  = dubInfo.fixtures;
    }

    if (fixtures.length == 0 && dubFixtures.length == 0)
        fixtures = ["tests/example.d"];

    if (!isOptimisedBuild) {
        throw new Exception(
            "benchmark refuses to run on a non-optimised build "
            ~ "(rebuild with `dub build -c benchmark -b benchmark-opt`).",
        );
    }

    printRunHeader(warmup, iterations);

    Runner[string] runners;
    runners["ctfe"] = new Ctfe;
    runners["system-linker"] = new SystemLinker;

    if (backendNames.length == 0)
        backendNames = ["ctfe"];

    foreach (name; backendNames)
        if (name !in runners)
            throw new Exception("unknown backend: " ~ name);

    auto fixtureRuns = prepareFixtureRuns(fixtures, importPaths, warmup, iterations);
    auto dubRuns = prepareFixtureRuns(dubFixtures, importPaths, warmup, iterations);

    const check = checkRunnerResults(
        runners,
        backendNames,
        fixtureRuns ~ dubRuns,
    );
    foreach (message; check.skipped)
        stderr.writeln(message);

    if (fixtureRuns.length > 0 || dubRuns.length > 0) {
        writeln("== frontend (parse + semantic) ==");
        printHeader;
        foreach (run; fixtureRuns ~ dubRuns) {
            printRow(run.displayName, "frontend", run.frontend);
        }
        writeln;
    }

    writeln("== post-parse (excludes dmd parse + semantic) ==");
    printHeader;
    foreach (name; backendNames) {
        auto runner = runners[name];

        foreach (run; fixtureRuns) {
            if (!check.passingPairs.get(pairKey(run.displayName, name), false))
                continue;

            try {
                printRow(
                    run.displayName, name,
                    measure(
                        () { runner.runTests(run.module_); },
                        warmup,
                        iterations,
                    ),
                );
            } catch (Exception e) {
                stderr.writefln(
                    "skipping %s %s: %s",
                    run.displayName, name, e.msg.firstLine,
                );
            }
            writeln;
        }
    }

    if (dubRuns.length > 0) {
        Module[] dubModules;
        foreach (run; dubRuns)
            dubModules ~= run.module_;

        if (dubModules.length > 0) {
            foreach (name; backendNames) {
                auto runner = runners[name];

                const allPassing = dubRuns.all!(
                    run => check.passingPairs.get(
                        pairKey(run.displayName, name),
                        false,
                    ),
                );
                if (!allPassing) {
                    stderr.writefln(
                        "skipping %s %s: failing fixtures", dubPkg, name,
                    );
                    continue;
                }

                try {
                    printRow(
                        dubPkg, name,
                        measure(
                            () {
                                foreach (module_; dubModules)
                                    runner.runTests(module_);
                            },
                            warmup,
                            iterations,
                        ),
                    );
                } catch (Exception e) {
                    stderr.writefln("skipping %s %s: %s", dubPkg, name, e.msg);
                }
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
    string[] fixtures;
}

public struct BenchmarkRun {
    public string displayName;
    public Module module_;
    public Result frontend;
}

public struct BenchmarkRow {
    public string fixture;
    public string backend;
    public Result result;
}

DubInfo resolveDubPkg(in string name) {
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.algorithm.sorting: sort;
    import std.file: dirEntries, exists, SpanMode;
    import std.path: buildPath;
    import std.process: Config, execute;
    import std.string: splitLines, strip;

    const pkgDir = findPkgDir(name);
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

    const rootLibrary = buildPath(pkgDir, "bin", "lib" ~ name ~ ".a");
    if (rootLibrary.exists)
        linkFiles = rootLibrary ~ linkFiles;

    const testsDir = buildPath(pkgDir, "tests");
    if (!testsDir.exists)
        throw new Exception("no tests/ directory found in " ~ pkgDir);

    import std.path: baseName;
    auto fixtures = dirEntries(testsDir, "*.d", SpanMode.depth)
        .filter!(e => e.isFile && !e.name.baseName.isTestRunnerFile)
        .map!(e => e.name)
        .array;
    fixtures.sort;

    return DubInfo(importPaths, linkFiles, fixtures);
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
    in size_t iterations,
) {
    import std.file: readText;

    BenchmarkRun[] runs;
    foreach (path; fixtures) {
        const source      = readText(path);
        const displayName = moduleDisplayName(path, importPaths);
        try {
            // The kept module must be parsed before the timed uncached
            // parses: the first parse of a source claims process-wide
            // ownership of its template instances (TemplateInstance.minst),
            // and only the owner's codegen emits them. SystemLinker links
            // with -z defs, so handing it a module that does not own its
            // instances fails the link with undefined template symbols.
            auto module_ = parseModule(source, importPaths).module_;
            const frontend = measure(
                () {
                    parseModuleUncached(source, importPaths);
                },
                warmup,
                iterations,
            );
            runs ~= BenchmarkRun(displayName, module_, frontend);
        } catch (Exception e) {
            import std.stdio: stderr;

            stderr.writefln("skipping %s: %s", displayName, e.msg);
        }
    }
    return runs;
}

bool isOptimisedBuild() {
    version (D_Optimized) return true;
    else return false;
}

void printRunHeader(in size_t warmup, in size_t iterations) {
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
    writefln("sampling:    %s warmup + %s timed iterations", warmup, iterations);
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
