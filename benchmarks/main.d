module benchmarks.main;

import benchmarks.harness: measure, Result;
import quickbite.backends.ir: runIrTests, runParsedIrTests;
import quickbite.backends.tree_walking:
    runParsedTreeWalkingTests, TreeWalkingExecutor;
import quickbite.frontend.compiler: parseModule;

private:

private struct Fixture {
    string name;
    string path;
}

enum size_t warmup = 1;
enum size_t iterations = 10;

int main(string[] args) {
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.file: readText;
    import std.path: baseName;
    import std.stdio: stderr, writefln, writeln;

    if (args.length < 2) {
        stderr.writefln("usage: %s <module.d> [<module.d> ...]", args[0]);
        return 1;
    }

    const fixtures = args[1 .. $]
        .map!(path => Fixture(path.baseName, path))
        .array;

    writeln("== post-parse (excludes dmd parse + semantic) ==");
    printHeader;
    foreach (fixture; fixtures) {
        const source = readText(fixture.path);
        auto parsed = parseModule(source);
        auto module_ = parsed.module_;

        printRow(fixture.name, "ir",          () => runParsedIrTests(module_));
        printRow(fixture.name, "treeWalking", () => runParsedTreeWalkingTests(module_));
    }

    writeln;
    writeln("== full edit-to-result (includes parse + semantic; dmd via subprocess) ==");
    printHeader;
    foreach (fixture; fixtures) {
        const source = readText(fixture.path);
        const path   = fixture.path;

        printRow(fixture.name, "ir",          () => runIrTests(source));
        printRow(fixture.name, "treeWalking", () => (new TreeWalkingExecutor).runTests(source));
        printRow(fixture.name, "dmd",         () => runDmd(path));
    }

    return 0;
}

void printHeader() {
    import std.stdio: writefln;
    writefln(
        "%-20s %-14s %10s %10s %10s",
        "fixture", "backend", "min", "median", "stddev",
    );
}

void printRow(in string fixture, in string backend, scope void delegate() run) {
    import std.stdio: writefln;

    const result = measure(run, warmup, iterations);
    writefln(
        "%-20s %-14s %7.2f ms %7.2f ms %7.2f ms",
        fixture,
        backend,
        result.min.total!"usecs" / 1000.0,
        result.median.total!"usecs" / 1000.0,
        result.stddevUsecs / 1000.0,
    );
}

void runDmd(in string path) {
    import std.process: Config, executeShell, escapeShellCommand;
    import std.conv: text;

    const cmd = escapeShellCommand("dmd", "-unittest", "-main", "-run", path);
    const result = executeShell(cmd, null, Config.suppressConsole);
    if (result.status != 0)
        throw new Exception(text("dmd -run failed (status ", result.status, "): ", result.output));
}
