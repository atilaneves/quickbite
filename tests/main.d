import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.backend_parity",
        "ut.bytecode",
        "ut.eval",
        "ut.compiler_api",
        "ut.minicereal",
        "ut.cerealed",
        "ut.projects.cerealed",
        "ut.repl",
    );
}
