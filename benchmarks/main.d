module benchmarks.main;

import benchmarks.harness: measure, Result;
import quickbite.backends.ir: runParsedIrTests;
import quickbite.backends.tree_walking: runParsedTreeWalkingTests;
import quickbite.frontend.compiler: parseModule;

private:

private struct Fixture {
    string name;
    string path;
}

private struct Backend {
    string name;
    void function(imported!"dmd.dmodule".Module) run;
}

enum size_t warmup = 1;
enum size_t iterations = 10;

int main(string[] args) {
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.file: readText;
    import std.path: baseName;
    import std.stdio: stderr, writefln;

    if (args.length < 2) {
        stderr.writefln("usage: %s <module.d> [<module.d> ...]", args[0]);
        return 1;
    }

    const fixtures = args[1 .. $]
        .map!(path => Fixture(path.baseName, path))
        .array;
    const backends = [
        Backend("ir",          &runParsedIrTests),
        Backend("treeWalking", &runParsedTreeWalkingTests),
    ];

    writefln(
        "%-20s %-14s %10s %10s %10s",
        "fixture", "backend", "min", "median", "stddev",
    );

    foreach (fixture; fixtures) {
        const source = readText(fixture.path);
        auto parsed = parseModule(source);
        auto module_ = parsed.module_;

        foreach (backend; backends) {
            const result = measure(
                () => backend.run(module_),
                warmup,
                iterations,
            );
            writefln(
                "%-20s %-14s %7.2f ms %7.2f ms %7.2f ms",
                fixture.name,
                backend.name,
                result.min.total!"usecs" / 1000.0,
                result.median.total!"usecs" / 1000.0,
                result.stddevUsecs / 1000.0,
            );
        }
    }

    return 0;
}
