import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.compiler_api",
        "ut.language",
        "ut.minicereal",
        "ut.cerealed",
    );
}
