import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.lang",
        "ut.value",
        "ut.compiler",
        "ut.benchmarks",
        "ut.backends",
        "ut.backends.pure_.arrays",
        "ut.backends.pure_.diagnostics",
        "ut.backends.pure_.eval",
        "ut.backends.pure_.expressions",
        "ut.backends.pure_.control_flow",
        "ut.backends.pure_.exceptions",
        "ut.backends.pure_.logic",
        "ut.backends.pure_.math",
        "ut.backends.pure_.structs",
        "ut.backends.pure_.minicereal",
        "ut.backends.pure_.projects.cerealed",
        "ut.backends.contracts",
        "ut.backends.codegen",
        "ut.backends.repl",
        "ut.backends.deps.unit_threaded",
        "ut.backends.deps.cerealed",
    );
}
