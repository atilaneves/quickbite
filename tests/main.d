import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.bin.repl",
        "ut.bin.cli",
        "ut.bin.benchmarks",
        "ut.frontend.compiler",
        "ut.backends.evaluator.value",
        "ut.backends.evaluator.eval",
        "ut.backends.runner.results",
        "ut.backends.runner.ct.expressions",
        "ut.backends.runner.ct.arrays",
        "ut.backends.runner.ct.control_flow",
        "ut.backends.runner.ct.diagnostics",
        "ut.backends.runner.ct.exceptions",
        "ut.backends.runner.ct.logic",
        "ut.backends.runner.ct.integrals",
        "ut.backends.runner.ct.math",
        "ut.backends.runner.ct.structs",
        "ut.backends.runner.ct.cerealed",
        "ut.backends.runner.ct.pollution",
        "ut.backends.runner.rt.cstdlib",
        "ut.backends.runner.rt.expressions",
        "ut.backends.runner.rt.arrays",
        "ut.backends.runner.rt.cerealed",
        "ut.backends.runner.rt.archive",
    );
}
