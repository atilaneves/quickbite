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
        "ut.backends.interpreter.interception_guard",
        "ut.backends.interpreter.native_block",
        "ut.backends.interpreter.layout",
        "ut.backends.interpreter.frame_layout",
        "ut.backends.interpreter.frame_block",
        "ut.backends.interpreter.place",
        "ut.backends.interpreter.place_value",
        "ut.backends.interpreter.lvalue_place",
        "ut.backends.interpreter.module_table",
        "ut.backends.interpreter.object_table",
        "ut.backends.interpreter.native_array",
        "ut.backends.interpreter.native_struct",
        "ut.backends.interpreter.native_scalar",
        "quickbite.backends.native.llvm_jit",
        "ut.backends.runner.results",
        "ut.backends.runner.lang.expressions",
        "ut.backends.runner.lang.arrays",
        "ut.backends.runner.lang.control_flow",
        "ut.backends.runner.lang.diagnostics",
        "ut.backends.runner.lang.exceptions",
        "ut.backends.runner.lang.logic",
        "ut.backends.runner.lang.integrals",
        "ut.backends.runner.lang.math",
        "ut.backends.runner.lang.structs",
        "ut.backends.runner.lang.cerealed",
        "ut.backends.runner.lang.pollution",
        "ut.backends.runner.lang.archive",
        "ut.backends.runner.lang.imports",
        "ut.backends.runner.sys.concurrency",
        "ut.backends.runner.sys.cstdlib",
        "ut.backends.runner.sys.file",
        "ut.backends.runner.sys.gc",
        "ut.backends.runner.sys.random",
        "ut.orc.elf",
        "ut.backends.native.llvm_jit",
        "ut.backends.native.inline_asm",
        "ut.backends.ffi.dependency_image",
    );
}
