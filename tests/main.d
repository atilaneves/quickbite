import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.language",
        "ut.minicereal",
        "ut.cerealed",
    );
}
