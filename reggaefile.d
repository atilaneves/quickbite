import reggae;

alias ut = dubBuild!(Configuration("unittest"));
alias utCov = dubBuild!(
    Configuration("unittest-cov"),
    CompilerFlags("-unittest -cov"),
);
// Optimisation comes from the dub build type passed on the reggae command
// line (`--dub-build-type=release-nobounds`), which - unlike per-target
// CompilerFlags - propagates `-O` into the dub dependencies (dmd:frontend,
// :dmd-backend-vendor) that the benchmark actually times. bin/bench.sh drives
// that build into its own directory; the dev build.ninja leaves this `debug`.
alias bench = dubBuild!(Configuration("benchmark-ldc"));
alias qb = dubBuild!(
    Configuration("qb"),
    CompilerFlags("-O -release -boundscheck=off"),
);
alias ffiResolveCacheLateLoadFixture = dubDependant!(
    TargetName("bin/ffi-resolve-cache-late-load-fixture"),
    DubPackageTargetType.sharedLibrary,
    Sources!(Files("tests/ut/ffi/late_load_fixture.d")),
    CompilerFlags("-fPIC -version=FfiResolveCacheLateLoadFixture"),
    LinkerFlags("-defaultlib=libphobos2.so"),
);

mixin build!(
    ut,
    utCov,
    bench,
    qb,
    ffiResolveCacheLateLoadFixture,
);
