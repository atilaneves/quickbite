import reggae;

alias ut = dubBuild!(Configuration("unittest"));
alias utCov = dubBuild!(
    Configuration("unittest-cov"),
    CompilerFlags("-unittest -cov"),
);
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
    qb,
    ffiResolveCacheLateLoadFixture,
);
