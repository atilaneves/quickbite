import unit_threaded;

int main(string[] args) {
    import quickbite.frontend.compiler: DubMode, initialize;

    // bin/ut is the single-snippet world: keep the lightning rod and allInst.
    initialize(DubMode.no);

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
        "ut.backends.runner.ct.archive",
        "ut.backends.runner.ct.imports",
        "ut.backends.runner.rt.cstdlib",
        "ut.backends.runner.rt.dependency_image",
        "ut.backends.runner.rt.elf",
        "ut.backends.runner.rt.inline_asm",
        "ut.backends.runner.rt.llvm_jit",
    );
}
