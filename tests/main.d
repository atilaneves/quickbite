import unit_threaded;

int main(string[] args) {
    return args.runTests!(
        "ut.language",
        "ut.negative",
        "ut.minicereal",
        "ut.dmd_ctfe",
    );
}
