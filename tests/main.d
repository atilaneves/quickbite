import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.value",
        "ut.compiler",
        "ut.backends",
        "ut.backends.eval",
        "ut.backends.parity",
        "ut.backends.bytecode",
        "ut.backends.ir",
        "ut.backends.ctfe",
        "ut.backends.codegen",
        "ut.backends.repl",
        "ut.backends.minicereal",
        "ut.backends.projects.cerealed",
        "ut.backends.deps.cerealed",
    );
}
