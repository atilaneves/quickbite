import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.value",
        "ut.compiler",
        "ut.backends",
        "ut.backends.pure_.arrays",
        "ut.backends.pure_.diagnostics",
        "ut.backends.pure_.eval",
        "ut.backends.pure_.expressions",
        "ut.backends.pure_.control_flow",
        "ut.backends.pure_.logic",
        "ut.backends.pure_.structs",
        "ut.backends.pure_.minicereal",
        "ut.backends.pure_.projects.cerealed",
        "ut.backends.parity",
        "ut.backends.bytecode",
        "ut.backends.ir",
        "ut.backends.ctfe",
        "ut.backends.codegen",
        "ut.backends.repl",
        "ut.backends.minicereal",
        "ut.backends.deps.cerealed",
    );
}
