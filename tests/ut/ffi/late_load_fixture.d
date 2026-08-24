module ut.ffi.late_load_fixture;


version (FfiResolveCacheLateLoadFixture) {
    extern(C) int ffiResolveCacheLateLoadFixture() {
        return 42;
    }
}
