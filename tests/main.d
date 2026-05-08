import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.language",
        "ut.language_ir",
        "ut.minicereal",
        "ut.cerealed",
    );
}
