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

void main() {
    import std.file: readText;
    import std.stdio: writefln, writeln;

    const fixtures = [
        Fixture("minicereal.d", "tests/minicereal.d"),
    ];
    const backends = [
        Backend("ir",          &runParsedIrTests),
        Backend("treeWalking", &runParsedTreeWalkingTests),
    ];

    writefln("%-20s %-14s %10s %10s", "fixture", "backend", "min", "median");

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
                "%-20s %-14s %7.2f ms %7.2f ms",
                fixture.name,
                backend.name,
                result.min.total!"usecs" / 1000.0,
                result.median.total!"usecs" / 1000.0,
            );
        }
    }
}
