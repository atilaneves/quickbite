module benchmarks.main;

import benchmarks.harness: measure, Result;
import quickbite.backends.dmd_ctfe: DmdCtfe;
import quickbite.backends.ir: IrExecutor;
import quickbite.backends.tree_walking: TreeWalkingExecutor;
import quickbite.executor: Executor;
import quickbite.frontend.compiler: parseModule;

private:

// Defaults; overridable with --warmup / --iterations.
enum size_t defaultWarmup = 1;
// Odd, so the median is a single sample without averaging two values.
enum size_t defaultIterations = 9;

int main(string[] args) {
    import std.file: readText;
    import std.getopt: defaultGetoptPrinter, getopt;
    import std.stdio: stderr, writefln, writeln;

    size_t warmup     = defaultWarmup;
    size_t iterations = defaultIterations;
    string[] importPaths;
    string dubPkg;
    bool noDmd;

    auto info = getopt(
        args,
        "warmup",       "untimed iterations before sampling",          &warmup,
        "iterations",   "timed iterations per measurement",            &iterations,
        "import-path",  "add an import search path (repeatable)",      &importPaths,
        "dub",          "benchmark a dub package's tests by name",     &dubPkg,
        "no-dmd",       "omit the dmd subprocess row",                 &noDmd,
    );
    if (info.helpWanted) {
        defaultGetoptPrinter(
            "usage: bench [--warmup=N] [--iterations=N]"
            ~ " [--import-path=P ...] [--dub=NAME] [--no-dmd]"
            ~ " [<module.d> ...]",
            info.options,
        );
        return 0;
    }

    string[] fixtures = args[1 .. $].dup;

    if (dubPkg.length > 0) {
        const dubInfo = resolveDubPkg(dubPkg);
        importPaths ~= dubInfo.importPaths;
        fixtures    ~= dubInfo.fixtures;
        // dmd -run cannot link against a package's precompiled deps.
        noDmd = true;
    }

    if (fixtures.length == 0)
        fixtures = ["tests/minicereal.d"];

    if (!isOptimisedBuild) {
        stderr.writeln(
            "benchmark refuses to run on a non-optimised build "
            ~ "(rebuild with `dub run -c benchmark -b release`).",
        );
        return 1;
    }

    printRunHeader(warmup, iterations);

    Executor[string] backends;
    backends["ir"]          = new IrExecutor;
    backends["treeWalking"] = new TreeWalkingExecutor;
    backends["dmd-ctfe"]    = new DmdCtfe;

    writeln("== post-parse (excludes dmd parse + semantic) ==");
    printHeader;
    foreach (path; fixtures) {
        const source      = readText(path);
        const displayName = moduleDisplayName(path, importPaths);
        try {
            auto parsed  = parseModule(source, importPaths);
            auto module_ = parsed.module_;

            foreach (name; ["ir", "treeWalking", "dmd-ctfe"]) {
                auto executor = backends[name];
                printRow(
                    displayName, name, warmup, iterations,
                    () => executor.runParsedTests(module_),
                );
            }
        } catch (Exception e) {
            stderr.writefln("skipping %s: %s", displayName, e.msg);
        }
        writeln;
    }

    if (!noDmd) {
        writeln;
        writeln("== full edit-to-result (includes parse + semantic; dmd via subprocess) ==");
        printHeader;
        foreach (path; fixtures) {
            const source      = readText(path);
            const displayName = moduleDisplayName(path, importPaths);

            try {
                foreach (name; ["ir", "treeWalking", "dmd-ctfe"]) {
                    auto executor = backends[name];
                    printRow(
                        displayName, name, warmup, iterations,
                        () => executor.runTests(source, importPaths),
                    );
                }
                printRow(displayName, "dmd", warmup, iterations, () => runDmd(path, importPaths));
            } catch (Exception e) {
                stderr.writefln("skipping %s: %s", displayName, e.msg);
            }
            writeln;
        }
    }

    return 0;
}

string moduleDisplayName(in string path, in string[] importPaths) {
    import std.algorithm.searching: startsWith;
    import std.path: absolutePath, baseName, buildNormalizedPath, relativePath, stripExtension;
    import std.string: replace;

    const absPath = path.absolutePath.buildNormalizedPath;
    foreach (ip; importPaths) {
        const rel = absPath.relativePath(ip.absolutePath.buildNormalizedPath);
        if (!rel.startsWith(".."))
            return rel.stripExtension.replace("/", ".").replace("\\", ".");
    }
    return absPath.baseName.stripExtension;
}

struct DubInfo {
    string[] importPaths;
    string[] fixtures;
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
    auto descResult = execute(
        ["dub", "describe", "--config=unittest", "--data=import-paths", "--data-list"],
        null, Config.none, size_t.max,
        pkgDir,
    );
    if (descResult.status != 0)
        descResult = execute(
            ["dub", "describe", "--data=import-paths", "--data-list"],
            null, Config.none, size_t.max,
            pkgDir,
        );
    if (descResult.status != 0)
        throw new Exception("dub describe failed for " ~ name ~ ": " ~ descResult.output);

    auto importPaths = descResult.output
        .splitLines
        .map!(l => l.strip)
        .filter!(l => l.length > 0)
        .array;

    const testsDir = buildPath(pkgDir, "tests");
    if (!testsDir.exists)
        throw new Exception("no tests/ directory found in " ~ pkgDir);

    import std.path: baseName;
    auto fixtures = dirEntries(testsDir, "*.d", SpanMode.depth)
        .filter!(e => e.isFile && !e.name.baseName.isTestRunnerFile)
        .map!(e => e.name)
        .array;
    fixtures.sort;

    return DubInfo(importPaths, fixtures);
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
        "%-32s %-14s %10s %10s %10s",
        "fixture", "backend", "min", "median", "stddev",
    );
    writeln;
}

void printRow(
    in string fixture,
    in string backend,
    in size_t warmup,
    in size_t iterations,
    scope void delegate() run,
) {
    import std.stdio: writefln;

    const result = measure(run, warmup, iterations);
    enum hnsecsPerMs = 10_000.0;
    writefln(
        "%-32s %-14s %7.3f ms %7.3f ms %7.3f ms",
        fixture,
        backend,
        result.min.total!"hnsecs" / hnsecsPerMs,
        result.median.total!"hnsecs" / hnsecsPerMs,
        result.stddevHnsecs / hnsecsPerMs,
    );
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

    const dmdVer = execute(["dmd", "--version"]);
    if (dmdVer.status == 0)
        writefln(
            "dmd (subprocess): %s",
            dmdVer.output.until('\n').array.text.strip,
        );

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

void runDmd(in string path, in string[] importPaths = []) {
    import std.algorithm.iteration: map;
    import std.array: array, join;
    import std.conv: text;
    import std.process: execute;

    const iFlags = importPaths.map!(p => "-I" ~ p).array;
    const args   = ["dmd", "-unittest", "-main"] ~ iFlags ~ ["-run", path];
    const result = execute(args);
    if (result.status != 0)
        throw new Exception(text(
            "`", args.join(" "), "` failed (status ", result.status, "):\n",
            result.output,
        ));
}
