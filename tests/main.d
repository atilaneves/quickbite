import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.lang",
        "ut.repl_cli",
        "ut.backends.architecture",
        "ut.backends.api.runner",
        "ut.backends.lang.eval",
        "ut.backends.lang.expressions",
        "ut.backends.lang.arrays",
        "ut.backends.lang.control_flow",
        "ut.backends.lang.diagnostics",
        "ut.backends.lang.exceptions",
        "ut.backends.lang.logic",
        "ut.backends.lang.integral_types",
        "ut.backends.lang.math",
        "ut.backends.lang.structs",
        "ut.backends.projects.cerealed",
        "ut.backends.api.repl",
        "ut.backends.interpreter",
        "ut.backends.ctfe",
        "ut.value",
        "ut.compiler",
        "ut.benchmarks",
    );
}
