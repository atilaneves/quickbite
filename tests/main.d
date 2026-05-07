import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.backends",
        "ut.negative",
        "ut.ir",
        "ut.tree_walking",
        "ut.minicereal",
    );
}
