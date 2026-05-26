module ut.backends.minicereal;


import ut.backends;


@("minicerealFileCanRunTwice.dmdCodegen")
unittest {
    if (experimentalBackendTestsEnabled) {
        import quickbite.backends.dmd_codegen: DmdCodegen;
        import quickbite.frontend.compiler: parseModule;
        import std.file: readText;

        // Reusing a parsed module catches stale DMD codegen object state
        // between in-process codegen runs. Without the reset, DMD can carry
        // backend symbols such as `__bzeroBytes` from the first object into
        // the second; the linker then rejects the generated objects before
        // the test runs.
        auto module_ = parseModule(readText("tests/minicereal.d")).module_;
        auto backend = new DmdCodegen;

        backend.runParsedTests(module_);
        backend.runParsedTests(module_);
    }
}
