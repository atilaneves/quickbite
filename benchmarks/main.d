module benchmarks.main;

import benchmarks.harness: measure, Result;
import quickbite.backends.ir: IrExecutor;
import quickbite.backends.tree_walking: TreeWalkingExecutor;
import quickbite.executor: Executor;
import quickbite.frontend.compiler: parseModule;

private:

// Defaults; overridable with --warmup / --iterations.
enum size_t defaultWarmup = 3;
// Odd, so the median is a single sample without averaging two values.
enum size_t defaultIterations = 31;

int main(string[] args) {
    import std.file: readText;
    import std.getopt: defaultGetoptPrinter, getopt;
    import std.stdio: stderr, writefln, writeln;

    size_t warmup     = defaultWarmup;
    size_t iterations = defaultIterations;

    auto info = getopt(
        args,
        "warmup",     "untimed iterations before sampling", &warmup,
        "iterations", "timed iterations per measurement",   &iterations,
    );
    if (info.helpWanted) {
        defaultGetoptPrinter(
            "usage: bench [--warmup=N] [--iterations=N] <module.d> [<module.d> ...]",
            info.options,
        );
        return 0;
    }
    if (args.length < 2) {
        stderr.writefln("usage: %s <module.d> [<module.d> ...]", args[0]);
        return 1;
    }

    if (!isOptimisedBuild) {
        stderr.writeln(
            "benchmark refuses to run on a non-optimised build "
            ~ "(rebuild with `dub run -c benchmark -b release`).",
        );
        return 1;
    }

    const fixtures = args[1 .. $].idup;

    printRunHeader(warmup, iterations);

    Executor[string] backends;
    backends["ir"]          = new IrExecutor;
    backends["treeWalking"] = new TreeWalkingExecutor;

    writeln("== post-parse (excludes dmd parse + semantic) ==");
    printHeader;
    foreach (path; fixtures) {
        const source = readText(path);
        auto parsed = parseModule(source);
        auto module_ = parsed.module_;

        foreach (name; ["ir", "treeWalking"]) {
            auto executor = backends[name];
            printRow(
                path, name, warmup, iterations,
                () => executor.runParsedTests(module_),
            );
        }
    }

    writeln;
    writeln("== full edit-to-result (includes parse + semantic; dmd via subprocess) ==");
    printHeader;
    foreach (path; fixtures) {
        const source = readText(path);

        foreach (name; ["ir", "treeWalking"]) {
            auto executor = backends[name];
            printRow(
                path, name, warmup, iterations,
                () => executor.runTests(source),
            );
        }
        printRow(path, "dmd", warmup, iterations, () => runDmd(path));
    }

    return 0;
}

void printHeader() {
    import std.stdio: writefln;
    writefln(
        "%-32s %-14s %10s %10s %10s",
        "fixture", "backend", "min", "median", "stddev",
    );
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

void runDmd(in string path) {
    import std.array: join;
    import std.conv: text;
    import std.process: execute;

    const args = ["dmd", "-unittest", "-main", "-run", path];
    const result = execute(args);
    if (result.status != 0)
        throw new Exception(text(
            "`", args.join(" "), "` failed (status ", result.status, "):\n",
            result.output,
        ));
}
