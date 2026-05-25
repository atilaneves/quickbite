import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.value",
        "ut.eval",
        "ut.backend_parity",
        "ut.bytecode",
        "ut.compiler_api",
        "ut.minicereal",
        "ut.cerealed",
        "ut.projects.cerealed",
        "ut.repl",
    );
}
