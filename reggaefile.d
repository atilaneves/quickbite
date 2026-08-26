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
alias bench = dubBuild!(
    Configuration("benchmark-ldc"),
    CompilerFlags("-g"),
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

// bench-exec must be DMD-built: it loads the DMD-codegen'd `.so` the
// SystemLinker benchmark produces, so its druntime has to be DMD's. The rest
// of the benchmark build is LDC, and `dubBuild!` uses one compiler for every
// target, so this is a raw target with its own `dmd` command. Ninja builds it
// in parallel with the host and rebuilds it only when a source changes.
// Flags mirror the `bench-exec` sub-package in dub.sdl.
enum benchExec = Target(
    "bin/bench-exec",
    "dmd -of$out -defaultlib=libphobos2.so -L-lLLVM"
        ~ " -I$project/bench-exec -I$project $in",
    [
        Target("bench-exec/main.d"),
        Target("bench-exec/run_wire.d"),
        Target("orc/bindings.d"),
        Target("orc/elf.d"),
        Target("orc/loader.d"),
    ],
);

mixin build!(
    ut,
    utCov,
    bench,
    benchExec,
    qb,
    ffiResolveCacheLateLoadFixture,
);
